import AppKit
import CryptoKit
import XCTest
@testable import RemoteDesktopHost

/// Opt-in qualification uses the actual runtime and the ordinary coordinator,
/// DOM adapter and task engine. Only the planner contract and local page differ
/// from normal composition. The observer never edits or approves a proposal.
@MainActor
final class ComputerUseFieldOperationsBrowserAcceptanceTests: XCTestCase {
    func testIndependentCopyOracleRequiresOriginAndEveryExactIntermediateState() {
        let copy = FieldOperationOracle(field: 1, mode: "replaceAll", sourceField: 0)
        XCTAssertNotEqual(copy, FieldOperationOracle(field: 1, mode: "replaceAll", value: "same"))
        XCTAssertNotEqual(copy, FieldOperationOracle(field: 1, mode: "replaceAll", sourceField: 1))
        let initial = FieldStateOracle(values: ["e\u{301}", "same"], target: nil)
        let input = FieldStateOracle(values: ["e\u{301}", "same"], target: 1)
        let expected = [initial, input, input]
        XCTAssertNotEqual([initial, input], expected, "A no-op copy still requires each requested input event")
        XCTAssertNotEqual([initial, input, .init(values: ["é", "same"], target: 1)], expected)
        XCTAssertNotEqual([initial, .init(values: ["e\u{301}", "same"], target: 0), input], expected)
        XCTAssertNotEqual([initial, .init(values: ["e\u{301}", "wrong"], target: 1), input], expected)
        XCTAssertEqual([initial, input, input], expected)
    }

