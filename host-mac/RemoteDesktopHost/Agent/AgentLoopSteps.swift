import Foundation

extension AgentLoop {
    func recordContinuation(_ observation: AgentObservation, action: AgentAction, gate: AgentGateResult,
                            execution: AgentExecutionResult) throws {
        let startedAt = Date()
        try record(observation, raw: "", action: action, gate: gate, execution: execution,
                   startedAt: startedAt, observationMS: 0, policyMS: 0, gateMS: 0, executionMS: 0)
        history.append(AgentHistoryItem(action: action, result: "approval continuation: \(execution.result)"))
        stepIndex += 1
    }

    func continueAfter() async throws -> AgentLoopResult {
        return try await runUntilBoundary()
    }

    func record(_ observation: AgentObservation, raw: String, action: AgentAction?, gate: AgentGateResult,
                        execution: AgentExecutionResult, startedAt: Date, observationMS: Int, policyMS: Int,
                        gateMS: Int, executionMS: Int) throws {
        let step = AgentEpisodeStep(episodeID: taskID, step: stepIndex, observation: observation,
                                    promptVersion: policy.promptVersion, rawModelOutput: raw, action: action,
                                    gate: gate, execution: execution,
                                    timings: AgentTimings(observationMS: observationMS, policyMS: policyMS,
                                                          gateMS: gateMS, executionMS: executionMS, recordMS: 0,
                                                          totalMS: milliseconds(since: startedAt)))
        do { try recorder.record(step) }
        catch {
            let message = "Could not durably record step \(stepIndex): \(error)"
            let terminal = AgentLoopResult.failed(reason: message)
            let footer = AgentEpisodeFooter(episodeID: taskID, outcome: "failed",
                                            approvals: approvals, corrections: corrections)
            try? recorder.finish(footer)
            if let pendingStep { self.gate.cancelPendingApproval(pendingStep.approval.id) }
            pendingStep = nil; pendingQuestion = nil
            terminalResult = terminal
            throw AgentLoopError.recordingFailed(message)
        }
    }

    func finish(_ result: AgentLoopResult, outcome: String) async throws -> AgentLoopResult {
        guard !didFinish else { return terminalResult ?? result }
        if let pendingStep { self.gate.cancelPendingApproval(pendingStep.approval.id) }
        pendingStep = nil
        pendingQuestion = nil
        let footer = AgentEpisodeFooter(episodeID: taskID, outcome: outcome,
                                        approvals: approvals, corrections: corrections)
        var recordingFailure: AgentLoopError?
        do { try recorder.finish(footer) }
        catch { recordingFailure = .recordingFailed("Could not durably finish the episode: \(error)") }
        await stopServices()
        didFinish = true
        if let recordingFailure {
            terminalResult = .failed(reason: String(describing: recordingFailure))
            throw recordingFailure
        }
        terminalResult = result
        return result
    }

    func terminate(reason: String, cancelled: Bool) async throws -> AgentLoopResult {
        if isRunning && (pauseRequested && !cancelled) { return .paused }
        let result: AgentLoopResult = cancelled ? .cancelled : .failed(reason: reason)
        return try await finish(result, outcome: cancelled ? "cancelled" : "failed")
    }

    func nextFrame() async throws -> AgentFrame {
        if let prefetchedFrame {
            self.prefetchedFrame = nil
            try verifySurfaceKind(prefetchedFrame)
            try bindOrVerifyScope(prefetchedFrame.scope)
            let context = observationContext()
            let previous = prefetchedFrame.observation
            let observation = AgentObservation(task: context.task, surface: previous.surface,
                screenshot: previous.screenshot, elements: previous.elements, focus: previous.focus,
                history: context.history, budget: context.budget)
            return AgentFrame(observation: observation, scope: prefetchedFrame.scope,
                              authorityDigest: prefetchedFrame.authorityDigest)
        }
        let frame = try await environment.observe(observationContext())
        try verifySurfaceKind(frame)
        try bindOrVerifyScope(frame.scope)
        return frame
    }

    func verifySurfaceKind(_ frame: AgentFrame) throws {
        let matches: Bool
        switch (frame.scope.kind, frame.observation.surface) {
        case (.web, .web), (.app, .app): matches = true
        default: matches = false
        }
        guard matches else { throw AgentEnvironmentError.scopeChanged }
    }

    func observationContext() -> AgentObservationContext {
        AgentObservationContext(task: taskText, history: history,
                                budget: AgentStepBudget(step: stepIndex, maxSteps: maxSteps))
    }

    func expectedScope() throws -> AgentScope {
        guard let boundScope else { throw AgentLoopError.invalidConfiguration }
        return boundScope
    }

