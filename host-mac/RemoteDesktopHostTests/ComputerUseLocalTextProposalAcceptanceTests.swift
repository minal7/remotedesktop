import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Actual local inference over fictional snapshots, with no effect adapter.
/// Kept separate from both stubbed wire tests and live desktop qualification.
@MainActor
final class ComputerUseLocalTextProposalAcceptanceTests: XCTestCase {
    func testOptInLocalTextProposalCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpusPath = environment["COMPUTER_USE_TEXT_PROPOSAL_CORPUS"],
              environment["RUN_NATIVE_TEXT_GOALS_LOCAL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Use run_native_text_model_acceptance.py --proposal-corpus with a local model")
        }
        let connectionFile = try XCTUnwrap(environment["COMPUTER_USE_TEXT_MODEL_CONNECTION_FILE"])
        let connectionObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: connectionFile))) as? [String: String])
        if connectionObject["runtimeOwner"] == "1" {
            let runtime = OSAtlasLlamaRuntime()
            let inputs = ComputerUseNativeTextRuntimeInputs(
                modelURL: URL(fileURLWithPath: try XCTUnwrap(connectionObject["modelPath"])),
                llamaServerURL: URL(fileURLWithPath: try XCTUnwrap(connectionObject["serverPath"])))
            do {
                try await runCorpus(corpusPath, environment: environment,
                                    planner: ComputerUseRuntimeTextGoalPlanner(inputs: inputs, runtime: runtime))
            } catch {
                await runtime.shutdown()
                throw error
            }
            await runtime.shutdown()
        } else {
            let connection = try ComputerUseTextModelConnection(
                baseURL: XCTUnwrap(URL(string: XCTUnwrap(connectionObject["baseURL"]))),
                bearerToken: XCTUnwrap(connectionObject["bearerToken"]), modelAlias: XCTUnwrap(connectionObject["modelAlias"]))
            let contract = try XCTUnwrap(ComputerUseLocalTextGoalPlanner.Contract(rawValue: connectionObject["contract"] ?? "frozen-v1"))
            let planner = ComputerUseLocalTextGoalPlanner(connection: connection, contract: contract)
            try await runCorpus(corpusPath, environment: environment, planner: planner)
        }
    }

    private func runCorpus(_ corpusPath: String, environment: [String: String],
                           planner: any ComputerUseTextGoalPlanning) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
        guard data.count <= 1_024 * 1_024 else { throw CorpusError.invalidCorpus }
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allCases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        let cases = allCases.filter { $0["fault"] == nil }
        guard (1...64).contains(cases.count), Set(cases.compactMap { $0["id"] as? String }).count == cases.count else {
            throw CorpusError.invalidCorpus
        }
        let reportPath = try XCTUnwrap(environment["COMPUTER_USE_TEXT_PROPOSAL_REPORT"])
        var rows: [[String: Any]] = []
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            var row: [String: Any] = ["id": id, "passed": false]
            let start = ProcessInfo.processInfo.systemUptime
            do {
                var prompt = try XCTUnwrap(item["prompt"] as? String)
                if item["payloadRecipe"] != nil {
                    prompt = prompt.replacingOccurrences(of: "PAYLOAD", with: "\"" + String(repeating: "x", count: 2_000) + "\"")
                }
                let suppliedFields = item["fields"] as? [[String: String]]
                    ?? [["id": "origin", "label": "Origin"], ["id": "destination", "label": "Destination"]]
                guard (1...16).contains(suppliedFields.count),
                      Set(suppliedFields.compactMap { $0["id"] }).count == suppliedFields.count else {
                    throw CorpusError.invalidCorpus
                }
                let initial = item["initial"] as? [String: String] ?? [:]
                var names: [String: String] = [:]
                let fields = try suppliedFields.map { field -> ComputerUseTextField in
                    let name = try XCTUnwrap(field["id"])
                    let targetID = "fictional-\(id)-\(name)"
                    names[targetID] = name
                    return ComputerUseTextField(label: try XCTUnwrap(field["label"]), snapshot: ComputerUseTextSnapshot(
                        targetID: targetID, value: initial[name] ?? "", selection: NSRange(location: 0, length: 0),
                        isEditable: true, isSecure: false))
                }
                let proposal = try await planner.propose(prompt: prompt, fields: fields)
                let outcome = item["expectedOutcome"] as? String
                switch proposal {
                case .unsupported:
                    row["disposition"] = "unsupported"
                    row["passed"] = outcome == "unsupportedWithoutEffects"
                case .clarification:
                    row["disposition"] = "clarification"
                    row["passed"] = outcome == "clarificationWithoutEffects"
                case .fieldOperations: throw CorpusError.invalidCorpus
                case .edits(let edits, let unchanged):
                    row["disposition"] = "supported"
                    let task = try ComputerUseTextTaskContract(taskID: id, prompt: prompt, fields: fields,
                                                              edits: edits, unchangedTargetIDs: unchanged)
                    let expected = item["expected"] as? [String: String]
                        ?? (item["payloadRecipe"] == nil ? nil : ["origin": String(repeating: "x", count: 2_000), "destination": ""])
                    var actual: [String: String] = [:]
                    for (targetID, value) in task.finalValues { actual[try XCTUnwrap(names[targetID])] = value }
                    let exactMatch = expected.map { expected in
                        Set(expected.keys) == Set(actual.keys) && expected.allSatisfy { name, value in
                            actual[name]?.utf8.elementsEqual(value.utf8) == true
                        }
                    } ?? false
                    row["passed"] = exactMatch && outcome != "unsupportedWithoutEffects" && outcome != "clarificationWithoutEffects"
                    row["edits"] = edits.map { ["field": names[$0.targetID] ?? "unknown", "mode": $0.mode.rawValue,
                                               "payloadBytes": $0.text.utf8.count] as [String: Any] }
                }
            } catch {
                row["errorType"] = String(reflecting: type(of: error))
            }
            row["seconds"] = ProcessInfo.processInfo.systemUptime - start
            rows.append(row)
            let report = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try report.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportPath)
            XCTAssertEqual(row["passed"] as? Bool, true, "\(id): \(row["disposition"] ?? row["errorType"] ?? "missing result")")
        }
    }

    private enum CorpusError: Error { case invalidCorpus }
}
