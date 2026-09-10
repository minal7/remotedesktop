import AppKit
import CoreMedia
import Foundation
import LiveKitWebRTC
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

    init(injector: InputInjector, onChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.injector = injector; self.onChange = onChange
    }

    @discardableResult
    func openChannel(_ id: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if let channelID { return channelID == id }
            channelID = id; helloCapabilities = nil
            inputHello = nil; acknowledgement = nil; inputGeneration = 0; lastInputSequence = 0
            return true
        }
    }

    @discardableResult
    func acceptHello(channel id: ObjectIdentifier, orderedControls: Int,
                     inputHello nextHello: DirectInputHello? = nil) -> Bool {
        lock.withLock {
            guard !closed, channelID == id else { return false }
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

    func readyAcknowledgement(for id: ObjectIdentifier) -> (session: InputInjector.DirectInputSession, wire: DirectInputAcknowledgement?)? {
        lock.withLock {
            guard !closed, channelID == id, let session else { return nil }
            return (session, acknowledgement)
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
        if !closed, connected, channelID != nil, helloCapabilities != nil {
            if session == nil {
                guard inputGeneration < UInt32.max else {
                    closed = true; connected = false; channelID = nil; helloCapabilities = nil
                    publishLocked(); return
                }
                inputGeneration += 1
                session = injector.beginDirectInputSession()
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
    private let onUserInput: @Sendable () -> Bool
    private let inputAuthorization: HostPeerInputAuthorization
    private let onEnded: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "webrtc")
    private let signalingStateQueue = DispatchQueue(label: "com.threadmark.remotedesktop.host.webrtc.signaling")
    private let closeStateLock = NSLock()

    private let factory: RTCPeerConnectionFactory
    private let audioBridge: SystemAudioBridge
    private let audioSource: RTCAudioSource
    private let audioTrack: RTCAudioTrack
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let videoCapturer: RTCVideoCapturer

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var videoSender: RTCRtpSender?
    private var adaptedVideoWidth: Int?
    private var adaptedVideoHeight: Int?
    private var captureMaximumMacroblocksPerFrame =
        DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame
    private var captureStarted = false
    private var audioRecordingStarted = false
    private var localMediaConfigured = false
    private var ended = false
    private var captureRestartTask: Task<Void, Never>?
    private var captureTeardownTask: Task<Void, Never>?
    private var hostSeq: UInt32 = 0
    private var answerSent = false
    private var pendingLocalICEPayloads: [[String: String]] = []
    private let captureRestartBackoff: [Duration] = [
        .milliseconds(250),
        .seconds(1),
        .seconds(2),
        .seconds(5),
        .seconds(10),
    ]

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
        onUserInput: @escaping @Sendable () -> Bool,
        onPeerAuthorizationChanged:
            @escaping @Sendable (PeerAuthorization) -> Void,
        onEnded: @escaping @Sendable (String) -> Void
    ) {
        RTCInitializeSSL()
        self.signaling = signaling
        self.capture = capture
        self.injector = injector
        self.iceConfig = iceConfig
        self.audioEnabled = audioEnabled
        self.onUserInput = onUserInput
        self.inputAuthorization = HostPeerInputAuthorization(injector: injector) { state in
            onPeerAuthorizationChanged(PeerAuthorization(senderID: peerSenderID,
                authorized: state.authorized, orderedComputerUseControls: state.orderedComputerUseControls))
        }
        self.onEnded = onEnded
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: true,
            encoderFactory: DesktopVideoEncoderFactory(),
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
        log.info("host audio ADM voiceProcessingEnabled=false status=\(voiceProcessingStatus, privacy: .public)")
        if audioEnabled {
            audioBridge.attach(to: factory.audioDeviceModule)
        }
        configureCaptureCallbacks()
    }

    func acceptOffer(sdp: String) async throws {
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
        captureMaximumMacroblocksPerFrame = DesktopVideoQuality
            .maximumMacroblocksPerFrame(
                negotiatedCodecs: videoSender?.parameters.codecs ?? [])
        applyVideoSenderPolicy(DesktopVideoQuality.sharpnessPolicy)
        startAudioRecordingIfNeeded()
        try await signaling.send(SignalingEnvelope(
            role: .host,
            kind: .answer,
            payload: [
                "sdp": answer.sdp,
                "sdpType": "answer",
            ],
            ts: Date().timeIntervalSince1970))
        flushBufferedLocalICEAfterAnswer()

        if !captureStarted {
            try await startCapture()
        }
    }

    func addRemoteIce(_ payload: [String: String]) {
        guard let peerConnection,
              let candidate = iceCandidate(from: payload) else {
            return
        }
        peerConnection.add(candidate) { [log] error in
            if let error {
                log.error("failed to add remote ICE candidate: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Synchronously revokes input/media ownership and returns the exact screen
    /// capture teardown barrier. A replacement peer must await the returned
    /// task before installing new capture callbacks on the shared capturer.
    @discardableResult
    func close(reason: String) -> Task<Void, Never> {
        closeStateLock.lock()
        if let captureTeardownTask {
            closeStateLock.unlock()
            return captureTeardownTask
        }
        ended = true
        inputAuthorization.close()
        captureRestartTask?.cancel()
        captureRestartTask = nil
        resetBufferedLocalICE()
        send(.bye(reason: reason))
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        videoSender = nil
        adaptedVideoWidth = nil
        adaptedVideoHeight = nil
        if audioEnabled {
            audioBridge.detach(from: factory.audioDeviceModule)
        }
        stopAudioRecording()
        // Clear capture callbacks before stopping to prevent the
        // delegate's didStopWithError from re-firing onEnded.
        capture.onStopped = nil
        capture.onVideoSample = nil
        capture.onAudioSample = nil
        let teardown = Task {
            await capture.stop()
        }
        captureTeardownTask = teardown
        captureStarted = false
        localMediaConfigured = false
        closeStateLock.unlock()
        return teardown
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
        capture.onVideoSample = { [weak self] sampleBuffer in
            self?.pushVideoSample(sampleBuffer)
        }
        if audioEnabled {
            capture.onAudioSample = { [weak self] sampleBuffer in
                self?.audioBridge.enqueue(sampleBuffer)
            }
        } else {
            capture.onAudioSample = nil
        }
        capture.onStopped = { [weak self] error in
            guard let self, !self.ended else { return }
            self.handleCaptureStopped(error)
        }
    }

    private func startCapture() async throws {
        try await capture.start(
            audioEnabled: audioEnabled,
            maximumMacroblocksPerFrame: captureMaximumMacroblocksPerFrame)
        captureStarted = true
    }

    private func applyVideoSenderPolicy(
        _ policy: DesktopVideoQuality.SenderPolicy
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
        for encoding in encodings {
            encoding.maxBitrateBps = NSNumber(value: policy.maximumBitrateBps)
            encoding.maxFramerate = NSNumber(value: policy.maximumFramesPerSecond)
            encoding.scaleResolutionDownBy = 1
        }
        parameters.encodings = encodings
        parameters.degradationPreference = NSNumber(
            value: policy.degradationPreference.rawValue)
        videoSender.parameters = parameters

        let bweUpdated = peerConnection?.setBweMinBitrateBps(
            nil,
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: policy.maximumBitrateBps)) ?? false
        log.info(
            "desktop video quality captureMacroblocks=\(self.captureMaximumMacroblocksPerFrame, privacy: .public) maxBitrate=\(policy.maximumBitrateBps, privacy: .public) maxFps=\(policy.maximumFramesPerSecond, privacy: .public) degradation=\(policy.degradationPreference.rawValue, privacy: .public) bweUpdated=\(bweUpdated, privacy: .public)")
    }

    private func handleCaptureStopped(_ error: Error?) {
        captureStarted = false
        guard let error else {
            log.error("screen capture stopped without an error")
            onEnded("Screen capture stopped.")
            return
        }

        guard ScreenCapture.isSystemStopped(error) else {
            log.error("screen capture stopped: \(String(describing: error), privacy: .public)")
            onEnded("Screen capture stopped.")
            return
        }

        restartCaptureAfterSystemStop(error)
    }

    private func restartCaptureAfterSystemStop(_ error: Error) {
        guard captureRestartTask == nil else {
            log.info("screen capture restart already pending")
            return
        }

        log.warning("screen capture was stopped by the system; attempting in-place restart: \(String(describing: error), privacy: .public)")
        captureRestartTask = Task { [weak self] in
            await self?.restartCaptureLoop()
        }
    }

    private func restartCaptureLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            guard !ended else { return }
            do {
                try await startCapture()
                log.info("screen capture restarted after system stop")
                captureRestartTask = nil
                return
            } catch {
                attempt += 1
                captureStarted = false
                log.error("screen capture restart attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                let delay = captureRestartBackoff[min(attempt - 1, captureRestartBackoff.count - 1)]
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func pushVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let normalizedSize = CaptureSizing.normalized(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer))
        if normalizedSize.width != adaptedVideoWidth
            || normalizedSize.height != adaptedVideoHeight {
            videoSource.adaptOutputFormat(
                toWidth: Int32(normalizedSize.width),
                height: Int32(normalizedSize.height),
                fps: CaptureSizing.targetFramesPerSecond)
            adaptedVideoWidth = normalizedSize.width
            adaptedVideoHeight = normalizedSize.height
        }

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: imageBuffer)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampNs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
        videoSource.capturer(videoCapturer, didCapture: frame)
    }

    private func send(_ message: ControlMessage) {
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

    private func sendHelloAckAndDisplay() {
        guard let dataChannel, dataChannel.readyState == .open,
              let ready = inputAuthorization.readyAcknowledgement(for: ObjectIdentifier(dataChannel)) else {
            return
        }

        let timestamp = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        hostSeq &+= 1
        let hello = HostMessageEncoder.helloAck(
            proto: HostConfig.protocolVersion,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            audio: audioEnabled,
            monitors: NSScreen.screens.count,
            seq: hostSeq,
            ts: timestamp,
            inputSession: ready.wire)
        guard dataChannel.sendData(RTCDataBuffer(data: hello, isBinary: false)) else {
            inputAuthorization.close()
            onEnded("The input handshake could not be sent.")
            return
        }

        let frame = NSScreen.main?.frame ?? .zero
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        hostSeq &+= 1
        let display = HostMessageEncoder.display(
            width: Int(frame.width.rounded()),
            height: Int(frame.height.rounded()),
            scale: scale,
            seq: hostSeq,
            ts: timestamp,
            inputSession: ready.wire)
        dataChannel.sendData(RTCDataBuffer(data: display, isBinary: false))
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

    private func bufferOrSendLocalICE(_ payload: [String: String]) {
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
        Task {
            do {
                try await signaling.send(SignalingEnvelope(
                    role: .host,
                    kind: .ice,
                    payload: payload,
                    ts: Date().timeIntervalSince1970))
            } catch {
                log.error("failed to send local ICE candidate: \(String(describing: error), privacy: .public)")
            }
        }
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
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        bufferOrSendLocalICE(signalingPayload(for: candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCConnectionState) {
        log.info("peer connection state → \(String(describing: stateChanged), privacy: .public)")
        guard !ended, self.peerConnection === peerConnection else { return }
        switch stateChanged {
        case .connected:
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
        guard self.peerConnection === peerConnection, dataChannel.label == "control",
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
            inputAuthorization.closeChannel(ObjectIdentifier(dataChannel))
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard inputAuthorization.ownsChannel(ObjectIdentifier(dataChannel)),
              dataChannel.readyState == .open,
              let packet = ControlPacket.decode(buffer.data) else {
            return
        }
        let message = packet.message
        switch message {
        case .hello(let proto, let orderedComputerUseControls):
            guard proto == HostConfig.protocolVersion else {
                if inputAuthorization.close(ifChannel: ObjectIdentifier(dataChannel)) {
                    close(reason: "protocol")
                    onEnded("protocol")
                }
                return
            }
            guard inputAuthorization.acceptHello(channel: ObjectIdentifier(dataChannel),
                orderedControls: orderedComputerUseControls, inputHello: packet.inputHello) else { return }
            sendHelloAckAndDisplay()
        case .bye(let reason):
            if inputAuthorization.close(ifChannel: ObjectIdentifier(dataChannel)) {
                close(reason: reason)
                onEnded(reason)
            }
        case .pointer, .scroll, .key, .text:
            guard let session = inputAuthorization.admitInput(channel: ObjectIdentifier(dataChannel), stamp: packet.inputStamp),
                  Self.acceptsDirectInput(message, helloAuthenticated: true) else {
                log.warning("dropping remote input without a current authorized input session")
                return
            }
            injector.applyDirectInput(message, session: session, interruptAutomation: onUserInput)
        case let .qos(targetFps, maxBitrateKbps, prefer):
            guard inputAuthorization.inputSession(for: ObjectIdentifier(dataChannel)) != nil else {
                log.warning("dropping video quality request received before authenticated hello")
                return
            }
            applyVideoSenderPolicy(DesktopVideoQuality.senderPolicy(
                targetFramesPerSecond: targetFps,
                maximumBitrateKbps: maxBitrateKbps,
                preference: prefer))
        }
    }
}
