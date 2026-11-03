import Foundation

enum AgentPolicyTermination: Error {
    case authorizationRevoked
}

@MainActor
final class AgentLoop {
    struct PendingStep { let resolved: AgentResolvedAction; let approval: AgentApprovalRequest; let note: String? }
    let taskID: String
    let maxSteps: Int
    private let directOpenName: String?
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
    var stepProgress: (@MainActor (String) -> Void)?
    private var progressNeedsSafeFallback = false
    private var deniedApprovalFingerprints: Set<String> = []
    private var taskDeclineCount = 0
    private let taskTimeLimit: Duration
    private var taskDeadline: ContinuousClock.Instant?
    private var deadlineWatchdog: Task<Void, Never>?
    private var deadlineExpired = false
    private var inFlightInput: (step: Int, fingerprint: String)?
    private let timeoutReason = "Couldn't finish within five minutes. Try a shorter task or take over."

    init(taskID: String, prompt: String, maxSteps: Int = 25, directOpenName: String? = nil, environment: AgentEnvironment,
         policy: AgentPolicy, gate: AgentActionGate, recorder: AgentRecording,
         journal: AgentEffectJournaling, taskTimeLimit: Duration = .seconds(300)) throws {
        guard !taskID.isEmpty, !prompt.isEmpty, (1...40).contains(maxSteps),
              taskTimeLimit > .zero, taskTimeLimit <= .seconds(300) else {
            throw AgentLoopError.invalidConfiguration
        }
        self.taskID = taskID; taskText = prompt; self.maxSteps = min(maxSteps, 25); self.directOpenName = directOpenName
        self.environment = environment; self.policy = policy; self.gate = gate
        self.recorder = recorder; self.journal = journal; self.taskTimeLimit = taskTimeLimit
    }

    func run() async throws -> AgentLoopResult {
        if let terminalResult { return terminalResult }
        if let pendingStep { return .pendingApproval(pendingStep.approval) }
        if let pendingQuestion { return .askUser(pendingQuestion) }
        return try await guarded { [self] in try await runSteps() }
    }

    func resume(approvalID: UUID, approved: Bool) async throws -> AgentLoopResult {
        guard let pending = pendingStep, pending.approval.id == approvalID else { throw AgentLoopError.noMatchingApproval }
        return try await guarded { [self] in try await continueApproval(pending, approved: approved) }
    }

    func resume(answer: String) async throws -> AgentLoopResult {
        guard let question = pendingQuestion else { throw AgentLoopError.noPendingQuestion }
        return try await guarded { [self] in
            try await activate(); try checkBoundary(); pendingQuestion = nil
            taskText += "\nAccepted clarification: " + answer; corrections.append(answer)
            history.append(.init(action: .askUser(question: question.question, choices: question.choices),
                                 result: "User clarification: \(answer)"))
            return try await runSteps()
        }
    }

