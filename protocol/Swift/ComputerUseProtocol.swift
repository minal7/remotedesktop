import Foundation

/// The small, user-facing capability contract published beside each host.
/// A host is only selectable for AI Computer Use when its local model runtime
/// is genuinely ready; installing a model file alone is not enough.
public struct ComputerUseCapability: Codable, Equatable, Sendable {
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
/// identifier, a non-secret fingerprint for selecting a previously enrolled
/// local TLS credential, the non-secret internal session routing binding, and
/// the small AI readiness value. The credential itself, model URLs, prompts,
/// and user data never belong in Bonjour.
public struct LocalHostBonjourMetadata: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumTXTRecordBytes = 512
    public static let maximumDetailBytes = 160

    public let version: Int
    public let senderID: String
    public let computerUseCapability: ComputerUseCapability
    /// SHA-256 fingerprint of the local TLS PSK. This is safe to advertise:
    /// it selects a Keychain item but cannot authenticate or decrypt traffic.
    public let localCredentialID: String?
    /// Legacy six-digit session routing value carried in TXT so the Bonjour
    /// service's visible display name never exposes a code-like suffix. It is
    /// not an authenticator and is accepted only after exact private-CloudKit
    /// host matching.
    public let routingBinding: String?

    public init?(
        senderID: String,
        computerUseCapability: ComputerUseCapability,
        localCredentialID: String? = nil,
        routingBinding: String? = nil
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
        if let localCredentialID {
            guard Self.isValidCredentialID(localCredentialID) else {
                return nil
            }
            self.localCredentialID = localCredentialID
        } else {
            self.localCredentialID = nil
        }
        if let routingBinding {
            guard Self.isValidRoutingBinding(routingBinding) else {
                return nil
            }
            self.routingBinding = routingBinding
        } else {
            self.routingBinding = nil
        }
    }

