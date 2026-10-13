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

        init(maxSteps: Int = 40, initialSurface: InitialSurface? = nil,
             fileRoots: [URL]? = nil, storageDirectory: URL? = nil,
             policy: AgentPolicyModel = .fara15_4b) {
            self.maxSteps = maxSteps
            self.policy = policy
            self.initialSurface = initialSurface
            self.fileRoots = fileRoots
            self.storageDirectory = storageDirectory
        }
    }

    static func make(receipt: ComputerUseInstallationReceipt, injector: InputInjector,
                     mayAct: @escaping () -> Bool, bundle: Bundle = .main,
                     configuration: Configuration = .init()) throws -> ComputerUseCapabilityExecutor {
        guard (1...40).contains(configuration.maxSteps) else {
            throw ConfigurationError.invalidMaxSteps
        }
        let directory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: bundle)
        let faraInputs: ComputerUseFaraRuntimeInputs?
        if configuration.policy == .fara15_4b {
            faraInputs = try OSAtlasRuntimeInputResolver().resolveFara(receipt: receipt,
                runtimeDirectoryURL: directory, enclosingBundleURL: bundle.bundleURL)
        } else { faraInputs = nil }
        let runtimeInputs = try AgentVisionRuntimeInputs.resolve(model: configuration.policy,
            faraInputs: faraInputs,
            modelRootURL: HostComputerUseManager.modelDirectoryURL.appendingPathComponent("Models", isDirectory: true),
            runtimeDirectoryURL: directory, enclosingBundleURL: bundle.bundleURL)
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
        let trustDirectory = configuration.storageDirectory?.appendingPathComponent("AgentTrust", isDirectory: true)
            ?? support.appendingPathComponent("AgentTrust", isDirectory: true)
        let trust = try PersistentAgentTrustStore(directory: trustDirectory)
        let taskExecutor = AgentTaskExecutor { taskID, prompt in
            let pixelMetadata = configuration.storageDirectory?.appendingPathComponent("pixel-metadata.json")
            let files = AgentFileCatalog(authorizedRoots: configuration.fileRoots)
            let picker = AgentNativeFilePicker(catalog: files, injector: injector, mayAct: mayAct)
            let finder: AgentWebFileFinder = { query, kind, after in
                try await files.find(query: query, kind: kind, modifiedAfter: after)
            }
            let pixel: PixelEnvironment
            switch configuration.initialSurface {
            case .web(let url):
                pixel = PixelEnvironment(taskID: taskID, injector: injector, registry: registry,
                    allowed: mayAct, finder: finder, picker: { try await picker.select($0) }, startURL: url,
                    capturePreference: configuration.policy.capturePreference, metadataURL: pixelMetadata)
            case .app(let name):
                try await registry.open(registry.resolve(name))
                pixel = PixelEnvironment(taskID: taskID, injector: injector, registry: registry,
                    allowed: mayAct, finder: finder, picker: { try await picker.select($0) },
                    capturePreference: configuration.policy.capturePreference, metadataURL: pixelMetadata)
            case nil:
                pixel = PixelEnvironment(taskID: taskID, injector: injector, registry: registry,
                    allowed: mayAct, finder: finder, picker: { try await picker.select($0) },
                    capturePreference: configuration.policy.capturePreference, metadataURL: pixelMetadata)
            }
            let recordingRoot = configuration.storageDirectory?.appendingPathComponent("episodes", isDirectory: true)
                ?? TrajectoryRecorder.defaultRoot
            let recorder = try TrajectoryRecorder(root: recordingRoot, episodeID: taskID)
            let journal = try AgentJournal(taskID: taskID, prompt: prompt,
                directory: configuration.storageDirectory?.appendingPathComponent("AgentEffects", isDirectory: true)
                    ?? support.appendingPathComponent("AgentEffects", isDirectory: true))
            return try AgentLoop(taskID: taskID, prompt: prompt, maxSteps: configuration.maxSteps,
                environment: pixel,
                policy: LlamaVLMPolicy(runtimeInputs: runtimeInputs, bundle: bundle),
                gate: AgentActionGate(trustStore: trust, allowPolicy: HostAgentAllowPolicy(registry: registry)),
                recorder: recorder, journal: journal)
        }
        return ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: taskExecutor))
    }
}