    func bindOrVerifyScope(_ scope: AgentScope, transition: AgentAction? = nil,
                                   observation: AgentObservation? = nil) throws {
        guard scope.taskID == taskID else {
            throw AgentEnvironmentError.scopeChanged
        }
        if let boundScope {
            if scope == boundScope { return }
            guard let transition, let observation,
                  let destinationKind = transitionKind(transition), destinationKind == scope.kind,
                  gate.matchesOpenedSurface(action: transition, from: boundScope, observation: observation) else {
                throw AgentEnvironmentError.scopeChanged
            }
            self.boundScope = scope
        } else {
            boundScope = scope
        }
    }

    func requireFingerprint(_ result: AgentGateResult) throws -> String {
        guard let fingerprint = result.fingerprint else {
            throw AgentLoopError.journalFailed("An allowed input action has no host fingerprint.")
        }
        return fingerprint
    }

    func markUncertain(step: Int, fingerprint: String) throws {
        do { try journal.markUncertain(step: step, fingerprint: fingerprint) }
        catch { throw AgentLoopError.journalFailed("Could not persist the uncertain action state: \(error)") }
    }

    func checkBoundary() throws {
        if cancelRequested || Task.isCancelled { throw CancellationError() }
        if pauseRequested { throw AgentLoopInterrupt.paused }
    }

    func signalCancellation() async {
        cancelRequested = true
        await stopServices()
    }

    func stopServices() async {
        guard !servicesStopped else { return }
        servicesStopped = true
        await environment.stop()
        await policy.stop()
    }

    func stopAfterRecordingFailure(_ error: AgentLoopError) async {
        await stopServices()
        if terminalResult == nil { terminalResult = .failed(reason: String(describing: error)) }
        didFinish = true
    }

    func completeRunCall() {
        isRunning = false
        let waiters = completionWaiters
        completionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForRunCall() async {
        guard isRunning else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }

    func milliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    func isTerminalAction(_ action: AgentAction) -> Bool {
        switch action { case .done, .fail: true; default: false }
    }

    func isQuestionAction(_ action: AgentAction) -> Bool {
        if case .askUser = action { true } else { false }
    }

    func isSurfaceTransition(_ action: AgentAction) -> Bool {
        switch action { case .openURL, .openApp: true; default: false }
    }

    func transitionKind(_ action: AgentAction) -> AgentScope.Kind? {
        switch action { case .openURL: .web; case .openApp: .app; default: nil }
    }

    func isInputEffect(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .type, .key, .scroll, .select, .drag, .openURL, .openApp, .setFiles: true
        case .findFiles, .wait, .askUser, .done, .fail: false
        }
    }

    func resolutionReason(_ error: Error) -> String {
        if let error = error as? AgentEnvironmentError {
            switch error {
            case .unavailable(let message): message
            case .scopeChanged: "The target belongs to another task surface."
            case .targetGone: "The target is no longer present."
            case .targetChanged: "The target changed after observation."
            case .targetCovered: "The target is covered."
            case .disabledTarget: "The target is disabled."
            case .unsupportedAction: "The environment does not support this action."
            case .credentialHandoff: "Credential fields are blocked; hand off to the user."
            }
        } else { "The target could not be resolved: \(error)" }
    }

    func rejected(_ reason: String, scope: AgentScope, risk: AgentRiskTier = .low) -> AgentGateResult {
        AgentGateResult(decision: .rejected, reason: reason, scopeIdentity: scope.identity, riskTier: risk.rawValue)
    }