    /// Encodes one bounded DNS-SD TXT record. Short keys keep the complete
    /// record comfortably below multicast DNS packet limits.
    public func txtRecordData() -> Data {
        var values: [String: Data] = [
            "v": Data(String(version).utf8),
            "sid": Data(senderID.utf8),
            "cu": Data(computerUseCapability.state.rawValue.utf8),
            "cud": Data(computerUseCapability.detail.utf8),
        ]
        if let localCredentialID {
            values["lci"] = Data(localCredentialID.utf8)
        }
        if let routingBinding {
            values["rb"] = Data(routingBinding.utf8)
        }
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

        let localCredentialID: String?
        if values["lci"] != nil {
            guard let value = decodedString(values["lci"], maximumBytes: 64),
                  isValidCredentialID(value) else {
                return nil
            }
            localCredentialID = value
        } else {
            localCredentialID = nil
        }

        let routingBinding: String?
        if values["rb"] != nil {
            guard let value = decodedString(values["rb"], maximumBytes: 6),
                  isValidRoutingBinding(value) else {
                return nil
            }
            routingBinding = value
        } else {
            routingBinding = nil
        }

        return Self(
            senderID: senderID,
            computerUseCapability: ComputerUseCapability(
                state: state,
                detail: detail),
            localCredentialID: localCredentialID,
            routingBinding: routingBinding)
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

    private static func isValidCredentialID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func isValidRoutingBinding(_ value: String) -> Bool {
        value.utf8.count == 6
            && value.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
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
public enum ComputerUseSetupIdentifierPolicy {
    public static let maximumSenderIDBytes = 64
    public static let maximumSessionIDBytes = 96
    public static let maximumRequestIDBytes = 64
    public static let maximumIdempotencyKeyBytes = 64
    public static let maximumEncodedRequestBodyBytes = 512

    public static func isValidSenderID(_ value: String) -> Bool {
        isBoundedOpaqueIdentifier(
            value,
            maximumBytes: maximumSenderIDBytes)
    }

    public static func isValidSessionID(_ value: String) -> Bool {
        isBoundedOpaqueIdentifier(
            value,
            maximumBytes: maximumSessionIDBytes)
    }

    public static func isValidRequestID(_ value: String) -> Bool {
        isBoundedOpaqueIdentifier(
            value,
            maximumBytes: maximumRequestIDBytes)
    }

    public static func isValidIdempotencyKey(_ value: String) -> Bool {
        isBoundedOpaqueIdentifier(
            value,
            maximumBytes: maximumIdempotencyKeyBytes)
    }

    public static func isValidRoute(
        senderID: String,
        sessionID: String,
        requestID: String
    ) -> Bool {
        isValidSenderID(senderID)
            && isValidSessionID(sessionID)
            && isValidRequestID(requestID)
    }

    /// Setup identifiers are opaque compatibility tokens, not display text.
    /// Restricting them to a small ASCII alphabet prevents control characters,
    /// Unicode confusables, and attacker-amplified retained strings while
    /// preserving UUIDs and the deployed `setup-<UUID>` session shape.
    private static func isBoundedOpaqueIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
        }
    }
}

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
        guard ComputerUseSetupIdentifierPolicy.isValidRequestID(requestID),
              ComputerUseSetupIdentifierPolicy.isValidIdempotencyKey(
                idempotencyKey) else {
            throw ComputerUsePayloadError.invalidIdentifier
        }
        let body = try encodeComputerUseBody(self)
        guard body.utf8.count <= ComputerUseSetupIdentifierPolicy
                .maximumEncodedRequestBodyBytes else {
            throw ComputerUsePayloadError.payloadTooLarge
        }
        return body
    }

    public static func decodeBody(_ body: String) throws -> Self {
        guard body.utf8.count <= ComputerUseSetupIdentifierPolicy
                .maximumEncodedRequestBodyBytes else {
            throw ComputerUsePayloadError.payloadTooLarge
        }
        let request = try decodeComputerUseBody(body, as: Self.self)
        guard ComputerUseSetupIdentifierPolicy.isValidRequestID(
                request.requestID),
              ComputerUseSetupIdentifierPolicy.isValidIdempotencyKey(
                request.idempotencyKey) else {
            throw ComputerUsePayloadError.invalidIdentifier
        }
        return request
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
    public let hostControlEpoch: UInt64?

    public init(
        requestID: String = UUID().uuidString,
        taskID: String,
        message: String,
        details: [Detail]? = nil,
        confirmLabel: String? = nil,
        appliedControlRevision: UInt64? = nil,
        hostControlEpoch: UInt64? = nil
    ) {
        self.requestID = requestID
        self.taskID = taskID
        self.message = String(message.prefix(500))
        self.details = details.map { Array($0.prefix(12)) }
        self.confirmLabel = confirmLabel.map { String($0.prefix(80)) }
        self.appliedControlRevision = appliedControlRevision
        self.hostControlEpoch = hostControlEpoch
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
    public let hostControlEpoch: UInt64?

    public init(
        requestID: String,
        approved: Bool,
        taskID: String? = nil,
        appliedControlRevision: UInt64? = nil,
        hostControlEpoch: UInt64? = nil
    ) {
        self.requestID = requestID
        self.approved = approved
        self.taskID = taskID
        self.appliedControlRevision = appliedControlRevision
        self.hostControlEpoch = hostControlEpoch
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
/// affect an already-active matching execution context before its first local
/// handoff; they cannot override a nonzero host control epoch.
public struct ComputerUseControlRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumTaskIDLength = 128

    public let version: Int
    public let taskID: String
    public let revision: UInt64
    /// The host's local takeover/handback clock observed when this intent was
    /// created. Freeze it with the revision through retries and recovery.
    /// Missing values from older clients mean epoch zero, never the latest.
    public let observedHostControlEpoch: UInt64?

    public init(taskID: String, revision: UInt64, observedHostControlEpoch: UInt64? = nil) {
        version = Self.currentVersion
        self.taskID = taskID
        self.revision = revision
        self.observedHostControlEpoch = observedHostControlEpoch
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

/// Host-authoritative classification for a terminal task result or a
/// resumable person-only handoff.
public enum ComputerUseTerminalOutcome: String, Codable, Equatable, Sendable {
    case taskCompleted
    case userInterventionRequired
    case unableToComplete
}

/// A host-issued reference to one retained unresolved request. It carries no
/// original text. The host must also match its retained sender/session/scope;
/// knowing a reference alone cannot authorize a continuation.
public struct ComputerUseClarificationReference: Codable, Equatable, Sendable {
    public let taskID: String
    public let nonce: UUID
    public let expiresAt: Date

    public init(taskID: String, nonce: UUID = UUID(), expiresAt: Date) throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 256,
              !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              expiresAt.timeIntervalSince1970.isFinite else { throw ComputerUsePayloadError.invalidIdentifier }
        self.taskID = taskID
        self.nonce = nonce
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case taskID, nonce, expiresAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(taskID: values.decode(String.self, forKey: .taskID),
            nonce: values.decode(UUID.self, forKey: .nonce), expiresAt: values.decode(Date.self, forKey: .expiresAt))
    }
}

/// Facts about one approved action, independent of the task's terminal state.
/// The identifiers are opaque digests; tool arguments never cross this surface.
public struct ComputerUseApprovedActionEvidence: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable { case unconfirmed, confirmed }
    public let actionID: String
    public let state: State
    public let summary: String?
    public let resultDigest: String?

    public init(actionID: String, state: State, summary: String? = nil, resultDigest: String? = nil) throws {
        func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard isDigest(actionID) else { throw ComputerUsePayloadError.invalidIdentifier }
        switch state {
        case .unconfirmed:
            guard summary == nil, resultDigest == nil else { throw ComputerUsePayloadError.invalidActionEvidence }
        case .confirmed:
            guard let summary, !summary.isEmpty, summary.count <= 4_000, summary.utf8.count <= 16_000,
                  let resultDigest, isDigest(resultDigest) else { throw ComputerUsePayloadError.invalidActionEvidence }
        }
        self.actionID = actionID
        self.state = state
        self.summary = summary
        self.resultDigest = resultDigest
    }

    private enum CodingKeys: String, CodingKey { case actionID, state, summary, resultDigest }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actionID: values.decode(String.self, forKey: .actionID),
            state: values.decode(State.self, forKey: .state),
            summary: values.decodeIfPresent(String.self, forKey: .summary),
            resultDigest: values.decodeIfPresent(String.self, forKey: .resultDigest))
    }
}

