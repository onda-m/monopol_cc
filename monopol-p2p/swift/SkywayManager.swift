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

class SkywayManager: NSObject, RoomDelegate, LocalRoomMemberDelegate, RoomPublicationDelegate, RoomSubscriptionDelegate {

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
    private var contextSetupDone: Bool = false
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
    private weak var sessionDelegate: SkywaySessionDelegate?
    private var subscribedPublicationIds: Set<String> = []
    //private var roomType: RoomType = .P2P

    private let backendBaseURL: String = "https://test.monopol.jp"

    private var tokenRoomNameForContextSetup: String = "default"

    class func sharedManager() -> SkywayManager {
        if (instance == nil) {
            instance = SkywayManager()
        }
        return instance!
    }

    // MARK: Session
    func sessionStart(delegate: SkywaySessionDelegate) {
        logState("sessionStart.begin")
        print("[SkyMgr] sessionStart called")
        sessionDelegate = delegate
        Task { @MainActor in
            do {
                try await setupContextIfNeeded()
                if peerId.isEmpty {
                    peerId = UUID().uuidString
                }
                print("[SkyMgr] sessionStart success, peerId=\(peerId)")
                delegate.sessionStart()
            } catch {
                print("[SkyMgr] sessionStart error: \(error)")
                delegate.connectError()
            }
        }
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        let state = "isConnectStarted=\(isConnectStarted) delegatesAttached=\(delegatesAttached) roomClosed=\(roomClosed) contextSetupDone=\(contextSetupDone) room=\(roomStr) localMember=\(memberStr)"
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
        print("[SkyMgr] connectStart called, roomName=\(roomName), myPeerId=\(peerId)")

        // 多重開始ガード: 既に接続中の場合はスキップ
        if isConnectStarted && room != nil {
            print("[SkyMgr] connectStart skipped: already connected (isConnectStarted=true, room exists)")
            return
        }

        isConnectStarted = true
        sessionDelegate = delegate
        roomClosed = false
        print("[SkyMgr] roomClosed set to false reason=connectStart")
        subscribedPublicationIds.removeAll()  // リセット
        roomTask?.cancel()
        roomTask = Task { @MainActor in
            await leaveRoomIfNeeded(reason: "connectStart cleanup", setRoomClosed: false)
            guard !Task.isCancelled else {
                print("[SkyMgr] connectStart Task cancelled before join")
                isConnectStarted = false
                return
            }
            await joinRoomIfNeeded(roomName: roomName, memberName: peerId)
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
            await cleanupRoomResources(reason: "closeMedia")
        }
        localDataStream = nil
        localAudioStream = nil
        localVideoStream = nil
        microphoneAudioSource = nil
        cameraVideoSource = nil
        dataSource = nil
        cameraDevice = nil
        remoteVideoStream = nil
        remoteAudioStream = nil
        remoteDataStream = nil
        detachLocalVideo()
        detachRemoteVideo()
        sessionDelegate?.connectEnd()
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

    @MainActor
    private func joinRoomIfNeeded(roomName: String, memberName: String) async {
        logState("joinRoomIfNeeded.begin")
        guard roomClosed == false else {
            logState("joinRoomIfNeeded.skip", reason: "roomClosed=true")
            print("[SkyMgr] joinRoomIfNeeded skipped: roomClosed=true")
            return
        }
        do {
            print("[SkyMgr] joinRoomIfNeeded start, roomName=\(roomName), memberName=\(memberName)")
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
            print("[SkyMgr] joinRoomIfNeeded complete, calling connectSucces")
            sessionDelegate?.connectSucces()
        } catch {
            print("[SkyMgr] joinRoomIfNeeded error: \(error)")
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

        // Set room delegate
        room.delegate = self

        // Set localMember delegate
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

        // (a) Nil subscription delegates
        for (_, subscription) in roomSubscriptions {
            subscription.delegate = nil
        }

        // (b) Nil publication delegates
        for (_, publication) in roomPublications {
            publication.delegate = nil
        }

        // (c) Unsubscribe all
        if let localMember = localMember {
            for (subscriptionId, _) in roomSubscriptions {
                print("[SkyMgr] unsubscribe subId=\(subscriptionId)")
                try? await localMember.unsubscribe(subscriptionId: subscriptionId)
            }
        }
        roomSubscriptions.removeAll()  // 念のため二重処理防止
        print("[SkyMgr] roomSubscriptions cleared")

        // (d) Unpublish all
        if let localMember = localMember {
            for (publicationId, _) in roomPublications {
                print("[SkyMgr] unpublish pubId=\(publicationId)")
                try? await localMember.unpublish(publicationId: publicationId)
            }
        }
        roomPublications.removeAll()  // 念のため二重処理防止
        print("[SkyMgr] roomPublications cleared")

        // (e) Nil localMember delegate
        localMember?.delegate = nil

        // (f) Leave room
        if let localMember = localMember {
            print("[SkyMgr] leaving room, memberId=\(localMember.id)")
            try? await localMember.leave()
        }

        // (g) Nil room delegate
        room?.delegate = nil

        // (h) Detach views first (while streams still exist), then clear streams
        detachRemoteVideo()
        remoteVideoStream = nil
        remoteAudioStream = nil
        remoteDataStream = nil
        print("[SkyMgr] remote streams cleared")

        // (i) Detach local views first, then clear local streams (再接続時は prepareLocalStreamsIfNeeded で再生成)
        detachLocalVideo()
        localVideoStream = nil
        localAudioStream = nil
        localDataStream = nil
        print("[SkyMgr] local streams cleared")

        // (j) Clear references and reset guards
        self.localMember = nil
        self.room = nil
        delegatesAttached = false
        isConnectStarted = false
        subscribedPublicationIds.removeAll()

        // (k) Reset Context flag so next sessionStart re-runs Context.setup
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

    @MainActor
    private func publishLocalStreams(localMember: LocalRoomMember) async throws {
        print("[SkyMgr] publishLocalStreams start")
        await prepareLocalStreamsIfNeeded()
        if let localAudioStream = localAudioStream {
            let pub = try await localMember.publish(localAudioStream, options: RoomPublicationOptions())
            pub.delegate = self
            roomPublications[pub.id] = pub
            print("[SkyMgr] published audio, pubId=\(pub.id)")
        }
        if let localVideoStream = localVideoStream {
            let pub = try await localMember.publish(localVideoStream, options: RoomPublicationOptions())
            pub.delegate = self
            roomPublications[pub.id] = pub
            print("[SkyMgr] published video, pubId=\(pub.id)")
        }
        print("[SkyMgr] publishLocalStreams complete, total publications=\(roomPublications.count)")
        // Data stream deferred for MVP
    }

    @MainActor
    private func prepareLocalStreamsIfNeeded() async {
        if localAudioStream == nil {
            if microphoneAudioSource == nil {
                microphoneAudioSource = MicrophoneAudioSource()
            }
            localAudioStream = microphoneAudioSource?.createStream()
        }
        if localVideoStream == nil {
            let cameraVideoSource = cameraVideoSource ?? CameraVideoSource.shared()
            self.cameraVideoSource = cameraVideoSource
            if cameraDevice == nil {
                cameraDevice = CameraVideoSource.supportedCameras().first(where: { $0.position == .front })
            }
            if let cameraDevice = cameraDevice {
                try? await cameraVideoSource.startCapturing(with: cameraDevice, options: nil)
                localVideoStream = cameraVideoSource.createStream()
            }
        }
        if localDataStream == nil {
            if dataSource == nil {
                dataSource = DataSource()
            }
            localDataStream = dataSource?.createStream()
        }
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
            print("[SkyMgr] subscribeToPublication start, pubId=\(pubId), contentType=\(publication.contentType)")
            let subscription = try await localMember.subscribe(publicationId: pubId, options: nil)
            subscription.delegate = self
            roomSubscriptions[subscription.id] = subscription
            print("[SkyMgr] subscribeToPublication success, subId=\(subscription.id), pubId=\(pubId)")
            handleStreamAttachment(subscription: subscription)
        } catch {
            // Subscription may fail if publication was canceled
            print("[SkyMgr] subscribeToPublication failed, pubId=\(pubId), error=\(error)")
            subscribedPublicationIds.remove(pubId)
        }
    }

    @MainActor
    private func handleStreamAttachment(subscription: RoomSubscription) {
        guard let stream = subscription.stream else {
            print("[SkyMgr] handleStreamAttachment: stream is nil, will attach on didAttach event, subId=\(subscription.id)")
            return
        }
        if let videoStream = stream as? RemoteVideoStream {
            print("[SkyMgr] handleStreamAttachment: attaching remote video, subId=\(subscription.id)")
            remoteVideoStream = videoStream
            attachRemoteVideo()
            sessionDelegate?.remoteConnectSucces()
        } else if let audioStream = stream as? RemoteAudioStream {
            print("[SkyMgr] handleStreamAttachment: attaching remote audio, subId=\(subscription.id)")
            remoteAudioStream = audioStream
        }
        // Data stream deferred for MVP
    }

    @MainActor
    func leaveRoomIfNeeded(reason: String) async {
        print("[SkyMgr] leaveRoomIfNeeded start reason=\(reason)")
        logState("leaveRoomIfNeeded.begin")
        await detachRoomCallbacks(reason: reason)
        roomClosed = true
        print("[SkyMgr] roomClosed set to true reason=\(reason)")
    }

    @MainActor
    private func cleanupRoomResources(reason: String) async {
        await detachRoomCallbacks(reason: reason)
    }

    private func attachLocalVideo() {
        guard let localContainerView = localContainerView else { return }
        if localVideoView == nil {
            localVideoView = VideoView(frame: localContainerView.bounds)
            if let localVideoView = localVideoView {
                localVideoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                localContainerView.addSubview(localVideoView)
            }
        }
        if let localVideoStream = localVideoStream, let localVideoView = localVideoView {
            localVideoStream.attach(localVideoView)
        }
    }

    private func attachRemoteVideo() {
        guard let remoteContainerView = remoteContainerView else { return }
        if remoteVideoView == nil {
            remoteVideoView = VideoView(frame: remoteContainerView.bounds)
            if let remoteVideoView = remoteVideoView {
                remoteVideoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                remoteContainerView.addSubview(remoteVideoView)
            }
        }
        if let remoteVideoStream = remoteVideoStream, let remoteVideoView = remoteVideoView {
            remoteVideoStream.attach(remoteVideoView)
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
            guard self.delegatesAttached else { return }
            print("[SkyMgr] roomDidClose")
            await self.detachRoomCallbacks(reason: "roomDidClose")  // isConnectStarted = false はここで設定される
            self.sessionDelegate?.connectEnd()
        }
    }

    func roomMemberListDidChange(_ room: Room) {
        // Handled by memberDidJoin/memberDidLeave
    }

    func room(_ room: Room, memberDidJoin member: RoomMember) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            guard let localMember = self.localMember else { return }
            if self.memberIdentifier(member) != self.localMemberIdentifier(localMember) {
                self.sessionDelegate?.remoteConnectSucces()
            }
        }
    }

