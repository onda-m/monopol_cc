//
//  SkywayManager.swift
//  swift_skyway
//
//  Created by onda on 2018/04/10.
//  Copyright © 2018年 worldtrip. All rights reserved.
//

import Foundation
import UIKit
import AVFoundation
import SkyWayRoom

private var instance: SkywayManager? = nil

protocol SkywaySessionDelegate: AnyObject {
    func sessionStart()
    func connectSucces()
    func remoteConnectSucces()
    func connectDisconnect()
    func connectEnd()
    func connectError()
}

class SkywayManager: NSObject, RoomDelegate, LocalRoomMemberDelegate, RoomPublicationDelegate, RoomSubscriptionDelegate, RemoteDataStreamDelegate {

    private var room: Room?
    private var localMember: LocalRoomMember?
    private var roomPublications: [String: RoomPublication] = [:]
    private var roomSubscriptions: [String: RoomSubscription] = [:]
    private var delegatesAttached: Bool = false
    private var localVideoStream: LocalVideoStream?
    private var localAudioStream: LocalAudioStream?
    private var localDataStream: LocalDataStream?
    private var microphoneAudioSource: MicrophoneAudioSource?
    private var cameraVideoSource: CameraVideoSource?
    private var dataSource: DataSource?
    private var cameraDevice: AVCaptureDevice?
    private var capturingSucceeded: Bool = false
    /// video publish 済みフラグ（二重 publish 完全防止）
    private var hasPublishedVideo: Bool = false
    /// video publish 実行中フラグ（concurrent publish 防止）
    private var isPublishingVideo: Bool = false
    /// ローカルトラック（audio + video）生成完了フラグ — これが true でなければ publish 禁止
    private(set) var localTracksReady: Bool = false
    private var contextSetupDone: Bool = false

    /// 診断用: publish 前提条件の文字列を返す
    var diagPublishState: String {
        return "room=\(room == nil ? "nil" : "exists") localMember=\(localMember == nil ? "nil" : "exists") videoStream=\(localVideoStream == nil ? "nil" : "exists") audioStream=\(localAudioStream == nil ? "nil" : "exists") capturing=\(capturingSucceeded) hasPublishedVideo=\(hasPublishedVideo) isPublishingVideo=\(isPublishingVideo) tracksReady=\(localTracksReady)"
    }

    /// approval gate 用: session が健全かどうか
    var isSessionHealthy: Bool {
        return room != nil && localMember != nil && localTracksReady && capturingSucceeded
    }
    private var remoteVideoStream: RemoteVideoStream?
    private var remoteAudioStream: RemoteAudioStream?
    private var remoteDataStream: RemoteDataStream?
    private var localVideoView: VideoView?
    private var remoteVideoView: VideoView?
    private weak var localContainerView: UIView?
    private weak var remoteContainerView: UIView?
    private var roomTask: Task<Void, Never>?
    private var roomClosed = false
    private var peerId: String = ""
    private var isConnectStarted: Bool = false
    private var isLeaving: Bool = false
    private weak var sessionDelegate: SkywaySessionDelegate?
    /// NewSDK チャット受信時に呼ばれるクロージャ（WaitViewController が登録）
    var onChatReceived: ((String) -> Void)?
    /// NewSDK チャット受信時にメタ情報付きで呼ばれるクロージャ（text, jsonDict）
    var onChatReceivedMeta: ((String, [String: Any]) -> Void)?
    private var subscribedPublicationIds: Set<String> = []
    //private var roomType: RoomType = .P2P

    private let backendBaseURL: String = "https://test.monopol.jp"

    private var tokenRoomNameForContextSetup: String = "default"

    /// バックグラウンド遷移で video を unpublish 済みかどうか
    private var videoUnpublishedForBackground: Bool = false

    class func sharedManager() -> SkywayManager {
        if (instance == nil) {
            instance = SkywayManager()
            instance!.registerAppLifecycleObservers()
        }
        return instance!
    }

    /// バックグラウンド/フォアグラウンド通知を登録
    /// iOS がバックグラウンドでカメラを停止すると track が invalid になり sender.cpp:78 crash する
    private func registerAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    /// バックグラウンド遷移時: video publication を unpublish して track 参照を安全に切る
    @objc private func appDidEnterBackground() {
        print("[DIAG][CB] appDidEnterBackground \(diagPublishState)")
        Task { @MainActor in
            await self.unpublishVideoIfNeeded()
            self.videoUnpublishedForBackground = true
        }
    }

    /// フォアグラウンド復帰時: camera を再 capture して video を再 publish
    @objc private func appWillEnterForeground() {
        print("[DIAG][CB] appWillEnterForeground bgUnpublished=\(videoUnpublishedForBackground) \(diagPublishState)")
        Task { @MainActor in
            guard self.videoUnpublishedForBackground else {
                print("[DIAG][CB] appWillEnterForeground SKIP bgUnpublished=false")
                return
            }
            self.videoUnpublishedForBackground = false
            print("[DIAG][CB] appWillEnterForeground → recaptureAndRepublishVideo START")
            await self.recaptureAndRepublishVideo()
            print("[DIAG][CB] appWillEnterForeground → recaptureAndRepublishVideo END")
        }
    }

    /// video publication を unpublish + 状態リセット
    @MainActor
    private func unpublishVideoIfNeeded() async {
        for (pubId, pub) in roomPublications where pub.contentType == .video {
            do {
                try await localMember?.unpublish(publicationId: pubId)
                print("[SkyMgr][lifecycle] video unpublished pubId=\(pubId)")
            } catch {
                print("[SkyMgr][lifecycle] video unpublish error pubId=\(pubId) error=\(error)")
            }
            pub.delegate = nil
            roomPublications.removeValue(forKey: pubId)
        }
        resetVideoStateIfNeeded()
    }

    /// camera 再 capture → video 再 publish（フォアグラウンド復帰用）
    @MainActor
    private func recaptureAndRepublishVideo() async {
        guard let localMember = localMember else {
            print("[SkyMgr][lifecycle] recapture: localMember=nil, skip")
            return
        }
        guard !roomClosed else {
            print("[SkyMgr][lifecycle] recapture: roomClosed=true, skip")
            return
        }
        await prepareLocalStreamsIfNeeded()
        let ok = await safePublishVideo(localMember: localMember)
        print("[SkyMgr][lifecycle] recapture result=\(ok) capturingOK=\(capturingSucceeded) stream=\(localVideoStream != nil)")
        if ok {
            attachLocalVideo()
        }
    }