    private func guarded(_ body: @escaping @MainActor () async throws -> AgentLoopResult) async throws -> AgentLoopResult {
        guard !isRunning else { throw AgentLoopError.alreadyRunning }
        isRunning = true; defer { completeRunCall() }
        let deadline = taskDeadline ?? (ContinuousClock.now + taskTimeLimit)
        taskDeadline = deadline
        let race = LoopResultRace()
        // These tasks deliberately do not form a task group: a noncooperative
        // capture or model startup must not keep the caller waiting at timeout.
        let worker = Task { @MainActor [self] in
            do { race.resolve(.success(try await runGuardedBody(body))) }
            catch { race.resolve(.failure(error)) }
        }
        deadlineWatchdog = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self, self.isRunning, !race.isResolved else { return }
            self.deadlineExpired = true
            worker.cancel()
            let interruptedInput = self.inFlightInput
            do {
                if !self.didFinish, let interruptedInput {
                    do { try self.journal.markUncertain(step: interruptedInput.step, fingerprint: interruptedInput.fingerprint) }
                    catch { self.corrections.append("Could not durably mark the interrupted input uncertain: \(error)") }
                }
                let reason = interruptedInput == nil ? self.timeoutReason
                    : "An interrupted input attempt may have taken effect. Take over to check it."
                let result = try self.finishRecord(.failed(reason: reason),
                    outcome: interruptedInput == nil ? "failed" : "uncertain")
                Task { @MainActor in await self.stopServices() }
                race.resolve(.success(result))
            } catch {
                Task { @MainActor in await self.stopServices() }
                race.resolve(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await race.wait()
        } onCancel: {
            worker.cancel()
            Task { @MainActor [weak self] in await self?.signalCancellation() }
        }
    }

    private func runGuardedBody(_ body: @MainActor () async throws -> AgentLoopResult) async throws -> AgentLoopResult {
            do { try checkDeadline(); return try await body() }
            catch LoopDeadline.exceeded {
                return try await finish(.failed(reason: timeoutReason), outcome: "failed")
            }
            catch AgentPolicyTermination.authorizationRevoked {
                corrections.append("Local authorization ended; the task stopped before using its stale result.")
                return try await finish(.cancelled, outcome: "cancelled")
            }
            catch is CancellationError {
                if deadlineExpired { return try await finish(.failed(reason: timeoutReason), outcome: "failed") }
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
    }

    private func continueApproval(_ pending: PendingStep, approved: Bool) async throws -> AgentLoopResult {
        let continuationStart = Date()
        if !approved {
            taskDeclineCount += 1
            deniedApprovalFingerprints.insert(pending.approval.fingerprint)
            gate.cancelPendingApproval(pending.approval.id); pendingStep = nil
            let denied = AgentGateResult(decision: .rejected, reason: "rejected: user declined",
                fingerprint: pending.approval.fingerprint, scopeIdentity: pending.approval.scopeIdentity,
                riskTier: pending.approval.riskTier.rawValue)
            let priorObservation = pending.resolved.frame.observation
            let denialObservation = AgentObservation(task: priorObservation.task,
                surface: priorObservation.surface, screenshot: priorObservation.screenshot,
                elements: priorObservation.elements, focus: priorObservation.focus,
                history: priorObservation.history,
                budget: AgentStepBudget(step: stepIndex, maxSteps: priorObservation.budget.maxSteps))
            try record(denialObservation, raw: "", action: pending.resolved.action,
                       gate: denied, execution: .init(status: .notExecuted, result: noted(denied.reason, pending.note)),
                       start: continuationStart)
            corrections.append("Approval declined by the owner.")
            history.append(.init(action: pending.resolved.action, result: noted("rejected: user declined", pending.note)))
            stepIndex += 1; rejectionStreak += 1
            if directOpenName != nil {
                return try await finish(.failed(reason: "App opening was declined."), outcome: "blocked: declined")
            }
            if taskDeclineCount >= 2 {
                return try await finish(.failed(reason: "BLOCKED: declined"), outcome: "blocked: declined")
            }
            if let question = askAfterRejections() { return question }
            return try await runSteps()
        }
        try await activate(); try checkBoundary()
        let frame = try await freshFrame(transition: pending.resolved.action)
        let rebound: AgentResolvedAction
        do { rebound = try await environment.rebind(pending.resolved, in: frame); try checkBoundary() }
        catch {
            try checkBoundary()
            gate.cancelPendingApproval(pending.approval.id); pendingStep = nil
            try record(frame.observation, raw: "", action: pending.resolved.action,
                       gate: rejected("Approval target changed: \(error)", scope: frame.scope),
                       execution: .init(status: .notExecuted, result: noted(String(describing: error), pending.note)),
                       start: continuationStart)
            history.append(.init(action: pending.resolved.action, result: noted("rejected: approval target changed", pending.note)))
            stepIndex += 1; rejectionStreak += 1
            if directOpenName != nil {
                return try await finish(.failed(reason: "The approved app action changed. Try again."), outcome: "failed")
            }
            if let question = askAfterRejections() { return question }
            return try await runSteps()
        }
        let decision = try gate.resolveApproval(pending.approval.id, approved: approved,
                                                resolved: rebound, expectedScope: try expectedScope())
        pendingStep = nil
        guard decision.result.decision == .allowed else {
            try record(frame.observation, raw: "", action: pending.resolved.action, gate: decision.result,
                       execution: .init(status: .notExecuted, result: noted(decision.result.reason, pending.note)),
                       start: continuationStart)
            corrections.append("Approval denied or invalidated: \(decision.result.reason)")
            let rejection = approved ? "rejected: \(decision.result.reason)" : "rejected: user declined"
            history.append(.init(action: pending.resolved.action, result: noted(rejection, pending.note)))
            stepIndex += 1; rejectionStreak += 1
            if directOpenName != nil {
                return try await finish(.failed(reason: "The app action could not be approved."), outcome: "failed")
            }
            if let question = askAfterRejections() { return question }
            return try await runSteps()
        }
        guard stepIndex < maxSteps else {
            let reason = "The task reached its \(maxSteps)-step limit before the approved action could run."
            let rejected = AgentGateResult(decision: .rejected, reason: reason,
                fingerprint: decision.result.fingerprint, scopeIdentity: decision.result.scopeIdentity,
                riskTier: decision.result.riskTier)
            try record(frame.observation, raw: "", action: pending.resolved.action, gate: rejected,
                       execution: .init(status: .notExecuted, result: noted(reason, pending.note)),
                       start: continuationStart)
            return try await finish(.failed(reason: reason), outcome: "failed")
        }
        approvals.append(pending.approval.fingerprint)
        if let terminal = try await execute(frame.observation, "", rebound, decision.result, continuationStart,
                                             note: pending.note) { return terminal }
        if let direct = try await finishDirectIfNeeded(rebound.action) { return direct }
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
            try checkBoundary()
            let observeMS = ms(observeStart)
            let policyStart = Date()
            let output: AgentPolicyOutput
            do {
                if let directOpenName, stepIndex == 0 {
                    output = AgentPolicyOutput(rawOutput: "", action: .openApp(name: directOpenName), rejectionReason: nil)
                } else {
                    output = try await policy.propose(frame.observation)
                }
            }
            catch is CancellationError { throw CancellationError() }
            catch AgentPolicyTermination.authorizationRevoked {
                throw AgentPolicyTermination.authorizationRevoked
            }
            catch let error as OSAtlasLlamaRuntimeError where
                error == .insufficientAvailableMemory || error == .insufficientPhysicalMemory ||
                error == .resourceInspectionFailed {
                try checkBoundary()
                let reason = "Policy resource error: \(error)"
                let decision = AgentGateResult(decision: .rejected, reason: reason,
                    scopeIdentity: frame.scope.identity, riskTier: AgentRiskTier.low.rawValue)
                try record(frame.observation, raw: "", action: nil, gate: decision,
                    execution: .init(status: .notExecuted, result: reason), start: start,
                    observeMS: observeMS, policyMS: ms(policyStart))
                stepIndex += 1
                return try await finish(.failed(reason: error.localizedDescription), outcome: "failed")
            }
            catch {
                if let result = try recordRejection(frame, raw: "", action: nil, reason: "Policy error: \(error)",
                    start: start, observeMS: observeMS, policyMS: ms(policyStart)) { return result }
                continue
            }
            let policyMS = ms(policyStart)
            try checkBoundary()
            progressNeedsSafeFallback = progressNeedsSafeFallback || AgentProgressNarration.hasSensitiveContext(frame.observation)
            stepProgress?(AgentProgressNarration.text(modelText: output.progressText,
                action: output.action, observation: frame.observation,
                afterSensitiveContext: progressNeedsSafeFallback))
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
                        observeMS: observeMS, policyMS: policyMS, note: output.resultLineNote)
                    return .handoff(reason: "Credential entry requires the owner.")
                }
                if let result = try recordRejection(frame, raw: output.rawOutput, action: proposedAction,
                    reason: "Target resolution rejected: \(error)", start: start,
                    observeMS: observeMS, policyMS: policyMS, note: output.resultLineNote) { return result }
                if directOpenName != nil { return try await finish(.failed(reason: "The app action could not be resolved."), outcome: "failed") }
                continue
            }
            catch {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: proposedAction,
                    reason: "Target resolution rejected: \(error)", start: start,
                    observeMS: observeMS, policyMS: policyMS, note: output.resultLineNote) { return result }
                if directOpenName != nil { return try await finish(.failed(reason: "The app action could not be resolved."), outcome: "failed") }
                continue
            }
            try checkBoundary()
            let action = resolved.action
            let gateStart = Date()
            let evaluation: AgentGateEvaluation
            do { evaluation = try gate.evaluate(resolved, expectedScope: try expectedScope()) }
            catch {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: action,
                    reason: "Gate rejected action: \(error)", start: start,
                    observeMS: observeMS, policyMS: policyMS, gateMS: ms(gateStart),
                    note: output.resultLineNote) { return result }
                if directOpenName != nil { return try await finish(.failed(reason: "The app action could not be approved."), outcome: "failed") }
                continue
            }
            let gateMS = ms(gateStart)
            if let fingerprint = evaluation.result.fingerprint,
               deniedApprovalFingerprints.contains(fingerprint) {
                if let approval = evaluation.approval {
                    gate.cancelPendingApproval(approval.id)
                }
                if let result = try await handleDeniedFingerprintRepeat(
                    frame: frame,
                    raw: output.rawOutput,
                    action: action,
                    evaluation: evaluation,
                    start: start,
                    observeMS: observeMS,
                    policyMS: policyMS,
                    gateMS: gateMS,
                    note: output.resultLineNote) {
                    return result
                }
                continue
            }
            if let approval = evaluation.approval {
                pendingStep = PendingStep(resolved: resolved, approval: approval, note: output.resultLineNote)
                try record(frame.observation, raw: output.rawOutput, action: action, gate: evaluation.result,
                           execution: .init(status: .notExecuted, result: noted(evaluation.result.reason, output.resultLineNote)),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
                history.append(.init(action: action, result: noted("needs approval: \(evaluation.result.reason)", output.resultLineNote))); stepIndex += 1
                return .pendingApproval(approval)
            }
            guard evaluation.result.decision == .allowed else {
                if let result = try recordRejection(frame, raw: output.rawOutput, action: action,
                    reason: evaluation.result.reason, start: start, observeMS: observeMS,
                    policyMS: policyMS, gateMS: gateMS, result: evaluation.result,
                    note: output.resultLineNote) { return result }
                if evaluation.result.reason.localizedCaseInsensitiveContains("credential") {
                    return .handoff(reason: evaluation.result.reason)
                }
                if directOpenName != nil { return try await finish(.failed(reason: evaluation.result.reason), outcome: "failed") }
                continue
            }
            rejectionStreak = 0
            if let result = try await control(frame, output, evaluation.result, start, observeMS,
                                              policyMS, gateMS) { return result }
            if let terminal = try await execute(frame.observation, output.rawOutput, resolved,
                evaluation.result, start, observeMS, policyMS, gateMS, note: output.resultLineNote) { return terminal }
            if let direct = try await finishDirectIfNeeded(resolved.action) { return direct }
        }
        return try await finish(.failed(reason: "The task reached its \(maxSteps)-step limit."), outcome: "failed")
    }

    private func handleDeniedFingerprintRepeat(
        frame: AgentFrame,
        raw: String,
        action: AgentAction,
        evaluation: AgentGateEvaluation,
        start: Date,
        observeMS: Int,
        policyMS: Int,
        gateMS: Int,
        note: String?
    ) async throws -> AgentLoopResult? {
        guard let fingerprint = evaluation.result.fingerprint else {
            throw AgentLoopError.invalidConfiguration
        }
        let reason = "BLOCKED: declined"
        let rejected = AgentGateResult(
            decision: .rejected,
            reason: reason,
            fingerprint: fingerprint,
            scopeIdentity: evaluation.result.scopeIdentity ?? frame.scope.identity,
            riskTier: evaluation.result.riskTier ?? AgentRiskTier.high.rawValue)
        try record(
            frame.observation,
            raw: raw,
            action: action,
            gate: rejected,
            execution: .init(status: .notExecuted, result: noted(reason, note)),
            start: start,
            observeMS: observeMS,
            policyMS: policyMS,
            gateMS: gateMS)
        history.append(.init(action: action, result: noted("rejected: \(reason)", note)))
        corrections.append(reason)
        stepIndex += 1
        return try await finish(.failed(reason: reason), outcome: "blocked: declined")
    }

    private func execute(_ observation: AgentObservation, _ raw: String, _ resolved: AgentResolvedAction,
                         _ gate: AgentGateResult, _ start: Date, _ observeMS: Int = 0,
                         _ policyMS: Int = 0, _ gateMS: Int = 0, note: String? = nil) async throws -> AgentLoopResult? {
        let action = resolved.action, begins = isInput(action), executionStart = Date()
        let fingerprint = gate.fingerprint ?? ""
        if begins {
            guard !fingerprint.isEmpty else { throw AgentLoopError.journalFailed("Allowed action has no fingerprint.") }
            do { try journal.assertMayContinue(); try journal.begin(step: stepIndex, fingerprint: fingerprint) }
            catch { throw AgentLoopError.journalFailed("Could not begin action: \(error)") }
        }
        if begins { inFlightInput = (stepIndex, fingerprint) }
        defer { inFlightInput = nil }
        let result: AgentExecutionResult
        do {
            try checkBoundary()
            if directOpenName != nil, case .openApp = resolved.action {
                result = try await environment.executeDirectOpen(resolved)
            } else { result = try await environment.execute(resolved) }
            try checkBoundary()
        }
        catch let error as AgentEnvironmentError {
            if didFinish { return terminalResult }
            if case .systemHandoff(let reason) = error {
                if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .error, result: noted("Owner handoff: \(reason)", note)),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                stepIndex += 1; throw LoopBoundary.handoff(reason)
            }
            if error == .credentialHandoff {
                if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .notExecuted, result: noted("Credential entry requires the owner.", note)),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                history.append(.init(action: action, result: noted("Credential entry requires the owner.", note)))
                stepIndex += 1
                throw LoopBoundary.handoff("Credential entry requires the owner.")
            }
            return try await recoverAttempt(error, observation, raw, action, gate, start,
                                            observeMS, policyMS, gateMS, executionStart, fingerprint, begins, note)
        } catch {
            if didFinish { return terminalResult }
            if error is CancellationError || error is LoopPause || error is LoopDeadline || cancelRequested || Task.isCancelled {
                if begins { try journal.markUncertain(step: stepIndex, fingerprint: fingerprint) }
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .error, result: noted("Interrupted input attempt: \(error)", note)),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                stepIndex += 1
                return try await finish(.failed(reason: "An interrupted input attempt may have taken effect."), outcome: "uncertain")
            }
            if begins && gate.riskTier == AgentRiskTier.high.rawValue {
                try journal.markUncertain(step: stepIndex, fingerprint: fingerprint)
                try record(observation, raw: raw, action: action, gate: gate,
                           execution: .init(status: .error, result: noted("Uncertain input attempt: \(error)", note)),
                           start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                           executionMS: ms(executionStart))
                history.append(.init(action: action, result: noted("uncertain: \(error)", note))); stepIndex += 1
                return try await finish(.failed(reason: "High-risk action outcome is uncertain."), outcome: "uncertain")
            }
            if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
            try record(observation, raw: raw, action: action, gate: gate,
                       execution: .init(status: .error, result: noted("Attempted; environment error: \(error)", note)),
                       start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                       executionMS: ms(executionStart))
            history.append(.init(action: action, result: "Attempted; environment error: \(error)")); stepIndex += 1
            return nil
        }
        if result.status != .ok && begins && gate.riskTier == AgentRiskTier.high.rawValue {
            try journal.markUncertain(step: stepIndex, fingerprint: fingerprint)
            try record(observation, raw: raw, action: action, gate: gate,
                       execution: .init(status: result.status, result: noted(result.result, note)),
                       start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                       executionMS: ms(executionStart))
            history.append(.init(action: action, result: noted("Uncertain: \(result.result)", note))); stepIndex += 1
            return try await finish(.failed(reason: "High-risk action outcome is uncertain."), outcome: "uncertain")
        }
        if begins {
            try journal.verify(step: stepIndex, fingerprint: fingerprint)
        }
        if result.status == .ok, case .openURL = action { expectedTransition = action }
        if result.status == .ok, case .openApp = action { expectedTransition = action }
        try record(observation, raw: raw, action: action, gate: gate,
                   execution: .init(status: result.status, result: noted(result.result, note)),
                   start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                   executionMS: ms(executionStart))
        history.append(.init(action: action, result: noted(result.status == .ok ? "ok: \(result.result)" : "Attempted: \(result.result)", note)))
        stepIndex += 1
        return nil
    }

    private func finishDirectIfNeeded(_ action: AgentAction) async throws -> AgentLoopResult? {
        guard let name = directOpenName, case .openApp = action else { return nil }
        guard history.last?.result.hasPrefix("ok:") == true else {
            return try await finish(.failed(reason: "Could not open \(name)."), outcome: "failed")
        }
        return try await finish(.completed(answer: "Opened \(name)."), outcome: "success")
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
                                _ fingerprint: String, _ begins: Bool, _ note: String?) async throws -> AgentLoopResult? {
        if begins && gate.riskTier == AgentRiskTier.high.rawValue {
            try journal.markUncertain(step: stepIndex, fingerprint: fingerprint)
            try record(observation, raw: raw, action: action, gate: gate,
                       execution: .init(status: .error, result: noted("Uncertain input attempt: \(error)", note)),
                       start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                       executionMS: ms(executionStart))
            history.append(.init(action: action, result: noted("uncertain: \(error)", note))); stepIndex += 1
            return try await finish(.failed(reason: "High-risk action outcome is uncertain."), outcome: "uncertain")
        }
        if begins && environment.followsFrontmostSurface { try await Task.sleep(for: .milliseconds(300)) }
        try checkBoundary()
        if begins { try journal.verify(step: stepIndex, fingerprint: fingerprint) }
        try record(observation, raw: raw, action: action, gate: gate,
                   execution: .init(status: .error, result: noted("Attempted; environment error: \(error)", note)),
                   start: start, observeMS: observeMS, policyMS: policyMS, gateMS: gateMS,
                   executionMS: ms(executionStart))
        history.append(.init(action: action, result: noted("Attempted; environment error: \(error)", note))); stepIndex += 1
        return nil
    }

    private func recordRejection(_ frame: AgentFrame, raw: String, action: AgentAction?, reason: String,
                                 start: Date, observeMS: Int, policyMS: Int, gateMS: Int = 0,
                                 result: AgentGateResult? = nil, note: String? = nil) throws -> AgentLoopResult? {
        let decision = result ?? AgentGateResult(decision: .rejected, reason: reason,
            scopeIdentity: frame.scope.identity, riskTier: AgentRiskTier.low.rawValue)
        try record(frame.observation, raw: raw, action: action, gate: decision,
                   execution: .init(status: .notExecuted, result: noted(reason, note)), start: start,
                   observeMS: observeMS, policyMS: policyMS, gateMS: gateMS)
        history.append(.init(action: action, result: noted("rejected: \(reason)", note))); stepIndex += 1
        rejectionStreak += 1; corrections.append(reason)
        return reason.localizedCaseInsensitiveContains("credential") ? nil : askAfterRejections()
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
        try checkBoundary()
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

    private func checkDeadline() throws {
        if deadlineExpired || taskDeadline.map({ ContinuousClock.now >= $0 }) == true {
            deadlineExpired = true
            throw LoopDeadline.exceeded
        }
    }

    private func checkBoundary() throws {
        if didFinish { throw CancellationError() }
        try checkDeadline()
        if cancelRequested || Task.isCancelled { throw CancellationError() }
        if pauseRequested { throw LoopPause.requested }
    }

    private func activate() async throws {
        guard pauseRequested else { return }
        try await environment.resume(); try checkDeadline()
        try await policy.resume(); try checkDeadline(); pauseRequested = false
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
        if didFinish { throw CancellationError() }
        let step = AgentEpisodeStep(episodeID: taskID, step: stepIndex, observation: observation,
            promptVersion: directOpenName == nil ? policy.promptVersion : "direct-open-v1", rawModelOutput: raw, action: action, gate: gate,
            execution: execution, timings: .init(observationMS: observeMS, policyMS: policyMS,
                gateMS: gateMS, executionMS: executionMS, recordMS: 0, totalMS: ms(start)),
            source: directOpenName == nil ? nil : "direct")
        do { try recorder.record(step) }
        catch {
            let failure = AgentLoopError.recordingFailed("Could not durably record step \(stepIndex): \(error)")
            if let pendingStep { gateCancel(pendingStep.approval.id) }; pendingStep = nil
            terminalResult = .failed(reason: String(describing: failure))
            throw failure
        }
    }

    private func finish(_ result: AgentLoopResult, outcome: String) async throws -> AgentLoopResult {
        let retained = try finishRecord(result, outcome: outcome)
        await stopServices()
        return retained
    }

    private func finishRecord(_ result: AgentLoopResult, outcome: String) throws -> AgentLoopResult {
        guard !didFinish else { return terminalResult ?? result }
        if let pendingStep { gateCancel(pendingStep.approval.id) }
        pendingStep = nil; pendingQuestion = nil
        footerAttempted = true
        // Set the fence before any asynchronous teardown. Both the timeout and
        // late worker may arrive here, but only one may write a terminal footer.
        didFinish = true
        terminalResult = result
        do { try recorder.finish(.init(episodeID: taskID, outcome: outcome, approvals: approvals, corrections: corrections)) }
        catch {
            terminalResult = .failed(reason: "Could not durably finish episode: \(error)")
            throw AgentLoopError.recordingFailed(String(describing: error))
        }
        return result
    }

    private func gateCancel(_ id: UUID) { gate.cancelPendingApproval(id) }
    private func noted(_ result: String, _ note: String?) -> String {
        guard let note, !note.isEmpty else { return result }
        return "\(result) (\(note))"
    }
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
        // Approval, clarification and takeover already show a needs-you state.
        // Keep that state intact; a later Resume checks the original deadline.
        deadlineWatchdog?.cancel(); deadlineWatchdog = nil
        isRunning = false; let waiters = completionWaiters; completionWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
    private func waitForRunCall() async {
        guard isRunning else { return }; await withCheckedContinuation { completionWaiters.append($0) }
    }
    private func ms(_ start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1_000)) }
}

private enum LoopDeadline: Error { case exceeded }
private enum LoopPause: Error { case requested }
private enum LoopBoundary: Error { case handoff(String) }

@MainActor
private final class LoopResultRace {
    private var result: Result<AgentLoopResult, Error>?
    private var continuation: CheckedContinuation<AgentLoopResult, Error>?

    var isResolved: Bool { result != nil }

    func resolve(_ result: Result<AgentLoopResult, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func wait() async throws -> AgentLoopResult {
        try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result) }
            else { self.continuation = continuation }
        }
    }
}
