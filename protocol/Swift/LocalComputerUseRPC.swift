import Foundation

/// A resolved local-network endpoint advertised by the macOS host.
///
/// The endpoint is discovery input, not an authentication claim. Callers must
/// still complete the TLS-PSK handshake with the Keychain credential selected
/// by the host's advertised credential fingerprint.
public struct LocalComputerUseEndpoint:
    Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var isValid: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == host
            && host.utf8.count <= LocalComputerUseRPCLimits.maximumHostBytes
            && host.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
            && port != 0
    }
}

/// Hard protocol limits shared by the local client and host. Bounds are
/// checked before a frame is sent and again after it is received.
public enum LocalComputerUseRPCLimits {
    public static let currentVersion = 1
    public static let lengthPrefixBytes = 4
    public static let maximumFrameBytes = 512 * 1_024
    public static let maximumHostBytes = 255
    public static let maximumIdentifierBytes = 128
    public static let maximumPairingBindingBytes = 128
    public static let maximumBodyBytes = 256 * 1_024
    public static let maximumEnvelopesPerFrame = 32
    public static let maximumAcknowledgementsPerFrame = 128
    public static let maximumFailureCodeBytes = 64
    public static let maximumFailureMessageBytes = 512
    public static let maximumMemoryTextBytes = 4_096
    public static let maximumMemoryMetadataPerReply = 32
    public static let maximumMemoryRecordsPerReply = 32
    public static let maximumMemorySearchQueryBytes = 2_048
}

/// One bounded request on the local Computer Use control plane. A request may
/// submit new messages, acknowledge previously received messages, or do both.
/// An empty request is a valid poll.
public struct LocalComputerUseRPCRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let senderID: String
    public let targetID: String
    public let sessionID: String
    public let envelopes: [ComputerUseEnvelope]
    public let acknowledgedEnvelopeIDs: [String]
    public let memoryCommand: LocalMemoryRPCCommand?
    /// Explicit authenticated connection-session bind; omitted by legacy polls.
    public let bindSession: Bool?

    public init(
        requestID: String = UUID().uuidString,
        senderID: String,
        targetID: String,
        sessionID: String,
        envelopes: [ComputerUseEnvelope] = [],
        acknowledgedEnvelopeIDs: [String] = [],
        memoryCommand: LocalMemoryRPCCommand? = nil,
        bindSession: Bool? = nil
    ) {
        version = LocalComputerUseRPCLimits.currentVersion
        self.requestID = requestID
        self.senderID = senderID
        self.targetID = targetID
        self.sessionID = sessionID
        self.envelopes = envelopes
        self.acknowledgedEnvelopeIDs = acknowledgedEnvelopeIDs
        self.memoryCommand = memoryCommand
        self.bindSession = bindSession
    }

    public func validate() throws {
        guard version == LocalComputerUseRPCLimits.currentVersion else {
            throw LocalComputerUseRPCValidationError.unsupportedVersion(version)
        }
        try LocalComputerUseRPCValidator.identifier(
            requestID,
            field: "requestID")
        try LocalComputerUseRPCValidator.identifier(
            senderID,
            field: "senderID")
        try LocalComputerUseRPCValidator.identifier(
            targetID,
            field: "targetID")
        try LocalComputerUseRPCValidator.identifier(
            sessionID,
            field: "sessionID")
        guard envelopes.count
                <= LocalComputerUseRPCLimits.maximumEnvelopesPerFrame else {
            throw LocalComputerUseRPCValidationError.tooManyEnvelopes
        }
        guard acknowledgedEnvelopeIDs.count
                <= LocalComputerUseRPCLimits
                    .maximumAcknowledgementsPerFrame else {
            throw LocalComputerUseRPCValidationError.tooManyAcknowledgements
        }
        for envelope in envelopes {
            try LocalComputerUseRPCValidator.envelope(envelope)
            guard envelope.sessionID == sessionID else {
                throw LocalComputerUseRPCValidationError.invalidField(
                    "envelope.sessionID")
            }
        }
        for acknowledgement in acknowledgedEnvelopeIDs {
            try LocalComputerUseRPCValidator.identifier(
                acknowledgement,
                field: "acknowledgedEnvelopeID")
        }
        try memoryCommand?.validate()
        if memoryCommand != nil && (!envelopes.isEmpty || !acknowledgedEnvelopeIDs.isEmpty) {
            throw LocalComputerUseRPCValidationError.invalidField("memoryOnlyRequest")
        }
        if bindSession == true,
           memoryCommand != nil || !envelopes.isEmpty || !acknowledgedEnvelopeIDs.isEmpty {
            throw LocalComputerUseRPCValidationError.invalidField("sessionBindOnlyRequest")
        }
    }
}

