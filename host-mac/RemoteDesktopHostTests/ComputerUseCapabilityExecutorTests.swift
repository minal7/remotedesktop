import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
private final class RoutingResearchFixture: ComputerUseBrowserResearchExecuting {
    var preparesOwner = true
    var admissionResult: ComputerUseExecutionResult? = .userInterventionRequired("Fixture handback")
    var beforeAdmissionReturn: (@MainActor (ComputerUseBrowserResearchTask?) async throws -> Void)?
    private(set) var owner: ComputerUseBrowserResearchTask?
    private(set) var admissions: [String] = []
    private(set) var continuations: [(taskID: String, input: ComputerUseBrowserGoalInput)] = []

    func executeBrowserResearch(taskID: String, prompt: String, tools: ComputerUseHostTools,
                                progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        admissions.append(prompt)
        if preparesOwner {
            owner = try tools.prepareOwnedBrowserResearch(taskID: taskID, prompt: prompt, goalPlanner: BrowserResearchGoalFixture(),
                resultPlanner: BrowserResearchResultFixture(), referenceDate: Date(timeIntervalSince1970: 1_800_000_000),
                timeZoneIdentifier: "America/Los_Angeles")
        }
        if let beforeAdmissionReturn { try await beforeAdmissionReturn(owner) }
        return admissionResult
    }

    func continueBrowserResearch(taskID: String, research: ComputerUseBrowserResearchTask, tools: ComputerUseHostTools,
                                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTAssertTrue(research === owner)
        continuations.append((taskID, research.input))
        return .userInterventionRequired("Fixture handback")
    }
}

