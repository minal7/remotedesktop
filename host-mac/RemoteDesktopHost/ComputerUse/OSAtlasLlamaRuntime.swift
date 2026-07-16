import Darwin
import Foundation
import ImageIO

enum OSAtlasModelVariant: String, Codable, Equatable, Sendable {
    case base4B = "base-4b"
    case pro4B = "pro-4b"
}

/// Fully resolved, verified installation inputs for one local OS-Atlas model.
/// The installer owns download and checksum validation; this runtime accepts
/// only local file URLs and never resolves model content over the network.
struct OSAtlasLlamaRuntimeInputs: Equatable, Sendable {
    let variant: OSAtlasModelVariant
    let modelFirstSplitURL: URL
    let multimodalProjectorURL: URL
    let llamaServerURL: URL
    let runtimeDirectoryURL: URL

    init(
        variant: OSAtlasModelVariant,
        modelFirstSplitURL: URL,
        multimodalProjectorURL: URL,
        llamaServerURL: URL,
        runtimeDirectoryURL: URL
    ) {
        self.variant = variant
        self.modelFirstSplitURL = modelFirstSplitURL.standardizedFileURL
        self.multimodalProjectorURL = multimodalProjectorURL.standardizedFileURL
        self.llamaServerURL = llamaServerURL.standardizedFileURL
        self.runtimeDirectoryURL = runtimeDirectoryURL.standardizedFileURL
    }

    /// Convenience bridge for HostComputerUseManager. The verified receipt
    /// supplies `modelDirectoryURL`; the pinned manifest supplies the first
    /// Q4_K_M split and F16 projector names; the signed app bundle supplies
    /// `llamaServerURL`. Executable code is never accepted from the download.
    init(
        variant: OSAtlasModelVariant,
        modelDirectoryURL: URL,
        modelFirstSplitFileName: String,
        multimodalProjectorFileName: String,
        llamaServerURL: URL
    ) {
        self.init(
            variant: variant,
            modelFirstSplitURL: modelDirectoryURL
                .appendingPathComponent(modelFirstSplitFileName),
            multimodalProjectorURL: modelDirectoryURL
                .appendingPathComponent(multimodalProjectorFileName),
            llamaServerURL: llamaServerURL,
            runtimeDirectoryURL: llamaServerURL.deletingLastPathComponent())
    }
}

struct OSAtlasLlamaEndpoint: Equatable, Sendable {
    let generation: UInt64
    let variant: OSAtlasModelVariant
    let baseURL: URL
    let bearerToken: String
}

struct OSAtlasLlamaLaunchConfiguration: Equatable, Sendable {
    static let host = "127.0.0.1"
    static let maximumGeneratedTokens = 256
    static let contextSize = 8_192
    static let logicalBatchSize = 512
    static let physicalBatchSize = 128
    static let imageTokensPerScreenshot = 256
    static let workerThreads = 4
    static let maximumResidentMemoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let bundledLlamaServerBuild = "b9992"
    static let bundledLlamaServerCommit = "6eddde0"
    /// Byte-for-byte equivalent to OS-Atlas Pro's upstream `phi3-chat`
    /// `Conversation.get_prompt()` for OpenAI-style role messages. In
    /// particular, upstream places the next role token immediately after
    /// `<|end|>`; llama.cpp b9992's legacy built-in `phi3` renderer inserts an
    /// extra newline there and therefore is not used.
    static let officialPhi3ChatTemplate =
        "{% for message in messages %}{{ '<|' + message['role'] + '|>\\n' + message['content'] + '<|end|>' }}{% endfor %}{% if add_generation_prompt %}{{ '<|assistant|>\\n' }}{% endif %}"

    let executableURL: URL
    let workingDirectoryURL: URL
    let modelFirstSplitURL: URL
    let multimodalProjectorURL: URL
    let port: UInt16
    let bearerToken: String

