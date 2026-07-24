import Foundation
import LiveKitWebRTC

/// Transport abstraction. The session model drives a `Transport`
/// without caring whether it's a mock loopback, LAN Bonjour fast-path,
/// or a full WebRTC peer connection. Callbacks fire on the main actor.
@MainActor
protocol Transport: AnyObject {
    // Callback types are explicitly @MainActor so the session model can
    // touch `@Published` state directly inside them without a `Task`
    // hop. Implementations invoke these from an already-isolated
    // MainActor context.
    var onHostHello: (@MainActor (HostHello) -> Void)? { get set }
    var onDisplay: (@MainActor (DisplayInfo) -> Void)? { get set }
    /// Fires once the transport has decoded an actual remote video frame.
    /// A negotiated track or control-channel hello is not sufficient: the
    /// macOS host can reach both while ScreenCaptureKit is still waiting for
    /// the person to answer its secure recording-consent prompt.
    var onFirstVideoFrame: (@MainActor () -> Void)? { get set }
    var onDisconnect: (@MainActor (String) -> Void)? { get set }

    func connect(pairingCode: String, expectedHostID: String?) async throws
    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64)
    func disconnect(reason: String)
}

extension Transport {
    func connect(pairingCode: String) async throws {
        try await connect(pairingCode: pairingCode, expectedHostID: nil)
    }
}

@MainActor
protocol VideoRenderingTransport: Transport {
    func attachVideoRenderer(_ renderer: RTCVideoRenderer)
    func detachVideoRenderer(_ renderer: RTCVideoRenderer)
}

enum TransportError: LocalizedError {
    case badPairingCode
    case hostUnavailable
    case negotiationFailed(String)
    case disconnected(String)
    case signalingUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .badPairingCode:  return "That computer is no longer available through your Apple Account."
        case .hostUnavailable: return "Your computer isn't reachable right now."
        case .negotiationFailed(let m): return "Connection failed: \(m)"
        case .disconnected(let m): return "Disconnected: \(m)"
        case .signalingUnavailable(let m): return m
        }
    }
}