    // MARK: Session
    func sessionStart(delegate: SkywaySessionDelegate) {
        logState("sessionStart.begin")
        print("[SkyMgr] sessionStart called")
        sessionDelegate = delegate
        // Context setup は joinRoomIfNeeded 内の setupContextIfNeeded() で行う
        // ここで setup すると roomName が未確定（"default"）のままトークンが発行され
        // 初回 joinRoom で 403 insufficient permissions になる
        if peerId.isEmpty {
            peerId = UUID().uuidString
        }
        print("[SkyMgr] sessionStart success, peerId=\(peerId)")
        delegate.sessionStart()
    }

    @MainActor
    private func setupContextIfNeeded() async throws {
        guard !contextSetupDone else {
            return
        }
        print("[SkyMgr] Context setup start (reset)")
        let token = try await fetchSkywayTokenFromServer(
            roomName: tokenRoomNameForContextSetup,
            userId: peerId.isEmpty ? "anonymous" : peerId
        )
        print("[SkyMgr] token source: cloudflare (\(backendBaseURL)/skyway/token)")
        logTokenExpiry(jwt: token)
        // Dispose stale context if it exists (e.g., previous dispose failed)
        if Context.isSetup {
            try? await Context.dispose()
        }
        try await Context.setup(withToken: token, options: nil)
        contextSetupDone = true
        print("[SkyMgr] Context setup completed")
        logState("contextSetup.completed")
    }

    /// サーバーからSkyWay JWTを取得する
    /// - Parameters:
    ///   - roomName: 参加予定のルーム名
    ///   - userId: ユーザー識別子
    /// - Returns: JWT文字列
    private func fetchSkywayTokenFromServer(roomName: String, userId: String) async throws -> String {
        let url = URL(string: backendBaseURL)!.appendingPathComponent("skyway/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["roomName": roomName, "userId": userId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SkyMgr", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "n/a"
            let bodyStr = String(raw.prefix(200))
            print("[SkyMgr] fetchToken failed: status=\(httpResponse.statusCode) body=\(bodyStr)")
            throw NSError(domain: "SkyMgr", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server returned \(httpResponse.statusCode)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw NSError(domain: "SkyMgr", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
        }
        return token
    }

    /// JSON の数値を Int? に安全変換する（NSNumber / Double / String 対応）
    private func safeInt(from value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String   { return Int(s) }
        return nil
    }

    /// JWT の exp / iat / jti を安全にログ出力する（トークン全文は出さない）
    /// json は Optional として扱い、Optional chaining でアクセスする（コンパイルエラー回避）
    private func logTokenExpiry(jwt token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            print("[SkyMgr] token check: invalid JWT format")
            return
        }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else {
            print("[SkyMgr] token check: failed to decode base64")
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any] else {
            print("[SkyMgr] token check: failed to parse JSON payload")
            return
        }
        let exp = safeInt(from: json["exp"]) ?? 0
        let iat = safeInt(from: json["iat"]) ?? 0
        let now = Int(Date().timeIntervalSince1970)
        let ttl = exp - iat
        let jtiRaw = json["jti"] as? String ?? "unknown"
        let jtiPrefix = String(jtiRaw.prefix(8))
        print("[SkyMgr] token check: exp=\(exp), iat=\(iat), ttl=\(ttl)s, now-iat=\(now - iat)s, jti=\(jtiPrefix)...")
    }

    /// デバッグ用: 改行をエスケープして1行にする
    @inline(__always)
    private func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }

    /// デバッグ用: callstack を短縮して1行にまとめる
    private let enableCallstackLog = true

    private func shortCallstack(_ maxLines: Int = 5) -> String {
        guard enableCallstackLog else { return "cs=disabled" }
        let syms = Thread.callStackSymbols.dropFirst(2).prefix(maxLines)
        let cleaned = syms.map { line -> String in
            let parts = line.components(separatedBy: " ")
            return parts.suffix(4).joined(separator: " ")
        }
        return "cs=" + cleaned.map(oneLine).joined(separator: " | ")
    }

    /// デバッグ用: 主要フラグの一括ログ出力
    private func logState(_ label: String, reason: String? = nil, includeCallstack: Bool = false) {
        let roomStr = (room != nil) ? "yes" : "nil"
        let memberStr = (localMember != nil) ? "yes" : "nil"
        let reasonStr = reason.map { " reason=\(oneLine($0))" } ?? ""
        let state = "isConnectStarted=\(isConnectStarted) isLeaving=\(isLeaving) delegatesAttached=\(delegatesAttached) roomClosed=\(roomClosed) contextSetupDone=\(contextSetupDone) room=\(roomStr) localMember=\(memberStr)"
        let cs = includeCallstack ? " \(shortCallstack(5))" : ""
        print("[SkyMgr] STATE[\(oneLine(label))]\(reasonStr) \(state)\(cs)")
    }

    func getPeerId() -> String {
        return peerId
    }

    public func setWaitLocal(localView: UIView, delegate: SkywaySessionDelegate) {
        sessionDelegate = delegate
        localContainerView = localView
        Task { @MainActor in
            await prepareLocalStreamsIfNeeded()
            attachLocalVideo()
        }
    }

    /// ルームに参加し、ローカルストリームを publish する
    /// - Parameters:
    ///   - roomName: 参加するルーム名（キャストの場合は自分の peerId、ユーザーの場合はキャストの peerId）
    ///   - delegate: コールバック受信用デリゲート
    public func connectStart(roomName: String, delegate: SkywaySessionDelegate) {
        logState("connectStart.begin")
        print("[SkyMgr] connectStart thread=\(Thread.isMainThread ? "MT" : "BG") roomName=\(roomName) myPeerId=\(peerId)")

        // 離脱中ガード: leave 処理中は再待機を拒否
        if isLeaving {
            print("[SkyMgr] connectStart skipped: currently leaving (isLeaving=true)")
            return
        }

        // 多重開始ガード: 既に接続中の場合はスキップ
        if isConnectStarted && room != nil {
            print("[SkyMgr] connectStart skipped: already connected (isConnectStarted=true, room exists)")
            return
        }

        isConnectStarted = true
        sessionDelegate = delegate
        roomClosed = false
        hasPublishedVideo = false  // 新セッション開始のためリセット
        localTracksReady = false   // トラック未生成状態に戻す
        delegatesAttached = false  // 【5】再join時に attachRoomCallbacks が確実に実行されるようリセット
        print("[SkyMgr] roomClosed set to false reason=connectStart hasPublishedVideo→false localTracksReady→false")
        subscribedPublicationIds.removeAll()  // リセット
        roomTask?.cancel()
        roomTask = Task { @MainActor in
            guard !Task.isCancelled else {
                print("[SkyMgr] connectStart Task cancelled before join")
                isConnectStarted = false
                return
            }
            let memberName = peerId.isEmpty ? String(UserDefaults.standard.integer(forKey: "user_id")) : peerId
            await joinRoomIfNeeded(roomName: roomName, memberName: memberName)
        }
    }

