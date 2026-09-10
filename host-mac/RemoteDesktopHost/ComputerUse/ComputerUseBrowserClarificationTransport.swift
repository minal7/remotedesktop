import Foundation

/// A request for a fixed host question, not model-authored display text.
/// The host validates it against its actual retained research owner.
struct ComputerUseBrowserQuestionRequest: Equatable, Sendable {
    let taskID: String
    let inputDigest: String
    let topic: ComputerUseBrowserClarificationTopic
    let requirementIDs: [String]
}

@MainActor
protocol ComputerUseBrowserResearchContinuing {
    func continueBrowserResearch(taskID: String, research: ComputerUseBrowserResearchTask,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
}

/// Admission receives only the complete current user request. A nil result
/// is a no-effect decline before retaining an owner; once prepared, that
/// owner must continue through the typed research entry, including on errors.
@MainActor
protocol ComputerUseBrowserResearchExecuting: ComputerUseBrowserResearchContinuing {
    func executeBrowserResearch(taskID: String, prompt: String,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult?
}

/// Maps the existing opaque phone reference to one host-held browser root.
/// The phone never supplies a browser identity or reconstructs the goal.
@MainActor
final class ComputerUseBrowserClarificationTransport {
    enum Failure: Error, Equatable, LocalizedError {
        case invalidReference, invalidOwner, questionPending
        var errorDescription: String? {
            switch self {
            case .invalidReference: return "This browser question no longer matches the current task. Start a new request with the complete instruction."
            case .invalidOwner: return "The original browser task is no longer available. Start a new request with the complete instruction."
            case .questionPending: return "Answer the current browser question before continuing."
            }
        }
    }
    struct Continuation {
        let owner: ComputerUseBrowserResearchTask
        let answerTaskID: String
        let inputDigest: String
        fileprivate init(owner: ComputerUseBrowserResearchTask, answerTaskID: String) {
            self.owner = owner; self.answerTaskID = answerTaskID; inputDigest = owner.input.digest
        }
    }
    struct RejectedAnswer: Error, CustomStringConvertible, CustomDebugStringConvertible {
        let retry: ComputerUseClarificationRetry
        let text: String
        fileprivate init(retry: ComputerUseClarificationRetry, question: String) {
            // Keep a maximum-sized question intact. The typed reason has its
            // own client presentation and must not push this text over its cap.
            self.retry = retry; text = question
        }
        var description: String { "BrowserAnswerRejected(\(retry.reason.rawValue))" }
        var debugDescription: String { description }
    }
    private struct Pending {
        let reference: ComputerUseClarificationReference
        let owner: ComputerUseBrowserResearchTask
        let question: ComputerUseBrowserGoalClarification.Question
        let senderID: String
        let sessionID: String
        func belongs(to envelope: ComputerUseEnvelope) -> Bool {
            senderID == envelope.senderID && sessionID == envelope.sessionID
        }
    }
    private var pending: Pending?

    func issue(_ request: ComputerUseBrowserQuestionRequest, owner: ComputerUseBrowserResearchTask,
               for envelope: ComputerUseEnvelope) throws -> (reference: ComputerUseClarificationReference, text: String) {
        guard pending == nil else { throw Failure.questionPending }
        guard envelope.kind == .prompt, owner.taskID == request.taskID,
              owner.input.digest == request.inputDigest, owner.executionTaskID == envelope.id else { throw Failure.invalidOwner }
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: envelope.senderID, controllerSessionID: envelope.sessionID)
        let reference: ComputerUseClarificationReference
        do { reference = try .init(taskID: envelope.id, expiresAt: question.expiresAt) }
        catch { owner.retire(); throw error }
        pending = Pending(reference: reference, owner: owner, question: question, senderID: envelope.senderID, sessionID: envelope.sessionID)
        return (reference, question.text)
    }

    func matches(_ reference: ComputerUseClarificationReference) -> Bool { pending?.reference == reference }

    /// Derive presentation limits only from the same live native question.
    /// The opaque answer reference is unchanged for older controller versions.
    func answerPolicy(for reference: ComputerUseClarificationReference?, envelope: ComputerUseEnvelope) -> ComputerUseClarificationAnswerPolicy? {
        guard retains(reference, for: envelope), let pending else { return nil }
        return try? ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: pending.owner.input.nextAnswerByteLimit,
            requiresNonblank: true, supportsRetry: true)
    }

