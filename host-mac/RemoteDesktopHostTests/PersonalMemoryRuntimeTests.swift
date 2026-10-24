import AppKit
import Foundation
import MemoryStoreKit
import XCTest
@testable import RemoteDesktopHost

final class PersonalMemoryRuntimeTests: XCTestCase {
    private let inputs = PersonalMemoryRuntimeInputs(
        modelURL: URL(fileURLWithPath: "/fixture/nomic-embed-text-v1.5.Q8_0.gguf"),
        llamaServerURL: URL(fileURLWithPath: "/fixture/runtime/llama-server"))

    func testNativeTextWithEmbeddingBasenameDoesNotEnableEmbeddingMode() {
        let sameBasename = URL(fileURLWithPath: "/fixture/native/\(PersonalMemoryRuntimeInputs.modelFileName)")
        let config = OSAtlasLlamaLaunchConfiguration(
            nativeTextInputs: .init(modelURL: sameBasename, llamaServerURL: inputs.llamaServerURL),
            port: 1234,
            bearerToken: "fixture-token",
            authenticationFile: .init(
                directoryURL: URL(fileURLWithPath: "/fixture"),
                fileURL: URL(fileURLWithPath: "/fixture/auth"),
                expectedContents: Data("fixture-token".utf8)))

        XCTAssertEqual(config.modelFirstSplitURL.lastPathComponent, PersonalMemoryRuntimeInputs.modelFileName)
        XCTAssertFalse(config.arguments.contains("--embedding"))
        XCTAssertFalse(config.arguments.contains("--pooling"))
    }

    func testEmbeddingActivationUsesAuthenticatedPinnedSingleModelConfiguration() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let client = MemoryRuntimeClient()
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
        addTeardownBlock { await runtime.shutdown() }

        let endpoint = try await runtime.activateMemoryEmbedding(inputs)
        let maybeConfig = await launcher.configuration()
        let config = try XCTUnwrap(maybeConfig)
        let args = config.arguments
        XCTAssertTrue(args.contains("--embedding"))
        XCTAssertEqual(value(after: "--pooling", in: args), "mean")
        XCTAssertTrue(args.contains("--offline"))
        XCTAssertTrue(args.contains("--no-ui"))
        XCTAssertTrue(args.contains("--log-disable"))
        XCTAssertEqual(value(after: "--host", in: args), "127.0.0.1")
        XCTAssertEqual(value(after: "--ctx-size", in: args), "8192")
        XCTAssertEqual(value(after: "--parallel", in: args), "1")
        XCTAssertEqual(value(after: "--batch-size", in: args), "512")
        XCTAssertEqual(value(after: "--ubatch-size", in: args), "512")
        XCTAssertEqual(value(after: "--poll", in: args), "0")
        XCTAssertFalse(args.contains("--alias"))
        XCTAssertFalse(args.contains("--api-key"))
        XCTAssertFalse(args.contains("--mmproj"))
        XCTAssertFalse(args.contains("--models-preset"))
        XCTAssertFalse(args.contains(endpoint.bearerToken))

