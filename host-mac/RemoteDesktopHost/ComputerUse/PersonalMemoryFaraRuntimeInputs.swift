import AppKit
import Foundation

/// Resolves the same immutable Fara installation used by the normal agent factory.
/// The task-memory runtime reads this value only after that factory has validated
/// the installation receipt; it never selects model paths independently.
final class PersonalMemoryFaraRuntimeInputsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: AgentVisionRuntimeInputs?

    @MainActor
    func resolve(receipt: ComputerUseInstallationReceipt, model: AgentPolicyModel,
                 bundle: Bundle) throws -> AgentVisionRuntimeInputs {
        clear()
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: bundle)
        let faraInputs: ComputerUseFaraRuntimeInputs?
        if model == .fara15_4b {
            faraInputs = try OSAtlasRuntimeInputResolver().resolveFara(
                receipt: receipt, runtimeDirectoryURL: runtimeDirectory,
                enclosingBundleURL: bundle.bundleURL)
        } else {
            faraInputs = nil
        }
        let inputs = try AgentVisionRuntimeInputs.resolve(model: model, faraInputs: faraInputs,
            modelRootURL: HostComputerUseManager.modelDirectoryURL.appendingPathComponent("Models", isDirectory: true),
            runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: bundle.bundleURL)
        lock.lock()
        resolved = model == .fara15_4b ? inputs : nil
        lock.unlock()
        return inputs
    }

    func faraInputs() -> AgentVisionRuntimeInputs? {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    func clear() {
        lock.lock(); resolved = nil; lock.unlock()
    }
}
