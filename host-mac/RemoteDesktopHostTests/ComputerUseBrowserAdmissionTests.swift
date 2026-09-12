import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserAdmissionTests: XCTestCase {
    func testSuccessiveResearchRootsReuseLiveAndStoppedBrowserAccountStateWithoutOldReceipts() async throws {
        for stopped in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/account": .init(body: """
                    <h1>Account ready</h1><script>
                    document.cookie = 'fixtureSession=retained; path=/; SameSite=Lax'; sessionStorage.fixtureSession = 'retained';
                    </script>
                    """),
                "/search?q=concerts": .init(body: """
                    <article><h2>Concert Alpha</h2></article><script>
                    fetch(document.cookie.includes('fixtureSession=retained') && sessionStorage.fixtureSession === 'retained'
                        ? '/session-preserved' : '/session-lost');
                    </script>
                    """),
            ])
            let base = try await server.start()
            defer { server.stop() }
            let directory = temporaryDirectory(), browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
            defer { coordinator.close(); try? FileManager.default.removeItem(at: directory) }
            try browser.claim(taskID: "previous")
            _ = try await browser.navigate(taskID: "previous", operationID: "account-open", to: base.appendingPathComponent("account"))
            var previousRequirement = try XCTUnwrap(browser.handbackRequirement(taskID: "previous", required: true))
            if stopped { browser.stop() }
            var previousOwner: ComputerUseBrowserResearchTask?
            for (index, root) in ["first", "second"].enumerated() {
                let owner = try prepare(coordinator, taskID: root)
                if let previousOwner {
                    do { _ = try await previousOwner.interpretGoal(); XCTFail("The old research root must be retired") }
                    catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
                }
                let interpretation = try await owner.interpretGoal()
                let admitted = try XCTUnwrap(browser.currentDocument(taskID: root))
                XCTAssertEqual(admitted.source, .taskAdmissionObservation)
                XCTAssertNil(browser.receipt(taskID: root, operationID: admitted.operationID), "Admission is an observation, not an action receipt")
                do { try await browser.reacquireAfterUserControl(taskID: previousRequirement.taskID, requirement: previousRequirement); XCTFail("Old handback authority cannot transfer") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
                let result = try await owner.openInitialSearch(query(interpretation.proposal), provider: provider(base))
                XCTAssertEqual(result.taskID, root)
                XCTAssertEqual(result.source, .automationNavigation)
                try await waitUntil { server.count("/session-preserved") == index + 1 }
                XCTAssertEqual(server.count("/session-lost"), 0)
                XCTAssertEqual(server.count("/account"), 1, "Admission never reloads the earlier page")
                XCTAssertEqual(server.count("/search?q=concerts"), index + 1, "Each new root owns exactly its own first search")
                XCTAssertEqual(owner.initialSearchState, .confirmed)
                previousOwner = owner
                previousRequirement = try XCTUnwrap(browser.handbackRequirement(taskID: root, required: true))
            }
        }
    }

    func testAdmissionDetectsExistingLoginBeforeInferenceAndRetainsExplicitHandback() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: """
            <input id='password' type='password' autocomplete='current-password'><h1>Account</h1>
            <script>fetch('/finish-login').then(() => {
                document.getElementById('password').remove(); sessionStorage.fixtureSession = 'retained';
                history.replaceState({}, '', '/account'); fetch('/logged-in');
            });</script>
            """), "/finish-login": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let directory = temporaryDirectory(), browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { coordinator.close(); try? FileManager.default.removeItem(at: directory) }
        try browser.claim(taskID: "previous")
        _ = try await browser.navigate(taskID: "previous", operationID: "login-open", to: base.appendingPathComponent("login"))
        let planner = BrowserResearchGoalFixture(), owner = try prepare(coordinator, planner: planner, mayAct: { allowed })
        let original = owner.input
        do { _ = try await owner.interpretGoal(); XCTFail("Visible credentials require manual control before inference") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertTrue(planner.inputs.isEmpty)
        XCTAssertEqual(browser.taskID, owner.taskID)
        let session = try XCTUnwrap(browser.handbackRequirement(taskID: owner.taskID, required: true))
        owner.pause(); allowed = false
        try await waitUntil { server.count("/finish-login") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/logged-in") == 1 && browser.hasPageAwaitingHandback }
        allowed = true
        try await owner.resumeAfterUserControl()
        let interpretation = try await owner.interpretGoal()
        _ = try await owner.openInitialSearch(query(interpretation.proposal), provider: provider(base))
        XCTAssertEqual(planner.inputs, [original])
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(browser.handbackRequirement(taskID: owner.taskID, required: true), session)
        XCTAssertEqual(server.count("/login"), 1); XCTAssertEqual(server.count("/search?q=concerts"), 1)
    }

    func testPauseDuringAdmissionKeepsOldBrowserUntilExplicitResumeAndCannotBeOverwritten() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory(), state = BrowserAdmissionFixtureState()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { state.onCommand?($0) }, mayAct: { true })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { state.onCommand = nil; coordinator.close(); try? FileManager.default.removeItem(at: directory) }
        try browser.claim(taskID: "previous")
        let previous = try await browser.navigate(taskID: "previous", operationID: "previous-open", to: base.appendingPathComponent("page"))
        let planner = BrowserResearchGoalFixture(), owner = try prepare(coordinator, planner: planner)
        state.onCommand = { command in
            guard command == .pageIdentity else { return }
            state.onCommand = nil
            owner.pause()
            do {
                _ = try self.prepare(coordinator, taskID: "replacement")
                XCTFail("Paused admission must keep its current owner until the callback returns")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        }
        do { _ = try await owner.interpretGoal(); XCTFail("Pause cancels admission before ownership transfers") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(planner.inputs.isEmpty)
        XCTAssertEqual(browser.taskID, "previous")
        try await browser.waitForDOMCompletion(document: previous)
        try await owner.resumeAfterUserControl()
        XCTAssertEqual(browser.taskID, owner.taskID)
        let history = try browser.navigationDispatchHistory(taskID: owner.taskID)
        let controlAssessment = ComputerUseBrowserResultAssessment.ControlHistory(history: history)
        XCTAssertEqual(controlAssessment.admittedContextCount, 1)
        XCTAssertEqual(controlAssessment.completedWorkflowResumeCount, 1)
        XCTAssertEqual(controlAssessment.completedNativeHandbackCount, 0)
        XCTAssertFalse(controlAssessment.gaps.contains(.resumeWithoutNativeHandback))
        XCTAssertFalse(controlAssessment.gaps.contains(.unclosedPause))
        let admitted = try XCTUnwrap(history.controlEvents.first { $0.phase == .workflowContextAdmitted })
        let resumed = try XCTUnwrap(history.controlEvents.first { $0.phase == .workflowResumed })
        XCTAssertNotNil(admitted.workflowOperationID); XCTAssertEqual(admitted.workflowOperationID, resumed.workflowOperationID)
        XCTAssertEqual(admitted.handback, resumed.handback); XCTAssertLessThan(admitted.order, resumed.order)
        XCTAssertFalse(history.controlEvents.contains { $0.phase == .nativeReacquisitionStarted },
            "Admission of a new research root is not a fabricated reacquisition of the previous task")
        _ = try await owner.interpretGoal()
        XCTAssertEqual(planner.inputs, [owner.input])
        XCTAssertEqual(server.count("/page"), 1)
    }

    func testBusyBrowserAdmissionCanResumeSameNewGoalAfterPreviousLoadSettles() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)]), base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory(), browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { coordinator.close(); try? FileManager.default.removeItem(at: directory) }
        try browser.claim(taskID: "previous")
        let loading = Task { try await browser.navigate(taskID: "previous", operationID: "previous-open", to: base.appendingPathComponent("held")) }
        defer { loading.cancel() }
        try await waitUntil { server.count("/held") == 1 }
        let planner = BrowserResearchGoalFixture(), owner = try prepare(coordinator, planner: planner)
        let original = owner.input
        do { _ = try await owner.interpretGoal(); XCTFail("Busy admission requests user control, not a terminal goal failure") }
        catch { XCTAssertEqual((error as? ComputerUseBrowserResearchAdmissionPause)?.reason, .busy) }
        XCTAssertTrue(planner.inputs.isEmpty)
        XCTAssertEqual(browser.taskID, "previous")
        owner.pause()
        server.releaseHeldResponses()
        _ = try await loading.value
        try await owner.resumeAfterUserControl()
        _ = try await owner.interpretGoal()
        XCTAssertEqual(browser.taskID, owner.taskID)
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(planner.inputs, [original])
        XCTAssertEqual(server.count("/held"), 1)
    }

    func testResearchReplacementWaitsForRetiredPredecessorToActuallyUnwind() async throws {
        let directory = temporaryDirectory(), browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let gate = BrowserResearchGate(), planner = BrowserResearchGoalFixture()
        let worker = ComputerUsePlanningWorker()
        defer { gate.release(); coordinator.close(); try? FileManager.default.removeItem(at: directory) }
        planner.beforeReply = { await gate.suspend() }
        let previous = try prepare(coordinator, taskID: "previous", planner: planner, planningWorker: worker)
        let delivered = expectation(description: "Retirement delivered before planner return")
        let running = Task { defer { delivered.fulfill() }; return try await previous.interpretGoal() }
        try await gate.waitUntilStarted()
        previous.retire()
        XCTAssertThrowsError(try prepare(coordinator)) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .busy)
        }
        XCTAssertTrue(coordinator.researchTask(taskID: "previous") === previous)
        await fulfillment(of: [delivered], timeout: 1)
        let next = try prepare(coordinator, planningWorker: worker)
        do { _ = try await next.interpretGoal(); XCTFail("Replacing a retired owner cannot bypass the shared model permit") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        gate.release()
        do { _ = try await running.value; XCTFail("A retired owner's late proposal cannot publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitForAvailablePlanningWorker(worker)
        _ = try await next.interpretGoal()
        XCTAssertFalse(browser.hasSession, "Text-only planning still does not allocate a browser")
    }

    func testAdmissionCannotClaimSessionStoppedOrClosedDuringIdentityRead() async throws {
        for closes in [false, true] {
            let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
            defer { server.stop() }
            let directory = temporaryDirectory(), state = BrowserAdmissionFixtureState()
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { state.onCommand?($0) }, mayAct: { true })
            let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
            defer { state.onCommand = nil; coordinator.close(); try? FileManager.default.removeItem(at: directory) }
            try browser.claim(taskID: "previous")
            _ = try await browser.navigate(taskID: "previous", operationID: "previous-open", to: base.appendingPathComponent("page"))
            let planner = BrowserResearchGoalFixture(), owner = try prepare(coordinator, planner: planner)
            state.onCommand = { command in
                guard command == .pageIdentity else { return }
                state.onCommand = nil
                if closes { browser.close() } else { browser.stop() }
            }
            do { _ = try await owner.interpretGoal(); XCTFail("An identity callback from the retired session cannot claim it") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            XCTAssertNil(browser.taskID)
            XCTAssertEqual(browser.hasSession, !closes)
            XCTAssertTrue(planner.inputs.isEmpty)
            XCTAssertEqual(server.count("/page"), 1)
        }
    }

    func testSearchFromAdmittedPageRetainsItsPlannedBindingWhenPageChangesDuringPause() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <h1>Original page</h1><script>fetch('/change').then(() => {
                history.replaceState({}, '', '/changed'); fetch('/changed-ready');
            });</script>
            """), "/change": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let directory = temporaryDirectory(), state = BrowserAdmissionFixtureState()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { state.onCommand?($0) }, mayAct: { allowed })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { state.onCommand = nil; coordinator.close(); try? FileManager.default.removeItem(at: directory) }
        try browser.claim(taskID: "previous")
        _ = try await browser.navigate(taskID: "previous", operationID: "previous-open", to: base.appendingPathComponent("page"))
        let owner = try prepare(coordinator, mayAct: { allowed }), interpretation = try await owner.interpretGoal()
        let original = try XCTUnwrap(browser.currentDocument(taskID: owner.taskID))
        state.onCommand = { command in
            guard command == .pageSnapshot, owner.hasPendingNavigation else { return }
            state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openInitialSearch(query(interpretation.proposal), provider: provider(base)); XCTFail("Pause must retain the prepared stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await browser.waitForDOMCompletion(document: original)
        let before = try initialSearchJournal(directory)
        XCTAssertEqual(before.statuses, [.planned])
        allowed = false
        try await waitUntil { server.count("/change") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/changed-ready") == 1 && browser.hasPageAwaitingHandback }
        allowed = true
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.resumeInitialSearch(); XCTFail("A different page cannot silently replace the retained starting-page binding") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(try initialSearchJournal(directory), before)
        XCTAssertEqual(server.count("/search?q=concerts"), 0)
        XCTAssertEqual(owner.initialSearchState, .pending)
        let originalGoal = owner.input
        let refreshed = try await owner.refreshInitialSearchStartingPage()
        XCTAssertEqual(refreshed, .updated)
        let rebound = try initialSearchJournal(directory)
        XCTAssertEqual(rebound.taskID, before.taskID); XCTAssertEqual(rebound.promptDigest, before.promptDigest)
        XCTAssertEqual(rebound.stepIDs, before.stepIDs); XCTAssertEqual(rebound.statuses, [.planned])
        XCTAssertNotEqual(rebound.contractDigest, before.contractDigest)
        XCTAssertEqual(server.count("/search?q=concerts"), 0, "Refresh is observation and binding replacement only")
        let samePage = try await owner.refreshInitialSearchStartingPage()
        XCTAssertEqual(samePage, .unchanged)
        _ = try await owner.resumeInitialSearch()
        XCTAssertEqual(owner.input, originalGoal)
        XCTAssertEqual(server.count("/search?q=concerts"), 1)
        let finished = try await owner.refreshInitialSearchStartingPage()
        XCTAssertEqual(finished, .noPendingStage)
    }

    func testAdmittedInitialSearchSurvivesUnchangedHandbackAndFreshPageSnapshots() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory(), state = BrowserAdmissionFixtureState()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { state.onCommand?($0) }, mayAct: { true })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { state.onCommand = nil; coordinator.close(); try? FileManager.default.removeItem(at: directory) }
        try browser.claim(taskID: "previous")
        _ = try await browser.navigate(taskID: "previous", operationID: "previous-open", to: base.appendingPathComponent("page"))
        let owner = try prepare(coordinator), interpretation = try await owner.interpretGoal()
        let original = try XCTUnwrap(browser.currentDocument(taskID: owner.taskID))
        state.onCommand = { command in
            guard command == .pageSnapshot, owner.hasPendingNavigation else { return }
            state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openInitialSearch(query(interpretation.proposal), provider: provider(base)); XCTFail("Pause cancels dispatch") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await browser.waitForDOMCompletion(document: original)
        let before = try initialSearchJournal(directory)
        XCTAssertEqual(before.statuses, [.planned])
        XCTAssertEqual(server.count("/search?q=concerts"), 0)
        try await owner.resumeAfterUserControl()
        _ = try await owner.resumeInitialSearch()
        let after = try initialSearchJournal(directory)
        XCTAssertEqual(after.contractDigest, before.contractDigest)
        XCTAssertEqual(after.stepIDs, before.stepIDs)
        XCTAssertEqual(after.statuses, [.verified])
        XCTAssertEqual(server.count("/page"), 1); XCTAssertEqual(server.count("/search?q=concerts"), 1)
        XCTAssertEqual(owner.initialSearchState, .confirmed)
    }

    func testBrowserAdmissionRequiresCurrentCoordinatorOwnerAndLiveOperation() async throws {
        let directory = temporaryDirectory(), browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let other = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { coordinator.close(); other.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = try prepare(coordinator)
        _ = try prepare(other)
        for candidate in [coordinator, other] {
            do { _ = try await candidate.admitBrowser(for: owner, admissionID: UUID(), checkCurrent: {}); XCTFail("Equal task text is not an active admission capability") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        }
        owner.retire()
        do { _ = try await coordinator.admitBrowser(for: owner, admissionID: UUID(), checkCurrent: {}); XCTFail("Retirement revokes admission") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        XCTAssertFalse(browser.hasSession)
    }

    private func prepare(_ coordinator: ComputerUseBrowserNavigationTask, taskID: String = "root",
                         planner: BrowserResearchGoalFixture? = nil, mayAct: @escaping @MainActor () -> Bool = { true },
                         planningWorker: ComputerUsePlanningWorker = .init()) throws -> ComputerUseBrowserResearchTask {
        try coordinator.prepareResearchTask(taskID: taskID, prompt: "Find concerts.", goalPlanner: planner ?? BrowserResearchGoalFixture(),
            resultPlanner: BrowserResearchResultFixture(), mayAct: mayAct, referenceDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "America/Los_Angeles", planningWorker: planningWorker)
    }
    private func query(_ proposal: ComputerUseBrowserGoalProposal) throws -> ComputerUseBrowserSearchQuery {
        try .decode(content: #"{"terms":[{"requirement":0,"text":"concerts"}]}"#, interpretation: proposal)
    }
    private func provider(_ base: URL) throws -> ComputerUseBrowserSearchProvider {
        try .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q")
    }
    private func initialSearchJournal(_ directory: URL) throws -> ComputerUseTaskJournal {
        let store = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Research/Initial Search"))
        let id = ComputerUseTaskContract.digest(["browser-initial-search-record-v1", "root"])
        return try XCTUnwrap(store.load(taskID: id))
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BrowserAdmissionFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum BrowserAdmissionFixtureError: Error { case timedOut }
@MainActor
private final class BrowserAdmissionFixtureState {
    var onCommand: ((ComputerUseBrowserDOMCommand) -> Void)?
}