    var arguments: [String] {
        [
            "--model", modelFirstSplitURL.path,
            "--mmproj", multimodalProjectorURL.path,
            "--host", Self.host,
            "--port", String(port),
            "--api-key", bearerToken,
            // OS-Atlas/InternVL can otherwise inherit its 128K model context
            // and llama-server's multi-slot/batching defaults. Those defaults
            // are inappropriate for one-at-a-time local GUI grounding.
            "--ctx-size", String(Self.contextSize),
            "--batch-size", String(Self.logicalBatchSize),
            "--ubatch-size", String(Self.physicalBatchSize),
            "--threads", String(Self.workerThreads),
            "--threads-batch", String(Self.workerThreads),
            "--parallel", "1",
            "--no-cont-batching",
            // One 448 px InternVL tile produces 256 image tokens. Keep both
            // the dynamic-resolution hint and mtmd's encoder batch at that
            // exact budget. The input validator below is the hard tile bound;
            // these flags are defense in depth inside pinned llama.cpp b9992.
            "--image-min-tokens", String(Self.imageTokensPerScreenshot),
            "--image-max-tokens", String(Self.imageTokensPerScreenshot),
            "--mtmd-batch-max-tokens", String(Self.imageTokensPerScreenshot),
            // b9992 otherwise permits an 8 GiB prompt cache and up to 32
            // context checkpoints per slot. Neither is useful for stateless
            // screenshot requests, so do not reserve or retain them.
            "--cache-ram", "0",
            "--ctx-checkpoints", "0",
            "--no-cache-idle-slots",
            // The GGUF's embedded template drops system-role messages, while
            // upstream OS-Atlas uses InternVL's phi3-chat conversation and
            // prepends its pinned system segment. Pin its exact MPT-style
            // serialization instead of b9992's close-but-different legacy
            // phi3 renderer. The template accepts llama.cpp's flattened
            // multimodal content string, including its private image marker.
            "--jinja",
            "--chat-template", Self.officialPhi3ChatTemplate,
            "--temp", "0",
            "--n-predict", String(Self.maximumGeneratedTokens),
            "--log-disable",
            "--no-webui",
        ]
    }
}

/// The image boundary shared by screenshot encoding and the HTTP client.
/// InternVL's pinned b9992 preprocessor treats any dimension above its native
/// 448 px tile as a multi-tile image (up to 12 tiles plus an overview). Keeping
/// both dimensions at or below 448 is therefore the hard memory bound; the
/// normalized 0...1000 coordinate contract remains independent of pixel size.
enum OSAtlasVisionInputPolicy {
    static let maximumPixelDimension = 448
    static let maximumPixelCount = maximumPixelDimension * maximumPixelDimension
    static let maximumEncodedBytes = 512 * 1_024

    struct Dimensions: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    static func validateJPEG(_ data: Data) throws -> Dimensions {
        guard !data.isEmpty,
              data.count <= maximumEncodedBytes,
              data.count >= 3,
              data[data.startIndex] == 0xFF,
              data[data.index(after: data.startIndex)] == 0xD8,
              data[data.index(data.startIndex, offsetBy: 2)] == 0xFF,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumPixelCount else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
        return Dimensions(width: width, height: height)
    }
}

struct OSAtlasLlamaResourceSnapshot: Equatable, Sendable {
    let physicalMemoryBytes: UInt64
    let reclaimableMemoryBytes: UInt64
}

protocol OSAtlasLlamaResourceInspecting: Sendable {
    func snapshot() throws -> OSAtlasLlamaResourceSnapshot
}

protocol OSAtlasLlamaServerProcess: Sendable {
    func terminate() async
    func waitUntilExit() async
}

protocol OSAtlasLlamaServerLaunching: Sendable {
    func launch(
        configuration: OSAtlasLlamaLaunchConfiguration
    ) async throws -> any OSAtlasLlamaServerProcess
}

protocol OSAtlasProcessInspecting: Sendable {
    func matchingProcessIDs(for executableURL: URL) throws -> [pid_t]
    func send(
        signal signalNumber: Int32,
        to processID: pid_t,
        ifExecutableMatches executableURL: URL
    ) throws
}

protocol OSAtlasLlamaHTTPTransport: Sendable {
    func health(baseURL: URL, bearerToken: String) async throws -> Bool
    func complete(request: URLRequest) async throws -> Data
    func cancelAll() async
}

protocol OSAtlasLlamaHTTPTransportMaking: Sendable {
    func makeTransport() -> any OSAtlasLlamaHTTPTransport
}

protocol OSAtlasLlamaPortProviding: Sendable {
    func availableLoopbackPort() throws -> UInt16
}

protocol OSAtlasLlamaTokenProviding: Sendable {
    func bearerToken() -> String
}

enum OSAtlasLlamaRuntimeError: Error, LocalizedError, Equatable {
    case proModelRequired
    case invalidLocalInstallation
    case invalidEndpoint
    case serverFailedToStart
    case inactiveSession
    case invalidResponse
    case invalidVisionInput
    case insufficientPhysicalMemory
    case insufficientAvailableMemory
    case resourceInspectionFailed