    func processFrame(_ frame: AgentFrame, startedAt: Date, observationMS: Int) async throws -> AgentLoopResult? {
        let scope = try expectedScope()
        let policyStart = Date()
        let output: AgentPolicyOutput
        do { output = try await policy.propose(frame.observation) }
        catch is CancellationError {
            if pauseRequested && !cancelRequested { throw AgentLoopInterrupt.paused }
            throw CancellationError()
        }
        catch {
            let reason = "The local policy failed: \(error)"
            let gateResult = rejected(reason, scope: scope)
            try record(frame.observation, raw: "", action: nil, gate: gateResult,
                       execution: .init(status: .notExecuted, result: reason), startedAt: startedAt,
                       observationMS: observationMS, policyMS: milliseconds(since: policyStart), gateMS: 0, executionMS: 0)
            history.append(AgentHistoryItem(action: nil, result: "rejected: \(reason)"))
            return try await terminate(reason: reason, cancelled: false)
        }
        let policyMS = milliseconds(since: policyStart)
        try checkBoundary()

        guard let action = output.action else {
            let reason = output.rejectionReason ?? "The policy output did not contain one valid action."
            let gateResult = rejected(reason, scope: scope)
            try record(frame.observation, raw: output.rawOutput, action: nil, gate: gateResult,
                       execution: .init(status: .notExecuted, result: reason), startedAt: startedAt,
                       observationMS: observationMS, policyMS: policyMS, gateMS: 0, executionMS: 0)
            history.append(AgentHistoryItem(action: nil, result: "rejected: \(reason)")); malformedCount += 1; stepIndex += 1
            if malformedCount > 1 { return try await terminate(reason: "The policy returned malformed output twice.", cancelled: false) }
            return nil
        }
        malformedCount = 0
        let resolved: AgentResolvedAction
        let resolveStart = Date()
        do {
            if isTerminalAction(action) || isQuestionAction(action) {
                resolved = AgentResolvedAction(action: action, frame: frame, targets: [])
            } else {
                resolved = try await environment.resolve(action, in: frame)
            }
        } catch {
            let reason = resolutionReason(error)
            let gateResult = rejected(reason, scope: scope, risk: .medium)
            try record(frame.observation, raw: output.rawOutput, action: action, gate: gateResult,
                       execution: .init(status: .notExecuted, result: reason), startedAt: startedAt,
                       observationMS: observationMS, policyMS: policyMS, gateMS: milliseconds(since: resolveStart), executionMS: 0)
            history.append(AgentHistoryItem(action: action, result: "rejected: \(reason)")); stepIndex += 1
            if (error as? AgentEnvironmentError) == .credentialHandoff { return .handoff(reason: reason) }
            return nil
        }
        let gateStart = Date()
        let evaluation = try gate.evaluate(resolved, expectedScope: scope)
        let gateMS = milliseconds(since: gateStart) + milliseconds(since: resolveStart)
        if let approval = evaluation.approval {
            return try recordApprovalRequest(approval, frame: frame, output: output, action: action,
                resolved: resolved, gateResult: evaluation.result, startedAt: startedAt,
                observationMS: observationMS, policyMS: policyMS, gateMS: gateMS)
        }
        if evaluation.result.decision == .rejected {
            try record(frame.observation, raw: output.rawOutput, action: action, gate: evaluation.result,
                       execution: .init(status: .notExecuted, result: evaluation.result.reason), startedAt: startedAt,
                       observationMS: observationMS, policyMS: policyMS, gateMS: gateMS, executionMS: 0)
            history.append(AgentHistoryItem(action: action, result: "rejected: \(evaluation.result.reason)")); stepIndex += 1
            if evaluation.result.reason.contains("Credential fields are blocked")
                || evaluation.result.reason.contains("could not resolve the requested app") {
                return .handoff(reason: evaluation.result.reason)
            }
            return nil
        }

        let terminal = try await executeAndRecord(frame.observation, output.rawOutput, resolved,
                                                  evaluation.result, startedAt, observationMS: observationMS,
                                                  policyMS: policyMS, gateMS: gateMS,
                                                  allowTransition: isSurfaceTransition(action))
        if let terminal { return terminal }
        return nil
    }

    func recordApprovalRequest(_ approval: AgentApprovalRequest, frame: AgentFrame,
                               output: AgentPolicyOutput, action: AgentAction,
                               resolved: AgentResolvedAction, gateResult: AgentGateResult,
                               startedAt: Date, observationMS: Int, policyMS: Int,
                               gateMS: Int) throws -> AgentLoopResult {
        pendingStep = PendingStep(resolved: resolved, approval: approval)
        try record(frame.observation, raw: output.rawOutput, action: action, gate: gateResult,
                   execution: .init(status: .notExecuted, result: gateResult.reason),
                   startedAt: startedAt, observationMS: observationMS, policyMS: policyMS,
                   gateMS: gateMS, executionMS: 0)
        history.append(AgentHistoryItem(action: action, result: "needs approval: \(gateResult.reason)"))
        stepIndex += 1
        return .pendingApproval(approval)
    }

