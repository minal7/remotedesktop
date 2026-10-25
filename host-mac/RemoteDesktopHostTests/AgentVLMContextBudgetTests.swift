import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentVLMContextBudgetTests: XCTestCase {
    func testAgentFaraLaunchPinsSixteenKFlashAttentionAndF16KVCache() throws {
        let authentication = try OSAtlasLlamaPrivateFile.authentication(token: "test-agent-fara-token-123456")
        defer { try? FileManager.default.removeItem(at: authentication.directoryURL) }
        let inputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: URL(fileURLWithPath: "/models/Fara1.5-4B-Q4_K_M.gguf"),
            projectorURL: URL(fileURLWithPath: "/models/mmproj-Fara1.5-4B-f16.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/runtime/llama-server"))
        let configuration = OSAtlasLlamaLaunchConfiguration(agentVisionInputs: inputs, port: 43125,
            bearerToken: "unused-test-token", authenticationFile: authentication)
        func value(after flag: String) throws -> String {
            let index = try XCTUnwrap(configuration.arguments.firstIndex(of: flag), "Missing \(flag)")
            return try XCTUnwrap(configuration.arguments.dropFirst(index + 1).first)
        }
        XCTAssertEqual(try value(after: "--ctx-size"), "16384")
        XCTAssertEqual(try value(after: "--flash-attn"), "on")
        XCTAssertEqual(try value(after: "--cache-type-k"), "f16")
        XCTAssertEqual(try value(after: "--cache-type-v"), "f16")
        XCTAssertEqual(try value(after: "--image-max-tokens"), "768")
        XCTAssertEqual(try value(after: "--mtmd-batch-max-tokens"), "1536")
        XCTAssertEqual(ComputerUseFaraModel.contextImageTokensPerScreenshot, 768,
            "Per-image preprocessing cap and host context reservation must agree")
        XCTAssertEqual(ComputerUseFaraModel.contextImageBatchTokens, 1536,
            "The independent multimodal batch cap remains unchanged")
    }

    func testAgentImageReservationMatchesEachModelLaunchCap() {
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.trainedVisionImageTokensPerScreenshot(for: .fara15_4b), 768)
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.trainedVisionImageTokensPerScreenshot(for: .uiTars15_7b), 1_536)
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.trainedVisionImageTokensPerScreenshot(for: .guiOwl15_4b), 1_536)
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.reservedAgentImageTokens(imageCount: 2, for: .fara15_4b), 1_536)
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.reservedAgentImageTokens(imageCount: 2, for: .uiTars15_7b), 3_072)
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.reservedAgentImageTokens(imageCount: 2, for: .guiOwl15_4b), 3_072)
    }

    func testTokenizerCountsInputsLargerThanModelContextForTrimming() throws {
        let tokenCount = 70_000
        let ids = Array(repeating: "0", count: tokenCount).joined(separator: ",")
        let response = Data("{\"tokens\":[\(ids)]}".utf8)

        XCTAssertLessThan(response.count, OSAtlasLlamaHTTPClient.maximumTokenizeResponseBytes)
        XCTAssertEqual(try OSAtlasLlamaHTTPClient.tokenCount(from: response), tokenCount)
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.tokenCount(
            from: Data(#"{"tokens":[1.5]}"#.utf8)),
            "Fractional tokenizer IDs remain invalid")
    }

    func testOversizedMarksPreferNearestFocusBeforeScreenCenter() async throws {
        let transport = ContextBudgetTransport()
        let runtime = OSAtlasLlamaRuntime(launcher: ContextBudgetLauncher(),
            transportMaker: ContextBudgetTransportMaker(transport: transport), portProvider: ContextBudgetPort(),
            tokenProvider: ContextBudgetToken(), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: ContextBudgetResources())
        let inputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: URL(fileURLWithPath: "/models/Fara1.5-4B-Q4_K_M.gguf"),
            projectorURL: URL(fileURLWithPath: "/models/mmproj-Fara1.5-4B-f16.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/runtime/llama-server"))
        let policy = try LlamaVLMPolicy(runtimeInputs: inputs, runtime: runtime)
        let huge = String(repeating: "z", count: 7_000)
        let marks = [
            AgentElement(id: 900, role: "textfield", name: huge, value: nil,
                state: ["enabled", "focused"], bbox: .init(x: 90, y: 90, width: 8, height: 8), inView: true),
            AgentElement(id: 901, role: "button", name: huge, value: nil,
                state: ["enabled"], bbox: .init(x: 80, y: 80, width: 8, height: 8), inView: true),
            AgentElement(id: 902, role: "button", name: huge, value: nil,
                state: ["enabled"], bbox: .init(x: 49, y: 49, width: 2, height: 2), inView: true),
            AgentElement(id: 903, role: "button", name: huge, value: nil,
                state: ["enabled"], bbox: .init(x: 0, y: 0, width: 8, height: 8), inView: true),
        ]
        let current = makeObservation(task: "Keep current task", png: try testPNG(), elements: marks,
            focusID: 900, history: [], step: 0)
        let output = try await policy.propose(current)
        XCTAssertEqual(output.action, AgentAction.wait(seconds: 1))
        let completedBody = await transport.completedRequestBody
        let body = try XCTUnwrap(completedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(user.compactMap { $0["text"] as? String }.first)
        let observationText = String(text.prefix { $0 != "\n" })
        let observationData = try XCTUnwrap(observationText.data(using: .utf8))
        let nativeObservation = try XCTUnwrap(JSONSerialization.jsonObject(with: observationData) as? [String: Any])
        let retained = Set((nativeObservation["elements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int })
        XCTAssertTrue(retained.contains(900))
        XCTAssertTrue(retained.contains(901), "The nearest mark to focus outranks a mark at screen centre")
        XCTAssertFalse(retained.contains(902))
        XCTAssertEqual(nativeObservation["task"] as? String, "Keep current task")
        XCTAssertEqual(try imageCount(in: body), 1)
        await runtime.shutdown()
    }

    func testOversizedMarksAndBoundedHistoryTrimBeforeCompletion() async throws {
        let transport = ContextBudgetTransport()
        let runtime = OSAtlasLlamaRuntime(launcher: ContextBudgetLauncher(),
            transportMaker: ContextBudgetTransportMaker(transport: transport), portProvider: ContextBudgetPort(),
            tokenProvider: ContextBudgetToken(), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: ContextBudgetResources())
        let inputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: URL(fileURLWithPath: "/models/Fara1.5-4B-Q4_K_M.gguf"),
            projectorURL: URL(fileURLWithPath: "/models/mmproj-Fara1.5-4B-f16.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/runtime/llama-server"))
        let policy = try LlamaVLMPolicy(runtimeInputs: inputs, runtime: runtime)
        let png = try testPNG()
        let focusID = 501
        let focusedElements = [
            AgentElement(id: 500, role: "button", name: "Center control", value: nil,
                state: ["enabled"], bbox: .init(x: 49, y: 49, width: 2, height: 2), inView: true),
            AgentElement(id: focusID, role: "textfield", name: "Focused field", value: nil,
                state: ["enabled", "focused"], bbox: .init(x: 90, y: 90, width: 8, height: 8), inView: true),
        ]
        var history: [AgentHistoryItem] = []
        for index in 0..<3 {
            let prior = makeObservation(task: "Keep this current task intact", png: png,
                elements: focusedElements, focusID: focusID, history: history, step: index)
            _ = try await policy.propose(prior)
            history.append(.init(action: .wait(seconds: 1), result: "prior result \(index)"))
        }
        for index in 2..<8 {
            history.append(.init(action: .wait(seconds: 1),
                result: index == 7 ? "LAST RESULT MUST REMAIN" : "prior result \(index)"))
        }
        await transport.resetMetrics()
        var elements = (0..<411).map { index in
            AgentElement(id: index, role: "button", name: "Long fixture control \(index) " + String(repeating: "x", count: 64),
                value: nil, state: ["enabled"],
                bbox: AgentBoundingBox(x: Double(index % 90), y: Double((index * 7) % 90), width: 4, height: 4), inView: true)
        }
        elements.append(contentsOf: focusedElements)
        let observation = makeObservation(task: "Keep this current task intact", png: png,
            elements: elements, focusID: focusID, history: history, step: 8)

        let output = try await policy.propose(observation)

        XCTAssertEqual(output.action, AgentAction.wait(seconds: 1))
        let tokenizations = await transport.tokenizationRequests
        XCTAssertGreaterThan(tokenizations.count, 1, "An oversized request must be trimmed before a model completion")
        XCTAssertLessThanOrEqual(try imageCount(in: XCTUnwrap(tokenizations.last)), 2,
            "Fara context retains at most one prior screenshot plus the current screenshot")
        let completionCount = await transport.completionCount
        XCTAssertEqual(completionCount, 1, "Context fitting selects one final request; it does not retry model output")
        let completedRequestBody = await transport.completedRequestBody
        let body = try XCTUnwrap(completedRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(userContent.compactMap { $0["text"] as? String }.first)
        let observationText = String(text.prefix { $0 != "\n" })
        let observationData = try XCTUnwrap(observationText.data(using: .utf8))
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: observationData) as? [String: Any])
        XCTAssertEqual(current["task"] as? String, "Keep this current task intact")
        let retainedElements = try XCTUnwrap(current["elements"] as? [[String: Any]])
        XCTAssertGreaterThan(retainedElements.count, 0)
        XCTAssertLessThan(retainedElements.count, 413, "Oversized marks are progressively trimmed")
        let retainedIDs = Set(retainedElements.compactMap { $0["id"] as? Int })
        XCTAssertTrue(retainedIDs.contains(focusID), "Keep the focused mark; proximity ranking is covered separately")
        let userImages = userContent.filter { $0["type"] as? String == "image_url" }.count
        XCTAssertEqual(userImages, 1, "The current screenshot is never trimmed")
        XCTAssertTrue(text.contains("LAST RESULT MUST REMAIN"), "The latest result is retained while older history can be trimmed")
        let finalImageCount = userImages
        let finalTokenCount = await transport.lastTokenCount
        let fitsBudget = finalTokenCount <= OSAtlasLlamaResourceProfile.agentVision.contextSize
            - finalImageCount * ComputerUseFaraModel.contextImageTokensPerScreenshot
            - OSAtlasLlamaHTTPClient.agentMaximumCompletionTokens
            - ComputerUseFaraModel.contextSafetyReserveTokens
        XCTAssertTrue(fitsBudget, "The selected request must fit exact token and reserved image/completion budget")

        let twoLargeMarks = [
            AgentElement(id: 700, role: "button", name: String(repeating: "focused ", count: 3_750), value: nil,
                state: ["enabled", "focused"], bbox: .init(x: 490, y: 490, width: 20, height: 20), inView: true),
            AgentElement(id: 701, role: "button", name: String(repeating: "optional ", count: 3_750), value: nil,
                state: ["enabled"], bbox: .init(x: 800, y: 800, width: 20, height: 20), inView: true),
        ]
        let twoMarkObservation = makeObservation(task: "Keep task and current screenshot", png: png,
            elements: twoLargeMarks, focusID: 700,
            history: [.init(action: .wait(seconds: 1), result: "LATEST RESULT MUST REMAIN")], step: 9)
        let twoMarkOutput = try await policy.propose(twoMarkObservation)
        XCTAssertEqual(twoMarkOutput.action, AgentAction.wait(seconds: 1))
        let completedTwoMarkBody = await transport.completedRequestBody
        let twoMarkBody = try XCTUnwrap(completedTwoMarkBody)
        let twoMarkObject = try XCTUnwrap(JSONSerialization.jsonObject(with: twoMarkBody) as? [String: Any])
        let twoMarkMessages = try XCTUnwrap(twoMarkObject["messages"] as? [[String: Any]])
        let twoMarkUser = try XCTUnwrap(twoMarkMessages.last?["content"] as? [[String: Any]])
        let twoMarkText = try XCTUnwrap(twoMarkUser.compactMap { $0["text"] as? String }.first)
        let twoMarkObservationJSON = String(twoMarkText.prefix { $0 != "\n" })
        let twoMarkCurrent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(twoMarkObservationJSON.utf8)) as? [String: Any])
        XCTAssertEqual(twoMarkCurrent["task"] as? String, "Keep task and current screenshot")
        XCTAssertTrue((twoMarkCurrent["elements"] as? [[String: Any]] ?? []).isEmpty,
            "Optional focused/center marks may be removed when the required task and image otherwise cannot fit")
        XCTAssertTrue(twoMarkText.contains("LATEST RESULT MUST REMAIN"))
        XCTAssertEqual(try imageCount(in: twoMarkBody), 1)

        let tokenizationsBeforeInvalid = await transport.tokenizationRequests
        let priorTokenizationCount = tokenizationsBeforeInvalid.count
        await transport.setForcedTokenCount(0)
        do {
            _ = try await policy.propose(observation)
            XCTFail("A zero token count is an invalid tokenizer response, not a context overflow")
        } catch let error as OSAtlasLlamaRuntimeError {
            if case .invalidResponse = error {} else {
                XCTFail("Expected invalidResponse for a zero token count, got \(error)")
            }
        } catch {
            XCTFail("Expected a runtime error for a zero token count, got \(error)")
        }
        let tokenizationsAfterInvalid = await transport.tokenizationRequests
        XCTAssertEqual(tokenizationsAfterInvalid.count, priorTokenizationCount + 1,
            "An invalid count must not trigger context trimming or a second tokenization")
        let completionCountAfterInvalid = await transport.completionCount
        XCTAssertEqual(completionCountAfterInvalid, 2, "Invalid tokenization must not start another model call")
        await runtime.shutdown()
    }

    func testUntrimmableTaskReturnsUserClarificationWithoutModelCall() async throws {
        let transport = ContextBudgetTransport()
        let runtime = OSAtlasLlamaRuntime(launcher: ContextBudgetLauncher(),
            transportMaker: ContextBudgetTransportMaker(transport: transport), portProvider: ContextBudgetPort(),
            tokenProvider: ContextBudgetToken(), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: ContextBudgetResources())
        let inputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: URL(fileURLWithPath: "/models/Fara1.5-4B-Q4_K_M.gguf"),
            projectorURL: URL(fileURLWithPath: "/models/mmproj-Fara1.5-4B-f16.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/runtime/llama-server"))
        let policy = try LlamaVLMPolicy(runtimeInputs: inputs, runtime: runtime)
        let observation = makeObservation(task: String(repeating: "long task ", count: 4_000), png: try testPNG(),
            elements: [], focusID: 0, history: [], step: 0)

        let output = try await policy.propose(observation)

        XCTAssertEqual(output.action, .askUser(
            question: "The request exceeds the available model context. Please narrow it to the next step.",
            choices: nil))
        XCTAssertEqual(output.rawOutput, "", "A host budget clarification is not model output")
        XCTAssertNil(output.rejectionReason)
        let tokenizationRequestCount = await transport.tokenizationRequestCount
        XCTAssertGreaterThanOrEqual(tokenizationRequestCount, 1)
        let completionCount = await transport.completionCount
        XCTAssertEqual(completionCount, 0, "An overlarge required task never reaches inference")
        await runtime.shutdown()
    }

    func testCancellationWhileTrimTokenizationIsBlockedKeepsSingleOwnerAndSkipsCompletion() async throws {
        let transport = ContextBudgetTransport()
        await transport.setForcedTokenCount(20_000)
        await transport.blockTokenization(onRequest: 2)
        let runtime = OSAtlasLlamaRuntime(launcher: ContextBudgetLauncher(),
            transportMaker: ContextBudgetTransportMaker(transport: transport), portProvider: ContextBudgetPort(),
            tokenProvider: ContextBudgetToken(), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: ContextBudgetResources())
        let inputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: URL(fileURLWithPath: "/models/Fara1.5-4B-Q4_K_M.gguf"),
            projectorURL: URL(fileURLWithPath: "/models/mmproj-Fara1.5-4B-f16.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/runtime/llama-server"))
        let endpoint = try await runtime.activateAgentVision(inputs)
        let png = try testPNG()
        let elements: [[String: Any]] = (0..<8).map { id in
            ["id": id, "bbox": [Double(id * 100), 100.0, 20.0, 20.0]]
        }
        let text = String(data: try JSONSerialization.data(withJSONObject: [
            "task": "fixture", "elements": elements, "focus": ["id": 0],
        ], options: [.sortedKeys]), encoding: .utf8)!
        let input = AgentVLMRequestInput(messages: [
            .init(role: .system, content: [.text("policy")]),
            .init(role: .user, content: [.text(text), .imagePNG(png)]),
        ], modelAlias: ComputerUseFaraRuntimeInputs.modelAlias, model: .fara15_4b)
        let first = Task { try await runtime.completeAgentAction(endpoint: endpoint, input: input) }
        await transport.waitForBlockedTokenization()
        let second = Task { try await runtime.completeAgentAction(endpoint: endpoint, input: input) }
        var queued = await runtime.queuedModelAccessRequestCount
        for _ in 0..<100 where queued == 0 {
            await Task.yield()
            queued = await runtime.queuedModelAccessRequestCount
        }
        XCTAssertEqual(queued, 1, "A second request waits behind the held tokenization lease")
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancellation must unwind the blocked tokenization")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        do {
            _ = try await second.value
            XCTFail("The queued request cannot use the stopped worker")
        } catch {
            XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession)
        }
        let tokenizations = await transport.tokenizationRequests
        XCTAssertEqual(tokenizations.count, 2, "Cancellation prevents another tokenizer or completion request")
        let completions = await transport.completionCount
        XCTAssertEqual(completions, 0)
        await runtime.shutdown()
    }
}

