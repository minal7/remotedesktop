import AppKit
import Foundation

@MainActor
enum AgentHostFactory {
    enum ConfigurationError: Error {
        case invalidMaxSteps
    }

    enum InitialSurface: Equatable {
        case web(String)
        case app(String)
    }

    struct Configuration: Equatable {
        let maxSteps: Int
        let policy: AgentPolicyModel
        let initialSurface: InitialSurface?
        let fileRoots: [URL]?
        let storageDirectory: URL?
        let requireCleanStart: Bool

        init(maxSteps: Int = 30, initialSurface: InitialSurface? = nil,
             fileRoots: [URL]? = nil, storageDirectory: URL? = nil,
             requireCleanStart: Bool = false,
             policy: AgentPolicyModel = .fara15_4b) {
            self.maxSteps = maxSteps
            self.policy = policy
            self.initialSurface = initialSurface
            self.fileRoots = fileRoots
            self.storageDirectory = storageDirectory
            self.requireCleanStart = requireCleanStart
        }
    }

    static func make(receipt: ComputerUseInstallationReceipt, injector: InputInjector,
                     mayAct: @escaping () -> Bool, bundle: Bundle = .main,
                     configuration: Configuration = .init(),
                     taskMemoryContextSlot: TaskMemoryContextSlot? = nil,
                     taskMemoryFaraRuntimeInputs: PersonalMemoryFaraRuntimeInputsCache? = nil,
                     runtime: OSAtlasLlamaRuntime = .shared) throws -> ComputerUseCapabilityExecutor {
        guard (1...40).contains(configuration.maxSteps) else {
            throw ConfigurationError.invalidMaxSteps
        }
        let inputsCache = taskMemoryFaraRuntimeInputs ?? PersonalMemoryFaraRuntimeInputsCache()
        let runtimeInputs = try inputsCache.resolve(receipt: receipt, model: configuration.policy,
            bundle: bundle)
        let registry = AgentAppRegistry(openHandler: { url in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try injector.performHostEffectIfAllowed(ifAllowed: mayAct) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        })
        let support = TrajectoryRecorder.defaultRoot.deletingLastPathComponent()
        let trust = try persistentTrustStore()
        let taskExecutor = AgentTaskExecutor { taskID, prompt in
            let pixelMetadata = configuration.storageDirectory?.appendingPathComponent("pixel-metadata.json")
            let files = AgentFileCatalog(authorizedRoots: configuration.fileRoots)
            let picker = AgentNativeFilePicker(catalog: files, injector: injector, mayAct: mayAct)
            let finder: AgentWebFileFinder = { query, kind, after in
                try await files.find(query: query, kind: kind, modifiedAfter: after)
            }
            let startURL: String?, startApp: String?
            switch configuration.initialSurface {
            case .web(let url): (startURL, startApp) = (url, nil)
            case .app(let name): (startURL, startApp) = (nil, name)
            case nil: (startURL, startApp) = (nil, nil)
            }
            let pixel = PixelEnvironment(taskID: taskID, injector: injector, registry: registry,
                allowed: mayAct, finder: finder, picker: { try await picker.select($0) },
                startURL: startURL, startApp: startApp,
                capturePreference: configuration.policy.capturePreference, metadataURL: pixelMetadata,
                requireCleanStart: configuration.requireCleanStart)
            let recordingRoot = configuration.storageDirectory?.appendingPathComponent("episodes", isDirectory: true)
                ?? TrajectoryRecorder.defaultRoot
            let recorder = try TrajectoryRecorder(root: recordingRoot, episodeID: taskID)
            let journal = try AgentJournal(taskID: taskID, prompt: prompt,
                directory: configuration.storageDirectory?.appendingPathComponent("AgentEffects", isDirectory: true)
                    ?? support.appendingPathComponent("AgentEffects", isDirectory: true))
            let basePolicy = try LlamaVLMPolicy(runtimeInputs: runtimeInputs, runtime: runtime, bundle: bundle)
            let memoryDisclosureAuthority = taskMemoryContextSlot.map {
                AgentMemoryDisclosureAuthority(taskID: taskID, slot: $0)
            }
            let policy = TaskMemoryContextPolicy.applying(
                taskID: taskID, slot: taskMemoryContextSlot, base: basePolicy,
                memoryDisclosureAuthority: memoryDisclosureAuthority)
            return try AgentLoop(taskID: taskID, prompt: prompt, maxSteps: configuration.maxSteps,
                environment: pixel,
                policy: policy,
                gate: AgentActionGate(trustStore: trust, allowPolicy: HostAgentAllowPolicy(registry: registry),
                    memoryDisclosureAuthority: memoryDisclosureAuthority),
                recorder: recorder, journal: journal)
        }
        return ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: taskExecutor))
    }

    static func persistentTrustStore() throws -> PersistentAgentTrustStore {
        try persistentTrustStore(directory: persistentTrustDirectory())
    }

    static func persistentTrustStore(directory: URL) throws -> PersistentAgentTrustStore {
        try PersistentAgentTrustStore(directory: directory)
    }

    static func persistentTrustDirectory() -> URL {
        TrajectoryRecorder.defaultRoot.deletingLastPathComponent().appendingPathComponent("AgentTrust", isDirectory: true)
    }
}
