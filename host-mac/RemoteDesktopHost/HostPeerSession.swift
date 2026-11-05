import AppKit
import CoreMedia
import Foundation
import LiveKitWebRTC
import os

extension ICEConfig {
    var iceServers: [RTCIceServer] {
        [RTCIceServer(urlStrings: stunURLs)]
    }
}

#if DEBUG
/// Process-wide field trials must be chosen once before any peer factory.
/// The isolated lab process never mutates or resets trials after that choice.
final class LabALRFieldTrialBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private var decided = false
    private var configuredMode = 0

    static func requestedMode(labInstrumentation: Bool, ordinaryPeer: Bool, f2Enabled: Bool, f3Enabled: Bool,
                              arguments: [String], environment: [String: String]) -> Int {
        guard labInstrumentation, ordinaryPeer, !f2Enabled, !f3Enabled,
              Array(arguments.dropFirst()) == ["--debug-latency-host"], environment["LATENCY_LAB"] == "1",
              environment["LATENCY_UDP_CAPACITY"] != "1", environment["LATENCY_STAGE2_FLOOR"] != "1",
              environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil,
              let rawID = environment["REMOTE_DESKTOP_LATENCY_HOST_ID"],
              rawID.utf8.count == 36, UUID(uuidString: rawID) != nil else { return 0 }
        switch environment["LATENCY_ALR_TRIAL"] {
        case "1": return 1
        case "2": return 2
        default: return 0
        }
    }

    static func trialString(mode: Int) -> String? {
        let screen = "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/"
        switch mode {
        case 1: return screen
        case 2: return screen + "WebRTC-Pacer-PadInSilence/Enabled/"
        default: return nil
        }
    }

    func configureOnce(requestedMode: Int, configure: (String) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        if !decided {
            decided = true
            if let trial = Self.trialString(mode: requestedMode) {
                configure(trial)
                configuredMode = requestedMode
            }
        }
        return configuredMode
    }
}
#endif

/// Serializes direct-input authority separately from media teardown. The
/// change callback must not re-enter this object; it runs inside the same lock
/// so authorization notifications keep the order of native transitions.
final class HostPeerInputAuthorization: @unchecked Sendable {
    struct State: Equatable, Sendable {
        let authorized: Bool
        let orderedComputerUseControls: Int
    }
    private let lock = NSLock()
    private let injector: InputInjector
    private let onChange: @Sendable (State) -> Void
    private var channelID: ObjectIdentifier?
    private var helloCapabilities: Int?
    private var connected = false
    private var closed = false
    private var session: InputInjector.DirectInputSession?
    private var inputHello: DirectInputHello?
    private var acknowledgement: DirectInputAcknowledgement?
    private var inputGeneration: UInt32 = 0
    private var lastInputSequence: UInt32 = 0
    private var captureAvailable: Bool
    private var captureDisplay: CaptureDisplayGeometry?
    private let requiresCaptureDisplay: Bool
    private var inputInvalidation: Int?
    private var hasAuthorizedInput = false

    enum CaptureChange: Equatable {
        case unchanged, available, unavailable(DirectInputAcknowledgement?), reconnect
    }

    init(injector: InputInjector, initialCaptureAvailable: Bool = false, requiresCaptureDisplay: Bool = true,
         onChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.injector = injector; self.onChange = onChange
        self.requiresCaptureDisplay = requiresCaptureDisplay
        captureAvailable = initialCaptureAvailable && !requiresCaptureDisplay
    }

    @discardableResult
    func openChannel(_ id: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if let channelID { return channelID == id }
            channelID = id; helloCapabilities = nil
            inputHello = nil; acknowledgement = nil; inputGeneration = 0; lastInputSequence = 0
            inputInvalidation = nil; hasAuthorizedInput = false
            return true
        }
    }

    @discardableResult
    func acceptHello(channel id: ObjectIdentifier, orderedControls: Int,
                     inputHello nextHello: DirectInputHello? = nil,
                     inputInvalidation nextInvalidation: Int = 0) -> Bool {
        lock.withLock {
            guard !closed, channelID == id,
                  (0...DirectInputWire.inputInvalidationVersion).contains(nextInvalidation),
                  nextInvalidation == 0 || nextHello != nil,
                  inputInvalidation == nil || inputInvalidation == nextInvalidation else { return false }
            if let nextHello, !nextHello.isValid { return false }
            if let inputHello {
                guard let nextHello, nextHello.clientID == inputHello.clientID,
                      nextHello.revision >= inputHello.revision else { return false }
                if nextHello.revision > inputHello.revision {
                    retireSessionLocked()
                    // A phone-observed loss still fences AI if the host never
                    // received its own disconnected callback.
                    publishLocked()
                }
            } else if helloCapabilities != nil, nextHello != nil {
                return false // The negotiated mode cannot change on this channel.
            }
            inputHello = nextHello
            inputInvalidation = nextInvalidation
            helloCapabilities = max(0, orderedControls)
            reconcileLocked(publishWhenUnauthorized: false)
            return true
        }
    }

    @discardableResult
    func connectionChanged(connected: Bool, terminal: Bool = false) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            // Legacy packets cannot prove which recovered lifetime sent them.
            let mustClose = terminal || (!connected && inputHello == nil)
            self.connected = connected && !mustClose
            if mustClose { closed = true; channelID = nil; helloCapabilities = nil }
            reconcileLocked(publishWhenUnauthorized: !self.connected)
            return true
        }
    }

    /// Capture is independent of transport connectivity. Retire the posting
    /// session and release its holds before returning the scope to notify.
    func captureChanged(available: Bool, display: CaptureDisplayGeometry? = nil) -> CaptureChange {
        lock.withLock {
            guard !closed, !available || display != nil || !requiresCaptureDisplay else { return .unchanged }
            if captureAvailable, available, captureDisplay != display {
                // A replacement layout needs an explicit loss/new scope.
                // Never silently remap an already authorized generation.
                closed = true; connected = false; channelID = nil; helloCapabilities = nil
                captureAvailable = false; captureDisplay = nil
                reconcileLocked()
                return .reconnect
            }
            guard captureAvailable != available else { return .unchanged }
            captureAvailable = available
            captureDisplay = available ? display : nil
            if available {
                reconcileLocked(publishWhenUnauthorized: false)
                return .available
            }
            let previous = acknowledgement
            let hadSession = session != nil
            let mustReconnect = hasAuthorizedInput && inputInvalidation != DirectInputWire.inputInvalidationVersion
            if mustReconnect { closed = true; connected = false; channelID = nil; helloCapabilities = nil }
            reconcileLocked(publishWhenUnauthorized: hadSession)
            return mustReconnect ? .reconnect : .unavailable(previous)
        }
    }

    @discardableResult
    func closeChannel(_ id: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard !closed, channelID == id else { return false }
            channelID = nil; helloCapabilities = nil
            reconcileLocked()
            return true
        }
    }

    func ownsChannel(_ id: ObjectIdentifier) -> Bool {
        lock.withLock { !closed && channelID == id }
    }

    func inputSession(for id: ObjectIdentifier) -> InputInjector.DirectInputSession? {
        lock.withLock { !closed && channelID == id ? session : nil }
    }

    var isClosed: Bool { lock.withLock { closed } }

    func readyAcknowledgement(for id: ObjectIdentifier) -> (session: InputInjector.DirectInputSession, wire: DirectInputAcknowledgement?, inputInvalidation: Int)? {
        lock.withLock {
            guard !closed, channelID == id, let session else { return nil }
            return (session, acknowledgement, inputInvalidation ?? 0)
        }
    }

    /// Consumes the wire sequence only for this exact live session. The
    /// injector must still recheck the returned local identity at posting.
    func admitInput(channel id: ObjectIdentifier, stamp: DirectInputStamp?) -> InputInjector.DirectInputSession? {
        lock.withLock {
            guard !closed, channelID == id, let session else { return nil }
            if inputHello != nil {
                guard let acknowledgement, let stamp, stamp.isValid,
                      stamp.hostID == acknowledgement.hostID,
                      stamp.generation == acknowledgement.generation,
                      stamp.sequence > lastInputSequence else { return nil }
                lastInputSequence = stamp.sequence
            } else if stamp != nil { return nil }
            return session
        }
    }

    func close() { _ = connectionChanged(connected: false, terminal: true) }

    @discardableResult
    func close(ifChannel id: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard !closed, channelID == id else { return false }
            closed = true; connected = false; channelID = nil; helloCapabilities = nil
            reconcileLocked()
            return true
        }
    }

    private func retireSessionLocked() {
        if let session { injector.endDirectInputSession(session) }
        session = nil; acknowledgement = nil; lastInputSequence = 0
    }

    private func reconcileLocked(publishWhenUnauthorized: Bool = true) {
        if !closed, captureAvailable, connected, channelID != nil, helloCapabilities != nil {
            if session == nil {
                guard inputGeneration < UInt32.max else {
                    closed = true; connected = false; channelID = nil; helloCapabilities = nil
                    publishLocked(); return
                }
                inputGeneration += 1
                session = injector.beginDirectInputSession(display: captureDisplay)
                hasAuthorizedInput = true
                if let inputHello {
                    acknowledgement = .init(hello: inputHello, hostID: UUID(), generation: inputGeneration)
                }
            }
        } else { retireSessionLocked() }
        // A partially completed initial handshake is not a loss of control.
        // Merely opening the visual sidecar must not interrupt a live LAN task.
        if session != nil || publishWhenUnauthorized { publishLocked() }
    }

    private func publishLocked() {
        onChange(.init(authorized: session != nil,
            orderedComputerUseControls: session == nil ? 0 : (helloCapabilities ?? 0)))
    }
}

private final class PeerCloseBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Gives every caller the same teardown barrier while allowing the session to
/// snapshot its state under its own lock before performing native cleanup.
final class PeerCloseCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: Task<Void, Never>?

    /// Revoke authority for every caller, but let only the first caller run
    /// teardown. Neither callback runs while the coordinator lock is held, so
    /// native close callbacks may safely reenter this method.
    func close(revokeInput: () -> Void,
               teardown: () -> Task<Void, Never>) -> Task<Void, Never> {
        lock.lock()
        if let completion {
            lock.unlock()
            revokeInput()
            return completion
        }
        let barrier = PeerCloseBarrier()
        let task = Task { await barrier.wait() }
        completion = task
        lock.unlock()

        revokeInput()
        let teardown = teardown()
        Task {
            await teardown.value
            barrier.finish()
        }
        return task
    }
}

final class HostPeerSession: NSObject {
    struct PeerAuthorization: Equatable, Sendable {
        let senderID: String
        let authorized: Bool
        let orderedComputerUseControls: Int

        var supportsOrderedComputerUseControls: Bool {
            authorized
                && orderedComputerUseControls
                    >= HostConfig.orderedComputerUseControlsVersion
        }
    }

