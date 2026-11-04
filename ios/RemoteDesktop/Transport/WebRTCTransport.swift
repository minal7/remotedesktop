import AVFAudio
import Foundation
import LiveKitWebRTC
import UIKit
import os

extension ICEConfig {
    /// Configuration completeness only; this does not prove relay reachability.
    var hasCompleteTURNConfiguration: Bool {
        turnURLs.contains { $0.lowercased().hasPrefix("turn:") || $0.lowercased().hasPrefix("turns:") }
            && !(turnUsername ?? "").isEmpty && !(turnCredential ?? "").isEmpty
    }

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

/// Counts only candidate kinds; the candidate text and network addresses are never retained.
struct ICECandidateDiagnosticCounts: Equatable {
    private(set) var host = 0, serverReflexive = 0, peerReflexive = 0, relay = 0, unknown = 0

    mutating func record(_ candidate: String) {
        let fields = candidate.prefix(2_048).split(whereSeparator: \.isWhitespace)
        let kind: Substring? = fields.firstIndex(of: "typ").flatMap { index in
            let next = fields.index(after: index)
            return next < fields.endIndex ? fields[next] : nil
        }
        switch kind {
        case "host": host = min(host + 1, 10_000)
        case "srflx": serverReflexive = min(serverReflexive + 1, 10_000)
        case "prflx": peerReflexive = min(peerReflexive + 1, 10_000)
        case "relay": relay = min(relay + 1, 10_000)
        default: unknown = min(unknown + 1, 10_000)
        }
    }