/// A bounded response to exactly one local RPC request. The response echoes
/// `requestID`, reports which submitted messages were durably accepted, and
/// returns any host-to-client messages currently available.
public struct LocalComputerUseRPCResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let senderID: String
    public let targetID: String
    public let envelopes: [ComputerUseEnvelope]
    public let acceptedEnvelopeIDs: [String]
    public let failure: LocalComputerUseRPCFailure?
    public let memoryReply: LocalMemoryRPCReply?
    /// Present only when the host processed an explicit session-bind request.
    public let sessionBindingAccepted: Bool?

    public init(
        requestID: String,
        senderID: String,
        targetID: String,
        envelopes: [ComputerUseEnvelope] = [],
        acceptedEnvelopeIDs: [String] = [],
        failure: LocalComputerUseRPCFailure? = nil,
        memoryReply: LocalMemoryRPCReply? = nil,
        sessionBindingAccepted: Bool? = nil
    ) {
        version = LocalComputerUseRPCLimits.currentVersion
        self.requestID = requestID
        self.senderID = senderID
        self.targetID = targetID
        self.envelopes = envelopes
        self.acceptedEnvelopeIDs = acceptedEnvelopeIDs
        self.failure = failure
        self.memoryReply = memoryReply
        self.sessionBindingAccepted = sessionBindingAccepted
    }

    public func validate() throws {
        guard version == LocalComputerUseRPCLimits.currentVersion else {
            throw LocalComputerUseRPCValidationError.unsupportedVersion(version)
        }
        try LocalComputerUseRPCValidator.identifier(
            requestID,
            field: "requestID")
        try LocalComputerUseRPCValidator.identifier(
            senderID,
            field: "senderID")
        try LocalComputerUseRPCValidator.identifier(
            targetID,
            field: "targetID")
        guard envelopes.count
                <= LocalComputerUseRPCLimits.maximumEnvelopesPerFrame else {
            throw LocalComputerUseRPCValidationError.tooManyEnvelopes
        }
        guard acceptedEnvelopeIDs.count
                <= LocalComputerUseRPCLimits
                    .maximumAcknowledgementsPerFrame else {
            throw LocalComputerUseRPCValidationError.tooManyAcknowledgements
        }
        for envelope in envelopes {
            try LocalComputerUseRPCValidator.envelope(envelope)
        }
        for acknowledgement in acceptedEnvelopeIDs {
            try LocalComputerUseRPCValidator.identifier(
                acknowledgement,
                field: "acceptedEnvelopeID")
        }
        try failure?.validate()
        try memoryReply?.validate()
        if sessionBindingAccepted != nil,
           !envelopes.isEmpty || !acceptedEnvelopeIDs.isEmpty
                || failure != nil || memoryReply != nil {
            throw LocalComputerUseRPCValidationError.invalidField("sessionBindingReply")
        }
        if failure != nil && memoryReply != nil {
            throw LocalComputerUseRPCValidationError.invalidField("contradictoryMemoryResponse")
        }
        if memoryReply != nil && (!envelopes.isEmpty || !acceptedEnvelopeIDs.isEmpty) {
            throw LocalComputerUseRPCValidationError.invalidField("memoryOnlyResponse")
        }
    }

    /// A legacy host may ignore this additive request field while returning a
    /// valid ordinary RPC response. Such a response is never memory success.
    public func memoryResult(
        for request: LocalComputerUseRPCRequest
    ) throws -> LocalMemoryRPCReply? {
        try request.validate()
        try validate()
        guard requestID == request.requestID,
              senderID == request.targetID,
              targetID == request.senderID else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryResponseRoute")
        }
        guard request.memoryCommand != nil else {
            guard memoryReply == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("unexpectedMemoryReply")
            }
            return nil
        }
        guard let memoryReply else {
            throw LocalComputerUseRPCValidationError.memoryReplyMissing
        }
        try memoryReply.validate()
        guard let command = request.memoryCommand,
              memoryReply.operation == command.operation,
              memoryReply.commandID == command.commandID,
              memoryReply.rememberKind == command.rememberKind else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryReplyMismatch")
        }
        if command.operation == .forgetEverything || command.operation == .initializeMemoryGeneration {
            guard memoryReply.generationReference == command.generationReference else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReplyGenerationReference")
            }
        } else if command.operation != .captureMemoryGeneration {
            guard memoryReply.generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReplyGenerationReference")
            }
        }
        if memoryReply.status == .completed {
            switch command.operation {
            case .remember, .confirmProposal:
                guard memoryReply.recordID != nil,
                      memoryReply.idempotentRetry != nil,
                      memoryReply.metadata.isEmpty, memoryReply.records.isEmpty else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyReceipt")
                }
            case .listMetadata:
                guard memoryReply.recordID == nil,
                      memoryReply.idempotentRetry == nil,
                      memoryReply.records.isEmpty,
                      memoryReply.metadata.count <= (command.limit ?? 0) else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyMetadata")
                }
            case .deleteMetadata:
                guard memoryReply.recordID == nil,
                      memoryReply.idempotentRetry == nil,
                      memoryReply.metadata.isEmpty, memoryReply.records.isEmpty else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyDelete")
                }
            case .listRecords, .searchRecords:
                guard memoryReply.recordID == nil, memoryReply.idempotentRetry == nil,
                      memoryReply.metadata.isEmpty,
                      memoryReply.records.count <= (command.limit ?? 0) else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyRecords")
                }
                var previousID = command.afterRecordID
                for record in memoryReply.records {
                    if let previousID,
                       !previousID.utf8.lexicographicallyPrecedes(record.recordID.utf8) {
                        throw LocalComputerUseRPCValidationError.invalidField("memoryReply.recordOrder")
                    }
                    previousID = record.recordID
                }
                if let nextRecordID = memoryReply.nextRecordID {
                    guard memoryReply.records.count == command.limit,
                          memoryReply.records.last?.recordID == nextRecordID,
                          command.afterRecordID.map({ $0.utf8.lexicographicallyPrecedes(nextRecordID.utf8) }) ?? true else {
                        throw LocalComputerUseRPCValidationError.invalidField("memoryReply.nextRecordID")
                    }
                }
            case .editRecord:
                guard memoryReply.recordID == command.recordID,
                      memoryReply.idempotentRetry != nil,
                      memoryReply.metadata.isEmpty, memoryReply.records.isEmpty else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyEditReceipt")
                }
            case .captureMemoryGeneration:
                guard memoryReply.generationReference != nil,
                      memoryReply.rememberKind == nil, memoryReply.recordID == nil,
                      memoryReply.idempotentRetry == nil, memoryReply.metadata.isEmpty,
                      memoryReply.records.isEmpty, memoryReply.nextRecordID == nil else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyGenerationCapture")
                }
            case .forgetEverything:
                guard memoryReply.commandID == command.commandID,
                      memoryReply.generationReference == command.generationReference,
                      memoryReply.recordID == nil, memoryReply.idempotentRetry == nil,
                      memoryReply.metadata.isEmpty, memoryReply.records.isEmpty,
                      memoryReply.nextRecordID == nil else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyForgetReceipt")
                }
            case .initializeMemoryGeneration:
                guard memoryReply.commandID == command.commandID,
                      memoryReply.generationReference == command.generationReference,
                      memoryReply.rememberKind == nil, memoryReply.recordID == nil,
                      memoryReply.idempotentRetry == nil, memoryReply.metadata.isEmpty,
                      memoryReply.records.isEmpty, memoryReply.nextRecordID == nil,
                      let replacement = memoryReply.replacementGenerationReference,
                      replacement != command.generationReference,
                      LocalMemoryRPCCommand.isValidGenerationReference(replacement) else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReplyInitializationReceipt")
                }
            }
            if command.operation == .remember,
               memoryReply.rememberKind != command.rememberKind {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReplyKind")
            }
        }
        return memoryReply
    }
}

