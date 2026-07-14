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

enum RemoteAudioSessionPolicy {
    static let category = AVAudioSession.Category.playback
    static let categoryOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
    static let mode = AVAudioSession.Mode.default
}

@MainActor
final class WebRTCTransport: NSObject, VideoRenderingTransport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "webrtc")
    private let factory: RTCPeerConnectionFactory
    private let signalingFactory: (String, String?) -> any SignalingChannel
    private let iceConfigProvider: @Sendable () async -> ICEConfig
    private let iceConnectTimeout: Duration = .seconds(25)
    private let connectionRecoveryTimeout: Duration = .seconds(12)
    private let mutedSystemVolumeThreshold: Float = 0.0625

    private var signaling: (any SignalingChannel)?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var renderer: RTCVideoRenderer?
    private lazy var firstVideoFrameProbe = FirstVideoFrameProbe { [weak self] in
        Task { @MainActor [weak self] in
            self?.onFirstVideoFrame?()
        }
    }
    private var pollTask: Task<Void, Never>?
    private var iceDeadlineTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var connectedOnce = false
    private var sentHello = false
    private var answerApplied = false
    private var isClosing = false
    private var didReportDisconnect = false
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private var loggedPendingRemoteICE = false
    private var systemOutputVolume: Float = AVAudioSession.sharedInstance().outputVolume
    private var appliedRemoteAudioGain: Double?

    init(
        signalingFactory: ((String, String?) -> any SignalingChannel)? = nil,
        iceConfigProvider: (@Sendable () async -> ICEConfig)? = nil
    ) {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: true,
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioProcessingModule: nil)
        self.signalingFactory = signalingFactory ?? { code, expectedHostID in
            CloudKitSignalingClient(
                containerIdentifier: Config.cloudKitContainerIdentifier,
                code: code,
                role: .client,
                expectedTargetID: expectedHostID)
        }
        if let iceConfigProvider {
            self.iceConfigProvider = iceConfigProvider
        } else {
            let fetcher = ICEConfigFetcher(
                containerIdentifier: Config.cloudKitContainerIdentifier)
            self.iceConfigProvider = { await fetcher.get() }
        }
        super.init()
        let audioSession = RTCAudioSession.sharedInstance()
        systemOutputVolume = audioSession.outputVolume
        audioSession.add(self)
        configureAudioSession()
    }

    deinit {
        RTCAudioSession.sharedInstance().remove(self)
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        isClosing = false
        didReportDisconnect = false
        connectedOnce = false
        sentHello = false
        answerApplied = false
        firstVideoFrameProbe.reset()
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        pendingRemoteICECandidates.removeAll()
        loggedPendingRemoteICE = false

        let signaling = signalingFactory(pairingCode, expectedHostID)
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
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isClosing, !self.connectedOnce else { return }
                self.iceDeadlineTask = nil
                self.finishDisconnect(reason: "Can't reach your computer — try putting both devices on the same Wi-Fi.")
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
        close(reason: reason, notifyRemote: true)
    }

    private func finishDisconnect(reason: String) {
        guard !didReportDisconnect else { return }
        didReportDisconnect = true
        let callback = onDisconnect
        close(reason: reason, notifyRemote: false)
        callback?(reason)
    }

    private func close(reason: String, notifyRemote: Bool) {
        isClosing = true
        if notifyRemote {
            send(.bye(reason: reason), seq: 0, ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000))
        }
        pollTask?.cancel()
        pollTask = nil
        iceDeadlineTask?.cancel()
        iceDeadlineTask = nil
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        connectedOnce = false
        if let renderer {
            remoteVideoTrack?.remove(renderer)
        }
        remoteVideoTrack?.remove(firstVideoFrameProbe)
        remoteAudioTrack?.isEnabled = false
        remoteVideoTrack = nil
        remoteAudioTrack = nil
        appliedRemoteAudioGain = nil
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
        configuration.category = RemoteAudioSessionPolicy.category.rawValue
        configuration.categoryOptions = RemoteAudioSessionPolicy.categoryOptions
        configuration.mode = RemoteAudioSessionPolicy.mode.rawValue
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setConfiguration(configuration, active: true)
            systemOutputVolume = session.outputVolume
            applyRemoteAudioGainForSystemVolume()
            log.info("configured RTCAudioSession for playback-only remote audio")
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
        if audioDeviceModule.isRecording {
            let stopRecordingStatus = audioDeviceModule.stopRecording()
            log.error(
                "unexpected client audio recording stopped status=\(stopRecordingStatus, privacy: .public)")
        }
        applyRemoteAudioGainForSystemVolume()
        log.info(
            "client audio ADM initPlayout=\(initStatus, privacy: .public) startPlayout=\(startStatus, privacy: .public) isPlaying=\(audioDeviceModule.isPlaying, privacy: .public) isRecording=\(audioDeviceModule.isRecording, privacy: .public)")
    }

    private func applySystemOutputVolume(_ outputVolume: Float) {
        systemOutputVolume = outputVolume
        applyRemoteAudioGainForSystemVolume()
    }

    private func applyRemoteAudioGainForSystemVolume() {
        guard let remoteAudioTrack else { return }
        let gain = systemOutputVolume <= mutedSystemVolumeThreshold ? 0.0 : 1.0
        remoteAudioTrack.source.volume = gain
        guard appliedRemoteAudioGain != gain else { return }
        appliedRemoteAudioGain = gain
        log.info(
            "client remote audio gain=\(gain, privacy: .public) systemVolume=\(self.systemOutputVolume, privacy: .public)")
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
                        finishDisconnect(reason: envelope.payload["reason"] ?? "Disconnected")
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
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                finishDisconnect(reason: "The WebRTC signaling loop ended unexpectedly: \(message)")
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
        log.info("WebRTC control data channel opened; sending client hello")
        send(
            .hello(proto: Config.protocolVersion),
            seq: 0,
            ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000))
    }

    private func scheduleConnectionRecoveryTimeout() {
        guard connectionRecoveryTask == nil else { return }
        log.warning("peer connection is disconnected; waiting for ICE recovery")
        connectionRecoveryTask = Task { [weak self, connectionRecoveryTimeout] in
            try? await Task.sleep(for: connectionRecoveryTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isClosing, self.connectedOnce else { return }
                self.connectionRecoveryTask = nil
                self.finishDisconnect(reason: "The peer connection did not recover.")
            }
        }
    }

    private func cancelConnectionRecoveryTimeout() {
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
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
        if let current = remoteVideoTrack, current.isEqual(track) {
            return
        }
        if let current = remoteVideoTrack {
            current.remove(firstVideoFrameProbe)
            if let renderer {
                current.remove(renderer)
            }
        }
        remoteVideoTrack = track
        log.info("adopting remote video track id=\(track.trackId, privacy: .public) rendererAttached=\(self.renderer != nil, privacy: .public)")
        track.add(firstVideoFrameProbe)
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
        appliedRemoteAudioGain = nil
        applyRemoteAudioGainForSystemVolume()
        log.info("adopting remote audio track id=\(track.trackId, privacy: .public) enabled=\(track.isEnabled, privacy: .public)")
        ensureAudioPlayoutStarted()
    }
}

