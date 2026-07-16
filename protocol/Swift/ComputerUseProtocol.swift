import Foundation

/// The small, user-facing capability contract published beside each host.
/// A host is only selectable for AI Computer Use when its local model runtime
/// is genuinely ready; installing a model file alone is not enough.
public struct ComputerUseCapability: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case unavailable
        case setupRequired
        case installing
        case ready
        case busy
        case paused
    }

    public let state: State
    public let detail: String

    public init(state: State, detail: String) {
        self.state = state
        self.detail = detail
    }

    public static let unavailable = ComputerUseCapability(
        state: .unavailable,
        detail: "AI Computer Use is not enabled")

    public static let setupRequired = ComputerUseCapability(
        state: .setupRequired,
        detail: "Finish AI setup on this Mac")

    public static let ready = ComputerUseCapability(
        state: .ready,
        detail: "AI Computer Use is ready")

    public var isAvailable: Bool {
        switch state {
        case .ready, .busy, .paused:
            return true
        case .unavailable, .setupRequired, .installing:
            return false
        }
    }
}

/// Versioned, local-network discovery metadata for a nearby host.
///
/// This record is intentionally a discovery hint rather than an
/// authentication mechanism. It contains only the host's opaque per-install
/// identifier and the small AI readiness value already advertised through
/// private CloudKit. Pairing, setup requests, and task control continue to go
/// through CloudKit; no credentials, model URLs, prompts, or user data belong
/// in this record.
public struct LocalHostBonjourMetadata: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumTXTRecordBytes = 512
    public static let maximumDetailBytes = 160

    public let version: Int
    public let senderID: String
    public let computerUseCapability: ComputerUseCapability

    public init?(
        senderID: String,
        computerUseCapability: ComputerUseCapability
    ) {
        guard let senderID = Self.validatedSenderID(senderID) else {
            return nil
        }
        let detail = Self.sanitizedDetail(computerUseCapability.detail)
        guard !detail.isEmpty else { return nil }

        self.version = Self.currentVersion
        self.senderID = senderID
        self.computerUseCapability = ComputerUseCapability(
            state: computerUseCapability.state,
            detail: detail)
    }

    /// Encodes one bounded DNS-SD TXT record. Short keys keep the complete
    /// record comfortably below multicast DNS packet limits.
    public func txtRecordData() -> Data {
        let values: [String: Data] = [
            "v": Data(String(version).utf8),
            "sid": Data(senderID.utf8),
            "cu": Data(computerUseCapability.state.rawValue.utf8),
            "cud": Data(computerUseCapability.detail.utf8),
        ]
        return NetService.data(fromTXTRecord: values)
    }

    /// Decodes only the current schema and rejects malformed, oversized, or
    /// display-spoofing values. Callers should fall back to the legacy Bonjour
    /// service-name row when this returns `nil`.
    public static func decode(txtRecordData data: Data) -> Self? {
        guard !data.isEmpty, data.count <= maximumTXTRecordBytes else {
            return nil
        }
        let values = NetService.dictionary(fromTXTRecord: data)
        guard let versionString = decodedString(values["v"], maximumBytes: 3),
              versionString == String(currentVersion),
              let rawSenderID = decodedString(values["sid"], maximumBytes: 36),
              let senderID = validatedSenderID(rawSenderID),
              let rawState = decodedString(values["cu"], maximumBytes: 24),
              let state = ComputerUseCapability.State(rawValue: rawState),
              let detail = decodedString(
                values["cud"],
                maximumBytes: maximumDetailBytes),
              !detail.isEmpty,
              sanitizedDetail(detail) == detail else {
            return nil
        }

        return Self(
            senderID: senderID,
            computerUseCapability: ComputerUseCapability(
                state: state,
                detail: detail))
    }

    private static func decodedString(
        _ data: Data?,
        maximumBytes: Int
    ) -> String? {
        guard let data,
              !data.isEmpty,
              data.count <= maximumBytes,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func validatedSenderID(_ value: String) -> String? {
        guard value.utf8.count == 36,
              UUID(uuidString: value) != nil else {
            return nil
        }
        // Preserve the exact Keychain value: CloudKit target matching is
        // string-exact even though UUID parsing itself is case-insensitive.
        return value
    }

    private static func sanitizedDetail(_ value: String) -> String {
        let flattened = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        let collapsed = flattened
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        var bounded = ""
        var byteCount = 0
        for character in collapsed {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumDetailBytes else {
                break
            }
            bounded.append(character)
            byteCount += characterBytes
        }
        return bounded
    }
}