    func recordControlAction(_ observation: AgentObservation, _ raw: String, _ action: AgentAction,
                             _ gateResult: AgentGateResult, _ startedAt: Date,
                             _ observationMS: Int, _ policyMS: Int, _ gateMS: Int) async throws -> AgentLoopResult? {
        switch action {
        case let .done(answer):
            try record(observation, raw: raw, action: action, gate: gateResult,
                       execution: .init(status: .ok, result: answer), startedAt: startedAt,
                       observationMS: observationMS, policyMS: policyMS, gateMS: gateMS, executionMS: 0)
            history.append(AgentHistoryItem(action: action, result: "ok: \(answer)")); stepIndex += 1
            return try await finish(.completed(answer: answer), outcome: "success")
        case let .fail(reason):
            try record(observation, raw: raw, action: action, gate: gateResult,
                       execution: .init(status: .error, result: reason), startedAt: startedAt,
                       observationMS: observationMS, policyMS: policyMS, gateMS: gateMS, executionMS: 0)
            history.append(AgentHistoryItem(action: action, result: "error: \(reason)")); stepIndex += 1
            return try await finish(.failed(reason: reason), outcome: "failed")
        case let .askUser(question, choices):
            let pending = AgentUserQuestion(id: UUID(), question: question, choices: choices)
            try record(observation, raw: raw, action: action, gate: gateResult,
                       execution: .init(status: .notExecuted, result: "Waiting for the user."), startedAt: startedAt,
                       observationMS: observationMS, policyMS: policyMS, gateMS: gateMS, executionMS: 0)
            stepIndex += 1; pendingQuestion = pending
            return .askUser(pending)
        default: return nil
        }
    }

    func executeEffect(_ observation: AgentObservation, _ raw: String, _ resolved: AgentResolvedAction,
                       _ gateResult: AgentGateResult, _ startedAt: Date, _ observationMS: Int,
                       _ policyMS: Int, _ gateMS: Int, _ allowTransition: Bool) async throws -> AgentLoopResult? {
        let action = resolved.action
        let executionStart = Date()
        let fingerprint = try requireFingerprint(gateResult)
        let began = isInputEffect(action)
        if began {
            do {
                try journal.assertMayContinue()
                try journal.begin(step: stepIndex, fingerprint: fingerprint)
            } catch { throw AgentLoopError.journalFailed("Could not durably begin the action: \(error)") }
        }
        let execution: AgentExecutionResult
        var nextFrame: AgentFrame?
        do {
            try checkBoundary()
            execution = try await environment.execute(resolved)
            try checkBoundary()
            guard execution.status == .ok else {
                return try await failUncertainEffect(observation, raw, action, gateResult, startedAt,
                    observationMS, policyMS, gateMS, executionStart, fingerprint, began,
                    reason: "The environment did not confirm the action: \(execution.result)", cancelled: false)
            }
            if began {
                nextFrame = try await environment.observe(observationContext())
                try verifySurfaceKind(nextFrame!)
                try bindOrVerifyScope(nextFrame!.scope,
                    transition: allowTransition && isSurfaceTransition(action) ? action : nil,
                    observation: nextFrame!.observation)
                try checkBoundary()
                try journal.verify(step: stepIndex, fingerprint: fingerprint)
            }
        } catch {
            return try await failUncertainEffect(observation, raw, action, gateResult, startedAt,
                observationMS, policyMS, gateMS, executionStart, fingerprint, began,
                reason: "Execution is uncertain: \(error)", cancelled: cancelRequested || Task.isCancelled)
        }
        if let nextFrame { prefetchedFrame = nextFrame }
        try record(observation, raw: raw, action: action, gate: gateResult, execution: execution,
                   startedAt: startedAt, observationMS: observationMS, policyMS: policyMS, gateMS: gateMS,
                   executionMS: milliseconds(since: executionStart))
        history.append(AgentHistoryItem(action: action, result: "ok: \(execution.result)")); stepIndex += 1
        return nil
    }

    func failUncertainEffect(_ observation: AgentObservation, _ raw: String, _ action: AgentAction,
                             _ gateResult: AgentGateResult, _ startedAt: Date,
                             _ observationMS: Int, _ policyMS: Int, _ gateMS: Int,
                             _ executionStart: Date, _ fingerprint: String, _ began: Bool,
                             reason: String, cancelled: Bool) async throws -> AgentLoopResult {
        if began { try markUncertain(step: stepIndex, fingerprint: fingerprint) }
        let execution = AgentExecutionResult(status: cancelled ? .notExecuted : .error, result: reason)
        try record(observation, raw: raw, action: action, gate: gateResult, execution: execution,
                   startedAt: startedAt, observationMS: observationMS, policyMS: policyMS,
                   gateMS: gateMS, executionMS: milliseconds(since: executionStart))
        history.append(AgentHistoryItem(action: action, result: "error: \(reason)")); stepIndex += 1
        let uncertainPause = began && pauseRequested && !cancelRequested && !cancelled
        if uncertainPause { pauseRequested = false }
        let outcome = cancelled ? "cancelled" : "uncertain"
        let result: AgentLoopResult = cancelled ? .cancelled : .failed(reason: reason)
        return try await finish(result, outcome: outcome)
    }

}