    public func closeMedia(localView: UIView, remoteView: UIView) {
        logState("closeMedia.begin")
        localContainerView = localView
        remoteContainerView = remoteView
        isConnectStarted = false
        roomClosed = true
        print("[SkyMgr] roomClosed set to true reason=closeMedia")
        contextSetupDone = false  // Synchronous reset (async detachRoomCallbacks also resets)
        roomTask?.cancel()
        roomTask = nil
        Task { @MainActor in
            // cleanupRoomResources (= detachRoomCallbacks) 完了を待ってから stream を解放
            await cleanupRoomResources(reason: "closeMedia")
            self.localDataStream = nil
            self.localAudioStream = nil
            self.localVideoStream = nil
            self.microphoneAudioSource = nil
            self.cameraVideoSource = nil
            self.capturingSucceeded = false
            self.hasPublishedVideo = false
            self.localTracksReady = false
            self.dataSource = nil
            self.cameraDevice = nil
            self.remoteVideoStream = nil
            self.remoteAudioStream = nil
            self.remoteDataStream = nil
            self.detachLocalVideo()
            self.detachRemoteVideo()
            self.sessionDelegate?.connectEnd()
        }
    }

    public func sessionClose() {
        Task { @MainActor in
            await leaveRoomIfNeeded(reason: "sessionClose")
        }
    }

    public func registerLocalVideoStream(_ stream: LocalVideoStream?) {
        localVideoStream = stream
    }

    public func setLocalVideoEnabled(_ enabled: Bool) {
        // Enable/disable is done via the publication, not the stream
        guard let videoPublication = roomPublications.values.first(where: { $0.contentType == .video }) else { return }
        Task {
            if enabled {
                try? await videoPublication.enable()
            } else {
                try? await videoPublication.disable()
            }
        }
    }

    func setRemoteView(remoteView: UIView) {
        remoteContainerView = remoteView
        attachRemoteVideo()
    }

    /// NewSDK 経由でプレーンテキストを送信する（スタンプ・nocoin・auto 等、JSON ラップ不要の payload 用）
    func sendData(text: String) {
        Task { @MainActor in
            guard let stream = self.localDataStream else {
                print("[DATA][NEWSDK][SEND] SKIP localDataStream=nil text=\(String(text.prefix(20)))")
                return
            }
            do {
                try await stream.write(text)
                print("[DATA][NEWSDK][SEND] result=ok len=\(text.count) textHead=\(String(text.prefix(30)))")
            } catch {
                print("[DATA][NEWSDK][SEND] result=error len=\(text.count) error=\(error)")
            }
        }
    }

    /// NewSDK 経由でテキストを送信する（localDataStream が publish 済みであること）
    func sendChat(text: String) {
        Task { @MainActor in
            guard let stream = self.localDataStream else {
                print("[CHAT][NEWSDK][SEND] SKIP localDataStream=nil text=\(String(text.prefix(20)))")
                return
            }
            do {
                try await stream.write(text)
                print("[CHAT][NEWSDK][SEND] result=ok len=\(text.count) textHead=\(String(text.prefix(30)))")
            } catch {
                print("[CHAT][NEWSDK][SEND] result=error len=\(text.count) error=\(error)")
            }
        }
    }

    @MainActor
    private func joinRoomIfNeeded(roomName: String, memberName: String) async {
        logState("joinRoomIfNeeded.begin")
        guard roomClosed == false else {
            logState("joinRoomIfNeeded.skip", reason: "roomClosed=true")
            print("[SkyMgr] joinRoomIfNeeded skipped: roomClosed=true")
            return
        }

        // 【1】再join安全化: 旧セッションが残存していたら完全破棄してからjoin
        if room != nil || localMember != nil {
            print("[SkyMgr] joinRoomIfNeeded: stale session detected (room=\(room != nil) localMember=\(localMember != nil)), cleaning up first")
            await detachRoomCallbacks(reason: "joinRoomIfNeeded.staleCleanup")
        }

        do {
            print("[SkyMgr] joinRoomIfNeeded START thread=\(Thread.isMainThread ? "MT" : "BG") roomName=\(roomName) memberName=\(memberName)")
            tokenRoomNameForContextSetup = roomName
            try await setupContextIfNeeded()
            let roomOptions = Room.InitOptions()
            roomOptions.name = roomName
            let room = try await P2PRoom.findOrCreate(with: roomOptions)
            self.room = room
            print("[SkyMgr] P2PRoom.findOrCreate success, roomId=\(room.id ?? "nil"), name=\(room.name ?? "nil")")
            let memberOptions = Room.MemberInitOptions()
            memberOptions.name = memberName
            let localMember = try await room.join(with: memberOptions)
            self.localMember = localMember
            print("[SkyMgr] room.join success, localMemberId=\(localMember.id), name=\(localMember.name ?? "nil")")
            attachRoomCallbacks(room: room, localMember: localMember)
            try await publishLocalStreams(localMember: localMember)
            print("[SkyMgr] joinRoomIfNeeded COMPLETE thread=\(Thread.isMainThread ? "MT" : "BG") calling connectSucces")
            sessionDelegate?.connectSucces()
        } catch {
            print("[SkyMgr] joinRoomIfNeeded ERROR thread=\(Thread.isMainThread ? "MT" : "BG") error=\(error) \(diagPublishState)")
            isConnectStarted = false
            sessionDelegate?.connectError()
        }
    }

