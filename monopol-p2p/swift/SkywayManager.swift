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

    // 開発用固定JWT（SkyWay Console で取得）
    // TODO: 本番では動的にトークンを取得する仕組みに置き換える
    private let devSkywayToken: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiI2ZDYzOWEzOC0xMzIxLTQ0NzQtYThmMS05NDZjM2E0ZTA0M2UiLCJpYXQiOjE3NjkzNTY3NjUsImV4cCI6MTc3MTk0ODc2NSwic2NvcGUiOnsiYXBwIjp7ImlkIjoiWU9VUl9BUFBfSUQiLCJhY3Rpb25zIjpbInJlYWQiXSwidHVybiI6dHJ1ZX19fQ.3FhfOCZp2CPCDIWXGgj7JoFl6G7YVqUpN-FNS3X-Hc0"

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

    class func sharedManager() -> SkywayManager {
        if (instance == nil) {
            instance = SkywayManager()
        }
        return instance!
    }

    // MARK: Session
    func sessionStart(delegate: SkywaySessionDelegate) {
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
        guard !contextSetupDone && !Context.isSetup else {
            contextSetupDone = true
            return
        }
        try await Context.setup(withToken: devSkywayToken, options: nil)
        contextSetupDone = true
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

    /// ルームに参加し、ローカルストリームめEpublish する
    /// - Parameters:
    ///   - roomName: 参加するルーム名（キャスト�E場合�E自刁E�E peerId、ユーザーの場合�Eキャスト�E peerId�E�E
    ///   - delegate: コールバック受信用チE��ゲーチE
    public func connectStart(roomName: String, delegate: SkywaySessionDelegate) {
        print("[SkyMgr] connectStart called, roomName=\(roomName), myPeerId=\(peerId)")

        // 多重開始ガーチE 既に接続中の場合�EスキチE�E
        if isConnectStarted && room != nil {
            print("[SkyMgr] connectStart skipped: already connected (isConnectStarted=true, room exists)")
            return
        }

        isConnectStarted = true
        sessionDelegate = delegate
        roomClosed = false
        subscribedPublicationIds.removeAll()  // リセチE��
        roomTask?.cancel()
        roomTask = Task { @MainActor in
            await leaveRoomIfNeeded()
            guard !Task.isCancelled else {
                print("[SkyMgr] connectStart Task cancelled before join")
                isConnectStarted = false
                return
            }
            await joinRoomIfNeeded(roomName: roomName, memberName: peerId)
        }
    }

    public func closeMedia(localView: UIView, remoteView: UIView) {
        localContainerView = localView
        remoteContainerView = remoteView
        isConnectStarted = false
        roomClosed = true
        roomTask?.cancel()
        roomTask = nil
        Task { @MainActor in
            await cleanupRoomResources()
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
            await leaveRoomIfNeeded()
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
        guard roomClosed == false else {
            print("[SkyMgr] joinRoomIfNeeded skipped: roomClosed=true")
            return
        }
        do {
            print("[SkyMgr] joinRoomIfNeeded start, roomName=\(roomName), memberName=\(memberName)")
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
    private func detachRoomCallbacks() async {
        print("[SkyMgr] detachRoomCallbacks start")

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
        roomSubscriptions.removeAll()  // 忁E��E 二重処琁E��止
        print("[SkyMgr] roomSubscriptions cleared")

        // (d) Unpublish all
        if let localMember = localMember {
            for (publicationId, _) in roomPublications {
                print("[SkyMgr] unpublish pubId=\(publicationId)")
                try? await localMember.unpublish(publicationId: publicationId)
            }
        }
        roomPublications.removeAll()  // 忁E��E 二重処琁E��止
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

        // (i) Detach local views first, then clear local streams (再接続時は prepareLocalStreamsIfNeeded で再生戁E
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
        print("[SkyMgr] detachRoomCallbacks complete, delegatesAttached=false, isConnectStarted=false, subscribedPublicationIds cleared")
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
    private func leaveRoomIfNeeded() async {
        await detachRoomCallbacks()
        roomClosed = true
    }

    @MainActor
    private func cleanupRoomResources() async {
        await detachRoomCallbacks()
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
            await self.detachRoomCallbacks()  // isConnectStarted = false はここで設定される
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
            guard !self.roomClosed else { return }  // 既に閉じてぁE��場合�EスキチE�E
            guard let localMember = self.localMember else { return }
            if self.memberIdentifier(member) != self.localMemberIdentifier(localMember) {
                print("[SkyMgr] memberDidLeave: remote member left, memberId=\(member.id)")
                // 1対1通話なので相手が退出したら終亁E��ぁE
                self.sessionDelegate?.connectDisconnect()
                // ルームから退出してリソースをクリーンアチE�E
                await self.leaveRoomIfNeeded()  // isConnectStarted = false はここで設定される
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
