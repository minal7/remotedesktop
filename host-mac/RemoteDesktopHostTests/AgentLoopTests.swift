import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentLoopTests: XCTestCase {
    func testWaitThenDoneRecordsEveryStepAndOneTerminalFooter() async throws {
        let frames = [webFrame(), webFrame(), webFrame()]
        let environment = TestEnvironment(frames: frames)
        let policy = TestPolicy([.action(.wait(seconds: 0.1)), .action(.done(answer: "Finished"))])
        let recorder = TestRecorder()
        let journal = TestJournal()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder, journal: journal)

        let result = try await loop.run()
        XCTAssertEqual(result, .completed(answer: "Finished"))
        XCTAssertEqual(recorder.steps.map(\.step), [0, 1])
        XCTAssertEqual(recorder.footer?.outcome, "success")
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertTrue(journal.begun.isEmpty)
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(environment.stopCount, 1)
        XCTAssertEqual(policy.stopCount, 1)
    }

    func testThreeMalformedOutputsAskTheUserAndKeepRejectionHistory() async throws {
        let environment = TestEnvironment(frames: [webFrame(), webFrame(), webFrame(), webFrame()])
        let policy = TestPolicy([.malformed("not JSON"), .malformed("still malformed"),
                                 .malformed("third malformed"), .action(.done(answer: "Recovered"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder, journal: TestJournal())

        let result = try await loop.run()
        guard case .askUser(let question) = result else { return XCTFail("Expected a handoff after three rejections") }
        XCTAssertTrue(question.question.contains("last three actions"))
        XCTAssertEqual(recorder.steps.map(\.rawModelOutput), ["not JSON", "still malformed", "third malformed"])
        XCTAssertTrue(recorder.steps.allSatisfy { $0.action == nil && $0.gate.decision == .rejected })
        XCTAssertEqual(recorder.steps.map(\.step), [0, 1, 2])
        XCTAssertNil(recorder.footer)
        let resumed = try await loop.resume(answer: "Please continue")
        XCTAssertEqual(resumed, .completed(answer: "Recovered"))
        let rejection = "rejected: Invalid output"
        XCTAssertTrue(policy.observations[1].history.map(\.result).contains(rejection))
        XCTAssertEqual(policy.observations[2].history.map(\.result).filter { $0 == rejection }.count, 2)
        XCTAssertEqual(policy.observations[3].history.map(\.result).filter { $0 == rejection }.count, 3)
    }

    func testStaleTargetRejectionIsRecordedAndReturnedInTheNextObservation() async throws {
        let environment = TestEnvironment(frames: [webFrame(), webFrame()])
        let policy = TestPolicy([.action(.click(target: .element(id: 99), button: nil, count: nil)),
                                 .action(.done(answer: "Recovered"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal())

        let result = try await loop.run()
        XCTAssertEqual(result, .completed(answer: "Recovered"))
        XCTAssertEqual(recorder.steps.count, 2)
        XCTAssertEqual(recorder.steps[0].gate.decision, .rejected)
        XCTAssertTrue(environment.lastContext?.history.last?.result.contains("Target resolution rejected") == true)
        XCTAssertTrue(environment.lastContext?.history.last?.result.contains("targetGone") == true)
    }

    func testPixelFrontmostWindowChangeRebindsToRealFreshScope() async throws {
        let firstScope = AgentScope(taskID: "task-1", kind: .web, identity: "window-1")
        let nextScope = AgentScope(taskID: "task-1", kind: .web, identity: "window-2")
        let first = webFrame(scope: firstScope, elements: [button(id: 1, name: "Continue")])
        let next = webFrame(scope: nextScope)
        let environment = TestEnvironment(frames: [first, next, next], followsFrontmostSurface: true)
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Recovered in the new window"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal(), trustedWeb: true)

        let result = try await loop.run()

        XCTAssertEqual(result, .completed(answer: "Recovered in the new window"))
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(environment.observedScopes, [firstScope, nextScope])
        XCTAssertEqual(recorder.steps.map(\.gate.decision), [.allowed, .allowed])
        XCTAssertEqual(recorder.steps[1].observation.surface, next.observation.surface)
    }

    func testAskUserReturnsTypedQuestionAndAcceptedAnswerContinuesTask() async throws {
        let environment = TestEnvironment(frames: [webFrame(), webFrame()])
        let policy = TestPolicy([.action(.askUser(question: "Which option?", choices: ["A", "B"])),
                                 .action(.done(answer: "Selected A"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder, journal: TestJournal())

        let first = try await loop.run()
        guard case .askUser(let question) = first else { return XCTFail("Expected a user question") }
        XCTAssertEqual(question.question, "Which option?")
        XCTAssertEqual(question.choices, ["A", "B"])
        let resumed = try await loop.resume(answer: "A")
        XCTAssertEqual(resumed, .completed(answer: "Selected A"))
        XCTAssertTrue(environment.lastContext?.task.contains("Accepted clarification: A") == true)
        XCTAssertEqual(recorder.footer?.corrections, ["A"])
        XCTAssertEqual(recorder.finishCount, 1)
    }

    func testChangedTargetInvalidatesApprovalAndDoesNotExecute() async throws {
        let original = webFrame(elements: [button(id: 1, name: "Continue")])
        let changed = webFrame(elements: [button(id: 1, name: "Delete")])
        let environment = TestEnvironment(frames: [original, changed, changed])
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Stopped"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder, journal: TestJournal())

        let pending = try await loop.run()
        guard case .pendingApproval(let approval) = pending else { return XCTFail("Expected approval") }
        let resumed = try await loop.resume(approvalID: approval.id, approved: true)
        XCTAssertEqual(resumed, .completed(answer: "Stopped"))
        XCTAssertTrue(environment.executed.isEmpty)
        XCTAssertEqual(recorder.steps.count, 3)
        XCTAssertEqual(recorder.steps[0].gate.decision, .needsApproval)
        XCTAssertEqual(recorder.steps[1].gate.decision, .rejected)
        XCTAssertEqual(recorder.steps[1].rawModelOutput, "")
        XCTAssertEqual(recorder.steps[1].action?.type, "click")
        XCTAssertTrue(recorder.steps[1].gate.reason.contains("changed"))
    }

    func testCancellingPendingApprovalRecordsTheUnexecutedStep() async throws {
        let environment = TestEnvironment(frames: [webFrame(elements: [button(id: 1, name: "Submit")])])
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal(), trustedWeb: true)
        guard case .pendingApproval = try await loop.run() else { return XCTFail("Expected approval") }
        XCTAssertEqual(recorder.steps.count, 1, "The model proposal is recorded before waiting for the owner.")
        XCTAssertEqual(recorder.steps[0].gate.decision, .needsApproval)
        XCTAssertEqual(recorder.steps[0].rawModelOutput, "action:click")

        let result = try await loop.cancel()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(recorder.steps.count, 1)
        XCTAssertEqual(recorder.steps[0].gate.decision, .needsApproval)
        XCTAssertEqual(recorder.steps[0].execution.status, .notExecuted)
        XCTAssertEqual(recorder.footer?.outcome, "cancelled")
        XCTAssertTrue(loop.didFinish)
        XCTAssertEqual(environment.stopCount, 1)
    }

    func testDeclinedApprovalIsFedBackAndDoesNotExecuteOrGrantTrust() async throws {
        let frame = webFrame(elements: [button(id: 1, name: "Submit")])
        let environment = TestEnvironment(frames: [frame, frame])
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Stopped safely"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal())
        guard case .pendingApproval(let approval) = try await loop.run() else {
            return XCTFail("Expected approval")
        }
        let result = try await loop.resume(approvalID: approval.id, approved: false)
        XCTAssertEqual(result, .completed(answer: "Stopped safely"))
        XCTAssertTrue(environment.executed.isEmpty)
        XCTAssertEqual(environment.lastContext?.history.last?.result, "rejected: user declined")
        XCTAssertEqual(recorder.steps.map(\.gate.decision), [.needsApproval, .rejected, .allowed])
        XCTAssertEqual(recorder.footer?.approvals, [])
    }

    func testDeclinedApprovalDoesNotRebindVanishedTargetOrChangedSurface() async throws {
        let original = webFrame(elements: [button(id: 1, name: "Submit")])
        let changedScope = AgentScope(taskID: "task-1", kind: .app, identity: "another-window")
        let changedSurface = AgentFrame(observation: observation(surface: .app(bundleID: "com.example.editor", title: nil)),
                                        scope: changedScope)
        let environment = TestEnvironment(frames: [original, changedSurface], followsFrontmostSurface: true)
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Declined safely"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal())

        guard case .pendingApproval(let approval) = try await loop.run() else {
            return XCTFail("Expected a pending approval")
        }
        let result = try await loop.resume(approvalID: approval.id, approved: false)

        XCTAssertEqual(result, .completed(answer: "Declined safely"))
        XCTAssertEqual(environment.executed.count, 0)
        XCTAssertEqual(recorder.steps.map(\.gate.decision), [.needsApproval, .rejected, .allowed])
        XCTAssertEqual(recorder.steps[1].observation.surface, original.observation.surface)
        XCTAssertEqual(environment.lastContext?.history.last?.result, "rejected: user declined")
    }

    func testPolicyResultNoteSurvivesApprovalDenialAndApprovedResume() async throws {
        let frame = webFrame(elements: [button(id: 1, name: "Submit")])
        let action = AgentAction.click(target: .element(id: 1), button: nil, count: nil)
        let note = "mapped ctrl+a → cmd+a"

        let deniedEnvironment = TestEnvironment(frames: [frame, frame])
        let deniedRecorder = TestRecorder()
        let deniedPolicy = TestPolicy([.output(.init(rawOutput: "action:key", action: action,
            rejectionReason: nil, resultLineNote: note)), .action(.done(answer: "Declined safely"))])
        let deniedLoop = try makeLoop(environment: deniedEnvironment, policy: deniedPolicy,
            recorder: deniedRecorder, journal: TestJournal())
        guard case .pendingApproval(let deniedApproval) = try await deniedLoop.run() else {
            return XCTFail("Expected approval")
        }
        _ = try await deniedLoop.resume(approvalID: deniedApproval.id, approved: false)
        XCTAssertTrue(deniedRecorder.steps[0].execution.result.contains(note))
        XCTAssertTrue(deniedRecorder.steps[1].execution.result.contains(note))
        XCTAssertTrue(deniedEnvironment.executed.isEmpty)

        let approvedEnvironment = TestEnvironment(frames: [frame, frame, frame])
        let approvedRecorder = TestRecorder()
        let approvedPolicy = TestPolicy([.output(.init(rawOutput: "action:key", action: action,
            rejectionReason: nil, resultLineNote: note)), .action(.done(answer: "Completed safely"))])
        let approvedLoop = try makeLoop(environment: approvedEnvironment, policy: approvedPolicy,
            recorder: approvedRecorder, journal: TestJournal())
        guard case .pendingApproval(let approval) = try await approvedLoop.run() else {
            return XCTFail("Expected approval")
        }
        _ = try await approvedLoop.resume(approvalID: approval.id, approved: true)
        XCTAssertTrue(approvedRecorder.steps[0].execution.result.contains(note))
        XCTAssertTrue(approvedRecorder.steps[1].execution.result.contains(note))
        XCTAssertEqual(approvedEnvironment.executed.count, 1)
    }

    func testPerStepProgressUsesPolicyNarrationWithoutChangingApprovalFlow() async throws {
        let secure = AgentFrame(observation: AgentObservation(task: "Complete a generic task",
            surface: .app(bundleID: "example.app", title: nil), screenshot: "",
            elements: [.init(id: 1, role: "AXSecureTextField", name: "Password", value: nil,
                state: ["secure"], bbox: .init(x: 1, y: 2, width: 3, height: 4), inView: true)],
            focus: nil, history: [], budget: .init(step: 0, maxSteps: 40)),
            scope: AgentScope(taskID: "task-1", kind: .app, identity: "window-1"))
        let ordinary = AgentFrame(observation: AgentObservation(task: secure.observation.task,
            surface: secure.observation.surface, screenshot: "", elements: [], focus: nil,
            history: [], budget: .init(step: 0, maxSteps: 40)), scope: secure.scope)
        let policy = TestPolicy([
            .output(.init(rawOutput: "action:wait", action: .wait(seconds: 0.1), rejectionReason: nil,
                          progressText: "The password is private-value-123.")),
            .output(.init(rawOutput: "action:done", action: .done(answer: "Done"), rejectionReason: nil,
                          progressText: "The password is private-value-123.")),
        ])
        let loop = try makeLoop(environment: TestEnvironment(frames: [secure, ordinary]), policy: policy,
            recorder: TestRecorder(), journal: TestJournal())
        var updates: [String] = []
        loop.stepProgress = { updates.append($0) }
        _ = try await loop.run()
        XCTAssertEqual(updates, ["I’m handling a sensitive control carefully.",
                                 "I’m handling a sensitive control carefully."])
        XCTAssertFalse(updates.joined().contains("private-value-123"))
    }

    func testApprovalAtStepLimitFailsWithoutExecutingOrExceedingBudget() async throws {
        let target = webFrame(elements: [button(id: 1, name: "Submit")])
        let environment = TestEnvironment(frames: [target, target])
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal(), maxSteps: 1)

        guard case .pendingApproval(let approval) = try await loop.run() else {
            return XCTFail("Expected approval")
        }
        let result = try await loop.resume(approvalID: approval.id, approved: true)

        guard case .failed(let reason) = result else { return XCTFail("Expected honest step-limit failure") }
        XCTAssertTrue(reason.contains("step limit"))
        XCTAssertTrue(environment.executed.isEmpty)
        XCTAssertEqual(recorder.steps.map(\.step), [0, 1])
        XCTAssertEqual(recorder.steps.map(\.gate.decision), [.needsApproval, .rejected])
        XCTAssertEqual(recorder.steps[1].execution.status, .notExecuted)
    }

    func testApprovedOpenURLCanTransitionFromBoundAppToRequestedWebOrigin() async throws {
        let appScope = AgentScope(taskID: "task-1", kind: .app, identity: "window-start")
        let webScope = AgentScope(taskID: "task-1", kind: .web, identity: "opened-tab")
        let app = AgentFrame(observation: observation(surface: .app(bundleID: "com.example.editor", title: nil)), scope: appScope)
        let opened = webFrame(scope: webScope, url: "https://destination.example/path")
        let environment = TestEnvironment(frames: [app, app, opened])
        let policy = TestPolicy([.action(.openURL(url: "https://destination.example/path")),
                                 .action(.done(answer: "Opened"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal(), appIdentity: "com.example.editor")

        let pending = try await loop.run()
        guard case .pendingApproval(let approval) = pending else { return XCTFail("Expected destination approval") }
        XCTAssertEqual(recorder.steps.count, 1)
        XCTAssertEqual(recorder.steps[0].gate.decision, .needsApproval)
        let resumed = try await loop.resume(approvalID: approval.id, approved: true)
        XCTAssertEqual(resumed, .completed(answer: "Opened"))
        XCTAssertEqual(environment.executed.map(\.action.type), ["open_url"])
        XCTAssertEqual(recorder.steps.map(\.gate.decision), [.needsApproval, .allowed, .allowed])
        XCTAssertEqual(recorder.steps[0].rawModelOutput, "action:open_url")
        XCTAssertEqual(recorder.steps[1].rawModelOutput, "")
        XCTAssertEqual(recorder.steps[0].observation.surface, app.observation.surface)
        XCTAssertEqual(recorder.steps[1].observation.surface, app.observation.surface)
        XCTAssertEqual(recorder.steps[2].observation.surface, opened.observation.surface)
        XCTAssertEqual(recorder.footer?.outcome, "success")
        XCTAssertEqual(environment.observedScopes, [appScope, appScope, webScope])
    }

    func testOrdinaryLowRiskEffectErrorIsRecordedAndPolicyMayRecoverWithoutReplay() async throws {
        let frame = webFrame(elements: [button(id: 1, name: "Continue")])
        let environment = TestEnvironment(frames: [frame, frame],
                                          executeError: AgentEnvironmentError.unavailable("input failed"))
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Recovered"))])
        let recorder = TestRecorder()
        let journal = TestJournal()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: journal, trustedWeb: true)

        let result = try await loop.run()
        XCTAssertEqual(result, .completed(answer: "Recovered"))
        XCTAssertEqual(journal.begun.count, 1)
        XCTAssertEqual(journal.verified.count, 1)
        XCTAssertTrue(journal.uncertain.isEmpty)
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(recorder.footer?.outcome, "success")
        XCTAssertTrue(recorder.steps[0].execution.result.contains("Attempted; environment error"))
    }

    func testPixelReadbackMismatchIsRecordedAndPolicyCanRecoverWithoutReplay() async throws {
        let mismatch = AgentExecutionResult(status: .ok, result: "typed 1 char → read-back unavailable or differs")
        let environment = TestEnvironment(frames: [webFrame(), webFrame(), webFrame()],
                                          executionResult: mismatch, followsFrontmostSurface: true)
        let policy = TestPolicy([.action(.type(target: nil, text: "x", mode: .replace)),
                                 .action(.done(answer: "The follow-up observation was reviewed"))])
        let recorder = TestRecorder()
        let journal = TestJournal()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: journal, trustedWeb: true)

        let result = try await loop.run()

        XCTAssertEqual(result, .completed(answer: "The follow-up observation was reviewed"))
        XCTAssertEqual(environment.executed.map(\.action.type), ["type"])
        XCTAssertEqual(recorder.steps.count, 2)
        XCTAssertTrue(recorder.steps[0].execution.result.contains("read-back unavailable or differs"))
        XCTAssertEqual(journal.verified.count, 1)
        XCTAssertTrue(journal.uncertain.isEmpty)
    }

    func testCredentialHandoffIsRecordedNonterminalAndFeedsRejectionBackToPolicy() async throws {
        let secure = AgentElement(id: 7, role: "password", name: "Secure entry", value: nil,
                                  state: ["enabled"], bbox: .init(x: 1, y: 2, width: 40, height: 12),
                                  inView: true)
        let focus = AgentFocus(id: 7, role: "password", name: "Secure entry", valuePrefix: "",
                               selection: .init(start: 0, end: 0))
        let environment = TestEnvironment(frames: [
            webFrame(elements: [secure], focus: focus), webFrame()
        ])
        let policy = TestPolicy([.action(.type(target: nil, text: "blocked", mode: .replace)),
                                 .action(.done(answer: "Continued after owner intervention"))])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal(), trustedWeb: true)

        let handoff = try await loop.run()
        guard case .handoff(let reason) = handoff else { return XCTFail("Expected credential handoff") }
        XCTAssertTrue(reason.contains("Credentials require you to take over on your Mac"))
        XCTAssertFalse(loop.didFinish)
        XCTAssertNil(recorder.footer)
        XCTAssertEqual(recorder.steps.count, 1)
        XCTAssertEqual(recorder.steps[0].gate.decision, .rejected)
        XCTAssertEqual(recorder.steps[0].execution.status, .notExecuted)

        let resumed = try await loop.run()
        XCTAssertEqual(resumed, .completed(answer: "Continued after owner intervention"))
        XCTAssertTrue(environment.lastContext?.history.last?.result.contains("Credentials require you to take over on your Mac") == true)
        XCTAssertEqual(recorder.steps.count, 2)
        XCTAssertEqual(recorder.footer?.outcome, "success")
    }

    func testCredentialQuestionAfterRepeatedRejectionsHandsOffWithoutPendingQuestion() async throws {
        let environment = TestEnvironment(frames: [webFrame(), webFrame(), webFrame()])
        let policy = TestPolicy([.malformed("first invalid reply"), .malformed("second invalid reply"),
            .action(.askUser(question: "Please provide your password or verification code.", choices: nil))])
        let recorder = TestRecorder(), loop = try makeLoop(environment: environment, policy: policy,
            recorder: recorder, journal: TestJournal(), trustedWeb: true)
        let outcome = try await loop.run()
        guard case .handoff(let reason) = outcome else { return XCTFail("Credential solicitation must hand off") }
        XCTAssertEqual(reason, "Credentials require you to take over on your Mac; never send passwords or codes in chat.")
        XCTAssertNil(loop.pendingQuestion)
        XCTAssertTrue(environment.executed.isEmpty)
        XCTAssertEqual(recorder.steps.last?.execution.status, .notExecuted)
        do {
            _ = try await loop.resume(answer: "123456")
            XCTFail("A credential handoff must not accept a model-created clarification answer")
        } catch {
            XCTAssertEqual(error as? AgentLoopError, .noPendingQuestion)
        }
    }

    func testExecutionCredentialHandoffStopsBeforeASecondModelAction() async throws {
        let frame = webFrame(elements: [button(id: 1, name: "Continue")])
        let environment = TestEnvironment(frames: [frame, frame],
                                          executeError: AgentEnvironmentError.credentialHandoff)
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Resumed after owner handoff"))])
        let recorder = TestRecorder()
        let journal = TestJournal()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: journal, trustedWeb: true)

        let handoff = try await loop.run()
        guard case .handoff(let reason) = handoff else { return XCTFail("Expected credential handoff") }
        XCTAssertTrue(reason.contains("Credential entry requires the owner"))
        XCTAssertFalse(loop.didFinish)
        XCTAssertEqual(recorder.steps.count, 1)
        XCTAssertEqual(recorder.steps[0].execution.status, .notExecuted)
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(journal.verified.count, 1)

        let resumed = try await loop.run()
        XCTAssertEqual(resumed, .completed(answer: "Resumed after owner handoff"))
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(recorder.steps.count, 2)
    }

    func testHighRiskEnvironmentErrorIsUncertainAndNeverRetried() async throws {
        let frame = webFrame(elements: [button(id: 1, name: "Submit")])
        let environment = TestEnvironment(frames: [frame, frame, frame],
                                          executeError: AgentEnvironmentError.unavailable("input outcome unknown"))
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil)),
                                 .action(.done(answer: "Must not run after uncertain submit"))])
        let recorder = TestRecorder()
        let journal = TestJournal()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: journal, trustedWeb: true)

        guard case .pendingApproval(let approval) = try await loop.run() else {
            return XCTFail("Expected high-risk approval")
        }
        let result = try await loop.resume(approvalID: approval.id, approved: true)

        guard case .failed(let reason) = result else { return XCTFail("Expected uncertain failure") }
        XCTAssertTrue(reason.contains("uncertain"))
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(journal.uncertain.count, 1)
        XCTAssertTrue(journal.verified.isEmpty)
        XCTAssertEqual(recorder.footer?.outcome, "uncertain")
    }

    func testRecorderFailureAfterVerifiedEffectMakesLoopTerminalWithoutReplaying() async throws {
        let environment = TestEnvironment(frames: [webFrame(elements: [button(id: 1, name: "Continue")])])
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil))])
        let recorder = TestRecorder()
        recorder.failRecords = true
        let journal = TestJournal()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: journal, trustedWeb: true)

        do {
            _ = try await loop.run()
            XCTFail("A durable recording failure must fail closed")
        } catch { XCTAssertTrue(error is AgentLoopError) }
        XCTAssertTrue(loop.didFinish)
        XCTAssertEqual(journal.verified.count, 1)
        XCTAssertTrue(journal.uncertain.isEmpty)
        XCTAssertEqual(environment.executed.count, 1)
        guard case .failed = try await loop.run() else { return XCTFail("Failed loop must remain terminal") }
        XCTAssertEqual(environment.executed.count, 1)
        XCTAssertEqual(recorder.footer?.outcome, "failed")
    }

    func testFooterPersistenceFailureStillStopsServicesAndTerminalizesLoop() async throws {
        let environment = TestEnvironment(frames: [webFrame()])
        let policy = TestPolicy([.action(.done(answer: "Finished"))])
        let recorder = TestRecorder()
        recorder.failFinish = true
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal())

        do {
            _ = try await loop.run()
            XCTFail("A footer persistence failure must be surfaced")
        } catch { XCTAssertTrue(error is AgentLoopError) }
        XCTAssertTrue(loop.didFinish)
        XCTAssertEqual(environment.stopCount, 1)
        XCTAssertEqual(policy.stopCount, 1)
        guard case .failed = try await loop.run() else { return XCTFail("Loop must remain terminal after footer failure") }
    }

    func testPauseDuringEffectWaitsForStopAndMakesStartedEffectUncertain() async throws {
        let environment = TestEnvironment(frames: [webFrame(elements: [button(id: 1, name: "Continue")])],
                                          blockExecution: true)
        let policy = TestPolicy([.action(.click(target: .element(id: 1), button: nil, count: nil))])
        let journal = TestJournal()
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: journal, trustedWeb: true)
        let run = Task { try await loop.run() }
        while !environment.executionStarted { await Task.yield() }
        await loop.pause()

        guard case .failed = try await run.value else { return XCTFail("An uncertain effect must terminate") }
        XCTAssertEqual(environment.suspendCount, 1)
        XCTAssertEqual(journal.begun.count, 1)
        XCTAssertEqual(journal.uncertain.count, 1)
        XCTAssertEqual(recorder.footer?.outcome, "uncertain")
        let resumed = try await loop.resume()
        guard case .failed = resumed else { return XCTFail("Uncertain action must remain terminal") }
        XCTAssertEqual(environment.executed.count, 1)
    }

    func testCancellationIgnoringPolicyCannotExecuteItsLateInput() async throws {
        let environment = TestEnvironment(frames: [webFrame(elements: [button(id: 1, name: "Continue")])])
        let policy = LateOutputPolicy(.click(target: .element(id: 1), button: nil, count: nil))
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal(), trustedWeb: true)

        let run = Task { try await loop.run() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !policy.proposalStarted, ContinuousClock.now < deadline { await Task.yield() }
        guard policy.proposalStarted else {
            run.cancel()
            _ = try? await run.value
            XCTFail("The fake policy did not enter its in-flight proposal")
            return
        }

        let cancellation = Task { try await loop.cancel() }
        let result = try await cancellation.value
        let runResult = try await run.value

        guard case .cancelled = result else { return XCTFail("Stop did not cancel the loop") }
        guard case .cancelled = runResult else { return XCTFail("The in-flight run did not cancel") }
        XCTAssertTrue(loop.didFinish)
        XCTAssertEqual(recorder.footer?.outcome, "cancelled")
        XCTAssertEqual(environment.executed.count, 0,
            "A policy that returns an input after Stop must be fenced before environment execution")
        XCTAssertEqual(policy.stopCount, 1)
    }

    func testMaximumLoopBudgetClampsLegacyFortyStepRequestsToThirty() throws {
        let loop = try makeLoop(environment: TestEnvironment(frames: [webFrame()]),
            policy: TestPolicy([]), recorder: TestRecorder(), journal: TestJournal(), maxSteps: 40)
        XCTAssertEqual(loop.maxSteps, 30)
    }

    func testRepeatedDeniedFingerprintDeflectsTwiceThenBlocksWithoutReapproval() async throws {
        let frame = webFrame(elements: [button(id: 1, name: "Submit")])
        let action = AgentAction.click(target: .element(id: 1), button: nil, count: nil)
        let environment = TestEnvironment(frames: Array(repeating: frame, count: 5))
        let policy = TestPolicy([.action(action), .action(action), .action(action), .action(action)])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal())

        guard case .pendingApproval(let approval) = try await loop.run() else {
            return XCTFail("Expected the initial approval")
        }
        guard case .pendingApproval(let sameApproval) = try await loop.run() else {
            return XCTFail("A repeated run must return the same pending approval")
        }
        XCTAssertEqual(sameApproval.id, approval.id)
        let result = try await loop.resume(approvalID: approval.id, approved: false)

        guard case .failed(let reason) = result else {
            return XCTFail("The third repeated proposal must end the task as blocked")
        }
        XCTAssertEqual(reason, "BLOCKED: declined")
        XCTAssertEqual(recorder.footer?.outcome, "blocked: declined")
        XCTAssertEqual(recorder.steps.map(\.gate.decision),
                       [.needsApproval, .rejected, .rejected, .rejected, .rejected])
        XCTAssertEqual(recorder.steps.filter { $0.gate.decision == .needsApproval }.count, 1)
        XCTAssertTrue(recorder.steps.allSatisfy { $0.gate.fingerprint == approval.fingerprint })
        XCTAssertEqual(recorder.steps[1].gate.reason, "rejected: user declined")
        XCTAssertEqual(recorder.steps[1].execution.status, .notExecuted)
        XCTAssertTrue(recorder.steps[2].gate.reason.contains("owner declined"))
        XCTAssertTrue(recorder.steps[3].gate.reason.contains("owner declined"))
        XCTAssertEqual(recorder.steps[4].gate.reason, "BLOCKED: declined")
        XCTAssertTrue(environment.executed.isEmpty)
    }

    func testDifferentFingerprintAfterDenialStillUsesNormalApprovalGate() async throws {
        let first = AgentAction.click(target: .element(id: 1), button: nil, count: nil)
        let second = AgentAction.click(target: .element(id: 2), button: nil, count: nil)
        let frame = webFrame(elements: [button(id: 1, name: "Submit"), button(id: 2, name: "Continue")])
        let environment = TestEnvironment(frames: [frame, frame, frame])
        let policy = TestPolicy([.action(first), .action(second)])
        let recorder = TestRecorder()
        let loop = try makeLoop(environment: environment, policy: policy, recorder: recorder,
                                journal: TestJournal())

        guard case .pendingApproval(let firstApproval) = try await loop.run() else {
            return XCTFail("Expected the initial approval")
        }
        guard case .pendingApproval(let secondApproval) = try await loop.resume(
            approvalID: firstApproval.id, approved: false) else {
            return XCTFail("An unrelated fingerprint should still request approval")
        }

        XCTAssertNotEqual(firstApproval.fingerprint, secondApproval.fingerprint)
        XCTAssertEqual(secondApproval.action, second)
        XCTAssertEqual(recorder.steps.map(\.gate.decision), [.needsApproval, .rejected, .needsApproval])
        XCTAssertTrue(environment.executed.isEmpty)
    }

    private func makeLoop(environment: TestEnvironment, policy: any AgentPolicy, recorder: TestRecorder,
                          journal: TestJournal, trustedWeb: Bool = false,
                          appIdentity: String? = nil, maxSteps: Int = 40) throws -> AgentLoop {
        let store = TestTrustStore(trustedWeb: trustedWeb)
        let allowPolicy = TestAllowPolicy(appIdentity: appIdentity)
        return try AgentLoop(taskID: "task-1", prompt: "Complete a generic task", maxSteps: maxSteps,
                             environment: environment,
                             policy: policy, gate: AgentActionGate(trustStore: store, allowPolicy: allowPolicy),
                             recorder: recorder, journal: journal)
    }

    private func webFrame(scope: AgentScope = AgentScope(taskID: "task-1", kind: .web, identity: "tab-1"),
                          url: String = "https://example.test/", elements: [AgentElement] = [],
                          focus: AgentFocus? = nil) -> AgentFrame {
        AgentFrame(observation: observation(surface: .web(url: url, title: "Example"),
                                            elements: elements, focus: focus), scope: scope)
    }

    private func observation(surface: AgentSurface, elements: [AgentElement] = [],
                             focus: AgentFocus? = nil) -> AgentObservation {
        AgentObservation(task: "Complete a generic task", surface: surface, screenshot: "", elements: elements,
                         focus: focus, history: [], budget: .init(step: 0, maxSteps: 40))
    }

    private func button(id: Int, name: String) -> AgentElement {
        AgentElement(id: id, role: "button", name: name, value: nil, state: ["enabled"],
                     bbox: .init(x: 1, y: 2, width: 40, height: 12), inView: true)
    }
}

