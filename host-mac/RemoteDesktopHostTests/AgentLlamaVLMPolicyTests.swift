import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentLlamaVLMPolicyTests: XCTestCase {
    func testPolicyIncludesPromptSchemaElementsAndOneAttachedPNG() async throws {
        let transport = RecordingAgentVLMTransport(response: #"{"type":"click","target":{"id":1}}"#)
        let (policy, observation, png, schema) = try fixture(transport: transport)

        let output = try await policy.propose(observation)

        XCTAssertEqual(policy.promptVersion, "v1")
        XCTAssertEqual(output.rawOutput, #"{"type":"click","target":{"id":1}}"#)
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
        for raw in ["Here is the action: {\"type\":\"done\",\"answer\":\"ok\"}",
                    #"{"type":"done","answer":"ok","tool":"extra"}"#] {
            let transport = RecordingAgentVLMTransport(response: raw)
            let (policy, observation, _, _) = try fixture(transport: transport)
            let output = try await policy.propose(observation)
            XCTAssertNil(output.action)
            XCTAssertEqual(output.rawOutput, raw)
            XCTAssertNotNil(output.rejectionReason)
            XCTAssertEqual(transport.callCount, 1)
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

    func testRequestUsesStrictSchemaGrammarAndAuthenticatedLoopbackOnly() throws {
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
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let declaration = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(declaration["strict"] as? Bool, true)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: declaration["schema"]!)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: schema) as? NSDictionary)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertFalse((content[0]["text"] as? String ?? "").contains(png.base64EncodedString()))
        XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"],
                       "data:image/png;base64," + png.base64EncodedString())
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