/// A renderer that observes decoded frames without retaining pixel data. The
/// callback crosses to `MainActor` in `WebRTCTransport`; the lock only makes
/// the exactly-once edge safe across WebRTC decoder queues.
private final class FirstVideoFrameProbe: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var didReport = false
    private let onFirstFrame: @Sendable () -> Void

    init(onFirstFrame: @escaping @Sendable () -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let shouldReport = !didReport
        didReport = true
        lock.unlock()
        if shouldReport {
            onFirstFrame()
        }
    }

    func reset() {
        lock.lock()
        didReport = false
        lock.unlock()
    }
}

extension WebRTCTransport: RTCAudioSessionDelegate {
    nonisolated func audioSession(_ audioSession: RTCAudioSession, didChangeOutputVolume outputVolume: Float) {
        Task { @MainActor [weak self] in
            self?.applySystemOutputVolume(outputVolume)
        }
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
            log.info("peer connection state → \(String(describing: stateChanged), privacy: .public)")
            guard !isClosing else { return }
            switch stateChanged {
            case .connected:
                connectedOnce = true
                iceDeadlineTask?.cancel()
                iceDeadlineTask = nil
                cancelConnectionRecoveryTimeout()
            case .failed:
                if !connectedOnce {
                    finishDisconnect(reason: "Can't reach your computer — try putting both devices on the same Wi-Fi.")
                } else {
                    finishDisconnect(reason: "The peer connection failed.")
                }
            case .disconnected:
                guard connectedOnce else { return }
                scheduleConnectionRecoveryTimeout()
            case .closed:
                finishDisconnect(reason: "The peer connection closed.")
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
            self?.log.info("peer connection opened the control data channel")
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
                log.info("host acknowledged the WebRTC control channel")
                onHostHello?(hello)
            case .display(let display):
                onDisplay?(display)
            case .bye(let reason):
                finishDisconnect(reason: reason)
            case nil:
                break
            }
        }
    }
}
