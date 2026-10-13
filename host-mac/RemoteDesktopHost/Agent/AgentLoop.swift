import Foundation

@MainActor
final class AgentLoop {
    struct PendingStep { let resolved: AgentResolvedAction; let approval: AgentApprovalRequest }
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
    var expectedTransition: AgentAction?
    var pendingStep: PendingStep?
    var pendingQuestion: AgentUserQuestion?
    var stepIndex = 0
    var rejectionStreak = 0
    var isRunning = false
    var pauseRequested = false
    var cancelRequested = false
    var servicesStopped = false
    var didFinish = false
    var footerAttempted = false
    var terminalResult: AgentLoopResult?
    var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(taskID: String, prompt: String, maxSteps: Int = 30, environment: AgentEnvironment,
         policy: AgentPolicy, gate: AgentActionGate, recorder: AgentRecording,
         journal: AgentEffectJournaling) throws {
        guard !taskID.isEmpty, !prompt.isEmpty, (1...40).contains(maxSteps) else {
            throw AgentLoopError.invalidConfiguration
        }
        self.taskID = taskID; taskText = prompt; self.maxSteps = min(maxSteps, 30)
        self.environment = environment; self.policy = policy; self.gate = gate
        self.recorder = recorder; self.journal = journal
    }

    func run() async throws -> AgentLoopResult {
        if let terminalResult { return terminalResult }
        if let pendingStep { return .pendingApproval(pendingStep.approval) }
        if let pendingQuestion { return .askUser(pendingQuestion) }
        return try await guarded { try await runSteps() }
    }

    func resume(approvalID: UUID, approved: Bool) async throws -> AgentLoopResult {
        guard let pending = pendingStep, pending.approval.id == approvalID else { throw AgentLoopError.noMatchingApproval }
        return try await guarded { try await continueApproval(pending, approved: approved) }
    }

    func resume(answer: String) async throws -> AgentLoopResult {
        guard let question = pendingQuestion else { throw AgentLoopError.noPendingQuestion }
        return try await guarded {
            try await activate(); pendingQuestion = nil
            taskText += "\nAccepted clarification: " + answer; corrections.append(answer)
            history.append(.init(action: .askUser(question: question.question, choices: question.choices),
                                 result: "User clarification: \(answer)"))
            return try await runSteps()
        }
    }

    private func guarded(_ body: () async throws -> AgentLoopResult) async throws -> AgentLoopResult {
        guard !isRunning else { throw AgentLoopError.alreadyRunning }
        isRunning = true; defer { completeRunCall() }
        return try await withTaskCancellationHandler {
            do { return try await body() }
            catch is CancellationError {
                if pauseRequested && !cancelRequested { return .paused }
                return try await finish(.cancelled, outcome: "cancelled")
            } catch LoopPause.requested { return .paused }
            catch LoopBoundary.handoff(let reason) { return .handoff(reason: reason) }
            catch let error as AgentEnvironmentError {
                if case .systemHandoff(let reason) = error { return .handoff(reason: reason) }
                if error == .credentialHandoff { return .handoff(reason: "Credential entry requires the owner.") }
                return try await finish(.failed(reason: String(describing: error)), outcome: "failed")
            } catch let error as AgentLoopError {
                if case .recordingFailed = error { await stopAfterRecordingFailure(error); throw error }
                return try await finish(.failed(reason: String(describing: error)), outcome: "failed")
            } catch { return try await finish(.failed(reason: String(describing: error)), outcome: "failed") }
        } onCancel: { Task { @MainActor [weak self] in await self?.signalCancellation() } }
    }