    func room(_ room: Room, memberDidLeave member: RoomMember) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            guard !self.roomClosed else { return }  // 既に閉じている場合はスキップ
            guard let localMember = self.localMember else { return }
            if self.memberIdentifier(member) != self.localMemberIdentifier(localMember) {
                print("[SkyMgr] memberDidLeave: remote member left, memberId=\(member.id)")
                // 1対1通話なので相手が退出したら終了扱い
                self.sessionDelegate?.connectDisconnect()
                // ルームから退出してリソースをクリーンアップ
                await self.leaveRoomIfNeeded(reason: "memberDidLeave")  // isConnectStarted = false はここで設定される
            }
        }
    }

    func roomPublicationListDidChange(_ room: Room) {
        // Handled by didPublishStreamOf/didUnpublishStreamOf
    }

    func room(_ room: Room, didPublishStreamOf publication: RoomPublication) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            guard let localMember = self.localMember else { return }
            let localMemberId = self.localMemberIdentifier(localMember)
            if self.publicationPublisherIdentifier(publication) != localMemberId {
                await self.subscribeToPublication(publication, localMember: localMember)
            }
        }
    }

    func room(_ room: Room, didUnpublishStreamOf publication: RoomPublication) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            // Remote unpublished; subscription will be canceled automatically
            // Clean up associated subscription if any
            for (subId, sub) in self.roomSubscriptions {
                if sub.publication?.id == publication.id {
                    sub.delegate = nil
                    self.roomSubscriptions.removeValue(forKey: subId)
                    break
                }
            }
        }
    }

    func roomSubscriptionListDidChange(_ room: Room) {
        // Handled by didSubscribePublicationOf/didUnsubscribePublicationOf
    }

    func room(_ room: Room, didSubscribePublicationOf subscription: RoomSubscription) {
        // Subscription created elsewhere; ensure delegate is set
        Task { @MainActor in
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
            guard self.delegatesAttached else { return }
            subscription.delegate = nil
            self.roomSubscriptions.removeValue(forKey: subscription.id)
        }
    }

    // MARK: - LocalRoomMemberDelegate

    func localRoomMember(_ member: LocalRoomMember, didUnpublishStreamOf publication: RoomPublication) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            publication.delegate = nil
            self.roomPublications.removeValue(forKey: publication.id)
        }
    }

    func localRoomMember(_ member: LocalRoomMember, didUnsubscribePublicationOf subscription: RoomSubscription) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            subscription.delegate = nil
            self.roomSubscriptions.removeValue(forKey: subscription.id)
        }
    }

    // MARK: - RoomSubscriptionDelegate

    func subscription(_ subscription: RoomSubscription, connectionStateDidChange connectionState: ConnectionState) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            if connectionState == .disconnected {
                // Remote stream ended
                subscription.delegate = nil
                self.roomSubscriptions.removeValue(forKey: subscription.id)
                // If this was the video subscription, clear remote video
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
            guard self.delegatesAttached else { return }
            self.handleStreamAttachment(subscription: subscription)
        }
    }

    // MARK: - RoomPublicationDelegate

    func publicationStateDidChange(_ publication: RoomPublication) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            if publication.state == .canceled {
                publication.delegate = nil
                self.roomPublications.removeValue(forKey: publication.id)
            }
        }
    }

    func publication(_ publication: RoomPublication, connectionStateDidChange connectionState: ConnectionState) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            if connectionState == .disconnected {
                // Publication connection lost
                publication.delegate = nil
                self.roomPublications.removeValue(forKey: publication.id)
            }
        }
    }
}
