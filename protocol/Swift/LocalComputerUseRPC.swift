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

    public init(
        requestID: String = UUID().uuidString,
        senderID: String,
        targetID: String,
        sessionID: String,
        envelopes: [ComputerUseEnvelope] = [],
        acknowledgedEnvelopeIDs: [String] = []
    ) {
        version = LocalComputerUseRPCLimits.currentVersion
        self.requestID = requestID
        self.senderID = senderID
        self.targetID = targetID
        self.sessionID = sessionID
        self.envelopes = envelopes
        self.acknowledgedEnvelopeIDs = acknowledgedEnvelopeIDs
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

    public init(
        requestID: String,
        senderID: String,
        targetID: String,
        envelopes: [ComputerUseEnvelope] = [],
        acceptedEnvelopeIDs: [String] = [],
        failure: LocalComputerUseRPCFailure? = nil
    ) {
        version = LocalComputerUseRPCLimits.currentVersion
        self.requestID = requestID
        self.senderID = senderID
        self.targetID = targetID
        self.envelopes = envelopes
        self.acceptedEnvelopeIDs = acceptedEnvelopeIDs
        self.failure = failure
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

private enum LocalComputerUseRPCValidator {
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
