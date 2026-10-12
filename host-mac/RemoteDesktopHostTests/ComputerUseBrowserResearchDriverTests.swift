import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchDriverTests: XCTestCase {
    func testDriverResearchStartsAfterSixAnswersWithoutReplacingTheRoot() async throws {
        try await verifyLongQuestionConversation(answerCount: 6, finish: true)
    }

    func testDriverRetainsTheFullRequestWhenQuestionCapacityIsExhausted() async throws {
        try await verifyLongQuestionConversation(answerCount: ComputerUseBrowserGoalInput.maximumUserTurns - 1, finish: false)
    }

    private func verifyLongQuestionConversation(answerCount: Int, finish: Bool) async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.goal.base.questionTopic = .location
        let started = try await fixture.start()
        var result = try XCTUnwrap(started)
        let owner = try fixture.owner(), original = owner.input
        var answers: [String] = []
        for index in 1...answerCount {
            guard case .browserClarificationRequired(let request) = result else { return XCTFail("A short answer should still fit the retained conversation") }
            let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
                controllerID: "phone", controllerSessionID: "session")
            let text = "Paris \(index)", taskID = "extended-answer-\(index)"
            let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: taskID, answer: text,
                controllerID: "phone", controllerSessionID: "session")
            answers.append(text)
            XCTAssertEqual(updated.userTurns, [original.prompt] + answers)
            XCTAssertTrue(updated.continues(original)); XCTAssertEqual(updated.rootDateContext, original.rootDateContext)
            if finish && index == answerCount { fixture.goal.base.questionTopic = nil }
            result = try await fixture.driver.continueBrowserResearch(taskID: taskID, research: owner, tools: fixture.tools, progress: { _ in })
        }
        XCTAssertEqual(owner.input.userTurns, [original.prompt] + answers)
        if finish {
            guard case .browserResearchProgress = result else { return XCTFail("The driver should reach research after collecting the details") }
            XCTAssertEqual(fixture.search.inputs.map(\.input), [owner.input])
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        } else {
            guard case .userInterventionRequired(let message) = result else { return XCTFail("Exhaustion is a nonterminal intervention, not a failed or new task") }
            XCTAssertEqual(message, owner.input.clarificationLimitMessage)
            XCTAssertEqual(owner.input.remainingAnswerCount, 0)
            XCTAssertNil(try owner.pendingQuestion(controllerID: "phone", controllerSessionID: "session"))
            XCTAssertFalse(fixture.browser.hasSession); XCTAssertEqual(fixture.server.requestCount, 0)
            let resumed = try await fixture.resume()
            guard case .userInterventionRequired(let repeated) = resumed else { return XCTFail("Resume must retain the exhausted conversation") }
            XCTAssertEqual(repeated, message)
            XCTAssertEqual(owner.input.userTurns, [original.prompt] + answers)
            XCTAssertEqual(fixture.server.requestCount, 0)
        }
    }

    func testDriverRequestsManualSignInWithoutFollowingTheEntryAndResumesTheOriginalGoal() async throws {
        try await verifyManualLoginHandoff(navigationLimit: 8)
    }

    func testDriverAllowsExplicitLoginHandoffAndHandbackOnTheLastPermittedPage() async throws {
        try await verifyManualLoginHandoff(navigationLimit: 1)
    }

    private func verifyManualLoginHandoff(navigationLimit: Int) async throws {
        let fixture = try await ResearchDriverFixture.make(navigationLimit: navigationLimit, searchBodyHTML: "<p>Sign in to view these concert tickets.</p><a href='/account'>Sign in</a>")
        defer { fixture.close() }
        fixture.policy.choices = [false]
        fixture.actions.select = { input in
            guard let entry = input.loginHandoffTargets.first else { return #"{"read_results":true}"# }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["login_handoff":entry.id]), as: UTF8.self)
        }
        let started = try await fixture.start(), result = try XCTUnwrap(started)
        guard case .userInterventionRequired(let message) = result else { return XCTFail("Expected a nonterminal manual sign-in request") }
        XCTAssertTrue(message.contains("Let AI continue")); XCTAssertFalse(message.contains(fixture.base.absoluteString))
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(owner.loginHandoffHistory.count, 1)
        XCTAssertEqual(owner.loginHandoffHistory.first?.controlReturned, false)
        XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.server.count("/account"), 0)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search])
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertFalse(fixture.state.commands.contains(.edit)); XCTAssertFalse(fixture.state.commands.contains(.openPopup))
        do { _ = try await fixture.resume(); XCTFail("The driver must wait for explicit handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        // Controlled fixture navigation stands in for manual work; it is not a real login.
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-manual-login", to: fixture.base.appendingPathComponent("account"))
        let calls = fixture.actions.inputs.count
        do { try await owner.resumeAfterUserControl(); XCTFail("The credential field still requires manual control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertEqual(owner.loginHandoffHistory.first?.controlReturned, false)
        XCTAssertEqual(fixture.actions.inputs.count, calls)
        do { _ = try await fixture.resume(); XCTFail("An authentication barrier does not complete handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-manual-ready", to: fixture.base.appendingPathComponent("account-ready"))
        try await owner.resumeAfterUserControl()
        XCTAssertEqual(owner.loginHandoffHistory.count, 1)
        XCTAssertEqual(owner.loginHandoffHistory.first?.controlReturned, true)
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/account"), 1)
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { $0.interpretation.input == original })
        let last = try XCTUnwrap(fixture.actions.inputs.last)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.contextJSON.utf8)) as? [String: Any])
        let history = try XCTUnwrap(context["login_handoff_history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["control_returned"] as? Bool, true)
        XCTAssertEqual(history.first?["authentication_verified"] as? Bool, false)
        XCTAssertEqual(history.first?["same_document"] as? Bool, false)
    }

    func testDriverAdmissionDeclinesOnlyBeforeOwnershipAndHonorsTheHostGate() async throws {
        for mode in ["unsupported", "foreign-goal", "paused", "no-provider", "empty-query"] {
            let fixture = try await ResearchDriverFixture.make()
            defer { fixture.close() }
            fixture.goal.unsupported = mode == "unsupported"
            if mode == "foreign-goal" {
                fixture.goal.base.replacement = try .init(taskID: "other", prompt: ResearchDriverFixture.prompt,
                    referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
            }
            fixture.state.allowed = mode != "paused"
            fixture.policy.providerEnabled = mode != "no-provider"
            fixture.search.empty = mode == "empty-query"
            do {
                let result = try await fixture.start()
                if mode == "unsupported" { XCTAssertNil(result) }
                else {
                    guard case .userInterventionRequired? = result else { return XCTFail("Accepted research must retain its unresolved owner") }
                    XCTAssertNotNil(fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root))
                }
                XCTAssertTrue(["unsupported", "no-provider", "empty-query"].contains(mode))
            } catch {
                if mode == "foreign-goal" { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .invalidProposal) }
                else { XCTAssertEqual(mode, "paused"); XCTAssertNotNil(error as? ComputerUseHostTools.ToolError) }
            }
            if ["unsupported", "foreign-goal", "paused"].contains(mode) {
                XCTAssertNil(fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root))
            }
            XCTAssertEqual(fixture.goal.inputs.count, mode == "paused" ? 0 : 1)
            XCTAssertFalse(fixture.browser.hasSession); XCTAssertEqual(fixture.server.requestCount, 0)
        }
    }

    func testDriverCapturesThePreparedOwnerBeforeAnAdmissionObserverFails() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        do {
            _ = try await fixture.tools.withOwnedBrowserResearchAdmission(didPrepare: { _ in
                throw ComputerUseTaskJournalStore.StoreError.unavailable
            }, operation: { try await fixture.start() })
            XCTFail("Observer failure must reach the caller")
        } catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(fixture.goal.inputs, [original]); XCTAssertTrue(fixture.search.inputs.isEmpty)
        XCTAssertFalse(fixture.browser.hasSession)
        _ = try await fixture.resume()
        XCTAssertTrue(try fixture.owner() === owner)
        XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.goal.inputs, [original])
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testDriverPauseDuringSelectionHoldsTheOwnerAndDriverUntilUnwind() async throws {
        let fixture = try await ResearchDriverFixture.make(), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        fixture.policy.beforeSelection = { await gate.suspend() }
        let delivered = expectation(description: "Selection Pause delivered before planner return")
        let running = Task { defer { delivered.fulfill() }; return try await fixture.start() }
        try await gate.waitUntilStarted()
        let owner = try fixture.owner()
        owner.pause()
        XCTAssertTrue(owner.isOperating)
        do { _ = try await fixture.resume(); XCTFail("The driver still owns its suspended selector") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .busy) }
        XCTAssertThrowsError(try fixture.coordinator.prepareResearchTask(taskID: "replacement", prompt: "Find movies.",
            goalPlanner: fixture.goal, resultPlanner: fixture.results, mayAct: { true })) {
                XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .busy)
            }
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertFalse(owner.isOperating)
        try await owner.resumeAfterUserControl()
        let busy = try await fixture.resume()
        guard case .userInterventionRequired = busy else { gate.release(); return XCTFail("Handback cannot overlap a suspended selector") }
        XCTAssertEqual(fixture.policy.goals.count, 1)
        gate.release()
        do { _ = try await running.value; XCTFail("A late selection cannot act after Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(fixture.server.count("/details"), 0)
        fixture.policy.beforeSelection = nil
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testDriverReplansAnUnsentLinkAfterLoginUnderTheSameGoalAndOperation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, true, false]
        fixture.state.onCommand = { command in
            guard command == .validatePageLink, let owner = fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root),
                  owner.hasPendingNavigation else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await fixture.start(); XCTFail("Retain the link before its request") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), original = owner.input
        let document = try XCTUnwrap(fixture.browser.currentDocument(taskID: owner.taskID))
        try await fixture.browser.waitForDOMCompletion(document: document)
        let before = try fixture.linkJournal()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "manual-login", to: fixture.base.appendingPathComponent("account"))
        do { try await owner.resumeAfterUserControl(); XCTFail("The password form needs manual control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        let selections = fixture.policy.goals.count
        do { _ = try await fixture.resume(); XCTFail("The driver cannot perform implicit handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        XCTAssertEqual(fixture.policy.goals.count, selections)
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "manual-finish", to: fixture.base.appendingPathComponent("account-ready"))
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        let after = try fixture.linkJournal()
        XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.stepIDs, before.stepIDs)
        XCTAssertEqual(after.promptDigest, before.promptDigest); XCTAssertEqual(after.statuses, [.verified])
        XCTAssertEqual(fixture.server.count("/details"), 0); XCTAssertEqual(fixture.server.count("/logged-in-offer"), 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.search.inputs.count, 1)
        XCTAssertEqual(owner.input, original); XCTAssertTrue(fixture.policy.goals.allSatisfy { $0 == original })
    }

    func testDriverRefreshesAnUnsentSearchAfterPageChangeWithoutChoosingAnotherQuery() async throws {
        let fixture = try await ResearchDriverFixture.make(seedPage: true)
        defer { fixture.close() }
        try await fixture.pauseInitialSearch()
        let owner = try fixture.owner(), original = owner.input, before = try fixture.searchJournal()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "manual-change", to: fixture.base.appendingPathComponent("account-ready"))
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        let after = try fixture.searchJournal()
        XCTAssertNotEqual(after.contractDigest, before.contractDigest)
        XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.stepIDs, before.stepIDs)
        XCTAssertEqual(after.statuses, [.verified]); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.goal.inputs.count, 1); XCTAssertEqual(fixture.search.inputs.count, 1)
        XCTAssertEqual(fixture.policy.providerCalls, 1); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testDriverKeepsUncertainSearchRecoveryPausedWithoutReadingOrRedispatch() async throws {
        for status in [ComputerUseTaskStepStatus.attempted, .uncertain, .verified] {
            let fixture = try await ResearchDriverFixture.make(seedPage: true)
            defer { fixture.close() }
            try await fixture.pauseInitialSearch()
            let store = try ComputerUseTaskJournalStore(directory: fixture.searchDirectory)
            let planned = try fixture.searchJournal()
            var attempted = planned; attempted.statuses = [.attempted]; try store.save(attempted, replacing: planned)
            if status != .attempted { var final = attempted; final.statuses = [status]; try store.save(final, replacing: attempted) }
            try await fixture.owner().resumeAfterUserControl()
            let commands = fixture.state.commands
            let result = try await fixture.resume()
            guard case .userInterventionRequired = result else { return XCTFail("An unresolved attempt must stay pending") }
            XCTAssertEqual(fixture.state.commands, commands); XCTAssertTrue(try fixture.owner().hasPendingNavigation)
            XCTAssertTrue(fixture.results.inputs.isEmpty); XCTAssertTrue(fixture.policy.goals.isEmpty)
            XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
        }
    }

    func testDriverPreservesStorageFailuresAndRecoversOnlyConfirmedNativeFacts() async throws {
        for failureAt in [1, 2, 3] {
            let fixture = try await ResearchDriverFixture.make()
            defer { fixture.close() }
            fixture.state.failureAtWrite = failureAt
            let result = try await fixture.start()
            guard case .userInterventionRequired? = result else { return XCTFail("Storage failure must retain the task for recovery") }
            let owner = try fixture.owner(), before = try fixture.searchJournal()
            XCTAssertTrue(owner.hasPendingNavigation)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), failureAt == 3 ? 1 : 0)
            owner.pause(); try await owner.resumeAfterUserControl()
            _ = try await fixture.resume()
            let after = try fixture.searchJournal()
            XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.stepIDs, before.stepIDs)
            XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(fixture.policy.providerCalls, 1)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), failureAt == 2 ? 0 : 1)
            XCTAssertEqual(owner.hasPendingNavigation, failureAt == 2)
        }
    }

    func testDriverRejectsForeignContinuationAndKeepsItsNavigationLimitAcrossResume() async throws {
        let fixture = try await ResearchDriverFixture.make(navigationLimit: 2)
        defer { fixture.close() }
        fixture.policy.choices = [true, true]
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(fixture.server.count("/details"), 1); XCTAssertEqual(fixture.server.count("/offers"), 0)
        owner.pause(); try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.policy.goals.count, 3, "The last permitted page remains readable across handback"); XCTAssertEqual(owner.input, original)
        do { _ = try await fixture.start(); XCTFail("Admission must not restart the same root") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .alreadyAdmitted) }
        let foreign = ComputerUseBrowserResearchTask(input: original, browser: fixture.browser, goalPlanner: fixture.goal,
            resultPlanner: fixture.results, mayAct: { true })
        do { _ = try await fixture.driver.continueBrowserResearch(taskID: owner.taskID, research: foreign, tools: fixture.tools, progress: { _ in }); XCTFail("An equal goal is not the retained owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .invalidContinuation) }
        do { _ = try await fixture.driver.continueBrowserResearch(taskID: "other", research: owner, tools: fixture.tools, progress: { _ in }); XCTFail("The execution ID must still match") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .invalidContinuation) }
        owner.retire()
        do { _ = try await fixture.resume(); XCTFail("A retired task cannot be resumed") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/offers"), 0)
    }

    func testDriverRejectsUnobservedSelectionsAndPageDriftBeforeOpeningALink() async throws {
        for changedPage in [false, true] {
            let fixture = try await ResearchDriverFixture.make()
            defer { fixture.close() }
            fixture.policy.choices = [true]
            fixture.policy.invalidChoice = !changedPage
            if changedPage {
                fixture.policy.beforeSelection = {
                    do {
                        _ = try await fixture.browser.navigate(taskID: ResearchDriverFixture.root, operationID: "manual-change",
                            to: fixture.base.appendingPathComponent("account-ready"))
                    } catch { XCTFail("Could not prepare changed-page fixture: \(error)") }
                }
            }
            do {
                let result = try await fixture.start()
                XCTAssertTrue(changedPage)
                guard case .userInterventionRequired? = result else { return XCTFail("Page drift must retain the task without opening the old choice") }
            } catch {
                XCTAssertFalse(changedPage)
                XCTAssertEqual(error as? ComputerUseBrowserResultError, .invalidProposal)
            }
            XCTAssertEqual(fixture.server.count("/details"), 0); XCTAssertEqual(fixture.server.count("/logged-in-offer"), 0)
            XCTAssertFalse(try fixture.owner().hasPendingNavigation)
        }
    }

    func testDriverRetainsChildCompletionBeforeCancelledReturnAndDoesNotRestoreRetiredHistory() async throws {
        for stop in [false, true] {
            for limit in [1, 2] {
                let fixture = try await ResearchDriverFixture.make(navigationLimit: limit)
                defer { fixture.close() }
                fixture.policy.choices = [true, true]
                var interrupted = false
                fixture.state.onMayAct = {
                    guard let owner = fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root),
                          owner.isOperating, owner.initialSearchState == .confirmed, !owner.hasPendingNavigation,
                          limit == 1 || fixture.server.count("/details") == 1 else { return }
                    fixture.state.onMayAct = nil; interrupted = true
                    if stop { owner.retire() } else { owner.pause() }
                }
                do { _ = try await fixture.start(); XCTFail("The completed child must not publish through interrupted ownership") }
                catch {
                    XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .paused
                        || error as? ComputerUseBrowserResearchTask.Failure == .retired)
                }
                let owner = try fixture.owner()
                XCTAssertTrue(interrupted); XCTAssertFalse(owner.isOperating)
                XCTAssertEqual(owner.confirmedNavigationHistory.count, stop ? 0 : limit)
                XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
                XCTAssertEqual(fixture.server.count("/details"), limit - 1)
                if stop {
                    do { _ = try await fixture.resume(); XCTFail("Retirement cannot recover history or resume") }
                    catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
                } else {
                    let history = owner.confirmedNavigationHistory
                    try await owner.resumeAfterUserControl()
                    let result = try await fixture.resume()
                    guard case .browserResearchProgress(let report) = result else { return XCTFail("Recover the final visit, read it, and retain findings without another navigation") }
                    XCTAssertEqual(report.pauseReason, .navigationLimit)
                    XCTAssertEqual(owner.confirmedNavigationHistory, history)
                }
                XCTAssertEqual(fixture.policy.goals.count, stop ? limit - 1 : limit)
                XCTAssertEqual(fixture.search.inputs.count, 1)
                XCTAssertEqual(fixture.server.count("/offers"), 0)
            }
        }
    }
    func testDriverReconcilesPendingFormQueriesBeforeReadingOrSelectingAnotherAction() async throws {
        for mode in ["unsent", "attempted", "verified-write", "late-pause"] {
            let fixture = try await ResearchDriverFixture.make(searchForm: true)
            defer { fixture.close() }
            _ = try await fixture.start()
            let owner = try fixture.owner(), original = owner.input
            let input = try await owner.prepareFormInput()
            let plan = try ComputerUseBrowserFormProposal.decode(
                content: #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"#, input: input)
            let form = try await owner.executeForm(plan, input: input)
            let page = try await owner.observeFormResultPage(after: form)
            let control = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
            let startingWrites = fixture.state.writes
            if mode == "verified-write" { fixture.state.failureAtWrite = startingWrites + 3 }
            else {
                fixture.state.onWrite = {
                    let offset = mode == "unsent" ? 1 : mode == "attempted" ? 2 : 3
                    if fixture.state.writes == startingWrites + offset { owner.pause() }
                }
            }
            do { _ = try await owner.openFormQuery(after: form, controlID: control.id, evidence: page); XCTFail("Keep the interrupted query pending") }
            catch {
                if mode == "verified-write" { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            fixture.state.onWrite = nil; fixture.state.failureAtWrite = nil
            XCTAssertTrue(owner.hasPendingFormNavigation)
            if mode != "verified-write" { try await owner.resumeAfterUserControl() }
            let readings = fixture.results.inputs.count, selections = fixture.policy.goals.count
            let result = try await fixture.resume()
            if mode == "attempted" {
                guard case .userInterventionRequired = result else { return XCTFail("The uncertain query remains pending") }
            } else {
                guard case .browserResearchProgress = result else { return XCTFail("Query navigation yields partial findings only") }
            }
            XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.goal.inputs.count, 1); XCTAssertEqual(fixture.search.inputs.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
            if mode == "attempted" {
                XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
                XCTAssertEqual(fixture.results.inputs.count, readings); XCTAssertEqual(fixture.policy.goals.count, selections)
                XCTAssertTrue(owner.hasPendingFormNavigation); XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search])
            } else {
                XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
                XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .formQuery])
                XCTAssertEqual(fixture.policy.histories.last?.map(\.kind), [.search, .formQuery])
                XCTAssertFalse(owner.hasPendingNavigation)
                _ = try await fixture.resume()
                XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
            }
        }
    }

    func testDriverReconcilesPendingFormEditsWithoutTreatingThemAsSubmissionOrAnAnswer() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        let input = try await owner.prepareFormInput()
        let plan = try ComputerUseBrowserFormProposal.decode(
            content: #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"#, input: input)
        fixture.state.failureAtWrite = fixture.state.writes + 2
        do { _ = try await owner.executeForm(plan, input: input); XCTFail("The verified write must report its failure") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        XCTAssertTrue(owner.hasPendingForm)
        let readings = fixture.results.inputs.count, selections = fixture.policy.goals.count
        let result = try await fixture.resume()
        guard case .browserResearchProgress = result else { return XCTFail("Reading after form recovery is still not a completed answer") }
        XCTAssertFalse(owner.hasPendingForm); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search]); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.results.inputs.count, readings + 1); XCTAssertEqual(fixture.policy.goals.count, selections + 1)
    }
    func testDriverChoosesAndExecutesAFormBeforeReadingResultsUnderTheCompleteGoal() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        configureAutomaticFormQueries(fixture)
        let result = try await fixture.start()
        guard case .browserResearchProgress? = result else { return XCTFail("A searched page is not a verified answer") }
        let owner = try fixture.owner(), original = owner.input
        let stages = fixture.actions.steps.map { step in
            switch step {
            case .editForm: return "select form"
            case .reviewControls: return "review controls"
            case .planFields: return "plan fields"
            case .openQuery: return "open query"
            case .readResults: return "read results"
            default: return "unexpected action"
            }
        }
        XCTAssertEqual(stages, ["select form", "review controls", "plan fields", "open query", "read results"])
        XCTAssertEqual(fixture.actions.inputs.map(\.usesFormHistoryContext), [false, false, false, true, true],
            "History guidance starts when there is real form history, and survives leaving the form")
        if let path = ProcessInfo.processInfo.environment["REPAIR_PLANNER_REQUEST_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let connection = try ComputerUseTextModelConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
                bearerToken: "fixture-token-value", modelAlias: "fixture-model")
            let transport = URLSessionOSAtlasTransport()
            let planner = ComputerUseLocalBrowserActionPlanner(connection: connection, transport: transport)
            // Serialize synthetic fixture requests only; neither tokenization
            // nor completion is sent to this transport.
            for (index, input) in fixture.actions.inputs.enumerated() {
                let body = try XCTUnwrap(planner.makeRequest(input).httpBody)
                try body.write(to: directory.appendingPathComponent("action-\(index).json"), options: .atomic)
            }
            let goalPlanner = ComputerUseLocalBrowserGoalPlanner(connection: connection, transport: transport)
            let searchPlanner = ComputerUseLocalBrowserSearchPlanner(connection: connection, transport: transport)
            let formPlanner = ComputerUseLocalBrowserFormPlanner(connection: connection, transport: transport)
            for (kind, requests) in [
                ("goal", try fixture.goal.inputs.map(goalPlanner.makeRequest)),
                ("search", try fixture.search.inputs.map(searchPlanner.makeRequest)),
                ("form", try fixture.forms.inputs.map(formPlanner.makeRequest))
            ] {
                for (index, request) in requests.enumerated() {
                    try XCTUnwrap(request.httpBody).write(to: directory.appendingPathComponent("\(kind)-\(index).json"), options: .atomic)
                }
            }
        }
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.forms.inputs.first?.interpretation.input, original)
        XCTAssertNotNil(fixture.forms.inputs.first?.selectedFormID)
        XCTAssertEqual(fixture.results.inputs, [original], "The initial form page must not first be interpreted as a result set")
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { $0.interpretation.input == original })
        let queryInput = try XCTUnwrap(fixture.actions.inputs.first { !$0.queryControlIDs.isEmpty })
        XCTAssertEqual(queryInput.queryReceipt, owner.confirmedFormHistory.first)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .formQuery])
        XCTAssertEqual(fixture.goal.inputs, [original]); XCTAssertEqual(fixture.search.inputs.map(\.input), [original])
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.forms.inputs.count, 1); XCTAssertEqual(owner.input, original)
    }

    func testDriverFormQuestionPreservesTheRootAndClockThroughItsAcceptedAnswer() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        configureAutomaticFormQueries(fixture)
        fixture.forms.content = #"{"question":{"topic":"date","requirements":[0]}}"#
        let result = try await fixture.start()
        guard case .browserClarificationRequired(let request)? = result else { return XCTFail("A scoped form question must use the research continuation") }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(request.taskID, original.taskID); XCTAssertEqual(request.inputDigest, original.digest)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "form-answer", answer: "Tomorrow.",
            controllerID: "phone", controllerSessionID: "session")
        fixture.forms.content = formContent
        let continued = try await fixture.resume()
        guard case .browserResearchProgress = continued else { return XCTFail("Further result verification remains necessary") }
        XCTAssertEqual(owner.input.prompt, original.prompt); XCTAssertEqual(owner.input.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(owner.input.timeZoneIdentifier, original.timeZoneIdentifier); XCTAssertEqual(owner.executionTaskID, "form-answer")
        XCTAssertEqual(fixture.forms.inputs.map { $0.interpretation.input }, [original, owner.input])
        XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(owner.confirmedFormHistory.first?.goalRevision, owner.input.digest)
        XCTAssertEqual(owner.confirmedFormHistory.first?.rootDigest, original.rootDigest)
    }

    func testDriverPauseDuringFormPlanningKeepsOwnershipAndReplansOnlyUnattemptedInput() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        configureAutomaticFormQueries(fixture)
        fixture.forms.beforeReply = { await gate.suspend() }
        let delivered = expectation(description: "Form Pause delivered before planner return")
        let running = Task { defer { delivered.fulfill() }; return try await fixture.start() }
        try await gate.waitUntilStarted()
        let owner = try fixture.owner(), original = owner.input
        owner.pause()
        XCTAssertTrue(owner.isOperating)
        do { _ = try await fixture.resume(); XCTFail("The original form planner must unwind first") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .busy) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertFalse(owner.isOperating)
        try await owner.resumeAfterUserControl()
        let busy = try await fixture.resume()
        guard case .userInterventionRequired = busy else { gate.release(); return XCTFail("Handback cannot overlap a suspended form planner") }
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        gate.release()
        do { _ = try await running.value; XCTFail("The late model reply cannot authorize input") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.forms.beforeReply = nil
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.forms.inputs.count, 2)
        XCTAssertTrue(fixture.forms.inputs.allSatisfy { $0.interpretation.input == original })
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1); XCTAssertEqual(fixture.search.inputs.count, 1)
    }

    func testDriverResumesCommittedFormInputThenSelectsTheQueryWithoutAnotherFormProposal() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        configureAutomaticFormQueries(fixture)
        fixture.forms.beforeReply = {
            let targetWrite = fixture.state.writes + 2
            fixture.state.onWrite = {
                if fixture.state.writes == targetWrite { fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)?.pause() }
            }
        }
        do { _ = try await fixture.start(); XCTFail("Pause after the verified input write must preserve the stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertTrue(owner.hasPendingForm); XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
        fixture.state.onWrite = nil; fixture.forms.beforeReply = nil
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original); XCTAssertFalse(owner.hasPendingForm)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1); XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .formQuery])
    }

    func testActiveWorkExcludesManualTimeAndKeepsTheAllowanceAcrossAnAcceptedAnswer() async throws {
        let clock = BrowserWorkFixtureClock()
        let fixture = try await ResearchDriverFixture.make(activeWorkLimit: .seconds(10), monotonicNow: { clock.instant })
        defer { fixture.close() }
        fixture.goal.base.questionTopic = .location
        fixture.goal.base.beforeReply = { clock.advance(.seconds(3)) }
        let first = try await fixture.start()
        guard case .browserClarificationRequired(let request)? = first else { return XCTFail("The first active segment must retain the question") }
        let owner = try fixture.owner(), original = owner.input
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs, controllerID: "phone", controllerSessionID: "session")
        clock.advance(.seconds(3_600)) // Monotonic manual time only; no wall-clock expiry is fabricated.
        let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Paris",
            controllerID: "phone", controllerSessionID: "session")
        fixture.goal.base.questionTopic = nil
        fixture.goal.base.beforeReply = { clock.advance(.seconds(4)) }
        fixture.search.beforeReply = { clock.advance(.seconds(2)) }
        fixture.actions.beforeReply = { clock.advance(.seconds(1)) }
        let continued = try await fixture.resume()
        guard case .userInterventionRequired(let message) = continued else { return XCTFail("The accepted answer must retain the three seconds already consumed") }
        XCTAssertTrue(message.contains("research time limit"))
        XCTAssertEqual(owner.input, updated); XCTAssertEqual(updated.rootDigest, original.rootDigest)
        XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(fixture.goal.inputs, [original, updated]); XCTAssertEqual(fixture.search.inputs.map(\.input), [updated])
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1, "Time outside execution must not consume the remaining allowance")
        XCTAssertTrue(fixture.results.inputs.isEmpty, "No next reading starts once active work consumes the allowance")
        let calls = fixture.state.commands
        clock.advance(.seconds(3_600))
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands, calls); XCTAssertEqual(fixture.actions.inputs.count, 1)
    }

    func testActiveWorkExpiryAfterFormProposalCannotStartInputOrResetOnHandback() async throws {
        let clock = BrowserWorkFixtureClock()
        let fixture = try await ResearchDriverFixture.make(searchForm: true, activeWorkLimit: .seconds(10), monotonicNow: { clock.instant })
        defer { fixture.close() }
        configureAutomaticFormQueries(fixture)
        fixture.forms.beforeReply = { clock.advance(.seconds(10)) }
        let result = try await fixture.start()
        guard case .userInterventionRequired(let message)? = result else { return XCTFail("A proposal cannot start an edit after the task's allowance expires") }
        XCTAssertTrue(message.contains("research time limit"))
        let owner = try fixture.owner(), original = owner.input
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertFalse(fixture.state.commands.contains(.edit)); XCTAssertEqual(fixture.forms.inputs.count, 1)
        owner.pause(); clock.advance(.seconds(3_600)); try await owner.resumeAfterUserControl()
        let commands = fixture.state.commands
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands, commands); XCTAssertEqual(owner.input, original)
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
    }

    func testActiveWorkExpiryDuringAdmittedInputKeepsItsReceiptAndBlocksTheNextStage() async throws {
        let clock = BrowserWorkFixtureClock()
        let fixture = try await ResearchDriverFixture.make(searchForm: true, activeWorkLimit: .seconds(10), monotonicNow: { clock.instant })
        defer { fixture.close() }
        configureAutomaticFormQueries(fixture)
        fixture.state.onCommand = { command in
            if command == .edit { fixture.state.onCommand = nil; clock.advance(.seconds(10)) }
        }
        let result = try await fixture.start()
        guard case .userInterventionRequired(let message)? = result else { return XCTFail("Expiry must stop the next stage after the admitted input finishes") }
        XCTAssertTrue(message.contains("research time limit"))
        let owner = try fixture.owner(), history = owner.confirmedFormHistory
        XCTAssertEqual(history.count, 1); XCTAssertFalse(owner.hasPendingForm)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
        let commands = fixture.state.commands
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands, commands); XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search])
    }

    func testFailedAdmissionRetryKeepsItsConsumedWorkAlongsideTheOriginalClock() async throws {
        let clock = BrowserWorkFixtureClock()
        let fixture = try await ResearchDriverFixture.make(activeWorkLimit: .seconds(5), monotonicNow: { clock.instant })
        defer { fixture.close() }
        fixture.goal.select = { _ in clock.advance(.seconds(4)); throw ComputerUseBrowserGoalPlanError.invalidInput }
        do { _ = try await fixture.start(); XCTFail("The failed initial proposal should reach its caller") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserGoalPlanError, .invalidInput) }
        let original = try XCTUnwrap(fixture.goal.inputs.first)
        XCTAssertNil(fixture.tools.ownedBrowserResearch(taskID: original.taskID)); XCTAssertFalse(fixture.browser.hasSession)
        clock.advance(.seconds(3_600)); fixture.goal.select = nil
        fixture.search.beforeReply = { clock.advance(.seconds(1)) }
        let retried = try await fixture.start()
        guard case .userInterventionRequired(let message)? = retried else { return XCTFail("Admission retry cannot create a fresh work allowance") }
        XCTAssertTrue(message.contains("research time limit"))
        XCTAssertEqual(fixture.goal.inputs, [original, original]); XCTAssertEqual(try fixture.owner().input, original)
        XCTAssertEqual(try fixture.owner().initialSearchState, .notPrepared)
        XCTAssertFalse(fixture.browser.hasSession); XCTAssertEqual(fixture.server.requestCount, 0)
    }

    func testLastPageFindingsRemainAvailableWithoutResettingNavigationCapacity() async throws {
        let fixture = try await ResearchDriverFixture.make(navigationLimit: 1, candidateBodyHTML: "<p>From USD 40. Fees apply.</p>")
        defer { fixture.close() }
        fixture.policy.choices = [true, true]
        let first = try await fixture.start()
        guard case .browserResearchProgress(let report)? = first else { return XCTFail("The last page's findings must survive a blocked next-link choice") }
        let owner = try fixture.owner(), original = owner.input, history = owner.confirmedNavigationHistory
        XCTAssertEqual(report.pauseReason, .navigationLimit)
        XCTAssertTrue(report.message.contains("From USD 40. Fees apply.")); XCTAssertTrue(report.message.contains(fixture.request))
        XCTAssertTrue(report.interventionGuidance.contains("Resume does not allow additional navigation"))
        XCTAssertEqual(fixture.results.inputs, [original]); XCTAssertEqual(fixture.policy.goals, [original])
        XCTAssertEqual(history.map(\.kind), [.search]); XCTAssertFalse(owner.hasPendingNavigation)
        owner.pause(); try await owner.resumeAfterUserControl()
        let resumed = try await fixture.resume()
        guard case .browserResearchProgress(let repeated) = resumed else { return XCTFail("Handback can read the page without buying another navigation") }
        XCTAssertEqual(repeated.pauseReason, .navigationLimit)
        XCTAssertEqual(fixture.results.inputs, [original, original]); XCTAssertEqual(fixture.policy.goals, [original, original])
        XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.confirmedNavigationHistory, history)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertEqual(try fixture.browser.navigationDispatchHistory(taskID: owner.taskID).attempts.count, 1)
    }

    func testLastPageCanVerifyFormInputButCannotStartAnotherQuery() async throws {
        let fixture = try await ResearchDriverFixture.make(navigationLimit: 1, searchForm: true)
        defer { fixture.close() }
        configureAutomaticFormQueries(fixture)
        let result = try await fixture.start()
        guard case .userInterventionRequired(let message)? = result else { return XCTFail("A new form query needs navigation capacity") }
        XCTAssertTrue(message.contains("navigation limit"))
        let owner = try fixture.owner(), original = owner.input, history = owner.confirmedFormHistory
        XCTAssertEqual(history.count, 1); XCTAssertFalse(owner.hasPendingForm); XCTAssertFalse(owner.hasPendingFormNavigation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        owner.pause(); try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.forms.inputs.count, 1); XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
        XCTAssertEqual(try fixture.browser.navigationDispatchHistory(taskID: owner.taskID).attempts.count, 1)
    }

    func testLastPageActionCannotTraverseAnEarlierVisitBeyondTheNavigationLimit() async throws {
        let fixture = try await ResearchDriverFixture.make(navigationLimit: 2)
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input, history = owner.confirmedNavigationHistory
        var selectedVisit: Int?
        fixture.actions.select = { input in
            let visit = try XCTUnwrap(input.historyOptions.first?.visit)
            selectedVisit = visit
            return "{\"revisit\":\(visit)}"
        }
        let result = try await fixture.resume()
        guard case .userInterventionRequired(let message) = result else { return XCTFail("A proposed revisit cannot open a new history stage without capacity") }
        XCTAssertTrue(message.contains("navigation limit")); XCTAssertNotNil(selectedVisit)
        XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.confirmedNavigationHistory, history)
        XCTAssertFalse(owner.hasPendingHistoryNavigation)
        XCTAssertEqual(try fixture.browser.navigationDispatchHistory(taskID: owner.taskID).attempts.count, 2)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 1)
    }

    func testAdmissionDeadlineDoesNotCreateAnOwnerAndRetryRetainsTheOriginalClock() async throws {
        var date = ResearchDriverFixture.date, zone = "America/Los_Angeles"
        let fixture = try await ResearchDriverFixture.make(planningTimeout: 0.15, now: { date }, timeZoneIdentifier: { zone })
        let gate = ComputerUsePlanningTestGate<Bool>(started: expectation(description: "admission started"), returned: expectation(description: "admission returned"))
        defer { gate.finish(true); fixture.close() }
        fixture.goal.base.beforeReply = { _ = await gate.wait() }
        let delivered = expectation(description: "admission deadline delivered")
        let call = Task { () -> Result<ComputerUseExecutionResult?, Error> in
            defer { delivered.fulfill() }
            do { return .success(try await fixture.start()) } catch { return .failure(error) }
        }
        await fulfillment(of: [gate.started, delivered], timeout: 2, enforceOrder: true)
        let original = try XCTUnwrap(fixture.goal.inputs.first)
        XCTAssertNil(fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)); XCTAssertFalse(fixture.browser.hasSession)
        date = date.addingTimeInterval(172_800); zone = "UTC"
        do {
            _ = try await fixture.driver.executeBrowserResearch(taskID: "competing-task", prompt: "Find movies.", tools: fixture.tools, progress: { _ in })
            XCTFail("A busy competing task cannot discard the original retry clock")
        } catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        do { _ = try await fixture.start(); XCTFail("Admission cannot queue another model call") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        do {
            _ = try await fixture.driver.executeBrowserResearch(taskID: ResearchDriverFixture.root, prompt: fixture.request + " Changed.", tools: fixture.tools, progress: { _ in })
            XCTFail("A retry cannot silently replace the original request")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserResearchDriver.Failure, .invalidContinuation) }
        XCTAssertEqual(fixture.goal.inputs, [original]); XCTAssertTrue(fixture.search.inputs.isEmpty)
        gate.finish(true)
        switch await call.value {
        case .failure(let error): XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut)
        case .success: XCTFail("Timeout cannot become admission or an unsupported-route fallback")
        }
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        XCTAssertNil(fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)); XCTAssertFalse(fixture.browser.hasSession)
        fixture.goal.base.beforeReply = nil
        _ = try await fixture.start()
        XCTAssertEqual(fixture.goal.inputs, [original, original]); XCTAssertEqual(try fixture.owner().input, original)
        XCTAssertEqual(original.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testActionDeadlineReturnsWithoutLettingTheLateProposalAct() async throws { try await verifyHeldProposalDeadline(.action) }
    func testFormDeadlineReturnsWithoutLettingTheLateProposalEdit() async throws { try await verifyHeldProposalDeadline(.form) }
    func testReadingDeadlineReturnsWithoutPublishingTheLateReading() async throws { try await verifyHeldProposalDeadline(.reading) }
    func testSelectionDeadlineReturnsWithoutOpeningTheLateLink() async throws { try await verifyHeldProposalDeadline(.selection) }

    private enum HeldProposalStage: Equatable { case action, form, reading, selection }
    private func verifyHeldProposalDeadline(_ stage: HeldProposalStage) async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: stage == .form, planningTimeout: 0.15)
        let gate = ComputerUsePlanningTestGate<Bool>(started: expectation(description: "\(stage) started"), returned: expectation(description: "\(stage) returned"))
        defer { gate.finish(true); fixture.close() }
        let hold: @MainActor () async -> Void = { _ = await gate.wait() }
        switch stage {
        case .action: fixture.actions.beforeReply = hold
        case .form: configureAutomaticFormQueries(fixture); fixture.forms.beforeReply = hold
        case .reading: fixture.results.beforeReply = hold
        case .selection: fixture.policy.choices = [true]; fixture.policy.beforeSelection = hold
        }
        let delivered = expectation(description: "\(stage) deadline delivered")
        let call = Task { () -> Result<ComputerUseExecutionResult?, Error> in
            defer { delivered.fulfill() }
            do { return .success(try await fixture.start()) } catch { return .failure(error) }
        }
        await fulfillment(of: [gate.started], timeout: 5)
        await fulfillment(of: [delivered], timeout: 1)
        let owner = try fixture.owner(), original = owner.input
        XCTAssertFalse(owner.isOperating)
        XCTAssertThrowsError(try fixture.planningWorker.requireAvailable()) {
            XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .busy)
        }
        let calls = [fixture.actions.inputs.count, fixture.forms.inputs.count, fixture.results.inputs.count, fixture.policy.goals.count]
        let retry = try await fixture.resume()
        guard case .userInterventionRequired = retry else { return XCTFail("Retry must respect the original planner's occupied permit") }
        XCTAssertEqual([fixture.actions.inputs.count, fixture.forms.inputs.count, fixture.results.inputs.count, fixture.policy.goals.count], calls)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertFalse(fixture.state.commands.contains(.edit)); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        let commands = fixture.state.commands, history = owner.confirmedNavigationHistory
        gate.finish(true)
        switch await call.value {
        case .success(.some(.userInterventionRequired)): break
        default: XCTFail("\(stage) deadline must keep the existing research task pending")
        }
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        XCTAssertEqual(fixture.state.commands, commands); XCTAssertEqual(owner.confirmedNavigationHistory, history)
        XCTAssertEqual(owner.input, original)
        fixture.actions.beforeReply = nil; fixture.forms.beforeReply = nil; fixture.results.beforeReply = nil; fixture.policy.beforeSelection = nil
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    private var formContent: String { #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"# }
    private func configureAutomaticFormQueries(_ fixture: ResearchDriverFixture) {
        fixture.forms.content = formContent
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["Query":[0]]) { return review }
            let choice: [String: Any]
            if let control = input.queryControlIDs.first { choice = ["query":control] }
            else if let form = input.formIDs.first { choice = ["form":form,"preserve":[]] }
            else { choice = ["read_results":true] }
            return String(decoding: try JSONSerialization.data(withJSONObject: choice), as: UTF8.self)
        }
    }
}