    var errorDescription: String? {
        switch self {
        case .proModelRequired:
            return "OS-Atlas Pro 4B is required for AI Computer Use."
        case .invalidLocalInstallation:
            return "The installed OS-Atlas runtime could not be verified. Choose Retry to repair it."
        case .invalidEndpoint:
            return "The local OS-Atlas endpoint was rejected because it was not loopback-only."
        case .serverFailedToStart:
            return "The local OS-Atlas model could not start."
        case .inactiveSession:
            return "The local OS-Atlas model changed while this task was running. Please retry."
        case .invalidResponse:
            return "The local OS-Atlas model returned an invalid response, so the Mac was left untouched."
        case .invalidVisionInput:
            return "The screenshot exceeded the safe local-model image limit, so the Mac was left untouched."
        case .insufficientPhysicalMemory:
            return "AI Computer Use requires a Mac with at least 16 GB of memory."
        case .insufficientAvailableMemory:
            return "There is not enough free memory for AI Computer Use. Close some apps, then choose Retry."
        case .resourceInspectionFailed:
            return "The Mac could not verify that enough memory is available for AI Computer Use. Choose Retry."
        }
    }
}

/// The sole owner of llama-server processes. Actor serialization plus the
/// stop-and-await activation boundary guarantees that Base and Pro are never
/// resident at the same time.
actor OSAtlasLlamaRuntime {
    static let shared = OSAtlasLlamaRuntime()

    static let minimumPhysicalMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    static let minimumLaunchMemoryBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024
    // The launch check reserves enough reclaimable memory to make the model
    // resident. Once it is loaded, the independent 8 GiB process guard bounds
    // any further growth. Keeping another 4 GiB reclaimable at that point made
    // the verified Q4 runtime reject inference on otherwise healthy 16/32 GiB
    // Macs, including while the system still reported normal memory pressure.
    // Two GiB covers the remaining bounded growth without making the
    // advertised 16 GiB minimum impossible under an ordinary app workload.
    static let minimumInferenceMemoryBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    private struct ActiveServer {
        let inputs: OSAtlasLlamaRuntimeInputs
        let endpoint: OSAtlasLlamaEndpoint
        let process: any OSAtlasLlamaServerProcess
        let transport: any OSAtlasLlamaHTTPTransport
    }

    private enum LifecycleOperation: Sendable {
        case replace(OSAtlasLlamaRuntimeInputs)
        case stop
    }

    private enum LifecycleTransitionResult: Sendable {
        case success
        case failure(OSAtlasLlamaRuntimeError)
        case cancelled
    }

    private struct LifecycleTransition {
        let generation: UInt64
        let task: Task<LifecycleTransitionResult, Never>
    }

    private let launcher: any OSAtlasLlamaServerLaunching
    private let transportMaker: any OSAtlasLlamaHTTPTransportMaking
    private let portProvider: any OSAtlasLlamaPortProviding
    private let tokenProvider: any OSAtlasLlamaTokenProviding
    private let resourceInspector: any OSAtlasLlamaResourceInspecting
    private let readinessAttempts: Int
    private let readinessDelay: Duration
    private let cachedHealthAttempts = 3
    private let cachedHealthDelay: Duration = .milliseconds(100)
    private var active: ActiveServer?
    private var nextGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    /// Invalidates activation calls that were already in flight when a stop
    /// request arrived. In particular, a cached-server health request is an
    /// actor reentrancy point and may ignore task cancellation at its transport
    /// boundary. Its old epoch must never be allowed to launch a replacement
    /// after shutdown has completed.
    private var activationEpoch: UInt64 = 0
    private var lifecycleTransition: LifecycleTransition?

    init() {
        launcher = FoundationOSAtlasLlamaServerLauncher()
        transportMaker = URLSessionOSAtlasTransportMaker()
        portProvider = LoopbackPortProvider()
        tokenProvider = RandomBearerTokenProvider()
        resourceInspector = DarwinOSAtlasLlamaResourceInspector()
        readinessAttempts = 120
        readinessDelay = .milliseconds(250)
    }

    init(
        launcher: any OSAtlasLlamaServerLaunching,
        transportMaker: any OSAtlasLlamaHTTPTransportMaking,
        portProvider: any OSAtlasLlamaPortProviding,
        tokenProvider: any OSAtlasLlamaTokenProviding,
        readinessAttempts: Int,
        readinessDelay: Duration,
        resourceInspector: any OSAtlasLlamaResourceInspecting = DarwinOSAtlasLlamaResourceInspector()
    ) {
        self.launcher = launcher
        self.transportMaker = transportMaker
        self.portProvider = portProvider
        self.tokenProvider = tokenProvider
        self.resourceInspector = resourceInspector
        self.readinessAttempts = max(1, readinessAttempts)
        self.readinessDelay = readinessDelay
    }

    func activate(
        _ inputs: OSAtlasLlamaRuntimeInputs
    ) async throws -> OSAtlasLlamaEndpoint {
        guard inputs.variant == .pro4B else {
            throw OSAtlasLlamaRuntimeError.proModelRequired
        }
        try Self.validateLocalInputs(inputs)
        try Task.checkCancellation()
        let requestedEpoch = activationEpoch
        await waitForLifecycleTransition()
        try validateActivation(epoch: requestedEpoch)
        while let candidate = active, candidate.inputs == inputs {
            let endpoint = candidate.endpoint
            let isHealthy = try await cachedServerIsHealthy(candidate)
            // Health checks are actor-reentrant. If another lifecycle request
            // replaced this endpoint while the request was in flight, inspect
            // the new server instead of starting a second replacement.
            await waitForLifecycleTransition()
            try validateActivation(epoch: requestedEpoch)
            guard let current = active, current.inputs == inputs else { break }
            guard current.endpoint == endpoint else { continue }
            if isHealthy {
                return endpoint
            }
            break
        }
        try validateActivation(epoch: requestedEpoch)
        switch await runLifecycleTransition(
            .replace(inputs),
            activationEpoch: requestedEpoch
        ) {
        case .success:
            break
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
        do {
            try validateActivation(epoch: requestedEpoch)
        } catch {
            _ = await runLifecycleTransition(.stop, activationEpoch: nil)
            throw error
        }
        guard let active, active.inputs == inputs else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        return active.endpoint
    }

    private func cachedServerIsHealthy(_ server: ActiveServer) async throws -> Bool {
        for attempt in 0 ..< cachedHealthAttempts {
            try Task.checkCancellation()
            do {
                let isHealthy = try await server.transport.health(
                    baseURL: server.endpoint.baseURL,
                    bearerToken: server.endpoint.bearerToken)
                try Task.checkCancellation()
                if isHealthy { return true }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed health request means the cached server may need a
                // restart. Preserve caller cancellation instead of folding it
                // into that ordinary unhealthy result.
                try Task.checkCancellation()
            }
            if attempt + 1 < cachedHealthAttempts {
                try await Task.sleep(for: cachedHealthDelay)
            }
        }
        return false
    }

    func complete(
        endpoint: OSAtlasLlamaEndpoint,
        prompt: String,
        jpegData: Data
    ) async throws -> String {
        guard let active,
              active.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        do {
            try validateResources(
                minimumReclaimableBytes: Self.minimumInferenceMemoryBytes)
        } catch {
            // Release the resident model as part of failing closed. This gives
            // memory back to the user's apps instead of leaving a multi-GB
            // child alive after refusing the inference request.
            await stopActiveServerUnserialized()
            throw error
        }
        let request = try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: prompt,
            jpegData: jpegData)
        let data = try await active.transport.complete(request: request)
        try Task.checkCancellation()
        guard self.active?.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        return try OSAtlasLlamaHTTPClient.responseText(from: data)
    }

    func cancel(endpoint: OSAtlasLlamaEndpoint) async {
        invalidateInFlightActivations()
        await waitForLifecycleTransition()
        guard active?.endpoint == endpoint else { return }
        _ = await runLifecycleTransition(.stop, activationEpoch: nil)
    }

    func shutdown() async {
        invalidateInFlightActivations()
        await waitForLifecycleTransition()
        _ = await runLifecycleTransition(.stop, activationEpoch: nil)
    }

    func activeVariant() -> OSAtlasModelVariant? {
        active?.endpoint.variant
    }

    private func runLifecycleTransition(
        _ operation: LifecycleOperation,
        activationEpoch expectedActivationEpoch: UInt64?
    ) async -> LifecycleTransitionResult {
        precondition(lifecycleTransition == nil)
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let task = Task {
            await self.performLifecycleOperation(
                operation,
                activationEpoch: expectedActivationEpoch)
        }
        lifecycleTransition = LifecycleTransition(
            generation: generation,
            task: task)
        // Task.init creates an unstructured lifecycle worker, so cancellation
        // of the activate caller is not inherited after creation. Bridge it
        // explicitly; otherwise a cancelled setup could continue launching a
        // multi-gigabyte server while HostComputerUseManager waits to exit.
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if lifecycleTransition?.generation == generation {
            lifecycleTransition = nil
        }
        return result
    }

    private func waitForLifecycleTransition() async {
        while let transition = lifecycleTransition {
            _ = await transition.task.value
            if lifecycleTransition?.generation == transition.generation {
                lifecycleTransition = nil
            }
        }
    }

    private func performLifecycleOperation(
        _ operation: LifecycleOperation,
        activationEpoch expectedActivationEpoch: UInt64?
    ) async -> LifecycleTransitionResult {
        switch operation {
        case .stop:
            await stopActiveServerUnserialized()
            return .success
        case .replace(let inputs):
            await stopActiveServerUnserialized()
            do {
                try validateActivation(epoch: expectedActivationEpoch)
                try validateResources(
                    minimumReclaimableBytes: Self.minimumLaunchMemoryBytes)
                let port = try portProvider.availableLoopbackPort()
                let token = tokenProvider.bearerToken()
                guard !token.isEmpty else {
                    throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
                }
                let baseURL = URL(
                    string: "http://\(OSAtlasLlamaLaunchConfiguration.host):\(port)")!
                try Self.validateLoopbackEndpoint(baseURL)
                let configuration = OSAtlasLlamaLaunchConfiguration(
                    executableURL: inputs.llamaServerURL,
                    workingDirectoryURL: inputs.runtimeDirectoryURL,
                    modelFirstSplitURL: inputs.modelFirstSplitURL,
                    multimodalProjectorURL: inputs.multimodalProjectorURL,
                    port: port,
                    bearerToken: token)
                let transport = transportMaker.makeTransport()
                let process = try await launcher.launch(configuration: configuration)
                nextGeneration &+= 1
                let endpoint = OSAtlasLlamaEndpoint(
                    generation: nextGeneration,
                    variant: inputs.variant,
                    baseURL: baseURL,
                    bearerToken: token)
                active = ActiveServer(
                    inputs: inputs,
                    endpoint: endpoint,
                    process: process,
                    transport: transport)
                try validateActivation(epoch: expectedActivationEpoch)
                try await waitUntilReady(endpoint: endpoint, transport: transport)
                // Recheck after model/projector residency so setup never says
                // "ready" when there is no safe headroom for the first tile.
                try validateResources(
                    minimumReclaimableBytes: Self.minimumInferenceMemoryBytes)
                try validateActivation(epoch: expectedActivationEpoch)
                return .success
            } catch is CancellationError {
                await stopActiveServerUnserialized()
                return .cancelled
            } catch let error as OSAtlasLlamaRuntimeError {
                await stopActiveServerUnserialized()
                return .failure(error)
            } catch {
                await stopActiveServerUnserialized()
                return .failure(.serverFailedToStart)
            }
        }
    }

    private func waitUntilReady(
        endpoint: OSAtlasLlamaEndpoint,
        transport: any OSAtlasLlamaHTTPTransport
    ) async throws {
        for attempt in 0 ..< readinessAttempts {
            try Task.checkCancellation()
            do {
                let isHealthy = try await transport.health(
                    baseURL: endpoint.baseURL,
                    bearerToken: endpoint.bearerToken)
                try Task.checkCancellation()
                if isHealthy { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
            if attempt + 1 < readinessAttempts {
                try await Task.sleep(for: readinessDelay)
            }
        }
        throw OSAtlasLlamaRuntimeError.serverFailedToStart
    }

    private func validateActivation(epoch expectedEpoch: UInt64?) throws {
        try Task.checkCancellation()
        if let expectedEpoch, expectedEpoch != activationEpoch {
            throw CancellationError()
        }
    }

    private func invalidateInFlightActivations() {
        activationEpoch &+= 1
        lifecycleTransition?.task.cancel()
    }

    private func validateResources(
        minimumReclaimableBytes: UInt64
    ) throws {
        let snapshot: OSAtlasLlamaResourceSnapshot
        do {
            snapshot = try resourceInspector.snapshot()
        } catch {
            throw OSAtlasLlamaRuntimeError.resourceInspectionFailed
        }
        guard snapshot.physicalMemoryBytes >= Self.minimumPhysicalMemoryBytes else {
            throw OSAtlasLlamaRuntimeError.insufficientPhysicalMemory
        }
        guard snapshot.reclaimableMemoryBytes >= minimumReclaimableBytes else {
            throw OSAtlasLlamaRuntimeError.insufficientAvailableMemory
        }
    }

    /// Call only from the lifecycle transition task. Other lifecycle requests
    /// wait on that task before they can start, closing the actor-reentrancy
    /// window that would otherwise allow two model processes to overlap.
    private func stopActiveServerUnserialized() async {
        guard let server = active else { return }
        // Invalidate HTTP work first so generation cannot continue while the
        // process teardown is pending. Then await the old process before any
        // replacement can be launched.
        active = nil
        await server.transport.cancelAll()
        await server.process.terminate()
        await server.process.waitUntilExit()
    }

    private static func validateLocalInputs(
        _ inputs: OSAtlasLlamaRuntimeInputs
    ) throws {
        let urls = [
            inputs.modelFirstSplitURL,
            inputs.multimodalProjectorURL,
            inputs.llamaServerURL,
            inputs.runtimeDirectoryURL,
        ]
        guard urls.allSatisfy(\.isFileURL),
              inputs.modelFirstSplitURL.pathExtension.lowercased() == "gguf",
              inputs.multimodalProjectorURL.pathExtension.lowercased() == "gguf",
              inputs.modelFirstSplitURL.lastPathComponent
                .lowercased().contains("q4_k_m"),
              inputs.modelFirstSplitURL.lastPathComponent
                .lowercased().contains("00001-of-"),
              inputs.multimodalProjectorURL.lastPathComponent
                .lowercased().contains("f16") else {
            throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
        }
    }

    static func validateLoopbackEndpoint(_ url: URL) throws {
        guard url.scheme?.lowercased() == "http",
              url.host == OSAtlasLlamaLaunchConfiguration.host,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw OSAtlasLlamaRuntimeError.invalidEndpoint
        }
    }
}

enum OSAtlasLlamaHTTPClient {
    /// Pinned `phi3-chat` system message from OS-Atlas-Pro-4B's
    /// `conversation.py`. The model was trained with this exact conditioning;
    /// replacing it with a generic assistant message measurably degraded point
    /// grounding in the local acceptance fixture.
    static let officialInternVLSystemMessage =
        "你是由上海人工智能实验室联合商汤科技开发的书生多模态大模型，英文名叫InternVL, 是一个有用无害的人工智能助手。"

    private struct ImageURL: Encodable {
        let url: String
    }

    private struct Content: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    private struct RequestBody: Encodable {
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    static func makeCompletionRequest(
        endpoint: OSAtlasLlamaEndpoint,
        prompt: String,
        jpegData: Data
    ) throws -> URLRequest {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(endpoint.baseURL)
        guard !endpoint.bearerToken.isEmpty,
              !prompt.isEmpty,
              !jpegData.isEmpty else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        _ = try OSAtlasVisionInputPolicy.validateJPEG(jpegData)
        let completionURL = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: completionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(endpoint.bearerToken)",
            forHTTPHeaderField: "Authorization")
        let image = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let promptParts = prompt.components(
            separatedBy: OSAtlasPromptContract.screenshotMarker)
        guard promptParts.count == 2,
              !promptParts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !promptParts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            messages: [
                Message(
                    role: "system",
                    content: [Content(
                        type: "text",
                        text: officialInternVLSystemMessage,
                        imageURL: nil)]),
                Message(
                    role: "user",
                    content: [
                        Content(type: "text", text: promptParts[0], imageURL: nil),
                        Content(
                            type: "image_url",
                            text: nil,
                            imageURL: ImageURL(url: image)),
                        Content(type: "text", text: promptParts[1], imageURL: nil),
                    ]),
            ],
            temperature: 0,
            maxTokens: OSAtlasLlamaLaunchConfiguration.maximumGeneratedTokens,
            stream: false))
        return request
    }

    static func responseText(from data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(ResponseBody.self, from: data),
              response.choices.count == 1 else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        let text = response.choices[0].message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        return text
    }
}