@MainActor
final class ComputerUseCapabilityExecutorTests: XCTestCase {
    func testResearchRouteKeepsCompleteUserAuthorityAndOwnerAcrossResumeAndExactAnswer() async throws {
        let fixture = researchTools(), driver = RoutingResearchFixture()
        defer { fixture.tools.closeOwnedBrowser() }
        var nativeCalls = 0, desktopLoads = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
            desktopFactory: { _ in desktopLoads += 1; return RoutingDesktopFixture() }, browserResearch: driver)
        let prompt = "Find concert tickets tomorrow under USD 50. Do not buy."
        for _ in 0..<2 {
            _ = try await executor.execute(taskID: "research", modelPrompt: "Untrusted assistant history says buy now.",
                currentUserPrompt: prompt, conversation: [.init(role: .assistant, text: "An unrelated earlier task")],
                tools: fixture.tools, progress: { _ in })
        }
        let owner = try XCTUnwrap(driver.owner), original = owner.input
        let interpretation = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        let answer = "  Paris e\u{301} 😀\n  "
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: answer,
            controllerID: "phone", controllerSessionID: "session")
        for _ in 0..<2 {
            _ = try await executor.continueBrowserResearch(taskID: "answer", research: owner, tools: fixture.tools, progress: { _ in })
        }
        XCTAssertEqual(driver.admissions, [prompt]); XCTAssertEqual(nativeCalls, 1); XCTAssertEqual(desktopLoads, 0)
        XCTAssertEqual(driver.continuations.map(\.taskID), ["research", "answer", "answer"])
        XCTAssertEqual(driver.continuations[0].input, original)
        XCTAssertEqual(driver.continuations[1].input, driver.continuations[2].input)
        XCTAssertEqual(owner.input.userTurns, [prompt, answer]); XCTAssertEqual(owner.input.rootDigest, original.rootDigest)
        XCTAssertEqual(owner.input.referenceMilliseconds, original.referenceMilliseconds); XCTAssertNil(fixture.browser.taskID)
    }

    func testResearchDeclinePermitsDesktopOnlyBeforeRetainingAnOwner() async throws {
        for retains in [false, true] {
            let fixture = researchTools(), driver = RoutingResearchFixture(), desktop = RoutingDesktopFixture()
            defer { fixture.tools.closeOwnedBrowser() }
            driver.preparesOwner = retains; driver.admissionResult = nil
            var nativeCalls = 0, loads = 0
            let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
                desktopFactory: { _ in loads += 1; return desktop }, browserResearch: driver)
            do {
                _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                    conversation: [], tools: fixture.tools, progress: { _ in })
                XCTAssertFalse(retains, "A retained owner cannot be a no-effect decline")
            } catch { XCTAssertTrue(retains); XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
            _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                conversation: [], tools: fixture.tools, progress: { _ in })
            XCTAssertEqual(driver.admissions.count, 1); XCTAssertEqual(nativeCalls, 1)
            XCTAssertEqual(driver.continuations.count, retains ? 1 : 0); XCTAssertEqual(loads, retains ? 0 : 1)
            XCTAssertEqual(desktop.taskIDs.count, retains ? 0 : 2)
        }
    }

    func testResearchAdmissionErrorsRetainRouteAndPreparedOwnerWithoutNativeReplay() async throws {
        for prepares in [false, true] {
            let fixture = researchTools(), driver = RoutingResearchFixture()
            defer { fixture.tools.closeOwnedBrowser() }
            driver.preparesOwner = prepares
            driver.beforeAdmissionReturn = { _ in throw ComputerUseBrowserError.pageChanged }
            var nativeCalls = 0, loads = 0
            let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
                desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() }, browserResearch: driver)
            do {
                _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                    conversation: [], tools: fixture.tools, progress: { _ in })
                XCTFail("An admission error is not a decline")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            let firstOwner = driver.owner
            driver.preparesOwner = true; driver.beforeAdmissionReturn = nil
            _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                conversation: [], tools: fixture.tools, progress: { _ in })
            XCTAssertEqual(nativeCalls, 1); XCTAssertEqual(loads, 0)
            XCTAssertEqual(driver.admissions.count, prepares ? 1 : 2); XCTAssertEqual(driver.continuations.count, prepares ? 1 : 0)
            if prepares { XCTAssertTrue(driver.owner === firstOwner) }
        }
    }

    func testResearchAdmissionCancellationPauseAndRetirementHoldRouteUntilDriverReturns() async throws {
        for interruption in ["cancel", "pause", "retire"] {
            let fixture = researchTools(), driver = RoutingResearchFixture(), gate = BrowserResearchGate()
            defer { gate.release(); fixture.tools.closeOwnedBrowser() }
            driver.beforeAdmissionReturn = { _ in await gate.suspend() }
            var nativeCalls = 0, loads = 0
            let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
                desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() }, browserResearch: driver)
            let running = Task { try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                conversation: [], tools: fixture.tools, progress: { _ in }) }
            try await gate.waitUntilStarted()
            let owner = try XCTUnwrap(driver.owner)
            if interruption == "cancel" { running.cancel() }
            else if interruption == "pause" { owner.pause() }
            else { owner.retire() }
            do {
                _ = try await executor.execute(taskID: "competing", modelPrompt: "context", currentUserPrompt: "Other goal.",
                    conversation: [], tools: fixture.tools, progress: { _ in })
                XCTFail("The cancelled delegate has not returned")
            } catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .alreadyExecuting) }
            gate.release()
            do { _ = try await running.value; XCTFail("A late driver result cannot escape interruption") }
            catch {
                if interruption == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, interruption == "pause" ? .paused : .retired) }
            }
            driver.beforeAdmissionReturn = nil
            if interruption == "pause" { try await owner.resumeAfterUserControl() }
            do {
                _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                    conversation: [], tools: fixture.tools, progress: { _ in })
                XCTAssertNotEqual(interruption, "retire")
            } catch { XCTAssertEqual(interruption, "retire"); XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
            XCTAssertEqual(nativeCalls, 1); XCTAssertEqual(loads, 0); XCTAssertEqual(driver.admissions.count, 1)
            XCTAssertEqual(driver.continuations.count, interruption == "retire" ? 0 : 1)
        }
    }

    func testResearchPreparationCannotDisappearAndAuthorizeFallbackOrReadmission() async throws {
        for mode in ["closed-decline", "closed-result", "replaced"] {
            let fixture = researchTools(), driver = RoutingResearchFixture()
            defer { fixture.tools.closeOwnedBrowser() }
            driver.admissionResult = mode == "closed-result" ? .userInterventionRequired("Late result") : nil
            driver.beforeAdmissionReturn = { _ in
                if mode == "replaced" {
                    _ = try fixture.tools.prepareOwnedBrowserResearch(taskID: "replacement", prompt: "A different request",
                        goalPlanner: BrowserResearchGoalFixture(), resultPlanner: BrowserResearchResultFixture())
                } else { fixture.tools.closeOwnedBrowser() }
            }
            var nativeCalls = 0, loads = 0
            let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
                desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() }, browserResearch: driver)
            for _ in 0..<2 {
                do {
                    _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                        conversation: [], tools: fixture.tools, progress: { _ in })
                    XCTFail("Loss of a prepared owner is not a no-effect decline or a fresh admission")
                } catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
            }
            XCTAssertEqual(driver.admissions.count, 1); XCTAssertTrue(driver.continuations.isEmpty)
            XCTAssertEqual(nativeCalls, 1); XCTAssertEqual(loads, 0)
        }
    }

    func testResearchContinuationRejectsForeignOwnersSkippedAnswersAndRetiredRoots() async throws {
        let fixture = researchTools(), driver = RoutingResearchFixture()
        defer { fixture.tools.closeOwnedBrowser() }
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil }, browserResearch: driver)
        _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
            conversation: [], tools: fixture.tools, progress: { _ in })
        let owner = try XCTUnwrap(driver.owner)
        let foreign = ComputerUseBrowserResearchTask(input: owner.input, browser: fixture.browser, goalPlanner: BrowserResearchGoalFixture(),
            resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
        for (id, candidate) in [("research", foreign), ("foreign", owner)] {
            do { _ = try await executor.continueBrowserResearch(taskID: id, research: candidate, tools: fixture.tools, progress: { _ in }); XCTFail("Reject a foreign continuation") }
            catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
        }
        for index in 1...2 {
            let interpretation = try await owner.interpretGoal()
            let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id],
                controllerID: "phone", controllerSessionID: "session")
            _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer-\(index)", answer: "Paris",
                controllerID: "phone", controllerSessionID: "session")
        }
        do { _ = try await executor.continueBrowserResearch(taskID: "answer-2", research: owner, tools: fixture.tools, progress: { _ in }); XCTFail("Do not skip an unobserved answer revision") }
        catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .taskChanged) }
        XCTAssertTrue(driver.continuations.isEmpty)
        _ = try await executor.execute(taskID: "new-root", modelPrompt: "context", currentUserPrompt: "Find movie tickets.",
            conversation: [], tools: fixture.tools, progress: { _ in })
        do { _ = try await owner.interpretGoal(); XCTFail("A new root must retire the old delegate owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        do { _ = try await executor.continueBrowserResearch(taskID: "answer-2", research: owner, tools: fixture.tools, progress: { _ in }); XCTFail("The old root cannot acquire the new route") }
        catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
    }

    func testResearchRouteRejectsMissingOwnersAndUnrelatedQuestionOrApprovalResults() async throws {
        let request = ComputerUseBrowserQuestionRequest(taskID: "foreign", inputDigest: "foreign", topic: .location, requirementIDs: [])
        let unsupported: [ComputerUseExecutionResult] = [.completed("Unsupported success without source evidence"),
            .browserClarificationRequired(request), .clarificationRequired("An unscoped question"),
            .approvalRequired(message: "wrong route", action: .typeText("unrelated"), continuation: .init(taskID: "research", nonce: UUID()))]
        for result in unsupported {
            let fixture = researchTools(), driver = RoutingResearchFixture()
            defer { fixture.tools.closeOwnedBrowser() }
            driver.admissionResult = result
            let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil }, browserResearch: driver)
            do {
                _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                    conversation: [], tools: fixture.tools, progress: { _ in }); XCTFail("Research results require the current owner's typed evidence")
            } catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
        }
        let driver = RoutingResearchFixture()
        driver.preparesOwner = false
        let missingOwner = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil }, browserResearch: driver)
        do {
            _ = try await missingOwner.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                conversation: [], tools: tools(), progress: { _ in }); XCTFail("A claimed research result requires its retained owner")
        } catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
        for fromDesktop in [false, true] {
            let desktop = RoutingDesktopFixture(); desktop.result = .browserClarificationRequired(request)
            let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in fromDesktop ? nil : .browserClarificationRequired(request) },
                desktopFactory: { _ in desktop })
            do {
                _ = try await executor.execute(taskID: "research", modelPrompt: "context", currentUserPrompt: "Find tickets.",
                    conversation: [], tools: tools(), progress: { _ in }); XCTFail("Research questions must originate in the retained research route")
            } catch { XCTAssertEqual(error as? ComputerUseCapabilityExecutor.RoutingError, .missingContinuation) }
        }
    }

    private func researchTools() -> (tools: ComputerUseHostTools, browser: ComputerUseOwnedBrowser) {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let navigation = ComputerUseBrowserNavigationTask(browser: browser,
            journalDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (.init(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation), browser)
    }

    func testMacToolsReadinessDoesNotPretendVisualControlIsInstalled() async throws {
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil })
        executor.setDesktopFactory(includesVisualControl: false) { _ in RoutingDesktopFixture() }
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.hasAdditionalSetup)
        XCTAssertTrue(executor.readyDetail.contains("Mac tools are ready"))
        XCTAssertTrue(executor.readyDetail.contains("visual control needs setup"))
        let result = try await executor.execute(taskID: "structured", prompt: "Use a Mac tool",
            trustedUserPrompt: "Use a Mac tool", tools: tools(), progress: { _ in })
        XCTAssertEqual(result, .completed("fixture"))
        executor.setDesktopFactory { _ in RoutingDesktopFixture() }
        XCTAssertFalse(executor.hasAdditionalSetup)
    }

    func testDeferredVisualRetainsTypedTaskAndContinuationWithoutReloading() async throws {
        var loads = 0
        let actual = RoutingDesktopFixture()
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in loads += 1; return actual })
        XCTAssertTrue(deferred.isReady)
        XCTAssertEqual(loads, 0)
        let conversation = [ComputerUseConversationTurn(role: .assistant, text: "Earlier model context")]
        for _ in 0..<2 {
            _ = try await deferred.execute(taskID: "visual", modelPrompt: "Full model context", currentUserPrompt: "Current goal",
                conversation: conversation, tools: tools(), progress: { _ in })
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(actual.taskIDs, ["visual", "visual"])
        XCTAssertEqual(actual.trustedPrompts, ["Current goal", "Current goal"])
        XCTAssertEqual(actual.conversations, [conversation, conversation])
        let continuation = ComputerUseVisualApprovalContinuation(taskID: "visual", nonce: UUID())
        let result = try await deferred.continueAfterApprovedVisualAction(continuation,
            action: .typeText("value"), tools: tools(), progress: { _ in })
        XCTAssertEqual(result, .completed("continued"))
        XCTAssertEqual(actual.visualContinuations, [continuation])
        XCTAssertEqual(loads, 1)
        do {
            _ = try await deferred.continueAfterApprovedVisualAction(.init(taskID: "other", nonce: UUID()),
                action: .typeText("value"), tools: tools(), progress: { _ in })
            XCTFail("A continuation from another task cannot acquire the loaded executor")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        XCTAssertEqual(actual.visualContinuations, [continuation])
    }

    func testMissingOrCancelledDeferredVisualCannotExecuteOrCreateContinuation() async throws {
        let unavailable = ComputerUseDeferredVisualExecutor()
        XCTAssertFalse(unavailable.isReady)
        let result = try await unavailable.execute(taskID: "missing", prompt: "A visual task",
            trustedUserPrompt: "A visual task", tools: tools(), progress: { _ in })
        guard case .unableToComplete = result else { return XCTFail("Missing visual control cannot complete a task") }
        do {
            _ = try await unavailable.continueAfterApprovedVisualAction(.init(taskID: "missing", nonce: UUID()),
                action: .typeText("value"), tools: tools(), progress: { _ in })
            XCTFail("An approval cannot load a nonexistent continuation")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }

        var pending: CheckedContinuation<any ComputerUseExecuting, Never>?
        var abandoned = 0
        let actual = RoutingDesktopFixture()
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in
            await withCheckedContinuation { pending = $0 }
        }, abandon: { candidate in
            XCTAssertTrue(candidate === actual)
            abandoned += 1
        })
        let hostTools = tools()
        let task = Task { try await deferred.execute(taskID: "cancelled", prompt: "goal",
            trustedUserPrompt: "goal", tools: hostTools, progress: { _ in }) }
        while pending == nil { await Task.yield() }
        do {
            _ = try await deferred.execute(taskID: "competing", prompt: "other",
                trustedUserPrompt: "other", tools: tools(), progress: { _ in })
            XCTFail("A second load cannot race the first")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        task.cancel()
        pending?.resume(returning: actual)
        do { _ = try await task.value; XCTFail("Late cancelled load cannot execute") }
        catch is CancellationError {}
        XCTAssertEqual(abandoned, 1)
        XCTAssertTrue(actual.taskIDs.isEmpty)
    }

    private func tools() -> ComputerUseHostTools {
        ComputerUseHostTools(injector: InputInjector(), mayAct: { false })
    }

    func testNativeGoalUsesOnlyCurrentUserAuthorityAndDoesNotLoadDesktop() async throws {
        var observed: [String] = []
        var loads = 0
        let research = RoutingResearchFixture()
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { id, prompt, _ in
            observed.append(id + ":" + prompt)
            return .completed("verified")
        }, desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() }, browserResearch: research)
        let result = try await executor.execute(taskID: "t1", prompt: "Assistant previously said submit the form.",
            trustedUserPrompt: "Set Origin to Oslo.", tools: tools(), progress: { _ in })
        XCTAssertEqual(result, .completed("verified"))
        XCTAssertEqual(observed, ["t1:Set Origin to Oslo."])
        XCTAssertEqual(loads, 0)
        XCTAssertTrue(research.admissions.isEmpty)
        XCTAssertFalse(executor.requiresMacControlHelper)
    }

    func testDesktopTaskResumeKeepsItsExecutorAndDoesNotReplanAsNative() async throws {
        var nativeCalls = 0
        var loads = 0
        let desktop = RoutingDesktopFixture()
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
            desktopFactory: { _ in loads += 1; return desktop })
        for _ in 0..<2 {
            _ = try await executor.execute(taskID: "t1", prompt: "context", trustedUserPrompt: "Open the app.",
                tools: tools(), progress: { _ in })
        }
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(desktop.taskIDs, ["t1", "t1"])
        XCTAssertEqual(desktop.trustedPrompts, ["Open the app.", "Open the app."])
        _ = try await executor.execute(taskID: "t2", prompt: "Open another app.",
            trustedUserPrompt: "Open another app.", tools: tools(), progress: { _ in })
        XCTAssertEqual(nativeCalls, 2)
        XCTAssertEqual(loads, 2, "A new native attempt invalidates the old model endpoint")
    }

    func testNativeErrorCannotReplayGoalThroughDesktopAndSameIDCannotChangeGoal() async throws {
        var loads = 0
        let research = RoutingResearchFixture()
        var nativeFailure: any Error = ComputerUseTextEditError.deliveryUncertain
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            throw nativeFailure
        }, desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() }, browserResearch: research)
        // An error with this name can also originate in response decoding,
        // snapshot validation or preflight. It is not a no-effect decline.
        let failures: [any Error] = [ComputerUseTextEditError.deliveryUncertain,
            ComputerUseBrowserError.unsupportedDocument, ComputerUseBrowserError.pageChanged]
        for failure in failures {
            nativeFailure = failure
            do {
                _ = try await executor.execute(taskID: "t1", prompt: "text", trustedUserPrompt: "Append x.",
                    tools: tools(), progress: { _ in })
                XCTFail("A native error must not fall back")
            } catch {
                if let expected = failure as? ComputerUseTextEditError { XCTAssertEqual(error as? ComputerUseTextEditError, expected) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, failure as? ComputerUseBrowserError) }
            }
        }
        do {
            _ = try await executor.execute(taskID: "t1", prompt: "new", trustedUserPrompt: "Append y.",
                tools: tools(), progress: { _ in })
            XCTFail("A retained task cannot change meaning")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        XCTAssertEqual(loads, 0)
        XCTAssertTrue(research.admissions.isEmpty)
    }

    func testMissingDesktopDoesNotDisableNativeReadinessOrClaimUnsupportedCompletion() async throws {
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil })
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.hasAdditionalSetup)
        let result = try await executor.execute(taskID: "t1", prompt: "Open an app.",
            trustedUserPrompt: "Open an app.", tools: tools(), progress: { _ in })
        guard case .unableToComplete = result else { return XCTFail("Missing capability must not complete") }
        executor.setDesktopFactory { _ in RoutingDesktopFixture() }
        XCTAssertFalse(executor.hasAdditionalSetup)
    }

    func testCancelledDesktopLoadCannotExecuteAndReleasesReturnedHelper() async throws {
        var pending: CheckedContinuation<any ComputerUseExecuting, Never>?
        let desktop = RoutingDesktopFixture()
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil },
            desktopFactory: { _ in await withCheckedContinuation { pending = $0 } })
        let hostTools = tools()
        let request = Task { try await executor.execute(taskID: "cancel-load", prompt: "Open an app.",
            trustedUserPrompt: "Open an app.", tools: hostTools, progress: { _ in }) }
        while pending == nil { await Task.yield() }
        request.cancel()
        pending?.resume(returning: desktop)
        do { _ = try await request.value; XCTFail("A cancelled load must not begin execution") }
        catch is CancellationError {}
        XCTAssertTrue(desktop.taskIDs.isEmpty)
        XCTAssertEqual(desktop.cancellations, 1)
    }

    func testConcurrentTaskIsRejectedAndCancelledNativeResultCannotComplete() async throws {
        var pending: CheckedContinuation<ComputerUseExecutionResult?, Never>?
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        })
        let hostTools = tools()
        let first = Task { try await executor.execute(taskID: "first", prompt: "edit",
            trustedUserPrompt: "edit", tools: hostTools, progress: { _ in }) }
        while pending == nil { await Task.yield() }
        do {
            _ = try await executor.execute(taskID: "second", prompt: "edit", trustedUserPrompt: "edit",
                tools: hostTools, progress: { _ in })
            XCTFail("Concurrent routes could race field edits and model ownership")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        first.cancel()
        pending?.resume(returning: .completed("late result"))
        do { _ = try await first.value; XCTFail("A late result cannot override cancellation") }
        catch is CancellationError {}
    }
}