        let records = await transport.requests()
        XCTAssertEqual(records.map(\.url?.path), ["/health", "/props"])
        XCTAssertTrue(records.dropFirst().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer private-memory-test-token"
        })
        let embeddings = await client.embeddings()
        XCTAssertEqual(embeddings.count, 1)
        XCTAssertEqual(embeddings.first?.text, "runtime readiness check")
    }

    func testMemoryRequestsRemainEndpointBoundAndReturnValidatedResults() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let client = MemoryRuntimeClient()
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
        addTeardownBlock { await runtime.shutdown() }

        let endpoint = try await runtime.activateMemoryEmbedding(inputs)
        let vector = try await runtime.embed(endpoint: endpoint, text: "fixture query", purpose: .query)
        XCTAssertEqual(vector.count, 768)
        XCTAssertTrue(vector.allSatisfy(\.isFinite))
        do {
            _ = try await runtime.countMemoryTokens(endpoint: endpoint, context: "fixture context")
            XCTFail("Nomic tokens must never be reported as planner tokens")
        } catch {
            XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession)
        }
        let faraEndpoint = try await runtime.activateAgentVision(.init(
            model: .fara15_4b,
            modelURL: URL(fileURLWithPath: "/fixture/Fara1.5-4B-Q4_K_M.gguf"),
            projectorURL: URL(fileURLWithPath: "/fixture/mmproj-Fara1.5-4B-f16.gguf"),
            llamaServerURL: inputs.llamaServerURL))
        let tokenCount = try await runtime.countMemoryTokens(endpoint: faraEndpoint, context: "fixture context")
        XCTAssertEqual(tokenCount, 3)
        let embeddings = await client.embeddings()
        XCTAssertEqual(embeddings.map(\.text), ["runtime readiness check", "fixture query"])
        let tokenizations = await client.tokenizations()
        XCTAssertEqual(tokenizations.map(\.context), ["fixture context"])
        XCTAssertEqual(tokenizations.first?.tokenizer.addSpecialTokens, false)
        XCTAssertEqual(tokenizations.first?.tokenizer.parseSpecialTokens, true)
    }

    @MainActor
    func testMemoryPreparationAndPolicyReuseObservedRuntime() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let capture = MemoryRuntimeExchangeCapture()
        let runtime = makeRuntime(launcher: launcher, transport: transport,
            client: MemoryRuntimeClient(), inspectFaraExchange: { request, response in capture.record(request, response) })
        addTeardownBlock { await runtime.shutdown() }

        // Match the production profile-only preparation sequence: bring up
        // Nomic, switch the shared runtime to Fara, and count the prepared
        // context before the agent policy is asked for its first action.
        let memoryRuntime = PersonalMemoryTaskRuntimeOperations.backed(by: runtime)
        _ = try await memoryRuntime.activateEmbedding(inputs)
        let faraInputs = ComputerUseFaraRuntimeInputs(
            modelURL: URL(fileURLWithPath: "/fixture/\(ComputerUseFaraRuntimeInputs.modelFileName)"),
            projectorURL: URL(fileURLWithPath: "/fixture/\(ComputerUseFaraRuntimeInputs.projectorFileName)"),
            llamaServerURL: inputs.llamaServerURL)
        let visionInputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: faraInputs.modelURL, projectorURL: faraInputs.projectorURL,
            llamaServerURL: faraInputs.llamaServerURL)
        let faraEndpoint = try await memoryRuntime.activateAgentVision(visionInputs)
        let preparedTokenCount = try await memoryRuntime.countMemoryTokens(faraEndpoint, "profile context")
        XCTAssertEqual(preparedTokenCount, 3)

        // The task-memory wrapper must retain the policy's runtime. A second
        // runtime would try to launch another worker while this one owns the
        // shared process lease.
        let base = try LlamaVLMPolicy(runtimeInputs: visionInputs,
            runtime: runtime, bundle: policyBundle)
        let policy = TaskMemoryContextPolicy.applying(taskID: "runtime-reuse-task",
            slot: TaskMemoryContextSlot(), base: base)
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        let observation = AgentObservation(task: "Complete a generic task",
            surface: .web(url: "https://example.test/", title: nil),
            screenshot: image.base64EncodedString(), elements: [], focus: nil, history: [],
            budget: .init(step: 0, maxSteps: 1))
        let output = try await policy.propose(observation)
        XCTAssertEqual(output.action, .wait(seconds: 1))

        let launches = await events.values().filter { $0.hasPrefix("launch:") }
        XCTAssertEqual(launches, ["launch:embedding", "launch:fara"],
            "Policy activation must reuse the active Fara worker instead of asking a second runtime to launch the same executable.")
        XCTAssertEqual(capture.count, 1, "The observer must still receive the Fara request/response from the shared runtime.")
        await policy.stop()
    }

    func testWrongAuthenticatedModelIdentityFailsClosedBeforeSentinelOrUse() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events, wrongModelPath: true)
        let launcher = MemoryRuntimeLauncher(events: events)
        let client = MemoryRuntimeClient()
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
        addTeardownBlock { await runtime.shutdown() }

        do {
            _ = try await runtime.activateMemoryEmbedding(inputs)
            XCTFail("A different model path must not become a memory endpoint")
        } catch {
            XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidLocalInstallation)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.url?.path), ["/health", "/props"])
        let embeddings = await client.embeddings()
        XCTAssertTrue(embeddings.isEmpty, "Identity must be checked before the sentinel request")
    }

    func testWrongBuildOrSleepingModelFailsBeforeSentinel() async throws {
        for mode in ["wrong-build", "sleeping"] {
            let events = MemoryRuntimeEvents()
            let transport = MemoryRuntimeTransport(events: events, propsFailure: mode)
            let launcher = MemoryRuntimeLauncher(events: events)
            let client = MemoryRuntimeClient()
            let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
            do {
                _ = try await runtime.activateMemoryEmbedding(inputs)
                XCTFail("Invalid props state must not be accepted: \(mode)")
            } catch {
                XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidLocalInstallation)
            }
            let embeddings = await client.embeddings()
            XCTAssertTrue(embeddings.isEmpty, mode)
            await runtime.shutdown()
        }
    }

    func testReplacingEmbeddingRuntimeStopsOldWorkerBeforeLaunchingNewOne() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: MemoryRuntimeClient())
        addTeardownBlock { await runtime.shutdown() }

        _ = try await runtime.activateNativeText(.init(
            modelURL: URL(fileURLWithPath: "/fixture/native/Qwen3.5-4B-Q4_K_M.gguf"),
            llamaServerURL: inputs.llamaServerURL))
        _ = try await runtime.activateMemoryEmbedding(inputs)

        let values = await events.values()
        let stopped = try XCTUnwrap(values.firstIndex(of: "wait-finished:native"))
        let embeddingLaunched = try XCTUnwrap(values.firstIndex(of: "launch:embedding"))
        XCTAssertLessThan(stopped, embeddingLaunched)
    }

    func testReplacedEndpointCannotReachEmbeddingClient() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let client = MemoryRuntimeClient()
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
        addTeardownBlock { await runtime.shutdown() }

        let oldEndpoint = try await runtime.activateMemoryEmbedding(inputs)
        _ = try await runtime.activateNativeText(.init(
            modelURL: URL(fileURLWithPath: "/fixture/native/Qwen3.5-4B-Q4_K_M.gguf"),
            llamaServerURL: inputs.llamaServerURL))
        do {
            _ = try await runtime.embed(endpoint: oldEndpoint, text: "stale", purpose: .query)
            XCTFail("A replaced endpoint must not issue an embedding request")
        } catch {
            XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession)
        }
        let calls = await client.embeddings()
        XCTAssertEqual(calls.count, 1, "Only activation's fixed readiness probe is allowed")
    }

    func testCancelledEmbeddingDoesNotReturnLateClientResult() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let client = MemoryRuntimeClient(blockText: "blocked query")
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
        addTeardownBlock { await runtime.shutdown() }
        let endpoint = try await runtime.activateMemoryEmbedding(inputs)

        let request = Task {
            try await runtime.embed(endpoint: endpoint, text: "blocked query", purpose: .query)
        }
        let started = await client.waitForBlockedCall()
        XCTAssertTrue(started, "The injected local adapter should reach its blocked fake call")
        request.cancel()
        await client.releaseBlockedCall()
        do {
            _ = try await request.value
            XCTFail("A cancellation-ignoring adapter result must not escape")
        } catch is CancellationError {
        }
        let calls = await client.embeddings()
        XCTAssertEqual(calls.count, 2, "Only readiness and the cancelled request were dispatched")
        let stopped = await events.waitFor("wait-finished:embedding")
        XCTAssertTrue(stopped, "Cancellation must join the server")
    }

    func testShutdownJoinsEmbeddingFailureTeardownAlreadyInProgress() async throws {
        let events = MemoryRuntimeEvents()
        let transport = MemoryRuntimeTransport(events: events)
        let launcher = MemoryRuntimeLauncher(events: events)
        let client = MemoryRuntimeClient(failText: "failed query")
        let runtime = makeRuntime(launcher: launcher, transport: transport, client: client)
        addTeardownBlock {
            await events.releaseProcessExit()
            await runtime.shutdown()
        }

        let endpoint = try await runtime.activateMemoryEmbedding(inputs)
        await events.holdProcessExit("embedding")
        let request = Task {
            try await runtime.embed(endpoint: endpoint, text: "failed query", purpose: .query)
        }
        let exitStarted = await events.waitFor("process-exit-started:embedding")
        XCTAssertTrue(exitStarted, "Failed memory requests must begin joining their worker")

        let shutdown = Task {
            await events.append("shutdown-started")
            await runtime.shutdown()
            await events.append("shutdown-returned")
        }
        let shutdownStarted = await events.waitFor("shutdown-started")
        XCTAssertTrue(shutdownStarted)
        try await Task.sleep(for: .milliseconds(50))
        let valuesBeforeRelease = await events.values()
        XCTAssertFalse(valuesBeforeRelease.contains("shutdown-returned"),
                       "Concurrent shutdown must join the in-progress worker teardown")

        await events.releaseProcessExit()
        _ = try? await request.value
        await shutdown.value
        let valuesAfterRelease = await events.values()
        XCTAssertTrue(valuesAfterRelease.contains("shutdown-returned"))
    }

    private func makeRuntime(
        launcher: MemoryRuntimeLauncher,
        transport: MemoryRuntimeTransport,
        client: any PersonalMemoryRuntimeClient,
        inspectFaraExchange: (@Sendable (Data, Data) -> Void)? = nil
    ) -> OSAtlasLlamaRuntime {
        OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: MemoryRuntimeTransportMaker(transport),
            portProvider: MemoryRuntimePort(),
            tokenProvider: MemoryRuntimeToken(),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: MemoryRuntimeResources(),
            inspectFaraExchange: inspectFaraExchange,
            personalMemoryClient: client)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private var policyBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        .main
