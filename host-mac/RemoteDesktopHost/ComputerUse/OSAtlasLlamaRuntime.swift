import Darwin
import CryptoKit
import Foundation
import ImageIO

@_silgen_name("flock")
private func osAtlasRuntimeFlock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

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

/// Host-only discriminator for semantic prompt/tool contracts. This value is
/// intentionally absent from the OpenAI-compatible JSON body: the host uses
/// it to reject a request whose frozen schema does not match the installed
/// served-model alias before any model switch, tokenization, or completion.
enum OSAtlasLlamaSemanticContract: Equatable, Sendable {
    case nativeRoutingV4
    case candidateSelectionV5
}

/// Stable, application-owned router identifiers. Callers never provide model
/// names: the runtime injects one of these values after it has validated the
/// endpoint generation and the locally verified model installation.
enum OSAtlasLlamaServedModel: String, CaseIterable, Equatable, Hashable, Sendable {
    case visualGrounder = "visual-grounder-v1"
    case semanticRouter = "semantic-router-v1"

    var semanticContract: OSAtlasLlamaSemanticContract? {
        switch self {
        case .visualGrounder:
            return nil
        case .semanticRouter:
            return .nativeRoutingV4
        }
    }
}

/// A deliberately small JSON value used for native-tool parameter schemas.
/// Keeping this typed prevents the semantic layer from passing arbitrary
/// Foundation objects or pre-encoded request bodies through the runtime.
indirect enum OSAtlasLlamaJSONValue: Codable, Equatable, Sendable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct OSAtlasLlamaSemanticMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Equatable, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct OSAtlasLlamaSemanticTool: Equatable, Sendable {
    let name: String
    let description: String
    let parameters: OSAtlasLlamaJSONValue
}

/// Model-neutral input for one native-tool semantic routing request. The
/// runtime supplies the fixed model ID, deterministic sampling values,
/// required tool choice, and non-streaming policy.
struct OSAtlasLlamaSemanticRequest: Equatable, Sendable {
    static let maximumMessages = 16
    static let maximumMessageBytes = 64 * 1_024
    static let maximumTools = 64
    static let maximumToolDescriptionBytes = 4 * 1_024
    static let maximumGeneratedTokens = 256

    let contract: OSAtlasLlamaSemanticContract
    let messages: [OSAtlasLlamaSemanticMessage]
    let tools: [OSAtlasLlamaSemanticTool]
    let maxTokens: Int

    init(
        contract: OSAtlasLlamaSemanticContract,
        messages: [OSAtlasLlamaSemanticMessage],
        tools: [OSAtlasLlamaSemanticTool],
        maxTokens: Int = Self.maximumGeneratedTokens
    ) {
        self.contract = contract
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }

    /// Binds the caller's host-only discriminator to the exact frozen prompt
    /// and native-tool surface. The tag alone is not authority: a request with
    /// V5 messages/tools relabeled as V4 must fail before model switching,
    /// tokenization, or completion.
    func matchesFrozenShape(
        for servedContract: OSAtlasLlamaSemanticContract
    ) -> Bool {
        guard contract == servedContract,
              messages.count == 2,
              messages[0].role == .system,
              messages[1].role == .user else {
            return false
        }
        switch servedContract {
        case .nativeRoutingV4:
            guard messages[0].content == LlamaSemanticActionRouter.systemPrompt,
                  maxTokens == Self.maximumGeneratedTokens else {
                return false
            }
            let names = tools.map(\.name)
            let allowedOrder = SemanticNativeToolWireContract
                .canonicalToolNames
                + [SemanticNativeToolWireContract.evaluatorAbstainName]
            let offered = Set(names)
            guard !names.isEmpty,
                  offered.count == names.count,
                  names == allowedOrder.filter(offered.contains),
                  names.last
                    == SemanticNativeToolWireContract.evaluatorAbstainName else {
                return false
            }
            for tool in tools {
                guard let definition = SemanticNativeToolWireContract
                        .definition(named: tool.name),
                      let parameters = try? LlamaSemanticActionRouter
                        .llamaJSON(definition.inputSchema),
                      tool == OSAtlasLlamaSemanticTool(
                        name: definition.name,
                        description: definition.description,
                        parameters: parameters) else {
                    return false
                }
            }
            return true
        case .candidateSelectionV5:
            return messages[0].content
                    == SemanticCandidateSelectionV5.systemPrompt
                && maxTokens == SemanticCandidateSelectionV5.maximumTokens
                && SemanticCandidateSelectionV5.matchesRuntimeTools(tools)
        }
    }
}

/// Hardware-aware limits for the one-at-a-time local visual runtime. The
/// compact profile is deliberately not just a relaxed installation check: it
/// reduces llama.cpp's context and batch allocations, requires launch and
/// post-load headroom, and halves the independent process kill ceiling.
struct OSAtlasLlamaResourceProfile: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        case compact
        case standard
    }

    static let minimumPhysicalMemoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let standardPhysicalMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024

    static let compact = OSAtlasLlamaResourceProfile(
        tier: .compact,
        contextSize: 4_096,
        logicalBatchSize: 256,
        physicalBatchSize: 64,
        maximumResidentMemoryBytes: 4 * 1_024 * 1_024 * 1_024,
        minimumLaunchMemoryBytes: 3 * 1_024 * 1_024 * 1_024,
        minimumInferenceMemoryBytes: 1 * 1_024 * 1_024 * 1_024)

    static let standard = OSAtlasLlamaResourceProfile(
        tier: .standard,
        contextSize: 8_192,
        logicalBatchSize: 512,
        physicalBatchSize: 128,
        maximumResidentMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        minimumLaunchMemoryBytes: 6 * 1_024 * 1_024 * 1_024,
        minimumInferenceMemoryBytes: 2 * 1_024 * 1_024 * 1_024)

    let tier: Tier
    let contextSize: Int
    let logicalBatchSize: Int
    let physicalBatchSize: Int
    let maximumResidentMemoryBytes: UInt64
    let minimumLaunchMemoryBytes: UInt64
    let minimumInferenceMemoryBytes: UInt64

    /// Compact Macs cannot safely keep OS-Atlas and the semantic router
    /// resident together. The b9992 router remains alive, but it is limited to
    /// one child worker and the runtime explicitly switches that worker before
    /// inference. Standard hosts retain the two-worker fast path.
    var maximumResidentModelWorkers: Int {
        tier == .compact ? 1 : 2
    }

    static func select(physicalMemoryBytes: UInt64) -> Self? {
        guard physicalMemoryBytes >= minimumPhysicalMemoryBytes else {
            return nil
        }
        return physicalMemoryBytes < standardPhysicalMemoryBytes
            ? .compact
            : .standard
    }
}

/// The exact two-model preset accepted by the pinned b9992 router. It is
/// generated from already-verified local file URLs; there is no repository,
/// URL, alias, or caller-controlled model identifier in this configuration.
struct OSAtlasLlamaRouterPreset: Equatable, Sendable {
    static let version = 1

    let visualModelFirstSplitURL: URL
    let visualProjectorURL: URL
    let semanticModelURL: URL
    let resourceProfile: OSAtlasLlamaResourceProfile

    var contents: String {
        let boundedWorkerSettings = [
            "threads = \(OSAtlasLlamaLaunchConfiguration.workerThreads)",
            "threads-batch = \(OSAtlasLlamaLaunchConfiguration.workerThreads)",
            "parallel = 1",
            "no-cont-batching = true",
            "batch-size = \(resourceProfile.logicalBatchSize)",
            "ubatch-size = \(resourceProfile.physicalBatchSize)",
            "cache-ram = 0",
            "ctx-checkpoints = 0",
            "no-cache-idle-slots = true",
            "temp = 0",
            "n-predict = \(OSAtlasLlamaLaunchConfiguration.maximumGeneratedTokens)",
            "jinja = true",
            "log-disable = true",
            "no-webui = true",
        ]
        return ([
            "version = \(Self.version)",
            "",
            "[\(OSAtlasLlamaServedModel.visualGrounder.rawValue)]",
        ] + boundedWorkerSettings + [
            "model = \(visualModelFirstSplitURL.path)",
            "mmproj = \(visualProjectorURL.path)",
            "ctx-size = \(resourceProfile.contextSize)",
            "image-min-tokens = \(OSAtlasLlamaLaunchConfiguration.imageTokensPerScreenshot)",
            "image-max-tokens = \(OSAtlasLlamaLaunchConfiguration.imageTokensPerScreenshot)",
            "mtmd-batch-max-tokens = \(OSAtlasLlamaLaunchConfiguration.imageTokensPerScreenshot)",
            "chat-template = \(OSAtlasLlamaLaunchConfiguration.officialPhi3ChatTemplate)",
            "load-on-startup = false",
            "",
            "[\(OSAtlasLlamaServedModel.semanticRouter.rawValue)]",
        ] + boundedWorkerSettings + [
            "model = \(semanticModelURL.path)",
            "ctx-size = \(resourceProfile.contextSize)",
            "load-on-startup = false",
            "",
        ]).joined(separator: "\n")
    }

    func validate() throws {
        let urls = [
            visualModelFirstSplitURL,
            visualProjectorURL,
            semanticModelURL,
        ]
        guard urls.allSatisfy(\.isFileURL),
              urls.allSatisfy({ $0.pathExtension.lowercased() == "gguf" }),
              urls.allSatisfy({ url in
                  !url.path.isEmpty
                      && !url.path.contains("\n")
                      && !url.path.contains("\r")
                      && !url.path.contains("\0")
              }) else {
            throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
        }
    }
}

