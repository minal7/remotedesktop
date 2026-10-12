import Foundation

@MainActor
final class AgentLoop {
    struct PendingStep {
        let resolved: AgentResolvedAction
        let approval: AgentApprovalRequest
    }

    let taskID: String
    let maxSteps: Int
    let environment: AgentEnvironment
    let policy: AgentPolicy
    let gate: AgentActionGate
    let recorder: AgentRecording
    let journal: AgentEffectJournaling

    var taskText: String
    var history: [AgentHistoryItem] = []
    var approvals: [String] = []
    var corrections: [String] = []
    var boundScope: AgentScope?
    var prefetchedFrame: AgentFrame?
    var pendingStep: PendingStep?
    var pendingQuestion: AgentUserQuestion?
    var stepIndex = 0
    var malformedCount = 0
    var isRunning = false
    var pauseRequested = false
    var cancelRequested = false
    var servicesStopped = false
    var didFinish = false
    var terminalResult: AgentLoopResult?
    var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(taskID: String, prompt: String, maxSteps: Int = 40, environment: AgentEnvironment,
         policy: AgentPolicy, gate: AgentActionGate, recorder: AgentRecording,
         journal: AgentEffectJournaling) throws {
        guard !taskID.isEmpty, !prompt.isEmpty, (1...40).contains(maxSteps) else {
            throw AgentLoopError.invalidConfiguration
        }
        self.taskID = taskID; taskText = prompt; self.maxSteps = maxSteps
        self.environment = environment; self.policy = policy; self.gate = gate
        self.recorder = recorder; self.journal = journal
    }

    func run() async throws -> AgentLoopResult {
        if let terminalResult { return terminalResult }
        if let pendingStep { return .pendingApproval(pendingStep.approval) }
        if let pendingQuestion { return .askUser(pendingQuestion) }
        if pauseRequested { return .paused }
        guard !isRunning else { throw AgentLoopError.alreadyRunning }
        isRunning = true
        defer { completeRunCall() }
        return try await withTaskCancellationHandler {
            do { return try await runUntilBoundary() }
            catch is CancellationError {
                if pauseRequested && !cancelRequested { return .paused }
                return try await terminate(reason: "The task was cancelled.", cancelled: true)
            }
            catch let error as AgentLoopInterrupt {
                if error == .paused { return .paused }
                return try await terminate(reason: "The task was cancelled.", cancelled: true)
            } catch let error as AgentLoopError {
                if case .recordingFailed = error {
                    await stopAfterRecordingFailure(error)
                    throw error
                }
                return try await terminate(reason: String(describing: error), cancelled: false)
            } catch {
                return try await terminate(reason: "The agent loop failed: \(error)", cancelled: false)
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.signalCancellation() }
        }
    }

    func resume(approvalID: UUID, approved: Bool) async throws -> AgentLoopResult {
        guard let pending = pendingStep, pending.approval.id == approvalID else { throw AgentLoopError.noMatchingApproval }
        guard !isRunning else { throw AgentLoopError.alreadyRunning }
        isRunning = true
        defer { completeRunCall() }
        do {
            try await activateForContinuation()
            try checkBoundary()
            let context = observationContext()
            let freshFrame = try await environment.observe(context)
            try verifySurfaceKind(freshFrame)
            try bindOrVerifyScope(freshFrame.scope)
            let freshResolved: AgentResolvedAction
            do { freshResolved = try await environment.resolve(pending.resolved.action, in: freshFrame) }
            catch {
                gate.cancelPendingApproval(approvalID)
                let reason = "The approved target is no longer available: \(error)"
                let result = AgentGateResult(decision: .rejected, reason: reason,
                                             fingerprint: pending.approval.fingerprint, scopeIdentity: freshFrame.scope.identity,
                                             riskTier: pending.approval.riskTier.rawValue)
                pendingStep = nil
                try recordContinuation(freshFrame.observation, action: pending.resolved.action, gate: result,
                    execution: .init(status: .notExecuted, result: result.reason))
                corrections.append("Approval invalidated: \(reason)")
                return try await continueAfter()
            }
            let evaluation = try gate.resolveApproval(approvalID, approved: approved, resolved: freshResolved,
                                                      expectedScope: try expectedScope())
            pendingStep = nil
            guard evaluation.result.decision == .allowed else {
                try recordContinuation(freshFrame.observation, action: pending.resolved.action,
                    gate: evaluation.result,
                    execution: .init(status: .notExecuted, result: evaluation.result.reason))
                corrections.append("Approval denied or invalidated: \(evaluation.result.reason)")
                return try await continueAfter()
            }
            guard stepIndex < maxSteps else {
                let reason = "The task reached its \(maxSteps)-step limit before the approved action could run."
                let rejected = AgentGateResult(decision: .rejected, reason: reason,
                    fingerprint: evaluation.result.fingerprint,
                    scopeIdentity: evaluation.result.scopeIdentity,
                    riskTier: evaluation.result.riskTier)
                try recordContinuation(freshFrame.observation, action: pending.resolved.action, gate: rejected,
                    execution: .init(status: .notExecuted, result: reason))
                return try await finish(.failed(reason: reason), outcome: "failed")
            }
            approvals.append(pending.approval.fingerprint)
            let terminal = try await executeAndRecord(freshFrame.observation, "", freshResolved,
                                                      evaluation.result, Date(), allowTransition: true)
            if let terminal { return terminal }
            return try await runUntilBoundary()
        } catch is CancellationError {
            if pauseRequested && !cancelRequested { return .paused }
            return try await terminate(reason: "The task was cancelled.", cancelled: true)
        } catch let error as AgentLoopInterrupt {
            if error == .paused { return .paused }
            return try await terminate(reason: "The task was cancelled.", cancelled: true)
        } catch let error as AgentLoopError {
            if case .recordingFailed = error {
                await stopAfterRecordingFailure(error)
                throw error
            }
            return try await terminate(reason: String(describing: error), cancelled: false)
        } catch {
            return try await terminate(reason: "The agent loop failed: \(error)", cancelled: false)
        }
    }

