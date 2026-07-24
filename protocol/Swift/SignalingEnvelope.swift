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
    /// Transport-authenticated source metadata. CloudKit fills this on read;
    /// it is not trusted from the serialized SDP payload.
    public let senderID: String?

    public init(
        role: Role,
        kind: Kind,
        payload: [String: String],
        ts: Double,
        senderID: String? = nil
    ) {
        self.role = role
        self.kind = kind
        self.payload = payload
        self.ts = ts
        self.senderID = senderID
    }
}

/// Small protocol both sides hold an `any SignalingChannel` reference to.
/// Implementations deliver envelopes in order for a given (sender → target)
/// pair; the caller still needs to handle out-of-order arrival across pairs.
public protocol SignalingChannel: AnyObject, Sendable {
    /// Side-specific handshake.
    /// - Host: writes a `HostAdvertisement` record for its private session
    ///   binding so
    ///   clients can discover it.
    /// - Client: queries for a matching `HostAdvertisement` and resolves the
    ///   host's `senderID`. Throws `.hostUnavailable` if no advertisement
    ///   exists for the binding, or `.signalingUnavailable` for network errors.
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
    /// The selected host is no longer advertising to this private database.
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
            return "That computer is not available through your Apple Account. Make sure both devices use the same Apple Account and the Mac host is running."
        case .iCloudUnavailable(let m):
            return m
        case .transport(let m):
            return m
        }
    }
}
