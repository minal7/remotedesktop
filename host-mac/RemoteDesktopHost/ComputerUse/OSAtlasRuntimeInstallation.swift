import Foundation
import CryptoKit

enum OSAtlasRuntimeInstallationError: Error, LocalizedError, Equatable {
    case invalidReceipt
    case missingModelArtifact(String)
    case invalidModelArtifact(String)
    case bundledRuntimeMissing
    case bundledRuntimeIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .invalidReceipt:
            return "The AI model installation receipt is invalid. Choose Retry to repair it."
        case .missingModelArtifact(let fileName):
            return "The installed AI model is missing \(fileName). Choose Retry to repair it."
        case .invalidModelArtifact(let fileName):
            return "The installed AI model could not be verified (\(fileName)). Choose Retry to repair it."
        case .bundledRuntimeMissing:
            return "This copy of Remote Desktop Host is missing its signed local AI runtime. Reinstall or update the host app."
        case .bundledRuntimeIncomplete(let fileName):
            return "The signed local AI runtime is incomplete (\(fileName)). Reinstall or update the host app."
        }
    }
}

/// The verified receipt selects the trained browser model or a supported
/// legacy package. Each model family resolves through its own exact shape.
enum OSAtlasResolvedRuntimePackage: Equatable, Sendable {
    case fara(ComputerUseFaraRuntimeInputs)
    case holo(ComputerUseHoloRuntimeInputs)
}

/// Converts a verified, data-only model receipt into the exact local inputs
/// accepted by OSAtlasLlamaRuntime. The model may live in Application Support,
/// but executable code must resolve inside the signed host application bundle.
struct OSAtlasRuntimeInputResolver {
    static let requiredBundledRuntimeFiles = [
        "runtime-manifest.json",
        "llama-server",
        "libllama-server-impl.dylib",
        "libllama-common.0.0.9992.dylib",
        "libllama-common.0.dylib",
        "libmtmd.0.0.9992.dylib",
        "libmtmd.0.dylib",
        "libllama.0.0.9992.dylib",
        "libllama.0.dylib",
        "libggml.0.16.0.dylib",
        "libggml.0.dylib",
        "libggml-cpu.0.16.0.dylib",
        "libggml-cpu.0.dylib",
        "libggml-blas.0.16.0.dylib",
        "libggml-blas.0.dylib",
        "libggml-metal.0.16.0.dylib",
        "libggml-metal.0.dylib",
        "libggml-rpc.0.16.0.dylib",
        "libggml-rpc.0.dylib",
        "libggml-base.0.16.0.dylib",
        "libggml-base.0.dylib",
    ]

    let manifest: ComputerUseArtifactManifest
    private let fileManager: FileManager

    init(
        manifest: ComputerUseArtifactManifest = .current,
        fileManager: FileManager = .default
    ) {
        self.manifest = manifest
        self.fileManager = fileManager
    }

