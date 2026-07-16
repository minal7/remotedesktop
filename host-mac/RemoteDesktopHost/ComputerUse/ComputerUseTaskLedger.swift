import Foundation

/// A small at-most-once ledger for privileged prompts. It is written before a
/// prompt starts, so an ambiguous CloudKit retry or host restart cannot execute
/// the same task ID twice. Terminal responses are retained for safe replay.
final class ComputerUseTaskLedger {
    enum Claim: Equatable {
        case new
        case accepted
        case paused(appliedControlRevision: UInt64)
        case completed(String)
        case identityMismatch
    }

    enum Control: String, Codable, Equatable {
        case pause
        case resume
        case cancel
    }

    enum ControlState: String, Codable, Equatable {
        case running
        case paused
        case cancelled
    }

    struct ControlResolution: Equatable {
        enum Disposition: Equatable {
            case advanced
            case duplicateOrStale
            case identityMismatch
        }

        let disposition: Disposition
        let state: ControlState?
        let appliedRevision: UInt64?
        let terminalResponse: String?
        let promptClaimed: Bool
    }

    enum LedgerError: Error, Equatable {
        case invalidIdentity
        case invalidControl
        case unavailable
    }

    static let stoppedResponse = "Stopped. You're in control of the Mac."

    private struct ControlSnapshot: Codable {
        var revision: UInt64
        var state: ControlState
    }

    private struct Record: Codable {
        let acceptedAt: Date
        var senderID: String?
        var sessionID: String?
        var promptClaimed: Bool
        var executionStarted: Bool
        var response: String?
        var control: ControlSnapshot?

        init(
            acceptedAt: Date,
            senderID: String,
            sessionID: String,
            promptClaimed: Bool,
            executionStarted: Bool,
            response: String? = nil,
            control: ControlSnapshot? = nil
        ) {
            self.acceptedAt = acceptedAt
            self.senderID = senderID
            self.sessionID = sessionID
            self.promptClaimed = promptClaimed
            self.executionStarted = executionStarted
            self.response = response
            self.control = control
        }

        private enum CodingKeys: String, CodingKey {
            case acceptedAt
            case senderID
            case sessionID
            case promptClaimed
            case executionStarted
            case response
            case control
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            acceptedAt = try values.decode(Date.self, forKey: .acceptedAt)
            senderID = try values.decodeIfPresent(String.self, forKey: .senderID)
            sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
            response = try values.decodeIfPresent(String.self, forKey: .response)
            control = try values.decodeIfPresent(
                ControlSnapshot.self,
                forKey: .control)
            // Records written before ordered controls existed were created
            // only by Prompt claims, and therefore conservatively represent
            // an execution that may already have started.
            promptClaimed = try values.decodeIfPresent(
                Bool.self,
                forKey: .promptClaimed) ?? true
            executionStarted = try values.decodeIfPresent(
                Bool.self,
                forKey: .executionStarted) ?? true
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var initializationError: LedgerError?
    private var records: [String: Record]

    init(
        fileURL: URL = ComputerUseTaskLedger.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(
                [String: Record].self,
                from: data)
            records = decoded
            initializationError = nil
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile {
            // A genuinely new ledger is the only condition that may start
            // from an empty set. Existing unreadable or malformed state could
            // contain an accepted privileged task and must poison the ledger
            // rather than make that task executable again.
            records = [:]
            initializationError = nil
        } catch {
            records = [:]
            initializationError = .unavailable
        }
    }

    func claim(
        taskID: String,
        senderID: String,
        sessionID: String
    ) throws -> Claim {
        try ensureAvailable()
        guard Self.validIdentity(
            taskID: taskID,
            senderID: senderID,
            sessionID: sessionID) else {
            throw LedgerError.invalidIdentity
        }

        guard var record = records[taskID] else {
            let record = Record(
                acceptedAt: Date(),
                senderID: senderID,
                sessionID: sessionID,
                promptClaimed: true,
                executionStarted: true)
            try commit(record, for: taskID)
            return .new
        }
        let wasUnbound = record.senderID == nil || record.sessionID == nil
        guard bindOrMatch(
            &record,
            senderID: senderID,
            sessionID: sessionID) else {
            return .identityMismatch
        }

        if let response = record.response {
            if !record.promptClaimed || wasUnbound {
                record.promptClaimed = true
                try commit(record, for: taskID)
            }
            return .completed(response)
        }

        if record.control?.state == .paused,
           !record.executionStarted {
            record.promptClaimed = true
            try commit(record, for: taskID)
            return .paused(
                appliedControlRevision: record.control?.revision ?? 0)
        }

        // Resume may arrive after a pre-Prompt Pause has already caused the
        // Prompt to be claimed. It remains safe to start exactly once because
        // the durable record proves no execution began while it was paused.
        if !record.executionStarted {
            record.promptClaimed = true
            record.executionStarted = true
            try commit(record, for: taskID)
            return .new
        }
        if wasUnbound {
            try commit(record, for: taskID)
        }
        return .accepted
    }

