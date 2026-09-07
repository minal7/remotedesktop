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
