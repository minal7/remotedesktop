import AppKit
import AVFoundation
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

final class HostPeerSession: NSObject {
    private let signaling: any SignalingChannel
    private let capture: ScreenCapture
    private let injector: InputInjector
    private let iceConfig: ICEConfig
    private let onEnded: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "webrtc")

    private let factory: RTCPeerConnectionFactory
    private let audioBridge: SystemAudioBridge
    private let audioSource: RTCAudioSource
    private let audioTrack: RTCAudioTrack
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let videoCapturer: RTCVideoCapturer
    private let signalingStateQueue = DispatchQueue(label: "com.threadmark.remotedesktop.host.webrtc.signaling")

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var captureStarted = false
    private var audioRecordingStarted = false
    private var hostSeq: UInt32 = 0
    private var answerSent = false
    private var pendingLocalICEPayloads: [[String: String]] = []

    init(
        signaling: any SignalingChannel,
        capture: ScreenCapture,
        injector: InputInjector,
        iceConfig: ICEConfig,
        onEnded: @escaping @Sendable (String) -> Void
    ) {
        RTCInitializeSSL()
        self.signaling = signaling
        self.capture = capture
        self.injector = injector
        self.iceConfig = iceConfig
        self.onEnded = onEnded
        self.factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: true,
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioProcessingModule: nil)
        // The host never forwards microphone audio, but the LiveKit/WebRTC
        // audio-engine bridge still needs the recording path available so the
        // local audio track can consume the ScreenCaptureKit system-audio feed
        // injected by SystemAudioBridge. Keep output available too so the ADM
        // builds the full engine graph expected by the delegate callbacks.
        _ = factory.audioDeviceModule.setEngineAvailability(
            RTCAudioEngineAvailability(
                isInputAvailable: ObjCBool(HostConfig.enableSystemAudio),
                isOutputAvailable: true))
        self.audioBridge = SystemAudioBridge()
        self.audioSource = factory.audioSource(with: nil)
        self.audioTrack = factory.audioTrack(with: audioSource, trackId: "system-audio")
        self.videoSource = factory.videoSource()
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: "screen")
        self.videoCapturer = RTCVideoCapturer(delegate: videoSource)
        super.init()
        audioBridge.attach(to: factory.audioDeviceModule)
        configureCaptureCallbacks()
    }

    func acceptOffer(sdp: String) async throws {
        resetBufferedLocalICE()
        if peerConnection == nil {
            peerConnection = try makePeerConnection()
            if HostConfig.enableSystemAudio {
                _ = peerConnection?.add(audioTrack, streamIds: ["system"])
            }
            _ = peerConnection?.add(videoTrack, streamIds: ["screen"])
        }

        guard let peerConnection else { return }
        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        try await setRemoteDescription(remote, on: peerConnection)
        let answer = try await createAnswer(on: peerConnection)
        try await setLocalDescription(answer, on: peerConnection)
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
            try await capture.start()
            captureStarted = true
        }
    }

    func addRemoteIce(_ payload: [String: String]) {
        guard let peerConnection,
              let candidate = iceCandidate(from: payload) else { return }
        peerConnection.add(candidate) { [log] error in
            if let error {
                log.error("failed to add remote ICE candidate: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func close(reason: String) {
        resetBufferedLocalICE()
        send(.bye(reason: reason))
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        audioBridge.detach(from: factory.audioDeviceModule)
        stopAudioRecording()
        Task {
            await capture.stop()
        }
        captureStarted = false
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceServers = iceConfig.iceServers

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

        guard let peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self) else {
            throw NSError(domain: "HostPeerSession", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create the peer connection."
            ])
        }
        return peerConnection
    }

    private func configureCaptureCallbacks() {
        capture.onVideoSample = { [weak self] sampleBuffer in
            self?.pushVideoSample(sampleBuffer)
        }
        if HostConfig.enableSystemAudio {
            capture.onAudioSample = { [weak self] sampleBuffer in
                self?.audioBridge.enqueue(sampleBuffer)
            }
        } else {
            capture.onAudioSample = nil
        }
        capture.onStopped = { [weak self] error in
            self?.log.error("screen capture stopped: \(String(describing: error), privacy: .public)")
            self?.onEnded("Screen capture stopped.")
        }
    }

    private func pushVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let normalizedSize = CaptureSizing.normalized(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer))
        let width = Int32(normalizedSize.width)
        let height = Int32(normalizedSize.height)
        videoSource.adaptOutputFormat(toWidth: width, height: height, fps: 60)

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: imageBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeNs = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timeNs)
        videoSource.capturer(videoCapturer, didCapture: frame)
    }

    private func send(_ message: ControlMessage) {
        guard let dataChannel, dataChannel.readyState == .open else { return }
        hostSeq &+= 1
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        let buffer = RTCDataBuffer(data: messageData(for: message, seq: hostSeq, ts: ts), isBinary: false)
        dataChannel.sendData(buffer)
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
        guard let dataChannel, dataChannel.readyState == .open else { return }
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        hostSeq &+= 1
        let hello = HostMessageEncoder.helloAck(
            proto: HostConfig.protocolVersion,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            audio: HostConfig.enableSystemAudio,
            monitors: NSScreen.screens.count,
            seq: hostSeq,
            ts: ts)
        dataChannel.sendData(RTCDataBuffer(data: hello, isBinary: false))

        let frame = NSScreen.main?.frame ?? .zero
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        hostSeq &+= 1
        let display = HostMessageEncoder.display(
            width: Int(frame.width.rounded()),
            height: Int(frame.height.rounded()),
            scale: scale,
            seq: hostSeq,
            ts: ts)
        dataChannel.sendData(RTCDataBuffer(data: display, isBinary: false))
    }

    private func iceCandidate(from payload: [String: String]) -> RTCIceCandidate? {
        guard let sdp = payload["candidate"] else { return nil }
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
        guard shouldSendImmediately else { return }
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
        // No legacy OfferToReceive constraints — under Unified Plan the
        // transceiver directions (sendonly for host audio/video, recvonly on
        // the client) negotiate correctly on their own. Setting
        // OfferToReceiveAudio:"false" would mark the audio m-line as
        // `inactive` in the answer SDP, killing the audio stream entirely.
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HostPeerSession",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Answer creation returned no SDP."]))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
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

    private func setRemoteDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
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
        guard HostConfig.enableSystemAudio, !audioRecordingStarted else { return }
        let adm = factory.audioDeviceModule
        let prepareStatus = adm.setRecordingAlwaysPreparedMode(true)
        // Do NOT mute the microphone: the WebRTC ADM treats this as "zero the
        // recording tap", which silences the frames our SystemAudioBridge is
        // injecting. The bridge already disconnects the real mic input, so
        // there is no user voice to worry about leaking.
        _ = adm.setMicrophoneMuted(false)
        let startStatus = adm.initAndStartRecording()
        log.info(
            "host audio ADM prepare=\(prepareStatus, privacy: .public) start=\(startStatus, privacy: .public) recordingInit=\(adm.isRecordingInitialized, privacy: .public) recording=\(adm.isRecording, privacy: .public) engineRunning=\(adm.isEngineRunning, privacy: .public)")
        audioRecordingStarted = startStatus == 0
    }

    private func stopAudioRecording() {
        guard audioRecordingStarted else { return }
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
        if stateChanged == .failed || stateChanged == .disconnected || stateChanged == .closed {
            onEnded("The peer connection closed.")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }
}

extension HostPeerSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = ControlMessage.decode(buffer.data) else { return }
        switch message {
        case .hello(let proto):
            guard proto == HostConfig.protocolVersion else {
                close(reason: "protocol")
                return
            }
            sendHelloAckAndDisplay()
        case .bye(let reason):
            close(reason: reason)
            onEnded(reason)
        default:
            injector.apply(message)
        }
    }
}
