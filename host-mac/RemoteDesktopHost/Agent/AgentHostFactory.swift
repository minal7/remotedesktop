import AppKit
import Foundation

@MainActor
enum AgentHostFactory {
    static func make(receipt: ComputerUseInstallationReceipt, injector: InputInjector,
                     mayAct: @escaping () -> Bool, bundle: Bundle = .main) throws -> ComputerUseCapabilityExecutor {
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
        let trust = try PersistentAgentTrustStore(directory: support.appendingPathComponent("AgentTrust", isDirectory: true))
        let taskExecutor = AgentTaskExecutor { taskID, prompt in
            let files = AgentFileCatalog()
            let picker = AgentNativeFilePicker(catalog: files, injector: injector, mayAct: mayAct)
            let finder: AgentWebFileFinder = { query, kind, after in
                try await files.find(query: query, kind: kind, modifiedAfter: after)
            }
            let makeMac: AgentEnvironments.MacFactory = {
                MacEnvironment(taskID: taskID, backend: AgentNativeBackend(injector: injector, registry: registry,
                    allowed: mayAct, finder: finder, picker: { try await picker.select($0) }))
            }
            let environments = AgentEnvironments(start: try makeMac(), makeWeb: { url in
                WebEnvironment(taskID: taskID, task: prompt, startURL: url, finder: finder,
                    fileResolver: { try await files.resolve($0) }, mayAct: mayAct)
            }, makeMac: makeMac, openApp: { name in
                try await registry.open(registry.resolve(name))
            })
            let recorder = try TrajectoryRecorder(episodeID: taskID)
            let journal = try AgentJournal(taskID: taskID, prompt: prompt,
                directory: support.appendingPathComponent("AgentEffects", isDirectory: true))
            return try AgentLoop(taskID: taskID, prompt: prompt, environment: environments,
                policy: LlamaVLMPolicy(runtimeInputs: inputs, bundle: bundle),
                gate: AgentActionGate(trustStore: trust, allowPolicy: HostAgentAllowPolicy(registry: registry)),
                recorder: recorder, journal: journal)
        }
        return ComputerUseCapabilityExecutor(agentAdapter: AgentCapabilityAdapter(executor: taskExecutor))
    }
}