/// A safe remote failure. Internal error descriptions, file paths, model
/// prompts, and credentials must never be placed in this value.
public struct LocalComputerUseRPCFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public func validate() throws {
        try LocalComputerUseRPCValidator.boundedInlineText(
            code,
            field: "failure.code",
            maximumBytes: LocalComputerUseRPCLimits.maximumFailureCodeBytes,
            mayBeEmpty: false)
        try LocalComputerUseRPCValidator.boundedInlineText(
            message,
            field: "failure.message",
            maximumBytes:
                LocalComputerUseRPCLimits.maximumFailureMessageBytes,
            mayBeEmpty: false)
    }
}

public enum LocalComputerUseRPCValidationError:
    Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidField(String)
    case fieldTooLarge(String)
    case bodyTooLarge
    case tooManyEnvelopes
    case tooManyAcknowledgements
    case tooManyMemoryMetadata
    case memoryReplyMissing
    case frameTooLarge
    case malformedFrame

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "The local Computer Use protocol version is unsupported."
        case .invalidField(let field):
            return "The local Computer Use frame has an invalid \(field)."
        case .fieldTooLarge(let field):
            return "The local Computer Use frame's \(field) is too large."
        case .bodyTooLarge:
            return "The local Computer Use message body is too large."
        case .tooManyEnvelopes:
            return "The local Computer Use frame contains too many messages."
        case .tooManyAcknowledgements:
            return "The local Computer Use frame contains too many acknowledgements."
        case .tooManyMemoryMetadata:
            return "The local memory reply contains too much metadata."
        case .memoryReplyMissing:
            return "The Mac did not return a local memory result."
        case .frameTooLarge:
            return "The local Computer Use frame is too large."
        case .malformedFrame:
            return "The local Computer Use frame is malformed."
        }
    }
}

