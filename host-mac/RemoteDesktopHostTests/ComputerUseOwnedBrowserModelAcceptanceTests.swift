import AppKit
import CryptoKit
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseOwnedBrowserModelAcceptanceTests: XCTestCase {
    func testSignedManagedLocalModelContinuesRetainedBrowserClarificationsWithoutReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_SIGNED_BROWSER_CLARIFICATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: actual signed local model and explicit retained-browser clarification executor")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw AcceptanceError.incomplete("A signed app host is required") }
        let corpusURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_BROWSER_CLARIFICATION_CORPUS"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_BROWSER_CLARIFICATION_REPORT"]))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw AcceptanceError.incomplete("Refusing to overwrite evidence") }
        let data = try Data(contentsOf: corpusURL)
        let corpusHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard corpusHash == "6334379a54986de7f9233ba019c9644891a7569a83d939570fbd33d0a76344d5",
              let corpus = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = corpus["cases"] as? [[String: Any]], cases.count == 20 else {
            throw AcceptanceError.incomplete("The original clarification corpus changed")
        }
        let byID = try Dictionary(uniqueKeysWithValues: cases.map { (try XCTUnwrap($0["id"] as? String), $0) })
        let groups = [["Q909", "Q910"], ["Q911", "Q912"], ["Q913", "Q914", "Q915"]]
        var routes: [String: OwnedBrowserHTTPFixture.Response] = [:]
        for group in groups {
            let labels = try XCTUnwrap(byID[group[0]]?["fields"] as? [String])
            guard labels.count == 2 else { throw AcceptanceError.incomplete("The browser fixture needs two fields") }
            routes["/case/" + group[0]] = .init(body: Self.form(id: group[0], initial: [:], labels: labels))
        }
        let server = try OwnedBrowserHTTPFixture(routes: routes)
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserClarificationModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser() }
        let receipt = try await ComputerUseInstaller.nativeText().install { _ in }
        let runtime = OSAtlasLlamaRuntime.shared
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(receipt: receipt,
            runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
        let runtimeHash = SHA256.hash(data: try Data(contentsOf: runtimeDirectory.appendingPathComponent("llama-server")))
            .map { String(format: "%02x", $0) }.joined()
        let planner = BrowserClarificationAcceptancePlanner(delegate: .init(inputs: inputs, runtime: runtime))
        let native = tools.makeNativeTextExecutor(planner: planner, journalDirectory: directory.appendingPathComponent("text"))
        let runID = UUID().uuidString
        var rows: [[String: Any]] = []
        func save() throws {
            let report: [String: Any] = ["schemaVersion": 1, "scope": "signed-native-executor-owned-browser-clarification-known-cases",
                "hostBundlePath": Bundle.main.bundleURL.path, "installationVersion": receipt.installationVersion,
                "runtimeBinarySHA256": runtimeHash, "modelSHA256FromVerifiedManifest": ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256,
                "corpusSHA256": corpusHash, "stateGroups": groups, "plannerCalls": planner.calls,
                "contract": "candidate-v2", "managerReferenceTransportExercised": false,
                "oracle": "independent-page-input-events-with-exact-target-and-full-form-state-after-every-allowed-operation", "cases": rows]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
        try save()
        do {
            for group in groups {
                let firstID = group[0], started = ProcessInfo.processInfo.systemUptime, callsBefore = planner.calls
                var states: [[String: String]] = []
                do {
                    let open = "Open \(base.appendingPathComponent("case/" + firstID))"
                    let opened = try await tools.executeOwnedBrowserTaskIfSupported(taskID: runID + "-open-" + firstID, prompt: open, progress: { _ in })
                    guard case .completed = opened, browser.isFrontmostWindow else { throw AcceptanceError.incomplete("The actual browser window is not frontmost") }
                    let prompt = try XCTUnwrap(byID[firstID]?["prompt"] as? String)
                    var pending: ComputerUseNativeTextExecutor.Clarification?
                    var scope: String?
                    for (index, id) in group.enumerated() {
                        let item = try XCTUnwrap(byID[id]), taskID = runID + "-" + id
                        guard item["prompt"] as? String == prompt else { throw AcceptanceError.incomplete("A state changed the original request") }
                        let origin = pending?.taskID
                        let goal: ComputerUseUnresolvedTextGoal
                        if index == 0 { goal = try .init(userRequest: prompt) }
                        else {
                            let retained = try XCTUnwrap(pending)
                            let answers = try XCTUnwrap(item["clarificationAnswers"] as? [[String: String]])
                            guard answers.count == index, let answer = answers.last,
                                  answer["question"] == retained.question, let text = answer["text"] else {
                                throw AcceptanceError.incomplete("The answer does not match the actual question")
                            }
                            goal = try retained.goal.answering(retained.question, with: text)
                        }
                        func runState() async throws -> ComputerUseExecutionResult? {
                            if index == 0 { return try await native.execute(taskID: taskID, prompt: prompt, progress: { _ in }) }
                            return try await native.continueClarification(taskID: taskID, originatingTaskID: XCTUnwrap(origin), goal: goal, progress: { _ in })
                        }
                        let before = planner.calls
                        let result = try await runState()
                        guard planner.calls == before + 1 else { throw AcceptanceError.incomplete("Each new state must use the actual local planner once") }
                        // Validate the first result before any replay check;
                        // a model failure must not get an automatic retry.
                        if item["expectedDisposition"] as? String == "clarification" {
                            guard case .clarificationRequired = result else { throw AcceptanceError.incomplete(id + " first result: " + String(describing: result)) }
                        } else if item["expectedDisposition"] as? String == "supported" {
                            guard case .completed = result else { throw AcceptanceError.incomplete(id + " first result: " + String(describing: result)) }
                        } else { throw AcceptanceError.incomplete("Unexpected frozen disposition") }
                        let replay = try await runState()
                        guard planner.calls == before + 1 else { throw AcceptanceError.incomplete("Replaying a state called the model again") }
                        switch item["expectedDisposition"] as? String {
                        case "clarification":
                            guard case .clarificationRequired = result, case .clarificationRequired = replay else {
                                throw AcceptanceError.incomplete(id + " did not ask the expected question: " + String(describing: result))
                            }
                            pending = try XCTUnwrap(native.clarification(taskID: taskID))
                            guard pending?.goal == goal else { throw AcceptanceError.incomplete("The executor lost the exact original goal") }
                            if let scope { guard pending?.scope == scope else { throw AcceptanceError.incomplete("The retained form scope changed") } }
                            else { scope = pending?.scope }
                            guard Self.states(server, id: firstID).allSatisfy({ $0["sequence"] == "0" }) else {
                                throw AcceptanceError.incomplete("A question dispatched input")
                            }
                            states.append(["id": id, "outcome": "clarification", "replay": "no model call or input"])
                        case "supported":
                            guard index == group.count - 1, case .completed = result, case .completed = replay else {
                                throw AcceptanceError.incomplete(id + " did not complete: " + String(describing: result))
                            }
                            guard try native.clarification(taskID: taskID) == nil else { throw AcceptanceError.incomplete("Completed work retained a question") }
                            states.append(["id": id, "outcome": "completed", "replay": "no model call or input"])
                        default: throw AcceptanceError.incomplete("Unexpected frozen disposition")
                        }
                    }
                    let final = try XCTUnwrap(byID[try XCTUnwrap(group.last)])
                    let plans = try XCTUnwrap(final["allowedPlans"] as? [[[String: Any]]])
                    let sequences = try plans.map { try Self.expectedSequence(initial: [:], edits: $0) }
                    guard sequences.allSatisfy({ $0.count == 2 }) else { throw AcceptanceError.incomplete("These conversations must each perform one exact edit") }
                    let deadline = ContinuousClock.now + .seconds(5)
                    while Self.states(server, id: firstID).count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    let observed = Self.states(server, id: firstID).sorted { (Int($0["sequence"] ?? "") ?? -1) < (Int($1["sequence"] ?? "") ?? -1) }
                    guard observed.count == 2, Set(observed.compactMap { Int($0["sequence"] ?? "") }) == [0, 1],
                          sequences.contains(where: { Self.matches(observed, expected: $0) }), server.count("/case/" + firstID) == 1 else {
                        throw AcceptanceError.incomplete("The independent page event sequence did not match the full goal")
                    }
                    rows.append(["id": firstID, "stateIDs": group, "states": states, "verified": true,
                        "inputEvents": 1, "plannerCalls": planner.calls - callsBefore, "observedFixtureStates": observed,
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                    try save()
                    FileHandle.standardError.write(Data("Owned browser clarification: \(group.joined(separator: ",")) verified\n".utf8))
                } catch {
                    rows.append(["id": firstID, "stateIDs": group, "states": states, "verified": false, "error": String(describing: error),
                        "plannerCalls": planner.calls - callsBefore, "observedFixtureStates": Self.states(server, id: firstID),
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                    try? save()
                    throw error
                }
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testIndependentSequenceOracleRejectsExtraWrongTargetReorderedAndNormalizedIntermediateStates() throws {
        let edits: [[String: Any]] = [["field": 0, "mode": "replaceAll", "value": "e\u{301}"],
                                     ["field": 0, "mode": "append", "value": " / checked"]]
        let expected = try Self.expectedSequence(initial: ["destination": "keep"], edits: edits)
        let before = ["origin": "", "destination": "keep", "target": ""]
        let first = ["origin": "e\u{301}", "destination": "keep", "target": "origin"]
        let last = ["origin": "e\u{301} / checked", "destination": "keep", "target": "origin"]
        XCTAssertTrue(Self.matches([before, first, last], expected: expected))
        var wrongTarget = first; wrongTarget["target"] = "destination"
        var wrongOtherField = first; wrongOtherField["destination"] = "changed"
        var normalized = first; normalized["origin"] = "é"
        let extra = ["origin": "Origin", "destination": "keep", "target": "origin"]
        for actual in [[before, extra, first, last], [before, wrongTarget, last],
                       [before, wrongOtherField, last], [before, normalized, last],
                       [before, last, first], [before, last]] {
            XCTAssertFalse(Self.matches(actual, expected: expected), "The entire sequence must match, not merely its final value")
        }
        XCTAssertThrowsError(try Self.expectedSequence(initial: [:], edits: [["field": 0, "mode": "insert", "value": "x"]]),
                             "This browser corpus has no selection oracle for insert")
    }

    func testSignedManagedLocalModelEditsOwnedBrowserThroughProductionCoordinator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_SIGNED_OWNED_BROWSER_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: actual signed runtime/model and visible isolated browser forms")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw AcceptanceError.incomplete("A signed app host is required") }
        let corpusURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_SIGNED_PACKAGE_CORPUS"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_OWNED_BROWSER_MODEL_REPORT"]))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw AcceptanceError.incomplete("Refusing to overwrite evidence") }
        let data = try Data(contentsOf: corpusURL)
        let corpusHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard corpusHash == "846b06a7b3524ec5803022d110805ec5614fa56f153238a792c01290b04e67f4" else {
            throw AcceptanceError.incomplete("The frozen regression corpus changed")
        }
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 14)
        let plansURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_OWNED_BROWSER_PLAN_CORPUS"]))
        let planData = try Data(contentsOf: plansURL)
        let planHash = SHA256.hash(data: planData).map { String(format: "%02x", $0) }.joined()
        guard planHash == "5aa2c8ffda2a66cf2a188472c16aa4cac9c4d8ecc83e760787564a68942a2f0b",
              let planCorpus = try JSONSerialization.jsonObject(with: planData) as? [String: Any],
              let planCases = planCorpus["cases"] as? [[String: Any]], planCases.count == cases.count else {
            throw AcceptanceError.incomplete("The complete edit-sequence corpus changed")
        }
        let plansByID = try Dictionary(uniqueKeysWithValues: planCases.map { (try XCTUnwrap($0["id"] as? String), $0) })
        guard Set(plansByID.keys) == Set(cases.compactMap { $0["id"] as? String }) else {
            throw AcceptanceError.incomplete("Complete-plan case identifiers do not match")
        }
        let expectedEvents = ["N01": 2, "N02": 2, "N03": 1, "N04": 1, "N05": 2, "N06": 0, "N07": 0,
                              "N08": 0, "N13": 1, "N14": 1, "N12": 2, "R15": 1, "R16": 1, "R17": 2]
        let selectedIDs = environment["COMPUTER_USE_OWNED_BROWSER_CASE_IDS"].map { Set($0.split(separator: ",").map(String.init)) }
        if let selectedIDs {
            guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(expectedEvents.keys)) else {
                throw AcceptanceError.incomplete("Invalid diagnostic case selection")
            }
        }
        var routes: [String: OwnedBrowserHTTPFixture.Response] = [:]
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let initial = item["initial"] as? [String: String] ?? [:]
            guard expectedEvents[id] != nil else { throw AcceptanceError.incomplete("Unknown corpus identifier") }
            routes["/case/" + id] = .init(body: Self.form(id: id, initial: initial))
        }
        let server = try OwnedBrowserHTTPFixture(routes: routes)
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnedBrowserModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser() }
        let installer = ComputerUseInstaller.nativeText()
        let receipt = try await installer.install { update in
            FileHandle.standardError.write(Data("Owned browser model setup: \(update.phase.rawValue)\n".utf8))
        }
        let runtime = OSAtlasLlamaRuntime.shared
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let runtimeHash = SHA256.hash(data: try Data(contentsOf: runtimeDirectory.appendingPathComponent("llama-server")))
            .map { String(format: "%02x", $0) }.joined()
        var rows: [[String: Any]] = []
        func save() throws {
            let report: [String: Any] = ["schemaVersion": 1, "scope": "signed-owned-browser-known-form-regressions",
                "hostBundlePath": Bundle.main.bundleURL.path, "installationVersion": receipt.installationVersion,
                "runtimeBinarySHA256": runtimeHash, "modelSHA256FromVerifiedManifest": ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256,
                "corpusSHA256": corpusHash, "completePlanCorpusSHA256": planHash,
                "oracle": "independent-page-input-events-with-exact-target-and-full-form-state-after-every-allowed-operation",
                "selectedCaseIDs": cases.compactMap { $0["id"] as? String }.filter { selectedIDs?.contains($0) ?? true },
                "cases": rows]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
        do {
            let executor = try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt, tools: tools,
                journalDirectory: directory.appendingPathComponent("text"), progress: { _ in })
            let runID = UUID().uuidString
            for item in cases {
                let id = try XCTUnwrap(item["id"] as? String)
                if let selectedIDs, !selectedIDs.contains(id) { continue }
                let started = ProcessInfo.processInfo.systemUptime
                var resultDescription = "not executed"
                do {
                    let open = "Open \(base.appendingPathComponent("case/" + id))"
                    let opened = try await executor.execute(taskID: runID + "-open-" + id, modelPrompt: open,
                        currentUserPrompt: open, conversation: [], tools: tools, progress: { _ in })
                    guard case .completed = opened, browser.isFrontmostWindow else {
                        let foreground = NSWorkspace.shared.frontmostApplication
                        let diagnostic = "result=\(opened), policy=\(NSApp.activationPolicy().rawValue), active=\(NSApp.isActive), foregroundPID=\(foreground?.processIdentifier ?? -1), selfPID=\(ProcessInfo.processInfo.processIdentifier), keyWindow=\(NSApp.keyWindow?.title ?? "none"), windows=\(NSApp.windows.map { "\($0.title):visible=\($0.isVisible):key=\($0.isKeyWindow):canKey=\($0.canBecomeKey)" })"
                        throw AcceptanceError.incomplete(id + " could not acquire the actual browser window: " + diagnostic)
                    }
                    var prompt = try XCTUnwrap(item["prompt"] as? String)
                    if item["payloadRecipe"] != nil { prompt = prompt.replacingOccurrences(of: "PAYLOAD", with: "\"" + String(repeating: "x", count: 2_000) + "\"") }
                    let planCase = try XCTUnwrap(plansByID[id])
                    guard planCase["prompt"] as? String == prompt,
                          planCase["fields"] as? [String] == ["Origin", "Destination"] else {
                        throw AcceptanceError.incomplete(id + " complete-plan input mismatch")
                    }
                    let result = try await executor.execute(taskID: runID + "-" + id, modelPrompt: prompt,
                        currentUserPrompt: prompt, conversation: [], tools: tools, progress: { _ in })
                    resultDescription = String(describing: result)
                    var expected = item["expected"] as? [String: String]
                        ?? ["origin": String(repeating: "x", count: 2_000), "destination": ""]
                    let disposition: String
                    switch item["expectedOutcome"] as? String {
                    case "unsupportedWithoutEffects":
                        guard case .unableToComplete = result else { throw AcceptanceError.incomplete(id + " unsupported result") }
                        disposition = "unsupportedWithoutEffects"
                        expected = item["initial"] as? [String: String] ?? [:]
                    case "clarificationWithoutEffects":
                        guard case .clarificationRequired = result else { throw AcceptanceError.incomplete(id + " clarification result") }
                        disposition = "clarificationWithoutEffects"
                        expected = item["initial"] as? [String: String] ?? [:]
                    default:
                        guard case .completed = result else { throw AcceptanceError.incomplete(id + " completion result") }
                        disposition = "completed"
                        let replay = try await executor.execute(taskID: runID + "-" + id, modelPrompt: prompt,
                            currentUserPrompt: prompt, conversation: [], tools: tools, progress: { _ in })
                        guard case .completed = replay else { throw AcceptanceError.incomplete(id + " retained task result") }
                    }
                    let eventCount = try XCTUnwrap(expectedEvents[id])
                    let deadline = ContinuousClock.now + .seconds(5)
                    while Self.states(server, id: id).count < eventCount + 1 && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let states = Self.states(server, id: id)
                    guard states.count == eventCount + 1,
                          Set(states.compactMap { Int($0["sequence"] ?? "") }) == Set(0...eventCount),
                          let final = states.first(where: { $0["sequence"] == String(eventCount) }) else {
                        throw AcceptanceError.incomplete(id + " independently observed input event count: expected \(eventCount), states \(states.count), sequences \(states.compactMap { $0["sequence"] })")
                    }
                    for name in ["origin", "destination"] {
                        guard let actual = final[name], actual.utf8.elementsEqual((expected[name] ?? "").utf8) else {
                            throw AcceptanceError.incomplete(id + " independently observed " + name)
                        }
                    }
                    let actualSequence = states.sorted { Int($0["sequence"]!)! < Int($1["sequence"]!)! }
                    let allowedPlans = planCase["allowedPlans"] as? [[[String: Any]]] ?? [[]]
                    let initial = item["initial"] as? [String: String] ?? [:]
                    let allowedSequences = try allowedPlans.map { try Self.expectedSequence(initial: initial, edits: $0) }
                    guard allowedSequences.contains(where: { Self.matches(actualSequence, expected: $0) }) else {
                        throw AcceptanceError.incomplete(id + " intermediate target/value sequence differs from every complete allowed plan")
                    }
                    guard server.count("/case/" + id) == 1 else { throw AcceptanceError.incomplete(id + " navigation replay") }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    rows.append(["id": id, "disposition": disposition, "verified": true, "inputEvents": eventCount,
                                 "completeOperationSequenceVerified": true, "observedFixtureStates": actualSequence,
                                 "retainedTaskReplayChecked": disposition == "completed", "elapsedSeconds": elapsed])
                    try save()
                    FileHandle.standardError.write(Data("Owned browser local model: \(id) verified in \(String(format: "%.3f", elapsed))s\n".utf8))
                } catch {
                    rows.append(["id": id, "verified": false, "error": String(describing: error),
                                 "executorResult": resultDescription, "observedFixtureStates": Self.states(server, id: id),
                                 "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                    try? save()
                    throw error
                }
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    static func expectedSequence(initial: [String: String], edits: [[String: Any]]) throws -> [[String: String]] {
        var value = ["origin": initial["origin"] ?? "", "destination": initial["destination"] ?? "", "target": ""]
        var states = [value]
        for edit in edits {
            guard let field = edit["field"] as? Int, (0...1).contains(field),
                  let payload = edit["value"] as? String, let mode = edit["mode"] as? String,
                  ["replaceAll", "append"].contains(mode) else {
                throw AcceptanceError.incomplete("Invalid operation in frozen browser corpus")
            }
            let name = ["origin", "destination"][field]
            value[name] = mode == "append" ? value[name]! + payload : payload
            value["target"] = name
            states.append(value)
        }
        return states
    }

    static func matches(_ actual: [[String: String]], expected: [[String: String]]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { observed, wanted in
            ["origin", "destination", "target"].allSatisfy { key in
                guard let value = observed[key], let target = wanted[key] else { return false }
                return value.utf8.elementsEqual(target.utf8)
            }
        }
    }

    static func states(_ server: OwnedBrowserHTTPFixture, id: String) -> [[String: String]] {
        server.requestedPaths.filter { $0.hasPrefix("/state?") }.compactMap { path in
            // URLSearchParams uses form encoding: '+' represents a space;
            // a literal plus is percent-encoded and must stay distinct.
            guard let items = URLComponents(string: "http://localhost" + path.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
                  items.first(where: { $0.name == "case" })?.value == id,
                  Set(items.map(\.name)).count == items.count else { return nil }
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
    }

    static func form(id: String, initial: [String: String], labels: [String] = ["Origin", "Destination"]) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Local form acceptance</title>
        <style>body {font:17px system-ui;color:#172d36;background:#f5f8f9;margin:40px} main {max-width:640px;margin:auto}
        label {display:block;font-weight:600;margin:24px 0 8px} textarea {box-sizing:border-box;width:100%;height:100px;font:17px system-ui;border:1px solid #a5bbc4;border-radius:8px;padding:12px}
        </style></head><body><main><p>LOCAL FORM ACCEPTANCE · \(id)</p><h1>Travel details</h1>
        <label for="origin">\(escape(labels[0]))</label><textarea id="origin">\(escape(initial["origin"] ?? ""))</textarea>
        <label for="destination">\(escape(labels[1]))</label><textarea id="destination">\(escape(initial["destination"] ?? ""))</textarea>
        </main><script>
        const originField = document.getElementById('origin'), destinationField = document.getElementById('destination');
        let sequence = 0;
        function report(target = '') { fetch('/state?' + new URLSearchParams({case:'\(id)',sequence:String(sequence),target,origin:originField.value,destination:destinationField.value})); }
        for (const field of [originField,destinationField]) {
          field.setSelectionRange(field.value.length,field.value.length);
          field.addEventListener('input', () => { sequence++; report(field.id); });
        }
        report();
        </script></body></html>
        """
    }

    private enum AcceptanceError: Error { case incomplete(String) }
}

@MainActor
final class BrowserClarificationAcceptancePlanner: ComputerUseTextGoalPlanning {
    let delegate: ComputerUseRuntimeTextGoalPlanner
    private(set) var calls = 0
    init(delegate: ComputerUseRuntimeTextGoalPlanner) { self.delegate = delegate }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        return try await delegate.propose(prompt: prompt, fields: fields)
    }
    func propose(goal: ComputerUseUnresolvedTextGoal, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        return try await delegate.propose(goal: goal, fields: fields)
    }
}