@MainActor
private final class TestPolicy: AgentPolicy {
    enum Reply { case action(AgentAction), malformed(String), output(AgentPolicyOutput) }
    let promptVersion = "test-v1"
    private var replies: [Reply]
    private(set) var observations: [AgentObservation] = []
    private(set) var stopCount = 0
    init(_ replies: [Reply]) { self.replies = replies }
    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        observations.append(observation)
        guard !replies.isEmpty else { return .init(rawOutput: "", action: nil, rejectionReason: "No reply") }
        switch replies.removeFirst() {
        case .action(let action): return .init(rawOutput: "action:\(action.type)", action: action, rejectionReason: nil)
        case .malformed(let raw): return .init(rawOutput: raw, action: nil, rejectionReason: "Invalid output")
        case .output(let output): return output
        }
    }
    func stop() async { stopCount += 1 }
}

@MainActor
private final class LateOutputPolicy: AgentPolicy {
    let promptVersion = "late-output-test"
    private let output: AgentPolicyOutput
    private var continuation: CheckedContinuation<AgentPolicyOutput, Never>?
    private(set) var proposalStarted = false
    private(set) var stopCount = 0

    init(_ action: AgentAction) {
        output = .init(rawOutput: "late action", action: action, rejectionReason: nil)
    }

    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        proposalStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func stop() async {
        stopCount += 1
        continuation?.resume(returning: output)
        continuation = nil
    }
}