    @MainActor
    private func attachRoomCallbacks(room: Room, localMember: LocalRoomMember) {
        // Idempotent: skip if already attached
        guard !delegatesAttached else {
            print("[SkyMgr] attachRoomCallbacks skipped: already attached")
            return
        }
        delegatesAttached = true
        print("[SkyMgr] attachRoomCallbacks start")

        // 【2】delegate 多重登録防止: 必ず nil → self の順で設定
        room.delegate = nil
        room.delegate = self

        localMember.delegate = nil
        localMember.delegate = self

        // Set delegates for existing publications we own
        for (_, publication) in roomPublications {
            publication.delegate = self
        }

        // Set delegates for existing subscriptions
        for (_, subscription) in roomSubscriptions {
            subscription.delegate = self
        }

        // Auto-subscribe to existing remote publications
        let localMemberId = localMemberIdentifier(localMember)
        let existingPubs = room.publications.filter { publicationPublisherIdentifier($0) != localMemberId }
        print("[SkyMgr] existing remote publications count=\(existingPubs.count)")
        for publication in existingPubs {
            Task { @MainActor in
                await self.subscribeToPublication(publication, localMember: localMember)
            }
        }

        // Check if remote members already present
        let remoteMembers = room.members.filter { memberIdentifier($0) != localMemberId }
        print("[SkyMgr] existing remote members count=\(remoteMembers.count)")
        if !remoteMembers.isEmpty {
            print("[SkyMgr] remote member found, calling remoteConnectSucces")
            sessionDelegate?.remoteConnectSucces()
        }
    }

    @MainActor
    func detachRoomCallbacks(reason: String) async {
        logState("detach.start", reason: reason, includeCallstack: true)
        print("[SkyMgr] detachRoomCallbacks start reason=\(oneLine(reason))")

        // (1) Unsubscribe all - await で完了を待つ
        if let member = localMember {
            for (subscriptionId, _) in roomSubscriptions {
                print("[SkyMgr] unsubscribe.start subId=\(subscriptionId)")
                do {
                    try await member.unsubscribe(subscriptionId: subscriptionId)
                    print("[SkyMgr] unsubscribe.ok subId=\(subscriptionId)")
                } catch {
                    print("[SkyMgr] unsubscribe.fail subId=\(subscriptionId) error=\(error)")
                }
            }
        }

        // (2) Unpublish all - await で完了を待つ
        if let member = localMember {
            for (publicationId, _) in roomPublications {
                print("[SkyMgr] unpublish.start pubId=\(publicationId)")
                do {
                    try await member.unpublish(publicationId: publicationId)
                    print("[SkyMgr] unpublish.ok pubId=\(publicationId)")
                } catch {
                    print("[SkyMgr] unpublish.fail pubId=\(publicationId) error=\(error)")
                }
            }
        }

        // (3) Leave room - 必ず await で完了を待つ
        if let member = localMember {
            let memberId = member.id
            print("[SkyMgr] leave.start memberId=\(memberId)")
            do {
                try await member.leave()
                print("[SkyMgr] leave.ok memberId=\(memberId)")
            } catch {
                print("[SkyMgr] leave.fail memberId=\(memberId) error=\(error)")
            }
        }

        // (4) leave 完了後に delegate を nil にし、map をクリア
        for (_, subscription) in roomSubscriptions {
            subscription.delegate = nil
        }
        roomSubscriptions.removeAll()
        print("[SkyMgr] roomSubscriptions cleared")

        for (_, publication) in roomPublications {
            publication.delegate = nil
        }
        roomPublications.removeAll()
        print("[SkyMgr] roomPublications cleared")

        localMember?.delegate = nil
        room?.delegate = nil

        // (5) Detach views, clear streams
        detachRemoteVideo()
        remoteVideoStream = nil
        remoteAudioStream = nil
        remoteDataStream?.delegate = nil
        remoteDataStream = nil
        print("[SkyMgr] remote streams cleared")

        detachLocalVideo()
        localVideoStream = nil
        localAudioStream = nil
        localDataStream = nil
        capturingSucceeded = false
        hasPublishedVideo = false
        isPublishingVideo = false
        localTracksReady = false
        print("[SkyMgr] local streams cleared hasPublishedVideo→false localTracksReady→false")

        // (6) Clear references and reset guards
        self.localMember = nil
        self.room = nil
        delegatesAttached = false
        isConnectStarted = false
        subscribedPublicationIds.removeAll()
        contextSetupDone = false

        print("[SkyMgr] Context reset on disconnect")
        logState("detach.after", reason: reason)
        print("[SkyMgr] detachRoomCallbacks complete reason=\(oneLine(reason))")
    }

    private func localMemberIdentifier(_ member: LocalRoomMember) -> String {
        member.id
    }

    private func memberIdentifier(_ member: RoomMember) -> String {
        member.id
    }

    private func publicationPublisherIdentifier(_ publication: RoomPublication) -> String? {
        publication.publisher?.id
    }

