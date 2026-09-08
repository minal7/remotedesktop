import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserInitialSearchRefreshTests: XCTestCase {
    func testInitialSearchRefreshRequiresReconciliationBeforeAnyReadingForDurableAttempts() async throws {
        for status in [ComputerUseTaskStepStatus.attempted, .uncertain, .verified] {
            let fixture = try await InitialSearchRefreshFixture.make()
            defer { fixture.close() }
            try await fixture.move()
            let store = try ComputerUseTaskJournalStore(directory: fixture.recordDirectory)
            var saved = try fixture.journal(), attempted = saved
            attempted.statuses = [.attempted]
            try store.save(attempted, replacing: saved); saved = attempted
            if status != .attempted {
                var final = saved; final.statuses = [status]
                try store.save(final, replacing: saved)
            }
            let commands = fixture.state.commands
            let result = try await fixture.stage.refreshStartingPage(checkCurrent: {})
            XCTAssertEqual(result, .requiresReconciliation)
            XCTAssertEqual(fixture.state.commands, commands)
            do { _ = try await fixture.stage.open(checkCurrent: {}); XCTFail("A journal without its native receipt cannot authorize a retry") }
            catch ComputerUseTaskExecutionError.uncertainEffect { }
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
        }
    }

    func testInitialSearchRefreshUsesNativeAttemptHistoryEvenWhenJournalStillSaysPlanned() async throws {
        for failed in [false, true] {
            let fixture = try await InitialSearchRefreshFixture.make(searchFails: failed)
            defer { fixture.close() }
            let before = try fixture.journal(), operationID = try XCTUnwrap(before.stepIDs.first)
            do {
                _ = try await fixture.browser.navigate(taskID: "root", operationID: operationID, to: fixture.request.destination)
                XCTAssertFalse(failed)
            } catch { XCTAssertTrue(failed); XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
            XCTAssertTrue(fixture.browser.hasNavigationAttempt(operationID: operationID))
            XCTAssertTrue(fixture.browser.hasObservedNavigationAttempt(operationID: operationID))
            if failed { XCTAssertNil(fixture.browser.receipt(taskID: "root", operationID: operationID)) }
            let commands = fixture.state.commands
            let result = try await fixture.stage.refreshStartingPage(checkCurrent: {})
            XCTAssertEqual(result, .requiresReconciliation)
            XCTAssertEqual(fixture.state.commands, commands, "Native-only attempts must also stop before another page read")
            XCTAssertEqual(try fixture.journal(), before)
            do { _ = try await fixture.stage.open(checkCurrent: {}); XCTFail("A planned file cannot erase native dispatch history") }
            catch ComputerUseTaskExecutionError.uncertainEffect { }
            do { _ = try await fixture.browser.navigate(taskID: "root", operationID: operationID, to: fixture.request.destination); XCTFail("The native adapter cannot repeat an attempted operation ID") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        }
    }

    func testInitialSearchRefreshHoldsExecutionLeaseDuringObservationAndCancellation() async throws {
        let fixture = try await InitialSearchRefreshFixture.make()
        defer { fixture.close() }
        try await fixture.move()
        let before = try fixture.journal()
        var checkedLease = false
        var reading: Task<ComputerUseBrowserInitialSearch.RefreshResult, Error>?
        fixture.state.onCommand = { command in
            guard command == .pageSnapshot else { return }
            fixture.state.onCommand = nil
            do {
                let store = try ComputerUseTaskJournalStore(directory: fixture.recordDirectory)
                let current = try store.load(taskID: before.taskID)
                XCTAssertThrowsError(try store.acquireExecution(taskID: before.taskID, expected: current)) {
                    XCTAssertEqual($0 as? ComputerUseTaskJournalStore.StoreError, .busy)
                }
                checkedLease = true
            } catch { XCTFail("Could not inspect the held execution lease: \(error)") }
            reading?.cancel()
        }
        reading = Task { try await fixture.stage.refreshStartingPage(checkCurrent: {}) }
        do { _ = try await reading?.value; XCTFail("Cancelled observation cannot publish a replacement") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(checkedLease)
        XCTAssertEqual(try fixture.journal(), before)
        let current = try XCTUnwrap(fixture.browser.currentDocument(taskID: "root"))
        try await fixture.browser.waitForDOMCompletion(document: current)
        let result = try await fixture.stage.refreshStartingPage(checkCurrent: {})
        XCTAssertEqual(result, .updated)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
        _ = try await fixture.stage.open(checkCurrent: {})
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testCommittedInitialSearchRefreshSurvivesLateCancellationWithoutRevivingRetirement() async throws {
        for retires in [false, true] {
            let fixture = try await InitialSearchRefreshFixture.make()
            defer { fixture.close() }
            try await fixture.move()
            let before = try fixture.journal()
            var refreshing: Task<ComputerUseBrowserInitialSearch.RefreshResult, Error>?
            fixture.state.onWrite = {
                if retires { fixture.stage.retire() } else { refreshing?.cancel() }
            }
            refreshing = Task { try await fixture.stage.refreshStartingPage(checkCurrent: {}) }
            do { _ = try await refreshing?.value; XCTFail("A late interruption cannot publish refresh success") }
            catch {
                if retires { XCTAssertEqual(error as? ComputerUseBrowserInitialSearchError, .retired) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            fixture.state.onWrite = nil
            let saved = try fixture.journal()
            XCTAssertNotEqual(saved.contractDigest, before.contractDigest)
            XCTAssertEqual(saved.taskID, before.taskID); XCTAssertEqual(saved.stepIDs, before.stepIDs)
            XCTAssertEqual(saved.statuses, [.planned])
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
            if retires {
                do { _ = try await fixture.stage.open(checkCurrent: {}); XCTFail("Committed metadata cannot revive a retired stage") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserInitialSearchError, .retired) }
            } else {
                _ = try await fixture.stage.open(checkCurrent: {})
                XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1, "The stage must retain the document matching its committed replacement")
            }
        }
    }

    func testFailedRefreshWriteRecoversOnlyTheKnownBindingVisibleUnderAFreshLease() async throws {
        for retainedOldFile in [false, true] {
            let fixture = try await InitialSearchRefreshFixture.make()
            defer { fixture.close() }
            try await fixture.move()
            let before = try fixture.journal(), request = fixture.stage.request
            fixture.state.onWrite = { throw InitialSearchRefreshFixture.Failure.writeFailed }
            do { _ = try await fixture.stage.refreshStartingPage(checkCurrent: {}); XCTFail("A failed commit cannot publish the new starting page") }
            catch { XCTAssertEqual(error as? InitialSearchRefreshFixture.Failure, .writeFailed) }
            fixture.state.onWrite = nil
            let visible = try fixture.journal()
            XCTAssertNotEqual(visible.contractDigest, before.contractDigest)
            XCTAssertTrue(fixture.stage.isPending)
            if retainedOldFile {
                // Model a crash/storage outcome retaining the earlier file,
                // without teaching the production store to roll back bindings.
                try fixture.replaceFixtureRecord(before)
                do { _ = try await fixture.stage.open(checkCurrent: {}); XCTFail("An old file cannot dispatch against the new document") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
                let refreshed = try await fixture.stage.refreshStartingPage(checkCurrent: {})
                XCTAssertEqual(refreshed, .updated)
            }
            _ = try await fixture.stage.open(checkCurrent: {})
            let final = try fixture.journal()
            XCTAssertEqual(final.taskID, before.taskID); XCTAssertEqual(final.promptDigest, before.promptDigest)
            XCTAssertEqual(final.stepIDs, before.stepIDs); XCTAssertEqual(final.statuses, [.verified])
            XCTAssertEqual(fixture.stage.request, request)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        }
    }

    func testFailedRefreshDoesNotAdoptAnUnknownJournalBinding() async throws {
        let fixture = try await InitialSearchRefreshFixture.make()
        defer { fixture.close() }
        try await fixture.move()
        fixture.state.onWrite = { throw InitialSearchRefreshFixture.Failure.writeFailed }
        do { _ = try await fixture.stage.refreshStartingPage(checkCurrent: {}); XCTFail("Expected ambiguous replacement") }
        catch { XCTAssertEqual(error as? InitialSearchRefreshFixture.Failure, .writeFailed) }
        fixture.state.onWrite = nil
        let visible = try fixture.journal()
        let foreign = ComputerUseTaskJournal(taskID: visible.taskID, promptDigest: visible.promptDigest,
            contractDigest: String(repeating: "a", count: 64), stepIDs: visible.stepIDs, statuses: [.planned])
        try fixture.replaceFixtureRecord(foreign)
        let commands = fixture.state.commands
        do { _ = try await fixture.stage.open(checkCurrent: {}); XCTFail("Only the two known bindings may be reconciled") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        do { _ = try await fixture.stage.refreshStartingPage(checkCurrent: {}); XCTFail("Another refresh cannot legitimize an unknown binding") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        XCTAssertEqual(fixture.state.commands, commands)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
    }

    func testInitialSearchRefreshCannotReplaceStoppedClosedOrReclaimedSession() async throws {
        for ending in ["stop", "close", "reclaim"] {
            let fixture = try await InitialSearchRefreshFixture.make()
            defer { fixture.close() }
            let before = try fixture.journal()
            if ending == "close" { fixture.browser.close() }
            else { fixture.browser.stop() }
            if ending == "reclaim" { _ = try fixture.browser.prepareWorkflowSession(taskID: "root") }
            let commands = fixture.state.commands
            do { _ = try await fixture.stage.refreshStartingPage(checkCurrent: {}); XCTFail("Page refresh cannot become browser replacement") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
            XCTAssertEqual(fixture.state.commands, commands)
            XCTAssertEqual(try fixture.journal(), before)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 0)
        }
    }
}

@MainActor
private struct InitialSearchRefreshFixture {
    enum Failure: Error, Equatable { case paused, writeFailed }
    let server: OwnedBrowserHTTPFixture
    let base: URL
    let browser: ComputerUseOwnedBrowser
    let directory: URL
    let state: State
    let request: ComputerUseBrowserInitialSearchRequest
    let stage: ComputerUseBrowserInitialSearch
    var recordDirectory: URL { directory.appendingPathComponent("Initial Search") }
    private var recordID: String { ComputerUseTaskContract.digest(["browser-initial-search-record-v1", "root"]) }

    static func make(searchFails: Bool = false) async throws -> Self {
        let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(status: searchFails ? 503 : 200)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), state = State()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: {
            state.commands.append($0); state.onCommand?($0)
        }, mayAct: { true })
        do {
            let base = try await server.start()
            let session = try browser.prepareWorkflowSession(taskID: "root")
            let document = try await browser.navigate(taskID: "root", operationID: "seed", to: base.appendingPathComponent("before"))
            let page = try await browser.observePage(document: document)
            let goal = try ComputerUseBrowserGoalInput(taskID: "root", prompt: "Find concerts.",
                referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
            let proposal = try await BrowserResearchGoalFixture().propose(goal)
            let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"requirement":0,"text":"concerts"}]}"#, interpretation: proposal)
            let request = try ComputerUseBrowserInitialSearchRequest(interpretation: proposal, query: query,
                provider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"))
            let stage = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory,
                startingPage: page, makeStore: { try .init(directory: $0,
                    afterReplacement: { try MainActor.assumeIsolated { try state.onWrite?() } }) })
            state.onWrite = { state.blocked = true }
            do {
                _ = try await stage.open(checkCurrent: { if state.blocked { throw Failure.paused } })
                XCTFail("Fixture must stop after its planned write and before dispatch")
            } catch Failure.paused { }
            state.blocked = false; state.onWrite = nil
            return .init(server: server, base: base, browser: browser, directory: directory, state: state, request: request, stage: stage)
        } catch {
            state.onWrite = nil; state.onCommand = nil; browser.close(); server.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func move() async throws {
        _ = try await browser.navigate(taskID: "root", operationID: "move", to: base.appendingPathComponent("after"))
    }
    func journal() throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: recordDirectory).load(taskID: recordID))
    }
    func replaceFixtureRecord(_ value: ComputerUseTaskJournal) throws {
        let file = recordDirectory.appendingPathComponent(ComputerUseTextTaskContract.digest(recordID) + ".json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func close() {
        state.onWrite = nil; state.onCommand = nil; browser.close(); server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    @MainActor final class State {
        var blocked = false
        var commands: [ComputerUseBrowserDOMCommand] = []
        var onCommand: ((ComputerUseBrowserDOMCommand) -> Void)?
        var onWrite: (() throws -> Void)?
    }
}