#endif
    }
}

private actor MemoryRuntimeEvents {
    private var storage: [String] = []
    private var heldProcessExit: String?
    private var processExitContinuation: CheckedContinuation<Void, Never>?
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
    func holdProcessExit(_ name: String) { heldProcessExit = name }
    func waitForProcessExit(_ name: String) async {
        storage.append("process-exit-started:\(name)")
        guard heldProcessExit == name else { return }
        await withCheckedContinuation { processExitContinuation = $0 }
        heldProcessExit = nil
    }
    func releaseProcessExit() {
        processExitContinuation?.resume()
        processExitContinuation = nil
    }
    func waitFor(_ expected: String, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if storage.contains(expected) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return storage.contains(expected)
    }
}

private actor MemoryRuntimeClient: PersonalMemoryRuntimeClient {
    private var embeddingCalls: [(text: String, purpose: MemoryEmbeddingPurpose)] = []
    private var tokenCalls: [(context: String, tokenizer: LlamaCppTokenizerIdentity)] = []
    private let blockText: String?
    private let failText: String?
    private var didBlock = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiter: CheckedContinuation<Bool, Never>?
    init(blockText: String? = nil, failText: String? = nil) {
        self.blockText = blockText
        self.failText = failText
    }
    func embed(endpoint: LlamaCppLocalEndpoint, text: String,
               purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        embeddingCalls.append((text, purpose))
        if text == failText { throw OSAtlasLlamaRuntimeError.invalidResponse }
        if let blockText, text == blockText {
            didBlock = true
            blockedWaiter?.resume(returning: true)
            blockedWaiter = nil
            await withCheckedContinuation { blockedContinuation = $0 }
        }
        return Array(repeating: 0.25, count: 768)
    }
    func countTokens(endpoint: LlamaCppLocalEndpoint, context: String,
                     tokenizer: LlamaCppTokenizerIdentity) async throws -> Int {
        tokenCalls.append((context, tokenizer))
        return 3
    }
    func waitForBlockedCall(timeout: Duration = .seconds(2)) async -> Bool {
        if didBlock { return true }
        return await withCheckedContinuation { continuation in
            blockedWaiter = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.expireBlockedWait()
            }
        }
    }
    private func expireBlockedWait() {
        blockedWaiter?.resume(returning: didBlock)
        blockedWaiter = nil
    }
    func releaseBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
    func embeddings() -> [(text: String, purpose: MemoryEmbeddingPurpose)] { embeddingCalls }
    func tokenizations() -> [(context: String, tokenizer: LlamaCppTokenizerIdentity)] { tokenCalls }
}

