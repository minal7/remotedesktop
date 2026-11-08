import CryptoKit
import Darwin
import Foundation

/// A small at-most-once ledger for privileged prompts. It is written before a
/// prompt starts, so an ambiguous CloudKit retry or host restart cannot execute
/// the same task ID twice. Terminal responses are retained for safe replay.
final class ComputerUseTaskLedger {
    /// A retained question must reach the person exactly. This character
    /// limit matches ComputerUseTaskUpdate's outgoing text bound.
    static let maximumClarificationCharacters = ComputerUseClarificationText.maximumCharacters
    static let maximumClarificationUTF8Bytes = ComputerUseClarificationText.maximumUTF8Bytes
    enum Claim: Equatable {
        case new
        case accepted
        case paused(appliedControlRevision: UInt64)
        case completed(String)
        case identityMismatch
        case promptIdentityUnavailable
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
            case staleHostEpoch
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
        case invalidClarification
        case unavailable
    }

    enum ClarificationOwner: String, Codable { case browser, text }

    struct TerminalResult: Equatable {
        let response: String
        let outcome: ComputerUseTerminalOutcome?
        let clarification: ComputerUseClarificationReference?
        let clarificationRetry: ComputerUseClarificationRetry?
        init(response: String, outcome: ComputerUseTerminalOutcome?, clarification: ComputerUseClarificationReference?,
             clarificationRetry: ComputerUseClarificationRetry? = nil) {
            self.response = response; self.outcome = outcome; self.clarification = clarification; self.clarificationRetry = clarificationRetry
        }
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
        var promptDigest: String?
        var promptClaimed: Bool
        var executionStarted: Bool
        var response: String?
        var outcome: ComputerUseTerminalOutcome?
        var clarification: ComputerUseClarificationReference?
        var clarificationRetry: ComputerUseClarificationRetry? = nil
        /// Historical owner kind, not proof that a native owner still exists.
        var clarificationOwner: ClarificationOwner? = nil
        var control: ControlSnapshot?
        var hostControlEpoch: UInt64 = 0
        var localControlState: ControlState?

        var effectiveControlState: ControlState? {
            control?.state == .cancelled ? .cancelled : (localControlState ?? control?.state)
        }

        init(
            acceptedAt: Date,
            senderID: String,
            sessionID: String,
            promptClaimed: Bool,
            executionStarted: Bool,
            promptDigest: String? = nil,
            response: String? = nil,
            outcome: ComputerUseTerminalOutcome? = nil,
            control: ControlSnapshot? = nil
        ) {
            self.acceptedAt = acceptedAt
            self.senderID = senderID
            self.sessionID = sessionID
            self.promptDigest = promptDigest
            self.promptClaimed = promptClaimed
            self.executionStarted = executionStarted
            self.response = response
            self.outcome = outcome
            self.clarification = nil
            self.control = control
        }