    /// video publish の安全ゲート
    /// ガード順: ロック → 完了 → トラック準備完了 → stream/source 個別チェック → 二重登録 → publish
    @MainActor
    private func safePublishVideo(localMember: LocalRoomMember) async -> Bool {
        print("[DIAG][PUBLISH] safePublishVideo ENTER localMember=exists room=\(room == nil ? "nil" : "exists") videoStream=\(localVideoStream == nil ? "nil" : "exists") audioStream=\(localAudioStream == nil ? "nil" : "exists") capturing=\(capturingSucceeded) hasPublished=\(hasPublishedVideo) isPublishing=\(isPublishingVideo) tracksReady=\(localTracksReady)")
        print("[SkyMgr][safePublish] ENTER isPublishingVideo=\(isPublishingVideo) hasPublishedVideo=\(hasPublishedVideo) localTracksReady=\(localTracksReady)")
        // --- 1. 同時実行ロック ---
        guard !isPublishingVideo else {
            print("[DIAG][PUBLISH_GATE] skip reason=isPublishingVideo_true")
            print("[SkyMgr][safePublish] BLOCK: already publishing")
            return false
        }
        // --- 2. 完了フラグ ---
        guard !hasPublishedVideo else {
            print("[DIAG][PUBLISH_GATE] skip reason=hasPublishedVideo_true")
            print("[SkyMgr][safePublish] BLOCK: already published (hasPublishedVideo=true)")
            return true
        }
        // --- 3. トラック準備完了チェック（audio + video 両方必須）---
        guard localTracksReady else {
            print("[DIAG][PUBLISH_GATE] skip reason=localTracksReady_false")
            print("[SkyMgr][safePublish] BLOCK: localTracksReady=false (tracks not generated)")
            return false
        }
        // ロック取得
        isPublishingVideo = true
        defer { isPublishingVideo = false }

        // --- 4. 個別 stream nil チェック ---
        guard let stream = localVideoStream else {
            print("[DIAG][PUBLISH_GATE] skip reason=localVideoStream_nil")
            print("[SkyMgr][safePublish] BLOCK: localVideoStream=nil")
            return false
        }
        guard localAudioStream != nil else {
            print("[DIAG][PUBLISH_GATE] skip reason=localAudioStream_nil")
            print("[SkyMgr][safePublish] BLOCK: localAudioStream=nil (audio track missing)")
            return false
        }
        guard capturingSucceeded else {
            print("[DIAG][PUBLISH_GATE] skip reason=capturingSucceeded_false")
            print("[SkyMgr][safePublish] BLOCK: capturingSucceeded=false")
            return false
        }
        guard cameraVideoSource != nil else {
            print("[DIAG][PUBLISH_GATE] skip reason=cameraVideoSource_nil")
            print("[SkyMgr][safePublish] BLOCK: cameraVideoSource=nil (capture source lost)")
            resetVideoStateIfNeeded()
            return false
        }
        // --- 5. roomPublications 二重登録チェック ---
        let alreadyPublished = roomPublications.values.contains(where: { $0.contentType == .video })
        guard !alreadyPublished else {
            print("[DIAG][PUBLISH_GATE] skip reason=already_in_roomPublications")
            print("[SkyMgr][safePublish] SKIP: video already in roomPublications (fixing flag)")
            hasPublishedVideo = true
            return true
        }
        // --- 6. publish 実行 ---
        do {
            let pub = try await localMember.publish(stream, options: RoomPublicationOptions())
            pub.delegate = self
            roomPublications[pub.id] = pub
            hasPublishedVideo = true
            print("[SkyMgr][safePublish] SUCCESS pubId=\(pub.id) hasPublishedVideo→true")
            print("[DIAG][PUBLISH] SUCCESS kind=video")
            attachLocalVideo()
            return true
        } catch {
            print("[SkyMgr][safePublish] FAIL error=\(error)")
            print("[DIAG][PUBLISH] FAIL kind=video error=\(error)")
            resetVideoStateIfNeeded()
            return false
        }
    }

    /// video 状態をリセットし、次回 prepareLocalStreamsIfNeeded で再 capture させる
    private func resetVideoStateIfNeeded() {
        print("[SkyMgr] resetVideoStateIfNeeded: hasPublishedVideo=\(hasPublishedVideo) capturingSucceeded=\(capturingSucceeded) videoStream=\(localVideoStream != nil) cameraSource=\(cameraVideoSource != nil)")
        hasPublishedVideo = false
        localTracksReady = false
        capturingSucceeded = false
        localVideoStream = nil
        cameraVideoSource = nil
    }

    /// 条件が揃った場合のみ publish を実行する公開エントリポイント
    /// remoteConnectSucces 等から直接 publish せず、この関数を経由する
    @MainActor
    func tryPublishIfReady() {
        guard let localMember = localMember else {
            print("[SkyMgr][tryPublish] SKIP: localMember=nil")
            return
        }
        guard localTracksReady else {
            print("[SkyMgr][tryPublish] SKIP: localTracksReady=false")
            return
        }
        guard !hasPublishedVideo else {
            print("[SkyMgr][tryPublish] SKIP: hasPublishedVideo=true")
            return
        }
        print("[SkyMgr][tryPublish] conditions met → safePublishVideo")
        Task { @MainActor in
            let ok = await self.safePublishVideo(localMember: localMember)
            print("[SkyMgr][tryPublish] result=\(ok)")
        }
    }

    @MainActor
    private func publishLocalStreams(localMember: LocalRoomMember) async throws {
        print("[SkyMgr][publish] ENTER CALLED hasPublishedVideo=\(hasPublishedVideo) localTracksReady=\(localTracksReady) audioStream=\(localAudioStream != nil) videoStream=\(localVideoStream != nil) dataStream=\(localDataStream != nil) capturingOK=\(capturingSucceeded) bgUnpublished=\(videoUnpublishedForBackground)")
        await prepareLocalStreamsIfNeeded()
        print("[SkyMgr][publish] afterPrepare localTracksReady=\(localTracksReady) audioStream=\(localAudioStream != nil) videoStream=\(localVideoStream != nil) dataStream=\(localDataStream != nil) capturingOK=\(capturingSucceeded)")
        // --- Audio ---
        print("[DIAG][PUBLISH] BEFORE AUDIO localAudioStream=\(localAudioStream == nil ? "nil" : "exists") localMember=\(localMember == nil ? "nil" : "exists") room=\(room == nil ? "nil" : "exists")")
        if let localAudioStream = localAudioStream {
            print("[SkyMgr][publish][AUDIO] >>> CALLING localMember.publish(audio) micSource=\(microphoneAudioSource != nil)")
            do {
                let pub = try await localMember.publish(localAudioStream, options: RoomPublicationOptions())
                pub.delegate = self
                roomPublications[pub.id] = pub
                print("[SkyMgr][publish][AUDIO] <<< SUCCESS pubId=\(pub.id)")
                print("[DIAG][PUBLISH] SUCCESS kind=audio")
            } catch {
                print("[SkyMgr][publish][AUDIO] <<< FAILED error=\(error)")
                print("[DIAG][PUBLISH] FAIL kind=audio error=\(error)")
            }
        } else {
            print("[DIAG][PUBLISH_GATE] skip reason=localAudioStream_nil (in publishLocalStreams)")
            print("[SkyMgr][publish][AUDIO] SKIP stream=nil")
        }
        // --- Video: safePublishVideo のみ（直接 publish 禁止）---
        print("[DIAG][PUBLISH] BEFORE VIDEO localVideoStream=\(localVideoStream == nil ? "nil" : "exists") localMember=\(localMember == nil ? "nil" : "exists") room=\(room == nil ? "nil" : "exists")")
        print("[SkyMgr][publish][VIDEO] >>> CALLING safePublishVideo")
        let videoOk = await safePublishVideo(localMember: localMember)
        if !videoOk {
            print("[SkyMgr][publish][VIDEO] <<< SKIP by safePublishVideo gate")
        } else {
            print("[SkyMgr][publish][VIDEO] <<< OK")
        }
        // --- Data ---
        if let localDataStream = localDataStream {
            print("[SkyMgr][publish][DATA] >>> CALLING localMember.publish(data) dataSource=\(dataSource != nil)")
            do {
                let pub = try await localMember.publish(localDataStream, options: RoomPublicationOptions())
                pub.delegate = self
                roomPublications[pub.id] = pub
                print("[SkyMgr][publish][DATA] <<< SUCCESS pubId=\(pub.id)")
            } catch {
                print("[SkyMgr][publish][DATA] <<< FAILED error=\(error)")
            }
        } else {
            print("[SkyMgr][publish][DATA] SKIP stream=nil")
        }
        print("[SkyMgr][publish] complete total=\(roomPublications.count)")
    }

