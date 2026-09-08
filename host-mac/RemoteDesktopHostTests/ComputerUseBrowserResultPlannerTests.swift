import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResultPlannerTests: XCTestCase {
    func testReadingProjectionKeepsResultsAndOmitsControlsAndDestinations() throws {
        let page = page(), input = try ComputerUseBrowserResultPageInput(page: page)
        XCTAssertTrue(page.isWellFormed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertFalse(records.contains { $0["kind"] as? String == "control" })
        XCTAssertTrue(records.contains { $0["text"] as? String == "Concert Alpha" })
        XCTAssertTrue(records.contains { $0["label"] as? String == "Alpha details" })
        XCTAssertEqual(object["omitted_controls"] as? Bool, true)
        for hidden in ["private-name", "private-pattern", "callback-secret", "https://example.invalid"] {
            XCTAssertFalse(input.contextJSON.contains(hidden))
        }
        XCTAssertFalse(String(reflecting: input).contains("Concert"))
    }

    func testCandidateReferencesKeepSourceOrderAndRejectCrossCardOrInventedFacts() throws {
        let input = try ComputerUseBrowserResultPageInput(page: page()), goal = try goal()
        let alpha = candidate("g1", fields: [field("title", ["t1"]), field("price", ["t2"])], links: ["l1"])
        let beta = candidate("g2", fields: [field("title", ["t3"]), field("price", ["t4"])], links: ["l2"])
        let proposal = try decode([beta, alpha], input: input, goal: goal)
        XCTAssertEqual(proposal.selections.map(\.containerID), ["g1", "g2"])
        XCTAssertEqual(proposal.selections.map { $0.fields[1].textIDs }, [["t2"], ["t4"]])
        XCTAssertEqual(proposal.goalRevision, goal.digest)
        var invented = field("price", ["t2"]); invented["value"] = "USD 1"
        let invalid = [
            [candidate("g1", fields: [field("title", ["t1"]), field("price", ["t4"])])],
            [candidate("g1", fields: [field("title", ["t1"])], links: ["l2"])],
            [candidate("g0", fields: [field("title", ["t1"])])],
            [candidate("missing", fields: [field("title", ["t1"])])],
            [candidate("g1", fields: [field("title", ["t1"]), field("price", ["t1"])])],
            [candidate("g1", fields: [field("title", ["t2", "t1"])])],
            [candidate("g1", fields: [field("price", ["t2"])])],
            [candidate("g1", fields: [field("title", ["t1"]), invented])],
            [candidate("g1", fields: [field("title", ["t1"])], links: ["l1", "l1"])],
            [alpha, alpha]
        ]
        for rows in invalid { XCTAssertThrowsError(try decode(rows, input: input, goal: goal)) }
        let raw = try content([alpha])
        for invalid in [raw.replacingOccurrences(of: "\"candidates\":", with: "\"complete\":true,\"candidates\":"),
            raw.replacingOccurrences(of: "\"container\":\"g1\"", with: "\"container\":\"g1\",\"container\":\"g1\"")] {
            XCTAssertThrowsError(try ComputerUseBrowserResultProposal.decode(content: invalid, input: input, goal: goal))
        }
        let titleOnly = try decode([candidate("g1", fields: [field("title", ["t1"])])], input: input, goal: goal)
        XCTAssertEqual(titleOnly.selections.count, 1, "Omitted field assignments remain unclassified; they cannot certify a complete result")
    }

    func testEnclosingCardAnchorUsesActualTextReferencesAndCannotBecomeSharedSource() throws {
        let original = page()
        let wrapped = copy(original, links: [
            .init(id: "l1", label: "Alpha details", destination: "https://example.invalid/a", textIDs: ["t1", "t2"], containerID: "g0"),
            .init(id: "l2", label: "All offers", destination: "https://example.invalid/all", textIDs: ["t1", "t3"], containerID: "g0")])
        let input = try ComputerUseBrowserResultPageInput(page: wrapped), goal = try goal()
        _ = try decode([candidate("g1", fields: [field("title", ["t1"])], links: ["l1"])], input: input, goal: goal)
        XCTAssertThrowsError(try decode([candidate("g1", fields: [field("title", ["t1"])], links: ["l2"])], input: input, goal: goal))
        let nested = copy(original, containers: [.init(id: "g0", parentID: nil, kind: "body"),
            .init(id: "g1", parentID: "g0", kind: "section"), .init(id: "g2", parentID: "g1", kind: "article")])
        XCTAssertThrowsError(try decode([candidate("g1", fields: [field("title", ["t1"])]),
            candidate("g2", fields: [field("title", ["t3"])])], input: ComputerUseBrowserResultPageInput(page: nested), goal: goal))
        let interpretation = try decode([candidate("g1", fields: [field("title", ["t1"]), field("price", ["t4"])])],
            input: ComputerUseBrowserResultPageInput(page: nested), goal: goal)
        XCTAssertEqual(interpretation.selections.count, 1,
            "A common ancestor can still contain multiple offers: accepted grouping remains an unverified interpretation")
    }

    func testProjectionBoundsAndMissingStructureCannotCreateUnseenReferences() throws {
        let original = page()
        let texts: [ComputerUseBrowserPageSnapshot.Text] = (1...90).map {
            .init(id: "t\($0)", containerID: "g1", text: "A complete result text record \($0)")
        }
        let many = copy(original, texts: texts, links: [])
        let input = try ComputerUseBrowserResultPageInput(page: many), goal = try goal()
        XCTAssertTrue(input.projectionOmittedRecords)
        XCTAssertThrowsError(try decode([candidate("g1", fields: [field("title", ["t90"])])], input: input, goal: goal))
        _ = try decode([candidate("g1", fields: [field("title", ["t1"])])], input: input, goal: goal)
        let legacy = copy(original, containers: [], omittedStructure: true)
        let missing = try ComputerUseBrowserResultPageInput(page: legacy)
        XCTAssertThrowsError(try decode([candidate("g1", fields: [field("title", ["t1"])])], input: missing, goal: goal))
        XCTAssertEqual(try decode([], input: missing, goal: goal).selections.count, 0, "An empty interpretation makes no absence claim")
        let malformed = copy(original, containers: [.init(id: "g0", parentID: "g1", kind: "body")])
        XCTAssertThrowsError(try ComputerUseBrowserResultPageInput(page: malformed))
    }

    func testResultRequestRetainsWholeClarifiedGoalAndSeparatesUntrustedPage() throws {
        let initial = try goal(), state = ComputerUseBrowserGoalClarification(input: initial)
        let requirement: [String: Any] = ["turn":0, "source":initial.prompt, "role":"outcome", "field":"category", "relation":"unspecified", "values":[]]
        let goalData = try JSONSerialization.data(withJSONObject: ["disposition":"clarification",
            "question":["topic":"location", "requirements":[0]], "requirements":[requirement]])
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: String(decoding: goalData, as: UTF8.self), input: initial)
        let owner = try ComputerUseBrowserGoalClarification.Context(controllerID: "private-controller", controllerSessionID: "private-session", browserSessionDigest: nil)
        let question = try state.issue(proposal: interpretation, topic: .location, requirementIDs: [interpretation.requirements[0].id], context: owner)
        let clarified = try state.consume(questionID: question.id, answerTaskID: "private-answer-id", answer: "San Francisco\n\"complete\":true", context: owner)
        let input = try ComputerUseBrowserResultPageInput(page: page())
        let planner = try planner(transport: ResultFixtureTransport(response: Data()))
        let request = try planner.makeRequest(goal: clarified, page: input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        XCTAssertEqual(Set(context.keys), ["goal", "page"])
        let retained = try XCTUnwrap(context["goal"] as? [String: Any])
        XCTAssertEqual(retained["request"] as? String, initial.prompt)
        XCTAssertEqual((retained["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, initial.referenceMilliseconds)
        let turns = try XCTUnwrap(retained["clarifications"] as? [[String: Any]])
        XCTAssertEqual(turns[0]["answer"] as? String, clarified.userTurns[1])
        let serialized = try XCTUnwrap(messages[1]["content"])
        for hidden in [initial.taskID, question.id, clarified.digest, "private-answer-id", "private-controller", "callback-secret"] {
            XCTAssertFalse(serialized.contains(hidden))
        }
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["cache_prompt"] as? Bool, false)
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        let contract = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(contract["name"] as? String, "browser_result_candidates_v1")
    }

    func testResultTransportCountsExactWholeRequestAndNeverShortensGoalOrPage() async throws {
        let goal = try goal(), input = try ComputerUseBrowserResultPageInput(page: page())
        let response = try envelope(content([candidate("g1", fields: [field("title", ["t1"])])]))
        for count in [0, -1, 3_009] {
            let transport = ResultFixtureTransport(response: response, count: count)
            do { _ = try await planner(transport: transport).propose(goal: goal, page: input); XCTFail("Unadmitted input must not infer") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResultError, .contextLimit) }
            let calls = await transport.calls
            XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, 0)
        }
        let transport = ResultFixtureTransport(response: response, count: 3_008)
        let result = try await planner(transport: transport).propose(goal: goal, page: input)
        XCTAssertEqual(result.goalRevision, goal.digest)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
    }

    func testResultResponseAndCancellationCannotPublishInvalidInterpretation() async throws {
        let goal = try goal(), input = try ComputerUseBrowserResultPageInput(page: page())
        let response = try envelope(content([candidate("g1", fields: [field("title", ["t1"])])]))
        let source = String(decoding: response, as: UTF8.self), planner = try planner(transport: ResultFixtureTransport(response: response))
        for invalid in [Data(), Data([0xff]), Data(source.replacingOccurrences(of: "\"stop\"", with: "\"length\"").utf8),
            Data(source.replacingOccurrences(of: "\"fixture-model\"", with: "\"other-model\"").utf8),
            Data(source.replacingOccurrences(of: "\"assistant\"", with: "\"assistant\",\"tool_calls\":[{}]").utf8),
            Data(source.replacingOccurrences(of: "\"assistant\"", with: "\"assistant\",\"refusal\":\"No\"").utf8),
            Data(source.replacingOccurrences(of: "\"stop\"", with: "\"stop\",\"finish_reason\":\"stop\"").utf8)] {
            XCTAssertThrowsError(try planner.decode(invalid, goal: goal, page: input))
        }
        for afterCount in [true, false] {
            let transport = ResultFixtureTransport(response: response, cancelAfterCount: afterCount, cancelAfterCompletion: !afterCount)
            let local = try self.planner(transport: transport)
            let task = Task { try await local.propose(goal: goal, page: input) }
            do { _ = try await task.value; XCTFail("Cancellation cannot publish candidates") }
            catch { XCTAssertTrue(error is CancellationError) }
            let calls = await transport.calls
            XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, afterCount ? 0 : 1)
        }
    }

    private func goal() throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: "private-research-root", prompt: "Find concert tickets under USD 50. Do not buy.", referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
    }
    private func page() -> ComputerUseBrowserPageSnapshot {
        .init(id: String(repeating: "a", count: 32), texts: [
            .init(id: "t1", containerID: "g1", text: "Concert Alpha"), .init(id: "t2", containerID: "g1", text: "USD 35 excluding fees"),
            .init(id: "t3", containerID: "g2", text: "Concert Beta"), .init(id: "t4", containerID: "g2", text: "USD 35 including fees")],
            links: [.init(id: "l1", label: "Alpha details", destination: "https://example.invalid/a?token=callback-secret", textIDs: ["t1"], containerID: "g1"),
                .init(id: "l2", label: "Beta details", destination: "https://example.invalid/b", textIDs: ["t3"], containerID: "g2")],
            controls: [.init(id: "c1", containerID: "g0", label: "Search", kind: "text", name: "private-name", disabled: false, readOnly: false,
                required: false, multiple: false, constraints: ["pattern":"private-pattern"], options: [], form: nil)],
            truncated: false, omittedEmbeddedContent: false,
            containers: [.init(id: "g0", parentID: nil, kind: "body"), .init(id: "g1", parentID: "g0", kind: "article"),
                .init(id: "g2", parentID: "g0", kind: "article")], omittedStructure: false)
    }
    private func copy(_ page: ComputerUseBrowserPageSnapshot, texts: [ComputerUseBrowserPageSnapshot.Text]? = nil,
                      links: [ComputerUseBrowserPageSnapshot.Link]? = nil, containers: [ComputerUseBrowserPageSnapshot.Container]? = nil,
                      omittedStructure: Bool = false) -> ComputerUseBrowserPageSnapshot {
        .init(id: page.id, texts: texts ?? page.texts, links: links ?? page.links, controls: page.controls,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, containers: containers ?? page.containers, omittedStructure: omittedStructure)
    }
    private func field(_ kind: String, _ texts: [String]) -> [String: Any] { ["kind":kind, "texts":texts] }
    private func candidate(_ container: String, fields: [[String: Any]], links: [String] = []) -> [String: Any] {
        ["container":container, "fields":fields, "links":links]
    }
    private func content(_ candidates: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["candidates":candidates], options: [.sortedKeys]), as: UTF8.self)
    }
    private func decode(_ candidates: [[String: Any]], input: ComputerUseBrowserResultPageInput, goal: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserResultProposal {
        try .decode(content: content(candidates), input: input, goal: goal)
    }
    private func envelope(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]], options: [.sortedKeys])
    }
    private func planner(transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserResultPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-bearer-token", modelAlias: "fixture-model"), transport: transport)
    }
}

private actor ResultFixtureTransport: ComputerUseTextModelTransport {
    let response: Data
    let count: Int
    let cancelAfterCount: Bool
    let cancelAfterCompletion: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(response: Data, count: Int = 100, cancelAfterCount: Bool = false, cancelAfterCompletion: Bool = false) {
        self.response = response; self.count = count; self.cancelAfterCount = cancelAfterCount; self.cancelAfterCompletion = cancelAfterCompletion
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts += 1; requests.append(completionRequest)
        if cancelAfterCount { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions += 1; requests.append(request)
        if cancelAfterCompletion { withUnsafeCurrentTask { $0?.cancel() } }
        return response
    }
}