        private enum CodingKeys: String, CodingKey {
            case acceptedAt
            case senderID
            case sessionID
            case promptDigest
            case promptClaimed
            case executionStarted
            case response
            case outcome
            case clarification
            case clarificationRetry
            case clarificationOwner
            case control
            case hostControlEpoch
            case localControlState
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            acceptedAt = try values.decode(Date.self, forKey: .acceptedAt)
            senderID = try values.decodeIfPresent(String.self, forKey: .senderID)
            sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
            promptDigest = try values.decodeIfPresent(String.self, forKey: .promptDigest)
            response = try values.decodeIfPresent(String.self, forKey: .response)
            if let rawOutcome = try values.decodeIfPresent(
                String.self,
                forKey: .outcome) {
                outcome = ComputerUseTerminalOutcome(rawValue: rawOutcome)
            } else {
                outcome = nil
            }
            clarification = try values.decodeIfPresent(ComputerUseClarificationReference.self, forKey: .clarification)
            clarificationRetry = try values.decodeIfPresent(ComputerUseClarificationRetry.self, forKey: .clarificationRetry)
            clarificationOwner = try values.decodeIfPresent(ClarificationOwner.self, forKey: .clarificationOwner)
            control = try values.decodeIfPresent(
                ControlSnapshot.self,
                forKey: .control)
            hostControlEpoch = try values.decodeIfPresent(UInt64.self, forKey: .hostControlEpoch) ?? 0
            localControlState = try values.decodeIfPresent(ControlState.self, forKey: .localControlState)
            // Records written before ordered controls existed were created
            // only by Prompt claims, and therefore conservatively represent
            // an execution that may already have started.
            promptClaimed = try values.decodeIfPresent(
                Bool.self,
                forKey: .promptClaimed) ?? true
            executionStarted = try values.decodeIfPresent(
                Bool.self,
                forKey: .executionStarted) ?? true
            if !promptClaimed && executionStarted { throw LedgerError.unavailable }
            if let promptDigest {
                guard promptClaimed, senderID != nil, sessionID != nil,
                      promptDigest.utf8.count == 64,
                      promptDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw LedgerError.unavailable
                }
            }
            if hostControlEpoch > 0 || localControlState != nil {
                guard hostControlEpoch > 0, promptClaimed, promptDigest != nil,
                      localControlState != .cancelled else { throw LedgerError.unavailable }
            }
            if clarificationOwner != nil {
                guard outcome == .userInterventionRequired, let response, ComputerUseClarificationText.isValid(response),
                      promptClaimed, promptDigest != nil, clarificationRetry == nil,
                      clarification != nil || control?.state == .cancelled else { throw LedgerError.unavailable }
            }
            if clarificationRetry != nil {
                guard outcome == .userInterventionRequired, clarification == nil,
                      let response, ComputerUseClarificationText.isValid(response),
                      promptClaimed, promptDigest != nil else { throw LedgerError.unavailable }
            }
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
            guard decoded.allSatisfy({ key, record in
                (record.clarificationRetry.map { $0.reference.taskID != key } ?? true)
                    && (record.clarificationOwner == nil || record.clarification == nil || record.clarification?.taskID == key)
            }) else {
                throw LedgerError.unavailable
            }
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
        sessionID: String,
        promptBody: String
    ) throws -> Claim {
        try ensureAvailable()
        guard Self.validIdentity(
            taskID: taskID,
            senderID: senderID,
            sessionID: sessionID) else {
            throw LedgerError.invalidIdentity
        }

        // Hash the exact wire bytes, not Swift String equality or decoded JSON:
        // Unicode normalization, conversation and clarification changes matter.
        let digest = SHA256.hash(data: Data(promptBody.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard var record = records[taskID] else {
            let record = Record(
                acceptedAt: Date(),
                senderID: senderID,
                sessionID: sessionID,
                promptClaimed: true,
                executionStarted: true,
                promptDigest: digest)
            try commit(record, for: taskID)
            return .new
        }
        guard bindOrMatch(
            &record,
            senderID: senderID,
            sessionID: sessionID) else {
            return .identityMismatch
        }
        if let originalDigest = record.promptDigest {
            guard originalDigest == digest else { return .identityMismatch }
        } else if record.promptClaimed {
            // A retry cannot retroactively establish the content of an old
            // claimed request. Keep the original record intact for recovery.
            return .promptIdentityUnavailable
        } else {
            // Only a control-only record has never received a Prompt. Bind its
            // first body in the same durable write that claims the instruction.
            record.promptDigest = digest
        }

        if let response = record.response {
            if !record.promptClaimed {
                record.promptClaimed = true
                try commit(record, for: taskID)
            }
            return .completed(response)
        }

        if record.effectiveControlState == .paused,
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
        return .accepted
    }

    /// Legacy results have no proof of which instruction they answered. This
    /// also gates control replies, whose envelopes intentionally have no body.
    func requiresPromptIdentityRecovery(taskID: String) -> Bool {
        guard initializationError == nil, let record = records[taskID] else { return false }
        return record.promptClaimed && record.promptDigest == nil
    }

    func applyControl(
        _ control: Control,
        taskID: String,
        revision: UInt64,
        senderID: String,
        sessionID: String,
        observedHostControlEpoch: UInt64? = nil
    ) throws -> ControlResolution {
        try reduceControl(control, taskID: taskID, revision: revision,
                          senderID: senderID, sessionID: sessionID,
                          observedHostControlEpoch: observedHostControlEpoch, permitsFinalLocalCancel: false)
    }

    /// Local takeover/handback has its own durable clock. It must not borrow
    /// phone revisions: an in-flight higher phone revision can predate this
    /// choice. Only a claimed, content-bound task can receive local authority.
    @discardableResult
    func applyLocalControl(_ control: Control, taskID: String, senderID: String,
                           sessionID: String) throws -> UInt64 {
        try ensureAvailable()
        guard control != .cancel else { throw LedgerError.invalidControl }
        guard var record = records[taskID], record.senderID == senderID,
              record.sessionID == sessionID, record.promptClaimed, record.promptDigest != nil,
              record.response == nil, record.effectiveControlState != .cancelled else {
            throw LedgerError.invalidIdentity
        }
        guard record.hostControlEpoch < UInt64.max else { throw LedgerError.invalidControl }
        record.hostControlEpoch += 1
        record.localControlState = control == .pause ? .paused : .running
        try commit(record, for: taskID)
        return record.hostControlEpoch
    }

    func hostControlEpoch(taskID: String) -> UInt64 {
        records[taskID]?.hostControlEpoch ?? 0
    }

    func canResumeLocally(taskID: String, senderID: String, sessionID: String) -> Bool {
        guard initializationError == nil, let record = records[taskID] else { return false }
        return record.senderID == senderID && record.sessionID == sessionID
            && record.promptClaimed && record.promptDigest != nil && record.response == nil
            && record.effectiveControlState != .cancelled && record.hostControlEpoch < UInt64.max
    }

    /// A local Stop is absorbing, including when the remote counter is
    /// exhausted. It never grants Pause/Resume permission to reuse a revision.
    func cancelLocally(taskID: String, senderID: String, sessionID: String) throws -> ControlResolution {
        let previous = appliedControlRevision(taskID: taskID) ?? 0
        return try reduceControl(.cancel, taskID: taskID,
            revision: previous == UInt64.max ? previous : previous + 1,
            senderID: senderID, sessionID: sessionID,
            observedHostControlEpoch: nil, permitsFinalLocalCancel: true)
    }

    private func reduceControl(_ control: Control, taskID: String, revision: UInt64,
                               senderID: String, sessionID: String,
                               observedHostControlEpoch: UInt64?,
                               permitsFinalLocalCancel: Bool) throws -> ControlResolution {
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

        let canCancelAtExhaustedRevision = permitsFinalLocalCancel && control == .cancel
            && revision == UInt64.max && record.control?.revision == UInt64.max
            && record.control?.state != .cancelled
        if let applied = record.control, revision <= applied.revision, !canCancelAtExhaustedRevision {
            return ControlResolution(
                disposition: .duplicateOrStale,
                state: record.effectiveControlState,
                appliedRevision: applied.revision,
                terminalResponse: record.response,
                promptClaimed: record.promptClaimed)
        }

        // Stop and terminal acknowledgements cannot resurrect a task. Every
        // live Pause/Resume must instead have observed the latest local choice.
        // Rejection leaves the phone revision untouched; it is not an ack.
        if control != .cancel, record.response == nil,
           ((observedHostControlEpoch ?? 0) != record.hostControlEpoch || record.hostControlEpoch == UInt64.max) {
            return ControlResolution(disposition: .staleHostEpoch,
                state: record.effectiveControlState,
                appliedRevision: record.control?.revision,
                terminalResponse: nil, promptClaimed: record.promptClaimed)
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
        record.localControlState = nil
        // Keep a retry's historical question association so a retried Cancel
        // can finish cancelling that question after a partial storage failure.
        // terminalClarificationRetry never exposes it once cancelled.
        if reducedState == .cancelled { record.clarification = nil }
        if reducedState == .cancelled, record.response == nil {
            // Persist the terminal result before the manager cancels any
            // active executor. A delayed completion can no longer overwrite
            // this absorbing user intent.
            record.response = Self.stoppedResponse
            record.outcome = .unableToComplete
        }
        try commit(record, for: taskID)
        return ControlResolution(
            disposition: .advanced,
            state: reducedState,
            appliedRevision: revision,
            terminalResponse: record.response,
            promptClaimed: record.promptClaimed)
    }

    @discardableResult
    func complete(
        taskID: String,
        response: String,
        outcome: ComputerUseTerminalOutcome? = nil,
        clarification: ComputerUseClarificationReference? = nil,
        clarificationRetry: ComputerUseClarificationRetry? = nil,
        clarificationOwner: ClarificationOwner? = nil
    ) throws -> TerminalResult {
        try ensureAvailable()
        guard var record = records[taskID] else {
            throw LedgerError.unavailable
        }
        // The first terminal result wins. In particular, an executor that
        // unwinds after a durable Cancel cannot replace the stopped response.
        if let existingResponse = record.response {
            return TerminalResult(
                response: existingResponse,
                outcome: record.outcome, clarification: record.clarification, clarificationRetry: record.clarificationRetry)
        }
        let retainedQuestion = outcome == .userInterventionRequired && clarification?.taskID == taskID ? clarification : nil
        if clarificationOwner != nil {
            guard retainedQuestion != nil, clarificationRetry == nil, record.promptClaimed, record.promptDigest != nil else {
                throw LedgerError.invalidClarification
            }
        }
        if let retry = clarificationRetry {
            guard outcome == .userInterventionRequired, clarification == nil, retry.reference.taskID != taskID,
                  record.promptClaimed, record.promptDigest != nil,
                  let sender = record.senderID, let session = record.sessionID,
                  let question = records[retry.reference.taskID], question.response != nil,
                  question.outcome == .userInterventionRequired, question.clarification == retry.reference,
                  question.senderID == sender, question.sessionID == session,
                  question.effectiveControlState != .cancelled else { throw LedgerError.invalidClarification }
            // executionStarted is the existing admission/idempotency fence,
            // set by claim before decoding or invoking an executor. Keep it
            // intact; native rejection, not this flag, proves no answer ran.
        }
        if retainedQuestion != nil || clarificationRetry != nil {
            guard ComputerUseClarificationText.isValid(response) else { throw LedgerError.invalidClarification }
        }
        record.response = retainedQuestion == nil && clarificationRetry == nil ? String(response.prefix(4_000)) : response
        record.outcome = outcome
        record.clarification = retainedQuestion
        record.clarificationRetry = clarificationRetry
        record.clarificationOwner = clarificationOwner
        try commit(record, for: taskID)
        return TerminalResult(
            response: record.response ?? "",
            outcome: record.outcome, clarification: record.clarification, clarificationRetry: record.clarificationRetry)
    }

    func terminalOutcome(taskID: String) -> ComputerUseTerminalOutcome? {
        guard initializationError == nil else { return nil }
        return records[taskID]?.outcome
    }

    func terminalClarification(taskID: String) -> ComputerUseClarificationReference? {
        guard initializationError == nil, let record = records[taskID], record.response != nil,
              record.outcome == .userInterventionRequired, record.control?.state != .cancelled,
              record.clarification?.taskID == taskID else { return nil }
        return record.clarification
    }

    func terminalClarificationText(taskID: String) -> String? {
        guard terminalClarification(taskID: taskID) != nil else { return nil }
        return records[taskID]?.response
    }

    func terminalClarificationRetry(taskID: String) -> ComputerUseClarificationRetry? {
        guard initializationError == nil, let record = records[taskID], record.response != nil,
              record.outcome == .userInterventionRequired, record.effectiveControlState != .cancelled,
              record.clarificationRetry?.reference.taskID != taskID else { return nil }
        return record.clarificationRetry
    }

    func isCancelled(taskID: String) -> Bool {
        initializationError == nil && records[taskID]?.effectiveControlState == .cancelled
    }

    func clarificationOwner(taskID: String) -> ClarificationOwner? {
        guard initializationError == nil else { return nil }
        return records[taskID]?.clarificationOwner
    }

    func rejectedAnswerReference(taskID: String) -> ComputerUseClarificationReference? {
        guard initializationError == nil else { return nil }
        return records[taskID]?.clarificationRetry?.reference
    }

    func appliedControlRevision(taskID: String) -> UInt64? {
        // `records` advances only after `persist` succeeds, so this remains
        // the last revision the host can prove reached durable storage even
        // when a later terminal write poisons the ledger. Terminal fallback
        // replies must carry that committed revision or a client that already
        // received Resume would correctly reject them as stale.
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
        if let boundSenderID = record.senderID, boundSenderID != senderID { return false }
        if let boundSessionID = record.sessionID, boundSessionID != sessionID { return false }
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
        // outlive the delivery window by a wide margin, while the generous
        // cap keeps storage bounded.
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