private actor MemoryRuntimeLauncher: OSAtlasLlamaServerLaunching {
    private let events: MemoryRuntimeEvents
    private var lastConfiguration: OSAtlasLlamaLaunchConfiguration?
    init(events: MemoryRuntimeEvents) { self.events = events }
    func launch(configuration: OSAtlasLlamaLaunchConfiguration) async throws -> any OSAtlasLlamaServerProcess {
        lastConfiguration = configuration
        let name = configuration.arguments.contains("--embedding") ? "embedding" :
            (configuration.arguments.contains("--mmproj") ? "fara" : "native")
        await events.append("launch:\(name)")
        return MemoryRuntimeProcess(name: name, events: events)
    }
    func configuration() -> OSAtlasLlamaLaunchConfiguration? { lastConfiguration }
}

private actor MemoryRuntimeProcess: OSAtlasLlamaServerProcess {
    let name: String
    let events: MemoryRuntimeEvents
    nonisolated let workerStopReason: OSAtlasLlamaWorkerStopReason? = nil
    init(name: String, events: MemoryRuntimeEvents) { self.name = name; self.events = events }
    func terminate() async { await events.append("terminate:\(name)") }
    func waitUntilExit() async throws {
        await events.waitForProcessExit(name)
        await events.append("wait-finished:\(name)")
    }
}

