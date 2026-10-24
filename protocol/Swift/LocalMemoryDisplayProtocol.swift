import Foundation

/// Versioned, typed owner-memory operation carried only by the authenticated
/// local RPC. It is deliberately separate from ComputerUseEnvelope.
public struct LocalMemoryRPCCommand: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Equatable, Sendable {
        case remember
        case confirmProposal
        case listMetadata
        case deleteMetadata
        case listRecords
        case searchRecords
        case editRecord
        case captureMemoryGeneration
        case forgetEverything
        case initializeMemoryGeneration
    }

    public enum RememberKind: String, Codable, Equatable, Sendable {
        case profile
        case fact
    }

    public let version: Int
    public let operation: Operation
    public let rememberKind: RememberKind?
    public let text: String?
    public let commandID: String?
    public let proposalID: String?
    public let recordID: String?
    public let limit: Int?
    public let query: String?
    public let revision: String?
    public let afterRecordID: String?
    public let generationReference: String?

    public init(rememberKind: RememberKind, text: String, commandID: String) {
        version = 1
        operation = .remember
        self.rememberKind = rememberKind
        self.text = text
        self.commandID = commandID
        proposalID = nil
        recordID = nil
        limit = nil
        query = nil
        revision = nil
        afterRecordID = nil
        generationReference = nil
    }

    public init(confirmProposalID proposalID: String, commandID: String) {
        version = 1
        operation = .confirmProposal
        rememberKind = nil
        text = nil
        self.commandID = commandID
        self.proposalID = proposalID
        recordID = nil
        limit = nil
        query = nil
        revision = nil
        afterRecordID = nil
        generationReference = nil
    }

    public init(listMetadata limit: Int = 20) {
        version = 1
        operation = .listMetadata
        rememberKind = nil
        text = nil
        commandID = nil
        proposalID = nil
        recordID = nil
        self.limit = limit
        query = nil
        revision = nil
        afterRecordID = nil
        generationReference = nil
    }

    public init(deleteMetadata recordID: String) {
        version = 1
        operation = .deleteMetadata
        rememberKind = nil
        text = nil
        commandID = nil
        proposalID = nil
        self.recordID = recordID
        limit = nil
        query = nil
        revision = nil
        afterRecordID = nil
        generationReference = nil
    }

    public init(listRecords limit: Int = 20, afterRecordID: String? = nil) {
        version = 1
        operation = .listRecords
        rememberKind = nil; text = nil; commandID = nil; proposalID = nil; recordID = nil
        self.limit = limit; query = nil; revision = nil; self.afterRecordID = afterRecordID
        generationReference = nil
    }

    public init(searchRecords query: String, limit: Int = 20, afterRecordID: String? = nil) {
        version = 1
        operation = .searchRecords
        rememberKind = nil; text = nil; commandID = nil; proposalID = nil; recordID = nil
        self.limit = limit; self.query = query; revision = nil; self.afterRecordID = afterRecordID
        generationReference = nil
    }

    public init(editRecord recordID: String, revision: String, text: String, commandID: String) {
        version = 1
        operation = .editRecord
        rememberKind = nil; self.text = text; self.commandID = commandID; proposalID = nil
        self.recordID = recordID; limit = nil; query = nil; self.revision = revision; afterRecordID = nil
        generationReference = nil
    }

    public init(captureMemoryGeneration: Void = ()) {
        version = 1
        operation = .captureMemoryGeneration
        rememberKind = nil; text = nil; commandID = nil; proposalID = nil; recordID = nil
        limit = nil; query = nil; revision = nil; afterRecordID = nil; generationReference = nil
    }

    /// Explicitly initializes a fresh store only if `generationReference` still
    /// identifies the exact generation the owner confirmed replacing.
    public init(initializeMemoryGeneration commandID: String, generationReference: String) {
        version = 1
        operation = .initializeMemoryGeneration
        rememberKind = nil; text = nil; self.commandID = commandID; proposalID = nil
        recordID = nil; limit = nil; query = nil; revision = nil; afterRecordID = nil
        self.generationReference = generationReference
    }

    /// Dedicated owner-confirmed erase command. Its UUID is an idempotency identity;
    /// the command contains no record, query, text, or proposal payload.
    public init(forgetEverything commandID: String, generationReference: String? = nil) {
        version = 1
        operation = .forgetEverything
        rememberKind = nil; text = nil; self.commandID = commandID; proposalID = nil
        recordID = nil; limit = nil; query = nil; revision = nil; afterRecordID = nil
        self.generationReference = generationReference
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, operation, rememberKind, text, commandID, proposalID, recordID, limit, query, revision, afterRecordID, generationReference
    }

    public init(from decoder: Decoder) throws {
        try LocalComputerUseRPCValidator.rejectUnknownKeys(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        operation = try values.decode(Operation.self, forKey: .operation)
        rememberKind = try values.decodeIfPresent(RememberKind.self, forKey: .rememberKind)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        commandID = try values.decodeIfPresent(String.self, forKey: .commandID)
        proposalID = try values.decodeIfPresent(String.self, forKey: .proposalID)
        recordID = try values.decodeIfPresent(String.self, forKey: .recordID)
        limit = try values.decodeIfPresent(Int.self, forKey: .limit)
        query = try values.decodeIfPresent(String.self, forKey: .query)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        afterRecordID = try values.decodeIfPresent(String.self, forKey: .afterRecordID)
        generationReference = try values.decodeIfPresent(String.self, forKey: .generationReference)
    }

    public func validate() throws {
        guard version == 1 else {
            throw LocalComputerUseRPCValidationError.unsupportedVersion(version)
        }
        switch operation {
        case .remember:
            guard let rememberKind, let text, let commandID,
                  proposalID == nil, recordID == nil, limit == nil, query == nil, revision == nil,
                  afterRecordID == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand")
            }
            try LocalComputerUseRPCValidator.identifier(commandID, field: "memoryCommand.commandID")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= LocalComputerUseRPCLimits.maximumMemoryTextBytes,
                  text.unicodeScalars.allSatisfy({ scalar in
                      !CharacterSet.controlCharacters.contains(scalar)
                        || scalar == "\n" || scalar == "\t" || scalar == "\r"
                  }) else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.text")
            }
        case .confirmProposal:
            guard let proposalID, let commandID, rememberKind == nil,
                  text == nil, recordID == nil, limit == nil, query == nil, revision == nil,
                  afterRecordID == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand")
            }
            try LocalComputerUseRPCValidator.identifier(proposalID, field: "memoryCommand.proposalID")
            try LocalComputerUseRPCValidator.identifier(commandID, field: "memoryCommand.commandID")
        case .listMetadata:
            guard let limit, (1...LocalComputerUseRPCLimits.maximumMemoryMetadataPerReply).contains(limit),
                  rememberKind == nil, text == nil, commandID == nil,
                  proposalID == nil, recordID == nil, query == nil, revision == nil,
                  afterRecordID == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.limit")
            }
        case .deleteMetadata:
            guard let recordID, rememberKind == nil, text == nil,
                  commandID == nil, proposalID == nil, limit == nil, query == nil, revision == nil,
                  afterRecordID == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.recordID")
            }
            try LocalComputerUseRPCValidator.identifier(recordID, field: "memoryCommand.recordID")
        case .listRecords:
            guard let limit, (1...LocalComputerUseRPCLimits.maximumMemoryRecordsPerReply).contains(limit),
                  rememberKind == nil, text == nil, commandID == nil, proposalID == nil,
                  recordID == nil, query == nil, revision == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.listRecords")
            }
            try Self.validateRecordCursor(afterRecordID)
        case .searchRecords:
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf8.count <= LocalComputerUseRPCLimits.maximumMemorySearchQueryBytes,
                  query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  let limit, (1...LocalComputerUseRPCLimits.maximumMemoryRecordsPerReply).contains(limit),
                  rememberKind == nil, text == nil, commandID == nil, proposalID == nil,
                  recordID == nil, revision == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.searchRecords")
            }
            try Self.validateRecordCursor(afterRecordID)
        case .editRecord:
            guard let recordID, let revision, let text, let commandID,
                  rememberKind == nil, proposalID == nil, limit == nil, query == nil,
                  afterRecordID == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.editRecord")
            }
            try LocalComputerUseRPCValidator.identifier(recordID, field: "memoryCommand.recordID")
            try LocalComputerUseRPCValidator.identifier(commandID, field: "memoryCommand.commandID")
            guard revision.utf8.count == 64,
                  revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.revision")
            }
            try LocalComputerUseRPCValidator.memoryText(text, field: "memoryCommand.text")
        case .captureMemoryGeneration:
            guard rememberKind == nil, text == nil, commandID == nil, proposalID == nil,
                  recordID == nil, limit == nil, query == nil, revision == nil,
                  afterRecordID == nil, generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.captureMemoryGeneration")
            }
        case .forgetEverything:
            guard let commandID, rememberKind == nil, text == nil, proposalID == nil,
                  recordID == nil, limit == nil, query == nil, revision == nil,
                  afterRecordID == nil, let generationReference,
                  Self.isValidGenerationReference(generationReference),
                  UUID(uuidString: commandID)?.uuidString.lowercased() == commandID else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.forgetEverything")
            }
        case .initializeMemoryGeneration:
            guard let commandID, let generationReference,
                  UUID(uuidString: commandID)?.uuidString.lowercased() == commandID,
                  Self.isValidGenerationReference(generationReference),
                  rememberKind == nil, text == nil, proposalID == nil, recordID == nil,
                  limit == nil, query == nil, revision == nil, afterRecordID == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryCommand.initializeMemoryGeneration")
            }
        }
    }

    private static func validateRecordCursor(_ cursor: String?) throws {
        if let cursor {
            try LocalComputerUseRPCValidator.identifier(cursor, field: "memoryCommand.afterRecordID")
        }
    }

    static func isValidGenerationReference(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Legacy metadata exposes no remembered text; record-list responses use only the
/// explicitly bounded owner-view record DTO. Internal error details never appear.
public struct LocalMemoryRPCMetadata: Codable, Equatable, Sendable {
    public let recordID: String
    public let kind: LocalMemoryRPCCommand.RememberKind
    public let createdAtMilliseconds: Int64

    public init(recordID: String, kind: LocalMemoryRPCCommand.RememberKind,
                createdAtMilliseconds: Int64) {
        self.recordID = recordID
        self.kind = kind
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

public struct LocalMemoryRPCReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case completed, disabled, unauthorized, inactiveTask, noMemory
        case incognito, learningPaused, notFound, conflict, invalidRequest
        case unavailable
    }

    public let version: Int
    public let operation: LocalMemoryRPCCommand.Operation
    public let commandID: String?
    public let rememberKind: LocalMemoryRPCCommand.RememberKind?
    public let status: Status
    public let recordID: String?
    public let idempotentRetry: Bool?
    public let metadata: [LocalMemoryRPCMetadata]
    public let records: [LocalMemoryRPCRecord]
    public let nextRecordID: String?
    public let generationReference: String?
    public let replacementGenerationReference: String?

    public init(operation: LocalMemoryRPCCommand.Operation,
                commandID: String? = nil,
                rememberKind: LocalMemoryRPCCommand.RememberKind? = nil,
                status: Status, recordID: String? = nil,
                idempotentRetry: Bool? = nil,
                metadata: [LocalMemoryRPCMetadata] = [],
                records: [LocalMemoryRPCRecord] = [], nextRecordID: String? = nil,
                generationReference: String? = nil,
                replacementGenerationReference: String? = nil) {
        version = 1
        self.operation = operation
        self.commandID = commandID
        self.rememberKind = rememberKind
        self.status = status
        self.recordID = recordID
        self.idempotentRetry = idempotentRetry
        self.metadata = metadata
        self.records = records
        self.nextRecordID = nextRecordID
        self.generationReference = generationReference
        self.replacementGenerationReference = replacementGenerationReference
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, operation, commandID, rememberKind, status, recordID, idempotentRetry, metadata, records, nextRecordID, generationReference, replacementGenerationReference
    }

    public init(from decoder: Decoder) throws {
        try LocalComputerUseRPCValidator.rejectUnknownKeys(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        operation = try values.decode(LocalMemoryRPCCommand.Operation.self, forKey: .operation)
        commandID = try values.decodeIfPresent(String.self, forKey: .commandID)
        rememberKind = try values.decodeIfPresent(LocalMemoryRPCCommand.RememberKind.self, forKey: .rememberKind)
        status = try values.decode(Status.self, forKey: .status)
        recordID = try values.decodeIfPresent(String.self, forKey: .recordID)
        idempotentRetry = try values.decodeIfPresent(Bool.self, forKey: .idempotentRetry)
        metadata = try values.decodeIfPresent([LocalMemoryRPCMetadata].self, forKey: .metadata) ?? []
        records = try values.decodeIfPresent([LocalMemoryRPCRecord].self, forKey: .records) ?? []
        nextRecordID = try values.decodeIfPresent(String.self, forKey: .nextRecordID)
        generationReference = try values.decodeIfPresent(String.self, forKey: .generationReference)
        replacementGenerationReference = try values.decodeIfPresent(String.self, forKey: .replacementGenerationReference)
        try validate()
    }

    public func validate() throws {
        guard version == 1 else {
            throw LocalComputerUseRPCValidationError.unsupportedVersion(version)
        }
        if let commandID {
            try LocalComputerUseRPCValidator.identifier(commandID, field: "memoryReply.commandID")
        }
        if let generationReference, !LocalMemoryRPCCommand.isValidGenerationReference(generationReference) {
            throw LocalComputerUseRPCValidationError.invalidField("memoryReply.generationReference")
        }
        if let replacementGenerationReference,
           !LocalMemoryRPCCommand.isValidGenerationReference(replacementGenerationReference) {
            throw LocalComputerUseRPCValidationError.invalidField("memoryReply.replacementGenerationReference")
        }
        if operation != .captureMemoryGeneration && operation != .forgetEverything
            && operation != .initializeMemoryGeneration {
            guard generationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.generationReference")
            }
        }
        if operation != .initializeMemoryGeneration {
            guard replacementGenerationReference == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.replacementGenerationReference")
            }
        }
        switch operation {
        case .captureMemoryGeneration:
            guard commandID == nil, rememberKind == nil, recordID == nil,
                  idempotentRetry == nil, metadata.isEmpty, records.isEmpty,
                  nextRecordID == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.generationCapture")
            }
        case .forgetEverything:
            guard let commandID,
                  UUID(uuidString: commandID)?.uuidString.lowercased() == commandID,
                  rememberKind == nil, recordID == nil, idempotentRetry == nil,
                  metadata.isEmpty, records.isEmpty, nextRecordID == nil else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.forgetEverything")
            }
        case .initializeMemoryGeneration:
            guard let commandID,
                  UUID(uuidString: commandID)?.uuidString.lowercased() == commandID,
                  rememberKind == nil, recordID == nil, idempotentRetry == nil,
                  metadata.isEmpty, records.isEmpty, nextRecordID == nil,
                  let generationReference else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.initializeMemoryGeneration")
            }
            if status == .completed {
                guard let replacementGenerationReference,
                      replacementGenerationReference != generationReference else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReply.initializeMemoryGeneration")
                }
            } else {
                guard replacementGenerationReference == nil else {
                    throw LocalComputerUseRPCValidationError.invalidField("memoryReply.initializeMemoryGeneration")
                }
            }
        default: break
        }
        guard metadata.count <= LocalComputerUseRPCLimits.maximumMemoryMetadataPerReply else {
            throw LocalComputerUseRPCValidationError.tooManyMemoryMetadata
        }
        guard records.count <= LocalComputerUseRPCLimits.maximumMemoryRecordsPerReply else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryReply.records")
        }
        if let recordID {
            try LocalComputerUseRPCValidator.identifier(recordID, field: "memoryReply.recordID")
        }
        if let nextRecordID {
            try LocalComputerUseRPCValidator.identifier(nextRecordID, field: "memoryReply.nextRecordID")
            guard status == .completed, !records.isEmpty,
                  records.last?.recordID == nextRecordID else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.nextRecordID")
            }
        }
        for entry in metadata {
            guard entry.createdAtMilliseconds >= 0 else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.metadata.createdAt")
            }
            try LocalComputerUseRPCValidator.identifier(entry.recordID, field: "memoryReply.metadata.recordID")
        }
        var seenRecordIDs = Set<String>()
        var textBytes = 0
        for record in records {
            try record.validate()
            guard seenRecordIDs.insert(record.recordID).inserted else {
                throw LocalComputerUseRPCValidationError.invalidField("memoryReply.records.recordID")
            }
            textBytes += record.text.utf8.count
            guard textBytes <= LocalComputerUseRPCLimits.maximumFrameBytes else {
                throw LocalComputerUseRPCValidationError.frameTooLarge
            }
        }
        guard status == .completed || (recordID == nil && idempotentRetry == nil && metadata.isEmpty
                                       && records.isEmpty && nextRecordID == nil) else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryReply")
        }
        guard status != .completed || validReplyShape else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryReply.operationData")
        }
    }

    private var validReplyShape: Bool {
        switch operation {
        case .remember, .confirmProposal:
            return metadata.isEmpty && records.isEmpty && nextRecordID == nil
        case .listMetadata:
            return recordID == nil && idempotentRetry == nil && records.isEmpty && nextRecordID == nil
        case .deleteMetadata:
            return recordID == nil && idempotentRetry == nil && metadata.isEmpty && records.isEmpty && nextRecordID == nil
        case .listRecords, .searchRecords:
            return recordID == nil && idempotentRetry == nil && metadata.isEmpty
        case .editRecord:
            return recordID != nil && idempotentRetry != nil && metadata.isEmpty && records.isEmpty && nextRecordID == nil
        case .captureMemoryGeneration:
            return commandID == nil && rememberKind == nil && recordID == nil
                && idempotentRetry == nil && metadata.isEmpty && records.isEmpty
                && nextRecordID == nil && (status != .completed || generationReference != nil)
        case .forgetEverything:
            return commandID != nil
                && UUID(uuidString: commandID ?? "")?.uuidString.lowercased() == commandID
                && rememberKind == nil && recordID == nil && idempotentRetry == nil
                && metadata.isEmpty && records.isEmpty && nextRecordID == nil
                && (status != .completed || generationReference != nil)
        case .initializeMemoryGeneration:
            return commandID != nil
                && UUID(uuidString: commandID ?? "")?.uuidString.lowercased() == commandID
                && rememberKind == nil && recordID == nil && idempotentRetry == nil
                && metadata.isEmpty && records.isEmpty && nextRecordID == nil
                && generationReference != nil
                && (status != .completed || (replacementGenerationReference != nil
                                               && replacementGenerationReference != generationReference))
        }
    }
}