/// Observed research passages, never a terminal answer or authority to act.
/// Kept separate from the short intervention signal so findings are not cut
/// off by its 500-character limit. Render the text literally, not as Markdown.
public struct ComputerUseResearchProgress: Codable, Equatable, Sendable {
    public static let maximumTextBytes = 16 * 1_024
    public let reportID: String
    public let text: String

    public init(reportID: String, text: String) throws {
        guard reportID.utf8.count == 64,
              reportID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !text.isEmpty, text.utf8.count <= Self.maximumTextBytes else {
            throw ComputerUsePayloadError.invalidResearchProgress
        }
        self.reportID = reportID; self.text = text
    }

    private enum CodingKeys: String, CodingKey { case reportID, text }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reportID: values.decode(String.self, forKey: .reportID),
            text: values.decode(String.self, forKey: .text))
    }
}

/// Complete scoped questions may include the retained 32 KiB user source,
/// display escaping and nearby context. A live answer reference must never be
/// paired with silently truncated text. Ordinary task updates keep their cap.
public enum ComputerUseClarificationText {
    public static let maximumCharacters = 64 * 1_024
    public static let maximumUTF8Bytes = 128 * 1_024

    public static func isValid(_ text: String) -> Bool {
        text.count <= maximumCharacters && text.utf8.count <= maximumUTF8Bytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Advisory input rules for this one question. The host still validates the
/// retained request and answer; these fields never grant continuation authority.
public struct ComputerUseClarificationAnswerPolicy: Codable, Equatable, Sendable {
    public enum Rejection: String, Codable, Equatable, Sendable {
        case blank, tooLong, formatMismatch
        public var message: String {
            switch self {
            case .blank: return "Enter an answer with some text for this question."
            case .tooLong: return "This answer is too long for this question. Shorten it before sending."
            case .formatMismatch: return "Use the answer format shown in this question."
            }
        }
    }
    /// Native admission and scalar compilation use this same bounded grammar.
    /// It consumes the complete answer; extra requirements are never discarded.
    public enum Format: String, Codable, Equatable, Sendable {
        case adultCount, childCount, partyCounts
        public var instruction: String {
            switch self {
            case .adultCount: return "Enter only an adult count from 0 to 999, such as 3 adults."
            case .childCount: return "Enter only a child count from 0 to 999, such as 0 children."
            case .partyCounts: return "Enter both adult and child counts from 0 to 999, such as 3 adults and 0 children."
            }
        }
        public func accepts(_ answer: String) -> Bool {
            guard answer.utf8.count <= 32 * 1_024, !Self.containsFormatControls(answer) else { return false }
            switch self {
            case .adultCount, .childCount: return count(in: answer) != nil
            case .partyCounts: return Self.partyLiteral(in: Self.answerSource(answer)) != nil
            }
        }
        public func count(in answer: String) -> Int64? {
            guard self != .partyCounts, answer.utf8.count <= 32 * 1_024,
                  !Self.containsFormatControls(answer) else { return nil }
            let source = Self.answerSource(answer)
            let category = self == .adultCount ? "adults?" : "(?:children|child)"
            let pattern = #"(?:exactly\s+)?"# + Self.numberPattern + #"\s+"# + category
            guard let match = Self.completeMatch(pattern, source: source),
                  let numberRange = Range(match.range(at: 1), in: source) else { return nil }
            return Self.number(String(source[numberRange]))
        }
        /// Shared with native source partitioning, so a recognized party and
        /// its category spans cannot use different literal grammars.
        public static let partyComponentPattern = numberPattern + #"\s+(adults?|children|child)"#
        public static var partyLiteralPattern: String {
            let separator = #"(?:\s*,?\s+and\s+|\s*,\s*|\s*&\s*|\s+)"#
            return #"(?:for\s+)?(?:exactly\s+)?"# + partyComponentPattern + separator + partyComponentPattern
        }
        public static func partyLiteral(in source: String) -> PartyCounts? {
            guard source.utf8.count <= 32 * 1_024, !containsFormatControls(source),
                  let match = completeMatch(partyLiteralPattern, source: source) else { return nil }
            let captures = (1...4).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: source) else { return nil }
                return String(source[range])
            }
            guard captures.count == 4, let first = number(captures[0]), let second = number(captures[2]) else { return nil }
            let firstIsAdult = captures[1].lowercased().hasPrefix("adult")
            let secondIsAdult = captures[3].lowercased().hasPrefix("adult")
            guard firstIsAdult != secondIsAdult else { return nil }
            return PartyCounts(adults: firstIsAdult ? first : second, children: firstIsAdult ? second : first)
        }
        private static let numberPattern = #"([0-9]{1,3}|zero|one|two|three|four|five|six|seven|eight|nine|ten)"#
        private static func number(_ source: String) -> Int64? {
            if let count = Int64(source), (0...999).contains(count) { return count }
            return ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
                .firstIndex(of: source.lowercased()).map { Int64($0) }
        }
        private static func completeMatch(_ pattern: String, source: String) -> NSTextCheckingResult? {
            let range = NSRange(source.startIndex..., in: source)
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: source, range: range), match.range == range else { return nil }
            return match
        }
        private static func containsFormatControls(_ source: String) -> Bool {
            source.unicodeScalars.contains { $0.properties.generalCategory == .format }
        }
        private static func answerSource(_ answer: String) -> String {
            var source = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.lowercased().hasPrefix("and ") { source = String(source.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let last = source.last, ".,;".contains(last) { source.removeLast() }
            return source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    public struct PartyCounts: Equatable, Sendable {
        public let adults: Int64
        public let children: Int64
        fileprivate init(adults: Int64, children: Int64) { self.adults = adults; self.children = children }
    }

    public let maximumUTF8Bytes: Int
    public let requiresNonblank: Bool
    public let supportsRetry: Bool
    public let format: Format?

    public init(maximumUTF8Bytes: Int, requiresNonblank: Bool, supportsRetry: Bool = false, format: Format? = nil) throws {
        guard (1...(32 * 1_024)).contains(maximumUTF8Bytes) else { throw ComputerUsePayloadError.invalidClarification }
        self.maximumUTF8Bytes = maximumUTF8Bytes; self.requiresNonblank = requiresNonblank; self.supportsRetry = supportsRetry
        self.format = format
    }
    public func rejection(of text: String) -> Rejection? {
        if requiresNonblank && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        if text.utf8.count > maximumUTF8Bytes { return .tooLong }
        if let format, !format.accepts(text) { return .formatMismatch }
        return nil
    }
    public func message(for rejection: Rejection) -> String {
        rejection == .formatMismatch ? (format?.instruction ?? rejection.message) : rejection.message
    }
    private enum CodingKeys: String, CodingKey { case maximumUTF8Bytes, requiresNonblank, supportsRetry, format, extendedFormat }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try values.decodeIfPresent(Format.self, forKey: .format)
        let extended = try values.decodeIfPresent(String.self, forKey: .extendedFormat)
        guard legacy != .partyCounts, legacy == nil || extended == nil,
              extended.map({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } }) ?? true else {
            throw ComputerUsePayloadError.invalidClarification
        }
        // New format kinds use a separate advisory field. Earlier phones can
        // read the complete question while ignoring a format they do not know.
        // Unknown future kinds are not advertised as supported in an answer.
        let format: Format? = extended == "partyCounts" ? .partyCounts : legacy
        try self.init(maximumUTF8Bytes: values.decode(Int.self, forKey: .maximumUTF8Bytes),
            requiresNonblank: values.decode(Bool.self, forKey: .requiresNonblank),
            supportsRetry: values.decodeIfPresent(Bool.self, forKey: .supportsRetry) ?? false, format: format)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximumUTF8Bytes, forKey: .maximumUTF8Bytes)
        try values.encode(requiresNonblank, forKey: .requiresNonblank)
        if supportsRetry { try values.encode(true, forKey: .supportsRetry) }
        if format == .partyCounts { try values.encode("partyCounts", forKey: .extendedFormat) }
        else { try values.encodeIfPresent(format, forKey: .format) }
    }
}

