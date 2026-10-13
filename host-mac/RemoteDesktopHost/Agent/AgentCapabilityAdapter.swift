import CryptoKit
import Foundation

/// Presents the general agent through the existing host task and clarification
/// APIs while retaining the loop's original task identity across answer tasks.
@MainActor
final class AgentCapabilityAdapter: ComputerUseTaskAwareExecuting, ComputerUseClarificationContinuing {
    private struct PendingQuestion {
        let rootTaskID: String
        var hostTaskID: String
        var goal: ComputerUseUnresolvedTextGoal
        let question: AgentUserQuestion
        let choicesByID: [String: String]
    }

    private let executor: AgentTaskExecutor
    private var rootTaskID: String?
    private var hostTaskID: String?
    private var goal: ComputerUseUnresolvedTextGoal?
    private var pendingQuestion: PendingQuestion?

    init(executor: AgentTaskExecutor) {
        self.executor = executor
    }

    let isReady = true
    let requiresMacControlHelper = false
    let hasAdditionalSetup = false
    let runtimeName = "General Agent"
    let readyDetail = "General agent is ready"
    var hasRetainedTask: Bool { executor.activeLoop.map { !$0.didFinish } ?? false }

#if DEBUG
    func debugPendingApproval(taskID: String, requestID: UUID) -> AgentLoop.PendingStep? {
        guard hostTaskID == taskID, let rootTaskID,
              executor.activeTaskID == rootTaskID,
              let pending = executor.activeLoop?.pendingStep,
              pending.approval.id == requestID,
              pending.approval.taskID == rootTaskID else { return nil }
        return pending
    }
#endif

    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        let taskID = UUID().uuidString
        return try await execute(taskID: taskID, prompt: prompt, trustedUserPrompt: prompt,
                                 tools: tools, progress: progress)
    }

    func execute(taskID: String, prompt: String, trustedUserPrompt: String,
                 tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await executeAgentTask(taskID: taskID, currentUserPrompt: trustedUserPrompt, progress: progress)
    }

    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await executeAgentTask(taskID: taskID, currentUserPrompt: currentUserPrompt, progress: progress)
    }

    private func executeAgentTask(taskID: String, currentUserPrompt: String,
                                  progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        let executionTaskID: String
        let executionPrompt: String
        if rootTaskID != taskID && hostTaskID != taskID {
            guard executor.activeTaskID == nil || executor.activeLoop?.didFinish == true else {
                throw AgentTaskExecutorError.taskAlreadyActive(executor.activeTaskID ?? "")
            }
            rootTaskID = taskID
            hostTaskID = taskID
            goal = try ComputerUseUnresolvedTextGoal(userRequest: currentUserPrompt)
            pendingQuestion = nil
            executionTaskID = taskID
            executionPrompt = currentUserPrompt
        } else {
            guard let rootTaskID, let hostTaskID, hostTaskID == taskID,
                  executor.activeTaskID == rootTaskID,
                  let activePrompt = executor.activePrompt else { throw AdapterError.taskAliasMismatch }
            executionTaskID = rootTaskID
            executionPrompt = activePrompt
            if rootTaskID == taskID {
                guard activePrompt == currentUserPrompt,
                      goal?.userTurns.first == currentUserPrompt else { throw AdapterError.goalMismatch }
            }
        }

        let result = try await executor.execute(taskID: executionTaskID, prompt: executionPrompt) { update in
            progress(Self.progressText(for: update))
        }
        return present(result, rootTaskID: executionTaskID, hostTaskID: taskID)
    }

    func clarification(taskID: String) throws -> ComputerUseClarificationQuestion? {
        guard let pending = pendingQuestion, pending.hostTaskID == taskID else { return nil }
        let choices = try pending.question.choices.map { labels in
            try labels.enumerated().map { index, label in
                try ComputerUseClarificationChoice(
                    id: Self.choiceID(questionID: pending.question.id, index: index), label: label)
            }
        }
        try ComputerUseClarificationChoice.validate(choices)
        return ComputerUseClarificationQuestion(
            taskID: taskID,
            goal: pending.goal,
            question: pending.question.question,
            scope: Self.scope(questionID: pending.question.id),
            expiresAt: Date().addingTimeInterval(600),
            choices: choices)
    }

    func continueClarification(taskID: String, originatingTaskID: String,
                               goal suppliedGoal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                                        goal: suppliedGoal, selectedChoice: nil, progress: progress)
    }

    func continueClarification(taskID: String, originatingTaskID: String,
                               goal suppliedGoal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard let pending = pendingQuestion,
              pending.rootTaskID == rootTaskID,
              pending.hostTaskID == originatingTaskID,
              hostTaskID == originatingTaskID,
              let rootTaskID = rootTaskID,
              let executorTaskID = executor.activeTaskID,
              executorTaskID == rootTaskID else { throw AdapterError.invalidClarification }

        let answer: String
        let nextGoal: ComputerUseUnresolvedTextGoal
        if let selectedChoice {
            guard let retainedChoice = pending.choicesByID[selectedChoice.id],
                  retainedChoice == selectedChoice.label,
                  selectedChoice.detail == nil,
                  suppliedGoal == pending.goal else { throw AdapterError.invalidClarification }
            answer = retainedChoice
            nextGoal = pending.goal
        } else {
            guard Self.isAnswering(suppliedGoal, retained: pending.goal, question: pending.question.question),
                  let latestAnswer = suppliedGoal.userTurns.last else { throw AdapterError.invalidClarification }
            answer = latestAnswer
            nextGoal = suppliedGoal
        }

        let result = try await executor.answer(taskID: rootTaskID, questionID: pending.question.id, answer: answer)
        pendingQuestion = nil
        hostTaskID = taskID
        goal = nextGoal
        return present(result, rootTaskID: rootTaskID, hostTaskID: taskID)
    }

    func invalidateClarification(taskID: String?) {
        guard taskID == nil || pendingQuestion?.hostTaskID == taskID else { return }
        pendingQuestion = nil
    }

    func ownsApproval(_ request: AgentApprovalRequest, hostTaskID: String) -> Bool {
        request.taskID == rootTaskID && hostTaskID == self.hostTaskID
            && executor.activeTaskID == request.taskID
            && executor.activeLoop?.pendingStep?.approval.id == request.id
    }

    func resumeApproval(request: AgentApprovalRequest, approved: Bool) async -> ComputerUseExecutionResult {
        guard request.taskID == rootTaskID, let hostTaskID,
              executor.activeTaskID == request.taskID else {
            return .unableToComplete("This approval is no longer attached to an active agent task.")
        }
        do {
            let result = try await executor.resumeApproval(taskID: request.taskID, request: request, approved: approved)
            return present(result, rootTaskID: request.taskID, hostTaskID: hostTaskID)
        } catch {
            return .unableToComplete("The agent could not resume this approval: \(error.localizedDescription)")
        }
    }

    func pauseAgent() async {
        await executor.pause()
    }

    func requestPause() { executor.requestPause() }
    func requestCancellation() { executor.requestCancellation() }

    func cancelAgent() async {
        do {
            try await executor.cancel()
            pendingQuestion = nil
            rootTaskID = nil
            hostTaskID = nil
            goal = nil
        } catch {
            // Keep the retained task binding if cancellation did not complete.
        }
    }

    private func present(_ result: AgentLoopResult, rootTaskID: String,
                         hostTaskID: String) -> ComputerUseExecutionResult {
        switch result {
        case .completed(let answer):
            pendingQuestion = nil
            return .completed(answer)
        case .failed(let reason):
            pendingQuestion = nil
            return .unableToComplete(reason)
        case .pendingApproval(let request):
            return .agentApprovalRequired(request)
        case .askUser(let question):
            guard let goal else { return .unableToComplete("The agent question has no retained task context.") }
            let pairs = (question.choices ?? []).enumerated().map { index, label in
                let id = Self.choiceID(questionID: question.id, index: index)
                return (id, label)
            }
            pendingQuestion = PendingQuestion(rootTaskID: rootTaskID, hostTaskID: hostTaskID,
                                              goal: goal, question: question,
                                              choicesByID: Dictionary(uniqueKeysWithValues: pairs))
            return .clarificationRequired(question.question)
        case .handoff(let reason):
            return .userInterventionRequired(reason)
        case .paused:
            return .userInterventionRequired("The agent task is paused. Choose Resume to continue.")
        case .cancelled:
            pendingQuestion = nil
            return .unableToComplete("The agent task was cancelled.")
        }
    }

    private static func isAnswering(_ candidate: ComputerUseUnresolvedTextGoal,
                                    retained: ComputerUseUnresolvedTextGoal,
                                    question: String) -> Bool {
        guard let answer = candidate.userTurns.last,
              let expected = try? retained.answering(question, with: answer) else { return false }
        return expected == candidate
    }

    private static func choiceID(questionID: UUID, index: Int) -> String {
        "agent-choice-\(questionID.uuidString.lowercased())-\(index)"
    }

    private static func scope(questionID: UUID) -> String {
        let digest = SHA256.hash(data: Data(questionID.uuidString.lowercased().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func progressText(for result: AgentLoopResult) -> String {
        switch result {
        case .completed(let answer): return answer
        case .failed(let reason), .handoff(let reason): return reason
        case .pendingApproval(let request): return request.reason
        case .askUser(let question): return question.question
        case .paused: return "The agent task is paused."
        case .cancelled: return "The agent task was cancelled."
        }
    }

    enum AdapterError: Error, Equatable {
        case taskAliasMismatch, goalMismatch, invalidClarification
    }
}