enum OSAtlasPromptContract {
    /// This is an application-side sentinel only. It is removed before JSON
    /// serialization and replaced by exactly one typed `image_url` part at the
    /// same position, so llama-server creates its private media marker there.
    static let screenshotMarker = "<image>"
}

struct DarwinOSAtlasLlamaResourceInspector: OSAtlasLlamaResourceInspecting {
    func snapshot() throws -> OSAtlasLlamaResourceSnapshot {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size
                / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    rebound,
                    &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw OSAtlasLlamaRuntimeError.resourceInspectionFailed
        }

        let pages = [
            statistics.free_count,
            statistics.inactive_count,
            statistics.speculative_count,
        ].reduce(UInt64(0)) { partial, value in
            partial.addingReportingOverflow(UInt64(value)).partialValue
        }
        let reclaimable = pages.multipliedReportingOverflow(
            by: UInt64(vm_kernel_page_size))
        guard !reclaimable.overflow else {
            throw OSAtlasLlamaRuntimeError.resourceInspectionFailed
        }
        return OSAtlasLlamaResourceSnapshot(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            reclaimableMemoryBytes: reclaimable.partialValue)
    }
}

private struct URLSessionOSAtlasTransportMaker: OSAtlasLlamaHTTPTransportMaking {
    func makeTransport() -> any OSAtlasLlamaHTTPTransport {
        URLSessionOSAtlasTransport()
    }
}

