import AppKit
import Combine
import Network
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseOwnedBrowserTests: XCTestCase {
    func testWebsiteProjectionAndDocumentDescriptionsOmitOpaqueURLComponents() throws {
        let rows = [
            ("https://example.test/private-path?arbitrary=private-query#private-fragment", "https://example.test"),
            ("https://example.test:8443/a%2Fb;opaque=private-path?next=%2Fprivate-query#private-fragment", "https://example.test:8443"),
            ("http://[::1]:8080/private-path?x=private-query#private-fragment", "http://[::1]:8080"),
            ("https://xn--bcher-kva.example/search?q=books", "https://xn--bcher-kva.example"),
        ]
        for (raw, expected) in rows {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(ComputerUseBrowserSite.displayName(for: url), expected)
            let document = ComputerUseBrowserDocument(contextID: "private-context", taskID: "private-task",
                generation: 1, operationID: "private-operation", requestedURL: url, committedURL: url)
            for description in [String(describing: document), String(reflecting: document)] {
                XCTAssertEqual(description, "ComputerUseBrowserDocument(site: \(expected), source: automationNavigation)")
                XCTAssertFalse(description.contains("private-"))
            }
            XCTAssertEqual(document.requestedURL, url)
            XCTAssertEqual(document.committedURL, url, "Descriptions must not rewrite the retained page identity")
        }
        for raw in ["https://private-user:private-password@example.test/private-path",
                    "https://@example.test/private-path", "file:///tmp/private-path",
                    "data:text/plain,private-path", "/private-path?x=private-query",
                    "https://example.test/" + String(repeating: "x", count: 8_192)] {
            XCTAssertEqual(ComputerUseBrowserSite.displayName(for: try XCTUnwrap(URL(string: raw))), "Website unavailable")
        }
        XCTAssertEqual(ComputerUseBrowserSite.displayName(for: nil), "Website unavailable")
    }

    func testRedirectDisplayOmitsCallbackSecretsWithoutChangingRequestsOrDocumentIdentity() async throws {
        let search = "/search?q=origin%20city&sort=price"
        let callback = "/callback/private-path?payload=private-query#private-fragment"
        let server = try OwnedBrowserHTTPFixture(routes: [search: .init(status: 302, location: callback, held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        var sites: [String] = []
        let observation = browser.$displayedSite.sink { sites.append($0) }
        defer { observation.cancel() }
        let requested = try XCTUnwrap(URL(string: search, relativeTo: base)?.absoluteURL)
        let committed = try XCTUnwrap(URL(string: callback, relativeTo: base)?.absoluteURL)
        try browser.claim(taskID: "callback")
        let navigation = Task { try await browser.navigate(taskID: "callback", operationID: "open", to: requested) }
        try await waitUntil { server.count(search) == 1 }
        XCTAssertEqual(browser.displayedSite, base.absoluteString, "Even the pending destination is a website-only label")
        server.releaseHeldResponses()
        let document = try await navigation.value
        XCTAssertEqual(document.requestedURL, requested, "Search parameters still reach navigation exactly")
        XCTAssertEqual(document.committedURL, committed, "Callback identity includes path, query and fragment")
        XCTAssertEqual(browser.displayedSite, base.absoluteString)
        XCTAssertEqual(server.count("/callback/private-path?payload=private-query"), 1)
        XCTAssertEqual(browser.receipt(taskID: "callback", operationID: "open"), document)
        for changeRequested in [false, true] {
            let other = try XCTUnwrap(URL(string: "/other?payload=other#other", relativeTo: base)?.absoluteURL)
            let altered = ComputerUseBrowserDocument(contextID: document.contextID, taskID: document.taskID,
                generation: document.generation, operationID: document.operationID,
                requestedURL: changeRequested ? other : document.requestedURL,
                committedURL: changeRequested ? document.committedURL : other)
            XCTAssertNotEqual(document, altered)
            XCTAssertFalse(browser.validate(altered), "Equal displayed websites cannot confer document authority")
        }
        XCTAssertTrue(browser.validate(document))
        browser.close()
        XCTAssertEqual(browser.displayedSite, "Website unavailable")
        XCTAssertTrue(sites.allSatisfy { $0 == base.absoluteString || $0 == "Website unavailable" })
    }

    func testResponseMatchingExcludesOnlyFragmentAndNeverReplacesExactDocumentMatching() throws {
        let resource = try XCTUnwrap(URL(string: "https://example.test:8443/callback?opaque=expected"))
        let documentURL = try XCTUnwrap(URL(string: resource.absoluteString + "#private-fragment"))
        XCTAssertTrue(ComputerUseOwnedBrowser.responseURL(resource, matchesDocumentURL: documentURL))
        XCTAssertTrue(ComputerUseOwnedBrowser.responseURL(documentURL, matchesDocumentURL: documentURL))
        XCTAssertFalse(ComputerUseOwnedBrowser.responseURL(nil, matchesDocumentURL: documentURL))
        for raw in ["http://example.test:8443/callback?opaque=expected",
                    "https://other.test:8443/callback?opaque=expected",
                    "https://example.test:9443/callback?opaque=expected",
                    "https://example.test:8443/other?opaque=expected",
                    "https://example.test:8443/callback?opaque=changed",
                    "https://example.test:8443/callback",
                    "https://user@example.test:8443/callback?opaque=expected"] {
            XCTAssertFalse(ComputerUseOwnedBrowser.responseURL(try XCTUnwrap(URL(string: raw)), matchesDocumentURL: documentURL))
        }
        let first = ComputerUseBrowserDocument(contextID: "context", taskID: "task", generation: 1,
            operationID: "operation", requestedURL: resource, committedURL: documentURL)
        let differentFragment = try XCTUnwrap(URL(string: resource.absoluteString + "#other"))
        let second = ComputerUseBrowserDocument(contextID: first.contextID, taskID: first.taskID,
            generation: first.generation, operationID: first.operationID,
            requestedURL: first.requestedURL, committedURL: differentFragment)
        XCTAssertNotEqual(first, second, "A fragment change still invalidates a retained exact document reference")
    }

    func testManualCallbackHandbackRetainsExactURLWithoutPublishingIt() async throws {
        let callback = "/account/private-path?opaque=private-query#private-fragment"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/login": .init(body: "<script>fetch('/signal').then(() => location.href = '\(callback)');</script>"),
            "/signal": .init(held: true),
        ])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        var sites: [String] = []
        let observation = browser.$displayedSite.sink { sites.append($0) }
        defer { observation.cancel() }
        try browser.claim(taskID: "handoff-callback")
        let original = try await browser.navigate(taskID: "handoff-callback", operationID: "login",
            to: base.appendingPathComponent("login"))
        try await waitUntil { server.count("/signal") == 1 }
        allowed = false
        server.releaseHeldResponses()
        try await waitUntil { browser.hasPageAwaitingHandback }
        XCTAssertEqual(browser.displayedSite, base.absoluteString)
        XCTAssertFalse(browser.validate(original))
        XCTAssertThrowsError(try browser.reacquireAfterUserControl(taskID: "handoff-callback"))
        allowed = true
        XCTAssertNil(browser.currentDocument(taskID: "handoff-callback"))
        try browser.reacquireAfterUserControl(taskID: "handoff-callback")
        let current = try XCTUnwrap(browser.currentDocument(taskID: "handoff-callback"))
        let expected = try XCTUnwrap(URL(string: callback, relativeTo: base)?.absoluteURL)
        XCTAssertEqual(current.committedURL, expected)
        XCTAssertEqual(current.source, .userControlObservation)
        XCTAssertNil(browser.receipt(taskID: "handoff-callback", operationID: current.operationID))
        XCTAssertEqual(browser.receipt(taskID: "handoff-callback", operationID: "login"), original)
        XCTAssertEqual(server.count("/account/private-path?opaque=private-query"), 1)
        XCTAssertEqual(server.count("/login"), 1)
        XCTAssertTrue(sites.allSatisfy { $0 == base.absoluteString || $0 == "Website unavailable" })
        XCTAssertFalse(String(reflecting: current).contains("private-"))
    }

    func testFailedCallbackKeepsAddressAndErrorProjectionsFreeOfOpaqueValues() async throws {
        let path = "/private-path?opaque=private-query"
        let server = try OwnedBrowserHTTPFixture(routes: [path: .init(status: 404)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "failed-callback")
        do {
            _ = try await browser.navigate(taskID: "failed-callback", operationID: "open",
                to: XCTUnwrap(URL(string: path + "#private-fragment", relativeTo: base)?.absoluteURL))
            XCTFail("An HTTP failure cannot produce a successful callback receipt")
        } catch {
            XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-"))
            XCTAssertFalse(String(reflecting: error).contains("private-"))
        }
        XCTAssertTrue([base.absoluteString, "Website unavailable"].contains(browser.displayedSite))
        XCTAssertFalse(browser.detail.contains("private-"))
        XCTAssertNil(browser.currentDocument(taskID: "failed-callback"))
        XCTAssertNil(browser.receipt(taskID: "failed-callback", operationID: "open"))
        XCTAssertEqual(server.count(path), 1)
    }

    func testNavigationGrammarRequiresACompleteCurrentTurnCommand() {
        for prompt in ["Open https://example.test/a", "navigate to https://example.test/a",
                       "Go to https://example.test/a", "visit https://example.test/a", "https://example.test/a"] {
            XCTAssertEqual(ComputerUseBrowserNavigationRequest.urls(in: prompt)?.map(\.absoluteString), ["https://example.test/a"])
        }
        XCTAssertEqual(ComputerUseBrowserNavigationRequest.urls(in:
            #"Open "https://example.test/a,b?q=x&y=z" then https://example.test/second"#)?.count, 2)
        XCTAssertEqual(ComputerUseBrowserNavigationRequest.urls(in:
            "Open https://example.test/a, https://example.test/a and then https://example.test/b")?.count, 3)
        XCTAssertEqual(ComputerUseBrowserNavigationRequest.urls(in:
            "Open https://example.test/a then open https://example.test/b and navigate to https://example.test/c")?.count, 3)
        for prompt in ["Don't open https://example.test/a", "Open https://example.test/a and submit the form",
                       "Open https://example.test/a then search for tea", "Explain https://example.test/a",
                       "Open file:///tmp/private", "Open javascript:alert(1)", "Open https://u:p@example.test/",
                       "Open https://example.test/a https://example.test/b", "Open https://example.test/a then",
                       "Open https://example.test/a and don't open https://example.test/b",
                       "Open " + Array(repeating: "https://example.test/a", count: 5).joined(separator: " then ")] {
            XCTAssertNil(ComputerUseBrowserNavigationRequest.urls(in: prompt), prompt)
        }
    }

    func testRepeatedURLHasTwoRealRequestsDistinctReceiptsAndNoDuplicateOperation() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "repeat")
        let url = base.appendingPathComponent("page")
        let first = try await browser.navigate(taskID: "repeat", operationID: "step-1", to: url)
        XCTAssertTrue(browser.validate(first))
        let second = try await browser.navigate(taskID: "repeat", operationID: "step-2", to: url)
        XCTAssertEqual(server.count("/page"), 2)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertFalse(browser.validate(first))
        XCTAssertTrue(browser.validate(second))
        XCTAssertEqual(browser.receipt(taskID: "repeat", operationID: "step-1"), first)
        do {
            _ = try await browser.navigate(taskID: "repeat", operationID: "step-2", to: url)
            XCTFail("A completed operation ID cannot issue another request")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(server.count("/page"), 2)
    }

    func testWrongTaskClosedGateAndInvalidURLCannotStartNavigation() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        try browser.claim(taskID: "owner")
        do {
            _ = try await browser.navigate(taskID: "other", operationID: "wrong", to: base)
            XCTFail("Another task cannot use this context")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        do {
            _ = try await browser.navigate(taskID: "owner", operationID: "invalid", to: URL(string: "file:///tmp/private")!)
            XCTFail("Non-web schemes cannot leave the context")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .invalidURL) }
        allowed = false
        do {
            _ = try await browser.navigate(taskID: "owner", operationID: "paused", to: base)
            XCTFail("A closed action gate must prevent loading")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        XCTAssertEqual(server.requestCount, 0)
    }

    func testBoundNavigationRequiresTheExactCurrentDocumentBeforeLoading() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "bound")
        let url = base.appendingPathComponent("same-url")
        let first = try await browser.navigate(taskID: "bound", operationID: "first", to: url)
        let current = try await browser.navigate(taskID: "bound", operationID: "second", to: url, from: first)
        XCTAssertNotEqual(current.generation, first.generation)
        let foreign = ComputerUseBrowserDocument(contextID: "different-context", taskID: current.taskID,
            generation: current.generation, operationID: current.operationID,
            requestedURL: current.requestedURL, committedURL: current.committedURL)
        let wrongTask = ComputerUseBrowserDocument(contextID: current.contextID, taskID: "another-task",
            generation: current.generation, operationID: current.operationID,
            requestedURL: current.requestedURL, committedURL: current.committedURL)
        for (index, prerequisite) in [first, foreign, wrongTask].enumerated() {
            let operation = "rejected-\(index)"
            do {
                _ = try await browser.navigate(taskID: "bound", operationID: operation,
                    to: base.appendingPathComponent("must-not-open"), from: prerequisite)
                XCTFail("An equal URL cannot replace document, context or task identity")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(browser.currentDocument(taskID: "bound"), current)
            XCTAssertNil(browser.receipt(taskID: "bound", operationID: operation))
        }
        XCTAssertEqual(server.count("/same-url"), 2); XCTAssertEqual(server.count("/must-not-open"), 0)
        let next = try await browser.navigate(taskID: "bound", operationID: "next",
            to: base.appendingPathComponent("next"), from: current)
        XCTAssertTrue(browser.validate(next)); XCTAssertEqual(server.count("/next"), 1)
    }

    func testPageReloadAfterDurableAttemptCannotStartTheNextPlannedNavigation() async throws {
        let body = "<h1>First page</h1><script>if (!sessionStorage.reloaded) { sessionStorage.reloaded = 'yes'; fetch('/signal').then(() => location.reload()); }</script>"
        let server = try OwnedBrowserHTTPFixture(routes: ["/first": .init(body: body), "/signal": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        var dispatchChecks = 0
        let execution = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory,
            beforeNavigationDispatch: { index in
                guard index == 1 else { return }
                dispatchChecks += 1
                let journal = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: "ordered"))
                XCTAssertEqual(journal.statuses, [.verified, .attempted], "The fault must occur after the durable attempt")
                let original = try XCTUnwrap(browser.currentDocument(taskID: "ordered"))
                try await self.waitUntil { server.count("/signal") == 1 }
                server.releaseHeldResponses()
                try await self.waitUntil { server.count("/first") == 2 && !browser.validate(original) }
                XCTAssertTrue(browser.hasOwnership(taskID: "ordered"), "The task still owns this browser despite the document change")
                XCTAssertEqual(browser.receipt(taskID: "ordered", operationID: original.operationID), original)
            })
        defer { execution.close() }
        let prompt = "Open \(base.appendingPathComponent("first").absoluteString) then \(base.appendingPathComponent("must-not-open").absoluteString)"
        for _ in 0..<2 {
            let result = try await execution.execute(taskID: "ordered", prompt: prompt, progress: { _ in })
            guard case .userInterventionRequired = result else { return XCTFail("The changed prerequisite cannot authorize a later navigation") }
        }
        XCTAssertEqual(dispatchChecks, 1, "Resume must reconcile the retained attempt without dispatching again")
        XCTAssertEqual(server.count("/first"), 2); XCTAssertEqual(server.count("/must-not-open"), 0)
        let saved = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: "ordered"))
        XCTAssertEqual(saved.statuses, [.verified, .uncertain])
    }

    func testRedirectRecordsCommittedURLAndSubframesCannotFailMainNavigation() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/redirect": .init(status: 302, location: "/destination"),
            "/destination": .init(body: "<h1>Destination</h1><iframe src='about:blank'></iframe><iframe src='data:text/html,Frame'></iframe><script>window.open('/popup')</script>")])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "redirect")
        let requested = base.appendingPathComponent("redirect")
        let document = try await browser.navigate(taskID: "redirect", operationID: "navigation", to: requested)
        XCTAssertEqual(document.requestedURL, requested)
        XCTAssertEqual(document.committedURL, base.appendingPathComponent("destination"))
        XCTAssertTrue(browser.validate(document))
        XCTAssertEqual(server.count("/redirect"), 1)
        XCTAssertEqual(server.count("/destination"), 1)
        XCTAssertEqual(server.count("/popup"), 0)
    }

    func testHTTPFailureDoesNotProduceSuccessReceipt() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/missing": .init(status: 404)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "missing")
        do {
            _ = try await browser.navigate(taskID: "missing", operationID: "navigation", to: base.appendingPathComponent("missing"))
            XCTFail("A rendered HTTP error cannot prove the requested page opened")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
        XCTAssertNil(browser.receipt(taskID: "missing", operationID: "navigation"))
        XCTAssertNil(browser.currentDocument(taskID: "missing"))
        XCTAssertEqual(server.count("/missing"), 1)
    }

    func testCancelledNavigationAndLateResponseCannotAcquireAReceipt() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "cancel")
        let task = Task { try await browser.navigate(taskID: "cancel", operationID: "navigation", to: base.appendingPathComponent("held")) }
        try await waitUntil { server.count("/held") == 1 }
        do { try browser.claim(taskID: "takeover"); XCTFail("Claim cannot replace in-flight navigation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Late navigation cannot complete a cancelled task") }
        catch is CancellationError { }
        server.releaseHeldResponses()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(browser.receipt(taskID: "cancel", operationID: "navigation"))
        XCTAssertNil(browser.currentDocument(taskID: "cancel"))
        XCTAssertEqual(server.count("/held"), 1)
    }

    func testDeadlineAndOwnershipLossStopPendingLoadWithoutSuccess() async throws {
        for losesOwnership in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, navigationTimeout: .milliseconds(700), mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "deadline")
            let task = Task { try await browser.navigate(taskID: "deadline", operationID: "navigation", to: base.appendingPathComponent("held")) }
            try await waitUntil { server.count("/held") == 1 }
            if losesOwnership { allowed = false; server.releaseHeldResponses() }
            do { _ = try await task.value; XCTFail("A timeout or lost owner cannot produce a ready document") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, losesOwnership ? .ownershipLost : .deadlineExceeded) }
            allowed = true
            XCTAssertNil(browser.receipt(taskID: "deadline", operationID: "navigation"))
            XCTAssertNil(browser.currentDocument(taskID: "deadline"))
        }
    }

    func testPageInitiatedSameURLReloadInvalidatesTheOriginalDocument() async throws {
        let body = "<h1>Reload fixture</h1><script>if (!sessionStorage.reloaded) { sessionStorage.reloaded = 'yes'; fetch('/signal').then(() => location.reload()); }</script>"
        let server = try OwnedBrowserHTTPFixture(routes: ["/reload": .init(body: body), "/signal": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "reload")
        let document = try await browser.navigate(taskID: "reload", operationID: "navigation", to: base.appendingPathComponent("reload"))
        XCTAssertTrue(browser.validate(document))
        try await waitUntil { server.count("/signal") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/reload") == 2 }
        XCTAssertFalse(browser.validate(document))
        XCTAssertNil(browser.currentDocument(taskID: "reload"))
        XCTAssertEqual(browser.receipt(taskID: "reload", operationID: "navigation"), document,
            "The historical navigation receipt must not masquerade as the current document")
    }

    func testUserControlPageNeedsExplicitHandbackAndNeverBecomesNavigationProof() async throws {
        for destination in ["/login", "/account"] {
            let body = """
                <label>Destination <input value="unchanged"></label><script>
                if (!sessionStorage.handoff) {
                    sessionStorage.handoff = 'retained';
                    fetch('/signal').then(() => location.href = '\(destination)');
                }
                </script>
                """
            let landing = """
                <label>Destination <input id="destination"></label><script>
                document.getElementById('destination').value = sessionStorage.handoff || 'lost';
                </script>
                """
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: body), "/account": .init(body: landing), "/signal": .init(held: true),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "handoff")
            let original = try await browser.navigate(taskID: "handoff", operationID: "opened-login",
                to: base.appendingPathComponent("login"))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = false
            server.releaseHeldResponses()
            try await waitUntil { browser.hasPageAwaitingHandback }
            XCTAssertFalse(browser.validate(original))
            XCTAssertThrowsError(try browser.reacquireAfterUserControl(taskID: "handoff")) {
                XCTAssertEqual($0 as? ComputerUseBrowserError, .ownershipLost)
            }
            allowed = true
            XCTAssertNil(browser.currentDocument(taskID: "handoff"), "Opening the gate is not handback")
            XCTAssertThrowsError(try browser.acquireCurrentDocument(taskID: "handoff"))
            try browser.reacquireAfterUserControl(taskID: "handoff")
            let current = try XCTUnwrap(browser.currentDocument(taskID: "handoff"))
            XCTAssertEqual(current.source, .userControlObservation)
            XCTAssertEqual(current.committedURL.path, destination)
            XCTAssertNotEqual(current.generation, original.generation)
            XCTAssertNotEqual(current.operationID, original.operationID)
            XCTAssertEqual(browser.receipt(taskID: "handoff", operationID: "opened-login"), original)
            XCTAssertNil(browser.receipt(taskID: "handoff", operationID: current.operationID))
            XCTAssertFalse(browser.validate(original))
            let target = ComputerUseBrowserTextTarget(browser: browser, document: current, requiresFrontmost: false)
            let fields = try await target.fieldsIfSupported()
            XCTAssertEqual(fields?.first?.snapshot.value, destination == "/account" ? "retained" : "unchanged")
            let transferred = try browser.acquireCurrentDocument(taskID: "next-request")
            XCTAssertEqual(transferred.source, .userControlObservation)
            XCTAssertNil(browser.receipt(taskID: "next-request", operationID: transferred.operationID))
            XCTAssertEqual(server.count("/login"), destination == "/login" ? 2 : 1)
            XCTAssertEqual(server.count("/account"), destination == "/account" ? 1 : 0)
            browser.close()
            XCTAssertFalse(browser.hasPageAwaitingHandback)
            XCTAssertNil(browser.currentDocument(taskID: "next-request"))
        }
    }

    func testFailedOrAutomationTimePageChangesCannotBeAdoptedOnHandback() async throws {
        for row in [(pause: false, status: 200), (pause: true, status: 404)] {
            let body = "<script>fetch('/signal').then(() => location.href = '/destination')</script>"
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: body), "/signal": .init(held: true),
                "/destination": .init(status: row.status),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "rejected-handoff")
            let original = try await browser.navigate(taskID: "rejected-handoff", operationID: "original",
                to: base.appendingPathComponent("login"))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = !row.pause
            server.releaseHeldResponses()
            try await waitUntil { server.count("/destination") == 1 && !browser.isLoadingPage }
            allowed = true
            XCTAssertThrowsError(try browser.reacquireAfterUserControl(taskID: "rejected-handoff")) {
                XCTAssertEqual($0 as? ComputerUseBrowserError, .pageChanged)
            }
            XCTAssertNil(browser.currentDocument(taskID: "rejected-handoff"))
            XCTAssertFalse(browser.hasPageAwaitingHandback)
            XCTAssertEqual(browser.receipt(taskID: "rejected-handoff", operationID: "original"), original)
            XCTAssertEqual(server.count("/login"), 1)
            XCTAssertEqual(server.count("/destination"), 1)
        }
    }

    func testStepJournalResumesAfterFirstPageWithoutReplayingAndContainsNoURLs() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let execution = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { execution.close() }
        let url = base.appendingPathComponent("private-search-token")
        let prompt = "Open \(url) then \(url)"
        do {
            _ = try await execution.execute(taskID: "resume", prompt: prompt, progress: { _ in allowed = false })
            XCTFail("Closing the gate after page one must prevent page two")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        XCTAssertEqual(server.count("/private-search-token"), 1)
        allowed = true
        for _ in 0..<2 {
            let result = try await execution.execute(taskID: "resume", prompt: prompt, progress: { _ in })
            guard case .completed(let text) = result else { return XCTFail("Both requested navigations should be verified") }
            XCTAssertEqual(text, "Opened all 2 pages in the AI browser. Website: \(base.absoluteString)")
        }
        XCTAssertEqual(server.count("/private-search-token"), 2)
        let store = try ComputerUseTaskJournalStore(directory: directory)
        let journal = try XCTUnwrap(store.load(taskID: "resume"))
        XCTAssertEqual(journal.statuses, [.verified, .verified])
        XCTAssertEqual(Set(journal.stepIDs).count, 2)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("private-search-token"))
            XCTAssertFalse(text.contains(base.absoluteString))
        }
    }

    func testUncertainNavigationCannotReplayOnResumeOrNewContext() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, navigationTimeout: .milliseconds(700), mayAct: { true })
        let execution = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { execution.close() }
        let prompt = "Open \(base.appendingPathComponent("held"))"
        do { _ = try await execution.execute(taskID: "uncertain", prompt: prompt, progress: { _ in }); XCTFail("Held response cannot complete") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .deadlineExceeded) }
        let result = try await execution.execute(taskID: "uncertain", prompt: prompt, progress: { _ in })
        guard case .userInterventionRequired = result else { return XCTFail("An uncertain effect cannot replay") }
        let replacement = ComputerUseBrowserNavigationTask(
            browser: ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), journalDirectory: directory)
        defer { replacement.close() }
        do { _ = try await replacement.execute(taskID: "uncertain", prompt: prompt, progress: { _ in }); XCTFail("A new context cannot recover old document authority") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        XCTAssertEqual(server.count("/held"), 1)
    }

    func testProductionCoordinatorUsesOnlyCurrentRequestAndNeverFallsThroughAfterBrowserFailure() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/missing": .init(status: 404)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browserTask = ComputerUseBrowserNavigationTask(
            browser: ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: browserTask)
        defer { tools.closeOwnedBrowser() }
        var nativeCalls = 0
        var desktopLoads = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return .unableToComplete("fixture") },
            desktopFactory: { _ in desktopLoads += 1; return ComputerUseDeferredVisualExecutor() })
        let current = "Open \(base.appendingPathComponent("current"))"
        let result = try await executor.execute(taskID: "current", modelPrompt: "Open \(base.appendingPathComponent("history"))",
            currentUserPrompt: current, conversation: [.init(role: .assistant, text: "Open \(base.appendingPathComponent("assistant"))")],
            tools: tools, progress: { _ in })
        guard case .completed = result else { return XCTFail("Explicit navigation should use the owned browser") }
        XCTAssertEqual(server.count("/current"), 1)
        XCTAssertEqual(server.count("/history"), 0)
        XCTAssertEqual(server.count("/assistant"), 0)
        XCTAssertEqual(nativeCalls, 0)
        do {
            _ = try await executor.execute(taskID: "failure", prompt: "context", trustedUserPrompt: "Open \(base.appendingPathComponent("missing"))",
                tools: tools, progress: { _ in })
            XCTFail("HTTP failure cannot become a completion or model fallback")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
        XCTAssertEqual(nativeCalls, 0)
        XCTAssertEqual(desktopLoads, 0)
        _ = try await executor.execute(taskID: "mixed", prompt: "Open \(base.appendingPathComponent("history"))",
            trustedUserPrompt: "Open \(base.appendingPathComponent("mixed")) and submit the form", tools: tools, progress: { _ in })
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(server.count("/mixed"), 0, "An unsupported whole goal cannot perform only its first navigation")
        XCTAssertEqual(server.count("/history"), 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureError.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum FixtureError: Error { case deadline }
}

@MainActor
final class ComputerUseOwnedBrowserVisibleAcceptanceTests: XCTestCase {
    func testSignedHostPresentsAndClosesItsOwnedBrowserWindow() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: opens only the signed development host's local fixture window")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/window-check": .init(body: """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Local browser check</title><style>
            body { font: 17px system-ui; margin: 0; color: #172d36; background: #f5f8f9 }
            main { max-width: 640px; margin: 48px auto; padding: 0 28px } h1 { font-size: 32px }
            article { padding: 24px; border: 1px solid #bdd0d7; border-radius: 12px; background: white }
            </style></head><body><main><p>REMOTE DESKTOP · LOCAL FIXTURE</p><h1>Your AI browser</h1>
            <article><h2>Page opened</h2><p>This page comes from an isolated web server on this Mac.</p>
            <p>The window belongs to the current task. Stop releases that task's browser control.</p></article>
            <label>Origin <input value="unchanged" oninput="fetch('/focus-edit')"></label>
            </main><script>
            fetch(sessionStorage.priorTask ? '/retained-context' : '/fresh-context');
            sessionStorage.priorTask = 'yes';
            </script></body></html>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "visible-fixture")
        let document = try await browser.navigate(taskID: "visible-fixture", operationID: "page", to: base.appendingPathComponent("window-check"))
        let window = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "AI Browser — Remote Desktop" }))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.minSize, NSSize(width: 480, height: 320))
        XCTAssertTrue(browser.validate(document))
        XCTAssertTrue(browser.isFrontmostWindow)
        let target = ComputerUseBrowserTextTarget(browser: browser, document: document)
        let fields = try await target.fields()
        let field = try XCTUnwrap(fields.first)
        let competingWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 200),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        competingWindow.title = "Competing local fixture"
        competingWindow.isReleasedWhenClosed = false
        defer { competingWindow.close() }
        competingWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(NSApp.keyWindow === competingWindow)
        XCTAssertFalse(browser.hasRequiredPresentation)
        do {
            try await target.apply(.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "wrong window"),
                expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["focus-loss"]))
            XCTFail("Losing the actual key window must stop browser edits")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        competingWindow.close()
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(browser.isFrontmostWindow)
        let unchanged = try await target.read(targetID: field.snapshot.targetID)
        XCTAssertEqual(unchanged?.value, "unchanged")
        XCTAssertEqual(server.count("/focus-edit"), 0)
        let initialDeadline = ContinuousClock.now + .seconds(5)
        while server.count("/fresh-context") == 0 && ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.count("/fresh-context"), 1)
        window.setContentSize(NSSize(width: 480, height: 340))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(browser.validate(document))
        if ProcessInfo.processInfo.environment["INSPECT_OWNED_BROWSER_WINDOW"] == "1" {
            let deadline = ContinuousClock.now + .seconds(180)
            while browser.taskID != nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(browser.taskID, "The visible Stop button must release task ownership during inspection")
            XCTAssertFalse(browser.validate(document))
        }
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.contentView, "A closed window must release the embedded WebKit view")
        XCTAssertNil(browser.taskID)
        XCTAssertFalse(browser.validate(document))
        try browser.claim(taskID: "reopened-fixture")
        _ = try await browser.navigate(taskID: "reopened-fixture", operationID: "fresh-page", to: base.appendingPathComponent("window-check"))
        let deadline = ContinuousClock.now + .seconds(5)
        while server.count("/fresh-context") < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.count("/fresh-context"), 2, "Closing a window must destroy its private browser session")
        XCTAssertEqual(server.count("/retained-context"), 0)
        XCTAssertEqual(server.count("/window-check"), 2)
    }
}

