import Foundation
import os
import UIKit

/// Transitional transport used before the full WebRTC transport lands.
/// It performs a real round-trip through the signaling channel so pairing
/// codes are validated against a live host instead of always "working".
@MainActor
final class SignalingPreflightTransport: Transport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "preflight")
    private let deviceName: () -> String
    private let handshakeTimeout: Duration
    private let signalingFactory: (String, String?) -> any SignalingChannel
    private var signaling: (any SignalingChannel)?
    private var pollTask: Task<Void, Never>?

    init(
        deviceName: (() -> String)? = nil,
        handshakeTimeout: Duration = .seconds(10),
        signalingFactory: ((String, String?) -> any SignalingChannel)? = nil
    ) {
        self.deviceName = deviceName ?? { UIDevice.current.name }
        self.handshakeTimeout = handshakeTimeout
        self.signalingFactory = signalingFactory ?? { code, expectedHostID in
            CloudKitSignalingClient(
                containerIdentifier: Config.cloudKitContainerIdentifier,
                code: code,
                role: .client,
                expectedTargetID: expectedHostID)
        }
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        let signaling = signalingFactory(pairingCode, expectedHostID)
        self.signaling = signaling

        try await signaling.claim()

        let offer = SignalingEnvelope(
            role: .client,
            kind: .offer,
            payload: [
                "client": deviceName(),
                "proto": "\(Config.protocolVersion)",
                "phase": "preflight",
            ],
            ts: Date().timeIntervalSince1970)
        try await signaling.send(offer)
        log.info("preflight offer sent")

        let answer = try await waitForAnswer()
        onHostHello?(hostHello(from: answer.payload))
        if let display = displayInfo(from: answer.payload) {
            onDisplay?(display)
        }

        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            await self?.pollLoop()
        }
    }

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        log.debug("dropping control message until WebRTC is wired seq=\(seq) ts=\(ts) \(String(describing: message), privacy: .public)")
    }

    func disconnect(reason: String) {
        pollTask?.cancel()
        pollTask = nil
        Task { @MainActor [weak self] in
            guard let self, let signaling = self.signaling else { return }
            defer { self.signaling = nil }
            let bye = SignalingEnvelope(
                role: .client,
                kind: .bye,
                payload: ["reason": reason],
                ts: Date().timeIntervalSince1970)
            try? await signaling.send(bye)
            if let cloudKit = signaling as? CloudKitSignalingClient {
                await cloudKit.cleanup()
            }
        }
    }

    private func waitForAnswer() async throws -> SignalingEnvelope {
        let deadline = ContinuousClock.now + handshakeTimeout
        while ContinuousClock.now < deadline {
            guard let signaling else {
                throw TransportError.disconnected("Session no longer active.")
            }

            let envelopes = try await signaling.poll()
            for envelope in envelopes {
                switch envelope.kind {
                case .answer:
                    return envelope
                case .bye:
                    throw TransportError.disconnected(
                        envelope.payload["reason"] ?? "The host ended the session.")
                case .offer, .ice:
                    continue
                }
            }
            // Throttle between polls: CloudKit is short-poll, not long-poll.
            try? await Task.sleep(for: .seconds(1))
        }

        throw TransportError.negotiationFailed(
            "No reply from your computer. Make sure it's awake and signed into the same iCloud account as this device.")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            guard let signaling else { return }

            do {
                let envelopes = try await signaling.poll()
                for envelope in envelopes {
                    switch envelope.kind {
                    case .bye:
                        onDisconnect?(envelope.payload["reason"] ?? "Disconnected")
                        return
                    case .answer, .offer, .ice:
                        continue
                    }
                }
            } catch {
                if Task.isCancelled { return }
                onDisconnect?("The signaling connection was lost.")
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func hostHello(from payload: [String: String]) -> HostHello {
        HostHello(
            app: payload["app"] ?? "RemoteDesktop-Host",
            version: payload["version"] ?? "0.1.0",
            hostname: payload["host"] ?? "Mac",
            os: payload["os"] ?? "macOS",
            audio: payload["audio"] == "true",
            monitors: Int(payload["monitors"] ?? "") ?? 1,
            orderedComputerUseControls: Int(
                payload["orderedComputerUseControls"] ?? "") ?? 0)
    }

    private func displayInfo(from payload: [String: String]) -> DisplayInfo? {
        guard let w = Int(payload["displayWidth"] ?? ""),
              let h = Int(payload["displayHeight"] ?? "") else {
            return nil
        }
        return DisplayInfo(
            w: w,
            h: h,
            scale: Double(payload["displayScale"] ?? "") ?? 2.0)
    }
}
