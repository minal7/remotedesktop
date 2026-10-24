import Foundation

struct PersonalMemoryMutationReceipt: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case edit, delete }
    let kind: Kind
    let recordID: String
    let requestID: String

    func matches(kind: Kind, recordID: String, requestID: String) -> Bool {
        self.kind == kind && self.recordID == recordID && self.requestID == requestID
    }
}

enum PersonalMemoryViewState: Equatable {
    case unavailable, loading, ready, error(String)
}

struct PersonalMemoryPendingEdit: Equatable {
    let recordID: String
    let revision: String
    let text: String
    let commandID: String
}

struct PersonalMemoryPendingRemember: Equatable {
    let kind: LocalMemoryRPCCommand.RememberKind
    let text: String
    let commandID: String
}

enum PersonalMemoryRememberState: Equatable { case idle, saving, unknown, saved, rejected }

struct PersonalMemoryRememberReceipt: Equatable {
    let kind: LocalMemoryRPCCommand.RememberKind
    let commandID: String
    let recordID: String
}

enum PersonalMemoryRequestKind: Equatable {
    case read, initialRead, mutation, remember, capture(PersonalMemoryViewState), forget, initialize
}

enum PersonalMemoryValidationFailure: Error { case invalid }

enum PersonalMemoryReplyValidator {
    static func remember(_ reply: LocalMemoryRPCReply,
                         command: LocalMemoryRPCCommand) throws {
        try reply.validate()
        guard command.operation == .remember, let commandID = command.commandID,
              let kind = command.rememberKind, reply.operation == .remember,
              reply.commandID == commandID, reply.rememberKind == kind,
              reply.generationReference == nil, reply.replacementGenerationReference == nil,
              reply.metadata.isEmpty, reply.records.isEmpty, reply.nextRecordID == nil,
              reply.status != .completed || reply.idempotentRetry != nil else {
            throw PersonalMemoryValidationFailure.invalid
        }
        if reply.status == .completed {
            guard reply.recordID != nil else { throw PersonalMemoryValidationFailure.invalid }
        }
        if reply.status != .completed,
           (reply.recordID != nil || reply.idempotentRetry != nil) {
            throw PersonalMemoryValidationFailure.invalid
        }
    }

    static func initialize(_ reply: LocalMemoryRPCReply, commandID: String,
                           sourceReference: String) throws {
        try reply.validate()
        guard reply.operation == .initializeMemoryGeneration, reply.commandID == commandID,
              reply.status == .completed, reply.generationReference == sourceReference,
              let replacement = reply.replacementGenerationReference,
              LocalMemoryRPCCommand.isValidGenerationReference(replacement),
              replacement != sourceReference, reply.rememberKind == nil,
              reply.recordID == nil, reply.idempotentRetry == nil, reply.metadata.isEmpty,
              reply.records.isEmpty, reply.nextRecordID == nil else {
            throw PersonalMemoryValidationFailure.invalid
        }
    }

    static func forget(_ reply: LocalMemoryRPCReply, commandID: String,
                       generationReference: String) throws {
        try reply.validate()
        guard reply.operation == .forgetEverything, reply.commandID == commandID,
              reply.generationReference == generationReference, reply.status == .completed,
              reply.rememberKind == nil, reply.recordID == nil, reply.idempotentRetry == nil,
              reply.metadata.isEmpty, reply.records.isEmpty, reply.nextRecordID == nil else {
            throw PersonalMemoryValidationFailure.invalid
        }
    }

    static func page(_ reply: LocalMemoryRPCReply, command: LocalMemoryRPCCommand,
                     previousCursor: String?, appendingTo existing: [LocalMemoryRPCRecord]) throws {
        try reply.validate()
        guard reply.operation == command.operation, reply.commandID == nil,
              reply.rememberKind == nil, reply.recordID == nil, reply.idempotentRetry == nil,
              reply.metadata.isEmpty, reply.nextRecordID == nil || reply.status == .completed,
              reply.status == .completed, reply.records.count <= (command.limit ?? 0) else {
            throw PersonalMemoryValidationFailure.invalid
        }
        if reply.nextRecordID != nil {
            guard reply.records.count == command.limit,
                  reply.nextRecordID == reply.records.last?.recordID,
                  reply.nextRecordID != previousCursor else {
                throw PersonalMemoryValidationFailure.invalid
            }
        }
        var seen = Set<String>()
        var prior: String?
        for record in existing + reply.records {
            try record.validate()
            guard seen.insert(record.recordID).inserted else {
                throw PersonalMemoryValidationFailure.invalid
            }
            if let prior, !prior.utf8.lexicographicallyPrecedes(record.recordID.utf8) {
                throw PersonalMemoryValidationFailure.invalid
            }
            prior = record.recordID
        }
    }

    static func verifiedAbsent(_ reply: LocalMemoryRPCReply,
                               command: LocalMemoryRPCCommand) throws {
        try reply.validate()
        guard (command.operation == .listRecords || command.operation == .searchRecords)
                && reply.operation == command.operation
                && reply.status == .initializationRequired
                && reply.commandID == nil && reply.rememberKind == nil
                && reply.recordID == nil && reply.idempotentRetry == nil
                && reply.metadata.isEmpty && reply.records.isEmpty
                && reply.nextRecordID == nil && reply.generationReference == nil
                && reply.replacementGenerationReference == nil else {
            throw PersonalMemoryValidationFailure.invalid
        }
    }

    static func mutation(_ reply: LocalMemoryRPCReply, command: LocalMemoryRPCCommand) throws {
        try reply.validate()
        guard reply.operation == command.operation else { throw PersonalMemoryValidationFailure.invalid }
        if command.operation == .editRecord {
            guard reply.commandID == command.commandID, reply.rememberKind == nil,
                  reply.metadata.isEmpty, reply.records.isEmpty else {
                throw PersonalMemoryValidationFailure.invalid
            }
            if reply.status == .completed {
                guard reply.recordID == command.recordID, reply.idempotentRetry != nil else {
                    throw PersonalMemoryValidationFailure.invalid
                }
            } else if reply.recordID != nil || reply.idempotentRetry != nil {
                throw PersonalMemoryValidationFailure.invalid
            }
        } else if reply.commandID != nil || reply.rememberKind != nil || reply.recordID != nil
                    || reply.idempotentRetry != nil || !reply.metadata.isEmpty
                    || !reply.records.isEmpty || reply.nextRecordID != nil {
            throw PersonalMemoryValidationFailure.invalid
        }
    }
}