/// A rejected answer attempt may return the same still-live question. The
/// receiver must match this reference to its submitted answer before restoring
/// its composer; the retry is not an accepted user turn or a new question.
public struct ComputerUseClarificationRetry: Codable, Equatable, Sendable {
    public let reference: ComputerUseClarificationReference
    public let reason: ComputerUseClarificationAnswerPolicy.Rejection
    public let answerPolicy: ComputerUseClarificationAnswerPolicy
    public init(reference: ComputerUseClarificationReference, reason: ComputerUseClarificationAnswerPolicy.Rejection,
                answerPolicy: ComputerUseClarificationAnswerPolicy) throws {
        guard answerPolicy.supportsRetry, reason != .formatMismatch || answerPolicy.format != nil else {
            throw ComputerUsePayloadError.invalidClarification
        }
        self.reference = reference; self.reason = reason; self.answerPolicy = answerPolicy
    }
    private enum CodingKeys: String, CodingKey { case reference, reason, answerPolicy }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: values.decode(ComputerUseClarificationReference.self, forKey: .reference),
            reason: values.decode(ComputerUseClarificationAnswerPolicy.Rejection.self, forKey: .reason),
            answerPolicy: values.decode(ComputerUseClarificationAnswerPolicy.self, forKey: .answerPolicy))
    }
}