/// A private, owner-only preset lease. The expected bytes travel with the
/// launch configuration so the launcher can verify the file immediately
/// before executing llama-server, then the lifecycle owner deletes it only
/// after the full process tree has exited.
struct OSAtlasLlamaRouterPresetFile: Equatable, Sendable {
    let directoryURL: URL
    let fileURL: URL
    let expectedContents: Data

    static func create(_ preset: OSAtlasLlamaRouterPreset) throws -> Self {
        try preset.validate()
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "RemoteDesktopHost-llama-router-\(UUID().uuidString)",
                isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("models.ini")
            let bytes = Data(preset.contents.utf8)
            try bytes.write(to: file, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path)
            let result = Self(
                directoryURL: directory,
                fileURL: file,
                expectedContents: bytes)
            try result.verify()
            return result
        } catch {
            try? fileManager.removeItem(at: directory)
            if let runtimeError = error as? OSAtlasLlamaRuntimeError {
                throw runtimeError
            }
            throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
        }
    }

    func verify() throws {
        let fileManager = FileManager.default
        let directoryAttributes = try fileManager.attributesOfItem(
            atPath: directoryURL.path)
        let fileAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let directoryPermissions = directoryAttributes[.posixPermissions] as? NSNumber
        let filePermissions = fileAttributes[.posixPermissions] as? NSNumber
        let directoryOwner = directoryAttributes[.ownerAccountID] as? NSNumber
        let fileOwner = fileAttributes[.ownerAccountID] as? NSNumber
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              fileAttributes[.type] as? FileAttributeType == .typeRegular,
              directoryURL.resolvingSymlinksInPath().standardizedFileURL
                == directoryURL.standardizedFileURL,
              fileURL.resolvingSymlinksInPath().standardizedFileURL
                == fileURL.standardizedFileURL,
              let directoryPermissions,
              let filePermissions,
              directoryPermissions.intValue & 0o077 == 0,
              filePermissions.intValue & 0o077 == 0,
              directoryOwner?.uint32Value == geteuid(),
              fileOwner?.uint32Value == geteuid(),
              try Data(contentsOf: fileURL, options: .mappedIfSafe)
                == expectedContents else {
            throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct OSAtlasLlamaLaunchConfiguration: Equatable, Sendable {
    static let host = "127.0.0.1"
    static let maximumGeneratedTokens = 256
    static let imageTokensPerScreenshot = 256
    static let workerThreads = 4
    static let maximumModelWorkers = 2
    static let maximumRouterProcessCount = maximumModelWorkers + 1
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
    let resourceProfile: OSAtlasLlamaResourceProfile
    let routerPresetFile: OSAtlasLlamaRouterPresetFile?

    init(
        executableURL: URL,
        workingDirectoryURL: URL,
        modelFirstSplitURL: URL,
        multimodalProjectorURL: URL,
        port: UInt16,
        bearerToken: String,
        resourceProfile: OSAtlasLlamaResourceProfile = .standard
    ) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.modelFirstSplitURL = modelFirstSplitURL
        self.multimodalProjectorURL = multimodalProjectorURL
        self.port = port
        self.bearerToken = bearerToken
        self.resourceProfile = resourceProfile
        routerPresetFile = nil
    }

    init(
        executableURL: URL,
        workingDirectoryURL: URL,
        modelFirstSplitURL: URL,
        multimodalProjectorURL: URL,
        port: UInt16,
        bearerToken: String,
        resourceProfile: OSAtlasLlamaResourceProfile,
        routerPresetFile: OSAtlasLlamaRouterPresetFile
    ) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.modelFirstSplitURL = modelFirstSplitURL
        self.multimodalProjectorURL = multimodalProjectorURL
        self.port = port
        self.bearerToken = bearerToken
        self.resourceProfile = resourceProfile
        self.routerPresetFile = routerPresetFile
    }

    var arguments: [String] {
        if let routerPresetFile {
            return [
                "--host", Self.host,
                "--port", String(port),
                "--api-key", bearerToken,
                "--models-preset", routerPresetFile.fileURL.path,
                "--models-max", String(resourceProfile.maximumResidentModelWorkers),
                "--no-models-autoload",
                "--offline",
                "--log-disable",
                "--no-webui",
            ]
        }
        return [
            "--model", modelFirstSplitURL.path,
            "--mmproj", multimodalProjectorURL.path,
            "--alias", OSAtlasLlamaServedModel.visualGrounder.rawValue,
            "--host", Self.host,
            "--port", String(port),
            "--api-key", bearerToken,
            "--offline",
            // OS-Atlas/InternVL can otherwise inherit its 128K model context
            // and llama-server's multi-slot/batching defaults. Those defaults
            // are inappropriate for one-at-a-time local GUI grounding.
            "--ctx-size", String(resourceProfile.contextSize),
            "--batch-size", String(resourceProfile.logicalBatchSize),
            "--ubatch-size", String(resourceProfile.physicalBatchSize),
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

    var maximumProcessCount: Int {
        routerPresetFile == nil
            ? 1
            : resourceProfile.maximumResidentModelWorkers + 1
    }

    func processEnvironment(
        inheriting environment: [String: String]
    ) -> [String: String] {
        var sanitized = environment
        for key in environment.keys where
            key.hasPrefix("LLAMA_")
                || key.hasPrefix("GGML_")
                || key.hasPrefix("HF_")
                || key.hasPrefix("HUGGINGFACE_") {
            sanitized.removeValue(forKey: key)
        }
        // The router always registers a built-in empty `default` entry in
        // addition to custom presets. Isolating its cache prevents that entry
        // (or any inherited cache setting) from discovering a third model;
        // callers can only explicitly load the two fixed application IDs.
        if let routerPresetFile {
            sanitized["LLAMA_CACHE"] = routerPresetFile.directoryURL
                .appendingPathComponent("cache", isDirectory: true).path
        }
        return sanitized
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
    func waitUntilExit() async throws
}

protocol OSAtlasLlamaServerLaunching: Sendable {
    func launch(
        configuration: OSAtlasLlamaLaunchConfiguration
    ) async throws -> any OSAtlasLlamaServerProcess
}

/// Immutable identity captured from the kernel for one process incarnation.
/// A PID alone is never an authorization to signal: it can be recycled after
/// enumeration. The executable path and start time bind cleanup to the exact
/// process that was inspected, while both user IDs keep cleanup inside the
/// host's audit boundary.
struct OSAtlasProcessIdentity: Equatable, Hashable, Sendable {
    let processIdentifier: pid_t
    let canonicalExecutablePath: String
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
    let effectiveUserIdentifier: uid_t
    let realUserIdentifier: uid_t

    static func synthetic(processIdentifier: pid_t) -> Self {
        Self(
            processIdentifier: processIdentifier,
            canonicalExecutablePath: "/test/process/\(processIdentifier)",
            startTimeSeconds: UInt64(processIdentifier),
            startTimeMicroseconds: 0,
            effectiveUserIdentifier: Darwin.geteuid(),
            realUserIdentifier: Darwin.getuid())
    }
}

protocol OSAtlasProcessInspecting: Sendable {
    func identity(processID: pid_t) throws -> OSAtlasProcessIdentity?
    func matchingProcesses(
        for executableURL: URL
    ) throws -> [OSAtlasProcessIdentity]
    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifExecutableMatches executableURL: URL
    ) throws
}

struct OSAtlasProcessTreeSnapshot: Equatable, Sendable {
    /// Descendants are ordered deepest-first and the root is always last so a
    /// graceful/forced cleanup cannot orphan workers before signaling them.
    let processIdentitiesChildFirst: [OSAtlasProcessIdentity]
    let aggregateResidentMemoryBytes: UInt64

    var processIDsChildFirst: [pid_t] {
        processIdentitiesChildFirst.map(\.processIdentifier)
    }

    init(
        processIdentitiesChildFirst: [OSAtlasProcessIdentity],
        aggregateResidentMemoryBytes: UInt64
    ) {
        self.processIdentitiesChildFirst = processIdentitiesChildFirst
        self.aggregateResidentMemoryBytes = aggregateResidentMemoryBytes
    }

    /// Test convenience that still gives each PID a stable incarnation. Live
    /// code always uses kernel-captured identities.
    init(
        processIDsChildFirst: [pid_t],
        aggregateResidentMemoryBytes: UInt64
    ) {
        self.init(
            processIdentitiesChildFirst: processIDsChildFirst.map {
                .synthetic(processIdentifier: $0)
            },
            aggregateResidentMemoryBytes: aggregateResidentMemoryBytes)
    }

    func exceeds(
        maximumResidentMemoryBytes: UInt64,
        maximumProcessCount: Int
    ) -> Bool {
        processIDsChildFirst.count > maximumProcessCount
            || aggregateResidentMemoryBytes > maximumResidentMemoryBytes
    }
}

protocol OSAtlasProcessTreeInspecting: Sendable {
    func snapshot(
        rootProcess: OSAtlasProcessIdentity
    ) throws -> OSAtlasProcessTreeSnapshot
    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifMemberOfTreeRoot rootProcess: OSAtlasProcessIdentity
    ) throws
}

struct OSAtlasProcessTreeController: Sendable {
    private let inspector: any OSAtlasProcessTreeInspecting

    init(
        inspector: any OSAtlasProcessTreeInspecting =
            DarwinOSAtlasProcessTreeInspector()
    ) {
        self.inspector = inspector
    }

    func snapshot(
        rootProcess: OSAtlasProcessIdentity
    ) throws -> OSAtlasProcessTreeSnapshot {
        try inspector.snapshot(rootProcess: rootProcess)
    }

    func signalTree(
        rootProcess: OSAtlasProcessIdentity,
        signal: Int32
    ) throws {
        try Task.checkCancellation()
        let snapshot = try inspector.snapshot(rootProcess: rootProcess)
        for process in snapshot.processIdentitiesChildFirst {
            try Task.checkCancellation()
            try inspector.send(
                signal: signal,
                to: process,
                ifMemberOfTreeRoot: rootProcess)
        }
    }
}

protocol OSAtlasLlamaHTTPTransport: Sendable {
    func health(baseURL: URL, bearerToken: String) async throws -> Bool
    func modelIsHealthy(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws -> Bool
    func loadModel(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws
    func unloadModel(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws
    func complete(request: URLRequest) async throws -> Data
    /// Exact count from the resident worker's own OpenAI chat-template and
    /// tokenizer endpoints. Implementations must fail closed on malformed or
    /// unavailable responses; callers never substitute a byte estimate.
    func exactInputTokenCount(
        completionRequest: URLRequest
    ) async throws -> Int
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
            return "The local OS-Atlas model returned an invalid response, so no further action was performed. Any earlier completed steps remain on the Mac."
        case .invalidVisionInput:
            return "The screenshot exceeded the safe local-model image limit, so no further action was performed. Any earlier completed steps remain on the Mac."
        case .insufficientPhysicalMemory:
            return "AI Computer Use requires a Mac with at least 8 GB of memory."
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

    private enum RuntimeInputs: Equatable, Sendable {
        case visual(OSAtlasLlamaRuntimeInputs)
        case router(
            visual: OSAtlasLlamaRuntimeInputs,
            semanticModelURL: URL)

        var visual: OSAtlasLlamaRuntimeInputs {
            switch self {
            case .visual(let inputs), .router(let inputs, _):
                return inputs
            }
        }

        var isRouter: Bool {
            if case .router = self { return true }
            return false
        }

        var semanticModelURL: URL? {
            if case .router(_, let url) = self { return url }
            return nil
        }
    }

    private struct ActiveServer: Sendable {
        let inputs: RuntimeInputs
        let endpoint: OSAtlasLlamaEndpoint
        let resourceProfile: OSAtlasLlamaResourceProfile
        let process: any OSAtlasLlamaServerProcess
        let transport: any OSAtlasLlamaHTTPTransport
        let routerPresetFile: OSAtlasLlamaRouterPresetFile?
        var residentModels: Set<OSAtlasLlamaServedModel>
        /// Monotonically changes whenever the router's physically resident
        /// worker set changes. Executors use this as an optimistic-concurrency
        /// boundary: a route selected across a compact worker swap must be
        /// rebound to a freshly captured screen/AX state before any effect.
        var residencyGeneration: UInt64
    }

    private enum LifecycleOperation: Sendable {
        case replace(RuntimeInputs)
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
    /// Endpoint-scoped cancellation must not invalidate an unrelated newer
    /// activation. Cached activation calls that observed a cancelled endpoint
    /// consult this set before they are allowed to relaunch it.
    private var cancelledEndpointGenerations: Set<UInt64> = []
    private var lifecycleTransition: LifecycleTransition?
    /// Once process cleanup cannot prove the old executable is gone, this
    /// actor must never launch another server. A detached identity-bound reaper
    /// keeps working, but only a fresh host process can clear this poison.
    private var cleanupPoisoned = false
    /// Inference and cached activation checks must not overlap a compact-model
    /// switch. Actor methods are reentrant at HTTP awaits, so an explicit lease
    /// keeps another request from unloading the worker currently completing.
    private var modelAccessLease: UInt64?
    private var nextModelAccessLease: UInt64 = 0
    private var modelAccessWaiters: [CheckedContinuation<Void, Never>] = []

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
        try await activateResolved(.visual(inputs))
    }

    /// Starts one b9992 router process with exactly two generated presets.
    /// Autoload is disabled: standard hosts explicitly load both fixed workers,
    /// while compact hosts load visual first and switch one worker on demand.
    func activateMultiModel(
        visualInputs: OSAtlasLlamaRuntimeInputs,
        semanticModelURL: URL
    ) async throws -> OSAtlasLlamaEndpoint {
        try await activateResolved(.router(
            visual: visualInputs,
            semanticModelURL: semanticModelURL.standardizedFileURL))
    }

    private func activateResolved(
        _ inputs: RuntimeInputs
    ) async throws -> OSAtlasLlamaEndpoint {
        let visualInputs = inputs.visual
        guard visualInputs.variant == .pro4B else {
            throw OSAtlasLlamaRuntimeError.proModelRequired
        }
        try Self.validateLocalInputs(visualInputs)
        if let semanticModelURL = inputs.semanticModelURL {
            try Self.validateSemanticModelURL(semanticModelURL)
        }
        try Task.checkCancellation()
        let requestedEpoch = activationEpoch
        let observedEndpointGeneration = active?.inputs == inputs
            ? active?.endpoint.generation
            : nil
        let modelAccessLease = try await acquireModelAccessLease()
        defer { releaseModelAccessLease(modelAccessLease) }
        try validateActivation(epoch: requestedEpoch)
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
            try validateEndpointWasNotCancelled(observedEndpointGeneration)
            guard let current = active, current.inputs == inputs else { break }
            guard current.endpoint == endpoint else { continue }
            if isHealthy {
                return endpoint
            }
            break
        }
        try validateActivation(epoch: requestedEpoch)
        try validateEndpointWasNotCancelled(observedEndpointGeneration)
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
                var isHealthy = try await server.transport.health(
                    baseURL: server.endpoint.baseURL,
                    bearerToken: server.endpoint.bearerToken)
                if isHealthy, server.inputs.isRouter {
                    guard server.residentModels.count
                            == server.resourceProfile.maximumResidentModelWorkers else {
                        return false
                    }
                    for model in OSAtlasLlamaServedModel.allCases
                        where server.residentModels.contains(model) {
                        isHealthy = try await server.transport.modelIsHealthy(
                            baseURL: server.endpoint.baseURL,
                            bearerToken: server.endpoint.bearerToken,
                            model: model)
                        if !isHealthy { break }
                    }
                }
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
        guard active?.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        let modelAccessLease = try await acquireModelAccessLease()
        defer { releaseModelAccessLease(modelAccessLease) }
        guard let active, active.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        do {
            try validateResources(
                minimumReclaimableBytes:
                    active.resourceProfile.minimumInferenceMemoryBytes)
        } catch {
            // Release the resident model as part of failing closed. This gives
            // memory back to the user's apps instead of leaving a multi-GB
            // child alive after refusing the inference request.
            try await stopActiveServerUnserialized()
            throw error
        }
        let request = try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: prompt,
            jpegData: jpegData)
        do {
            try await ensureModelResident(
                .visualGrounder,
                endpoint: endpoint,
                server: active)
            let data = try await active.transport.complete(request: request)
            try Task.checkCancellation()
            guard self.active?.endpoint == endpoint else {
                throw OSAtlasLlamaRuntimeError.inactiveSession
            }
            return try OSAtlasLlamaHTTPClient.responseText(from: data)
        } catch is CancellationError {
            if self.active?.endpoint == endpoint {
                try await stopActiveServerUnserialized()
            }
            throw CancellationError()
        } catch let error as OSAtlasLlamaRuntimeError {
            if self.active?.endpoint == endpoint {
                try await stopActiveServerUnserialized()
            }
            throw error
        } catch {
            if self.active?.endpoint == endpoint {
                try await stopActiveServerUnserialized()
            }
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
    }

    /// Executes one deterministic native-tool request against the fixed
    /// semantic worker and returns the raw OpenAI-compatible response bytes.
    /// Strict tool-call decoding belongs to the semantic wire layer.
    func completeSemantic(
        endpoint: OSAtlasLlamaEndpoint,
        request: OSAtlasLlamaSemanticRequest
    ) async throws -> Data {
        try await completeSemantic(
            endpoint: endpoint,
            candidateRequests: [request],
            maximumInputTokens: LlamaSemanticActionRouter.maximumInputTokens)
    }

    func completeSemantic(
        endpoint: OSAtlasLlamaEndpoint,
        candidateRequests: [OSAtlasLlamaSemanticRequest],
        maximumInputTokens: Int
    ) async throws -> Data {
        guard active?.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        guard !candidateRequests.isEmpty,
              maximumInputTokens > 0 else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        guard let servedContract = OSAtlasLlamaServedModel.semanticRouter
                .semanticContract,
              candidateRequests.allSatisfy({
                  $0.matchesFrozenShape(for: servedContract)
              }) else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        let modelAccessLease = try await acquireModelAccessLease()
        defer { releaseModelAccessLease(modelAccessLease) }
        guard let active,
              active.endpoint == endpoint,
              active.inputs.isRouter else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        do {
            try validateResources(
                minimumReclaimableBytes:
                    active.resourceProfile.minimumInferenceMemoryBytes)
        } catch {
            try await stopActiveServerUnserialized()
            throw error
        }
        do {
            try await ensureModelResident(
                .semanticRouter,
                endpoint: endpoint,
                server: active)
            var selectedRequest: URLRequest?
            for candidate in candidateRequests {
                guard maximumInputTokens + candidate.maxTokens
                        <= active.resourceProfile.contextSize else {
                    throw OSAtlasLlamaRuntimeError.invalidResponse
                }
                let completionRequest = try OSAtlasLlamaHTTPClient
                    .makeSemanticRequest(
                        endpoint: endpoint,
                        request: candidate)
                let exactTokenCount = try await active.transport
                    .exactInputTokenCount(
                        completionRequest: completionRequest)
                try Task.checkCancellation()
                guard self.active?.endpoint == endpoint else {
                    throw OSAtlasLlamaRuntimeError.inactiveSession
                }
                if exactTokenCount <= maximumInputTokens {
                    selectedRequest = completionRequest
                    break
                }
            }
            guard let selectedRequest else {
                throw OSAtlasLlamaRuntimeError.invalidResponse
            }
            let data = try await active.transport.complete(
                request: selectedRequest)
            try Task.checkCancellation()
            guard self.active?.endpoint == endpoint else {
                throw OSAtlasLlamaRuntimeError.inactiveSession
            }
            // Compact hosts return to the visual worker before exposing a
            // semantic route. Pointer grounding therefore never consumes a
            // pre-switch screenshot, and non-pointer routes can be guarded by
            // the residency-generation/fresh-observation check in the host.
            if active.resourceProfile.maximumResidentModelWorkers == 1 {
                try await ensureModelResident(
                    .visualGrounder,
                    endpoint: endpoint,
                    server: active)
            }
            return data
        } catch is CancellationError {
            if self.active?.endpoint == endpoint {
                try await stopActiveServerUnserialized()
            }
            throw CancellationError()
        } catch let error as OSAtlasLlamaRuntimeError {
            if self.active?.endpoint == endpoint {
                try await stopActiveServerUnserialized()
            }
            throw error
        } catch {
            if self.active?.endpoint == endpoint {
                try await stopActiveServerUnserialized()
            }
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
    }

    func cancel(endpoint: OSAtlasLlamaEndpoint) async {
        cancelledEndpointGenerations.insert(endpoint.generation)
        if cancelledEndpointGenerations.count > 128 {
            let floor = nextGeneration > 64 ? nextGeneration - 64 : 0
            cancelledEndpointGenerations = cancelledEndpointGenerations.filter {
                $0 >= floor
            }
        }
        // Do not invalidate the global activation epoch here. A late task
        // cancellation for generation N has no authority over an in-flight or
        // cached generation N+1 replacement.
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

    func residencyGeneration(
        endpoint: OSAtlasLlamaEndpoint
    ) throws -> UInt64 {
        guard let active, active.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        return active.residencyGeneration
    }

    private func acquireModelAccessLease() async throws -> UInt64 {
        try Task.checkCancellation()
        while modelAccessLease != nil {
            await withCheckedContinuation { continuation in
                modelAccessWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
        nextModelAccessLease &+= 1
        let lease = nextModelAccessLease
        modelAccessLease = lease
        return lease
    }

    private func releaseModelAccessLease(_ lease: UInt64) {
        guard modelAccessLease == lease else { return }
        modelAccessLease = nil
        let waiters = modelAccessWaiters
        modelAccessWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureModelResident(
        _ requestedModel: OSAtlasLlamaServedModel,
        endpoint: OSAtlasLlamaEndpoint,
        server: ActiveServer
    ) async throws {
        try validateActiveServer(endpoint: endpoint, requiresRouter: server.inputs.isRouter)
        guard server.inputs.isRouter else {
            guard requestedModel == .visualGrounder else {
                throw OSAtlasLlamaRuntimeError.inactiveSession
            }
            return
        }

        guard let current = active,
              current.endpoint == endpoint,
              current.residentModels.count
                <= current.resourceProfile.maximumResidentModelWorkers else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        if current.residentModels.contains(requestedModel) {
            return
        }

        // A compact host has exactly one worker slot. Wait for the old worker
        // to be observably gone before asking b9992 to load the replacement;
        // the process-tree guard independently enforces router + one child.
        let modelsToUnload = OSAtlasLlamaServedModel.allCases.filter {
            current.residentModels.contains($0) && $0 != requestedModel
        }
        for model in modelsToUnload {
            guard let latest = active,
                  latest.endpoint == endpoint,
                  latest.residentModels.count
                    >= latest.resourceProfile.maximumResidentModelWorkers else {
                break
            }
            try await server.transport.unloadModel(
                baseURL: endpoint.baseURL,
                bearerToken: endpoint.bearerToken,
                model: model)
            try validateActiveServer(endpoint: endpoint, requiresRouter: true)
            try await waitUntilModelUnloaded(
                endpoint: endpoint,
                transport: server.transport,
                model: model)
            try validateActiveServer(endpoint: endpoint, requiresRouter: true)
            guard var updated = active, updated.endpoint == endpoint else {
                throw OSAtlasLlamaRuntimeError.inactiveSession
            }
            updated.residentModels.remove(model)
            active = updated
        }

        try validateActiveServer(endpoint: endpoint, requiresRouter: true)
        guard let beforeLoad = active,
              beforeLoad.endpoint == endpoint,
              !beforeLoad.residentModels.contains(requestedModel),
              beforeLoad.residentModels.count
                < beforeLoad.resourceProfile.maximumResidentModelWorkers else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        try await server.transport.loadModel(
            baseURL: endpoint.baseURL,
            bearerToken: endpoint.bearerToken,
            model: requestedModel)
        try validateActiveServer(endpoint: endpoint, requiresRouter: true)
        try await waitUntilModelReady(
            endpoint: endpoint,
            transport: server.transport,
            model: requestedModel)
        try validateActiveServer(endpoint: endpoint, requiresRouter: true)
        // Loading a replacement can consume materially more memory than the
        // pre-switch snapshot predicted. Recheck only after b9992 reports the
        // worker ready, before any request is sent to it or the resident set is
        // published to callers.
        try validateResources(
            minimumReclaimableBytes:
                beforeLoad.resourceProfile.minimumInferenceMemoryBytes)
        guard var updated = active, updated.endpoint == endpoint else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
        updated.residentModels.insert(requestedModel)
        updated.residencyGeneration &+= 1
        guard updated.residentModels.count
                <= updated.resourceProfile.maximumResidentModelWorkers else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        active = updated
    }

    private func validateActiveServer(
        endpoint: OSAtlasLlamaEndpoint,
        requiresRouter: Bool
    ) throws {
        try Task.checkCancellation()
        guard let active,
              active.endpoint == endpoint,
              !requiresRouter || active.inputs.isRouter else {
            throw OSAtlasLlamaRuntimeError.inactiveSession
        }
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
            do {
                try await stopActiveServerUnserialized()
                return .success
            } catch let error as OSAtlasLlamaRuntimeError {
                return .failure(error)
            } catch {
                return .failure(.serverFailedToStart)
            }
        case .replace(let inputs):
            var pendingPresetFile: OSAtlasLlamaRouterPresetFile?
            do {
                try await stopActiveServerUnserialized()
                try validateActivation(epoch: expectedActivationEpoch)
                let resourceProfile = try resourceProfileForLaunch()
                let visualInputs = inputs.visual
                let port = try portProvider.availableLoopbackPort()
                let token = tokenProvider.bearerToken()
                guard !token.isEmpty else {
                    throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
                }
                let baseURL = URL(
                    string: "http://\(OSAtlasLlamaLaunchConfiguration.host):\(port)")!
                try Self.validateLoopbackEndpoint(baseURL)
                let configuration: OSAtlasLlamaLaunchConfiguration
                if let semanticModelURL = inputs.semanticModelURL {
                    let presetFile = try OSAtlasLlamaRouterPresetFile.create(
                        OSAtlasLlamaRouterPreset(
                            visualModelFirstSplitURL:
                                visualInputs.modelFirstSplitURL,
                            visualProjectorURL:
                                visualInputs.multimodalProjectorURL,
                            semanticModelURL: semanticModelURL,
                            resourceProfile: resourceProfile))
                    pendingPresetFile = presetFile
                    configuration = OSAtlasLlamaLaunchConfiguration(
                        executableURL: visualInputs.llamaServerURL,
                        workingDirectoryURL: visualInputs.runtimeDirectoryURL,
                        modelFirstSplitURL: visualInputs.modelFirstSplitURL,
                        multimodalProjectorURL:
                            visualInputs.multimodalProjectorURL,
                        port: port,
                        bearerToken: token,
                        resourceProfile: resourceProfile,
                        routerPresetFile: presetFile)
                } else {
                    configuration = OSAtlasLlamaLaunchConfiguration(
                        executableURL: visualInputs.llamaServerURL,
                        workingDirectoryURL: visualInputs.runtimeDirectoryURL,
                        modelFirstSplitURL: visualInputs.modelFirstSplitURL,
                        multimodalProjectorURL:
                            visualInputs.multimodalProjectorURL,
                        port: port,
                        bearerToken: token,
                        resourceProfile: resourceProfile)
                }
                let transport = transportMaker.makeTransport()
                let process = try await launcher.launch(configuration: configuration)
                nextGeneration &+= 1
                let endpoint = OSAtlasLlamaEndpoint(
                    generation: nextGeneration,
                    variant: visualInputs.variant,
                    baseURL: baseURL,
                    bearerToken: token)
                active = ActiveServer(
                    inputs: inputs,
                    endpoint: endpoint,
                    resourceProfile: resourceProfile,
                    process: process,
                    transport: transport,
                    routerPresetFile: pendingPresetFile,
                    residentModels: inputs.isRouter
                        ? []
                        : [.visualGrounder],
                    residencyGeneration: inputs.isRouter ? 0 : 1)
                pendingPresetFile = nil
                try validateActivation(epoch: expectedActivationEpoch)
                try await waitUntilReady(endpoint: endpoint, transport: transport)
                if inputs.isRouter {
                    // A compact endpoint is not ready until both packaged
                    // models have been proven loadable one at a time and the
                    // visual worker has been restored. Standard hosts retain
                    // both workers after the same explicit smoke loads.
                    let startupModels: [OSAtlasLlamaServedModel] =
                        resourceProfile.maximumResidentModelWorkers == 1
                            ? [.visualGrounder, .semanticRouter, .visualGrounder]
                            : OSAtlasLlamaServedModel.allCases
                    for model in startupModels {
                        try validateActivation(epoch: expectedActivationEpoch)
                        guard let server = active,
                              server.endpoint == endpoint else {
                            throw OSAtlasLlamaRuntimeError.inactiveSession
                        }
                        try await ensureModelResident(
                            model,
                            endpoint: endpoint,
                            server: server)
                    }
                }
                // Recheck after model/projector residency so setup never says
                // "ready" when there is no safe headroom for the first tile.
                try validateResources(
                    minimumReclaimableBytes:
                        resourceProfile.minimumInferenceMemoryBytes)
                try validateActivation(epoch: expectedActivationEpoch)
                return .success
            } catch is CancellationError {
                pendingPresetFile?.remove()
                do {
                    try await stopActiveServerUnserialized()
                } catch {
                    return .failure(.serverFailedToStart)
                }
                return .cancelled
            } catch let error as OSAtlasLlamaRuntimeError {
                pendingPresetFile?.remove()
                do {
                    try await stopActiveServerUnserialized()
                } catch {
                    return .failure(.serverFailedToStart)
                }
                return .failure(error)
            } catch {
                pendingPresetFile?.remove()
                do {
                    try await stopActiveServerUnserialized()
                } catch {
                    return .failure(.serverFailedToStart)
                }
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

    private func waitUntilModelReady(
        endpoint: OSAtlasLlamaEndpoint,
        transport: any OSAtlasLlamaHTTPTransport,
        model: OSAtlasLlamaServedModel
    ) async throws {
        for attempt in 0 ..< readinessAttempts {
            try Task.checkCancellation()
            do {
                let isHealthy = try await transport.modelIsHealthy(
                    baseURL: endpoint.baseURL,
                    bearerToken: endpoint.bearerToken,
                    model: model)
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

    private func waitUntilModelUnloaded(
        endpoint: OSAtlasLlamaEndpoint,
        transport: any OSAtlasLlamaHTTPTransport,
        model: OSAtlasLlamaServedModel
    ) async throws {
        for attempt in 0 ..< readinessAttempts {
            try Task.checkCancellation()
            do {
                let isHealthy = try await transport.modelIsHealthy(
                    baseURL: endpoint.baseURL,
                    bearerToken: endpoint.bearerToken,
                    model: model)
                try Task.checkCancellation()
                if !isHealthy { return }
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
        guard !cleanupPoisoned else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        if let expectedEpoch, expectedEpoch != activationEpoch {
            throw CancellationError()
        }
    }

    private func validateEndpointWasNotCancelled(
        _ endpointGeneration: UInt64?
    ) throws {
        guard let endpointGeneration else { return }
        if cancelledEndpointGenerations.contains(endpointGeneration) {
            throw CancellationError()
        }
    }

    private func invalidateInFlightActivations() {
        activationEpoch &+= 1
        lifecycleTransition?.task.cancel()
    }

    private func resourceProfileForLaunch() throws -> OSAtlasLlamaResourceProfile {
        let snapshot = try resourceSnapshot()
        guard let profile = OSAtlasLlamaResourceProfile.select(
            physicalMemoryBytes: snapshot.physicalMemoryBytes
        ) else {
            throw OSAtlasLlamaRuntimeError.insufficientPhysicalMemory
        }
        guard snapshot.reclaimableMemoryBytes >= profile.minimumLaunchMemoryBytes else {
            throw OSAtlasLlamaRuntimeError.insufficientAvailableMemory
        }
        return profile
    }

    private func validateResources(minimumReclaimableBytes: UInt64) throws {
        let snapshot = try resourceSnapshot()
        guard snapshot.physicalMemoryBytes >=
                OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes else {
            throw OSAtlasLlamaRuntimeError.insufficientPhysicalMemory
        }
        guard snapshot.reclaimableMemoryBytes >= minimumReclaimableBytes else {
            throw OSAtlasLlamaRuntimeError.insufficientAvailableMemory
        }
    }

    private func resourceSnapshot() throws -> OSAtlasLlamaResourceSnapshot {
        let snapshot: OSAtlasLlamaResourceSnapshot
        do {
            snapshot = try resourceInspector.snapshot()
        } catch {
            throw OSAtlasLlamaRuntimeError.resourceInspectionFailed
        }
        return snapshot
    }

    /// Call only from the lifecycle transition task. Other lifecycle requests
    /// wait on that task before they can start, closing the actor-reentrancy
    /// window that would otherwise allow two model processes to overlap.
    private func stopActiveServerUnserialized() async throws {
        guard let server = active else { return }
        // Invalidate HTTP work first so generation cannot continue while the
        // process teardown is pending. Capture this exact incarnation before
        // crossing an await: `active` can subsequently describe only a newer
        // generation, never the process this transition is responsible for.
        active = nil

        // Activation callers are allowed to cancel the lifecycle worker so it
        // cannot continue into a launch. Teardown is stronger: once ownership
        // of an ActiveServer has been detached, cancellation must not let its
        // exact process escape the lifecycle barrier. A detached cleanup task
        // cannot inherit caller/transition cancellation, and this transition
        // remains installed until its value is observed below.
        let cleanupSucceeded = await Task.detached { [server] in
            await server.transport.cancelAll()
            await server.process.terminate()
            do {
                try await server.process.waitUntilExit()
                return true
            } catch {
                return false
            }
        }.value
        server.routerPresetFile?.remove()

        // Caller cancellation is handled after the old process is gone and
        // therefore never poisons the runtime. Only a cleanup operation that
        // failed to prove exit permanently prevents a later launch.
        guard cleanupSucceeded else {
            cleanupPoisoned = true
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
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

    private static func validateSemanticModelURL(_ url: URL) throws {
        guard url.isFileURL,
              url.pathExtension.lowercased() == "gguf",
              !url.path.isEmpty,
              !url.path.contains("\n"),
              !url.path.contains("\r"),
              !url.path.contains("\0") else {
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
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
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

    private struct SemanticFunction: Encodable {
        let name: String
        let description: String
        let parameters: OSAtlasLlamaJSONValue
        let strict = true
    }

    private struct SemanticTool: Encodable {
        let type = "function"
        let function: SemanticFunction
    }

    private struct SemanticRequestBody: Encodable {
        let model: String
        let messages: [OSAtlasLlamaSemanticMessage]
        let tools: [SemanticTool]
        let toolChoice = "required"
        let parallelToolCalls = false
        let temperature: Double = 0
        let seed = 0
        let maxTokens: Int
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case tools
            case toolChoice = "tool_choice"
            case parallelToolCalls = "parallel_tool_calls"
            case temperature
            case seed
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private struct TokenizeRequestBody: Encodable {
        let model = OSAtlasLlamaServedModel.semanticRouter.rawValue
        let content: String
        let addSpecial = false
        let parseSpecial = true
        let withPieces = false

        enum CodingKeys: String, CodingKey {
            case model
            case content
            case addSpecial = "add_special"
            case parseSpecial = "parse_special"
            case withPieces = "with_pieces"
        }
    }

    static let maximumTemplateResponseBytes = 512 * 1_024
    static let maximumTokenizeResponseBytes = 1_024 * 1_024
    static let maximumTokenizedInputTokens = 65_536

    private static func validToolSchema(
        _ schema: OSAtlasLlamaJSONValue
    ) -> Bool {
        var nodes = 0
        func visit(_ value: OSAtlasLlamaJSONValue, depth: Int) -> Bool {
            nodes += 1
            guard nodes <= 4_096, depth <= 16 else { return false }
            switch value {
            case .object(let object):
                guard object.keys.allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 256
                }) else { return false }
                if let maximumLength = object["maxLength"] {
                    guard case .number(let value) = maximumLength,
                          value.isFinite,
                          value.rounded(.towardZero) == value,
                          (0 ... 512).contains(value) else {
                        return false
                    }
                }
                return object.values.allSatisfy {
                    visit($0, depth: depth + 1)
                }
            case .array(let array):
                return array.allSatisfy { visit($0, depth: depth + 1) }
            case .string(let string):
                return string.utf8.count <= 64 * 1_024
            case .number(let number):
                return number.isFinite
            case .boolean, .null:
                return true
            }
        }
        guard case .object = schema else { return false }
        return visit(schema, depth: 0)
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
            model: OSAtlasLlamaServedModel.visualGrounder.rawValue,
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

    static func makeSemanticRequest(
        endpoint: OSAtlasLlamaEndpoint,
        request semanticRequest: OSAtlasLlamaSemanticRequest
    ) throws -> URLRequest {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(endpoint.baseURL)
        guard !endpoint.bearerToken.isEmpty,
              !semanticRequest.messages.isEmpty,
              semanticRequest.messages.count
                <= OSAtlasLlamaSemanticRequest.maximumMessages,
              semanticRequest.messages.first?.role == .system,
              semanticRequest.messages.last?.role == .user,
              semanticRequest.messages.allSatisfy({ message in
                  !message.content.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                      && message.content.utf8.count
                        <= OSAtlasLlamaSemanticRequest.maximumMessageBytes
              }),
              !semanticRequest.tools.isEmpty,
              semanticRequest.tools.count
                <= OSAtlasLlamaSemanticRequest.maximumTools,
              (1 ... OSAtlasLlamaSemanticRequest.maximumGeneratedTokens)
                .contains(semanticRequest.maxTokens) else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }

        var names = Set<String>()
        let allowedNameCharacters = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for tool in semanticRequest.tools {
            guard !tool.name.isEmpty,
                  tool.name.utf8.count <= 64,
                  tool.name.unicodeScalars.allSatisfy(
                    allowedNameCharacters.contains),
                  names.insert(tool.name).inserted,
                  !tool.description.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  tool.description.utf8.count
                    <= OSAtlasLlamaSemanticRequest.maximumToolDescriptionBytes,
                  Self.validToolSchema(tool.parameters) else {
                throw OSAtlasLlamaRuntimeError.invalidResponse
            }
        }

        let completionURL = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var urlRequest = URLRequest(url: completionURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            "Bearer \(endpoint.bearerToken)",
            forHTTPHeaderField: "Authorization")
        let body = SemanticRequestBody(
            model: OSAtlasLlamaServedModel.semanticRouter.rawValue,
            messages: semanticRequest.messages,
            tools: semanticRequest.tools.map {
                SemanticTool(function: SemanticFunction(
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.parameters))
            },
            maxTokens: semanticRequest.maxTokens)
        // llama.cpp's OpenAI compatibility layer preserves JSON object order
        // while handing native-tool schemas to the embedded chat template.
        // Sorting every keyed container makes the model-facing prompt stable
        // across Swift, the Windows evaluation harness, and the pinned b9992
        // token preflight instead of depending on Dictionary iteration order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(body)
        guard encoded.count <= 512 * 1_024 else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        urlRequest.httpBody = encoded
        return urlRequest
    }

    /// b9992's `/apply-template` runs the same
    /// `oaicompat_chat_params_parse` path as `/v1/chat/completions`. Reusing
    /// the exact completion body therefore includes tools, required tool
    /// choice, `parallel_tool_calls: false`, and every sampling/request field
    /// in the model's real Granite chat-template render.
    static func makeSemanticTemplateRequest(
        from completionRequest: URLRequest
    ) throws -> URLRequest {
        guard let completionURL = completionRequest.url,
              completionURL.path == "/v1/chat/completions",
              completionURL.scheme?.lowercased() == "http",
              completionURL.host == OSAtlasLlamaLaunchConfiguration.host,
              completionURL.user == nil,
              completionURL.password == nil,
              completionURL.query == nil,
              completionURL.fragment == nil,
              completionURL.port != nil,
              let body = completionRequest.httpBody,
              !body.isEmpty,
              completionRequest.httpMethod == "POST" else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        let baseURL = URL(
            string: "http://\(OSAtlasLlamaLaunchConfiguration.host):\(completionURL.port ?? 80)")!
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        var request = completionRequest
        request.url = baseURL.appendingPathComponent("apply-template")
        request.timeoutInterval = 30
        return request
    }

    static func templatePrompt(from data: Data) throws -> String {
        guard !data.isEmpty,
              data.count <= maximumTemplateResponseBytes,
              let source = String(data: data, encoding: .utf8) else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        var parser = StrictSemanticJSONParser(source)
        guard case .object(let object) = try parser.parse(),
              Set(object.keys) == ["prompt"],
              case .string(let prompt)? = object["prompt"],
              !prompt.isEmpty,
              prompt.utf8.count <= maximumTemplateResponseBytes else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        return prompt
    }

    static func makeTokenizeRequest(
        from completionRequest: URLRequest,
        templatePrompt: String
    ) throws -> URLRequest {
        guard let completionURL = completionRequest.url,
              completionURL.path == "/v1/chat/completions",
              completionURL.scheme?.lowercased() == "http",
              completionURL.host == OSAtlasLlamaLaunchConfiguration.host,
              completionURL.user == nil,
              completionURL.password == nil,
              completionURL.query == nil,
              completionURL.fragment == nil,
              completionURL.port != nil,
              !templatePrompt.isEmpty,
              templatePrompt.utf8.count <= maximumTemplateResponseBytes else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        let baseURL = URL(
            string: "http://\(OSAtlasLlamaLaunchConfiguration.host):\(completionURL.port ?? 80)")!
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        var request = URLRequest(
            url: baseURL.appendingPathComponent("tokenize"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let authorization = completionRequest.value(
            forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ") else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(TokenizeRequestBody(
            content: templatePrompt))
        return request
    }

    static func tokenCount(from data: Data) throws -> Int {
        guard !data.isEmpty,
              data.count <= maximumTokenizeResponseBytes,
              let source = String(data: data, encoding: .utf8) else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        var parser = StrictSemanticJSONParser(
            source,
            maximumValueCount: maximumTokenizedInputTokens + 2)
        guard case .object(let object) = try parser.parse(),
              Set(object.keys) == ["tokens"],
              case .array(let tokens)? = object["tokens"],
              !tokens.isEmpty,
              tokens.count <= maximumTokenizedInputTokens,
              tokens.allSatisfy({ token in
                  if case .integer(let value) = token { return value >= 0 }
                  return false
              }) else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        return tokens.count
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
    private struct LoadModelBody: Encodable {
        let model: String
    }

    private struct LoadModelResponse: Decodable {
        let success: Bool
    }

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

    func modelIsHealthy(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws -> Bool {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        var components = URLComponents(
            url: baseURL.appendingPathComponent("health"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model.rawValue),
            URLQueryItem(name: "autoload", value: "false"),
        ]
        guard let url = components?.url else {
            throw OSAtlasLlamaRuntimeError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func loadModel(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws {
        try await mutateModel(
            action: "load",
            baseURL: baseURL,
            bearerToken: bearerToken,
            model: model)
    }

    func unloadModel(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws {
        try await mutateModel(
            action: "unload",
            baseURL: baseURL,
            bearerToken: bearerToken,
            model: model)
    }

    private func mutateModel(
        action: String,
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws {
        guard action == "load" || action == "unload" else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("models")
                .appendingPathComponent(action))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(bearerToken)",
            forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            LoadModelBody(model: model.rawValue))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 64 * 1_024,
              let result = try? JSONDecoder().decode(
                LoadModelResponse.self,
                from: data),
              result.success else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
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
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 1_024 * 1_024 else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        return data
    }

    func exactInputTokenCount(
        completionRequest: URLRequest
    ) async throws -> Int {
        let templateRequest = try OSAtlasLlamaHTTPClient
            .makeSemanticTemplateRequest(from: completionRequest)
        let (templateData, templateResponse) = try await session.data(
            for: templateRequest)
        guard (templateResponse as? HTTPURLResponse)?.statusCode == 200,
              templateData.count
                <= OSAtlasLlamaHTTPClient.maximumTemplateResponseBytes else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        let prompt = try OSAtlasLlamaHTTPClient.templatePrompt(
            from: templateData)
        let tokenizeRequest = try OSAtlasLlamaHTTPClient.makeTokenizeRequest(
            from: completionRequest,
            templatePrompt: prompt)
        let (tokenData, tokenResponse) = try await session.data(
            for: tokenizeRequest)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
              tokenData.count
                <= OSAtlasLlamaHTTPClient.maximumTokenizeResponseBytes else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        return try OSAtlasLlamaHTTPClient.tokenCount(from: tokenData)
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

/// Cross-process lifetime lease for one exact llama-server path. The lease is
/// acquired before orphan inspection/reaping and remains held until the root
/// and exact-path workers are gone. This closes the check-then-launch race
/// between two host processes without ever killing a peer that still owns the
/// lock.
final class OSAtlasLlamaServerLifetimeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    func release() {
        let descriptor = lock.withLock { () -> Int32? in
            defer { self.descriptor = nil }
            return self.descriptor
        }
        guard let descriptor else { return }
        _ = osAtlasRuntimeFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static func acquire(
        executableURL: URL,
        lockDirectoryURL: URL? = nil,
        retryDelay: Duration = .milliseconds(20)
    ) async throws -> OSAtlasLlamaServerLifetimeLease {
        try Task.checkCancellation()
        let directory = try validatedLockDirectory(
            override: lockDirectoryURL)
        let canonicalPath = executableURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard !canonicalPath.isEmpty else {
            throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
        }
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let lockURL = directory.appendingPathComponent(
            "llama-server-\(digest).lock",
            isDirectory: false)
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        while osAtlasRuntimeFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw OSAtlasLlamaRuntimeError.serverFailedToStart
            }
            try Task.checkCancellation()
            try await Task.sleep(for: retryDelay)
        }
        try Task.checkCancellation()
        shouldClose = false
        return OSAtlasLlamaServerLifetimeLease(descriptor: descriptor)
    }

    private static func validatedLockDirectory(
        override: URL?
    ) throws -> URL {
        let directory: URL
        if let override {
            directory = override.standardizedFileURL
        } else {
            guard let caches = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask).first else {
                throw OSAtlasLlamaRuntimeError.serverFailedToStart
            }
            directory = caches
                .appendingPathComponent(
                    "com.threadmark.remotedesktop.host",
                    isDirectory: true)
                .appendingPathComponent(
                    "LlamaRuntimeLocks",
                    isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var status = stat()
        let result = directory.path.withCString {
            Darwin.lstat($0, &status)
        }
        guard result == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid() else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        let chmodResult = directory.path.withCString {
            Darwin.chmod($0, S_IRWXU)
        }
        guard chmodResult == 0 else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        return directory
    }
}

private struct FoundationOSAtlasLlamaServerLauncher: OSAtlasLlamaServerLaunching {
    private let processInspector = DarwinOSAtlasProcessInspector()
    private let processReaper = OSAtlasExclusiveProcessReaper()

    func launch(
        configuration: OSAtlasLlamaLaunchConfiguration
    ) async throws -> any OSAtlasLlamaServerProcess {
        let lifetimeLease = try await OSAtlasLlamaServerLifetimeLease.acquire(
            executableURL: configuration.executableURL)
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

        if let presetFile = configuration.routerPresetFile {
            do {
                try presetFile.verify()
            } catch {
                throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
            }
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.arguments = configuration.arguments
        if let presetFile = configuration.routerPresetFile {
            let cacheDirectory = presetFile.directoryURL
                .appendingPathComponent("cache", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
            }
        }
        process.environment = configuration.processEnvironment(
            inheriting: ProcessInfo.processInfo.environment)
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
        let rootIdentity: OSAtlasProcessIdentity
        do {
            guard let captured = try processInspector.identity(
                processID: process.processIdentifier),
                  captured.canonicalExecutablePath == configuration.executableURL
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path else {
                throw OSAtlasLlamaRuntimeError.serverFailedToStart
            }
            rootIdentity = captured
        } catch {
            // The lease remains held while the exact-path reaper resolves any
            // launch that exec'd but could not be bound to a kernel identity.
            Self.reapUnboundLaunchInBackground(
                process: process,
                executableURL: configuration.executableURL,
                lifetimeLease: lifetimeLease,
                processReaper: processReaper)
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        return FoundationOSAtlasLlamaServerProcess(
            process: process,
            rootIdentity: rootIdentity,
            executableURL: configuration.executableURL,
            lifetimeLease: lifetimeLease,
            maximumResidentMemoryBytes:
                configuration.resourceProfile.maximumResidentMemoryBytes,
            maximumProcessCount: configuration.maximumProcessCount)
    }

    private static func reapUnboundLaunchInBackground(
        process: Process,
        executableURL: URL,
        lifetimeLease: OSAtlasLlamaServerLifetimeLease,
        processReaper: OSAtlasExclusiveProcessReaper
    ) {
        Task.detached(priority: .utility) {
            while true {
                do {
                    try await processReaper.prepareForExclusiveLaunch(
                        executableURL: executableURL)
                    // If exec/path inspection was merely late, an empty scan
                    // is not proof while Foundation still observes the child.
                    guard !process.isRunning else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    lifetimeLease.release()
                    return
                } catch {
                    // An inspection failure is uncertainty, not permission to
                    // release the cross-process lease. Retry out of band.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
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
        try Task.checkCancellation()
        var remaining = try inspector.matchingProcesses(for: executableURL)
        try Task.checkCancellation()
        guard !remaining.isEmpty else { return }

        for process in remaining {
            try Task.checkCancellation()
            try inspector.send(
                signal: SIGTERM,
                to: process,
                ifExecutableMatches: executableURL)
        }
        remaining = try await waitForExit(
            executableURL: executableURL,
            attempts: gracefulAttempts)
        try Task.checkCancellation()
        guard !remaining.isEmpty else { return }

        for process in remaining {
            try Task.checkCancellation()
            try inspector.send(
                signal: SIGKILL,
                to: process,
                ifExecutableMatches: executableURL)
        }
        remaining = try await waitForExit(
            executableURL: executableURL,
            attempts: forcedAttempts)
        try Task.checkCancellation()
        guard remaining.isEmpty else {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
    }

    private func waitForExit(
        executableURL: URL,
        attempts: Int
    ) async throws -> [OSAtlasProcessIdentity] {
        for attempt in 0 ..< attempts {
            try Task.checkCancellation()
            let remaining = try inspector.matchingProcesses(for: executableURL)
            if remaining.isEmpty { return [] }
            if attempt + 1 < attempts {
                try await Task.sleep(for: retryDelay)
            } else {
                return remaining
            }
        }
        try Task.checkCancellation()
        return try inspector.matchingProcesses(for: executableURL)
    }
}

struct DarwinOSAtlasProcessInspector: OSAtlasProcessInspecting {
    private enum InspectionError: Error {
        case processListUnavailable
        case signalFailed
    }

    func identity(processID: pid_t) throws -> OSAtlasProcessIdentity? {
        guard processID > 0,
              let path = executablePath(processID: processID),
              let information = bsdInformation(processID: processID) else {
            return nil
        }
        return OSAtlasProcessIdentity(
            processIdentifier: processID,
            canonicalExecutablePath: URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path,
            startTimeSeconds: information.pbi_start_tvsec,
            startTimeMicroseconds: information.pbi_start_tvusec,
            effectiveUserIdentifier: information.pbi_uid,
            realUserIdentifier: information.pbi_ruid)
    }

    func matchingProcesses(
        for executableURL: URL
    ) throws -> [OSAtlasProcessIdentity] {
        let expectedPath = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return try allProcessIDs().compactMap { processID in
            guard processID != getpid(),
                  let identity = try identity(processID: processID),
                  identity.canonicalExecutablePath == expectedPath,
                  identity.effectiveUserIdentifier == Darwin.geteuid()
                    else { return nil }
            return identity
        }.sorted {
            $0.processIdentifier < $1.processIdentifier
        }
    }

    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifExecutableMatches executableURL: URL
    ) throws {
        try Task.checkCancellation()
        let expectedPath = executableURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
        // Revalidate the complete incarnation immediately before signaling.
        // Matching the executable path alone is insufficient when a PID is
        // recycled into a newly launched copy of the same executable.
        guard process.canonicalExecutablePath == expectedPath,
              process.effectiveUserIdentifier == Darwin.geteuid(),
              let current = try identity(
                processID: process.processIdentifier),
              current == process else {
            return
        }
        guard Darwin.kill(process.processIdentifier, signalNumber) == 0
                || errno == ESRCH else {
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

    private func bsdInformation(processID: pid_t) -> proc_bsdinfo? {
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let copied = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize))
        }
        guard copied == Int32(expectedSize),
              information.pbi_pid == UInt32(processID) else { return nil }
        return information
    }
}

struct DarwinOSAtlasProcessTreeInspector: OSAtlasProcessTreeInspecting {
    private enum InspectionError: Error {
        case processListUnavailable
        case processInformationUnavailable
        case residentMemoryOverflow
        case signalFailed
    }

    private let processInspector = DarwinOSAtlasProcessInspector()

    func snapshot(
        rootProcess: OSAtlasProcessIdentity
    ) throws -> OSAtlasProcessTreeSnapshot {
        guard let currentRoot = try processInspector.identity(
            processID: rootProcess.processIdentifier),
              currentRoot == rootProcess else {
            throw InspectionError.processInformationUnavailable
        }
        let processIDs = try allProcessIDs()
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(processIDs.count)
        for processID in processIDs {
            if let parent = parentProcessID(processID: processID) {
                parents[processID] = parent
            }
        }
        guard parents[rootProcess.processIdentifier] != nil else {
            throw InspectionError.processInformationUnavailable
        }

        var members: [(processID: pid_t, depth: Int)] = [
            (rootProcess.processIdentifier, 0),
        ]
        for processID in processIDs
            where processID != rootProcess.processIdentifier {
            if let depth = depth(
                of: processID,
                below: rootProcess.processIdentifier,
                parents: parents) {
                members.append((processID, depth))
            }
        }
        members.sort {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.processID < $1.processID
        }

        var identities: [OSAtlasProcessIdentity] = []
        identities.reserveCapacity(members.count)
        var aggregate: UInt64 = 0
        for member in members {
            guard let identity = try processInspector.identity(
                processID: member.processID),
                  identity.effectiveUserIdentifier
                    == rootProcess.effectiveUserIdentifier else {
                throw InspectionError.processInformationUnavailable
            }
            guard let bytes = OSAtlasProcessMemoryGuard.residentBytes(
                processID: member.processID) else {
                throw InspectionError.processInformationUnavailable
            }
            let sum = aggregate.addingReportingOverflow(bytes)
            guard !sum.overflow else {
                throw InspectionError.residentMemoryOverflow
            }
            aggregate = sum.partialValue
            identities.append(identity)
        }
        return OSAtlasProcessTreeSnapshot(
            processIdentitiesChildFirst: identities,
            aggregateResidentMemoryBytes: aggregate)
    }

    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifMemberOfTreeRoot rootProcess: OSAtlasProcessIdentity
    ) throws {
        try Task.checkCancellation()
        // Rebuild the tree and compare complete process incarnations
        // immediately before signaling. This closes both reparenting and
        // same-executable PID-reuse windows.
        guard let snapshot = try? snapshot(rootProcess: rootProcess),
              snapshot.processIdentitiesChildFirst.contains(process),
              let current = try processInspector.identity(
                processID: process.processIdentifier),
              current == process else {
            return
        }
        guard Darwin.kill(process.processIdentifier, signalNumber) == 0
                || errno == ESRCH else {
            throw InspectionError.signalFailed
        }
    }

    private func depth(
        of processID: pid_t,
        below rootProcessID: pid_t,
        parents: [pid_t: pid_t]
    ) -> Int? {
        var current = processID
        var visited: Set<pid_t> = []
        var depth = 0
        while let parent = parents[current], parent > 0 {
            guard visited.insert(current).inserted else { return nil }
            depth += 1
            if parent == rootProcessID { return depth }
            current = parent
        }
        return nil
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

    private func parentProcessID(processID: pid_t) -> pid_t? {
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let copied = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize))
        }
        guard copied == Int32(expectedSize) else { return nil }
        return pid_t(information.pbi_ppid)
    }
}

private final class OSAtlasProcessCleanupState: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func recordFailure() {
        lock.withLock { failed = true }
    }

    func clearFailure() {
        lock.withLock { failed = false }
    }

    func hasFailed() -> Bool {
        lock.withLock { failed }
    }
}

/// Fail-closed cleanup used by the detached memory/process-count monitor. A
/// tree snapshot can become uninspectable between enumeration and signaling;
/// killing only the root in that case can orphan a router worker. Always
/// follow the root kill with exact-executable reaping, whose failure remains
/// observable to the owning runtime via `waitUntilExit`.
struct OSAtlasEmergencyProcessReaper: Sendable {
    private let processTreeController: OSAtlasProcessTreeController
    private let processReaper: OSAtlasExclusiveProcessReaper
    private let rootKiller: @Sendable (
        OSAtlasProcessIdentity,
        Int32
    ) throws -> Void

    init(
        processTreeController: OSAtlasProcessTreeController,
        processReaper: OSAtlasExclusiveProcessReaper,
        rootKiller: @escaping @Sendable (
            OSAtlasProcessIdentity,
            Int32
        ) throws -> Void = { process, signal in
            try DarwinOSAtlasProcessInspector().send(
                signal: signal,
                to: process,
                ifExecutableMatches: URL(
                    fileURLWithPath: process.canonicalExecutablePath))
        }
    ) {
        self.processTreeController = processTreeController
        self.processReaper = processReaper
        self.rootKiller = rootKiller
    }

    func killAndReap(
        rootProcess: OSAtlasProcessIdentity,
        executableURL: URL
    ) async throws {
        try Task.checkCancellation()
        do {
            try processTreeController.signalTree(
                rootProcess: rootProcess,
                signal: SIGKILL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The exact-executable reaper below is the child fallback. Root
            // termination is still attempted even when tree inspection fails.
        }
        try Task.checkCancellation()
        try rootKiller(rootProcess, SIGKILL)
        try Task.checkCancellation()
        try await processReaper.prepareForExclusiveLaunch(
            executableURL: executableURL)
    }
}

final class FoundationOSAtlasLlamaServerProcess: OSAtlasLlamaServerProcess,
    @unchecked Sendable {
    private let process: Process
    private let rootIdentity: OSAtlasProcessIdentity
    private let executableURL: URL
    private let processTreeController: OSAtlasProcessTreeController
    private let processReaper: OSAtlasExclusiveProcessReaper
    private let processInspector: any OSAtlasProcessInspecting
    private let cleanupState = OSAtlasProcessCleanupState()
    private let lock = NSLock()
    private var lifetimeLease: OSAtlasLlamaServerLifetimeLease?
    private var memoryMonitor: Task<Void, Never>?
    private var terminationRequested = false

    init(
        process: Process,
        rootIdentity: OSAtlasProcessIdentity,
        executableURL: URL,
        lifetimeLease: OSAtlasLlamaServerLifetimeLease,
        maximumResidentMemoryBytes: UInt64,
        maximumProcessCount: Int,
        processTreeController: OSAtlasProcessTreeController =
            OSAtlasProcessTreeController(),
        processReaper: OSAtlasExclusiveProcessReaper =
            OSAtlasExclusiveProcessReaper(),
        processInspector: any OSAtlasProcessInspecting =
            DarwinOSAtlasProcessInspector(),
        memoryMonitorOverride: Task<Void, Never>? = nil
    ) {
        self.process = process
        self.rootIdentity = rootIdentity
        self.executableURL = executableURL
        self.lifetimeLease = lifetimeLease
        self.processTreeController = processTreeController
        self.processReaper = processReaper
        self.processInspector = processInspector
        let emergencyReaper = OSAtlasEmergencyProcessReaper(
            processTreeController: processTreeController,
            processReaper: processReaper)
        if let memoryMonitorOverride {
            memoryMonitor = memoryMonitorOverride
        } else {
            memoryMonitor = Task.detached(priority: .utility) {
            [weak process, processTreeController, emergencyReaper,
             executableURL, cleanupState] in
            while !Task.isCancelled {
                guard let process, process.isRunning else { return }
                let snapshot: OSAtlasProcessTreeSnapshot
                do {
                    snapshot = try processTreeController.snapshot(
                        rootProcess: rootIdentity)
                } catch {
                    // An uninspectable live process tree cannot be proven to
                    // obey the resource or worker bound. Kill the root now;
                    // waitUntilExit performs exact-executable orphan cleanup.
                    do {
                        try await emergencyReaper.killAndReap(
                            rootProcess: rootIdentity,
                            executableURL: executableURL)
                        cleanupState.clearFailure()
                    } catch is CancellationError {
                        return
                    } catch {
                        cleanupState.recordFailure()
                    }
                    return
                }
                if snapshot.exceeds(
                    maximumResidentMemoryBytes: maximumResidentMemoryBytes,
                    maximumProcessCount: maximumProcessCount) {
                    // This is the last safety boundary if a future mtmd
                    // regression ignores the image/batch limits or the router
                    // exceeds this profile's permitted model-worker count.
                    do {
                        try await emergencyReaper.killAndReap(
                            rootProcess: rootIdentity,
                            executableURL: executableURL)
                        cleanupState.clearFailure()
                    } catch is CancellationError {
                        return
                    } catch {
                        cleanupState.recordFailure()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            }
        }
    }

    deinit {
        let monitor = cancelMemoryMonitor()
        if let lifetimeLease = takeLifetimeLease() {
            Self.reapInBackground(
                lifetimeLease: lifetimeLease,
                memoryMonitor: monitor,
                rootIdentity: rootIdentity,
                executableURL: executableURL,
                processTreeController: processTreeController,
                processReaper: processReaper)
        }
    }

    func terminate() async {
        await quiesceMemoryMonitor()
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !terminationRequested else { return false }
            terminationRequested = true
            return process.isRunning
        }
        if shouldTerminate {
            do {
                try processTreeController.signalTree(
                    rootProcess: rootIdentity,
                    signal: SIGTERM)
            } catch is CancellationError {
                return
            } catch {
                // Never fall back to Process.terminate()/a raw PID. Revalidate
                // the exact kernel incarnation immediately before signaling.
                do {
                    try Task.checkCancellation()
                    try processInspector.send(
                        signal: SIGTERM,
                        to: rootIdentity,
                        ifExecutableMatches: executableURL)
                } catch {
                    // `waitUntilExit` owns bounded forced cleanup and retains
                    // the lifetime lease if this graceful signal is uncertain.
                }
            }
        }
    }

    func waitUntilExit() async throws {
        // The monitor can itself be inside emergency cleanup. Cancellation
        // checks make it unwind before another signal boundary; joining here
        // proves it can never outlive release of the same-path lifetime lease.
        await quiesceMemoryMonitor()
        do {
            // Process.waitUntilExit has no deadline and can pin the runtime
            // actor forever. Poll Foundation's nonblocking state for a fixed
            // grace period, then use identity-bound forced cleanup.
            let exitedGracefully = try await waitForRootExit(
                attempts: 60,
                retryDelay: .milliseconds(50))
            if !exitedGracefully {
                try await OSAtlasEmergencyProcessReaper(
                    processTreeController: processTreeController,
                    processReaper: processReaper)
                    .killAndReap(
                        rootProcess: rootIdentity,
                        executableURL: executableURL)
                guard try await waitForRootExit(
                    attempts: 40,
                    retryDelay: .milliseconds(50)) else {
                    throw OSAtlasLlamaRuntimeError.serverFailedToStart
                }
            }
            // Router workers are separate processes and can outlive a crashed
            // root. Reclaim the exact executable while the cross-process lease
            // remains held, then release the lease only after absence is
            // proven.
            try await processReaper.prepareForExclusiveLaunch(
                executableURL: executableURL)
            cleanupState.clearFailure()
            releaseLifetimeLease()
        } catch {
            cleanupState.recordFailure()
            transferLifetimeLeaseToBackgroundReaper()
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
    }

    private func waitForRootExit(
        attempts: Int,
        retryDelay: Duration
    ) async throws -> Bool {
        for attempt in 0 ..< max(1, attempts) {
            try Task.checkCancellation()
            if !process.isRunning { return true }
            if attempt + 1 < attempts {
                try await Task.sleep(for: retryDelay)
            }
        }
        return !process.isRunning
    }

    private func releaseLifetimeLease() {
        takeLifetimeLease()?.release()
    }

    private func cancelMemoryMonitor() -> Task<Void, Never>? {
        lock.withLock {
            memoryMonitor?.cancel()
            return memoryMonitor
        }
    }

    private func quiesceMemoryMonitor() async {
        if let monitor = cancelMemoryMonitor() {
            await monitor.value
        }
    }

    private func takeLifetimeLease() -> OSAtlasLlamaServerLifetimeLease? {
        lock.withLock {
            defer { lifetimeLease = nil }
            return lifetimeLease
        }
    }

    private func transferLifetimeLeaseToBackgroundReaper() {
        guard let lifetimeLease = takeLifetimeLease() else { return }
        Self.reapInBackground(
            lifetimeLease: lifetimeLease,
            memoryMonitor: cancelMemoryMonitor(),
            rootIdentity: rootIdentity,
            executableURL: executableURL,
            processTreeController: processTreeController,
            processReaper: processReaper)
    }

    private static func reapInBackground(
        lifetimeLease: OSAtlasLlamaServerLifetimeLease,
        memoryMonitor: Task<Void, Never>?,
        rootIdentity: OSAtlasProcessIdentity,
        executableURL: URL,
        processTreeController: OSAtlasProcessTreeController,
        processReaper: OSAtlasExclusiveProcessReaper
    ) {
        Task.detached(priority: .utility) {
            memoryMonitor?.cancel()
            await memoryMonitor?.value
            let emergencyReaper = OSAtlasEmergencyProcessReaper(
                processTreeController: processTreeController,
                processReaper: processReaper)
            while true {
                try? await emergencyReaper.killAndReap(
                    rootProcess: rootIdentity,
                    executableURL: executableURL)
                do {
                    try await processReaper.prepareForExclusiveLaunch(
                        executableURL: executableURL)
                    lifetimeLease.release()
                    return
                } catch {
                    // A failed inspection cannot prove cleanup. Retain the
                    // lease and retry out of band so the actor is never
                    // blocked and a peer cannot check-then-launch.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
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
