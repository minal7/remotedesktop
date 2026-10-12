import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentLlamaVLMPolicyTests: XCTestCase {
    func testPolicyIncludesPromptSchemaElementsAndOneAttachedPNG() async throws {
        let raw = try completion(arguments: #"{"type":"click","target":{"id":1}}"#,
                                 content: "I will continue with the visible control.")
        let transport = RecordingAgentVLMTransport(response: raw)
        let (policy, observation, png, schema) = try fixture(transport: transport)

        let output = try await policy.propose(observation)

        XCTAssertEqual(policy.promptVersion, "v1")
        XCTAssertEqual(output.rawOutput, raw)
        XCTAssertEqual(output.action, .click(target: .element(id: 1), button: nil, count: nil))
        let input = try XCTUnwrap(transport.inputs.first)
        XCTAssertEqual(input.prompt, try promptText())
        XCTAssertEqual(input.actionSchema, schema)
        XCTAssertEqual(input.screenshotPNG, png)
        XCTAssertTrue(input.observationJSON.contains(#""elements":[{"bbox":[1,2,30,12]"#))
        XCTAssertTrue(input.observationJSON.contains("[attached PNG image]"))
        XCTAssertFalse(input.observationJSON.contains(png.base64EncodedString()))
        XCTAssertEqual(transport.callCount, 1)
    }

    func testMalformedJSONAndExtraActionFieldsAreRejectedWithoutRetry() async throws {
        let validArguments = #"{"type":"done","answer":"ok"}"#
        for raw in ["Here is the action: {\"type\":\"done\",\"answer\":\"ok\"}",
                    try completionWithoutToolCall(content: #"<tool_call>{"name":"computer_use","arguments":{"type":"done","answer":"ok"}}</tool_call>"#),
                    try completion(arguments: #"{"type":"done","answer":"ok","tool":"extra"}"#),
                    try completion(arguments: validArguments, extraCalls: true),
                    try completion(arguments: validArguments, toolName: "other")] {
            let transport = RecordingAgentVLMTransport(response: raw)
            let (policy, observation, _, _) = try fixture(transport: transport)
            let output = try await policy.propose(observation)
            XCTAssertNil(output.action)
            XCTAssertEqual(output.rawOutput, raw)
            XCTAssertNotNil(output.rejectionReason)
            XCTAssertEqual(transport.callCount, 1)
        }
    }

    func testNativeToolEnvelopeRepresentsEveryCanonicalActionExactly() throws {
        let actions = [
            #"{"type":"click","target":{"x":120,"y":45},"button":"right","count":2}"#,
            #"{"type":"type","text":"sample","mode":"append"}"#,
            #"{"type":"key","chord":"cmd+l"}"#,
            #"{"type":"scroll","direction":"down","amount":40}"#,
            #"{"type":"select","target":{"id":2},"option":"Choice"}"#,
            #"{"type":"drag","from":{"x":1,"y":2},"to":{"x":8,"y":9}}"#,
            #"{"type":"open_url","url":"https://example.test/"}"#,
            #"{"type":"open_app","name":"Example Editor"}"#,
            #"{"type":"find_files","query":"sample","kind":"text"}"#,
            #"{"type":"set_files","target":{"id":3},"file_ids":["file-1"]}"#,
            #"{"type":"wait","seconds":1}"#,
            #"{"type":"ask_user","question":"Choose one","choices":["A","B"]}"#,
            #"{"type":"done","answer":"Complete"}"#,
            #"{"type":"fail","reason":"Unavailable"}"#,
        ]
        for source in actions {
            let raw = try completion(arguments: source)
            let decoded = try FaraPolicyAdapter.actionJSON(fromCompletion: raw)
            XCTAssertEqual(decoded, source)
            XCTAssertNoThrow(try JSONDecoder().decode(AgentAction.self, from: Data(decoded.utf8)))
        }
    }

    func testPolicyCancellationStopsInjectedTransport() async throws {
        let transport = RecordingAgentVLMTransport(response: "", blocks: true)
        let (policy, observation, _, _) = try fixture(transport: transport)
        let proposal = Task { try await policy.propose(observation) }
        while transport.callCount == 0 { await Task.yield() }
        proposal.cancel()
        do {
            _ = try await proposal.value
            XCTFail("A cancelled proposal returned")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.stopCount, 1)
    }

    func testRequestUsesNativeRequiredToolGrammarAndAuthenticatedLoopbackOnly() throws {
        let (_, observation, png, schema) = try fixture(transport: RecordingAgentVLMTransport(response: ""))
        let input = AgentVLMRequestInput(prompt: try promptText(),
            observationJSON: try LlamaVLMPolicy.observationJSON(observation),
            screenshotPNG: png, actionSchema: schema)
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unit-test-token")
        let request = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: input)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:43123/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, ComputerUseFaraRuntimeInputs.modelAlias)
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertNil(body["response_format"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "computer_use")
        let parameters = try XCTUnwrap(function["parameters"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: parameters)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: schema) as? NSDictionary)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertFalse((content[0]["text"] as? String ?? "").contains(png.base64EncodedString()))
        XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"],
                       "data:image/png;base64," + png.base64EncodedString())
        let templateRequest = try OSAtlasLlamaHTTPClient.makeSemanticTemplateRequest(from: request)
        XCTAssertEqual(templateRequest.url?.absoluteString, "http://127.0.0.1:43123/apply-template")
        XCTAssertEqual(templateRequest.httpBody, request.httpBody)
        for url in ["https://example.test/", "http://user:secret@127.0.0.1:43123"] {
            let rejected = OSAtlasLlamaEndpoint(generation: 2, variant: nil,
                baseURL: URL(string: url)!, bearerToken: "token")
            XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: rejected, input: input))
        }
    }

    func testInvalidPNGAndObservationAreRejectedBeforeTransport() async throws {
        let transport = RecordingAgentVLMTransport(response: #"{"type":"done","answer":"ok"}"#)
        let (policy, observation, _, _) = try fixture(transport: transport)
        let invalidPNG = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: "bm90LXBuZw==", elements: observation.elements, focus: observation.focus,
            history: observation.history, budget: observation.budget)
        do { _ = try await policy.propose(invalidPNG); XCTFail("Invalid PNG passed through") }
        catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidVisionInput) }
        XCTAssertEqual(transport.callCount, 0)
    }

    private func fixture(transport: RecordingAgentVLMTransport) throws
        -> (LlamaVLMPolicy, AgentObservation, Data, Data) {
        let png = try XCTUnwrap(NSBitmapImageRep(data: makeJPEG())?.representation(using: .png, properties: [:]))
        let observation = AgentObservation(task: "Complete a generic task",
            surface: .web(url: "https://example.test/", title: nil), screenshot: png.base64EncodedString(),
            elements: [.init(id: 1, role: "button", name: "Continue", value: nil, state: ["enabled"],
                             bbox: .init(x: 1, y: 2, width: 30, height: 12), inView: true)],
            focus: nil, history: [], budget: .init(step: 0, maxSteps: 40))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let prompt = try String(contentsOf: root.appendingPathComponent("policy/prompts/v1.txt"), encoding: .utf8)
        let schema = try Data(contentsOf: root.appendingPathComponent("host-mac/RemoteDesktopHost/Agent/Schemas/action.schema.json"))
        return (try LlamaVLMPolicy(transport: transport, prompt: prompt, actionSchema: schema), observation, png, schema)
    }

    private func promptText() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("policy/prompts/v1.txt"), encoding: .utf8)
    }

    private func completion(arguments: String, toolName: String = "computer_use", extraCalls: Bool = false,
                            content: String = "") throws -> String {
        let function: [String: Any] = ["name": toolName, "arguments": arguments]
        let call: [String: Any] = ["id": "call-1", "type": "function", "function": function]
        var toolCalls: [[String: Any]] = [call]
        if extraCalls { toolCalls.append(call) }
        let message: [String: Any] = ["role": "assistant", "content": content, "tool_calls": toolCalls]
        let body: [String: Any] = ["model": ComputerUseFaraRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "tool_calls", "message": message]]]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func completionWithoutToolCall(content: String) throws -> String {
        let body: [String: Any] = ["model": ComputerUseFaraRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeJPEG() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return image.representation(using: .jpeg, properties: [:])!
    }
}

@MainActor
private final class RecordingAgentVLMTransport: AgentVLMTransport {
    private let response: String
    private let blocks: Bool
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var inputs: [AgentVLMRequestInput] = []
    private(set) var stopCount = 0
    var callCount: Int { inputs.count }

    init(response: String, blocks: Bool = false) {
        self.response = response
        self.blocks = blocks
    }

    func complete(_ input: AgentVLMRequestInput) async throws -> String {
        inputs.append(input)
        if blocks {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return response
    }

    func stop() async {
        stopCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
