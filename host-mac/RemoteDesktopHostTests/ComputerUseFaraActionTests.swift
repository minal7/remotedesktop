import Foundation
import CryptoKit
import AppKit
import WebKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseFaraActionTests: XCTestCase {
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
        let inputs = try await verifiedFaraRuntimeInputs(environment: environment)
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

    private func verifiedFaraRuntimeInputs(environment: [String: String]) async throws -> ComputerUseFaraRuntimeInputs {
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