    func resume(answer: String) async throws -> AgentLoopResult {
        guard let question = pendingQuestion else { throw AgentLoopError.noPendingQuestion }
        guard !isRunning else { throw AgentLoopError.alreadyRunning }
        isRunning = true
        defer { completeRunCall() }
        do { try await activateForContinuation() }
        catch { return try await finish(.failed(reason: "The task could not resume: \(error)"), outcome: "failed") }
        pendingQuestion = nil
        taskText += "\nAccepted clarification: " + answer
        corrections.append(answer)
        history.append(AgentHistoryItem(action: .askUser(question: question.question, choices: question.choices),
                                        result: "User clarification: \(answer)"))
        do { return try await runUntilBoundary() }
        catch is CancellationError {
            if pauseRequested && !cancelRequested { return .paused }
            return try await terminate(reason: "The task was cancelled.", cancelled: true)
        }
        catch let error as AgentLoopError {
            if case .recordingFailed = error {
                await stopAfterRecordingFailure(error)
                throw error
            }
            return try await terminate(reason: String(describing: error), cancelled: false)
        } catch {
            return try await terminate(reason: "The agent loop failed: \(error)", cancelled: false)
        }
    }

    func pause() async {
        guard isRunning else {
            pauseRequested = true
            await environment.suspend()
            await policy.suspend()
            return
        }
        pauseRequested = true
        await environment.suspend()
        await policy.suspend()
        await waitForRunCall()
    }

    func resume() async throws -> AgentLoopResult {
        guard pauseRequested, !cancelRequested, pendingStep == nil, pendingQuestion == nil else { return try await run() }
        do { try await activateForContinuation() }
        catch {
            return try await finish(.failed(reason: "The task could not resume: \(error)"), outcome: "failed")
        }
        return try await run()
    }

    func activateForContinuation() async throws {
        guard pauseRequested else { return }
        try await environment.resume()
        try await policy.resume()
        pauseRequested = false
    }

    func cancel() async throws -> AgentLoopResult {
        guard !didFinish else { return terminalResult ?? .cancelled }
        cancelRequested = true
        await stopServices()
        await waitForRunCall()
        if didFinish { return terminalResult ?? .cancelled }
        return try await terminate(reason: "The task was cancelled.", cancelled: true)
    }

    func runUntilBoundary() async throws -> AgentLoopResult {
        try checkBoundary()
        do { try journal.assertMayContinue() }
        catch { throw AgentLoopError.journalFailed("The effect journal blocked continuation: \(error)") }
        while stepIndex < maxSteps {
            try checkBoundary()
            let startedAt = Date()
            let observationStart = Date()
            let frame = try await nextFrame()
            if let result = try await processFrame(frame, startedAt: startedAt,
                                                   observationMS: milliseconds(since: observationStart)) {
                return result
            }
        }
        return try await terminate(reason: "The task reached its \(maxSteps)-step limit.", cancelled: false)
    }

    func executeAndRecord(_ observation: AgentObservation, _ raw: String, _ resolved: AgentResolvedAction,
                          _ gateResult: AgentGateResult, _ startedAt: Date,
                          observationMS: Int = 0, policyMS: Int = 0, gateMS: Int = 0,
                          allowTransition: Bool = false) async throws -> AgentLoopResult? {
        if let terminal = try await recordControlAction(observation, raw, resolved.action, gateResult, startedAt,
                                                        observationMS, policyMS, gateMS) { return terminal }
        return try await executeEffect(observation, raw, resolved, gateResult, startedAt,
                                       observationMS, policyMS, gateMS, allowTransition)
    }


}

enum AgentLoopInterrupt: Error, Equatable { case paused }