private final class URLSessionOSAtlasTransport: OSAtlasLlamaHTTPTransport,
    @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func health(baseURL: URL, bearerToken: String) async throws -> Bool {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func complete(request: URLRequest) async throws -> Data {
        guard let url = request.url else {
            throw OSAtlasLlamaRuntimeError.invalidEndpoint
        }
        guard let scheme = url.scheme,
              let host = url.host,
              let baseURL = URL(string: "\(scheme)://\(host):\(url.port ?? 80)") else {
            throw OSAtlasLlamaRuntimeError.invalidEndpoint
        }
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        return data
    }

    func cancelAll() async {
        session.invalidateAndCancel()
    }
}

private struct LoopbackPortProvider: OSAtlasLlamaPortProviding {
    func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr(OSAtlasLlamaLaunchConfiguration.host))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        return UInt16(bigEndian: bound.sin_port)
    }
}

private struct RandomBearerTokenProvider: OSAtlasLlamaTokenProviding {
    func bearerToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private struct FoundationOSAtlasLlamaServerLauncher: OSAtlasLlamaServerLaunching {
    private let processReaper = OSAtlasExclusiveProcessReaper()

    func launch(
        configuration: OSAtlasLlamaLaunchConfiguration
    ) async throws -> any OSAtlasLlamaServerProcess {
        // A prior host can disappear without AppKit receiving a termination
        // callback (power loss or SIGKILL). Reclaim only processes whose
        // executable resolves to this exact signed bundled runtime, and await
        // their exit before loading another model.
        do {
            try await processReaper.prepareForExclusiveLaunch(
                executableURL: configuration.executableURL)
        } catch {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.arguments = configuration.arguments
        // llama-server is deliberately log-disabled. Null file handles are a
        // second privacy boundary so prompts, typed text, and model reasoning
        // cannot enter the host's unified log or console if a dependency
        // regresses its logging behavior.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        return FoundationOSAtlasLlamaServerProcess(
            process: process,
            maximumResidentMemoryBytes:
                OSAtlasLlamaLaunchConfiguration.maximumResidentMemoryBytes)
    }
}

/// Cross-process counterpart to OSAtlasLlamaRuntime's actor serialization.
/// It never matches by process name: only the canonical path to this app's
/// signed llama-server is eligible for termination.
struct OSAtlasExclusiveProcessReaper: Sendable {
    private let inspector: any OSAtlasProcessInspecting
    private let gracefulAttempts: Int
    private let forcedAttempts: Int
    private let retryDelay: Duration

