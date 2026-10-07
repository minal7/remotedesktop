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

    /// Independent of the task's first terminal result. Stop can remain the
    /// terminal outcome while a late helper result confirms an approved effect.
    struct ApprovedActionRecord: Codable, Equatable {
        let fingerprint: MCPApprovalFingerprint
        let attemptedAt: Date
        var response: String?
        var responseDigest: String? = nil
        /// Present only when the host separately proved the complete original
        /// request. Legacy records and action-only confirmations leave it nil.
        var completionPromptDigest: String? = nil
        var stepEffectID: String? = nil
        var confirmedAt: Date? = nil

        func exactlyMatches(_ other: ApprovedActionRecord?) -> Bool {
            guard let other, self == other else { return false }
            switch (response, other.response) {
            case (.some(let lhs), .some(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
            case (.none, .none): return true
            default: return false
            }
        }
    }

    /// Durable approval order projected from an already host-bound task
    /// contract. This journal records dispatch/confirmation; it does not
    /// evaluate the contract's external preconditions or whole-goal outcomes.
    struct ApprovedActionPlan: Codable, Equatable {
        struct Step: Codable, Equatable {
            let effectID: String
            let callDigest: String
        }
        let taskID: String
        let requestDigest: String
        let contractDigest: String
        let steps: [Step]
        let planDigest: String

        init(contract: ComputerUseTaskContract, promptBody: String, calls: [MCPToolCall]) throws {
            let prompt = ComputerUsePromptRequest.decodeCompatibleBody(promptBody).prompt
            let approvedSteps = contract.steps.filter { $0.operation.capabilityID == "mcp.approved" }
            guard promptBody.utf8.count <= 1_048_576,
                  contract.promptDigest == ComputerUseTaskContract.digest([prompt]),
                  !approvedSteps.isEmpty, approvedSteps.count == calls.count else { throw LedgerError.invalidIdentity }
            var bindings: [Step] = []
            for (step, call) in zip(approvedSteps, calls) {
                let reconstructed = try MCPToolCall(taskID: call.taskID, serverID: call.serverID,
                    processGeneration: call.processGeneration, toolName: call.toolName, arguments: call.arguments,
                    schemaDigest: call.schemaDigest, risk: call.risk, approval: call.approvalDisplay, stepEffectID: call.stepEffectID)
                guard reconstructed == call, call.taskID == contract.taskID, call.risk == .approvalRequired,
                      call.stepEffectID == contract.effectIdentity(for: step), step.operation.payloadVersion == 1,
                      step.operation.payloadDigest == call.argumentsDigest,
                      contract.entities.first(where: { $0.id == step.operation.entityID })?.authorityDigest
                        == Self.authorityDigest(for: call) else { throw LedgerError.invalidIdentity }
                bindings.append(.init(effectID: contract.effectIdentity(for: step), callDigest: call.canonicalDigest))
            }
            taskID = contract.taskID
            requestDigest = SHA256.hash(data: Data(promptBody.utf8)).map { String(format: "%02x", $0) }.joined()
            contractDigest = contract.contractDigest
            steps = bindings
            planDigest = Self.digest(taskID: taskID, requestDigest: requestDigest, contractDigest: contractDigest, steps: bindings)
            guard isWellFormed else { throw LedgerError.invalidIdentity }
        }

        static func authorityDigest(for call: MCPToolCall) -> String {
            ComputerUseTaskContract.digest(["mcp-approved-target-v1", call.serverID, call.toolName, call.schemaDigest])
        }

        var isWellFormed: Bool {
            !taskID.isEmpty && taskID.utf8.count <= 256
                && !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && ComputerUseTaskLedger.validDigest(requestDigest) && ComputerUseTaskLedger.validDigest(contractDigest)
                && (1...64).contains(steps.count)
                && Set(steps.map(\.effectID)).count == steps.count && Set(steps.map(\.callDigest)).count == steps.count
                && steps.allSatisfy({ ComputerUseTaskLedger.validDigest($0.effectID) && ComputerUseTaskLedger.validDigest($0.callDigest) })
                && planDigest == Self.digest(taskID: taskID, requestDigest: requestDigest, contractDigest: contractDigest, steps: steps)
        }

        private static func digest(taskID: String, requestDigest: String, contractDigest: String, steps: [Step]) -> String {
            ComputerUseTaskContract.digest(["approved-action-plan-v1", taskID, requestDigest, contractDigest, String(steps.count)]
                + steps.flatMap { [$0.effectID, $0.callDigest] })
        }
    }

    enum ApprovedActionClaim: Equatable {
        case new
        case existing(ApprovedActionRecord)
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
        var approvedAction: ApprovedActionRecord?
        /// The latest record is also encoded in approvedAction so an older
        /// host cannot mistake this task for one with no attempted mutation.
        var approvedActionPlan: ApprovedActionPlan? = nil
        var approvedActionSteps: [ApprovedActionRecord]? = nil

        var effectiveControlState: ControlState? {
            control?.state == .cancelled ? .cancelled : (localControlState ?? control?.state)
        }

        var approvalRetentionDate: Date {
            (approvedActionSteps ?? approvedAction.map { [$0] } ?? []).reduce(acceptedAt) {
                max($0, max($1.attemptedAt, $1.confirmedAt ?? $1.attemptedAt))
            }
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
            self.approvedAction = nil
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
            case approvedAction
            case approvedActionPlan, approvedActionSteps
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
            approvedAction = try values.decodeIfPresent(ApprovedActionRecord.self, forKey: .approvedAction)
            approvedActionPlan = try values.decodeIfPresent(ApprovedActionPlan.self, forKey: .approvedActionPlan)
            approvedActionSteps = try values.decodeIfPresent([ApprovedActionRecord].self, forKey: .approvedActionSteps)
            if clarificationOwner != nil {
                guard outcome == .userInterventionRequired, let response, ComputerUseClarificationText.isValid(response),
                      promptClaimed, promptDigest != nil, clarificationRetry == nil,
                      clarification != nil || control?.state == .cancelled else { throw LedgerError.unavailable }
            }
            if clarificationRetry != nil {
                guard outcome == .userInterventionRequired, clarification == nil,
                      let response, ComputerUseClarificationText.isValid(response),
                      promptClaimed, promptDigest != nil,
                      approvedAction == nil, approvedActionPlan == nil,
                      approvedActionSteps?.isEmpty ?? true else { throw LedgerError.unavailable }
            }
            if approvedAction != nil, !promptClaimed || !executionStarted || senderID == nil || sessionID == nil {
                throw LedgerError.unavailable
            }
            if let approvedAction, (approvedAction.response == nil) != (approvedAction.responseDigest == nil) {
                throw LedgerError.unavailable
            }
            if let proof = approvedAction?.completionPromptDigest {
                guard approvedAction?.response != nil, proof.utf8.count == 64,
                      proof.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw LedgerError.unavailable
                }
            }
            if let plan = approvedActionPlan, let actions = approvedActionSteps {
                guard plan.isWellFormed, promptDigest == plan.requestDigest,
                      !actions.isEmpty, actions.count <= plan.steps.count,
                      approvedAction?.exactlyMatches(actions.last) == true,
                      actions.enumerated().allSatisfy({ index, action in
                          action.stepEffectID == plan.steps[index].effectID
                            && action.fingerprint.canonicalDigest == plan.steps[index].callDigest
                            && action.completionPromptDigest == nil
                            && ((action.response == nil && action.responseDigest == nil && action.confirmedAt == nil && index == actions.count - 1)
                                || (action.response != nil && action.confirmedAt != nil
                                    && action.responseDigest.map(ComputerUseTaskLedger.validDigest) == true))
                      }) else { throw LedgerError.unavailable }
            } else {
                guard approvedActionPlan == nil, approvedActionSteps == nil, approvedAction?.stepEffectID == nil else {
                    throw LedgerError.unavailable
                }
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
                (record.approvedActionPlan.map { $0.taskID == key } ?? true)
                    && (record.clarificationRetry.map { $0.reference.taskID != key } ?? true)
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
                  record.approvedAction == nil, record.approvedActionPlan == nil,
                  record.approvedActionSteps?.isEmpty ?? true,
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

    func claimApprovedAction(taskID: String, senderID: String, sessionID: String,
                             prepared: MCPPreparedApproval) throws -> ApprovedActionClaim {
        try ensureAvailable()
        guard var record = records[taskID], record.promptClaimed, record.promptDigest != nil, record.executionStarted,
              record.senderID == senderID, record.sessionID == sessionID,
              prepared.call.taskID == taskID, prepared.call.risk == .approvalRequired,
              prepared.fingerprint.matches(call: prepared.call) else {
            throw LedgerError.invalidIdentity
        }
        // A legacy claim seals this task's dispatch. Scoped calls must use the
        // contract-bound overload and cannot reinterpret this legacy record.
        guard record.approvedActionPlan == nil, prepared.call.stepEffectID == nil else { throw LedgerError.invalidIdentity }
        if let existing = record.approvedAction { return .existing(existing) }
        guard record.response == nil, record.effectiveControlState != .cancelled,
              record.effectiveControlState != .paused else { throw LedgerError.invalidControl }
        record.approvedAction = ApprovedActionRecord(fingerprint: prepared.fingerprint, attemptedAt: Date(), response: nil)
        try commit(record, for: taskID)
        return .new
    }

    func claimApprovedAction(taskID: String, senderID: String, sessionID: String,
                             prepared: MCPPreparedApproval, plan: ApprovedActionPlan) throws -> ApprovedActionClaim {
        try ensureAvailable()
        guard var record = records[taskID], record.promptClaimed, record.executionStarted,
              record.senderID == senderID, record.sessionID == sessionID,
              plan.isWellFormed, plan.taskID == taskID, plan.requestDigest == record.promptDigest,
              prepared.call.taskID == taskID, prepared.call.risk == .approvalRequired,
              prepared.fingerprint.matches(call: prepared.call),
              let effectID = prepared.call.stepEffectID,
              let index = plan.steps.firstIndex(where: { $0.effectID == effectID }),
              plan.steps[index].callDigest == prepared.call.canonicalDigest else { throw LedgerError.invalidIdentity }
        let call = prepared.call
        let reconstructed = try MCPToolCall(taskID: call.taskID, serverID: call.serverID,
            processGeneration: call.processGeneration, toolName: call.toolName, arguments: call.arguments,
            schemaDigest: call.schemaDigest, risk: call.risk, approval: call.approvalDisplay, stepEffectID: call.stepEffectID)
        guard reconstructed == call else { throw LedgerError.invalidIdentity }
        if let existingPlan = record.approvedActionPlan {
            guard existingPlan == plan else { throw LedgerError.invalidIdentity }
        } else {
            guard record.approvedAction == nil, record.approvedActionSteps == nil else { throw LedgerError.invalidControl }
        }
        var actions = record.approvedActionSteps ?? []
        if index < actions.count { return .existing(actions[index]) }
        guard index == actions.count, actions.last.map({ $0.response != nil }) ?? true,
              record.response == nil, record.effectiveControlState != .cancelled,
              record.effectiveControlState != .paused else { throw LedgerError.invalidControl }
        let action = ApprovedActionRecord(fingerprint: prepared.fingerprint, attemptedAt: Date(),
            response: nil, stepEffectID: effectID)
        actions.append(action)
        record.approvedActionPlan = plan
        record.approvedActionSteps = actions
        record.approvedAction = action
        try commit(record, for: taskID)
        return .new
    }

    func recordApprovedActionResult(taskID: String, senderID: String, sessionID: String,
                                    fingerprint: MCPApprovalFingerprint, response: String,
                                    completionPromptDigest: String? = nil) throws {
        try ensureAvailable()
        guard var record = records[taskID], record.senderID == senderID, record.sessionID == sessionID else {
            throw LedgerError.invalidIdentity
        }
        let stepIndex = record.approvedActionSteps?.firstIndex { $0.fingerprint == fingerprint }
        var action: ApprovedActionRecord
        if let actions = record.approvedActionSteps {
            guard let stepIndex, completionPromptDigest == nil else { throw LedgerError.invalidIdentity }
            action = actions[stepIndex]
        } else {
            guard let existing = record.approvedAction, existing.fingerprint == fingerprint else { throw LedgerError.invalidIdentity }
            action = existing
        }
        if let proof = completionPromptDigest {
            guard proof.utf8.count == 64,
                  proof.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw LedgerError.invalidIdentity
            }
        }
        let bounded = String(response.prefix(4_000))
        let digest = try MCPDigest.sha256(of: .string(response))
        if action.response != nil {
            guard action.responseDigest == digest, action.completionPromptDigest == completionPromptDigest else {
                throw LedgerError.invalidIdentity
            }
            return
        }
        action.response = bounded
        action.responseDigest = digest
        action.completionPromptDigest = completionPromptDigest
        action.confirmedAt = Date()
        if let stepIndex {
            record.approvedActionSteps?[stepIndex] = action
            record.approvedAction = record.approvedActionSteps?.last
        } else { record.approvedAction = action }
        // Do not change a Cancel/Stop terminal or its control revision.
        try commit(record, for: taskID)
    }

    func approvedAction(taskID: String, senderID: String, sessionID: String,
                        fingerprint: MCPApprovalFingerprint? = nil) throws -> ApprovedActionRecord? {
        let actions = try approvedActionHistory(taskID: taskID, senderID: senderID, sessionID: sessionID)
        if let fingerprint { return actions.first { $0.fingerprint == fingerprint } }
        return actions.last
    }

    func approvedActionHistory(taskID: String, senderID: String, sessionID: String) throws -> [ApprovedActionRecord] {
        try ensureAvailable()
        guard let record = records[taskID], record.senderID == senderID, record.sessionID == sessionID else {
            throw LedgerError.invalidIdentity
        }
        return record.approvedActionSteps ?? record.approvedAction.map { [$0] } ?? []
    }

    func approvedActionPlan(taskID: String, senderID: String, sessionID: String) throws -> ApprovedActionPlan? {
        try ensureAvailable()
        guard let record = records[taskID], record.senderID == senderID, record.sessionID == sessionID else {
            throw LedgerError.invalidIdentity
        }
        return record.approvedActionPlan
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

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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
            ($0.value.promptClaimed && $0.value.response == nil)
                || ($0.value.approvedAction != nil && $0.value.approvedAction?.response == nil)
        }
        let replayable = candidate
            .filter {
                (!$0.value.promptClaimed || $0.value.response != nil)
                    && !($0.value.approvedAction != nil && $0.value.approvedAction?.response == nil)
                    && $0.value.approvalRetentionDate >= cutoff
            }
            .sorted { $0.value.approvalRetentionDate > $1.value.approvalRetentionDate }
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

/// Privacy-safe evidence for browser pointer effects that were actually
/// posted by the visual executor. This is deliberately separate from the
/// at-most-once task ledger: an unavailable evidence file must never make the
/// executor retry an input that may already have reached macOS.
struct ComputerUseBrowserActionGroundingDraft: Equatable, Sendable {
    let directive: String
    let rawNormalizedPoint: [Int]
    let preHostGroundingNormalizedPoint: [Int]
}

/// A bounded, owner-only attestation ledger used by local live acceptance.
/// It contains no prompt, target label, visible text, account identity, or
/// response. Records are appended only after `ComputerUseHostTools.perform`
/// returns successfully.
actor ComputerUseBrowserActionAttestationLedger {
    enum PlannerProvenance: String, Codable, Equatable, Sendable {
        case appleFoundationModels = "apple-foundation-models"
        case nonFoundation = "non-foundation"
        case mixed
    }

    enum LedgerError: Error, Equatable {
        case invalidRecord
        case unsafePath
        case malformedLedger
        case oversizedLedger
    }

    private struct Grounding: Codable, Equatable {
        let directive: String
        let rawNormalizedPoint: [Int]
        let preHostGroundingNormalizedPoint: [Int]
        let hostGroundingApplied: Bool
        let groundedScreenPoint: [Int]
        let effectPosted: Bool
    }

    private struct TaskRecord: Codable, Equatable {
        var plannerProvenance: PlannerProvenance
        var groundings: [Grounding]
        var updatedAt: Date
    }

    private struct Snapshot: Codable, Equatable {
        let version: Int
        var tasks: [String: TaskRecord]
    }

    static let version = 1
    static let maximumTasks = 10_000
    static let maximumGroundingsPerTask = 100
    static let maximumEncodedBytes = 8 * 1_024 * 1_024
    static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true)
        return base
            .appendingPathComponent(
                "Remote Desktop Host",
                isDirectory: true)
            .appendingPathComponent(
                "Computer Use Tasks",
                isDirectory: true)
            .appendingPathComponent(
                "browser-action-attestations.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var loadedSnapshot: Snapshot?

    init(
        fileURL: URL = ComputerUseBrowserActionAttestationLedger
            .defaultFileURL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    func recordPostedGrounding(
        taskID: String,
        plannerProvenance: PlannerProvenance,
        draft: ComputerUseBrowserActionGroundingDraft,
        groundedScreenPoint: [Int]
    ) throws {
        guard Self.validTaskID(taskID),
              Self.validDirective(draft.directive),
              Self.validNormalizedPoint(draft.rawNormalizedPoint),
              draft.preHostGroundingNormalizedPoint
                == draft.rawNormalizedPoint,
              Self.validScreenPoint(groundedScreenPoint) else {
            throw LedgerError.invalidRecord
        }

        var candidate = try loadSnapshotIfNeeded()
        let timestamp = now()
        var task = candidate.tasks[taskID] ?? TaskRecord(
            plannerProvenance: plannerProvenance,
            groundings: [],
            updatedAt: timestamp)
        if task.plannerProvenance != plannerProvenance {
            task.plannerProvenance = .mixed
        }
        task.groundings.append(Grounding(
            directive: draft.directive,
            rawNormalizedPoint: draft.rawNormalizedPoint,
            preHostGroundingNormalizedPoint:
                draft.preHostGroundingNormalizedPoint,
            hostGroundingApplied: true,
            groundedScreenPoint: groundedScreenPoint,
            effectPosted: true))
        if task.groundings.count > Self.maximumGroundingsPerTask {
            task.groundings.removeFirst(
                task.groundings.count - Self.maximumGroundingsPerTask)
        }
        task.updatedAt = timestamp
        candidate.tasks[taskID] = task
        prune(&candidate, now: timestamp)
        try persist(candidate)
        loadedSnapshot = candidate
    }

    private func loadSnapshotIfNeeded() throws -> Snapshot {
        if let loadedSnapshot { return loadedSnapshot }
        let snapshot = try withPinnedDirectory { directory in
            guard let data = try readExistingFile(directory: directory) else {
                return Snapshot(version: Self.version, tasks: [:])
            }
            guard data.count <= Self.maximumEncodedBytes else {
                throw LedgerError.oversizedLedger
            }
            let decoded: Snapshot
            do {
                decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            } catch {
                throw LedgerError.malformedLedger
            }
            guard decoded.version == Self.version,
                  decoded.tasks.count <= Self.maximumTasks,
                  decoded.tasks.allSatisfy({ taskID, task in
                      Self.validTaskID(taskID)
                        && task.groundings.count
                            <= Self.maximumGroundingsPerTask
                        && task.groundings.allSatisfy(Self.validGrounding)
                  }) else {
                throw LedgerError.malformedLedger
            }
            return decoded
        }
        loadedSnapshot = snapshot
        return snapshot
    }

    private func prune(_ snapshot: inout Snapshot, now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        snapshot.tasks = snapshot.tasks.filter {
            $0.value.updatedAt >= cutoff
        }
        if snapshot.tasks.count > Self.maximumTasks {
            let retained = snapshot.tasks.sorted {
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt > $1.value.updatedAt
                }
                return $0.key < $1.key
            }.prefix(Self.maximumTasks)
            snapshot.tasks = Dictionary(uniqueKeysWithValues: retained.map {
                ($0.key, $0.value)
            })
        }
    }

    private func persist(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumEncodedBytes else {
            throw LedgerError.oversizedLedger
        }
        try withPinnedDirectory { directory in
            try validateExistingDestination(directory: directory)
            let name = fileURL.lastPathComponent
            let temporaryName = ".\(name).\(UUID().uuidString).tmp"
            let temporary = temporaryName.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
            }
            guard temporary >= 0 else { throw Self.posixError() }
            var renamed = false
            defer {
                Darwin.close(temporary)
                if !renamed {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(directory, $0, 0)
                    }
                }
            }
            guard Darwin.fchmod(temporary, S_IRUSR | S_IWUSR) == 0 else {
                throw Self.posixError()
            }
            var temporaryStatus = stat()
            guard Darwin.fstat(temporary, &temporaryStatus) == 0,
                  temporaryStatus.st_mode & S_IFMT == S_IFREG,
                  temporaryStatus.st_uid == Darwin.geteuid(),
                  temporaryStatus.st_nlink == 1,
                  temporaryStatus.st_mode & mode_t(0o777)
                    == mode_t(0o600) else {
                throw LedgerError.unsafePath
            }
            try Self.writeAll(data, to: temporary)
            try Self.synchronize(temporary)
            let renameResult = temporaryName.withCString { source in
                name.withCString { destination in
                    Darwin.renameat(
                        directory,
                        source,
                        directory,
                        destination)
                }
            }
            guard renameResult == 0 else { throw Self.posixError() }
            renamed = true
            try Self.synchronize(directory)
            try validateExistingDestination(
                directory: directory,
                requireOwnerOnlyPermissions: true)
        }
    }

    private func withPinnedDirectory<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = directoryURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw LedgerError.unsafePath }
        defer { Darwin.close(directory) }
        guard Darwin.fchmod(directory, S_IRWXU) == 0 else {
            throw Self.posixError()
        }
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = directoryURL.path.withCString {
            Darwin.lstat($0, &pathStatus)
        }
        guard Darwin.fstat(directory, &descriptorStatus) == 0,
              pathResult == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid(),
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_mode & mode_t(0o777)
                == mode_t(0o700) else {
            throw LedgerError.unsafePath
        }
        return try body(directory)
    }

    private func readExistingFile(directory: Int32) throws -> Data? {
        let name = fileURL.lastPathComponent
        var pathStatus = stat()
        let statusResult = name.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            if errno == ENOENT { return nil }
            throw Self.posixError()
        }
        guard Self.validRegularFile(pathStatus) else {
            throw LedgerError.unsafePath
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw LedgerError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              Self.validRegularFile(openedStatus),
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw LedgerError.unsafePath
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            guard count > 0 else { break }
            guard data.count + count <= Self.maximumEncodedBytes else {
                throw LedgerError.oversizedLedger
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func validateExistingDestination(
        directory: Int32,
        requireOwnerOnlyPermissions: Bool = false
    ) throws {
        let name = fileURL.lastPathComponent
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        guard Self.validRegularFile(status),
              !requireOwnerOnlyPermissions
                || status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw LedgerError.unsafePath
        }
    }

    private static func validGrounding(_ grounding: Grounding) -> Bool {
        validDirective(grounding.directive)
            && validNormalizedPoint(grounding.rawNormalizedPoint)
            && grounding.preHostGroundingNormalizedPoint
                == grounding.rawNormalizedPoint
            && grounding.hostGroundingApplied
            && validScreenPoint(grounding.groundedScreenPoint)
            && grounding.effectPosted
    }

    private static func validTaskID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                (48 ... 57).contains(scalar.value)
                    || (65 ... 90).contains(scalar.value)
                    || (97 ... 122).contains(scalar.value)
                    || [45, 46, 95].contains(scalar.value)
            }
    }

    private static func validDirective(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 32
            && value.unicodeScalars.allSatisfy { scalar in
                (97 ... 122).contains(scalar.value)
                    || scalar.value == 45
            }
    }

    private static func validNormalizedPoint(_ point: [Int]) -> Bool {
        point.count == 2 && point.allSatisfy { (0 ... 1_000).contains($0) }
    }

    private static func validScreenPoint(_ point: [Int]) -> Bool {
        point.count == 2
    }

    private static func validRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == Darwin.geteuid()
            && status.st_nlink == 1
            && status.st_size >= 0
            && status.st_size <= maximumEncodedBytes
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                address = address.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
