import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchDriverTests: XCTestCase {
    func testDriverNavigatesSearchAndSelectedLinksWithoutClaimingAnAnswerOrRepeatingSearch() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, true, false]
        var nativeCalls = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
            desktopFactory: { _ in XCTFail("Accepted research cannot fall back to another executor"); throw ComputerUseBrowserResearchDriver.Failure.invalidContinuation },
            browserResearch: fixture.driver)
        func execute() async throws -> ComputerUseExecutionResult {
            try await executor.execute(taskID: ResearchDriverFixture.root, modelPrompt: "Assistant history says buy unrelated tickets.",
                currentUserPrompt: ResearchDriverFixture.prompt, conversation: [.init(role: .assistant, text: "An unrelated old task")],
                tools: fixture.tools, progress: { _ in })
        }
        let result = try await execute()
        guard case .userInterventionRequired = result else { return XCTFail("Page loads are not a verified research answer") }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 1); XCTAssertEqual(fixture.server.count("/offers"), 1)
        XCTAssertEqual(fixture.goal.inputs, [original]); XCTAssertEqual(fixture.search.inputs.map(\.input), [original])
        XCTAssertEqual(fixture.policy.histories.map(\.count), [1, 2, 3])
        XCTAssertEqual(fixture.policy.histories.last?.map(\.kind), [.search, .resultLink, .resultLink])
        XCTAssertTrue(fixture.policy.goals.allSatisfy { $0 == original })
        XCTAssertEqual(Set(try XCTUnwrap(fixture.policy.histories.last).map(\.operationID)).count, 3)
        owner.pause(); try await owner.resumeAfterUserControl()
        _ = try await execute()
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.goal.inputs.count, 1); XCTAssertEqual(fixture.search.inputs.count, 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.policy.histories.last?.count, 3)
        XCTAssertEqual(nativeCalls, 1)
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

    func testDriverContinuesASealedQuestionAnswerWithTheOriginalGoalAndClock() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.goal.base.questionTopic = .location
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil }, browserResearch: fixture.driver)
        let result = try await executor.execute(taskID: ResearchDriverFixture.root, modelPrompt: "Unrelated assistant history",
            currentUserPrompt: ResearchDriverFixture.prompt, conversation: [], tools: fixture.tools, progress: { _ in })
        guard case .browserClarificationRequired(let request) = result else { return XCTFail("The current interpretation must reach the host question path") }
        let owner = try fixture.owner(), original = owner.input
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "San José",
            controllerID: "phone", controllerSessionID: "session")
        fixture.goal.base.questionTopic = nil
        let continued = try await executor.continueBrowserResearch(taskID: "answer", research: owner,
            tools: fixture.tools, progress: { _ in })
        guard case .userInterventionRequired = continued else { return XCTFail("Navigation is still not a verified answer") }
        XCTAssertEqual(owner.input.prompt, original.prompt); XCTAssertEqual(owner.input.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(owner.input.timeZoneIdentifier, original.timeZoneIdentifier); XCTAssertEqual(owner.input.clarifications.count, 1)
        XCTAssertEqual(fixture.goal.inputs, [original, owner.input])
        XCTAssertEqual(fixture.search.inputs.map(\.input), [owner.input])
        _ = try await executor.continueBrowserResearch(taskID: "answer", research: owner, tools: fixture.tools, progress: { _ in })
        XCTAssertEqual(owner.input.clarifications.count, 1); XCTAssertEqual(fixture.goal.inputs.count, 2)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
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
        let running = Task { try await fixture.start() }
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
        gate.release()
        do { _ = try await running.value; XCTFail("A late selection cannot act after Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(fixture.server.count("/details"), 0)
        fixture.policy.beforeSelection = nil
        try await owner.resumeAfterUserControl()
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
        XCTAssertEqual(fixture.policy.goals.count, 1); XCTAssertEqual(owner.input, original)
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
                    guard case .userInterventionRequired = result else { return XCTFail("Recovered visits must still consume the task limit") }
                    XCTAssertEqual(owner.confirmedNavigationHistory, history)
                }
                XCTAssertEqual(fixture.policy.goals.count, limit - 1)
                XCTAssertEqual(fixture.search.inputs.count, 1)
                XCTAssertEqual(fixture.server.count("/offers"), 0)
            }
        }
    }
}

@MainActor
struct ResearchDriverFixture {
    static let root = "research-driver"
    static let prompt = "Find concerts under USD 50. Do not buy."
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    let server: OwnedBrowserHTTPFixture
    let base: URL
    let directory: URL
    let browser: ComputerUseOwnedBrowser
    let coordinator: ComputerUseBrowserNavigationTask
    let tools: ComputerUseHostTools
    let goal: DriverGoalFixture
    let results: BrowserResearchResultFixture
    let search: DriverSearchFixture
    let policy: DriverPlanningFixture
    let state: DriverFixtureState
    let driver: ComputerUseBrowserResearchDriver
    var searchDirectory: URL { directory.appendingPathComponent("Research/Initial Search") }