    init(
        inspector: any OSAtlasProcessInspecting = DarwinOSAtlasProcessInspector(),
        gracefulAttempts: Int = 40,
        forcedAttempts: Int = 40,
        retryDelay: Duration = .milliseconds(50)
    ) {
        self.inspector = inspector
        self.gracefulAttempts = max(1, gracefulAttempts)
        self.forcedAttempts = max(1, forcedAttempts)
        self.retryDelay = retryDelay
    }

    func prepareForExclusiveLaunch(executableURL: URL) async throws {
        var remaining = try inspector.matchingProcessIDs(for: executableURL)
        guard !remaining.isEmpty else { return }

        for processID in remaining {
            try inspector.send(
                signal: SIGTERM,
                to: processID,
                ifExecutableMatches: executableURL)
        }
        remaining = try await waitForExit(
            executableURL: executableURL,
            attempts: gracefulAttempts)
        guard !remaining.isEmpty else { return }

        for processID in remaining {
            try inspector.send(
                signal: SIGKILL,
                to: processID,
                ifExecutableMatches: executableURL)
        }
        remaining = try await waitForExit(
            executableURL: executableURL,
            attempts: forcedAttempts)
        guard remaining.isEmpty else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
    }

    private func waitForExit(
        executableURL: URL,
        attempts: Int
    ) async throws -> [pid_t] {
        for attempt in 0 ..< attempts {
            try Task.checkCancellation()
            let remaining = try inspector.matchingProcessIDs(for: executableURL)
            if remaining.isEmpty { return [] }
            if attempt + 1 < attempts {
                try await Task.sleep(for: retryDelay)
            } else {
                return remaining
            }
        }
        return try inspector.matchingProcessIDs(for: executableURL)
    }
}

struct DarwinOSAtlasProcessInspector: OSAtlasProcessInspecting {
    private enum InspectionError: Error {
        case processListUnavailable
        case signalFailed
    }