@MainActor
private final class TestEnvironment: AgentEnvironment {
    private let frames: [AgentFrame]
    private let executeError: Error?
    private let executionResult: AgentExecutionResult?
    private let blockExecution: Bool
    var followsFrontmostSurface: Bool
    private var continuation: CheckedContinuation<AgentExecutionResult, Error>?
    private var observeIndex = 0
    private(set) var executed: [AgentResolvedAction] = []
    private(set) var observedScopes: [AgentScope] = []
    private(set) var stopCount = 0
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var executionStarted = false
    private(set) var lastContext: AgentObservationContext?

    init(frames: [AgentFrame], executeError: Error? = nil, executionResult: AgentExecutionResult? = nil,
         blockExecution: Bool = false,
         followsFrontmostSurface: Bool = false) {
        self.frames = frames; self.executeError = executeError; self.executionResult = executionResult
        self.blockExecution = blockExecution
        self.followsFrontmostSurface = followsFrontmostSurface
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        lastContext = context
        let source = frames[min(observeIndex, frames.count - 1)]
        observeIndex += 1; observedScopes.append(source.scope)
        let frameObservation = source.observation
        let observation = AgentObservation(task: context.task, surface: frameObservation.surface,
            screenshot: frameObservation.screenshot, elements: frameObservation.elements,
            focus: frameObservation.focus, history: context.history, budget: context.budget)
        return AgentFrame(observation: observation, scope: source.scope)
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        if case let .click(target, _, _) = action, case let .element(id) = target {
            guard let element = frame.observation.elements.first(where: { $0.id == id }) else {
                throw AgentEnvironmentError.targetGone
            }
            return AgentResolvedAction(action: action, frame: frame, targets: [element])
        }
        return AgentResolvedAction(action: action, frame: frame, targets: [])
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        executionStarted = true
        executed.append(resolved)
        if blockExecution {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        if let executeError { throw executeError }
        if let executionResult { return executionResult }
        return .init(status: .ok, result: "Executed")
    }

    func stop() async {
        stopCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func suspend() async {
        suspendCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func resume() async throws { resumeCount += 1 }
}

@MainActor
private final class TestRecorder: AgentRecording {
    private(set) var steps: [AgentEpisodeStep] = []
    private(set) var footer: AgentEpisodeFooter?
    private(set) var finishCount = 0
    var failRecords = false
    var failFinish = false
    func record(_ step: AgentEpisodeStep) throws {
        if failRecords { throw AgentEnvironmentError.unavailable("recorder failure") }
        steps.append(step)
    }
    func finish(_ footer: AgentEpisodeFooter) throws {
        finishCount += 1
        if failFinish { throw AgentEnvironmentError.unavailable("footer failure") }
        self.footer = footer
    }
}

@MainActor
private final class TestJournal: AgentEffectJournaling {
    private(set) var begun: [(Int, String)] = []
    private(set) var verified: [(Int, String)] = []
    private(set) var uncertain: [(Int, String)] = []
    func begin(step: Int, fingerprint: String) throws { begun.append((step, fingerprint)) }
    func verify(step: Int, fingerprint: String) throws { verified.append((step, fingerprint)) }
    func markUncertain(step: Int, fingerprint: String) throws { uncertain.append((step, fingerprint)) }
    func assertMayContinue() throws {}
}

@MainActor
private final class TestTrustStore: AgentTrustStore {
    private var trustedWeb: Bool
    init(trustedWeb: Bool) { self.trustedWeb = trustedWeb }
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool {
        kind == .web && trustedWeb
    }
    func markTrusted(kind: AgentScope.Kind, identity: String) throws {
        if kind == .web { trustedWeb = true }
    }
}

@MainActor
private final class TestAllowPolicy: AgentAllowPolicy {
    private let appIdentity: String?
    init(appIdentity: String?) { self.appIdentity = appIdentity }
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? {
        guard case .openApp = action, let appIdentity else { return nil }
        return AgentTrustIdentity(kind: .app, identity: appIdentity)
    }
}