/// Read-only question recovery, carried in a status envelope. The fresh probe
/// ID distinguishes a current native-owner check from old mailbox replies.
public struct ComputerUseClarificationProbe: Codable, Equatable, Sendable {
    public let probeID: UUID
    public let reference: ComputerUseClarificationReference
    public init(probeID: UUID = UUID(), reference: ComputerUseClarificationReference) {
        self.probeID = probeID; self.reference = reference
    }
    private enum CodingKeys: String, CodingKey { case type, probeID, reference }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .type) == "clarificationProbe" else { throw ComputerUsePayloadError.invalidClarification }
        probeID = try values.decode(UUID.self, forKey: .probeID)
        reference = try values.decode(ComputerUseClarificationReference.self, forKey: .reference)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("clarificationProbe", forKey: .type)
        try values.encode(probeID, forKey: .probeID); try values.encode(reference, forKey: .reference)
    }
    public func encodedBody() throws -> String { try encodeComputerUseBody(self) }
    public static func decodeBody(_ body: String) throws -> Self {
        guard body.utf8.count <= 2_048 else { throw ComputerUsePayloadError.payloadTooLarge }
        return try decodeComputerUseBody(body, as: Self.self)
    }
}

/// A host-provided option for resolving one live clarification. The opaque ID
/// binds a later selection to the host's retained candidate; labels/details
/// are display data and never expand the original task's authority.
public struct ComputerUseClarificationChoice: Codable, Equatable, Sendable {
    public static let maximumChoices = 8
    public static let maximumIDBytes = 128
    public static let maximumDisplayBytes = 512

    public let id: String
    public let label: String
    public let detail: String?

    public init(id: String, label: String, detail: String? = nil) throws {
        guard Self.validID(id), Self.validDisplay(label), detail.map(Self.validDisplay) ?? true else {
            throw ComputerUsePayloadError.invalidClarification
        }
        self.id = id
        self.label = label
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case id, label, detail }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      label: values.decode(String.self, forKey: .label),
                      detail: values.decodeIfPresent(String.self, forKey: .detail))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encodeIfPresent(detail, forKey: .detail)
    }

    public static func validate(_ choices: [Self]?) throws {
        guard let choices else { return }
        guard (1...maximumChoices).contains(choices.count),
              Set(choices.map(\.id)).count == choices.count,
              choices.allSatisfy({ validID($0.id) && validDisplay($0.label) && ($0.detail.map(validDisplay) ?? true) }) else {
            throw ComputerUsePayloadError.invalidClarification
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumIDBytes
    }

    private static func validDisplay(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumDisplayBytes
    }
}

public struct ComputerUseClarificationProbeResult: Codable, Equatable, Sendable {
    public let probeID: UUID
    public let reference: ComputerUseClarificationReference
    /// Nil means the original native question is unavailable, not completed.
    public let question: String?
    public let answerPolicy: ComputerUseClarificationAnswerPolicy?
    public let clarificationChoices: [ComputerUseClarificationChoice]?
    public init(probeID: UUID, reference: ComputerUseClarificationReference, question: String?,
                answerPolicy: ComputerUseClarificationAnswerPolicy? = nil,
                clarificationChoices: [ComputerUseClarificationChoice]? = nil) throws {
        guard question.map(ComputerUseClarificationText.isValid) ?? (answerPolicy == nil) else {
            throw ComputerUsePayloadError.invalidClarification
        }
        try ComputerUseClarificationChoice.validate(clarificationChoices)
        guard clarificationChoices == nil || question != nil else { throw ComputerUsePayloadError.invalidClarification }
        self.probeID = probeID; self.reference = reference; self.question = question; self.answerPolicy = answerPolicy
        self.clarificationChoices = clarificationChoices
    }
    private enum CodingKeys: String, CodingKey { case type, probeID, reference, question, answerPolicy, clarificationChoices }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .type) == "clarificationProbeResult" else { throw ComputerUsePayloadError.invalidClarification }
        try self.init(probeID: values.decode(UUID.self, forKey: .probeID), reference: values.decode(ComputerUseClarificationReference.self, forKey: .reference),
            question: values.decodeIfPresent(String.self, forKey: .question), answerPolicy: values.decodeIfPresent(ComputerUseClarificationAnswerPolicy.self, forKey: .answerPolicy),
            clarificationChoices: values.decodeIfPresent([ComputerUseClarificationChoice].self, forKey: .clarificationChoices))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("clarificationProbeResult", forKey: .type)
        try values.encode(probeID, forKey: .probeID); try values.encode(reference, forKey: .reference)
        try values.encodeIfPresent(question, forKey: .question); try values.encodeIfPresent(answerPolicy, forKey: .answerPolicy)
        try values.encodeIfPresent(clarificationChoices, forKey: .clarificationChoices)
    }
    public func encodedBody() throws -> String { try encodeComputerUseBody(self) }
    public static func decodeBody(_ body: String) throws -> Self { try decodeComputerUseBody(body, as: Self.self) }
}