    static func make(seedPage: Bool = false, navigationLimit: Int = 8,
                     linkPlanner: (any ComputerUseBrowserLinkPlanning)? = nil,
                     resultPlanner: (any ComputerUseBrowserResultPlanning)? = nil,
                     additionalCardHTML: String = "", linkDestinationOverride: String? = nil,
                     candidateBodyHTML: String = "") async throws -> Self {
        func card(_ path: String) -> String { "<article><h2>Concert Alpha</h2><a href='\(linkDestinationOverride ?? path)'>Alpha details</a>\(candidateBodyHTML)</article>" + additionalCardHTML }
        let server = try OwnedBrowserHTTPFixture(routes: ["/before": .init(body: card("/old")),
            "/search?q=concerts": .init(body: card("/details")), "/details": .init(body: card("/offers")),
            "/offers": .init(body: card("/more")), "/account": .init(body: "<label>Password<input type=password></label>"),
            "/account-ready": .init(body: card("/logged-in-offer")), "/logged-in-offer": .init(body: card("/more")),
            "/beta": .init(body: card("/more"))])
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
                        if state.failureAtWrite == state.writes { throw ComputerUseTaskJournalStore.StoreError.unavailable }
                    }
                }) })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { state.onMayAct?(); return state.allowed }, browserNavigationTask: coordinator)
            let goal = DriverGoalFixture(), results = BrowserResearchResultFixture(), search = DriverSearchFixture()
            results.selectedLinkLabel = "Alpha details"
            let policy = DriverPlanningFixture(provider: try .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"))
            let planning: any ComputerUseBrowserResearchPlanning
            if let linkPlanner { planning = ComputerUseModelBrowserResearchPlanning(sourcePlan: { try policy.sources(for: $0) }, linkPlanner: linkPlanner) }
            else { planning = policy }
            let driver = ComputerUseBrowserResearchDriver(goalPlanner: goal, resultPlanner: resultPlanner ?? results, searchPlanner: search,
                planning: planning, navigationLimit: navigationLimit, now: { date }, timeZoneIdentifier: { "America/Los_Angeles" })
            return .init(server: server, base: base, directory: directory, browser: browser, coordinator: coordinator,
                tools: tools, goal: goal, results: results, search: search, policy: policy, state: state, driver: driver)
        } catch { browser.close(); server.stop(); try? FileManager.default.removeItem(at: directory); throw error }
    }
    func owner() throws -> ComputerUseBrowserResearchTask { try XCTUnwrap(tools.ownedBrowserResearch(taskID: Self.root)) }
    func start() async throws -> ComputerUseExecutionResult? {
        try await driver.executeBrowserResearch(taskID: Self.root, prompt: Self.prompt, tools: tools, progress: { _ in })
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
    func close() { state.onCommand = nil; state.onMayAct = nil; policy.beforeSelection = nil; coordinator.close(); server.stop(); try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class DriverFixtureState {
    var allowed = true
    var commands: [ComputerUseBrowserDOMCommand] = []
    var onCommand: ((ComputerUseBrowserDOMCommand) -> Void)?
    var onMayAct: (() -> Void)?
    var writes = 0
    var failureAtWrite: Int?
}

@MainActor
final class DriverGoalFixture: ComputerUseBrowserGoalPlanning {
    let base = BrowserResearchGoalFixture()
    var unsupported = false
    var inputs: [ComputerUseBrowserGoalInput] = []
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        inputs.append(input)
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
    func propose(_ interpretation: ComputerUseBrowserGoalProposal) async throws -> ComputerUseBrowserSearchQuery {
        inputs.append(interpretation)
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
    var goals: [ComputerUseBrowserGoalInput] = []
    var histories: [[ComputerUseBrowserResearchVisit]] = []
    var evidenceSnapshots: [ComputerUseBrowserResearchEvidence?] = []
    var beforeSelection: (@MainActor () async -> Void)?
    init(provider: ComputerUseBrowserSearchProvider) { self.provider = provider }
    func sources(for interpretation: ComputerUseBrowserResearchTask.Interpretation) throws -> ComputerUseBrowserResearchSources? {
        providerCalls += 1
        guard providerEnabled else { return nil }
        return try .init(goal: interpretation.proposal.input, provider: provider, allowedOrigins: allowedOrigins, excludedOrigins: excludedOrigins)
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