@MainActor
final class ComputerUseBrowserWorkBudgetTests: XCTestCase {
    func testActiveSegmentsAccumulateWithoutChargingManualTimeOrRefillingOnFinish() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); clock.advance(.seconds(4)); budget.finish(); budget.finish()
        clock.advance(.seconds(3_600)); try budget.begin()
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 6, accuracy: 0.000_001)
        clock.advance(.seconds(6))
        XCTAssertThrowsError(try budget.admit()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
        budget.finish(); clock.advance(.seconds(3_600))
        XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
        XCTAssertThrowsError(try budget.planningTimeout(maximum: 30), "An inactive owner cannot bypass exhausted capacity")
    }

    func testRepeatedCheckpointsChargeEachActiveIntervalOnlyOnce() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); defer { budget.finish() }
        clock.advance(.seconds(2)); try budget.admit(); try budget.admit()
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 8, accuracy: 0.000_001)
        clock.advance(.seconds(3)); try budget.admit()
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 5, accuracy: 0.000_001)
        XCTAssertEqual(try budget.planningTimeout(maximum: 2), 2, accuracy: 0.000_001)
    }

    func testOverlappingBeginCannotReplaceAnActiveSegmentOrRefundItsTime() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); defer { budget.finish() }; clock.advance(.seconds(3))
        XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .alreadyActive) }
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 7, accuracy: 0.000_001)
    }

    func testInvalidAllowancesFailBeforeOpeningASegment() {
        for allowance in [Duration.zero, .seconds(-1), ComputerUseBrowserWorkBudget.maximumAllowance + .seconds(1)] {
            var clockCalls = 0
            let budget = ComputerUseBrowserWorkBudget(allowance: allowance, clock: { clockCalls += 1; return .now })
            XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .invalidAllowance) }
            XCTAssertThrowsError(try budget.planningTimeout(maximum: 30))
            budget.finish(); XCTAssertEqual(clockCalls, 0)
        }
    }

    func testRegressedClockCannotRefundOrReviveWorkCapacity() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .seconds(10), clock: { clock.instant })
        try budget.begin(); clock.advance(.seconds(-1))
        XCTAssertThrowsError(try budget.admit()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
        budget.finish(); clock.advance(.seconds(3_600))
        XCTAssertThrowsError(try budget.begin()) { XCTAssertEqual($0 as? ComputerUseBrowserWorkBudget.Failure, .exhausted) }
    }

    func testProposalAllowanceUsesRemainingFractionalTimeAndRejectsInvalidStageLimits() throws {
        let clock = BrowserWorkFixtureClock(), budget = ComputerUseBrowserWorkBudget(allowance: .milliseconds(150), clock: { clock.instant })
        try budget.begin(); defer { budget.finish() }
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 0.15, accuracy: 0.000_001)
        clock.advance(.milliseconds(100))
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 0.05, accuracy: 0.000_001)
        for maximum in [0, -1, .infinity, .nan, ComputerUsePlanningWorker.maximumWait + 1] {
            XCTAssertThrowsError(try budget.planningTimeout(maximum: maximum)) {
                XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .invalidDeadline)
            }
        }
        XCTAssertEqual(try budget.planningTimeout(maximum: 30), 0.05, accuracy: 0.000_001)
    }
}

