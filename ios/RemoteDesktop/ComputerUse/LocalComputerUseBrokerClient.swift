import Foundation

protocol ComputerUseSetupChannel: Sendable {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope

    func poll() async throws -> [ComputerUseEnvelope]
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws
}

/// iOS side of the TLS-PSK LAN broker. It implements the same small channel
/// contracts as CloudKit, so prompt recovery, lifecycle controls, approvals,
/// and typed terminal outcomes retain their existing semantics.
actor LocalComputerUseBrokerClient:
    ComputerUseSessionChannel, ComputerUseSetupChannel, PersonalMemoryChannel {
    typealias RPCExchange = @Sendable (
        LocalComputerUseRPCRequest
    ) async throws -> LocalComputerUseRPCResponse

    private let endpoint: LocalComputerUseEndpoint
    private let credential: LocalComputerUseCredential
    private let rpcExchange: RPCExchange
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
        targetID: String,
        rpcExchange: RPCExchange? = nil
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.rpcExchange = rpcExchange ?? { request in
            try await LocalComputerUseRPCTransport.call(
                endpoint: endpoint,
                credential: credential,
                request: request)
        }
        self.pairingCode = pairingCode
        self.sessionID = sessionID
        self.senderID = senderID
        self.targetID = targetID
    }

    /// Performs a no-message authenticated exchange. SessionModel calls this
    /// before presenting the composer, making TLS readiness—not Bonjour TXT—
    /// the authority for local AI availability.
    func handshake() async throws {
        let response = try await exchange(bindSession: true)
        // A pre-binding host's missing additive field remains a valid legacy
        // connectivity handshake. Explicit rejection from a new host is not.
        guard response.sessionBindingAccepted != false else {
            throw LocalComputerUseRPCTransportError.responseMismatch
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

    /// Owner memory uses a typed request/reply frame separate from the task
    /// mailbox so memory values never enter prompt, retry, or lifecycle traffic.
    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        let request = LocalComputerUseRPCRequest(
            senderID: senderID,
            targetID: targetID,
            sessionID: sessionID,
            memoryCommand: command)
        let response = try await LocalComputerUseRPCTransport.call(
            endpoint: endpoint,
            credential: credential,
            request: request)
        guard let reply = try response.memoryResult(for: request) else {
            throw LocalComputerUseRPCValidationError.memoryReplyMissing
        }
        return reply
    }

    @discardableResult
    private func exchange(
        envelopes: [ComputerUseEnvelope] = [],
        acknowledgedEnvelopeIDs: [String] = [],
        bindSession: Bool? = nil
    ) async throws -> LocalComputerUseRPCResponse {
        let request = LocalComputerUseRPCRequest(
            senderID: senderID,
            targetID: targetID,
            sessionID: sessionID,
            envelopes: envelopes,
            acknowledgedEnvelopeIDs: acknowledgedEnvelopeIDs,
            bindSession: bindSession)
        let response = try await rpcExchange(request)
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
