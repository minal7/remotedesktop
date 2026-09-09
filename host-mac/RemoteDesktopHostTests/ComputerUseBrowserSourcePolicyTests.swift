import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserSourcePolicyTests: XCTestCase {
    func testNativePolicyObservationsKeepSlotCorrelationSeparateFromExactNavigationCallbacks() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let origin = try ComputerUseBrowserSourceOrigin(base)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "native", to: base)
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        let attempt = try XCTUnwrap(history.attempts.first)
        let action = try XCTUnwrap(history.observations.first { $0.phase == .navigationAction && $0.attemptID == attempt.id })
        let response = try XCTUnwrap(history.observations.first { $0.phase == .response && $0.attemptID == attempt.id })
        let start = try XCTUnwrap(history.observations.first { $0.phase == .provisionalStart && $0.attemptID == attempt.id })
        let commit = try XCTUnwrap(history.observations.first { $0.phase == .documentCommitStarted && $0.attemptID == attempt.id })
        let finish = try XCTUnwrap(history.observations.first { $0.phase == .documentFinished && $0.attemptID == attempt.id })
        for event in [action, response] {
            XCTAssertEqual(event.binding, .pendingSlot); XCTAssertEqual(event.decision, .allowed)
            XCTAssertEqual(event.policyCheck, .permitted); XCTAssertEqual(event.configuredPolicy, policy)
            XCTAssertEqual(event.origin, origin)
        }
        XCTAssertEqual(action.control, .automationAllowed)
        XCTAssertEqual(response.control, .unknown, "Response policy enforcement does not query the pending operation's current control gate")
        for event in [start, commit, finish] {
            XCTAssertEqual(event.binding, .exactPendingNavigation); XCTAssertEqual(event.decision, .observed)
            XCTAssertEqual(event.policyCheck, .notChecked)
        }
        for event in [action, response, start, commit, finish] {
            XCTAssertEqual(event.attemptID, attempt.id)
            XCTAssertEqual(event.parentSessionID, attempt.sessionID)
            XCTAssertEqual(event.ownershipEpoch, attempt.ownershipEpoch)
            XCTAssertEqual(event.generation, attempt.generation)
            XCTAssertEqual(event.navigationCorrelationID, start.navigationCorrelationID)
        }
        XCTAssertNotNil(start.navigationCorrelationID)
        XCTAssertTrue(history.observations.contains { $0.phase == .locationChanged })
        XCTAssertFalse(history.observationsOverflowed)
    }

    func testRedirectCallbacksRemainObservationsRatherThanInventedRequestDecisions() async throws {
        let destination = try OwnedBrowserHTTPFixture(), target = try await destination.start()
        let server = try OwnedBrowserHTTPFixture(routes: ["/redirect": .init(status: 302, location: target.absoluteString + "/callback?code=private-code#private-fragment")])
        let base = try await server.start()
        defer { server.stop(); destination.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input,
            allowedOrigins: [ComputerUseBrowserSourceOrigin(base), ComputerUseBrowserSourceOrigin(target)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "redirect", to: base.appendingPathComponent("redirect"))
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        let attempt = try XCTUnwrap(history.attempts.first)
        let redirect = try XCTUnwrap(history.observations.first { $0.phase == .serverRedirect && $0.attemptID == attempt.id })
        XCTAssertEqual(redirect.binding, .exactPendingNavigation); XCTAssertEqual(redirect.attemptID, attempt.id)
        XCTAssertEqual(redirect.decision, .observed); XCTAssertEqual(redirect.policyCheck, .notChecked)
        XCTAssertEqual(redirect.control, .unknown); XCTAssertEqual(redirect.configuredPolicy, policy)
        // WebKit's redirect callback has no destination argument. Do not
        // assert that its live location snapshot is the next requested origin.
        XCTAssertEqual(attempt.committedOrigin, try ComputerUseBrowserSourceOrigin(target))
        XCTAssertTrue(history.observations.contains {
            $0.phase == .response && $0.decision == .allowed && $0.origin == attempt.committedOrigin
        })
        for observation in history.observations {
            let text = String(reflecting: observation)
            XCTAssertFalse(text.contains("private-code")); XCTAssertFalse(text.contains("private-fragment"))
            XCTAssertFalse(text.contains(base.absoluteString)); XCTAssertFalse(text.contains(target.absoluteString))
        }
    }

    func testScriptedNavigationHasItsOwnObservedIdentityWithoutCreatingAnAutomatedDispatch() async throws {
        let destination = try OwnedBrowserHTTPFixture(), target = try await destination.start()
        let script = "fetch('/go').then(() => location.href = '\(target.absoluteString)/landed');"
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<h1>Starting page</h1><script>\(script)</script>"), "/go": .init(held: true)])
        let base = try await server.start()
        defer { server.stop(); destination.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input,
            allowedOrigins: [ComputerUseBrowserSourceOrigin(base), ComputerUseBrowserSourceOrigin(target)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "first", to: base.appendingPathComponent("page"))
        try await waitUntil { server.count("/go") == 1 }
        let before = try browser.navigationDispatchHistory(taskID: input.taskID)
        let targetOrigin = try ComputerUseBrowserSourceOrigin(target)
        server.releaseHeldResponses()
        try await waitUntil {
            (try? browser.navigationDispatchHistory(taskID: input.taskID).observations.dropFirst(before.observations.count).contains {
                $0.phase == .documentFinished && $0.binding == .exactObservedNavigation && $0.origin == targetOrigin
            }) == true
        }
        let after = try browser.navigationDispatchHistory(taskID: input.taskID)
        let added = after.observations.dropFirst(before.observations.count)
        let started = try XCTUnwrap(added.first { $0.phase == .provisionalStart && $0.binding == .exactObservedNavigation })
        let finished = try XCTUnwrap(added.first { $0.phase == .documentFinished && $0.binding == .exactObservedNavigation })
        XCTAssertEqual(started.control, .automationAllowed)
        XCTAssertEqual(started.navigationCorrelationID, finished.navigationCorrelationID)
        XCTAssertNotNil(started.navigationCorrelationID)
        XCTAssertNil(started.attemptID); XCTAssertNil(finished.attemptID)
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertNotEqual(after.identity, before.identity)
        XCTAssertEqual(finished.origin, try ComputerUseBrowserSourceOrigin(target))
        XCTAssertEqual(destination.count("/landed"), 1)
    }

    func testDispatchHistoryKeepsNativeOriginsAndThePolicyUsedByEachAttempt() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let origin = try ComputerUseBrowserSourceOrigin(base)
        let firstPolicy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin])
        try browser.installSourcePolicy(firstPolicy, replacing: nil, session: session)
        let empty = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(empty.attempts.isEmpty); XCTAssertFalse(empty.beganAfterAnotherClaim)
        let destination = try url(base.absoluteString + "/private-callback?code=secret-callback#private-fragment")
        let document = try await browser.navigate(taskID: input.taskID, operationID: "first", to: destination)
        let first = try browser.navigationDispatchHistory(taskID: input.taskID)
        let attempt = try XCTUnwrap(first.attempts.first)
        XCTAssertEqual(first.taskID, input.taskID); XCTAssertEqual(first.contextID, browser.contextID)
        XCTAssertEqual(attempt.operationID, "first"); XCTAssertEqual(attempt.generation, document.generation)
        XCTAssertEqual(attempt.requestedOrigin, origin); XCTAssertEqual(attempt.committedOrigin, origin)
        XCTAssertEqual(attempt.policy, firstPolicy); XCTAssertEqual(attempt.outcome, .documentCommitted)
        XCTAssertNotEqual(first.identity, empty.identity)
        let nextPolicy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin],
            excludedOrigins: [ComputerUseBrowserSourceOrigin(url("https://blocked.test"))])
        try browser.installSourcePolicy(nextPolicy, replacing: firstPolicy.digest, session: session)
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: input.taskID).attempts, first.attempts,
            "Installing a new policy cannot rewrite which policy governed earlier work")
        _ = try await browser.navigate(taskID: input.taskID, operationID: "second", to: base)
        let second = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(first.attempts, [attempt], "Returned history is an immutable value snapshot")
        XCTAssertEqual(second.attempts.map(\.policy), [firstPolicy, nextPolicy])
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertEqual(second.attempts.first, attempt)
        for value in [String(reflecting: first), String(reflecting: attempt)] {
            for hidden in [input.taskID, "private-callback", "secret-callback", "private-fragment", base.absoluteString, firstPolicy.digest] {
                XCTAssertFalse(value.contains(hidden))
            }
        }
        XCTAssertThrowsError(try browser.navigationDispatchHistory(taskID: "foreign-task"))
    }

    func testDispatchHistoryRetainsCancellationAndFailureWithoutInventingCommitOrigins() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true), "/missing": .init(status: 404)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        let work = Task { try await browser.navigate(taskID: input.taskID, operationID: "cancelled", to: base.appendingPathComponent("held")) }
        try await waitUntil { server.count("/held") == 1 }
        let pending = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(pending.attempts.first?.outcome, .pending)
        XCTAssertNil(pending.attempts.first?.committedOrigin)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled navigation cannot return a document") } catch { }
        let cancelled = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(cancelled.attempts.first?.outcome, .ownershipLost)
        XCTAssertNil(cancelled.attempts.first?.committedOrigin)
        XCTAssertEqual(cancelled.attempts.first?.id, pending.attempts.first?.id)
        XCTAssertEqual(pending.attempts.first?.outcome, .pending)
        XCTAssertNotEqual(cancelled.identity, pending.identity)
        do { _ = try await browser.navigate(taskID: input.taskID, operationID: "failed", to: base.appendingPathComponent("missing")); XCTFail("HTTP failure cannot commit") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
        let failed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(failed.attempts.map(\.outcome), [.ownershipLost, .failed])
        XCTAssertTrue(failed.attempts.allSatisfy { $0.policy == nil && $0.committedOrigin == nil })
        XCTAssertEqual(failed.attempts.map(\.requestedOrigin), [try ComputerUseBrowserSourceOrigin(base), try ComputerUseBrowserSourceOrigin(base)])
        XCTAssertNil(browser.receipt(taskID: input.taskID, operationID: "failed"))
        let rejectedResponse = try XCTUnwrap(failed.observations.first {
            $0.phase == .response && $0.attemptID == failed.attempts.last?.id && $0.decision == .cancelled
        })
        XCTAssertEqual(rejectedResponse.policyCheck, .notChecked, "HTTP failure is rejected before source policy assessment")
        XCTAssertEqual(rejectedResponse.binding, .pendingSlot)
    }

    func testDispatchHistoryRetainsATimedOutNativeAttempt() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)]), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, navigationTimeout: .milliseconds(250), mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        do { _ = try await browser.navigate(taskID: input.taskID, operationID: "timed-out", to: base.appendingPathComponent("held")); XCTFail("Held response must time out") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .deadlineExceeded) }
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(history.attempts.count, 1); XCTAssertEqual(history.attempts.first?.outcome, .timedOut)
        XCTAssertNil(history.attempts.first?.committedOrigin)
        XCTAssertTrue(browser.hasNavigationAttempt(operationID: "timed-out"))
    }

    func testDispatchHistorySurvivesSameTaskStopAndBrowserRecreationWithoutReusingAttemptIdentity() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "same-id", to: base)
        let first = try browser.navigationDispatchHistory(taskID: input.taskID)
        browser.stop()
        XCTAssertThrowsError(try browser.navigationDispatchHistory(taskID: input.taskID))
        try browser.claim(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "same-id", to: base)
        let reclaimed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(reclaimed.hasClaimBoundary); XCTAssertFalse(first.hasClaimBoundary)
        XCTAssertEqual(reclaimed.attempts.count, 2)
        XCTAssertEqual(reclaimed.attempts[0], first.attempts[0])
        XCTAssertEqual(reclaimed.attempts.map(\.operationID), ["same-id", "same-id"])
        XCTAssertNotEqual(reclaimed.attempts[0].id, reclaimed.attempts[1].id)
        XCTAssertNotEqual(reclaimed.attempts[0].ownershipEpoch, reclaimed.attempts[1].ownershipEpoch)
        XCTAssertEqual(reclaimed.attempts[0].sessionID, reclaimed.attempts[1].sessionID)
        XCTAssertNil(reclaimed.attempts[1].policy)
        browser.close(); try browser.claim(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "after-close", to: base)
        let reopened = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(reopened.attempts.count, 3)
        XCTAssertEqual(Array(reopened.attempts.prefix(2)), reclaimed.attempts)
        XCTAssertNotEqual(reopened.attempts[1].sessionID, reopened.attempts[2].sessionID)
        XCTAssertNotEqual(reopened.identity, reclaimed.identity)
    }

    func testDispatchHistoryMakesDiscardedOtherClaimHistoryExplicit() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "first", to: base)
        let original = try browser.navigationDispatchHistory(taskID: input.taskID)
        browser.stop(); try browser.claim(taskID: "another-task")
        let other = try browser.navigationDispatchHistory(taskID: "another-task")
        XCTAssertTrue(other.beganAfterAnotherClaim); XCTAssertTrue(other.attempts.isEmpty)
        XCTAssertNotEqual(other.identity, original.identity)
        XCTAssertThrowsError(try browser.navigationDispatchHistory(taskID: input.taskID))
        browser.stop(); try browser.claim(taskID: input.taskID)
        let returned = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(returned.beganAfterAnotherClaim); XCTAssertTrue(returned.attempts.isEmpty)
        XCTAssertNotEqual(returned.identity, original.identity)
        XCTAssertEqual(original.attempts.count, 1)
    }

    func testDispatchHistoryBoundsRepeatedClaimsWithoutSilentlyDroppingEarlierAttempts() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        for index in 0..<64 {
            _ = try await browser.navigate(taskID: input.taskID, operationID: "attempt-\(index)", to: base)
        }
        let full = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(full.attempts.count, 64); XCTAssertFalse(full.overflowed)
        browser.stop(); try browser.claim(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "after-limit", to: base)
        let overflowed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(overflowed.overflowed); XCTAssertTrue(overflowed.hasClaimBoundary)
        XCTAssertEqual(overflowed.attempts, full.attempts)
        XCTAssertNotEqual(overflowed.identity, full.identity)
        XCTAssertTrue(browser.hasNavigationAttempt(operationID: "after-limit"))
        XCTAssertNotNil(browser.receipt(taskID: input.taskID, operationID: "after-limit"))
    }

    func testSourceOriginsKeepSchemeHostAndEffectivePortWithoutSuffixOrCredentialAliases() throws {
        let input = try goal(), origin = try ComputerUseBrowserSourceOrigin(url("https://EXAMPLE.test:443/path?private=value"))
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin])
        XCTAssertTrue(policy.permits(try url("https://example.test/other#fragment")))
        for raw in ["https://example.test.evil.test", "https://sub.example.test", "https://www.example.test", "http://example.test",
            "https://example.test:444", "https://example.test.", "https://user@example.test", "https://example.test@evil.test"] {
            XCTAssertFalse(policy.permits(try url(raw)))
        }
        let excluded = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin], excludedOrigins: [origin])
        XCTAssertFalse(excluded.permits(try url("https://example.test")))
        let empty = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [])
        XCTAssertFalse(empty.permits(try url("https://example.test")))
        let unrestricted = try ComputerUseBrowserSourcePolicy(goal: input)
        XCTAssertTrue(unrestricted.permits(try url("https://another.test")))
        XCTAssertNotEqual(empty.digest, unrestricted.digest)
        XCTAssertEqual(policy.digest, try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin, origin]).digest)
        let ipv6 = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(url("http://[::1]"))])
        XCTAssertTrue(ipv6.permits(try url("http://[0:0:0:0:0:0:0:1]:80/path")))
        let excludingIPv4 = try ComputerUseBrowserSourcePolicy(goal: input, excludedOrigins: [ComputerUseBrowserSourceOrigin(url("http://127.0.0.1"))])
        for raw in ["http://127.1", "http://2130706433", "http://0x7f000001", "http://0177.0.0.1"] {
            XCTAssertFalse(excludingIPv4.permits(try url(raw)))
        }
        XCTAssertFalse(String(reflecting: origin).contains("example")); XCTAssertFalse(String(reflecting: policy).contains(input.taskID))
    }

    func testSourcePlanRejectsAProviderOutsideScopeAndBindsInitialSearchToPolicy() async throws {
        let input = try goal(), interpretation = try await BrowserResearchGoalFixture().propose(input)
        let provider = try ComputerUseBrowserSearchProvider(endpoint: url("https://search.test/search"), queryParameter: "q")
        let origin = try ComputerUseBrowserSourceOrigin(url("https://search.test")), other = try ComputerUseBrowserSourceOrigin(url("https://other.test"))
        XCTAssertThrowsError(try ComputerUseBrowserResearchSources(goal: input, provider: provider, allowedOrigins: [other]))
        XCTAssertThrowsError(try ComputerUseBrowserResearchSources(goal: input, provider: provider, excludedOrigins: [origin]))
        let sources = try ComputerUseBrowserResearchSources(goal: input, provider: provider, allowedOrigins: [origin])
        let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"requirement":0,"text":"concerts"}]}"#, interpretation: interpretation)
        let old = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation, query: query, provider: provider)
        let current = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation, query: query, provider: provider, sourcePolicy: sources.policy)
        XCTAssertEqual(old.destination, current.destination); XCTAssertNotEqual(old.digest, current.digest)
        let foreign = try ComputerUseBrowserSourcePolicy(goal: goal(id: "foreign"), allowedOrigins: [origin])
        XCTAssertThrowsError(try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation, query: query, provider: provider, sourcePolicy: foreign))
    }

    func testNativeSourcePolicyStopsBeforeDispatchAndRejectsChangedPolicyAtTheEffectBoundary() async throws {
        let first = try OwnedBrowserHTTPFixture(), second = try OwnedBrowserHTTPFixture()
        let base = try await first.start(), outside = try await second.start()
        defer { first.stop(); second.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        var callbacks = 0
        do { _ = try await browser.navigate(taskID: input.taskID, operationID: "outside", to: outside, willBeginEffect: { callbacks += 1 }); XCTFail("Outside source cannot reach dispatch admission") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(second.requestCount, 0); XCTAssertFalse(browser.hasNavigationAttempt(operationID: "outside"))
        XCTAssertTrue(try browser.navigationDispatchHistory(taskID: input.taskID).attempts.isEmpty)
        let replacement = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [])
        do {
            _ = try await browser.navigate(taskID: input.taskID, operationID: "changed", to: base, willBeginEffect: {
                callbacks += 1; try browser.installSourcePolicy(replacement, replacing: policy.digest, session: session)
            })
            XCTFail("The captured policy cannot change before native load")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(callbacks, 1); XCTAssertEqual(first.requestCount, 0); XCTAssertFalse(browser.hasNavigationAttempt(operationID: "changed"))
        XCTAssertTrue(try browser.navigationDispatchHistory(taskID: input.taskID).attempts.isEmpty)
        XCTAssertThrowsError(try browser.installSourcePolicy(policy, replacing: nil, session: session))
        try browser.installSourcePolicy(policy, replacing: replacement.digest, session: session)
        browser.stop(); try browser.claim(taskID: "next-task")
        XCTAssertThrowsError(try browser.installSourcePolicy(policy, replacing: nil, session: session))
        _ = try await browser.navigate(taskID: "next-task", operationID: "next", to: outside)
        XCTAssertEqual(second.requestCount, 1, "A new task does not inherit the retired task's source policy")
    }

    func testSourcePolicyChecksRedirectDestinationsAndCannotReplayABlockedAttempt() async throws {
        for includeDestination in [false, true] {
            let destination = try OwnedBrowserHTTPFixture(), target = try await destination.start()
            let start = try OwnedBrowserHTTPFixture(routes: ["/first": .init(status: 302, location: "/second"),
                "/second": .init(status: 302, location: target.appendingPathComponent("result").absoluteString)])
            let base = try await start.start()
            defer { start.stop(); destination.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
            var origins = [try ComputerUseBrowserSourceOrigin(base)]
            if includeDestination { origins.append(try ComputerUseBrowserSourceOrigin(target)) }
            try browser.installSourcePolicy(.init(goal: input, allowedOrigins: origins), replacing: nil, session: session)
            do {
                let document = try await browser.navigate(taskID: input.taskID, operationID: "redirect", to: base.appendingPathComponent("first"))
                XCTAssertTrue(includeDestination); XCTAssertEqual(document.committedURL, target.appendingPathComponent("result"))
            } catch { XCTAssertFalse(includeDestination); XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
            XCTAssertEqual(start.count("/first"), 1); XCTAssertEqual(start.count("/second"), 1)
            XCTAssertEqual(destination.count("/result"), includeDestination ? 1 : 0)
            XCTAssertTrue(browser.hasNavigationAttempt(operationID: "redirect"))
            let history = try browser.navigationDispatchHistory(taskID: input.taskID)
            XCTAssertEqual(history.attempts.count, 1)
            XCTAssertEqual(history.attempts.first?.requestedOrigin, try ComputerUseBrowserSourceOrigin(base))
            XCTAssertEqual(history.attempts.first?.outcome, includeDestination ? .documentCommitted : .sourceBlocked)
            XCTAssertEqual(history.attempts.first?.committedOrigin, includeDestination ? try ComputerUseBrowserSourceOrigin(target) : nil)
            if !includeDestination { XCTAssertNil(browser.receipt(taskID: input.taskID, operationID: "redirect")) }
            do { _ = try await browser.navigate(taskID: input.taskID, operationID: "redirect", to: base.appendingPathComponent("first")); XCTFail("A blocked redirect still attempted its first request") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(start.count("/first"), 1)
        }
    }

    func testObservedLinkAndFormQueryBindingsIncludeTheCurrentSourcePolicy() async throws {
        for isQuery in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body:
                "<a href='/target'>Details</a><form action='/query' method='get'><input name='q' value='tickets'><button type='submit'>Search</button></form>")])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
            let document = try await browser.navigate(taskID: input.taskID, operationID: "page", to: base.appendingPathComponent("page"))
            func prepare() async throws -> ComputerUseBrowserNavigationTarget {
                let evidence = try await browser.observePage(document: document)
                if isQuery {
                    let submit = try XCTUnwrap(evidence.page.controls.first { $0.kind == "submit" })
                    return try await browser.prepareFormQuery(controlID: submit.id, evidence: evidence)
                }
                return try await browser.prepareLinkNavigation(linkID: XCTUnwrap(evidence.page.links.first?.id), evidence: evidence)
            }
            let old = try await prepare(), policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
            try browser.installSourcePolicy(policy, replacing: nil, session: session)
            do { try await browser.validateObservedDestination(old); XCTFail("An earlier policy is part of the old target binding") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            let current = try await prepare()
            XCTAssertNotEqual(current.payloadDigest, old.payloadDigest)
            _ = try await browser.openObservedDestination(current, operationID: ComputerUseTaskContract.digest(["scoped-target"]))
            XCTAssertEqual(server.count(isQuery ? "/query?q=tickets" : "/target"), 1)
        }
    }

    func testResearchDriverRetainsItsSourcePlanAndRejectsOutsideProviderOrSelectedLink() async throws {
        let outsideServer = try OwnedBrowserHTTPFixture(), outside = try await outsideServer.start()
        defer { outsideServer.stop() }
        for providerOutside in [false, true] {
            let fixture = try await ResearchDriverFixture.make(linkDestinationOverride: outside.appendingPathComponent("offer").absoluteString)
            defer { fixture.close() }
            fixture.policy.choices = [true, true]
            fixture.policy.allowedOrigins = [try ComputerUseBrowserSourceOrigin(providerOutside ? outside : fixture.base)]
            let result = try await fixture.start()
            guard case .userInterventionRequired? = result else { return XCTFail("Source failure must retain the complete task") }
            let owner = try fixture.owner(), original = owner.input
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), providerOutside ? 0 : 1)
            XCTAssertEqual(outsideServer.requestCount, 0); XCTAssertFalse(owner.hasPendingNavigation)
            if !providerOutside {
                fixture.policy.allowedOrigins?.append(try ComputerUseBrowserSourceOrigin(outside))
                owner.pause(); try await owner.resumeAfterUserControl()
                _ = try await fixture.resume()
                XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.policy.providerCalls, 1)
                XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(outsideServer.requestCount, 0)
            }
        }
    }

    func testOwnerPolicyCannotChangeAnAcceptedRevisionOrReplacePendingWork() async throws {
        let fixture = try await ResearchDriverFixture.make(seedPage: true)
        defer { fixture.close() }
        try await fixture.pauseInitialSearch()
        let owner = try fixture.owner(), original = owner.input
        try await owner.resumeAfterUserControl()
        XCTAssertThrowsError(try owner.configureSourcePolicy(.init(goal: original)))
        _ = try await fixture.resume()
        XCTAssertThrowsError(try owner.configureSourcePolicy(.init(goal: original, allowedOrigins: []))) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .goalChanged)
        }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        planner.questionTopic = .location
        let unanswered = ComputerUseBrowserResearchTask(input: try goal(id: "question"), browser: browser,
            goalPlanner: planner, resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
        let interpretation = try await unanswered.interpretGoal()
        let before = try ComputerUseBrowserSourcePolicy(goal: unanswered.input)
        try unanswered.configureSourcePolicy(before)
        let question = try unanswered.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id], controllerID: "phone", controllerSessionID: "session")
        _ = try unanswered.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Paris", controllerID: "phone", controllerSessionID: "session")
        XCTAssertThrowsError(try unanswered.configureSourcePolicy(before))
        try unanswered.configureSourcePolicy(.init(goal: unanswered.input, allowedOrigins: []))
        XCTAssertFalse(browser.hasSession, "Policy selection alone must not allocate a browser")
        unanswered.retire()
        XCTAssertThrowsError(try unanswered.configureSourcePolicy(.init(goal: unanswered.input)))
    }

    func testSourcePolicyAllowsManualLoginOutsideScopeButOnlyUsesAllowedResultsAfterHandback() async throws {
        let loginScript = "fetch('/finish').then(() => location.href = decodeURIComponent(location.hash.slice(1)));"
        let login = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: "<input type='password'><script>\(loginScript)</script>"), "/finish": .init(held: true)])
        let loginBase = try await login.start()
        let enterScript = "fetch('/enter').then(() => location.href = '\(loginBase.absoluteString)/login#' + encodeURIComponent(location.origin + '/account'));"
        let card = "<article><h2>Concert Alpha</h2><a href='/offer'>Alpha details</a></article>"
        let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(body: card + "<script>\(enterScript)</script>"),
            "/enter": .init(held: true), "/account": .init(body: card)])
        let base = try await server.start(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { server.stop(); login.stop(); try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { coordinator.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed }, browserNavigationTask: coordinator)
        let policy = DriverPlanningFixture(provider: try .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"))
        policy.allowedOrigins = [try ComputerUseBrowserSourceOrigin(base)]
        let results = BrowserResearchResultFixture(), search = DriverSearchFixture()
        results.selectedLinkLabel = "Alpha details"
        let driver = ComputerUseBrowserResearchDriver(goalPlanner: DriverGoalFixture(), resultPlanner: results, searchPlanner: search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(),
            planning: policy, now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
        _ = try await driver.executeBrowserResearch(taskID: "login-policy", prompt: ResearchDriverFixture.prompt, tools: tools, progress: { _ in })
        let owner = try XCTUnwrap(tools.ownedBrowserResearch(taskID: "login-policy")), original = owner.input
        let beforeLogin = try browser.navigationDispatchHistory(taskID: owner.taskID)
        try await waitUntil { server.count("/enter") == 1 }
        owner.pause(); allowed = false; server.releaseHeldResponses()
        try await waitUntil { login.count("/finish") == 1 && browser.hasPageAwaitingHandback }
        let readings = results.inputs.count
        allowed = true
        do { try await owner.resumeAfterUserControl(); XCTFail("The login page still requires manual control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        do { _ = try await driver.continueBrowserResearch(taskID: owner.executionTaskID, research: owner, tools: tools, progress: { _ in }); XCTFail("No implicit handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        XCTAssertEqual(results.inputs.count, readings)
        allowed = false; login.releaseHeldResponses()
        try await waitUntil { server.count("/account") == 1 && browser.hasPageAwaitingHandback }
        allowed = true; try await owner.resumeAfterUserControl()
        _ = try await driver.continueBrowserResearch(taskID: owner.executionTaskID, research: owner, tools: tools, progress: { _ in })
        XCTAssertEqual(owner.input, original); XCTAssertEqual(search.inputs.count, 1)
        XCTAssertEqual(server.count("/search?q=concerts"), 1); XCTAssertEqual(results.inputs.count, readings + 1)
        let afterLogin = try browser.navigationDispatchHistory(taskID: owner.taskID)
        XCTAssertEqual(afterLogin.attempts, beforeLogin.attempts, "Manual sign-in navigation is not an automated dispatch receipt")
        let loginOrigin = try ComputerUseBrowserSourceOrigin(loginBase)
        let manual = try XCTUnwrap(afterLogin.observations.first {
            $0.phase == .navigationAction && $0.origin == loginOrigin && $0.decision == .allowed
        })
        XCTAssertEqual(manual.control, .userControl); XCTAssertEqual(manual.policyCheck, .notChecked)
        XCTAssertNil(manual.attemptID)
        XCTAssertNotNil(manual.configuredPolicy, "A configured task policy is not automatically applied to a human's login")
    }

    func testSourcePolicyBlocksScriptedHistoryToAnEarlierOutsidePage() async throws {
        let earlier = try OwnedBrowserHTTPFixture(), outside = try await earlier.start()
        let script = "fetch('/signal').then(() => history.back());"
        let current = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<h1>Allowed page</h1><script>\(script)</script>"), "/signal": .init(held: true)])
        let base = try await current.start()
        defer { current.stop(); earlier.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "earlier", to: outside)
        let document = try await browser.navigate(taskID: input.taskID, operationID: "current", to: base.appendingPathComponent("page"))
        try browser.installSourcePolicy(.init(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)]), replacing: nil, session: session)
        try await waitUntil { current.count("/signal") == 1 }
        current.releaseHeldResponses()
        try await waitUntil { browser.detail == "Blocked a page outside this task's allowed sources." }
        if let retained = browser.currentDocument(taskID: input.taskID) {
            try browser.validateSourceDocument(retained)
            XCTAssertEqual(retained.committedURL, document.committedURL)
        }
        XCTAssertEqual(earlier.requestCount, 1)
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        let outsideOrigin = try ComputerUseBrowserSourceOrigin(outside)
        XCTAssertTrue(history.observations.contains {
            [.historyRequest, .navigationAction].contains($0.phase) && $0.origin == outsideOrigin
                && $0.decision == .cancelled && $0.policyCheck == .blocked && $0.attemptID == nil
        })
    }

    private func goal(id: String = "source-policy") throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: id, prompt: ResearchDriverFixture.prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
    }
    private func url(_ raw: String) throws -> URL { try XCTUnwrap(URL(string: raw)) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw FixtureFailure.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private enum FixtureFailure: Error { case timeout }
}
