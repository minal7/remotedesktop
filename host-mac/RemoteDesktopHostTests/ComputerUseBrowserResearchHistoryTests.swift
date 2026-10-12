import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchHistoryTests: XCTestCase {
    func testNativeHistoryTraversesBackAndForwardAndExplicitlyRevisitsAnEvictedGET() async throws {
        let fixture = try await ResearchHistoryFixture.make()
        defer { fixture.close() }
        let owner = try fixture.owner(), original = owner.input
        let details = try await owner.revalidateCandidates()
        let back = try XCTUnwrap(details.historyOptions.first { $0.visit == 0 })
        XCTAssertEqual(back.mode, .back)
        let returned = try await owner.revisitAfterReading(back)
        XCTAssertEqual(returned.document.committedURL, fixture.base.appendingPathComponent("search").appending(queryItems: [.init(name: "q", value: "concerts")]))
        let afterBack = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        XCTAssertEqual(afterBack.attempts.last?.historySourceOperationID, back.operationID)
        XCTAssertEqual(afterBack.attempts.last?.outcome, .documentCommitted)
        XCTAssertNotNil(afterBack.attempts.last?.commitBasis)
        if #available(macOS 26.0, *) {
            let decision = try XCTUnwrap(afterBack.observations.first {
                $0.phase == .historyRequest && $0.attemptID == afterBack.attempts.last?.id
            })
            XCTAssertEqual(decision.binding, .exactHistoryItem); XCTAssertEqual(decision.decision, .allowed)
            XCTAssertNotNil(decision.instantBack)
            if afterBack.attempts.last?.commitBasis == .instantBackHistoryItem { XCTAssertEqual(decision.instantBack, true) }
        }
        let search = try await owner.readCandidates(), forward = try XCTUnwrap(search.historyOptions.first { $0.visit == 1 })
        XCTAssertEqual(forward.mode, .forward, "A real history traversal preserves the forward entry")
        let resumed = try await owner.revisitAfterReading(forward)
        XCTAssertEqual(resumed.document.committedURL, fixture.base.appendingPathComponent("details"))
        let afterForward = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        XCTAssertEqual(afterForward.attempts.last?.historySourceOperationID, forward.operationID)
        let calls = fixture.server.count("/details")
        let replay = try await owner.resumeHistoryNavigation()
        XCTAssertEqual(replay, resumed)
        XCTAssertEqual(fixture.server.count("/details"), calls)
        XCTAssertEqual(try fixture.browser.navigationDispatchHistory(taskID: owner.taskID).attempts, afterForward.attempts,
            "Replaying a confirmed history result cannot create another native dispatch")
        let reread = try await owner.readCandidates(), toSearch = try XCTUnwrap(reread.historyOptions.first { $0.mode == .back })
        _ = try await owner.revisitAfterReading(toSearch)
        let again = try await owner.readCandidates(), oldForward = try XCTUnwrap(again.historyOptions.first { $0.mode == .forward })
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "branch-to-beta", to: fixture.base.appendingPathComponent("beta"))
        let branched = try await owner.readCandidates()
        let revisit = try XCTUnwrap(branched.historyOptions.first { $0.operationID == oldForward.operationID })
        XCTAssertEqual(revisit.mode, .revisit)
        XCTAssertThrowsError(try fixture.browser.validateHistoryRefresh(oldForward.target, replacement: revisit.target),
            "An unsent history traversal cannot silently turn into a fresh GET")
        let before = fixture.server.count("/details")
        _ = try await owner.revisitAfterReading(revisit)
        XCTAssertEqual(fixture.server.count("/details"), before + 1)
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink, .revisit, .revisit, .revisit, .revisit])
        let native = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        XCTAssertEqual(native.attempts.count, owner.confirmedNavigationHistory.count + 1,
            "The direct native branch must remain visible even though it has no owner-confirmed visit")
        XCTAssertTrue(native.attempts.contains { $0.operationID == "branch-to-beta" && $0.historySourceOperationID == nil })
        XCTAssertNil(native.attempts.last?.historySourceOperationID, "An evicted-page GET is not a native Back/Forward restoration")
        XCTAssertEqual(native.attempts.last?.commitBasis, .responseAndFinish)
        let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: native)
        XCTAssertEqual(episodes.matchedCommittedAttemptCount, native.attempts.count)
        XCTAssertFalse(episodes.gaps.contains(.historySourceMissing))
        XCTAssertFalse(episodes.gaps.contains(.instantBackApprovalMissing))
        XCTAssertFalse(episodes.gaps.contains(.unmatchedCommittedAttempt))
    }

    func testActionAndResultContractsBindOfferedVisitsAndCountTheWholeRequest() async throws {
        let fixture = try await ResearchHistoryFixture.make()
        defer { fixture.close() }
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = action.input, option = try XCTUnwrap(input.historyOptions.first)
        XCTAssertEqual(option.mode, .back); XCTAssertTrue(input.needsPlanningDecision); XCTAssertFalse(input.needsFormDecision)
        let context = try object(input.contextJSON)
        XCTAssertEqual(context["version"] as? Int, 7)
        XCTAssertFalse(input.contextJSON.contains(fixture.base.absoluteString))
        XCTAssertFalse(input.contextJSON.contains(option.operationID))
        XCTAssertEqual((context["goal"] as? [String: Any])?["request"] as? String, owner.input.prompt)
        let transport = HistoryActionTransport(visit: option.visit)
        let local = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
        let reply = try await local.propose(input)
        XCTAssertEqual(reply.step, .revisit(option.visit))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        let body = try object(String(decoding: XCTUnwrap(requests[0].httpBody), as: UTF8.self))
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_research_action_v7")
        for bad in [#"{"revisit":true}"#, #"{"revisit":0.5}"#, #"{"revisit":999}"#, #"{"revisit":0,"url":"https://example.com"}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: bad, input: input))
        }
        let page = try await owner.readCandidates(), archive = try owner.researchEvidence(for: owner.input)
        let resultInput = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: page,
            history: owner.confirmedNavigationHistory, evidence: archive, allowsAnswer: true)
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: page,
            history: [], evidence: archive, allowsAnswer: true), "Visit ordinals require their original native history")
        let result = try ComputerUseBrowserLinkProposal.decode(content: "{\"revisit\":\(option.visit)}", input: resultInput)
        XCTAssertEqual(try result.requestedHistory(for: resultInput)?.operationID, option.operationID)
        XCTAssertThrowsError(try result.choice(for: resultInput))
        let legacy = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: page, history: owner.confirmedNavigationHistory)
        XCTAssertThrowsError(try ComputerUseBrowserLinkProposal.decode(content: "{\"revisit\":\(option.visit)}", input: legacy))
        XCTAssertThrowsError(try fixture.browser.historyOption(visit: 0, operationID: "invented", evidence: input.evidence))
        owner.pause()
        XCTAssertThrowsError(try owner.validateDriverContinuation(owner.input))
        do { _ = try await owner.revisitAfterReading(option); XCTFail("Pause closes history action admission") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
    }

    func testPausedUnsentHistoryKeepsItsJournalAndResumesTheSameVisitOnce() async throws {
        let fixture = try await ResearchHistoryFixture.make()
        defer { fixture.close() }
        let owner = try fixture.owner(), reading = try await owner.revalidateCandidates()
        let option = try XCTUnwrap(reading.historyOptions.first)
        fixture.state.onWrite = { fixture.state.onWrite = nil; owner.pause() }
        do { _ = try await owner.revisitAfterReading(option); XCTFail("Pause must retain the unsent history stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.hasPendingHistoryNavigation)
        let before = try historyJournal(fixture)
        XCTAssertEqual(before.statuses, [.planned])
        try await owner.resumeAfterUserControl()
        let receipt = try await owner.resumeHistoryNavigation()
        let after = try historyJournal(fixture)
        XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.statuses, [.verified])
        XCTAssertFalse(owner.hasPendingHistoryNavigation)
        let counts = [fixture.server.count("/search?q=concerts"), fixture.server.count("/details")]
        let replay = try await owner.resumeHistoryNavigation()
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual([fixture.server.count("/search?q=concerts"), fixture.server.count("/details")], counts)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink, .revisit])
    }

    func testAnUncertainHistoryAttemptCannotBeRetriedUnderANewOperation() async throws {
        let fixture = try await ResearchHistoryFixture.make()
        defer { fixture.close() }
        let owner = try fixture.owner(), reading = try await owner.revalidateCandidates(), option = try XCTUnwrap(reading.historyOptions.first)
        let beforeDocument = fixture.browser.currentDocument(taskID: owner.taskID)
        fixture.state.failureAtWrite = fixture.state.writes + 2 // Durable attempted replacement fails before WebKit dispatch.
        do { _ = try await owner.revisitAfterReading(option); XCTFail("The failed attempt cannot publish success") }
        catch { XCTAssertTrue(owner.hasPendingHistoryNavigation) }
        fixture.state.failureAtWrite = nil
        let saved = try historyJournal(fixture)
        for _ in 0..<2 {
            do { _ = try await owner.resumeHistoryNavigation(); XCTFail("An ambiguous attempt cannot repeat history navigation") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationUncertain) }
        }
        XCTAssertEqual(try historyJournal(fixture).taskID, saved.taskID)
        XCTAssertEqual(fixture.browser.currentDocument(taskID: owner.taskID), beforeDocument)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink])
        XCTAssertTrue(owner.hasPendingHistoryNavigation)
        let refused = try await owner.retirePendingUnsentHistoryNavigation()
        XCTAssertNil(refused); XCTAssertTrue(owner.retiredHistoryNavigations.isEmpty)
        XCTAssertNil(try historyJournal(fixture).retirementDigest)
        XCTAssertTrue(owner.hasPendingHistoryNavigation, "An attempted record is never converted to a new selection")
    }

    func testRetirementRejectsOldNativeAndReopenedJournalExecutionEvenIfTheTombstoneDisappears() async throws {
        let (fixture, option) = try await pausedBackVisit()
        defer { fixture.close() }
        let owner = try fixture.owner(), original = owner.input, saved = try historyJournal(fixture), operation = saved.stepIDs[0]
        try await owner.resumeAfterUserControl()
        let retired = try await owner.retirePendingUnsentHistoryNavigation()
        let receipt = try XCTUnwrap(retired), tombstone = try historyJournal(fixture)
        XCTAssertEqual(receipt.digest, tombstone.retirementDigest); XCTAssertEqual(tombstone.statuses, [.planned])
        XCTAssertEqual(owner.retiredHistoryNavigations, [receipt]); XCTAssertEqual(owner.input, original)
        XCTAssertFalse(owner.hasPendingNavigation)
        do { _ = try await fixture.browser.openObservedDestination(option.target, operationID: operation); XCTFail("Native revocation survives stale callers") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationRetired) }
        do { _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: operation, to: fixture.base.appendingPathComponent("search")); XCTFail("Generic native loading cannot bypass revocation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationRetired) }
        let reopened = ComputerUseBrowserNavigationTask(browser: fixture.browser, journalDirectory: historyDirectory(fixture))
        do { _ = try await reopened.openObservedDestination(option.target, promptDigest: owner.input.rootDigest, operationID: operation, willBeginEffect: {}); XCTFail("A new adapter cannot execute the retired journal") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        var prepares = 0
        do { _ = try await reopened.replanUnsentObservedDestination(option.target, promptDigest: owner.input.rootDigest, operationID: operation,
            prepare: { prepares += 1; return option.target }); XCTFail("A tombstone is not a planned rebind") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        XCTAssertThrowsError(try reopened.resolveUnconfirmedObservedDestination(option.target, replacement: option.target,
            promptDigest: owner.input.rootDigest, operationID: operation, checkCurrent: {}))
        let files = try FileManager.default.contentsOfDirectory(at: historyDirectory(fixture).appendingPathComponent("Observed Destinations"), includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: XCTUnwrap(files.first { $0.pathExtension == "json" }))
        do { _ = try await reopened.replanUnsentObservedDestination(option.target, promptDigest: owner.input.rootDigest, operationID: operation,
            prepare: { prepares += 1; return option.target }); XCTFail("Missing disk state cannot undo native revocation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationRetired) }
        XCTAssertEqual(prepares, 0)
        XCTAssertEqual(fixture.server.count("/details"), 1); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testFailedRetirementWriteBlocksOldStageUntilTheExactTombstoneIsDurable() async throws {
        let (fixture, _) = try await pausedBackVisit()
        defer { fixture.close() }
        let owner = try fixture.owner(), before = try historyJournal(fixture)
        try await owner.resumeAfterUserControl()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        do { _ = try await owner.retirePendingUnsentHistoryNavigation(); XCTFail("Do not clear the stage after an unconfirmed write") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        let uncertain = try historyJournal(fixture), writes = fixture.state.writes
        XCTAssertNotNil(uncertain.retirementDigest); XCTAssertEqual(uncertain.statuses, before.statuses)
        XCTAssertTrue(owner.hasPendingHistoryNavigation); XCTAssertTrue(owner.retiredHistoryNavigations.isEmpty)
        fixture.state.failureAtWrite = nil
        do { _ = try await owner.resumeHistoryNavigation(); XCTFail("Only retirement can resume now") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchHistoryNavigation.Failure, .retirementPending) }
        _ = try await owner.retirePendingUnsentHistoryNavigation()
        XCTAssertEqual(fixture.state.writes, writes + 1, "Retry flushes the same retirement without executing navigation")
        XCTAssertEqual(try historyJournal(fixture), uncertain)
        XCTAssertEqual(owner.retiredHistoryNavigations.first?.digest, uncertain.retirementDigest)
        XCTAssertFalse(owner.hasPendingHistoryNavigation)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink])
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testPauseAfterRetirementWriteRetainsItsReceiptThroughExplicitHandback() async throws {
        let (fixture, _) = try await pausedBackVisit()
        defer { fixture.close() }
        let owner = try fixture.owner(), original = owner.input
        try await owner.resumeAfterUserControl()
        fixture.state.onWrite = { fixture.state.onWrite = nil; owner.pause() }
        do { _ = try await owner.retirePendingUnsentHistoryNavigation(); XCTFail("Late Pause remains visible") }
        catch { XCTAssertTrue(error is CancellationError) }
        let saved = try historyJournal(fixture), writes = fixture.state.writes
        XCTAssertNotNil(saved.retirementDigest); XCTAssertTrue(owner.hasPendingHistoryNavigation)
        try await owner.resumeAfterUserControl()
        let retired = try await owner.retirePendingUnsentHistoryNavigation()
        XCTAssertEqual(retired?.digest, saved.retirementDigest); XCTAssertEqual(fixture.state.writes, writes)
        XCTAssertFalse(owner.hasPendingHistoryNavigation); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(owner.retiredHistoryNavigations.count, 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testRetirementResolvesAnUnconfirmedPageRebindingWithoutLosingTheOriginalOperation() async throws {
        let (fixture, option) = try await pausedBackVisit()
        defer { fixture.close() }
        let owner = try fixture.owner(), before = try historyJournal(fixture)
        try await owner.resumeAfterUserControl()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        do { _ = try await owner.resumeHistoryNavigation(); XCTFail("Retain both known bindings after an unconfirmed replacement") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        let replacement = try historyJournal(fixture)
        XCTAssertEqual(replacement.statuses, [.planned]); XCTAssertEqual(replacement.stepIDs, before.stepIDs)
        XCTAssertNotEqual(replacement.contractDigest, before.contractDigest)
        fixture.state.failureAtWrite = nil
        let retired = try await owner.retirePendingUnsentHistoryNavigation(), final = try historyJournal(fixture)
        XCTAssertEqual(final.contractDigest, replacement.contractDigest); XCTAssertEqual(final.taskID, before.taskID)
        XCTAssertEqual(final.retirementDigest, retired?.digest); XCTAssertNotNil(retired)
        XCTAssertFalse(owner.hasPendingHistoryNavigation)
        do { _ = try await fixture.browser.openObservedDestination(option.target, operationID: before.stepIDs[0]); XCTFail("The old binding cannot bypass the resolved retirement") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationRetired) }
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testCompetingLeaseAndForeignJournalCannotRetireThePendingVisit() async throws {
        let (fixture, _) = try await pausedBackVisit()
        defer { fixture.close() }
        let owner = try fixture.owner(), saved = try historyJournal(fixture)
        try await owner.resumeAfterUserControl()
        let directory = historyDirectory(fixture).appendingPathComponent("Observed Destinations")
        let store = try ComputerUseTaskJournalStore(directory: directory), lease = try store.acquireExecution(taskID: saved.taskID, expected: saved)
        do { _ = try await owner.retirePendingUnsentHistoryNavigation(); XCTFail("A different executor owns the operation") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .busy) }
        lease.release()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.pathExtension == "json" }), bytes = try Data(contentsOf: file)
        let foreign = ComputerUseTaskJournal(taskID: saved.taskID, promptDigest: String(repeating: "a", count: 64),
            contractDigest: saved.contractDigest, stepIDs: saved.stepIDs, statuses: saved.statuses)
        try JSONEncoder().encode(foreign).write(to: file)
        do { _ = try await owner.retirePendingUnsentHistoryNavigation(); XCTFail("A foreign binding is not an absence proof") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        XCTAssertTrue(owner.retiredHistoryNavigations.isEmpty); XCTAssertTrue(owner.hasPendingHistoryNavigation)
        try bytes.write(to: file)
        let retired = try await owner.retirePendingUnsentHistoryNavigation()
        XCTAssertNotNil(retired); XCTAssertFalse(owner.hasPendingHistoryNavigation)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testConfirmedHistoryCannotBeRetiredAndStillReplaysItsReceipt() async throws {
        let fixture = try await ResearchHistoryFixture.make()
        defer { fixture.close() }
        let owner = try fixture.owner(), page = try await owner.revalidateCandidates(), option = try XCTUnwrap(page.historyOptions.first)
        let completed = try await owner.revisitAfterReading(option), before = fixture.server.count("/search?q=concerts")
        let refused = try await owner.retirePendingUnsentHistoryNavigation()
        XCTAssertNil(refused); XCTAssertFalse(try fixture.browser.retireUnsentObservedDestination(option.target, operationID: completed.document.operationID))
        let replay = try await owner.resumeHistoryNavigation()
        XCTAssertEqual(replay, completed); XCTAssertEqual(fixture.server.count("/search?q=concerts"), before)
        XCTAssertEqual(try historyJournal(fixture).statuses, [.verified]); XCTAssertNil(try historyJournal(fixture).retirementDigest)
        XCTAssertTrue(owner.retiredHistoryNavigations.isEmpty)
    }

    private func pausedBackVisit() async throws -> (ResearchHistoryFixture, ComputerUseBrowserHistoryOption) {
        let fixture = try await ResearchHistoryFixture.make()
        do {
            let owner = try fixture.owner(), reading = try await owner.revalidateCandidates(), option = try XCTUnwrap(reading.historyOptions.first)
            fixture.state.onWrite = { fixture.state.onWrite = nil; owner.pause() }
            do { _ = try await owner.revisitAfterReading(option); XCTFail("Pause keeps the planned visit") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try historyJournal(fixture).statuses, [.planned]); XCTAssertTrue(owner.hasPendingHistoryNavigation)
            return (fixture, option)
        } catch { fixture.close(); throw error }
    }

    private func historyDirectory(_ fixture: ResearchHistoryFixture) -> URL { fixture.directory.appendingPathComponent("Research/History") }
    private func historyJournal(_ fixture: ResearchHistoryFixture) throws -> ComputerUseTaskJournal {
        let directory = fixture.directory.appendingPathComponent("Research/History/Observed Destinations")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        return try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: XCTUnwrap(files.first)))
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
}

@MainActor
private struct ResearchHistoryFixture {
    static let root = "research-driver"
    static let prompt = "Find concerts under USD 50. Do not buy."
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    let server: OwnedBrowserHTTPFixture
    let base: URL
    let directory: URL
    let browser: ComputerUseOwnedBrowser
    let navigation: ComputerUseBrowserNavigationTask
    let researchOwner: ComputerUseBrowserResearchTask
    let actions: BrowserResearchActionFixture
    let state: DriverFixtureState

    static func make() async throws -> Self {
        func card(_ destination: String) -> String {
            "<article><h2>Concert Alpha</h2><a href='\(destination)'>Alpha details</a></article>"
        }
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/search?q=concerts": .init(body: card("/details")),
            "/details": .init(body: card("/offers")),
            "/beta": .init(body: card("/more"))
        ])
        let base = try await server.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = DriverFixtureState()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
            state.commands.append(command)
            state.onCommand?(command)
        }, mayAct: {
            state.onMayAct?()
            return state.allowed
        })
        do {
            let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory,
                observedNavigationStore: { location in
                    try .init(directory: location, afterReplacement: {
                        try MainActor.assumeIsolated {
                            state.writes += 1
                            state.onWrite?()
                            if state.failureAtWrite == state.writes {
                                throw ComputerUseTaskJournalStore.StoreError.unavailable
                            }
                        }
                    })
                })
            let goalPlanner = BrowserResearchGoalFixture()
            let resultPlanner = BrowserResearchResultFixture()
            resultPlanner.selectedLinkLabel = "Alpha details"
            let search = DriverSearchFixture()
            let actions = BrowserResearchActionFixture()
            let input = try ComputerUseBrowserGoalInput(taskID: root, prompt: prompt,
                referenceDate: date, timeZoneIdentifier: "America/Los_Angeles")
            let owner = try navigation.prepareResearchTask(taskID: root, prompt: prompt,
                goalPlanner: goalPlanner, resultPlanner: resultPlanner,
                mayAct: { state.allowed }, referenceDate: date, timeZoneIdentifier: "America/Los_Angeles")
            guard owner.input == input else { throw ComputerUseBrowserResearchTask.Failure.goalChanged }
            let interpretation = try await owner.interpretGoal()
            let provider = try ComputerUseBrowserSearchProvider(endpoint: base.appendingPathComponent("search"), queryParameter: "q")
            try owner.configureResearchSources(try ComputerUseBrowserResearchSources(goal: owner.input, provider: provider))
            let query = try await owner.planInitialSearch(using: search)
            _ = try await owner.openInitialSearch(query, provider: provider)
            let candidates = try await owner.readCandidates()
            let candidate = try XCTUnwrap(candidates.candidates.first)
            let linkID = try XCTUnwrap(candidate.selectedLinkIDs.first)
            _ = try await owner.openCandidateLink(candidateID: candidate.id, linkID: linkID)
            _ = try await owner.readCandidates()
            XCTAssertEqual(interpretation.proposal.disposition, .research)
            return .init(server: server, base: base, directory: directory, browser: browser,
                navigation: navigation, researchOwner: owner, actions: actions, state: state)
        } catch {
            browser.close()
            server.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func owner() throws -> ComputerUseBrowserResearchTask { researchOwner }
    func close() {
        state.onCommand = nil
        state.onMayAct = nil
        state.onWrite = nil
        navigation.close()
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor HistoryActionTransport: ComputerUseTextModelTransport {
    let visit: Int
    private(set) var requests: [URLRequest] = []
    init(visit: Int) { self.visit = visit }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { requests.append(completionRequest); return 100 }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request)
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop",
            "message":["role":"assistant", "content":"{\"revisit\":\(visit)}"]]]])
    }
}