    /// Resolves only browser-trained packages that remain in the shipped
    /// visual route. Legacy OS-Atlas visual receipts are rejected before any
    /// model activation can occur.
    func resolveAvailablePackage(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> OSAtlasResolvedRuntimePackage {
        if manifest.modelVariant == .fara15_4B {
            return .fara(try resolveFara(receipt: receipt, runtimeDirectoryURL: runtimeDirectoryURL,
                enclosingBundleURL: enclosingBundleURL))
        }
#if DEBUG
        if manifest.modelVariant == .holo31_4B {
            return .holo(try resolveHolo(receipt: receipt, runtimeDirectoryURL: runtimeDirectoryURL,
                enclosingBundleURL: enclosingBundleURL))
        }
#endif
        throw OSAtlasRuntimeInstallationError.invalidReceipt
    }

    /// The receipt must already have passed installer checksum verification.
    /// This stage checks current shape/containment and resolves executable code
    /// only from the enclosing app bundle, independently of visual artifacts.
    func resolveNativeText(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> ComputerUseNativeTextRuntimeInputs {
#if DEBUG
        guard manifest.modelVariant == .nativeText4B,
              receipt.modelVariant == .nativeText4B,
              receipt.installationVersion == manifest.installationVersion,
              (receipt.modelDirectory as NSString).isAbsolutePath,
              manifest.modelArtifacts.count == 1,
              let artifact = manifest.modelArtifacts.first,
              artifact.kind == .nativeTextPlannerModel,
              artifact.fileName == "Qwen3.5-4B-Q4_K_M.gguf" else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        let directory = URL(fileURLWithPath: receipt.modelDirectory, isDirectory: true).standardizedFileURL
        guard isStrictDirectory(directory) else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        let model = directory.appendingPathComponent(artifact.fileName)
        guard contains(directory, model),
              let values = try? model.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == artifact.byteCount else {
            throw OSAtlasRuntimeInstallationError.invalidModelArtifact(artifact.fileName)
        }
        return ComputerUseNativeTextRuntimeInputs(modelURL: model, llamaServerURL:
            try resolveBundledExecutable(runtimeDirectoryURL: runtimeDirectoryURL, enclosingBundleURL: enclosingBundleURL))

#else
        throw OSAtlasRuntimeInstallationError.invalidReceipt
#endif
    }

    /// Installer verification supplies the content hashes. Activation rechecks
    /// the exact two-file shape, receipt identity and current file containment.
    func resolveFara(receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL, enclosingBundleURL: URL) throws -> ComputerUseFaraRuntimeInputs {
        let directory = try resolveTrainedVisionDirectory(receipt: receipt, variant: .fara15_4B,
            modelFileName: ComputerUseFaraRuntimeInputs.modelFileName, projectorFileName: ComputerUseFaraRuntimeInputs.projectorFileName)
        return ComputerUseFaraRuntimeInputs(modelURL: directory.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName),
            projectorURL: directory.appendingPathComponent(ComputerUseFaraRuntimeInputs.projectorFileName),
            llamaServerURL: try resolveBundledExecutable(runtimeDirectoryURL: runtimeDirectoryURL, enclosingBundleURL: enclosingBundleURL))
    }

    func resolveHolo(receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL, enclosingBundleURL: URL) throws -> ComputerUseHoloRuntimeInputs {
#if DEBUG
        let directory = try resolveTrainedVisionDirectory(receipt: receipt, variant: .holo31_4B,
            modelFileName: ComputerUseHoloRuntimeInputs.modelFileName, projectorFileName: ComputerUseHoloRuntimeInputs.projectorFileName)
        return ComputerUseHoloRuntimeInputs(modelURL: directory.appendingPathComponent(ComputerUseHoloRuntimeInputs.modelFileName),
            projectorURL: directory.appendingPathComponent(ComputerUseHoloRuntimeInputs.projectorFileName),
            llamaServerURL: try resolveBundledExecutable(runtimeDirectoryURL: runtimeDirectoryURL, enclosingBundleURL: enclosingBundleURL))

#else
        throw OSAtlasRuntimeInstallationError.invalidReceipt
#endif
    }

    /// Resolves the separately pinned UI-TARS package without consulting or
    /// mutating the active Fara installation receipt.
    func resolveUITARS15(modelRootURL: URL, runtimeDirectoryURL: URL,
                         enclosingBundleURL: URL) throws -> AgentVisionRuntimeInputs {
#if DEBUG
        try resolveAgentVisionPackage(manifest: .uiTars15, model: .uiTars15_7b,
            modelRootURL: modelRootURL, runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: enclosingBundleURL)

#else
        throw OSAtlasRuntimeInstallationError.invalidReceipt
#endif
    }

    func resolveGUIOwl15(modelRootURL: URL, runtimeDirectoryURL: URL,
                         enclosingBundleURL: URL) throws -> AgentVisionRuntimeInputs {
#if DEBUG
        try resolveAgentVisionPackage(manifest: .guiOwl15, model: .guiOwl15_4b,
            modelRootURL: modelRootURL, runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: enclosingBundleURL)

#else
        throw OSAtlasRuntimeInstallationError.invalidReceipt
#endif
    }

    func resolveAgentVisionPackage(manifest: ComputerUseArtifactManifest, model: AgentPolicyModel,
        modelRootURL: URL, runtimeDirectoryURL: URL, enclosingBundleURL: URL) throws -> AgentVisionRuntimeInputs {
#if DEBUG
        let expectedVariant: ComputerUseArtifactManifest.ModelVariant
        switch model {
        case .uiTars15_7b: expectedVariant = .uiTars15_7B
        case .guiOwl15_4b: expectedVariant = .guiOwl15_4B
        case .fara15_4b: throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        let directory = modelRootURL.appendingPathComponent(manifest.installationVersion, isDirectory: true).standardizedFileURL
        guard manifest.modelVariant == expectedVariant,
              manifest.modelArtifacts.count == 2,
              manifest.modelArtifacts.filter({ $0.kind == .textModelShard }).count == 1,
              manifest.modelArtifacts.filter({ $0.kind == .visionProjector }).count == 1,
              Set(manifest.modelArtifacts.map(\.fileName)).count == 2,
              isStrictDirectory(directory), contains(modelRootURL.standardizedFileURL, directory) else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        var resolved: [String: URL] = [:]
        for artifact in manifest.modelArtifacts {
            let url = directory.appendingPathComponent(artifact.fileName)
            guard contains(directory, url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == artifact.byteCount,
                  try Self.sha256(file: url) == artifact.sha256 else {
                throw OSAtlasRuntimeInstallationError.invalidModelArtifact(artifact.fileName)
            }
            resolved[artifact.fileName] = url
        }
        guard let modelArtifact = manifest.modelArtifacts.first(where: { $0.kind == .textModelShard }),
              let projectorArtifact = manifest.modelArtifacts.first(where: { $0.kind == .visionProjector }),
              let modelURL = resolved[modelArtifact.fileName], let projectorURL = resolved[projectorArtifact.fileName] else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        return AgentVisionRuntimeInputs(model: model, modelURL: modelURL, projectorURL: projectorURL,
            llamaServerURL: try resolveBundledExecutable(runtimeDirectoryURL: runtimeDirectoryURL,
                                                          enclosingBundleURL: enclosingBundleURL))

#else
        throw OSAtlasRuntimeInstallationError.invalidReceipt
#endif
    }

    private static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resolveTrainedVisionDirectory(receipt: ComputerUseInstallationReceipt,
        variant: ComputerUseArtifactManifest.ModelVariant, modelFileName: String, projectorFileName: String) throws -> URL {
        guard manifest.modelVariant == variant, receipt.modelVariant == variant,
              receipt.installationVersion == manifest.installationVersion,
              (receipt.modelDirectory as NSString).isAbsolutePath,
              manifest.modelArtifacts.count == 2,
              manifest.modelArtifacts.filter({ $0.kind == .textModelShard && $0.fileName == modelFileName }).count == 1,
              manifest.modelArtifacts.filter({ $0.kind == .visionProjector && $0.fileName == projectorFileName }).count == 1 else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        let directory = URL(fileURLWithPath: receipt.modelDirectory, isDirectory: true).standardizedFileURL
        guard isStrictDirectory(directory) else { throw OSAtlasRuntimeInstallationError.invalidReceipt }
        for artifact in manifest.modelArtifacts {
            let url = directory.appendingPathComponent(artifact.fileName)
            guard contains(directory, url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  artifact.byteCount > 0, Int64(values.fileSize ?? -1) == artifact.byteCount else {
                throw OSAtlasRuntimeInstallationError.invalidModelArtifact(artifact.fileName)
            }
        }
        return directory
    }

    private func resolveBundledExecutable(runtimeDirectoryURL: URL, enclosingBundleURL: URL) throws -> URL {
        let runtimeDirectoryURL = runtimeDirectoryURL.standardizedFileURL
        let enclosingBundleURL = enclosingBundleURL.standardizedFileURL
        guard isDirectory(runtimeDirectoryURL),
              contains(enclosingBundleURL, runtimeDirectoryURL) else {
            throw OSAtlasRuntimeInstallationError.bundledRuntimeMissing
        }
        for fileName in Self.requiredBundledRuntimeFiles {
            let url = runtimeDirectoryURL.appendingPathComponent(fileName)
            guard isContainedRegularFile(url, in: runtimeDirectoryURL) else {
                throw OSAtlasRuntimeInstallationError.bundledRuntimeIncomplete(
                    fileName)
            }
        }

        let llamaServerURL = runtimeDirectoryURL.appendingPathComponent(
            "llama-server")
        guard fileManager.isExecutableFile(atPath: llamaServerURL.path) else {
            throw OSAtlasRuntimeInstallationError.bundledRuntimeIncomplete(
                "llama-server")
        }

        return llamaServerURL
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func isStrictDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// llama.cpp ships versioned dylibs plus compatibility symlinks. Resolve
    /// those links completely before checking their type, but retain the signed
    /// runtime directory as a hard trust boundary. Broken links, directories,
    /// special files, and links that escape the runtime all fail closed.
    private func isContainedRegularFile(
        _ url: URL,
        in directory: URL
    ) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard contains(directory, resolvedURL),
              fileManager.fileExists(atPath: resolvedURL.path),
              (try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else {
            return false
        }
        return true
    }

    private func contains(_ directory: URL, _ candidate: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let child = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return child == root || child.hasPrefix(root + "/")
    }
}

@MainActor
struct ComputerUsePreparedVisualExecutor {
    let executor: any ComputerUseExecuting
    let runtimeWasActivated: Bool
}

@MainActor
protocol ComputerUseVisualExecutorLoading: AnyObject {
    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting

    func prepare(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> ComputerUsePreparedVisualExecutor

    func deactivate() async
}

extension ComputerUseVisualExecutorLoading {
    func prepare(receipt: ComputerUseInstallationReceipt,
                 progress: @escaping @MainActor (String) -> Void) async throws -> ComputerUsePreparedVisualExecutor {
        .init(executor: try await load(receipt: receipt, progress: progress), runtimeWasActivated: true)
    }
}

/// Production bridge used by HostComputerUseManager. It searches only inside
/// the signed app bundle and never treats downloaded bytes as executable code.
@MainActor
final class OSAtlasVisualExecutorLoader: ComputerUseVisualExecutorLoading {
    private let resolver: OSAtlasRuntimeInputResolver
    private let bundle: Bundle
    private let runtime: OSAtlasLlamaRuntime
    private let nativeControlInspectExchange: (@Sendable (Data, Data) -> Void)?
    private let browserRevalidationFailureObserver:
        ComputerUseDefaultBrowserExecutor.RevalidationFailureObserver?
    private let faraJournalDirectory: URL
    private let nativeJournalDirectory: URL

    init(
        resolver: OSAtlasRuntimeInputResolver = OSAtlasRuntimeInputResolver(),
        bundle: Bundle = .main,
        runtime: OSAtlasLlamaRuntime = .shared,
        nativeControlInspectExchange: (@Sendable (Data, Data) -> Void)? = nil,
        browserRevalidationFailureObserver:
            ComputerUseDefaultBrowserExecutor.RevalidationFailureObserver? = nil,
        faraJournalDirectory: URL = ComputerUseTaskJournalStore.defaultDirectory
            .deletingLastPathComponent().appendingPathComponent("Fara", isDirectory: true),
        nativeJournalDirectory: URL = ComputerUseTaskJournalStore.defaultDirectory
            .deletingLastPathComponent().appendingPathComponent("NativeDesktop", isDirectory: true),
    ) {
        self.resolver = resolver
        self.bundle = bundle
        self.runtime = runtime
        self.nativeControlInspectExchange = nativeControlInspectExchange
        self.browserRevalidationFailureObserver = browserRevalidationFailureObserver
        self.faraJournalDirectory = faraJournalDirectory
        self.nativeJournalDirectory = nativeJournalDirectory
    }

    func prepare(receipt: ComputerUseInstallationReceipt,
                 progress: @escaping @MainActor (String) -> Void) async throws -> ComputerUsePreparedVisualExecutor {
        try Task.checkCancellation()
        let package = try resolver.resolveAvailablePackage(receipt: receipt,
            runtimeDirectoryURL: Self.bundledRuntimeDirectoryURL(in: bundle), enclosingBundleURL: bundle.bundleURL)
        if case .fara(let inputs) = package {
            try Task.checkCancellation()
            return .init(executor: try makeDefaultBrowserExecutor(resolveInputs: { inputs }), runtimeWasActivated: false)
        }
        return .init(executor: try await load(receipt: receipt, progress: progress), runtimeWasActivated: true)
    }

    @MainActor private final class NativeControlInputsCache {
        var value: ComputerUseNativeTextRuntimeInputs?
    }

    private func makeDefaultBrowserExecutor(
        resolveInputs: @escaping @MainActor @Sendable () throws -> ComputerUseFaraRuntimeInputs,
        nativeControlInputs: ComputerUseDefaultBrowserExecutor.NativeControlInputs? = nil
    ) throws -> ComputerUseDefaultBrowserExecutor {
        let runtime = self.runtime
        let nativeControlInspectExchange = self.nativeControlInspectExchange
        let propose: ComputerUseDesktopExecutor.Propose = { input in
            let endpoint = try await runtime.activateFara(resolveInputs())
            return .init(try await runtime.proposeFara(endpoint: endpoint, input: input))
        }
        let outcomeCheck: ComputerUseDefaultBrowserExecutor.OutcomeCheck = { input, candidateAnswer in
            let endpoint = try await runtime.activateFara(resolveInputs())
            let review = try await runtime.reviewFaraOutcome(endpoint: endpoint, input: input,
                candidateAnswer: candidateAnswer)
            return review.acceptsCompletion(for: input)
        }
        let nativeControlPlanner: ComputerUseDefaultBrowserExecutor.NativeControlPlanner?
        let nativeBootstrapPlanner: ComputerUseDefaultBrowserExecutor.NativeBootstrapPlanner?
        if let nativeControlInputs {
            let cachedInputs = NativeControlInputsCache()
            let resolveNativeInputs: @MainActor @Sendable () async throws -> ComputerUseNativeTextRuntimeInputs? = {
                if let cached = cachedInputs.value { return cached }
                guard let resolved = try await nativeControlInputs() else { return nil }
                cachedInputs.value = resolved
                return resolved
            }
            nativeControlPlanner = { input, page in
                guard let inputs = try await resolveNativeInputs() else {
                    return .visualFallback("The native page planner is not installed.", directive: nil)
                }
                let endpoint = try await runtime.activateNativeText(inputs)
                return try await runtime.proposeDefaultBrowserControl(endpoint: endpoint, input: input, page: page,
                    inspectExchange: nativeControlInspectExchange)
            }
            nativeBootstrapPlanner = { input in
                guard let inputs = try await resolveNativeInputs() else {
                    return .askUser("The local browser planner is unavailable. Review the browser window, then choose Resume.")
                }
                let endpoint = try await runtime.activateNativeText(inputs)
                return try await runtime.proposeDefaultBrowserBootstrap(endpoint: endpoint, input: input,
                    inspectExchange: nativeControlInspectExchange)
            }
        } else {
            nativeControlPlanner = nil
            nativeBootstrapPlanner = nil
        }
        return try ComputerUseDefaultBrowserExecutor(journalDirectory: faraJournalDirectory,
            propose: propose, nativeControlPlanner: nativeControlPlanner,
            nativeBootstrapPlanner: nativeBootstrapPlanner,
            finishRun: { await runtime.shutdown() }, outcomeCheck: outcomeCheck,
            revalidationFailureObserver: browserRevalidationFailureObserver)
    }

    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting {
        let runtimeDirectoryURL = try Self.bundledRuntimeDirectoryURL(in: bundle)
        let package = try resolver.resolveAvailablePackage(
            receipt: receipt,
            runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: bundle.bundleURL)
        switch package {
        case .holo(let inputs):
            progress("Checking Holo native computer use…")
            do {
                _ = try await runtime.activateHolo(inputs)
                try Task.checkCancellation()
                await runtime.shutdown()
                try Task.checkCancellation()
                let runtime = self.runtime
                return try ComputerUseDesktopExecutor(journalDirectory: nativeJournalDirectory,
                    propose: { input in
                        let endpoint = try await runtime.activateHolo(inputs)
                        return try await .init(runtime.proposeHolo(endpoint: endpoint, input: input))
                    }, finishRun: { await runtime.shutdown() })
            } catch {
                await runtime.shutdown()
                throw error
            }
        case .fara(let inputs):
            progress("Checking Fara browser computer use…")
            do {
                // Setup may retire its rollback package only after the pinned
                // runtime has actually loaded both model data files.
                _ = try await runtime.activateFara(inputs)
                try Task.checkCancellation()
                await runtime.shutdown()
                try Task.checkCancellation()
                return try makeDefaultBrowserExecutor(resolveInputs: { inputs })
            } catch {
                await runtime.shutdown()
                throw error
            }
        }
    }

    func deactivate() async {
        await runtime.shutdown()
    }

    static func bundledRuntimeDirectoryURL(in bundle: Bundle) throws -> URL {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(
                "llama-\(OSAtlasLlamaLaunchConfiguration.bundledLlamaServerBuild)",
                isDirectory: true))
            candidates.append(resourceURL
                .appendingPathComponent("ComputerUseRuntime", isDirectory: true)
                .appendingPathComponent(
                    "llama-\(OSAtlasLlamaLaunchConfiguration.bundledLlamaServerBuild)",
                    isDirectory: true))
            candidates.append(resourceURL
                .appendingPathComponent("ThirdPartyRuntime", isDirectory: true)
                .appendingPathComponent(
                    "llama-\(OSAtlasLlamaLaunchConfiguration.bundledLlamaServerBuild)",
                    isDirectory: true))
        }
        candidates.append(bundle.bundleURL
            .appendingPathComponent(
                "Contents/Helpers/ComputerUseRuntime",
                isDirectory: true)
            .appendingPathComponent(
                "llama-\(OSAtlasLlamaLaunchConfiguration.bundledLlamaServerBuild)",
                isDirectory: true))

        guard let directory = candidates.first(where: {
            FileManager.default.fileExists(atPath:
                $0.appendingPathComponent("llama-server").path)
        }) else {
            throw OSAtlasRuntimeInstallationError.bundledRuntimeMissing
        }
        return directory
    }
}