    private func continueApproval(_ pending: PendingStep, approved: Bool) async throws -> AgentLoopResult {
        let continuationStart = Date()
        if !approved {
            gate.cancelPendingApproval(pending.approval.id); pendingStep = nil
            let denied = AgentGateResult(decision: .rejected, reason: "rejected: user declined",
                fingerprint: pending.approval.fingerprint, scopeIdentity: pending.approval.scopeIdentity,
                riskTier: pending.approval.riskTier.rawValue)
            try record(pending.resolved.frame.observation, raw: "", action: pending.resolved.action,
                       gate: denied, execution: .init(status: .notExecuted, result: denied.reason),
                       start: continuationStart)
            corrections.append("Approval declined by the owner.")
            history.append(.init(action: pending.resolved.action, result: "rejected: user declined"))
            stepIndex += 1; rejectionStreak += 1
            if let question = askAfterRejections() { return question }
            return try await runSteps()
        }
        try await activate(); try checkBoundary()
        let frame = try await freshFrame(transition: pending.resolved.action)
        let rebound: AgentResolvedAction
        do { rebound = try await environment.rebind(pending.resolved, in: frame) }
        catch {
            gate.cancelPendingApproval(pending.approval.id); pendingStep = nil
            try record(frame.observation, raw: "", action: pending.resolved.action,
                       gate: rejected("Approval target changed: \(error)", scope: frame.scope),
                       execution: .init(status: .notExecuted, result: String(describing: error)),
                       start: continuationStart)
            history.append(.init(action: pending.resolved.action, result: "rejected: approval target changed"))
            stepIndex += 1; rejectionStreak += 1
            if let question = askAfterRejections() { return question }
            return try await runSteps()
        }
        let decision = try gate.resolveApproval(pending.approval.id, approved: approved,
                                                resolved: rebound, expectedScope: try expectedScope())
        pendingStep = nil
        guard decision.result.decision == .allowed else {
            try record(frame.observation, raw: "", action: pending.resolved.action, gate: decision.result,
                       execution: .init(status: .notExecuted, result: decision.result.reason),
                       start: continuationStart)
            corrections.append("Approval denied or invalidated: \(decision.result.reason)")
            let rejection = approved ? "rejected: \(decision.result.reason)" : "rejected: user declined"
            history.append(.init(action: pending.resolved.action, result: rejection))
            stepIndex += 1; rejectionStreak += 1
            if let question = askAfterRejections() { return question }
            return try await runSteps()
        }
        guard stepIndex < maxSteps else {
            let reason = "The task reached its \(maxSteps)-step limit before the approved action could run."
            let rejected = AgentGateResult(decision: .rejected, reason: reason,
                fingerprint: decision.result.fingerprint, scopeIdentity: decision.result.scopeIdentity,
                riskTier: decision.result.riskTier)
            try record(frame.observation, raw: "", action: pending.resolved.action, gate: rejected,
                       execution: .init(status: .notExecuted, result: reason),
                       start: continuationStart)
            return try await finish(.failed(reason: reason), outcome: "failed")
        }
        approvals.append(pending.approval.fingerprint)
        if let terminal = try await execute(frame.observation, "", rebound, decision.result, continuationStart) { return terminal }
        return try await runSteps()
    }

    func pause() async {
        pauseRequested = true; await environment.suspend(); await policy.suspend()
        await waitForRunCall()
    }

    func resume() async throws -> AgentLoopResult { try await run() }

    func cancel() async throws -> AgentLoopResult {
        guard !didFinish else { return terminalResult ?? .cancelled }
        cancelRequested = true; await stopServices(); await waitForRunCall()
        if didFinish { return terminalResult ?? .cancelled }
        return try await finish(.cancelled, outcome: "cancelled")
    }

