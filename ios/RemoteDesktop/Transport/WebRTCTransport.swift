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
    enum MediaPolicy: Equatable {
        /// Ordinary remote-control sessions retain host-system-audio playback.
        case remoteSession
        /// The optional local Computer Use companion carries pixels and direct
        /// person input only. AI traffic remains on TLS and host audio is not
        /// negotiated or played.
        case computerUseVisualSidecar

        fileprivate var receivesHostAudio: Bool {
            self == .remoteSession && Config.enableHostAudio
        }
    }

    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onInputUnavailable: (@MainActor () -> Void)?
    var onVideoFrameUnavailable: (@MainActor () -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    #if DEBUG
    private struct DebugVideoSample: Sendable {
        let id: String
        let bytes: Double
        let frames: Double
        let width: Int
        let height: Int
        let rttMilliseconds: Double?
    }
    private var previousDebugVideoSample: (sample: DebugVideoSample, time: TimeInterval)?

    func debugVideoStatistics() async -> String {
        guard let peer = peerConnection, !isClosing else { return "Video unavailable" }
        let sample: DebugVideoSample? = await withCheckedContinuation { continuation in
            peer.statistics { report in
                guard let video = report.statistics.values.first(where: {
                    $0.type == "inbound-rtp" && (($0.values["kind"] as? String) == "video"
                        || ($0.values["mediaType"] as? String) == "video")
                }) else { continuation.resume(returning: nil); return }
                let selectedPairID = report.statistics.values.first(where: { $0.type == "transport" })?
                    .values["selectedCandidatePairId"] as? String
                let pair = selectedPairID.flatMap { report.statistics[$0] }
                let rtt = (pair?.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                continuation.resume(returning: DebugVideoSample(
                    id: video.id,
                    bytes: (video.values["bytesReceived"] as? NSNumber)?.doubleValue ?? 0,
                    frames: (video.values["framesDecoded"] as? NSNumber)?.doubleValue ?? 0,
                    width: (video.values["frameWidth"] as? NSNumber)?.intValue ?? 0,
                    height: (video.values["frameHeight"] as? NSNumber)?.intValue ?? 0,
                    rttMilliseconds: rtt.map { $0 * 1_000 }))
            }
        }
        guard peerConnection === peer, !isClosing, let sample else { return "Waiting for video stats…" }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousDebugVideoSample = (sample, now) }
        let rtt = sample.rttMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        guard let previous = previousDebugVideoSample, previous.sample.id == sample.id,
              now > previous.time else { return "\(sample.width)×\(sample.height) · RTT \(rtt)" }
        let seconds = now - previous.time
        let fps = max(0, sample.frames - previous.sample.frames) / seconds
        let mbps = max(0, sample.bytes - previous.sample.bytes) * 8 / seconds / 1_000_000
        return String(format: "%.0f fps · %.1f Mbps · %d×%d · RTT %@", fps, mbps,
                      sample.width, sample.height, rtt)
    }
    #endif

    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "webrtc")
    private let factory: RTCPeerConnectionFactory
    private let signalingFactory: (String, String?) -> any SignalingChannel
    private let iceConfigProvider: @Sendable () async -> ICEConfig
    private let mediaPolicy: MediaPolicy
    private let iceConnectTimeout: Duration = .seconds(25)
    private let connectionRecoveryTimeout: Duration = .seconds(12)
    private let mutedSystemVolumeThreshold: Float = 0.0625

    private var signaling: (any SignalingChannel)?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var renderer: (any RemoteVideoSurface)?
    private struct RendererRegistration {
        let track: RTCVideoTrack
        let subscription: RemoteVideoRenderSubscription
        let attachment: RemoteVideoSurfaceAttachment
        let lease: RemoteInputPresentationState.FrameLease
    }
    private var rendererRegistration: RendererRegistration?
    private var currentDisplay: DisplayInfo?
    private var hasReportedRendererFrame = false
    private var rendererUpdateDepth = 0
    private var isInstallingRenderer = false
    private var inputPresentation = RemoteInputPresentationState()
    private var pollTask: Task<Void, Never>?
    private var iceDeadlineTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var connectedOnce = false
    private var directInputState = DirectInputClientState()
    private var inputHandshakeDeadlineTask: Task<Void, Never>?
    private var answerApplied = false
    private var isClosing = false
    private var didReportDisconnect = false
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private var loggedPendingRemoteICE = false
    private var systemOutputVolume: Float = 1
    private var appliedRemoteAudioGain: Double?

    init(
        signalingFactory: ((String, String?) -> any SignalingChannel)? = nil,
        iceConfigProvider: (@Sendable () async -> ICEConfig)? = nil,
        mediaPolicy: MediaPolicy = .remoteSession
    ) {
        RTCInitializeSSL()
        self.mediaPolicy = mediaPolicy
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: true,
            encoderFactory: DesktopVideoEncoderFactory(),
            decoderFactory: DesktopVideoDecoderFactory(),
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
        if mediaPolicy.receivesHostAudio {
            let audioSession = RTCAudioSession.sharedInstance()
            systemOutputVolume = audioSession.outputVolume
            audioSession.add(self)
            configureAudioSession()
        }
    }

    deinit {
        if mediaPolicy.receivesHostAudio {
            RTCAudioSession.sharedInstance().remove(self)
        }
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        isClosing = false
        didReportDisconnect = false
        connectedOnce = false
        directInputState = DirectInputClientState()
        inputHandshakeDeadlineTask?.cancel()
        inputHandshakeDeadlineTask = nil
        answerApplied = false
        invalidateInputPresentation()
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
        if mediaPolicy.receivesHostAudio {
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
                self.finishDisconnect(reason: "Can't reach your computer — try putting both devices on the same Wi-Fi.", category: .peerConnection)
            }
        }
    }

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        guard let dataChannel, dataChannel.readyState == .open else {
            return
        }
        var stamp: DirectInputStamp?
        switch message {
        case .hello:
            sendHelloIfPossible()
            return
        case .pointer, .scroll, .key, .text:
            guard let permission = directInputState.authorizeNextInput() else {
                if directInputState.isClosed { finishDisconnect(reason: "Reconnect to start a new input session.", category: .input) }
                return
            }
            if case .scoped(let value) = permission { stamp = value }
        case .qos:
            guard directInputState.isReady else { return }
        case .bye: break
        }
        let data = message.encoded(seq: seq, ts: ts, inputStamp: stamp)
        if !dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false)), !isClosing {
            // Retrying text or a key transition could duplicate an effect.
            finishDisconnect(reason: "Remote input could not be sent. Reconnect to continue.", category: .input)
        }
    }

    func disconnect(reason: String) {
        close(reason: reason, notifyRemote: true)
    }

    private enum DisconnectCategory: String {
        case renderer, peerConnection, dataChannel, signaling, remoteBye, input
    }

    private func finishDisconnect(reason: String, category: DisconnectCategory) {
        guard !didReportDisconnect else { return }
        didReportDisconnect = true
        // Never log reason: it can contain remote or signaling-provided text.
        log.notice("transport ended category=\(category.rawValue, privacy: .public) sidecar=\(self.mediaPolicy == .computerUseVisualSidecar, privacy: .public) connectedOnce=\(self.connectedOnce, privacy: .public)")
        let callback = onDisconnect
        close(reason: reason, notifyRemote: false)
        callback?(reason)
    }

    private func close(reason: String, notifyRemote: Bool) {
        isClosing = true
        #if DEBUG
        previousDebugVideoSample = nil
        #endif
        if notifyRemote {
            send(.bye(reason: reason), seq: 0, ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000))
        }
        pollTask?.cancel()
        pollTask = nil
        iceDeadlineTask?.cancel()
        iceDeadlineTask = nil
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        inputHandshakeDeadlineTask?.cancel()
        inputHandshakeDeadlineTask = nil
        directInputState.close()
        connectedOnce = false
        invalidateInputPresentation()
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
        answerApplied = false
        pendingRemoteICECandidates.removeAll()
        loggedPendingRemoteICE = false
    }

    func attachVideoRenderer(_ renderer: any RemoteVideoSurface) {
        guard self.renderer !== renderer else { return }
        updateVideoRendering {
            self.renderer = renderer
            retireVideoRenderer(notify: true)
        }
    }

    func detachVideoRenderer(_ renderer: any RemoteVideoSurface) {
        guard self.renderer === renderer else { return }
        updateVideoRendering {
            self.renderer = nil
            retireVideoRenderer(notify: true)
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
                        finishDisconnect(reason: envelope.payload["reason"] ?? "Disconnected", category: .remoteBye)
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
                finishDisconnect(reason: "The WebRTC signaling loop ended unexpectedly: \(message)", category: .signaling)
                return
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func sendHelloIfPossible(timeout: Duration = .seconds(10)) {
        guard !isClosing, let hello = directInputState.helloToSend,
              let dataChannel, dataChannel.readyState == .open else {
            return
        }
        log.info("WebRTC control data channel opened; sending client hello")
        let data = ControlMessage.hello(proto: Config.protocolVersion).encoded(seq: 0,
            ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000), inputHello: hello)
        guard dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false)),
              directInputState.markHelloSent(hello) else {
            finishDisconnect(reason: "The input handshake could not be sent.", category: .input)
            return
        }
        inputHandshakeDeadlineTask?.cancel()
        inputHandshakeDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !self.isClosing, self.directInputState.hello == hello,
                  !self.directInputState.isReady else { return }
            self.finishDisconnect(reason: "The computer did not acknowledge the input session. Reconnect to try again.", category: .input)
        }
    }

    private func invalidateInputPresentation() {
        updateVideoRendering {
            let hadPresentation = inputPresentation.invalidate()
            currentDisplay = nil
            retireVideoRenderer(notify: false)
            if hadPresentation { onInputUnavailable?() }
        }
    }

    private func updateVideoRendering(_ update: () -> Void) {
        rendererUpdateDepth += 1
        update()
        rendererUpdateDepth -= 1
        if rendererUpdateDepth == 0 { installVideoRendererIfReady() }
    }

    private func retireVideoRenderer(notify: Bool) {
        let previous = rendererRegistration
        rendererRegistration = nil
        inputPresentation.retireProbe()
        let didReport = hasReportedRendererFrame
        hasReportedRendererFrame = false
        // Revoke admission before native removal, using the retained exact
        // registration track rather than whichever track is current now.
        previous?.subscription.retire()
        previous?.attachment.retire()
        if let previous { previous.track.remove(previous.subscription) }
        if notify && didReport { onVideoFrameUnavailable?() }
    }

    private func installVideoRendererIfReady() {
        guard rendererUpdateDepth == 0, !isInstallingRenderer else { return }
        isInstallingRenderer = true
        defer { isInstallingRenderer = false }
        // Surface creation/removal may reenter UIKit and change the desired
        // target or input scope. Drain that preparation before trying again.
        while rendererRegistration == nil, !isClosing,
              directInputState.isReady, let display = currentDisplay,
              inputPresentation.matches(display.inputSession),
              let renderer, let track = remoteVideoTrack,
              let lease = inputPresentation.armProbe() {
            let attachment = renderer.makeVideoAttachment(display: display)
            guard !isClosing, self.renderer === renderer, remoteVideoTrack === track,
                  currentDisplay == display, inputPresentation.acceptsFrame(lease),
                  directInputState.isReady else {
                attachment?.retire()
                continue
            }
            guard let attachment, let presentation = attachment.presentation, presentation.state != .retired else {
                attachment?.retire()
                guard !isClosing, self.renderer === renderer, remoteVideoTrack === track,
                      currentDisplay == display, inputPresentation.acceptsFrame(lease), directInputState.isReady else { continue }
                // A failed native surface cannot produce trustworthy readiness.
                // For Computer Use this ends only the optional video sidecar.
                finishDisconnect(reason: "The remote screen renderer could not be prepared. Reconnect to try again.", category: .renderer)
                return
            }
            // Forwarding a decoded frame is no longer the readiness receipt.
            let subscription = RemoteVideoRenderSubscription(renderer: attachment.renderer, onFirstForwardedFrame: {})
            rendererRegistration = .init(track: track, subscription: subscription, attachment: attachment, lease: lease)
            presentation.observe { [weak self, weak track, weak attachment] state in
                guard let self, let track, let attachment, !self.isClosing,
                      self.remoteVideoTrack === track, self.rendererRegistration?.attachment === attachment,
                      self.rendererRegistration?.lease == lease, self.inputPresentation.acceptsFrame(lease),
                      self.directInputState.isReady, attachment.presentation?.state == state else { return }
                switch state {
                case .presented, .rendered:
                    // Simulator readiness follows GPU rendering of a scheduled
                    // drawable; physical devices require the presentation callback.
                    guard !self.hasReportedRendererFrame else { return }
                    self.hasReportedRendererFrame = true
                    self.onFirstVideoFrame?()
                case .waiting, .retired:
                    let reported = self.hasReportedRendererFrame
                    self.hasReportedRendererFrame = false
                    if reported { self.onVideoFrameUnavailable?() }
                case .failed(_, let message):
                    self.finishDisconnect(reason: message, category: .renderer)
                }
            }
            guard rendererRegistration?.attachment === attachment else { continue }
            track.add(subscription)
        }
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
                self.finishDisconnect(reason: "Can’t reconnect to your computer. Keep the host app open and check that both devices are on the same Wi-Fi.", category: .peerConnection)
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
        guard !isClosing else { return }
        if let current = remoteVideoTrack, current.isEqual(track) { return }
        updateVideoRendering {
            remoteVideoTrack = track
            retireVideoRenderer(notify: true)
        }
        log.info("adopting remote video track id=\(track.trackId, privacy: .public) rendererAttached=\(self.renderer != nil, privacy: .public)")
    }

    private func adoptRemoteAudioTrack(_ track: RTCAudioTrack) {
        guard mediaPolicy.receivesHostAudio else {
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
            guard let self, self.peerConnection === peerConnection else { return }
            log.info("peer connection state → \(String(describing: stateChanged), privacy: .public)")
            guard !isClosing else { return }
            switch stateChanged {
            case .connected:
                guard directInputState.connectionChanged(connected: true) else { return }
                connectedOnce = true
                iceDeadlineTask?.cancel()
                iceDeadlineTask = nil
                cancelConnectionRecoveryTimeout()
                sendHelloIfPossible()
            case .failed:
                if !connectedOnce {
                    finishDisconnect(reason: "Can't reach your computer — try putting both devices on the same Wi-Fi.", category: .peerConnection)
                } else {
                    finishDisconnect(reason: "The connection to your computer was lost. Check your Wi-Fi and try again.", category: .peerConnection)
                }
            case .disconnected:
                invalidateInputPresentation()
                inputHandshakeDeadlineTask?.cancel()
                inputHandshakeDeadlineTask = nil
                guard directInputState.connectionChanged(connected: false) else {
                    finishDisconnect(reason: "The connection was interrupted. Reconnect to resume remote control.", category: .peerConnection)
                    return
                }
                guard connectedOnce else { return }
                scheduleConnectionRecoveryTimeout()
            case .closed:
                finishDisconnect(reason: "Your computer ended the connection. Open the host app and try again.", category: .peerConnection)
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
            guard let self, !self.isClosing, self.peerConnection === peerConnection,
                  dataChannel.label == "control",
                  self.dataChannel == nil || self.dataChannel === dataChannel else {
                dataChannel.close(); return
            }
            self.log.info("peer connection opened the control data channel")
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.sendHelloIfPossible()
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
            guard let self, !self.isClosing, self.dataChannel === dataChannel else { return }
            if dataChannel.readyState == .closing || dataChannel.readyState == .closed {
                self.finishDisconnect(reason: "The input channel closed.", category: .dataChannel)
                return
            }
            self.sendHelloIfPossible()
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing, self.dataChannel === dataChannel,
                  dataChannel.readyState == .open else { return }
            switch HostMessage.decode(buffer.data) {
            case .helloAck(let hello):
                switch directInputState.accept(version: hello.inputSessions, acknowledgement: hello.inputSession,
                                               inputInvalidation: hello.inputInvalidation) {
                case .ignored: return
                case .invalid:
                    finishDisconnect(reason: "The computer sent an invalid input-session acknowledgement.", category: .input)
                    return
                case .accepted: break
                }
                inputHandshakeDeadlineTask?.cancel()
                inputHandshakeDeadlineTask = nil
                if inputPresentation.matches(hello.inputSession) { return }
                invalidateInputPresentation()
                guard !isClosing, self.dataChannel === dataChannel, directInputState.isReady else { return }
                inputPresentation.begin(hello.inputSession)
                log.info("host acknowledged the WebRTC control channel")
                onHostHello?(hello)
            case .inputUnavailable(let scope):
                switch directInputState.invalidate(scope) {
                case .ignored: return
                case .invalid:
                    finishDisconnect(reason: "The computer sent an invalid input-unavailable event.", category: .input)
                    return
                case .accepted: break
                }
                inputHandshakeDeadlineTask?.cancel()
                inputHandshakeDeadlineTask = nil
                invalidateInputPresentation()
                sendHelloIfPossible(timeout: DirectInputWire.captureHandshakeTimeout)
            case .display(let display):
                guard directInputState.isReady, inputPresentation.matches(display.inputSession) else { return }
                updateVideoRendering {
                    if currentDisplay != display {
                        currentDisplay = display
                        retireVideoRenderer(notify: true)
                    }
                    guard !isClosing, self.dataChannel === dataChannel,
                          currentDisplay == display, inputPresentation.matches(display.inputSession) else { return }
                    onDisplay?(display)
                }
            case .bye(let reason):
                finishDisconnect(reason: reason, category: .remoteBye)
            case nil:
                break
            }
        }
    }
}
