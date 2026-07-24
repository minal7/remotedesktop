import Foundation

/// iOS side of the TLS-PSK LAN broker. It implements the same small channel
/// contracts as CloudKit, so prompt recovery, lifecycle controls, approvals,
/// and typed terminal outcomes retain their existing semantics.
actor LocalComputerUseBrokerClient:
    ComputerUseSessionChannel, ComputerUseSetupChannel {
    private let endpoint: LocalComputerUseEndpoint
    private let credential: LocalComputerUseCredential
    private let pairingCode: String
    private let sessionID: String
    private let senderID: String
    private let targetID: String
    private var inboxByID: [String: ComputerUseEnvelope] = [:]

    init(
        endpoint: LocalComputerUseEndpoint,
        credential: LocalComputerUseCredential,
        pairingCode: String,
        sessionID: String,
        senderID: String,
        targetID: String
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.pairingCode = pairingCode
        self.sessionID = sessionID
        self.senderID = senderID
        self.targetID = targetID
    }

    /// Performs a no-message authenticated exchange. SessionModel calls this
    /// before presenting the composer, making TLS readiness—not Bonjour TXT—
    /// the authority for local AI availability.
    func handshake() async throws {
        _ = try await exchange()
    }

    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let destination = explicitTargetID ?? targetID
        let effectiveSessionID = explicitSessionID ?? sessionID
        guard destination == targetID,
              effectiveSessionID == sessionID else {
            throw LocalComputerUseRPCTransportError.responseMismatch
        }
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: senderID,
            targetID: targetID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            kind: kind,
            body: body)
        let response = try await exchange(envelopes: [envelope])
        guard response.acceptedEnvelopeIDs.contains(envelope.id) else {
            throw LocalComputerUseRPCTransportError.responseMismatch
        }
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        _ = try await exchange()
        return inboxByID.values.sorted(by: Self.envelopeOrder)
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        let acknowledged = Array(Set(envelopes.map(\.id))).sorted()
        guard acknowledged.count
                <= LocalComputerUseRPCLimits.maximumAcknowledgementsPerFrame else {
            throw LocalComputerUseRPCValidationError.tooManyAcknowledgements
        }
        _ = try await exchange(acknowledgedEnvelopeIDs: acknowledged)
        for envelope in envelopes {
            guard inboxByID[envelope.id] == envelope else { continue }
            inboxByID[envelope.id] = nil
        }
    }

    @discardableResult
    private func exchange(
        envelopes: [ComputerUseEnvelope] = [],
        acknowledgedEnvelopeIDs: [String] = []
    ) async throws -> LocalComputerUseRPCResponse {
        let request = LocalComputerUseRPCRequest(
            senderID: senderID,
            targetID: targetID,
            sessionID: sessionID,
            envelopes: envelopes,
            acknowledgedEnvelopeIDs: acknowledgedEnvelopeIDs)
        let response = try await LocalComputerUseRPCTransport.call(
            endpoint: endpoint,
            credential: credential,
            request: request)
        try merge(response.envelopes)
        return response
    }

    private func merge(_ envelopes: [ComputerUseEnvelope]) throws {
        for envelope in envelopes {
            guard envelope.senderID == targetID,
                  envelope.targetID == senderID,
                  envelope.pairingCode == pairingCode,
                  envelope.sessionID == sessionID else {
                throw LocalComputerUseRPCTransportError.responseMismatch
            }
            if let existing = inboxByID[envelope.id] {
                guard existing == envelope else {
                    throw LocalComputerUseRPCTransportError.responseMismatch
                }
            } else {
                inboxByID[envelope.id] = envelope
            }
        }
    }

    private static func envelopeOrder(
        _ lhs: ComputerUseEnvelope,
        _ rhs: ComputerUseEnvelope
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
        return lhs.createdAt < rhs.createdAt
    }
}