private func makeObservation(task: String, png: Data, elements: [AgentElement], focusID: Int,
                         history: [AgentHistoryItem], step: Int) -> AgentObservation {
    AgentObservation(task: task, surface: .app(bundleID: "fixture.app", title: "Fixture"),
        screenshot: png.base64EncodedString(), elements: elements,
        focus: AgentFocus(id: focusID, role: "textfield", name: "Focused field", valuePrefix: "",
            selection: .init(start: 0, end: 0)), history: history, budget: .init(step: step, maxSteps: 40))
}

private func imageCount(in body: Data) throws -> Int {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
    return messages.reduce(0) { count, message in
        count + ((message["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image_url" }.count ?? 0)
    }
}

private func testPNG() throws -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<100 {
        for x in 0..<100 { image.setColor(.white, atX: x, y: y) }
    }
    return try XCTUnwrap(image.representation(using: .png, properties: [:]))
}

private struct ContextBudgetPort: OSAtlasLlamaPortProviding { func availableLoopbackPort() throws -> UInt16 { 43125 } }
private struct ContextBudgetToken: OSAtlasLlamaTokenProviding { func bearerToken() -> String { "context-budget-test-token" } }
private struct ContextBudgetResources: OSAtlasLlamaResourceInspecting {
    func snapshot() throws -> OSAtlasLlamaResourceSnapshot {
        .init(physicalMemoryBytes: UInt64.max, reclaimableMemoryBytes: UInt64.max)
    }
}
private struct ContextBudgetTransportMaker: OSAtlasLlamaHTTPTransportMaking {
    let transport: ContextBudgetTransport
    func makeTransport() -> any OSAtlasLlamaHTTPTransport { transport }
}
private struct ContextBudgetLauncher: OSAtlasLlamaServerLaunching {
    func launch(configuration: OSAtlasLlamaLaunchConfiguration) async throws -> any OSAtlasLlamaServerProcess {
        ContextBudgetProcess()
    }
}
private struct ContextBudgetProcess: OSAtlasLlamaServerProcess {
    func terminate() async {}
    func waitUntilExit() async throws {}
}