    private let signaling: any SignalingChannel
    private let capture: ScreenCapture
    private let injector: InputInjector
    private let iceConfig: ICEConfig
    private let audioEnabled: Bool
    private let adaptive60Requested: Bool
    private var adaptive60Selected = false
    private let onUserInput: @Sendable () -> Bool
    private let inputAuthorization: HostPeerInputAuthorization
    private let onEnded: @Sendable (String) -> Void
    private let latencyF2Enabled: Bool
    #if DEBUG
    private let labOrdinaryPeer: Bool
    private let labALRTrialMode: Int
    private static let labALRBootstrap = LabALRFieldTrialBootstrap()
    private let lab60Requested: Bool
    private let labHEVCEnabled: Bool
    private var lab60Selected = false // protected by closeStateLock
    #endif
    private let latencyF3Enabled: Bool
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "webrtc")
    private let signalingStateQueue = DispatchQueue(label: "com.threadmark.remotedesktop.host.webrtc.signaling")
    private let closeStateLock = NSRecursiveLock()
    // Cursor transitions are ordered separately from capture and peer locks.
    private var cursorTransition: Task<Void, Never>?
    private var cursorEpoch = UUID()
    private var cursorRequested = false
    private var cursorPublisher: HostCursorPublisher? // main queue only

    private let factory: RTCPeerConnectionFactory
    private let audioBridge: SystemAudioBridge
    private let audioSource: RTCAudioSource
    private let audioTrack: RTCAudioTrack
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let videoCapturer: RTCVideoCapturer

    #if DEBUG
    private var lastCaptureMarker: Int?
    private let latencyF1Nonce: String?
    private let onLatencyF1RestartRequest: (@Sendable (String, @escaping @Sendable () -> Void) -> Void)?
    private let latencyCapabilities: LatencyLabConfiguration
    private let stage2Enabled: Bool
    private let stage2KeyframeControl: LatencyKeyframeControl?
    private var stage2State: LatencyLabSenderPolicy.Stage2State?
    private var stage2CaptureFrames: UInt64 = 0
    private var capacitySender: LatencyUDPCapacitySender?
    private var capacityLANAddress: String?
    private var capacityRequested = false

    private var capacityProbeEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return labInstrumentation && labOrdinaryPeer && environment["LATENCY_LAB"] == "1" &&
            environment["LATENCY_UDP_CAPACITY"] == "1" &&
            Array(ProcessInfo.processInfo.arguments.dropFirst()) == ["--debug-latency-host"] &&
            environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil &&
            environment["REMOTE_DESKTOP_LATENCY_HOST_ID"].flatMap(UUID.init(uuidString:)) != nil
    }

    private func consumeCapacityMessage(_ data: Data, channel: RTCDataChannel) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String,
              type == "latencyUdpCapacityRequest" || type == "latencyUdpCapacityProgress" || type == "latencyUdpCapacityStop" else { return false }
        guard capacityProbeEnabled, !isEnded, dataChannel === channel,
              channel.readyState == .open, inputAuthorization.ownsChannel(ObjectIdentifier(channel)) else { return true }
        if type == "latencyUdpCapacityStop" {
            closeStateLock.lock(); let sender = capacitySender; closeStateLock.unlock()
            sender?.stop()
            return true
        }
        if type == "latencyUdpCapacityProgress" {
            guard let rows = object["steps"] as? [[String: Any]], rows.count == LatencyUDPCapacityWire.ratesMbps.count,
                  let overflowed = object["overflowed"] as? Bool,
                  let final = object["final"] as? Bool else { return true }
            var values: [LatencyUDPCapacitySender.ReceiverStep] = []
            for row in rows {
                func integer(_ key: String) -> Int? {
                    guard let number = row[key] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue == Double(number.intValue),
                          number.intValue >= 0 else { return nil }
                    return number.intValue
                }
                guard let unique = integer("unique"), let duplicate = integer("duplicate"),
                      let reordered = integer("reordered"), let late = integer("late"),
                      let bytes = integer("bytes") else { return true }
                values.append(.init(unique: unique, duplicate: duplicate, reordered: reordered, late: late, bytes: bytes))
            }
            closeStateLock.lock(); let sender = capacitySender; closeStateLock.unlock()
            sender?.updateReceiver(values, overflowed: overflowed, final: final)
            return true
        }
        diagnosticLock.lock(); let address = capacityLANAddress; diagnosticLock.unlock()
        guard let address else { return true }
        closeStateLock.lock()
        guard !ended, !capacityRequested else { closeStateLock.unlock(); return true }
        capacityRequested = true
        let sender = LatencyUDPCapacitySender(lanAddress: address,
            offer: { [weak self, weak channel] offer in
                guard let self, let channel, let offer, !self.isEnded,
                      self.dataChannel === channel, channel.readyState == .open,
                      self.inputAuthorization.ownsChannel(ObjectIdentifier(channel)) else { return }
                let payload: [String: Any] = ["type": "latencyUdpCapacityOffer", "host": offer.host,
                    "port": Int(offer.port), "key": offer.key.base64EncodedString()]
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
                }
            }, requestSnapshot: { [weak self, weak channel] in
                guard let self, let channel, !self.isEnded, self.dataChannel === channel,
                      channel.readyState == .open, self.inputAuthorization.ownsChannel(ObjectIdentifier(channel)),
                      let data = try? JSONSerialization.data(withJSONObject: ["type": "latencyUdpCapacitySnapshotRequest"]) else { return }
                _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
            }, completion: { [weak self, weak channel] result in
                guard let self else { return }
                Self.writeCapacitySummary(result)
                guard let channel, !self.isEnded, self.dataChannel === channel,
                      channel.readyState == .open, self.inputAuthorization.ownsChannel(ObjectIdentifier(channel)) else { return }
                var payload = result; payload["type"] = "latencyUdpCapacityResult"
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
                }
            })
        capacitySender = sender
        closeStateLock.unlock()
        sender?.start()
        return true
    }

    private static func writeCapacitySummary(_ result: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["LATENCY_UDP_CAPACITY_OUTPUT"],
              path.hasPrefix("/"), let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? file.write(contentsOf: data)
        try? file.close()
    }
    private var stage2CodecAllowed = false
    private var stage2LossUnavailableLogged = false
    private let send10Enabled: Bool
    private var send10Timer: DispatchSourceTimer?
    private var send10Gate = LabSendPollGate()
    private var send10Sampler = LabSendIntervalSampler()
    private var f3AppliedPath: LatencyLabSenderPolicy.Path?
    private var f3OriginalPriorities: [(LKRTCPriority, Double)]?
    #endif
    private let latencyStats: LatencyStatsCollector
    private let labInstrumentation: Bool
    private var latencyTimer: DispatchSourceTimer?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var videoSender: RTCRtpSender?
    private var adaptedVideoWidth: Int?
    private var adaptedVideoHeight: Int?
    private var captureMaximumMacroblocksPerFrame =
        DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame
    private var captureFramesPerSecond = Int32(DesktopVideoQuality.targetFramesPerSecond)
    private var captureOwner: CaptureOwnerLease?
    private var audioRecordingStarted = false
    private var localMediaConfigured = false
    private var ended = false
    private var captureStartupRequested = false
    private var captureRestartTask: Task<Void, Never>?
    private var captureRestartID: UUID?
    private var captureRecovery: CaptureRecoveryEpisode?
    private var captureRecoveryDeadlineTask: Task<Void, Never>?
    private var lastVideoAttempt: CaptureAttemptLease?
    private let closeCoordinator = PeerCloseCoordinator()
    private var portMappingSession: HostPortMappingSession?
    private var hostSeq: UInt32 = 0
    private let diagnosticLock = NSLock()
    private var diagnosticLocal = ICECandidateDiagnostics()
    private var diagnosticRemote = ICECandidateDiagnostics()
    #if DEBUG
    private var candidateDiagnosticCount = 0
    #endif
    private var answerSent = false
    private var pendingLocalICEPayloads: [[String: String]] = []

    static func shouldSelectAdaptive60(requested: Bool, codecSupported: Bool) -> Bool {
        requested && codecSupported
    }

    static func allowsPortMapping(for classification: HostComputerUseManager.WebRTCPeerClassification?) -> Bool {
        classification == .primaryRemoteControl
    }

    static func handlePortMappingICEState(_ state: RTCIceConnectionState, session: HostPortMappingSession?) {
        if state == .failed || state == .closed { session?.closeAsync() }
    }

    /// Message-kind/protocol classification only. Dispatch also requires the
    /// current channel's exact connected input session, rechecked by the injector.
    nonisolated static func acceptsDirectInput(
        _ message: ControlMessage,
        helloAuthenticated: Bool
    ) -> Bool {
        guard helloAuthenticated else { return false }
        switch message {
        case .pointer, .scroll, .key, .text:
            return true
        case .hello, .qos, .bye:
            return false
        }
    }

    init(
        signaling: any SignalingChannel,
        capture: ScreenCapture,
        injector: InputInjector,
        iceConfig: ICEConfig,
        audioEnabled: Bool,
        peerSenderID: String,
        acceptedOrdinaryPeer: Bool = false,
        requestAdaptive60: Bool = false,
        onUserInput: @escaping @Sendable () -> Bool,
        onPeerAuthorizationChanged:
            @escaping @Sendable (PeerAuthorization) -> Void,
        labInstrumentation: Bool = true,
        latencyF1Nonce: String? = nil,
        latencyF2Enabled: Bool = false,
        latencyF3Enabled: Bool = false,
        lab60Requested: Bool = false,
        labHEVCRequested: Bool = false,
        onLatencyF1RestartRequest: (@Sendable (String, @escaping @Sendable () -> Void) -> Void)? = nil,
        onEnded: @escaping @Sendable (String) -> Void
    ) {
        #if DEBUG
        let requestedALRMode = LabALRFieldTrialBootstrap.requestedMode(
            labInstrumentation: labInstrumentation, ordinaryPeer: acceptedOrdinaryPeer,
            f2Enabled: latencyF2Enabled, f3Enabled: latencyF3Enabled,
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        let configuredALRMode = Self.labALRBootstrap.configureOnce(requestedMode: requestedALRMode) {
            RTCPeerConnectionFactory.configureFieldTrials($0)
        }
        #endif
        RTCInitializeSSL()
        self.signaling = signaling
        self.capture = capture
        self.injector = injector
        self.iceConfig = iceConfig
        self.audioEnabled = audioEnabled
        self.adaptive60Requested = acceptedOrdinaryPeer && requestAdaptive60
        self.onUserInput = onUserInput
        self.inputAuthorization = HostPeerInputAuthorization(injector: injector) { state in
            onPeerAuthorizationChanged(PeerAuthorization(senderID: peerSenderID,
                authorized: state.authorized, orderedComputerUseControls: state.orderedComputerUseControls))
        }
        self.onEnded = onEnded
        self.labInstrumentation = labInstrumentation
        #if DEBUG
        self.labOrdinaryPeer = acceptedOrdinaryPeer
        self.labALRTrialMode = configuredALRMode
        self.lab60Requested = lab60Requested
        #endif
        let stats = LatencyStatsCollector(side: "host", enabled: labInstrumentation && LatencyStatsCollector.enabled)
        self.latencyStats = stats
        #if DEBUG
        self.onLatencyF1RestartRequest = onLatencyF1RestartRequest
        self.latencyF1Nonce = latencyF1Nonce
        let labConfiguration = LatencyLabConfiguration.current
        self.latencyCapabilities = labConfiguration
        let enableF2 = latencyF2Enabled && labConfiguration.f2Encoder
        let enableF3 = latencyF3Enabled && labConfiguration.f3Sender
        #else
        let enableF2 = false
        let enableF3 = false
        #endif
        self.latencyF2Enabled = enableF2
        self.latencyF3Enabled = enableF3
        #if DEBUG
        let observeEncodedBytes: ((Int) -> Void)? = labInstrumentation && LatencyStatsCollector.enabled && !LatencyStatsCollector.resourcesOnly
            ? { [weak stats] bytes in stats?.recordEncodedFrameBytes(bytes) } : nil
        let enableStage2 = LatencyLabSenderPolicy.stage2Allowed(labInstrumentation: labInstrumentation && !LatencyStatsCollector.resourcesOnly,
            ordinaryPeer: acceptedOrdinaryPeer, arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
        self.send10Enabled = LabSendIntervalSampler.enabled(labAdmitted: labInstrumentation,
            ordinaryPeer: acceptedOrdinaryPeer, resourcesOnly: LatencyStatsCollector.resourcesOnly,
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        self.stage2Enabled = enableStage2
        self.stage2State = enableStage2 ? LatencyLabSenderPolicy.Stage2State(candidate: enableF3) : nil
        let keyframeControl: LatencyKeyframeControl? = enableStage2 && enableF3 ? LatencyKeyframeControl { [weak stats] event in
            stats?.trace(["type": "stage2_keyframe", "time": ProcessInfo.processInfo.systemUptime,
                          "event": event.rawValue])
        } : nil
        self.stage2KeyframeControl = keyframeControl
        #else
        let observeEncodedBytes: ((Int) -> Void)? = nil
        #endif
        #if DEBUG
        let cbrEnabled = Self.labCBREnabled(labInstrumentation: labInstrumentation, ordinaryPeer: acceptedOrdinaryPeer,
            clientRequested: lab60Requested, f2Enabled: enableF2, f3Enabled: enableF3, arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
        if labInstrumentation {
            stats.trace(["type": "encoder_cbr_gate", "time": ProcessInfo.processInfo.systemUptime,
                         "requested": ProcessInfo.processInfo.environment["LATENCY_ENCODER_MODE"] == "h264-cbr100" ? 1 : 0,
                         "clientLab60": lab60Requested ? 1 : 0, "admitted": cbrEnabled ? 1 : 0])
        }
        let baseEncoderFactory = DesktopVideoEncoderFactory(f2Enabled: enableF2, frameByteObserver: observeEncodedBytes,
            keyframeControl: keyframeControl, cbrEnabled: cbrEnabled,
            cbrTrace: cbrEnabled ? { [weak stats] event in
                var record = event
                record["time"] = ProcessInfo.processInfo.systemUptime
                stats?.trace(record)
            } : nil)
        let hevcRequested = Self.labHEVCAllowed(labInstrumentation: labInstrumentation, ordinaryPeer: acceptedOrdinaryPeer,
            clientRequested: labHEVCRequested, lab60Requested: lab60Requested, f2Enabled: enableF2, f3Enabled: enableF3,
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        let encoderFactory: any LKRTCVideoEncoderFactory
        if #available(macOS 26.0, *), hevcRequested, LabHEVCEncoder.preflight() {
            self.labHEVCEnabled = true
            encoderFactory = LabHEVCEncoderFactory(base: baseEncoderFactory, observeBytes: observeEncodedBytes, trace: { [weak stats] in stats?.trace($0) })
        } else { self.labHEVCEnabled = false; encoderFactory = baseEncoderFactory }
        stats.trace(["type": "encoder_hevc_gate", "time": ProcessInfo.processInfo.systemUptime,
                     "requested": hevcRequested ? 1 : 0, "admitted": self.labHEVCEnabled ? 1 : 0])
        #else
        let encoderFactory = DesktopVideoEncoderFactory(f2Enabled: enableF2, frameByteObserver: observeEncodedBytes)
        #endif
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: true,
            encoderFactory: encoderFactory,
            decoderFactory: DesktopVideoDecoderFactory(),
            audioProcessingModule: nil)
        let voiceProcessingStatus = factory.audioDeviceModule.setVoiceProcessingEnabled(false)
        _ = factory.audioDeviceModule.setEngineAvailability(
            RTCAudioEngineAvailability(
                isInputAvailable: ObjCBool(audioEnabled),
                isOutputAvailable: true))
        self.audioBridge = SystemAudioBridge()
        self.audioSource = factory.audioSource(with: nil)
        self.audioTrack = factory.audioTrack(with: audioSource, trackId: "system-audio")
        self.videoSource = factory.videoSource(forScreenCast: true)
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: "screen")
        self.videoCapturer = RTCVideoCapturer(delegate: videoSource)
        super.init()
        #if DEBUG
        latencyStats.trace(["type": "lab_peer", "time": ProcessInfo.processInfo.systemUptime,
                           "peerNonce": latencyF1Nonce as Any? ?? NSNull(),
                           "f2Configured": enableF2, "f3Configured": enableF3])
        #endif
        portMappingSession = HostPortMappingSession(acceptedOrdinaryPeer: acceptedOrdinaryPeer,
            enabled: {
                let defaults = UserDefaults.standard
                return defaults.object(forKey: "allowRouterPortMapping") as? Bool ?? true
            }, send: { [weak self] candidate, sdp in
                guard let self, !self.isEnded else { return }
                #if DEBUG
                self.logCandidateLifecycle("mapped_queued", sdp: sdp)
                #endif
                self.bufferOrSendLocalICE([
                    "candidate": sdp,
                    "sdpMid": candidate.mid ?? "",
                    "sdpMLineIndex": "\(candidate.lineIndex)",
                ])
            })
        log.info("host audio ADM voiceProcessingEnabled=false status=\(voiceProcessingStatus, privacy: .public)")
        if audioEnabled {
            audioBridge.attach(to: factory.audioDeviceModule)
        }
        configureCaptureCallbacks()
    }

    func acceptOffer(sdp: String) async throws {
        log.notice("ICE stage=offer_received")
        resetBufferedLocalICE()
        if peerConnection == nil {
            peerConnection = try makePeerConnection()
        }

        guard let peerConnection else {
            throw NSError(
                domain: "HostPeerSession",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Peer connection was released."])
        }

        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        try await setRemoteDescription(remoteDescription, on: peerConnection)
        try configureLocalMedia(on: peerConnection)
        let answer = try await createAnswer(on: peerConnection)
        try await setLocalDescription(answer, on: peerConnection)
        #if DEBUG
        let stage2Supported = DesktopVideoQuality.supportsAdaptive60(answerSDP: answer.sdp)
        closeStateLock.lock()
        stage2CodecAllowed = stage2Supported
        closeStateLock.unlock()
        if stage2Enabled && !stage2Supported {
            neutralizeStage2(peerConnection, at: ProcessInfo.processInfo.systemUptime, reason: .codecUnavailable)
        }
        #endif
        let codecs = videoSender?.parameters.codecs ?? []
        let capturePolicy = DesktopVideoQuality.capturePolicy(
            negotiatedCodecs: codecs, f2Requested: latencyF2Enabled)
        #if DEBUG
        let codec = codecs.first { ["H264", "VP8", "VP9", "AV1"].contains($0.name.uppercased()) }
        let packetization = codec?.parameters["packetization-mode"]
        let lab60 = Self.lab60Allowed(labInstrumentation: labInstrumentation, ordinaryPeer: labOrdinaryPeer,
            clientRequested: lab60Requested, f2Enabled: latencyF2Enabled, f3Enabled: latencyF3Enabled,
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
            codecName: codec?.name, profileLevelID: codec?.parameters["profile-level-id"] as? String,
            packetizationMode: (packetization as? String) ?? (packetization as? NSNumber)?.stringValue)
        #else
        let lab60 = false
        #endif
        #if DEBUG
        let hevcSelected = labHEVCEnabled && DesktopVideoQuality.supportsLabHEVC60(answerSDP: answer.sdp)
        #else
        let hevcSelected = false
        #endif
        let supportedAnswer = DesktopVideoQuality.supportsAdaptive60(answerSDP: answer.sdp) || hevcSelected
        let appliedCapture = try setCaptureMacroblockLimit(hevcSelected ? 16_384 : capturePolicy.maximumMacroblocksPerFrame,
                                     framesPerSecond: (lab60 || hevcSelected) ? 60 : capturePolicy.framesPerSecond,
                                     lab60: lab60 || hevcSelected, supportedAnswer: supportedAnswer)
        let selectedAdaptive = appliedCapture.adaptive
        #if DEBUG
        latencyStats.trace(["type": "f2_capture_policy", "time": ProcessInfo.processInfo.systemUptime,
                           "authorized": latencyF2Enabled, "framesPerSecond": appliedCapture.rate,
                           "macroblocks": appliedCapture.limit,
                           "lowLatencyRequested": capturePolicy.lowLatencyEncoder])
        #endif
        applyVideoSenderPolicy(selectedAdaptive ? DesktopVideoQuality.adaptivePolicy : DesktopVideoQuality.sharpnessPolicy, isDefault: true)
        #if DEBUG
        if !capacityProbeEnabled { startAudioRecordingIfNeeded() }
        #else
        startAudioRecordingIfNeeded()
        #endif
        var answerPayload = ["sdp": answer.sdp, "sdpType": "answer"]
        if selectedAdaptive { answerPayload["adaptiveVideo60"] = "1" }
        #if DEBUG
        if hevcSelected { answerPayload["latencyLabHEVC"] = "1" }
        #endif
        try await signaling.send(SignalingEnvelope(
            role: .host,
            kind: .answer,
            payload: latencySignalingPayload(answerPayload),
            ts: Date().timeIntervalSince1970))
        log.notice("ICE stage=answer_sent")
        flushBufferedLocalICEAfterAnswer()
        startLatencyPolling(peerConnection)

        // Capture discovery/start and first-frame delivery have their own
        // bounded worker. Keep signaling free to deliver ICE and disconnects.
        #if DEBUG
        if !capacityProbeEnabled { try requestCaptureStartup() }
        #else
        try requestCaptureStartup()
        #endif
    }

    private func startLatencyPolling(_ connection: RTCPeerConnection) {
        guard labInstrumentation, LatencyStatsCollector.enabled, latencyTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "host.latency.stats"))
        timer.schedule(deadline: .now(), repeating: 1)
        var count = 0
        #if DEBUG
        var cpuSampler = LatencyProcessCPUSampler()
        #endif
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, !self.isEnded else { return }
            #if DEBUG
            let time = ProcessInfo.processInfo.systemUptime
            let capturedFramesAtPoll: UInt64
            if self.stage2Enabled {
                self.closeStateLock.lock()
                capturedFramesAtPoll = self.stage2CaptureFrames
                self.closeStateLock.unlock()
            } else { capturedFramesAtPoll = 0 }
            self.latencyStats.flushEncodedFrameSizes(at: time)
            if let cpu = cpuSampler.sample(at: time) {
                self.latencyStats.trace(["type": "resource", "time": time,
                                         "processCPUPercent": cpu])
            }
            #endif
            count += 1
            if LatencyStatsCollector.resourcesOnly && count % 10 != 1 { return }
            let shouldLog = count % 5 == 0
            connection.statistics { report in
                let items = report.statistics.values.map {
                    LatencyStatsReport(id: $0.id, type: $0.type, values: $0.values)
                }
                #if DEBUG
                let reportTimes = Dictionary(report.statistics.values.map { ($0.id, $0.timestamp_us) },
                                             uniquingKeysWith: { first, _ in first })
                self.applyLatencySenderPolicy(items, connection: connection, sampledAt: time, capturedFrames: capturedFramesAtPoll,
                                              reportTimestampUs: report.timestamp_us, reportTimes: reportTimes)
                #endif
                self.latencyStats.ingest(items, at: ProcessInfo.processInfo.systemUptime)
                if shouldLog {
                    self.log.info("latency stats: \(String(describing: self.latencyStats.snapshot()), privacy: .public)")
                }
            }
        }
        latencyTimer = timer
        timer.resume()
        #if DEBUG
        startSend10Polling(connection)
        #endif
    }

    #if DEBUG
    private func startSend10Polling(_ connection: RTCPeerConnection) {
        closeStateLock.lock()
        guard send10Enabled, !ended, peerConnection === connection, send10Timer == nil else { closeStateLock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "host.latency.send10"))
        send10Timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(90), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            LabSendPollInvocation.start(reserve: { () -> (UInt64, TimeInterval)? in
                self.closeStateLock.lock(); defer { self.closeStateLock.unlock() }
                guard !self.ended, self.peerConnection === connection, let token = self.send10Gate.begin() else { return nil }
                return (token, ProcessInfo.processInfo.systemUptime)
            }, invoke: { reservation, completion in
                self.latencyStats.trace(["type": "send_10hz_request", "time": reservation.1])
                connection.statistics(completionHandler: completion)
            }, complete: { [weak self, weak connection] reservation, report in
                guard let self, let connection else { return }
                let completed = ProcessInfo.processInfo.systemUptime
                let reports = report.statistics.values.map { LatencyStatsReport(id: $0.id, type: $0.type, values: $0.values) }
                let times = Dictionary(report.statistics.values.map { ($0.id, $0.timestamp_us) }, uniquingKeysWith: { first, _ in first })
                self.closeStateLock.lock(); defer { self.closeStateLock.unlock() }
                guard !self.ended, self.peerConnection === connection, self.send10Gate.finish(reservation.0) else { return }
                let row = self.send10Sampler.sample(request: reservation.1, completion: completed,
                    reportTimestampUs: report.timestamp_us, reports: reports, times: times)
                self.latencyStats.trace(row)
            })
        }
        timer.resume()
        closeStateLock.unlock()
    }

    private func applyLatencySenderPolicy(_ reports: [LatencyStatsReport], connection: RTCPeerConnection, sampledAt: Double, capturedFrames: UInt64,
                                          reportTimestampUs: Double, reportTimes: [String: Double]) {
        if stage2Enabled {
            applyStage2(reports, connection: connection, sampledAt: sampledAt, capturedFrames: capturedFrames,
                        reportTimestampUs: reportTimestampUs, reportTimes: reportTimes)
            return
        }
        guard latencyF3Enabled, let path = LatencyLabSenderPolicy.selectedPath(in: reports) else { return }
        closeStateLock.lock(); defer { closeStateLock.unlock() }
        guard !ended, peerConnection === connection, let videoSender, f3AppliedPath != path else { return }
        // Nil preserves the previous minimum. Explicit zero is needed when a
        // connection leaves the LAN, so its former 2.5 Mbps floor is removed.
        guard connection.setBweMinBitrateBps(NSNumber(value: path.minimumBitrate),
            currentBitrateBps: NSNumber(value: path.startingBitrate),
            maxBitrateBps: NSNumber(value: path.maximumBitrate)) else { return }
        let parameters = videoSender.parameters
        if f3OriginalPriorities == nil {
            f3OriginalPriorities = parameters.encodings.map { ($0.networkPriority, $0.bitratePriority) }
        }
        for (index, encoding) in parameters.encodings.enumerated() {
            if path.isLAN {
                encoding.networkPriority = .high
                encoding.bitratePriority = 2
            } else if let prior = f3OriginalPriorities, prior.indices.contains(index) {
                encoding.networkPriority = prior[index].0
                encoding.bitratePriority = prior[index].1
            }
        }
        videoSender.parameters = parameters
        f3AppliedPath = path
        latencyStats.trace(["type": "f3_path_applied", "time": ProcessInfo.processInfo.systemUptime,
                           "localType": path.localType, "remoteType": path.remoteType,
                           "minimumBitrate": path.minimumBitrate, "startingBitrate": path.startingBitrate,
                           "maximumBitrate": path.maximumBitrate, "highPriority": path.isLAN])
    }

    private func neutralizeStage2(_ connection: RTCPeerConnection, at time: Double,
                                  reason: LatencyLabSenderPolicy.Stage2Action.Reason) {
        closeStateLock.lock(); defer { closeStateLock.unlock() }
        guard !ended, peerConnection === connection, var state = stage2State else { return }
        let decision = state.unavailable(at: time, reason: reason) { action in
            connection.setBweMinBitrateBps(NSNumber(value: action.floor), currentBitrateBps: nil, maxBitrateBps: nil)
        }
        stage2State = state
        if let decision {
            latencyStats.trace(["type": "stage2_floor", "time": time, "reason": reason.rawValue,
                                "floorBps": 0, "applied": decision.applied])
        }
    }

    private func applyStage2(_ reports: [LatencyStatsReport], connection: RTCPeerConnection, sampledAt: Double, capturedFrames: UInt64,
                             reportTimestampUs: Double, reportTimes: [String: Double]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard sampledAt.isFinite, now >= sampledAt, now - sampledAt <= 2 else { return }
        closeStateLock.lock(); let supported = !ended && peerConnection === connection && stage2CodecAllowed; closeStateLock.unlock()
        guard supported else { neutralizeStage2(connection, at: sampledAt, reason: .codecUnavailable); return }
        guard let path = LatencyLabSenderPolicy.selectedPath(in: reports) else {
            neutralizeStage2(connection, at: sampledAt, reason: .pathUnavailable); return
        }
        let video = reports.filter { report in
            report.type == "outbound-rtp" && (report.values["kind"] as? String ?? report.values["mediaType"] as? String) == "video"
        }
        guard video.count == 1, let outbound = video.first,
              let frames = (outbound.values["framesEncoded"] as? NSNumber)?.doubleValue else { return }
        let remote = reports.filter { report in
            report.type == "remote-inbound-rtp" && ((report.values["localId"] as? String) == outbound.id ||
                (outbound.values["remoteId"] as? String) == report.id)
        }
        guard remote.count <= 1 else { return }
        let selected = reports.first { $0.id == path.id && $0.type == "candidate-pair" }
        func number(_ report: LatencyStatsReport?, _ key: String) -> Double? {
            (report?.values[key] as? NSNumber)?.doubleValue
        }
        closeStateLock.lock(); defer { closeStateLock.unlock() }
        guard !ended, peerConnection === connection, stage2CodecAllowed, videoSender != nil,
              var next = stage2State else { return }
        let fraction = number(remote.first, "fractionLost")
        let remoteTimestamp = remote.first.flatMap { reportTimes[$0.id] }
        if fraction == nil || remoteTimestamp == nil {
            if !stage2LossUnavailableLogged {
                latencyStats.trace(["type": "stage2_loss", "time": now, "status": "unavailable"])
                stage2LossUnavailableLogged = true
            }
        } else { stage2LossUnavailableLogged = false }
        let sample = LatencyLabSenderPolicy.Stage2Sample(time: sampledAt, path: path, outboundID: outbound.id,
            remoteID: remote.first?.id, captureFrames: capturedFrames, framesEncoded: frames,
            rttSeconds: number(selected, "currentRoundTripTime"), rttResponses: number(selected, "responsesReceived"),
            fractionLost: fraction, lossTimestampUs: remoteTimestamp, reportTimestampUs: reportTimestampUs,
            targetBitrate: number(outbound, "targetBitrate"))
        let decision = next.apply(sample) { action in
            connection.setBweMinBitrateBps(NSNumber(value: action.floor),
                currentBitrateBps: action.current.map { NSNumber(value: $0) },
                maxBitrateBps: NSNumber(value: path.maximumBitrate))
        }
        stage2State = next
        guard let decision else { return }
        let action = decision.action
        var event: [String: Any] = ["type": "stage2_floor", "time": now, "reason": action.reason.rawValue,
                                    "floorBps": action.floor, "applied": decision.applied,
                                    "localType": path.localType, "remoteType": path.remoteType]
        if let current = action.current { event["currentBps"] = current }
        latencyStats.trace(event)
        if action.reason == .stall && decision.applied {
            let result = stage2KeyframeControl?.requestKeyframe()
            latencyStats.trace(["type": "stage2_keyframe", "time": now, "event": "requested",
                                "result": result?.rawValue ?? "unavailable"])
        }
    }
    #endif

    func addRemoteIce(_ payload: [String: String]) {
        guard let peerConnection,
              let candidate = iceCandidate(from: payload) else {
            return
        }
        diagnosticLock.lock()
        diagnosticRemote.record(candidate.sdp)
        let remoteSummary = diagnosticRemote.summary
        diagnosticLock.unlock()
        log.notice("ICE remote={\(remoteSummary, privacy: .public)}")
        peerConnection.add(candidate) { [log] error in
            if error != nil {
                log.error("failed to add remote ICE candidate")
            }
        }
    }

    /// Synchronously revokes input/media ownership and returns the exact screen
    /// capture teardown barrier. A replacement peer must await the returned
    /// task before installing new capture callbacks on the shared capturer.
    @discardableResult
    func close(reason: String) -> Task<Void, Never> {
        return closeCoordinator.close(revokeInput: {
            self.inputAuthorization.close()
        }) {
            self.portMappingSession?.close()
            self.closeStateLock.lock()
            self.ended = true
            #if DEBUG
            self.capacitySender?.stop()
            self.capacitySender = nil
            self.stage2KeyframeControl?.invalidate()
            self.stage2State = nil
            self.send10Gate.cancel()
            self.send10Timer?.cancel(); self.send10Timer = nil
            #endif
            self.latencyTimer?.cancel()
            self.latencyTimer = nil
            self.cursorRequested = false
            self.cursorEpoch = UUID()
            DispatchQueue.main.async { [weak self] in self?.stopCursorPublisher() }
            let restartTask = self.captureRestartTask
            self.captureRestartTask = nil
            self.captureRestartID = nil
            self.captureRecovery = nil
            let recoveryDeadlineTask = self.captureRecoveryDeadlineTask
            self.captureRecoveryDeadlineTask = nil
            let owner = self.captureOwner
            let channelToClose = self.dataChannel
            self.dataChannel = nil
            let peerConnectionToClose = self.peerConnection
            self.peerConnection = nil
            self.videoSender = nil
            self.adaptedVideoWidth = nil
            self.adaptedVideoHeight = nil
            self.lastVideoAttempt = nil
            let shouldDetachAudio = self.audioEnabled
            let shouldStopAudioRecording = self.audioRecordingStarted
            self.audioRecordingStarted = false
            self.localMediaConfigured = false
            self.hostSeq &+= 1
            let timestamp = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
            let byePayload = self.messageData(for: .bye(reason: reason), seq: self.hostSeq, ts: timestamp)
            self.closeStateLock.unlock()

            restartTask?.cancel()
            recoveryDeadlineTask?.cancel()
            // Never acquire the capture gate under the peer lock: capture callbacks
            // may synchronously reenter native peer callbacks during teardown.
            let captureTeardown = owner.map { self.capture.endSession($0) } ?? Task {}
            self.resetBufferedLocalICE()
            if let channelToClose, channelToClose.readyState == .open {
                _ = channelToClose.sendData(RTCDataBuffer(data: byePayload, isBinary: false))
            }
            channelToClose?.close()
            peerConnectionToClose?.close()
            if shouldDetachAudio {
                self.audioBridge.detach(from: self.factory.audioDeviceModule)
            }
            if shouldStopAudioRecording {
                let stopStatus = self.factory.audioDeviceModule.stopRecording()
                self.log.info("host audio ADM stop=\(stopStatus, privacy: .public)")
            }
            return captureTeardown
        }
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
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
            throw NSError(
                domain: "HostPeerSession",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't create the peer connection."])
        }
        return peerConnection
    }

    private func configureLocalMedia(on peerConnection: RTCPeerConnection?) throws {
        guard let peerConnection else {
            throw NSError(
                domain: "HostPeerSession",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Missing peer connection."])
        }
        guard !localMediaConfigured else {
            return
        }

        try addOutboundVideoTrack(on: peerConnection)
        if audioEnabled {
            try bindAudioTrackToExistingTransceiver(on: peerConnection)
        }
        localMediaConfigured = true
    }

    private func addOutboundVideoTrack(on peerConnection: RTCPeerConnection) throws {
        guard let sender = peerConnection.add(videoTrack, streamIds: ["screen"]) else {
            throw NSError(
                domain: "HostPeerSession",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't attach the video track to the peer connection."])
        }
        videoSender = sender
        let transceiverMid = peerConnection.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid ?? "nil"
        log.info("bound video sender to negotiated transceiver mid=\(transceiverMid, privacy: .public)")
    }

    /// Finds the audio transceiver already created by `setRemoteDescription`
    /// (from the client's `recvOnly` audio m-line) and sets our audio track
    /// on its sender. This avoids creating a second, unmatched audio m-line
    /// that `peerConnection.add(track:)` would produce.
    private func bindAudioTrackToExistingTransceiver(on peerConnection: RTCPeerConnection) throws {
        // After setRemoteDescription with the client's recvOnly audio offer,
        // the host has a transceiver with direction sendOnly and no local track.
        let audioTransceiver = peerConnection.transceivers.first { transceiver in
            transceiver.mediaType == .audio
        }

        guard let audioTransceiver else {
            // Fallback: no pre-existing transceiver, add one explicitly.
            let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .sendOnly
            transceiverInit.streamIds = ["system"]
            guard let fallback = peerConnection.addTransceiver(with: audioTrack, init: transceiverInit) else {
                throw NSError(
                    domain: "HostPeerSession",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't create an audio transceiver."])
            }
            log.info("created fallback audio transceiver mid=\(fallback.mid, privacy: .public)")
            return
        }

        audioTransceiver.sender.track = audioTrack
        audioTransceiver.setDirection(.sendOnly, error: nil)
        log.info("bound audio track to existing transceiver mid=\(audioTransceiver.mid, privacy: .public) direction=\(String(describing: audioTransceiver.direction), privacy: .public)")
    }

    private func configureCaptureCallbacks() {
        let onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
        if audioEnabled {
            onAudioSample = { [weak self] sample in self?.audioBridge.enqueue(sample) }
        } else {
            onAudioSample = nil
        }
        captureOwner = capture.beginSession(callbacks: ScreenCapture.Callbacks(
            onVideoFrame: { [weak self] frame, attempt in
                self?.pushVideoFrame(frame)
                self?.recordRecoveryFrame(from: attempt)
            },
            onAudioSample: onAudioSample,
            onVideoUnavailable: { [weak self] attempt in self?.handleCaptureVideoUnavailable(from: attempt) },
            onStopped: { [weak self] receipt, error in
                // Classify the stop before any retry can retire its receipt.
                // Input closes synchronously; native peer teardown is deferred.
                self?.revokeCaptureInput()
                self?.handleCaptureStopped(receipt, error: error)
            }))
    }

    private func captureStartParameters() throws -> (CaptureOwnerLease, Int) {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended, let captureOwner else { throw CancellationError() }
        return (captureOwner, captureMaximumMacroblocksPerFrame)
    }

    #if DEBUG
    static func lab60OfferRequested(_ payload: [String: String]) -> Bool {
        payload["latencyLab60"] == "1"
    }

    static func lab60Allowed(labInstrumentation: Bool, ordinaryPeer: Bool, clientRequested: Bool, f2Enabled: Bool, f3Enabled: Bool,
                             arguments: [String], environment: [String: String], codecName: String?,
                             profileLevelID: String?, packetizationMode: String?) -> Bool {
        guard labInstrumentation, ordinaryPeer, clientRequested,
              Array(arguments.dropFirst()) == [DebugResidentHostConfiguration.latencyArgument],
              let rawID = environment[DebugResidentHostConfiguration.latencyIdentityEnvironmentKey],
              rawID.utf8.count == 36, UUID(uuidString: rawID) != nil,
              environment[DebugResidentHostConfiguration.identityEnvironmentKey] == nil,
              environment["LATENCY_LAB"] == "1", environment["LATENCY_CAPTURE_FPS"] == "60",
              ["3600", "8192", "16384"].contains(environment["LATENCY_CAPTURE_MACROBLOCKS"] ?? "") else { return false }
        return DesktopVideoQuality.supportsExperimentalEncoder(name: codecName ?? "",
            profileLevelID: profileLevelID, packetizationMode: packetizationMode)
    }

    static func lab60SenderRate(requested: Int, captureRate: Int32, lab60: Bool) -> Int? {
        lab60 && captureRate == 60 && requested == 60 ? 60 : nil
    }

    /// The common 5 Mbps lab ceiling is deliberately a single closed setting.
    /// A missing or malformed opt-in leaves the sender policy unchanged.
    #if DEBUG
    static func labHEVCAllowed(labInstrumentation: Bool, ordinaryPeer: Bool, clientRequested: Bool,
                               lab60Requested: Bool, f2Enabled: Bool, f3Enabled: Bool,
                               arguments: [String], environment: [String: String]) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return labInstrumentation && ordinaryPeer && clientRequested && lab60Requested && !f2Enabled && !f3Enabled &&
            Array(arguments.dropFirst()) == ["--debug-latency-host"] && environment["LATENCY_LAB"] == "1" &&
            environment["LATENCY_ENCODER_MODE"] == "h265-cbr100" &&
            environment["LATENCY_UDP_CAPACITY"] != "1" && environment["LATENCY_STAGE2_FLOOR"] != "1" &&
            environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil &&
            environment["REMOTE_DESKTOP_LATENCY_HOST_ID"].flatMap(UUID.init(uuidString:)) != nil
    }

    static func labCBREnabled(labInstrumentation: Bool, ordinaryPeer: Bool, clientRequested: Bool, f2Enabled: Bool, f3Enabled: Bool,
                              arguments: [String], environment: [String: String]) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return labInstrumentation && ordinaryPeer && clientRequested && !f2Enabled && !f3Enabled &&
            Array(arguments.dropFirst()) == ["--debug-latency-host"] && environment["LATENCY_LAB"] == "1" &&
            environment["LATENCY_ENCODER_MODE"] == "h264-cbr100" &&
            environment["LATENCY_UDP_CAPACITY"] != "1" && environment["LATENCY_STAGE2_FLOOR"] != "1" &&
            environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil &&
            environment["REMOTE_DESKTOP_LATENCY_HOST_ID"].flatMap(UUID.init(uuidString:)) != nil
    }
    #endif

    static func labVideoCeiling(labInstrumentation: Bool, ordinaryPeer: Bool, f3Enabled: Bool,
                                arguments: [String], environment: [String: String]) -> Int? {
        guard labInstrumentation, ordinaryPeer, !f3Enabled,
              Array(arguments.dropFirst()) == ["--debug-latency-host"],
              environment["LATENCY_LAB"] == "1", environment["LATENCY_VIDEO_CEILING_BPS"] == "5000000",
              environment["LATENCY_UDP_CAPACITY"] != "1", environment["LATENCY_STAGE2_FLOOR"] != "1",
              environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil,
              let rawID = environment["REMOTE_DESKTOP_LATENCY_HOST_ID"],
              rawID.utf8.count == 36, UUID(uuidString: rawID) != nil else { return nil }
        return 5_000_000
    }

    static func labClampedVideoMaximum(_ requested: Int, ceiling: Int?) -> Int {
        guard let ceiling else { return requested }
        return min(requested, ceiling)
    }

    static func lab60CaptureMacroblockLimit(negotiated: Int, labInstrumentation: Bool,
                                           environment: [String: String], lab60: Bool) -> Int {
        if lab60, labInstrumentation, environment["LATENCY_LAB"] == "1",
           environment["LATENCY_CAPTURE_MACROBLOCKS"] == "16384" {
            return min(negotiated, 16_384)
        }
        return labCaptureMacroblockLimit(negotiated: negotiated, labInstrumentation: labInstrumentation,
                                        environment: environment)
    }

    static func labCaptureMacroblockLimit(negotiated: Int, labInstrumentation: Bool,
                                         environment: [String: String]) -> Int {
        guard labInstrumentation, environment["LATENCY_LAB"] == "1",
              let raw = environment["LATENCY_CAPTURE_MACROBLOCKS"],
              raw == "3600" || raw == "8192", let requested = Int(raw) else { return negotiated }
        return min(negotiated, requested)
    }
    #endif

    private func setCaptureMacroblockLimit(_ limit: Int, framesPerSecond: Int32, lab60: Bool, supportedAnswer: Bool) throws -> (adaptive: Bool, rate: Int32, limit: Int) {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended else { throw CancellationError() }
        if captureStartupRequested {
            guard !adaptive60Selected || supportedAnswer else {
                throw NSError(domain: "HostPeerSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "The capture codec changed. Reconnect to continue."])
            }
            if adaptive60Selected {
                return (true, captureFramesPerSecond, captureMaximumMacroblocksPerFrame)
            }
        } else {
            adaptive60Selected = Self.shouldSelectAdaptive60(requested: adaptive60Requested, codecSupported: supportedAnswer)
        }
        let limit = adaptive60Selected ? min(limit, DesktopVideoQuality.adaptiveMaximumMacroblocksPerFrame) : limit
        let framesPerSecond = adaptive60Selected ? Int32(DesktopVideoQuality.adaptiveFramesPerSecond) : framesPerSecond
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let selectedLimit = Self.lab60CaptureMacroblockLimit(negotiated: limit,
            labInstrumentation: labInstrumentation, environment: environment, lab60: lab60)
        let ceilingRequested = ["3600", "8192"].contains(environment["LATENCY_CAPTURE_MACROBLOCKS"] ?? "") ||
            (lab60 && environment["LATENCY_CAPTURE_MACROBLOCKS"] == "16384")
        // Do not apply an experimental ceiling to an already running stream.
        if labInstrumentation, environment["LATENCY_LAB"] == "1", ceilingRequested,
           captureStartupRequested, captureMaximumMacroblocksPerFrame != selectedLimit {
            throw NSError(domain: "LatencyLab", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Capture sizing changed. Reconnect to continue."])
        }
        // Lab handoffs create a fresh peer/capture owner. A subsequent codec
        // renegotiation must not claim new constraints on an existing stream.
        if (latencyF2Enabled || lab60Selected || lab60), captureStartupRequested,
           captureMaximumMacroblocksPerFrame != selectedLimit || captureFramesPerSecond != framesPerSecond {
            throw NSError(domain: "LatencyLab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The latency capture policy changed. Reconnect to continue."])
        }
        if labInstrumentation, environment["LATENCY_LAB"] == "1", ceilingRequested {
            latencyStats.trace(["type": "capture_ceiling", "time": ProcessInfo.processInfo.systemUptime,
                                "negotiatedMacroblocks": limit, "appliedMacroblocks": selectedLimit,
                                "framesPerSecond": framesPerSecond])
        }
        #else
        let selectedLimit = limit
        #endif
        #if DEBUG
        lab60Selected = lab60
        #endif
        captureMaximumMacroblocksPerFrame = selectedLimit
        captureFramesPerSecond = framesPerSecond
        return (adaptive60Selected, captureFramesPerSecond, captureMaximumMacroblocksPerFrame)
    }

    private var captureFrameRate: Int32 {
        closeStateLock.lock(); defer { closeStateLock.unlock() }
        return captureFramesPerSecond
    }

    var isEnded: Bool {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        return ended
    }

    private func requestCaptureStartup() throws {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended, captureOwner != nil else { throw CancellationError() }
        // Renegotiation joins the original request. It cannot renew an
        // unavailable episode or restart a stream that is already available.
        guard !captureStartupRequested else { return }
        captureStartupRequested = true
        beginCaptureRecoveryLocked()
        startCaptureWorkerLocked()
    }

    private func startCapture() async throws {
        let (owner, limit) = try captureStartParameters()
        try await capture.start(for: owner, audioEnabled: audioEnabled,
                                maximumMacroblocksPerFrame: limit,
                                framesPerSecond: captureFrameRate)
        refreshCaptureInputAvailability()
    }

    private func applyVideoSenderPolicy(
        _ policy: DesktopVideoQuality.SenderPolicy, isDefault: Bool = false, requestedFrameRate: Int? = nil
    ) {
        guard let videoSender else {
            log.warning("couldn't apply desktop video quality policy: missing sender")
            return
        }
        let parameters = videoSender.parameters
        let encodings = parameters.encodings
        guard !encodings.isEmpty else {
            log.warning("couldn't apply desktop video quality policy: missing encoding")
            return
        }
        let senderFrameRate: Int
        #if DEBUG
        closeStateLock.lock()
        let lab60 = lab60Selected
        closeStateLock.unlock()
        if let requestedFrameRate, let selected = Self.lab60SenderRate(requested: requestedFrameRate,
                                                                       captureRate: captureFrameRate, lab60: lab60) {
            senderFrameRate = selected
        } else {
            senderFrameRate = DesktopVideoQuality.senderFrameRate(
                policyRate: policy.maximumFramesPerSecond, captureRate: captureFrameRate, isDefault: isDefault)
        }
        #else
        senderFrameRate = DesktopVideoQuality.senderFrameRate(
            policyRate: policy.maximumFramesPerSecond, captureRate: captureFrameRate, isDefault: isDefault)
        #endif
        #if DEBUG
        let labCeiling = Self.labVideoCeiling(labInstrumentation: labInstrumentation, ordinaryPeer: labOrdinaryPeer,
            f3Enabled: latencyF3Enabled, arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
        let maximumBitrate = Self.labClampedVideoMaximum(policy.maximumBitrateBps, ceiling: labCeiling)
        #else
        let maximumBitrate = policy.maximumBitrateBps
        #endif
        for encoding in encodings {
            encoding.maxBitrateBps = NSNumber(value: maximumBitrate)
            encoding.maxFramerate = NSNumber(value: senderFrameRate)
            encoding.scaleResolutionDownBy = 1
        }
        parameters.encodings = encodings
        parameters.degradationPreference = NSNumber(
            value: policy.degradationPreference.rawValue)
        videoSender.parameters = parameters

        #if DEBUG
        if labInstrumentation && labOrdinaryPeer {
            let extensions = videoSender.parameters.headerExtensions
            let transportSequence = extensions.contains {
                $0.uri == "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01" ||
                $0.uri == "http://www.webrtc.org/experiments/rtp-hdrext/transport-wide-cc-02"
            }
            latencyStats.trace(["type": "alr_field_trial", "time": ProcessInfo.processInfo.systemUptime,
                "configuredMode": labALRTrialMode, "screenShareSource": true,
                "transportSequenceExtensionPresent": transportSequence, "runtimeProbingVerified": false])
        }
        #endif
        let bweUpdated = peerConnection?.setBweMinBitrateBps(
            nil,
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: maximumBitrate)) ?? false
        #if DEBUG
        if let labCeiling {
            let readback = videoSender.parameters.encodings.compactMap { $0.maxBitrateBps?.intValue }
            let transportSequenceExtension = videoSender.parameters.headerExtensions.contains {
                $0.uri == "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01" ||
                $0.uri == "http://www.webrtc.org/experiments/rtp-hdrext/transport-wide-cc-02"
            }
            var event: [String: Any] = ["type": "video_ceiling", "time": ProcessInfo.processInfo.systemUptime,
                "configuredBps": labCeiling, "requestedMaximumBps": maximumBitrate,
                "encodingReadbackMatches": !readback.isEmpty && readback.count == encodings.count && readback.allSatisfy { $0 == maximumBitrate },
                "bweMaximumApplied": bweUpdated, "transportSequenceExtensionPresent": transportSequenceExtension]
            if readback.count == encodings.count, let first = readback.first, readback.allSatisfy({ $0 == first }) {
                event["effectiveEncodingMaximumBps"] = first
            }
            latencyStats.trace(event)
        }
        #endif
        let captureLimit = (try? captureStartParameters().1) ?? 0
        log.info(
            "desktop video quality captureMacroblocks=\(captureLimit, privacy: .public) maxBitrate=\(maximumBitrate, privacy: .public) maxFps=\(senderFrameRate, privacy: .public) degradation=\(policy.degradationPreference.rawValue, privacy: .public) bweUpdated=\(bweUpdated, privacy: .public)")
    }

    private func handleCaptureStopped(_ receipt: CaptureStopReceipt, error: Error) {
        // All composed transitions acquire capture admission before the peer
        // lock. Validation and the recovery decision share that same admission.
        var terminalReason: String?
        var terminalOwner: CaptureOwnerLease?
        capture.consumeStop(receipt) {
            closeStateLock.lock()
            defer { closeStateLock.unlock() }
            guard !ended else { return }
            guard ScreenCapture.isRecoverableStop(error) else {
                log.error("screen capture stopped: \(String(describing: error), privacy: .public)")
                ended = true
                terminalOwner = captureOwner
                terminalReason = "Screen capture stopped. Reconnect to try again."
                return
            }
            beginCaptureRecoveryLocked()
            startCaptureWorkerLocked()
        }
        if let terminalReason {
            // This method is entered under the capture callback's gate, with
            // no outer peer lock. Retire native admission before a waiting
            // worker can begin another attempt; defer native peer teardown.
            if let terminalOwner { _ = capture.endSession(terminalOwner) }
            scheduleCaptureClose(terminalReason)
        }
    }

    /// Called with the peer lock held. Startup arms the deadline before any
    /// native await; capture callbacks acquire capture admission first.
    /// Nonterminal output loss waits on the continuing stream without restart.
    private func beginCaptureRecoveryLocked(waitingForOutputFrom attempt: CaptureAttemptLease? = nil) {
        guard captureRecovery == nil else { return }
        let episode = CaptureRecoveryEpisode(now: ContinuousClock.now, waitingForOutputFrom: attempt)
        captureRecovery = episode
        captureRecoveryDeadlineTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: episode.deadline) }
            catch { return }
            self?.endCaptureRecovery(episode.id, reason: CaptureRecoveryEpisode.Failure.timedOut.message)
        }
    }

    private func startCaptureWorkerLocked() {
        guard captureRestartTask == nil, let episode = captureRecovery else { return }
        let worker = UUID()
        captureRestartID = worker
        captureRestartTask = Task { [weak self] in
            await self?.restartCaptureLoop(worker: worker, episode: episode.id)
        }
    }

    private func handleCaptureVideoUnavailable(from attempt: CaptureAttemptLease) {
        // This callback is synchronous inside the current stream's admission
        // gate. Clear remembered output before any startup completion can use it.
        revokeCaptureInput()
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended else { return }
        beginCaptureRecoveryLocked(waitingForOutputFrom: attempt)
    }

    private func ownsCaptureRestart(_ worker: UUID, episode: UUID) -> Bool {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        return !ended && captureRestartID == worker && captureRecovery?.id == episode
    }

    private func reserveCaptureRestart(_ worker: UUID, episode: UUID) -> Bool {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended, captureRestartID == worker, captureRecovery?.id == episode else { return false }
        return captureRecovery?.reserveAttempt(at: ContinuousClock.now) == true
    }

    private func captureRestartDelay(_ worker: UUID, episode: UUID) -> Duration? {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended, captureRestartID == worker, captureRecovery?.id == episode else { return nil }
        return captureRecovery?.retryDelay(at: ContinuousClock.now)
    }

    /// Called within the media admission gate after forwarding a validated
    /// frame. This records source output, not remote decode or presentation.
    private func recordRecoveryFrame(from attempt: CaptureAttemptLease) {
        closeStateLock.lock()
        guard !ended else { closeStateLock.unlock(); return }
        lastVideoAttempt = attempt
        closeStateLock.unlock()
        refreshCaptureInputAvailability()
    }

    private func refreshCaptureInputAvailability() {
        guard let (owner, _) = try? captureStartParameters() else { return }
        capture.withRunningSession(owner) { runningAttempt, videoAvailable, display in
            closeStateLock.lock()
            defer { closeStateLock.unlock() }
            guard !ended, videoAvailable, lastVideoAttempt == runningAttempt else { return }
            if let episode = captureRecovery {
                guard episode.acceptsFrame(lastOutput: lastVideoAttempt, running: runningAttempt,
                                           at: ContinuousClock.now) else { return }
                completeCaptureRecoveryLocked()
            }
            restoreCaptureInputLocked(display: display)
        }
    }

    /// Called under the current capture gate and peer lock, after current
    /// source output is available. This is not remote presentation proof.
    private func restoreCaptureInputLocked(display: CaptureDisplayGeometry) {
        switch inputAuthorization.captureChanged(available: true, display: display) {
        case .available: sendHelloAckAndDisplay()
        case .reconnect: scheduleCaptureTerminalFailure("The screen layout changed without a new input session. Reconnect to restore control.")
        case .unchanged, .unavailable: break
        }
    }

    /// Called synchronously inside the unavailable or retired stream's capture gate.
    private func revokeCaptureInput() {
        closeStateLock.lock()
        lastVideoAttempt = nil
        closeStateLock.unlock()
        switch inputAuthorization.captureChanged(available: false) {
        case .unchanged, .available: break
        case .reconnect:
            scheduleCaptureTerminalFailure("Screen capture was interrupted. Reconnect to restore control.")
        case .unavailable(let scope):
            if let scope, !sendInputUnavailable(scope) {
                inputAuthorization.close()
                scheduleCaptureTerminalFailure("The screen interruption could not be sent. Reconnect to restore control.")
            }
        }
    }

    private func scheduleCaptureTerminalFailure(_ reason: String) {
        closeStateLock.lock()
        guard !ended else { closeStateLock.unlock(); return }
        ended = true
        closeStateLock.unlock()
        scheduleCaptureClose(reason)
    }

    private func scheduleCaptureClose(_ reason: String) {
        // Native teardown must run after this capture callback releases its
        // gate. Input has already been revoked synchronously.
        Task { [weak self] in
            guard let self else { return }
            self.close(reason: reason)
            self.onEnded(reason)
        }
    }

    private enum CaptureStartDisposition { case restored, awaitingFrame, retry, retired }

    /// Startup success alone cannot clear the watchdog. Early output can be
    /// counted once this exact attempt is running; later output completes the
    /// same episode through recordRecoveryFrame. Clearing the worker while the
    /// stream gate is held prevents a simultaneous stop from being lost.
    private func settleCaptureRestart(_ worker: UUID, episode: UUID) -> CaptureStartDisposition {
        guard let (owner, _) = try? captureStartParameters() else { return .retired }
        var result = CaptureStartDisposition.retry
        capture.withRunningSession(owner) { runningAttempt, videoAvailable, display in
            closeStateLock.lock()
            defer { closeStateLock.unlock() }
            guard !ended, captureRestartID == worker, let recovery = captureRecovery,
                  recovery.id == episode else { result = .retired; return }
            guard recovery.permitsRecovery(at: ContinuousClock.now) else { return }
            if videoAvailable, recovery.acceptsFrame(lastOutput: lastVideoAttempt, running: runningAttempt,
                                                     at: ContinuousClock.now) {
                completeCaptureRecoveryLocked()
                restoreCaptureInputLocked(display: display)
                result = .restored
            } else {
                captureRestartID = nil
                captureRestartTask = nil
                result = .awaitingFrame
            }
        }
        return result
    }

    /// Called with the peer lock held under capture admission.
    private func completeCaptureRecoveryLocked() {
        captureRecovery = nil
        captureRecoveryDeadlineTask?.cancel()
        captureRecoveryDeadlineTask = nil
        captureRestartID = nil
        captureRestartTask = nil
        log.info("screen capture produced a complete frame from its current running stream")
    }

    private func retireCaptureRestart(_ worker: UUID) {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard captureRestartID == worker else { return }
        captureRestartID = nil
        captureRestartTask = nil
    }

    /// Claim termination before leaving the lock. Close revokes direct input
    /// and media synchronously, while its returned barrier continues to join
    /// any native operation that has not returned. The watchdog never claims
    /// to have forcibly terminated ScreenCaptureKit.
    private func endCaptureRecovery(_ episode: UUID, worker: UUID? = nil, reason: String) {
        closeStateLock.lock()
        guard !ended, captureRecovery?.id == episode,
              worker == nil || captureRestartID == worker else { closeStateLock.unlock(); return }
        ended = true
        captureRecovery = nil
        closeStateLock.unlock()
        close(reason: reason)
        onEnded(reason)
    }

    private func endAfterCaptureBudget(_ episode: UUID, worker: UUID) {
        closeStateLock.lock()
        let failure = captureRecovery?.id == episode
            ? captureRecovery?.failure(at: ContinuousClock.now) : nil
        closeStateLock.unlock()
        guard let failure else { return }
        endCaptureRecovery(episode, worker: worker, reason: failure.message)
    }

    private func restartCaptureLoop(worker: UUID, episode: UUID) async {
        defer { retireCaptureRestart(worker) }
        while !Task.isCancelled && ownsCaptureRestart(worker, episode: episode) {
            guard reserveCaptureRestart(worker, episode: episode) else {
                endAfterCaptureBudget(episode, worker: worker)
                return
            }
            do {
                try await startCapture()
                switch settleCaptureRestart(worker, episode: episode) {
                case .restored, .awaitingFrame, .retired: return
                case .retry: break
                }
            } catch {
                guard !Task.isCancelled, ownsCaptureRestart(worker, episode: episode) else { return }
                if error is CaptureStreamTeardownFailure {
                    endCaptureRecovery(episode, worker: worker,
                        reason: "Screen capture cleanup failed. Restart the Mac host app before reconnecting.")
                    return
                }
                log.error("screen capture restart failed: \(String(describing: error), privacy: .public)")
            }
            guard let delay = captureRestartDelay(worker, episode: episode) else {
                endAfterCaptureBudget(episode, worker: worker)
                return
            }
            do { try await Task.sleep(for: delay) }
            catch { return }
        }
    }

    private func pushVideoFrame(_ captured: CapturedVideoFrame) {
        #if DEBUG
        if stage2Enabled {
            closeStateLock.lock()
            if !ended { stage2CaptureFrames &+= 1 }
            closeStateLock.unlock()
        }
        #endif
        if labInstrumentation && LatencyStatsCollector.enabled {
            let display = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(captured.metadata.displayTimeHostTicks))
            let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            if display.isFinite, now >= display {
                latencyStats.trace(["type": "capture", "time": now, "sampleAgeMs": (now - display) * 1000])
                #if DEBUG
                if let size = captured.latencyDisplaySize,
                   let marker = LatencyMarkerSampler.sample(pixelBuffer: captured.imageBuffer,
                       cropX: 0, cropY: 0, cropWidth: captured.metadata.width, cropHeight: captured.metadata.height,
                       screenWidth: Double(size.width), screenHeight: Double(size.height)), marker != lastCaptureMarker {
                    lastCaptureMarker = marker
                    latencyStats.trace(["type": "capture_marker", "marker_id": marker,
                                        "sampleDisplayTime": display, "pushTime": now])
                }
                #endif
            }
        }
        let imageBuffer = captured.imageBuffer
        let normalizedSize = CaptureSizing.normalized(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer))
        if normalizedSize.width != adaptedVideoWidth
            || normalizedSize.height != adaptedVideoHeight {
            videoSource.adaptOutputFormat(
                toWidth: Int32(normalizedSize.width),
                height: Int32(normalizedSize.height),
                fps: captureFrameRate)
            adaptedVideoWidth = normalizedSize.width
            adaptedVideoHeight = normalizedSize.height
            #if DEBUG
            if labInstrumentation && LatencyStatsCollector.enabled {
                latencyStats.recordCaptureSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
            }
            #endif
        }

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: imageBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0,
                                  timeStampNs: captured.metadata.captureTimeNanoseconds)
        videoSource.capturer(videoCapturer, didCapture: frame)
    }

    private func send(_ message: ControlMessage) {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard let dataChannel, dataChannel.readyState == .open else {
            return
        }
        hostSeq &+= 1
        let timestamp = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        let payload = messageData(for: message, seq: hostSeq, ts: timestamp)
        dataChannel.sendData(RTCDataBuffer(data: payload, isBinary: false))
    }

    private func messageData(for message: ControlMessage, seq: UInt32, ts: UInt64) -> Data {
        switch message {
        case .bye(let reason):
            return (try? JSONSerialization.data(withJSONObject: [
                "t": "bye",
                "s": seq,
                "ts": ts,
                "reason": reason,
            ])) ?? Data()
        default:
            return Data()
        }
    }

    private func sendInputUnavailable(_ scope: DirectInputAcknowledgement) -> Bool {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended, let dataChannel, dataChannel.readyState == .open,
              inputAuthorization.ownsChannel(ObjectIdentifier(dataChannel)) else { return false }
        hostSeq &+= 1
        let timestamp = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        let payload = HostMessageEncoder.inputUnavailable(scope, seq: hostSeq, ts: timestamp)
        return dataChannel.sendData(RTCDataBuffer(data: payload, isBinary: false))
    }

    #if DEBUG
    /// Bind the advertised lab capabilities to the same immutable host
    /// configuration that selected this peer's encoder and sender policy.
    static func pinLatencyCapabilities(_ data: Data, configuration: LatencyLabConfiguration) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var caps = object["caps"] as? [String: Any] else { return nil }
        for (key, value) in HostMessageEncoder.latencyCapabilities(configuration) { caps[key] = value }
        object["caps"] = caps
        return try? JSONSerialization.data(withJSONObject: object)
    }
    #endif

    #if DEBUG
    static func cursorCapabilityAllowed(requested: Bool, labInstrumentation: Bool,
                                        environment: [String: String]) -> Bool {
        requested && !(labInstrumentation && environment["CURSOR_CAPABILITY_OFF"] == "1")
    }
    #endif

    private func sendHelloAckAndDisplay() {
        closeStateLock.lock()
        guard !ended, let channel = dataChannel, channel.readyState == .open,
              let ready = inputAuthorization.readyAcknowledgement(for: ObjectIdentifier(channel)),
              let display = ready.session.display, let owner = captureOwner else {
            closeStateLock.unlock(); return
        }
        guard cursorRequested else {
            closeStateLock.unlock()
            _ = sendHelloAckAndDisplay(clientCursor: false)
            return
        }
        let epoch = cursorEpoch
        let previous = cursorTransition
        cursorTransition = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var enabled = false
            do {
                try await self.capture.setCursorVisible(false, for: owner)
                enabled = true
            } catch {
                // An unconfirmed hide must never result in an overlay-only cursor.
                try? await self.capture.setCursorVisible(true, for: owner)
            }
            self.closeStateLock.lock()
            let current = !self.ended && self.cursorRequested && self.cursorEpoch == epoch
                && self.dataChannel === channel && channel.readyState == .open
            self.closeStateLock.unlock()
            guard current else { return }
            let acknowledged = self.sendHelloAckAndDisplay(clientCursor: enabled, epoch: epoch)
            if !enabled {
                DispatchQueue.main.async { [weak self] in self?.stopCursorPublisher() }
            }
            if enabled && acknowledged {
                let bounds = CGRect(x: display.state.originX, y: display.state.originY,
                                    width: display.state.width, height: display.state.height)
                DispatchQueue.main.async { [weak self] in self?.startCursorPublisher(bounds: bounds, epoch: epoch) }
            }
        }
        closeStateLock.unlock()
    }

    @discardableResult
    private func sendHelloAckAndDisplay(clientCursor: Bool, epoch: UUID? = nil) -> Bool {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard epoch == nil || (cursorRequested && cursorEpoch == epoch) else { return false }
        guard !ended, let dataChannel, dataChannel.readyState == .open,
              let ready = inputAuthorization.readyAcknowledgement(for: ObjectIdentifier(dataChannel)) else {
            return false
        }
        guard let captureDisplay = ready.session.display else {
            inputAuthorization.close()
            scheduleCaptureTerminalFailure("The captured screen layout is unavailable. Reconnect to restore control.")
            return false
        }

        let timestamp = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        hostSeq &+= 1
        let encodedHello = HostMessageEncoder.helloAck(
            proto: HostConfig.protocolVersion,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            audio: audioEnabled,
            monitors: NSScreen.screens.count,
            seq: hostSeq,
            ts: timestamp,
            inputSession: ready.wire,
            inputInvalidation: ready.inputInvalidation,
            clientCursor: clientCursor)
        #if DEBUG
        guard let hello = Self.pinLatencyCapabilities(encodedHello, configuration: latencyCapabilities) else {
            inputAuthorization.close()
            scheduleCaptureTerminalFailure("The input handshake could not be sent. Reconnect to restore control.")
            return false
        }
        #else
        let hello = encodedHello
        #endif
        guard dataChannel.sendData(RTCDataBuffer(data: hello, isBinary: false)) else {
            inputAuthorization.close()
            scheduleCaptureTerminalFailure("The input handshake could not be sent. Reconnect to restore control.")
            return false
        }

        hostSeq &+= 1
        let display = HostMessageEncoder.display(
            captureDisplay,
            seq: hostSeq,
            ts: timestamp,
            inputSession: ready.wire)
        guard dataChannel.sendData(RTCDataBuffer(data: display, isBinary: false)) else {
            inputAuthorization.close()
            scheduleCaptureTerminalFailure("The screen layout could not be sent. Reconnect to restore control.")
            return false
        }
        return true
    }

    private func startCursorPublisher(bounds: CGRect, epoch: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        closeStateLock.lock()
        let current = !ended && cursorRequested && cursorEpoch == epoch
        closeStateLock.unlock()
        guard current else { return }
        if let cursorPublisher {
            cursorPublisher.updateDisplayBounds(bounds)
            return
        }
        let publisher = HostCursorPublisher(displayBounds: bounds) { [weak self] payload in
            guard let self else { return }
            self.closeStateLock.lock()
            defer { self.closeStateLock.unlock() }
            guard !self.ended, self.cursorEpoch == epoch, self.cursorRequested,
                  let channel = self.dataChannel, channel.readyState == .open,
                  self.inputAuthorization.ownsChannel(ObjectIdentifier(channel)) else { return }
            _ = channel.sendData(RTCDataBuffer(data: payload, isBinary: false))
        }
        #if DEBUG
        if labInstrumentation && LatencyStatsCollector.enabled &&
            ProcessInfo.processInfo.environment["CURSOR_DIAGNOSTICS"] == "1" {
            publisher.debugTrace = { [weak self] event, position, shape in
                guard let self else { return }
                var record: [String: Any] = ["type": "cursor", "event": event,
                                              "time": ProcessInfo.processInfo.systemUptime]
                if let position { record["x"] = position.x; record["y"] = position.y }
                if let shape { record["shape"] = shape }
                self.latencyStats.trace(record)
            }
        }
        #endif
        cursorPublisher = publisher
        publisher.start()
    }

    private func stopCursorPublisher() {
        dispatchPrecondition(condition: .onQueue(.main))
        cursorPublisher?.stop()
        cursorPublisher = nil
    }

    private func stopClientCursor() {
        closeStateLock.lock()
        cursorRequested = false
        cursorEpoch = UUID()
        let previous = cursorTransition
        let owner = captureOwner
        cursorTransition = Task { [weak self] in
            await previous?.value
            if let self, let owner { try? await self.capture.setCursorVisible(true, for: owner) }
        }
        closeStateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.stopCursorPublisher() }
    }

    private func invalidateChangedCaptureDisplay() {
        guard let (owner, _) = try? captureStartParameters() else { return }
        capture.invalidateChangedDisplay(for: owner)
    }

    private func iceCandidate(from payload: [String: String]) -> RTCIceCandidate? {
        guard let sdp = payload["candidate"] else {
            return nil
        }
        let sdpMid = payload["sdpMid"]
        let lineIndex = Int32(payload["sdpMLineIndex"] ?? "") ?? 0
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: sdpMid)
    }

    private func signalingPayload(for candidate: RTCIceCandidate) -> [String: String] {
        [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": "\(candidate.sdpMLineIndex)",
        ]
    }

    private func resetBufferedLocalICE() {
        signalingStateQueue.sync {
            answerSent = false
            pendingLocalICEPayloads.removeAll()
        }
    }

    private func flushBufferedLocalICEAfterAnswer() {
        let bufferedPayloads = signalingStateQueue.sync { () -> [[String: String]] in
            answerSent = true
            let payloads = pendingLocalICEPayloads
            pendingLocalICEPayloads.removeAll()
            return payloads
        }
        for payload in bufferedPayloads {
            sendLocalICE(payload)
        }
    }

    #if DEBUG
    private func candidateLifecycleLabels(_ sdp: String) -> (type: String, family: String) {
        let fields = sdp.prefix(2048).split(whereSeparator: \.isWhitespace)
        guard fields.count > 7, let index = fields.firstIndex(of: "typ"), index + 1 < fields.count else {
            return ("unknown", "unknown")
        }
        return (ICECandidateDiagnostics.kind(String(fields[index + 1])),
                ICECandidateDiagnostics.family(String(fields[4])))
    }

    private func logCandidateLifecycle(_ stage: String, sdp: String) {
        guard ProcessInfo.processInfo.environment["CONNECTIVITY_DIAGNOSTICS"] == "1" else { return }
        let labels = candidateLifecycleLabels(sdp)
        diagnosticLock.lock()
        candidateDiagnosticCount += 1
        let count = candidateDiagnosticCount
        diagnosticLock.unlock()
        log.notice("candidate_lifecycle=\(stage, privacy: .public) type=\(labels.type, privacy: .public) family=\(labels.family, privacy: .public) count=\(count, privacy: .public)")
    }
    #endif

    private func bufferOrSendLocalICE(_ payload: [String: String]) {
        #if DEBUG
        if let sdp = payload["candidate"] { logCandidateLifecycle("queued", sdp: sdp) }
        #endif
        let shouldSendImmediately = signalingStateQueue.sync { () -> Bool in
            guard answerSent else {
                pendingLocalICEPayloads.append(payload)
                return false
            }
            return true
        }
        guard shouldSendImmediately else {
            return
        }
        sendLocalICE(payload)
    }

    private func sendLocalICE(_ payload: [String: String]) {
        let signaling = self.signaling
        let log = self.log
        let taggedPayload = latencySignalingPayload(payload)
        Task {
            do {
                try await signaling.send(SignalingEnvelope(
                    role: .host,
                    kind: .ice,
                    payload: taggedPayload,
                    ts: Date().timeIntervalSince1970))
                #if DEBUG
                if let sdp = payload["candidate"] { self.logCandidateLifecycle("saved", sdp: sdp) }
                #endif
            } catch {
                #if DEBUG
                if let sdp = payload["candidate"] { self.logCandidateLifecycle("save_failed", sdp: sdp) }
                #endif
                log.error("failed to send local ICE candidate")
            }
        }
    }

    private func latencySignalingPayload(_ payload: [String: String]) -> [String: String] {
        #if DEBUG
        guard let latencyF1Nonce else { return payload }
        var tagged = payload
        tagged["latencyF1Restart"] = latencyF1Nonce
        return tagged
        #else
        return payload
        #endif
    }

    private func createAnswer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HostPeerSession",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Answer creation returned no SDP."]))
                }
            }
        }
    }

    private func setLocalDescription(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
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
        on peerConnection: RTCPeerConnection
    ) async throws {
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

    private func startAudioRecordingIfNeeded() {
        guard audioEnabled, !audioRecordingStarted else {
            return
        }
        let audioDeviceModule = factory.audioDeviceModule
        let prepareStatus = audioDeviceModule.setRecordingAlwaysPreparedMode(true)
        let muteStatus = audioDeviceModule.setMicrophoneMuted(true)
        let startStatus = audioDeviceModule.initAndStartRecording()
        log.info(
            "host audio ADM prepare=\(prepareStatus, privacy: .public) mute=\(muteStatus, privacy: .public) muted=\(audioDeviceModule.isMicrophoneMuted, privacy: .public) start=\(startStatus, privacy: .public) recordingInit=\(audioDeviceModule.isRecordingInitialized, privacy: .public) recording=\(audioDeviceModule.isRecording, privacy: .public) engineRunning=\(audioDeviceModule.isEngineRunning, privacy: .public)")
        audioRecordingStarted = startStatus == 0
    }

    private func stopAudioRecording() {
        guard audioRecordingStarted else {
            return
        }
        let stopStatus = factory.audioDeviceModule.stopRecording()
        log.info("host audio ADM stop=\(stopStatus, privacy: .public)")
        audioRecordingStarted = false
    }
}