/// Deterministic JSON coding kept separate from Network.framework so the
/// frame contract can be exercised as a pure unit.
public enum LocalComputerUseRPCCodec {
    public static func encode(
        _ request: LocalComputerUseRPCRequest
    ) throws -> Data {
        try request.validate()
        return try boundedEncode(request)
    }

    public static func decodeRequest(
        _ data: Data
    ) throws -> LocalComputerUseRPCRequest {
        let request: LocalComputerUseRPCRequest = try boundedDecode(
            data,
            as: LocalComputerUseRPCRequest.self)
        try request.validate()
        return request
    }

    public static func encode(
        _ response: LocalComputerUseRPCResponse
    ) throws -> Data {
        try response.validate()
        return try boundedEncode(response)
    }

    public static func decodeResponse(
        _ data: Data
    ) throws -> LocalComputerUseRPCResponse {
        let response: LocalComputerUseRPCResponse = try boundedDecode(
            data,
            as: LocalComputerUseRPCResponse.self)
        try response.validate()
        return response
    }

    private static func boundedEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= LocalComputerUseRPCLimits.maximumFrameBytes else {
            throw LocalComputerUseRPCValidationError.frameTooLarge
        }
        return data
    }

    private static func boundedDecode<T: Decodable>(
        _ data: Data,
        as type: T.Type
    ) throws -> T {
        guard !data.isEmpty,
              data.count <= LocalComputerUseRPCLimits.maximumFrameBytes else {
            throw data.isEmpty
                ? LocalComputerUseRPCValidationError.malformedFrame
                : LocalComputerUseRPCValidationError.frameTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch let validation as LocalComputerUseRPCValidationError {
            throw validation
        } catch {
            throw LocalComputerUseRPCValidationError.malformedFrame
        }
    }
}

enum LocalComputerUseRPCValidator {
    static func rejectUnknownKeys<K: CodingKey>(_ decoder: Decoder, allowed: [K]) throws {
        let values = try decoder.container(keyedBy: LocalComputerUseDynamicCodingKey.self)
        let accepted = Set(allowed.map(\.stringValue))
        guard values.allKeys.allSatisfy({ accepted.contains($0.stringValue) }) else {
            throw LocalComputerUseRPCValidationError.invalidField("unknownMemoryField")
        }
    }

    static func memoryText(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= LocalComputerUseRPCLimits.maximumMemoryTextBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "\n" || scalar == "\t" || scalar == "\r"
              }) else {
            throw LocalComputerUseRPCValidationError.invalidField(field)
        }
    }

    static func envelope(_ envelope: ComputerUseEnvelope) throws {
        try identifier(envelope.id, field: "envelope.id")
        try identifier(envelope.senderID, field: "envelope.senderID")
        try identifier(envelope.targetID, field: "envelope.targetID")
        try boundedInlineText(
            envelope.pairingCode,
            field: "envelope.pairingCode",
            maximumBytes:
                LocalComputerUseRPCLimits.maximumPairingBindingBytes,
            mayBeEmpty: true)
        try identifier(envelope.sessionID, field: "envelope.sessionID")
        guard envelope.body.utf8.count
                <= LocalComputerUseRPCLimits.maximumBodyBytes else {
            throw LocalComputerUseRPCValidationError.bodyTooLarge
        }
        guard envelope.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LocalComputerUseRPCValidationError.invalidField(
                "envelope.createdAt")
        }
    }

    static func identifier(_ value: String, field: String) throws {
        try boundedInlineText(
            value,
            field: field,
            maximumBytes: LocalComputerUseRPCLimits.maximumIdentifierBytes,
            mayBeEmpty: false)
    }

    static func boundedInlineText(
        _ value: String,
        field: String,
        maximumBytes: Int,
        mayBeEmpty: Bool
    ) throws {
        guard mayBeEmpty || !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.newlines.contains(scalar)
              }) else {
            throw LocalComputerUseRPCValidationError.invalidField(field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw LocalComputerUseRPCValidationError.fieldTooLarge(field)
        }
    }
}

private struct LocalComputerUseDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}
