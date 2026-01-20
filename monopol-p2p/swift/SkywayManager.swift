//
//  SkywayManager.swift
//  swift_skyway
//
//  Created by onda on 2018/04/10.
//  Copyright © 2018年 worldtrip. All rights reserved.
//

import Foundation
import UIKit
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

    //API Key
    static let apiKey: String = "<あなたのID>"

    //Domain
    static let domain: String = "<あなたの指定したdomain>"

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
    private var cameraDevice: CameraVideoSource.Camera?
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
    private var connectStart: Bool = false
    private var sessionDelegate: SkywaySessionDelegate?
    //private var roomType: RoomType = .P2P

    class func sharedManager() -> SkywayManager {
        if (instance == nil) {
            instance = SkywayManager()
        }
        return instance!
    }

    // MARK: Session
    func sessionStart(delegate: SkywaySessionDelegate) {
        sessionDelegate = delegate
        Task { @MainActor in
            do {
                try await Util.setupSkyWayRoomContextIfNeeded()
                if peerId.isEmpty {
                    peerId = UUID().uuidString
                }
                delegate.sessionStart()
            } catch {
                delegate.connectError()
            }
        }
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

    //通話開始要求
    public func connectStart(connectPeerId: String, delegate: SkywaySessionDelegate) {
        connectStart = true
        sessionDelegate = delegate
        roomClosed = false
        roomTask?.cancel()
        roomTask = Task { @MainActor in
            await leaveRoomIfNeeded()
            await joinRoomIfNeeded(roomName: connectPeerId, memberName: peerId)
        }
    }

    public func closeMedia(localView: UIView, remoteView: UIView) {
        localContainerView = localView
        remoteContainerView = remoteView
        connectStart = false
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
        localVideoStream?.enabled = enabled
    }

    func setRemoteView(remoteView: UIView) {
        remoteContainerView = remoteView
        attachRemoteVideo()
    }

    @MainActor
    private func joinRoomIfNeeded(roomName: String, memberName: String) async {
        guard roomClosed == false else { return }
        do {
            try await Util.setupSkyWayRoomContextIfNeeded()
            let roomOptions = Room.InitOptions()
            roomOptions.name = roomName
            //roomOptions.type = .p2p
            let room = try await Room.findOrCreate(with: roomOptions)
            self.room = room
            let localMember = try await room.join(withName: memberName)
            self.localMember = localMember
            attachRoomCallbacks(room: room, localMember: localMember)
            try await publishLocalStreams(localMember: localMember)
            sessionDelegate?.connectSucces()
        } catch {
            sessionDelegate?.connectError()
        }
    }

    @MainActor
    private func attachRoomCallbacks(room: Room, localMember: LocalRoomMember) {
        // Idempotent: skip if already attached
        guard !delegatesAttached else { return }
        delegatesAttached = true

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
        for publication in room.publications {
            if publicationPublisherIdentifier(publication) != localMemberId {
                Task { @MainActor in
                    await self.subscribeToPublication(publication, localMember: localMember)
                }
            }
        }

        // Check if remote members already present
        for member in room.members {
            if memberIdentifier(member) != localMemberId {
                sessionDelegate?.remoteConnectSucces()
                break
            }
        }
    }

    @MainActor
    private func detachRoomCallbacks() async {
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
                try? await localMember.unsubscribe(subscriptionId: subscriptionId)
            }
        }
        roomSubscriptions.removeAll()

        // (d) Unpublish all
        if let localMember = localMember {
            for (publicationId, _) in roomPublications {
                try? await localMember.unpublish(publicationId: publicationId)
            }
        }
        roomPublications.removeAll()

        // (e) Nil localMember delegate
        localMember?.delegate = nil

        // (f) Leave room
        if let localMember = localMember {
            try? await localMember.leave()
        }

        // (g) Nil room delegate
        room?.delegate = nil

        // (h) Clear references
        self.localMember = nil
        self.room = nil
        delegatesAttached = false
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
        await prepareLocalStreamsIfNeeded()
        if let localAudioStream = localAudioStream {
            let pub = try await localMember.publish(localAudioStream, options: RoomPublicationOptions())
            pub.delegate = self
            roomPublications[pub.id] = pub
        }
        if let localVideoStream = localVideoStream {
            let pub = try await localMember.publish(localVideoStream, options: RoomPublicationOptions())
            pub.delegate = self
            roomPublications[pub.id] = pub
        }
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
        // Skip if already subscribed
        let existingIds = Set(roomSubscriptions.keys)
        for sub in localMember.subscriptions {
            if sub.publication?.id == publication.id && existingIds.contains(sub.id) {
                return
            }
        }

        do {
            let subscription = try await localMember.subscribe(publicationId: publication.id, options: nil)
            subscription.delegate = self
            roomSubscriptions[subscription.id] = subscription
            handleStreamAttachment(subscription: subscription)
        } catch {
            // Subscription may fail if publication was canceled
        }
    }

    @MainActor
    private func handleStreamAttachment(subscription: RoomSubscription) {
        guard let stream = subscription.stream else { return }
        if let videoStream = stream as? RemoteVideoStream {
            remoteVideoStream = videoStream
            attachRemoteVideo()
            sessionDelegate?.remoteConnectSucces()
        } else if let audioStream = stream as? RemoteAudioStream {
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
            localVideoStream.addRenderer(localVideoView)
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
            remoteVideoStream.addRenderer(remoteVideoView)
        }
    }

    private func detachLocalVideo() {
        if let localVideoView = localVideoView {
            localVideoStream?.removeRenderer(localVideoView)
        }
        localVideoView?.removeFromSuperview()
        localVideoView = nil
    }

    private func detachRemoteVideo() {
        if let remoteVideoView = remoteVideoView {
            remoteVideoStream?.removeRenderer(remoteVideoView)
        }
        remoteVideoView?.removeFromSuperview()
        remoteVideoView = nil
    }

    // MARK: - RoomDelegate

    func roomDidClose(_ room: Room) {
        Task { @MainActor in
            guard self.delegatesAttached else { return }
            await self.detachRoomCallbacks()
            self.detachRemoteVideo()
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
            guard let localMember = self.localMember else { return }
            if self.memberIdentifier(member) != self.localMemberIdentifier(localMember) {
                self.detachRemoteVideo()
                self.remoteVideoStream = nil
                self.remoteAudioStream = nil
                self.sessionDelegate?.connectDisconnect()
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