    private func runSteps() async throws -> AgentLoopResult {
        try await activate()
        do { try journal.assertMayContinue() }
        catch { throw AgentLoopError.journalFailed("The effect journal blocked continuation: \(error)") }
        while stepIndex < maxSteps {
            try checkBoundary()
            let start = Date(), observeStart = Date()
            let frame = try await freshFrame()
            let observeMS = ms(observeStart)
            let policyStart = Date()
            let output: AgentPolicyOutput
            do { output = try await policy.propose(frame.observation) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if let result = try recordRejection(frame, raw: "", action: nil, reason: "Policy error: \(error)",
                    start: start, observeMS: observeMS, policyMS: ms(policyStart)) { return result }
                continue
            }
            let policyMS = ms(policyStart)
            try checkBoundary()
            guard let proposedAction = output.action else {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: nil,
                    reason: output.rejectionReason ?? "Malformed action output.", start: start,
                    observeMS: observeMS, policyMS: policyMS) { return result }
                continue
            }
            let resolved: AgentResolvedAction
            do {
                switch proposedAction {
                case .done, .fail, .askUser: resolved = AgentResolvedAction(action: proposedAction, frame: frame, targets: [])
                default: resolved = try await environment.resolve(proposedAction, in: frame)
                }
            }
            catch let error as AgentEnvironmentError {
                if case .systemHandoff(let reason) = error { return .handoff(reason: reason) }
                if error == .credentialHandoff {
                    try recordRejection(frame, raw: output.rawOutput, action: proposedAction,
                        reason: "Credential entry requires the owner.", start: start,
                        observeMS: observeMS, policyMS: policyMS)
                    return .handoff(reason: "Credential entry requires the owner.")
                }
                if let result = try recordRejection(frame, raw: output.rawOutput, action: proposedAction,
                    reason: "Target resolution rejected: \(error)", start: start,
                    observeMS: observeMS, policyMS: policyMS) { return result }
                continue
            }
            catch {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: proposedAction,
                    reason: "Target resolution rejected: \(error)", start: start,
                    observeMS: observeMS, policyMS: policyMS) { return result }
                continue
            }
            let action = resolved.action
            let gateStart = Date()
            let evaluation: AgentGateEvaluation
            do { evaluation = try gate.evaluate(resolved, expectedScope: try expectedScope()) }
            catch {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: action,
                    reason: "Gate rejected action: \(error)", start: start,
                    observeMS: observeMS, policyMS: policyMS, gateMS: ms(gateStart)) { return result }
                continue
            }
            let gateMS = ms(gateStart)
            if let approval = evaluation.approval {
                pendingStep = PendingStep(resolved: resolved, approval: approval)
                try record(frame.observation, raw: output.rawOutput, action: action, gate: evaluation.result,
                           execution: .init(status: .notExecuted, result: evaluation.result.reason),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
                history.append(.init(action: action, result: "needs approval: \(evaluation.result.reason)")); stepIndex += 1
                return .pendingApproval(approval)
            }
            guard evaluation.result.decision == .allowed else {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: action,
                    reason: evaluation.result.reason, start: start, observeMS: observeMS,
                    policyMS: policyMS, gateMS: gateMS, result: evaluation.result) { return result }
                if evaluation.result.reason.localizedCaseInsensitiveContains("credential") {
                    return .handoff(reason: evaluation.result.reason)
                }
                continue
            }
            rejectionStreak = 0
            if let result = try await control(frame, output, evaluation.result, start, observeMS,
                                              policyMS, gateMS) { return result }
            if let terminal = try await execute(frame.observation, output.rawOutput, resolved,
                evaluation.result, start, observeMS, policyMS, gateMS) { return terminal }
        }
        return try await finish(.failed(reason: "The task reached its \(maxSteps)-step limit."), outcome: "failed")
    }

    private func execute(_ observation: AgentObservation, _ raw: String, _ resolved: AgentResolvedAction,
                         _ gate: AgentGateResult, _ start: Date, _ observeMS: Int = 0,
                         _ policyMS: Int = 0, _ gateMS: Int = 0) async throws -> AgentLoopResult? {
        let action = resolved.action, begins = isInput(action), executionStart = Date()
        let fingerprint = gate.fingerprint ?? ""
        if begins {
            guard !fingerprint.isEmpty else { throw AgentLoopError.journalFailed("Allowed action has no fingerprint.") }
            do { try journal.assertMayContinue(); try journal.begin(step: stepIndex, fingerprint: fingerprint) }
            catch { throw AgentLoopError.journalFailed("Could not begin action: \(error)") }
        }
        let result: AgentExecutionResult
        do { try checkBoundary(); result = try await environment.execute(resolved); try checkBoundary() }
        catch let error as AgentEnvironmentError {
            if case .systemHandoff(let reason) = error {
                if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .error, result: "Owner handoff: \(reason)"),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                stepIndex += 1; throw LoopBoundary.handoff(reason)
            }
            if error == .credentialHandoff {
                if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .notExecuted, result: "Credential entry requires the owner."),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                history.append(.init(action: action, result: "Credential entry requires the owner."))
                stepIndex += 1
                throw LoopBoundary.handoff("Credential entry requires the owner.")
            }
            return try await recoverAttempt(error, observation, raw, action, gate, start,
                                            observeMS, policyMS, gateMS, executionStart, fingerprint, begins)
        } catch {
            if error is CancellationError || error is LoopPause || cancelRequested || Task.isCancelled {
                if begins { try journal.markUncertain(step: stepIndex, fingerprint: fingerprint) }
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .error, result: "Interrupted input attempt: \(error)"),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                stepIndex += 1
                return try await finish(.failed(reason: "An interrupted input attempt may have taken effect."), outcome: "uncertain")
            }
            if begins && gate.riskTier == AgentRiskTier.high.rawValue {
                try journal.markUncertain(step: stepIndex, fingerprint: fingerprint)
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .error, result: "Uncertain input attempt: \(error)"),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                history.append(.init(action: action, result: "uncertain: \(error)")); stepIndex += 1
                return try await finish(.failed(reason: "High-risk action outcome is uncertain."), outcome: "uncertain")
            }
            if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
            try record(observation, raw: raw, action: action, gate: gate,
                       execution: .init(status: .error, result: "Attempted; environment error: \(error)"),
                       start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                       executionMS: ms(executionStart))
            history.append(.init(action: action, result: "Attempted; environment error: \(error)")); stepIndex += 1
            return nil
        }
        if result.status != .ok && begins && gate.riskTier == AgentRiskTier.high.rawValue {
            try journal.markUncertain(step: stepIndex, fingerprint: fingerprint)
            try record(observation, raw: raw, action: action, gate: gate, execution: result,
                       start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                       executionMS: ms(executionStart))
            history.append(.init(action: action, result: "Uncertain: \(result.result)")); stepIndex += 1
            return try await finish(.failed(reason: "High-risk action outcome is uncertain."), outcome: "uncertain")
        }
        if begins {
            if environment.followsFrontmostSurface { try await Task.sleep(for: .milliseconds(300)) }
            try journal.verify(step: stepIndex, fingerprint: fingerprint)
        }
        if result.status == .ok, case .openURL = action { expectedTransition = action }
        if result.status == .ok, case .openApp = action { expectedTransition = action }
        try record(observation, raw: raw, action: action, gate: gate, execution: result,
                   start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                   executionMS: ms(executionStart))
        history.append(.init(action: action, result: result.status == .ok ? "ok: \(result.result)" : "Attempted: \(result.result)"))
        stepIndex += 1
        return nil
    }

    private func control(_ frame: AgentFrame, _ output: AgentPolicyOutput, _ gate: AgentGateResult,
                         _ start: Date, _ observeMS: Int, _ policyMS: Int, _ gateMS: Int) async throws -> AgentLoopResult? {
        guard let action = output.action else { return nil }
        switch action {
        case .done(let answer):
            try record(frame.observation, raw: output.rawOutput, action: action, gate: gate,
                       execution: .init(status: .ok, result: answer), start: start,
                       observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
            stepIndex += 1; return try await finish(.completed(answer: answer), outcome: "success")
        case .fail(let reason):
            try record(frame.observation, raw: output.rawOutput, action: action, gate: gate,
                       execution: .init(status: .error, result: reason), start: start,
                       observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
            stepIndex += 1; return try await finish(.failed(reason: reason), outcome: "failed")
        case .askUser(let question, let choices):
            let pending = AgentUserQuestion(id: UUID(), question: question, choices: choices)
            try record(frame.observation, raw: output.rawOutput, action: action, gate: gate,
                       execution: .init(status: .notExecuted, result: "Waiting for the user."), start: start,
                       observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
            stepIndex += 1; pendingQuestion = pending; return .askUser(pending)
        default: return nil
        }
    }

    private func recoverAttempt(_ error: Error, _ observation: AgentObservation, _ raw: String,
                                _ action: AgentAction, _ gate: AgentGateResult, _ start: Date,
                                _ observeMS: Int, _ policyMS: Int, _ gateMS: Int, _ executionStart: Date,
                                _ fingerprint: String, _ begins: Bool) async throws -> AgentLoopResult? {
        if begins && gate.riskTier == AgentRiskTier.high.rawValue {
            try journal.markUncertain(step: stepIndex, fingerprint: fingerprint)
            try record(observation, raw: raw, action: action, gate: gate,
                       execution: .init(status: .error, result: "Uncertain input attempt: \(error)"),
                       start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                       executionMS: ms(executionStart))
            history.append(.init(action: action, result: "uncertain: \(error)")); stepIndex += 1
            return try await finish(.failed(reason: "High-risk action outcome is uncertain."), outcome: "uncertain")
        }
        if begins && environment.followsFrontmostSurface { try await Task.sleep(for: .milliseconds(300)) }
        if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
        try record(observation, raw: raw, action: action, gate: gate,
                   execution: .init(status: .error, result: "Attempted; environment error: \(error)"),
                   start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                   executionMS: ms(executionStart))
        history.append(.init(action: action, result: "Attempted; environment error: \(error)")); stepIndex += 1
        return nil
    }

    private func recordRejection(_ frame: AgentFrame, raw: String, action: AgentAction?, reason: String,
                                 start: Date, observeMS: Int, policyMS: Int, gateMS: Int = 0,
                                 result: AgentGateResult? = nil) throws -> AgentLoopResult? {
        let decision = result ?? AgentGateResult(decision: .rejected, reason: reason,
            scopeIdentity: frame.scope.identity, riskTier: AgentRiskTier.low.rawValue)
        try record(frame.observation, raw: raw, action: action, gate: decision,
                   execution: .init(status: .notExecuted, result: reason), start: start,
                   observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
        history.append(.init(action: action, result: "rejected: \(reason)")); stepIndex += 1
        rejectionStreak += 1; corrections.append(reason)
        return askAfterRejections()
    }

    private func askAfterRejections() -> AgentLoopResult? {
        guard rejectionStreak >= 3 else { return nil }
        let question = AgentUserQuestion(id: UUID(), question: "The last three actions could not be safely completed. How should I proceed?", choices: nil)
        pendingQuestion = question
        return .askUser(question)
    }

    private func freshFrame(transition: AgentAction? = nil) async throws -> AgentFrame {
        let context = AgentObservationContext(task: taskText, history: history,
            budget: .init(step: stepIndex, maxSteps: maxSteps))
        let frame = try await environment.observe(context)
        let matches: Bool
        switch (frame.scope.kind, frame.observation.surface) {
        case (.web, .web), (.app, .app): matches = true
        default: matches = false
        }
        guard matches, frame.scope.taskID == taskID else { throw AgentEnvironmentError.scopeChanged }
        if environment.followsFrontmostSurface { boundScope = frame.scope }
        else if let boundScope, boundScope != frame.scope {
            guard let transition = transition ?? expectedTransition,
                  gate.matchesOpenedSurface(action: transition, from: boundScope,
                                                             observation: frame.observation) else {
                throw AgentEnvironmentError.scopeChanged
            }
            self.boundScope = frame.scope; expectedTransition = nil
        }
        else { boundScope = frame.scope }
        return frame
    }

    private func expectedScope() throws -> AgentScope {
        guard let boundScope else { throw AgentLoopError.invalidConfiguration }; return boundScope
    }

    private func checkBoundary() throws {
        if cancelRequested || Task.isCancelled { throw CancellationError() }
        if pauseRequested { throw LoopPause.requested }
    }

    private func activate() async throws {
        guard pauseRequested else { return }
        try await environment.resume(); try await policy.resume(); pauseRequested = false
    }

    private func isInput(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .type, .key, .scroll, .select, .drag, .openURL, .openApp, .setFiles: true
        default: false
        }
    }

    private func rejected(_ reason: String, scope: AgentScope) -> AgentGateResult {
        .init(decision: .rejected, reason: reason, scopeIdentity: scope.identity, riskTier: AgentRiskTier.medium.rawValue)
    }

    private func record(_ observation: AgentObservation, raw: String, action: AgentAction?, gate: AgentGateResult,
                        execution: AgentExecutionResult, start: Date, observeMS: Int = 0,
                        policyMS: Int = 0, gateMS: Int = 0, executionMS: Int = 0) throws {
        let step = AgentEpisodeStep(episodeID: taskID, step: stepIndex, observation: observation,
            promptVersion: policy.promptVersion, rawModelOutput: raw, action: action, gate: gate,
            execution: execution, timings: .init(observationMS: observeMS, policyMS: policyMS,
                gateMS: gateMS, executionMS: executionMS, recordMS: 0, totalMS: ms(start)))
        do { try recorder.record(step) }
        catch {
            let failure = AgentLoopError.recordingFailed("Could not durably record step \(stepIndex): \(error)")
            if let pendingStep { gateCancel(pendingStep.approval.id) }; pendingStep = nil
            terminalResult = .failed(reason: String(describing: failure))
            throw failure
        }
    }

    private func finish(_ result: AgentLoopResult, outcome: String) async throws -> AgentLoopResult {
        guard !didFinish else { return terminalResult ?? result }
        if let pendingStep { gateCancel(pendingStep.approval.id) }
        pendingStep = nil; pendingQuestion = nil
        footerAttempted = true
        do { try recorder.finish(.init(episodeID: taskID, outcome: outcome, approvals: approvals, corrections: corrections)) }
        catch { terminalResult = .failed(reason: "Could not durably finish episode: \(error)"); await stopServices(); didFinish = true; throw AgentLoopError.recordingFailed(String(describing: error)) }
        await stopServices(); didFinish = true; terminalResult = result; return result
    }

    private func gateCancel(_ id: UUID) { gate.cancelPendingApproval(id) }
    private func stopServices() async {
        guard !servicesStopped else { return }; servicesStopped = true
        await environment.stop(); await policy.stop()
    }
    private func stopAfterRecordingFailure(_ error: AgentLoopError) async {
        if !footerAttempted {
            footerAttempted = true
            try? recorder.finish(.init(episodeID: taskID, outcome: "failed", approvals: approvals, corrections: corrections))
        }
        await stopServices(); terminalResult = terminalResult ?? .failed(reason: String(describing: error)); didFinish = true
    }
    private func signalCancellation() async { cancelRequested = true; await stopServices() }
    private func completeRunCall() {
        isRunning = false; let waiters = completionWaiters; completionWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
    private func waitForRunCall() async {
        guard isRunning else { return }; await withCheckedContinuation { completionWaiters.append($0) }
    }
    private func ms(_ start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1_000)) }
}

private enum LoopPause: Error { case requested }
private enum LoopBoundary: Error { case handoff(String) }
