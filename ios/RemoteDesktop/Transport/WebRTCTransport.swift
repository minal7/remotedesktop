import AVFAudio
import Foundation
import LiveKitWebRTC
import UIKit
import os

extension ICEConfig {
    var iceServers: [RTCIceServer] {
        var servers = [RTCIceServer(urlStrings: stunURLs)]
        if !turnURLs.isEmpty, let username = turnUsername, let credential = turnCredential {
            servers.append(RTCIceServer(
                urlStrings: turnURLs,
                username: username,
                credential: credential))
        }
        return servers
    }
}

@MainActor
final class WebRTCTransport: NSObject, VideoRenderingTransport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "webrtc")
    private let factory: RTCPeerConnectionFactory
    private let signalingFactory: (String) -> any SignalingChannel
    private let iceConfigProvider: @Sendable () async -> ICEConfig
    private let iceConnectTimeout: Duration = .seconds(25)

    private var signaling: (any SignalingChannel)?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var renderer: RTCVideoRenderer?
    private var pollTask: Task<Void, Never>?
    private var iceDeadlineTask: Task<Void, Never>?
    private var connectedOnce = false
    private var sentHello = false
    private var answerApplied = false
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private var loggedPendingRemoteICE = false

    init(
        signalingFactory: ((String) -> any SignalingChannel)? = nil,
        iceConfigProvider: (@Sendable () async -> ICEConfig)? = nil
    ) {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: true,
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioProcessingModule: nil)
        self.signalingFactory = signalingFactory ?? { code in
            CloudKitSignalingClient(
                containerIdentifier: Config.cloudKitContainerIdentifier,
                code: code,
                role: .client)
        }
        if let iceConfigProvider {
            self.iceConfigProvider = iceConfigProvider
        } else {
            let fetcher = ICEConfigFetcher(
                containerIdentifier: Config.cloudKitContainerIdentifier)
            self.iceConfigProvider = { await fetcher.get() }
        }
        super.init()
        configureAudioSession()
    }

    func connect(pairingCode: String) async throws {
        connectedOnce = false
        sentHello = false
        answerApplied = false
        pendingRemoteICECandidates.removeAll()
        loggedPendingRemoteICE = false

        let signaling = signalingFactory(pairingCode)
        self.signaling = signaling
        try await signaling.claim()

        let iceConfig = await iceConfigProvider()
        let peerConnection = try makePeerConnection(iceConfig: iceConfig)
        self.peerConnection = peerConnection
        if Config.enableHostAudio {
            addReceiveOnlyTransceiver(of: .audio, on: peerConnection)
        }
        addReceiveOnlyTransceiver(of: .video, on: peerConnection)

        let dataChannelConfiguration = RTCDataChannelConfiguration()
        dataChannelConfiguration.isOrdered = true
        dataChannelConfiguration.isNegotiated = false
        let dataChannel = peerConnection.dataChannel(
            forLabel: "control",
            configuration: dataChannelConfiguration)
        dataChannel?.delegate = self
        self.dataChannel = dataChannel

        let offer = try await createOffer(on: peerConnection)
        try await setLocalDescription(offer, on: peerConnection)
        try await signaling.send(SignalingEnvelope(
            role: .client,
            kind: .offer,
            payload: [
                "client": UIDevice.current.name,
                "sdp": offer.sdp,
                "sdpType": "offer",
            ],
            ts: Date().timeIntervalSince1970))

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }

        iceDeadlineTask?.cancel()
        iceDeadlineTask = Task { [weak self, iceConnectTimeout] in
            try? await Task.sleep(for: iceConnectTimeout)
            await MainActor.run {
                guard let self, !self.connectedOnce else { return }
                self.onDisconnect?("Can't reach your computer — try putting both devices on the same Wi-Fi.")
            }
        }
    }

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        guard let dataChannel, dataChannel.readyState == .open else {
            return
        }
        let data = message.encoded(seq: seq, ts: ts)
        dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func disconnect(reason: String) {
        send(.bye(reason: reason), seq: 0, ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000))
        pollTask?.cancel()
        pollTask = nil
        iceDeadlineTask?.cancel()
        iceDeadlineTask = nil
        connectedOnce = false
        if let renderer {
            remoteVideoTrack?.remove(renderer)
        }
        remoteAudioTrack?.isEnabled = false
        remoteVideoTrack = nil
        remoteAudioTrack = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        if let signaling = signaling as? CloudKitSignalingClient {
            Task { await signaling.cleanup() }
        }
        signaling = nil
        sentHello = false
        answerApplied = false
        pendingRemoteICECandidates.removeAll()
        loggedPendingRemoteICE = false
    }

    func attachVideoRenderer(_ renderer: RTCVideoRenderer) {
        self.renderer = renderer
        remoteVideoTrack?.add(renderer)
    }

    func detachVideoRenderer(_ renderer: RTCVideoRenderer) {
        remoteVideoTrack?.remove(renderer)
        if self.renderer === (renderer as AnyObject) {
            self.renderer = nil
        }
    }

    private func makePeerConnection(iceConfig: ICEConfig) throws -> RTCPeerConnection {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = iceConfig.iceServers

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil)

        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self) else {
            throw TransportError.negotiationFailed("Couldn't create the peer connection.")
        }
        return peerConnection
    }

    private func addReceiveOnlyTransceiver(of mediaType: RTCRtpMediaType, on peerConnection: RTCPeerConnection) {
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        _ = peerConnection.addTransceiver(of: mediaType, init: transceiverInit)
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.ignoresPreferredAttributeConfigurationErrors = true

        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.categoryOptions = [
            .defaultToSpeaker,
            .allowBluetooth,
            .allowBluetoothA2DP,
        ]
        configuration.mode = AVAudioSession.Mode.default.rawValue
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setConfiguration(configuration, active: true)
            log.info("configured RTCAudioSession for playAndRecord")
        } catch {
            log.error("failed to configure RTCAudioSession: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureAudioPlayoutStarted() {
        // Re-activate the audio session in case iOS deactivated it.
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setActive(true)
        } catch {
            log.error("failed to re-activate RTCAudioSession: \(error.localizedDescription, privacy: .public)")
        }
        session.unlockForConfiguration()

        let audioDeviceModule = factory.audioDeviceModule
        let initStatus = audioDeviceModule.initPlayout()
        let startStatus = audioDeviceModule.startPlayout()
        log.info(
            "client audio ADM initPlayout=\(initStatus, privacy: .public) startPlayout=\(startStatus, privacy: .public) isPlaying=\(audioDeviceModule.isPlaying, privacy: .public)")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            guard let signaling else {
                return
            }

            do {
                let envelopes = try await signaling.poll()
                for envelope in envelopes {
                    switch envelope.kind {
                    case .answer:
                        guard !answerApplied,
                              let sdp = envelope.payload["sdp"] else {
                            continue
                        }
                        try await setRemoteDescription(
                            RTCSessionDescription(type: .answer, sdp: sdp),
                            on: peerConnection)
                        answerApplied = true
                        loggedPendingRemoteICE = false
                        try await flushPendingRemoteICECandidates()
                    case .ice:
                        guard let candidate = iceCandidate(from: envelope.payload) else {
                            continue
                        }
                        try await handleRemoteICECandidate(candidate)
                    case .bye:
                        await MainActor.run { [weak self] in
                            self?.onDisconnect?(envelope.payload["reason"] ?? "Disconnected")
                        }
                        return
                    case .offer:
                        continue
                    }
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                log.error("poll loop failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { [weak self] in
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self?.onDisconnect?("The WebRTC signaling loop ended unexpectedly: \(message)")
                }
                return
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func sendHelloIfPossible() {
        guard !sentHello, let dataChannel, dataChannel.readyState == .open else {
            return
        }
        sentHello = true
        send(
            .hello(proto: Config.protocolVersion),
            seq: 0,
            ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000))
    }

    private func iceCandidate(from payload: [String: String]) -> RTCIceCandidate? {
        guard let sdp = payload["candidate"] else {
            return nil
        }
        let sdpMid = payload["sdpMid"]
        let index = Int32(payload["sdpMLineIndex"] ?? "") ?? 0
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: sdpMid)
    }

    private func handleRemoteICECandidate(_ candidate: RTCIceCandidate) async throws {
        guard answerApplied else {
            pendingRemoteICECandidates.append(candidate)
            if !loggedPendingRemoteICE {
                loggedPendingRemoteICE = true
                log.info("buffering remote ICE candidate until answer is applied")
            }
            return
        }
        try await addRemoteICECandidate(candidate)
    }

    private func flushPendingRemoteICECandidates() async throws {
        guard answerApplied, !pendingRemoteICECandidates.isEmpty else {
            return
        }
        let pendingCandidates = pendingRemoteICECandidates
        pendingRemoteICECandidates.removeAll()
        for candidate in pendingCandidates {
            try await addRemoteICECandidate(candidate)
        }
    }

    private func addRemoteICECandidate(_ candidate: RTCIceCandidate) async throws {
        guard let peerConnection else {
            throw TransportError.disconnected("Peer connection was released.")
        }
        try await peerConnection.add(candidate)
    }

    private func createOffer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: TransportError.negotiationFailed("Offer creation returned no SDP."))
                }
            }
        }
    }

    private func setLocalDescription(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection?
    ) async throws {
        guard let peerConnection else {
            throw TransportError.disconnected("Peer connection was released.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemoteDescription(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection?
    ) async throws {
        guard let peerConnection else {
            throw TransportError.disconnected("Peer connection was released.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func adoptRemoteVideoTrack(_ track: RTCVideoTrack) {
        remoteVideoTrack = track
        log.info("adopting remote video track id=\(track.trackId, privacy: .public) rendererAttached=\(self.renderer != nil, privacy: .public)")
        if let renderer {
            track.add(renderer)
        }
    }

    private func adoptRemoteAudioTrack(_ track: RTCAudioTrack) {
        guard Config.enableHostAudio else {
            log.info("ignoring remote audio track because host audio is disabled")
            return
        }
        if let currentTrack = remoteAudioTrack, currentTrack.isEqual(track) {
            ensureAudioPlayoutStarted()
            return
        }
        remoteAudioTrack?.isEnabled = false
        remoteAudioTrack = track
        track.isEnabled = true
        log.info("adopting remote audio track id=\(track.trackId, privacy: .public) enabled=\(track.isEnabled, privacy: .public)")
        ensureAudioPlayoutStarted()
    }
}

extension WebRTCTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch stateChanged {
            case .connected:
                connectedOnce = true
                iceDeadlineTask?.cancel()
                iceDeadlineTask = nil
            case .failed:
                if !connectedOnce {
                    onDisconnect?("Can't reach your computer — try putting both devices on the same Wi-Fi.")
                } else {
                    onDisconnect?("The peer connection closed.")
                }
            case .disconnected, .closed:
                onDisconnect?("The peer connection closed.")
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self, let signaling = self.signaling else {
                return
            }
            do {
                try await signaling.send(SignalingEnvelope(
                    role: .client,
                    kind: .ice,
                    payload: [
                        "candidate": candidate.sdp,
                        "sdpMid": candidate.sdpMid ?? "",
                        "sdpMLineIndex": "\(candidate.sdpMLineIndex)",
                    ],
                    ts: Date().timeIntervalSince1970))
            } catch {
                self.log.error("failed to send local ICE candidate: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            self?.dataChannel = dataChannel
            dataChannel.delegate = self
            self?.sendHelloIfPossible()
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor [weak self] in
            guard let self, let track = stream.videoTracks.first else {
                return
            }
            self.adoptRemoteVideoTrack(track)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor [weak self] in
            guard let self, let track = receiver.track else {
                return
            }
            self.log.info("received track via receiver kind=\(track.kind, privacy: .public) id=\(track.trackId, privacy: .public)")
            if let videoTrack = track as? RTCVideoTrack {
                self.adoptRemoteVideoTrack(videoTrack)
            } else if let audioTrack = track as? RTCAudioTrack {
                self.adoptRemoteAudioTrack(audioTrack)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor [weak self] in
            guard let self, let track = transceiver.receiver.track else {
                return
            }
            self.log.info("transceiver started receiving kind=\(track.kind, privacy: .public) id=\(track.trackId, privacy: .public)")
            if let videoTrack = track as? RTCVideoTrack {
                self.adoptRemoteVideoTrack(videoTrack)
            } else if let audioTrack = track as? RTCAudioTrack {
                self.adoptRemoteAudioTrack(audioTrack)
            }
        }
    }
}

extension WebRTCTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            self?.sendHelloIfPossible()
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch HostMessage.decode(buffer.data) {
            case .helloAck(let hello):
                onHostHello?(hello)
            case .display(let display):
                onDisplay?(display)
            case .bye(let reason):
                onDisconnect?(reason)
            case nil:
                break
            }
        }
    }
}