private struct MemoryRuntimeTransportMaker: OSAtlasLlamaHTTPTransportMaking {
    let transport: MemoryRuntimeTransport
    init(_ transport: MemoryRuntimeTransport) { self.transport = transport }
    func makeTransport() -> any OSAtlasLlamaHTTPTransport { transport }
}

private actor MemoryRuntimeTransport: OSAtlasLlamaHTTPTransport {
    private let events: MemoryRuntimeEvents
    private let wrongModelPath: Bool
    private let propsFailure: String?
    private var requestsStorage: [URLRequest] = []
    init(events: MemoryRuntimeEvents, wrongModelPath: Bool = false, propsFailure: String? = nil) {
        self.events = events
        self.wrongModelPath = wrongModelPath
        self.propsFailure = propsFailure
    }
    func health(baseURL: URL, bearerToken: String) async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        requestsStorage.append(request)
        return true
    }
    func modelIsHealthy(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws -> Bool { true }
    func loadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func unloadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func complete(request: URLRequest) async throws -> Data {
        requestsStorage.append(request)
        switch request.url?.path {
        case "/props":
            let modelPath = wrongModelPath ? "/other/model.gguf" : "/fixture/nomic-embed-text-v1.5.Q8_0.gguf"
            let build = propsFailure == "wrong-build"
                ? "b9992-not-the-pinned-build" : PersonalMemoryRuntimeInputs.llamaServerBuildInfo
            let sleeping = propsFailure == "sleeping"
            return try JSONSerialization.data(withJSONObject: [
                "model_path": modelPath, "build_info": build, "is_sleeping": sleeping,
            ])
        case "/v1/embeddings":
            return try JSONSerialization.data(withJSONObject: [
                "data": [["index": 0, "embedding": Array(repeating: 0.25, count: 768)]],
            ])
        case "/tokenize": return Data("{\"tokens\":[1,2,3]}".utf8)
        case "/v1/chat/completions":
            let action = #"<tool_call>{"name":"computer_use","arguments":{"action":"wait","time":1}}</tool_call>"#
            return try JSONSerialization.data(withJSONObject: [
                "model": ComputerUseFaraRuntimeInputs.modelAlias,
                "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": action]]],
            ])
        default: throw OSAtlasLlamaRuntimeError.invalidResponse
        }
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { 3 }
    func cancelAll() async {}
    func requests() -> [URLRequest] { requestsStorage }
}

private final class MemoryRuntimeExchangeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [(Data, Data)] = []

    func record(_ request: Data, _ response: Data) {
        lock.lock()
        exchanges.append((request, response))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return exchanges.count
    }
}

private struct MemoryRuntimePort: OSAtlasLlamaPortProviding { func availableLoopbackPort() throws -> UInt16 { 43127 } }
private struct MemoryRuntimeToken: OSAtlasLlamaTokenProviding { func bearerToken() -> String { "private-memory-test-token" } }
private struct MemoryRuntimeResources: OSAtlasLlamaResourceInspecting {
    func snapshot() throws -> OSAtlasLlamaResourceSnapshot {
        .init(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024, reclaimableMemoryBytes: .max)
    }
}