    /// 【3】capturingSucceeded を唯一の video 判定基準とする
    /// startCapturing 成功時のみ createStream() を呼ぶ（nil track crash 防止）
    @MainActor
    private func prepareLocalStreamsIfNeeded() async {
        // --- Audio ---
        if localAudioStream == nil {
            if microphoneAudioSource == nil {
                microphoneAudioSource = MicrophoneAudioSource()
            }
            localAudioStream = microphoneAudioSource?.createStream()
            print("[SkyMgr][prepare] audio: source=\(microphoneAudioSource != nil) stream=\(localAudioStream != nil)")
        }

        // --- Video: capturingSucceeded が true なら再生成不要 ---
        if !capturingSucceeded {
            // 前回の失敗 stream を破棄（nil track の可能性がある）
            localVideoStream = nil

            let source = cameraVideoSource ?? CameraVideoSource.shared()
            self.cameraVideoSource = source
            if cameraDevice == nil {
                cameraDevice = CameraVideoSource.supportedCameras().first(where: { $0.position == .front })
            }
            print("[SkyMgr][prepare] video: cameraDevice=\(cameraDevice != nil) capturingSucceeded=\(capturingSucceeded)")
            if let device = cameraDevice {
                do {
                    try await source.startCapturing(with: device, options: nil)
                    capturingSucceeded = true
                    localVideoStream = source.createStream()
                    print("[SkyMgr][prepare] video: startCapturing OK stream=\(localVideoStream != nil)")
                } catch {
                    capturingSucceeded = false
                    localVideoStream = nil
                    print("[SkyMgr][prepare] video: startCapturing FAILED error=\(error) — createStream SKIPPED")
                }
            } else {
                capturingSucceeded = false
                localVideoStream = nil
                print("[SkyMgr][prepare] video: SKIP no cameraDevice available")
            }
        }

        // --- Data ---
        if localDataStream == nil {
            if dataSource == nil {
                dataSource = DataSource()
            }
            localDataStream = dataSource?.createStream()
            print("[SkyMgr][prepare] data: source=\(dataSource != nil) stream=\(localDataStream != nil)")
        }

        // --- トラック生成完了判定 ---
        let audioOk = localAudioStream != nil
        let videoOk = localVideoStream != nil && capturingSucceeded
        let wasReady = localTracksReady
        localTracksReady = audioOk && videoOk
        print("[SkyMgr][prepare] localTracksReady=\(localTracksReady) (was=\(wasReady)) audioOk=\(audioOk) videoOk=\(videoOk)")
    }

    @MainActor
    private func subscribeToPublication(_ publication: RoomPublication, localMember: LocalRoomMember) async {
        let pubId = publication.id

        // Guard: skip if already subscribed to this publication
        if subscribedPublicationIds.contains(pubId) {
            print("[SkyMgr] subscribeToPublication skipped: already subscribed pubId=\(pubId)")
            return
        }

        // Also check SDK-side subscriptions
        for sub in localMember.subscriptions {
            if sub.publication?.id == pubId {
                print("[SkyMgr] subscribeToPublication skipped: SDK already has subscription for pubId=\(pubId)")
                subscribedPublicationIds.insert(pubId)
                if roomSubscriptions[sub.id] == nil {
                    sub.delegate = self
                    roomSubscriptions[sub.id] = sub
                    handleStreamAttachment(subscription: sub)
                }
                return
            }
        }

        // Mark as subscribing before await to prevent race
        subscribedPublicationIds.insert(pubId)

        do {
            print("[SkyMgr][subscribe] start pubId=\(pubId) contentType=\(publication.contentType)")
            let subscription = try await localMember.subscribe(publicationId: pubId, options: nil)
            subscription.delegate = self
            roomSubscriptions[subscription.id] = subscription
            print("[SkyMgr][subscribe] ok subId=\(subscription.id) pubId=\(pubId)")
            handleStreamAttachment(subscription: subscription)
        } catch {
            // Subscription may fail if publication was canceled
            print("[SkyMgr][subscribe] fail pubId=\(pubId) error=\(error)")
            subscribedPublicationIds.remove(pubId)
        }
    }

    @MainActor
    private func handleStreamAttachment(subscription: RoomSubscription) {
        print("[DIAG][ATTACH] BEFORE stream=\(subscription.stream == nil ? "nil" : "exists") subId=\(subscription.id)")
        // stream=nil の場合は即 return（SDK内部 publish 誘発による crash 防止）
        // 「will attach later」ロジックは完全禁止
        guard let stream = subscription.stream else {
            print("[SkyMgr][attach] BLOCK: stream=nil subId=\(subscription.id) → attach禁止（crash防止）")
            return
        }
        if let videoStream = stream as? RemoteVideoStream {
            print("[SkyMgr][attach] remote video OK subId=\(subscription.id)")
            remoteVideoStream = videoStream
            attachRemoteVideo()
            sessionDelegate?.remoteConnectSucces()
        } else if let audioStream = stream as? RemoteAudioStream {
            print("[SkyMgr][attach] remote audio OK subId=\(subscription.id)")
            remoteAudioStream = audioStream
        } else if let dataStream = stream as? RemoteDataStream {
            print("[SkyMgr][attach] remote data OK subId=\(subscription.id)")
            remoteDataStream = dataStream
            dataStream.delegate = self
        }
    }