/// An idempotent request for the host to ensure the computer-use runtime that
/// ships with this protocol generation is installed and verified. Repeating a
/// request with the same `idempotencyKey` must report the existing install
/// instead of starting a second download.
public struct ComputerUseSetupRequest: Codable, Equatable, Sendable {
    /// v2 adds the verified local MCP helper to the mobile-triggered setup.
    public static let currentIdempotencyKey = "computer-use-setup-v2"

    public let requestID: String
    public let idempotencyKey: String

    public init(
        requestID: String = UUID().uuidString,
        idempotencyKey: String = ComputerUseSetupRequest.currentIdempotencyKey
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }
}

/// Aggregate setup progress displayed by the iOS device row. The host owns
/// the actual package list and download locations; iOS receives only a safe,
/// user-facing phase and optional completion fraction.
public struct ComputerUseSetupProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case queued
        case downloadingModel
        case installingPackages
        case verifying
        case ready
        case failed
    }

    public let requestID: String
    public let idempotencyKey: String
    public let phase: Phase
    public let fractionCompleted: Double?
    public let detail: String
    public let errorMessage: String?

    public init(
        requestID: String,
        idempotencyKey: String = ComputerUseSetupRequest.currentIdempotencyKey,
        phase: Phase,
        fractionCompleted: Double? = nil,
        detail: String,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.phase = phase
        self.fractionCompleted = Self.normalized(fractionCompleted)
        self.detail = detail
        self.errorMessage = errorMessage
    }

    public var isTerminal: Bool {
        phase == .ready || phase == .failed
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case idempotencyKey
        case phase
        case fractionCompleted
        case detail
        case errorMessage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(String.self, forKey: .requestID)
        idempotencyKey = try values.decodeIfPresent(String.self, forKey: .idempotencyKey)
            ?? ComputerUseSetupRequest.currentIdempotencyKey
        phase = try values.decode(Phase.self, forKey: .phase)
        fractionCompleted = Self.normalized(
            try values.decodeIfPresent(Double.self, forKey: .fractionCompleted))
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? "Setting up AI…"
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(phase, forKey: .phase)
        try values.encodeIfPresent(fractionCompleted, forKey: .fractionCompleted)
        try values.encode(detail, forKey: .detail)
        try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

    private static func normalized(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite else { return nil }
        return min(1, max(0, fraction))
    }
}

/// The local model must stop before a consequential action and ask the user
/// in the iOS chat. Approval is scoped to one task and one request; it is not
/// a blanket permission for later actions.
public struct ComputerUseApprovalRequest: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String

        public var id: String { label }

        public init(label: String, value: String) {
            self.label = String(label.prefix(80))
            self.value = String(value.prefix(8_000))
        }
    }

    public let requestID: String
    public let taskID: String
    public let message: String
    /// Exact, host-validated values for the one proposed action. Older clients
    /// safely ignore this optional field; newer clients use it to make email,
    /// calendar, message, and other consequential approvals unambiguous.
    public let details: [Detail]?
    public let confirmLabel: String?
    /// Highest lifecycle control revision applied when the host created this
    /// approval. `nil` keeps requests from pre-revision peers decodable.
    public let appliedControlRevision: UInt64?

    public init(
        requestID: String = UUID().uuidString,
        taskID: String,
        message: String,
        details: [Detail]? = nil,
        confirmLabel: String? = nil,
        appliedControlRevision: UInt64? = nil
    ) {
        self.requestID = requestID
        self.taskID = taskID
        self.message = String(message.prefix(500))
        self.details = details.map { Array($0.prefix(12)) }
        self.confirmLabel = confirmLabel.map { String($0.prefix(80)) }
        self.appliedControlRevision = appliedControlRevision
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }
}