extension HostPeerSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.notice("ICE connection_state=\(String(describing: newState), privacy: .public)")
        Self.handlePortMappingICEState(newState, session: portMappingSession)
        if newState == .connected || newState == .completed { logSelectedPair(peerConnection) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        diagnosticLock.lock()
        let summary = diagnosticLocal.summary
        let global = diagnosticLocal.globalIPv6Host
        diagnosticLock.unlock()
        log.notice("ICE local={\(summary, privacy: .public)} global_ipv6_host=\(global, privacy: .public)")
    }

    private func logSelectedPair(_ peer: RTCPeerConnection) {
        peer.statistics { [log] report in
            guard let id = report.statistics.values.first(where: { $0.type == "transport" })?.values["selectedCandidatePairId"] as? String,
                  let pair = report.statistics[id],
                  let localID = pair.values["localCandidateId"] as? String,
                  let remoteID = pair.values["remoteCandidateId"] as? String,
                  let local = report.statistics[localID], let remote = report.statistics[remoteID] else { return }
            let lt = ICECandidateDiagnostics.kind(local.values["candidateType"] as? String)
            let rt = ICECandidateDiagnostics.kind(remote.values["candidateType"] as? String)
            let lf = ICECandidateDiagnostics.family(local.values["address"] as? String ?? local.values["ip"] as? String ?? "")
            let rf = ICECandidateDiagnostics.family(remote.values["address"] as? String ?? remote.values["ip"] as? String ?? "")
            let proto = ICECandidateDiagnostics.transport(local.values["protocol"] as? String)
            log.notice("ICE selected local=\(lt, privacy: .public)/\(lf, privacy: .public) remote=\(rt, privacy: .public)/\(rf, privacy: .public) protocol=\(proto, privacy: .public)")
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        diagnosticLock.lock()
        diagnosticLocal.record(candidate.sdp)
        #if DEBUG
        if capacityProbeEnabled, capacityLANAddress == nil,
           let mapping = HostMappingCandidate(sdp: candidate.sdp, mid: candidate.sdpMid, lineIndex: candidate.sdpMLineIndex) {
            capacityLANAddress = mapping.lanAddress
        }
        #endif
        diagnosticLock.unlock()
        bufferOrSendLocalICE(signalingPayload(for: candidate))
        portMappingSession?.gather(sdp: candidate.sdp, mid: candidate.sdpMid, lineIndex: candidate.sdpMLineIndex)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCConnectionState) {
        log.info("peer connection state → \(String(describing: stateChanged), privacy: .public)")
        guard !isEnded, self.peerConnection === peerConnection else { return }
        switch stateChanged {
        case .connected:
            #if DEBUG
            if latencyF3Enabled && !stage2Enabled {
                peerConnection.statistics { [weak self, weak peerConnection] report in
                    guard let self, let peerConnection else { return }
                    self.applyLatencySenderPolicy(report.statistics.values.map {
                        LatencyStatsReport(id: $0.id, type: $0.type, values: $0.values)
                    }, connection: peerConnection, sampledAt: ProcessInfo.processInfo.systemUptime, capturedFrames: 0,
                       reportTimestampUs: report.timestamp_us, reportTimes: [:])
                }
            }
            #endif
            inputAuthorization.connectionChanged(connected: true)
            // Hello and the transport-state callback can arrive in either
            // order. Publish readiness only once both have authorized input.
            sendHelloAckAndDisplay()
        case .disconnected:
            // ICE may recover, but queued input loses this exact session now.
            if inputAuthorization.connectionChanged(connected: false), inputAuthorization.isClosed {
                onEnded("The connection was interrupted. Reconnect to resume remote control.")
            }
            log.warning("peer connection is disconnected (may recover)")
        case .failed, .closed:
            if inputAuthorization.connectionChanged(connected: false, terminal: true) {
                onEnded("The peer connection closed.")
            }
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        closeStateLock.lock()
        defer { closeStateLock.unlock() }
        guard !ended, self.peerConnection === peerConnection, dataChannel.label == "control",
              inputAuthorization.openChannel(ObjectIdentifier(dataChannel)) else {
            dataChannel.close()
            return
        }
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }
}

extension HostPeerSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed || dataChannel.readyState == .closing {
            closeStateLock.lock()
            let isCurrentChannel = self.dataChannel === dataChannel
            closeStateLock.unlock()
            guard isCurrentChannel else { return }
            inputAuthorization.closeChannel(ObjectIdentifier(dataChannel))
            #if DEBUG
            closeStateLock.lock(); let capacity = capacitySender; closeStateLock.unlock()
            capacity?.stop()
            #endif
            stopClientCursor()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        #if DEBUG
        let receiveTime = labInstrumentation && LatencyStatsCollector.enabled ? ProcessInfo.processInfo.systemUptime : nil
        #endif
        guard inputAuthorization.ownsChannel(ObjectIdentifier(dataChannel)), dataChannel.readyState == .open else { return }
        #if DEBUG
        if labInstrumentation, inputAuthorization.inputSession(for: ObjectIdentifier(dataChannel)) != nil,
           let object = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any],
           object["type"] as? String == "latencyF1RestartRequest" {
            guard let nonce = object["nonce"] as? String, nonce.count == 36,
                  UUID(uuidString: nonce) != nil, let onLatencyF1RestartRequest else { return }
            onLatencyF1RestartRequest(nonce) { [weak self, weak dataChannel] in
                guard let self, let dataChannel, !self.isEnded,
                      self.dataChannel === dataChannel, dataChannel.readyState == .open,
                      self.inputAuthorization.ownsChannel(ObjectIdentifier(dataChannel)),
                      self.inputAuthorization.inputSession(for: ObjectIdentifier(dataChannel)) != nil,
                      let data = try? JSONSerialization.data(withJSONObject: [
                        "type": "latencyF1RestartReady", "nonce": nonce]) else { return }
                _ = dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
            }
            return
        }
        if consumeCapacityMessage(buffer.data, channel: dataChannel) { return }
        if let receiveTime,
           inputAuthorization.inputSession(for: ObjectIdentifier(dataChannel)) != nil,
           let object = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any],
           object["type"] as? String == "latencyPing",
           let id = object["id"] as? Int, let t0 = object["t0"] as? Double, t0.isFinite {
            let pong: [String: Any] = ["type": "latencyPong", "id": id, "t0": t0,
                                      "t1": receiveTime, "t2": ProcessInfo.processInfo.systemUptime]
            if let data = try? JSONSerialization.data(withJSONObject: pong) {
                dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
            }
            return
        }
        #endif
        guard let packet = ControlPacket.decode(buffer.data) else {
            return
        }
        let message = packet.message
        switch message {
        case .hello(let proto, let orderedComputerUseControls):
            invalidateChangedCaptureDisplay()
            guard proto == HostConfig.protocolVersion else {
                if inputAuthorization.close(ifChannel: ObjectIdentifier(dataChannel)) {
                    close(reason: "protocol")
                    onEnded("protocol")
                }
                return
            }
            guard inputAuthorization.acceptHello(channel: ObjectIdentifier(dataChannel),
                orderedControls: orderedComputerUseControls, inputHello: packet.inputHello,
                inputInvalidation: packet.inputInvalidation) else { return }
            #if DEBUG
            let wantsCursor = Self.cursorCapabilityAllowed(requested: packet.clientCursor,
                labInstrumentation: labInstrumentation, environment: ProcessInfo.processInfo.environment)
            #else
            let wantsCursor = packet.clientCursor
            #endif
            if !wantsCursor { stopClientCursor() }
            closeStateLock.lock()
            if wantsCursor && !cursorRequested { cursorEpoch = UUID() }
            cursorRequested = wantsCursor
            closeStateLock.unlock()
            sendHelloAckAndDisplay()
        case .bye(let reason):
            if inputAuthorization.close(ifChannel: ObjectIdentifier(dataChannel)) {
                close(reason: reason)
                onEnded(reason)
            }
        case .pointer, .scroll, .key, .text:
            invalidateChangedCaptureDisplay()
            guard let session = inputAuthorization.admitInput(channel: ObjectIdentifier(dataChannel), stamp: packet.inputStamp),
                  Self.acceptsDirectInput(message, helloAuthenticated: true) else {
                log.warning("dropping remote input without a current authorized input session")
                return
            }
            if case let .pointer(x, y, _) = message {
                DispatchQueue.main.async { [weak self] in
                    self?.cursorPublisher?.recordClientPosition(CGPoint(x: x, y: y))
                }
            }
            #if DEBUG
            let clientTime = labInstrumentation && LatencyStatsCollector.enabled ? ((try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any])?["ts"] as? NSNumber : nil
            let onPost: ((TimeInterval) -> Void)? = clientTime.flatMap { timestamp in
                guard let receiveTime else { return nil }
                return { [latencyStats] postTime in
                    latencyStats.trace(["type": "input", "receiveTime": receiveTime,
                                        "postTime": postTime, "clientTime": timestamp.doubleValue / 1_000_000])
                }
            }
            #else
            let onPost: ((TimeInterval) -> Void)? = nil
            #endif
            let applied = injector.applyDirectInput(message, session: session, onPost: onPost, interruptAutomation: onUserInput)
            if !applied {
                if let display = injector.takeDisplayInvalidation(for: session),
                   let (owner, _) = try? captureStartParameters() {
                    // Preserve a layout loss observed at posting even if the
                    // display has already returned to its previous bounds.
                    capture.invalidateDisplay(for: owner, matching: display)
                }
            }
        case let .qos(targetFps, maxBitrateKbps, prefer):
            guard inputAuthorization.inputSession(for: ObjectIdentifier(dataChannel)) != nil else {
                log.warning("dropping video quality request received before authenticated hello")
                return
            }
            applyVideoSenderPolicy(DesktopVideoQuality.senderPolicy(
                targetFramesPerSecond: targetFps,
                maximumBitrateKbps: maxBitrateKbps,
                preference: prefer, maximumFramesPerSecond: Int(captureFrameRate)), requestedFrameRate: targetFps)
        }
    }
}