    @MainActor
    func leaveRoomIfNeeded(reason: String, setRoomClosed: Bool = true) async {
        print("[NEWSDK][LEAVE] leaveRoomIfNeeded reason=\(reason)")
        print("[NEWSDK][LEAVE] room=\(String(describing: room)) localMember=\(String(describing: localMember))")
        // 二重実行防止
        guard !isLeaving else {
            print("[SkyMgr] leaveRoomIfNeeded skipped: already leaving")
            return
        }
        isLeaving = true
        defer { isLeaving = false }

        print("[SkyMgr] leaveRoomIfNeeded START thread=\(Thread.isMainThread ? "MT" : "BG") reason=\(reason)")
        logState("leaveRoomIfNeeded.begin")
        await detachRoomCallbacks(reason: reason)
        if setRoomClosed {
            roomClosed = true
            print("[SkyMgr] roomClosed set to true reason=\(reason)")
        }
        print("[SkyMgr] leaveRoomIfNeeded END thread=\(Thread.isMainThread ? "MT" : "BG") reason=\(reason)")
    }

    @MainActor
    private func cleanupRoomResources(reason: String) async {
        await detachRoomCallbacks(reason: reason)
    }

    private func attachLocalVideo() {
        guard let localContainerView = localContainerView else {
            print("[SkyMgr][attachLocalVideo] BLOCK: localContainerView=nil")
            return
        }
        // stream が nil の場合は attach 禁止（VideoView 作成もスキップ）
        guard let stream = localVideoStream else {
            print("[SkyMgr][attachLocalVideo] BLOCK: localVideoStream=nil capturingOK=\(capturingSucceeded)")
            return
        }
        if localVideoView == nil {
            localVideoView = VideoView(frame: localContainerView.bounds)
            if let localVideoView = localVideoView {
                localVideoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                localContainerView.addSubview(localVideoView)
            }
        }
        if let localVideoView = localVideoView {
            stream.attach(localVideoView)
            print("[SkyMgr][attachLocalVideo] stream attached to view OK")
        }
    }

