import Foundation

@MainActor
final class AgentTaskExecutor {
    typealias LoopFactory = @MainActor (String, String) async throws -> AgentLoop

    private struct ActiveTask {
        let taskID: String
        let prompt: String
        let loop: AgentLoop
    }

    private let loopFactory: LoopFactory
    private var active: ActiveTask?
    private var cancellationInProgress = false

    init(loopFactory: @escaping LoopFactory) {
        self.loopFactory = loopFactory
    }

    var activeTaskID: String? { active?.taskID }
    var activePrompt: String? { active?.prompt }
    var activeLoop: AgentLoop? { active?.loop }

    func execute(taskID: String, prompt: String,
                 progress: (@MainActor (AgentLoopResult) -> Void)? = nil,
                 stepProgress: (@MainActor (String) -> Void)? = nil) async throws -> AgentLoopResult {
        guard !taskID.isEmpty, !prompt.isEmpty else { throw AgentTaskExecutorError.invalidTask }
        guard !cancellationInProgress, active?.loop.cancelRequested != true else {
            throw AgentTaskExecutorError.cancellationInProgress
        }
        if let active {
            if active.taskID == taskID {
                guard active.prompt == prompt else { throw AgentTaskExecutorError.promptChanged }
                active.loop.stepProgress = stepProgress
                let result = try await (active.loop.pauseRequested ? active.loop.resume() : active.loop.run())
                progress?(result)
                return result
            }
            guard active.loop.didFinish else { throw AgentTaskExecutorError.taskAlreadyActive(active.taskID) }
            self.active = nil
        }

        let loop = try await loopFactory(taskID, prompt)
        guard loop.taskID == taskID else { throw AgentTaskExecutorError.factoryTaskMismatch }
        loop.stepProgress = stepProgress
        active = ActiveTask(taskID: taskID, prompt: prompt, loop: loop)
        let result = try await (loop.pauseRequested ? loop.resume() : loop.run())
        progress?(result)
        return result
    }

    func resumeApproval(taskID: String, request: AgentApprovalRequest,
                        approved: Bool, stepProgress: (@MainActor (String) -> Void)? = nil) async throws -> AgentLoopResult {
        let loop = try requireActive(taskID: taskID)
        guard request.taskID == taskID,
              loop.pendingStep?.approval == request else {
            throw AgentTaskExecutorError.staleApproval
        }
        loop.stepProgress = stepProgress
        return try await loop.resume(approvalID: request.id, approved: approved)
    }

    func answer(taskID: String, questionID: UUID, answer: String,
                stepProgress: (@MainActor (String) -> Void)? = nil) async throws -> AgentLoopResult {
        let loop = try requireActive(taskID: taskID)
        guard loop.pendingQuestion?.id == questionID else { throw AgentTaskExecutorError.staleQuestion }
        loop.stepProgress = stepProgress
        return try await loop.resume(answer: answer)
    }

    func abandonPendingQuestion(taskID: String, questionID: UUID) async throws {
        let loop = try requireActive(taskID: taskID)
        guard !loop.didFinish, !loop.isRunning, loop.pendingStep == nil,
              loop.pendingQuestion?.id == questionID else {
            throw AgentTaskExecutorError.staleQuestion
        }
        try await cancel()
    }

    func pause() async {
        await active?.loop.pause()
    }

    func requestPause() {
        active?.loop.pauseRequested = true
    }

    func requestCancellation() {
        active?.loop.cancelRequested = true
    }

    func cancel() async throws {
        guard let active else { return }
        guard !cancellationInProgress else {
            throw AgentTaskExecutorError.cancellationInProgress
        }
        cancellationInProgress = true
        active.loop.cancelRequested = true
        do {
            _ = try await active.loop.cancel()
            if self.active?.loop === active.loop { self.active = nil }
            cancellationInProgress = false
        } catch {
            cancellationInProgress = false
            throw error
        }
    }

    private func requireActive(taskID: String) throws -> AgentLoop {
        guard !cancellationInProgress else { throw AgentTaskExecutorError.cancellationInProgress }
        guard let active else { throw AgentTaskExecutorError.noActiveTask }
        guard !active.loop.cancelRequested else { throw AgentTaskExecutorError.cancellationInProgress }
        guard active.taskID == taskID else { throw AgentTaskExecutorError.taskMismatch }
        return active.loop
    }
}

enum AgentTaskExecutorError: Error, Equatable {
    case invalidTask
    case noActiveTask
    case taskMismatch
    case taskAlreadyActive(String)
    case promptChanged
    case staleApproval
    case staleQuestion
    case factoryTaskMismatch
    case cancellationInProgress
}