public struct ComputerUseApprovalResponse: Codable, Equatable, Sendable {
    public let requestID: String
    public let approved: Bool
    /// Current clients bind a choice to the exact task and lifecycle revision
    /// shown in the approval card. Both fields remain optional so hosts can
    /// accept responses from peers that predate ordered lifecycle controls.
    public let taskID: String?
    public let appliedControlRevision: UInt64?

    public init(
        requestID: String,
        approved: Bool,
        taskID: String? = nil,
        appliedControlRevision: UInt64? = nil
    ) {
        self.requestID = requestID
        self.approved = approved
        self.taskID = taskID
        self.appliedControlRevision = appliedControlRevision
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }
}

/// A causally ordered lifecycle intent for one stable privileged prompt.
///
/// Versioned clients persist and monotonically increase `revision` for the
/// lifetime of `taskID`. Hosts reduce those revisions durably, so CloudKit may
/// deliver Pause, Resume, Cancel, and the prompt itself in any order without a
/// stale control reversing a newer user intent. Hosts still accept the empty
/// control bodies emitted by older clients, but those legacy controls can only
/// affect an already-active matching execution context.
public struct ComputerUseControlRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumTaskIDLength = 128

    public let version: Int
    public let taskID: String
    public let revision: UInt64

    public init(taskID: String, revision: UInt64) {
        version = Self.currentVersion
        self.taskID = taskID
        self.revision = revision
    }

    public var isValid: Bool {
        version == Self.currentVersion
            && !taskID.isEmpty
            && taskID.count <= Self.maximumTaskIDLength
            && revision > 0
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }
}

/// Correlates assistant/status traffic with the stable privileged prompt ID.
/// This lets iOS safely ignore a delayed replay from an older task after the
/// user has already started a newer one in the same chat session.
public struct ComputerUseTaskUpdate: Codable, Equatable, Sendable {
    public let taskID: String
    public let text: String
    /// Highest versioned lifecycle revision durably applied by the host when
    /// this update was created. `nil` preserves decoding and behavior for
    /// peers that predate ordered controls.
    public let appliedControlRevision: UInt64?

    public init(
        taskID: String,
        text: String,
        appliedControlRevision: UInt64? = nil
    ) {
        self.taskID = taskID
        self.text = String(text.prefix(8_000))
        self.appliedControlRevision = appliedControlRevision
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }
}

/// Typed text carried inside the existing status envelope when automation has
/// deliberately paused for a person-only step. Older clients safely display
/// the complete value as ordinary status text; current clients decode the
/// prefix and enter their existing manual-control/resume state.
public enum ComputerUseStatusSignal {
    public static let userInterventionPrefix = "user-intervention-required:"
    public static let maximumInterventionCharacters = 500

    public static func userIntervention(_ message: String) -> String {
        let bounded = String(message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumInterventionCharacters))
        return userInterventionPrefix + bounded
    }

    public static func userInterventionMessage(from status: String) -> String? {
        guard status.hasPrefix(userInterventionPrefix) else { return nil }
        let message = status.dropFirst(userInterventionPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              message.count <= maximumInterventionCharacters else {
            return nil
        }
        return message
    }
}

/// A bounded turn from the recent AI Computer Use chat. The current request
/// is carried separately by ``ComputerUsePromptRequest`` so retries can reuse
/// one exact wire body while a later clarification answer can include the
/// question that prompted it.
public struct ComputerUseConversationTurn: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = String(text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(ComputerUsePromptRequest.maximumTurnLength))
    }
}

