import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserActionRecallTests: XCTestCase {

    private func actionInput(_ base: ComputerUseBrowserActionInput, archive: ComputerUseBrowserResearchEvidence?, recalled: [Int] = []) throws -> ComputerUseBrowserActionInput {
        try .init(interpretation: base.interpretation, evidence: base.evidence, navigationHistory: [], formHistory: [],
            latestForm: nil, changedFormTargetIDs: [], researchEvidence: archive, recalledReadings: recalled)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserActionPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
    }
}

private actor ActionRecallTransport: ComputerUseTextModelTransport {
    let counts: [Int]
    private(set) var calls: (counts: [URLRequest], completions: [URLRequest]) = ([], [])
    init(counts: [Int]) { self.counts = counts }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        let index = calls.counts.count; calls.counts.append(completionRequest)
        return counts[index]
    }
    func complete(request: URLRequest) async throws -> Data {
        let first = calls.completions.isEmpty; calls.completions.append(request)
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model",
            "choices":[["finish_reason":"stop", "message":["role":"assistant",
                "content":first ? #"{"reading":0}"# : #"{"unavailable":true}"#]]]])
    }
}
