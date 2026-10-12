import CryptoKit
import Foundation

/// Experimental work remains disabled until explicitly enabled by the host.
enum ComputerUseFeatureFlags {
    static let experimentalPreferenceKey = "computerUseExperimental"

    static var experimental: Bool { isExperimentalEnabled(in: .standard) }

    static func isExperimentalEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: experimentalPreferenceKey)
    }

    static var computerUseV2: Bool { UserDefaults.standard.bool(forKey: "computerUseV2") }
}

/// A small, deterministic JSON representation kept independent from the MCP
/// SDK. Planner, policy, and approval code can therefore exchange tool calls
/// without retaining SDK transport objects or losing integer fidelity.
indirect enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    /// Index schemas require an exact integer, including integral JSON doubles.
    /// Preserve native integer precision and never truncate fractional values.
    var exactInteger: Int? {
        switch self {
        case .integer(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "MCP JSON numbers must be finite.")
            }
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MCPJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported MCP JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "MCP JSON numbers must be finite."))
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum MCPToolRisk: String, Codable, Equatable, Sendable {
    /// Observes state without changing the Mac.
    case readOnly
    /// A specifically reviewed, bounded change with a straightforward undo.
    case reversible
    /// A mutation that must stop at the iOS approval boundary.
    case approvalRequired
    /// Never exposed to the planner and never executable through this host.
    case blocked

    var isMutation: Bool {
        self == .reversible || self == .approvalRequired
    }

    var requiresApproval: Bool {
        self == .approvalRequired
    }
}

struct MCPApprovalDisplay: Codable, Equatable, Sendable {
    let summary: String
    let details: String
    let confirmLabel: String

    init(summary: String, details: String, confirmLabel: String) {
        self.summary = String(summary.prefix(240))
        self.details = String(details.prefix(1_000))
        self.confirmLabel = String(confirmLabel.prefix(80))
    }
}

struct MCPProcessIdentity: Codable, Equatable, Sendable {
    let serverID: String
    let processGeneration: UInt64
    let processIdentifier: Int32
    let binaryPath: String
    let launchedAt: Date
}

/// One server-advertised tool after the host has intersected it with the
/// pinned registry allowlist. Server annotations are intentionally absent:
/// risk and approval copy come from the host-owned policy only.
struct MCPAllowedTool: Codable, Equatable, Sendable {
    let serverID: String
    let processGeneration: UInt64
    let toolName: String
    let description: String
    let inputSchema: MCPJSONValue
    let schemaDigest: String
    let risk: MCPToolRisk
    let approval: MCPApprovalDisplay

    init(
        serverID: String,
        processGeneration: UInt64,
        toolName: String,
        description: String,
        inputSchema: MCPJSONValue,
        risk: MCPToolRisk,
        approval: MCPApprovalDisplay
    ) throws {
        self.serverID = serverID
        self.processGeneration = processGeneration
        self.toolName = toolName
        self.description = String(description.prefix(2_000))
        self.inputSchema = inputSchema
        self.schemaDigest = try MCPDigest.sha256(of: inputSchema)
        self.risk = risk
        self.approval = approval
    }

    func makeCall(
        taskID: String,
        arguments: [String: MCPJSONValue],
        stepEffectID: String? = nil
    ) throws -> MCPToolCall {
        try MCPToolSafetyPolicy.validateArguments(
            toolName: toolName,
            arguments: arguments)
        let assessment = MCPToolSafetyPolicy.assess(
            toolName: toolName,
            arguments: arguments)
        guard assessment.risk != .blocked,
              assessment.risk == risk else {
            throw MCPClientError.toolNotAllowed(toolName)
        }
        return try MCPToolCall(
            taskID: taskID,
            serverID: serverID,
            processGeneration: processGeneration,
            toolName: toolName,
            arguments: arguments,
            schemaDigest: schemaDigest,
            risk: assessment.risk,
            approval: assessment.approval,
            stepEffectID: stepEffectID)
    }
}

/// Canonical call material used for policy, approval, and durable at-most-once
/// mutation records. `canonicalDigest` intentionally excludes the sidecar
/// generation so a host restart cannot make an ambiguous mutation retryable.
struct MCPToolCall: Codable, Equatable, Sendable {
    static let maximumCanonicalArgumentBytes = 64 * 1_024

    let taskID: String
    let serverID: String
    let processGeneration: UInt64
    let toolName: String
    let arguments: [String: MCPJSONValue]
    let canonicalArguments: String
    let argumentsDigest: String
    let canonicalDigest: String
    /// Host task-contract effect identity, never a tool argument or model-
    /// chosen retry nonce. Nil preserves the original single-action identity.
    let stepEffectID: String?
    let schemaDigest: String
    let risk: MCPToolRisk
    let approvalSummary: String
    let approvalDetails: String
    let approvalConfirmLabel: String

