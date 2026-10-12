import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserLinkPlannerTests: XCTestCase {

    private func content(_ candidate: Int, _ link: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["candidate":candidate, "link":link]), as: UTF8.self)
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserLinkPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: transport)
    }
}

private struct LinkDeadlineReply: ComputerUseBrowserLinkPlanning {
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        throw ComputerUseBrowserLinkPlanError.deadlineExceeded
    }
}

private actor LinkDeadlineTransport: ComputerUseTextModelTransport {
    let phase: String
    private(set) var calls: (counts: [URLRequest], completions: [URLRequest]) = ([], [])
    private(set) var cancelled = false
    private(set) var waiting = false
    init(phase: String) { self.phase = phase }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts.append(completionRequest)
        if phase == "count", calls.counts.count == 2 { try await stall() }
        return 100
    }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions.append(request)
        if phase == "complete", calls.completions.count == 2 { try await stall() }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages.last?["content"]).utf8)) as? [String: Any])
        let available = try XCTUnwrap(context["recallable_readings"] as? [Int])
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["reading":try XCTUnwrap(available.first)]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
    private func stall() async throws {
        waiting = true
        defer { waiting = false }
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = error is CancellationError; throw error }
    }
}

private actor LinkFixtureTransport: ComputerUseTextModelTransport {
    let count: Int
    let cancelCount: Bool
    let cancelCompletion: Bool
    var selectedIndices: [Int]
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(count: Int = 100, cancelCount: Bool = false, cancelCompletion: Bool = false, selectedIndices: [Int] = []) {
        self.count = count; self.cancelCount = cancelCount; self.cancelCompletion = cancelCompletion; self.selectedIndices = selectedIndices
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts += 1; requests.append(completionRequest)
        if cancelCount { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions += 1; requests.append(request)
        if cancelCompletion { withUnsafeCurrentTask { $0?.cancel() } }
        let index = selectedIndices.isEmpty ? -1 : selectedIndices.removeFirst()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        let candidates = try XCTUnwrap(context["candidates"] as? [[String: Any]])
        let link: String
        if index == -1 { link = "" }
        else { link = try XCTUnwrap((candidates[index]["links"] as? [String])?.first) }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidate":index, "link":link]), as: UTF8.self)
        return try Self.envelope(content)
    }
    static func envelope(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop",
            "message":["role":"assistant", "content":content]]]], options: [.sortedKeys])
    }
}

@MainActor
private final class LinkReplyFixture: ComputerUseBrowserLinkPlanning {
    var replacement: ComputerUseBrowserLinkProposal?
    var beforeReply: (@MainActor () async -> Void)?
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        if let beforeReply { await beforeReply() }
        return try replacement ?? .decode(content: #"{"candidate":-1,"link":""}"#, input: input)
    }
}

private struct LinkCardsFixture: ComputerUseBrowserResultPlanning {
    func propose(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput) async throws -> ComputerUseBrowserResultProposal {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.contextJSON.utf8)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let candidates: [[String: Any]] = try ["Alpha", "Beta"].map { name in
            let title = try XCTUnwrap(records.first { $0["text"] as? String == "Concert \(name)" })
            var group = try XCTUnwrap(title["group"] as? String)
            while let container = records.first(where: { $0["kind"] as? String == "container" && $0["id"] as? String == group }),
                  container["element"] as? String != "article" { group = try XCTUnwrap(container["parent"] as? String) }
            let link = try XCTUnwrap(records.first { $0["label"] as? String == "\(name) details" })
            return ["container":group, "fields":[["kind":"title", "texts":[try XCTUnwrap(title["id"] as? String)]]],
                "links":[try XCTUnwrap(link["id"] as? String)]]
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates":candidates]), as: UTF8.self)
        return try .decode(content: content, input: page, goal: goal)
    }
}
