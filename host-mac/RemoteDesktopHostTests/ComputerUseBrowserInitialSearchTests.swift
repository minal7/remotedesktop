import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserInitialSearchTests: XCTestCase {
    func testFaraBingFormatMatchesUpstreamWithoutChangingQueryBytesOrOtherProviders() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://www.bing.com/search"))
        let provider = try ComputerUseBrowserSearchProvider(endpoint: endpoint, queryParameter: "q", queryFormat: .faraBing)
        let query = "C++ & cafés e\u{301} 😀 #1=50%"
        let url = try provider.destination(query: query)
        XCTAssertEqual(url.absoluteString, "https://www.bing.com/search?q=C%2B%2B+%26+caf%C3%A9s+e%CC%81+%F0%9F%98%80+%231%3D50%25&FORM=QBLH")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encoded = try XCTUnwrap(parts.percentEncodedQuery?.components(separatedBy: "&").first?.dropFirst(2))
        XCTAssertTrue(String(encoded).replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.utf8.elementsEqual(query.utf8) == true)
        XCTAssertEqual(parts.queryItems?.map(\.name), ["q", "FORM"])
        XCTAssertNil(parts.fragment); XCTAssertNil(parts.user); XCTAssertNil(parts.password)
        let standard = try ComputerUseBrowserSearchProvider(endpoint: endpoint, queryParameter: "q")
        XCTAssertNotEqual(provider.digest, standard.digest, "A changed search URL contract cannot reuse an earlier provider identity")
        XCTAssertEqual(try standard.destination(query: "two words").absoluteString, "https://www.bing.com/search?q=two%20words")
        XCTAssertThrowsError(try ComputerUseBrowserSearchProvider(endpoint: XCTUnwrap(URL(string: "https://example.com/search")), queryParameter: "q", queryFormat: .faraBing))
        XCTAssertThrowsError(try ComputerUseBrowserSearchProvider(endpoint: endpoint, queryParameter: "other", queryFormat: .faraBing))
    }

    func testInitialSearchBindsWholeGoalAndHostProviderWithoutQueryInjection() async throws {
        let text = "C++ & cafés e\u{301} 😀 #1=50%"
        let proposal = try await BrowserResearchGoalFixture().propose(goal(prompt: "Find " + text))
        let query = try query(proposal, text: text)
        let provider = try ComputerUseBrowserSearchProvider(endpoint: XCTUnwrap(URL(string: "https://example.com/search")), queryParameter: "q")
        let request = try ComputerUseBrowserInitialSearchRequest(interpretation: proposal, query: query, provider: provider)
        let url = try XCTUnwrap(URLComponents(url: request.destination, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.queryItems, [URLQueryItem(name: "q", value: text)])
        XCTAssertTrue(request.destination.absoluteString.contains("C%2B%2B%20%26%20caf"))
        XCTAssertNil(url.fragment); XCTAssertNil(url.user); XCTAssertNil(url.password)
        XCTAssertEqual(request.goal, proposal.input)
        XCTAssertFalse(String(reflecting: request).contains("caf"))
        XCTAssertEqual(String(reflecting: provider), "BrowserSearchProvider")
        let empty = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[]}"#, interpretation: proposal)
        XCTAssertThrowsError(try ComputerUseBrowserInitialSearchRequest(interpretation: proposal, query: empty, provider: provider))
        let changed = try await BrowserResearchGoalFixture().propose(goal(prompt: "Find something else"))
        XCTAssertThrowsError(try ComputerUseBrowserInitialSearchRequest(interpretation: changed, query: query, provider: provider))
        for endpoint in ["http://example.com/search", "https://user:secret@example.com/", "https://example.com/?fixed=1", "https://example.com/#section", "file:///tmp/search"] {
            XCTAssertThrowsError(try ComputerUseBrowserSearchProvider(endpoint: XCTUnwrap(URL(string: endpoint)), queryParameter: "q"))
        }
        for parameter in ["", "q&other", "q=value", "é", String(repeating: "q", count: 33)] {
            XCTAssertThrowsError(try ComputerUseBrowserSearchProvider(endpoint: XCTUnwrap(URL(string: "https://example.com/search")), queryParameter: parameter))
        }
    }

    func testInitialSearchPersistsBeforeLoadAndReplaysOnlyItsHistoricalReceipt() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let request = try await request(base: base), session = try browser.prepareWorkflowSession(taskID: "root")
        var states: [ComputerUseTaskStepStatus] = [], counts: [Int] = []
        let stage = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory,
            makeStore: { location in
                try .init(directory: location, afterReplacement: {
                    try MainActor.assumeIsolated {
                        counts.append(server.requestCount)
                        // The writer holds the journal lock here. Inspect the
                        // fixture's replaced bytes directly, without asking a
                        // competing store to acquire that same lock.
                        let id = ComputerUseTaskContract.digest(["browser-initial-search-record-v1", "root"])
                        let file = location.appendingPathComponent(ComputerUseTextTaskContract.digest(id) + ".json")
                        states.append(contentsOf: try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: file)).statuses)
                    }
                })
            })
        let first = try await stage.open(checkCurrent: {})
        XCTAssertFalse(stage.isPending)
        XCTAssertEqual(states, [.planned, .attempted, .verified])
        XCTAssertEqual(Array(counts.prefix(2)), [0, 0])
        XCTAssertEqual(server.count("/search?q=concerts"), 1)
        let next = try await browser.navigate(taskID: "root", operationID: "other", to: base.appendingPathComponent("other"))
        let replay = try await stage.open(checkCurrent: {})
        let replacement = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory)
        let recovered = try await replacement.open(checkCurrent: {})
        XCTAssertEqual(replay, first); XCTAssertEqual(recovered, first)
        XCTAssertEqual(browser.currentDocument(taskID: "root"), next, "A historical receipt does not reload or claim the current page")
        XCTAssertEqual(server.count("/search?q=concerts"), 1)
        let data = try JSONEncoder().encode(journal(directory))
        let savedText = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(savedText.contains("concerts")); XCTAssertFalse(savedText.contains(base.absoluteString))
    }

    func testInitialSearchPauseKeepsPlannedAndUncertainStagesDistinct() async throws {
        for pauseAtWrite in [1, 2] {
            let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
            defer { server.stop() }
            let directory = temporaryDirectory(), state = InitialSearchTestState()
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            state.onWrite = { index in if index == pauseAtWrite { state.owner?.pause() } }
            let owner = try owner(browser: browser, directory: directory, state: state)
            state.owner = owner
            XCTAssertEqual(owner.initialSearchState, .notPrepared)
            let interpretation = try await owner.interpretGoal()
            let query = try query(interpretation.proposal), provider = try provider(base)
            do { _ = try await owner.openInitialSearch(query, provider: provider); XCTFail("Pause must cancel the initial request") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(owner.hasPendingNavigation)
            XCTAssertEqual(owner.initialSearchState, .pending)
            XCTAssertEqual(try journal(directory).statuses, pauseAtWrite == 1 ? [.planned] : [.uncertain])
            XCTAssertEqual(server.requestCount, 0)
            state.onWrite = nil
            try await owner.resumeAfterUserControl()
            do { _ = try await owner.interpretGoal(); XCTFail("A pending effect must precede replacement planning") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .navigationPending) }
            let different = try ComputerUseBrowserSearchProvider(endpoint: base.appendingPathComponent("elsewhere"), queryParameter: "q")
            do { _ = try await owner.openInitialSearch(query, provider: different); XCTFail("An interruption cannot choose another destination") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserInitialSearchError, .pendingStage) }
            if pauseAtWrite == 1 {
                let resumed = try await owner.resumeInitialSearch()
                XCTAssertNotNil(resumed); XCTAssertFalse(owner.hasPendingNavigation)
                XCTAssertEqual(owner.initialSearchState, .confirmed)
                XCTAssertEqual(server.count("/search?q=concerts"), 1)
            } else {
                for _ in 0..<2 {
                    do { _ = try await owner.resumeInitialSearch(); XCTFail("Empty native contents cannot reauthorize a durable attempt") }
                    catch ComputerUseTaskExecutionError.uncertainEffect { }
                }
                XCTAssertTrue(owner.hasPendingNavigation); XCTAssertEqual(server.requestCount, 0)
            }
        }
    }

    func testInitialSearchFailedAndCancelledLoadsCannotBeRetriedByAnotherStage() async throws {
        for cancelled in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(status: cancelled ? 200 : 503, held: cancelled)])
            let base = try await server.start()
            defer { server.stop() }
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let request = try await request(base: base), session = try browser.prepareWorkflowSession(taskID: "root")
            let stage = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory)
            let loading = Task { try await stage.open(checkCurrent: {}) }
            try await waitUntil { server.count("/search?q=concerts") == 1 }
            if cancelled { loading.cancel() }
            do { _ = try await loading.value; XCTFail("An interrupted load cannot succeed") }
            catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
            }
            let replacement = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory)
            do { _ = try await replacement.open(checkCurrent: {}); XCTFail("A new adapter cannot replay the old attempt") }
            catch ComputerUseTaskExecutionError.uncertainEffect { }
            XCTAssertEqual(try journal(directory).statuses, [.uncertain])
            XCTAssertEqual(server.count("/search?q=concerts"), 1)
        }
    }

    func testInitialSearchStorageFailurePreservesVisibleAttemptAndConfirmation() async throws {
        for failureAtWrite in [1, 2, 3] {
            let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
            defer { server.stop() }
            let directory = temporaryDirectory(), state = InitialSearchTestState()
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let request = try await request(base: base), session = try browser.prepareWorkflowSession(taskID: "root")
            state.onWrite = { index in if index == failureAtWrite { throw InitialSearchFixtureError.writeFailed } }
            let stage = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory,
                makeStore: { try .init(directory: $0, afterReplacement: { try MainActor.assumeIsolated { try state.didWrite() } }) })
            do { _ = try await stage.open(checkCurrent: {}); XCTFail("A failed durable write cannot publish success") }
            catch { XCTAssertEqual(error as? InitialSearchFixtureError, .writeFailed) }
            XCTAssertTrue(stage.isPending)
            XCTAssertEqual(server.count("/search?q=concerts"), failureAtWrite == 3 ? 1 : 0)
            state.onWrite = nil
            if failureAtWrite == 2 {
                do { _ = try await stage.open(checkCurrent: {}); XCTFail("An unconfirmed attempt write still forbids replay") }
                catch ComputerUseTaskExecutionError.uncertainEffect { }
                XCTAssertEqual(server.requestCount, 0)
            } else {
                _ = try await stage.open(checkCurrent: {})
                XCTAssertFalse(stage.isPending)
                XCTAssertEqual(server.count("/search?q=concerts"), 1)
                XCTAssertEqual(try journal(directory).statuses, [.verified])
            }
        }
    }

    func testInitialSearchJournalRejectsChangedQueryProviderGoalAndSession() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let original = try await request(base: base), session = try browser.prepareWorkflowSession(taskID: "root")
        let stage = try ComputerUseBrowserInitialSearch(request: original, session: session, browser: browser, directory: directory)
        _ = try await stage.open(checkCurrent: {})
        let proposal = try await BrowserResearchGoalFixture().propose(original.goal)
        let anotherQuery = try ComputerUseBrowserInitialSearchRequest(interpretation: proposal, query: query(proposal, text: "Find"), provider: provider(base))
        let anotherProvider = try await request(base: base.appendingPathComponent("other"))
        let anotherGoal = try await request(base: base, input: goal(prompt: "Find concerts tomorrow."))
        for changed in [anotherQuery, anotherProvider, anotherGoal] {
            let replacement = try ComputerUseBrowserInitialSearch(request: changed, session: session, browser: browser, directory: directory)
            do { _ = try await replacement.open(checkCurrent: {}); XCTFail("A changed binding must find the original record") }
            catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        }
        browser.close()
        let fresh = try browser.prepareWorkflowSession(taskID: "root")
        let replacement = try ComputerUseBrowserInitialSearch(request: original, session: fresh, browser: browser, directory: directory)
        do { _ = try await replacement.open(checkCurrent: {}); XCTFail("A fresh blank browser is not the old session") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testInitialSearchRechecksNativeSessionAfterDurableAttemptCallback() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory(), state = InitialSearchTestState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let request = try await request(base: base), session = try browser.prepareWorkflowSession(taskID: "root")
        state.onWrite = { index in
            if index == 2 { browser.stop(); _ = try browser.prepareWorkflowSession(taskID: "root") }
        }
        let stage = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory,
            makeStore: { try .init(directory: $0, afterReplacement: { try MainActor.assumeIsolated { try state.didWrite() } }) })
        do { _ = try await stage.open(checkCurrent: {}); XCTFail("Same task ID after Stop cannot authorize the retired session") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(try journal(directory).statuses, [.uncertain])
    }

    func testInitialSearchCannotReplaceExistingPageOrClaimAnotherTasksBrowser() async throws {
        for taskID in ["root", "other"] {
            let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
            defer { server.stop() }
            let directory = temporaryDirectory(), state = InitialSearchTestState()
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: taskID)
            let previous = try await browser.navigate(taskID: taskID, operationID: "existing", to: base.appendingPathComponent("existing"))
            let owner = try owner(browser: browser, directory: directory, state: state)
            let interpretation = try await owner.interpretGoal()
            let query = try query(interpretation.proposal)
            do { _ = try await owner.openInitialSearch(query, provider: provider(base)); XCTFail("First-page dispatch cannot replace an existing context") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, taskID == "root" ? .pageChanged : .ownershipLost) }
            XCTAssertEqual(browser.taskID, taskID)
            XCTAssertEqual(browser.currentDocument(taskID: taskID), previous)
            XCTAssertEqual(server.count("/search?q=concerts"), 0)
            if taskID == "root" { XCTAssertEqual(try journal(directory).statuses, [.planned]) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
        }
    }

    func testInitialSearchExecutionLeaseAndRetirementSurviveHeldNativeLoad() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory(), state = InitialSearchTestState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let owner = try owner(browser: browser, directory: directory, state: state)
        let interpretation = try await owner.interpretGoal()
        let query = try query(interpretation.proposal), provider = try provider(base)
        let loading = Task { try await owner.openInitialSearch(query, provider: provider) }
        try await waitUntil { server.count("/search?q=concerts") == 1 }
        let session = try XCTUnwrap(browser.handbackRequirement(taskID: "root", required: true))
        let request = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation.proposal, query: query, provider: provider)
        let competing = try ComputerUseBrowserInitialSearch(request: request, session: session, browser: browser, directory: directory)
        do { _ = try await competing.open(checkCurrent: {}); XCTFail("A suspended native load still holds its execution lease") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .busy) }
        owner.retire()
        XCTAssertTrue(owner.isOperating, "Retirement cannot release an operation before its actual unwind")
        do { _ = try await loading.value; XCTFail("A retired owner cannot publish the page") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating)
        do { _ = try await owner.resumeInitialSearch(); XCTFail("Retirement is permanent") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        do { _ = try await competing.open(checkCurrent: {}); XCTFail("Released exclusion is not new effect authority") }
        catch ComputerUseTaskExecutionError.uncertainEffect { }
        XCTAssertEqual(server.count("/search?q=concerts"), 1)
        XCTAssertEqual(try journal(directory).statuses, [.uncertain])
    }

    func testInitialSearchOwnerRetainsExactAnswerThroughLoginAndCandidateNavigation() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(body: """
            <input id='auth' type='password' autocomplete='current-password'>
            <article><h2>Concert Alpha</h2><a href='/offer'>Details</a></article>
            <script>fetch('/finish-login').then(() => {
                document.getElementById('auth').remove(); history.replaceState({}, '', '/account'); fetch('/logged-in');
            });</script>
            """), "/finish-login": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        let original = try goal(), reader = BrowserResearchResultFixture()
        reader.selectedLinkLabel = "Details"
        let owner = ComputerUseBrowserResearchTask(input: original, browser: browser, goalPlanner: BrowserResearchGoalFixture(),
            resultPlanner: reader, navigationJournalDirectory: directory, mayAct: { allowed })
        let first = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .location, requirementIDs: first.proposal.requirements.map(\.id),
            controllerID: "phone", controllerSessionID: "session")
        let answer = "  Paris e\u{301} 😀\n  "
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: answer,
            controllerID: "phone", controllerSessionID: "session")
        let interpretation = try await owner.interpretGoal()
        let query = try query(interpretation.proposal), provider = try provider(base)
        let initial = try await owner.openInitialSearch(query, provider: provider)
        do { _ = try await owner.readCandidates(); XCTFail("Authentication must hand control to the user") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertTrue(reader.inputs.isEmpty)
        owner.pause(); allowed = false
        try await waitUntil { server.count("/finish-login") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/logged-in") == 1 && browser.hasPageAwaitingHandback }
        allowed = true
        try await owner.resumeAfterUserControl()
        let replay = try await owner.openInitialSearch(query, provider: provider)
        XCTAssertEqual(replay, initial, "Handback may move the page without repeating the initial search")
        let candidates = try await owner.readCandidates(), candidate = try XCTUnwrap(candidates.candidates.first)
        let link = try await owner.openCandidateLink(candidateID: candidate.id, linkID: XCTUnwrap(candidate.selectedLinkIDs.first))
        XCTAssertEqual(link.document.committedURL, base.appendingPathComponent("offer"))
        XCTAssertEqual(server.count("/search?q=concerts"), 1); XCTAssertEqual(server.count("/offer"), 1)
        XCTAssertEqual(owner.input.rootDigest, original.rootDigest)
        XCTAssertEqual(owner.input.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(owner.input.userTurns, [original.prompt, answer])
        XCTAssertEqual(owner.executionTaskID, "answer")
        XCTAssertEqual(reader.inputs, [owner.input])
        XCTAssertFalse(owner.hasPendingNavigation)
        XCTAssertEqual(owner.initialSearchState, .confirmed)
    }

    private func goal(prompt: String = "Find concerts.") throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: "root", prompt: prompt, referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
    }
    private func query(_ proposal: ComputerUseBrowserGoalProposal, text: String = "concerts") throws -> ComputerUseBrowserSearchQuery {
        let data = try JSONSerialization.data(withJSONObject: ["terms":[["requirement":0, "text":text]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), interpretation: proposal)
    }
    private func provider(_ base: URL) throws -> ComputerUseBrowserSearchProvider {
        try .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q")
    }
    private func request(base: URL, input: ComputerUseBrowserGoalInput? = nil) async throws -> ComputerUseBrowserInitialSearchRequest {
        let proposal = try await BrowserResearchGoalFixture().propose(input ?? goal())
        return try .init(interpretation: proposal, query: query(proposal), provider: provider(base))
    }
    private func owner(browser: ComputerUseOwnedBrowser, directory: URL, state: InitialSearchTestState) throws -> ComputerUseBrowserResearchTask {
        .init(input: try goal(), browser: browser, goalPlanner: BrowserResearchGoalFixture(), resultPlanner: BrowserResearchResultFixture(),
            navigationJournalDirectory: directory, navigationStore: { try .init(directory: $0,
                afterReplacement: { try MainActor.assumeIsolated { try state.didWrite() } }) }, mayAct: { true })
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func journal(_ directory: URL) throws -> ComputerUseTaskJournal {
        let store = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Initial Search"))
        return try XCTUnwrap(store.load(taskID: ComputerUseTaskContract.digest(["browser-initial-search-record-v1", "root"])))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw InitialSearchFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum InitialSearchFixtureError: Error, Equatable { case writeFailed, timedOut }
@MainActor
private final class InitialSearchTestState {
    weak var owner: ComputerUseBrowserResearchTask?
    var onWrite: ((Int) throws -> Void)?
    private var writes = 0
    func didWrite() throws { writes += 1; try onWrite?(writes) }
}