    func consume(_ reference: ComputerUseClarificationReference, answer: String, for envelope: ComputerUseEnvelope,
                 retainedOwner: (String) -> ComputerUseBrowserResearchTask?) throws -> Continuation {
        let pending = try validatedAnswerQuestion(reference, envelope: envelope, retainedOwner: retainedOwner)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: pending.owner.input.nextAnswerByteLimit,
            requiresNonblank: true, supportsRetry: true)
        if let reason = policy.rejection(of: answer) {
            throw RejectedAnswer(retry: try .init(reference: reference, reason: reason, answerPolicy: policy), question: pending.question.text)
        }
        _ = try pending.owner.answerQuestion(questionID: pending.question.id, answerTaskID: envelope.id, answer: answer,
            controllerID: envelope.senderID, controllerSessionID: envelope.sessionID)
        self.pending = nil
        return Continuation(owner: pending.owner, answerTaskID: envelope.id)
    }

    private func validatedAnswerQuestion(_ reference: ComputerUseClarificationReference, envelope: ComputerUseEnvelope,
                                        retainedOwner: (String) -> ComputerUseBrowserResearchTask?) throws -> Pending {
        guard envelope.kind == .prompt, let pending, pending.reference == reference, pending.belongs(to: envelope),
              envelope.id != reference.taskID else { throw Failure.invalidReference }
        guard retainedOwner(pending.owner.taskID) === pending.owner,
              pending.owner.input.digest == pending.question.inputDigest,
              pending.owner.executionTaskID == reference.taskID else { throw Failure.invalidOwner }
        guard try pending.owner.pendingQuestion(controllerID: envelope.senderID, controllerSessionID: envelope.sessionID) == pending.question else {
            throw Failure.invalidReference
        }
        return pending
    }

    /// A replay must still match the submitted invalid answer and the exact
    /// live question. A ledger record alone cannot recreate a retired owner.
    func retainsRetry(_ retry: ComputerUseClarificationRetry, for envelope: ComputerUseEnvelope,
                      retainedOwner: (String) -> ComputerUseBrowserResearchTask?) -> Bool {
        guard let pending = try? validatedAnswerQuestion(retry.reference, envelope: envelope, retainedOwner: retainedOwner),
              let submitted = try? ComputerUseExecutionPromptDecoder.decode(envelope.body),
              submitted.supportsClarificationRetry, submitted.clarification == retry.reference,
              retry.answerPolicy.rejection(of: submitted.prompt) == retry.reason,
              retry.answerPolicy.maximumUTF8Bytes == pending.owner.input.nextAnswerByteLimit,
              retry.answerPolicy.requiresNonblank else { return false }
        return true
    }

    /// The caller has durably accepted Cancel for an answer attempt, or a
    /// verified cancellation already preceded that exact submitted answer.
    func invalidateAnswerQuestion(_ reference: ComputerUseClarificationReference, for envelope: ComputerUseEnvelope) {
        guard let pending, pending.reference == reference, pending.belongs(to: envelope),
              envelope.id != reference.taskID, pending.owner.executionTaskID == reference.taskID else { return }
        invalidate()
    }

    /// Only the exact live question can keep its owner through a transport
    /// terminal. A failed/mismatched durable terminal must retire that owner.
    func retains(_ reference: ComputerUseClarificationReference?, for envelope: ComputerUseEnvelope) -> Bool {
        guard let reference, let pending, pending.reference == reference, pending.belongs(to: envelope),
              reference.taskID == envelope.id, pending.owner.executionTaskID == envelope.id,
              pending.owner.input.digest == pending.question.inputDigest else { return false }
        return (try? pending.owner.pendingQuestion(controllerID: envelope.senderID, controllerSessionID: envelope.sessionID)) == pending.question
    }

    /// Delivery additionally requires the same owner in the host registry.
    /// A retained bridge pointer or durable reference alone is insufficient.
    func retainsRegisteredQuestion(_ reference: ComputerUseClarificationReference?, for envelope: ComputerUseEnvelope,
                                   retainedOwner: (String) -> ComputerUseBrowserResearchTask?) -> Bool {
        guard retains(reference, for: envelope), let pending else { return false }
        return retainedOwner(pending.owner.taskID) === pending.owner
    }

    func invalidate(for envelope: ComputerUseEnvelope) {
        guard let pending, pending.reference.taskID == envelope.id, pending.belongs(to: envelope) else { return }
        invalidate()
    }
    func invalidate() { pending?.owner.retire(); pending = nil }
}
