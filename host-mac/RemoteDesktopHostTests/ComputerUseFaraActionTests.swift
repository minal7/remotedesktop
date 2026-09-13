import Foundation
import CryptoKit
import AppKit
import WebKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseFaraActionTests: XCTestCase {
    @MainActor
    func testOptInManagedFaraOpensControlledConcertResultAndReportsSource() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_SEARCH_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: at most six actual Fara proposals on a fictional search and concert page")
        }
        let inputs = try await FaraTestAssets.inputs(environment: environment)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let searchPath = "/search?q=Tokyo%20Music%20Hall%20concerts"
        let style = "<style>body{font:26px system-ui;background:white;color:#111;margin:50px}a{display:block;padding:24px;background:#eef4ff}</style>"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<!doctype html><title>Local search results</title>" + style + "<h1>Concert search results</h1><a href='/details'>Tokyo Music Hall — concert times and tickets</a>"),
            searchPath: .init(body: "<!doctype html><title>Concert search results</title>" + style + "<h1>Tokyo Music Hall concerts</h1><a href='/details'>Tokyo Music Hall — concert times and tickets</a>"),
            "/details": .init(body: "<!doctype html><title>Tokyo Music Hall concert details</title>" + style + "<h1>Tokyo Music Hall</h1><p>Friday concert starts at 7 pm.</p><p>Ticket price: 2400 JPY.</p>")])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraSearchModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "fara-search-model")
        let boundary = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: "fara-search-model", prompt: "Use only the controlled local fixture.", referenceDate: Date(), timeZoneIdentifier: "UTC"),
            allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        let browserSession = try browser.prepareWorkflowSession(taskID: "fara-search-model")
        try browser.installSourcePolicy(boundary, replacing: nil, session: browserSession)
        _ = try await browser.navigate(taskID: "fara-search-model", operationID: "open", to: base.appendingPathComponent("start"))
        let runtime = OSAtlasLlamaRuntime()
        let executable = inputs.llamaServerURL
        let memory = Task.detached { () -> (UInt64, Int) in
            var peak: UInt64 = 0, count = 0
            while !Task.isCancelled {
                for process in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: executable)) ?? [] {
                    if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: process.processIdentifier) { peak = max(peak, bytes); count += 1 }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return (peak, count)
        }
        var responses: [[String: Any]] = []
        let goal = "Find the Tokyo Music Hall concert in these search results. Open its details and report the ticket price and start time with the source URL."
        let started = Date()
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"),
            searchProvider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"), propose: { input in
                guard responses.count < 6 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let began = Date()
                let endpoint = try await runtime.activateFara(inputs)
                let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
                responses.append(["response": proposal.response, "seconds": Date().timeIntervalSince(began),
                    "currentURL": input.currentURL?.absoluteString ?? ""])
                return proposal
            }, finishRun: { await runtime.shutdown() })
        var result: ComputerUseExecutionResult?, failure: Error?
        do {
            result = try await executor.execute(taskID: "fara-search-model", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        } catch { failure = error }
        await runtime.shutdown()
        memory.cancel()
        let measured = await memory.value
        let gone = try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty
        let report: [String: Any] = ["scope": "actual-Fara-controlled-concert-result-navigation", "targetMacRAMGB": 12,
            "wholeApp12GBQualified": false, "liveWebsiteQualified": false, "responses": responses,
            "requests": server.requestedPaths, "elapsedSeconds": Date().timeIntervalSince(started),
            "peakSampledProcessMemoryBytes": measured.0, "memorySamples": measured.1, "ownedProcessExited": gone,
            "failure": failure.map { String(describing: $0) } ?? ""]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Fara controlled concert search evidence"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(gone)
        if let failure { XCTFail("Controlled Fara search failed: \(failure)"); return }
        guard case .completed(let answer) = result else { XCTFail("Fara did not return a completed research answer"); return }
        let normalized = answer.lowercased().replacingOccurrences(of: ",", with: "")
        XCTAssertTrue(normalized.contains("2400"))
        XCTAssertTrue(normalized.contains("7") || normalized.contains("19:00"))
        XCTAssertTrue(answer.contains(base.appendingPathComponent("details").absoluteString))
        XCTAssertEqual(server.count(searchPath), 0)
        XCTAssertEqual(server.count("/details"), 1)
    }

    @MainActor
    func testOptInFaraWaitsForChangedPageBeforeProposingNextAction() async throws {
        try await runFaraChangedPageProposal(waitForChange: true)
    }

    @MainActor
    func testOptInFaraRejectsCompletionFromChangedPage() async throws {
        try await runFaraChangedPageProposal(waitForChange: false)
    }

    @MainActor
    private func runFaraChangedPageProposal(waitForChange: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: the page changes during a read-only wait proposal")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/start": .init(body: """
            <!doctype html><title>Loading fixture</title><h1 id='state'>Loading</h1>
            <script>fetch('/change').then(() => {document.getElementById('state').textContent='Loaded'; fetch('/changed')})</script>
            """), "/change": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraWait-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "fara-wait")
        _ = try await browser.navigate(taskID: "fara-wait", operationID: "open", to: base.appendingPathComponent("start"))
        let ready = ContinuousClock.now + .seconds(3)
        while server.count("/change") == 0 && ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.count("/change"), 1)
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard calls < 2 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            XCTAssertEqual(input.history.count, calls)
            if calls == 0 {
                server.releaseHeldResponses()
                let changed = ContinuousClock.now + .seconds(3)
                while server.count("/changed") == 0 && ContinuousClock.now < changed { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(server.count("/changed"), 1)
            }
            let action = calls == 0 && waitForChange ? #"{"action":"wait","time":0}"# : #"{"action":"terminate","answer":"Loaded"}"#
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + action + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            let result = try await executor.execute(taskID: "fara-wait", prompt: "Wait for the page to load.", trustedUserPrompt: "Wait for the page to load.", tools: tools, progress: { _ in })
            XCTAssertTrue(waitForChange, "Completion was accepted from a stale screenshot")
            XCTAssertEqual(result, .completed("Loaded"))
            XCTAssertEqual(calls, 2)
        } catch ComputerUseBrowserError.pageChanged {
            XCTAssertFalse(waitForChange, "Read-only waiting required the page to stay unchanged")
            XCTAssertEqual(calls, 1)
        } catch { XCTFail("Changed-page proposal failed after \(calls) proposals: \(error)") }
    }

    @MainActor
    func testOptInFaraReadsNewDocumentAfterNativeLinkNavigation() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: native result click followed by a fresh document observation")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/start": .init(body: """
            <!doctype html><title>Concert results</title><a href='/details' style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh'>Tokyo Music Hall details</a>
            <script>document.addEventListener('click',()=>fetch('/clicked'))</script>
            """), "/details": .init(body: "<!doctype html><title>Concert details</title><h1>Tokyo Music Hall: 2400 JPY, 7 pm</h1>")])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraResultClick-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "fara-result-click")
        _ = try await browser.navigate(taskID: "fara-result-click", operationID: "open", to: base.appendingPathComponent("start"))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard calls < 2 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            XCTAssertEqual(input.currentURL, base.appendingPathComponent(calls == 0 ? "start" : "details"))
            let action = calls == 0 ? #"{"action":"left_click","coordinate":[500,250]}"# : #"{"action":"terminate","answer":"2400 JPY, 7 pm"}"#
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + action + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            let result = try await executor.execute(taskID: "fara-result-click", prompt: "Open the concert details.", trustedUserPrompt: "Open the concert details.", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("2400 JPY, 7 pm"))
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(server.count("/details"), 1)
            XCTAssertEqual(server.count("/clicked"), 1)
        } catch { XCTFail("Result navigation failed after \(calls) proposals: \(error)") }
    }

    @MainActor
    func testOptInFaraSearchFailureRetainsUncertainNavigationWithoutRetry() async throws {
        try await runFaraSearchOutcome(login: false)
    }

    @MainActor
    func testOptInFaraSearchStopsBeforeReadingLoginAndRejectsEarlyResume() async throws {
        try await runFaraSearchOutcome(login: true)
    }

    @MainActor
    private func runFaraSearchOutcome(login: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: native search reaches an error or simulated login")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(status: login ? 200 : 500,
            body: login ? "<!doctype html><title>Fictional login</title><label>Password<input type='password' value='private-fictional-password'></label>" : "<!doctype html><title>Unavailable</title><h1>Try later</h1>")])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraSearchOutcome-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "fara-search-outcome")
        _ = try await browser.navigate(taskID: "fara-search-outcome", operationID: "open", to: base.appendingPathComponent("start"))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"),
            searchProvider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"), propose: { _ in
                guard calls == 0 else { throw ComputerUseFaraAction.Failure.invalidResponse }
                calls += 1
                let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"web_search","query":"concerts"}}</tool_call>"#
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
        func run() async throws -> ComputerUseExecutionResult {
            try await executor.execute(taskID: "fara-search-outcome", prompt: "Find concerts.", trustedUserPrompt: "Find concerts.", tools: tools, progress: { _ in })
        }
        var first: ComputerUseExecutionResult?, failure: Error?
        do { first = try await run() } catch { failure = error }
        if login {
            XCTAssertNil(failure)
            guard case .userInterventionRequired = first else { XCTFail("Login did not pause the task"); return }
        } else {
            XCTAssertNotNil(failure)
            XCTAssertNil(first)
        }
        do {
            let again = try await run()
            if login { XCTAssertEqual(again, first) }
            else { guard case .unableToComplete = again else { XCTFail("Uncertain navigation was resumed"); return } }
        } catch { XCTFail("Retained outcome failed: \(error)"); return }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(server.count("/search?q=concerts"), 1)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try Data(contentsOf: $0) }
        let journals = try records.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: $0) }
        XCTAssertEqual(journals.count, 2)
        XCTAssertEqual(journals.first { $0.stepIDs == ["native-dispatch-returned"] }?.statuses, [login ? .verified : .uncertain])
        XCTAssertEqual(journals.first { $0.stepIDs == ["model-assessed-completion"] }?.statuses, [.attempted])
        XCTAssertFalse(records.contains { String(decoding: $0, as: UTF8.self).contains("private-fictional-password") })
    }

    @MainActor
    func testOptInFaraExecutorSearchesThenVisitsSourceWithoutReplay() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: native navigation through a controlled search and source page")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let query = "東京 concerts A+B & tickets"
        let searchPath = "/search?q=%E6%9D%B1%E4%BA%AC%20concerts%20A%2BB%20%26%20tickets"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<!doctype html><title>Local browser search</title><h1>Ready to search</h1>"),
            searchPath: .init(body: "<!doctype html><title>Fictional concert results</title><a href='/details'>Tokyo Music Hall: Friday, 7 pm, 2400 JPY</a>"),
            "/details": .init(body: "<!doctype html><title>Fictional venue details</title><h1>Tokyo Music Hall</h1><p>Friday, 7 pm. Tickets: 2400 JPY.</p>")])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraSearch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "fara-search")
        _ = try await browser.navigate(taskID: "fara-search", operationID: "open", to: base.appendingPathComponent("start"))
        let source = base.appendingPathComponent("details").absoluteString
        let answer = "Tokyo Music Hall: Friday, 7 pm, 2400 JPY. Source: " + source
        let actions: [[String: Any]] = [["action": "web_search", "query": query],
            ["action": "visit_url", "url": source], ["action": "terminate", "answer": answer]]
        var calls = 0
        let goal = "Find a Tokyo concert and report its venue, time, ticket price and source."
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"),
            searchProvider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"), propose: { input in
            XCTAssertEqual(input.goal, goal)
            XCTAssertEqual(input.history.count, calls)
            let observedURLs = [base.appendingPathComponent("start"), URL(string: base.absoluteString + searchPath)!, base.appendingPathComponent("details")]
            XCTAssertEqual(input.currentURL, observedURLs[calls])
            XCTAssertEqual(input.history.map(\.currentURL), Array(observedURLs.prefix(calls)).map(Optional.some))
            if calls == 1 { XCTAssertEqual(server.count(searchPath), 1) }
            if calls == 2 { XCTAssertEqual(server.count("/details"), 1) }
            guard calls < actions.count else { throw ComputerUseFaraAction.Failure.invalidResponse }
            let json = try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": actions[calls]])
            let response = "<tool_call>" + String(decoding: json, as: UTF8.self) + "</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        let result: ComputerUseExecutionResult
        do {
            result = try await executor.execute(taskID: "fara-search", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        } catch {
            XCTFail("Fara search failed after \(calls) proposals: \(error)")
            return
        }
        XCTAssertEqual(result, .completed(answer))
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(server.requestedPaths.filter { $0 == "/start" || $0 == searchPath || $0 == "/details" }, ["/start", searchPath, "/details"])
        let repeated = try await executor.execute(taskID: "fara-search", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(repeated, result)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(server.count(searchPath), 1)
        XCTAssertEqual(server.count("/details"), 1)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try Data(contentsOf: $0) }
        let journals = try records.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: $0) }
        XCTAssertEqual(journals.count, 3)
        XCTAssertTrue(journals.allSatisfy { $0.statuses == [.verified] })
        XCTAssertFalse(records.contains { String(decoding: $0, as: UTF8.self).contains(base.absoluteString) })
    }

    @MainActor
    func testOptInOwnedBrowserFaraNavigationRejectsReplayCancellationAndRevokedControl() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: stale and cancelled Fara navigation on local pages")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowed })
        defer { browser.close() }
        try browser.claim(taskID: "fara-nav-edges")
        let original = try await browser.navigate(taskID: "fara-nav-edges", operationID: "open", to: base.appendingPathComponent("start"))
        let first = try await browser.captureAgentObservation(document: original)
        var begins = 0
        try await browser.performAgentInput(.visitURL(base.appendingPathComponent("source")), observation: first,
            operationID: "source", willBeginEffect: { begins += 1 })
        XCTAssertEqual(server.count("/source"), 1)
        XCTAssertEqual(begins, 1)
        do {
            try await browser.performAgentInput(.visitURL(base.appendingPathComponent("replayed")), observation: first,
                operationID: "replayed", willBeginEffect: { begins += 1 })
            XCTFail("A consumed screenshot authorized navigation")
        } catch ComputerUseBrowserError.pageChanged { }
        let current = try await browser.acquireObservedDocument(taskID: "fara-nav-edges")
        for invalid in [URL(string: "file:///tmp/fara-fixture")!, URL(string: "https://user:secret@example.com/")!] {
            let observation = try await browser.captureAgentObservation(document: current)
            do {
                try await browser.performAgentInput(.visitURL(invalid), observation: observation,
                    operationID: UUID().uuidString, willBeginEffect: { begins += 1 })
                XCTFail("An invalid destination was admitted")
            } catch ComputerUseBrowserError.invalidURL { }
            do {
                try await browser.performAgentInput(.visitURL(base.appendingPathComponent("replayed")), observation: observation,
                    operationID: UUID().uuidString, willBeginEffect: { begins += 1 })
                XCTFail("Failed navigation left a reusable observation")
            } catch ComputerUseBrowserError.pageChanged { }
        }
        let cancelledObservation = try await browser.captureAgentObservation(document: current)
        let cancelled = Task { @MainActor in
            try await browser.performAgentInput(.visitURL(base.appendingPathComponent("cancelled")), observation: cancelledObservation,
                operationID: "cancelled", willBeginEffect: { begins += 1 })
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled navigation was admitted") }
        catch is CancellationError { }
        XCTAssertEqual(begins, 1)
        let revoked = try await browser.captureAgentObservation(document: current)
        do {
            try await browser.performAgentInput(.visitURL(base.appendingPathComponent("revoked")), observation: revoked,
                operationID: "revoked", willBeginEffect: { begins += 1; allowed = false })
            XCTFail("Navigation continued after control was revoked")
        } catch ComputerUseBrowserError.pageChanged { }
        allowed = true
        do {
            try await browser.performAgentInput(.visitURL(base.appendingPathComponent("replayed")), observation: revoked,
                operationID: "revoked-replay", willBeginEffect: { begins += 1 })
            XCTFail("Reopening the action gate revived a retired observation")
        } catch ComputerUseBrowserError.pageChanged { }
        XCTAssertEqual(begins, 2)
        XCTAssertEqual(server.requestedPaths.filter { ["/start", "/source", "/replayed", "/cancelled", "/revoked"].contains($0) }, ["/start", "/source"])
    }

    @MainActor
    func testOptInFaraExecutorJournalsInputAndRejectsRestartReplay() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: retained task and restart checks in a visible local fictional form")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><title>Local Fara journal</title><label for="destination" style="position:fixed;left:20vw;top:12vh">Destination</label>
            <input id="destination" style="position:fixed;left:20vw;top:20vh;width:60vw;height:10vh">
            <script>document.addEventListener('input', event => fetch('/typed?value='+encodeURIComponent(event.target.value)));
            document.addEventListener('click', () => fetch('/clicked'));</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraJournal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "fara-journal")
        _ = try await browser.navigate(taskID: "fara-journal", operationID: "open", to: base.appendingPathComponent("form"))
        var calls = 0
        let goal = "Type Tokyo into Destination."
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            XCTAssertEqual(input.goal, goal)
            XCTAssertEqual(input.history.count, calls)
            let actions = [#"{"action":"left_click","coordinate":[500,250]}"#,
                #"{"action":"type","text":"Tokyo"}"#, #"{"action":"terminate","answer":"Destination is Tokyo."}"#]
            guard calls < actions.count else { throw ComputerUseFaraAction.Failure.invalidResponse }
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + actions[calls] + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        let result = try await executor.execute(taskID: "fara-journal", prompt: "Untrusted assistant text", trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Destination is Tokyo."))
        XCTAssertEqual(calls, 3)
        let deadline = ContinuousClock.now + .seconds(3)
        while server.count("/typed?value=Tokyo") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.count("/typed?value=Tokyo"), 1)
        XCTAssertEqual(server.count("/clicked"), 1)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try Data(contentsOf: $0) }
        let journals = try records.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: $0) }
        XCTAssertEqual(journals.count, 3)
        XCTAssertEqual(journals.filter { $0.stepIDs == ["native-dispatch-returned"] }.count, 2)
        XCTAssertEqual(journals.filter { $0.stepIDs == ["model-assessed-completion"] }.count, 1)
        XCTAssertTrue(journals.allSatisfy { $0.statuses == [.verified] && $0.promptDigest == ComputerUseTextTaskContract.digest(goal) })
        XCTAssertFalse(records.contains { String(data: $0, encoding: .utf8)?.contains("Tokyo") == true })
        let cached = try await executor.execute(taskID: "fara-journal", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(cached, result)
        do {
            _ = try await executor.execute(taskID: "fara-journal", prompt: "Type Kyoto", trustedUserPrompt: "Type Kyoto", tools: tools, progress: { _ in })
            XCTFail("A changed request cannot reuse this task")
        } catch { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .changedTask) }
        let restarted = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            XCTFail("Restart cannot reconstruct and replay the old task")
            throw ComputerUseFaraAction.Failure.invalidResponse
        })
        do {
            _ = try await restarted.execute(taskID: "fara-journal", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTFail("The durable prior task requires recovery, not replay")
        } catch { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .recoveredTask) }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(server.count("/typed?value=Tokyo"), 1)
        XCTAssertEqual(server.count("/clicked"), 1)
    }

    @MainActor
    func testOptInOwnedBrowserNativeClickAndUnicodeInputStopAtLogin() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: native events in a visible local fictional browser form")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var stage = "create loopback fixture"
        defer {
            let attachment = XCTAttachment(string: "Native browser input checkpoint: \(stage)")
            attachment.name = "Fara browser input stage"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><html><head><meta charset="utf-8"><title>Local native input</title><style>
            body {font:22px system-ui; background:white; margin:0} label {position:absolute;left:60px}
            input,textarea {position:absolute;left:60px;width:500px;box-sizing:border-box;font:22px system-ui}
            #origin {top:70px;height:50px} #destination {top:180px;height:96px}
            </style></head><body><label style="top:30px" for="origin">Origin</label><input id="origin" value="Seattle">
            <label style="top:140px" for="destination">Destination</label><textarea id="destination"></textarea>
            <script>
            const originField = document.getElementById('origin'), destinationField = document.getElementById('destination');
            let inputTimer;
            function record(event) { fetch('/event?' + new URLSearchParams({kind:event.type,
              target:event.target.id, trusted:String(event.isTrusted), value:event.target.value || ''}));
              if (event.type === 'input') {
                clearTimeout(inputTimer);
                inputTimer = setTimeout(() => fetch('/state?' + new URLSearchParams({origin:originField.value,
                  destination:destinationField.value,password:document.getElementById('password')?.value || ''})), 0);
              }
            }
            for (const kind of ['click','input','keydown','keyup']) document.addEventListener(kind, record);
            destinationField.addEventListener('input', () => {
              const login = document.createElement('input'); login.id='password'; login.type='password';
              login.style.top='350px'; login.value='private-fixture-password'; document.body.append(login);
              fetch('/login-shown');
            }, {once:true});
            </script></body></html>
            """)])
        stage = "start loopback fixture"
        let base = try await server.start()
        defer {
            let attachment = XCTAttachment(string: server.requestedPaths.joined(separator: "\n"))
            attachment.name = "Fara native fixture events"; attachment.lifetime = .keepAlways
            add(attachment)
            server.stop()
        }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        stage = "claim browser"
        try browser.claim(taskID: "fara-native-input")
        stage = "navigate local form"
        let document = try await browser.navigate(taskID: "fara-native-input", operationID: "open", to: base.appendingPathComponent("form"))
        stage = "capture first observation"
        let observation = try await browser.captureAgentObservation(document: document)
        XCTAssertTrue(browser.isFrontmostWindow)
        let point = ComputerUseFaraAction.Point(x: 310 / observation.viewportSize.width * 1000, y: 228 / observation.viewportSize.height * 1000)
        stage = "native click"
        try await browser.performAgentInput(.pointer(.leftClick, point), observation: observation)
        func events(_ kind: String) -> [[String: String]] {
            server.requestedPaths.compactMap { path -> [String: String]? in
                guard path.hasPrefix("/event?"), let items = URLComponents(string: path.replacingOccurrences(of: "+", with: "%20"))?.queryItems else { return nil }
                let value = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                return value["kind"] == kind ? value : nil
            }
        }
        let clickDeadline = ContinuousClock.now + .seconds(3)
        while events("click").isEmpty && ContinuousClock.now < clickDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(events("click").count, 1)
        XCTAssertEqual(events("click").first?["target"], "destination")
        XCTAssertEqual(events("click").first?["trusted"], "true")
        stage = "capture focused field"
        let focused = try await browser.captureAgentObservation(document: document)
        let exact = "  東京 e\u{301} 😀\n  "
        stage = "native Unicode input"
        var inputDispatches = 0
        try await browser.performAgentInput(.typeText(exact), observation: focused, willBeginEffect: { inputDispatches += 1 })
        let inputDeadline = ContinuousClock.now + .seconds(3)
        while (!server.requestedPaths.contains { $0.hasPrefix("/state?") } || server.count("/login-shown") == 0) && ContinuousClock.now < inputDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let inputs = events("input")
        XCTAssertEqual(inputDispatches, 1)
        XCTAssertFalse(inputs.isEmpty)
        for input in inputs {
            XCTAssertEqual(input["target"], "destination")
            XCTAssertEqual(input["trusted"], "true")
            XCTAssertTrue(try XCTUnwrap(input["value"]).utf8.elementsEqual(exact.utf8))
        }
        let statePath = try XCTUnwrap(server.requestedPaths.last { $0.hasPrefix("/state?") })
        let stateItems = try XCTUnwrap(URLComponents(string: statePath.replacingOccurrences(of: "+", with: "%20"))?.queryItems)
        let state = Dictionary(uniqueKeysWithValues: stateItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(state["origin"], "Seattle")
        XCTAssertTrue(try XCTUnwrap(state["destination"]).utf8.elementsEqual(exact.utf8))
        XCTAssertEqual(state["password"], "private-fixture-password")
        XCTAssertTrue(events("keydown").isEmpty, "Text insertion cannot imply an Enter key or form submission")
        stage = "login and replay rejection"
        do { _ = try await browser.captureAgentObservation(document: document); XCTFail("Login must stop the next screenshot") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        do { try await browser.performAgentInput(.typeText("duplicate"), observation: focused); XCTFail("Consumed input cannot be replayed") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(events("input").count, inputs.count)
        XCTAssertEqual(inputDispatches, 1)
    }

    @MainActor
    func testOptInOwnedBrowserRejectsMovedTargetAndChangedTextFocus() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: stale observation checks in a visible local fictional form")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mutation in ["geometry", "focus", "selection", "value", "overlay"] {
            let scripts = ["geometry": """
                for (const rule of document.styleSheets[0].cssRules) {
                  if (rule.selectorText === '#origin') rule.style.top='180px';
                  if (rule.selectorText === '#destination') rule.style.top='70px';
                }
                """, "focus": "document.getElementById('origin').focus()",
                "selection": "document.getElementById('destination').setSelectionRange(0,2)",
                "value": "document.getElementById('destination').value='Changed elsewhere'",
                "overlay": "for (const rule of document.styleSheets[0].cssRules) { if (rule.selectorText === '#cover') rule.style.left='60px'; }"]
            let script = try XCTUnwrap(scripts[mutation])
            let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
                <!doctype html><html><head><title>Local stale target</title><style>
                body {font:22px system-ui; background:white; margin:0}
                input {position:absolute;left:60px;width:500px;height:50px;box-sizing:border-box;font:22px system-ui}
                #origin {top:70px} #destination {top:180px}
                #cover {position:absolute;left:9000px;top:180px;width:500px;height:50px;z-index:9}
                </style></head><body><input id="origin" aria-label="Origin" value="Seattle">
                <input id="destination" aria-label="Destination" value="Paris">
                <div id="cover"></div>
                <script>
                document.addEventListener('click', () => fetch('/click'));
                document.addEventListener('input', () => fetch('/input'));
                document.getElementById('destination').focus();
                fetch('/mutate').then(() => { \(script); document.getElementById('destination').getBoundingClientRect(); fetch('/mutated'); });
                </script></body></html>
                """), "/mutate": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: "stale-\(mutation)")
            let document = try await browser.navigate(taskID: "stale-\(mutation)", operationID: "open", to: base.appendingPathComponent("form"))
            let observation = try await browser.captureAgentObservation(document: document)
            let waiting = ContinuousClock.now + .seconds(3)
            while server.count("/mutate") == 0 && ContinuousClock.now < waiting { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(server.count("/mutate"), 1)
            server.releaseHeldResponses()
            let changed = ContinuousClock.now + .seconds(3)
            while server.count("/mutated") == 0 && ContinuousClock.now < changed { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(server.count("/mutated"), 1)
            guard server.count("/mutated") == 1 else { return }
            let action: ComputerUseFaraAction = ["geometry", "overlay"].contains(mutation)
                ? .pointer(.leftClick, .init(x: 310 / observation.viewportSize.width * 1000, y: 205 / observation.viewportSize.height * 1000))
                : .typeText("must not enter Origin")
            var attempts = 0
            do {
                try await browser.performAgentInput(action, observation: observation, willBeginEffect: { attempts += 1 })
                XCTFail("The \(mutation) changed after capture; stale input must not dispatch")
                return
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(attempts, 0)
            XCTAssertEqual(server.count("/click"), 0)
            XCTAssertEqual(server.count("/input"), 0)
        }
    }

    @MainActor
    func testOptInOwnedBrowserRetiresCancelledAndRevokedAgentObservations() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: authority and replay checks in a visible local fictional form")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><title>Local input ownership</title><input aria-label="Destination" style="position:absolute;left:60px;top:180px;width:500px;height:50px">
            <script>document.addEventListener('click', () => fetch('/click'));
            window.addEventListener('resize', () => fetch('/resized'));</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowed })
        defer { browser.close() }
        var stage = "claim retirement browser"
        defer {
            let attachment = XCTAttachment(string: stage)
            attachment.name = "Fara retirement stage"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        do {
        try browser.claim(taskID: "observation-retirement")
        stage = "navigate retirement form"
        let document = try await browser.navigate(taskID: "observation-retirement", operationID: "open", to: base.appendingPathComponent("form"))
        for scenario in ["cancel", "takeover", "closed-gate", "resize", "unsupported", "gate-at-attempt"] {
            stage = "capture \(scenario)"
            let observation = try await browser.captureAgentObservation(document: document)
            let action = ComputerUseFaraAction.pointer(.leftClick,
                .init(x: 310 / observation.viewportSize.width * 1000, y: 205 / observation.viewportSize.height * 1000))
            var attempts = 0
            var expected: ComputerUseBrowserError? = .pageChanged
            stage = "attempt \(scenario)"
            switch scenario {
            case "cancel":
                expected = nil
                let work = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await browser.performAgentInput(action, observation: observation, willBeginEffect: { attempts += 1 })
                }
                do { try await work.value; XCTFail("Cancelled input cannot dispatch"); return }
                catch { XCTAssertTrue(error is CancellationError) }
            case "takeover":
                allowed = false
                browser.prepareForUserControl(taskID: "observation-retirement")
                allowed = true
            case "closed-gate": allowed = false
            case "resize":
                XCTAssertTrue(browser.isFrontmostWindow)
                let window = try XCTUnwrap(NSApp.keyWindow)
                var frame = window.frame; frame.size.width -= 20
                window.setFrame(frame, display: true)
            case "unsupported": expected = .unsupportedDocument
            default: break
            }
            if let expected {
                do {
                    try await browser.performAgentInput(scenario == "unsupported" ? .key(["UnsupportedKey"]) : action,
                        observation: observation, willBeginEffect: {
                            attempts += 1
                            if scenario == "gate-at-attempt" {
                                allowed = false; browser.prepareForUserControl(taskID: "observation-retirement")
                            }
                        })
                    XCTFail("\(scenario) input cannot dispatch"); return
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, expected) }
            }
            allowed = true
            stage = "reject replay \(scenario)"
            do { try await browser.performAgentInput(action, observation: observation); XCTFail("\(scenario) observation cannot revive"); return }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(attempts, scenario == "gate-at-attempt" ? 1 : 0)
            XCTAssertEqual(server.count("/click"), 0)
            if scenario == "resize" {
                stage = "wait for WebKit resize acknowledgement"
                let deadline = ContinuousClock.now + .seconds(3)
                while server.count("/resized") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertGreaterThan(server.count("/resized"), 0)
            }
        }
        // Rejecting an old result must not retire a newer observation.
        stage = "capture old observation"
        let old = try await browser.captureAgentObservation(document: document)
        stage = "capture current observation"
        let current = try await browser.captureAgentObservation(document: document)
        let click = ComputerUseFaraAction.pointer(.leftClick,
            .init(x: 310 / current.viewportSize.width * 1000, y: 205 / current.viewportSize.height * 1000))
        do { try await browser.performAgentInput(click, observation: old); XCTFail("Old image cannot act"); return }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        stage = "dispatch current click"
        try await browser.performAgentInput(click, observation: current)
        let deadline = ContinuousClock.now + .seconds(3)
        while server.count("/click") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.count("/click"), 1)
        stage = "capture before Stop"
        let stopped = try await browser.captureAgentObservation(document: document)
        stage = "Stop and reject"
        browser.stop()
        do { try await browser.performAgentInput(click, observation: stopped); XCTFail("Stopped browser cannot act"); return }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(server.count("/click"), 1)
        } catch {
            stage += "; underlying error before teardown: \(error)"
            throw error
        }
    }

    @MainActor
    func testOptInManagedFaraTypesIntoOwnedBrowserAndStopsAtLogin() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_MANAGED_FARA_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: at most two Fara proposals in a local fictional browser form")
        }
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_MANAGED_REPORT_PATH"]))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        let inputs = try await FaraTestAssets.inputs(environment: environment)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><html><head><meta charset="utf-8"><title>Local travel form</title><style>
            body {font:22px system-ui;background:white;margin:0} label {position:absolute;left:60px}
            input {position:absolute;left:60px;width:500px;height:50px;box-sizing:border-box;font:22px system-ui}
            #origin {top:70px} #destination {top:180px}
            </style></head><body><label for="origin" style="top:30px">Origin</label><input id="origin" value="Seattle">
            <label for="destination" style="top:140px">Destination</label><input id="destination" value="">
            <script>
            document.addEventListener('click', event => fetch('/clicked?target='+encodeURIComponent(event.target.id)));
            document.addEventListener('input', event => {
              const destination = document.getElementById('destination'), origin = document.getElementById('origin');
              fetch('/edited?' + new URLSearchParams({target:event.target.id,trusted:String(event.isTrusted),destination:destination.value,origin:origin.value}));
              if (!document.getElementById('password')) {
                const password = document.createElement('input'); password.id='password'; password.type='password';
                password.style.top='350px'; password.value='private-fixture-password'; document.body.append(password);
                fetch('/login-shown');
              }
            });
            </script></body></html>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "managed-fara-browser")
        let document = try await browser.navigate(taskID: "managed-fara-browser", operationID: "open", to: base.appendingPathComponent("form"))
        let runtime = OSAtlasLlamaRuntime(), worker = ComputerUsePlanningWorker()
        let began = Date()
        var report: [String: Any] = ["scope":"managed-Fara-native-browser-input-login-admission", "targetMacRAMGB":12,
            "wholeApp12GBQualified":false, "fullTaskResumeQualified":false, "status":"running"]
        let executable = inputs.llamaServerURL
        let memory = Task.detached { () -> (UInt64, Int) in
            var peak: UInt64 = 0, count = 0
            while !Task.isCancelled {
                for process in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: executable)) ?? [] {
                    if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: process.processIdentifier) { peak = max(peak, bytes); count += 1 }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return (peak, count)
        }
        var failure: Error?, responses: [[String: Any]] = []
        do {
            let endpoint = try await worker.perform(timeout: 30) { try await runtime.activateFara(inputs) }
            report["startupSeconds"] = Date().timeIntervalSince(began)
            var history: [ComputerUseFaraModel.Step] = []
            var typed = false
            for _ in 0..<2 {
                let observation = try await browser.captureAgentObservation(document: document)
                let input = ComputerUseFaraModel.Input(goal: "In the Destination field, type Tokyo. Leave Origin as Seattle.",
                    screenshotPNG: observation.png, history: history)
                let start = Date()
                let proposal = try await worker.perform(timeout: 25) { try await runtime.proposeFara(endpoint: endpoint, input: input) }
                responses.append(["response":proposal.response,"generationSeconds":Date().timeIntervalSince(start),
                    "imageWidth":observation.pixelWidth,"imageHeight":observation.pixelHeight])
                if case .typeText(let text) = proposal.action {
                    guard text.utf8.elementsEqual("Tokyo".utf8) else { throw ComputerUseFaraAction.Failure.invalidResponse }
                    typed = true
                } else if case .pointer(.leftClick, _) = proposal.action { }
                else { throw ComputerUseBrowserError.unsupportedDocument }
                let prefix = typed ? "/edited?" : "/clicked?"
                let previousEvents = server.requestedPaths.filter { $0.hasPrefix(prefix) }.count
                try await browser.performAgentInput(proposal.action, observation: observation)
                history.append(.init(screenshotPNG: observation.png, response: proposal.response))
                let deadline = ContinuousClock.now + .seconds(3)
                while server.requestedPaths.filter({ $0.hasPrefix(prefix) }).count <= previousEvents && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard server.requestedPaths.filter({ $0.hasPrefix(prefix) }).count > previousEvents else { throw ComputerUseFaraAction.Failure.invalidResponse }
                let path = try XCTUnwrap(server.requestedPaths.last { $0.hasPrefix(prefix) })
                let items = try XCTUnwrap(URLComponents(string: path.replacingOccurrences(of: "+", with: "%20"))?.queryItems)
                let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                guard fields["target"] == "destination" else { throw ComputerUseFaraAction.Failure.invalidResponse }
                if typed {
                    guard fields["destination"] == "Tokyo", fields["origin"] == "Seattle", fields["trusted"] == "true" else {
                        throw ComputerUseFaraAction.Failure.invalidResponse
                    }
                    break
                }
            }
            guard typed else { throw ComputerUseFaraAction.Failure.invalidResponse }
            let deadline = ContinuousClock.now + .seconds(3)
            while server.count("/login-shown") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard server.count("/login-shown") == 1 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            do { _ = try await browser.captureAgentObservation(document: document); throw ComputerUseFaraAction.Failure.invalidResponse }
            catch ComputerUseBrowserError.authenticationRequired { }
            report["status"] = "passed"
        } catch { failure = error; report["status"] = "failed"; report["failure"] = String(describing: error) }
        await runtime.shutdown()
        memory.cancel()
        let measured = await memory.value
        let gone = try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty
        report["responses"] = responses
        report["fixtureRequests"] = server.requestedPaths
        report["peakSampledProcessMemoryBytes"] = measured.0
        report["memorySamples"] = measured.1
        report["ownedProcessExited"] = gone
        report["totalSeconds"] = Date().timeIntervalSince(began)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: reportURL, options: .atomic)
        XCTAssertTrue(gone)
        if let failure { throw failure }
    }

    func testOptInManagedFaraProposesFrozenTargetAndReleasesWorker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_MANAGED_FARA_PROPOSAL"] == "1" else { throw XCTSkip("Opt-in: one managed Fara image proposal without input effects") }
        let assets = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_MODEL_DIRECTORY"]))
        let fixture = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_FIXTURE_DIRECTORY"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_MANAGED_REPORT_PATH"]))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        for (name, expected) in [(ComputerUseFaraRuntimeInputs.modelFileName, "aedd3e6ed7071eb0941a9d86de0f35c16f76eedb9e15dbefa2b4a4e5e7838e51"),
                                 (ComputerUseFaraRuntimeInputs.projectorFileName, "373320845fb5539dd55a66d3faafcd8f123e83a7318334d557a04d604f5ef84d")] {
            let file = try FileHandle(forReadingFrom: assets.appendingPathComponent(name))
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
            }
        }
        let directory = try await OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let executable = directory.appendingPathComponent("llama-server")
        guard try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty else { throw OSAtlasLlamaRuntimeError.inactiveSession }
        let inputs = ComputerUseFaraRuntimeInputs(modelURL: assets.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName),
            projectorURL: assets.appendingPathComponent(ComputerUseFaraRuntimeInputs.projectorFileName), llamaServerURL: executable)
        let oracle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("oracle.json"))) as? [String: Any])
        let goal = try XCTUnwrap(oracle["goal"] as? String)
        guard goal == "Click the Destination field." else { throw ComputerUseFaraAction.Failure.invalidResponse }
        let input = ComputerUseFaraModel.Input(goal: goal, screenshotPNG: try Data(contentsOf: fixture.appendingPathComponent("browser.png")))
        let runtime = OSAtlasLlamaRuntime(), worker = ComputerUsePlanningWorker()
        let began = Date()
        var report: [String: Any] = ["scope": "managed-native-Fara-frozen-image-no-effects", "targetMacRAMGB": 12,
            "wholeApp12GBQualified": false, "memoryMetric": "sampled max of process resident size and physical footprint", "status": "running"]
        let memory = Task.detached { () -> (UInt64, Int) in
            var peak: UInt64 = 0, count = 0
            while !Task.isCancelled {
                for process in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: executable)) ?? [] {
                    if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: process.processIdentifier) {
                        peak = max(peak, bytes); count += 1
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return (peak, count)
        }
        var failure: Error?
        do {
            let endpoint = try await worker.perform(timeout: 45) { try await runtime.activateFara(inputs) }
            report["startupSeconds"] = Date().timeIntervalSince(began)
            let startedGeneration = Date()
            let proposal = try await worker.perform(timeout: 45) { try await runtime.proposeFara(endpoint: endpoint, input: input) }
            report["generationSeconds"] = Date().timeIntervalSince(startedGeneration)
            guard case .pointer(.leftClick, let point) = proposal.action else { throw ComputerUseFaraAction.Failure.invalidResponse }
            let width = try XCTUnwrap(oracle["imageWidth"] as? Int), height = try XCTUnwrap(oracle["imageHeight"] as? Int)
            let bounds = try XCTUnwrap(oracle["destination"] as? [String: Double])
            let pixel = try point.pixel(width: width, height: height)
            let x = Double(pixel.x) * (try XCTUnwrap(bounds["viewportWidth"])) / Double(width)
            let y = Double(pixel.y) * (try XCTUnwrap(bounds["viewportHeight"])) / Double(height)
            let left = try XCTUnwrap(bounds["left"]), top = try XCTUnwrap(bounds["top"])
            guard x > left + 8, x < left + (try XCTUnwrap(bounds["width"])) - 8,
                  y > top + 8, y < top + (try XCTUnwrap(bounds["height"])) - 8 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            report["normalizedCoordinate"] = [point.x, point.y]
            report["status"] = "passed"
        } catch { failure = error; report["status"] = "failed"; report["failure"] = String(describing: error) }
        await runtime.shutdown()
        memory.cancel()
        let measured = await memory.value
        report["peakSampledProcessMemoryBytes"] = measured.0
        report["memorySamples"] = measured.1
        let gone = try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty
        report["ownedProcessExited"] = gone
        report["totalSeconds"] = Date().timeIntervalSince(began)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        XCTAssertTrue(gone)
        if let failure { throw failure }
    }

    private func smallPNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testModelRequestRetainsObservedURLsBesideTheirScreenshots() throws {
        let png = try smallPNG()
        let goal = "Find a concert and give its source URL."
        let sources = (0..<5).map { URL(string: "https://example.com/source/\($0)?q=A%2BB#details")! }
        let history = (0..<4).map { ComputerUseFaraModel.Step(screenshotPNG: png,
            response: call(#"{"action":"wait","time":0}"#), currentURL: sources[$0]) }
        let input = ComputerUseFaraModel.Input(goal: goal, screenshotPNG: png, history: history, currentURL: sources[4])
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "test-only-token")
        let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let userParts = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? [[String: Any]] }
        XCTAssertEqual(userParts.count, 5)
        for (index, parts) in userParts.enumerated() {
            XCTAssertTrue(parts.compactMap { $0["text"] as? String }.contains("Current URL: " + sources[index].absoluteString), "Missing URL at observation \(index)")
        }
        XCTAssertTrue(userParts[0].contains { $0["text"] as? String == goal })
        XCTAssertEqual(userParts.flatMap { $0 }.filter { $0["type"] as? String == "image_url" }.count, 3)
        for source in ["file:///private/tmp/source", "https://person:secret@example.com/", "https://example.com/" + String(repeating: "a", count: 8192)] {
            var invalid = input; invalid.currentURL = URL(string: source)!
            XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: invalid))
            invalid = input; invalid.history[0].currentURL = URL(string: source)!
            XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: invalid))
        }
    }

    func testModelRequestPreservesGoalAndActionHistoryWithOnlyLatestThreeImages() throws {
        let png = try smallPNG()
        let click = call(#"{"action":"left_click","coordinate":[392,540]}"#)
        let history = (0..<4).map { ComputerUseFaraModel.Step(screenshotPNG: png, response: "Observation \($0).\n" + click) }
        let input = ComputerUseFaraModel.Input(goal: "  Type 東京 exactly.  ", screenshotPNG: png, history: history)
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "test-only-token")
        let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, ComputerUseFaraRuntimeInputs.modelAlias)
        XCTAssertEqual(body["reasoning_format"] as? String, "none")
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        let userParts = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? [[String: Any]] }
        XCTAssertEqual(userParts.flatMap { $0 }.filter { $0["type"] as? String == "image_url" }.count, 3)
        XCTAssertEqual(userParts.first?.last?["text"] as? String, input.goal)
        XCTAssertEqual(messages.filter { $0["role"] as? String == "assistant" }.compactMap { $0["content"] as? String }, history.map(\.response))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-only-token"))
        XCTAssertEqual(request.timeoutInterval, 45)
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: .init(goal: "", screenshotPNG: png)))
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: .init(goal: "Click", screenshotPNG: Data("not an image".utf8))))
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: .init(goal: "Click", screenshotPNG: png,
            history: [.init(screenshotPNG: png, response: "Malformed earlier action")])))
    }

    func testModelResponseRequiresCorrectAliasRoleFinishAndNativeAction() throws {
        let content = "The field is visible.\n" + call(#"{"action":"left_click","coordinate":[392,540]}"#)
        func response(model: String = ComputerUseFaraRuntimeInputs.modelAlias, role: String = "assistant", finish: String = "stop", text: String? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["model": model, "choices": [["finish_reason": finish,
                "message": ["role": role, "content": text ?? content]]]])
        }
        let result = try ComputerUseFaraModel.decode(response())
        XCTAssertEqual(result.response, content)
        XCTAssertEqual(result.action, .pointer(.leftClick, .init(x: 392, y: 540)))
        for data in try [response(model: "native-form-planner-v2"), response(role: "user"), response(finish: "length"),
                         response(text: ""), response(text: content + " trailing text")] {
            XCTAssertThrowsError(try ComputerUseFaraModel.decode(data))
        }
    }

    func testOptInDecodeFrozenModelProposalAgainstIndependentDOMOracle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_FROZEN_PROPOSAL_CHECK"] == "1" else { throw XCTSkip("Opt-in: inspect a recorded model proposal without input effects") }
        let responseURL = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_RESPONSE_PATH"]))
        let oracleURL = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_ORACLE_PATH"]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any])
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? String)
        let action = try ComputerUseFaraAction.decodeNativeMessage(content)
        guard case .pointer(.leftClick, let point) = action else { return XCTFail("The actual model must propose one Destination click") }
        let oracle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: oracleURL)) as? [String: Any])
        let bounds = try XCTUnwrap(oracle["destination"] as? [String: Double])
        let width = try XCTUnwrap(oracle["imageWidth"] as? Int), height = try XCTUnwrap(oracle["imageHeight"] as? Int)
        let pixel = try point.pixel(width: width, height: height)
        let pageX = Double(pixel.x) * (try XCTUnwrap(bounds["viewportWidth"])) / Double(width)
        let pageY = Double(pixel.y) * (try XCTUnwrap(bounds["viewportHeight"])) / Double(height)
        let left = try XCTUnwrap(bounds["left"]), top = try XCTUnwrap(bounds["top"])
        // The oracle comes from the original DOM and was never included in the model request.
        XCTAssertGreaterThan(pageX, left + 8)
        XCTAssertLessThan(pageX, left + (try XCTUnwrap(bounds["width"])) - 8)
        XCTAssertGreaterThan(pageY, top + 8)
        XCTAssertLessThan(pageY, top + (try XCTUnwrap(bounds["height"])) - 8)
    }

    @MainActor
    func testOptInRenderFrozenBrowserGroundingFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_FROZEN_FIXTURE"] == "1" else { throw XCTSkip("Opt-in: render only a local fictional form") }
        let directory = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_FIXTURE_DIRECTORY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pngURL = directory.appendingPathComponent("browser.png"), oracleURL = directory.appendingPathComponent("oracle.json")
        guard !FileManager.default.fileExists(atPath: pngURL.path), !FileManager.default.fileExists(atPath: oracleURL.path) else {
            throw ComputerUseFaraAction.Failure.invalidResponse
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1188, height: 768))
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString("""
            <!doctype html><html><head><meta charset='utf-8'><title>Local travel form</title>
            <style>body{font:22px system-ui;background:#f4f7fa;color:#152c41;margin:60px}main{width:820px}label{display:block;margin:36px 0 10px;font-weight:600}input{box-sizing:border-box;width:100%;height:70px;font:24px system-ui;padding:16px;border:2px solid #8195a7;border-radius:8px;background:white}button{margin-top:32px;padding:16px 40px;font:22px system-ui}</style></head>
            <body><main><h1>Travel details</h1><p>Local computer-use test — fictional form</p>
            <label for='origin'>Origin</label><input id='origin' value='Seattle'>
            <label for='destination'>Destination</label><input id='destination' value=''>
            <button type='button'>Search</button></main></body></html>
            """, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var ready = false
        while ContinuousClock.now < deadline {
            ready = (try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('destination')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(ready)
        let observedBounds = try await webView.evaluateJavaScript("""
            (()=>{const r=document.getElementById('destination').getBoundingClientRect();return {left:r.left,top:r.top,width:r.width,height:r.height,viewportWidth:innerWidth,viewportHeight:innerHeight};})()
            """)
        let oracle = try XCTUnwrap(observedBounds as? [String: Any])
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 1188
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0); XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        try png.write(to: pngURL, options: .atomic)
        try JSONSerialization.data(withJSONObject: ["goal": "Click the Destination field.", "destination": oracle,
            "imageWidth": bitmap.pixelsWide, "imageHeight": bitmap.pixelsHigh, "scope": "native-WebKit-local-fictional-form-no-effects"], options: [.prettyPrinted, .sortedKeys]).write(to: oracleURL, options: .atomic)
    }

    private func call(_ arguments: String) -> String {
        "<tool_call>{\"name\":\"computer_use\",\"arguments\":\(arguments)}</tool_call>"
    }

    func testNativeNarrativeIsSeparateFromExactlyOneValidatedAction() throws {
        let click = call(#"{"action":"left_click","coordinate":[392,540]}"#)
        XCTAssertEqual(try ComputerUseFaraAction.decodeNativeMessage("The Destination field is below Origin.\n" + click),
                       .pointer(.leftClick, .init(x: 392, y: 540)))
        XCTAssertEqual(try ComputerUseFaraAction.decodeNativeMessage(click), .pointer(.leftClick, .init(x: 392, y: 540)))
        let payload = "literal <tool_call> and </tool_call> in the requested text"
        let arguments = try JSONSerialization.data(withJSONObject: ["action": "type", "text": payload])
        XCTAssertEqual(try ComputerUseFaraAction.decodeNativeMessage("The field is focused.\n" + call(String(decoding: arguments, as: UTF8.self))), .typeText(payload))
        for response in ["Only notes", "Notes\n" + click + click, "Notes\n" + click + "afterward",
                         "Notes <tool_call>malformed\n" + click, "Notes </tool_call>\n" + click,
                         String(repeating: "x", count: 32_768) + click] {
            XCTAssertThrowsError(try ComputerUseFaraAction.decodeNativeMessage(response))
        }
        // Call-only entry points cannot accidentally treat arbitrary prose as executable.
        XCTAssertThrowsError(try ComputerUseFaraAction.decode("Notes\n" + click))
    }

    func testDecodesOfficialClickAndExactUnicodeTyping() throws {
        let click = try ComputerUseFaraAction.decode(call(#"{"action":"left_click","coordinate":[500,250.5]}"#))
        XCTAssertEqual(click, .pointer(.leftClick, .init(x: 500, y: 250.5)))
        let payload = "  東京 e\u{301} 😀\n<tool_call>literal</tool_call>  "
        let arguments = try JSONSerialization.data(withJSONObject: ["action": "type", "text": payload])
        let action = try ComputerUseFaraAction.decode(call(String(decoding: arguments, as: UTF8.self)))
        guard case .typeText(let text) = action else { return XCTFail("Typing cannot imply a Return or another action") }
        XCTAssertTrue(text.utf8.elementsEqual(payload.utf8))
    }

    func testRejectsMalformedMultipleUnknownAndAmbiguousCalls() throws {
        let valid = call(#"{"action":"left_click","coordinate":[500,250]}"#)
        let invalid = ["", valid + valid, "Run this: " + valid, String(valid.dropLast()),
            call(#"{"action":"shell","text":"echo unexpected"}"#),
            call(#"{"action":"type","action":"key","text":"secret"}"#),
            call(#"{"action":"left_click","coordinate":[true,250]}"#),
            call(#"{"action":"left_click","coordinate":[-1,250]}"#),
            call(#"{"action":"left_click","coordinate":[1001,250]}"#),
            call(#"{"action":"left_click","coordinate":[1,2,3]}"#),
            call(#"{"action":"left_click","coordinate":[1,2],"text":"unrelated"}"#),
            call(#"{"action":"type"}"#), call(#"{"action":"key","keys":[]}"#),
            call(#"{"action":"visit_url","url":"javascript:alert(1)"}"#),
            call(#"{"action":"visit_url","url":"https://user:password@example.com/"}"#),
            call(#"{"action":"wait","time":-1}"#),
            valid.replacingOccurrences(of: "computer_use", with: "another_tool")]
        for response in invalid {
            XCTAssertThrowsError(try ComputerUseFaraAction.decode(response)) {
                XCTAssertEqual($0 as? ComputerUseFaraAction.Failure, .invalidResponse)
            }
        }
    }

    func testSeparatesUserHandoffAndReportedCompletionFromInput() throws {
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"ask_user_question","question":"Please sign in."}"#)), .askUser("Please sign in."))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"terminate","answer":"Found a concert."}"#)), .reportCompletion("Found a concert."))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"web_search","query":"Los Angeles concerts"}"#)), .webSearch("Los Angeles concerts"))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"visit_url","url":"https://example.com/events?q=live"}"#)), .visitURL(try XCTUnwrap(URL(string: "https://example.com/events?q=live"))))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"key","keys":["Control","a"]}"#)), .key(["Control", "a"]))
    }

    func testMapsNormalizedPointsToCurrentImageCellsWithoutEscapingEdges() throws {
        let origin = try ComputerUseFaraAction.Point(x: 0, y: 0).pixel(width: 1188, height: 768)
        XCTAssertEqual(origin.x, 0); XCTAssertEqual(origin.y, 0)
        let middle = try ComputerUseFaraAction.Point(x: 500, y: 250).pixel(width: 1188, height: 768)
        XCTAssertEqual(middle.x, 594); XCTAssertEqual(middle.y, 192)
        let edge = try ComputerUseFaraAction.Point(x: 1000, y: 1000).pixel(width: 1188, height: 768)
        XCTAssertEqual(edge.x, 1187); XCTAssertEqual(edge.y, 767)
        let tiny = try ComputerUseFaraAction.Point(x: 999, y: 999).pixel(width: 1, height: 1)
        XCTAssertEqual(tiny.x, 0); XCTAssertEqual(tiny.y, 0)
        for point in [ComputerUseFaraAction.Point(x: .nan, y: 0), .init(x: .infinity, y: 0), .init(x: -1, y: 0), .init(x: 1001, y: 0)] {
            XCTAssertThrowsError(try point.pixel(width: 1188, height: 768))
        }
        XCTAssertThrowsError(try ComputerUseFaraAction.Point(x: 0, y: 0).pixel(width: 0, height: 768))
        XCTAssertThrowsError(try ComputerUseFaraAction.Point(x: 0, y: 0).pixel(width: Int.max, height: 768))
    }
}

@MainActor
enum FaraTestAssets {
    static func inputs(environment: [String: String]) async throws -> ComputerUseFaraRuntimeInputs {
        let assets = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_MODEL_DIRECTORY"]))
        for (name, expected) in [(ComputerUseFaraRuntimeInputs.modelFileName, "aedd3e6ed7071eb0941a9d86de0f35c16f76eedb9e15dbefa2b4a4e5e7838e51"),
                                 (ComputerUseFaraRuntimeInputs.projectorFileName, "373320845fb5539dd55a66d3faafcd8f123e83a7318334d557a04d604f5ef84d")] {
            let file = try FileHandle(forReadingFrom: assets.appendingPathComponent(name))
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
            }
        }
        let directory = try await OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let executable = directory.appendingPathComponent("llama-server")
        guard try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty else { throw OSAtlasLlamaRuntimeError.inactiveSession }
        return ComputerUseFaraRuntimeInputs(modelURL: assets.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName),
            projectorURL: assets.appendingPathComponent(ComputerUseFaraRuntimeInputs.projectorFileName), llamaServerURL: executable)
    }

}
