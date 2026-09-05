import AppKit
import CryptoKit
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseOwnedBrowserModelAcceptanceTests: XCTestCase {
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
                "corpusSHA256": corpusHash, "oracle": "independent-page-input-events-and-full-form-values-received-over-loopback-http",
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
                    guard server.count("/case/" + id) == 1 else { throw AcceptanceError.incomplete(id + " navigation replay") }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    rows.append(["id": id, "disposition": disposition, "verified": true, "inputEvents": eventCount,
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

    private static func states(_ server: OwnedBrowserHTTPFixture, id: String) -> [[String: String]] {
        server.requestedPaths.filter { $0.hasPrefix("/state?") }.compactMap { path in
            // URLSearchParams uses form encoding: '+' represents a space;
            // a literal plus is percent-encoded and must stay distinct.
            guard let items = URLComponents(string: "http://localhost" + path.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
                  items.first(where: { $0.name == "case" })?.value == id,
                  Set(items.map(\.name)).count == items.count else { return nil }
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
    }

    private static func form(id: String, initial: [String: String]) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Local form acceptance</title>
        <style>body {font:17px system-ui;color:#172d36;background:#f5f8f9;margin:40px} main {max-width:640px;margin:auto}
        label {display:block;font-weight:600;margin:24px 0 8px} textarea {box-sizing:border-box;width:100%;height:100px;font:17px system-ui;border:1px solid #a5bbc4;border-radius:8px;padding:12px}
        </style></head><body><main><p>LOCAL FORM ACCEPTANCE · \(id)</p><h1>Travel details</h1>
        <label for="origin">Origin</label><textarea id="origin">\(escape(initial["origin"] ?? ""))</textarea>
        <label for="destination">Destination</label><textarea id="destination">\(escape(initial["destination"] ?? ""))</textarea>
        </main><script>
        const originField = document.getElementById('origin'), destinationField = document.getElementById('destination');
        let sequence = 0;
        function report() { fetch('/state?' + new URLSearchParams({case:'\(id)',sequence:String(sequence),origin:originField.value,destination:destinationField.value})); }
        for (const field of [originField,destinationField]) {
          field.setSelectionRange(field.value.length,field.value.length);
          field.addEventListener('input', () => { sequence++; report(); });
        }
        report();
        </script></body></html>
        """
    }

    private enum AcceptanceError: Error { case incomplete(String) }
}
