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

    func consume(_ reference: ComputerUseClarificationReference, answer: String, for envelope: ComputerUseEnvelope,
                 retainedOwner: (String) -> ComputerUseBrowserResearchTask?) throws -> Continuation {
        guard envelope.kind == .prompt, let pending, pending.reference == reference, pending.belongs(to: envelope),
              envelope.id != reference.taskID else { throw Failure.invalidReference }
        guard retainedOwner(pending.owner.taskID) === pending.owner,
              pending.owner.input.digest == pending.question.inputDigest,
              pending.owner.executionTaskID == reference.taskID else { throw Failure.invalidOwner }
        _ = try pending.owner.answerQuestion(questionID: pending.question.id, answerTaskID: envelope.id, answer: answer,
            controllerID: envelope.senderID, controllerSessionID: envelope.sessionID)
        self.pending = nil
        return Continuation(owner: pending.owner, answerTaskID: envelope.id)
    }

    /// Only the exact live question can keep its owner through a transport
    /// terminal. A failed/mismatched durable terminal must retire that owner.
    func retains(_ reference: ComputerUseClarificationReference?, for envelope: ComputerUseEnvelope) -> Bool {
        guard let reference, let pending, pending.reference == reference, pending.belongs(to: envelope),
              reference.taskID == envelope.id, pending.owner.executionTaskID == envelope.id,
              pending.owner.input.digest == pending.question.inputDigest else { return false }
        return (try? pending.owner.pendingQuestion(controllerID: envelope.senderID, controllerSessionID: envelope.sessionID)) == pending.question
    }

    func invalidate(for envelope: ComputerUseEnvelope) {
        guard let pending, pending.reference.taskID == envelope.id, pending.belongs(to: envelope) else { return }
        invalidate()
    }
    func invalidate() { pending?.owner.retire(); pending = nil }
}