@MainActor
final class BrowserWorkFixtureClock {
    var instant = ContinuousClock.now
    func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
}

@MainActor
struct ResearchDriverFixture {
    static let root = "research-driver"
    static let prompt = "Find concerts under USD 50. Do not buy."
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    let request: String
    let server: OwnedBrowserHTTPFixture
    let base: URL
    let directory: URL
    let browser: ComputerUseOwnedBrowser
    let coordinator: ComputerUseBrowserNavigationTask
    let tools: ComputerUseHostTools
    let goal: DriverGoalFixture
    let results: BrowserResearchResultFixture
    let search: DriverSearchFixture
    let actions: BrowserResearchActionFixture
    let forms: BrowserResearchFormFixture
    let policy: DriverPlanningFixture
    let state: DriverFixtureState
    let driver: ComputerUseBrowserResearchDriver
    let planningWorker: ComputerUsePlanningWorker
    var searchDirectory: URL { directory.appendingPathComponent("Research/Initial Search") }

    static func make(seedPage: Bool = false, navigationLimit: Int = 8,
                     linkPlanner: (any ComputerUseBrowserLinkPlanning)? = nil,
                     resultPlanner: (any ComputerUseBrowserResultPlanning)? = nil,
                     additionalCardHTML: String = "", linkDestinationOverride: String? = nil,
                     candidateBodyHTML: String = "", searchForm: Bool = false,
                     actionPlanner: (any ComputerUseBrowserActionPlanning)? = nil,
                     formPlanner: (any ComputerUseBrowserFormPlanning)? = nil, request: String = ResearchDriverFixture.prompt,
                     searchFormHTML: String? = nil, heldSignal: Bool = false, offersBodyHTML: String? = nil,
                     searchBodyHTML: String? = nil, detailsBodyHTML: String? = nil, betaBodyHTML: String? = nil,
                     planningWorker: ComputerUsePlanningWorker = .init(), planningTimeout: TimeInterval = 30,
                     now: @escaping () -> Date = { ResearchDriverFixture.date }, timeZoneIdentifier: @escaping () -> String = { "America/Los_Angeles" },
                     activeWorkLimit: Duration = ComputerUseBrowserWorkBudget.defaultAllowance,
                     monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) async throws -> Self {
        func card(_ path: String) -> String { "<article><h2>Concert Alpha</h2><a href='\(linkDestinationOverride ?? path)'>Alpha details</a>\(candidateBodyHTML)</article>" + additionalCardHTML }
        let form = searchFormHTML ?? (searchForm ? "<form action='/filtered'><label>Query<input name='q' value='old'></label><button>Search</button></form>" : "")
        let server = try OwnedBrowserHTTPFixture(routes: ["/signal": .init(held: heldSignal), "/before": .init(body: card("/old")),
            "/search?q=concerts": .init(body: searchBodyHTML ?? card("/details") + form), "/details": .init(body: detailsBodyHTML ?? card("/offers")),
            "/filtered?q=concerts": .init(body: card("/more")),
            "/filtered?q=concerts&category=concerts": .init(body: card("/more")),
            "/offers": .init(body: offersBodyHTML ?? card("/more")), "/account": .init(body: "<label>Password<input type=password></label>"),
            "/account-ready": .init(body: card("/logged-in-offer")), "/logged-in-offer": .init(body: card("/more")),
            "/beta": .init(body: betaBodyHTML ?? card("/more"))])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), state = DriverFixtureState()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: {
            state.commands.append($0); state.onCommand?($0)
        }, mayAct: { state.onMayAct?(); return state.allowed })
        do {
            let base = try await server.start()
            if seedPage {
                try browser.claim(taskID: "previous")
                _ = try await browser.navigate(taskID: "previous", operationID: "seed", to: base.appendingPathComponent("before"))
            }
            let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory,
                observedNavigationStore: { try .init(directory: $0, afterReplacement: {
                    try MainActor.assumeIsolated {
                        state.writes += 1
                        state.onWrite?()
                        if state.failureAtWrite == state.writes { throw ComputerUseTaskJournalStore.StoreError.unavailable }
                    }
                }) })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { state.onMayAct?(); return state.allowed }, browserNavigationTask: coordinator)
            let goal = DriverGoalFixture(), results = BrowserResearchResultFixture(), search = DriverSearchFixture()
            let actions = BrowserResearchActionFixture(), forms = BrowserResearchFormFixture()
            results.selectedLinkLabel = "Alpha details"
            let policy = DriverPlanningFixture(provider: try .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"))
            let planning: any ComputerUseBrowserResearchPlanning
            if let linkPlanner { planning = ComputerUseModelBrowserResearchPlanning(sourcePlan: { try policy.sources(for: $0) }, linkPlanner: linkPlanner) }
            else { planning = policy }
            let driver = ComputerUseBrowserResearchDriver(goalPlanner: goal, resultPlanner: resultPlanner ?? results, searchPlanner: search, actionPlanner: actionPlanner ?? actions, formPlanner: formPlanner ?? forms,
                planning: planning, navigationLimit: navigationLimit, now: now, timeZoneIdentifier: timeZoneIdentifier,
                planningWorker: planningWorker, planningTimeout: planningTimeout, activeWorkLimit: activeWorkLimit, monotonicNow: monotonicNow)
            return .init(request: request, server: server, base: base, directory: directory, browser: browser, coordinator: coordinator,
                tools: tools, goal: goal, results: results, search: search, actions: actions, forms: forms, policy: policy, state: state, driver: driver, planningWorker: planningWorker)
        } catch { browser.close(); server.stop(); try? FileManager.default.removeItem(at: directory); throw error }
    }
    func owner() throws -> ComputerUseBrowserResearchTask { try XCTUnwrap(tools.ownedBrowserResearch(taskID: Self.root)) }
    func start() async throws -> ComputerUseExecutionResult? {
        try await driver.executeBrowserResearch(taskID: Self.root, prompt: request, tools: tools, progress: { _ in })
    }
    func resume() async throws -> ComputerUseExecutionResult {
        let owner = try owner()
        return try await driver.continueBrowserResearch(taskID: owner.executionTaskID, research: owner, tools: tools, progress: { _ in })
    }
    func pauseInitialSearch() async throws {
        state.onCommand = { command in
            guard command == .pageSnapshot, let owner = tools.ownedBrowserResearch(taskID: Self.root),
                  owner.initialSearchState == .pending else { return }
            state.onCommand = nil; owner.pause()
        }
        do { _ = try await start(); XCTFail("Expected a planned initial search before Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try owner(), document = try XCTUnwrap(browser.currentDocument(taskID: owner.taskID))
        try await browser.waitForDOMCompletion(document: document)
        XCTAssertEqual(try searchJournal().statuses, [.planned])
        XCTAssertEqual(server.count("/search?q=concerts"), 0)
    }
    func searchJournal() throws -> ComputerUseTaskJournal {
        let id = ComputerUseTaskContract.digest(["browser-initial-search-record-v1", Self.root])
        return try XCTUnwrap(ComputerUseTaskJournalStore(directory: searchDirectory).load(taskID: id))
    }
    func linkJournal() throws -> ComputerUseTaskJournal {
        let location = directory.appendingPathComponent("Research/Observed Destinations")
        let files = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        return try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: XCTUnwrap(files.first)))
    }
    func close() { state.onCommand = nil; state.onMayAct = nil; state.onWrite = nil; goal.base.beforeReply = nil; search.beforeReply = nil; results.beforeReply = nil; policy.beforeSelection = nil; actions.beforeReply = nil; forms.beforeReply = nil; coordinator.close(); server.stop(); try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class DriverFixtureState {
    var allowed = true
    var commands: [ComputerUseBrowserDOMCommand] = []
    var onCommand: ((ComputerUseBrowserDOMCommand) -> Void)?
    var onMayAct: (() -> Void)?
    var writes = 0
    var onWrite: (() -> Void)?
    var failureAtWrite: Int?
}

@MainActor
final class DriverGoalFixture: ComputerUseBrowserGoalPlanning {
    let base = BrowserResearchGoalFixture()
    var select: ((ComputerUseBrowserGoalInput) throws -> String)?
    var unsupported = false
    var inputs: [ComputerUseBrowserGoalInput] = []
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        inputs.append(input)
        if let select { return try .decode(content: select(input), input: input) }
        if !unsupported { return try await base.propose(input) }
        let rows: [[String: Any]] = input.userTurns.enumerated().map {
            ["turn":$0.offset, "source":$0.element, "role":"unsupported", "field":"other", "relation":"unspecified", "values":[]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["disposition":"unsupported", "requirements":rows,
            "question":["topic":"none", "requirements":[]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

@MainActor
final class DriverSearchFixture: ComputerUseBrowserSearchPlanning {
    var inputs: [ComputerUseBrowserGoalProposal] = []
    var empty = false
    var beforeReply: (@MainActor () async -> Void)?
    func propose(_ interpretation: ComputerUseBrowserGoalProposal) async throws -> ComputerUseBrowserSearchQuery {
        inputs.append(interpretation)
        if let beforeReply { await beforeReply() }
        return try .decode(content: empty ? #"{"terms":[]}"# : #"{"terms":[{"requirement":0,"text":"concerts"}]}"#, interpretation: interpretation)
    }
}

@MainActor
final class DriverPlanningFixture: ComputerUseBrowserResearchPlanning {
    let provider: ComputerUseBrowserSearchProvider
    var providerEnabled = true
    var providerCalls = 0
    var choices: [Bool] = []
    var invalidChoice = false
    var allowedOrigins: [ComputerUseBrowserSourceOrigin]?
    var excludedOrigins: [ComputerUseBrowserSourceOrigin] = []
    var answerExcludedOrigins: [ComputerUseBrowserSourceOrigin] = []
    var goals: [ComputerUseBrowserGoalInput] = []
    var histories: [[ComputerUseBrowserResearchVisit]] = []
    var evidenceSnapshots: [ComputerUseBrowserResearchEvidence?] = []
    var beforeSelection: (@MainActor () async -> Void)?
    init(provider: ComputerUseBrowserSearchProvider) { self.provider = provider }
    func sources(for interpretation: ComputerUseBrowserResearchTask.Interpretation) throws -> ComputerUseBrowserResearchSources? {
        providerCalls += 1
        guard providerEnabled else { return nil }
        return try .init(goal: interpretation.proposal.input, provider: provider, allowedOrigins: allowedOrigins,
            excludedOrigins: excludedOrigins, answerExcludedOrigins: answerExcludedOrigins)
    }
    func selectLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence? = nil) async throws -> ComputerUseBrowserResearchTask.LinkChoice? {
        goals.append(goal); histories.append(history); evidenceSnapshots.append(evidence)
        if let beforeSelection { await beforeSelection() }
        guard !choices.isEmpty, choices.removeFirst() else { return nil }
        let candidate = try XCTUnwrap(candidates.candidates.first)
        if invalidChoice { return .init(candidateID: candidate.id, linkID: "not-observed") }
        return .init(candidateID: candidate.id, linkID: try XCTUnwrap(candidate.selectedLinkIDs.first))
    }
}

@MainActor
final class BrowserResearchActionFixture: ComputerUseBrowserActionPlanning {
    var select: ((ComputerUseBrowserActionInput) throws -> String)?
    var beforeReply: (@MainActor () async throws -> Void)?
    private(set) var inputs: [ComputerUseBrowserActionInput] = []
    private(set) var steps: [ComputerUseBrowserActionProposal.Step] = []
    func propose(_ input: ComputerUseBrowserActionInput) async throws -> ComputerUseBrowserActionProposal {
        inputs.append(input)
        if let beforeReply { try await beforeReply() }
        let proposal = try ComputerUseBrowserActionProposal.decode(content: select?(input) ?? #"{"read_results":true}"#, input: input)
        steps.append(proposal.step)
        return proposal
    }
}
@MainActor
final class BrowserResearchFormFixture: ComputerUseBrowserFormPlanning {
    var select: ((ComputerUseBrowserResearchFormInput) throws -> String)?
    var content = #"{"unavailable":true}"#
    var beforeReply: (@MainActor () async throws -> Void)?
    private(set) var inputs: [ComputerUseBrowserResearchFormInput] = []
    func propose(_ input: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserFormProposal {
        inputs.append(input)
        if let beforeReply { try await beforeReply() }
        return try .decode(content: select?(input) ?? content, input: input)
    }
}