    func applyControl(
        _ control: Control,
        taskID: String,
        revision: UInt64,
        senderID: String,
        sessionID: String
    ) throws -> ControlResolution {
        try ensureAvailable()
        guard Self.validIdentity(
            taskID: taskID,
            senderID: senderID,
            sessionID: sessionID) else {
            throw LedgerError.invalidIdentity
        }
        guard revision > 0 else { throw LedgerError.invalidControl }

        var record = records[taskID] ?? Record(
            acceptedAt: Date(),
            senderID: senderID,
            sessionID: sessionID,
            promptClaimed: false,
            executionStarted: false)
        guard bindOrMatch(
            &record,
            senderID: senderID,
            sessionID: sessionID) else {
            return ControlResolution(
                disposition: .identityMismatch,
                state: nil,
                appliedRevision: nil,
                terminalResponse: nil,
                promptClaimed: record.promptClaimed)
        }

        if let applied = record.control, revision <= applied.revision {
            return ControlResolution(
                disposition: .duplicateOrStale,
                state: applied.state,
                appliedRevision: applied.revision,
                terminalResponse: record.response,
                promptClaimed: record.promptClaimed)
        }

        let reducedState: ControlState
        if record.control?.state == .cancelled {
            // Cancel is absorbing. A later Pause or Resume advances the
            // acknowledgement revision, but it can never resurrect the task.
            reducedState = .cancelled
        } else {
            switch control {
            case .pause: reducedState = .paused
            case .resume: reducedState = .running
            case .cancel: reducedState = .cancelled
            }
        }
        record.control = ControlSnapshot(
            revision: revision,
            state: reducedState)
        if reducedState == .cancelled, record.response == nil {
            // Persist the terminal result before the manager cancels any
            // active executor. A delayed completion can no longer overwrite
            // this absorbing user intent.
            record.response = Self.stoppedResponse
        }
        try commit(record, for: taskID)
        return ControlResolution(
            disposition: .advanced,
            state: reducedState,
            appliedRevision: revision,
            terminalResponse: record.response,
            promptClaimed: record.promptClaimed)
    }

    func complete(taskID: String, response: String) {
        guard initializationError == nil else { return }
        guard var record = records[taskID] else { return }
        // The first terminal result wins. In particular, an executor that
        // unwinds after a durable Cancel cannot replace the stopped response.
        guard record.response == nil else { return }
        record.response = String(response.prefix(4_000))
        try? commit(record, for: taskID)
    }

    func appliedControlRevision(taskID: String) -> UInt64? {
        guard initializationError == nil else { return nil }
        return records[taskID]?.control?.revision
    }

    private func ensureAvailable() throws {
        if let initializationError {
            throw initializationError
        }
    }

    private func bindOrMatch(
        _ record: inout Record,
        senderID: String,
        sessionID: String
    ) -> Bool {
        if let boundSenderID = record.senderID,
           let boundSessionID = record.sessionID {
            return boundSenderID == senderID && boundSessionID == sessionID
        }
        // This is the one-time migration path for a pre-control ledger record.
        // Once bound, every future Prompt and control must present both values.
        record.senderID = senderID
        record.sessionID = sessionID
        return true
    }

    private static func validIdentity(
        taskID: String,
        senderID: String,
        sessionID: String
    ) -> Bool {
        !taskID.isEmpty && !senderID.isEmpty && !sessionID.isEmpty
    }

    private func commit(_ record: Record, for taskID: String) throws {
        var candidate = records
        candidate[taskID] = record
        prune(&candidate)
        do {
            try persist(candidate)
        } catch {
            // A failed atomic write leaves the caller unable to prove whether
            // the safety state reached durable storage. Poison this in-process
            // ledger so a later Prompt cannot execute merely because the disk
            // recovers before the unacknowledged Pause or Cancel is retried.
            initializationError = .unavailable
            throw error
        }
        records = candidate
    }

    private func prune(_ candidate: inout [String: Record]) {
        let cutoff = Date(timeIntervalSinceNow: -(90 * 24 * 60 * 60))
        let accepted = candidate.filter {
            $0.value.promptClaimed && $0.value.response == nil
        }
        let replayable = candidate
            .filter {
                (!$0.value.promptClaimed || $0.value.response != nil)
                    && $0.value.acceptedAt >= cutoff
            }
            .sorted { $0.value.acceptedAt > $1.value.acceptedAt }
        // Never evict an accepted-but-nonterminal privileged task: doing so
        // would permit a delayed retry to execute it again after a restart.
        // Terminal records and controls that arrived before their Prompt
        // outlive CloudKit's delivery window by a wide margin, while the
        // generous cap keeps storage bounded.
        let replayableCapacity = max(0, 10_000 - accepted.count)
        candidate = accepted
        for (key, value) in replayable.prefix(replayableCapacity) {
            candidate[key] = value
        }
    }

    private func persist(_ candidate: [String: Record]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(candidate).write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Tasks", isDirectory: true)
            .appendingPathComponent("processed-prompts.json")
    }
}