/// Versioned prompt payload sent from iOS to the host. Keeping recent chat
/// turns with the current request makes clarification genuinely multi-turn,
/// while the strict bounds keep the CloudKit record and local model prompt
/// small enough to process predictably.
public struct ComputerUsePromptRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumConversationTurns = 12
    public static let maximumTurnLength = 4_000
    public static let maximumPromptLength = 8_000

    public let version: Int
    public let prompt: String
    public let conversation: [ComputerUseConversationTurn]

    public init(
        prompt: String,
        conversation: [ComputerUseConversationTurn] = []
    ) {
        version = Self.currentVersion
        self.prompt = Self.boundedPrompt(prompt)
        self.conversation = Self.boundedConversation(conversation)
    }

    public func encodedBody() throws -> String {
        try encodeComputerUseBody(self)
    }

    public static func decodeBody(_ body: String) throws -> Self {
        try decodeComputerUseBody(body, as: Self.self)
    }

    /// Accepts prompts from app versions that predate the structured payload.
    /// New senders always encode once and persist that exact body for retry.
    public static func decodeCompatibleBody(_ body: String) -> Self {
        (try? decodeBody(body)) ?? Self(prompt: body)
    }

    /// A labeled, bounded model input. Only user and assistant chat turns are
    /// included; transport status and approval copy never become task input.
    public var modelPrompt: String {
        guard !conversation.isEmpty else { return prompt }
        var value = "Recent conversation (oldest to newest):\n"
        for turn in conversation {
            let label = turn.role == .user ? "User" : "Assistant"
            value += "\(label): \(turn.text)\n"
        }
        value += "Current user request: \(prompt)"
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case prompt
        case conversation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        prompt = Self.boundedPrompt(
            try values.decode(String.self, forKey: .prompt))
        conversation = Self.boundedConversation(
            try values.decodeIfPresent(
                [ComputerUseConversationTurn].self,
                forKey: .conversation) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(prompt, forKey: .prompt)
        try values.encode(conversation, forKey: .conversation)
    }

    private static func boundedPrompt(_ value: String) -> String {
        String(value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumPromptLength))
    }

    private static func boundedConversation(
        _ turns: [ComputerUseConversationTurn]
    ) -> [ComputerUseConversationTurn] {
        turns
            .filter { !$0.text.isEmpty }
            .suffix(maximumConversationTurns)
            .map { ComputerUseConversationTurn(role: $0.role, text: $0.text) }
    }
}

/// CloudKit envelope used by the computer-use control plane. Screen video
/// remains on WebRTC; prompts and lifecycle controls use the same private
/// CloudKit container as pairing so they work without a new service.
public struct ComputerUseEnvelope: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case prompt
        case assistant
        case status
        case pause
        case resume
        case cancel
        case setupRequest
        case setupProgress
        case approvalRequest
        case approvalResponse
    }

    public let id: String
    public let senderID: String
    public let targetID: String
    public let pairingCode: String
    public let sessionID: String
    public let kind: Kind
    public let body: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        senderID: String,
        targetID: String,
        pairingCode: String,
        sessionID: String,
        kind: Kind,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.senderID = senderID
        self.targetID = targetID
        self.pairingCode = pairingCode
        self.sessionID = sessionID
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
    }
}

private func encodeComputerUseBody<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let body = String(data: data, encoding: .utf8) else {
        throw ComputerUsePayloadError.invalidUTF8
    }
    return body
}

private func decodeComputerUseBody<T: Decodable>(_ body: String, as type: T.Type) throws -> T {
    guard let data = body.data(using: .utf8) else {
        throw ComputerUsePayloadError.invalidUTF8
    }
    return try JSONDecoder().decode(type, from: data)
}

private enum ComputerUsePayloadError: Error {
    case invalidUTF8
}