/// Correlates assistant/status traffic with the stable privileged prompt ID.
/// A delayed lifecycle replay cannot replace a newer task, while optional
/// action evidence can still annotate its original request.
public struct ComputerUseTaskUpdate: Codable, Equatable, Sendable {
    public let taskID: String
    public let text: String
    /// Highest versioned lifecycle revision durably applied by the host when
    /// this update was created. `nil` preserves decoding and behavior for
    /// peers that predate ordered controls.
    public let appliedControlRevision: UInt64?
    /// Independent durable clock for host-local takeover and handback. A
    /// greater epoch supersedes older nonterminal phone intents without
    /// pretending their revisions were applied. Evidence-only updates omit it.
    public let hostControlEpoch: UInt64?
    /// A machine-readable result for terminal assistant replies and resumable
    /// person-only status updates. `nil` preserves wire compatibility with
    /// peers that only understand the existing text and status prefix.
    public let outcome: ComputerUseTerminalOutcome?
    public let clarification: ComputerUseClarificationReference?
    public let clarificationAnswerPolicy: ComputerUseClarificationAnswerPolicy?
    public let clarificationRetry: ComputerUseClarificationRetry?
    public let clarificationChoices: [ComputerUseClarificationChoice]?
    public let supportsClarificationRecovery: Bool
    public let approvedActionEvidence: ComputerUseApprovedActionEvidence?
    /// Carried in a status envelope. It updates historical evidence only and
    /// cannot acknowledge controls, finish a task or open an approval flow.
    public let isApprovedActionEvidenceOnly: Bool
    /// Only valid on a scoped, ordered, resumable intervention status.
    public let researchProgress: ComputerUseResearchProgress?

    public init(
        taskID: String,
        text: String,
        appliedControlRevision: UInt64? = nil,
        hostControlEpoch: UInt64? = nil,
        outcome: ComputerUseTerminalOutcome? = nil,
        clarification: ComputerUseClarificationReference? = nil,
        clarificationAnswerPolicy: ComputerUseClarificationAnswerPolicy? = nil,
        clarificationRetry: ComputerUseClarificationRetry? = nil,
        clarificationChoices: [ComputerUseClarificationChoice]? = nil,
        supportsClarificationRecovery: Bool = false,
        approvedActionEvidence: ComputerUseApprovedActionEvidence? = nil,
        isApprovedActionEvidenceOnly: Bool = false,
        researchProgress: ComputerUseResearchProgress? = nil
    ) {
        self.taskID = taskID
        let question = outcome == .userInterventionRequired && clarification?.taskID == taskID ? clarification : nil
        self.text = question == nil && clarificationRetry == nil ? String(text.prefix(8_000)) : text
        self.appliedControlRevision = appliedControlRevision
        self.hostControlEpoch = hostControlEpoch
        self.outcome = outcome
        self.clarification = question
        self.clarificationAnswerPolicy = clarificationAnswerPolicy
        self.clarificationRetry = clarificationRetry
        self.clarificationChoices = clarificationChoices
        self.supportsClarificationRecovery = supportsClarificationRecovery
        self.approvedActionEvidence = approvedActionEvidence
        self.isApprovedActionEvidenceOnly = isApprovedActionEvidenceOnly
        self.researchProgress = researchProgress
    }

    private enum CodingKeys: String, CodingKey {
        case taskID
        case text
        case appliedControlRevision
        case hostControlEpoch
        case outcome
        case clarification
        case clarificationAnswerPolicy
        case clarificationRetry
        case clarificationChoices
        case supportsClarificationRecovery
        case approvedActionEvidence
        case isApprovedActionEvidenceOnly
        case researchProgress
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try values.decode(String.self, forKey: .taskID)
        text = try values.decode(String.self, forKey: .text)
        appliedControlRevision = try values.decodeIfPresent(
            UInt64.self,
            forKey: .appliedControlRevision)
        hostControlEpoch = try values.decodeIfPresent(UInt64.self, forKey: .hostControlEpoch)
        let rawOutcome = try values.decodeIfPresent(
            String.self,
            forKey: .outcome)
        if let rawOutcome {
            // A newer peer may add another result category. Preserve the
            // correlated text update and fall back to legacy presentation
            // instead of rejecting the entire JSON envelope.
            outcome = ComputerUseTerminalOutcome(rawValue: rawOutcome)
        } else {
            outcome = nil
        }
        let reference = try values.decodeIfPresent(ComputerUseClarificationReference.self, forKey: .clarification)
        clarification = outcome == .userInterventionRequired && reference?.taskID == taskID ? reference : nil
        clarificationAnswerPolicy = try values.decodeIfPresent(ComputerUseClarificationAnswerPolicy.self, forKey: .clarificationAnswerPolicy)
        clarificationRetry = try values.decodeIfPresent(ComputerUseClarificationRetry.self, forKey: .clarificationRetry)
        clarificationChoices = try values.decodeIfPresent([ComputerUseClarificationChoice].self, forKey: .clarificationChoices)
        supportsClarificationRecovery = try values.decodeIfPresent(Bool.self, forKey: .supportsClarificationRecovery) ?? false
        approvedActionEvidence = try values.decodeIfPresent(ComputerUseApprovedActionEvidence.self, forKey: .approvedActionEvidence)
        isApprovedActionEvidenceOnly = try values.decodeIfPresent(Bool.self, forKey: .isApprovedActionEvidenceOnly) ?? false
        researchProgress = try values.decodeIfPresent(ComputerUseResearchProgress.self, forKey: .researchProgress)
        if researchProgress != nil && reference != nil { throw ComputerUsePayloadError.invalidResearchProgress }
        if isApprovedActionEvidenceOnly && (rawOutcome != nil || reference != nil) {
            throw ComputerUsePayloadError.invalidActionEvidence
        }
        try validatePayloadUse()
    }