/// A loopback-only HTTP origin with an independent request counter. No test
/// depends on public network pages, ambient browser profiles or Accessibility.
final class OwnedBrowserHTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var location: String? = nil
        var body = "<!doctype html><title>Browser fixture</title><h1>Verified local page</h1>"
        var held = false
        var bytes: Data {
            let content = Data(body.utf8)
            let headers = "HTTP/1.1 \(status) Fixture\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
                + (location.map { "Location: \($0)\r\n" } ?? "") + "\r\n"
            return Data(headers.utf8) + content
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "remotedesktop.test.owned-browser-http")
    private let lock = NSLock()
    private let routes: [String: Response]
    private var requests: [String] = []
    private var active: [NWConnection] = []
    private var held: [(NWConnection, Data)] = []
    private var readyReported = false
    var requestCount: Int { lock.withLock { requests.count } }
    var requestedPaths: [String] { lock.withLock { requests } }
    func count(_ path: String) -> Int { lock.withLock { requests.filter { $0 == path }.count } }

    init(routes: [String: Response] = [:]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.active.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<URL, Error>
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    result = .success(URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let first = self.lock.withLock { let first = !self.readyReported; self.readyReported = true; return first }
                if first { continuation.resume(with: result) }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] chunk, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            let accumulated = data + (chunk ?? Data())
            guard accumulated.count <= 8_192 else { connection.cancel(); return }
            guard accumulated.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection, data: accumulated) }
                return
            }
            guard let text = String(data: accumulated, encoding: .utf8),
                  let line = text.components(separatedBy: "\r\n").first else { connection.cancel(); return }
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == "GET" else { connection.cancel(); return }
            let path = String(fields[1])
            let response = self.routes[path] ?? Response()
            self.lock.withLock {
                self.requests.append(path)
                if response.held { self.held.append((connection, response.bytes)) }
            }
            if !response.held { Self.send(response.bytes, on: connection) }
        }
    }

    private static func send(_ bytes: Data, on connection: NWConnection) {
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
    func releaseHeldResponses() {
        let responses = lock.withLock { let responses = held; held = []; return responses }
        for (connection, bytes) in responses { Self.send(bytes, on: connection) }
    }
    func stop() {
        listener.cancel()
        let connections = lock.withLock { let connections = active; active = []; held = []; return connections }
        connections.forEach { $0.cancel() }
    }
}