    func testSignedManagedModelExecutesTypedOperationsInVisibleOwnedBrowser() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FIELD_OPERATIONS_BROWSER_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in signed local model and visible controlled browser effects")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.invalidInput }
        let corpusURL = URL(fileURLWithPath: try XCTUnwrap(environment["FIELD_OPERATIONS_BROWSER_CORPUS"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["FIELD_OPERATIONS_BROWSER_REPORT"]))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw Failure.invalidInput }
        let data = try Data(contentsOf: corpusURL)
        let corpusHash = Self.sha(data)
        guard corpusHash == "9a3baa1f4a6c449821237a30ac10fce6ab683a43d9cf2be6855737db68a64464" else { throw Failure.invalidInput }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.schemaVersion == 1, corpus.cases.map(\.id) == ["B801", "B802", "B803", "B804", "B805", "B806"] else {
            throw Failure.invalidInput
        }
        var routes: [String: OwnedBrowserHTTPFixture.Response] = [:]
        for item in corpus.cases {
            guard item.fields.count == item.initial.count, item.states.count == item.operations.count + 1,
                  item.states.first == .init(values: item.initial, target: nil),
                  item.states.allSatisfy({ $0.values.count == item.fields.count }) else { throw Failure.invalidInput }
            routes["/case/" + item.id] = .init(body: Self.form(item))
        }
        let server = try OwnedBrowserHTTPFixture(routes: routes)
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FieldOperationsBrowser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true })
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory.appendingPathComponent("navigation"))
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser() }
        let receipt = try await ComputerUseInstaller.nativeText().install { _ in }
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
        let runtime = OSAtlasLlamaRuntime.shared
        let planner = ObservedFieldOperationsPlanner(inputs: inputs, runtime: runtime)
        let executor = ComputerUseCapabilityExecutor(native: tools.makeNativeTextExecutor(planner: planner,
            journalDirectory: directory.appendingPathComponent("text")))
        let runtimeHash = Self.sha(try Data(contentsOf: runtimeDirectory.appendingPathComponent("llama-server")))
        var rows: [[String: Any]] = []
        func save() throws {
            let result: [String: Any] = ["schemaVersion": 1, "scope": corpus.scope, "contract": "field-operations-v8",
                "composition": "actual runtime candidate with production coordinator, observation, compilation, DOM effects and recovery",
                "hostBundlePath": Bundle.main.bundleURL.path, "corpusSHA256": corpusHash,
                "runtimeBinarySHA256": runtimeHash,
                "modelSHA256FromVerifiedManifest": ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256,
                "expectedCaseIDs": corpus.cases.map(\.id), "cases": rows,
                "oracle": "typed payload origin plus independent handwritten full state and target after every input; same-task replay adds no inference or input"]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
        do {
            for item in corpus.cases {
                let started = ProcessInfo.processInfo.systemUptime
                let taskID = UUID().uuidString
                planner.reset()
                var resultDescription = "not executed"
                do {
                    let open = "Open \(base.appendingPathComponent("case/" + item.id))"
                    let opened = try await executor.execute(taskID: taskID + "-open", modelPrompt: open,
                        currentUserPrompt: open, conversation: [], tools: tools, progress: { _ in })
                    guard case .completed = opened, browser.isFrontmostWindow else { throw Failure.browserNotFrontmost }
                    let result = try await executor.execute(taskID: taskID, modelPrompt: item.prompt,
                        currentUserPrompt: item.prompt, conversation: [], tools: tools, progress: { _ in })
                    resultDescription = String(describing: result)
                    switch item.expectedDisposition {
                    case "supported":
                        guard case .completed = result else { throw Failure.wrongOutcome }
                        let replay = try await executor.execute(taskID: taskID, modelPrompt: item.prompt,
                            currentUserPrompt: item.prompt, conversation: [], tools: tools, progress: { _ in })
                        guard case .completed = replay else { throw Failure.wrongOutcome }
                    case "unsupported": guard case .unableToComplete = result else { throw Failure.wrongOutcome }
                    default: throw Failure.invalidInput
                    }
                    // The complete quoted compiler must not bypass the model in
                    // these selected cases; a replay must not call it again.
                    guard planner.calls == 1, planner.disposition == item.expectedDisposition,
                          planner.operations == item.operations else { throw Failure.wrongTypedProposal }
                    let deadline = ContinuousClock.now + .seconds(5)
                    while Self.observations(server, id: item.id).count < item.states.count && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let observed = Self.observations(server, id: item.id)
                    guard observed.map(\.sequence) == Array(item.states.indices), observed.map(\.state) == item.states,
                          server.count("/case/" + item.id) == 1 else { throw Failure.wrongInputSequence }
                    rows.append(["id": item.id, "verified": true, "disposition": item.expectedDisposition,
                        "modelCalls": planner.calls, "operations": try Self.object(planner.operations),
                        "observedStates": try Self.object(observed), "inputEvents": observed.count - 1,
                        "sameTaskReplayChecked": item.expectedDisposition == "supported",
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                    try save()
                    FileHandle.standardError.write(Data("Field operations browser: \(item.id) verified\n".utf8))
                } catch {
                    rows.append(["id": item.id, "verified": false, "error": String(describing: error),
                        "executorResult": resultDescription, "modelCalls": planner.calls,
                        "proposedDisposition": planner.disposition, "operations": try Self.object(planner.operations),
                        "observedStates": try Self.object(Self.observations(server, id: item.id)),
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                    try save()
                    throw error
                }
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    private struct Corpus: Decodable { let schemaVersion: Int; let scope: String; let cases: [Case] }
    private struct Case: Decodable {
        let id: String; let prompt: String; let fields: [String]; let initial: [String]
        let expectedDisposition: String; let operations: [FieldOperationOracle]; let states: [FieldStateOracle]
    }
    private struct Observation: Codable { let sequence: Int; let state: FieldStateOracle }
    private static func observations(_ server: OwnedBrowserHTTPFixture, id: String) -> [Observation] {
        server.requestedPaths.filter { $0.hasPrefix("/field-state?") }.compactMap { path in
            guard let items = URLComponents(string: "http://localhost" + path.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
                  Set(items.map(\.name)) == ["case", "sequence", "state"], items.count == 3,
                  items.first(where: { $0.name == "case" })?.value == id,
                  let number = items.first(where: { $0.name == "sequence" })?.value, let sequence = Int(number),
                  let text = items.first(where: { $0.name == "state" })?.value,
                  let state = try? JSONDecoder().decode(FieldStateOracle.self, from: Data(text.utf8)) else { return nil }
            return Observation(sequence: sequence, state: state)
        }.sorted { $0.sequence < $1.sequence }
    }
    private static func form(_ item: Case) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let fields = item.fields.indices.map { index in
            "<label for='field\(index)'>\(escape(item.fields[index]))</label><textarea id='field\(index)'>\(escape(item.initial[index]))</textarea>"
        }.joined()
        return """
        <!doctype html><meta charset="utf-8"><title>Local field operations acceptance</title>
        <style>body {font:17px system-ui;margin:36px;background:#f5f8f9;color:#172d36} main {max-width:640px;margin:auto} label {display:block;margin:16px 0 6px;font-weight:600} textarea {box-sizing:border-box;width:100%;height:90px;padding:10px;font:17px system-ui}</style>
        <main><p>LOCAL FIELD ACCEPTANCE · \(item.id)</p><h1>Field operations</h1>\(fields)</main>
        <script>
        const fields = Array.from(document.querySelectorAll('textarea'));
        let sequence = 0;
        let reports = Promise.resolve();
        function report(target = null) {
          const state = JSON.stringify({values:fields.map(field => field.value),target});
          const url = '/field-state?' + new URLSearchParams({case:'\(item.id)',sequence:String(sequence),state});
          reports = reports.then(() => fetch(url));
        }
        fields.forEach((field,index) => {
          field.setSelectionRange(field.value.length,field.value.length);
          field.addEventListener('input', () => { sequence++; report(index); });
        });
        report();
        </script>
        """
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private enum Failure: Error { case invalidInput, browserNotFrontmost, wrongOutcome, wrongTypedProposal, wrongInputSequence }
}

private struct FieldStateOracle: Codable, Equatable {
    let values: [String]; let target: Int?
    static func == (left: Self, right: Self) -> Bool {
        left.target == right.target && left.values.count == right.values.count
            && zip(left.values, right.values).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

private struct FieldOperationOracle: Codable, Equatable {
    let field: Int; let mode: String; let value: String?; let sourceField: Int?
    init(field: Int, mode: String, value: String? = nil, sourceField: Int? = nil) {
        self.field = field; self.mode = mode; self.value = value; self.sourceField = sourceField
    }
    static func == (left: Self, right: Self) -> Bool {
        guard left.field == right.field, left.mode == right.mode, left.sourceField == right.sourceField else { return false }
        switch (left.value, right.value) {
        case (nil, nil): return true
        case (.some(let a), .some(let b)): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }
}

@MainActor
private final class ObservedFieldOperationsPlanner: ComputerUseTextGoalPlanning {
    let inputs: ComputerUseNativeTextRuntimeInputs
    let runtime: OSAtlasLlamaRuntime
    private(set) var calls = 0
    private(set) var disposition = "none"
    private(set) var operations: [FieldOperationOracle] = []
    init(inputs: ComputerUseNativeTextRuntimeInputs, runtime: OSAtlasLlamaRuntime) { self.inputs = inputs; self.runtime = runtime }
    func reset() { calls = 0; disposition = "none"; operations = [] }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let endpoint = try await runtime.activateNativeText(inputs)
        let proposal = try await runtime.proposeNativeText(endpoint: endpoint, prompt: prompt, fields: fields, contract: .fieldOperationsV8)
        switch proposal {
        case .unsupported: disposition = "unsupported"
        case .clarification: disposition = "clarification"
        case .edits: throw ComputerUseLocalTextPlanError.invalidResponse
        case .fieldOperations(let plan, _):
            disposition = "supported"
            operations = try plan.map { operation in
                let target = try XCTUnwrap(fields.firstIndex { $0.snapshot.targetID == operation.targetID })
                switch operation {
                case .enterText(let edit): return .init(field: target, mode: edit.mode.rawValue, value: edit.text)
                case .copyField(let sourceID, _, let mode):
                    let source = try XCTUnwrap(fields.firstIndex { $0.snapshot.targetID == sourceID })
                    return .init(field: target, mode: mode.rawValue, sourceField: source)
                }
            }
        }
        return proposal
    }
}
