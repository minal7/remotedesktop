import Foundation
import LiveKitWebRTC

/// Local presentation identity, distinct from successful input dispatch. A
/// queued frame callback must match both the handshake and the installed renderer subscription.
struct RemoteInputPresentationState {
    struct FrameLease: Equatable { let inputID: UUID; let probeID: UUID }
    private var inputID: UUID?
    private var probeID: UUID?
    private var acknowledgement: DirectInputAcknowledgement?

    func matches(_ acknowledgement: DirectInputAcknowledgement?) -> Bool {
        inputID != nil && self.acknowledgement == acknowledgement
    }

    mutating func begin(_ acknowledgement: DirectInputAcknowledgement?) {
        inputID = UUID(); probeID = nil; self.acknowledgement = acknowledgement
    }

    mutating func invalidate() -> Bool {
        let hadPresentation = inputID != nil
        inputID = nil; probeID = nil; acknowledgement = nil
        return hadPresentation
    }

    mutating func retireProbe() { probeID = nil }

    mutating func armProbe() -> FrameLease? {
        guard let inputID else { return nil }
        let probeID = UUID(); self.probeID = probeID
        return .init(inputID: inputID, probeID: probeID)
    }

    func acceptsFrame(_ lease: FrameLease) -> Bool {
        inputID == lease.inputID && probeID == lease.probeID
    }
}

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
    /// Revokes the previous input/screen lifetime before a recovery handshake.
    /// Consumers discard local holds; they must not send releases to a new lifetime.
    var onInputUnavailable: (@MainActor () -> Void)? { get set }
    /// The renderer attachment lost its submitted-frame readiness, while the
    /// host input handshake/display remain valid. Release existing controls
    /// under that scope before disabling local input; do not restart AI tasks.
    var onVideoFrameUnavailable: (@MainActor () -> Void)? { get set }
    /// Fires after the current renderer subscription forwards its first valid
    /// decoded frame. Submission does not prove GPU presentation or capture
    /// freshness. Non-video fixtures may synthesize this event explicitly.
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
protocol VideoRendererTarget: AnyObject {
    func attachVideoRenderer(_ renderer: any RemoteVideoSurface)
    func detachVideoRenderer(_ renderer: any RemoteVideoSurface)
}

@MainActor
protocol VideoRenderingTransport: Transport, VideoRendererTarget {}

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
