import AppKit
import CryptoKit
import XCTest
@testable import RemoteDesktopHost
@testable import RemoteDesktopClientCore

private typealias ClientModel = RemoteDesktopClientCore.ComputerUseSessionModel
private typealias ClientEnvelope = RemoteDesktopClientCore.ComputerUseEnvelope
private typealias HostEnvelope = RemoteDesktopHost.ComputerUseEnvelope
private typealias ClientUpdate = RemoteDesktopClientCore.ComputerUseTaskUpdate
private typealias FormOracle = ComputerUseOwnedBrowserModelAcceptanceTests

@MainActor
final class ComputerUseClarificationCompositionTests: XCTestCase {
    func testOptInShippedClientAnswersFaraQuestionWithoutRepeatingEarlierEdit() async throws {
        try await runFaraQuestionComposition(initialQuestion: false)
    }

    func testOptInShippedClientAnswersFaraQuestionBeforeFirstNavigation() async throws {
        try await runFaraQuestionComposition(initialQuestion: true)
    }

    func testOptInShippedClientFaraAnswerRetainsLoginUntilExplicitResume() async throws {
        try await runFaraQuestionComposition(initialQuestion: false, login: .resume)
    }

    func testOptInShippedClientStopRetiresFaraAnsweredBrowserDuringLogin() async throws {
        try await runFaraQuestionComposition(initialQuestion: false, login: .stop)
    }

    private enum FaraQuestionLogin { case resume, stop }

