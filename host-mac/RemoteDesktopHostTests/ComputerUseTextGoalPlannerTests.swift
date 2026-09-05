import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextGoalPlannerTests: XCTestCase {
    func testOptInActualModelPlansFrozenCurrentFormCorpus() async throws {
        guard ProcessInfo.processInfo.environment["RUN_NATIVE_TEXT_GOALS_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set RUN_NATIVE_TEXT_GOALS_MODEL_ACCEPTANCE=1 for the actual local model corpus")
        }
        XCTAssertEqual(AppleFoundationMCPPlanner().availability(), .available)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AcceptanceFixtures/native-text-goals-v1.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        for item in cases where item["fault"] == nil {
            let id = try XCTUnwrap(item["id"] as? String)
            var prompt = try XCTUnwrap(item["prompt"] as? String)
            if item["payloadRecipe"] != nil {
                prompt = prompt.replacingOccurrences(of: "PAYLOAD", with: "\"" + String(repeating: "x", count: 2_000) + "\"")
            }
            let initial = item["initial"] as? [String: String] ?? [:]
            let fields = ["origin", "destination"].map { name in
                let value = initial[name] ?? ""
                return ComputerUseTextField(label: name.capitalized, snapshot: ComputerUseTextSnapshot(
                    targetID: name, value: value, selection: NSRange(location: 0, length: 0),
                    isEditable: true, isSecure: false))
            }
            let proposal: ComputerUseTextGoalProposal
            do {
                proposal = try await ComputerUseTextGoalPlanner(inspectProposal: {
                    print("Frozen text goal \(id) raw: \($0)")
                }).propose(prompt: prompt, fields: fields)
            } catch {
                XCTFail("\(id): \(error)")
                continue
            }
            if let outcome = item["expectedOutcome"] as? String, outcome == "unsupportedWithoutEffects" {
                XCTAssertEqual(proposal, .unsupported, id)
            } else if item["expectedOutcome"] as? String == "clarificationWithoutEffects" {
                XCTAssertEqual(proposal, .clarification, id)
            } else {
                guard case .edits(let edits) = proposal else { XCTFail("\(id): expected supported complete edits"); continue }
                let contract = try ComputerUseTextTaskContract(taskID: id, prompt: prompt, fields: fields, edits: edits)
                var actual = initial
                for name in ["origin", "destination"] where actual[name] == nil { actual[name] = "" }
                for (name, value) in contract.finalValues { actual[name] = value }
                let expected = item["expected"] as? [String: String]
                    ?? ["origin": String(repeating: "x", count: 2_000), "destination": ""]
                XCTAssertEqual(actual, expected, id)
            }
        }
    }
}