    public func encode(to encoder: Encoder) throws {
        try validatePayloadUse()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(taskID, forKey: .taskID)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(
            appliedControlRevision,
            forKey: .appliedControlRevision)
        try values.encodeIfPresent(hostControlEpoch, forKey: .hostControlEpoch)
        try values.encodeIfPresent(outcome?.rawValue, forKey: .outcome)
        try values.encodeIfPresent(clarification, forKey: .clarification)
        try values.encodeIfPresent(clarificationAnswerPolicy, forKey: .clarificationAnswerPolicy)
        try values.encodeIfPresent(clarificationRetry, forKey: .clarificationRetry)
        try values.encodeIfPresent(clarificationChoices, forKey: .clarificationChoices)
        if supportsClarificationRecovery { try values.encode(true, forKey: .supportsClarificationRecovery) }
        try values.encodeIfPresent(approvedActionEvidence, forKey: .approvedActionEvidence)
        if isApprovedActionEvidenceOnly { try values.encode(true, forKey: .isApprovedActionEvidenceOnly) }
        try values.encodeIfPresent(researchProgress, forKey: .researchProgress)
    }

    private func validatePayloadUse() throws {
        try ComputerUseClarificationChoice.validate(clarificationChoices)
        if clarificationChoices != nil, (outcome != .userInterventionRequired || clarification == nil || clarificationRetry != nil) {
            throw ComputerUsePayloadError.invalidClarification
        }
        if supportsClarificationRecovery {
            guard outcome == .userInterventionRequired, clarification != nil || clarificationRetry != nil else {
                throw ComputerUsePayloadError.invalidClarification
            }
        }
        if let retry = clarificationRetry {
            guard outcome == .userInterventionRequired, clarification == nil, clarificationAnswerPolicy == nil,
                  retry.reference.taskID != taskID, approvedActionEvidence == nil, !isApprovedActionEvidenceOnly,
                  researchProgress == nil, ComputerUseClarificationText.isValid(text) else {
                throw ComputerUsePayloadError.invalidClarification
            }
        }
        if clarificationAnswerPolicy != nil && clarification == nil { throw ComputerUsePayloadError.invalidClarification }
        if clarification != nil, !ComputerUseClarificationText.isValid(text) {
            throw ComputerUsePayloadError.invalidClarification
        }
        if researchProgress != nil {
            guard !isApprovedActionEvidenceOnly, clarification == nil,
                  outcome == .userInterventionRequired,
                  appliedControlRevision != nil, hostControlEpoch != nil,
                  ComputerUseStatusSignal.userInterventionMessage(from: text) != nil else {
                throw ComputerUsePayloadError.invalidResearchProgress
            }
        }
        guard !isApprovedActionEvidenceOnly || (approvedActionEvidence != nil && text.isEmpty
            && appliedControlRevision == nil && hostControlEpoch == nil && outcome == nil && clarification == nil) else {
            throw ComputerUsePayloadError.invalidActionEvidence
        }
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
    /// Strict host admission uses the same declared fields as the shipped
    /// encoder/decoder, so adding optional transport metadata cannot make
    /// every current client request fail an older handwritten allowlist.
    public static let wireFieldNames = Set(CodingKeys.allCases.map(\.rawValue))
    public static let maximumConversationTurns = 12
    public static let maximumTurnLength = 4_000
    public static let maximumPromptLength = 8_000

    public let version: Int
    public let prompt: String
    public let conversation: [ComputerUseConversationTurn]
    public let clarification: ComputerUseClarificationReference?
    /// The selected host option for this exact clarification. The selected
    /// display label remains the prompt text; this opaque ID is transport-only.
    public let clarificationChoiceID: String?
    /// Allows evidence-only status updates. Older clients receive optional
    /// evidence only on their existing lifecycle replies.
    public let supportsApprovedActionEvidence: Bool
    public let supportsClarificationRetry: Bool
    /// Answer-only opt-in: older retry clients cannot decode formatMismatch.
    public let supportsClarificationFormatRetry: Bool

    public init(
        prompt: String,
        conversation: [ComputerUseConversationTurn] = [],
        supportsApprovedActionEvidence: Bool = false
    ) {
        version = Self.currentVersion
        self.prompt = Self.boundedPrompt(prompt)
        self.conversation = Self.boundedConversation(conversation)
        clarification = nil
        clarificationChoiceID = nil
        self.supportsApprovedActionEvidence = supportsApprovedActionEvidence
        self.supportsClarificationRetry = false
        self.supportsClarificationFormatRetry = false
    }

    /// A clarification answer is exact user input, not a bounded chat-history
    /// excerpt. Reject an oversized answer instead of truncating its payload.
    public static func answering(_ reference: ComputerUseClarificationReference, text: String,
        supportsApprovedActionEvidence: Bool = false, supportsClarificationRetry: Bool = false,
        supportsClarificationFormatRetry: Bool = false, clarificationChoiceID: String? = nil) throws -> Self {
        try Self(exactAnswer: text, reference: reference, supportsApprovedActionEvidence: supportsApprovedActionEvidence,
            supportsClarificationRetry: supportsClarificationRetry, supportsClarificationFormatRetry: supportsClarificationFormatRetry,
            clarificationChoiceID: clarificationChoiceID)
    }

    private init(exactAnswer: String, reference: ComputerUseClarificationReference, supportsApprovedActionEvidence: Bool,
                 supportsClarificationRetry: Bool, supportsClarificationFormatRetry: Bool,
                 clarificationChoiceID: String?) throws {
        guard !supportsClarificationFormatRetry || supportsClarificationRetry else { throw ComputerUsePayloadError.invalidClarification }
        if let clarificationChoiceID {
            guard !clarificationChoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  clarificationChoiceID.utf8.count <= ComputerUseClarificationChoice.maximumIDBytes else {
                throw ComputerUsePayloadError.invalidClarification
            }
        }
        try Self.validateExactAnswer(exactAnswer)
        version = Self.currentVersion
        prompt = exactAnswer
        conversation = []
        clarification = reference
        self.clarificationChoiceID = clarificationChoiceID
        self.supportsApprovedActionEvidence = supportsApprovedActionEvidence
        self.supportsClarificationRetry = supportsClarificationRetry
        self.supportsClarificationFormatRetry = supportsClarificationFormatRetry
    }

    private static func validateExactAnswer(_ text: String) throws {
        guard !text.isEmpty, text.count <= maximumPromptLength, text.utf8.count <= 32 * 1_024 else {
            throw ComputerUsePayloadError.payloadTooLarge
        }
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case prompt
        case conversation
        case clarification
        case clarificationChoiceID
        case supportsApprovedActionEvidence
        case supportsClarificationRetry
        case supportsClarificationFormatRetry
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        clarification = try values.decodeIfPresent(ComputerUseClarificationReference.self, forKey: .clarification)
        clarificationChoiceID = try values.decodeIfPresent(String.self, forKey: .clarificationChoiceID)
        if let clarificationChoiceID {
            guard clarification != nil,
                  !clarificationChoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  clarificationChoiceID.utf8.count <= ComputerUseClarificationChoice.maximumIDBytes else {
                throw ComputerUsePayloadError.invalidClarification
            }
        }
        supportsApprovedActionEvidence = try values.decodeIfPresent(Bool.self, forKey: .supportsApprovedActionEvidence) ?? false
        supportsClarificationRetry = try values.decodeIfPresent(Bool.self, forKey: .supportsClarificationRetry) ?? false
        supportsClarificationFormatRetry = try values.decodeIfPresent(Bool.self, forKey: .supportsClarificationFormatRetry) ?? false
        guard !supportsClarificationFormatRetry || (supportsClarificationRetry && clarification != nil) else {
            throw ComputerUsePayloadError.invalidClarification
        }
        let rawPrompt = try values.decode(String.self, forKey: .prompt)
        if clarification != nil {
            try Self.validateExactAnswer(rawPrompt)
            prompt = rawPrompt
        } else {
            prompt = Self.boundedPrompt(rawPrompt)
        }
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
        try values.encodeIfPresent(clarification, forKey: .clarification)
        try values.encodeIfPresent(clarificationChoiceID, forKey: .clarificationChoiceID)
        if supportsApprovedActionEvidence { try values.encode(true, forKey: .supportsApprovedActionEvidence) }
        if supportsClarificationRetry { try values.encode(true, forKey: .supportsClarificationRetry) }
        if supportsClarificationFormatRetry { try values.encode(true, forKey: .supportsClarificationFormatRetry) }
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
public struct ComputerUseEnvelope: Codable, Identifiable, Equatable, Sendable {
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
    case invalidIdentifier
    case payloadTooLarge
    case invalidActionEvidence
    case invalidResearchProgress
    case invalidClarification
}