@MainActor
private final class RoutingDesktopFixture: ComputerUseExecuting, MCPApprovalContinuing, ComputerUseVisualApprovalContinuing {
    let isReady = true
    let runtimeName = "fixture"
    var cancellations = 0
    var result: ComputerUseExecutionResult = .completed("fixture")
    func cancelMCPWork() { cancellations += 1 }
    func continueAfterApproval(_ prepared: MCPPreparedApproval, tools: ComputerUseHostTools,
                              progress: @escaping (String) -> Void) async throws -> MCPApprovedActionResult {
        throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation
    }
    var taskIDs: [String] = []
    var trustedPrompts: [String] = []
    var conversations: [[ComputerUseConversationTurn]] = []
    var visualContinuations: [ComputerUseVisualApprovalContinuation] = []
    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        conversations.append(conversation)
        return try await execute(taskID: taskID, prompt: modelPrompt, trustedUserPrompt: currentUserPrompt,
                                 tools: tools, progress: progress)
    }
    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        visualContinuations.append(continuation)
        return .completed("continued")
    }
    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {}
    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTFail("The typed task boundary must be retained")
        return .unableToComplete("unexpected entry point")
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        taskIDs.append(taskID)
        trustedPrompts.append(trustedUserPrompt)
        return result
    }
}