private actor ContextBudgetTransport: OSAtlasLlamaHTTPTransport {
    private(set) var tokenizationRequests: [Data] = []
    private(set) var completionCount = 0
    private(set) var completedRequestBody: Data?
    private(set) var lastTokenCount = 0
    private var forcedTokenCount: Int?
    private var blockedTokenizationRequest: Int?
    private var blockedTokenization: CheckedContinuation<Int, Error>?
    private var tokenizationWaiter: CheckedContinuation<Void, Never>?
    var tokenizationRequestCount: Int { tokenizationRequests.count }
    func resetMetrics() {
        tokenizationRequests.removeAll()
        completionCount = 0
        completedRequestBody = nil
        lastTokenCount = 0
    }
    func setForcedTokenCount(_ value: Int?) { forcedTokenCount = value }
    func blockTokenization(onRequest number: Int) { blockedTokenizationRequest = number }
    func waitForBlockedTokenization() async {
        if blockedTokenization != nil { return }
        await withCheckedContinuation { tokenizationWaiter = $0 }
    }
    func health(baseURL: URL, bearerToken: String) async throws -> Bool { true }
    func modelIsHealthy(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws -> Bool { true }
    func loadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func unloadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        let body = completionRequest.httpBody ?? Data()
        tokenizationRequests.append(body)
        if let blockedTokenizationRequest, tokenizationRequests.count == blockedTokenizationRequest {
            return try await withCheckedThrowingContinuation { continuation in
                blockedTokenization = continuation
                tokenizationWaiter?.resume()
                tokenizationWaiter = nil
            }
        }
        lastTokenCount = forcedTokenCount ?? body.count / 2
        return lastTokenCount
    }
    func complete(request: URLRequest) async throws -> Data {
        completionCount += 1
        completedRequestBody = request.httpBody
        let native = #"<tool_call>{"name":"computer_use","arguments":{"action":"wait","time":1}}</tool_call>"#
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": native]]]])
    }
    func cancelAll() async {
        blockedTokenization?.resume(throwing: CancellationError())
        blockedTokenization = nil
    }
}
