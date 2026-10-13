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
        let initialSurface: InitialSurface?
        let fileRoots: [URL]?
        let storageDirectory: URL?

        init(maxSteps: Int = 40, initialSurface: InitialSurface? = nil,
             fileRoots: [URL]? = nil, storageDirectory: URL? = nil) {
            self.maxSteps = maxSteps
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
        let package = try OSAtlasRuntimeInputResolver().resolveAvailablePackage(receipt: receipt,
            runtimeDirectoryURL: directory, enclosingBundleURL: bundle.bundleURL)
        guard case let .fara(inputs) = package else { throw OSAtlasLlamaRuntimeError.invalidLocalInstallation }
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
            let files = AgentFileCatalog(authorizedRoots: configuration.fileRoots)
            let picker = AgentNativeFilePicker(catalog: files, injector: injector, mayAct: mayAct)
            let finder: AgentWebFileFinder = { query, kind, after in
                try await files.find(query: query, kind: kind, modifiedAfter: after)
            }
            let makeMac: AgentEnvironments.MacFactory = {
                MacEnvironment(taskID: taskID, backend: AgentNativeBackend(injector: injector, registry: registry,
                    allowed: mayAct, finder: finder, picker: { try await picker.select($0) }))
            }
            let makeWeb: AgentEnvironments.WebFactory = { url in
                WebEnvironment(taskID: taskID, task: prompt, startURL: url, finder: finder,
                    fileResolver: { try await files.resolve($0) }, mayAct: mayAct)
            }
            let start: any AgentEnvironment
            switch configuration.initialSurface {
            case .web(let url): start = try makeWeb(url)
            case .app(let name):
                try await registry.open(registry.resolve(name))
                start = try makeMac()
            case nil: start = try makeMac()
            }
            let environments = AgentEnvironments(start: start, makeWeb: makeWeb,
                makeMac: makeMac, openApp: { name in
                try await registry.open(registry.resolve(name))
            })
            let recordingRoot = configuration.storageDirectory?.appendingPathComponent("episodes", isDirectory: true)
                ?? TrajectoryRecorder.defaultRoot
            let recorder = try TrajectoryRecorder(root: recordingRoot, episodeID: taskID)
            let journal = try AgentJournal(taskID: taskID, prompt: prompt,
                directory: configuration.storageDirectory?.appendingPathComponent("AgentEffects", isDirectory: true)
                    ?? support.appendingPathComponent("AgentEffects", isDirectory: true))
            return try AgentLoop(taskID: taskID, prompt: prompt, maxSteps: configuration.maxSteps,
                environment: environments,
                policy: LlamaVLMPolicy(runtimeInputs: inputs, bundle: bundle),
                gate: AgentActionGate(trustStore: trust, allowPolicy: HostAgentAllowPolicy(registry: registry)),
                recorder: recorder, journal: journal)
        }
        return ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: taskExecutor))
    }
}