    func matchingProcessIDs(for executableURL: URL) throws -> [pid_t] {
        let expectedPath = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return try allProcessIDs().filter { processID in
            guard processID != getpid(),
                  let path = executablePath(processID: processID) else {
                return false
            }
            return URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == expectedPath
        }.sorted()
    }

    func send(
        signal signalNumber: Int32,
        to processID: pid_t,
        ifExecutableMatches executableURL: URL
    ) throws {
        // Revalidate immediately before signaling so PID reuse cannot turn an
        // exact-path cleanup into a signal sent to an unrelated process.
        guard let path = executablePath(processID: processID),
              URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == executableURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path else {
            return
        }
        guard Darwin.kill(processID, signalNumber) == 0 || errno == ESRCH else {
            throw InspectionError.signalFailed
        }
    }

    private func allProcessIDs() throws -> [pid_t] {
        var capacity = 4_096
        while capacity <= 65_536 {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else {
                throw InspectionError.processListUnavailable
            }
            if count < capacity {
                return Array(processIDs.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity *= 2
        }
        throw InspectionError.processListUnavailable
    }

    private func executablePath(processID: pid_t) -> String? {
        var buffer = [CChar](
            repeating: 0,
            // PROC_PIDPATHINFO_MAXSIZE is a C macro (4 * MAXPATHLEN) and is
            // not imported into Swift by every macOS SDK.
            count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(
                processID,
                bytes.baseAddress,
                UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

private final class FoundationOSAtlasLlamaServerProcess: OSAtlasLlamaServerProcess,
    @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var memoryMonitor: Task<Void, Never>?
    private var terminationRequested = false

    init(process: Process, maximumResidentMemoryBytes: UInt64) {
        self.process = process
        let processID = process.processIdentifier
        memoryMonitor = Task.detached(priority: .utility) { [weak process] in
            while !Task.isCancelled {
                guard let process, process.isRunning else { return }
                if let residentBytes = OSAtlasProcessMemoryGuard.residentBytes(
                    processID: processID),
                   residentBytes > maximumResidentMemoryBytes {
                    // This is the last safety boundary if a future mtmd
                    // regression ignores the image/batch limits. SIGKILL is
                    // intentional: allocating past 8 GiB is more dangerous
                    // than preserving model state on a 16 GiB Mac.
                    Darwin.kill(processID, SIGKILL)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    deinit {
        memoryMonitor?.cancel()
    }

    func terminate() async {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !terminationRequested else { return false }
            terminationRequested = true
            return process.isRunning
        }
        memoryMonitor?.cancel()
        if shouldTerminate {
            process.terminate()
        }
    }

    func waitUntilExit() async {
        guard process.isRunning else { return }
        let process = self.process
        let forcedStop = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        forcedStop.cancel()
        memoryMonitor?.cancel()
    }
}

enum OSAtlasProcessMemoryGuard {
    static func residentBytes(processID: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { rebound in
                proc_pid_rusage(processID, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return max(usage.ri_resident_size, usage.ri_phys_footprint)
    }
}