    /// 【6】attachRemoteVideo: remoteVideoStream nil guard 追加
    private func attachRemoteVideo() {
        guard let remoteContainerView = remoteContainerView else {
            print("[SkyMgr] attachRemoteVideo: remoteContainerView=nil, skip")
            return
        }
        guard let stream = remoteVideoStream else {
            print("[SkyMgr] attachRemoteVideo: remoteVideoStream=nil, skip")
            return
        }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.attachRemoteVideo() }
            return
        }
        remoteContainerView.layoutIfNeeded()
        print("[SkyMgr] attachRemoteVideo: frame=\(remoteContainerView.frame) hidden=\(remoteContainerView.isHidden) superview=\(remoteContainerView.superview != nil)")
        if remoteVideoView == nil {
            remoteVideoView = VideoView(frame: remoteContainerView.bounds)
            if let remoteVideoView = remoteVideoView {
                remoteVideoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                remoteContainerView.addSubview(remoteVideoView)
            }
        }
        if let remoteVideoView = remoteVideoView {
            stream.attach(remoteVideoView)
        }
    }

    /// Idempotent: safe to call multiple times, safe if views/streams are nil
    private func detachLocalVideo() {
        // Detach stream from view (safe even if either is nil)
        if let view = localVideoView, let stream = localVideoStream {
            stream.detach(view)
            print("[SkyMgr] detachLocalVideo: stream detached from view")
        }
        // Remove view from superview and clear reference
        if let view = localVideoView {
            view.removeFromSuperview()
            localVideoView = nil
            print("[SkyMgr] detachLocalVideo: view removed")
        }
    }

    /// Idempotent: safe to call multiple times, safe if views/streams are nil
    private func detachRemoteVideo() {
        // Detach stream from view (safe even if either is nil)
        if let view = remoteVideoView, let stream = remoteVideoStream {
            stream.detach(view)
            print("[SkyMgr] detachRemoteVideo: stream detached from view")
        }
        // Remove view from superview and clear reference
        if let view = remoteVideoView {
            view.removeFromSuperview()
            remoteVideoView = nil
            print("[SkyMgr] detachRemoteVideo: view removed")
        }
    }

    // MARK: - RoomDelegate

    func roomDidClose(_ room: Room) {
        Task { @MainActor in
            print("[DIAG][CB] roomDidClose delegatesAttached=\(self.delegatesAttached) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            print("[SkyMgr] roomDidClose")
            await self.detachRoomCallbacks(reason: "roomDidClose")  // isConnectStarted = false はここで設定される
            self.sessionDelegate?.connectEnd()
        }
    }

    func roomMemberListDidChange(_ room: Room) {
        print("[DIAG][CB] roomMemberListDidChange \(diagPublishState)")
    }

    func room(_ room: Room, memberDidJoin member: RoomMember) {
        Task { @MainActor in
            let memberId = self.memberIdentifier(member)
            let localId = self.localMember.map { self.localMemberIdentifier($0) } ?? "nil"
            let isRemote = memberId != localId
            print("[DIAG][CB] memberDidJoin memberId=\(memberId) isRemote=\(isRemote) \(self.diagPublishState)")
            print("[FLOW][L7] memberDidJoin memberId=\(memberId) localId=\(localId) isRemote=\(isRemote) delegatesAttached=\(self.delegatesAttached) localMember=\(self.localMember == nil ? "nil" : "exists") roomId=\(room.id)")
            guard self.delegatesAttached else { return }
            guard let localMember = self.localMember else { return }
            if self.memberIdentifier(member) != self.localMemberIdentifier(localMember) {
                print("[FLOW][L7] calling remoteConnectSucces")
                self.sessionDelegate?.remoteConnectSucces()
            }
        }
    }

    func room(_ room: Room, memberDidLeave member: RoomMember) {
        Task { @MainActor in
            print("[DIAG][CB] memberDidLeave memberId=\(member.id) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            guard !self.roomClosed else { return }
            guard let localMember = self.localMember else { return }
            if self.memberIdentifier(member) != self.localMemberIdentifier(localMember) {
                print("[SkyMgr] memberDidLeave: remote member left, memberId=\(member.id)")
                self.sessionDelegate?.connectDisconnect()
                await self.leaveRoomIfNeeded(reason: "memberDidLeave")
            }
        }
    }

    func roomPublicationListDidChange(_ room: Room) {
        print("[DIAG][CB] roomPublicationListDidChange \(diagPublishState)")
    }

    func room(_ room: Room, didPublishStreamOf publication: RoomPublication) {
        Task { @MainActor in
            let pubId = publication.id
            let contentType = publication.contentType
            let publisherId = self.publicationPublisherIdentifier(publication) ?? "nil"
            let localMemberId = self.localMember.map { self.localMemberIdentifier($0) } ?? "nil"
            let isRemote = publisherId != localMemberId
            print("[DIAG][CB] didPublishStreamOf pubId=\(pubId) contentType=\(contentType) publisherId=\(publisherId) isRemote=\(isRemote) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            guard let localMember = self.localMember else { return }
            if isRemote {
                await self.subscribeToPublication(publication, localMember: localMember)
            }
        }
    }

    /// 【7】didUnpublishStreamOf: remote stream クリア追加
    func room(_ room: Room, didUnpublishStreamOf publication: RoomPublication) {
        Task { @MainActor in
            let pubId = publication.id
            let contentType = publication.contentType
            print("[DIAG][CB] didUnpublishStreamOf pubId=\(pubId) contentType=\(contentType) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }

            // contentType に応じて remote stream を確実にクリア
            switch contentType {
            case .video:
                self.detachRemoteVideo()
                self.remoteVideoStream = nil
                print("[SkyMgr] didUnpublishStreamOf: remoteVideoStream cleared")
            case .audio:
                self.remoteAudioStream = nil
                print("[SkyMgr] didUnpublishStreamOf: remoteAudioStream cleared")
            case .data:
                self.remoteDataStream?.delegate = nil
                self.remoteDataStream = nil
                print("[SkyMgr] didUnpublishStreamOf: remoteDataStream cleared")
            @unknown default:
                break
            }

            // Clean up associated subscription and subscribedPublicationIds
            self.subscribedPublicationIds.remove(pubId)
            for (subId, sub) in self.roomSubscriptions {
                if sub.publication?.id == pubId {
                    sub.delegate = nil
                    self.roomSubscriptions.removeValue(forKey: subId)
                    print("[SkyMgr] didUnpublishStreamOf: removed subscription subId=\(subId)")
                    break
                }
            }
        }
    }

    func roomSubscriptionListDidChange(_ room: Room) {
        print("[DIAG][CB] roomSubscriptionListDidChange \(diagPublishState)")
    }

    func room(_ room: Room, didSubscribePublicationOf subscription: RoomSubscription) {
        Task { @MainActor in
            print("[DIAG][CB] didSubscribePublicationOf subId=\(subscription.id) contentType=\(subscription.contentType) stream=\(subscription.stream == nil ? "nil" : "exists") \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            if self.roomSubscriptions[subscription.id] == nil {
                subscription.delegate = self
                self.roomSubscriptions[subscription.id] = subscription
                self.handleStreamAttachment(subscription: subscription)
            }
        }
    }

    func room(_ room: Room, didUnsubscribePublicationOf subscription: RoomSubscription) {
        Task { @MainActor in
            print("[DIAG][CB] didUnsubscribePublicationOf subId=\(subscription.id) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            subscription.delegate = nil
            self.roomSubscriptions.removeValue(forKey: subscription.id)
        }
    }

    // MARK: - LocalRoomMemberDelegate

    func localRoomMember(_ member: LocalRoomMember, didUnpublishStreamOf publication: RoomPublication) {
        Task { @MainActor in
            print("[DIAG][CB] localMember.didUnpublishStreamOf pubId=\(publication.id) contentType=\(publication.contentType) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            publication.delegate = nil
            self.roomPublications.removeValue(forKey: publication.id)
        }
    }

    func localRoomMember(_ member: LocalRoomMember, didUnsubscribePublicationOf subscription: RoomSubscription) {
        Task { @MainActor in
            print("[DIAG][CB] localMember.didUnsubscribePublicationOf subId=\(subscription.id) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            subscription.delegate = nil
            self.roomSubscriptions.removeValue(forKey: subscription.id)
        }
    }

    // MARK: - RoomSubscriptionDelegate

    func subscription(_ subscription: RoomSubscription, connectionStateDidChange connectionState: ConnectionState) {
        Task { @MainActor in
            print("[DIAG][CB] subscription.connectionStateDidChange subId=\(subscription.id) state=\(connectionState) contentType=\(subscription.contentType) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            if connectionState == .disconnected {
                subscription.delegate = nil
                self.roomSubscriptions.removeValue(forKey: subscription.id)
                if subscription.contentType == .video {
                    self.detachRemoteVideo()
                    self.remoteVideoStream = nil
                    self.sessionDelegate?.connectDisconnect()
                }
            }
        }
    }

    func subscription(_ subscription: RoomSubscription, didAttach stream: RemoteStream) {
        Task { @MainActor in
            print("[DIAG][CB] subscription.didAttach subId=\(subscription.id) streamType=\(type(of: stream)) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            guard subscription.stream != nil else {
                print("[SkyMgr][didAttach] BLOCK: subscription.stream=nil despite didAttach, subId=\(subscription.id)")
                return
            }
            self.handleStreamAttachment(subscription: subscription)
        }
    }

    // MARK: - RoomPublicationDelegate

    func publicationStateDidChange(_ publication: RoomPublication) {
        Task { @MainActor in
            print("[DIAG][CB] publicationStateDidChange pubId=\(publication.id) state=\(publication.state) contentType=\(publication.contentType) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            if publication.state == .canceled {
                publication.delegate = nil
                self.roomPublications.removeValue(forKey: publication.id)
            }
        }
    }

    func publication(_ publication: RoomPublication, connectionStateDidChange connectionState: ConnectionState) {
        Task { @MainActor in
            print("[DIAG][CB] publication.connectionStateDidChange pubId=\(publication.id) state=\(connectionState) contentType=\(publication.contentType) \(self.diagPublishState)")
            guard self.delegatesAttached else { return }
            if connectionState == .disconnected {
                publication.delegate = nil
                self.roomPublications.removeValue(forKey: publication.id)
            }
        }
    }

    // MARK: - RemoteDataStreamDelegate

    func dataStream(_ dataStream: RemoteDataStream, didReceive string: String) {
        Task { @MainActor in
            print("[CHAT][NEWSDK][RECV][RAW]", string)
            print("[CHAT][NEWSDK][RECV] len=\(string.count) textHead=\(String(string.prefix(30)))")
            if let data = string.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let json = obj as? [String: Any],
               json["type"] as? String == "chat",
               let text = json["text"] as? String {
                self.onChatReceivedMeta?(text, json)
                self.onChatReceived?(text)
            } else {
                self.onChatReceived?(string)
            }
        }
    }
}