/// An ordinary owner-visible memory record. The wire shape intentionally excludes
/// source references, tool/page excerpts, provenance spans, episodes, and vault values.
public struct LocalMemoryRPCRecord: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case ownerMessage = "owner_message"
        case ownerConfirmed = "owner_confirmed"
    }

    public let recordID: String
    public let kind: LocalMemoryRPCCommand.RememberKind
    public let text: String
    public let observedAtMilliseconds: Int64
    public let active: Bool
    public let revision: String
    public let source: Source

    public init(recordID: String, kind: LocalMemoryRPCCommand.RememberKind, text: String,
                observedAtMilliseconds: Int64, active: Bool, revision: String, source: Source) {
        self.recordID = recordID
        self.kind = kind
        self.text = text
        self.observedAtMilliseconds = observedAtMilliseconds
        self.active = active
        self.revision = revision
        self.source = source
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recordID, kind, text, observedAtMilliseconds, active, revision, source
    }

    public init(from decoder: Decoder) throws {
        try LocalComputerUseRPCValidator.rejectUnknownKeys(decoder, allowed: CodingKeys.allCases)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try values.decode(String.self, forKey: .recordID)
        kind = try values.decode(LocalMemoryRPCCommand.RememberKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        observedAtMilliseconds = try values.decode(Int64.self, forKey: .observedAtMilliseconds)
        active = try values.decode(Bool.self, forKey: .active)
        revision = try values.decode(String.self, forKey: .revision)
        source = try values.decode(Source.self, forKey: .source)
        try validate()
    }

    public func validate() throws {
        try LocalComputerUseRPCValidator.identifier(recordID, field: "memoryRecord.recordID")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= LocalComputerUseRPCLimits.maximumMemoryTextBytes,
              text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "\n" || scalar == "\t" || scalar == "\r"
              }) else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryRecord.text")
        }
        guard observedAtMilliseconds >= 0 else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryRecord.observedAtMilliseconds")
        }
        guard revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LocalComputerUseRPCValidationError.invalidField("memoryRecord.revision")
        }
    }
}
