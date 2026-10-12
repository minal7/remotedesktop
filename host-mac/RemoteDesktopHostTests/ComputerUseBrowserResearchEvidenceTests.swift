import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchEvidenceTests: XCTestCase {

    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserLinkPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
    }
}

@MainActor
private final class EvidenceSequencePlanner: ComputerUseBrowserLinkPlanning {
    enum Step { case follow, recall(Int), none }
    var steps: [Step]
    var inputs: [ComputerUseBrowserLinkSelectionInput] = []
    var beforeReply: (@MainActor (Int) async -> Void)?
    init(steps: [Step]) { self.steps = steps }
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        inputs.append(input)
        if let beforeReply { await beforeReply(inputs.count) }
        let step = steps.isEmpty ? .none : steps.removeFirst(), content: String
        switch step {
        case .none: content = #"{"candidate":-1,"link":""}"#
        case .recall(let index): content = "{\"reading\":\(index)}"
        case .follow:
            let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
            let candidates = try XCTUnwrap(context["candidates"] as? [[String: Any]]), link = try XCTUnwrap((candidates[0]["links"] as? [String])?.first)
            content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidate":0, "link":link]), as: UTF8.self)
        }
        return try .decode(content: content, input: input)
    }
}

private struct EvidenceReviewFixture: ComputerUseBrowserResultReviewPlanning {
    func propose(_ input: ComputerUseBrowserResultReviewInput) async throws -> ComputerUseBrowserResultReview {
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        let page = try XCTUnwrap(context["page"] as? [String: Any]), records = try XCTUnwrap(page["records"] as? [[String: Any]])
        let id = try XCTUnwrap(records.first { $0["text"] as? String == "From t1 l1 g1" }?["id"] as? String)
        var candidate: [String: Any] = ["association":"singleOffer", "fields":[["scope":"offer", "price":"notPrice", "qualifiers":[id]]]]
        if input.interpretation != nil {
            candidate["requirements"] = (0..<input.requirementCount).map { ["requirement":$0, "judgment":"unknown", "texts":[]] as [String: Any] }
        }
        let data = try JSONSerialization.data(withJSONObject: ["candidates":[candidate]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

private actor EvidenceTransport: ComputerUseTextModelTransport {
    var responses: [String]
    var counts: [Int]
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(responses: [String], counts: [Int] = []) { self.responses = responses; self.counts = counts }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest); calls.counts += 1
        return counts.isEmpty ? 100 : counts.removeFirst()
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request); calls.completions += 1
        let content = responses.isEmpty ? #"{"candidate":-1,"link":""}"# : responses.removeFirst()
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
}
