import AppKit
import Combine
import Network
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseOwnedBrowserTests: XCTestCase {
    func testParentCloseStatusCannotReleaseAReplacementSession() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let original = try browser.prepareWorkflowSession(taskID: "original")
        var replaced = false
        var replacement: ComputerUseBrowserHandbackRequirement?
        let subscription = browser.$detail.sink { status in
            guard status == "Stopped", !replaced else { return }
            replaced = true
            do { replacement = try browser.prepareWorkflowSession(taskID: "replacement") }
            catch { XCTFail("Native cleanup must finish before final status can admit a replacement: \(error)") }
        }
        defer { subscription.cancel() }
        browser.close()
        let current = try XCTUnwrap(replacement)
        XCTAssertNotEqual(current.sessionID, original.sessionID)
        XCTAssertEqual(browser.handbackRequirement(taskID: "replacement", required: true), current)
        XCTAssertTrue(try browser.isUnnavigatedSession(current))
        let next = try await browser.navigate(taskID: "replacement", operationID: "next", to: base.appendingPathComponent("next"))
        XCTAssertTrue(browser.validate(next))
        XCTAssertEqual(server.count("/next"), 1)
    }

    func testParentRetirementCannotOfferHandbackOrEraseReplacementFromChildPublication() async throws {
        for close in [false, true] {
            for replace in [false, true] {
                let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: "<script>fetch('/signal').then(() => window.open('/provider'));</script>"),
                    "/signal": .init(held: true), "/provider": .init(body: "<script>fetch('/ready');</script>")])
                let base = try await server.start()
                defer { server.stop() }
                var allowed = true, observedRetirement = false, details: [String] = []
                let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
                defer { browser.close() }
                _ = try browser.prepareWorkflowSession(taskID: "parent")
                _ = try await browser.navigate(taskID: "parent", operationID: "login", to: base.appendingPathComponent("login"))
                try await waitUntil { server.count("/signal") == 1 }
                allowed = false
                browser.updateTaskControls(.init(taskID: "parent", scopeID: UUID(), presentationID: UUID(), phase: .paused, canResume: true), handler: { _, _ in })
                server.releaseHeldResponses()
                try await waitUntil { browser.hasOpenSignInWindow && server.count("/ready") == 1 }
                var replacement: ComputerUseBrowserHandbackRequirement?
                let detailSubscription = browser.$detail.sink { details.append($0) }
                let subscription = browser.$signInSite.dropFirst().sink { site in
                    guard site == nil, !observedRetirement else { return }
                    observedRetirement = true
                    XCTAssertNil(browser.taskID, "Parent authority must retire before child-clear publication")
                    XCTAssertFalse(browser.hasOpenSignInWindow)
                    if replace {
                        allowed = true
                        do { replacement = try browser.prepareWorkflowSession(taskID: "replacement") }
                        catch { XCTFail("Replacement admission follows native cleanup: \(error)") }
                    }
                }
                defer { subscription.cancel(); detailSubscription.cancel() }
                if close { browser.close() } else { browser.stop() }
                XCTAssertTrue(observedRetirement)
                XCTAssertFalse(details.contains { $0.hasPrefix("Sign-in window closed") }, "A cancelled parent must not offer child handback")
                allowed = true
                if replace {
                    XCTAssertEqual(browser.handbackRequirement(taskID: "replacement", required: true), try XCTUnwrap(replacement))
                    XCTAssertEqual(browser.taskID, "replacement")
                } else {
                    XCTAssertNil(browser.taskID)
                    XCTAssertEqual(browser.hasSession, !close)
                    XCTAssertEqual(browser.detail, "Stopped")
                    _ = try browser.prepareWorkflowSession(taskID: "replacement")
                }
                let next = try await browser.navigate(taskID: "replacement", operationID: "next", to: base.appendingPathComponent("next"))
                XCTAssertTrue(browser.validate(next))
                XCTAssertEqual(server.count("/login"), 1); XCTAssertEqual(server.count("/provider"), 1); XCTAssertEqual(server.count("/next"), 1)
            }
        }
    }

    func testParentStopKeepsDispatchedDOMOccupiedUntilCallbackOrClose() async throws {
        for close in [false, true] {
            let server = try OwnedBrowserHTTPFixture()
            let base = try await server.start()
            defer { server.stop() }
            var stopped = false
            weak var owner: ComputerUseOwnedBrowser?
            var replacement: ComputerUseBrowserHandbackRequirement?
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
                guard command == .pageSnapshot, !stopped, let owner else { return }
                stopped = true
                owner.stop()
                XCTAssertThrowsError(try owner.claim(taskID: "replacement")) {
                    XCTAssertEqual($0 as? ComputerUseBrowserError, .busy, "Stop cannot release an unfinished native DOM slot")
                }
                if close {
                    owner.close()
                    do { replacement = try owner.prepareWorkflowSession(taskID: "replacement") }
                    catch { XCTFail("Close must release only the old browser's slot: \(error)") }
                }
            }, mayAct: { true })
            owner = browser
            defer { browser.close() }
            let original = try browser.prepareWorkflowSession(taskID: "original")
            let document = try await browser.navigate(taskID: "original", operationID: "page", to: base.appendingPathComponent("page"))
            do { _ = try await browser.observePage(document: document); XCTFail("Stopped DOM work cannot return a current result") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            XCTAssertTrue(stopped)
            await browser.joinDOMCompletion(document: document)
            if !close { replacement = try browser.prepareWorkflowSession(taskID: "replacement") }
            let current = try XCTUnwrap(replacement)
            if close { XCTAssertNotEqual(current.sessionID, original.sessionID) }
            else { XCTAssertEqual(current.sessionID, original.sessionID) }
            XCTAssertEqual(browser.handbackRequirement(taskID: "replacement", required: true), current)
            let next = try await browser.navigate(taskID: "replacement", operationID: "next", to: base.appendingPathComponent("next"))
            XCTAssertTrue(browser.validate(next))
            XCTAssertEqual(server.count("/page"), 1); XCTAssertEqual(server.count("/next"), 1)
        }
    }

    func testSignInCreationPublicationCannotReturnARetiredChild() async throws {
        for publication in ["site", "detail"] {
            for ending in ["child", "owner"] {
                let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: """
                    <script>fetch('/signal').then(() => {
                        const child = window.open('/provider');
                        fetch('/attempted?child=' + (child ? 'yes' : 'no'));
                    });</script>
                    """), "/signal": .init(held: true)])
                let base = try await server.start()
                defer { server.stop() }
                var allowed = true, interrupted = false, lateResets = 0
                let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
                defer { browser.close() }
                _ = try browser.prepareWorkflowSession(taskID: "creation")
                let original = try await browser.navigate(taskID: "creation", operationID: "login", to: base.appendingPathComponent("login"))
                try await waitUntil { server.count("/signal") == 1 }
                let controls = ComputerUseBrowserTaskControls(taskID: "creation", scopeID: UUID(), presentationID: UUID(), phase: .paused, canResume: true)
                allowed = false
                browser.updateTaskControls(controls, handler: { _, _ in })
                let interrupt: () -> Void = {
                    guard !interrupted else { return }
                    interrupted = true
                    if ending == "child" { browser.closeSignInWindow() }
                    else {
                        browser.updateTaskControls(.init(taskID: "creation", scopeID: UUID(), presentationID: UUID(),
                            phase: .paused, canResume: true, ownerID: UUID()), handler: { _, _ in })
                    }
                }
                let detailSubscription = browser.$signInDetail.dropFirst().sink { _ in
                    if interrupted { lateResets += 1 }
                }
                let subscription: AnyCancellable
                if publication == "site" { subscription = browser.$signInSite.dropFirst().sink { if $0 != nil { interrupt() } } }
                else { subscription = browser.$signInDetail.dropFirst().sink { _ in interrupt() } }
                defer { subscription.cancel(); detailSubscription.cancel() }
                server.releaseHeldResponses()
                try await waitUntil { server.count("/attempted?child=no") + server.count("/attempted?child=yes") == 1 }
                XCTAssertTrue(interrupted)
                XCTAssertFalse(browser.hasOpenSignInWindow)
                XCTAssertEqual(server.count("/attempted?child=no"), 1, "Abandoned setup must return no child to WebKit")
                XCTAssertEqual(server.count("/provider"), 0)
                if publication == "site" { XCTAssertEqual(lateResets, 0, "Old setup cannot publish another sign-in status") }
                allowed = true
                XCTAssertEqual(browser.currentDocument(taskID: "creation"), original)
                XCTAssertEqual(server.count("/login"), 1)
            }
        }
    }

    func testSignInClosurePublicationPreservesReplacementParentAndControlOwner() async throws {
        for ending in ["stop", "close", "reclaim", "controls"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: "<script>fetch('/signal').then(() => window.open('/provider'));</script>"),
                "/signal": .init(held: true), "/provider": .init(body: "<script>fetch('/provider-ready');</script>")])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true, interrupted = false
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            _ = try browser.prepareWorkflowSession(taskID: "parent")
            _ = try await browser.navigate(taskID: "parent", operationID: "login", to: base.appendingPathComponent("login"))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = false
            browser.updateTaskControls(.init(taskID: "parent", scopeID: UUID(), presentationID: UUID(), phase: .paused, canResume: true), handler: { _, _ in })
            server.releaseHeldResponses()
            try await waitUntil { browser.hasOpenSignInWindow && server.count("/provider-ready") == 1 }
            var expectedDetail: String?
            var replacement: ComputerUseBrowserHandbackRequirement?
            let subscription = browser.$signInSite.dropFirst().sink { site in
                guard site == nil, !interrupted else { return }
                interrupted = true; allowed = true
                if ending == "close" { browser.close() }
                else if ending != "controls" { browser.stop() }
                if ending == "reclaim" {
                    do { replacement = try browser.prepareWorkflowSession(taskID: "replacement") }
                    catch { XCTFail("Cannot retain replacement parent: \(error)") }
                } else if ending == "controls" {
                    browser.updateTaskControls(.init(taskID: "parent", scopeID: UUID(), presentationID: UUID(),
                        phase: .paused, canResume: true, ownerID: UUID()), handler: { _, _ in })
                }
                expectedDetail = browser.detail
            }
            defer { subscription.cancel() }
            browser.closeSignInWindow()
            XCTAssertTrue(interrupted)
            XCTAssertFalse(browser.hasOpenSignInWindow)
            XCTAssertEqual(browser.detail, try XCTUnwrap(expectedDetail), "Old closure cannot publish guidance in a replacement parent/control scope")
            if let replacement { XCTAssertEqual(browser.handbackRequirement(taskID: "replacement", required: true), replacement) }
            _ = try browser.prepareWorkflowSession(taskID: "next")
            let next = try await browser.navigate(taskID: "next", operationID: "next", to: base.appendingPathComponent("next"))
            XCTAssertTrue(browser.validate(next))
            XCTAssertEqual(server.count("/login"), 1); XCTAssertEqual(server.count("/provider"), 1); XCTAssertEqual(server.count("/next"), 1)
        }
    }

    func testSignInCreationKeepsSameOwnerDuringEarlyResumePublication() async throws {
        for publication in ["site", "detail"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: "<script>fetch('/signal').then(() => window.open('/provider'));</script>"),
                "/signal": .init(held: true), "/provider": .init(body: "<script>fetch('/provider-ready');</script>")])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true, resumed = false
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            let session = try browser.prepareWorkflowSession(taskID: "early-resume")
            let original = try await browser.navigate(taskID: "early-resume", operationID: "login", to: base.appendingPathComponent("login"))
            try await waitUntil { server.count("/signal") == 1 }
            let ownerID = UUID()
            allowed = false
            browser.updateTaskControls(.init(taskID: "early-resume", scopeID: UUID(), presentationID: UUID(),
                phase: .paused, canResume: true, ownerID: ownerID), handler: { _, _ in })
            let resume: () -> Void = {
                guard !resumed else { return }
                resumed = true; allowed = true
                browser.updateTaskControls(.init(taskID: "early-resume", scopeID: UUID(), presentationID: UUID(),
                    phase: .working, canResume: false, ownerID: ownerID), handler: { _, _ in })
            }
            let subscription: AnyCancellable
            if publication == "site" { subscription = browser.$signInSite.dropFirst().sink { if $0 != nil { resume() } } }
            else { subscription = browser.$signInDetail.dropFirst().sink { _ in resume() } }
            defer { subscription.cancel() }
            server.releaseHeldResponses()
            try await waitUntil { resumed && server.count("/provider-ready") == 1 }
            XCTAssertTrue(browser.hasOpenSignInWindow)
            XCTAssertFalse(browser.hasOwnership(taskID: "early-resume"))
            XCTAssertEqual(browser.handbackRequirement(taskID: "early-resume", required: true), session)
            do { try await browser.reacquireAfterUserControl(taskID: "early-resume", requirement: session); XCTFail("The unfinished child still blocks AI handback") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .signInWindowOpen) }
            browser.closeSignInWindow()
            XCTAssertEqual(browser.currentDocument(taskID: "early-resume"), original)
            XCTAssertEqual(server.count("/login"), 1); XCTAssertEqual(server.count("/provider"), 1)
        }
    }

    func testCompletedNavigationPublicationCannotOverwriteStoppedOrReclaimedStatus() async throws {
        for ending in ["stop", "reclaim", "close"] {
            let server = try OwnedBrowserHTTPFixture()
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            _ = try browser.prepareWorkflowSession(taskID: "completion")
            var interrupted = false, details: [String] = []
            var expectedDetail: String?
            var committed: ComputerUseBrowserDocument?
            var history: ComputerUseBrowserNavigationDispatchHistory?
            let detailSubscription = browser.$detail.sink { details.append($0) }
            let subscription = browser.$displayedSite.dropFirst().sink { _ in
                guard !interrupted, let receipt = browser.receipt(taskID: "completion", operationID: "load") else { return }
                interrupted = true; committed = receipt
                do { history = try browser.navigationDispatchHistory(taskID: "completion") }
                catch { XCTFail("Missing native completion history: \(error)") }
                if ending == "close" { browser.close() } else { browser.stop() }
                if ending == "reclaim" {
                    do { _ = try browser.prepareWorkflowSession(taskID: "completion") }
                    catch { XCTFail("Cannot reclaim stopped context: \(error)") }
                }
                expectedDetail = browser.detail
            }
            defer { subscription.cancel(); detailSubscription.cancel() }
            do {
                _ = try await browser.navigate(taskID: "completion", operationID: "load", to: base.appendingPathComponent("load"))
                XCTFail("The waiting caller must reject a retired current result")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            XCTAssertTrue(interrupted)
            XCTAssertEqual(browser.detail, try XCTUnwrap(expectedDetail))
            XCTAssertFalse(details.contains("Page opened"), "The old callback cannot announce completion in its successor's status")
            XCTAssertEqual(try XCTUnwrap(committed).committedURL, base.appendingPathComponent("load"))
            XCTAssertEqual(history?.attempts.last?.outcome, .documentCommitted)
            XCTAssertEqual(server.count("/load"), 1)
        }
    }

    func testCompletedNavigationPublicationTakeoverKeepsReceiptWithoutCurrentStatus() async throws {
        for reopen in [false, true] {
            let server = try OwnedBrowserHTTPFixture()
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true, interrupted = false, details: [String] = []
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            let session = try browser.prepareWorkflowSession(taskID: "takeover")
            let detailSubscription = browser.$detail.sink { details.append($0) }
            let subscription = browser.$displayedSite.dropFirst().sink { _ in
                guard !interrupted, browser.receipt(taskID: "takeover", operationID: "load") != nil else { return }
                interrupted = true; allowed = false
                browser.prepareForUserControl(taskID: "takeover")
                allowed = reopen
            }
            defer { subscription.cancel(); detailSubscription.cancel() }
            do {
                _ = try await browser.navigate(taskID: "takeover", operationID: "load", to: base.appendingPathComponent("load"))
                XCTFail("A completed load cannot return as current across a publication-time takeover")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            XCTAssertTrue(interrupted)
            XCTAssertFalse(details.contains("Page opened"))
            allowed = true
            XCTAssertEqual(browser.handbackRequirement(taskID: "takeover", required: true), session)
            XCTAssertEqual(try XCTUnwrap(browser.receipt(taskID: "takeover", operationID: "load")).committedURL, base.appendingPathComponent("load"))
            XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "takeover").attempts.last?.outcome, .documentCommitted)
            XCTAssertEqual(server.count("/load"), 1)
        }
    }

    func testObservedPageCompletionCannotPublishReadinessAfterReentrantStop() async throws {
        for ending in ["stop", "close"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/start": .init(body: """
                <title>Manual navigation fixture</title><p>Continue manually</p>
                <script>fetch('/continue').then(() => { location.href = '/login'; });</script>
                """), "/continue": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true, interrupted = false, details: [String] = []
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            _ = try browser.prepareWorkflowSession(taskID: "observed")
            _ = try await browser.navigate(taskID: "observed", operationID: "start", to: base.appendingPathComponent("start"))
            try await waitUntil { server.count("/continue") == 1 }
            let detailSubscription = browser.$detail.sink { details.append($0) }
            let subscription = browser.$displayedSite.dropFirst().sink { _ in
                guard !interrupted else { return }
                // Locate the delegate's accepted-page publication without
                // assuming when WebKit updates its separate isLoading flag.
                allowed = true
                let accepted = try? browser.navigationDispatchHistory(taskID: "observed").pageObservationEvents.last
                allowed = false
                guard accepted?.phase == .accepted,
                      accepted?.observation.source == .userControlObservation else { return }
                interrupted = true
                if ending == "stop" { browser.stop() } else { browser.close() }
            }
            defer { subscription.cancel(); detailSubscription.cancel() }
            allowed = false
            browser.prepareForUserControl(taskID: "observed")
            server.releaseHeldResponses()
            try await waitUntil { interrupted }
            XCTAssertEqual(browser.detail, "Stopped")
            XCTAssertFalse(details.contains { $0.hasPrefix("Page ready") })
            XCTAssertFalse(browser.hasPageAwaitingHandback)
            XCTAssertNil(browser.taskID)
            XCTAssertEqual(server.count("/start"), 1); XCTAssertEqual(server.count("/login"), 1)
        }
    }

    func testNavigationPublicationTakeoverRetiresReservationBeforeNativeDispatch() async throws {
        for publication in ["site", "detail"] {
            for control in ["paused", "reopened", "gate-only"] {
                let server = try OwnedBrowserHTTPFixture()
                let base = try await server.start()
                defer { server.stop() }
                var allowed = true, interrupted = false, details: [String] = []
                let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
                defer { browser.close() }
                let session = try browser.prepareWorkflowSession(taskID: "publication")
                let detailSubscription = browser.$detail.sink { details.append($0) }
                let subscription = observeNavigationPublication(publication, browser: browser) {
                    guard !interrupted else { return }
                    interrupted = true; allowed = false
                    if control != "gate-only" {
                        browser.prepareForUserControl(taskID: "publication")
                        // Inspect in the callback, before the old caller can
                        // proceed or its asynchronous cleanup can run.
                        allowed = true
                        do {
                            let history = try browser.navigationDispatchHistory(taskID: "publication")
                            XCTAssertEqual(history.attempts.last?.outcome, .ownershipLost)
                        } catch { XCTFail("Missing retired reservation: \(error)") }
                        allowed = control == "reopened"
                    }
                }
                defer { subscription.cancel(); detailSubscription.cancel() }
                do {
                    _ = try await browser.navigate(taskID: "publication", operationID: "old", to: base.appendingPathComponent("old"))
                    XCTFail("A status callback cannot allow the old preparation to dispatch")
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
                XCTAssertTrue(interrupted)
                allowed = true
                XCTAssertEqual(browser.handbackRequirement(taskID: "publication", required: true), session)
                XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "publication").attempts.last?.outcome, .ownershipLost)
                XCTAssertNil(browser.receipt(taskID: "publication", operationID: "old"))
                if publication == "site" { XCTAssertFalse(details.contains("Opening page…")) }
                let next = try await browser.navigate(taskID: "publication", operationID: "next", to: base.appendingPathComponent("next"))
                XCTAssertTrue(browser.validate(next))
                XCTAssertEqual(server.count("/old"), 0); XCTAssertEqual(server.count("/next"), 1)
            }
        }
    }

    func testNavigationPublicationReplacementCannotBeOverwrittenByOldUnwind() async throws {
        for publication in ["site", "detail"] {
            for ending in ["stop", "close"] {
                let server = try OwnedBrowserHTTPFixture()
                let base = try await server.start()
                defer { server.stop() }
                let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
                defer { browser.close() }
                let original = try browser.prepareWorkflowSession(taskID: "same-task")
                var interrupted = false
                var replacement: ComputerUseBrowserHandbackRequirement?
                var replacementHistory: ComputerUseBrowserNavigationDispatchHistory?
                let subscription = observeNavigationPublication(publication, browser: browser) {
                    guard !interrupted else { return }
                    interrupted = true
                    if ending == "stop" { browser.stop() } else { browser.close() }
                    do {
                        replacement = try browser.prepareWorkflowSession(taskID: "same-task")
                        replacementHistory = try browser.navigationDispatchHistory(taskID: "same-task")
                    } catch { XCTFail("Cannot prepare replacement: \(error)") }
                }
                defer { subscription.cancel() }
                do {
                    _ = try await browser.navigate(taskID: "same-task", operationID: "old", to: base.appendingPathComponent("old"))
                    XCTFail("The old call cannot dispatch into a replacement with the same task ID")
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
                let current = try XCTUnwrap(replacement)
                XCTAssertNotEqual(current, original)
                XCTAssertEqual(browser.handbackRequirement(taskID: "same-task", required: true), current)
                XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "same-task"), try XCTUnwrap(replacementHistory))
                XCTAssertNil(browser.receipt(taskID: "same-task", operationID: "old"))
                let next = try await browser.navigate(taskID: "same-task", operationID: "next", to: base.appendingPathComponent("next"))
                XCTAssertTrue(browser.validate(next))
                XCTAssertEqual(server.count("/old"), 0); XCTAssertEqual(server.count("/next"), 1)
            }
        }
    }

    func testNavigationPreparationRejectsTakeoverEvenWhenAdmissionReopens() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true, callbacks = 0
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        let session = try browser.prepareWorkflowSession(taskID: "preparation")
        do {
            _ = try await browser.navigate(taskID: "preparation", operationID: "old", to: base.appendingPathComponent("old"), willBeginEffect: {
                callbacks += 1; allowed = false
                browser.prepareForUserControl(taskID: "preparation")
                allowed = true
            })
            XCTFail("A reopened gate cannot revive the preparation preceding Take Control")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(browser.handbackRequirement(taskID: "preparation", required: true), session)
        XCTAssertTrue(try browser.isUnnavigatedSession(session))
        XCTAssertTrue(try browser.navigationDispatchHistory(taskID: "preparation").attempts.isEmpty)
        let next = try await browser.navigate(taskID: "preparation", operationID: "next", to: base.appendingPathComponent("next"))
        XCTAssertTrue(browser.validate(next))
        XCTAssertEqual(server.count("/old"), 0); XCTAssertEqual(server.count("/next"), 1)
    }

    func testNavigationPreparationRejectsSameTaskClaimAndBrowserReplacement() async throws {
        for ending in ["stop", "close"] {
            let server = try OwnedBrowserHTTPFixture()
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let original = try browser.prepareWorkflowSession(taskID: "same-task")
            var replacement: ComputerUseBrowserHandbackRequirement?
            do {
                _ = try await browser.navigate(taskID: "same-task", operationID: "old", to: base.appendingPathComponent("old"), willBeginEffect: {
                    if ending == "stop" { browser.stop() } else { browser.close() }
                    replacement = try browser.prepareWorkflowSession(taskID: "same-task")
                })
                XCTFail("An unbound first-page call still needs its original owner and browser")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            let current = try XCTUnwrap(replacement)
            XCTAssertNotEqual(current, original)
            XCTAssertTrue(try browser.isUnnavigatedSession(current))
            XCTAssertTrue(try browser.navigationDispatchHistory(taskID: "same-task").attempts.isEmpty)
            let next = try await browser.navigate(taskID: "same-task", operationID: "next", to: base.appendingPathComponent("next"))
            XCTAssertTrue(browser.validate(next))
            XCTAssertEqual(server.count("/old"), 0); XCTAssertEqual(server.count("/next"), 1)
        }
    }

    func testNavigationPublicationCancellationStopsBeforeOpeningStatusAndLoad() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        _ = try browser.prepareWorkflowSession(taskID: "cancelled")
        var cancelled = false, details: [String] = []
        let detailSubscription = browser.$detail.sink { details.append($0) }
        let subscription = observeNavigationPublication("site", browser: browser) {
            guard !cancelled else { return }
            cancelled = true
            withUnsafeCurrentTask { task in
                XCTAssertNotNil(task)
                task?.cancel()
            }
        }
        defer { subscription.cancel(); detailSubscription.cancel() }
        let running = Task { try await browser.navigate(taskID: "cancelled", operationID: "old", to: base.appendingPathComponent("old")) }
        do { _ = try await running.value; XCTFail("Cancelled preparation cannot continue into WebKit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(cancelled); XCTAssertTrue(running.isCancelled)
        XCTAssertFalse(details.contains("Opening page…"))
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "cancelled").attempts.last?.outcome, .ownershipLost)
        let next = try await browser.navigate(taskID: "cancelled", operationID: "next", to: base.appendingPathComponent("next"))
        XCTAssertTrue(browser.validate(next))
        XCTAssertEqual(server.count("/old"), 0); XCTAssertEqual(server.count("/next"), 1)
    }

    func testFinishedNavigationCannotReturnAcrossTakeoverDuringIdentityRead() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true, interrupted = false
        weak var owner: ComputerUseOwnedBrowser?
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
            guard command == .pageIdentity, !interrupted else { return }
            interrupted = true; allowed = false
            owner?.prepareForUserControl(taskID: "identity")
            allowed = true
        }, mayAct: { allowed })
        owner = browser
        defer { browser.close() }
        _ = try browser.prepareWorkflowSession(taskID: "identity")
        do {
            _ = try await browser.navigate(taskID: "identity", operationID: "completed", to: base.appendingPathComponent("completed"))
            XCTFail("Takeover cannot be swallowed as an optional DOM identity failure")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        XCTAssertTrue(interrupted)
        let historical = try XCTUnwrap(browser.receipt(taskID: "identity", operationID: "completed"))
        XCTAssertEqual(historical.committedURL, base.appendingPathComponent("completed"))
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "identity").attempts.last?.outcome, .documentCommitted)
        try await browser.waitForDOMCompletion(document: historical)
        XCTAssertEqual(server.count("/completed"), 1, "Losing the current result cannot erase a native fact or authorize retry")
    }

    private func observeNavigationPublication(_ publication: String, browser: ComputerUseOwnedBrowser,
                                               action: @escaping () -> Void) -> AnyCancellable {
        if publication == "site" { return browser.$displayedSite.dropFirst().sink { _ in action() } }
        return browser.$detail.dropFirst().sink { if $0 == "Opening page…" { action() } }
    }

    func testHostTakeoverRetiresPendingNavigationBeforeCancellationUnwinds() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/old": .init(held: true), "/next": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser(); try? FileManager.default.removeItem(at: directory) }
        let session = try browser.prepareWorkflowSession(taskID: "takeover")
        let old = Task { try await browser.navigate(taskID: "takeover", operationID: "old", to: base.appendingPathComponent("old")) }
        try await waitUntil { server.count("/old") == 1 }
        old.cancel() // Queues the navigation's existing asynchronous cleanup.
        allowed = false
        tools.pauseOwnedBrowserForUserControl(taskID: "takeover")
        // Inspect immediately, without yielding to that cancellation handler.
        allowed = true
        let retired = try browser.navigationDispatchHistory(taskID: "takeover")
        XCTAssertEqual(retired.attempts.last?.outcome, .ownershipLost)
        XCTAssertEqual(browser.handbackRequirement(taskID: "takeover", required: true), session)
        XCTAssertNil(browser.receipt(taskID: "takeover", operationID: "old"))
        let next = Task { try await browser.navigate(taskID: "takeover", operationID: "next", to: base.appendingPathComponent("next")) }
        try await waitUntil { server.count("/next") == 1 }
        server.releaseHeldResponses() // Includes any remaining old response.
        let current = try await next.value
        do { _ = try await old.value; XCTFail("The retired request cannot return a current page") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(browser.validate(current))
        XCTAssertEqual(current.committedURL, base.appendingPathComponent("next"))
        XCTAssertEqual(server.count("/old"), 1); XCTAssertEqual(server.count("/next"), 1)
        XCTAssertNil(browser.receipt(taskID: "takeover", operationID: "old"))
    }

    func testHostTakeoverRetiresURLLoadWithAnUnrelatedRetainedResearchOwner() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser(); try? FileManager.default.removeItem(at: directory) }
        let retained = try tools.prepareOwnedBrowserResearch(taskID: "old-research", prompt: "Find concert tickets.",
            goalPlanner: BrowserResearchGoalFixture(), resultPlanner: BrowserResearchResultFixture())
        tools.retireOwnedBrowserResearch(taskID: "old-research")
        _ = try browser.prepareWorkflowSession(taskID: "new-url-task")
        let load = Task { try await browser.navigate(taskID: "new-url-task", operationID: "held", to: base.appendingPathComponent("held")) }
        try await waitUntil { server.count("/held") == 1 }
        allowed = false
        tools.pauseOwnedBrowserForUserControl(taskID: "new-url-task")
        allowed = true
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "new-url-task").attempts.last?.outcome, .ownershipLost)
        do { _ = try await load.value; XCTFail("An unrelated retained research owner cannot prevent native takeover") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        XCTAssertTrue(tools.ownedBrowserResearch(taskID: "old-research") === retained)
        XCTAssertNil(browser.receipt(taskID: "new-url-task", operationID: "held"))
        XCTAssertEqual(server.count("/held"), 1)
    }

    func testRepeatedTakeoverPreservesObservedUserNavigationAndHandback() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/start": .init(body: """
            <!doctype html><title>Handoff fixture</title><p>Continue manually</p>
            <script>fetch('/continue').then(() => { location.href = '/login'; });</script>
            """), "/continue": .init(held: true), "/login": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        let session = try browser.prepareWorkflowSession(taskID: "manual-navigation")
        _ = try await browser.navigate(taskID: "manual-navigation", operationID: "start", to: base.appendingPathComponent("start"))
        try await waitUntil { server.count("/continue") == 1 }
        allowed = false
        browser.prepareForUserControl(taskID: "manual-navigation")
        server.releaseHeldResponses()
        try await waitUntil { server.count("/login") == 1 }
        XCTAssertTrue(browser.isLoadingPage)
        browser.prepareForUserControl(taskID: "manual-navigation")
        browser.prepareForUserControl(taskID: "manual-navigation")
        XCTAssertTrue(browser.isLoadingPage, "Repeated takeover cannot stop an observed user-time navigation")
        server.releaseHeldResponses()
        try await waitUntil { browser.hasPageAwaitingHandback }
        allowed = true
        try await browser.reacquireAfterUserControl(taskID: "manual-navigation", requirement: session)
        let current = try XCTUnwrap(browser.currentDocument(taskID: "manual-navigation"))
        XCTAssertEqual(current.source, .userControlObservation)
        XCTAssertEqual(current.committedURL, base.appendingPathComponent("login"))
        XCTAssertNil(browser.receipt(taskID: "manual-navigation", operationID: current.operationID))
        XCTAssertEqual(server.count("/start"), 1); XCTAssertEqual(server.count("/login"), 1)
    }

    func testTakeoverPreparationRejectsForeignOwnersAndOpenAdmission() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        _ = try browser.prepareWorkflowSession(taskID: "current")
        let load = Task { try await browser.navigate(taskID: "current", operationID: "held", to: base.appendingPathComponent("held")) }
        try await waitUntil { server.count("/held") == 1 }
        allowed = false
        browser.prepareForUserControl(taskID: "foreign")
        allowed = true
        browser.prepareForUserControl(taskID: "current")
        XCTAssertTrue(browser.isLoadingPage)
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "current").attempts.last?.outcome, .pending)
        server.releaseHeldResponses()
        let current = try await load.value
        XCTAssertTrue(browser.validate(current))
        XCTAssertEqual(server.count("/held"), 1)
    }

    func testTakeoverWithdrawsDOMReplyWhileJoiningItsNativeCallback() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true, withdrew = false
        weak var owner: ComputerUseOwnedBrowser?
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
            guard command == .pageSnapshot, !withdrew else { return }
            withdrew = true; allowed = false
            owner?.prepareForUserControl(taskID: "dom-takeover")
            allowed = true // A reopened gate cannot resurrect the withdrawn reply.
        }, mayAct: { allowed })
        owner = browser
        defer { browser.close() }
        _ = try browser.prepareWorkflowSession(taskID: "dom-takeover")
        let document = try await browser.navigate(taskID: "dom-takeover", operationID: "page", to: base)
        do { _ = try await browser.observePage(document: document); XCTFail("A withdrawn native reply cannot reach the task") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        XCTAssertTrue(withdrew)
        try await browser.waitForDOMCompletion(document: document)
        let fresh = try await browser.observePage(document: document)
        try await browser.validatePageEvidence(fresh)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testUnnavigatedSessionHandbackRetainsIdentityWithoutPageOrReceipt() async throws {
        var allowed = true, commands: [ComputerUseBrowserDOMCommand] = []
        let browser = ComputerUseOwnedBrowser(presentsWindow: false,
            domScriptDidDispatch: { commands.append($0) }, mayAct: { allowed })
        defer { browser.close() }
        let missing = try XCTUnwrap(browser.handbackRequirement(taskID: "root", required: true))
        let session = try browser.prepareWorkflowSession(taskID: "root")
        XCTAssertTrue(try browser.isUnnavigatedSession(session))
        XCTAssertThrowsError(try browser.isUnnavigatedSession(missing))
        allowed = false
        XCTAssertThrowsError(try browser.isUnnavigatedSession(session)) {
            XCTAssertEqual($0 as? ComputerUseBrowserError, .ownershipLost)
        }
        do { try await browser.reacquireAfterUserControl(taskID: "root", requirement: session); XCTFail("Handback needs the action gate") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        allowed = true
        for _ in 0..<2 {
            try await browser.reacquireAfterUserControl(taskID: "root", requirement: session)
            XCTAssertEqual(browser.handbackRequirement(taskID: "root", required: true), session)
            XCTAssertTrue(try browser.isUnnavigatedSession(session))
            XCTAssertNil(browser.currentDocument(taskID: "root"))
            XCTAssertNil(browser.receipt(taskID: "root", operationID: "first"))
        }
        do { _ = try await browser.acquireObservedDocument(taskID: "root"); XCTFail("Empty handback is not page evidence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertTrue(commands.isEmpty, "Handback must not read an invented document")
        let history = try browser.navigationDispatchHistory(taskID: "root")
        XCTAssertEqual(history.controlEvents.map(\.phase), [.nativeReacquisitionStarted, .nativeReacquisitionFailed,
            .nativeReacquisitionStarted, .nativeReacquisitionFinished, .nativeReacquisitionStarted, .nativeReacquisitionFinished])
        XCTAssertTrue(history.controlEvents.allSatisfy { $0.handbackBinding == session.sessionBindingDigest && $0.workflowOperationID == nil })
        for index in stride(from: 0, to: 6, by: 2) {
            XCTAssertNotNil(history.controlEvents[index].nativeOperationID)
            XCTAssertEqual(history.controlEvents[index].nativeOperationID, history.controlEvents[index + 1].nativeOperationID)
        }
        XCTAssertEqual(Set(history.controlEvents.compactMap(\.nativeOperationID)).count, 3)
    }

    func testUnnavigatedSessionCannotSurviveOwnershipOrBrowserReplacement() async throws {
        for ending in ["stop", "close", "other-owner"] {
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let missing = try XCTUnwrap(browser.handbackRequirement(taskID: "root", required: true))
            let old = try browser.prepareWorkflowSession(taskID: "root")
            if ending == "stop" { browser.stop() }
            else if ending == "close" { browser.close() }
            else { try browser.claim(taskID: "other") }
            let fresh = try browser.prepareWorkflowSession(taskID: "root")
            XCTAssertNotEqual(fresh, old)
            for stale in [old, missing] {
                XCTAssertThrowsError(try browser.isUnnavigatedSession(stale)) {
                    XCTAssertEqual($0 as? ComputerUseBrowserError, .handbackContextLost)
                }
                do { try await browser.reacquireAfterUserControl(taskID: "root", requirement: stale); XCTFail("Blankness cannot replace session identity") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
            }
            XCTAssertTrue(try browser.isUnnavigatedSession(fresh))
            try await browser.reacquireAfterUserControl(taskID: "root", requirement: fresh)
            XCTAssertNil(browser.currentDocument(taskID: "root"))
        }
    }

    func testFailedAndCancelledFirstLoadsNeverBecomeUnnavigatedSessions() async throws {
        for cancelled in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/first": .init(status: cancelled ? 200 : 503, held: cancelled)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let session = try browser.prepareWorkflowSession(taskID: "root")
            XCTAssertTrue(try browser.isUnnavigatedSession(session))
            let load = Task { try await browser.navigate(taskID: "root", operationID: "first", to: base.appendingPathComponent("first")) }
            try await waitUntil { server.count("/first") == 1 }
            if cancelled { load.cancel() }
            do { _ = try await load.value; XCTFail("An interrupted or failed page must not succeed") }
            catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
            }
            try await waitUntil { !browser.isLoadingPage }
            XCTAssertFalse(try browser.isUnnavigatedSession(session))
            XCTAssertNil(browser.currentDocument(taskID: "root"))
            XCTAssertNil(browser.receipt(taskID: "root", operationID: "first"))
            do { try await browser.reacquireAfterUserControl(taskID: "root", requirement: session); XCTFail("A failed load is not a first-page handback") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(server.count("/first"), 1, "Handback cannot retry navigation")
        }
    }

    func testUnnavigatedHandbackDoesNotReauthorizeJournaledNavigationAttempt() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true, dispatches = 0
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let session = try browser.prepareWorkflowSession(taskID: "root")
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory,
            beforeNavigationDispatch: { _ in dispatches += 1; allowed = false })
        defer { navigation.close() }
        let prompt = "Open \(base.appendingPathComponent("first").absoluteString)"
        do { _ = try await navigation.execute(taskID: "root", prompt: prompt, progress: { _ in }); XCTFail("The gate closes after the durable attempt") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        let store = try ComputerUseTaskJournalStore(directory: directory)
        let attempted = try XCTUnwrap(store.load(taskID: "root"))
        XCTAssertEqual(attempted.statuses, [.uncertain])
        allowed = true
        XCTAssertTrue(try browser.isUnnavigatedSession(session), "No native request started, but the journal still owns the uncertain attempt")
        try await browser.reacquireAfterUserControl(taskID: "root", requirement: session)
        for _ in 0..<2 {
            let result = try await navigation.execute(taskID: "root", prompt: prompt, progress: { _ in })
            guard case .userInterventionRequired = result else { return XCTFail("An uncertain action must reconcile, not redispatch") }
        }
        let retained = try XCTUnwrap(store.load(taskID: "root"))
        XCTAssertEqual(retained.stepIDs, attempted.stepIDs)
        XCTAssertEqual(retained.statuses, [.uncertain])
        XCTAssertEqual(dispatches, 1); XCTAssertEqual(server.requestCount, 0)
        XCTAssertTrue(try browser.isUnnavigatedSession(session))
        XCTAssertNil(browser.currentDocument(taskID: "root"))
    }

    func testUsedSessionDoesNotBecomeUnnavigatedWhenClaimClearsEvidence() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let original = try browser.prepareWorkflowSession(taskID: "root")
        _ = try await browser.navigate(taskID: "root", operationID: "first", to: base.appendingPathComponent("first"))
        browser.stop()
        let reclaimed = try browser.prepareWorkflowSession(taskID: "root")
        XCTAssertNotEqual(reclaimed, original)
        XCTAssertNil(browser.currentDocument(taskID: "root"))
        XCTAssertNil(browser.receipt(taskID: "root", operationID: "first"))
        XCTAssertFalse(try browser.isUnnavigatedSession(reclaimed), "Cleared task evidence cannot erase native session history")
        do { try await browser.reacquireAfterUserControl(taskID: "root", requirement: reclaimed); XCTFail("Claim cannot adopt a used page as blank") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        browser.close()
        let replacement = try browser.prepareWorkflowSession(taskID: "root")
        XCTAssertTrue(try browser.isUnnavigatedSession(replacement))
        XCTAssertThrowsError(try browser.isUnnavigatedSession(reclaimed))
        XCTAssertEqual(server.count("/first"), 1)
    }

    func testBrowserWorkflowRefreshesUnsentDestinationAfterLoginAndKeepsVerifiedQueryValues() async throws {
        for mode in ["link", "query", "changed-query", "failed-link-rebind", "failed-query-rebind"] {
            let isLink = mode == "link" || mode == "failed-link-rebind"
            let loginChange = isLink
                ? "history.replaceState(null, '', '/account'); document.querySelector('a').href = '/results?session=retained';"
                : (mode == "changed-query" ? "document.getElementById('q').value = 'Tokyo';" : "")
            let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
                <a href='/old'>Results</a><div id='login'></div>
                <form method='get' action='/results'><label>Destination<input name='q' id='q' value='old'></label><button>Search</button></form>
                <script>
                document.getElementById('q').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value), { keepalive: true }));
                fetch('/show-login').then(() => {
                    document.getElementById('login').innerHTML = '<label>Password<input type=password></label>';
                    fetch('/login-shown'); return fetch('/finish-login');
                }).then(() => {
                    document.getElementById('login').remove(); \(loginChange) fetch('/logged-in');
                });
                </script>
                """), "/show-login": .init(held: true), "/finish-login": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            let root = "unsent-login-workflow"
            var allowed = true, linkValidations = 0, pausedOnce = false
            var requirement: ComputerUseBrowserHandbackRequirement?
            weak var observedBrowser: ComputerUseOwnedBrowser?
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
                if command == .validatePageLink { linkValidations += 1 }
                let opening = isLink ? command == .validatePageLink && linkValidations == 2 : command == .validateFormQuery
                if opening && !pausedOnce {
                    pausedOnce = true
                    requirement = observedBrowser?.handbackRequirement(taskID: root, required: true)
                    allowed = false
                }
            }, mayAct: { allowed })
            observedBrowser = browser
            defer { browser.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ending = isLink ? "open the link \"Results\"" : "set \"Destination\" to \"Paris\" then open the form query using \"Search\""
            let prompt = "Open \(base.appendingPathComponent("form").absoluteString) then \(ending)"
            let request = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile(prompt))
            var failReplacement = false
            let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory,
                observedNavigationStore: { try .init(directory: $0, afterReplacement: {
                    if failReplacement { failReplacement = false; throw ComputerUseTaskJournalStore.StoreError.unavailable }
                }) })
            let paused = try await navigation.executeWorkflow(taskID: root, request: request, injector: InputInjector(), progress: { _ in })
            guard case .userInterventionRequired = paused else { return XCTFail("Takeover must stop the prepared destination before a request") }
            let parentStore = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Workflows"))
            let parent = try XCTUnwrap(parentStore.load(taskID: root)), operation = try XCTUnwrap(parent.stepIDs.last)
            XCTAssertEqual(parent.statuses, isLink ? [.verified, .attempted] : [.verified, .verified, .attempted])
            let childStore = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Workflows/Stages")
                .appendingPathComponent(operation).appendingPathComponent("Observed Destinations"))
            let journalID = ComputerUseTaskContract.digest(["observed-browser-effect-record-v1", root, operation])
            let unsent = try XCTUnwrap(childStore.load(taskID: journalID))
            XCTAssertEqual(unsent.statuses, [.planned]); XCTAssertEqual(unsent.promptDigest, ComputerUseTextTaskContract.digest(prompt))
            XCTAssertFalse(browser.hasObservedNavigationAttempt(operationID: operation))
            try await waitUntil { server.count("/show-login") == 1 }
            server.releaseHeldResponses()
            try await waitUntil { server.count("/login-shown") == 1 && server.count("/finish-login") == 1 }
            allowed = true
            let handback = try XCTUnwrap(requirement)
            try await browser.reacquireAfterUserControl(taskID: root, requirement: handback)
            do { _ = try await navigation.executeWorkflow(taskID: root, request: request, injector: InputInjector(), progress: { _ in })
                XCTFail("An active login challenge still requires the user") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
            XCTAssertEqual(try childStore.load(taskID: journalID), unsent)
            allowed = false
            server.releaseHeldResponses()
            try await waitUntil { server.count("/logged-in") == 1 }
            allowed = true
            try await browser.reacquireAfterUserControl(taskID: root, requirement: handback)
            if mode.hasPrefix("failed-") {
                failReplacement = true
                do { _ = try await navigation.executeWorkflow(taskID: root, request: request, injector: InputInjector(), progress: { _ in }); XCTFail("A failed replacement must remain pending") }
                catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
                XCTAssertFalse(failReplacement)
                let visible = try XCTUnwrap(childStore.load(taskID: journalID))
                XCTAssertNotEqual(visible.contractDigest, unsent.contractDigest); XCTAssertEqual(visible.statuses, [.planned])
                XCTAssertEqual(visible.stepIDs, unsent.stepIDs); XCTAssertEqual(try parentStore.load(taskID: root), parent)
                XCTAssertFalse(server.requestedPaths.contains { $0.hasPrefix("/results") })
            }
            let resumed = try await navigation.executeWorkflow(taskID: root, request: request, injector: InputInjector(), progress: { _ in })
            if mode == "changed-query" {
                guard case .userInterventionRequired = resumed else { return XCTFail("Rebinding must retain the original verified Paris requirement") }
                XCTAssertEqual(try childStore.load(taskID: journalID), unsent)
                XCTAssertEqual(try parentStore.load(taskID: root), parent)
                XCTAssertFalse(server.requestedPaths.contains { $0.hasPrefix("/results") })
            } else {
                guard case .completed = resumed else { return XCTFail("The unsent stage must continue after explicit handback") }
                let completed = try XCTUnwrap(childStore.load(taskID: journalID))
                XCTAssertEqual(completed.statuses, [.verified]); XCTAssertNotEqual(completed.contractDigest, unsent.contractDigest)
                XCTAssertEqual(completed.promptDigest, unsent.promptDigest); XCTAssertEqual(completed.stepIDs, unsent.stepIDs)
                let finished = try XCTUnwrap(parentStore.load(taskID: root))
                XCTAssertEqual(finished.stepIDs, parent.stepIDs); XCTAssertEqual(finished.contractDigest, parent.contractDigest)
                XCTAssertEqual(finished.statuses, parent.stepIDs.map { _ in .verified })
                XCTAssertEqual(server.count(isLink ? "/results?session=retained" : "/results?q=Paris"), 1)
                _ = try await navigation.executeWorkflow(taskID: root, request: request, injector: InputInjector(), progress: { _ in })
                XCTAssertEqual(server.requestedPaths.filter { $0.hasPrefix("/results") }.count, 1)
            }
            if !isLink {
                try await waitUntil { server.count("/edited?value=Paris") == 1 }
                XCTAssertEqual(server.count("/edited?value=Paris"), 1)
            }
            XCTAssertEqual(server.count("/form"), 1); XCTAssertEqual(server.count("/old"), 0)
        }
    }

    func testBrowserWorkflowCompilerPreservesQuotedConnectorsAndRejectsUncoveredGoals() throws {
        let prompt = "Open https://example.invalid/form then set \"Message\" to \"Now then later, and then 😀\" then append \"!\" to the same field then open the form query using \"Search\""
        let request = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile(prompt))
        XCTAssertEqual(request.prompt, prompt)
        XCTAssertEqual(request.stages.count, 3)
        XCTAssertEqual(request.stages.map(\.kindID), ["navigation", "edits", "form-query"])
        XCTAssertTrue(request.stages[1].source.contains("\"Now then later, and then 😀\""))
        XCTAssertTrue(request.stages[1].source.hasSuffix("append \"!\" to the same field"))
        for tail in [" then find three tickets under $100", " then buy the cheapest ticket", " then click \"Pay\"",
                     " then set \"Other\" to \"unfinished", " then leave all unavailable results out"] {
            XCTAssertNil(try ComputerUseBrowserWorkflowRequest.compile(prompt + tail), "Uncovered requirements cannot be dropped after a recognized prefix")
        }
        XCTAssertNil(try ComputerUseBrowserWorkflowRequest.compile("Open https://example.invalid/one then open https://example.invalid/two"), "Keep the existing complete navigation capability")
        XCTAssertNil(try ComputerUseBrowserWorkflowRequest.compile("Set \"A\" to \"one\" then set \"B\" to \"two\""), "Keep the existing complete form capability")
    }

    func testBrowserWorkflowGivesRepeatedNavigationsDistinctEffectsAndReplaysNoStages() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <label>Destination<input id='destination' value='old'></label><script>
            document.getElementById('destination').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value), { keepalive: true }));
            </script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = "Open \(base.appendingPathComponent("form").absoluteString) then set \"Destination\" to \"Paris\" then open \(base.appendingPathComponent("form").absoluteString) then set \"Destination\" to \"Paris\" then open \(base.appendingPathComponent("form").absoluteString)"
        let request = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile(prompt))
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let first = try await navigation.executeWorkflow(taskID: "repeated-workflow", request: request, injector: InputInjector(), progress: { _ in })
        guard case .completed = first else { return XCTFail("Every requested occurrence must execute") }
        try await waitUntil { server.count("/edited?value=Paris") == 2 }
        XCTAssertEqual(server.count("/form"), 3)
        let store = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Workflows"))
        let saved = try XCTUnwrap(store.load(taskID: "repeated-workflow"))
        XCTAssertEqual(saved.statuses, Array(repeating: .verified, count: 5))
        XCTAssertEqual(Set(saved.stepIDs).count, 5)
        XCTAssertEqual(saved.promptDigest, ComputerUseTextTaskContract.digest(prompt))
        for runner in [navigation, ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)] {
            let replay = try await runner.executeWorkflow(taskID: "repeated-workflow", request: request, injector: InputInjector(), progress: { _ in })
            guard case .completed = replay else { return XCTFail("Verified stages must be recoverable without re-execution") }
        }
        XCTAssertEqual(server.count("/form"), 3)
        XCTAssertEqual(server.count("/edited?value=Paris"), 2)
        XCTAssertEqual(try store.load(taskID: "repeated-workflow"), saved)
    }

    func testBrowserWorkflowKeepsVerifiedFormRequirementsAfterManualChanges() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <form method='get' action='/results'><label>Destination<input name='q' id='q' value='old'></label><button>Search</button></form>
            <script>
            document.getElementById('q').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value), { keepalive: true }));
            fetch('/change').then(() => { document.getElementById('q').value = 'Tokyo'; fetch('/changed'); });
            </script>
            """), "/change": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = "Open \(base.appendingPathComponent("form").absoluteString) then set \"Destination\" to \"Paris\" then open the form query using \"Search\""
        let request = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile(prompt))
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        var requirement: ComputerUseBrowserHandbackRequirement?
        let paused = try await navigation.executeWorkflow(taskID: "changed-workflow", request: request, injector: InputInjector(), progress: { message in
            if message == "Browser step 3 of 3…" {
                requirement = browser.handbackRequirement(taskID: "changed-workflow", required: true)
                allowed = false
            }
        })
        guard case .userInterventionRequired = paused else { return XCTFail("Takeover must retain the unfinished query") }
        try await waitUntil { server.count("/change") == 1 && server.count("/edited?value=Paris") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/changed") == 1 }
        allowed = true
        try await browser.reacquireAfterUserControl(taskID: "changed-workflow", requirement: XCTUnwrap(requirement))
        let resumed = try await navigation.executeWorkflow(taskID: "changed-workflow", request: request, injector: InputInjector(), progress: { _ in })
        guard case .userInterventionRequired = resumed else { return XCTFail("Current values cannot replace the verified intended form values") }
        XCTAssertEqual(server.count("/form"), 1)
        XCTAssertEqual(server.count("/edited?value=Paris"), 1)
        XCTAssertFalse(server.requestedPaths.contains { $0.hasPrefix("/results") })
        let saved = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Workflows")).load(taskID: "changed-workflow"))
        XCTAssertEqual(saved.statuses, [.verified, .verified, .attempted])
    }

    func testBrowserWorkflowCannotReplayUncertainObservedNavigation() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<a href='/held'>Results</a>"), "/held": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile("Open \(base.appendingPathComponent("start").absoluteString) then open the link \"Results\""))
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let running = Task { try await navigation.executeWorkflow(taskID: "uncertain-workflow", request: request, injector: InputInjector(), progress: { _ in }) }
        try await waitUntil { server.count("/held") == 1 }
        running.cancel()
        do { _ = try await running.value; XCTFail("Cancellation cannot report completion") }
        catch { XCTAssertTrue(error is CancellationError) }
        let retry = try await navigation.executeWorkflow(taskID: "uncertain-workflow", request: request, injector: InputInjector(), progress: { _ in })
        guard case .userInterventionRequired = retry else { return XCTFail("An uncertain child effect requires reconciliation") }
        XCTAssertEqual(server.count("/start"), 1)
        XCTAssertEqual(server.count("/held"), 1)
        let saved = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Workflows")).load(taskID: "uncertain-workflow"))
        XCTAssertEqual(saved.statuses, [.verified, .attempted])
    }

    func testBrowserWorkflowRejectsGoalSessionAndStorageChangesBeforeNewEffects() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<a href='/details'>Details</a><a href='/other'>Other</a>"),
            "/details": .init(body: "<p>Details</p>")])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let other = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close(); other.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = "Open \(base.appendingPathComponent("start").absoluteString) then open the link \"Details\""
        let request = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile(prompt))
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let result = try await navigation.executeWorkflow(taskID: "bound-workflow", request: request, injector: InputInjector(), progress: { _ in })
        guard case .completed = result else { return XCTFail("Initial workflow must finish") }
        let changed = try XCTUnwrap(ComputerUseBrowserWorkflowRequest.compile(prompt.replacingOccurrences(of: "\"Details\"", with: "\"Other\"")))
        do {
            _ = try await navigation.executeWorkflow(taskID: "bound-workflow", request: changed, injector: InputInjector(), progress: { _ in })
            XCTFail("The same root task cannot replace its remaining requirements")
        } catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        for replacement in [other, browser] {
            if replacement === browser { browser.close() }
            let runner = ComputerUseBrowserNavigationTask(browser: replacement, journalDirectory: directory)
            do {
                _ = try await runner.executeWorkflow(taskID: "bound-workflow", request: request, injector: InputInjector(), progress: { _ in })
                XCTFail("A lost or replaced browser cannot recreate prior workflow facts")
            } catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .journalMismatch) }
        }
        let blocked = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("not a journal directory".utf8).write(to: blocked.appendingPathComponent("Workflows"))
        let blockedRunner = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: blocked)
        do {
            _ = try await blockedRunner.executeWorkflow(taskID: "blocked-workflow", request: request, injector: InputInjector(), progress: { _ in })
            XCTFail("Storage must be available before the first child receives execution")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(server.count("/start"), 1)
        XCTAssertEqual(server.count("/details"), 1)
        XCTAssertEqual(server.count("/other"), 0)
    }

    func testPageControlsExposeSearchMetadataWithoutEnteredOrSubmissionValues() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <form id='trip' action='/search?private-form=original' method='get'>
              <input type='hidden' name='action' value='private-clobber'><input type='hidden' name='method'><input type='hidden' name='noValidate'>
              <label>Departure<input type='date' min='2026-09-10' max='2026-10-10' required value='2026-09-18' name='private-departure'></label>
              <label>Cabin<select name='private-cabin'><optgroup label='Seating'>
                <option value='private-economy'>Economy</option><option disabled value='private-upgrade'>Upgrade</option>
                <option hidden value='private-hidden'>Hidden choice</option>
              </optgroup></select></label>
              <fieldset disabled><label>Unavailable<input></label></fieldset>
              <button formaction='/alternate?private-form=override' formmethod='post' formtarget='_blank' formenctype='text/plain' formnovalidate>Search<span style='display:none'>private-hidden-caption</span></button>
            </form>
            <label>City<input type='search' form='trip' value='private-city-value' name='private-city'></label>
            <input hidden aria-label='Hidden' value='private-hidden-value'>
            <div role='combobox' tabindex='0'>Custom city</div>
            <script>for (const event of ['input','change','submit']) document.addEventListener(event, () => fetch('/unexpected'));</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "control-metadata")
        let document = try await browser.navigate(taskID: "control-metadata", operationID: "page", to: base.appendingPathComponent("page"))
        let evidence = try await browser.observePage(document: document)
        let controls = evidence.page.controls
        XCTAssertEqual(controls.map(\.label), ["Departure", "Cabin", "Unavailable", "Search", "City"])
        let departure = try XCTUnwrap(controls.first { $0.label == "Departure" })
        let cabin = try XCTUnwrap(controls.first { $0.label == "Cabin" })
        let search = try XCTUnwrap(controls.first { $0.label == "Search" })
        let city = try XCTUnwrap(controls.first { $0.label == "City" })
        XCTAssertEqual(departure.kind, "date")
        XCTAssertEqual(departure.constraints, ["min": "2026-09-10", "max": "2026-10-10"])
        XCTAssertTrue(departure.required)
        XCTAssertEqual(controls.first { $0.label == "Unavailable" }?.disabled, true)
        XCTAssertEqual(cabin.options.map(\.label), ["Economy", "Upgrade", "Hidden choice"])
        XCTAssertEqual(cabin.options.map(\.value), ["private-economy", "private-upgrade", "private-hidden"])
        XCTAssertTrue(try XCTUnwrap(cabin.options.first { $0.label == "Upgrade" }).disabled)
        XCTAssertTrue(try XCTUnwrap(cabin.options.first { $0.label == "Hidden choice" }).hidden)
        XCTAssertEqual(cabin.options.map(\.groupLabel), ["Seating", "Seating", "Seating"])
        XCTAssertEqual(departure.form?.id, city.form?.id, "The form owner can be outside the control's ancestors")
        XCTAssertEqual(search.form?.id, city.form?.id)
        XCTAssertEqual(city.form?.method, "get")
        XCTAssertTrue(city.form?.action.hasSuffix("/search?private-form=original") == true)
        XCTAssertEqual(city.form?.noValidate, false)
        XCTAssertEqual(search.form?.method, "post")
        XCTAssertTrue(search.form?.action.hasSuffix("/alternate?private-form=override") == true)
        XCTAssertEqual(search.form?.target, "_blank")
        XCTAssertEqual(search.form?.encoding, "text/plain")
        XCTAssertEqual(search.form?.noValidate, true)
        XCTAssertTrue(evidence.page.omittedControls, "An unsupported custom widget is not silently complete control coverage")
        XCTAssertTrue(evidence.page.isWellFormed)
        let context = try ComputerUseBrowserPlanningContext(page: evidence.page).serialized()
        XCTAssertTrue(context.contains("\"control_kind\":\"date\""))
        XCTAssertTrue(context.contains("Economy"))
        XCTAssertTrue(context.contains("\"omitted_controls\":true"))
        XCTAssertFalse(context.contains("private-"))
        XCTAssertFalse(context.contains("2026-09-18"))
        XCTAssertFalse(String(reflecting: controls).contains("private-"))
        try await browser.validatePageEvidence(evidence)
        let refreshed = try await browser.observePage(document: document)
        XCTAssertEqual(refreshed.page.controls, controls, "Unchanged DOM objects retain their observation identities")
        XCTAssertEqual(server.count("/unexpected"), 0)
        XCTAssertEqual(server.count("/page"), 1)
    }

    func testPageControlsInvalidateInvisibleFormChangesAndReplacedObjects() async throws {
        for mutation in [
            "document.querySelector('form').action='/changed?private-token=changed';",
            "document.querySelector('button').formAction='/changed-button';",
            "document.querySelector('input').name='different-field';",
            "document.querySelector('input').min='2026-09-12';",
            "document.querySelector('option').value='different-choice';",
            "document.querySelector('optgroup').disabled=true;",
            "document.querySelector('input').replaceWith(document.querySelector('input').cloneNode(true));",
            "document.querySelector('option').replaceWith(document.querySelector('option').cloneNode(true));",
            "document.querySelector('form').replaceWith(document.querySelector('form').cloneNode(true));",
        ] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <form action='/search'><label>Departure<input type='date' min='2026-09-10' name='departure'></label>
                <label>Cabin<select><optgroup label='Seating'><option value='original-choice'>Economy</option></optgroup></select></label>
                <button>Search</button></form>
                <script>fetch('/change').then(() => { \(mutation) fetch('/changed'); });</script>
                """), "/change": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: "changed-control")
            let document = try await browser.navigate(taskID: "changed-control", operationID: "page", to: base.appendingPathComponent("page"))
            try await waitUntil { server.count("/change") == 1 }
            let evidence = try await browser.observePage(document: document)
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == 1 }
            do { try await browser.validatePageEvidence(evidence); XCTFail("Changed control metadata or identity must invalidate retained page evidence") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged, mutation) }
            let fresh = try await browser.observePage(document: document)
            XCTAssertNotEqual(fresh.page.controls, evidence.page.controls, mutation)
            try await browser.validatePageEvidence(fresh)
        }
    }

    func testPageControlsBoundCatalogsAndOmitHiddenOrProtectedWidgets() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <label>Large<select id='large'></select></label><input type='file' aria-label='Upload'>
            <div hidden><input aria-label='Hidden'></div><input type='password' readonly value='private-saved-password'>
            <div id='shadow'></div><script>
            document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML = '<label>Shadow date<input type="date"></label><span style="opacity:0"><input aria-label="Concealed"></span>';
            for (let i=0; i<65; i++) document.querySelector('#large').append(new Option('Option '+i, 'private-option-'+i));
            for (let i=0; i<70; i++) { const input = document.createElement('input'); input.setAttribute('aria-label','Field '+i); document.body.append(input); }
            </script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "bounded-controls")
        let document = try await browser.navigate(taskID: "bounded-controls", operationID: "page", to: base.appendingPathComponent("page"))
        let evidence = try await browser.observePage(document: document)
        XCTAssertEqual(evidence.page.controls.count, 64)
        XCTAssertTrue(evidence.page.controls.contains { $0.label == "Shadow date" && $0.kind == "date" })
        XCTAssertFalse(evidence.page.controls.contains { ["Large", "Upload", "Hidden", "Concealed"].contains($0.label) })
        XCTAssertTrue(evidence.page.truncated)
        XCTAssertTrue(evidence.page.omittedControls)
        XCTAssertTrue(evidence.page.isWellFormed)
        try await browser.validatePageEvidence(evidence)
        let context = try ComputerUseBrowserPlanningContext(page: evidence.page)
        XCTAssertLessThanOrEqual(context.serialized().utf8.count, ComputerUseBrowserPlanningContext.maximumSerializedBytes)
        XCTAssertTrue(context.serialized(maximumRecords: 0).contains("\"omitted_controls\":true"))
        XCTAssertFalse(context.serialized().contains("private-"))
    }

    func testPageEvidenceReadsRenderedTextAndLinksWithoutFormValuesOrEffects() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/results": .init(body: """
            <base href="/tickets/"><style>.hidden { display:none } .contents { display:contents }</style>
            <h1>Concert tickets</h1><div class="contents"><p>Friday, September 18 — $35</p></div>
            <a href="event/42?date=2026-09-18#seats"><span>See seats</span> 🧭</a>
            <a href="javascript:fetch('/unexpected')">Script action</a>
            <a href="https://user:secret@example.test/private">Unsupported destination</a>
            <div class="hidden">hidden-result</div><div aria-hidden="true">aria-hidden-result</div>
            <label>Search<input value="private-query"></label><textarea aria-label="Notes">private-notes</textarea>
            <div contenteditable>private-draft</div><select><option>private-option</option></select>
            <script>const privateScript = 'private-script'; addEventListener('input', () => fetch('/unexpected'));</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "page-read")
        let document = try await browser.navigate(taskID: "page-read", operationID: "results", to: base.appendingPathComponent("results"))
        let evidence = try await browser.observePage(document: document)
        let text = evidence.page.texts.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Concert tickets"))
        XCTAssertTrue(text.contains("Friday, September 18 — $35"))
        XCTAssertFalse(text.contains("private-"))
        XCTAssertFalse(text.contains("hidden-result"))
        XCTAssertEqual(evidence.page.links.map(\.label), ["See seats 🧭"])
        let linkTextIDs = try XCTUnwrap(evidence.page.links.first).textIDs
        let linkTexts = evidence.page.texts.filter { linkTextIDs.contains($0.id) }
        XCTAssertEqual(linkTexts.map(\.text), ["See seats", "🧭"])
        XCTAssertEqual(Set(linkTexts.map(\.containerID)).count, 1)
        XCTAssertEqual(evidence.page.links.first?.destination,
            base.appendingPathComponent("tickets/event/42").absoluteString + "?date=2026-09-18#seats")
        XCTAssertFalse(evidence.page.truncated)
        XCTAssertFalse(evidence.page.omittedEmbeddedContent)
        XCTAssertTrue(evidence.page.isWellFormed)
        try await browser.validatePageEvidence(evidence)
        XCTAssertEqual(server.count("/unexpected"), 0)
        XCTAssertEqual(server.count("/results"), 1)
        XCTAssertFalse(String(reflecting: evidence).contains("date="))
        XCTAssertFalse(String(reflecting: evidence).contains("Concert tickets"))
    }

    func testPageEvidenceRejectsChangedResultsDestinationsRenderingAndDocumentRoots() async throws {
        for mutation in [
            "document.querySelector('p').textContent = 'Sold out';",
            "document.querySelector('a').href = '/different-event';",
            "document.styleSheets[0].insertRule('p { display:none }', 0);",
            "document.documentElement.replaceWith(document.documentElement.cloneNode(true));",
        ] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/results": .init(body: """
                <style></style><p>Available for $35</p><a href="/event">Event</a>
                <script>fetch('/change').then(() => { \(mutation) fetch('/changed'); });</script>
                """), "/change": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: "changed-results")
            let document = try await browser.navigate(taskID: "changed-results", operationID: "results", to: base.appendingPathComponent("results"))
            try await waitUntil { server.count("/change") == 1 }
            let evidence = try await browser.observePage(document: document)
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == 1 }
            do {
                try await browser.validatePageEvidence(evidence)
                XCTFail("Old page evidence cannot survive a changed projection or document root")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged, mutation) }
            let fresh = try await browser.observePage(document: document)
            try await browser.validatePageEvidence(fresh)
            XCTAssertNotEqual(fresh.page.id, evidence.page.id)
        }
    }

    func testPageEvidenceReportsBoundsAndEmbeddedContentWithoutInventingCoverage() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/results": .init(body: """
            <p>Known result</p><iframe src="/frame"></iframe><canvas>Canvas fallback</canvas>
            <div id="shadow"><span slot="chosen">Assigned result</span><span slot="concealed">Invisible assigned result</span><span>Unassigned result</span></div><script>
            document.getElementById('shadow').attachShadow({mode:'open'}).innerHTML = '<p>Shadow result</p><a href="/shadow-event">Shadow event</a><a href="/assigned-event"><slot name="chosen">Unused slot fallback</slot></a><span style="opacity:0"><slot name="concealed"></slot></span>';
            for (let i = 0; i < 300; i++) { const p = document.createElement('p'); p.textContent = 'Result ' + i; document.body.append(p); }
            </script>
            """), "/frame": .init(body: "<p>Embedded result cannot be silently included</p>")])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "bounded-results")
        let document = try await browser.navigate(taskID: "bounded-results", operationID: "results", to: base.appendingPathComponent("results"))
        let evidence = try await browser.observePage(document: document)
        XCTAssertTrue(evidence.page.truncated)
        XCTAssertTrue(evidence.page.omittedEmbeddedContent)
        XCTAssertEqual(evidence.page.texts.count, 256)
        XCTAssertTrue(evidence.page.texts.contains { $0.text == "Shadow result" })
        XCTAssertTrue(evidence.page.texts.contains { $0.text == "Assigned result" })
        XCTAssertFalse(evidence.page.texts.contains { $0.text == "Unassigned result" || $0.text == "Invisible assigned result" || $0.text == "Unused slot fallback" || $0.text == "Canvas fallback" })
        XCTAssertFalse(evidence.page.texts.contains { $0.text.contains("Embedded result") })
        XCTAssertTrue(evidence.page.links.contains { $0.label == "Shadow event" })
        XCTAssertTrue(evidence.page.links.contains { $0.label == "Assigned result" && $0.destination.hasSuffix("/assigned-event") })
        XCTAssertTrue(evidence.page.isWellFormed)
        try await browser.validatePageEvidence(evidence)
    }

    func testPageEvidenceAuthenticationAndControlGatesRunBeforePublication() async throws {
        for credential in ["<input type='password' value='private-password'>",
                           "<input autocomplete='one-time-code' value='private-code'>"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: "<p>Private account page</p>" + credential)])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            var commands: [ComputerUseBrowserDOMCommand] = []
            let browser = ComputerUseOwnedBrowser(presentsWindow: false,
                domScriptDidDispatch: { commands.append($0) }, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "page-login")
            let document = try await browser.navigate(taskID: "page-login", operationID: "login", to: base.appendingPathComponent("login"))
            allowed = false
            let beforePause = commands
            do { _ = try await browser.observePage(document: document); XCTFail("Paused reads cannot dispatch") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(commands, beforePause)
            allowed = true
            do { _ = try await browser.observePage(document: document); XCTFail("Authentication cannot publish page text") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        }
        let server = try OwnedBrowserHTTPFixture(routes: ["/results": .init(body: "<p>Current result</p>")])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false,
            domScriptDidDispatch: { if $0 == .pageSnapshot { allowed = false } }, mayAct: { allowed })
        defer { browser.close() }
        try browser.claim(taskID: "read-race")
        let document = try await browser.navigate(taskID: "read-race", operationID: "results", to: base.appendingPathComponent("results"))
        do { _ = try await browser.observePage(document: document); XCTFail("Losing control during WebKit's await cannot publish evidence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
    }

    func testPageEvidenceFreshReadSupersedesPriorEvidenceWithoutRetiringFormBindings() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/results": .init(body: "<p>Current result</p><label>Search<input value='private-query'></label>")])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "page-and-form")
        let document = try await browser.navigate(taskID: "page-and-form", operationID: "results", to: base.appendingPathComponent("results"))
        let target = ComputerUseBrowserTextTarget(browser: browser, document: document, requiresFrontmost: false)
        let fields = try await target.fields()
        let field = try XCTUnwrap(fields.first)
        let first = try await browser.observePage(document: document)
        let second = try await browser.observePage(document: document)
        let retained = try await target.read(targetID: field.snapshot.targetID)
        XCTAssertEqual(retained, field.snapshot)
        do { try await browser.validatePageEvidence(first); XCTFail("A new read supersedes the earlier snapshot") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        try await browser.validatePageEvidence(second)
        browser.close()
        do { try await browser.validatePageEvidence(second); XCTFail("Closing the page invalidates its evidence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
    }

    func testPageEvidenceAfterLoginRequiresHandbackAndUsesOnlyTheCurrentDocument() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/results": .init(body: "<p>Public results</p><script>fetch('/go').then(() => location.href = '/login');</script>"),
            "/go": .init(held: true),
            "/login": .init(body: "<input type='password' value='private-password'><script>fetch('/finish').then(() => location.href = '/account');</script>"),
            "/finish": .init(held: true),
            "/account": .init(body: "<p>Member tickets available</p><a href='/event'>Member event</a>"),
        ])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        try browser.claim(taskID: "login-evidence")
        let original = try await browser.navigate(taskID: "login-evidence", operationID: "results", to: base.appendingPathComponent("results"))
        let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "login-evidence", required: true))
        try await waitUntil { server.count("/go") == 1 }
        let beforeLogin = try await browser.observePage(document: original)
        allowed = false
        server.releaseHeldResponses()
        try await waitUntil { server.count("/finish") == 1 && browser.hasPageAwaitingHandback }
        allowed = true
        try await browser.reacquireAfterUserControl(taskID: "login-evidence", requirement: requirement)
        let login = try XCTUnwrap(browser.currentDocument(taskID: "login-evidence"))
        do { _ = try await browser.observePage(document: login); XCTFail("Early handback still stops at authentication") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        allowed = false
        server.releaseHeldResponses()
        try await waitUntil { server.count("/account") == 1 && browser.hasPageAwaitingHandback }
        allowed = true
        XCTAssertNil(browser.currentDocument(taskID: "login-evidence"), "Opening the gate alone cannot adopt the person's page")
        try await browser.reacquireAfterUserControl(taskID: "login-evidence", requirement: requirement)
        let account = try XCTUnwrap(browser.currentDocument(taskID: "login-evidence"))
        let current = try await browser.observePage(document: account)
        XCTAssertEqual(account.source, .userControlObservation)
        XCTAssertTrue(current.page.texts.contains { $0.text == "Member tickets available" })
        XCTAssertFalse(current.page.texts.contains { $0.text == "Public results" })
        try await browser.validatePageEvidence(current)
        do { try await browser.validatePageEvidence(beforeLogin); XCTFail("Pre-login result evidence belongs to an old document") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertNil(browser.receipt(taskID: "login-evidence", operationID: account.operationID))
        XCTAssertEqual(server.count("/results"), 1)
    }

    func testClosingSignInPopupDoesNotAssertAuthenticationSucceeded() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/login": .init(body: """
                <input type="password" value="private-password">
                <script>fetch('/signal').then(() => window.open('/provider'));</script>
                """), "/signal": .init(held: true),
            "/provider": .init(body: "<input autocomplete='one-time-code' value='private-code'><script>fetch('/ready');</script>"),
        ])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        defer { browser.close() }
        try browser.claim(taskID: "incomplete-login")
        let original = try await browser.navigate(taskID: "incomplete-login", operationID: "login", to: base.appendingPathComponent("login"))
        let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "incomplete-login", required: true))
        try await waitUntil { server.count("/signal") == 1 }
        allowed = false
        browser.updateTaskControls(.init(taskID: "incomplete-login", scopeID: UUID(), presentationID: UUID(),
            phase: .paused, canResume: true), handler: { _, _ in })
        server.releaseHeldResponses()
        try await waitUntil { browser.hasOpenSignInWindow && server.count("/ready") == 1 }
        browser.closeSignInWindow()
        XCTAssertNil(browser.currentDocument(taskID: "incomplete-login"))
        allowed = true
        let closedHistory = try browser.navigationDispatchHistory(taskID: "incomplete-login")
        let controlAssessment = ComputerUseBrowserResultAssessment.ControlHistory(history: closedHistory)
        XCTAssertEqual(controlAssessment.closedSignInWindowCount, 1)
        XCTAssertEqual(controlAssessment.openSignInWindowCount, 0)
        XCTAssertEqual(controlAssessment.completedNativeHandbackCount, 0)
        XCTAssertEqual(controlAssessment.completedWorkflowResumeCount, 0)
        XCTAssertTrue(controlAssessment.gaps.contains(.signInWindowWithoutRecordedPause),
            "The fixture's paused window controls are not a research-owner Pause record")
        let opened = try XCTUnwrap(closedHistory.controlEvents.first { $0.phase == .signInWindowOpened })
        let closed = try XCTUnwrap(closedHistory.controlEvents.first { $0.phase == .signInWindowClosed })
        XCTAssertNotNil(opened.signInWindowID); XCTAssertEqual(opened.signInWindowID, closed.signInWindowID)
        XCTAssertLessThan(opened.order, closed.order)
        XCTAssertFalse(closedHistory.controlEvents.contains { [.nativeReacquisitionFinished, .workflowResumed].contains($0.phase) })
        try await browser.reacquireAfterUserControl(taskID: "incomplete-login", requirement: requirement)
        XCTAssertEqual(browser.currentDocument(taskID: "incomplete-login"), original)
        let target = ComputerUseBrowserTextTarget(browser: browser, document: original, requiresFrontmost: false)
        do {
            _ = try await target.fieldsIfSupported()
            XCTFail("The unchanged authentication form must request user intervention again")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertEqual(server.count("/login"), 1)
    }

    func testSignInPopupPreservesOpenerSessionAndRequiresExplicitHandback() async throws {
        for open in [
            "window.open('/provider?opaque=private-token#private-fragment');",
            "const child = window.open('about:blank'); child.location = '/provider?opaque=private-token#private-fragment';",
            "const child = window.open(''); child.location = '/provider?opaque=private-token#private-fragment';",
            "const child = window.open(); child.location = '/provider?opaque=private-token#private-fragment';",
        ] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: """
                    <label>Origin<input value="old"></label><input type="password" value="private-password">
                    <script>
                    fetch('/open-signal').then(() => { \(open) });
                    addEventListener('message', e => {
                        if (e.origin !== location.origin || e.data !== 'finished') return;
                        document.body.innerHTML = '<label>Origin<input id="fresh" value="retained"></label>';
                        document.getElementById('fresh').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));
                        history.replaceState({}, '', '/account');
                        fetch(document.cookie.includes('fixture_session=yes') ? '/shared-session' : '/lost-session');
                    });
                    </script>
                    """),
                "/open-signal": .init(held: true),
                "/provider?opaque=private-token": .init(body: """
                    <input autocomplete="one-time-code" value="private-code"><script>
                    document.cookie = 'fixture_session=yes; SameSite=Lax; Path=/';
                    fetch('/finish-signal').then(() => {
                        if (opener) opener.postMessage('finished', location.origin);
                        window.close();
                    });
                    </script>
                    """),
                "/finish-signal": .init(held: true),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            var commands: [ComputerUseBrowserDOMCommand] = []
            let browser = ComputerUseOwnedBrowser(presentsWindow: false,
                domScriptDidDispatch: { commands.append($0) }, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "popup-login")
            let original = try await browser.navigate(taskID: "popup-login", operationID: "login", to: base.appendingPathComponent("login"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "popup-login", required: true))
            try await waitUntil { server.count("/open-signal") == 1 }
            let beforePause = commands
            allowed = false
            browser.updateTaskControls(.init(taskID: "popup-login", scopeID: UUID(), presentationID: UUID(),
                phase: .paused, canResume: true), handler: { _, _ in })
            server.releaseHeldResponses()
            try await waitUntil { browser.hasOpenSignInWindow && server.count("/finish-signal") == 1 }
            XCTAssertEqual(browser.signInSite, base.absoluteString)
            XCTAssertFalse(browser.signInDetail.contains("private-"))
            allowed = true
            XCTAssertFalse(browser.hasOwnership(taskID: "popup-login"))
            XCTAssertFalse(browser.hasRequiredPresentation)
            XCTAssertNil(browser.currentDocument(taskID: "popup-login"))
            XCTAssertThrowsError(try browser.claim(taskID: "replacement")) {
                XCTAssertEqual($0 as? ComputerUseBrowserError, .signInWindowOpen)
            }
            do {
                try await browser.reacquireAfterUserControl(taskID: "popup-login", requirement: requirement)
                XCTFail("Resume cannot bypass an open sign-in window")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .signInWindowOpen) }
            do {
                _ = try await browser.callDOM(.fields, arguments: [:], document: original)
                XCTFail("Even a temporarily open host gate cannot inspect the popup or its opener")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(commands, beforePause, "No DOM command runs while the user owns the sign-in flow")
            allowed = false
            server.releaseHeldResponses()
            try await waitUntil { !browser.hasOpenSignInWindow && browser.hasPageAwaitingHandback && server.count("/shared-session") == 1 }
            XCTAssertNil(browser.signInSite)
            XCTAssertNil(browser.currentDocument(taskID: "popup-login"))
            allowed = true
            XCTAssertNil(browser.currentDocument(taskID: "popup-login"))
            try await browser.reacquireAfterUserControl(taskID: "popup-login", requirement: requirement)
            let current = try XCTUnwrap(browser.currentDocument(taskID: "popup-login"))
            XCTAssertEqual(current.source, .userControlObservation)
            let history = try browser.navigationDispatchHistory(taskID: "popup-login")
            let controlAssessment = ComputerUseBrowserResultAssessment.ControlHistory(history: history)
            XCTAssertEqual(controlAssessment.closedSignInWindowCount, 1)
            XCTAssertEqual(controlAssessment.completedNativeHandbackCount, 1)
            XCTAssertEqual(controlAssessment.failedNativeHandbackCount, 1)
            XCTAssertEqual(controlAssessment.completedWorkflowResumeCount, 0)
            XCTAssertFalse(controlAssessment.gaps.contains(.signInObservationOutsideLifetime))
            XCTAssertTrue(controlAssessment.gaps.contains(.nativeHandbackWithoutWorkflow))
            let signInObservations = history.observations.filter { $0.surface == .signInWindow }
            let opened = try XCTUnwrap(history.controlEvents.first { $0.phase == .signInWindowOpened })
            let closed = try XCTUnwrap(history.controlEvents.first { $0.phase == .signInWindowClosed })
            XCTAssertNotNil(opened.signInWindowID); XCTAssertEqual(opened.signInWindowID, closed.signInWindowID)
            XCTAssertTrue(signInObservations.allSatisfy { $0.signInWindowID == opened.signInWindowID && $0.order > opened.order && $0.order < closed.order })
            XCTAssertFalse(signInObservations.isEmpty)
            XCTAssertTrue(signInObservations.contains { $0.phase == .response && $0.decision == .allowed && $0.control == .userControl })
            XCTAssertTrue(signInObservations.allSatisfy {
                $0.attemptID == nil && $0.navigationCorrelationID == nil && $0.binding == .none
                    && $0.configuredPolicy == nil && $0.policyCheck == .notChecked
            })
            XCTAssertEqual(history.attempts.count, 1)
            for observation in signInObservations { XCTAssertFalse(String(reflecting: observation).contains("private-")) }
            XCTAssertFalse(browser.validate(original))
            XCTAssertEqual(browser.receipt(taskID: "popup-login", operationID: "login"), original)
            XCTAssertNil(browser.receipt(taskID: "popup-login", operationID: current.operationID))
            let target = ComputerUseBrowserTextTarget(browser: browser, document: current, requiresFrontmost: false)
            let fields = try await target.fieldsIfSupported()
            let field = try XCTUnwrap(fields?.first)
            XCTAssertEqual(field.snapshot.value, "retained")
            try await target.apply(.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "Paris"),
                expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["popup-edit"]))
            try await waitUntil { server.count("/edited?value=Paris") == 1 }
            XCTAssertEqual(server.count("/login"), 1)
            XCTAssertEqual(server.count("/provider?opaque=private-token"), 1)
            XCTAssertEqual(server.count("/account"), 0)
            XCTAssertEqual(server.count("/lost-session"), 0)
        }
    }

    func testSignInPopupRequiresPausedTaskAndRejectsExtraAndNestedWindows() async throws {
        for (phase, canResume) in [(ComputerUseBrowserTaskControls.Phase.working, false),
                                  (.awaitingApproval, false), (.paused, false), (.paused, true)] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: """
                    <script>fetch('/signal').then(() => {
                        window.open('data:text/html,unsupported');
                        window.open('/provider'); window.open('/extra'); fetch('/attempted');
                    });</script>
                    """), "/signal": .init(held: true),
                "/provider": .init(body: "<script>window.open('/nested'); fetch('/provider-ready');</script>"),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "popup-admission")
            let original = try await browser.navigate(taskID: "popup-admission", operationID: "login", to: base.appendingPathComponent("login"))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = phase == .working
            browser.updateTaskControls(.init(taskID: "popup-admission", scopeID: UUID(), presentationID: UUID(),
                phase: phase, canResume: canResume), handler: { _, _ in })
            server.releaseHeldResponses()
            try await waitUntil { server.count("/attempted") == 1 }
            if phase == .paused && canResume {
                try await waitUntil { server.count("/provider-ready") == 1 }
                XCTAssertTrue(browser.hasOpenSignInWindow)
                XCTAssertEqual(server.count("/provider"), 1)
            } else {
                XCTAssertFalse(browser.hasOpenSignInWindow)
                XCTAssertEqual(server.count("/provider"), 0)
            }
            XCTAssertEqual(server.count("/extra"), 0)
            XCTAssertEqual(server.count("/nested"), 0)
            browser.closeSignInWindow()
            XCTAssertEqual(browser.taskID, "popup-admission", "Closing the child does not cancel the main task")
            allowed = true
            XCTAssertEqual(browser.currentDocument(taskID: "popup-admission"), original)
            XCTAssertEqual(browser.receipt(taskID: "popup-admission", operationID: "login"), original)
        }
    }

    func testSignInPopupRetainsOwnerThroughResumeButRetiresOnStopCloseOrReplacement() async throws {
        for ending in ["stop", "close", "owner", "revoke"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: "<script>fetch('/signal').then(() => window.open('/provider'));</script>"),
                "/signal": .init(held: true),
                "/provider": .init(body: "<script>fetch('/late-child'); window.close();</script>", held: true),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "popup-owner")
            let original = try await browser.navigate(taskID: "popup-owner", operationID: "login", to: base.appendingPathComponent("login"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "popup-owner", required: true))
            try await waitUntil { server.count("/signal") == 1 }
            let ownerID = UUID()
            allowed = false
            browser.updateTaskControls(.init(taskID: "popup-owner", scopeID: UUID(), presentationID: UUID(),
                phase: .paused, canResume: true, ownerID: ownerID), handler: { _, _ in })
            server.releaseHeldResponses()
            try await waitUntil { browser.hasOpenSignInWindow && server.count("/provider") == 1 }
            browser.updateTaskControls(.init(taskID: "popup-owner", scopeID: UUID(), presentationID: UUID(),
                phase: .working, canResume: false, ownerID: ownerID), handler: { _, _ in })
            XCTAssertTrue(browser.hasOpenSignInWindow, "A successor execution must not silently dismiss an unfinished login")
            allowed = true
            do {
                try await browser.reacquireAfterUserControl(taskID: "popup-owner", requirement: requirement)
                XCTFail("Early handback must retain the child and pause again")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .signInWindowOpen) }
            allowed = false
            if ending == "stop" { browser.stop() }
            else if ending == "close" { browser.close() }
            else if ending == "revoke" { browser.updateTaskControls(nil, handler: { _, _ in }) }
            else {
                browser.updateTaskControls(.init(taskID: "popup-owner", scopeID: UUID(), presentationID: UUID(),
                    phase: .paused, canResume: true, ownerID: UUID()), handler: { _, _ in })
            }
            XCTAssertFalse(browser.hasOpenSignInWindow)
            XCTAssertNil(browser.signInSite)
            server.releaseHeldResponses()
            // This bound checks that a retired held response cannot run its
            // script or mutate the opener; it is not a general timing oracle.
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(server.count("/late-child"), 0)
            XCTAssertFalse(browser.hasPageAwaitingHandback)
            allowed = true
            if ending == "stop" || ending == "close" {
                XCTAssertNil(browser.taskID)
                XCTAssertFalse(browser.validate(original))
            } else {
                XCTAssertEqual(browser.currentDocument(taskID: "popup-owner"), original)
            }
        }
    }

    func testHistoryHandbackCreatesFreshTargetsWithoutReloadOrNavigationProof() async throws {
        let changes = [
            "history.pushState({}, '', '/account?opaque=private-query#private-fragment');",
            "history.replaceState({}, '', '/account?opaque=private-query#private-fragment');",
            "location.hash = 'private-fragment';",
            "history.pushState({}, '', '/temporary'); history.replaceState({}, '', '/login');",
        ]
        for change in changes {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: """
                    <label>Origin<input value="old"></label><script>
                    fetch('/signal').then(() => {
                        document.body.innerHTML = '<label>Origin<input id="fresh" value="retained"></label>';
                        document.getElementById('fresh').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));
                        \(change)
                        fetch('/changed');
                    });
                    </script>
                    """), "/signal": .init(held: true),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "history")
            let original = try await browser.navigate(taskID: "history", operationID: "login", to: base.appendingPathComponent("login"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "history"))
            let oldTarget = ComputerUseBrowserTextTarget(browser: browser, document: original, requiresFrontmost: false)
            let oldFields = try await oldTarget.fieldsIfSupported()
            let oldField = try XCTUnwrap(oldFields?.first)
            try await waitUntil { server.count("/signal") == 1 }
            allowed = false
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == 1 && browser.hasPageAwaitingHandback }
            XCTAssertFalse(browser.validate(original))
            allowed = true
            XCTAssertNil(browser.currentDocument(taskID: "history"), "Opening the action gate does not accept the history change")
            do { _ = try await browser.acquireObservedDocument(taskID: "history"); XCTFail("Ordinary planning cannot adopt a page changed during user control") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            try await browser.reacquireAfterUserControl(taskID: "history", requirement: requirement)
            let current = try XCTUnwrap(browser.currentDocument(taskID: "history"))
            XCTAssertNotEqual(current.generation, original.generation, "A -> B -> A cannot revive the old reference")
            XCTAssertEqual(current.source, .userControlObservation)
            XCTAssertEqual(browser.receipt(taskID: "history", operationID: "login"), original)
            XCTAssertNil(browser.receipt(taskID: "history", operationID: current.operationID))
            do {
                _ = try await oldTarget.read(targetID: oldField.snapshot.targetID)
                XCTFail("Pre-login targets cannot read the replacement form")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            let freshTarget = ComputerUseBrowserTextTarget(browser: browser, document: current, requiresFrontmost: false)
            let freshFields = try await freshTarget.fieldsIfSupported()
            let freshField = try XCTUnwrap(freshFields?.first)
            XCTAssertNotEqual(freshField.snapshot.targetID, oldField.snapshot.targetID)
            XCTAssertEqual(freshField.snapshot.value, "retained")
            try await freshTarget.apply(.init(targetID: freshField.snapshot.targetID, mode: .replaceAll, text: "Paris"),
                expected: freshField.snapshot, operationID: ComputerUseTaskContract.digest(["fresh-edit"]))
            try await waitUntil { server.count("/edited?value=Paris") == 1 }
            XCTAssertEqual(server.count("/login"), 1)
            XCTAssertEqual(server.count("/account?opaque=private-query"), 0)
            XCTAssertEqual(server.count("/temporary"), 0)
            XCTAssertEqual(browser.displayedSite, base.absoluteString)
        }
    }

    func testHistoryChangesDuringAutomationRemainObservationOnlyAfterExplicitHandback() async throws {
        for change in ["history.replaceState({}, '', '/account');",
                       "history.pushState({}, '', '/other'); history.replaceState({}, '', '/login');"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: "<script>fetch('/signal').then(() => { \(change) fetch('/changed'); });</script>"),
                "/signal": .init(held: true),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "active-history")
            let original = try await browser.navigate(taskID: "active-history", operationID: "login", to: base.appendingPathComponent("login"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "active-history", required: true))
            try await waitUntil { server.count("/signal") == 1 }
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == 1 && !browser.validate(original) }
            allowed = false
            XCTAssertFalse(browser.hasPageAwaitingHandback)
            allowed = true
            try await browser.reacquireAfterUserControl(taskID: "active-history", requirement: requirement)
            let current = try XCTUnwrap(browser.currentDocument(taskID: "active-history"))
            XCTAssertEqual(current.source, .activePageObservation, "Handback cannot reclassify the earlier page change as a requested navigation or a user-time observation")
            let history = try browser.navigationDispatchHistory(taskID: "active-history")
            let observationHistory = ComputerUseBrowserResultAssessment.PageObservationHistory(history: history)
            XCTAssertGreaterThan(observationHistory.sameDocumentCandidateCount, 0)
            XCTAssertEqual(observationHistory.matchedAdoptionCount, 1)
            XCTAssertEqual(observationHistory.nativeHandbackLinkedAdoptionCount, 1)
            XCTAssertEqual(observationHistory.gaps, [.sameDocumentSourceUnqualified])
            XCTAssertEqual(observationHistory.retiredCount, observationHistory.matchedRetirementCount)
            XCTAssertEqual(observationHistory.acceptedCount, observationHistory.adoptedCount + observationHistory.retiredCount)
            XCTAssertTrue(history.pageObservationEvents.allSatisfy { $0.observation.navigationCorrelationID == nil })
            XCTAssertFalse(browser.validate(original), "An A -> B -> A history transition cannot revive an old document")
            XCTAssertNil(browser.receipt(taskID: "active-history", operationID: current.operationID))
            XCTAssertEqual(browser.receipt(taskID: "active-history", operationID: "login"), original)
            XCTAssertEqual(server.count("/login"), 1)
        }
    }

    func testActiveLinkAndSearchPagesBecomeFreshObservationsWithoutNavigationReceipts() async throws {
        for action in ["document.querySelector('a').click();", "document.querySelector('form').requestSubmit();"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/start": .init(body: """
                    <label>Origin<input value="old"></label><a href="/redirect">Results</a>
                    <form action="/results" method="get"><input name="q" value="Paris"></form>
                    <script>fetch('/signal').then(() => { \(action) });</script>
                    """), "/signal": .init(held: true), "/redirect": .init(status: 302, location: "/results?q=Paris"),
                "/results?q=Paris": .init(body: "<p>Paris results</p><label>Destination<input value='new'></label>")])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: "active-results")
            let original = try await browser.navigate(taskID: "active-results", operationID: "open", to: base.appendingPathComponent("start"))
            let oldTarget = ComputerUseBrowserTextTarget(browser: browser, document: original, requiresFrontmost: false)
            // The unlabelled submitted input makes this whole text form
            // unsupported; retain the actual document/page evidence instead.
            let oldEvidence = try await browser.observePage(document: original)
            try await waitUntil { server.count("/signal") == 1 }
            server.releaseHeldResponses()
            try await waitUntil { server.count("/results?q=Paris") == 1 && !browser.isLoadingPage }
            XCTAssertNil(browser.currentDocument(taskID: "active-results"), "A callback alone cannot publish executable document authority")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
            let observed = try await navigation.pageEvidenceIfFrontmost(taskID: "active-results")
            let fresh = try XCTUnwrap(observed)
            XCTAssertEqual(fresh.document.source, .activePageObservation)
            XCTAssertTrue(fresh.page.answerVerificationText.contains("Paris results"))
            XCTAssertEqual(fresh.document.committedURL, base.appendingPathComponent("results").appending(queryItems: [.init(name: "q", value: "Paris")]))
            XCTAssertEqual(browser.receipt(taskID: "active-results", operationID: "open"), original)
            XCTAssertNil(browser.receipt(taskID: "active-results", operationID: fresh.document.operationID))
            XCTAssertFalse(browser.validate(original))
            do { try await browser.validatePageEvidence(oldEvidence); XCTFail("Old page evidence cannot survive the navigation") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            do { _ = try await oldTarget.fields(); XCTFail("Old field authority cannot transfer to the new document") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            let repeated = try await browser.acquireObservedDocument(taskID: "active-results")
            XCTAssertEqual(repeated, fresh.document)
            XCTAssertEqual(server.count("/start"), 1); XCTAssertEqual(server.count("/results?q=Paris"), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Observing a page cannot create an action journal")
        }
    }

    func testActivePageObservationWaitsForSuccessAndTimeoutDoesNotReloadThePage() async throws {
        for timeout in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/start": .init(body: "<script>fetch('/signal').then(() => location.href='/results');</script>"),
                "/signal": .init(held: true), "/results": .init(status: timeout ? 200 : 503, body: "<p>Results</p>", held: timeout)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, navigationTimeout: .seconds(1), mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: "waiting-results")
            let original = try await browser.navigate(taskID: "waiting-results", operationID: "open", to: base.appendingPathComponent("start"))
            try await waitUntil { server.count("/signal") == 1 }
            server.releaseHeldResponses()
            try await waitUntil { server.count("/results") == 1 }
            if timeout {
                do { _ = try await browser.navigate(taskID: "waiting-results", operationID: "competing", to: base.appendingPathComponent("replacement")); XCTFail("A tracked page load cannot be overtaken by another navigation") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .busy) }
                XCTAssertEqual(server.count("/replacement"), 0)
            }
            do { _ = try await browser.acquireObservedDocument(taskID: "waiting-results"); XCTFail("An unfinished or unsuccessful page is not ready evidence") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, timeout ? .deadlineExceeded : .pageChanged) }
            XCTAssertNil(browser.currentDocument(taskID: "waiting-results"))
            XCTAssertEqual(browser.receipt(taskID: "waiting-results", operationID: "open"), original)
            if timeout {
                server.releaseHeldResponses()
                try await waitUntil { !browser.isLoadingPage }
                let ready = try await browser.acquireObservedDocument(taskID: "waiting-results")
                XCTAssertEqual(ready.source, .activePageObservation)
                XCTAssertNil(browser.receipt(taskID: "waiting-results", operationID: ready.operationID))
            }
            XCTAssertEqual(server.count("/results"), 1, "An observation timeout is never a navigation retry")
        }
    }

    func testActiveObservationWaitCannotCrossCancellationTakeoverOrSameTaskOwnershipRestart() async throws {
        for interruption in ["cancel", "pause", "restart"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/start": .init(body: "<script>fetch('/signal').then(() => location.href='/results');</script>"),
                "/signal": .init(held: true), "/results": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: "interrupted-observation")
            _ = try await browser.navigate(taskID: "interrupted-observation", operationID: "open", to: base.appendingPathComponent("start"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "interrupted-observation", required: true))
            try await waitUntil { server.count("/signal") == 1 }
            server.releaseHeldResponses()
            try await waitUntil {
                server.count("/results") == 1 && browser.isLoadingPage
                    && (try? browser.navigationDispatchHistory(taskID: "interrupted-observation").observations.contains {
                        $0.phase == .provisionalStart && $0.binding == .exactObservedNavigation
                    }) == true
            }
            var started = false
            let waiting = Task { started = true; return try await browser.acquireObservedDocument(taskID: "interrupted-observation") }
            defer { waiting.cancel() }
            try await waitUntil { started }
            if interruption == "cancel" { waiting.cancel() }
            else if interruption == "pause" { allowed = false }
            else { browser.stop(); try browser.claim(taskID: "interrupted-observation") }
            do { _ = try await waiting.value; XCTFail("An old observation must not publish across an ownership boundary") }
            catch {
                if interruption == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            }
            XCTAssertNil(browser.currentDocument(taskID: "interrupted-observation"))
            if interruption != "restart" {
                server.releaseHeldResponses()
                try await waitUntil { !browser.isLoadingPage }
                allowed = true
                if interruption == "pause" {
                    do { _ = try await browser.acquireObservedDocument(taskID: "interrupted-observation"); XCTFail("A load that completed under user control still needs explicit handback") }
                    catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                    try await browser.reacquireAfterUserControl(taskID: "interrupted-observation", requirement: requirement)
                }
                let fresh = try await browser.acquireObservedDocument(taskID: "interrupted-observation")
                XCTAssertEqual(fresh.source, .activePageObservation)
                XCTAssertNil(browser.receipt(taskID: "interrupted-observation", operationID: fresh.operationID))
                let history = try browser.navigationDispatchHistory(taskID: "interrupted-observation")
                let accepted = try XCTUnwrap(history.pageObservationEvents.first)
                XCTAssertEqual(accepted.observation.source, .activePageObservation)
                XCTAssertEqual(accepted.observation.requiresExplicitHandback, interruption == "pause")
                let assessment = ComputerUseBrowserResultAssessment.PageObservationHistory(history: history)
                XCTAssertEqual(assessment.matchedAdoptionCount, 1)
                XCTAssertEqual(assessment.nativeHandbackLinkedAdoptionCount, interruption == "pause" ? 1 : 0)
                XCTAssertTrue(assessment.gaps.isEmpty)
            } else {
                let history = try browser.navigationDispatchHistory(taskID: "interrupted-observation")
                let ended = try XCTUnwrap(history.observations.first { $0.phase == .observedNavigationEnded })
                let started = try XCTUnwrap(history.observations.first {
                    $0.phase == .provisionalStart && $0.navigationCorrelationID == ended.navigationCorrelationID
                })
                XCTAssertEqual(ended.observedEnd, .stopped)
                XCTAssertEqual(ended.parentSessionID, started.parentSessionID)
                XCTAssertEqual(ended.ownershipEpoch, started.ownershipEpoch)
                XCTAssertEqual(ended.generation, started.generation)
                let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: history)
                XCTAssertEqual(episodes.endedObservedEpisodeCount, 1)
                XCTAssertEqual(episodes.rejectedObservedEpisodeCount, 0)
                XCTAssertFalse(episodes.gaps.contains(.unfinishedEpisode), "The old tracked load ended before the replacement claim")
                XCTAssertTrue(history.pageObservationEvents.isEmpty)
            }
            XCTAssertEqual(server.count("/results"), 1)
        }
    }

    func testActiveHistoryIdentityReadCannotPublishAfterTakeoverStopOrClose() async throws {
        for interruption in ["pause", "stop", "close"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/start": .init(body: "<script>fetch('/signal').then(() => { history.replaceState({}, '', '/results'); fetch('/changed'); });</script>"),
                "/signal": .init(held: true)])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true, armed = false
            var context: ComputerUseOwnedBrowser?
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
                guard armed, command == .pageIdentity else { return }
                armed = false
                if interruption == "pause" { allowed = false }
                else if interruption == "stop" { context?.stop() }
                else { context?.close() }
            }, mayAct: { allowed })
            context = browser
            defer { browser.close(); context = nil }
            try browser.claim(taskID: "history-read")
            let original = try await browser.navigate(taskID: "history-read", operationID: "open", to: base.appendingPathComponent("start"))
            try await waitUntil { server.count("/signal") == 1 }
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == 1 && !browser.validate(original) }
            armed = true
            do { _ = try await browser.acquireObservedDocument(taskID: "history-read"); XCTFail("The identity callback lost its observation scope") }
            catch { XCTAssertTrue(error as? ComputerUseBrowserError == .pageChanged || error as? ComputerUseBrowserError == .ownershipLost) }
            XCTAssertFalse(armed); XCTAssertNil(browser.currentDocument(taskID: "history-read"))
            XCTAssertEqual(server.count("/results"), 0, "History verification must not load its URL")
        }
    }

    func testHistoryIdentityCheckCannotPublishAfterCancellationStopOrClose() async throws {
        for interruption in ["cancel", "stop", "close"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/login": .init(body: "<script>fetch('/signal').then(() => { history.replaceState({}, '', '/account'); fetch('/changed'); });</script>"),
                "/signal": .init(held: true),
            ])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true, shouldInterrupt = false
            var running: Task<Void, Error>?
            var owned: ComputerUseOwnedBrowser?
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, domScriptDidDispatch: { command in
                guard command == .pageIdentity, shouldInterrupt else { return }
                shouldInterrupt = false
                if interruption == "cancel" { running?.cancel() }
                else if interruption == "stop" { owned?.stop() }
                else { owned?.close() }
            }, mayAct: { allowed })
            owned = browser
            defer { browser.close() }
            try browser.claim(taskID: "interrupted-history")
            let original = try await browser.navigate(taskID: "interrupted-history", operationID: "login", to: base.appendingPathComponent("login"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "interrupted-history"))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = false
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == 1 && browser.hasPageAwaitingHandback }
            allowed = true
            shouldInterrupt = true
            let handback = Task { try await browser.reacquireAfterUserControl(taskID: "interrupted-history", requirement: requirement) }
            running = handback
            do { try await handback.value; XCTFail("An interrupted identity query cannot publish a document") }
            catch is CancellationError { XCTAssertEqual(interruption, "cancel") }
            catch {
                let failure = try XCTUnwrap(error as? ComputerUseBrowserError)
                XCTAssertTrue([ComputerUseBrowserError.ownershipLost, .closed, .pageChanged, .handbackContextLost].contains(failure))
            }
            XCTAssertNil(browser.currentDocument(taskID: "interrupted-history"))
            XCTAssertFalse(browser.validate(original))
            if interruption == "cancel" {
                // The read owns its DOM slot until its real callback. A later
                // explicit handback may retry only after that slot is free.
                let deadline = ContinuousClock.now + .seconds(5)
                while true {
                    do { try await browser.reacquireAfterUserControl(taskID: "interrupted-history", requirement: requirement); break }
                    catch ComputerUseBrowserError.busy {
                        guard ContinuousClock.now < deadline else { throw FixtureError.deadline }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                XCTAssertEqual(browser.currentDocument(taskID: "interrupted-history")?.source, .userControlObservation)
            } else {
                XCTAssertFalse(browser.hasPageAwaitingHandback)
                XCTAssertNil(browser.taskID)
            }
            XCTAssertEqual(server.count("/login"), 1)
            XCTAssertEqual(server.count("/account"), 0)
        }
    }

    func testLoadedDocumentIdentityReadsNoAuthenticationValuesAndSurvivesOnlyThatDocument() async throws {
        let secret = "private-authentication-fixture"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/login": .init(body: """
                <input type="password" value="\(secret)"><script>
                fetch('/signal').then(() => {
                    const root = document.createElement('html');
                    root.innerHTML = '<body><input autocomplete="one-time-code" value="\(secret)"></body>';
                    document.replaceChild(root, document.documentElement); fetch('/changed');
                });
                </script>
                """), "/signal": .init(held: true),
            "/second": .init(body: "<input type='password' value='\(secret)'>"),
        ])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "identity")
        let first = try await browser.navigate(taskID: "identity", operationID: "first", to: base.appendingPathComponent("login"))
        let before = try await browser.callDOM(.pageIdentity, arguments: [:], document: first)
        XCTAssertEqual(before.status, "page-identity")
        XCTAssertNil(before.fields)
        try await waitUntil { server.count("/signal") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/changed") == 1 }
        let afterRootChange = try await browser.callDOM(.pageIdentity, arguments: [:], document: first)
        XCTAssertEqual(afterRootChange.documentID, before.documentID)
        XCTAssertNil(afterRootChange.fields)
        do {
            _ = try await browser.callDOM(.fields, arguments: [:], document: first)
            XCTFail("Document identity does not grant access to authentication fields")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        let second = try await browser.navigate(taskID: "identity", operationID: "second", to: base.appendingPathComponent("second"))
        let reloaded = try await browser.callDOM(.pageIdentity, arguments: [:], document: second)
        XCTAssertNotEqual(reloaded.documentID, before.documentID)
        XCTAssertNil(reloaded.fields)
        XCTAssertFalse(browser.validate(first))
    }

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
        let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "handoff-callback", required: true))
        try await waitUntil { server.count("/signal") == 1 }
        allowed = false
        server.releaseHeldResponses()
        try await waitUntil { browser.hasPageAwaitingHandback }
        XCTAssertEqual(browser.displayedSite, base.absoluteString)
        XCTAssertFalse(browser.validate(original))
        do {
            try await browser.reacquireAfterUserControl(taskID: "handoff-callback", requirement: requirement)
            XCTFail("A closed gate cannot hand back control")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
        allowed = true
        XCTAssertNil(browser.currentDocument(taskID: "handoff-callback"))
        try await browser.reacquireAfterUserControl(taskID: "handoff-callback", requirement: requirement)
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

    func testHandbackRequirementBindsTaskBrowserAndOwnershipWithoutReloading() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<p>Current page</p>")])
        let base = try await server.start()
        defer { server.stop() }
        var commands: [ComputerUseBrowserDOMCommand] = []
        let browser = ComputerUseOwnedBrowser(presentsWindow: false,
            domScriptDidDispatch: { commands.append($0) }, mayAct: { true })
        let other = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close(); other.close() }
        XCTAssertNil(browser.handbackRequirement(taskID: "root"))
        try browser.claim(taskID: "root")
        let original = try await browser.navigate(taskID: "root", operationID: "open", to: base.appendingPathComponent("page"))
        let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "root"))
        XCTAssertNil(browser.handbackRequirement(taskID: "unrelated"))
        XCTAssertEqual(String(describing: requirement), "BrowserHandbackRequirement")
        XCTAssertEqual(String(reflecting: requirement), "BrowserHandbackRequirement")
        let before = commands
        try await browser.reacquireAfterUserControl(taskID: "root", requirement: requirement)
        XCTAssertEqual(browser.currentDocument(taskID: "root"), original)
        XCTAssertEqual(commands, before, "Unchanged handback needs no DOM read or request")
        do {
            try await browser.reacquireAfterUserControl(taskID: "unrelated", requirement: requirement)
            XCTFail("A token cannot be applied to another task")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        try other.claim(taskID: "root")
        _ = try await other.navigate(taskID: "root", operationID: "open", to: base.appendingPathComponent("page"))
        do {
            try await other.reacquireAfterUserControl(taskID: "root", requirement: requirement)
            XCTFail("Matching task and URL do not identify the same browser")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        try browser.claim(taskID: "another-owner")
        try browser.claim(taskID: "root")
        do {
            try await browser.reacquireAfterUserControl(taskID: "root", requirement: requirement)
            XCTFail("Returning to the old task ID cannot restore retired ownership")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        XCTAssertEqual(commands, before)
        XCTAssertEqual(server.count("/page"), 2)
    }

    func testHandbackRequirementCannotSurviveStoppedOrRecreatedSession() async throws {
        for ending in ["stop", "close"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<p>Current page</p>")])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let missing = try XCTUnwrap(browser.handbackRequirement(taskID: "root", required: true))
            try browser.claim(taskID: "root")
            _ = try await browser.navigate(taskID: "root", operationID: "first", to: base.appendingPathComponent("page"))
            let old = try XCTUnwrap(browser.handbackRequirement(taskID: "root"))
            if ending == "stop" { browser.stop() } else { browser.close() }
            for requirement in [old, missing] {
                do {
                    try await browser.reacquireAfterUserControl(taskID: "root", requirement: requirement)
                    XCTFail("A missing browser must fail explicitly")
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
            }
            try browser.claim(taskID: "root")
            let replacement = try await browser.navigate(taskID: "root", operationID: "second", to: base.appendingPathComponent("page"))
            for requirement in [old, missing] {
                do {
                    try await browser.reacquireAfterUserControl(taskID: "root", requirement: requirement)
                    XCTFail("A later same-task browser cannot satisfy the earlier handoff")
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
            }
            let fresh = try XCTUnwrap(browser.handbackRequirement(taskID: "root"))
            XCTAssertNotEqual(fresh, old)
            try await browser.reacquireAfterUserControl(taskID: "root", requirement: fresh)
            XCTAssertEqual(browser.currentDocument(taskID: "root"), replacement)
            XCTAssertEqual(server.count("/page"), 2, "Handback validation cannot create a third navigation")
        }
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
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "handoff"))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = false
            server.releaseHeldResponses()
            try await waitUntil { browser.hasPageAwaitingHandback }
            XCTAssertFalse(browser.validate(original))
            do {
                try await browser.reacquireAfterUserControl(taskID: "handoff", requirement: requirement)
                XCTFail("A closed gate cannot hand back control")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            allowed = true
            XCTAssertNil(browser.currentDocument(taskID: "handoff"), "Opening the gate is not handback")
            XCTAssertThrowsError(try browser.acquireCurrentDocument(taskID: "handoff"))
            try await browser.reacquireAfterUserControl(taskID: "handoff", requirement: requirement)
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

    func testSupersededObservedCandidateIsRetiredBeforeTheReplacementIsAdopted() async throws {
        let script = """
            (async () => {
                await fetch('/first'); history.replaceState({}, '', '/discarded'); await fetch('/first-changed');
                await fetch('/second'); history.replaceState({}, '', '/current'); await fetch('/second-changed');
            })();
            """
        let server = try OwnedBrowserHTTPFixture(routes: ["/start": .init(body: "<script>\(script)</script>"),
            "/first": .init(held: true), "/second": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "superseded-observation")
        _ = try await browser.navigate(taskID: "superseded-observation", operationID: "open", to: base.appendingPathComponent("start"))
        try await waitUntil { server.count("/first") == 1 }
        server.releaseHeldResponses()
        try await waitUntil { server.count("/first-changed") == 1 && server.count("/second") == 1 }
        let before = try browser.navigationDispatchHistory(taskID: "superseded-observation")
        let first = try XCTUnwrap(before.pageObservationEvents.first)
        XCTAssertEqual(before.pageObservationEvents.map(\.phase), [.accepted])
        server.releaseHeldResponses()
        try await waitUntil { server.count("/second-changed") == 1 }
        let current = try await browser.acquireObservedDocument(taskID: "superseded-observation")
        let history = try browser.navigationDispatchHistory(taskID: "superseded-observation")
        XCTAssertEqual(history.pageObservationEvents.map(\.phase), [.accepted, .retired, .accepted, .adopted])
        let retired = try XCTUnwrap(history.pageObservationEvents.first { $0.phase == .retired })
        let adopted = try XCTUnwrap(history.pageObservationEvents.last)
        XCTAssertEqual(retired.observation, first.observation)
        XCTAssertEqual(retired.retirement, .locationChanged)
        XCTAssertNil(retired.adoptedSource); XCTAssertNil(retired.nativeReacquisitionID)
        XCTAssertNotEqual(adopted.observation.id, first.observation.id)
        XCTAssertEqual(current.operationID, "page-observation-\(adopted.observation.id.uuidString)")
        XCTAssertEqual(current.committedURL, base.appendingPathComponent("current"))
        XCTAssertNil(browser.receipt(taskID: "superseded-observation", operationID: current.operationID))
        let assessment = ComputerUseBrowserResultAssessment.PageObservationHistory(history: history)
        XCTAssertEqual(assessment.acceptedCount, 2); XCTAssertEqual(assessment.matchedAdoptionCount, 1)
        XCTAssertEqual(assessment.retiredCount, 1); XCTAssertEqual(assessment.matchedRetirementCount, 1)
        XCTAssertEqual(assessment.gaps, [.sameDocumentSourceUnqualified])
        XCTAssertEqual(history.attempts.count, 1)
        XCTAssertEqual(server.count("/discarded"), 0); XCTAssertEqual(server.count("/current"), 0)
    }

    func testObservedPageTransferRetainsItsOriginalClaimWithoutInventingAcceptanceHistory() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<script>fetch('/signal').then(() => location.href='/destination')</script>"),
            "/signal": .init(held: true),
        ])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "original-observation-owner")
        _ = try await browser.navigate(taskID: "original-observation-owner", operationID: "open", to: base.appendingPathComponent("start"))
        try await waitUntil { server.count("/signal") == 1 }
        server.releaseHeldResponses()
        try await waitUntil {
            (try? browser.navigationDispatchHistory(taskID: "original-observation-owner").pageObservationEvents.count) == 1
        }
        let before = try browser.navigationDispatchHistory(taskID: "original-observation-owner")
        let accepted = try XCTUnwrap(before.pageObservationEvents.first)
        let transferred = try await browser.acquireObservedDocument(taskID: "new-observation-owner")
        let after = try browser.navigationDispatchHistory(taskID: "new-observation-owner")
        XCTAssertTrue(after.beganAfterAnotherClaim)
        XCTAssertTrue(after.attempts.isEmpty)
        XCTAssertEqual(after.pageObservationEvents.count, 1)
        let adoption = try XCTUnwrap(after.pageObservationEvents.first)
        XCTAssertEqual(adoption.phase, .adopted)
        XCTAssertEqual(adoption.observation, accepted.observation)
        XCTAssertEqual(adoption.observation.taskID, "original-observation-owner")
        XCTAssertNotEqual(adoption.ownershipEpoch, accepted.observation.ownershipEpoch)
        XCTAssertEqual(adoption.generation, transferred.generation)
        XCTAssertNil(adoption.nativeReacquisitionID)
        let assessment = ComputerUseBrowserResultAssessment.PageObservationHistory(history: after)
        XCTAssertEqual(assessment.acceptedCount, 0); XCTAssertEqual(assessment.adoptedCount, 1)
        XCTAssertEqual(assessment.matchedAdoptionCount, 0)
        XCTAssertTrue(assessment.gaps.contains(.claimTransferUnreconciled))
        XCTAssertTrue(assessment.gaps.contains(.unmatchedAdoption))
        XCTAssertEqual(transferred.source, .activePageObservation)
        XCTAssertNil(browser.receipt(taskID: "new-observation-owner", operationID: transferred.operationID))
        XCTAssertEqual(server.count("/destination"), 1)
    }

    func testObservedPageHistoryStaysBoundedAndOmittedAdoptionsStillInvalidateSnapshots() async throws {
        let script = """
            (async () => { let step = 0; while (true) {
                await fetch('/signal'); history.replaceState({}, '', '/page?step=' + step++); await fetch('/changed');
            } })();
            """
        let server = try OwnedBrowserHTTPFixture(routes: ["/start": .init(body: "<script>\(script)</script>"), "/signal": .init(held: true)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "bounded-observations")
        var current = try await browser.navigate(taskID: "bounded-observations", operationID: "open", to: base.appendingPathComponent("start"))
        for step in 0..<66 {
            try await waitUntil { server.count("/signal") == step + 1 }
            server.releaseHeldResponses()
            try await waitUntil { server.count("/changed") == step + 1 && !browser.validate(current) }
            let beforeAdoption = try browser.navigationDispatchHistory(taskID: "bounded-observations")
            current = try await browser.acquireObservedDocument(taskID: "bounded-observations")
            let afterAdoption = try browser.navigationDispatchHistory(taskID: "bounded-observations")
            XCTAssertEqual(current.source, .activePageObservation)
            XCTAssertNil(browser.receipt(taskID: "bounded-observations", operationID: current.operationID))
            if step >= 64 {
                XCTAssertEqual(afterAdoption.pageObservationEvents.count, 128)
                XCTAssertTrue(afterAdoption.pageObservationEventsOverflowed)
                XCTAssertEqual(afterAdoption.pageObservationEvents, beforeAdoption.pageObservationEvents)
                XCTAssertEqual(afterAdoption.observations, beforeAdoption.observations)
                XCTAssertEqual(afterAdoption.controlEvents, beforeAdoption.controlEvents)
                XCTAssertEqual(afterAdoption.attempts, beforeAdoption.attempts)
                XCTAssertEqual(afterAdoption.policyInstallations, beforeAdoption.policyInstallations)
                XCTAssertNotEqual(afterAdoption.identity, beforeAdoption.identity, "An omitted adoption still invalidates the frozen history")
                let assessment = ComputerUseBrowserResultAssessment.PageObservationHistory(history: afterAdoption)
                XCTAssertTrue(assessment.gaps.contains(.overflow))
            }
        }
        XCTAssertEqual(server.count("/start"), 1)
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: "bounded-observations").attempts.count, 1)
    }

    func testHandbackAcceptsSuccessfulPageObservationsAndRejectsFailedLoads() async throws {
        for row in [(pause: false, status: 200), (pause: true, status: 200),
                    (pause: false, status: 404), (pause: true, status: 404)] {
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
            try browser.claim(taskID: "page-handoff")
            let original = try await browser.navigate(taskID: "page-handoff", operationID: "original",
                to: base.appendingPathComponent("login"))
            let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "page-handoff", required: true))
            try await waitUntil { server.count("/signal") == 1 }
            allowed = !row.pause
            server.releaseHeldResponses()
            try await waitUntil { server.count("/destination") == 1 && !browser.isLoadingPage }
            XCTAssertFalse(browser.validate(original))
            XCTAssertEqual(browser.hasPageAwaitingHandback, row.pause && row.status == 200)
            allowed = false
            do {
                try await browser.reacquireAfterUserControl(taskID: "page-handoff", requirement: requirement)
                XCTFail("A completed load cannot reopen the control gate")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .ownershipLost) }
            allowed = true
            XCTAssertNil(browser.currentDocument(taskID: "page-handoff"), "Opening the gate does not adopt a changed page")
            if row.status == 200 {
                try await browser.reacquireAfterUserControl(taskID: "page-handoff", requirement: requirement)
                let current = try XCTUnwrap(browser.currentDocument(taskID: "page-handoff"))
                XCTAssertEqual(current.source, row.pause ? .userControlObservation : .activePageObservation,
                    "Explicit handback preserves when the page was observed")
                XCTAssertEqual(current.committedURL, base.appendingPathComponent("destination"))
                XCTAssertNotEqual(current.generation, original.generation)
                XCTAssertNotEqual(current.operationID, original.operationID)
                XCTAssertNil(browser.receipt(taskID: "page-handoff", operationID: current.operationID),
                    "Accepting an observed page never fabricates an automated navigation receipt")
            } else {
                do {
                    try await browser.reacquireAfterUserControl(taskID: "page-handoff", requirement: requirement)
                    XCTFail("An unsuccessful load cannot become an accepted page observation")
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                XCTAssertNil(browser.currentDocument(taskID: "page-handoff"))
            }
            XCTAssertFalse(browser.hasPageAwaitingHandback)
            XCTAssertEqual(browser.receipt(taskID: "page-handoff", operationID: "original"), original)
            let history = try browser.navigationDispatchHistory(taskID: "page-handoff")
            XCTAssertEqual(history.attempts.count, 1, "Neither handback nor a script creates another automated dispatch")
            XCTAssertEqual(history.attempts.first?.operationID, original.operationID)
            XCTAssertEqual(history.attempts.first?.outcome, .documentCommitted)
            let observations = ComputerUseBrowserResultAssessment.PageObservationHistory(history: history)
            let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: history)
            XCTAssertEqual(episodes.endedObservedEpisodeCount, 1)
            XCTAssertEqual(episodes.rejectedObservedEpisodeCount, row.status == 200 ? 0 : 1)
            XCTAssertFalse(episodes.gaps.contains(.unfinishedEpisode))
            XCTAssertEqual(episodes.matchedObservedAdmissionCount, row.status == 200 ? 1 : 0)
            XCTAssertEqual(observations.acceptedCount, row.status == 200 ? 1 : 0)
            XCTAssertEqual(observations.adoptedCount, row.status == 200 ? 1 : 0)
            XCTAssertEqual(observations.matchedAdoptionCount, row.status == 200 ? 1 : 0)
            XCTAssertEqual(observations.nativeHandbackLinkedAdoptionCount, row.status == 200 ? 1 : 0)
            XCTAssertTrue(observations.gaps.isEmpty)
            if row.status == 200 {
                XCTAssertEqual(history.pageObservationEvents.map(\.phase), [.accepted, .adopted])
                XCTAssertEqual(history.pageObservationEvents.first?.observation, history.pageObservationEvents.last?.observation)
                XCTAssertNotNil(history.pageObservationEvents.last?.nativeReacquisitionID)
            }
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
    func testUserParentWindowCloseNotifiesItsDisplayedControlOnceAfterRetirement() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: closes a local fixture window through AppKit")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        _ = try browser.prepareWorkflowSession(taskID: "user-close")
        _ = try await browser.navigate(taskID: "user-close", operationID: "page", to: base)
        let parent = try XCTUnwrap(NSApp.windows.first { $0.title == "AI Browser — Remote Desktop" && $0.isVisible })
        let controls = ComputerUseBrowserTaskControls(taskID: "user-close", scopeID: UUID(), presentationID: UUID(), phase: .working, canResume: false)
        var requests: [ComputerUseBrowserTaskControls.Action] = []
        browser.updateTaskControls(controls, handler: { [weak browser] displayed, action in
            guard let browser else { return XCTFail("Missing retiring browser") }
            XCTAssertEqual(displayed, controls)
            requests.append(action)
            XCTAssertNil(browser.taskID); XCTAssertFalse(browser.hasSession)
            XCTAssertThrowsError(try browser.claim(taskID: "premature")) { XCTAssertEqual($0 as? ComputerUseBrowserError, .busy) }
            browser.close(); browser.stop()
        })
        parent.performClose(nil)
        XCTAssertEqual(requests, [.stop])
        XCTAssertFalse(parent.isVisible); XCTAssertNil(parent.contentView)
        XCTAssertEqual(browser.detail, "Closed")
        let replacement = try browser.prepareWorkflowSession(taskID: "replacement")
        XCTAssertTrue(try browser.isUnnavigatedSession(replacement))
        XCTAssertEqual(server.count("/"), 1)
    }

    func testNativeWindowCleanupRejectsMidwayClaimsAndCoalescesNestedClose() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: presents local fixture windows and exercises native close notifications")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for withChild in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: withChild
                ? "<script>fetch('/signal').then(() => window.open('/provider'));</script>" : "<p>Parent fixture</p>"),
                "/signal": .init(held: true), "/provider": .init(body: "<script>fetch('/ready');</script>")])
            let base = try await server.start()
            defer { server.stop() }
            var allowed = true
            let browser = ComputerUseOwnedBrowser(mayAct: { allowed })
            defer { browser.close() }
            _ = try browser.prepareWorkflowSession(taskID: "native-close")
            _ = try await browser.navigate(taskID: "native-close", operationID: "login", to: base.appendingPathComponent("login"))
            let parent = try XCTUnwrap(NSApp.windows.first { $0.title == "AI Browser — Remote Desktop" && $0.isVisible })
            var child: NSWindow?
            if withChild {
                let deadline = ContinuousClock.now + .seconds(5)
                while server.count("/signal") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(server.count("/signal"), 1)
                allowed = false
                browser.updateTaskControls(.init(taskID: "native-close", scopeID: UUID(), presentationID: UUID(), phase: .paused, canResume: true), handler: { _, _ in
                    XCTFail("Programmatic retirement must not invent a user window-close command")
                })
                server.releaseHeldResponses()
                while server.count("/ready") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(server.count("/ready"), 1)
                child = try XCTUnwrap(NSApp.windows.first { $0.title == "Sign-in window — AI Browser" && $0.isVisible })
            }
            var notifications = 0
            let subscription = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: child ?? parent).sink { _ in
                notifications += 1
                XCTAssertThrowsError(try browser.claim(taskID: "premature")) { XCTAssertEqual($0 as? ComputerUseBrowserError, .busy) }
                browser.close() // Upgrades an in-progress parent Stop when the child is closing.
                browser.stop()
            }
            defer { subscription.cancel() }
            if withChild { browser.stop() } else { browser.close() }
            XCTAssertEqual(notifications, 1)
            XCTAssertFalse(parent.isVisible); XCTAssertNil(parent.contentView)
            if let child { XCTAssertFalse(child.isVisible); XCTAssertNil(child.contentView) }
            XCTAssertFalse(browser.hasSession); XCTAssertFalse(browser.hasOpenSignInWindow); XCTAssertNil(browser.taskID)
            allowed = true
            let replacement = try browser.prepareWorkflowSession(taskID: "replacement")
            XCTAssertTrue(try browser.isUnnavigatedSession(replacement), "The native cleanup barrier must end before future admission")
        }
    }

    func testSignedHostOwnsVisibleSignInWindowAndClosingItPreservesThePausedParent() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: presents only local fixture browser and sign-in windows")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/login": .init(body: "<script>fetch('/signal').then(() => window.open('/provider?opaque=private-token'));</script>"),
            "/signal": .init(held: true),
            "/provider?opaque=private-token": .init(body: "<label>Password<input type='password'></label><script>fetch('/ready');</script>"),
        ])
        let base = try await server.start()
        defer { server.stop() }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowed })
        defer { browser.close() }
        try browser.claim(taskID: "visible-popup")
        let original = try await browser.navigate(taskID: "visible-popup", operationID: "login", to: base.appendingPathComponent("login"))
        let requirement = try XCTUnwrap(browser.handbackRequirement(taskID: "visible-popup", required: true))
        let parent = try XCTUnwrap(NSApp.windows.first { $0.title == "AI Browser — Remote Desktop" })
        let controls = ComputerUseBrowserTaskControls(taskID: "visible-popup", scopeID: UUID(),
            presentationID: UUID(), phase: .paused, canResume: true)
        allowed = false
        browser.updateTaskControls(controls, handler: { _, _ in XCTFail("Closing the child must not send Resume or Stop") })
        let deadline = ContinuousClock.now + .seconds(5)
        while server.count("/signal") == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.count("/signal"), 1)
        server.releaseHeldResponses()
        while server.count("/ready") == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.count("/ready"), 1)
        let child = try XCTUnwrap(NSApp.windows.first { $0.title == "Sign-in window — AI Browser" })
        XCTAssertTrue(child.isVisible)
        XCTAssertTrue(NSApp.keyWindow === child)
        XCTAssertFalse(child.isRestorable)
        XCTAssertTrue(child.styleMask.contains(.closable))
        XCTAssertTrue(child.styleMask.contains(.resizable))
        XCTAssertTrue(parent.isVisible)
        XCTAssertFalse(browser.hasRequiredPresentation)
        if let screen = child.screen { XCTAssertTrue(screen.visibleFrame.contains(child.frame)) }
        XCTAssertEqual(browser.signInSite, base.absoluteString)
        child.performClose(nil)
        XCTAssertFalse(child.isVisible)
        XCTAssertNil(child.contentView)
        XCTAssertFalse(browser.hasOpenSignInWindow)
        XCTAssertTrue(parent.isVisible)
        XCTAssertEqual(browser.taskID, "visible-popup")
        XCTAssertEqual(browser.taskControls, controls)
        XCTAssertNil(browser.currentDocument(taskID: "visible-popup"))
        allowed = true
        try await browser.reacquireAfterUserControl(taskID: "visible-popup", requirement: requirement)
        XCTAssertEqual(browser.currentDocument(taskID: "visible-popup"), original)
        XCTAssertEqual(server.count("/login"), 1)
    }

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