    init(
        taskID: String,
        serverID: String,
        processGeneration: UInt64,
        toolName: String,
        arguments: [String: MCPJSONValue],
        schemaDigest: String,
        risk: MCPToolRisk,
        approval: MCPApprovalDisplay,
        stepEffectID: String? = nil
    ) throws {
        let trimmedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTaskID.isEmpty,
              !serverID.isEmpty,
              !toolName.isEmpty,
              !schemaDigest.isEmpty else {
            throw MCPClientError.invalidArguments("The MCP call identity is incomplete.")
        }
        if let stepEffectID {
            guard risk == .approvalRequired, stepEffectID.utf8.count == 64,
                  stepEffectID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw MCPClientError.invalidArguments("The approved task-step identity is invalid.")
            }
        }

        let canonicalData = try MCPDigest.canonicalData(
            for: MCPJSONValue.object(arguments))
        guard canonicalData.count <= Self.maximumCanonicalArgumentBytes,
              let canonicalArguments = String(data: canonicalData, encoding: .utf8) else {
            throw MCPClientError.invalidArguments(
                "The MCP tool arguments exceed the 64 KB safety limit.")
        }
        let argumentsDigest = MCPDigest.sha256(canonicalData)
        var callMaterial = Data()
        for component in [
            trimmedTaskID, serverID, toolName, schemaDigest, canonicalArguments,
        ] {
            callMaterial.append(Data(component.utf8))
            callMaterial.append(0)
        }
        if let stepEffectID {
            callMaterial.append(Data("approved-task-step-v1".utf8))
            callMaterial.append(0)
            callMaterial.append(Data(stepEffectID.utf8))
            callMaterial.append(0)
        }

        self.taskID = trimmedTaskID
        self.serverID = serverID
        self.processGeneration = processGeneration
        self.toolName = toolName
        self.arguments = arguments
        self.canonicalArguments = canonicalArguments
        self.argumentsDigest = argumentsDigest
        self.canonicalDigest = MCPDigest.sha256(callMaterial)
        self.stepEffectID = stepEffectID
        self.schemaDigest = schemaDigest
        self.risk = risk
        self.approvalSummary = approval.summary
        self.approvalDetails = approval.details
        self.approvalConfirmLabel = approval.confirmLabel
    }

    var approvalDisplay: MCPApprovalDisplay {
        MCPApprovalDisplay(
            summary: approvalSummary,
            details: approvalDetails,
            confirmLabel: approvalConfirmLabel)
    }
}

struct MCPApprovalFingerprint: Codable, Equatable, Hashable, Sendable {
    let serverID: String
    let processGeneration: UInt64
    let toolName: String
    let canonicalDigest: String
    let schemaDigest: String
    let mailAttachmentDigest: String?

    init(call: MCPToolCall, mailAttachmentDigest: String? = nil) {
        serverID = call.serverID
        processGeneration = call.processGeneration
        toolName = call.toolName
        canonicalDigest = call.canonicalDigest
        schemaDigest = call.schemaDigest
        self.mailAttachmentDigest = mailAttachmentDigest
    }

    /// Attachment bytes are host-prepared approval material, so they augment
    /// the call identity without changing the canonical MCP call itself.
    func matches(call: MCPToolCall) -> Bool {
        serverID == call.serverID
            && processGeneration == call.processGeneration
            && toolName == call.toolName
            && canonicalDigest == call.canonicalDigest
            && schemaDigest == call.schemaDigest
    }
}

struct MCPPreparedApproval: Codable, Equatable, Sendable {
    let call: MCPToolCall
    let fingerprint: MCPApprovalFingerprint
    let display: MCPApprovalDisplay
}

struct MCPToolResult: Codable, Equatable, Sendable {
    let text: String
    let structuredContent: MCPJSONValue?
    let isError: Bool
    let wasTruncated: Bool
    let resultDigest: String

    init(
        text: String,
        structuredContent: MCPJSONValue?,
        isError: Bool,
        wasTruncated: Bool
    ) throws {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
        self.wasTruncated = wasTruncated
        self.resultDigest = try MCPDigest.sha256(of: .object([
            "text": .string(text),
            "structuredContent": structuredContent ?? .null,
            "isError": .bool(isError),
            "wasTruncated": .bool(wasTruncated),
        ]))
    }
}

enum MCPMutationClaim: Equatable, Sendable {
    case new
    case completed(MCPToolResult)
    case ambiguous
}

/// Confirmation of one exact approved operation. This is deliberately not a
/// ComputerUseExecutionResult: an action receipt is not whole-task completion.
struct MCPApprovedActionResult: Equatable, Sendable {
    let callDigest: String
    let response: String
    let completionPromptDigest: String?