    private func runFaraQuestionComposition(initialQuestion: Bool, login: FaraQuestionLogin? = nil) async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: native Fara question/client continuation") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><style>label,input{position:fixed;left:20vw}input{width:60vw;height:10vh}#origin{top:20vh}#destination{top:55vh}</style>
            <label for='origin' style='top:12vh'>Origin</label><input id='origin'>
            <label for='destination' style='top:47vh'>Destination</label><input id='destination'>
            <script>document.addEventListener('input',e=>fetch('/edit?field='+e.target.id+'&value='+encodeURIComponent(e.target.value),{keepalive:true}));</script>
            """ + (login == nil ? "" : """
            <script>fetch('/hold-for-login').then(()=>{
                const password=document.createElement('input');password.type='password';password.value='private-fixture-password';
                document.body.prepend(password);fetch('/login-shown');
                fetch('/hold-for-return').then(()=>{password.remove();fetch('/logged-in')});
            });</script>
            """)), "/hold-for-login": .init(held: true), "/hold-for-return": .init(held: true)])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraQuestion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID, sessionID: sessionID, pairingCode: pairingCode)
        let original = "In the browser, enter Tokyo in Origin. Ask me for the destination city, then fill Destination with my answer."
        let question = "Which city should I enter in Destination?", answer = "Kyoto"
        var actions = ["{\"action\":\"visit_url\",\"url\":\"\(base.appendingPathComponent("form").absoluteString)\"}",
            #"{"action":"left_click","coordinate":[500,250]}"#, #"{"action":"type","text":"Tokyo"}"#,
            "{\"action\":\"ask_user_question\",\"question\":\"\(question)\"}",
            #"{"action":"left_click","coordinate":[500,600]}"#, #"{"action":"type","text":"Kyoto"}"#,
            #"{"action":"terminate","answer":"Origin is Tokyo and Destination is Kyoto."}"#]
        if initialQuestion { actions.insert(actions.remove(at: 3), at: 0) }
        var calls = 0, nativeAdmissions = 0, loads = 0, finishedRuns = 0
        let fara = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard calls < actions.count else { throw CompositionFailure.incomplete("Question continuation replayed work") }
            XCTAssertEqual(input.goal, original); XCTAssertEqual(input.history.count, calls)
            if calls == (initialQuestion ? 1 : 4) {
                let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
                XCTAssertEqual(content.last?["text"] as? String, initialQuestion ? answer : "Current URL: \(base.appendingPathComponent("form").absoluteString)\n\(answer)")
                XCTAssertTrue(input.history.last?.response.contains("ask_user_question") == true)
            }
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + actions[calls] + "}</tool_call>"
            calls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        }, finishRun: { finishedRuns += 1 })
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in loads += 1; return fara })
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeAdmissions += 1; return nil }, desktopFactory: { _ in deferred })
        var browser: ComputerUseOwnedBrowser?
        let manager = HostComputerUseManager(injector: InputInjector(), executor: executor,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                let owned = ComputerUseOwnedBrowser(mayAct: mayAct); browser = owned
                return .init(browser: owned, journalDirectory: directory.appendingPathComponent("browser"))
            }, allowsExternalServices: false, channelFactory: { _ in mailbox })
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: CompositionPendingStore(), channel: bridge, promptRefreshInterval: .seconds(600))
        defer { client.stop(); manager.stop() }
        manager.authorizePeer(senderID: clientID); client.start()
        XCTAssertTrue(client.sendPrompt(original))
        try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
        XCTAssertEqual(calls, initialQuestion ? 1 : 4); XCTAssertEqual(finishedRuns, 1)
        XCTAssertEqual(server.count("/edit?field=origin&value=Tokyo"), initialQuestion ? 0 : 1)
        guard case .answer(let reference, _) = client.composerMode else {
            return XCTFail("Fara's question must retain an answer reference: \(client.messages.map(\.text))")
        }
        XCTAssertEqual(client.messages.last(where: { $0.author == .assistant })?.text, question)
        let rootID = reference.taskID
        XCTAssertEqual(browser?.taskID, rootID)
        if login != nil {
            try await pumpHost(manager, mailbox: mailbox) { server.count("/hold-for-login") == 1 }
            server.releaseHeldResponses()
            try await pumpHost(manager, mailbox: mailbox) { server.count("/login-shown") == 1 && server.count("/hold-for-return") == 1 }
        }
        XCTAssertTrue(client.sendPrompt(answer))
        if let login {
            try await pumpHost(manager, mailbox: mailbox) {
                client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
            }
            XCTAssertTrue(client.hasActivePrompt); XCTAssertEqual(calls, 4)
            XCTAssertEqual(browser?.taskID, rootID)
            XCTAssertEqual(server.count("/edit?field=destination&value=Kyoto"), 0)
            if login == .stop {
                client.stopCurrentTask(); XCTAssertTrue(client.isCancellationPending)
                client.resumeAI(); XCTAssertTrue(client.isCancellationPending)
                server.releaseHeldResponses()
                try await pumpHost(manager, mailbox: mailbox) {
                    !client.hasActivePrompt && client.latestTerminalOutcome == .unableToComplete && manager.activity == .idle
                }
                XCTAssertNil(browser?.taskID); XCTAssertNil(browser?.taskControls)
                XCTAssertEqual(client.messages.last(where: { $0.author == .assistant })?.text, ComputerUseTaskLedger.stoppedResponse)
                client.resumeAI(); XCTAssertFalse(client.hasActivePrompt); XCTAssertFalse(client.isCancellationPending)
                XCTAssertEqual(client.state, .ready); XCTAssertEqual(calls, 4)
                XCTAssertEqual(server.count("/edit?field=origin&value=Tokyo"), 1)
                XCTAssertEqual(server.count("/edit?field=destination&value=Kyoto"), 0)
                let prompts = await bridge.prompts(), sent = try XCTUnwrap(prompts.last)
                let ledger = ComputerUseTaskLedger(fileURL: directory.appendingPathComponent("ledger.json"))
                XCTAssertEqual(try ledger.claim(taskID: sent.id, senderID: clientID, sessionID: sessionID,
                    promptBody: sent.body), .completed(ComputerUseTaskLedger.stoppedResponse))
                return
            }
            client.resumeAI()
            try await pumpHost(manager, mailbox: mailbox) {
                client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
            }
            XCTAssertEqual(calls, 4); XCTAssertEqual(server.count("/logged-in"), 0)
            server.releaseHeldResponses()
            try await pumpHost(manager, mailbox: mailbox) { server.count("/logged-in") == 1 }
            XCTAssertEqual(calls, 4, "Finishing login cannot consume the retained answer before explicit Resume")
            client.resumeAI()
        }
        try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
        XCTAssertEqual(client.latestTerminalOutcome, .taskCompleted)
        XCTAssertEqual(client.composerMode, .request); XCTAssertEqual(calls, 7)
        XCTAssertEqual(nativeAdmissions, 1); XCTAssertEqual(loads, 1); XCTAssertEqual(finishedRuns, login == nil ? 2 : 4)
        XCTAssertFalse(client.messages.contains { $0.text.contains("private-fixture-password") })
        XCTAssertEqual(server.count("/form"), 1)
        XCTAssertEqual(server.count("/edit?field=origin&value=Tokyo"), 1)
        XCTAssertEqual(server.count("/edit?field=destination&value=Kyoto"), 1)
        let prompts = await bridge.prompts(), sent = try XCTUnwrap(prompts.last)
        let decoded = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(sent.body)
        XCTAssertEqual(decoded.clarification, reference); XCTAssertNotEqual(sent.id, rootID)
        let before = await bridge.terminals(taskID: sent.id).count
        try await bridge.replay(sent)
        try await pumpHost(manager, mailbox: mailbox) { await bridge.terminals(taskID: sent.id).count > before }
        XCTAssertEqual(calls, 7); XCTAssertEqual(server.count("/edit?field=origin&value=Tokyo"), 1)
    }

    func testOptInRealFaraAsksAndUsesClientAnswerThroughTLSWithoutRepeatingInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_QUESTION_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: one actual Fara question/answer task through shipped client TLS and native WebKit")
        }
        let assets = try await FaraTestAssets.inputs(environment: environment)
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body:
            FormOracle.form(id: "fara-question", initial: ["origin": "", "destination": ""]) + """
            <style>p,h1{display:none}label,textarea{position:fixed!important;left:20vw!important;margin:0!important}
            textarea{width:60vw!important;height:10vh!important}#origin{top:20vh}#destination{top:55vh}
            label[for=origin]{top:12vh}label[for=destination]{top:47vh}</style>
            """)])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraQuestionModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = "Visit \(base.appendingPathComponent("form").absoluteString). Set Origin to Tokyo. Ask me which city to enter in Destination; wait for my answer, then enter that city. Leave the form open."
        let runtime = OSAtlasLlamaRuntime()
        var responses: [String] = [], answeredObservations = 0, nativeAdmissions = 0, loads = 0
        let fara = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            guard responses.count < 16 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            XCTAssertEqual(input.goal, goal); XCTAssertEqual(input.history.count, responses.count)
            if let answer = input.userResponse { XCTAssertEqual(answer, "Kyoto"); answeredObservations += 1 }
            let screenshot = XCTAttachment(data: input.screenshotPNG, uniformTypeIdentifier: "public.png")
            screenshot.name = "Fara question observation \(responses.count + 1)"; screenshot.lifetime = .keepAlways; self.add(screenshot)
            let endpoint = try await runtime.activateFara(assets)
            let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
            responses.append(proposal.response)
            return proposal
        }, finishRun: { await runtime.shutdown() })
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in loads += 1; return fara })
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeAdmissions += 1; return nil }, desktopFactory: { _ in deferred })
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        var browser: ComputerUseOwnedBrowser?
        let manager = HostComputerUseManager(injector: InputInjector(), executor: executor,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                let owned = ComputerUseOwnedBrowser(mayAct: mayAct); browser = owned
                return .init(browser: owned, journalDirectory: directory.appendingPathComponent("browser"))
            }, channelFactory: { _ in channel })
        let key = Data(repeating: 0x6D, count: 32)
        let broker = LocalComputerUseBrokerServer(credential: try RemoteDesktopHost.LocalComputerUseCredential(rawKey: key),
            hostID: hostID, channel: channel, authorizePeer: { peer in manager.authorizePeer(senderID: peer); return true },
            revokePeer: { _ in manager.revokePeerAuthorization() })
        let port = try await broker.start(); defer { broker.stop() }
        let clientChannel = RemoteDesktopClientCore.LocalComputerUseBrokerClient(endpoint: .init(host: "127.0.0.1", port: port),
            credential: try RemoteDesktopClientCore.LocalComputerUseCredential(rawKey: key), pairingCode: pairingCode,
            sessionID: sessionID, senderID: clientID, targetID: hostID)
        let pendingStore = CompositionPendingStore()
        let client = ClientModel(hostName: "Fara Question Fixture", pairingCode: pairingCode, hostID: hostID,
            sessionID: sessionID, pendingStore: pendingStore, channel: clientChannel, promptRefreshInterval: .seconds(600))
        var stage = "startup", failure: Error?
        let started = Date()
        func reach(_ next: String, _ condition: () -> Bool) async throws {
            stage = next
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition() {
                if case .error(let detail) = manager.modelState { throw CompositionFailure.incomplete(detail) }
                guard ContinuousClock.now < deadline else { throw CompositionFailure.incomplete("\(stage): \(client.statusText); host=\(manager.activity)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        do {
            manager.start(pairingCode: pairingCode, additionalChannels: [channel], includeDefaultChannel: false)
            try await clientChannel.handshake()
            try await reach("ready") { if case .ready = manager.modelState { return true }; return false }
            client.start(); XCTAssertTrue(client.sendPrompt(goal))
            try await reach("model question") { !client.hasActivePrompt }
            guard case .answer(let reference, _) = client.composerMode else {
                throw CompositionFailure.incomplete("No retained model question: \(client.statusText)")
            }
            XCTAssertEqual(browser?.taskID, reference.taskID)
            let paused = FormOracle.states(server, id: "fara-question").sorted { $0["sequence"]! < $1["sequence"]! }
            XCTAssertEqual(paused.map { $0["target"]! }, ["", "origin"])
            XCTAssertEqual(paused.last?["origin"], "Tokyo"); XCTAssertEqual(paused.last?["destination"], "")
            XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: assets.llamaServerURL).isEmpty)
            XCTAssertTrue(client.sendPrompt("Kyoto"))
            let answerRequest = try XCTUnwrap(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
            XCTAssertNotEqual(answerRequest.messageID, reference.taskID)
            try await reach("answered task completion") { !client.hasActivePrompt }
            XCTAssertEqual(client.latestTerminalOutcome, .taskCompleted); XCTAssertEqual(client.composerMode, .request)
            let expected = try FormOracle.expectedSequence(initial: ["origin": "", "destination": ""],
                edits: [["field": 0, "mode": "replaceAll", "value": "Tokyo"], ["field": 1, "mode": "replaceAll", "value": "Kyoto"]])
            let actual = FormOracle.states(server, id: "fara-question").sorted { $0["sequence"]! < $1["sequence"]! }
            XCTAssertTrue(FormOracle.matches(actual, expected: expected), "Exactly one native edit per field is required")
            XCTAssertEqual(server.count("/form"), 1); XCTAssertEqual(answeredObservations, 1)
            XCTAssertEqual(nativeAdmissions, 1); XCTAssertEqual(loads, 1)
            guard case .completed = try ComputerUseTaskLedger(fileURL: directory.appendingPathComponent("ledger.json"))
                .claim(taskID: answerRequest.messageID, senderID: clientID, sessionID: sessionID, promptBody: answerRequest.exactWireBody) else {
                throw CompositionFailure.incomplete("Answer completion was not durable")
            }
        } catch { failure = error }
        client.stop(); await manager.shutdown(); await runtime.shutdown()
        XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: assets.llamaServerURL).isEmpty)
        let evidence = XCTAttachment(string: "Stage: \(stage)\nGoal: \(goal)\nProposals: \(responses)\nAnswer observations: \(answeredObservations)\nMessages: \(client.messages.filter { $0.author == .assistant }.map(\.text))\nNative field receipts: \(FormOracle.states(server, id: "fara-question"))\nSeconds: \(Date().timeIntervalSince(started))\nFailure: \(String(reflecting: failure))")
        evidence.name = "Actual Fara retained question through client TLS"; evidence.lifetime = .keepAlways; add(evidence)
        if let failure { throw failure }
    }

    func testOptInProductionStartupCompletesClientConcertTaskThroughTLSAndFara() async throws {
        try await runProductionStartupTLS(login: false)
    }

    func testOptInProductionStartupRetainsTaskThroughLoginAndClientResume() async throws {
        try await runProductionStartupTLS(login: true)
    }

    private func runProductionStartupTLS(login: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_PRODUCTION_ENTRY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: real installers, native/Fara loaders, Mac helper, Apple planner and client TLS")
        }
        let assets = try await FaraTestAssets.inputs(environment: environment)
        let nativeModel = URL(fileURLWithPath: try XCTUnwrap(environment["NATIVE_TEXT_MODEL_PATH"]))
        let helper = URL(fileURLWithPath: try XCTUnwrap(environment["MAC_CONTROL_HELPER_PATH"]))
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ProductionFaraTLS-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Isolate installed receipts and files. The shipped installers recheck
        // each copy's bytes, hash and trust; this test never starts a download.
        func stagedModel(_ manifest: ComputerUseArtifactManifest, source: URL, name: String) throws -> ComputerUseInstaller {
            let root = directory.appendingPathComponent(name)
            let models = root.appendingPathComponent("Models").appendingPathComponent(manifest.installationVersion)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for artifact in manifest.modelArtifacts {
                try FileManager.default.copyItem(at: source.appendingPathComponent(artifact.fileName), to: models.appendingPathComponent(artifact.fileName))
            }
            let receipt = ComputerUseInstallationReceipt(installationVersion: manifest.installationVersion,
                modelVariant: manifest.modelVariant, modelDirectory: models.path, installedAt: Date())
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("active-installation.json"), options: .atomic)
            return ComputerUseInstaller(manifest: manifest, rootDirectory: root, legacyManifest: nil)
        }
        let nativeInstaller = try stagedModel(.nativeTextV2, source: nativeModel.deletingLastPathComponent(), name: "native")
        let visualInstaller = try stagedModel(.current, source: assets.modelURL.deletingLastPathComponent(), name: "fara")
        let helperManifest = MacControlMCPArtifactManifest.current
        let helperRoot = directory.appendingPathComponent("helper")
        let helperVersion = helperRoot.appendingPathComponent("Versions").appendingPathComponent(helperManifest.version)
        try FileManager.default.createDirectory(at: helperVersion, withIntermediateDirectories: true)
        let helperApp = helperVersion.appendingPathComponent(helperManifest.appBundleName)
        try FileManager.default.copyItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), to: helperApp)
        let helperReceipt = MacControlMCPInstallationReceipt(packageVersion: helperManifest.version,
            archiveSHA256: helperManifest.archiveSHA256, appBundlePath: helperApp.path,
            binaryPath: helperApp.appendingPathComponent("Contents/MacOS/" + helperManifest.executableName).path,
            executableSHA256: helperManifest.executableSHA256, bundleIdentifier: helperManifest.bundleIdentifier,
            teamIdentifier: helperManifest.teamIdentifier, signingIdentity: helperManifest.signingIdentity, installedAt: Date())
        try JSONEncoder().encode(helperReceipt).write(to: helperRoot.appendingPathComponent("active-installation.json"), options: .atomic)
        let helperInstaller = MacControlMCPInstaller(rootDirectory: helperRoot)
        let nativeReceipt = await nativeInstaller.currentInstallation(), visualReceipt = await visualInstaller.currentInstallation()
        let verifiedHelper = await helperInstaller.currentInstallation()
        _ = try XCTUnwrap(nativeReceipt); _ = try XCTUnwrap(visualReceipt); _ = try XCTUnwrap(verifiedHelper)

        let style = "<style>body{font:26px system-ui;margin:50px;background:white;color:#111}a{display:block;padding:24px;background:#eef4ff}</style>"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/results": .init(body: "<!doctype html>" + style + "<h1>Concert search results</h1><a href='/details'>Tokyo Music Hall concert details</a>"),
            "/details": .init(body: "<!doctype html>" + style + "<h1>Tokyo Music Hall</h1><p>Friday concert starts at 7 pm.</p><p>Ticket price: 2400 JPY.</p>"),
            "/form": .init(body: FormOracle.form(id: "production-login", initial: ["origin": "old origin", "destination": "old destination"]) + """
                <style>p,h1{display:none}label,textarea{position:fixed!important;left:20vw!important;margin:0!important}
                textarea{width:60vw!important;height:10vh!important}#origin{top:20vh}#destination{top:55vh}
                label[for=origin]{top:12vh}label[for=destination]{top:47vh}</style>
                <script>originField.addEventListener('input',()=>{
                    if(sessionStorage.fixtureAccount==='retained')return;
                    const password=document.createElement('input');password.type='password';password.value='private-fixture-password';
                    document.querySelector('main').prepend(password);fetch('/login-shown');
                    fetch('/release-login').then(()=>{password.remove();sessionStorage.fixtureAccount='retained';fetch('/logged-in')});
                })</script>
                """), "/release-login": .init(held: true)])
        let base = try await server.start(); defer { server.stop() }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let blank = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        blank.isReleasedWhenClosed = false; blank.title = "Computer Use startup fixture"
        blank.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        blank.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { blank.close() }
        let runtime = OSAtlasLlamaRuntime()
        let loader = OSAtlasVisualExecutorLoader(runtime: runtime, faraJournalDirectory: directory.appendingPathComponent("fara-journal"))
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        var ownedBrowser: ComputerUseOwnedBrowser?
        let manager = HostComputerUseManager(injector: InputInjector(), installer: visualInstaller,
            nativeTextInstaller: nativeInstaller, nativeTextLoader: { receipt, tools, progress in
                try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt, tools: tools, runtime: runtime,
                    journalDirectory: directory.appendingPathComponent("text"), progress: progress)
            }, macControlInstaller: helperInstaller, visualExecutorLoader: loader,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                let browser = ComputerUseOwnedBrowser(mayAct: mayAct); ownedBrowser = browser
                return .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser"))
            }, channelFactory: { _ in channel })
        let browser = try XCTUnwrap(ownedBrowser); defer { browser.close() }
        let key = Data(repeating: 0x6D, count: 32)
        let broker = LocalComputerUseBrokerServer(credential: try RemoteDesktopHost.LocalComputerUseCredential(rawKey: key),
            hostID: hostID, channel: channel, authorizePeer: { peer in manager.authorizePeer(senderID: peer); return true },
            revokePeer: { _ in manager.revokePeerAuthorization() })
        let port = try await broker.start(); defer { broker.stop() }
        let clientChannel = RemoteDesktopClientCore.LocalComputerUseBrokerClient(endpoint: .init(host: "127.0.0.1", port: port),
            credential: try RemoteDesktopClientCore.LocalComputerUseCredential(rawKey: key), pairingCode: pairingCode,
            sessionID: sessionID, senderID: clientID, targetID: hostID)
        let pendingStore = CompositionPendingStore()
        let client = ClientModel(hostName: "Production Entry Fixture", pairingCode: pairingCode, hostID: hostID,
            sessionID: sessionID, pendingStore: pendingStore, channel: clientChannel, promptRefreshInterval: .seconds(600))
        var stage = "startup"
        func reach(_ next: String, seconds: Double, _ condition: () -> Bool) async throws {
            stage = next
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition() {
                if case .error(let detail) = manager.modelState { throw CompositionFailure.incomplete(detail) }
                if !client.hasActivePrompt && client.latestTerminalOutcome == .unableToComplete {
                    throw CompositionFailure.incomplete(client.statusText)
                }
                guard ContinuousClock.now < deadline else { throw CompositionFailure.incomplete("\(stage): \(client.statusText); host=\(manager.activity)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        var failure: Error?
        do {
            manager.start(pairingCode: pairingCode, additionalChannels: [channel], includeDefaultChannel: false)
            try await clientChannel.handshake()
            try await reach("ready", seconds: 60) { if case .ready = manager.modelState { return true }; return false }
            XCTAssertFalse(browser.hasSession, "No browser task/page may be pre-admitted for this cold-entry check.")
            client.start()
            let prompt = login
                ? "Visit \(base.appendingPathComponent("form").absoluteString). First replace the Origin with Tokyo. Then replace the Destination with Kyoto."
                : "Visit \(base.appendingPathComponent("results").absoluteString). Find the Tokyo Music Hall concert. Open its details and report the ticket price, start time and source URL."
            XCTAssertTrue(client.sendPrompt(prompt))
            let pending = try XCTUnwrap(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
            if login {
                try await reach("default-composition login pause", seconds: 90) {
                    client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
                }
                XCTAssertTrue(client.hasActivePrompt); XCTAssertEqual(client.latestTerminalOutcome, .userInterventionRequired)
                let paused = FormOracle.states(server, id: "production-login").sorted { $0["sequence"]! < $1["sequence"]! }
                XCTAssertEqual(paused.map { $0["target"]! }, ["", "origin"])
                XCTAssertEqual(paused.last?["origin"], "Tokyo"); XCTAssertEqual(paused.last?["destination"], "old destination")
                XCTAssertEqual(server.count("/login-shown"), 1)
                client.resumeAI()
                XCTAssertFalse(client.hasHostPauseAcknowledgement)
                try await reach("early Resume remains paused", seconds: 15) {
                    client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
                }
                XCTAssertEqual(FormOracle.states(server, id: "production-login"), paused)
                XCTAssertEqual(server.count("/logged-in"), 0)
                server.releaseHeldResponses()
                try await reach("simulated sign-in complete", seconds: 10) { server.count("/logged-in") == 1 }
                XCTAssertEqual(FormOracle.states(server, id: "production-login"), paused, "Signing in cannot resume input by itself")
                client.resumeAI()
                try await reach("default-composition resumed completion", seconds: 90) {
                    !client.hasActivePrompt && client.latestTerminalOutcome == .taskCompleted && manager.activity == .idle
                }
                let expected = try FormOracle.expectedSequence(initial: ["origin": "old origin", "destination": "old destination"],
                    edits: [["field": 0, "mode": "replaceAll", "value": "Tokyo"], ["field": 1, "mode": "replaceAll", "value": "Kyoto"]])
                let actual = FormOracle.states(server, id: "production-login").sorted { $0["sequence"]! < $1["sequence"]! }
                XCTAssertTrue(FormOracle.matches(actual, expected: expected), "The original goal must produce exactly one edit per field")
                XCTAssertEqual(server.count("/form"), 1)
                XCTAssertFalse(client.messages.contains { $0.text.contains("private-fixture-password") })
            } else {
                try await reach("concert answer", seconds: 90) { !client.hasActivePrompt }
                XCTAssertEqual(client.latestTerminalOutcome, .taskCompleted)
                let answer = try XCTUnwrap(client.messages.last(where: { $0.author == .assistant })?.text)
                XCTAssertTrue(answer.lowercased().contains("2400 jpy")); XCTAssertTrue(answer.lowercased().contains("7 pm") || answer.contains("19:00"))
                XCTAssertTrue(answer.contains(base.appendingPathComponent("details").absoluteString))
                XCTAssertEqual(server.count("/results"), 1); XCTAssertEqual(server.count("/details"), 1)
            }
            XCTAssertNil(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
            guard case .completed = try ComputerUseTaskLedger(fileURL: directory.appendingPathComponent("ledger.json"))
                .claim(taskID: pending.messageID, senderID: clientID, sessionID: sessionID, promptBody: pending.exactWireBody) else {
                throw CompositionFailure.incomplete("Client answer was not durably completed for the original task")
            }
        } catch { failure = error }
        let evidence = XCTAttachment(string: "Stage: \(stage)\nState: \(client.state)\nStatus: \(client.statusText)\nMessages: \(client.messages.filter { $0.author == .assistant }.map(\.text))\nHost: \(manager.activity)\nRequests: results=\(server.count("/results")), details=\(server.count("/details"))\nLogin: shown=\(server.count("/login-shown")), returned=\(server.count("/logged-in"))\nField receipts: \(FormOracle.states(server, id: "production-login"))\nFailure: \(String(reflecting: failure))")
        evidence.name = login ? "Production startup client TLS login" : "Production startup client TLS Fara concert"; evidence.lifetime = .keepAlways; add(evidence)
        client.stop(); await manager.shutdown(); await runtime.shutdown()
        XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: assets.llamaServerURL).isEmpty)
        if let failure { throw failure }
    }

    func testOptInShippedClientLocalModelResumesVisibleFormThroughTLSLoginHandback() async throws {
        try await runSingleModelTLSLogin(earlyResume: false)
    }

    func testOptInShippedClientLocalModelEarlyResumeKeepsLoginPausedWithoutRepeatingInput() async throws {
        try await runSingleModelTLSLogin(earlyResume: true)
    }

    func testOptInShippedClientFaraActionsResumeThroughTLSLoginWithoutRepeatingInput() async throws {
        try await runSingleModelTLSLogin(earlyResume: true, fara: true)
    }

    func testOptInShippedClientFaraModelResumesThroughTLSLoginWithoutRepeatingInput() async throws {
        try await runSingleModelTLSLogin(earlyResume: true, fara: true, realFara: true)
    }

    private func runSingleModelTLSLogin(earlyResume: Bool, fara: Bool = false, realFara: Bool = false) async throws {
        let optIn = realFara ? "RUN_FARA_TLS_MODEL_ACCEPTANCE" : fara ? "RUN_FARA_TLS_LOGIN_ACCEPTANCE" : "RUN_SINGLE_MODEL_TLS_LOGIN_ACCEPTANCE"
        guard ProcessInfo.processInfo.environment[optIn] == "1" else {
            throw XCTSkip("Opt-in: one local-model goal, visible fixture, shipped client and real loopback TLS")
        }
        let nativeInstaller = ComputerUseInstaller.nativeText()
        if !fara {
            let installation = await nativeInstaller.currentInstallation()
            _ = try XCTUnwrap(installation, "This test requires the existing model; it must not download one")
        }
        let runtime = OSAtlasLlamaRuntime()
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let faraInputs = realFara ? try await FaraTestAssets.inputs(environment: ProcessInfo.processInfo.environment) : nil
        let faraLayout = fara ? """
            <style>p,h1 {display:none} label,textarea {position:fixed!important;left:20vw!important;margin:0!important}
            textarea {width:60vw!important;height:10vh!important} #origin {top:20vh} #destination {top:55vh}
            label[for=origin] {top:12vh} label[for=destination] {top:47vh}</style>
            """ : ""
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/form": .init(body: FormOracle.form(id: "model-login", initial: [
                "origin": "old origin", "destination": "old destination"
            ]) + faraLayout + """
                <script>
                originField.addEventListener('input', () => {
                    if (sessionStorage.fixtureAccount === 'retained') return;
                    const password = document.createElement('input');
                    password.id = 'password'; password.type = 'password';
                    password.value = 'private-fixture-password';
                    document.querySelector('main').prepend(password);
                    fetch('/login-shown');
                    fetch('/release-login').then(() => {
                        password.remove(); sessionStorage.fixtureAccount = 'retained';
                        fetch('/logged-in');
                    });
                });
                </script>
                """),
            "/release-login": .init(held: true),
        ])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelTLSLogin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        var ownedBrowser: ComputerUseOwnedBrowser?
        var faraCalls = 0
        var faraResponses: [String] = []
        let request = fara ? "First replace the Origin with Tokyo. Then replace the Destination with Kyoto."
            : "Please replace the Origin with Tokyo and the Destination with Kyoto."
        let faraExecutor: ComputerUseFaraBrowserExecutor? = try fara ? .init(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            XCTAssertEqual(input.goal, request)
            XCTAssertEqual(input.history.count, faraCalls, "Resume must retain native action history")
            if let faraInputs {
                let endpoint = try await runtime.activateFara(faraInputs)
                let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
                faraCalls += 1; faraResponses.append(proposal.response)
                return proposal
            }
            let actions = [
                #"{"action":"left_click","coordinate":[500,250]}"#,
                #"{"action":"key","keys":["CTRL","A"]}"#,
                #"{"action":"type","text":"Tokyo"}"#,
                #"{"action":"left_click","coordinate":[500,600]}"#,
                #"{"action":"key","keys":["CTRL","A"]}"#,
                #"{"action":"type","text":"Kyoto"}"#,
                #"{"action":"terminate","answer":"Set Origin to Tokyo and Destination to Kyoto."}"#]
            guard faraCalls < actions.count else { throw CompositionFailure.incomplete("Fara actions were replayed") }
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + actions[faraCalls] + "}</tool_call>"
            faraCalls += 1
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        }, finishRun: { await runtime.shutdown() }) : nil
        let manager = HostComputerUseManager(injector: InputInjector(), executor: faraExecutor, nativeTextInstaller: nativeInstaller,
            nativeTextLoader: { receipt, tools, progress in
                try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt, tools: tools, runtime: runtime,
                    journalDirectory: directory.appendingPathComponent("text"), progress: progress)
            }, macControlInstaller: NoCompositionHelperInstaller(),
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                let browser = ComputerUseOwnedBrowser(mayAct: mayAct)
                ownedBrowser = browser
                return .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser"))
            }, channelFactory: { _ in channel })
        let browser = try XCTUnwrap(ownedBrowser)
        defer { browser.close() }
        let key = Data(repeating: 0x6D, count: 32)
        let broker = LocalComputerUseBrokerServer(
            credential: try RemoteDesktopHost.LocalComputerUseCredential(rawKey: key), hostID: hostID, channel: channel,
            authorizePeer: { peer in manager.authorizePeer(senderID: peer); return true },
            revokePeer: { _ in manager.revokePeerAuthorization() })
        let port = try await broker.start()
        defer { broker.stop() }
        let clientChannel = RemoteDesktopClientCore.LocalComputerUseBrokerClient(
            endpoint: .init(host: "127.0.0.1", port: port),
            credential: try RemoteDesktopClientCore.LocalComputerUseCredential(rawKey: key),
            pairingCode: pairingCode, sessionID: sessionID, senderID: clientID, targetID: hostID)
        let pendingStore = CompositionPendingStore()
        let client = ClientModel(hostName: "Local Model Fixture Mac", pairingCode: pairingCode, hostID: hostID,
            sessionID: sessionID, pendingStore: pendingStore, channel: clientChannel, promptRefreshInterval: .seconds(600))
        let modelStart = Date()
        let memory = realFara ? Task.detached { () -> (UInt64, Int) in
            var peak: UInt64 = 0, count = 0
            while !Task.isCancelled {
                for process in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: runtimeDirectory.appendingPathComponent("llama-server"))) ?? [] {
                    if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: process.processIdentifier) { peak = max(peak, bytes); count += 1 }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return (peak, count)
        } : nil
        func finishFaraEvidence() async {
            guard let memory else { return }
            memory.cancel()
            let samples = await memory.value
            let report: [String: Any] = ["modelCalls":faraCalls,"responses":faraResponses,
                "peakSampledProcessMemoryBytes":samples.0,"memorySamples":samples.1,
                "totalSeconds":Date().timeIntervalSince(modelStart),"wholeApp12GBQualified":false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(string: string)
                attachment.name = "Actual Fara TLS model resources and proposals"; attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        var stage = "setup"
        func reach(_ nextStage: String, seconds: Double = 12, _ condition: () -> Bool) async throws {
            stage = nextStage
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition() {
                if case .error(let detail) = manager.modelState { throw CompositionFailure.incomplete(detail) }
                if !client.hasActivePrompt && client.latestTerminalOutcome == .unableToComplete {
                    throw CompositionFailure.incomplete("\(stage): \(client.statusText)")
                }
                guard ContinuousClock.now < deadline else {
                    throw CompositionFailure.incomplete("\(stage): client=\(client.state), status=\(client.statusText), host=\(manager.activity)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func evidence(_ result: String) {
            let observed = FormOracle.states(server, id: "model-login")
            let attachment = XCTAttachment(string: "\(result); stage=\(stage); client=\(client.state); status=\(client.statusText); host=\(manager.activity); fixtureStates=\(observed); loginShown=\(server.count("/login-shown")); loginReturned=\(server.count("/logged-in"))")
            attachment.name = fara ? (realFara ? "Actual Fara client TLS browser login" : "Scripted Fara actions client TLS browser login") : "Actual local model client TLS browser login"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        do {
            manager.start(pairingCode: pairingCode, additionalChannels: [channel], includeDefaultChannel: false)
            try await clientChannel.handshake()
            try await reach("model ready", seconds: 45) { if case .ready = manager.modelState { return true }; return false }
            client.start()
            XCTAssertTrue(client.sendPrompt("Open \(base.appendingPathComponent("form").absoluteString)"))
            try await reach("visible form open") { !client.hasActivePrompt }
            XCTAssertEqual(client.latestTerminalOutcome, .taskCompleted)
            XCTAssertTrue(browser.isFrontmostWindow)
            let prompt = request
            XCTAssertTrue(client.sendPrompt(prompt))
            let pending = try XCTUnwrap(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
            try await reach("login pause after first edit", seconds: 45) {
                client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
            }
            XCTAssertTrue(client.hasActivePrompt)
            XCTAssertEqual(client.latestTerminalOutcome, .userInterventionRequired)
            XCTAssertEqual(server.count("/login-shown"), 1)
            let paused = FormOracle.states(server, id: "model-login").sorted { $0["sequence"]! < $1["sequence"]! }
            XCTAssertEqual(paused.map { $0["target"]! }, ["", "origin"])
            XCTAssertEqual(paused.last?["origin"], "Tokyo")
            XCTAssertEqual(paused.last?["destination"], "old destination")
            let pausedFaraCalls = faraCalls
            if fara { XCTAssertGreaterThan(faraCalls, 0) }
            if fara && !realFara { XCTAssertEqual(faraCalls, 3) }
            if earlyResume {
                client.resumeAI()
                XCTAssertFalse(client.hasHostPauseAcknowledgement)
                try await reach("early Resume remains paused") {
                    client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
                }
                XCTAssertEqual(client.latestTerminalOutcome, .userInterventionRequired)
                XCTAssertEqual(FormOracle.states(server, id: "model-login"), paused)
                XCTAssertEqual(server.count("/login-shown"), 1)
                XCTAssertEqual(server.count("/logged-in"), 0)
                if fara { XCTAssertEqual(faraCalls, pausedFaraCalls, "Early Resume cannot invoke Fara during login") }
            }
            server.releaseHeldResponses()
            // This login changes only the DOM. hasPageAwaitingHandback tracks
            // navigation during user control and is false for this retained page.
            try await reach("simulated login return") { server.count("/logged-in") == 1 }
            XCTAssertEqual(FormOracle.states(server, id: "model-login"), paused, "Login alone cannot resume AI input")
            client.resumeAI()
            try await reach("resumed completion", seconds: 45) {
                !client.hasActivePrompt && client.latestTerminalOutcome == .taskCompleted && manager.activity == .idle
            }
            XCTAssertEqual(client.state, .ready)
            XCTAssertNil(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
            try await reach("independent edit receipts") { FormOracle.states(server, id: "model-login").count >= 3 }
            let observed = FormOracle.states(server, id: "model-login").sorted { $0["sequence"]! < $1["sequence"]! }
            let expected = try FormOracle.expectedSequence(initial: ["origin": "old origin", "destination": "old destination"],
                edits: [["field": 0, "mode": "replaceAll", "value": "Tokyo"], ["field": 1, "mode": "replaceAll", "value": "Kyoto"]])
            XCTAssertTrue(FormOracle.matches(observed, expected: expected), "Exactly one edit per field, preserving every intermediate state")
            XCTAssertEqual(server.count("/form"), 1)
            if fara { XCTAssertGreaterThan(faraCalls, pausedFaraCalls) }
            if fara && !realFara { XCTAssertEqual(faraCalls, 7) }
            XCTAssertFalse(client.messages.contains { $0.text.contains("private-fixture-password") })
            let ledger = ComputerUseTaskLedger(fileURL: directory.appendingPathComponent("ledger.json"))
            guard case .completed = try ledger.claim(taskID: pending.messageID, senderID: clientID,
                sessionID: sessionID, promptBody: pending.exactWireBody) else {
                throw CompositionFailure.incomplete("Completion was not durable for the original task")
            }
            evidence("Verified \(fara && !realFara ? "scripted Fara actions" : "actual model") → visible browser first edit → login pause → shipped client Resume over TLS → second edit; exact original task completed")
            client.stop()
            await manager.shutdown()
            await runtime.shutdown()
        } catch {
            evidence("Failed: \(error)")
            client.stop()
            await manager.shutdown()
            await runtime.shutdown()
            await finishFaraEvidence()
            throw error
        }
        await finishFaraEvidence()
        XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: runtimeDirectory.appendingPathComponent("llama-server")).isEmpty)
    }

    func testShippedClientCompletesLocalBrowserWorkflowThroughTLSLoginHandback() async throws {
        try await runShippedClientTLSLoginWorkflow(stopAtLogin: false)
    }

    func testShippedClientStopDuringLoginRejectsImmediateAndLateResume() async throws {
        try await runShippedClientTLSLoginWorkflow(stopAtLogin: true)
    }

    private func runShippedClientTLSLoginWorkflow(stopAtLogin: Bool) async throws {
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/form": .init(body: """
                <input id='password' type='password' value='private-fixture-password'>
                <form method='get' action='/results'><label>Destination<input id='q' name='q' value='old'></label><button>Search</button></form>
                <script>
                document.getElementById('q').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value), { keepalive: true }));
                fetch('/release-login').then(() => {
                    document.getElementById('password').remove(); sessionStorage.fixtureAccount = 'retained';
                    history.replaceState({}, '', '/account'); fetch('/logged-in');
                });
                </script>
                """),
            "/release-login": .init(held: true),
            "/results?q=Paris": .init(body: """
                <p>Paris results</p><a id='event'>Event details</a><script>
                document.getElementById('event').href = sessionStorage.fixtureAccount === 'retained' ? '/event?session=retained' : '/event?session=lost';
                </script>
                """),
            "/event?session=retained": .init(body: "<p>Event details visible</p>"),
        ])
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        var fallbackEntries = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            fallbackEntries += 1
            XCTFail("This controlled explicit workflow must never invoke a model or desktop fallback")
            return .unableToComplete("Unexpected fallback")
        })
        var ownedBrowser: ComputerUseOwnedBrowser?
        let manager = HostComputerUseManager(injector: InputInjector(), executor: executor,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: mayAct)
                ownedBrowser = browser
                return .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser"))
            }, allowsExternalServices: true, channelFactory: { _ in channel })
        let browser = try XCTUnwrap(ownedBrowser)
        defer { manager.stop(); browser.close() }
        XCTAssertTrue(HostRuntimeContext.isRunningUnitTests)
        let key = Data(repeating: 0x6D, count: 32)
        let broker = LocalComputerUseBrokerServer(
            credential: try RemoteDesktopHost.LocalComputerUseCredential(rawKey: key), hostID: hostID, channel: channel,
            authorizePeer: { peer in manager.authorizePeer(senderID: peer); return true },
            revokePeer: { _ in manager.revokePeerAuthorization() })
        let port = try await broker.start()
        defer { broker.stop() }
        manager.start(pairingCode: pairingCode, additionalChannels: [channel], includeDefaultChannel: false)
        let clientChannel = RemoteDesktopClientCore.LocalComputerUseBrokerClient(
            endpoint: .init(host: "127.0.0.1", port: port),
            credential: try RemoteDesktopClientCore.LocalComputerUseCredential(rawKey: key),
            pairingCode: pairingCode, sessionID: sessionID, senderID: clientID, targetID: hostID)
        try await clientChannel.handshake()
        let pendingStore = CompositionPendingStore()
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: pendingStore, channel: clientChannel, promptRefreshInterval: .seconds(600))
        defer { client.stop() }
        // Both production polling loops run themselves. The fixture controls only
        // the local page's simulated login response; it never pumps a mailbox,
        // creates a Resume envelope, or calls the host's handle method.
        func reach(_ stage: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    throw CompositionFailure.incomplete("\(stage): client=\(client.state), status=\(client.statusText), host=\(manager.activity)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        client.start()
        let prompt = "Open \(base.appendingPathComponent("form").absoluteString) then set \"Destination\" to \"Paris\" then open the form query using \"Search\" then open the link \"Event details\""
        XCTAssertTrue(client.sendPrompt(prompt))
        let pending = try XCTUnwrap(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
        let admitted = try RemoteDesktopHost.ComputerUseExecutionPromptDecoder.decode(pending.exactWireBody)
        XCTAssertEqual(admitted.prompt, prompt)
        XCTAssertTrue(admitted.supportsApprovedActionEvidence)
        try await reach("login pause") {
            client.state == .paused && client.hasHostPauseAcknowledgement && manager.activity == .paused
        }
        XCTAssertTrue(client.hasActivePrompt)
        XCTAssertEqual(client.latestTerminalOutcome, .userInterventionRequired)
        XCTAssertEqual(server.count("/form"), 1)
        XCTAssertEqual(server.count("/edited?value=Paris"), 0)
        let store = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("browser/Workflows"))
        let paused = try XCTUnwrap(store.load(taskID: pending.messageID))
        XCTAssertEqual(paused.statuses, [.verified, .attempted, .planned, .planned])
        XCTAssertEqual(paused.promptDigest, ComputerUseTextTaskContract.digest(prompt))
        if stopAtLogin {
            client.stopCurrentTask()
            XCTAssertTrue(client.isCancellationPending)
            client.resumeAI()
            XCTAssertTrue(client.isCancellationPending, "A queued Resume cannot supersede the client's pending Stop")
            server.releaseHeldResponses()
            try await reach("client stopped") {
                !client.hasActivePrompt && client.latestTerminalOutcome == .unableToComplete && manager.activity == .idle
            }
            XCTAssertEqual(client.state, .ready)
            XCTAssertNil(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
            XCTAssertNil(browser.taskID)
            XCTAssertNil(browser.taskControls)
            XCTAssertEqual(client.messages.last(where: { $0.author == .assistant })?.text,
                           ComputerUseTaskLedger.stoppedResponse)
            client.resumeAI()
            XCTAssertFalse(client.hasActivePrompt)
            XCTAssertFalse(client.isCancellationPending)
            XCTAssertEqual(client.state, .ready, "Resume after confirmed Stop cannot create another request")
            let ledger = ComputerUseTaskLedger(fileURL: directory.appendingPathComponent("ledger.json"))
            XCTAssertEqual(try ledger.claim(taskID: pending.messageID, senderID: clientID, sessionID: sessionID,
                promptBody: pending.exactWireBody), .completed(ComputerUseTaskLedger.stoppedResponse))
            XCTAssertEqual(server.count("/form"), 1)
            XCTAssertEqual(server.count("/edited?value=Paris"), 0)
            XCTAssertEqual(server.count("/results?q=Paris"), 0)
            XCTAssertEqual(server.count("/event?session=retained"), 0)
            XCTAssertEqual(server.count("/event?session=lost"), 0)
            XCTAssertEqual(fallbackEntries, 0)
            XCTAssertFalse(client.messages.contains { $0.text.contains("private-fixture-password") })
            let evidence = XCTAttachment(string: "Shipped client Stop during login over real TLS; immediate Resume cannot supersede pending Stop, released login response cannot resume effects, client receives the durable stopped result, browser ownership retires, and Resume after terminal does nothing. Zero field edits, queries or link openings.")
            evidence.name = "Client-to-host Stop during login"
            evidence.lifetime = .keepAlways
            add(evidence)
            return
        }
        server.releaseHeldResponses()
        try await reach("simulated login return") { server.count("/logged-in") == 1 && browser.hasPageAwaitingHandback }
        client.resumeAI()
        try await reach("client completion") {
            !client.hasActivePrompt && client.latestTerminalOutcome == .taskCompleted && manager.activity == .idle
        }
        XCTAssertEqual(client.state, .ready)
        XCTAssertNil(pendingStore.load(hostID: hostID, pairingCode: pairingCode))
        XCTAssertEqual(fallbackEntries, 0)
        XCTAssertEqual(server.count("/form"), 1)
        XCTAssertEqual(server.count("/edited?value=Paris"), 1)
        XCTAssertEqual(server.count("/results?q=Paris"), 1)
        XCTAssertEqual(server.count("/event?session=retained"), 1)
        XCTAssertEqual(server.count("/event?session=lost"), 0)
        let completed = try XCTUnwrap(store.load(taskID: pending.messageID))
        XCTAssertEqual(completed.statuses, Array(repeating: .verified, count: 4))
        XCTAssertEqual(completed.stepIDs, paused.stepIDs)
        XCTAssertEqual(completed.contractDigest, paused.contractDigest)
        XCTAssertEqual(completed.promptDigest, paused.promptDigest)
        XCTAssertFalse(client.messages.contains { $0.text.contains("private-fixture-password") })
        let serialized = String(decoding: try JSONEncoder().encode(completed), as: UTF8.self)
        for privateValue in ["Paris", "Destination", "private-fixture-password", base.absoluteString] {
            XCTAssertFalse(serialized.contains(privateValue))
        }
        let evidence = XCTAttachment(string: "Shipped client session and LAN broker → real TLS → automatic host polling → hidden WebKit; paused for simulated login, resumed through client.resumeAI(), one field edit/query/link and four verified journal stages; client received taskCompleted and cleared pending recovery.")
        evidence.name = "Client-to-host controlled workflow"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testShippedClientRecoversSavedBrowserQuestionThroughSerializedProbeWithoutReexecutingOriginalPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID,
            sessionID: sessionID, pairingCode: pairingCode)
        let executor = BrowserQuestionLifecycleExecutor()
        let manager = HostComputerUseManager(injector: InputInjector(), executor: executor.capabilityExecutor(),
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                .init(browser: ComputerUseOwnedBrowser(presentsWindow: false, mayAct: mayAct), journalDirectory: directory.appendingPathComponent("browser"))
            }, allowsExternalServices: false, channelFactory: { _ in mailbox })
        let store = CompositionPendingStore()
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: store, channel: bridge, promptRefreshInterval: .seconds(600))
        defer { client.stop(); manager.stop() }
        manager.authorizePeer(senderID: clientID); client.start()
        let original = "Find concert tickets. Do not purchase anything.", draft = "  Paris e\u{301} 😀\n  "
        XCTAssertTrue(client.sendPrompt(original))
        try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
        guard case .answer(let reference, let deadline) = client.composerMode else { return XCTFail("Expected original question") }
        let owner = try XCTUnwrap(executor.owner), root = owner.input
        client.updateQuestionDraft(draft); client.stop()
        XCTAssertEqual(store.load(hostID: hostID, pairingCode: pairingCode)?.question?.draft, draft)
        let recovered = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID,
            pendingStore: store, channel: bridge, promptRefreshInterval: .seconds(600))
        defer { recovered.stop() }
        recovered.start()
        XCTAssertEqual(recovered.composerMode, .recoveringAnswer)
        try await pumpHost(manager, mailbox: mailbox) {
            if case .answer = recovered.composerMode { return true }; return false
        }
        XCTAssertEqual(recovered.composerMode, .answer(reference, validUntil: deadline))
        XCTAssertTrue(try XCTUnwrap(recovered.restoredClarificationDraft).utf8.elementsEqual(draft.utf8))
        let beforeAnswer = await bridge.prompts()
        XCTAssertEqual(beforeAnswer.count, 1); XCTAssertEqual(executor.planner.inputs.count, 1)
        XCTAssertEqual(owner.input, root); XCTAssertTrue(executor.continued.isEmpty)
        XCTAssertTrue(recovered.sendPrompt(draft))
        try await pumpHost(manager, mailbox: mailbox) { !recovered.hasActivePrompt }
        let prompts = await bridge.prompts(), answer = try XCTUnwrap(prompts.last)
        XCTAssertEqual(prompts.count, 2)
        let decoded = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(answer.body)
        XCTAssertEqual(decoded.clarification, reference); XCTAssertTrue(decoded.prompt.utf8.elementsEqual(draft.utf8))
        XCTAssertTrue(decoded.conversation.isEmpty); XCTAssertEqual(owner.input.userTurns, [original, draft])
        XCTAssertEqual(owner.input.rootDateContext, root.rootDateContext); XCTAssertTrue(executor.owner === owner)
        XCTAssertEqual(executor.planner.inputs.count, 2); XCTAssertEqual(executor.continued.map(\.taskID), [answer.id])
        XCTAssertEqual(store.load(hostID: hostID, pairingCode: pairingCode)?.question?.reference.taskID, answer.id)
    }

    func testShippedClientAnswersBrowserQuestionsWithoutReplacingOriginalGoalOrClock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID,
            sessionID: sessionID, pairingCode: pairingCode)
        let executor = BrowserQuestionLifecycleExecutor()
        let manager = HostComputerUseManager(injector: InputInjector(), executor: executor.capabilityExecutor(),
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), browserNavigationFactory: { mayAct in
                .init(browser: ComputerUseOwnedBrowser(presentsWindow: false, mayAct: mayAct),
                    journalDirectory: directory.appendingPathComponent("browser"))
            }, allowsExternalServices: false, channelFactory: { _ in mailbox })
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: CompositionPendingStore(), channel: bridge, promptRefreshInterval: .seconds(600))
        defer { client.stop(); manager.stop() }
        manager.authorizePeer(senderID: clientID)
        client.start()
        let original = "Find concert tickets. Do not purchase anything."
        let turns = [original, "  Paris e\u{301} 😀\n  ", "2026-10-15"]
        var reference: RemoteDesktopClientCore.ComputerUseClarificationReference?
        var rootID: String?
        for (index, text) in turns.enumerated() {
            XCTAssertTrue(client.sendPrompt(text))
            try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
            let prompts = await bridge.prompts(), sent = try XCTUnwrap(prompts.last)
            let decoded = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(sent.body)
            XCTAssertEqual(decoded.clarification, reference)
            XCTAssertTrue(decoded.prompt.utf8.elementsEqual(text.utf8))
            XCTAssertTrue(decoded.conversation.isEmpty)
            if rootID == nil { rootID = sent.id }
            let owner = try XCTUnwrap(executor.owner)
            XCTAssertEqual(owner.input.taskID, rootID)
            XCTAssertEqual(owner.executionTaskID, sent.id)
            XCTAssertEqual(owner.input.referenceMilliseconds, 1_800_000_000_000)
            XCTAssertEqual(owner.input.timeZoneIdentifier, "America/Los_Angeles")
            XCTAssertEqual(owner.input.userTurns.count, index + 1)
            XCTAssertTrue(zip(owner.input.userTurns, turns.prefix(index + 1)).allSatisfy { $0.utf8.elementsEqual($1.utf8) })
            if index < turns.count - 1 {
                guard case .answer(let next, _) = client.composerMode else { return XCTFail("A browser question must use the existing exact-answer composer") }
                reference = next
                XCTAssertEqual(next.taskID, sent.id)
                let question = try XCTUnwrap(client.messages.last(where: { $0.author == .assistant })?.text)
                XCTAssertTrue(question.hasPrefix(index == 0 ? ComputerUseBrowserClarificationTopic.location.question : ComputerUseBrowserClarificationTopic.date.question))
                XCTAssertTrue(question.contains("⟦\(original)⟧"))
            } else {
                XCTAssertEqual(client.latestTerminalOutcome, .unableToComplete)
                XCTAssertEqual(client.composerMode, .request)
            }
            let before = await bridge.terminals(taskID: sent.id).count
            try await bridge.replay(sent)
            try await pumpHost(manager, mailbox: mailbox) { await bridge.terminals(taskID: sent.id).count > before }
            XCTAssertEqual(executor.continued.count, index)
            XCTAssertEqual(executor.ordinaryPrompts, [original])
        }
        XCTAssertEqual(executor.planner.inputs.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("browser").path))
    }

    func testCurrentClientCapabilityPassesHostAdmissionAcrossScopedAnswersAndDurableReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID,
            sessionID: sessionID, pairingCode: pairingCode)
        let executor = ScopedClarificationTestExecutor()
        let manager = HostComputerUseManager(injector: InputInjector(), executor: executor,
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")), allowsExternalServices: false,
            channelFactory: { _ in mailbox })
        let client = ClientModel(hostName: "Fixture Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: CompositionPendingStore(), channel: bridge, promptRefreshInterval: .seconds(600))
        defer { client.stop(); manager.stop() }
        manager.authorizePeer(senderID: clientID)
        client.start()
        let original = "Put \"  e\u{301} 😀\n" + String(repeating: "x", count: 5_000) + "  \" in a field."
        let turns = [original, "  東京 e\u{301} 😀\n  ", "International"]
        var previousReference: RemoteDesktopClientCore.ComputerUseClarificationReference?
        var sentIDs: [String] = []
        for (index, text) in turns.enumerated() {
            XCTAssertTrue(client.sendPrompt(text))
            try await pumpHost(manager, mailbox: mailbox) { !client.hasActivePrompt }
            let sentPrompts = await bridge.prompts()
            let sent = try XCTUnwrap(sentPrompts.last)
            sentIDs.append(sent.id)
            let admitted = try RemoteDesktopHost.ComputerUseExecutionPromptDecoder.decode(sent.body)
            XCTAssertTrue(admitted.supportsApprovedActionEvidence, "Use the actual shipped client payload, not a default-false hand-built request")
            XCTAssertTrue(admitted.prompt.utf8.elementsEqual(text.utf8))
            let clientRequest = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(sent.body)
            XCTAssertEqual(clientRequest.clarification, previousReference)
            XCTAssertTrue(clientRequest.conversation.isEmpty)
            XCTAssertEqual(executor.normalPrompts, [original])
            XCTAssertEqual(executor.answers.count, index)
            let delivered = await bridge.terminals(taskID: sent.id)
            let terminal = try XCTUnwrap(delivered.last)
            if index < turns.count - 1 {
                guard case .answer(let reference, _) = client.composerMode else {
                    return XCTFail("The real client must receive the host's scoped question")
                }
                XCTAssertEqual(reference, terminal.clarification)
                XCTAssertEqual(terminal.outcome, .userInterventionRequired)
                previousReference = reference
                XCTAssertEqual(executor.effects, 0)
            } else {
                XCTAssertEqual(client.composerMode, .request)
                XCTAssertEqual(terminal.outcome, .taskCompleted)
                XCTAssertNil(terminal.clarification)
                XCTAssertEqual(executor.effects, 1, "Only the controlled executor counter is an effect in this fixture")
            }
            let before = await bridge.terminals(taskID: sent.id).count
            try await bridge.replay(sent)
            try await pumpHost(manager, mailbox: mailbox) { await bridge.terminals(taskID: sent.id).count > before }
            let replayed = await bridge.terminals(taskID: sent.id)
            let replay = try XCTUnwrap(replayed.last)
            XCTAssertEqual(replay, terminal)
            XCTAssertEqual(executor.normalPrompts.count, 1)
            XCTAssertEqual(executor.answers.count, index, "A replay must not repeat clarification continuation")
        }
        XCTAssertEqual(Set(sentIDs).count, turns.count)
        let retained = try XCTUnwrap(executor.answers.last?.goal.userTurns)
        XCTAssertEqual(retained.count, turns.count)
        XCTAssertTrue(zip(retained, turns).allSatisfy { $0.utf8.elementsEqual($1.utf8) })
        XCTAssertEqual(executor.effects, 1)
    }

    func testBrowserFactoryReceivesTheManagerActionGate() async throws {
        var browserGate: (() -> Bool)?
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = HostComputerUseManager(injector: InputInjector(),
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")),
            browserNavigationFactory: { mayAct in
                browserGate = mayAct
                return ComputerUseBrowserNavigationTask(browser: ComputerUseOwnedBrowser(mayAct: mayAct),
                    journalDirectory: directory.appendingPathComponent("navigation"))
            }, allowsExternalServices: false)
        let gate = try XCTUnwrap(browserGate)
        XCTAssertTrue(gate())
        let teardown = manager.stop()
        XCTAssertFalse(gate(), "The injected browser must close synchronously with the production action gate")
        await teardown.value
        await manager.shutdown()
        XCTAssertFalse(gate())
    }

    func testSignedLocalModelClarifiesThroughClientHostMailboxAndOwnedBrowser() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_SIGNED_CLARIFICATION_COMPOSITION_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: signed app host, actual local model, shipped client state, and visible browser")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw CompositionFailure.incomplete("Signed app host required") }
        let corpusURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_BROWSER_CLARIFICATION_CORPUS"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_CLARIFICATION_COMPOSITION_REPORT"]))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw CompositionFailure.incomplete("Refusing to overwrite evidence") }
        let corpusData = try Data(contentsOf: corpusURL)
        let corpusHash = SHA256.hash(data: corpusData).map { String(format: "%02x", $0) }.joined()
        guard corpusHash == "6334379a54986de7f9233ba019c9644891a7569a83d939570fbd33d0a76344d5",
              let corpus = try JSONSerialization.jsonObject(with: corpusData) as? [String: Any],
              let cases = corpus["cases"] as? [[String: Any]], cases.count == 20 else {
            throw CompositionFailure.incomplete("The original clarification corpus changed")
        }
        let byID = try Dictionary(uniqueKeysWithValues: cases.map { (try XCTUnwrap($0["id"] as? String), $0) })
        let groups = [["Q909", "Q910"], ["Q911", "Q912"], ["Q913", "Q914", "Q915"]]
        var routes: [String: OwnedBrowserHTTPFixture.Response] = [:]
        for group in groups {
            let labels = try XCTUnwrap(byID[group[0]]?["fields"] as? [String])
            guard labels.count == 2 else { throw CompositionFailure.incomplete("Two fields required") }
            routes["/case/" + group[0]] = .init(body: FormOracle.form(id: group[0], initial: [:], labels: labels))
        }
        let server = try OwnedBrowserHTTPFixture(routes: routes)
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClarificationComposition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let nativeInstaller = ComputerUseInstaller.nativeText()
        // A missing installation fails this test; it must never initiate a download.
        let installation = await nativeInstaller.currentInstallation()
        let receipt = try XCTUnwrap(installation)
        let runtime = OSAtlasLlamaRuntime.shared
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let runtimeHash = SHA256.hash(data: try Data(contentsOf: runtimeDirectory.appendingPathComponent("llama-server")))
            .map { String(format: "%02x", $0) }.joined()
        var planner: BrowserClarificationAcceptancePlanner?
        var nativeExecutor: ComputerUseNativeTextExecutor?
        var browser: ComputerUseOwnedBrowser?
        let hostID = UUID().uuidString, clientID = UUID().uuidString, sessionID = UUID().uuidString, pairingCode = "842193"
        let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID, clientID: clientID,
            sessionID: sessionID, pairingCode: pairingCode)
        let manager = HostComputerUseManager(injector: InputInjector(), nativeTextInstaller: nativeInstaller,
            nativeTextLoader: { loadedReceipt, tools, progress in
                progress("Loading local form editing…")
                let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(receipt: loadedReceipt,
                    runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
                _ = try await runtime.activateNativeText(inputs)
                try Task.checkCancellation()
                let counting = BrowserClarificationAcceptancePlanner(delegate: .init(inputs: inputs, runtime: runtime))
                planner = counting
                let native = tools.makeNativeTextExecutor(planner: counting,
                    journalDirectory: directory.appendingPathComponent("text"))
                nativeExecutor = native
                return ComputerUseCapabilityExecutor(native: native)
            }, macControlInstaller: NoCompositionHelperInstaller(),
            taskLedger: .init(fileURL: directory.appendingPathComponent("ledger.json")),
            browserNavigationFactory: { mayAct in
                let owned = ComputerUseOwnedBrowser(mayAct: mayAct)
                browser = owned
                return ComputerUseBrowserNavigationTask(browser: owned, journalDirectory: directory.appendingPathComponent("navigation"))
            })
        let client = ClientModel(hostName: "Controlled Mac", pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
            pendingStore: CompositionPendingStore(), channel: bridge, promptRefreshInterval: .seconds(600))
        var rows: [[String: Any]] = []
        func save() throws {
            let report: [String: Any] = ["schemaVersion": 1, "scope": "signed-client-state-host-mailbox-local-model-browser-composition",
                "hostBundlePath": Bundle.main.bundleURL.path, "installationVersion": receipt.installationVersion,
                "runtimeBinarySHA256": runtimeHash, "modelSHA256FromVerifiedManifest": ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256,
                "corpusSHA256": corpusHash, "stateGroups": groups, "plannerCalls": planner?.calls ?? 0,
                "contract": "candidate-v2", "managerReferenceTransportExercised": true, "clientSessionStateExercised": true,
                "productionLocalMailboxExercised": true, "liveTLSOrMobileUIExercised": false,
                "oracle": "independent-page-input-events-with-exact-target-and-full-form-state-after-every-allowed-operation", "cases": rows]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
        try save()
        do {
            manager.start(pairingCode: pairingCode, additionalChannels: [mailbox], includeDefaultChannel: false)
            manager.authorizePeer(senderID: clientID)
            try await wait { if case .ready = manager.modelState { return planner != nil }; return false }
            let counting = try XCTUnwrap(planner), owned = try XCTUnwrap(browser)
            client.start()
            for group in groups {
                let firstID = group[0], started = ProcessInfo.processInfo.systemUptime, callsBefore = counting.calls
                var states: [[String: Any]] = []
                do {
                    guard client.sendPrompt("Open \(base.appendingPathComponent("case/" + firstID))") else {
                        throw CompositionFailure.incomplete("Client did not admit navigation")
                    }
                    try await wait { !client.hasActivePrompt }
                    guard client.latestTerminalOutcome == .taskCompleted, owned.isFrontmostWindow else {
                        throw CompositionFailure.incomplete("Navigation did not complete in the visible owned browser: " + client.statusText)
                    }
                    let initialPrompt = try XCTUnwrap(byID[firstID]?["prompt"] as? String)
                    var previousReference: RemoteDesktopClientCore.ComputerUseClarificationReference?
                    var formScope: String?
                    for (index, id) in group.enumerated() {
                        let item = try XCTUnwrap(byID[id])
                        guard item["prompt"] as? String == initialPrompt else { throw CompositionFailure.incomplete("Original request changed") }
                        let text: String
                        if index == 0 { text = initialPrompt }
                        else {
                            let answers = try XCTUnwrap(item["clarificationAnswers"] as? [[String: String]])
                            guard answers.count == index, let answer = answers.last,
                                  let question = client.messages.last(where: { $0.author == .assistant })?.text,
                                  answer["question"] == question else { throw CompositionFailure.incomplete("Frozen answer does not match the actual question") }
                            text = try XCTUnwrap(answers.last?["text"])
                        }
                        let before = counting.calls, sentBefore = await bridge.prompts().count
                        guard client.sendPrompt(text) else { throw CompositionFailure.incomplete(id + " client refused the request") }
                        try await wait { !client.hasActivePrompt }
                        let prompts = await bridge.prompts()
                        guard prompts.count == sentBefore + 1 else { throw CompositionFailure.incomplete("Unexpected prompt retry") }
                        let sent = try XCTUnwrap(prompts.last)
                        let decoded = try RemoteDesktopClientCore.ComputerUsePromptRequest.decodeBody(sent.body)
                        guard decoded.prompt.utf8.elementsEqual(text.utf8), decoded.conversation.isEmpty,
                              decoded.clarification == previousReference, counting.calls == before + 1 else {
                            throw CompositionFailure.incomplete(id + " exact client payload, reference, or planner count differs")
                        }
                        let delivered = await bridge.terminals(taskID: sent.id)
                        let terminal = try XCTUnwrap(delivered.last)
                        if item["expectedDisposition"] as? String == "clarification" {
                            guard terminal.outcome == .userInterventionRequired,
                                  case .answer(let reference, _) = client.composerMode,
                                  reference == terminal.clarification, reference.taskID == sent.id else {
                                throw CompositionFailure.incomplete(id + " first result did not deliver a scoped answer composer: " + terminal.text)
                            }
                            let retained = try XCTUnwrap(nativeExecutor?.clarification(taskID: sent.id))
                            if let formScope { guard formScope == retained.scope else { throw CompositionFailure.incomplete("Form scope changed") } }
                            else { formScope = retained.scope }
                            previousReference = reference
                            guard FormOracle.states(server, id: firstID).allSatisfy({ $0["sequence"] == "0" }) else {
                                throw CompositionFailure.incomplete("A clarification dispatched input")
                            }
                        } else {
                            guard item["expectedDisposition"] as? String == "supported", index == group.count - 1,
                                  terminal.outcome == .taskCompleted, terminal.clarification == nil, client.composerMode == .request else {
                                throw CompositionFailure.incomplete(id + " first result did not complete: " + terminal.text)
                            }
                        }
                        // Only after the first response passes, replay the exact wire envelope
                        // through the production mailbox and manager ledger. Never retry inference.
                        let terminalCount = await bridge.terminals(taskID: sent.id).count
                        let observedBeforeReplay = FormOracle.states(server, id: firstID)
                        try await bridge.replay(sent)
                        try await waitAsync { await bridge.terminals(taskID: sent.id).count > terminalCount }
                        let replayDeliveries = await bridge.terminals(taskID: sent.id)
                        let replayed = try XCTUnwrap(replayDeliveries.last)
                        guard replayed == terminal, counting.calls == before + 1,
                              FormOracle.states(server, id: firstID) == observedBeforeReplay else {
                            throw CompositionFailure.incomplete("Terminal replay changed its reference, model calls, or input")
                        }
                        states.append(["id": id, "taskID": sent.id, "outcome": terminal.outcome!.rawValue,
                            "exactWirePayloadVerified": true, "durableTerminalReplayVerified": true])
                    }
                    let final = try XCTUnwrap(byID[try XCTUnwrap(group.last)])
                    let plans = try XCTUnwrap(final["allowedPlans"] as? [[[String: Any]]])
                    let expected = try plans.map { try FormOracle.expectedSequence(initial: [:], edits: $0) }
                    try await wait { FormOracle.states(server, id: firstID).count >= 2 }
                    let observed = FormOracle.states(server, id: firstID).sorted { (Int($0["sequence"] ?? "") ?? -1) < (Int($1["sequence"] ?? "") ?? -1) }
                    guard expected.allSatisfy({ $0.count == 2 }), observed.count == 2,
                          Set(observed.compactMap { Int($0["sequence"] ?? "") }) == [0, 1],
                          expected.contains(where: { FormOracle.matches(observed, expected: $0) }), server.count("/case/" + firstID) == 1 else {
                        throw CompositionFailure.incomplete("Independent page sequence does not satisfy the full goal")
                    }
                    rows.append(["id": firstID, "stateIDs": group, "states": states, "verified": true,
                        "inputEvents": 1, "plannerCalls": counting.calls - callsBefore, "observedFixtureStates": observed,
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                    try save()
                    FileHandle.standardError.write(Data("Clarification composition: \(group.joined(separator: ",")) verified\n".utf8))
                } catch {
                    rows.append(["id": firstID, "stateIDs": group, "states": states, "verified": false,
                        "error": String(describing: error), "plannerCalls": counting.calls - callsBefore,
                        "observedFixtureStates": FormOracle.states(server, id: firstID)])
                    try? save()
                    throw error
                }
            }
            client.stop()
            await manager.shutdown()
            await runtime.shutdown()
        } catch {
            client.stop()
            await manager.shutdown()
            await runtime.shutdown()
            throw error
        }
    }

    /// Schedule only mailbox delivery here. The shipped client, JSON wire
    /// types, mailbox admission, host decoder and manager ledger are real;
    /// the executor is controlled and no browser/model/service is started.
    private func pumpHost(_ manager: HostComputerUseManager, mailbox: LocalHostComputerUseChannel,
                          until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CompositionFailure.incomplete("Timed out waiting for client/host wire composition") }
            let incoming = try await mailbox.poll()
            var accepted: [HostEnvelope] = []
            for envelope in incoming where manager.handle(envelope, channel: mailbox) { accepted.append(envelope) }
            try await mailbox.acknowledge(accepted)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        try await waitAsync { condition() }
    }
    private func waitAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CompositionFailure.incomplete("Timed out waiting for composed state") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum CompositionFailure: Error { case incomplete(String) }

/// Only the transport adapter is controlled. Both endpoints compile their own
/// production wire types and exchange JSON bytes; no cross-module cast can hide
/// a serialization mismatch. LocalHostComputerUseChannel performs real routing
/// and mailbox validation, but this fixture makes no claim about TLS enrollment.
private actor SerializedClarificationClientChannel: RemoteDesktopClientCore.ComputerUseSessionChannel {
    let mailbox: LocalHostComputerUseChannel
    let hostID: String, clientID: String, sessionID: String, pairingCode: String
    private var sentPrompts: [ClientEnvelope] = []
    private var receivedTerminals: [String: [ClientUpdate]] = [:]
    private var seen = Set<String>()
    init(mailbox: LocalHostComputerUseChannel, hostID: String, clientID: String, sessionID: String, pairingCode: String) {
        self.mailbox = mailbox; self.hostID = hostID; self.clientID = clientID
        self.sessionID = sessionID; self.pairingCode = pairingCode
    }
    func send(kind: ClientEnvelope.Kind, body: String, to target: String?, sessionID session: String?, messageID: String?) async throws -> ClientEnvelope {
        let envelope = ClientEnvelope(id: messageID ?? UUID().uuidString, senderID: clientID, targetID: target ?? hostID,
            pairingCode: pairingCode, sessionID: session ?? sessionID, kind: kind, body: body)
        try await replay(envelope)
        if kind == .prompt { sentPrompts.append(envelope) }
        return envelope
    }
    func replay(_ envelope: ClientEnvelope) async throws {
        let decoded = try JSONDecoder().decode(HostEnvelope.self, from: JSONEncoder().encode(envelope))
        try await mailbox.receiveFromClient(decoded, authenticatedSenderID: clientID)
    }
    func poll() async throws -> [ClientEnvelope] {
        let outgoing = try await mailbox.pollForClient(authenticatedSenderID: clientID, sessionID: sessionID)
        let decoded = try JSONDecoder().decode([ClientEnvelope].self, from: JSONEncoder().encode(outgoing))
        for envelope in decoded where envelope.kind == .assistant && seen.insert(envelope.id).inserted {
            let update = try ClientUpdate.decodeBody(envelope.body)
            if update.outcome != nil { receivedTerminals[update.taskID, default: []].append(update) }
        }
        return decoded
    }
    func acknowledge(_ envelopes: [ClientEnvelope]) async throws {
        try await mailbox.acknowledgeFromClient(ids: envelopes.map(\.id), authenticatedSenderID: clientID, sessionID: sessionID)
    }
    func prompts() -> [ClientEnvelope] { sentPrompts }
    func terminals(taskID: String) -> [ClientUpdate] { receivedTerminals[taskID] ?? [] }
}

private struct NoCompositionHelperInstaller: MacControlMCPProvisioning {
    func durableStatus() async -> MacControlMCPInstaller.DurableStatus { .notInstalled }
    func install(progress: @MainActor @Sendable @escaping (MacControlMCPInstaller.Update) -> Void) async throws -> MacControlMCPInstallationReceipt {
        throw CompositionFailure.incomplete("Unrelated helper installation was requested")
    }
}

private final class CompositionPendingStore: RemoteDesktopClientCore.ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteDesktopClientCore.ComputerUsePendingPrompt?
    func load(hostID: String, pairingCode: String) -> RemoteDesktopClientCore.ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        return value?.hostID == hostID && value?.pairingCode == pairingCode ? value : nil
    }
    func save(_ pending: RemoteDesktopClientCore.ComputerUsePendingPrompt) -> Bool {
        lock.lock(); defer { lock.unlock() }; value = pending; return true
    }
    func remove(hostID: String) {
        lock.lock(); defer { lock.unlock() }; if value?.hostID == hostID { value = nil }
    }
}