    var summary: String { "host=\(host) srflx=\(serverReflexive) prflx=\(peerReflexive) relay=\(relay) unknown=\(unknown)" }
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
    nonisolated private let labInstrumentation: Bool
    private struct DebugVideoSample: Sendable {
        let id: String
        let bytes: Double
        let frames: Double
        let width: Int
        let height: Int
        let rttMilliseconds: Double?
    }
    private var latencyTask: Task<Void, Never>?
    private var latencyCollector: LatencyStatsCollector?
    private var peerLatencyCollector: LatencyStatsCollector?
    private var latencyPings: [Int: Double] = [:]
    private var latencySamples: [(rtt: Double, offset: Double)] = []
    private var latencyPingID = 0
    private var previousDebugVideoSample: (sample: DebugVideoSample, time: TimeInterval)?
    private enum F1State {
        case idle, requested(String), restarting(String), active(String), unavailable
    }
    private var f1State: F1State = .idle
    private var f1Configuration = LatencyLabConfiguration.current
    private var f1WaitingToSendOffer = false
    private var f1PendingLocalICE: [RTCIceCandidate] = []
    private var f1RetiredPeer: RTCPeerConnection?
    private var f1RetiredChannel: RTCDataChannel?
    private var f1RetiredFactory: RTCPeerConnectionFactory?
    private var f1ICEConfig: ICEConfig?
    private var f1RequestTimeout: Task<Void, Never>?
    private var f1RestartTask: Task<Void, Never>?
    private var f1FactoryConfigured = false
    private var f1ApplyToReplacement = false
    private var f2ApplyToReplacement = false
    private var f3ApplyToReplacement = false
    private var labApplied = LatencyLabSelection(f1MaximumDelayMs: nil, f2: false, f3: false, f4: false)
    private var labPending: LatencyLabSelection?
    private var labLastHello: HostHello?
    private var labActiveNonce: String?
    private var labObserver: NSObjectProtocol?
    private var labPairRun: LatencyLabPairRun?
    private var labPairOriginalConfiguration: LatencyLabConfiguration?
    private static let labPairStatusQueue = DispatchQueue(label: "latency.pair.status")

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
        var text = String(format: "%.0f fps · %.1f Mbps · %d×%d · RTT %@", fps, mbps,
                          sample.width, sample.height, rtt)
        if labInstrumentation && LatencyStatsCollector.enabled {
            let stats = RemoteVideoLatencyProbe.shared.collector.snapshot()
            for (key, label) in [("jitterBufferMs", "Jitter"), ("decodeMs", "Decode"), ("processingMs", "Processing")] {
                if let value = stats[key] { text += String(format: "\n%@: %.1f ms", label, value) }
            }
            if let (p50, p95) = RemoteVideoLatencyProbe.shared.renderPercentiles() {
                text += String(format: "\nRender p50/p95: %.1f / %.1f ms", p50, p95)
            }
            if ProcessInfo.processInfo.arguments.contains("LatencyQuality") {
                let requested = LatencyLabConfiguration.current
                let onlyRenderer = !requested.f1Playout && !requested.f2Encoder && !requested.f3Sender
                let expected = LatencyLabSelection(f1MaximumDelayMs: nil, f2: false, f3: false, f4: requested.f4Renderer)
                let ready = onlyRenderer && labPending == nil && labApplied == expected
                    && answerApplied && directInputState.isReady && hasReportedRendererFrame
                text += "\nQuality F4 \(labApplied.f4 ? "on" : "off"): \(ready ? "ready" : "waiting")"
            }
        }
        return text
    }
    #endif

    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "webrtc")
    private var factory: RTCPeerConnectionFactory
    private let signalingFactory: (String, String?) -> any SignalingChannel
    private let iceConfigProvider: @Sendable () async -> ICEConfig
    private let mediaPolicy: MediaPolicy
    private let iceConnectTimeout: Duration = .seconds(25)
    private let connectionRecoveryTimeout: Duration = .seconds(12)
    private let mutedSystemVolumeThreshold: Float = 0.0625
    private var localCandidateCounts = ICECandidateDiagnosticCounts()
    private var remoteCandidateCounts = ICECandidateDiagnosticCounts()
    private var diagnosticStateEvents = 0
    private var diagnosticConnectionID = UUID().uuidString

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
        #if DEBUG
        self.labInstrumentation = mediaPolicy == .remoteSession
        #endif
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
        #if DEBUG
        labObserver = NotificationCenter.default.addObserver(
            forName: .latencyLabConfigurationDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileLabConfiguration() }
        }
        #endif
        if mediaPolicy.receivesHostAudio {
            let audioSession = RTCAudioSession.sharedInstance()
            systemOutputVolume = audioSession.outputVolume
            audioSession.add(self)
            configureAudioSession()
        }
    }

    deinit {
        #if DEBUG
        if let labObserver { NotificationCenter.default.removeObserver(labObserver) }
        #endif
        if mediaPolicy.receivesHostAudio {
            RTCAudioSession.sharedInstance().remove(self)
        }
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        localCandidateCounts = .init()
        remoteCandidateCounts = .init()
        diagnosticStateEvents = 0
        diagnosticConnectionID = UUID().uuidString
        #if DEBUG
        if mediaPolicy == .remoteSession {
            let original = LatencyLabConfiguration.current
            labPairRun = LatencyLabPairRun.make(arguments: ProcessInfo.processInfo.arguments,
                                               maximumDelayMs: original.f1MaximumDelayMs)
            labPairOriginalConfiguration = labPairRun == nil ? nil : original
            if let configuration = labPairRun?.configuration { LatencyLabConfiguration.setRuntime(configuration) }
        }
        if f1FactoryConfigured {
            // A reused transport must not carry a previous host's trial into
            // the next host's initial, capability-unknown connection.
            factory = RTCPeerConnectionFactory(
                audioDeviceModuleType: .platformDefault, bypassVoiceProcessing: true,
                encoderFactory: DesktopVideoEncoderFactory(), decoderFactory: DesktopVideoDecoderFactory(),
                audioProcessingModule: nil)
            f1FactoryConfigured = false
        }
        if labInstrumentation && LatencyStatsCollector.enabled {
            latencyTask?.cancel(); latencyTask = nil
            latencyPings.removeAll(); latencySamples.removeAll()
            peerLatencyCollector = nil
            RemoteVideoLatencyProbe.shared.reset()
            latencyCollector = RemoteVideoLatencyProbe.shared.collector
        }
        f1Configuration = LatencyLabConfiguration.current
        f1State = .idle
        f1WaitingToSendOffer = false
        f1PendingLocalICE.removeAll()
        f1RetiredPeer = nil; f1RetiredChannel = nil; f1RetiredFactory = nil
        f1ICEConfig = nil
        f1RequestTimeout?.cancel(); f1RequestTimeout = nil
        f1RestartTask?.cancel(); f1RestartTask = nil
        f1ApplyToReplacement = false; f2ApplyToReplacement = false
        f3ApplyToReplacement = false; labPending = nil; labLastHello = nil; labActiveNonce = nil
        labApplied = LatencyLabSelection(f1MaximumDelayMs: nil, f2: false, f3: false, f4: f1Configuration.f4Renderer)
        latencyCollector?.trace(["type": "f1_playout", "time": ProcessInfo.processInfo.systemUptime,
                                 "requested": f1Configuration.f1Playout,
                                 "maximumDelayMs": f1Configuration.f1MaximumDelayMs,
                                 "configured": false, "effective": "unverified", "stage": "initial"])
        #endif
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
        log.info("ICE id=\(self.diagnosticConnectionID, privacy: .public) stage=signaling_claimed")

        let iceConfig = await iceConfigProvider()
        log.info("ICE id=\(self.diagnosticConnectionID, privacy: .public) stage=configuration turn_config_complete=\(iceConfig.hasCompleteTURNConfiguration, privacy: .public)")
        #if DEBUG
        f1ICEConfig = iceConfig
        #endif
        let peerConnection = try makePeerConnection(iceConfig: iceConfig)
        self.peerConnection = peerConnection
        #if DEBUG
        peerLatencyCollector = latencyCollector
        #endif
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
        log.info("ICE id=\(self.diagnosticConnectionID, privacy: .public) stage=offer_sent")

        #if DEBUG
        if labInstrumentation && LatencyStatsCollector.enabled {
            latencyTask?.cancel()
            if let collector = latencyCollector {
                latencyTask = Task { [weak self, collector] in await self?.latencyLoop(collector: collector) }
            }
        }
        #endif
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
                self.finishDisconnect(reason: "Can’t connect to your computer. Check that both devices are online and the host app is open, then try again.", category: .peerConnection)
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
        logCandidateCounts(stage: "transport_ended")
        let callback = onDisconnect
        close(reason: reason, notifyRemote: false)
        callback?(reason)
    }

    private func logCandidateCounts(stage: String) {
        log.info("ICE id=\(self.diagnosticConnectionID, privacy: .public) stage=\(stage, privacy: .public) local={\(self.localCandidateCounts.summary, privacy: .public)} remote={\(self.remoteCandidateCounts.summary, privacy: .public)}")
    }

    @discardableResult
    private func logICEState(kind: String, value: String) -> Bool {
        guard diagnosticStateEvents < 32 else { return false }
        diagnosticStateEvents += 1
        log.info("ICE id=\(self.diagnosticConnectionID, privacy: .public) \(kind, privacy: .public)=\(value, privacy: .public)")
        return true
    }

    private func close(reason: String, notifyRemote: Bool) {
        #if DEBUG
        (peerLatencyCollector ?? latencyCollector)?.trace(["type": "transport_close", "time": ProcessInfo.processInfo.systemUptime,
                                 "origin": notifyRemote ? "requested_disconnect" : "transport_disconnect",
                                 "notifyRemote": notifyRemote])
        #endif
        isClosing = true
        #if DEBUG
        if let original = labPairOriginalConfiguration {
            if labPairRun?.finished == false {
                latencyCollector?.trace(["type": "lab_pair_cancelled", "time": ProcessInfo.processInfo.systemUptime])
                Self.writeLabPairStatus(["stage": "aborted", "reason": "transport_closed"], collector: latencyCollector)
            }
            labPairRun = nil; labPairOriginalConfiguration = nil
            LatencyLabConfiguration.setRuntime(original)
        }
        previousDebugVideoSample = nil
        latencyTask?.cancel(); latencyTask = nil
        latencyPings.removeAll(); latencySamples.removeAll()
        f1RetiredChannel?.close(); f1RetiredPeer?.close()
        f1RetiredChannel = nil; f1RetiredPeer = nil; f1RetiredFactory = nil
        f1WaitingToSendOffer = false; f1PendingLocalICE.removeAll()
        f1RequestTimeout?.cancel(); f1RequestTimeout = nil
        f1RestartTask?.cancel(); f1RestartTask = nil
        labLastHello = nil; labPending = nil; labActiveNonce = nil
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

    #if DEBUG
    private static func writeLabPairStatus(_ fields: [String: Any], collector: LatencyStatsCollector?) {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        var status = fields
        status["processIdentifier"] = ProcessInfo.processInfo.processIdentifier
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "LatencyLabPairToken"), arguments.indices.contains(index + 1) {
            status["launchToken"] = arguments[index + 1]
        }
        let record = status
        let url = directory.appendingPathComponent("RemoteDesktopHost/Latency/pair-status.json")
        labPairStatusQueue.async {
            if let stage = record["stage"] as? String, stage == "complete" || stage == "aborted" {
                collector?.flush()
            }
            guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func advanceLabPairRun(collector: LatencyStatsCollector) {
        guard var run = labPairRun, !run.finished else { return }
        let requested = run.configuration
        let expected = LatencyLabSelection(f1MaximumDelayMs: requested.f1Playout ? requested.f1MaximumDelayMs : nil,
                                          f2: requested.f2Encoder, f3: requested.f3Sender, f4: requested.f4Renderer)
        let supported = labLastHello.map { LatencyF1Policy.selection(configuration: requested, hello: $0) }
        let ready = answerApplied && directInputState.isReady && dataChannel?.readyState == .open
            && labPending == nil && labApplied == expected && supported == expected
            && hasReportedRendererFrame && latencySamples.count == 50
            && RemoteVideoLatencyProbe.shared.hasRecentMarker()
        let actions = run.tick(now: ProcessInfo.processInfo.systemUptime, ready: ready,
                               currentConfiguration: LatencyLabConfiguration.current)
        labPairRun = run
        // A handoff can change the nonce only after this synchronous batch.
        // Bind end/begin events to the peer that actually served that window.
        let nonce: Any = labActiveNonce as Any? ?? NSNull()
        for action in actions {
            switch action {
            case .apply(let configuration): LatencyLabConfiguration.setRuntime(configuration)
            case .trace(var fields):
                fields["peerNonce"] = nonce
                collector.trace(fields)
                Self.writeLabPairStatus(fields, collector: collector)
            }
        }
        if run.finished, let original = labPairOriginalConfiguration {
            labPairOriginalConfiguration = nil
            LatencyLabConfiguration.setRuntime(original)
        }
    }

    private func reconcileLabConfiguration() {
        latencyCollector?.trace(["type": "lab_configuration", "time": ProcessInfo.processInfo.systemUptime,
                                 "side": "client", "source": "runtime", "settings": LatencyLabConfiguration.current.traceValues])
        guard !isClosing, answerApplied, mediaPolicy == .remoteSession, let hello = labLastHello,
              let channel = dataChannel, channel.readyState == .open, directInputState.isReady else { return }
        switch f1State {
        case .requested, .restarting: return // Reconcile again after the replacement hello.
        case .idle, .active, .unavailable: break
        }
        startF1IfSupported(hello, channel: channel)
    }

    private func startF1IfSupported(_ hello: HostHello, channel: RTCDataChannel) {
        guard answerApplied, mediaPolicy == .remoteSession else { return }
        switch f1State {
        case .requested, .restarting: return
        case .idle, .active, .unavailable: break
        }
        f1Configuration = LatencyLabConfiguration.current
        let desired = LatencyF1Policy.selection(configuration: f1Configuration, hello: hello)
        latencyCollector?.trace(["type": "lab_configuration", "time": ProcessInfo.processInfo.systemUptime,
            "side": "client", "source": "negotiation", "settings": f1Configuration.traceValues,
            "hostF1Capability": hello.latencyF1Playout, "hostF2Capability": hello.latencyF2Encoder,
            "hostF3Capability": hello.latencyF3Sender, "f1Configured": labApplied.f1MaximumDelayMs != nil,
            "f2RequestedToHost": labApplied.f2, "f3RequestedToHost": labApplied.f3,
            "f4Selected": labApplied.f4, "effective": "unverified"])
        guard desired != labApplied else { return }
        guard hello.latencyF1Playout == 1 else {
            f1State = .unavailable
            latencyCollector?.trace(["type": "f1_playout", "time": ProcessInfo.processInfo.systemUptime,
                                     "requested": f1Configuration.f1Playout, "configured": false, "effective": "unverified",
                                     "f4Requested": desired.f4,
                                     "stage": desired.f4 != labApplied.f4 ? "f4_requires_capable_host" : "host_unsupported"])
            return
        }
        f1ApplyToReplacement = desired.f1MaximumDelayMs != nil
        f2ApplyToReplacement = desired.f2; f3ApplyToReplacement = desired.f3
        labPending = desired
        let nonce = UUID().uuidString
        guard let request = try? JSONSerialization.data(withJSONObject: ["type": "latencyF1RestartRequest", "nonce": nonce]),
              channel.sendData(RTCDataBuffer(data: request, isBinary: false)) else {
            f1State = .unavailable
            return
        }
        f1State = .requested(nonce)
        f1RequestTimeout?.cancel()
        f1RequestTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, case .requested(let current) = self.f1State, current == nonce else { return }
            self.f1State = .unavailable; self.f1RequestTimeout = nil
            self.latencyCollector?.trace(["type": "f1_playout", "time": ProcessInfo.processInfo.systemUptime,
                "requested": self.f1Configuration.f1Playout, "configured": false, "effective": "unverified", "stage": "handoff_timeout"])
            if LatencyLabConfiguration.current != self.f1Configuration { self.reconcileLabConfiguration() }
        }
        latencyCollector?.trace(["type": "f1_playout", "time": ProcessInfo.processInfo.systemUptime,
                                 "requested": f1Configuration.f1Playout, "configured": false, "effective": "unverified",
                                 "maximumDelayMs": f1Configuration.f1MaximumDelayMs,
                                 "f2Requested": desired.f2, "stage": "host_confirmed"])
    }

    private func consumeF1Ready(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "latencyF1RestartReady" else { return false }
        guard let nonce = object["nonce"] as? String, case .requested(let expected) = f1State,
              nonce == expected, directInputState.isReady else { return true }
        f1RequestTimeout?.cancel(); f1RequestTimeout = nil
        f1State = .restarting(nonce)
        f1RestartTask = Task { @MainActor [weak self] in await self?.restartForF1(nonce) }
        return true
    }

    private func restartForF1(_ nonce: String) async {
        guard !isClosing, case .restarting(let expected) = f1State, expected == nonce,
              let signaling, let iceConfig = f1ICEConfig,
              directInputState.isReady, let oldPeer = peerConnection,
              let oldChannel = dataChannel, oldChannel.readyState == .open else {
            if case .restarting(let current) = f1State, current == nonce { f1State = .unavailable }
            return
        }
        let oldFactory = factory
        // The bundled factory copies this process-global string into its own
        // environment during initialization. Do not suspend before restoring it.
        let replacementFactory: RTCPeerConnectionFactory
        if LatencyF1Policy.needsNewFactory(currentMaximumMs: labApplied.f1MaximumDelayMs,
                                           desiredMaximumMs: labPending?.f1MaximumDelayMs) {
            if f1ApplyToReplacement {
                RTCPeerConnectionFactory.configureFieldTrials("WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:\(f1Configuration.f1MaximumDelayMs)/")
            } else {
                RTCPeerConnectionFactory.configureFieldTrials(nil)
            }
            replacementFactory = RTCPeerConnectionFactory(
                audioDeviceModuleType: .platformDefault, bypassVoiceProcessing: true,
                encoderFactory: DesktopVideoEncoderFactory(), decoderFactory: DesktopVideoDecoderFactory(),
                audioProcessingModule: nil)
            RTCPeerConnectionFactory.configureFieldTrials(nil)
        } else {
            replacementFactory = oldFactory
        }
        factory = replacementFactory
        f1FactoryConfigured = f1ApplyToReplacement
        do {
            guard !isClosing, case .restarting(let current) = f1State, current == nonce else { return }
            let replacement = try makePeerConnection(iceConfig: iceConfig)
            f1RetiredPeer = oldPeer; f1RetiredChannel = oldChannel; f1RetiredFactory = oldFactory
            invalidateInputPresentation()
            guard !isClosing, case .restarting(let current) = f1State, current == nonce else {
                replacement.close()
                return
            }
            remoteAudioTrack?.isEnabled = false
            remoteAudioTrack = nil; remoteVideoTrack = nil; appliedRemoteAudioGain = nil
            inputHandshakeDeadlineTask?.cancel(); inputHandshakeDeadlineTask = nil
            directInputState = DirectInputClientState(); connectedOnce = false
            answerApplied = false; pendingRemoteICECandidates.removeAll()
            peerConnection = replacement
            labActiveNonce = nonce
            iceDeadlineTask?.cancel()
            iceDeadlineTask = Task { [weak self, iceConnectTimeout] in
                try? await Task.sleep(for: iceConnectTimeout)
                guard !Task.isCancelled, let self, !self.isClosing, self.peerConnection === replacement,
                      !self.connectedOnce else { return }
                self.finishDisconnect(reason: "The latency experiment could not reconnect.", category: .peerConnection)
            }
            if mediaPolicy.receivesHostAudio { addReceiveOnlyTransceiver(of: .audio, on: replacement) }
            addReceiveOnlyTransceiver(of: .video, on: replacement)
            let config = RTCDataChannelConfiguration(); config.isOrdered = true; config.isNegotiated = false
            guard let channel = replacement.dataChannel(forLabel: "control", configuration: config) else {
                throw TransportError.negotiationFailed("The latency experiment could not create its control channel.")
            }
            channel.delegate = self; dataChannel = channel
            f1WaitingToSendOffer = true; f1PendingLocalICE.removeAll()
            let offer = try await createOffer(on: replacement)
            guard !isClosing, peerConnection === replacement else { return }
            try await setLocalDescription(offer, on: replacement)
            guard !isClosing, peerConnection === replacement else { return }
            var payload = ["client": UIDevice.current.name, "sdp": offer.sdp, "sdpType": "offer",
                           "latencyF1Restart": nonce]
            if f2ApplyToReplacement { payload["latencyF2Encoder"] = "1" }
            if f3ApplyToReplacement { payload["latencyF3Sender"] = "1" }
            try await signaling.send(SignalingEnvelope(role: .client, kind: .offer,
                payload: payload, ts: Date().timeIntervalSince1970))
            guard !isClosing, peerConnection === replacement else { return }
            f1WaitingToSendOffer = false
            let pending = f1PendingLocalICE; f1PendingLocalICE.removeAll()
            for candidate in pending {
                guard !Task.isCancelled, !isClosing, peerConnection === replacement else { return }
                await sendF1ICE(candidate, nonce: nonce, signaling: signaling)
            }
            latencyCollector?.trace(["type": "f1_playout", "time": ProcessInfo.processInfo.systemUptime,
                                     "requested": f1Configuration.f1Playout, "configured": f1ApplyToReplacement, "effective": "unverified",
                                     "maximumDelayMs": f1Configuration.f1MaximumDelayMs, "stage": "replacement_offer"])
        } catch {
            guard !Task.isCancelled, !isClosing, case .restarting(let current) = f1State,
                  current == nonce else { return }
            finishDisconnect(reason: "The latency experiment could not reconnect.", category: .peerConnection)
        }
    }

    private func sendF1ICE(_ candidate: RTCIceCandidate, nonce: String, signaling: any SignalingChannel) async {
        do {
            try await signaling.send(SignalingEnvelope(role: .client, kind: .ice,
                payload: ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid ?? "",
                          "sdpMLineIndex": "\(candidate.sdpMLineIndex)", "latencyF1Restart": nonce],
                ts: Date().timeIntervalSince1970))
        } catch { log.error("failed to send F1 ICE candidate") }
    }

    private func latencyLoop(collector: LatencyStatsCollector) async {
        let batteryLease = LatencyBatteryMonitoringLease.shared.acquire()
        var cycle = 0
        let center = NotificationCenter.default
        let lifecycleNames: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willTerminateNotification, "willTerminate")
        ]
        // Asynchronous events may not survive suspension or termination; absence is inconclusive.
        let lifecycleObservers = lifecycleNames.map { name, event in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                collector.trace(["type": "app_lifecycle", "event": event,
                                 "time": ProcessInfo.processInfo.systemUptime])
            }
        }
        collector.trace(["type": "latency_loop_start", "time": ProcessInfo.processInfo.systemUptime])
        defer {
            for observer in lifecycleObservers { center.removeObserver(observer) }
            collector.trace(["type": "latency_loop_exit", "time": ProcessInfo.processInfo.systemUptime,
                             "cancelled": Task.isCancelled, "isClosing": isClosing, "cycle": cycle])
            LatencyBatteryMonitoringLease.shared.release(batteryLease)
        }
        while !Task.isCancelled, !isClosing {
            advanceLabPairRun(collector: collector)
            if (!LatencyStatsCollector.resourcesOnly || cycle % 10 == 0), let peer = peerConnection {
                peer.statistics { report in
                    let reports = report.statistics.values.map { LatencyStatsReport(id: $0.id, type: $0.type, values: $0.values) }
                    collector.ingest(reports, at: ProcessInfo.processInfo.systemUptime)
                }
            }
            let resource: [String: Any] = ["type": "resource", "time": ProcessInfo.processInfo.systemUptime,
                                           "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                                           "batteryState": UIDevice.current.batteryState.rawValue,
                                           "batteryLevel": Double(UIDevice.current.batteryLevel),
                                           "appState": UIApplication.shared.applicationState.rawValue]
            collector.trace(resource)
            if cycle % 10 == 0, directInputState.isReady, dataChannel?.readyState == .open {
                latencyPings.removeAll(); latencySamples.removeAll()
                for _ in 0..<50 {
                    guard !Task.isCancelled, let channel = dataChannel, channel.readyState == .open else { break }
                    latencyPingID += 1
                    let id = latencyPingID, t0 = ProcessInfo.processInfo.systemUptime
                    latencyPings[id] = t0
                    if let data = try? JSONSerialization.data(withJSONObject: ["type": "latencyPing", "id": id, "t0": t0]) {
                        _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
                    }
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            } else {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            cycle += 1
        }
    }

    private func receiveLatencyPong(_ data: Data, receivedAt t3: Double) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "latencyPong" else { return false }
        guard LatencyStatsCollector.enabled, let id = object["id"] as? Int,
              let t0 = latencyPings.removeValue(forKey: id),
              let echoed = (object["t0"] as? NSNumber)?.doubleValue, echoed == t0,
              let t1 = (object["t1"] as? NSNumber)?.doubleValue,
              let t2 = (object["t2"] as? NSNumber)?.doubleValue,
              t2 >= t1, t3 >= t0 else { return true }
        let rtt = (t3 - t0) - (t2 - t1)
        guard rtt >= 0 else { return true }
        latencySamples.append((rtt, ((t1 - t0) + (t2 - t3)) / 2))
        if latencySamples.count == 50 { publishLatencyClock() }
        return true
    }

    private func publishLatencyClock() {
        guard let estimate = LatencyClockEstimate.calculate(latencySamples),
              let collector = peerLatencyCollector else { return }
        collector.trace(["type": "clock", "time": ProcessInfo.processInfo.systemUptime, "offset": estimate.offset, "uncertainty": estimate.uncertainty, "rtt": estimate.rtt, "samples": latencySamples.count])
        if RemoteVideoLatencyProbe.shared.collector === collector {
            RemoteVideoLatencyProbe.shared.markClockReady()
        }
    }
    #endif

    private func pollLoop() async {
        while !Task.isCancelled {
            guard let signaling else {
                return
            }

            do {
                let envelopes = try await signaling.poll()
                #if DEBUG
                guard !Task.isCancelled, self.signaling === signaling, !isClosing else { return }
                #endif
                for envelope in envelopes {
                    switch envelope.kind {
                    case .answer:
                        #if DEBUG
                        let answerNonce = labActiveNonce
                        guard LatencyF1Policy.acceptsSignaling(activeNonce: answerNonce,
                            messageNonce: envelope.payload["latencyF1Restart"]) else { continue }
                        guard let answeringPeer = peerConnection else { continue }
                        #endif
                        guard !answerApplied,
                              let sdp = envelope.payload["sdp"] else {
                            continue
                        }
                        do {
                            try await setRemoteDescription(
                                RTCSessionDescription(type: .answer, sdp: sdp),
                                on: peerConnection)
                        } catch {
                            #if DEBUG
                            guard !isClosing, self.peerConnection === answeringPeer else { continue }
                            #endif
                            throw error
                        }
                        #if DEBUG
                        guard !isClosing, self.peerConnection === answeringPeer else { continue }
                        guard labActiveNonce == answerNonce else { continue }
                        #endif
                        answerApplied = true
                        log.info("ICE id=\(self.diagnosticConnectionID, privacy: .public) stage=answer_applied")
                        loggedPendingRemoteICE = false
                        try await flushPendingRemoteICECandidates()
                        #if DEBUG
                        guard !isClosing, self.peerConnection === answeringPeer else { continue }
                        if answerNonce != nil {
                            f1RetiredChannel?.close(); f1RetiredPeer?.close()
                            f1RetiredChannel = nil; f1RetiredPeer = nil; f1RetiredFactory = nil
                        }
                        if labLastHello != nil { reconcileLabConfiguration() }
                        #endif
                    case .ice:
                        #if DEBUG
                        guard LatencyF1Policy.acceptsSignaling(activeNonce: labActiveNonce,
                            messageNonce: envelope.payload["latencyF1Restart"]) else { continue }
                        #endif
                        guard let candidate = iceCandidate(from: envelope.payload) else {
                            continue
                        }
                        remoteCandidateCounts.record(candidate.sdp)
                        #if DEBUG
                        let icePeer = peerConnection
                        #endif
                        do { try await handleRemoteICECandidate(candidate) }
                        catch {
                            #if DEBUG
                            guard !isClosing, peerConnection === icePeer else { continue }
                            #endif
                            throw error
                        }
                    case .bye:
                        #if DEBUG
                        guard LatencyF1Policy.acceptsSignaling(activeNonce: labActiveNonce,
                            messageNonce: envelope.payload["latencyF1Restart"]) else { continue }
                        #endif
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
                self.finishDisconnect(reason: "Can’t reconnect to your computer. Check that both devices are online and the host app is open, then try again.", category: .peerConnection)
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
        #if DEBUG
        guard let expectedPeer = peerConnection else { return }
        #endif
        for candidate in pendingCandidates {
            #if DEBUG
            guard !isClosing, peerConnection === expectedPeer else { return }
            #endif
            do { try await addRemoteICECandidate(candidate) }
            catch {
                #if DEBUG
                guard !isClosing, peerConnection === expectedPeer else { return }
                #endif
                throw error
            }
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
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing else { return }
            self.logICEState(kind: "connection_state", value: String(describing: newState))
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosing else { return }
            let logged = self.logICEState(kind: "gathering_state", value: String(describing: newState))
            if logged && newState == .complete { self.logCandidateCounts(stage: "gathering_complete") }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            #if DEBUG
            let collector = self.peerLatencyCollector
            collector?.trace(["type": "peer_state", "time": ProcessInfo.processInfo.systemUptime,
                              "state": String(describing: stateChanged)])
            #endif
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
                    finishDisconnect(reason: "Can’t connect to your computer. Check that both devices are online and the host app is open, then try again.", category: .peerConnection)
                } else {
                    finishDisconnect(reason: "The connection to your computer was lost. Check that both devices are online and try again.", category: .peerConnection)
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
            if self.peerConnection === peerConnection { self.localCandidateCounts.record(candidate.sdp) }
            #if DEBUG
            guard !self.isClosing, self.peerConnection === peerConnection else { return }
            if let nonce = self.labActiveNonce {
                if self.f1WaitingToSendOffer { self.f1PendingLocalICE.append(candidate); return }
                await self.sendF1ICE(candidate, nonce: nonce, signaling: signaling)
                return
            }
            #endif
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
            #if DEBUG
            guard self.peerConnection === peerConnection else { return }
            #endif
            self.adoptRemoteVideoTrack(track)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor [weak self] in
            guard let self, let track = receiver.track else {
                return
            }
            #if DEBUG
            guard self.peerConnection === peerConnection else { return }
            #endif
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
            #if DEBUG
            guard self.peerConnection === peerConnection else { return }
            #endif
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
            #if DEBUG
            let collector = self.peerLatencyCollector
            collector?.trace(["type": "data_channel_state", "time": ProcessInfo.processInfo.systemUptime,
                              "state": String(describing: dataChannel.readyState)])
            #endif
            if dataChannel.readyState == .closing || dataChannel.readyState == .closed {
                self.finishDisconnect(reason: "The input channel closed.", category: .dataChannel)
                return
            }
            self.sendHelloIfPossible()
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        #if DEBUG
        let latencyReceivedAt = labInstrumentation && LatencyStatsCollector.enabled ? ProcessInfo.processInfo.systemUptime : nil
        #endif
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing, self.dataChannel === dataChannel,
                  dataChannel.readyState == .open else { return }
            #if DEBUG
            if self.consumeF1Ready(buffer.data) { return }
            if let latencyReceivedAt, self.receiveLatencyPong(buffer.data, receivedAt: latencyReceivedAt) { return }
            #endif
            switch HostMessage.decode(buffer.data) {
            case .helloAck(let hello):
                #if DEBUG
                if case .restarting = self.f1State {
                    guard hello.latencyF1Playout == 1,
                          (!self.f2ApplyToReplacement || hello.latencyF2Encoder == 1),
                          (!self.f3ApplyToReplacement || hello.latencyF3Sender == 1) else {
                        self.finishDisconnect(reason: "The latency experiment is no longer supported by the host.", category: .input)
                        return
                    }
                }
                #endif
                switch directInputState.accept(version: hello.inputSessions, acknowledgement: hello.inputSession,
                                               inputInvalidation: hello.inputInvalidation) {
                case .ignored: return
                case .invalid:
                    finishDisconnect(reason: "The computer sent an invalid input-session acknowledgement.", category: .input)
                    return
                case .accepted: break
                }
                #if DEBUG
                if case .restarting(let nonce) = self.f1State {
                    self.f1State = .active(nonce)
                    if let pending = self.labPending { self.labApplied = pending }
                    self.labPending = nil
                    self.latencyCollector?.trace(["type": "f1_playout", "time": ProcessInfo.processInfo.systemUptime,
                        "requested": self.f1Configuration.f1Playout, "configured": self.f1ApplyToReplacement, "effective": "unverified", "stage": "replacement_hello",
                        "maximumDelayMs": self.f1Configuration.f1MaximumDelayMs])
                }
                #endif
                inputHandshakeDeadlineTask?.cancel()
                inputHandshakeDeadlineTask = nil
                if inputPresentation.matches(hello.inputSession) { return }
                invalidateInputPresentation()
                guard !isClosing, self.dataChannel === dataChannel, directInputState.isReady else { return }
                inputPresentation.begin(hello.inputSession)
                log.info("host acknowledged the WebRTC control channel")
                #if DEBUG
                self.labLastHello = hello
                #endif
                onHostHello?(hello)
                #if DEBUG
                if !isClosing, self.dataChannel === dataChannel { self.startF1IfSupported(hello, channel: dataChannel) }
                #endif
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
                    #if DEBUG
                    if self.labInstrumentation && LatencyStatsCollector.enabled { RemoteVideoLatencyProbe.shared.setDisplay(display) }
                    #endif
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