    static func verified(call: MCPToolCall, result: MCPToolResult,
                         trustedUserPrompt: String) throws -> MCPApprovedActionResult {
        if call.serverID == RemoteDesktopCloudStorageMCP.serverID,
           call.toolName == RemoteDesktopCloudStorageMCP.toolName {
            return try RemoteDesktopCloudStorage.verified(
                call: call, result: result, trustedUserPrompt: trustedUserPrompt)
        }
        guard call.risk == .approvalRequired,
              call.serverID == RemoteDesktopMailMCP.serverID,
              call.toolName == RemoteDesktopMailMCP.toolName,
              !result.isError, !result.wasTruncated,
              case .object(let content)? = result.structuredContent,
              let mail = try? RemoteDesktopMailRequest(arguments: call.arguments),
              case .string(let status)? = content["status"],
              status == (mail.sendNow ? "accepted_for_sending" : "draft_opened"),
              Self.hasExpectedAttachmentReceipt(content, mail: mail) else {
            throw MCPClientError.toolFailed("The approved action returned no matching, complete confirmation. It will not be repeated.")
        }
        let response = mail.sendNow
            ? "Mail accepted the approved email for sending."
            : "Email draft opened visibly in Mail for review."
        let provesWholeTask = call.stepEffectID == nil && exactSingleMailRequest(trustedUserPrompt, matches: mail)
        return .init(callDigest: call.canonicalDigest, response: response,
            completionPromptDigest: provesWholeTask ? try MCPDigest.sha256(of: .string(trustedUserPrompt)) : nil)
    }

    private static func hasExpectedAttachmentReceipt(
        _ content: [String: MCPJSONValue], mail: RemoteDesktopMailRequest
    ) -> Bool {
        let expectedNames = mail.attachmentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard !expectedNames.isEmpty else { return Set(content.keys) == ["status"] }
        guard Set(content.keys) == ["status", "attachment_count", "attachment_names", "attachment_digest"],
              content["attachment_count"] == .integer(expectedNames.count),
              case .array(let values)? = content["attachment_names"],
              case .string(let digest)? = content["attachment_digest"],
              digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return values == expectedNames.map(MCPJSONValue.string)
    }

    /// A complete literal command supplies a bounded whole-task proof. Other
    /// natural-language/compound requests retain action-only evidence until a
    /// task compiler verifies every requested outcome. Approval of the call
    /// alone cannot erase their remaining requirements.
    private static func exactSingleMailRequest(_ prompt: String, matches mail: RemoteDesktopMailRequest) -> Bool {
        guard prompt.utf8.count <= 16_384, mail.cc.isEmpty, mail.bcc.isEmpty,
              mail.attachmentPaths.isEmpty else { return false }
        let pattern = #"(?is)^\s*(?:please\s+)?(send|draft)\s+(?:an?\s+)?email\s+to\s+([^\s,;<>"]+@[^\s,;<>"]+)\s+with\s+subject\s+"([^"]*)"\s+and\s+body\s+"([^"]*)"\s*[.!]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) else { return false }
        let values = (1...4).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: prompt) else { return nil }
            return String(prompt[range])
        }
        guard values.count == 4 else { return false }
        let action = values[0].lowercased()
        guard action == "send" || action == "draft" else { return false }
        return (action == "send") == mail.sendNow
            && values[1].utf8.elementsEqual(mail.to.utf8)
            && values[2].utf8.elementsEqual(mail.subject.utf8)
            && values[3].utf8.elementsEqual(mail.body.utf8)
    }
}

/// Persistent implementations must record `.new` before the external call,
/// then atomically store completion. A process death between those points is
/// permanently ambiguous and must never be converted back to `.new`.
protocol MCPMutationCallLedger: Sendable {
    func claim(_ call: MCPToolCall) async throws -> MCPMutationClaim
    func complete(_ call: MCPToolCall, result: MCPToolResult) async throws
    func markAmbiguous(_ call: MCPToolCall) async
}

enum MCPClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidBinary(String)
    case invalidSignature(String)
    case serverMismatch(String)
    case notRunning
    case paginationLoop
    case toolNotAllowed(String)
    case staleCall
    case invalidArguments(String)
    case approvalRequired(MCPApprovalDisplay)
    case approvalMismatch
    case mutationLedgerRequired
    case mutationAmbiguous
    case toolFailed(String)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidBinary(let reason):
            return "The Mac tools helper is invalid: \(reason)"
        case .invalidSignature(let reason):
            return "The Mac tools helper could not be verified: \(reason)"
        case .serverMismatch(let reason):
            return "The Mac tools helper does not match the pinned release: \(reason)"
        case .notRunning:
            return "The Mac tools helper is not running."
        case .paginationLoop:
            return "The Mac tools helper returned an invalid paginated tool list."
        case .toolNotAllowed(let tool):
            return "The Mac tool “\(tool)” is not allowed by this host."
        case .staleCall:
            return "The Mac tools helper changed after this action was planned."
        case .invalidArguments(let reason):
            return "The Mac tool arguments are invalid: \(reason)"
        case .approvalRequired(let display):
            return display.summary
        case .approvalMismatch:
            return "The approved Mac tool action no longer matches the planned action."
        case .mutationLedgerRequired:
            return "A persistent safety record is required before this Mac tool can make changes."
        case .mutationAmbiguous:
            return "The Mac tool may have made this change before its connection ended. It will not be retried automatically."
        case .toolFailed(let message):
            return "The Mac tool reported a failure: \(message)"
        case .transport(let message):
            return "The Mac tools connection failed: \(message)"
        case .cancelled:
            return "The Mac tool action was canceled."
        }
    }
}

enum MCPDigest {
    static func canonicalData(for value: MCPJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(of value: MCPJSONValue) throws -> String {
        sha256(try canonicalData(for: value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
