import Foundation
import CryptoKit
import AppKit
import WebKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseFaraActionTests: XCTestCase {
    @MainActor
    private func requireSameNativeWindow(_ retained: inout NSWindow?) throws {
        let current = try XCTUnwrap(NSApp.keyWindow)
        if let retained {
            _ = try XCTUnwrap(current === retained ? current : nil,
                "Related native cases must retain one visible window instead of flashing new windows")
        } else { retained = current }
    }

    @MainActor
    func testOptInFaraFindSupportsExactReplacementNoMatchAndNativeClear() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: exact Find editing and query outcomes") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><h1>Reference 123456</h1><p style='margin-top:1500px'>café 🗼 first</p><p style='margin-top:2000px;margin-bottom:1000px'>café 🗼 second</p>")])
        let base = try await server.start(); defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        try browser.claim(taskID: "query")
        let document = try await browser.navigate(taskID: "query", operationID: "fixture", to: base.appendingPathComponent("page"))
        func dispatch(_ action: ComputerUseFaraAction) async throws {
            let observation = try await browser.captureAgentObservation(document: document)
            try await browser.performAgentInput(action, observation: observation)
        }
        try await dispatch(.key(["Control", "F"]))
        @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let views = descendants(try XCTUnwrap(NSApp.keyWindow?.contentView))
        let web = try XCTUnwrap(views.compactMap { $0 as? WKWebView }.first)
        let field = try XCTUnwrap(views.first { $0.identifier?.rawValue == "owned-browser-find-query" } as? NSSearchField)
        try await dispatch(.typeText("café 🗼"))
        XCTAssertEqual(field.stringValue, "café 🗼")
        let first = try await web.evaluateJavaScript("scrollY") as? Double
        try await dispatch(.key(["Control", "G"]))
        let second = try await web.evaluateJavaScript("scrollY") as? Double
        XCTAssertGreaterThan(try XCTUnwrap(second), try XCTUnwrap(first) + 1000)
        try await dispatch(.key(["Control", "Shift", "G"]))
        let previous = try await web.evaluateJavaScript("scrollY") as? Double
        XCTAssertLessThan(try XCTUnwrap(previous), try XCTUnwrap(second) - 1000)
        try await dispatch(.key(["Control", "A"]))
        try await dispatch(.typeText("absent café 🗼"))
        XCTAssertEqual(field.stringValue, "absent café 🗼")
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "No matches" })
        let observation = try await browser.captureAgentObservation(document: document)
        let action = ComputerUseFaraAction.typeText("123456")
        let inspected = try await browser.inspectAgentTarget(action, observation: observation)
        let target = try XCTUnwrap(inspected)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        XCTAssertNil(tools.approvalReason(for: target.action, nativeTarget: target), "Finding a numeric reference in native chrome does not enter credentials into a website")
        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        let rect = cell.cancelButtonRect(forBounds: field.bounds)
        let point = web.convert(NSPoint(x: rect.midX, y: rect.midY), from: field)
        try await dispatch(.pointer(.leftClick, .init(x: point.x / web.bounds.width * 1000, y: (web.isFlipped ? point.y : web.bounds.height - point.y) / web.bounds.height * 1000)))
        XCTAssertEqual(field.stringValue, "", "Clicking the native clear button must clear, not select all")
        XCTAssertEqual(server.count("/page"), 1)
    }

    @MainActor
    func testOptInFaraFindRejectsChangedQuerySelectionFocusLoginAndRetiredAuthority() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: Find input ownership boundaries") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var retainedWindow: NSWindow?
        var allowsActions = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowsActions }); defer { browser.close() }
        for mode in ["query", "selection", "focus", "login", "cancelled", "paused", "owner", "admission-withdrawn", "closed"] {
            allowsActions = true
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><h1>Find fixture</h1><input id='page-field'><p style='margin-top:2000px'>needle</p><script>document.addEventListener('input',()=>fetch('/edit'))</script>")])
            let base = try await server.start(); defer { server.stop() }
            try browser.claim(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "fixture", to: base.appendingPathComponent("page"))
            let first = try await browser.captureAgentObservation(document: document)
            try await browser.performAgentInput(.key(["Command", "F"]), observation: first)
            try requireSameNativeWindow(&retainedWindow)
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let window = try XCTUnwrap(NSApp.keyWindow)
            let views = descendants(try XCTUnwrap(window.contentView))
            let web = try XCTUnwrap(views.compactMap { $0 as? WKWebView }.first)
            let field = try XCTUnwrap(views.first { $0.identifier?.rawValue == "owned-browser-find-query" } as? NSSearchField)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("seed", replacementRange: NSRange(location: NSNotFound, length: 0))
            let observation = try await browser.captureAgentObservation(document: document)
            let action = ComputerUseFaraAction.typeText("needle")
            let inspected = try await browser.inspectAgentTarget(action, observation: observation)
            let target = try XCTUnwrap(inspected)
            switch mode {
            case "query": editor.insertText("changed", replacementRange: NSRange(location: NSNotFound, length: 0))
            case "selection": editor.setSelectedRange(NSRange(location: 0, length: 4))
            case "focus": window.makeFirstResponder(web)
            case "login": _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<input type=password>')")
            case "paused": allowsActions = false; browser.prepareForUserControl(taskID: mode)
            case "owner": try browser.claim(taskID: "successor")
            case "closed": browser.close()
            default: break
            }
            var attempts = 0
            let work = Task { @MainActor in
                if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                try await browser.performAgentInput(action, observation: observation, target: target, willBeginEffect: {
                    attempts += 1
                    if mode == "admission-withdrawn" { allowsActions = false }
                })
            }
            do { try await work.value; XCTFail("Find accepted retired input: \(mode)") }
            catch {
                if mode == "cancelled" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, mode == "login" ? .authenticationRequired : .pageChanged, mode) }
            }
            XCTAssertEqual(attempts, mode == "admission-withdrawn" ? 1 : 0, mode)
            XCTAssertFalse(field.stringValue.contains("needle"), mode)
            XCTAssertEqual(server.count("/edit"), 0, mode)
            if mode == "owner" { XCTAssertEqual(browser.taskID, "successor") }
        }
    }

    @MainActor
    func testOptInFaraFindsPageTextWithVisibleQueryAndReturnsToPage() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: visible native Find in Page workflow") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <!doctype html><style>body{font:24px system-ui}section{margin-top:1500px;height:1200px}</style>
            <h1>Local movie listings</h1><input id='page-input' aria-label='Page input'>
            <section>September 17 — Little Roxie, 6:20 PM</section>
            <script>document.addEventListener('input',()=>fetch('/page-edit'));document.addEventListener('keydown',()=>fetch('/page-key'));</script>
            """)])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraFind-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        try browser.claim(taskID: "find")
        _ = try await browser.navigate(taskID: "find", operationID: "fixture", to: base.appendingPathComponent("page"))
        let actions = [#"{"action":"key","keys":["Control","f"]}"#, #"{"action":"type","text":"September 17"}"#,
            #"{"action":"key","keys":["Return"]}"#, #"{"action":"key","keys":["Shift","Return"]}"#,
            #"{"action":"key","keys":["Escape"]}"#, #"{"action":"terminate","answer":"September 17 — Little Roxie, 6:20 PM"}"#]
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard calls < actions.count else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let views = try XCTUnwrap(NSApp.keyWindow?.contentView).subviews.flatMap { descendants($0) }
            if calls > 0 && calls < 5 {
                let field = try XCTUnwrap(views.first { $0.identifier?.rawValue == "owned-browser-find-query" } as? NSSearchField)
                XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
                XCTAssertNotNil(field.currentEditor())
                XCTAssertEqual(field.stringValue, calls == 1 ? "" : "September 17")
            }
            if calls >= 2 {
                let web = try XCTUnwrap(views.compactMap { $0 as? WKWebView }.first)
                let scroll = try await web.evaluateJavaScript("scrollY")
                XCTAssertGreaterThan(try XCTUnwrap(scroll as? Double), 1000)
                let value = try await web.evaluateJavaScript("document.getElementById('page-input').value")
                XCTAssertEqual(value as? String, "")
            }
            if calls == 2 {
                let attachment = XCTAttachment(data: input.screenshotPNG, uniformTypeIdentifier: "public.png")
                attachment.name = "Model sees native Find query and matching page"; attachment.lifetime = .keepAlways; self.add(attachment)
            }
            if calls == 5 { XCTAssertFalse(views.contains { $0.identifier?.rawValue == "owned-browser-find-query" && !$0.isHiddenOrHasHiddenAncestor }) }
            let response = self.call(actions[calls]); calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            let result = try await executor.execute(taskID: "find", prompt: "Find September 17 in this page, inspect its result, then close Find.", trustedUserPrompt: "Find September 17 in this page, inspect its result, then close Find.", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("September 17 — Little Roxie, 6:20 PM"))
            let replay = try await executor.execute(taskID: "find", prompt: "Find September 17 in this page, inspect its result, then close Find.", trustedUserPrompt: "Find September 17 in this page, inspect its result, then close Find.", tools: tools, progress: { _ in })
            XCTAssertEqual(replay, result)
        } catch { return XCTFail("Find failed after \(calls) proposals: \(String(reflecting: error))") }
        XCTAssertEqual(calls, actions.count); XCTAssertEqual(server.count("/page"), 1)
        XCTAssertEqual(server.count("/page-edit"), 0); XCTAssertEqual(server.count("/page-key"), 0)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(records.filter { $0.stepIDs == ["native-dispatch-returned"] && $0.statuses == [.verified] }.count, 5)
    }

    @MainActor
    func testOptInPublicWebKitTextFinderShowsFindBarAndFindsVisibleResult() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: one public AppKit/WebKit find experiment") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let finder = NSTextFinder(); finder.client = view; finder.findBarContainer = scroll
        finder.isIncrementalSearchingEnabled = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Local Find in Page Experiment"; window.contentView = scroll
        defer { finder.performAction(.hideFindInterface); finder.client = nil; finder.findBarContainer = nil; view.stopLoading(); window.close() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        view.loadHTMLString("<!doctype html><style>body{font:24px system-ui}section{margin-top:1800px;height:1000px}</style><h1>Local movie listings</h1><section>September 17, 2026: Little Roxie, 6:20 PM</section>", baseURL: nil)
        var ready = false
        let loadDeadline = ContinuousClock.now + .seconds(5)
        while !ready && ContinuousClock.now < loadDeadline {
            ready = (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('section')")) as? Bool == true
            if !ready { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(finder.validateAction(.showFindInterface))
        finder.performAction(.showFindInterface)
        let deadline = ContinuousClock.now + .seconds(5)
        while !scroll.isFindBarVisible && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(scroll.isFindBarVisible)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "Find should focus its native text editor")
        editor.selectAll(nil); editor.insertText("September 17", replacementRange: NSRange(location: NSNotFound, length: 0))
        let findResult = try await view.find("September 17", configuration: WKFindConfiguration())
        XCTAssertTrue(findResult.matchFound)
        var found = false
        while !found && ContinuousClock.now < deadline {
            found = (try? await view.evaluateJavaScript("scrollY > 1000")) as? Bool == true
            if !found { try await Task.sleep(for: .milliseconds(25)) }
        }
        let selection = try await view.evaluateJavaScript("JSON.stringify({scrollY,selection:window.getSelection().toString()})")
        let state = XCTAttachment(string: "findBarVisible=\(scroll.isFindBarVisible), barFrame=\(String(describing: scroll.findBarView?.frame)), webFrame=\(view.frame), result=\(selection)")
        state.name = "Public NSTextFinder experiment state"; state.lifetime = .keepAlways; add(state)
        let webImage = try await view.takeSnapshot(configuration: nil)
        let webAttachment = XCTAttachment(image: webImage); webAttachment.name = "WebKit snapshot with native find interface open"; webAttachment.lifetime = .keepAlways; add(webAttachment)
        if let bar = scroll.findBarView, let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let barAttachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                barAttachment.name = "Native find bar pixels"; barAttachment.lifetime = .keepAlways; add(barAttachment)
            }
        }
        XCTAssertTrue(found, "Public WebKit find must reveal the requested text")
    }

    @MainActor
    func testOptInFaraNewContextLinkCannotLeaveAllowedSources() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: source admission for observed new-context links") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let blocked = try OwnedBrowserHTTPFixture(), destination = try await blocked.start(); defer { blocked.stop() }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><a href='\(destination.absoluteString)/details' target='_blank' style='position:fixed;left:10vw;top:10vh;width:20vw;height:10vh'>Buy Tickets</a>")])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLinkSource-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        let goal = "Read the screening details."
        let session = try browser.prepareWorkflowSession(taskID: "source")
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: "source", prompt: goal, referenceDate: Date(), timeZoneIdentifier: "UTC"), allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: "source", operationID: "fixture", to: base.appendingPathComponent("page"))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            calls += 1
            guard calls == 1 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            let response = self.call(#"{"action":"left_click","coordinate":[200,150]}"#)
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            _ = try await executor.execute(taskID: "source", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTFail("New-context link navigation bypassed the source restriction")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(blocked.requestCount, 0); XCTAssertEqual(server.count("/page"), 1)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertFalse(records.contains { $0.stepIDs == ["native-dispatch-returned"] })
    }

    @MainActor
    func testOptInFaraNavigationKeepsPurchaseControlsAndUnsupportedLinksGated() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: navigation classification is not purchase authorization") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for markup in [
            "<button onclick=\"fetch('/selected')\">Buy Tickets</button>",
            "<a href='/details'>Buy Tickets</a>",
            "<a href='/details' target='_blank' role='button'>Buy Tickets</a>",
            "<a href='/details' target='_blank' download>Buy Tickets</a>",
            "<a href='/details' target='_blank' ping='/selected'>Buy Tickets</a>",
            "<a href='/details' target='account'>Buy Tickets</a>",
            "<a href='#'>Buy Tickets</a>",
            "<a href='#missing'>Buy Tickets</a>",
            "<a href='#hidden'>Buy Tickets</a><section id='hidden' hidden>Details</section>"
        ] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><style>a,button{position:fixed;left:10vw;top:10vh;width:20vw;height:10vh;font:24px system-ui}</style>" + markup)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraTicketGate-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("browser"))
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
            try browser.claim(taskID: "gate")
            _ = try await browser.navigate(taskID: "gate", operationID: "fixture", to: base.appendingPathComponent("page"))
            let observation = try await navigation.captureAgentObservation(taskID: "gate")
            let inspected = try await browser.inspectAgentTarget(.pointer(.leftClick, .init(x: 200, y: 150)), observation: observation)
            let target = try XCTUnwrap(inspected)
            XCTAssertNil(target.navigation, markup)
            XCTAssertNotNil(tools.approvalReason(for: target.action, nativeTarget: target), markup)
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
                calls += 1
                guard calls == 1 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let response = self.call(#"{"action":"left_click","coordinate":[200,150]}"#)
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            let result = try await executor.execute(taskID: "gate", prompt: "Read the screening details.", trustedUserPrompt: "Read the screening details.", tools: tools, progress: { _ in })
            guard case .approvalRequired = result else { return XCTFail("Purchase control lost its approval gate: \(markup): \(result)") }
            XCTAssertEqual(calls, 1); XCTAssertEqual(server.count("/page"), 1); XCTAssertEqual(server.count("/details"), 0); XCTAssertEqual(server.count("/selected"), 0)
        }
    }

    @MainActor
    func testOptInFaraLinkNavigationRejectsChangedTargetsCancellationAndReusedInput() async throws {
        try await runRetiredLinkNavigation(kind: .leftClick)
    }

    @MainActor
    func testOptInFaraDoubleClickRejectsChangedLinksCancellationAndReusedInput() async throws {
        try await runRetiredLinkNavigation(kind: .doubleClick)
    }

    @MainActor
    private func runRetiredLinkNavigation(kind: ComputerUseFaraAction.PointerKind) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native link navigation lifetime") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var retainedWindow: NSWindow?
        var allowsActions = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowsActions }); defer { browser.close() }
        for mode in ["href", "target", "role", "fragment-replaced", "fragment-reinserted", "cancelled", "paused", "owner"] {
            allowsActions = true
            let fragment = mode.hasPrefix("fragment")
            let changes = ["href":"link.href='/changed'", "target":"link.target='account'", "role":"link.role='button'",
                "fragment-replaced":"section.replaceWith(section.cloneNode(true))", "fragment-reinserted":"section.remove();document.body.append(section)"]
            let mutation = changes[mode].map { "fetch('/release').then(()=>{const link=document.getElementById('link'),section=document.getElementById('showtimes');\($0);fetch('/changed')})" } ?? ""
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>body{margin:0}a{position:absolute;left:10vw;top:10vh;width:20vw;height:10vh;display:block;font:24px system-ui}section{margin-top:150vh;height:100vh}</style>
                <a id='link' href='\(fragment ? "#showtimes" : "/details")' target='\(fragment ? "_self" : "_blank")' onclick="fetch('/selected')">Buy Tickets</a><section id='showtimes'>Details</section>
                <script>\(mutation)</script>
                """), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            try browser.claim(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "fixture", to: base.appendingPathComponent("page"))
            try requireSameNativeWindow(&retainedWindow)
            let observation = try await browser.captureAgentObservation(document: document)
            let action = ComputerUseFaraAction.pointer(kind, .init(x: 200, y: 150))
            let inspected = try await browser.inspectAgentTarget(action, observation: observation)
            let target = try XCTUnwrap(inspected)
            XCTAssertNotNil(target.navigation)
            if changes[mode] != nil {
                let deadline = ContinuousClock.now + .seconds(2)
                while server.count("/release") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                server.releaseHeldResponses()
                while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(server.count("/changed"), 1)
            }
            if mode == "paused" { allowsActions = false }
            if mode == "owner" { try browser.claim(taskID: "successor") }
            var effects = 0
            let work = Task { @MainActor in
                try await browser.performAgentInput(action, observation: observation,
                    operationID: ComputerUseTaskContract.digest([mode, "input"]), target: target, willBeginEffect: { effects += 1 })
            }
            if mode == "cancelled" { work.cancel() }
            do { try await work.value; XCTFail("Retired link dispatched: \(mode)") }
            catch { if mode == "cancelled" { XCTAssertTrue(error is CancellationError) } }
            do {
                try await browser.performAgentInput(action, observation: observation,
                    operationID: ComputerUseTaskContract.digest([mode, "replay"]), target: target, willBeginEffect: { effects += 1 })
                XCTFail("Rejected input was reused: \(mode)")
            } catch { }
            XCTAssertEqual(effects, 0, mode); XCTAssertEqual(server.count("/details"), 0); XCTAssertEqual(server.count("/selected"), 0)
            if mode == "owner" { XCTAssertEqual(browser.taskID, "successor") }
        }
    }

    @MainActor
    func testOptInFaraRevealsShowtimesAndOpensTicketDetailsWithoutActivatingPurchaseHandlers() async throws {
        try await runObservedTicketLink(action: "left_click")
    }

    @MainActor
    func testOptInFaraDoubleClickFollowsObservedLinkOnce() async throws {
        try await runObservedTicketLink(action: "double_click")
    }

    @MainActor
    func testOptInFaraDoubleClickCannotActivatePurchaseControlsOrUnsupportedLinks() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: double click only dispatches proven navigation") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var retainedWindow: NSWindow?
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        for (index, markup) in ["<button>Buy Tickets</button>", "<a href='/details'>Buy Tickets</a>",
                       "<a href='/details' target='_blank' role='button'>Buy Tickets</a>",
                       "<a href='/details' target='_blank' download>Buy Tickets</a>",
                       "<a href='/details' target='_blank' ping='/selected'>Buy Tickets</a>",
                       "<a href='#missing'>Buy Tickets</a>"].enumerated() {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><style>a,button{position:fixed;left:10vw;top:10vh;width:20vw;height:10vh}</style>" + markup + "<script>document.addEventListener('click',()=>fetch('/selected'));document.addEventListener('dblclick',()=>fetch('/selected'))</script>")])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraDoubleClickGate-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            let taskID = "gate-\(index)"
            try browser.claim(taskID: taskID)
            _ = try await browser.navigate(taskID: taskID, operationID: "fixture", to: base.appendingPathComponent("page"))
            try requireSameNativeWindow(&retainedWindow)
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
                calls += 1
                guard calls == 1 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let response = self.call(#"{"action":"double_click","coordinate":[200,150]}"#)
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            do {
                _ = try await executor.execute(taskID: taskID, prompt: "Read the screening details.", trustedUserPrompt: "Read the screening details.", tools: tools, progress: { _ in })
                XCTFail("Double click activated an unsupported control: \(markup)")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .unsupportedDocument, markup) }
            XCTAssertEqual(calls, 1); XCTAssertEqual(server.count("/page"), 1)
            XCTAssertEqual(server.count("/details"), 0); XCTAssertEqual(server.count("/selected"), 0)
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertFalse(records.contains { $0.stepIDs == ["native-dispatch-returned"] })
        }
    }

    @MainActor
    private func runObservedTicketLink(action: String) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: observed fragment and new-context link navigation") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var retainedWindow: NSWindow?
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        for fragment in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>body{margin:0}a{position:absolute;left:10vw;top:10vh;width:20vw;height:10vh;display:block;font:24px system-ui}section{margin-top:150vh;height:100vh}</style>
                <a href='\(fragment ? "#showtimes" : "/details")' target='\(fragment ? "_self" : "_blank")' onclick="fetch('/selected')">Buy Tickets</a>
                <section id='showtimes'><h1>Screening details</h1><p>Thursday, 6:20 PM. Stop before selecting tickets.</p></section>
                """)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraTicketNavigation-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            let taskID = "ticket-navigation-\(fragment)", goal = "Read the screening details. Stop before selecting tickets or purchasing."
            try browser.claim(taskID: taskID)
            _ = try await browser.navigate(taskID: taskID, operationID: "fixture", to: base.appendingPathComponent("page"))
            try requireSameNativeWindow(&retainedWindow)
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
                guard calls < 2 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                XCTAssertEqual(input.goal, goal); XCTAssertEqual(input.history.count, calls)
                if calls == 1 {
                    XCTAssertEqual(input.currentURL, base.appendingPathComponent(fragment ? "page" : "details"))
                    XCTAssertEqual(server.count("/selected"), 0, "Navigation must not invoke link click handlers")
                    XCTAssertFalse(browser.hasOpenSignInWindow)
                    if fragment {
                        func webViews(_ view: NSView) -> [WKWebView] { if let web = view as? WKWebView { return [web] }; return view.subviews.flatMap(webViews) }
                        let view = try XCTUnwrap(NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
                        let revealed = try await view.evaluateJavaScript("scrollY > 500 && Math.abs(document.getElementById('showtimes').getBoundingClientRect().top) < 2 && location.hash === ''")
                        XCTAssertEqual(revealed as? Bool, true, "The existing section must be revealed without routing or activating the link")
                    }
                }
                let response = self.call(calls == 0 ? "{\"action\":\"\(action)\",\"coordinate\":[200,150]}" : #"{"action":"terminate","answer":"Screening details are visible."}"#)
                calls += 1
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            let result: ComputerUseExecutionResult
            do { result = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
            catch { return XCTFail("Observed \(action) failed: \(String(reflecting: error))") }
            guard result == .completed("Screening details are visible.") else { return XCTFail("Observed ticket navigation stopped as \(result), fragment=\(fragment)") }
            let replay = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(replay, result); XCTAssertEqual(calls, 2)
            XCTAssertEqual(server.count("/page"), 1); XCTAssertEqual(server.count("/details"), fragment ? 0 : 1); XCTAssertEqual(server.count("/selected"), 0)
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            let dispatches = records.filter { $0.stepIDs == ["native-dispatch-returned"] }
            XCTAssertEqual(dispatches.count, 1); XCTAssertEqual(dispatches.first?.statuses, [.verified])
        }
    }

    func testFaraActionFailureWirePreservesObservationHistoryAndBoundsText() throws {
        let png = try smallPNG(), source = URL(string: "https://example.com/start")!
        let failure = "visit_url to https://blocked.example/ failed: BrowserSourcePolicy: The destination is not permitted for this task."
        let rejected = call(#"{"action":"visit_url","url":"https://blocked.example/"}"#)
        let wait = call(#"{"action":"wait","time":0}"#)
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        func messages(_ input: ComputerUseFaraModel.Input) throws -> [[String: Any]] {
            let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            return try XCTUnwrap(body["messages"] as? [[String: Any]])
        }
        var input = ComputerUseFaraModel.Input(goal: "Find the details.", screenshotPNG: png,
            history: [.init(screenshotPNG: png, response: rejected, currentURL: source)], currentURL: source, actionError: failure)
        let fresh = try messages(input)
        let content = try XCTUnwrap(fresh.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["text"] as? String, "Current URL: \(source.absoluteString)\n\(failure)\nHere is the next screenshot. Think about what to do next.")
        XCTAssertEqual(fresh[fresh.count - 2]["content"] as? String, rejected)
        input.history.append(.init(screenshotPNG: png, response: wait, currentURL: source, actionError: failure))
        input.actionError = nil
        for _ in 0..<3 { input.history.append(.init(screenshotPNG: png, response: wait, currentURL: source)) }
        let aged = try messages(input)
        let observations = aged.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? [[String: Any]] }
        XCTAssertEqual(observations.flatMap { $0 }.filter { ($0["text"] as? String)?.contains(failure) == true }.count, 1)
        XCTAssertFalse(observations.last!.contains { ($0["text"] as? String)?.contains(failure) == true })
        XCTAssertEqual(observations.flatMap { $0 }.filter { $0["type"] as? String == "image_url" }.count, 3)
        for value in [" \n", String(repeating: "é", count: 8_193)] {
            var invalid = input; invalid.actionError = value
            XCTAssertThrowsError(try messages(invalid))
            invalid = input; invalid.history[0].actionError = value
            XCTAssertThrowsError(try messages(invalid))
        }
        var oversized = input
        oversized.history = (0..<5).map { _ in .init(screenshotPNG: png, response: wait, actionError: String(repeating: "x", count: 16_384)) }
        XCTAssertThrowsError(try messages(oversized), "All retained failure text must count toward the aggregate context budget")
    }

    @MainActor
    func testOptInFaraReportsUndispatchedURLRejectionAndContinuesOriginalTask() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: rejected native navigation feedback") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for initiallyBlank in [true, false] {
            let server = try OwnedBrowserHTTPFixture(), base = try await server.start(); defer { server.stop() }
            let blockedServer = try OwnedBrowserHTTPFixture(), blockedBase = try await blockedServer.start(); defer { blockedServer.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraRejectedURL-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            let taskID = "rejected-url", goal = "Find the requested details on the allowed source."
            let session = try browser.prepareWorkflowSession(taskID: taskID)
            let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: taskID, prompt: goal, referenceDate: Date(), timeZoneIdentifier: "UTC"), allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
            try browser.installSourcePolicy(policy, replacing: nil, session: session)
            if !initiallyBlank { _ = try await browser.navigate(taskID: taskID, operationID: "fixture", to: base.appendingPathComponent("start")) }
            let blocked = blockedBase.appendingPathComponent("blocked"), allowed = base.appendingPathComponent("details")
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
                guard calls < 3 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                XCTAssertEqual(input.goal, goal); XCTAssertEqual(input.history.count, calls)
                if calls == 1 {
                    XCTAssertNotNil(input.actionError)
                    XCTAssertEqual(input.currentURL, initiallyBlank ? nil : base.appendingPathComponent("start"))
                    XCTAssertTrue(input.history.last?.response.contains(blocked.absoluteString) == true)
                    let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                    let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
                    let text = try XCTUnwrap(content.last?["text"] as? String)
                    XCTAssertTrue(text.contains("visit_url to \(blocked.absoluteString) failed:"))
                    XCTAssertTrue(text.contains("not permitted")); XCTAssertTrue(text.contains("Here is the next screenshot."))
                    XCTAssertEqual(blockedServer.requestCount, 0)
                }
                if calls == 2 {
                    XCTAssertNil(input.actionError, "A successful next action consumes the failure prefix")
                    XCTAssertNotNil(input.history.last?.actionError, "The next action retains its actual failure-bearing observation")
                }
                let args = calls == 0 ? "{\"action\":\"visit_url\",\"url\":\"\(blocked.absoluteString)\"}"
                    : calls == 1 ? "{\"action\":\"visit_url\",\"url\":\"\(allowed.absoluteString)\"}" : #"{"action":"terminate","answer":"Found the details."}"#
                calls += 1
                let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + args + "}</tool_call>"
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            do {
                let result = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(result, .completed("Found the details."))
                let replay = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(replay, result)
            } catch {
                let windows = NSApp.windows.map { "\($0.title): visible=\($0.isVisible), key=\($0.isKeyWindow), mini=\($0.isMiniaturized)" }
                let focus = "active=\(NSApp.isActive), frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), ownPID=\(ProcessInfo.processInfo.processIdentifier), windows=\(windows)"
                let attachment = XCTAttachment(string: focus); attachment.name = "Native test focus diagnostic"; attachment.lifetime = .keepAlways; self.add(attachment)
                return XCTFail("Rejected URL aborted the original task after \(calls) proposals, initiallyBlank=\(initiallyBlank): \(error); \(focus)")
            }
            XCTAssertEqual(calls, 3); XCTAssertEqual(blockedServer.requestCount, 0); XCTAssertEqual(server.count("/details"), 1)
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            let dispatches = records.filter { $0.stepIDs == ["native-dispatch-returned"] }
            XCTAssertEqual(dispatches.count, 1); XCTAssertEqual(dispatches.first?.statuses, [.verified])
        }
    }

    @MainActor
    func testOptInFaraRejectedRedirectRemainsUncertainWithoutRetry() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: rejected post-dispatch redirect") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for initiallyBlank in [true, false] {
            let blockedServer = try OwnedBrowserHTTPFixture(), blockedBase = try await blockedServer.start(); defer { blockedServer.stop() }
            let server = try OwnedBrowserHTTPFixture(routes: ["/redirect": .init(status: 302, location: blockedBase.appendingPathComponent("blocked").absoluteString)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraRejectedRedirect-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            let taskID = "redirect", goal = "Find the requested details."
            let session = try browser.prepareWorkflowSession(taskID: taskID)
            let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: taskID, prompt: goal, referenceDate: Date(), timeZoneIdentifier: "UTC"), allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
            try browser.installSourcePolicy(policy, replacing: nil, session: session)
            if !initiallyBlank { _ = try await browser.navigate(taskID: taskID, operationID: "fixture", to: base.appendingPathComponent("start")) }
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
                calls += 1
                guard calls == 1 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let response = self.call("{\"action\":\"visit_url\",\"url\":\"\(base.appendingPathComponent("redirect").absoluteString)\"}")
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            do {
                _ = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTFail("A rejected redirect after native dispatch cannot resume model planning")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
            let replay = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            guard case .unableToComplete = replay else { return XCTFail("Dispatched navigation must remain uncertain") }
            XCTAssertEqual(calls, 1); XCTAssertEqual(server.count("/redirect"), 1); XCTAssertEqual(blockedServer.requestCount, 0)
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            let dispatches = records.filter { $0.stepIDs == ["native-dispatch-returned"] }
            XCTAssertEqual(dispatches.count, 1); XCTAssertEqual(dispatches.first?.statuses, [.uncertain])
        }
    }

    @MainActor
    func testOptInFaraDoesNotRecoverRejectedURLAfterAuthorityWithdrawal() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: rejected URL cannot regain withdrawn authority") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["paused", "changed-owner", "revoked-source"] {
            let server = try OwnedBrowserHTTPFixture(), base = try await server.start(); defer { server.stop() }
            let blockedServer = try OwnedBrowserHTTPFixture(), blockedBase = try await blockedServer.start(); defer { blockedServer.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraRejectedAuthority-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var allowsActions = true
            let browser = ComputerUseOwnedBrowser(mayAct: { allowsActions }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowsActions }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            let goal = "Find the requested details."
            let session = try browser.prepareWorkflowSession(taskID: mode)
            let researchGoal = try ComputerUseBrowserGoalInput(taskID: mode, prompt: goal, referenceDate: Date(), timeZoneIdentifier: "UTC")
            let policy = try ComputerUseBrowserSourcePolicy(goal: researchGoal, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
            try browser.installSourcePolicy(policy, replacing: nil, session: session)
            _ = try await browser.navigate(taskID: mode, operationID: "fixture", to: base.appendingPathComponent("start"))
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
                calls += 1
                guard calls == 1 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                if mode == "paused" { allowsActions = false }
                if mode == "changed-owner" { try browser.claim(taskID: "successor") }
                if mode == "revoked-source" { try browser.installSourcePolicy(.init(goal: researchGoal, allowedOrigins: []), replacing: policy.digest, session: session) }
                let response = self.call("{\"action\":\"visit_url\",\"url\":\"\(blockedBase.appendingPathComponent("blocked").absoluteString)\"}")
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            do {
                _ = try await executor.execute(taskID: mode, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTFail("Withdrawn authority cannot become a recoverable URL rejection")
            } catch {
                if mode == "paused" { XCTAssertEqual(error as? ComputerUseHostTools.ToolError, .paused) }
                else if mode == "revoked-source" { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
                else { XCTAssertNotNil(error as? ComputerUseBrowserError) }
            }
            XCTAssertEqual(calls, 1); XCTAssertEqual(blockedServer.requestCount, 0); XCTAssertEqual(server.count("/start"), 1)
            if mode == "changed-owner" { XCTAssertEqual(browser.taskID, "successor") }
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertFalse(records.contains { $0.stepIDs == ["native-dispatch-returned"] })
        }
    }

    @MainActor
    func testOptInFaraQuestionLimitAndStaleControlsPreserveLatestAnswerOwner() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: successive Fara answer ownership and turn limit") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraAnswerOwnership-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowsActions = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowsActions }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowsActions }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            calls += 1
            guard calls <= 4 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"ask_user_question\",\"question\":\"Question \(calls)?\"}}</tool_call>"
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        _ = try await executor.execute(taskID: "root", prompt: "Find tickets.", trustedUserPrompt: "Find tickets.", tools: tools, progress: { _ in })
        var origin = "root"
        for index in 1...2 {
            let question = try XCTUnwrap(executor.clarification(taskID: origin))
            let goal = try question.goal.answering(question.question, with: "Answer \(index)")
            _ = try await executor.continueClarification(taskID: "answer\(index)", originatingTaskID: origin, goal: goal, progress: { _ in })
            origin = "answer\(index)"
        }
        let retained = try XCTUnwrap(executor.clarification(taskID: "answer2"))
        XCTAssertEqual(retained.goal.userTurns, ["Find tickets.", "Answer 1", "Answer 2"])
        XCTAssertEqual(tools.ownedBrowserTaskID(forExecution: "answer2"), "root")
        XCTAssertEqual(tools.ownedBrowserTaskID(forExecution: "answer1"), "answer1")
        let captured = try await browser.captureInitialAgentObservation(taskID: "root", expectedSessionIdentity: nil)
        let observation = try XCTUnwrap(captured)
        for stale in ["root", "answer1", "unrelated"] {
            executor.invalidateClarification(taskID: stale)
            allowsActions = false
            tools.pauseOwnedBrowserForUserControl(taskID: stale)
            tools.stopOwnedBrowserActivity(taskID: stale)
            allowsActions = true
            XCTAssertNoThrow(try browser.validateInitialAgentObservation(observation), "A stale Pause must not retire the current answer's observation")
            XCTAssertEqual(browser.taskID, "root")
            XCTAssertEqual(try executor.clarification(taskID: "answer2")?.question, retained.question)
        }
        let finalGoal = try retained.goal.answering(retained.question, with: "Answer 3")
        do {
            _ = try await executor.continueClarification(taskID: "answer3", originatingTaskID: "answer2", goal: finalGoal, progress: { _ in })
            XCTFail("A fourth question would exceed the retained user-turn limit")
        } catch { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .invalidQuestion) }
        XCTAssertEqual(calls, 4); XCTAssertNil(try executor.clarification(taskID: "answer3"))
        tools.stopOwnedBrowserActivity(taskID: "answer2"); XCTAssertEqual(browser.taskID, "root")
        tools.stopOwnedBrowserActivity(taskID: "answer3"); XCTAssertNil(browser.taskID)
    }

    @MainActor
    func testOptInFaraDoesNotAskQuestionWithoutBudgetToReadTheAnswer() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: cumulative Fara question budget") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraQuestionLimit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            guard calls < 64 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            let args = calls == 63 ? #"{"action":"ask_user_question","question":"Which city?"}"# : #"{"action":"wait","time":0}"#
            calls += 1
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + args + "}</tool_call>"
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            _ = try await executor.execute(taskID: "limit", prompt: "Find tickets.", trustedUserPrompt: "Find tickets.", tools: tools, progress: { _ in })
            XCTFail("The last allowed turn must not publish an unanswerable question")
        } catch { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .stepLimit) }
        XCTAssertEqual(calls, 64); XCTAssertNil(try executor.clarification(taskID: "limit"))
    }

    @MainActor
    func testOptInFaraQuestionRejectsExpiredChangedCancelledAndMismatchedAnswers() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: retained question boundaries") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["expired", "changed-browser", "cancelled", "invalidated", "wrong-goal", "wrong-question", "wrong-origin", "blank-answer", "oversized-answer"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraQuestionBoundary-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            var calls = 0, now = Date(timeIntervalSince1970: 1_800_000_000)
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
                calls += 1
                guard calls == 1 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"ask_user_question","question":"Which city?"}}</tool_call>"#
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            }, now: { now })
            let result = try await executor.execute(taskID: mode, prompt: "Find tickets.", trustedUserPrompt: "Find tickets.", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .clarificationRequired("Which city?"))
            let pending = try XCTUnwrap(executor.clarification(taskID: mode))
            let answer = mode == "blank-answer" ? " \n " : mode == "oversized-answer" ? "x" + String(repeating: "\u{301}", count: 4_100) : "Kyoto"
            let original = mode == "wrong-goal" ? try ComputerUseUnresolvedTextGoal(userRequest: "A different task") : pending.goal
            let goal = try original.answering(mode == "wrong-question" ? "A different question?" : pending.question, with: answer)
            if mode == "expired" { now.addTimeInterval(601) }
            if mode == "changed-browser" { try browser.claim(taskID: "successor") }
            if mode == "invalidated" { executor.invalidateClarification(taskID: mode) }
            let work = Task { @MainActor in
                if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                return try await executor.continueClarification(taskID: "answer", originatingTaskID: mode == "wrong-origin" ? "another-root" : mode,
                    goal: goal, progress: { _ in })
            }
            do { _ = try await work.value; XCTFail("Invalid answer was accepted: \(mode)") }
            catch {
                if mode == "cancelled" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .invalidQuestion, mode) }
            }
            XCTAssertEqual(calls, 1, mode)
            XCTAssertEqual(browser.taskID, mode == "changed-browser" ? "successor" : mode)
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.stepIDs, ["model-assessed-completion"])
        }
    }

    @MainActor
    func testOptInFaraKeepsQuestionAndExactAnswerWhenHistoryAndImagesAgeOut() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: bounded Fara answer history") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraAnswerHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        let original = "Find tickets after asking for the destination.", answer = "  Kyoto e\u{301} 😀\n  "
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            XCTAssertEqual(input.goal, original); XCTAssertLessThanOrEqual(input.history.count, 20)
            guard calls <= 25 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            if calls == 1 { XCTAssertTrue(input.userResponse?.utf8.elementsEqual(answer.utf8) == true) }
            if calls == 25 {
                XCTAssertNil(input.userResponse)
                XCTAssertEqual(input.history.count, 20)
                XCTAssertEqual(input.history.filter { $0.userResponse != nil }.count, 1)
                XCTAssertTrue(input.history.contains { $0.response.contains("Which city?") })
                let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let matching = messages.filter { message in
                    guard message["role"] as? String == "user", let content = message["content"] as? [[String: Any]] else { return false }
                    return content.contains { ($0["text"] as? String)?.utf8.elementsEqual(answer.utf8) == true }
                }
                XCTAssertEqual(matching.count, 1, "The old answer remains exact text after image and ordinary-history eviction")
                XCTAssertFalse((matching.first?["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image_url" })
            }
            let args = calls == 0 ? #"{"action":"ask_user_question","question":"Which city?"}"#
                : calls == 25 ? #"{"action":"ask_user_question","question":"Any other constraints?"}"# : #"{"action":"wait","time":0}"#
            calls += 1
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + args + "}</tool_call>"
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        _ = try await executor.execute(taskID: "history", prompt: original, trustedUserPrompt: original, tools: tools, progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "history"))
        let goal = try pending.goal.answering(pending.question, with: answer)
        let result = try await executor.continueClarification(taskID: "answer", originatingTaskID: "history", goal: goal, progress: { _ in })
        XCTAssertEqual(result, .clarificationRequired("Any other constraints?")); XCTAssertEqual(calls, 26)
        XCTAssertEqual(try executor.clarification(taskID: "answer")?.goal, goal)
        let replay = try await executor.continueClarification(taskID: "answer", originatingTaskID: "history", goal: goal, progress: { _ in })
        XCTAssertEqual(replay, result); XCTAssertEqual(calls, 26)
        do { _ = try await executor.continueClarification(taskID: "another-answer", originatingTaskID: "history", goal: goal, progress: { _ in }); XCTFail("Consumed question accepted a second answer") }
        catch { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .invalidQuestion) }
    }

    @MainActor
    func testOptInFaraTabRejectsStaleFocusLoginAndRetiredControl() async throws {
        try await runTabBoundaries(modes: ["focus-changed", "login", "cancelled", "revoked", "replacement", "admission-revoked", "unsupported-modifier"])
    }

    @MainActor
    func testOptInNativeMarkedTextPreconditionForFaraTab() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_MARKED_TEXT_PROBE"] == "1" else { throw XCTSkip("Unqualified native experiment: establish actual WebKit marked text before testing focus-key rejection") }
        try await runTabBoundaries(modes: ["composition"])
    }

    @MainActor
    private func runTabBoundaries(modes: [String]) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native focus-key boundaries") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in modes {
            let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
                <!doctype html><label>Origin<input id='origin'></label><label>Destination<input id='destination'></label>
                <script>document.addEventListener('keydown',()=>fetch('/key',{keepalive:true}));requestAnimationFrame(()=>{document.getElementById('origin').focus();fetch('/ready')});</script>
                """)])
            let base = try await server.start(); defer { server.stop() }
            var allowed = true, attempts = 0
            let browser = ComputerUseOwnedBrowser(mayAct: { allowed }); defer { browser.close() }
            try browser.claim(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("form"))
            let deadline = ContinuousClock.now + .seconds(2)
            while server.count("/ready") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/ready"), 1, mode)
            // The experiment only operates on this test's native owned view.
            func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            let initial = try await browser.captureAgentObservation(document: document)
            let window = try XCTUnwrap(NSApp.keyWindow)
            let view = try XCTUnwrap(window.contentView.flatMap { webViews($0).first })
            if mode == "composition" {
                let coordinates = try await view.evaluateJavaScript("(()=>{const r=document.getElementById('origin').getBoundingClientRect();return [(r.x+r.width/2)/innerWidth*1000,(r.y+r.height/2)/innerHeight*1000]})()")
                let point = try XCTUnwrap(coordinates as? [Double])
                try await browser.performAgentInput(.pointer(.leftClick, .init(x: point[0], y: point[1])), observation: initial)
                let client = try XCTUnwrap(window.firstResponder as? any NSTextInputClient)
                client.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let compositionDeadline = ContinuousClock.now + .seconds(1)
                while !client.hasMarkedText() && ContinuousClock.now < compositionDeadline { try await Task.sleep(for: .milliseconds(10)) }
                guard client.hasMarkedText() else { return XCTFail("Native composition fixture did not establish marked text") }
            }
            let observation = try await browser.captureAgentObservation(document: document)
            switch mode {
            case "focus-changed": _ = try await view.evaluateJavaScript("document.getElementById('destination').focus()")
            case "login": _ = try await view.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<input type=password>')")
            case "revoked": allowed = false
            case "replacement": try browser.claim(taskID: "successor")
            default: break
            }
            let keys = mode == "unsupported-modifier" ? ["Control", "Tab"] : ["Shift", "Tab"]
            let work = Task { @MainActor in
                if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                try await browser.performAgentInput(.key(keys), observation: observation, willBeginEffect: {
                    attempts += 1
                    if mode == "admission-revoked" { allowed = false }
                })
            }
            do { try await work.value; XCTFail("Rejected focus key dispatched: \(mode)") }
            catch {
                if mode == "cancelled" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, mode == "login" ? .authenticationRequired : mode == "unsupported-modifier" ? .unsupportedDocument : .pageChanged, mode) }
            }
            XCTAssertEqual(attempts, mode == "admission-revoked" ? 1 : 0, mode)
            XCTAssertEqual(server.count("/key"), 0, mode)
            if mode == "replacement" { XCTAssertEqual(browser.taskID, "successor") }
        }
    }

    @MainActor
    func testOptInFaraTabAndShiftTabSelectFieldsBeforeExactTyping() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native browser focus traversal") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><label>Origin<input id='origin'></label><input disabled aria-label='Unavailable'><label>Destination<input id='destination'></label>
            <script>
            document.addEventListener('keydown',e=>fetch('/key?key='+e.key+'&shift='+e.shiftKey+'&trusted='+e.isTrusted,{keepalive:true}));
            document.addEventListener('input',e=>fetch('/edit?field='+e.target.id+'&value='+encodeURIComponent(e.target.value),{keepalive:true}));
            requestAnimationFrame(()=>{document.getElementById('origin').focus();fetch('/ready')});
            </script>
            """)])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraTab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        try browser.claim(taskID: "tab")
        _ = try await browser.navigate(taskID: "tab", operationID: "open", to: base.appendingPathComponent("form"))
        let deadline = ContinuousClock.now + .seconds(2)
        while server.count("/ready") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.count("/ready"), 1)
        let actions = [#"{"action":"key","keys":["Tab"]}"#, #"{"action":"type","text":"Tokyo"}"#,
            #"{"action":"key","keys":["Shift","Tab"]}"#, #"{"action":"type","text":"Kyoto"}"#,
            #"{"action":"terminate","answer":"Both fields filled."}"#]
        let goal = "Enter Tokyo in Destination, then Kyoto in Origin using Tab and Shift+Tab."
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard calls < actions.count else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            XCTAssertEqual(input.goal, goal); XCTAssertEqual(input.history.count, calls)
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + actions[calls] + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            let result = try await executor.execute(taskID: "tab", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("Both fields filled."))
            let replay = try await executor.execute(taskID: "tab", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(replay, result)
        } catch { return XCTFail("Focus traversal failed after \(calls) proposals: \(String(reflecting: error))") }
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(server.count("/edit?field=destination&value=Tokyo"), 1)
        XCTAssertEqual(server.count("/edit?field=origin&value=Kyoto"), 1)
        XCTAssertEqual(server.count("/key?key=Tab&shift=false&trusted=true"), 1)
        XCTAssertEqual(server.count("/key?key=Tab&shift=true&trusted=true"), 1)
        let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            .filter { $0.stepIDs == ["native-dispatch-returned"] }
        XCTAssertEqual(journals.count, 4); XCTAssertTrue(journals.allSatisfy { $0.statuses == [.verified] })
    }

    func testFaraBrowserBackShortcutUsesHistoryWithoutBroadeningOtherKeys() throws {
        func decode(_ keys: [String]) throws -> ComputerUseFaraAction {
            let data = try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": ["action": "key", "keys": keys]])
            return try ComputerUseFaraAction.decode("<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>")
        }
        for keys in [["Alt", "Left"], ["Alt", "ArrowLeft"], ["alt", "left"]] {
            XCTAssertEqual(try decode(keys), .historyBack)
        }
        for keys in [["Left"], ["Control", "Left"], ["Alt", "Right"], ["Alt", "Shift", "Left"], ["Left", "Alt"], ["Control", "a"]] {
            XCTAssertEqual(try decode(keys), .key(keys))
        }
    }

    @MainActor
    func testOptInFaraBackRejectsUnavailableStaleLoginAndRetiredAuthority() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native Back boundaries") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["empty", "unobserved", "stale", "revoked", "replacement", "cancelled", "login", "source-blocked", "throw-at-admission", "replace-at-admission"] {
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/a": .init(body: "<!doctype html><h1>A</h1>"),
                "/b": .init(body: "<!doctype html><h1>B</h1><script>fetch('/release').then(()=>{document.body.insertAdjacentHTML('beforeend','<input type=password>');fetch('/login')})</script>"),
                "/c": .init(body: "<!doctype html><h1>C</h1>"), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            var mayAct = true, dispatches = 0, began = 0
            let browser = ComputerUseOwnedBrowser(nativeNavigationDidDispatch: { _, _ in dispatches += 1 }, mayAct: { mayAct })
            defer { browser.close() }
            try browser.claim(taskID: mode)
            if mode != "empty" {
                let a = try await browser.navigate(taskID: mode, operationID: "open-a", to: base.appendingPathComponent("a"))
                if mode != "unobserved" { _ = try await browser.captureAgentObservation(document: a) }
            }
            var components = try XCTUnwrap(URLComponents(url: base.appendingPathComponent("b"), resolvingAgainstBaseURL: false))
            if mode == "source-blocked" { components.host = "localhost" }
            let bURL = try XCTUnwrap(components.url)
            let b = try await browser.navigate(taskID: mode, operationID: "open-b", to: bURL)
            if mode == "source-blocked" {
                let session = try browser.prepareWorkflowSession(taskID: mode)
                let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: mode, prompt: "Go back", referenceDate: Date(), timeZoneIdentifier: "UTC"),
                    allowedOrigins: [ComputerUseBrowserSourceOrigin(bURL)])
                try browser.installSourcePolicy(policy, replacing: nil, session: session)
            }
            let observation = try await browser.captureAgentObservation(document: b)
            if mode == "stale" { _ = try await browser.navigate(taskID: mode, operationID: "open-c", to: base.appendingPathComponent("c")) }
            if mode == "revoked" { mayAct = false }
            if mode == "replacement" { try browser.claim(taskID: "successor") }
            if mode == "login" {
                server.releaseHeldResponses()
                let deadline = ContinuousClock.now + .seconds(2)
                while server.count("/login") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(server.count("/login"), 1)
            }
            let before = dispatches
            let operation = Task { @MainActor in
                try await browser.performAgentInput(.historyBack, observation: observation,
                    operationID: ComputerUseTaskContract.digest([mode, "back"]), willBeginEffect: {
                        began += 1
                        if mode == "throw-at-admission" { throw CancellationError() }
                        if mode == "replace-at-admission" { try browser.claim(taskID: "successor") }
                    })
            }
            if mode == "cancelled" { operation.cancel() }
            do { try await operation.value; XCTFail("Back unexpectedly dispatched: \(mode)") }
            catch {
                if ["empty", "unobserved"].contains(mode) { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationUnavailable) }
                if mode == "source-blocked" { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
                if mode == "login" { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
                if ["cancelled", "throw-at-admission"].contains(mode) { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertEqual(dispatches, before, "No native history call may escape rejection: \(mode)")
            XCTAssertEqual(began, ["throw-at-admission", "replace-at-admission"].contains(mode) ? 1 : 0, mode)
            if ["replacement", "replace-at-admission"].contains(mode) { XCTAssertEqual(browser.taskID, "successor") }
        }
    }

    @MainActor
    func testOptInFaraReturnsThroughObservedNativeHistoryWithoutRevisiting() async throws {
        try await runNativeBackWorkflow(realModel: false)
    }

    @MainActor
    func testOptInFaraBackShortcutTraversesNativeHistoryWithoutRevisiting() async throws {
        try await runNativeBackWorkflow(realModel: false, shortcut: true)
    }

    @MainActor
    func testOptInActualFaraCompletesNaturalLanguageBackWorkflow() async throws {
        try await runNativeBackWorkflow(realModel: true)
    }

    @MainActor
    private func runNativeBackWorkflow(realModel: Bool, shortcut: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        let optIn = realModel ? "RUN_FARA_SEARCH_MODEL_ACCEPTANCE" : "RUN_FARA_NATIVE_BROWSER_INPUT"
        guard environment[optIn] == "1" else { throw XCTSkip("Opt-in: bounded native browser history") }
        let inputs = realModel ? try await FaraTestAssets.inputs(environment: environment) : nil
        let runtime = OSAtlasLlamaRuntime()
        var stage = "fixture setup", calls = 0, backProposals = 0
        var modelResponses: [String] = []
        var observedPaths: [String] = []
        defer {
            let attachment = XCTAttachment(string: "Stage: \(stage)\nProposals: \(calls)\nObserved paths: \(observedPaths)\nReal model: \(realModel)\nBack proposals: \(backProposals)\nModel responses: \(modelResponses)")
            attachment.name = "Native Fara Back diagnostic"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let style = "<style>a{position:fixed;left:20vw;top:20vh;width:60vw;height:20vh;background:#ddd}</style>"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/a": .init(body: "<!doctype html><h1>Page A</h1>" + style + "<a href='/b'>Open B</a>"),
            "/b": .init(body: "<!doctype html><h1>Page B</h1>" + style + "<a href='/c'>Open C</a>"),
            "/c": .init(body: "<!doctype html><h1>Page C</h1>")])
        stage = "HTTP fixture start"
        let base = try await server.start(); defer { server.stop() }
        stage = "browser setup"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraBack-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        try browser.claim(taskID: "back")
        stage = "initial A navigation"
        _ = try await browser.navigate(taskID: "back", operationID: "open-a", to: base.appendingPathComponent("a"))
        let goal = "Visit B and C, then go back twice to A."
        let paths = ["/a", "/b", "/c", "/b", "/a"]
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            stage = "proposal \(calls + 1)"; observedPaths.append(input.currentURL?.path ?? "none")
            guard calls < (realModel ? 8 : paths.count) else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            XCTAssertEqual(input.goal, goal); XCTAssertEqual(input.history.count, calls)
            if let inputs {
                let endpoint = try await runtime.activateFara(inputs)
                let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
                calls += 1; modelResponses.append(proposal.response)
                if case .historyBack = proposal.action { backProposals += 1 }
                return proposal
            }
            XCTAssertEqual(input.currentURL?.path, paths[calls])
            let back = shortcut ? #"{"action":"key","keys":["Alt","Left"]}"# : #"{"action":"history_back"}"#
            let action = calls < 2 ? #"{"action":"left_click","coordinate":[500,300]}"#
                : calls < 4 ? back : #"{"action":"terminate","answer":"Returned to A."}"#
            calls += 1
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + action + "}</tool_call>"
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        }, readPage: { reading in
            guard let inputs else { throw ComputerUseFaraBrowserExecutor.Failure.unsupportedAction }
            let endpoint = try await runtime.activateFara(inputs)
            return try await runtime.readFaraPage(endpoint: endpoint, reading: reading)
        }, finishRun: { await runtime.shutdown() })
        stage = "executor start"
        let result: ComputerUseExecutionResult
        do { result = try await executor.execute(taskID: "back", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
        catch { return XCTFail("Back failed at \(stage): \(String(reflecting: error)); type=\(String(reflecting: type(of: error)))") }
        if let inputs {
            guard case .completed = result else { return XCTFail("Model did not complete: \(result)") }
            XCTAssertEqual(backProposals, 2, "The model must use Back, not synthesize old URLs")
            XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: inputs.llamaServerURL).isEmpty)
            var visited: [String] = []
            for path in observedPaths where visited.last != path { visited.append(path) }
            XCTAssertEqual(visited, paths)
        } else { XCTAssertEqual(result, .completed("Returned to A.")); XCTAssertEqual(calls, 5) }
        XCTAssertEqual(browser.currentDocument(taskID: "back")?.committedURL.path, "/a")
        XCTAssertEqual(server.count("/c"), 1, "Back must traverse existing entries, not append URL revisits")
        XCTAssertLessThanOrEqual(server.count("/a"), 2); XCTAssertLessThanOrEqual(server.count("/b"), 2)
        let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            .filter { $0.stepIDs == ["native-dispatch-returned"] }
        if realModel { XCTAssertGreaterThanOrEqual(journals.count, 4) } else { XCTAssertEqual(journals.count, 4) }
        XCTAssertTrue(journals.allSatisfy { $0.statuses == [.verified] })
    }

    func testFaraExtractionRequestAndResponseRemainBoundedAndTextOnly() throws {
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let reading = ComputerUseFaraModel.PageReading(sourceURL: URL(string: "https://example.com/source")!,
            question: "Which venue?", text: "Miner Auditorium — 東京", truncated: true, omittedEmbeddedContent: true)
        let request = try ComputerUseFaraModel.makePageReadRequest(endpoint: endpoint, reading: reading)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2); XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[1]["content"], "Page content:\nMiner Auditorium — 東京\n... [truncated]\n[Embedded page content omitted]\n\nQuestion: Which venue?")
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["tools"]); XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        func response(finish: String = "stop", content: String = "Miner Auditorium", role: String = "assistant", model: String = ComputerUseFaraRuntimeInputs.modelAlias) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["model": model, "choices": [["finish_reason": finish, "message": ["role": role, "content": content]]]])
        }
        XCTAssertEqual(try ComputerUseFaraModel.decodePageAnswer(response()), "Miner Auditorium")
        for data in [try response(finish: "length"), try response(finish: "tool_calls"), try response(content: " \n"),
                     try response(content: String(repeating: "x", count: 32_769)), try response(role: "user"), try response(model: "another-model"),
                     Data(#"{"model":"fara-browser-v1","model":"fara-browser-v1","choices":[]}"#.utf8)] {
            XCTAssertThrowsError(try ComputerUseFaraModel.decodePageAnswer(data))
        }
        let bounded = ComputerUseFaraModel.formatPageAnswer(question: "Read", answer: String(repeating: "東京👩🏽‍💻", count: 600))
        XCTAssertTrue(bounded.contains("[truncated ")); XCTAssertTrue(bounded.hasSuffix("東京👩🏽‍💻")); XCTAssertFalse(bounded.contains("�"))
        XCTAssertLessThan(bounded.count, 1100)
    }

    func testFaraRejectsUnextractedPageTextInActionConversation() throws {
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let reading = ComputerUseFaraModel.PageReading(sourceURL: URL(string: "https://example.com/source")!,
            question: "Which venue?", text: "Raw page data is not the answer to the reading action.", truncated: false, omittedEmbeddedContent: false)
        let input = try ComputerUseFaraModel.Input(goal: "Read the venue", screenshotPNG: smallPNG(), pageReading: reading)
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input),
            "read_page_answer_question must receive an extracted answer before returning to the action conversation")
    }

    func testFaraPageReadingWireRetainsSourceAndBoundsContext() throws {
        let png = try smallPNG()
        let source = URL(string: "https://example.com/original-page")!
        let reading = ComputerUseFaraModel.PageReading(sourceURL: source, question: "Which venue?", text: "Unrelated raw page text", truncated: true, omittedEmbeddedContent: true, answer: "Miner Auditorium — 東京")
        let wait = #"<tool_call>{"name":"computer_use","arguments":{"action":"wait","time":0}}</tool_call>"#
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        var input = ComputerUseFaraModel.Input(goal: "Keep the complete original request.", screenshotPNG: png,
            history: [.init(screenshotPNG: png, response: wait, currentURL: source, pageReading: reading)], currentURL: URL(string: "https://example.com/current-page")!)
        func texts(_ value: ComputerUseFaraModel.Input) throws -> String {
            let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: value)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let parts = messages.filter { $0["role"] as? String == "user" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            XCTAssertTrue(parts.contains { $0["text"] as? String == value.goal })
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let retained = try texts(input)
        XCTAssertTrue(retained.contains("Miner Auditorium — 東京")); XCTAssertTrue(retained.contains(source.absoluteString))
        XCTAssertTrue(retained.contains("Page text truncated: true; embedded content omitted: true"))
        XCTAssertTrue(retained.contains("I read the page to answer: Which venue?\nAnswer: Miner Auditorium — 東京"))
        XCTAssertFalse(retained.contains("Unrelated raw page text"))
        input.history += Array(repeating: .init(screenshotPNG: png, response: wait), count: 3)
        let aged = try texts(input)
        XCTAssertFalse(aged.contains("Miner Auditorium")); XCTAssertTrue(aged.contains("[Earlier page-reading text omitted] Source: " + source.absoluteString))
        for bad in [
            ComputerUseFaraModel.PageReading(sourceURL: URL(string: "file:///private/page")!, question: "Read", text: "x", truncated: false, omittedEmbeddedContent: false),
            .init(sourceURL: source, question: " \n", text: "x", truncated: false, omittedEmbeddedContent: false),
            .init(sourceURL: source, question: String(repeating: "界", count: 342), text: "x", truncated: false, omittedEmbeddedContent: false),
            .init(sourceURL: source, question: "Read", text: String(repeating: "x", count: 4097), truncated: false, omittedEmbeddedContent: false)
        ] {
            input.pageReading = bad
            XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input))
        }
    }

    @MainActor
    func testOptInLiveSFJazzPageReadingRetainsExactVenueAndTicketFacts() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: native public-page text reading without inference") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLivePageText-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        let url = URL(string: "https://www.sfjazz.org/tickets/productions/26-27/branford-marsalis-and-dianne-reeves-celebrate-john-coltrane/")!
        try browser.claim(taskID: "live-page-text")
        _ = try await browser.navigate(taskID: "live-page-text", operationID: "open", to: url)
        var calls = 0, screenshot = Data()
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            calls += 1; guard calls <= 2 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            if calls == 1 {
                screenshot = input.screenshotPNG
                let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"read_page_answer_question","question":"For the September 17, 2026 performance, read the exact venue, start time and advertised price range."}}</tool_call>"#
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            }
            let reading = try XCTUnwrap(input.pageReading)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let text = XCTAttachment(data: try encoder.encode(reading), uniformTypeIdentifier: "public.json"); text.name = "Native SFJAZZ page reading"; text.lifetime = .keepAlways; self.add(text)
            let image = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png"); image.name = "Source screenshot for native page reading"; image.lifetime = .keepAlways; self.add(image)
            XCTAssertEqual(reading.sourceURL, url)
            XCTAssertTrue(reading.text.localizedCaseInsensitiveContains("Miner Auditorium"))
            XCTAssertTrue(reading.text.contains("7:30")); XCTAssertTrue(reading.text.contains("$55.00")); XCTAssertTrue(reading.text.contains("$155.00"))
            let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"terminate","answer":"Native text captured."}}</tool_call>"#
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        }, readPage: { $0.text.isEmpty ? "No matching information." : $0.text })
        let result = try await executor.execute(taskID: "live-page-text", prompt: "Read the ticket details without input.", trustedUserPrompt: "Read the ticket details without input.", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Native text captured.")); XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testOptInFaraPageReadingBoundsAndRetirement() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native page-reading boundaries") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["truncated", "empty", "empty-question", "oversized-question", "changed", "login", "revoked", "replacement", "cancelled", "reading-login", "reading-revoked", "reading-replacement", "reading-changed", "reading-cancelled"] {
            let text = mode == "empty" ? "" : mode == "truncated" ? (0..<40).map { "<p>\($0) " + String(repeating: "東京😀", count: 15) + "</p>" }.joined() : "<h1 id='venue'>Original venue</h1>"
            let change = mode.contains("login") ? "document.body.insertAdjacentHTML('beforeend','<input type=password>')" : "venue.textContent='Changed venue'"
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html>\(text)<input value='PrivateFieldValue'><iframe srcdoc='<p>EmbeddedOnly</p>'></iframe>
                <script>fetch('/release').then(()=>{\(change);fetch('/changed')})</script>
                """), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraReadEdges-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var mayAct = true
            let browser = ComputerUseOwnedBrowser(mayAct: { mayAct }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { mayAct }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            try browser.claim(taskID: mode)
            let url = base.appendingPathComponent("page")
            _ = try await browser.navigate(taskID: mode, operationID: "open", to: url)
            var calls = 0
            let question = mode == "empty-question" ? " \n\t" : mode == "oversized-question" ? String(repeating: "界", count: 342) : "Read the exact page text."
            let read = "<tool_call>" + String(decoding: try JSONSerialization.data(withJSONObject: ["name":"computer_use","arguments":["action":"read_page_answer_question","question":question]]), as: UTF8.self) + "</tool_call>"
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
                calls += 1; XCTAssertEqual(input.goal, "Read this page without changing it.")
                guard calls <= 3 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                if calls == 1 {
                    XCTAssertNil(input.pageReading)
                    if mode == "changed" || mode == "login" {
                        server.releaseHeldResponses()
                        let deadline = ContinuousClock.now + .seconds(2)
                        while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                        XCTAssertEqual(server.count("/changed"), 1)
                    }
                    if mode == "revoked" { mayAct = false }
                    if mode == "replacement" { try browser.claim(taskID: "successor") }
                    if mode == "cancelled" { throw CancellationError() }
                    return try .init(response: read, action: ComputerUseFaraAction.decodeNativeMessage(read))
                }
                if mode == "changed" && calls == 2 {
                    XCTAssertNil(input.pageReading); XCTAssertTrue(input.history.isEmpty, "An unsent stale read cannot leave an observation or history entry")
                    return try .init(response: read, action: ComputerUseFaraAction.decodeNativeMessage(read))
                }
                let reading = try XCTUnwrap(input.pageReading)
                XCTAssertEqual(reading.sourceURL, url); XCTAssertEqual(reading.question, question)
                XCTAssertLessThanOrEqual(reading.text.utf8.count, 4096)
                XCTAssertFalse(reading.text.contains("PrivateFieldValue")); XCTAssertFalse(reading.text.contains("EmbeddedOnly"))
                XCTAssertTrue(reading.omittedEmbeddedContent)
                if mode == "truncated" { XCTAssertTrue(reading.truncated); XCTAssertTrue(reading.text.contains("東京😀")); XCTAssertFalse(reading.text.contains("�")) }
                if mode == "empty" { XCTAssertEqual(reading.text, ""); XCTAssertFalse(reading.truncated) }
                if mode == "changed" { XCTAssertTrue(reading.text.contains("Changed venue")); XCTAssertFalse(reading.text.contains("Original venue")) }
                let done = #"<tool_call>{"name":"computer_use","arguments":{"action":"terminate","answer":"Read without input."}}</tool_call>"#
                return try .init(response: done, action: ComputerUseFaraAction.decodeNativeMessage(done))
            }, readPage: { reading in
                XCTAssertNil(reading.answer, "Extraction receives native source data only")
                if mode == "reading-login" || mode == "reading-changed" {
                    server.releaseHeldResponses()
                    let deadline = ContinuousClock.now + .seconds(2)
                    while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertEqual(server.count("/changed"), 1)
                }
                if mode == "reading-revoked" { mayAct = false }
                if mode == "reading-replacement" { try browser.claim(taskID: "successor") }
                if mode == "reading-cancelled" { throw CancellationError() }
                return reading.text.isEmpty ? "No matching information." : reading.text
            })
            do {
                let result = try await executor.execute(taskID: mode, prompt: "Read this page without changing it.", trustedUserPrompt: "Read this page without changing it.", tools: tools, progress: { _ in })
                if mode == "login" || mode == "reading-login" { guard case .userInterventionRequired = result else { return XCTFail("Login did not pause the read") }; XCTAssertEqual(calls, 1) }
                else { XCTAssertTrue(["truncated", "empty", "changed"].contains(mode), mode); XCTAssertEqual(result, .completed("Read without input.")) }
            } catch ComputerUseFaraBrowserExecutor.Failure.unsupportedAction { XCTAssertTrue(["empty-question", "oversized-question"].contains(mode), mode); XCTAssertEqual(calls, 1) }
            catch ComputerUseHostTools.ToolError.paused { XCTAssertTrue(["revoked", "reading-revoked"].contains(mode)); XCTAssertEqual(calls, 1) }
            catch is CancellationError { XCTAssertTrue(["cancelled", "reading-cancelled"].contains(mode)); XCTAssertEqual(calls, 1) }
            catch ComputerUseBrowserError.ownershipLost { XCTAssertTrue(["replacement", "reading-replacement"].contains(mode)); XCTAssertEqual(browser.taskID, "successor"); XCTAssertEqual(calls, 1) }
            catch ComputerUseBrowserError.pageChanged {
                XCTAssertTrue(["reading-changed", "reading-replacement"].contains(mode)); XCTAssertEqual(calls, 1)
                if mode == "reading-replacement" { XCTAssertEqual(browser.taskID, "successor") }
            }
            catch { return XCTFail("Page reading edge \(mode): \(error)") }
            let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] }, mode)
        }
    }

    @MainActor
    func testOptInFaraReadsNativePageTextWithoutInputAndRetainsItsSource() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: owned native page-reading action") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/concert": .init(body: """
            <!doctype html><h1>Miner Auditorium — 東京</h1><p>Thursday, September 17, 2026 · 7:30 PM</p><p>$55.00–$155.00</p>
            <input value='DoNotExportFieldValue'><div hidden>DoNotExportHiddenText</div>
            <button onclick="fetch('/clicked')">Purchase</button><script>document.addEventListener('input',()=>fetch('/edited'))</script>
            """)])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraPageRead-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        try browser.claim(taskID: "read-page")
        let url = base.appendingPathComponent("concert")
        _ = try await browser.navigate(taskID: "read-page", operationID: "open", to: url)
        let goal = "Report this concert's exact venue, time and advertised price range. Do not purchase."
        let read = #"<tool_call>{"name":"computer_use","arguments":{"action":"read_page_answer_question","question":"What are the exact venue, start time and price range on this page?"}}</tool_call>"#
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            calls += 1; XCTAssertEqual(input.goal, goal)
            guard calls <= 2 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            if calls == 1 { return try .init(response: read, action: ComputerUseFaraAction.decodeNativeMessage(read)) }
            XCTAssertEqual(input.currentURL, url)
            XCTAssertEqual(input.history.map(\.response), [read])
            let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "test-only")
            let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertTrue(text.contains("Miner Auditorium — 東京"))
            XCTAssertTrue(text.contains("7:30 PM")); XCTAssertTrue(text.contains("$55.00–$155.00"))
            XCTAssertTrue(text.contains(url.absoluteString))
            XCTAssertFalse(text.contains("DoNotExportFieldValue")); XCTAssertFalse(text.contains("DoNotExportHiddenText"))
            let answer = #"<tool_call>{"name":"computer_use","arguments":{"action":"terminate","answer":"Miner Auditorium — 東京; 7:30 PM; $55.00–$155.00"}}</tool_call>"#
            return try .init(response: answer, action: ComputerUseFaraAction.decodeNativeMessage(answer))
        }, readPage: { $0.text.isEmpty ? "No matching information." : $0.text })
        do {
            let result = try await executor.execute(taskID: "read-page", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("Miner Auditorium — 東京; 7:30 PM; $55.00–$155.00"))
        } catch { return XCTFail("Native page read failed after \(calls) proposals: \(error)") }
        XCTAssertEqual(calls, 2); XCTAssertEqual(server.count("/concert"), 1)
        XCTAssertEqual(server.count("/clicked"), 0); XCTAssertEqual(server.count("/edited"), 0)
        let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] })
    }

    @MainActor
    func testOptInFaraReplaysFrozenLiveTicketAnswerExactly() async throws {
        try await runFrozenFaraReplay(templateOnly: false)
    }

    @MainActor
    func testOptInFaraServerTemplateReceivesNativePageReading() async throws {
        try await runFrozenFaraReplay(templateOnly: true)
    }

    @MainActor
    func testOptInFaraExtractsExactVenueFromNativeText() async throws {
        try await runFrozenFaraReplay(templateOnly: false, extractionOnly: true)
    }

    @MainActor
    private func runFrozenFaraReplay(templateOnly: Bool, extractionOnly: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_FROZEN_REPLAY"] == "1" else { throw XCTSkip("Opt-in: one model proposal from an immutable public-site trajectory; no browser input") }
        struct Replay: Decodable {
            struct Frame: Decodable { let response: String; let currentURL: URL?; let pngFile: String?; let pngSHA256: String? }
            let goal: String; let history: [Frame]; let current: Frame
            let expectedVenue: String; let expectedTime: String; let expectedURL: URL
        }
        let file = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_REPLAY_INPUT"]))
        let bytes = try Data(contentsOf: file), replay = try JSONDecoder().decode(Replay.self, from: bytes)
        func image(_ frame: Replay.Frame) throws -> Data {
            guard let name = frame.pngFile else { return Data() }
            let data = try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(name))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), frame.pngSHA256)
            return data
        }
        var input = try ComputerUseFaraModel.Input(goal: replay.goal, screenshotPNG: image(replay.current),
            history: replay.history.map { try .init(screenshotPNG: image($0), response: $0.response, currentURL: $0.currentURL) }, currentURL: replay.current.currentURL)
        var pageReadingSHA256 = "none"
        if let path = environment["FARA_FROZEN_PAGE_READING"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            input.pageReading = try JSONDecoder().decode(ComputerUseFaraModel.PageReading.self, from: data)
            XCTAssertEqual(input.pageReading?.sourceURL, replay.expectedURL)
            pageReadingSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if templateOnly && input.pageReading == nil { throw XCTSkip("Template probe requires the native page-reading fixture") }
        let inputs = try await FaraTestAssets.inputs(environment: environment)
        let runtime = OSAtlasLlamaRuntime(), started = Date()
        var proposal: ComputerUseFaraModel.Proposal?, failure: Error?
        var templateContainsVenue = false, templateSHA256 = "none"
        var extractedAnswer = "", extractionFinishReason = ""
        do {
            let endpoint = try await runtime.activateFara(inputs)
            if extractionOnly {
                let reading = try XCTUnwrap(input.pageReading)
                extractedAnswer = try await runtime.readFaraPage(endpoint: endpoint, reading: reading)
                extractionFinishReason = "stop" // Strict production decoder rejects every other finish reason.
            } else if templateOnly {
                let completion = try ComputerUseFaraModel.makePageReadRequest(endpoint: endpoint, reading: XCTUnwrap(input.pageReading))
                let request = try OSAtlasLlamaHTTPClient.makeSemanticTemplateRequest(from: completion)
                let data = try await URLSessionOSAtlasTransport().complete(request: request)
                let prompt = try OSAtlasLlamaHTTPClient.templatePrompt(from: data)
                templateContainsVenue = prompt.contains(replay.expectedVenue)
                templateSHA256 = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
            } else {
                if var reading = input.pageReading {
                    extractedAnswer = try await runtime.readFaraPage(endpoint: endpoint, reading: reading)
                    extractionFinishReason = "stop"
                    reading.answer = extractedAnswer
                    input.pageReading = reading
                }
                proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
            }
        } catch { failure = error }
        await runtime.shutdown()
        let exited = try DarwinOSAtlasProcessInspector().matchingProcesses(for: inputs.llamaServerURL).isEmpty
        let report: [String: Any] = ["response": proposal?.response ?? "", "failure": failure.map { String(reflecting: $0) } ?? "",
            "seconds": Date().timeIntervalSince(started), "ownedProcessExited": exited,
            "inputSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "pageReadingSHA256": pageReadingSHA256,
            "extractionOnly": extractionOnly, "extractedAnswer": extractedAnswer, "extractionFinishReason": extractionFinishReason,
            "extractionSampling": "pinned llama-server defaults; no temperature override, matching upstream extraction call",
            "templateOnly": templateOnly, "templateContainsExactVenue": templateContainsVenue, "templateSHA256": templateSHA256]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Frozen live answer replay"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(exited)
        if let failure { return XCTFail("Frozen proposal failed: \(failure)") }
        if extractionOnly {
            XCTAssertEqual(extractionFinishReason, "stop", "Truncated extraction is not a complete answer")
            XCTAssertTrue(extractedAnswer.contains(replay.expectedVenue), "Text-only extraction must retain the exact source spelling")
            XCTAssertTrue(extractedAnswer.localizedCaseInsensitiveContains(replay.expectedTime))
            XCTAssertTrue(extractedAnswer.contains("$55") && extractedAnswer.contains("$155"))
            return
        }
        if templateOnly { XCTAssertTrue(templateContainsVenue, "The actual server template must retain native page text"); return }
        guard case .reportCompletion(let answer) = proposal?.action else { return XCTFail("Expected a final answer from the complete retained page: \(String(reflecting: proposal?.action))") }
        XCTAssertTrue(answer.localizedCaseInsensitiveContains(replay.expectedVenue), "Exact venue must match the independent page oracle")
        XCTAssertTrue(answer.localizedCaseInsensitiveContains(replay.expectedTime))
        XCTAssertTrue(answer.contains("$55") && answer.contains("$155"))
        XCTAssertTrue(answer.contains(replay.expectedURL.absoluteString))
    }

    @MainActor
    func testOptInSearchSubmitUsesBoundFormContextAndRetainsCommitGates() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native icon search submission") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["search", "post", "override", "purchase", "unknown", "changed-form", "changed-field", "replaced-field"] {
            let method = mode == "post" ? "post" : "get"
            let label = mode == "purchase" ? "Search and purchase" : mode == "unknown" ? "Message" : "Search concerts"
            let override = mode == "override" ? "formaction='/purchase' formmethod='post'" : ""
            let mutation = mode == "changed-form" ? "document.querySelector('form').method='post'" : mode == "changed-field" ? "query.placeholder='Payment'" : "query.replaceWith(query.cloneNode(true))"
            let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
                <!doctype html><style>#submitter{position:fixed;left:40vw;top:20vh;width:20vw;height:15vh}</style>
                <form action='/search' method='\(method)' onsubmit="fetch('/submitted?trusted='+event.isTrusted,{keepalive:true})"><input id='query' name='q' type='search' placeholder='\(label)' value='Branford Marsalis'><input id='submitter' type='submit' value='submit' \(override)></form>
                <script>fetch('/release').then(()=>{\(mutation);fetch('/changed')})</script>
                """), "/search?q=Branford+Marsalis": .init(body: "<!doctype html><h1>Search results</h1>"), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraSearchSubmit-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
            try browser.claim(taskID: mode)
            _ = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("form"))
            let observation = try await navigation.captureAgentObservation(taskID: mode)
            let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 500, y: 275))
            let inspected = try await browser.inspectAgentTarget(action, observation: observation)
            let target = try XCTUnwrap(inspected)
            if mode.hasPrefix("changed-") || mode == "replaced-field" {
                server.releaseHeldResponses()
                let deadline = ContinuousClock.now + .seconds(2)
                while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(server.count("/changed"), 1)
                do { try await browser.validateAgentTarget(target); return XCTFail("Changed search form retained input authority: \(mode)") }
                catch ComputerUseBrowserError.pageChanged { }
            } else if mode == "search" {
                guard tools.approvalReason(for: target.action, nativeTarget: target) == nil else { return XCTFail("Observed GET search submit was treated as a consequential commit: \(target.context)") }
                XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(for: target.action, accessibilityContext: target.context,
                    forceConfirmation: true, verifiedSearchSubmission: target.isSearchSubmission))
                try await browser.performAgentInput(action, observation: observation, target: target)
                let deadline = ContinuousClock.now + .seconds(2)
                while (server.count("/submitted?trusted=true") == 0 || server.count("/search?q=Branford+Marsalis") == 0) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                let result = try await navigation.captureAgentObservation(taskID: mode, preserving: observation)
                XCTAssertEqual(result.currentURL.path, "/search")
                XCTAssertEqual(server.count("/submitted?trusted=true"), 1)
                XCTAssertEqual(server.count("/search?q=Branford+Marsalis"), 1)
            } else {
                XCTAssertNotNil(tools.approvalReason(for: target.action, nativeTarget: target), mode)
                XCTAssertEqual(server.count("/submitted?trusted=true"), 0)
            }
        }
    }

    @MainActor
    func testOptInAgentReadBudgetStartsAfterDelayedNativeNavigation() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: delayed native navigation followed by layout settling") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<!doctype html><a href='/details' style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh'>View details</a>"),
            "/details": .init(body: "<!doctype html><h1>Details loaded once</h1>", held: true)])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLoadThenLayout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var moves = 0, changing = false
        var settlesAt: ContinuousClock.Instant?
        let browser = ComputerUseOwnedBrowser(domScriptDidDispatch: { command in
            guard changing, command == .pageSnapshot else { return }
            if settlesAt == nil { settlesAt = .now + .seconds(4) }
            guard let settlesAt, ContinuousClock.now < settlesAt,
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }) else { return }
            moves += 1
            window.setFrameOrigin(NSPoint(x: window.frame.minX + (moves.isMultiple(of: 2) ? -1 : 1), y: window.frame.minY))
        }, mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        try browser.claim(taskID: "load-layout")
        _ = try await browser.navigate(taskID: "load-layout", operationID: "open", to: base.appendingPathComponent("start"))
        let initial = try await navigation.captureAgentObservation(taskID: "load-layout")
        let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 500, y: 250))
        let target = try await browser.inspectAgentTarget(action, observation: initial)
        var began = 0
        try await browser.performAgentInput(action, observation: initial, target: target, willBeginEffect: { began += 1 })
        // Join the actual pending request before timing its five-second load.
        let requestDeadline = ContinuousClock.now + .seconds(2)
        while server.count("/details") == 0 && ContinuousClock.now < requestDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.count("/details"), 1)
        changing = true
        let release = Task { try await Task.sleep(for: .seconds(5)); server.releaseHeldResponses() }
        defer { release.cancel() }
        let beganRead = ContinuousClock.now
        do {
            let page = try await navigation.captureAgentObservation(taskID: "load-layout", preserving: initial)
            XCTAssertEqual(page.currentURL, base.appendingPathComponent("details"))
            XCTAssertGreaterThanOrEqual(beganRead.duration(to: .now), .seconds(9))
        } catch { XCTFail("Page loading consumed the layout retry budget: \(error)") }
        XCTAssertEqual(began, 1); XCTAssertEqual(server.count("/details"), 1); XCTAssertGreaterThan(moves, 1)
    }

    @MainActor
    func testOptInAgentCaptureWaitsForLayoutWithoutRepeatingInput() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: delayed native layout after one click") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><button style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh' onclick=\"fetch('/clicked')\">Open details</button>")])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLayoutSettle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settlesAt: ContinuousClock.Instant?, moves = 0
        let browser = ComputerUseOwnedBrowser(domScriptDidDispatch: { command in
            guard command == .pageSnapshot, let settlesAt, ContinuousClock.now < settlesAt,
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }) else { return }
            // Invalidate each in-flight capture until the layout settles.
            // This runs after capture recorded its frame, so the result
            // cannot pass accidentally between periodic timer callbacks.
            moves += 1
            window.setFrameOrigin(NSPoint(x: window.frame.minX + (moves.isMultiple(of: 2) ? -1 : 1), y: window.frame.minY))
        }, mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        try browser.claim(taskID: "layout-settle")
        _ = try await browser.navigate(taskID: "layout-settle", operationID: "open", to: base.appendingPathComponent("page"))
        let initial = try await navigation.captureAgentObservation(taskID: "layout-settle")
        let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 500, y: 250))
        let target = try await browser.inspectAgentTarget(action, observation: initial)
        var began = 0
        try await browser.performAgentInput(action, observation: initial, target: target, willBeginEffect: { began += 1 })
        settlesAt = .now + .seconds(4)
        let beganRead = ContinuousClock.now
        do {
            let settled = try await navigation.captureAgentObservation(taskID: "layout-settle", preserving: initial)
            XCTAssertEqual(settled.currentURL, base.appendingPathComponent("page"))
            XCTAssertGreaterThanOrEqual(beganRead.duration(to: .now), .seconds(4))
        } catch { XCTFail("The read expired before the delayed layout settled: \(error)") }
        XCTAssertGreaterThan(moves, 1); XCTAssertEqual(began, 1); XCTAssertEqual(server.count("/clicked"), 1)
    }

    @MainActor
    func testOptInAgentReadsHistoryUpdatedDocumentAfterOneNativeClick() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native navigation with history changes before load finishes") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["query", "fragment", "login", "takeover"] {
            let path = mode == "fragment" ? "/details#shows" : "/details?month=2026-09#shows"
            let server = try OwnedBrowserHTTPFixture(routes: [
                "/start": .init(body: "<!doctype html><a href='/details' style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh'>View Calendar</a>"),
                "/details": .init(body: """
                    <!doctype html><h1>September calendar</h1>\(mode == "login" ? "<input type=password>" : "")
                    <script>document.addEventListener('DOMContentLoaded',()=>{history.replaceState({},'',\(String(reflecting: path)));fetch('/ready')})</script>
                    """)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraCalendar-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var mayAct = true
            let browser = ComputerUseOwnedBrowser(mayAct: { mayAct }); defer { browser.close() }
            let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
            try browser.claim(taskID: mode)
            _ = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("start"))
            let original = try await navigation.captureAgentObservation(taskID: mode)
            let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 500, y: 250))
            let target = try await browser.inspectAgentTarget(action, observation: original)
            var began = 0
            try await browser.performAgentInput(action, observation: original, target: target, willBeginEffect: { began += 1 })
            let deadline = ContinuousClock.now + .seconds(3)
            while server.count("/ready") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/ready"), 1)
            if mode == "takeover" { mayAct = false; browser.prepareForUserControl(taskID: mode) }
            if mode == "login" || mode == "takeover" {
                do { _ = try await navigation.captureAgentObservation(taskID: mode, preserving: original); XCTFail("Private or user-controlled page was captured") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, mode == "login" ? .authenticationRequired : .ownershipLost) }
            } else {
                let page = try await navigation.captureAgentObservation(taskID: mode, preserving: original)
                XCTAssertEqual(page.currentURL, URL(string: path, relativeTo: base)?.absoluteURL)
                XCTAssertEqual(page.approvalPageEvidence.document.source, .activePageObservation)
                XCTAssertNil(browser.receipt(taskID: mode, operationID: page.approvalPageEvidence.document.operationID))
                XCTAssertEqual(try browser.navigationDispatchHistory(taskID: mode).attempts.count, 1)
            }
            XCTAssertEqual(began, 1); XCTAssertEqual(server.count("/details"), 1)
        }
    }

    @MainActor
    func testOptInLiveSFJazzSearchCanOpenCalendarAndReadItsResult() async throws {
        try await runLiveSFJazzTransitionProbe(.searchToCalendar)
    }

    @MainActor
    func testOptInLiveSFJazzDetailsTabCanBeReadAfterOneClick() async throws {
        try await runLiveSFJazzTransitionProbe(.detailsTab)
    }

    @MainActor
    func testOptInLiveSFJazzCalendarEventLinkProducesAgentObservation() async throws {
        try await runLiveSFJazzTransitionProbe(.calendarToEvent)
    }

    private enum LiveSFJazzTransition: Equatable { case searchToCalendar, detailsTab, calendarToEvent }

    @MainActor
    private func runLiveSFJazzTransitionProbe(_ transition: LiveSFJazzTransition) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: native search-to-calendar transition without inference") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLiveCalendarProbe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        var captureCommands: [String] = []
        let browser = ComputerUseOwnedBrowser(domScriptDidDispatch: { command in
            guard command == .pageSnapshot || command == .validatePageSnapshot else { return }
            func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            let view = NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first
            captureCommands.append("\(Date().timeIntervalSince(started)) \(command.rawValue) \(view?.url?.absoluteString ?? "none") loading=\(String(describing: view?.isLoading))")
        }, mayAct: { true }); defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let taskID = "live-calendar-probe", session = try browser.prepareWorkflowSession(taskID: taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: taskID, prompt: "Open the calendar from site search", referenceDate: Date(), timeZoneIdentifier: "America/Los_Angeles"),
            allowedOrigins: [ComputerUseBrowserSourceOrigin(URL(string: "https://sfjazz.org")!), ComputerUseBrowserSourceOrigin(URL(string: "https://www.sfjazz.org")!)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        var stage = "open observed search URL", began = 0, failure: Error?
        let eventPath = "/tickets/productions/26-27/branford-marsalis-and-dianne-reeves-celebrate-john-coltrane/"
        do {
            let url: String
            switch transition {
            case .searchToCalendar: url = "https://www.sfjazz.org/search/?query=Branford%20Marsalis"
            case .detailsTab: url = "https://www.sfjazz.org" + eventPath
            case .calendarToEvent: url = "https://www.sfjazz.org/calendar/?date=2026-09-17&layout=A"
            }
            _ = try await browser.navigate(taskID: taskID, operationID: "open", to: URL(string: url)!)
            var point = ComputerUseFaraAction.Point(x: 143, y: 626)
            if transition != .searchToCalendar {
                func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
                let view = try XCTUnwrap(NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
                // Public-page fixture setup only: put the known link
                // in view, then exercise the real screenshot/native input path.
                let query = transition == .detailsTab ? "document.querySelector('a[href=\"#Details\"]')"
                    : "Array.from(document.links).find(link=>link.pathname==='\(eventPath)' && link.innerText.toLowerCase().includes('branford'))"
                if transition == .calendarToEvent { try await Task.sleep(for: .seconds(2)) }
                _ = try await view.evaluateJavaScript("\(query).scrollIntoView({block:'center',behavior:'instant'})")
                try await Task.sleep(for: .seconds(8))
                let rawLocation = try await view.evaluateJavaScript("(()=>{const r=\(query).getBoundingClientRect();return [(r.x+r.width/2)*1000/innerWidth,(r.y+r.height/2)*1000/innerHeight]})()")
                let location = try XCTUnwrap(rawLocation as? [Double])
                point = .init(x: location[0], y: location[1])
                let mutationScript = """
                    window.__remoteDesktopProbeMutations=[]; new MutationObserver(records=>{for(const r of records){window.__remoteDesktopProbeMutations.push({time:performance.now(),type:r.type,tag:r.target.nodeName,id:r.target.id||'',attribute:r.attributeName,old:r.oldValue,value:r.attributeName?r.target.getAttribute(r.attributeName):null,added:r.addedNodes.length,removed:r.removedNodes.length});if(window.__remoteDesktopProbeMutations.length>100)window.__remoteDesktopProbeMutations.shift()}}).observe(document,{subtree:true,attributes:true,attributeOldValue:true,childList:true,characterData:true});
                    """
                _ = try await view.evaluateJavaScript(mutationScript)
                view.configuration.userContentController.addUserScript(WKUserScript(source: mutationScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            stage = "capture search"
            let observation = try await navigation.captureAgentObservation(taskID: taskID)
            if transition == .searchToCalendar { try await Task.sleep(for: .seconds(8)) }
            stage = "inspect View Calendar"
            let action = ComputerUseFaraAction.pointer(.leftClick, point)
            let target = try await browser.inspectAgentTarget(action, observation: observation)
            let label = transition == .detailsTab ? "details" : transition == .calendarToEvent ? "branford" : "calendar"
            XCTAssertTrue(try XCTUnwrap(target).context.lowercased().contains(label))
            stage = "dispatch View Calendar"
            try await browser.performAgentInput(action, observation: observation, target: target, willBeginEffect: {
                began += 1; captureCommands.append("\(Date().timeIntervalSince(started)) native click")
            })
            stage = "capture calendar"
            let deadline = ContinuousClock.now + .seconds(8)
            var page = try await navigation.captureAgentObservation(taskID: taskID)
            func arrived(_ url: URL) -> Bool {
                switch transition {
                case .searchToCalendar: return url.path.hasPrefix("/calendar")
                case .detailsTab: return url.fragment == "Details"
                case .calendarToEvent: return url.path == URL(string: "https://www.sfjazz.org" + eventPath)!.path
                }
            }
            while !arrived(page.currentURL) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                page = try await navigation.captureAgentObservation(taskID: taskID)
            }
            XCTAssertTrue(arrived(page.currentURL)); XCTAssertEqual(began, 1)
            let image = XCTAttachment(data: page.png, uniformTypeIdentifier: "public.png")
            image.name = "Native calendar result"; image.lifetime = .keepAlways; add(image)
            stage = "complete"
        } catch { failure = error }
        if failure != nil, stage == "capture calendar" {
            func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            let view = try XCTUnwrap(NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
            let changes = try await view.callAsyncJavaScript("""
                return await new Promise(resolve=>{const changes=[]; const observer=new MutationObserver(records=>{for(const r of records){if(changes.length<100)changes.push({type:r.type,tag:r.target.nodeName,id:r.target.id||'',attribute:r.attributeName,value:r.attributeName?r.target.getAttribute(r.attributeName):null,added:r.addedNodes.length,removed:r.removedNodes.length})}});observer.observe(document,{subtree:true,attributes:true,childList:true,characterData:true});setTimeout(()=>{observer.disconnect();resolve(JSON.stringify({during:window.__remoteDesktopProbeMutations||[],after:changes}))},600)});
                """, arguments: [:], in: nil, contentWorld: .page)
            let diagnostic = XCTAttachment(string: String(describing: changes)); diagnostic.name = "Public calendar mutation sample"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); attachment.name = "Public calendar diagnostic image"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let ledger = try browser.navigationDispatchHistory(taskID: taskID)
        let events = ledger.observations.map { "\($0.order) \($0.phase.rawValue) \($0.decision.rawValue) \($0.binding.rawValue) generation=\($0.generation) end=\($0.observedEnd?.rawValue ?? "none")" }
        let pages = ledger.pageObservationEvents.map { "\($0.order) page=\($0.phase.rawValue) basis=\($0.observation.basis.rawValue) generation=\($0.generation) retirement=\($0.retirement?.rawValue ?? "none")" }
        let history = XCTAttachment(string: (events + pages).joined(separator: "\n"))
        history.name = "Native calendar navigation history"; history.lifetime = .keepAlways; add(history)
        let details = XCTAttachment(string: "Stage: \(stage)\nBegan native input: \(began)\nTarget: \(browser.lastAgentTargetStatus ?? "none")\nCapture: \(browser.lastAgentCaptureStage ?? "none")\nCurrent document: \(browser.currentDocument(taskID: taskID)?.committedURL.absoluteString ?? "none")\nFailure: \(String(reflecting: failure))\nCommands: \(captureCommands)")
        details.name = "Native calendar transition evidence"; details.lifetime = .keepAlways; add(details)
        if let failure { XCTFail("\(stage), began \(began): \(failure)") }
    }

    @MainActor
    func testOptInFaraReturnSubmitsSearchOnceAndRetainsApprovalAndControlGates() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: real Return key and form navigation") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["search", "message", "dangerous-search", "revoked", "login"] {
            let label = mode == "message" ? "Message" : mode == "dangerous-search" ? "Search and purchase" : "Search"
            let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
                <!doctype html><form action='/results' method='get' onsubmit="fetch('/submitted',{keepalive:true})"><label>\(label)<input id='query' name='q' value='Branford Marsalis'></label></form>
                <script>query.addEventListener('keydown',e=>fetch('/key?value='+e.key+'&trusted='+e.isTrusted,{keepalive:true}));requestAnimationFrame(()=>{query.focus();fetch('/focused')});fetch('/release').then(()=>{document.body.insertAdjacentHTML('beforeend','<input type=password>');fetch('/login-ready')})</script>
                """), "/results?q=Branford+Marsalis": .init(body: "<!doctype html><h1>Form submitted once</h1>"), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraReturn-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var mayAct = true
            let browser = ComputerUseOwnedBrowser(mayAct: { mayAct }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { mayAct }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            try browser.claim(taskID: mode)
            _ = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("form"))
            let focusDeadline = ContinuousClock.now + .seconds(2)
            while server.count("/focused") == 0 && ContinuousClock.now < focusDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/focused"), 1)
            let goal = "Submit this form once."
            var calls = 0
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
                XCTAssertEqual(input.goal, goal); calls += 1
                guard calls <= 4 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                if mode == "revoked" { mayAct = false }
                if mode == "login" {
                    server.releaseHeldResponses()
                    let deadline = ContinuousClock.now + .seconds(2)
                    while server.count("/login-ready") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertEqual(server.count("/login-ready"), 1)
                }
                if calls > 1 { XCTAssertEqual(input.history.count, calls-1) }
                let args: String
                if calls == 1 { args = #"{"action":"key","keys":["Enter"]}"# }
                else if input.currentURL?.path == "/form" { args = #"{"action":"wait","time":0.05}"# }
                else { XCTAssertEqual(input.currentURL?.path, "/results"); args = #"{"action":"terminate","answer":"Form submitted once."}"# }
                let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + args + "}</tool_call>"
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            var result: ComputerUseExecutionResult?
            do { result = try await executor.execute(taskID: mode, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
            catch ComputerUseHostTools.ToolError.paused { XCTAssertEqual(mode, "revoked") }
            catch { return XCTFail("Return failed in \(mode) after \(calls) proposals: \(error)") }
            if mode == "message" || mode == "dangerous-search" {
                XCTAssertEqual(calls, 1); XCTAssertEqual(server.count("/submitted"), 0)
                guard case .approvalRequired(_, let action, let continuation) = result else { return XCTFail("Return on a non-search form requires approval") }
                XCTAssertEqual(action, .key(usage: 0x28, modifiers: 0))
                let fingerprint = try XCTUnwrap(continuation.nativeBrowserTarget).fingerprint
                try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {})
                do { try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Repeated Return approval dispatched twice") }
                catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
                result = try await executor.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: { _ in })
            }
            let submitted = mode == "search" || mode == "message" || mode == "dangerous-search"
            if submitted {
                XCTAssertEqual(result, .completed("Form submitted once.")); XCTAssertTrue((2...4).contains(calls))
                let completedCalls = calls
                let replay = try await executor.execute(taskID: mode, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(replay, result); XCTAssertEqual(calls, completedCalls)
            } else if mode == "login" { guard case .userInterventionRequired = result else { return XCTFail("Login must stop Return") }; XCTAssertEqual(calls, 1) }
            let deadline = ContinuousClock.now + .seconds(2)
            if submitted { while server.count("/submitted") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) } }
            XCTAssertEqual(server.count("/submitted"), submitted ? 1 : 0)
            XCTAssertEqual(server.count("/key?value=Enter&trusted=true"), submitted ? 1 : 0)
            XCTAssertEqual(server.count("/results?q=Branford+Marsalis"), submitted ? 1 : 0)
        }
    }

    @MainActor
    func testOptInAgentDistinguishesBackgroundMotionFromChangedHitTargets() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: retained browser hit-target evidence") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["behind", "behind-replacement", "cover", "uncover", "visual-cover", "target", "zoom"] {
            let initial = mode == "uncover" ? "left:10vw;top:10vh" : "left:60vw;top:60vh"
            let change: String
            switch mode {
            case "behind", "zoom": change = "backdrop.style.transform='translateX(20px)'"
            case "behind-replacement": change = "backdrop.replaceWith(backdrop.cloneNode(true))"
            case "cover", "visual-cover": change = "front.style.left='10vw';front.style.top='10vh'"
            case "uncover": change = "front.style.top='60vh'"
            default: change = "search.style.transform='translateX(40px)'"
            }
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>body{margin:0;height:100vh}#backdrop{position:fixed;inset:0;background:blue;z-index:0}#panel{position:fixed;left:0;top:0;width:40vw;height:40vh;background:black;z-index:10}button{position:fixed;left:10vw;top:10vh;width:20vw;height:10vh;font:24px system-ui}#front{position:fixed;width:20vw;height:10vh;background:red;z-index:99;\(initial);\(mode == "visual-cover" ? "pointer-events:none" : "")}</style>
                <div id='backdrop'></div><div id='panel'><button id='search' onclick="fetch('/clicked')">Search</button></div><div id='front'></div>
                <script>addEventListener('resize',()=>fetch('/resized'));fetch('/release').then(()=>{\(change);fetch('/changed')})</script>
                """), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            try browser.claim(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("page"))
            if mode == "zoom" {
                func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
                let view = try XCTUnwrap(NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
                let window = try XCTUnwrap(view.window)
                let count = server.count("/resized")
                view.pageZoom = 1.25
                window.setFrameOrigin(NSPoint(x: window.frame.minX+0.25, y: window.frame.minY+0.25))
                let deadline = ContinuousClock.now + .seconds(2)
                while server.count("/resized") == count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertGreaterThan(server.count("/resized"), count); XCTAssertEqual(view.pageZoom, 1.25)
            }
            let beganCapture = Date()
            let observation = try await browser.captureAgentObservation(document: document)
            let timing = XCTAttachment(string: "\(mode) observation seconds: \(Date().timeIntervalSince(beganCapture))")
            timing.name = "Native hit-target capture timing"; timing.lifetime = .keepAlways; add(timing)
            server.releaseHeldResponses()
            let deadline = ContinuousClock.now + .seconds(2)
            while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/changed"), 1)
            let allowed = mode.hasPrefix("behind") || mode == "zoom", action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 200, y: 150))
            var began = 0
            do {
                let target = try await browser.inspectAgentTarget(action, observation: observation)
                try await browser.performAgentInput(action, observation: observation, target: target, willBeginEffect: { began += 1 })
                if !allowed { XCTFail("Changed hit target admitted: \(mode)") }
            } catch {
                if allowed { return XCTFail("Hidden background blocked an unchanged Search control (\(mode)): \(error)") }
                XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged, mode)
            }
            if allowed { while server.count("/clicked") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) } }
            XCTAssertEqual(began, allowed ? 1 : 0, mode); XCTAssertEqual(server.count("/clicked"), allowed ? 1 : 0, mode)
        }
    }

    @MainActor
    func testOptInLiveSFJazzSearchFieldRemainsUsableOverAnimatedHomepage() async throws {
        try await runLiveSFJazzSearchProbe(submit: false)
    }

    @MainActor
    func testOptInLiveSFJazzIconSearchSubmitsWithoutCommitApproval() async throws {
        try await runLiveSFJazzSearchProbe(submit: true)
    }

    @MainActor
    private func runLiveSFJazzSearchProbe(submit: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: one live native search-panel experiment without inference") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLiveSearchProbe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let taskID = "live-search-probe", session = try browser.prepareWorkflowSession(taskID: taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: taskID, prompt: "Open site search", referenceDate: Date(), timeZoneIdentifier: "America/Los_Angeles"),
            allowedOrigins: [ComputerUseBrowserSourceOrigin(URL(string: "https://sfjazz.org")!), ComputerUseBrowserSourceOrigin(URL(string: "https://www.sfjazz.org")!)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        let initial = try await browser.captureInitialAgentObservation(taskID: taskID, expectedSessionIdentity: nil)
        try await browser.performInitialAgentNavigation(URL(string: "https://sfjazz.org")!, observation: XCTUnwrap(initial), operationID: "open", willBeginEffect: {})
        var observation = try await navigation.captureAgentObservation(taskID: taskID)
        let headerAction = ComputerUseFaraAction.pointer(.leftClick, .init(x: 277, y: 83))
        let headerTarget = try await browser.inspectAgentTarget(headerAction, observation: observation)
        XCTAssertTrue(try XCTUnwrap(headerTarget).context.lowercased().contains("search"))
        try await browser.performAgentInput(headerAction, observation: observation, target: headerTarget)
        try await Task.sleep(for: .seconds(1))
        observation = try await navigation.captureAgentObservation(taskID: taskID)
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        let view = try XCTUnwrap(NSApp.windows.filter { $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
        func pointDetails() async throws -> String {
            try await view.evaluateJavaScript("""
                JSON.stringify({focus:document.activeElement?.outerHTML.slice(0,500),selection:String(document.getSelection()),items:[...document.querySelectorAll('*')].flatMap(e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.x<=137&&r.x+r.width>137&&r.y<=167&&r.y+r.height>167&&s.display!=='none'&&s.visibility==='visible'?[{tag:e.tagName,id:e.id,classes:e.className,rect:[r.x,r.y,r.width,r.height],opacity:s.opacity,z:s.zIndex,pointer:s.pointerEvents}]:[]})})
                """) as? String ?? "unavailable"
        }
        let before = try await pointDetails()
        let image = XCTAttachment(data: observation.png, uniformTypeIdentifier: "public.png")
        image.name = "Live search field before delay"; image.lifetime = .keepAlways; add(image)
        try await Task.sleep(for: .seconds(8))
        let details = XCTAttachment(string: "Before: \(before)\nAfter: \(try await pointDetails())")
        details.name = "Live search point geometry before and after delay"; details.lifetime = .keepAlways; add(details)
        let fieldAction = ComputerUseFaraAction.pointer(.leftClick, .init(x: 143, y: 294))
        do {
            let target = try await browser.inspectAgentTarget(fieldAction, observation: observation)
            XCTAssertTrue(try XCTUnwrap(target).context.contains("AXTextField"))
            try await browser.performAgentInput(fieldAction, observation: observation, target: target)
        } catch { return XCTFail("Search field after eight seconds: \(error), target status: \(browser.lastAgentTargetStatus ?? "none")") }
        guard submit else { return }
        let metadata = try await view.evaluateJavaScript("JSON.stringify([...document.forms].filter(f=>[...f.elements].some(e=>(e.placeholder||'').includes('Search'))).map(f=>({action:f.action,method:f.method,target:f.target,members:[...f.elements].map(e=>({tag:e.tagName,type:e.type,name:e.name,label:e.getAttribute('aria-label'),placeholder:e.placeholder,formaction:e.getAttribute('formaction'),formmethod:e.getAttribute('formmethod')}))})))")
        let attachment = XCTAttachment(string: String(describing: metadata)); attachment.name = "Public search form metadata"; attachment.lifetime = .keepAlways; add(attachment)
        observation = try await navigation.captureAgentObservation(taskID: taskID, preserving: observation)
        let typing = ComputerUseFaraAction.typeText("Branford Marsalis")
        let field = try await browser.inspectAgentTarget(typing, observation: observation)
        try await browser.performAgentInput(typing, observation: observation, target: field)
        observation = try await navigation.captureAgentObservation(taskID: taskID, preserving: observation)
        let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 299, y: 292))
        let inspected = try await browser.inspectAgentTarget(action, observation: observation)
        let target = try XCTUnwrap(inspected)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        guard tools.approvalReason(for: target.action, nativeTarget: target) == nil else { return XCTFail("Live search submit still requires approval: \(target.context)") }
        var begins = 0
        try await browser.performAgentInput(action, observation: observation, target: target, willBeginEffect: { begins += 1 })
        let deadline = ContinuousClock.now + .seconds(15)
        repeat {
            observation = try await navigation.captureAgentObservation(taskID: taskID, preserving: observation)
            if observation.currentURL.path == "/search" { break }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(observation.currentURL.path, "/search")
        XCTAssertTrue(observation.currentURL.absoluteString.contains("Branford"))
        XCTAssertEqual(begins, 1)
    }

    @MainActor
    func testOptInAgentScopesInputToUnchangedControlWhilePageContentChanges() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: target-scoped native input on a changing page") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let changes = [
            ("away-text", "motion.textContent='Another concert'"),
            ("away-node", "motion.append(Object.assign(document.createElement('span'),{textContent:'More dates'}))"),
            ("away-control", "other.remove()"),
            ("target-text", "search.textContent='Purchase tickets'"),
            ("target-replaced", "search.replaceWith(search.cloneNode(true))"),
            ("target-remove-restore", "const s=search,p=s.parentNode;s.remove();p.append(s)"),
            ("target-link", "search.href='/changed-destination'"),
            ("login", "motion.innerHTML='<input type=password>'"),
            ("source-policy", "void 0"),
            ("source-boundary", "void 0")
        ]
        for (mode, change) in changes {
            let target = mode == "target-link" ? "<a id='search' href='/destination'>Search</a>" : "<button id='search' onclick=\"fetch('/clicked')\">Search</button>"
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>body{margin:0;height:100vh}#search{position:fixed;left:10vw;top:10vh;width:20vw;height:10vh;font:24px system-ui}#motion{position:fixed;left:50vw;top:50vh;width:20vw;height:10vh}</style>
                \(target)<div id='motion'>A concert<a id='other' href='/elsewhere'>Elsewhere</a></div>
                <script>fetch('/release').then(()=>{\(change);fetch('/changed')})</script>
                """), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let session = try browser.prepareWorkflowSession(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("page"))
            let observation = try await browser.captureAgentObservation(document: document)
            server.releaseHeldResponses()
            let deadline = ContinuousClock.now + .seconds(2)
            while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/changed"), 1)
            func revokeSource() throws {
                let goal = try ComputerUseBrowserGoalInput(taskID: mode, prompt: "Click Search", referenceDate: Date(), timeZoneIdentifier: "America/Los_Angeles")
                let policy = try ComputerUseBrowserSourcePolicy(goal: goal, allowedOrigins: [])
                try browser.installSourcePolicy(policy, replacing: nil, session: session)
            }
            if mode == "source-policy" { try revokeSource() }
            let allowed = mode.hasPrefix("away-")
            if allowed && mode != "away-node" {
                do { try await browser.validateAgentObservation(observation); XCTFail("Changed page cannot verify a final answer") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            }
            let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 200, y: 150))
            var began = 0
            do {
                let target = try await browser.inspectAgentTarget(action, observation: observation)
                try await browser.performAgentInput(action, observation: observation, target: target, willBeginEffect: {
                    began += 1
                    if mode == "source-boundary" { try revokeSource() }
                })
                if !allowed { XCTFail("Changed target admitted: \(mode)") }
            } catch {
                if allowed { return XCTFail("Unrelated content blocked an unchanged control (\(mode)): \(error)") }
                let expected: ComputerUseBrowserError = mode == "login" ? .authenticationRequired : mode.hasPrefix("source-") ? .sourceNotAllowed : .pageChanged
                XCTAssertEqual(error as? ComputerUseBrowserError, expected, mode)
            }
            if allowed { while server.count("/clicked") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) } }
            XCTAssertEqual(began, allowed || mode == "source-boundary" ? 1 : 0, mode); XCTAssertEqual(server.count("/clicked"), allowed ? 1 : 0, mode)
            XCTAssertEqual(server.count("/changed-destination"), 0)
        }
    }

    @MainActor
    func testOptInFaraReplansOnlyUnsentStaleProposalsAndBoundsRetries() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: stale-proposal recovery with real native input") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["once", "continuous", "replacement"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>body{margin:0;height:100vh}button{position:fixed;left:10vw;top:10vh;width:20vw;height:10vh;font:24px system-ui}</style>
                <button id='search' onclick="fetch('/clicked')">Search</button>
                <script>(async()=>{for(let n=1;n<=4;n++){await fetch('/release');search.style.left=(10+n*2)+'vw';fetch('/changed?n='+n)}})()</script>
                """), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraStaleProposal-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
            try browser.claim(taskID: mode)
            _ = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("page"))
            let goal = "Click Search once."
            var calls = 0, historyCounts: [Int] = []
            let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
                XCTAssertEqual(input.goal, goal); historyCounts.append(input.history.count); calls += 1
                guard calls <= 4 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                if mode == "replacement" { try browser.claim(taskID: "replacement-owner") }
                else if calls == 1 || mode == "continuous" {
                    let deadline = ContinuousClock.now + .seconds(2)
                    while server.count("/release") < calls && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    server.releaseHeldResponses()
                    while server.count("/changed?n=\(calls)") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertEqual(server.count("/changed?n=\(calls)"), 1)
                }
                let action: [String: Any] = mode == "once" && calls == 3 ? ["action":"terminate","answer":"Clicked Search once."]
                    : ["action":"left_click","coordinate":[mode == "once" && calls == 2 ? 220 : 200,150]]
                let response = "<tool_call>" + String(decoding: try JSONSerialization.data(withJSONObject: ["name":"computer_use","arguments":action]), as: UTF8.self) + "</tool_call>"
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
            var result: ComputerUseExecutionResult?, failure: Error?
            do { result = try await executor.execute(taskID: mode, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
            catch { failure = error }
            if mode == "once" {
                if let failure { return XCTFail("Unsent stale proposal was not replanned: \(failure)") }
                XCTAssertEqual(result, .completed("Clicked Search once.")); XCTAssertEqual(calls, 3); XCTAssertEqual(historyCounts, [0,0,1])
                let deadline = ContinuousClock.now + .seconds(2)
                while server.count("/clicked") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(server.count("/clicked"), 1)
            } else if mode == "continuous" {
                XCTAssertNil(failure); guard case .userInterventionRequired = result else { return XCTFail("Continuous change must hand control back after bounded replanning") }
                XCTAssertEqual(calls, 4); XCTAssertEqual(historyCounts, [0,0,0,0]); XCTAssertEqual(server.count("/clicked"), 0)
            } else {
                XCTAssertEqual(failure as? ComputerUseBrowserError, .ownershipLost); XCTAssertEqual(calls, 1)
                XCTAssertEqual(browser.taskID, "replacement-owner", "Recovery must not reclaim a successor's browser")
                XCTAssertEqual(server.count("/clicked"), 0)
            }
            let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(journals.filter { $0.stepIDs == ["native-dispatch-returned"] }.count, mode == "once" ? 1 : 0)
        }
    }

    @MainActor
    func testOptInAgentAllowsUnrelatedMotionAndRejectsMotionAtInputPoint() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: bounded native input geometry") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for mode in ["away", "target", "cover", "uncover"] {
            let initial = mode == "uncover" ? "left:10vw;top:10vh;width:20vw;height:10vh;z-index:99" : "left:50vw;top:50vh;width:20vw;height:10vh"
            let change = mode == "away" ? "motion.style.transform='translateX(30px)'"
                : mode == "target" ? "search.style.transform='translateX(40px)'"
                : mode == "cover" ? "motion.style.cssText='position:fixed;left:10vw;top:10vh;width:20vw;height:10vh;z-index:99;background:red'"
                : "motion.style.top='50vh'"
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>body{margin:0;height:100vh}button{position:fixed;left:10vw;top:10vh;width:20vw;height:10vh;font:24px system-ui}#motion{position:fixed;background:red;\(initial)}</style>
                <button id='search' onclick="fetch('/clicked')">Search</button><div id='motion'></div>
                <script>fetch('/release').then(()=>{\(change);fetch('/changed')})</script>
                """), "/release": .init(held: true)])
            let base = try await server.start(); defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
            try browser.claim(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("page"))
            let observation = try await browser.captureAgentObservation(document: document)
            server.releaseHeldResponses()
            let deadline = ContinuousClock.now + .seconds(2)
            while server.count("/changed") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/changed"), 1)
            let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 200, y: 150))
            var began = 0
            do {
                try await browser.validateAgentObservation(observation)
                let target = try await browser.inspectAgentTarget(action, observation: observation)
                try await browser.performAgentInput(action, observation: observation, target: target, willBeginEffect: { began += 1 })
                if mode != "away" { XCTFail("Input admitted motion at its point: \(mode)") }
            } catch {
                if mode == "away" { return XCTFail("Unrelated decorative motion blocked a stable Search button: \(error)") }
                XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged, mode)
            }
            if mode == "away" {
                while server.count("/clicked") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            }
            XCTAssertEqual(began, mode == "away" ? 1 : 0, mode)
            XCTAssertEqual(server.count("/clicked"), mode == "away" ? 1 : 0, mode)
        }
    }

    @MainActor
    func testOptInLiveSFJazzInitialNavigationAndCaptureWithoutInference() async throws {
        try await runLiveInitialCaptureProbe(url: URL(string: "https://sfjazz.org")!)
    }

    @MainActor
    func testOptInLiveSFJazzFreshEventPageProducesAgentObservation() async throws {
        try await runLiveInitialCaptureProbe(url: URL(string: "https://www.sfjazz.org/tickets/productions/26-27/branford-marsalis-and-dianne-reeves-celebrate-john-coltrane/")!)
    }

    @MainActor
    func testOptInNativeRoxieTicketLinkMetadata() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: inspect public movie link metadata without clicking") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoxieLinkMetadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let taskID = "roxie-link-metadata", url = URL(string: "https://roxie.com/film/the-cycle-of-love/")!
        try browser.claim(taskID: taskID)
        _ = try await browser.navigate(taskID: taskID, operationID: "open", to: url)
        let observation = try await navigation.captureAgentObservation(taskID: taskID)
        let links = observation.approvalPageEvidence.page.links.filter { $0.label.lowercased().contains("buy tickets") }
        XCTAssertFalse(links.isEmpty)
        func webViews(_ view: NSView) -> [WKWebView] { if let web = view as? WKWebView { return [web] }; return view.subviews.flatMap(webViews) }
        let view = try XCTUnwrap(NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
        let attributes = try await view.evaluateJavaScript("""
            JSON.stringify(Array.from(document.querySelectorAll('a')).filter(a=>a.textContent.toLowerCase().includes('buy tickets')).map(a=>({text:a.textContent.trim(),attributes:Array.from(a.attributes).map(v=>[v.name,v.value]),destination:a.href,fragmentTarget:a.hash ? document.getElementById(decodeURIComponent(a.hash.slice(1)))?.outerHTML.slice(0,2048) : null})))
            """)
        let text = links.map { "\($0.id): \($0.label) -> \($0.destination)" }.joined(separator: "\n") + "\n" + String(describing: attributes)
        let attachment = XCTAttachment(string: text); attachment.name = "Roxie Buy Tickets native link metadata"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testOptInNativeBingSearchFindsOfficialMovieListing() async throws {
        try await runMovieSearchProbe(endpoint: "https://www.bing.com/search")
    }

    @MainActor
    func testOptInNativeUpstreamFaraBingSearchFindsOfficialMovieListing() async throws {
        try await runMovieSearchProbe(endpoint: "https://www.bing.com/search", upstreamFara: true)
    }

    @MainActor
    private func runMovieSearchProbe(endpoint: String, upstreamFara: Bool = false) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: one native search-provider result probe, no inference") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMovieSearch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let provider = try ComputerUseBrowserSearchProvider(endpoint: XCTUnwrap(URL(string: endpoint)), queryParameter: "q",
            queryFormat: upstreamFara ? .percentEncoded : .faraBing)
        let query = "The Cycle of Love Roxie San Francisco September 17 2026 official screening"
        var url = try provider.destination(query: query)
        if upstreamFara { url = try XCTUnwrap(URL(string: url.absoluteString.replacingOccurrences(of: "%20", with: "+") + "&FORM=QBLH")) }
        let taskID = "native-movie-search"
        try browser.claim(taskID: taskID)
        _ = try await browser.navigate(taskID: taskID, operationID: "open", to: url)
        let deadline = ContinuousClock.now + .seconds(8)
        var links: [ComputerUseBrowserPageSnapshot.Link] = [], screenshot = Data()
        repeat {
            try await Task.sleep(for: .seconds(1))
            let observation = try await navigation.captureAgentObservation(taskID: taskID)
            screenshot = observation.png; links = observation.approvalPageEvidence.page.links
            if links.contains(where: { $0.label.localizedCaseInsensitiveContains("the cycle of love") && ($0.label.localizedCaseInsensitiveContains("roxie") || $0.destination.contains("roxie.com")) }) { break }
        } while ContinuousClock.now < deadline
        let data = try JSONSerialization.data(withJSONObject: ["query": query, "requestURL": url.absoluteString,
            "currentURL": browser.currentDocument(taskID: taskID)?.committedURL.absoluteString ?? "",
            "links": links.map { ["label": $0.label, "destination": $0.destination] }], options: [.prettyPrinted, .sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); evidence.name = "Native movie search results"; evidence.lifetime = .keepAlways; add(evidence)
        let image = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png"); image.name = "Native movie search screenshot"; image.lifetime = .keepAlways; add(image)
        XCTAssertTrue(links.contains { $0.label.localizedCaseInsensitiveContains("the cycle of love") && ($0.label.localizedCaseInsensitiveContains("roxie") || $0.destination.contains("roxie.com")) }, "The same query must return an official movie listing in the actual native browser")
    }

    @MainActor
    func testOptInLiveRoxieHomePageProducesAgentObservation() async throws {
        try await runLiveInitialCaptureProbe(url: URL(string: "https://roxie.com/")!,
            goal: "Read the official Roxie cinema site", origins: ["https://roxie.com", "https://www.roxie.com"])
    }

    @MainActor
    func testOptInLiveRoxieTicketPageProducesAgentObservation() async throws {
        try await runLiveInitialCaptureProbe(url: URL(string: "https://ticketing.uswest.veezi.com/purchase/21982?siteToken=4m48btf3yavn7xjk5yxk6nc40c")!,
            goal: "Read the advertised movie ticket price without selecting tickets", origins: ["https://ticketing.uswest.veezi.com"])
    }

    @MainActor
    private func runLiveInitialCaptureProbe(url: URL, goal: String = "Read the official SFJAZZ site",
        origins: [String] = ["https://sfjazz.org", "https://www.sfjazz.org"]) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: one native public-site navigation/capture, no inference") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveNavigation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var captures: [String] = []
        let start = Date()
        let browser = ComputerUseOwnedBrowser(domScriptDidDispatch: { command in
            if command == .pageSnapshot || command == .validatePageSnapshot { captures.append("\(command.rawValue) at \(Date().timeIntervalSince(start))") }
        }, mayAct: { true }); defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let taskID = "live-native-probe"
        let session = try browser.prepareWorkflowSession(taskID: taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: taskID, prompt: goal, referenceDate: Date(), timeZoneIdentifier: "America/Los_Angeles"),
            allowedOrigins: try origins.map { try ComputerUseBrowserSourceOrigin(XCTUnwrap(URL(string: $0))) })
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        var stage = "initial capture", failure: Error?
        do {
            let captured = try await browser.captureInitialAgentObservation(taskID: taskID, expectedSessionIdentity: nil)
            let initial = try XCTUnwrap(captured)
            try await Task.sleep(for: .seconds(1))
            stage = "initial validation"; try browser.validateInitialAgentObservation(initial)
            func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            let view = try XCTUnwrap(NSApp.windows.filter { $0.isVisible && $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews).first)
            view.configuration.userContentController.addUserScript(WKUserScript(source: """
                window.__remoteDesktopReadMutations=[]; new MutationObserver(records=>{for(const r of records){window.__remoteDesktopReadMutations.push({time:performance.now(),type:r.type,tag:r.target.nodeName,id:r.target.id||'',attribute:r.attributeName,old:r.oldValue,value:r.attributeName?r.target.getAttribute(r.attributeName):null,added:r.addedNodes.length,removed:r.removedNodes.length});if(window.__remoteDesktopReadMutations.length>100)window.__remoteDesktopReadMutations.shift()}}).observe(document,{subtree:true,attributes:true,attributeOldValue:true,attributeFilter:['class','style','hidden','id','href'],childList:true,characterData:true});
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            stage = "native navigation"
            try await browser.performInitialAgentNavigation(url, observation: initial, operationID: "native-open", willBeginEffect: {})
            stage = "loaded page capture"
            let page = try await navigation.captureAgentObservation(taskID: taskID)
            let image = XCTAttachment(data: page.png, uniformTypeIdentifier: "public.png")
            image.name = "Native \(url.host ?? "live") page"; image.lifetime = .keepAlways; add(image)
            stage = "complete"
        } catch { failure = error }
        var details = "Capture stage: \(browser.lastAgentCaptureStage ?? "none")\nCapture commands: \(captures)\n"
        if let document = browser.currentDocument(taskID: taskID), let reply = try? await browser.callDOM(.pageSnapshot, arguments: ["agentInput": true], document: document) {
            details += "DOM status: \(reply.status); page: \(String(describing: reply.page)); wellFormed: \(String(describing: reply.page?.isWellFormed))\n"
            if let page = reply.page {
                details += "Invalid link URLs: \(page.links.filter { URL(string: $0.destination).flatMap(ComputerUseOwnedBrowser.validatedURL) == nil }.map(\.destination))\n"
                details += "Container roots: \(page.containers.filter { $0.parentID == nil }.count); duplicate container IDs: \(page.containers.count - Set(page.containers.map(\.id)).count); kinds: \(Set(page.containers.map(\.kind)))\n"
            }
        }
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        if let view = NSApp.windows.filter({ $0.title == "AI Browser — Remote Desktop" }).compactMap(\.contentView).flatMap(webViews).first {
            let metadata = try? await view.evaluateJavaScript("JSON.stringify({time:performance.now(),ready:document.readyState,elements:document.getElementsByTagName('*').length,width:innerWidth,height:innerHeight,mutations:window.__remoteDesktopReadMutations||[]})")
            details += "Native document metadata: \(String(describing: metadata))\n"
            if let snapshot = try? await view.takeSnapshot(configuration: nil), let tiff = snapshot.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                image.name = "Native live page diagnostic screenshot"; image.lifetime = .keepAlways; add(image)
            }
        }
        let history = try? browser.navigationDispatchHistory(taskID: taskID)
        let evidence = XCTAttachment(string: "Stage: \(stage)\nFailure: \(String(reflecting: failure))\n\(details)Attempts: \(history?.attempts.map { $0.outcome.rawValue } ?? [])\nObservations: \(history?.observations.map { "\($0.order):\($0.phase.rawValue):\($0.binding.rawValue):\($0.decision.rawValue)" } ?? [])\nCurrent document: \(browser.currentDocument(taskID: taskID)?.committedURL.absoluteString ?? "none")")
        evidence.name = "Native live \(url.host ?? "site") navigation probe"; evidence.lifetime = .keepAlways; add(evidence)
        if let failure { XCTFail("\(stage): \(failure)") }
    }

    @MainActor
    func testOptInFaraFindsLiveSFJazzConcertTicketInformation() async throws {
        try await runLiveTicketTrial(movie: false)
    }

    @MainActor
    func testOptInFaraFindsLiveRoxieMovieTimePriceAndTicketLink() async throws {
        try await runLiveTicketTrial(movie: true)
    }

    @MainActor
    private func runLiveTicketTrial(movie: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_LIVE_SITE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: bounded public website ticket-information trial, no purchase") }
        let inputs = try await FaraTestAssets.inputs(environment: environment)
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraLiveTicket-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        let taskID = movie ? "live-roxie-movie-tickets" : "live-sfjazz-ticket-information"
        let goal = movie
            ? "Find tickets for The Cycle of Love at the Roxie in San Francisco on September 17, 2026. Report the showtime, screen, runtime in minutes, general admission price including booking fee, the fee amount, and the official link for that screening. Stop before selecting tickets or purchasing."
            : "Find tickets for Branford Marsalis and Dianne Reeves at SFJAZZ on September 17, 2026. Report the start time, venue, advertised price range and official event link. Stop before purchasing."
        let session = try browser.prepareWorkflowSession(taskID: taskID)
        let officialOrigins = movie ? ["https://roxie.com", "https://www.roxie.com", "https://ticketing.uswest.veezi.com"] : ["https://www.sfjazz.org", "https://sfjazz.org"]
        let origins = try (["https://www.bing.com", "https://www.google.com", "https://www.duckduckgo.com", "https://duckduckgo.com"] + officialOrigins).map {
            try ComputerUseBrowserSourceOrigin(XCTUnwrap(URL(string: $0)))
        }
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: taskID, prompt: goal, referenceDate: Date(), timeZoneIdentifier: "America/Los_Angeles"), allowedOrigins: origins)
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        let runtime = OSAtlasLlamaRuntime()
        var responses: [[String: Any]] = [], progress: [String] = []
        let proposalLimit = 24
        let timeoutSeconds = 300
        let started = Date()
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard responses.count < proposalLimit else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            let screenshot = XCTAttachment(data: input.screenshotPNG, uniformTypeIdentifier: "public.png")
            screenshot.name = "Live browser observation \(responses.count + 1)"; screenshot.lifetime = .keepAlways; self.add(screenshot)
            let began = Date()
            let endpoint = try await runtime.activateFara(inputs)
            let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
            responses.append(["response": proposal.response, "seconds": Date().timeIntervalSince(began), "currentURL": input.currentURL?.absoluteString ?? ""])
            if movie, input.currentURL?.host == "ticketing.uswest.veezi.com" {
                // The trial is read-only. A model attempt to select tickets is
                // a failed trial; it cannot be dispatched to the live provider.
                switch proposal.action {
                case .pointer(let kind, _) where kind != .mouseMove:
                    throw ComputerUseFaraBrowserExecutor.Failure.unsupportedAction
                case .typeText, .key: throw ComputerUseFaraBrowserExecutor.Failure.unsupportedAction
                default: break
                }
            }
            return proposal
        }, readPage: { reading in
                let endpoint = try await runtime.activateFara(inputs)
                return try await runtime.readFaraPage(endpoint: endpoint, reading: reading)
            }, finishRun: { await runtime.shutdown() })
        let run = Task { try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { progress.append($0) }) }
        let timeout = Task { try await Task.sleep(for: .seconds(timeoutSeconds)); run.cancel() }
        var result: ComputerUseExecutionResult?, failure: Error?
        do { result = try await run.value } catch { failure = error }
        timeout.cancel(); await runtime.shutdown()
        let exited = try DarwinOSAtlasProcessInspector().matchingProcesses(for: inputs.llamaServerURL).isEmpty
        let history = try? browser.navigationDispatchHistory(taskID: taskID)
        let journals = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }) ?? []
        let report: [String: Any] = ["goal": goal, "responses": responses, "progress": progress, "result": String(reflecting: result),
            "proposalLimit": proposalLimit, "timeoutSeconds": timeoutSeconds,
            "lastAgentTargetStatus": browser.lastAgentTargetStatus ?? "none",
            "lastAgentCaptureStage": browser.lastAgentCaptureStage ?? "none",
            "finalDocumentURL": browser.currentDocument(taskID: taskID)?.committedURL.absoluteString ?? "none",
            "nativeDispatchJournalStatuses": journals.filter { $0.stepIDs == ["native-dispatch-returned"] }.map { $0.statuses.map(\.rawValue) },
            "nativeAttemptOutcomes": history?.attempts.map { $0.outcome.rawValue } ?? [],
            "nativeObservations": history?.observations.map { "\($0.order):\($0.phase.rawValue):\($0.binding.rawValue):\($0.decision.rawValue)" } ?? [],
            "failure": failure.map { String(reflecting: $0) } ?? "", "seconds": Date().timeIntervalSince(started), "ownedProcessExited": exited,
            "oracleCheckedOn": "2026-09-13", "oracleURL": movie
                ? "https://ticketing.uswest.veezi.com/purchase/21982?siteToken=4m48btf3yavn7xjk5yxk6nc40c"
                : "https://www.sfjazz.org/tickets/productions/26-27/branford-marsalis-and-dianne-reeves-celebrate-john-coltrane/"]
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        evidence.name = movie ? "Live Roxie Fara ticket trial" : "Live SFJAZZ Fara ticket trial"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertTrue(exited)
        if let failure { return XCTFail("Live ticket task failed after \(responses.count) proposals: \(failure)") }
        guard case .completed(let answer) = result else { return XCTFail("Live ticket task did not complete: \(String(reflecting: result))") }
        // A live-source oracle, independently checked on 2026-09-13. A changed
        // event listing requires review, not silently weakening these checks.
        let normalized = answer.lowercased()
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = detector.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)).compactMap(\.url)
        if movie {
            XCTAssertTrue(normalized.contains("6:20") && normalized.contains("pm"))
            XCTAssertTrue(normalized.contains("little roxie")); XCTAssertTrue(normalized.contains("95") && normalized.contains("min"))
            XCTAssertTrue(normalized.contains("$15.62") && normalized.contains("$1.62"))
            XCTAssertTrue(links.contains { $0.scheme == "https" && $0.host == "ticketing.uswest.veezi.com" && $0.path == "/purchase/21982"
                && URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "siteToken", value: "4m48btf3yavn7xjk5yxk6nc40c")) == true }, "The link must identify the requested screening, not the movie's other dates")
            XCTAssertTrue(responses.contains { ($0["currentURL"] as? String)?.hasPrefix("https://ticketing.uswest.veezi.com/purchase/21982?") == true }, "Prices must follow a native observation of the screening's official ticket page")
            return
        }
        XCTAssertTrue(normalized.contains("7:30") && normalized.contains("pm"))
        XCTAssertTrue(normalized.contains("miner auditorium"))
        XCTAssertTrue(normalized.contains("$55") && normalized.contains("$155"))
        let expectedPath = "/tickets/productions/26-27/branford-marsalis-and-dianne-reeves-celebrate-john-coltrane"
        XCTAssertTrue(links.contains { $0.scheme == "https" && ["sfjazz.org", "www.sfjazz.org"].contains($0.host ?? "")
            && $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.dropFirst() }, "The answer must link to the exact official event page.")
        XCTAssertTrue(responses.contains { ($0["currentURL"] as? String)?.hasPrefix("https://www.sfjazz.org/") == true }, "A claimed answer must follow an actual native observation of the official site.")
    }

    @MainActor
    func testOptInColdBrowserSnapshotLaysOutWhileHostAlreadyActive() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native initial browser layout") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let native = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false; native.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        native.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { native.close() }
        let deadline = ContinuousClock.now + .seconds(2)
        while (NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier || NSApp.keyWindow !== native) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(NSApp.keyWindow === native)
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        do {
            let captured = try await browser.captureInitialAgentObservation(taskID: "cold-layout", expectedSessionIdentity: nil)
            let observation = try XCTUnwrap(captured)
            try ComputerUseFaraModel.validatePNG(observation.png)
            try browser.validateInitialAgentObservation(observation)
        } catch {
            func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            let views = NSApp.windows.filter { $0.title == "AI Browser — Remote Desktop" }.compactMap(\.contentView).flatMap(webViews)
            XCTFail("Cold capture: \(error); browser frames: \(views.map(\.frame)); bounds: \(views.map(\.bounds))")
        }
    }

    @MainActor
    func testOptInBrowserRoutingKeepsOtherMacWindowsOnNativePathAndHonorsPause() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: owned browser and a local native form window") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraRouting-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(mayAct: { allowed }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed },
            browserNavigationTask: .init(browser: browser, journalDirectory: directory))
        _ = try await tools.captureOwnedBrowserInitialAgentObservation(taskID: "routing", expectedSessionIdentity: nil)
        XCTAssertTrue(try tools.shouldRouteToOwnedBrowserAgent())
        let native = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = NSTextField(string: "Unrelated native form")
        defer { native.close() }
        native.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while NSApp.keyWindow !== native && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(NSApp.keyWindow === native)
        XCTAssertFalse(try tools.shouldRouteToOwnedBrowserAgent())
        allowed = false
        XCTAssertThrowsError(try tools.shouldRouteToOwnedBrowserAgent()) { XCTAssertEqual($0 as? ComputerUseHostTools.ToolError, .paused) }
    }

    @MainActor
    func testOptInInitialBrowserObservationsRejectReplacementCancellationAndReusedNavigation() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native empty-browser ownership") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><h1>Local page</h1>")])
        let base = try await server.start(); defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let oldValue = try await browser.captureInitialAgentObservation(taskID: "initial-ownership", expectedSessionIdentity: nil)
        let old = try XCTUnwrap(oldValue)
        let currentValue = try await browser.captureInitialAgentObservation(taskID: "initial-ownership", expectedSessionIdentity: old.sessionIdentity)
        let current = try XCTUnwrap(currentValue)
        XCTAssertThrowsError(try browser.validateInitialAgentObservation(old))
        var effects = 0
        let cancelled = Task {
            try Task.checkCancellation()
            try await browser.performInitialAgentNavigation(base.appendingPathComponent("page"), observation: current, operationID: "cancelled", willBeginEffect: { effects += 1 })
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled initial navigation must not run") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects, 0); XCTAssertTrue(server.requestedPaths.isEmpty)
        try await browser.performInitialAgentNavigation(base.appendingPathComponent("page"), observation: current, operationID: "first", willBeginEffect: { effects += 1 })
        XCTAssertEqual(effects, 1); XCTAssertEqual(server.count("/page"), 1)
        do {
            try await browser.performInitialAgentNavigation(base.appendingPathComponent("page"), observation: current, operationID: "replay", willBeginEffect: { effects += 1 })
            XCTFail("An initial observation must be single-use")
        } catch { }
        try browser.claim(taskID: "successor")
        do {
            _ = try await browser.captureInitialAgentObservation(taskID: "initial-ownership", expectedSessionIdentity: old.sessionIdentity)
            XCTFail("An old task cannot reclaim the successor's browser")
        } catch { }
        XCTAssertEqual(browser.taskID, "successor")
        XCTAssertEqual(effects, 1); XCTAssertEqual(server.count("/page"), 1)
    }

    @MainActor
    func testOptInFailedInitialFaraSearchCannotReplayOrRestartItsJournal() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: one failed initial search") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let path = "/search?q=concerts"
        let server = try OwnedBrowserHTTPFixture(routes: [path: .init(status: 500, body: "Search unavailable")])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraInitialFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("navigation")))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"),
            searchProvider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"), propose: { _ in
                calls += 1
                let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"web_search","query":"concerts"}}</tool_call>"#
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
        do {
            _ = try await executor.execute(taskID: "initial-failure", prompt: "Find concerts", trustedUserPrompt: "Find concerts", tools: tools, progress: { _ in })
            XCTFail("A failed first request cannot complete")
        } catch { }
        let retried = try await executor.execute(taskID: "initial-failure", prompt: "Find concerts", trustedUserPrompt: "Find concerts", tools: tools, progress: { _ in })
        guard case .unableToComplete = retried else { return XCTFail("Uncertain navigation requires manual reconciliation") }
        let restarted = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            XCTFail("Restart must not reconstruct missing live history"); throw ComputerUseFaraBrowserExecutor.Failure.recoveredTask
        })
        do {
            _ = try await restarted.execute(taskID: "initial-failure", prompt: "Find concerts", trustedUserPrompt: "Find concerts", tools: tools, progress: { _ in })
            XCTFail("A restarted executor must reject this journal")
        } catch { XCTAssertEqual(error as? ComputerUseFaraBrowserExecutor.Failure, .recoveredTask) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(server.count(path), 1)
        let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(journals.first { $0.stepIDs == ["native-dispatch-returned"] }?.statuses, [.uncertain])
    }

    @MainActor
    func testOptInFaraStartsFromEmptyBrowserThenSearchesOnceWithOriginalGoal() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: visible blank browser and one controlled search")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let path = "/search?q=Tokyo%20concerts"
        let server = try OwnedBrowserHTTPFixture(routes: [path: .init(body: "<!doctype html><title>Tokyo concerts</title><h1>Tokyo Music Hall</h1><p>Friday, 7 pm. Tickets: 2400 JPY.</p>")])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraEmpty-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("navigation")))
        XCTAssertNil(browser.taskID)
        let goal = "Find a Tokyo concert and report its ticket price, time and source."
        let source = base.absoluteString + path
        let answer = "Tokyo Music Hall: 2400 JPY, Friday 7 pm. Source: " + source
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"),
            searchProvider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"), propose: { input in
                XCTAssertEqual(input.goal, goal)
                XCTAssertEqual(input.history.count, calls)
                try ComputerUseFaraModel.validatePNG(input.screenshotPNG)
                guard calls < 2 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                if calls == 0 {
                    XCTAssertNil(input.currentURL, "An empty browser is not a navigated page.")
                    XCTAssertTrue(server.requestedPaths.isEmpty, "Starting the agent must not invent an initial website.")
                    let image = XCTAttachment(data: input.screenshotPNG, uniformTypeIdentifier: "public.png")
                    image.name = "Actual initial empty browser"; image.lifetime = .keepAlways; self.add(image)
                } else {
                    XCTAssertEqual(input.currentURL?.absoluteString, source)
                    XCTAssertNil(input.history.first?.currentURL)
                    XCTAssertEqual(server.count(path), 1)
                }
                let action: [String: Any] = calls == 0 ? ["action": "web_search", "query": "Tokyo concerts"] : ["action": "terminate", "answer": answer]
                let json = try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": action])
                let response = "<tool_call>" + String(decoding: json, as: UTF8.self) + "</tool_call>"
                calls += 1
                return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
            })
        let result: ComputerUseExecutionResult
        do {
            result = try await executor.execute(taskID: "fara-empty", prompt: "Untrusted old assistant context", trustedUserPrompt: goal, tools: tools, progress: { _ in })
        } catch {
            XCTFail("Empty-browser task failed after \(calls) proposals and requests \(server.requestedPaths): \(String(reflecting: error))")
            return
        }
        XCTAssertEqual(result, .completed(answer))
        let repeated = try await executor.execute(taskID: "fara-empty", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(repeated, result)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(server.requestedPaths, [path])
    }

    @MainActor
    func testOptInFaraScrollMatchesViewportDirectionAndRetiresObservation() async throws {
        try await runFaraViewportScroll(observesWheel: false)
    }

    @MainActor
    func testOptInFaraScrollWorksWithPageWheelListenersWithoutPostingWheelEvents() async throws {
        try await runFaraViewportScroll(observesWheel: true)
    }

    @MainActor
    private func runFaraViewportScroll(observesWheel: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in owned-browser scroll contract") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <!doctype html><style>body{margin:0;width:400vw;height:400vh;background:linear-gradient(white,lightblue)}</style>
            <h1 style='position:fixed'>Local scroll fixture</h1>
            <script>addEventListener('scroll',()=>fetch('/scrolled?x='+scrollX+'&y='+scrollY));
            \(observesWheel ? "addEventListener('wheel',event=>fetch('/wheel?dx='+event.deltaX+'&dy='+event.deltaY+'&trusted='+event.isTrusted),{passive:true});" : "")</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "native-scroll")
        let document = try await browser.navigate(taskID: "native-scroll", operationID: "open", to: base.appendingPathComponent("page"))
        var checkpoints: [[String: Any]] = []
        defer {
            let report: [String: Any] = ["checkpoints": checkpoints, "requests": server.requestedPaths]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Owned-browser scroll checkpoints"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for (horizontal, pixels) in [(false, -500.0), (false, 250.0), (true, 500.0), (true, -250.0)] {
            let before = try await browser.captureAgentObservation(document: document)
            let initial = try XCTUnwrap(before.approvalPageEvidence.page.viewport)
            let delta = (pixels * (horizontal ? initial.width : initial.height) / 1000).rounded(.towardZero)
            let expectedX = initial.x + (horizontal ? delta : 0)
            let expectedY = initial.y - (horizontal ? 0 : delta)
            var dispatches = 0
            do {
                try await browser.performAgentInput(.scroll(horizontal: horizontal, pixels: pixels), observation: before,
                    willBeginEffect: { dispatches += 1 })
            } catch { return XCTFail("Owned-browser scroll failed before observing movement: \(error)") }
            let deadline = ContinuousClock.now + .seconds(2)
            var actual: ComputerUseBrowserViewport?
            repeat {
                try await Task.sleep(for: .milliseconds(20))
                actual = try await browser.observePage(document: document).page.viewport
            } while ContinuousClock.now < deadline && (abs((actual?.x ?? -1) - expectedX) > 1 || abs((actual?.y ?? -1) - expectedY) > 1)
            let moved = try XCTUnwrap(actual)
            checkpoints.append(["horizontal": horizontal, "pixels": pixels, "beforeX": initial.x, "beforeY": initial.y,
                "expectedX": expectedX, "expectedY": expectedY, "afterX": moved.x, "afterY": moved.y])
            XCTAssertEqual(moved.x, expectedX, accuracy: 1, "horizontal=\(horizontal), pixels=\(pixels)")
            XCTAssertEqual(moved.y, expectedY, accuracy: 1, "horizontal=\(horizontal), pixels=\(pixels)")
            XCTAssertEqual(dispatches, 1)
            do {
                try await browser.performAgentInput(.scroll(horizontal: horizontal, pixels: pixels), observation: before,
                    willBeginEffect: { dispatches += 1 })
                XCTFail("A scroll reused its consumed observation")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(dispatches, 1)
        }
        XCTAssertTrue(server.requestedPaths.contains { $0.hasPrefix("/scrolled?") })
        if observesWheel {
            let events = server.requestedPaths.filter { $0.hasPrefix("/wheel?") }
            XCTAssertEqual(events.count, 0)
        }
    }

    @MainActor
    func testOptInFaraScrollKeepsNestedContainerAtItsBoundary() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in nested scroll target") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <!doctype html><style>body{margin:0;height:300vh}.panel{position:fixed;top:10vh;width:40vw;height:80vh;overflow:auto;overscroll-behavior:contain;scroll-behavior:smooth}
            #left{left:0}#right{right:0}.inside{height:300vh}button{position:absolute;left:10vw;top:10vh;width:20vw;height:10vh}</style>
            <div id='left' class='panel'><div class='inside'><button>Focus these results</button></div></div>
            <div id='right' class='panel'><div class='inside'>Other results</div></div>
            <script>left.addEventListener('scroll',()=>fetch('/left?y='+left.scrollTop+'&max='+(left.scrollHeight-left.clientHeight)));right.addEventListener('scroll',()=>fetch('/wrong'));</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        try browser.claim(taskID: "nested-scroll")
        let document = try await browser.navigate(taskID: "nested-scroll", operationID: "open", to: base.appendingPathComponent("page"))
        let initial = try await browser.captureAgentObservation(document: document)
        try await browser.performAgentInput(.pointer(.leftClick, .init(x: 200, y: 250)), observation: initial)
        for (index, pixels) in [-500.0, -10_000.0, -10_000.0].enumerated() {
            let observation = try await browser.captureAgentObservation(document: document)
            try await browser.performAgentInput(.scroll(horizontal: false, pixels: pixels), observation: observation)
            let deadline = ContinuousClock.now + .seconds(1)
            while server.requestedPaths.filter({ $0.hasPrefix("/left?") }).count < min(index + 1, 2) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let current = try await browser.observePage(document: document)
        XCTAssertEqual(current.page.viewport?.y, 0, "Scrolling the left panel must preserve the page")
        let deadline = ContinuousClock.now + .seconds(2)
        while server.requestedPaths.filter({ $0.hasPrefix("/left?") }).count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.requestedPaths.filter { $0.hasPrefix("/left?") }.count, 2)
        let finalPath = try XCTUnwrap(server.requestedPaths.last { $0.hasPrefix("/left?") })
        let fields = try XCTUnwrap(URLComponents(string: "http://fixture" + finalPath)?.queryItems)
        XCTAssertEqual(fields.first { $0.name == "y" }?.value, fields.first { $0.name == "max" }?.value)
        XCTAssertEqual(server.count("/wrong"), 0)
    }

    @MainActor
    func testOptInFaraScrollDoesNotMoveLockedPageBehindOverlay() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in locked page scrolling") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for lockedElement in ["html", "body"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
                <!doctype html><style>\(lockedElement){overflow:hidden}body{margin:0;height:300vh}.overlay{position:fixed;inset:0;background:#eee}</style>
                <h1>Background results</h1><div class='overlay'>Dialog over a locked page</div>
                """)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: lockedElement)
            let document = try await browser.navigate(taskID: lockedElement, operationID: "open", to: base.appendingPathComponent("page"))
            let observation = try await browser.captureAgentObservation(document: document)
            try await browser.performAgentInput(.scroll(horizontal: false, pixels: -500), observation: observation)
            let current = try await browser.observePage(document: document)
            XCTAssertEqual(current.page.viewport?.y, 0, lockedElement)
        }
    }

    @MainActor
    func testOptInFaraScrollRejectsInvalidCancelledAndRevokedInput() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in scroll rejection") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<!doctype html><body style='height:300vh'>Scroll rejection fixture</body>")])
        let base = try await server.start()
        defer { server.stop() }
        for mode in ["nan", "infinite", "over-limit", "cancelled", "revoked", "revoked-at-dispatch"] {
            var allowed = true
            let browser = ComputerUseOwnedBrowser(mayAct: { allowed })
            defer { browser.close() }
            try browser.claim(taskID: mode)
            let document = try await browser.navigate(taskID: mode, operationID: "open", to: base.appendingPathComponent("page"))
            let observation = try await browser.captureAgentObservation(document: document)
            let pixels: Double = mode == "nan" ? .nan : mode == "infinite" ? .infinity : mode == "over-limit" ? 10_001 : -500
            if mode == "revoked" { allowed = false }
            var attempts = 0
            let task = Task { @MainActor in
                try await browser.performAgentInput(.scroll(horizontal: false, pixels: pixels), observation: observation,
                    willBeginEffect: { attempts += 1; if mode == "revoked-at-dispatch" { allowed = false } })
            }
            if mode == "cancelled" { task.cancel() }
            do { try await task.value; XCTFail("Scroll admitted \(mode)") } catch { }
            XCTAssertEqual(attempts, mode == "revoked-at-dispatch" ? 1 : 0, mode)
            allowed = true
            let current = try await browser.observePage(document: document)
            XCTAssertEqual(current.page.viewport?.y, 0, mode)
        }
    }

    @MainActor
    func testOptInFaraScrollObservesRevealedContentAndJournalsOnce() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in Fara scroll workflow") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: """
            <!doctype html><style>body{margin:0;height:300vh;font:26px system-ui}#result{position:absolute;top:110vh}</style>
            <h1>Concert results</h1><p>More results below</p><h2 id='result'>Tokyo Music Hall: 2400 JPY, 7 pm</h2>
            <script>let revealed=false; addEventListener('scroll',()=>{if(!revealed && document.getElementById('result').getBoundingClientRect().bottom<innerHeight){revealed=true;fetch('/revealed')}});</script>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraScroll-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "scroll-result")
        _ = try await browser.navigate(taskID: "scroll-result", operationID: "open", to: base.appendingPathComponent("page"))
        var calls = 0
        var initialImage: Data?
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard calls < 2 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            if calls == 0 { initialImage = input.screenshotPNG; XCTAssertEqual(server.count("/revealed"), 0) }
            else {
                let image = XCTAttachment(data: input.screenshotPNG, uniformTypeIdentifier: "public.png")
                image.name = "Result observation after scrolling"; image.lifetime = .keepAlways; self.add(image)
                // The independent page receipt uses fetch; network delivery may
                // follow snapshot delivery even when the result is already visible.
                let deadline = ContinuousClock.now + .seconds(1)
                while server.count("/revealed") == 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(server.count("/revealed"), 1, "The next proposal must observe the revealed result")
                XCTAssertNotEqual(input.screenshotPNG, initialImage)
                XCTAssertEqual(input.history.count, 1)
            }
            let action = calls == 0 ? #"{"action":"scroll","pixels":-600}"# : #"{"action":"terminate","answer":"2400 JPY, 7 pm"}"#
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + action + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            let result = try await executor.execute(taskID: "scroll-result", prompt: "Find the concert price and start time.", trustedUserPrompt: "Find the concert price and start time.", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("2400 JPY, 7 pm"))
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(server.count("/revealed"), 1)
            let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.allSatisfy { $0.statuses == [.verified] })
            let repeated = try await executor.execute(taskID: "scroll-result", prompt: "Find the concert price and start time.", trustedUserPrompt: "Find the concert price and start time.", tools: tools, progress: { _ in })
            XCTAssertEqual(repeated, result)
            XCTAssertEqual(calls, 2)
        } catch { XCTFail("Fara scroll workflow failed after \(calls) proposals: \(error)") }
    }

    @MainActor
    func testOptInFocusedTargetRejectsReadOnlyAndNonTextControls() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in writable focus check") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for control in ["<input id='target' aria-label='Reference' readonly>",
                        "<textarea id='target' aria-label='Reference' readonly></textarea>",
                        "<button id='target'>Next</button>", "<a id='target' href='/next'>Next</a>",
                        "<input id='target' type='checkbox' aria-label='Choice'>",
                        "<select id='target' aria-label='Destination'><option>Tokyo</option></select>"] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
                \(control)<script>requestAnimationFrame(()=>{document.getElementById('target').focus();fetch('/focused');});</script>
                """)])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: "writable-focus")
            let document = try await browser.navigate(taskID: "writable-focus", operationID: "open", to: base.appendingPathComponent("form"))
            let deadline = ContinuousClock.now + .seconds(3)
            while server.count("/focused") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(server.count("/focused"), 1)
            let observation = try await browser.captureAgentObservation(document: document)
            let inspected = try await browser.inspectAgentTarget(.typeText("123456"), observation: observation)
            let target = try XCTUnwrap(inspected)
            XCTAssertTrue(target.context.isEmpty, "Typing must not be admitted to: \(control)")
        }
    }

    @MainActor
    func testOptInNativeTargetCannotAuthorizeAnotherPointOrObservation() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in native target binding") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <button style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh' onclick="fetch('/clicked')">Save changes</button>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        for scenario in ["different-point", "different-observation"] {
            let browser = ComputerUseOwnedBrowser(mayAct: { true })
            defer { browser.close() }
            try browser.claim(taskID: scenario)
            let document = try await browser.navigate(taskID: scenario, operationID: "open", to: base.appendingPathComponent("form"))
            var observation = try await browser.captureAgentObservation(document: document)
            let action = ComputerUseFaraAction.pointer(.leftClick, .init(x: 500, y: 250))
            let inspected = try await browser.inspectAgentTarget(action, observation: observation)
            let target = try XCTUnwrap(inspected)
            XCTAssertTrue(target.context.contains("Save changes"))
            let attempted: ComputerUseFaraAction
            if scenario == "different-point" { attempted = .pointer(.leftClick, .init(x: 600, y: 250)) }
            else { observation = try await browser.captureAgentObservation(document: document); attempted = action }
            var dispatches = 0
            do {
                try await browser.performAgentInput(attempted, observation: observation, target: target, willBeginEffect: { dispatches += 1 })
                XCTFail("Target evidence authorized a different proposal or observation")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            _ = try await browser.observePage(document: document)
            XCTAssertEqual(dispatches, 0)
            XCTAssertEqual(server.count("/clicked"), 0)
        }
    }

    @MainActor
    func testOptInUnidentifiedBrowserControlHandsBackWithoutClickOrFurtherProposal() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in unidentified-control handback") }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <canvas style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh;background:gray' onclick="fetch('/clicked')"></canvas>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraUnknown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        try browser.claim(taskID: "unknown-control")
        let document = try await browser.navigate(taskID: "unknown-control", operationID: "open", to: base.appendingPathComponent("form"))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            calls += 1
            guard calls == 1 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            let response = #"<tool_call>{"name":"computer_use","arguments":{"action":"left_click","coordinate":[500,250]}}</tool_call>"#
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        let result = try await executor.execute(taskID: "unknown-control", prompt: "Open the canvas item", trustedUserPrompt: "Open the canvas item", tools: tools, progress: { _ in })
        guard case .userInterventionRequired = result else { return XCTFail("An unidentified control must hand back before input") }
        _ = try await browser.observePage(document: document)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(server.count("/clicked"), 0)
        let records = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.stepIDs, ["model-assessed-completion"])
        XCTAssertEqual(records.first?.statuses, [.attempted])
    }

    @MainActor
    func testOptInFaraHoldsConsequentialClickBeforeNativeDispatch() async throws {
        try await runFaraApprovalLifecycle(mode: .hold)
    }

    @MainActor
    func testOptInFaraApprovalRejectsForgedAndDuplicateContinuations() async throws {
        try await runFaraApprovalLifecycle(mode: .perform)
    }

    @MainActor
    func testOptInFaraApprovalCancellationBeforeDispatchRetiresAuthority() async throws {
        try await runFaraApprovalLifecycle(mode: .cancelBefore)
    }

    @MainActor
    func testOptInFaraApprovalCancellationAfterDispatchDoesNotReplayTheEffect() async throws {
        try await runFaraApprovalLifecycle(mode: .cancelAfter)
    }

    private enum ApprovalTestMode { case hold, perform, cancelBefore, cancelAfter }

    @MainActor
    private func runFaraApprovalLifecycle(mode: ApprovalTestMode) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: a fictional Save changes button must await approval")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><title>Fictional settings</title><button style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh' onclick="fetch('/saved')">Save changes</button>
            """)])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraApproval-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        defer { browser.close() }
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            approvalTargetProvider: { _ in .init(context: "AXButton Save changes", applicationID: "fixture.browser", accessibilityIdentity: "save-button") },
            browserNavigationTask: navigation, accessibilityContextProvider: { _ in "AXButton Save changes" })
        try browser.claim(taskID: "fara-approval")
        _ = try await browser.navigate(taskID: "fara-approval", operationID: "open", to: base.appendingPathComponent("form"))
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { _ in
            guard calls < 2 else { throw ComputerUseFaraAction.Failure.invalidResponse }
            let action = calls == 0 ? #"{"action":"left_click","coordinate":[500,250]}"# : #"{"action":"terminate","answer":"Saved."}"#
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + action + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        do {
            let result = try await executor.execute(taskID: "fara-approval", prompt: "Save these settings.", trustedUserPrompt: "Save these settings.", tools: tools, progress: { _ in })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(server.count("/saved"), 0)
            guard case .approvalRequired(_, let action, let continuation) = result else { XCTFail("Consequential input bypassed approval"); return }
            XCTAssertEqual(continuation.taskID, "fara-approval")
            XCTAssertNotNil(continuation.browserPageEvidence)
            let repeated = try await executor.execute(taskID: "fara-approval", prompt: "Save these settings.", trustedUserPrompt: "Save these settings.", tools: tools, progress: { _ in })
            XCTAssertEqual(repeated, result)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(server.count("/saved"), 0)
            if mode == .hold { return }
            let fingerprint = ComputerUseApprovalFingerprint(action: action, applicationID: "fixture.browser", accessibilityIdentity: "save-button", visualDigest: nil)
            var begins = 0
            func perform(_ token: ComputerUseVisualApprovalContinuation, action proposed: ComputerUsePredictedAction? = nil) async throws {
                try await executor.performApprovedVisualAction(token, action: proposed ?? action, fingerprint: fingerprint,
                    tools: tools, willBeginEffect: { begins += 1 })
            }
            let forged = ComputerUseVisualApprovalContinuation(taskID: continuation.taskID, nonce: UUID(), browserPageEvidence: continuation.browserPageEvidence)
            do { try await perform(forged); XCTFail("A forged continuation authorized input") }
            catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
            do { try await perform(continuation, action: .wait); XCTFail("An approval authorized a different action") }
            catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
            executor.cancelVisualApprovalContinuation(forged)
            if mode == .cancelBefore {
                executor.cancelVisualApprovalContinuation(continuation)
                do { try await perform(continuation); XCTFail("Cancelled authority authorized input") }
                catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
                XCTAssertEqual(begins, 0); XCTAssertEqual(server.count("/saved"), 0)
                return
            }
            try await perform(continuation)
            XCTAssertEqual(begins, 1)
            do { try await perform(continuation); XCTFail("An approved input was posted twice") }
            catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
            if mode == .cancelAfter {
                executor.cancelVisualApprovalContinuation(continuation)
                do {
                    _ = try await executor.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: { _ in })
                    XCTFail("Cancelled post-effect continuation resumed")
                } catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
                let stopped = try await executor.execute(taskID: "fara-approval", prompt: "Save these settings.", trustedUserPrompt: "Save these settings.", tools: tools, progress: { _ in })
                guard case .unableToComplete = stopped else { XCTFail("Interrupted approved effect was reconstructed"); return }
                XCTAssertEqual(calls, 1)
            } else {
                let finished = try await executor.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: { _ in })
                XCTAssertEqual(finished, .completed("Saved."))
                XCTAssertEqual(calls, 2)
                do {
                    _ = try await executor.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: { _ in })
                    XCTFail("A continuation was consumed twice")
                } catch ComputerUseFaraBrowserExecutor.Failure.invalidApproval { }
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while server.count("/saved") == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(begins, 1); XCTAssertEqual(server.count("/saved"), 1)
            let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("fara"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(journals.count, 2)
            XCTAssertEqual(journals.first { $0.stepIDs == ["native-dispatch-returned"] }?.statuses, [.verified])
            XCTAssertEqual(journals.first { $0.stepIDs == ["model-assessed-completion"] }?.statuses, [mode == .cancelAfter ? .attempted : .verified])
        } catch { XCTFail("Approval fixture failed: \(error)") }
    }

    @MainActor
    func testOptInManagedFaraOpensControlledConcertResultAndReportsSource() async throws {
        try await runManagedFaraConcertResult(scrollFirst: false)
    }

    @MainActor
    func testOptInManagedFaraScrollsToConcertResultAndReportsSource() async throws {
        try await runManagedFaraConcertResult(scrollFirst: true)
    }

    @MainActor
    func testOptInProductionFaraLoaderActivatesThenOpensConcertResultAndReleasesWorker() async throws {
        try await runManagedFaraConcertResult(scrollFirst: false, productionLoader: true)
    }

    @MainActor
    func testOptInProductionFaraStartsFromEmptyBrowserAndFindsConcertSource() async throws {
        try await runManagedFaraConcertResult(scrollFirst: false, productionLoader: true, startEmpty: true)
    }

    @MainActor
    private func runManagedFaraConcertResult(scrollFirst: Bool, productionLoader: Bool = false, startEmpty: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_SEARCH_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: actual Fara on a fictional search and concert page")
        }
        let inputs = try await FaraTestAssets.inputs(environment: environment)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let searchPath = "/search?q=Tokyo%20Music%20Hall%20concerts"
        let style = "<style>body{font:26px system-ui;background:white;color:#111;margin:50px}a{display:block;padding:24px;background:#eef4ff}</style>"
        let spacer = scrollFirst ? "<p>More results below</p><div style='height:85vh'></div><script>addEventListener('scroll',()=>fetch('/scrolled'));</script>" : ""
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<!doctype html><title>Local search results</title>" + style + "<h1>Concert search results</h1>" + spacer + "<a href='/details'>Tokyo Music Hall — concert times and tickets</a>"),
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
        if !startEmpty { _ = try await browser.navigate(taskID: "fara-search-model", operationID: "open", to: base.appendingPathComponent("start")) }
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
        let goal = (startEmpty ? "Visit \(base.appendingPathComponent("start").absoluteString). " : "")
            + (scrollFirst ? "Scroll down to find the Tokyo Music Hall concert in these search results. " : "Find the Tokyo Music Hall concert in these search results. ")
            + "Open its details and report the ticket price and start time with the source URL."
        let started = Date()
        let executor: any ComputerUseExecuting
        if productionLoader {
            let loader = OSAtlasVisualExecutorLoader(runtime: runtime, faraJournalDirectory: directory.appendingPathComponent("fara"))
            let receipt = ComputerUseInstallationReceipt(installationVersion: ComputerUseArtifactManifest.current.installationVersion,
                modelVariant: .fara15_4B, modelDirectory: inputs.modelURL.deletingLastPathComponent().path, installedAt: Date())
            executor = ComputerUseDeferredVisualExecutor(loader: { progress in
                let loaded = try await loader.load(receipt: receipt, progress: progress)
                XCTAssertTrue(loaded is ComputerUseFaraBrowserExecutor)
                XCTAssertTrue(loaded.isReady)
                XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty,
                    "Verified setup must leave the model worker idle until a task needs it.")
                return loaded
            }, abandon: { _ in await loader.deactivate() })
        } else {
            executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"),
            searchProvider: .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"), propose: { input in
                guard responses.count < 6 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let began = Date()
                let endpoint = try await runtime.activateFara(inputs)
                let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
                responses.append(["response": proposal.response, "seconds": Date().timeIntervalSince(began),
                    "currentURL": input.currentURL?.absoluteString ?? ""])
                return proposal
            }, readPage: { reading in
                let endpoint = try await runtime.activateFara(inputs)
                return try await runtime.readFaraPage(endpoint: endpoint, reading: reading)
            }, finishRun: { await runtime.shutdown() })
        }
        var result: ComputerUseExecutionResult?, failure: Error?
        do {
            result = try await executor.execute(taskID: "fara-search-model", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        } catch { failure = error }
        await runtime.shutdown()
        memory.cancel()
        let measured = await memory.value
        let gone = try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty
        let reportedAnswer: String
        if case .completed(let answer) = result { reportedAnswer = answer } else { reportedAnswer = "" }
        let report: [String: Any] = ["scope": startEmpty ? "production-Fara-empty-browser-concert-result" : (productionLoader ? "production-Fara-loader-controlled-concert-result" : (scrollFirst ? "actual-Fara-controlled-scroll-concert-result" : "actual-Fara-controlled-concert-result-navigation")), "targetMacRAMGB": 12,
            "wholeApp12GBQualified": false, "liveWebsiteQualified": false, "responses": responses,
            "reportedAnswer": reportedAnswer,
            "requests": server.requestedPaths, "elapsedSeconds": Date().timeIntervalSince(started),
            "peakSampledProcessMemoryBytes": measured.0, "memorySamples": measured.1, "ownedProcessExited": gone,
            "failure": failure.map { String(describing: $0) } ?? ""]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Fara controlled concert search evidence"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(gone)
        if let failure { XCTFail("Controlled Fara search failed: \(failure)"); return }
        guard case .completed(let answer) = result else { XCTFail("Fara did not return a completed research answer"); return }
        let normalized = answer.lowercased().replacingOccurrences(of: ",", with: "")
        XCTAssertNotNil(normalized.range(of: #"(?:\b2400\s*(?:jpy|yen)\b|(?:\bjpy\s*|¥\s*)2400\b)"#, options: .regularExpression))
        XCTAssertNotNil(normalized.range(of: #"\b(?:7(?::00)?\s*p\.?m\.?|19:00)\b"#, options: .regularExpression))
        XCTAssertTrue(answer.contains(base.appendingPathComponent("details").absoluteString))
        XCTAssertEqual(server.count(searchPath), 0)
        XCTAssertEqual(server.count("/details"), 1)
        if scrollFirst { XCTAssertGreaterThan(server.count("/scrolled"), 0) }
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
    func testOptInFaraNewContextTicketLinkStopsBeforeReadingLoginAndRejectsEarlyResume() async throws {
        try await runFaraSearchOutcome(login: true, viaLink: true)
    }

    @MainActor
    private func runFaraSearchOutcome(login: Bool, viaLink: Bool = false) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else {
            throw XCTSkip("Opt-in: native search reaches an error or simulated login")
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/start": .init(body: "<!doctype html><a href='/search?q=concerts' target='_blank' style='position:fixed;left:20vw;top:20vh;width:60vw;height:10vh'>Buy Tickets</a>"),
            "/search?q=concerts": .init(status: login ? 200 : 500,
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
                let response = viaLink
                    ? #"<tool_call>{"name":"computer_use","arguments":{"action":"left_click","coordinate":[500,250]}}</tool_call>"#
                    : #"<tool_call>{"name":"computer_use","arguments":{"action":"web_search","query":"concerts"}}</tool_call>"#
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
            XCTAssertTrue(parts.compactMap { $0["text"] as? String }.flatMap { $0.components(separatedBy: "\n") }.contains("Current URL: " + sources[index].absoluteString), "Missing URL at observation \(index)")
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
