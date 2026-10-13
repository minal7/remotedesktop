import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentLlamaVLMPolicyTests: XCTestCase {
    func testPolicyIncludesPromptSchemaElementsAndOneAttachedPNG() async throws {
        let raw = try completion(arguments: #"{"action":"left_click","coordinate":[250,500]}"#,
                                 content: "I will continue with the visible control.")
        let transport = RecordingAgentVLMTransport(response: raw)
        let (policy, observation, png, schema) = try fixture(transport: transport)

        let output = try await policy.propose(observation)

        XCTAssertEqual(policy.promptVersion, "v1-fara-native-tool")
        XCTAssertEqual(output.rawOutput, raw)
        XCTAssertEqual(output.action, .click(target: .point(x: 1, y: 2), button: nil, count: nil))
        let input = try XCTUnwrap(transport.inputs.first)
        XCTAssertTrue(input.prompt.contains("Use find_files to obtain file IDs"))
        XCTAssertTrue(input.prompt.contains("Call Fara's native computer_use tool exactly once"))
        XCTAssertEqual(input.actionSchema, schema)
        XCTAssertEqual(input.screenshotPNG, png)
        XCTAssertTrue(input.observationJSON.contains(#""elements":[{"bbox":[1,2,30,12]"#))
        XCTAssertTrue(input.observationJSON.contains("[attached PNG image]"))
        XCTAssertFalse(input.observationJSON.contains(png.base64EncodedString()))
        XCTAssertEqual(transport.callCount, 1)
    }

    func testMalformedJSONAndExtraActionFieldsAreRejectedWithoutRetry() async throws {
        let validArguments = #"{"action":"terminate","answer":"ok"}"#
        for raw in ["Here is the action: {\"type\":\"done\",\"answer\":\"ok\"}",
                    try completionWithoutToolCall(content: #"<tool_call>{"name":"computer_use","arguments":{"type":"done","answer":"ok"}}</tool_call>"#),
                    try completion(arguments: #"{"action":"terminate","answer":"ok","tool":"extra"}"#),
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
        let cases: [(String, String)] = [
            (#"{"action":"left_click","coordinate":[120,45]}"#, #"{"type":"click","target":{"x":120,"y":45}}"#),
            (#"{"action":"right_click","coordinate":[120,45]}"#, #"{"type":"click","target":{"x":120,"y":45},"button":"right"}"#),
            (#"{"action":"type","text":"sample","mode":"append"}"#, #"{"type":"type","text":"sample","mode":"append"}"#),
            (#"{"action":"key","keys":["CTRL","L"]}"#, #"{"type":"key","chord":"CTRL+L"}"#),
            (#"{"action":"scroll","pixels":40}"#, #"{"type":"scroll","direction":"up","amount":40}"#),
            (#"{"action":"select_option","coordinate":[2,3],"option":"Choice"}"#, #"{"type":"select","target":{"x":2,"y":3},"option":"Choice"}"#),
            (#"{"action":"left_click_drag","start_coordinate":[1,2],"coordinate":[8,9]}"#, #"{"type":"drag","from":{"x":1,"y":2},"to":{"x":8,"y":9}}"#),
            (#"{"action":"visit_url","url":"https://example.test/"}"#, #"{"type":"open_url","url":"https://example.test/"}"#),
            (#"{"action":"open_app","name":"Example Editor"}"#, #"{"type":"open_app","name":"Example Editor"}"#),
            (#"{"action":"find_files","query":"sample","kind":"text"}"#, #"{"type":"find_files","query":"sample","kind":"text"}"#),
            (#"{"action":"set_files","coordinate":[3,4],"file_ids":["file-1"]}"#, #"{"type":"set_files","target":{"x":3,"y":4},"file_ids":["file-1"]}"#),
            (#"{"action":"wait","time":1}"#, #"{"type":"wait","seconds":1}"#),
            (#"{"action":"ask_user_question","question":"Choose one","choices":["A","B"]}"#, #"{"type":"ask_user","question":"Choose one","choices":["A","B"]}"#),
            (#"{"action":"terminate","answer":"Complete"}"#, #"{"type":"done","answer":"Complete"}"#),
            (#"{"action":"fail","reason":"Unavailable"}"#, #"{"type":"fail","reason":"Unavailable"}"#),
        ]
        for (native, expected) in cases {
            let raw = try completion(arguments: native)
            let decoded = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: raw, imageSize: (1_000, 1_000))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
            XCTAssertNoThrow(try JSONDecoder().decode(AgentAction.self, from: Data(decoded.utf8)))
        }
    }

    func testUiTarsNativeTextAndResizedCoordinatesAreStrictlyAdapted() throws {
        XCTAssertEqual(try UIActionTextParser.resizedSize(for: (1280, 800)).width, 1288)
        XCTAssertEqual(try UIActionTextParser.resizedSize(for: (1280, 800)).height, 812)
        let large = try UIActionTextParser.resizedSize(for: (2048, 1323))
        XCTAssertEqual(large.width % 28, 0)
        XCTAssertEqual(large.height % 28, 0)
        XCTAssertGreaterThanOrEqual(large.width * large.height, 8 * 28 * 28)
        XCTAssertLessThanOrEqual(large.width * large.height, 1_536 * 28 * 28)
        XCTAssertThrowsError(try UIActionTextParser.resizedSize(for: (10_000, 10)))
        let center = try uiTarsCompletion("Thought: click the visible control.\nAction: click(start_box='(644,406)')")
        let mapped = try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: center, imageSize: (1280, 800))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(mapped.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":640,"y":400}}"#.utf8)) as? NSDictionary)
        for invalid in [
            "Thought: choose.\nAction: click(start_box='(1288,406)')",
            "Thought: choose.\nAction: click(start_box='(1,2)')\nAction: wait()",
            "Thought: choose.\nAction: python('arbitrary')",
            "Thought: choose.\nAction: click(start_box='(NaN,2)')",
        ] {
            XCTAssertThrowsError(try UIActionTextParser.canonicalJSON(invalid, imageSize: (1280, 800)))
        }
    }

    func testUiTarsNativeActionBranchesMapToCanonicalActions() throws {
        let cases: [(String, String)] = [
            ("click(start_box='(644,406)')", #"{"type":"click","target":{"x":640,"y":400}}"#),
            ("left_double(start_box='(644,406)')", #"{"type":"click","target":{"x":640,"y":400},"count":2}"#),
            ("right_single(start_box='(644,406)')", #"{"type":"click","target":{"x":640,"y":400},"button":"right"}"#),
            ("drag(start_box='(644,406)', end_box='(1287,811)')", #"{"type":"drag","from":{"x":640,"y":400},"to":{"x":1279.0062111801242,"y":799.0147783251232}}"#),
            ("hotkey(key='CTRL+L')", #"{"type":"key","chord":"CTRL+L"}"#),
            ("type(content='hello\\nworld')", #"{"type":"type","text":"hello\nworld","mode":"append"}"#),
            ("scroll(start_box='(644,406)', direction='down')", #"{"type":"scroll","target":{"x":640,"y":400},"direction":"down","amount":400}"#),
            ("wait()", #"{"type":"wait","seconds":5}"#),
            ("finished(content='complete')", #"{"type":"done","answer":"complete"}"#),
            ("call_user(content='clarify')", #"{"type":"ask_user","question":"clarify"}"#),
            ("open_url(url='https://example.test/')", #"{"type":"open_url","url":"https://example.test/"}"#),
            ("open_app(name='Example Editor')", #"{"type":"open_app","name":"Example Editor"}"#),
            ("find_files(query='sample', kind='text')", #"{"type":"find_files","query":"sample","kind":"text"}"#),
            ("select_option(start_box='(644,406)', option='First choice')", #"{"type":"select","target":{"x":640,"y":400},"option":"First choice"}"#),
            ("set_files(start_box='(644,406)', file_ids='[\\\"file-1\\\"]')", #"{"type":"set_files","target":{"x":640,"y":400},"file_ids":["file-1"]}"#),
            ("fail(reason='Unavailable')", #"{"type":"fail","reason":"Unavailable"}"#),
        ]
        for (line, expected) in cases {
            let actual = try UIActionTextParser.canonicalJSON("Thought: act.\nAction: " + line, imageSize: (1280, 800))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(actual.utf8)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary, line)
            XCTAssertNoThrow(try JSONDecoder().decode(AgentAction.self, from: Data(actual.utf8)), line)
        }
    }

    func testFaraNormalizedCoordinatesAndScrollScaleToScreenshot() throws {
        let center = try completion(arguments: #"{"action":"left_click","coordinate":[500,500]}"#)
        let centerAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: center, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(centerAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":1000,"y":500}}"#.utf8)) as? NSDictionary)
        let edge = try completion(arguments: #"{"action":"left_click","coordinate":[999,999]}"#)
        let edgeAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: edge, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(edgeAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":1998,"y":999}}"#.utf8)) as? NSDictionary)
        let vertical = try completion(arguments: #"{"action":"scroll","pixels":500}"#)
        let verticalAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: vertical, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(verticalAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"scroll","direction":"up","amount":500}"#.utf8)) as? NSDictionary)
        let horizontal = try completion(arguments: #"{"action":"hscroll","pixels":500}"#)
        let horizontalAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: horizontal, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(horizontalAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"scroll","direction":"right","amount":1000}"#.utf8)) as? NSDictionary)
        let invalid = try completion(arguments: #"{"action":"left_click","coordinate":[1000,10]}"#)
        XCTAssertThrowsError(try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: invalid, imageSize: (2_000, 1_000)))
    }

    func testUiTarsCompletionRejectsWrongModelAndMultipleChoices() throws {
        let valid = try uiTarsCompletion("Thought: wait.\nAction: wait()")
        XCTAssertNoThrow(try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: valid, imageSize: (1920, 1080)))
        let wrong = valid.replacingOccurrences(of: "ui-tars15-7b-v1", with: "another-model")
        XCTAssertThrowsError(try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: wrong, imageSize: (1920, 1080)))
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        var choices = try XCTUnwrap(body["choices"] as? [[String: Any]])
        choices.append(choices[0]); body["choices"] = choices
        let multiple = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertThrowsError(try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: multiple, imageSize: (1920, 1080)))
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

    func testPolicyCarriesOnlyTwoPriorPNGs() async throws {
        let raw = try completion(arguments: #"{"action":"wait","time":1}"#)
        let transport = RecordingAgentVLMTransport(response: raw)
        let (policy, observation, png, _) = try fixture(transport: transport)
        for _ in 0..<3 { _ = try await policy.propose(observation) }
        XCTAssertEqual(transport.inputs.map(\.priorScreenshotsPNG.count), [0, 1, 2])
        let request = AgentVLMRequestInput(prompt: "Prompt", observationJSON: "{}", screenshotPNG: png,
            actionSchema: try AgentPolicyActionSchema.schema(for: .fara15_4b),
            priorScreenshotsPNG: [png, png, png])
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unit-test-token")
        let urlRequest = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image_url", "image_url", "image_url"])
    }

    func testObservationCarriesOnlyLastEightActionResults() throws {
        let items = (0..<10).map { index in
            AgentHistoryItem(action: .wait(seconds: 1), result: "result-\(index)")
        }
        let observation = AgentObservation(task: "A generic task",
            surface: .app(bundleID: "example.editor", title: nil), screenshot: "AA==",
            elements: [], focus: nil, history: items, budget: .init(step: 10, maxSteps: 20))
        let json = try LlamaVLMPolicy.observationJSON(observation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let history = try XCTUnwrap(object["history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 8)
        XCTAssertEqual(history.first?["result"] as? String, "result-2")
        XCTAssertEqual(history.last?["result"] as? String, "result-9")
    }

    func testPolicyCapturePreferencesAndUIResourceLimitsAreExplicit() {
        XCTAssertEqual(AgentPolicyModel.fara15_4b.capturePreference, .frontmostWindow)
        XCTAssertEqual(AgentPolicyModel.uiTars15_7b.capturePreference, .fullDisplay)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.agentVision.contextSize, 16_384)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.agentVision.maximumResidentMemoryBytes, 12 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.agentVision.maximumResidentModelWorkers, 1)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.fara.contextSize, 8_192)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.fara.maximumResidentMemoryBytes, 4 * 1_024 * 1_024 * 1_024)
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
        let uiInput = AgentVLMRequestInput(prompt: "UI prompt", observationJSON: "{}", screenshotPNG: png,
            actionSchema: try AgentPolicyActionSchema.schema(for: .uiTars15_7b),
            modelAlias: "ui-tars15-7b-v1", model: .uiTars15_7b)
        let uiRequest = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: uiInput)
        let uiBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(uiRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(uiBody["model"] as? String, "ui-tars15-7b-v1")
        XCTAssertNil(uiBody["tools"])
        XCTAssertNil(uiBody["tool_choice"])
        XCTAssertNil(uiBody["response_format"])
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
        let promptURL = try XCTUnwrap(Bundle.main.url(forResource: "v1", withExtension: "txt",
                                                      subdirectory: "policy/prompts"))
        let prompt = try String(contentsOf: promptURL, encoding: .utf8)
        let schema = try AgentPolicyActionSchema.schema(for: .fara15_4b)
        return (try LlamaVLMPolicy(transport: transport, prompt: prompt, actionSchema: schema), observation, png, schema)
    }

    private func promptText() throws -> String {
        let promptURL = try XCTUnwrap(Bundle.main.url(forResource: "v1", withExtension: "txt",
                                                      subdirectory: "policy/prompts"))
        return try String(contentsOf: promptURL, encoding: .utf8)
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

    private func uiTarsCompletion(_ content: String) throws -> String {
        let body: [String: Any] = ["model": "ui-tars15-7b-v1",
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
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
