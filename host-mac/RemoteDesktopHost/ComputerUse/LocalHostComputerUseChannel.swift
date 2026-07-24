import Foundation

/// In-memory durable-for-the-process mailbox behind the local TLS listener.
/// TLS authenticates the connection; this actor then rebinds every serialized
/// identity to that connection before the existing host manager can see it.
actor LocalHostComputerUseChannel: HostComputerUseChannel {
    static let maximumBodyBytes = 96 * 1_024
    static let maximumSessionIDBytes = 256
    static let maximumQueuedEnvelopesPerDirection = 256
    static let maximumTrackedOutboundPeerSessions = 64
    static let maximumTotalQueuedOutboundEnvelopes = 256
    static let outboundPeerIdleLifetime: TimeInterval = 15 * 60

    private struct PeerSession: Hashable {
        let senderID: String
        let sessionID: String
    }

    private struct PeerActivity {
        let touchedAt: Date
        let sequence: UInt64
    }

    private let hostID: String
    private let pairingCode: String
    private let now: @Sendable () -> Date
    private var inboundByID: [String: ComputerUseEnvelope] = [:]
    private var outboundByPeer: [PeerSession: [String: ComputerUseEnvelope]] = [:]
    private var outboundActivityByPeer: [PeerSession: PeerActivity] = [:]
    private var activitySequence: UInt64 = 0

    init(
        hostID: String,
        pairingCode: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(!hostID.isEmpty)
        precondition(!pairingCode.isEmpty)
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.now = now
    }

    /// Accepts one client frame only after TLS authenticated the local access
    /// key. Caller-supplied routing fields are checked against that connection
    /// and the currently advertised host before the envelope enters policy.
    func receiveFromClient(
        _ envelope: ComputerUseEnvelope,
        authenticatedSenderID: String
    ) throws {
        _ = try applyClientFrame(
            envelopes: [envelope],
            acknowledgedEnvelopeIDs: [],
            authenticatedSenderID: authenticatedSenderID,
            sessionID: envelope.sessionID)
    }

    /// Validates and commits one complete RPC frame atomically. A malformed
    /// later envelope must never leave an earlier task queued even though the
    /// client receives only a failure for the whole request.
    @discardableResult
    func applyClientFrame(
        envelopes: [ComputerUseEnvelope],
        acknowledgedEnvelopeIDs: [String],
        authenticatedSenderID: String,
        sessionID: String
    ) throws -> [String] {
        guard Self.isValidPeerID(authenticatedSenderID),
              Self.isValidSessionID(sessionID),
              envelopes.count <= LocalComputerUseRPCLimits.maximumEnvelopesPerFrame,
              acknowledgedEnvelopeIDs.count
                <= LocalComputerUseRPCLimits.maximumAcknowledgementsPerFrame,
              acknowledgedEnvelopeIDs.allSatisfy(Self.isValidMessageID) else {
            throw SignalingError.transport(
                "The local AI request failed authenticated routing validation.")
        }

        var nextInbound = inboundByID
        for envelope in envelopes {
            guard envelope.senderID == authenticatedSenderID,
                  envelope.targetID == hostID,
                  envelope.pairingCode == pairingCode,
                  envelope.sessionID == sessionID,
                  Self.isValidEnvelope(envelope) else {
                throw SignalingError.transport(
                    "The local AI request failed authenticated routing validation.")
            }
            if let existing = nextInbound[envelope.id] {
                guard existing == envelope else {
                    throw SignalingError.transport(
                        "A local AI request reused an identifier with different contents.")
                }
            } else {
                nextInbound[envelope.id] = envelope
            }
        }
        guard nextInbound.count <= Self.maximumQueuedEnvelopesPerDirection else {
            throw SignalingError.transport(
                "The local AI request queue is full. Wait for the Mac, then retry.")
        }

        let peer = PeerSession(
            senderID: authenticatedSenderID,
            sessionID: sessionID)
        let timestamp = now()
        pruneOutboundState(at: timestamp, protecting: peer)
        var nextOutbound = outboundByPeer[peer]
        for id in acknowledgedEnvelopeIDs {
            nextOutbound?[id] = nil
        }

        inboundByID = nextInbound
        if nextOutbound?.isEmpty == true {
            outboundByPeer[peer] = nil
            outboundActivityByPeer[peer] = nil
        } else if let nextOutbound {
            outboundByPeer[peer] = nextOutbound
            touch(peer, at: timestamp)
        }
        return envelopes.map(\.id)
    }

    func pollForClient(
        authenticatedSenderID: String,
        sessionID: String
    ) throws -> [ComputerUseEnvelope] {
        guard Self.isValidPeerID(authenticatedSenderID),
              Self.isValidSessionID(sessionID) else {
            throw SignalingError.transport(
                "The local AI session identity is invalid.")
        }
        let peer = PeerSession(
            senderID: authenticatedSenderID,
            sessionID: sessionID)
        let timestamp = now()
        pruneOutboundState(at: timestamp, protecting: peer)
        if outboundByPeer[peer] != nil { touch(peer, at: timestamp) }
        return (outboundByPeer[peer].map { Array($0.values) } ?? [])
            .sorted(by: Self.envelopeOrder)
    }

    func acknowledgeFromClient(
        ids: [String],
        authenticatedSenderID: String,
        sessionID: String
    ) throws {
        guard ids.count
                <= LocalComputerUseRPCLimits.maximumAcknowledgementsPerFrame,
              Self.isValidPeerID(authenticatedSenderID),
              Self.isValidSessionID(sessionID),
              ids.allSatisfy(Self.isValidMessageID) else {
            throw SignalingError.transport(
                "The local AI acknowledgement is invalid.")
        }
        let peer = PeerSession(
            senderID: authenticatedSenderID,
            sessionID: sessionID)
        let timestamp = now()
        pruneOutboundState(at: timestamp, protecting: peer)
        for id in ids {
            outboundByPeer[peer]?[id] = nil
        }
        if outboundByPeer[peer]?.isEmpty == true {
            outboundByPeer[peer] = nil
            outboundActivityByPeer[peer] = nil
        } else if outboundByPeer[peer] != nil {
            touch(peer, at: timestamp)
        }
    }

    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        guard let targetID = explicitTargetID,
              Self.isValidPeerID(targetID),
              let sessionID = explicitSessionID,
              Self.isValidSessionID(sessionID),
              body.utf8.count <= Self.maximumBodyBytes else {
            throw SignalingError.transport(
                "The local AI response exceeded its authenticated session bounds.")
        }
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: hostID,
            targetID: targetID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            kind: kind,
            body: body)
        guard Self.isValidEnvelope(envelope) else {
            throw SignalingError.transport("The local AI response was invalid.")
        }

        let peer = PeerSession(senderID: targetID, sessionID: sessionID)
        let timestamp = now()
        pruneOutboundState(at: timestamp, protecting: peer)
        var queue = outboundByPeer[peer] ?? [:]
        if let existing = queue[envelope.id] {
            guard existing == envelope else {
                throw SignalingError.transport(
                    "A local AI response reused an identifier with different contents.")
            }
            touch(peer, at: timestamp)
            return existing
        }
        guard queue.count < Self.maximumQueuedEnvelopesPerDirection else {
            throw SignalingError.transport(
                "The local AI response queue is full.")
        }
        guard makeOutboundCapacity(for: peer) else {
            throw SignalingError.transport(
                "The local AI response queue is full.")
        }
        queue[envelope.id] = envelope
        outboundByPeer[peer] = queue
        touch(peer, at: timestamp)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        inboundByID.values.sorted(by: Self.envelopeOrder)
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        for envelope in envelopes {
            guard let current = inboundByID[envelope.id],
                  current == envelope else { continue }
            inboundByID[envelope.id] = nil
        }
    }

    func outboundStateCounts() -> (peerSessions: Int, envelopes: Int) {
        (
            outboundByPeer.count,
            outboundByPeer.values.reduce(0) { $0 + $1.count }
        )
    }

    private func touch(_ peer: PeerSession, at timestamp: Date) {
        activitySequence &+= 1
        outboundActivityByPeer[peer] = PeerActivity(
            touchedAt: timestamp,
            sequence: activitySequence)
    }

    private func pruneOutboundState(
        at timestamp: Date,
        protecting protectedPeer: PeerSession?
    ) {
        let expired: [PeerSession] = outboundActivityByPeer.compactMap {
            entry -> PeerSession? in
            let peer = entry.key
            let activity = entry.value
            guard peer != protectedPeer,
                  timestamp.timeIntervalSince(activity.touchedAt)
                    >= Self.outboundPeerIdleLifetime else { return nil }
            return peer
        }
        for peer in expired { removeOutboundState(for: peer) }

        while outboundByPeer.count
                > Self.maximumTrackedOutboundPeerSessions {
            guard evictLeastRecentPeer(excluding: protectedPeer) else { break }
        }
        while totalOutboundEnvelopeCount
                > Self.maximumTotalQueuedOutboundEnvelopes {
            guard evictLeastRecentPeer(excluding: protectedPeer) else { break }
        }
    }

    private func makeOutboundCapacity(for protectedPeer: PeerSession) -> Bool {
        if outboundByPeer[protectedPeer] == nil {
            while outboundByPeer.count
                    >= Self.maximumTrackedOutboundPeerSessions {
                guard evictLeastRecentPeer(excluding: protectedPeer) else {
                    return false
                }
            }
        }
        while totalOutboundEnvelopeCount
                >= Self.maximumTotalQueuedOutboundEnvelopes {
            guard evictLeastRecentPeer(excluding: protectedPeer) else {
                return false
            }
        }
        return true
    }

    @discardableResult
    private func evictLeastRecentPeer(
        excluding protectedPeer: PeerSession?
    ) -> Bool {
        guard let victim = outboundActivityByPeer
            .filter({ $0.key != protectedPeer })
            .min(by: { lhs, rhs in
                if lhs.value.sequence == rhs.value.sequence {
                    if lhs.key.senderID == rhs.key.senderID {
                        return lhs.key.sessionID < rhs.key.sessionID
                    }
                    return lhs.key.senderID < rhs.key.senderID
                }
                return lhs.value.sequence < rhs.value.sequence
            })?.key else { return false }
        removeOutboundState(for: victim)
        return true
    }

    private func removeOutboundState(for peer: PeerSession) {
        outboundByPeer[peer] = nil
        outboundActivityByPeer[peer] = nil
    }

    private var totalOutboundEnvelopeCount: Int {
        outboundByPeer.values.reduce(0) { $0 + $1.count }
    }

    private static func isValidPeerID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumSessionIDBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isValidMessageID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            }
    }

    private static func isValidEnvelope(
        _ envelope: ComputerUseEnvelope
    ) -> Bool {
        isValidMessageID(envelope.id)
            && isValidPeerID(envelope.senderID)
            && isValidPeerID(envelope.targetID)
            && envelope.pairingCode.utf8.count <= 64
            && isValidSessionID(envelope.sessionID)
            && envelope.body.utf8.count <= maximumBodyBytes
            && envelope.createdAt.timeIntervalSinceNow < 5 * 60
            && envelope.createdAt.timeIntervalSinceNow > -(24 * 60 * 60)
    }

    private static func envelopeOrder(
        _ lhs: ComputerUseEnvelope,
        _ rhs: ComputerUseEnvelope
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
        return lhs.createdAt < rhs.createdAt
    }
}
