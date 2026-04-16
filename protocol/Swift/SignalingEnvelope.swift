import Foundation

/// Wire envelope used by the signaling layer. The signaling implementation
/// (CloudKit / mock / other) is transparent to callers — both sides agree on
/// this shape and treat payload as an opaque dictionary.
public struct SignalingEnvelope: Codable, Sendable {
    public enum Role: String, Codable, Sendable { case host, client }
    public enum Kind: String, Codable, Sendable { case offer, answer, ice, bye }

    public let role: Role
    public let kind: Kind
    public let payload: [String: String]
    public let ts: Double

    public init(role: Role, kind: Kind, payload: [String: String], ts: Double) {
        self.role = role
        self.kind = kind
        self.payload = payload
        self.ts = ts
    }
}

/// Small protocol both sides hold an `any SignalingChannel` reference to.
/// Implementations deliver envelopes in order for a given (sender → target)
/// pair; the caller still needs to handle out-of-order arrival across pairs.
public protocol SignalingChannel: AnyObject, Sendable {
    /// Side-specific handshake.
    /// - Host: writes a `HostAdvertisement` record for its pairing code so
    ///   clients can discover it.
    /// - Client: queries for a matching `HostAdvertisement` and resolves the
    ///   host's `senderID`. Throws `.hostUnavailable` if no advertisement
    ///   exists for the code, or `.signalingUnavailable` for network errors.
    func claim() async throws

    /// Sends an envelope to the peer. Fire-and-forget from the caller's
    /// point of view; errors surface via the returned `try`.
    func send(_ envelope: SignalingEnvelope) async throws

    /// Returns any envelopes addressed to us since the last call. Returns
    /// an empty array if nothing is available yet. Callers loop on this.
    func poll() async throws -> [SignalingEnvelope]
}

/// Errors shared across signaling implementations. Transport-level errors
/// (`TransportError`) wrap these at the caller boundary.
public enum SignalingError: Error, LocalizedError {
    /// Host isn't advertising for the supplied pairing code. Either the
    /// code is wrong or the host was closed.
    case hostUnavailable
    /// Client's iCloud account differs from the host's, or the user isn't
    /// signed into iCloud at all.
    case iCloudUnavailable(String)
    /// Underlying CloudKit (or other transport) error. Message is
    /// user-readable.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .hostUnavailable:
            return "No computer is advertising that pairing code. Check the code on your Mac and make sure both devices are signed into the same iCloud account."
        case .iCloudUnavailable(let m):
            return m
        case .transport(let m):
            return m
        }
    }
}
