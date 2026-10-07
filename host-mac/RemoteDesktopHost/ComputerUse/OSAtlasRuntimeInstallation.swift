import Foundation

enum OSAtlasRuntimeInstallationError: Error, LocalizedError, Equatable {
    case proModelRequired
    case invalidReceipt
    case missingModelArtifact(String)
    case invalidModelArtifact(String)
    case bundledRuntimeMissing
    case bundledRuntimeIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .proModelRequired:
            return "AI Computer Use requires the verified OS-Atlas Pro 4B package. Choose Retry to repair it."
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

/// Fully resolved inputs for the two-model local package. Both paths are
/// derived from one verified receipt and its pinned manifest; callers cannot
/// inject a semantic model path independently from the visual package.
struct OSAtlasResolvedRuntimeInstallation: Equatable, Sendable {
    let visualInputs: OSAtlasLlamaRuntimeInputs
    let semanticRouterModelURL: URL
}

/// The verified receipt selects the trained browser model or a supported
/// legacy package. Each model family resolves through its own exact shape.
enum OSAtlasResolvedRuntimePackage: Equatable, Sendable {
    case fara(ComputerUseFaraRuntimeInputs)
    case holo(ComputerUseHoloRuntimeInputs)
    case visualOnly(OSAtlasLlamaRuntimeInputs)
    case visualAndSemantic(OSAtlasResolvedRuntimeInstallation)
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

    func resolve(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> OSAtlasLlamaRuntimeInputs {
        guard manifest.modelVariant == .pro4B,
              receipt.modelVariant == .pro4B else {
            throw OSAtlasRuntimeInstallationError.proModelRequired
        }
        guard receipt.installationVersion == manifest.installationVersion,
              !receipt.modelDirectory.isEmpty else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }

        let modelDirectoryURL = URL(
            fileURLWithPath: receipt.modelDirectory,
            isDirectory: true).standardizedFileURL
        guard (receipt.modelDirectory as NSString).isAbsolutePath,
              isStrictDirectory(modelDirectoryURL) else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }

        let textArtifacts = manifest.modelArtifacts.filter {
            $0.kind == .textModelShard
        }
        let projectors = manifest.modelArtifacts.filter {
            $0.kind == .visionProjector
        }
        guard let firstTextArtifact = textArtifacts.first,
              projectors.count == 1,
              let projectorArtifact = projectors.first else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }

        for artifact in manifest.modelArtifacts {
            let url = modelDirectoryURL.appendingPathComponent(
                artifact.fileName,
                isDirectory: false)
            guard contains(modelDirectoryURL, url) else {
                throw OSAtlasRuntimeInstallationError.invalidModelArtifact(
                    artifact.fileName)
            }
            guard fileManager.fileExists(atPath: url.path) else {
                throw OSAtlasRuntimeInstallationError.missingModelArtifact(
                    artifact.fileName)
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            } catch {
                throw OSAtlasRuntimeInstallationError.invalidModelArtifact(
                    artifact.fileName)
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == artifact.byteCount else {
                throw OSAtlasRuntimeInstallationError.invalidModelArtifact(
                    artifact.fileName)
            }
        }

        let llamaServerURL = try resolveBundledExecutable(
            runtimeDirectoryURL: runtimeDirectoryURL, enclosingBundleURL: enclosingBundleURL)

        return OSAtlasLlamaRuntimeInputs(
            variant: .pro4B,
            modelDirectoryURL: modelDirectoryURL,
            modelFirstSplitFileName: firstTextArtifact.fileName,
            multimodalProjectorFileName: projectorArtifact.fileName,
            llamaServerURL: llamaServerURL)
    }

    func resolvePackage(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> OSAtlasResolvedRuntimeInstallation {
        let textArtifacts = manifest.modelArtifacts.filter {
            $0.kind == .textModelShard
        }
        let projectors = manifest.modelArtifacts.filter {
            $0.kind == .visionProjector
        }
        let semanticArtifacts = manifest.modelArtifacts.filter {
            $0.kind == .semanticRouterModel
        }
        guard !textArtifacts.isEmpty,
              projectors.count == 1,
              semanticArtifacts.count == 1,
              let semanticArtifact = semanticArtifacts.first else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }

        // `resolve` validates every manifest artifact (not just the visual
        // inputs) as a contained, non-symlink regular file with exact size.
        let visualInputs = try resolve(
            receipt: receipt,
            runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: enclosingBundleURL)
        let modelDirectoryURL = URL(
            fileURLWithPath: receipt.modelDirectory,
            isDirectory: true).standardizedFileURL
        let semanticURL = modelDirectoryURL.appendingPathComponent(
            semanticArtifact.fileName,
            isDirectory: false)
        guard contains(modelDirectoryURL, semanticURL) else {
            throw OSAtlasRuntimeInstallationError.invalidModelArtifact(
                semanticArtifact.fileName)
        }
        return OSAtlasResolvedRuntimeInstallation(
            visualInputs: visualInputs,
            semanticRouterModelURL: semanticURL)
    }

    /// Resolves exactly the package shape declared by the pinned manifest.
    /// Fara uses its two-file shape. Legacy visual packages may additionally
    /// contain exactly one semantic artifact; other shapes fail closed.
    func resolveAvailablePackage(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> OSAtlasResolvedRuntimePackage {
        if manifest.modelVariant == .fara15_4B {
            return .fara(try resolveFara(receipt: receipt, runtimeDirectoryURL: runtimeDirectoryURL,
                enclosingBundleURL: enclosingBundleURL))
        }
        if manifest.modelVariant == .holo31_4B {
            return .holo(try resolveHolo(receipt: receipt, runtimeDirectoryURL: runtimeDirectoryURL,
                enclosingBundleURL: enclosingBundleURL))
        }
        let semanticArtifactCount = manifest.modelArtifacts.filter {
            $0.kind == .semanticRouterModel
        }.count
        switch semanticArtifactCount {
        case 0:
            return .visualOnly(try resolve(
                receipt: receipt,
                runtimeDirectoryURL: runtimeDirectoryURL,
                enclosingBundleURL: enclosingBundleURL))
        case 1:
            return .visualAndSemantic(try resolvePackage(
                receipt: receipt,
                runtimeDirectoryURL: runtimeDirectoryURL,
                enclosingBundleURL: enclosingBundleURL))
        default:
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
    }

    /// The receipt must already have passed installer checksum verification.
    /// This stage checks current shape/containment and resolves executable code
    /// only from the enclosing app bundle, independently of visual artifacts.
    func resolveNativeText(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> ComputerUseNativeTextRuntimeInputs {
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
        let directory = try resolveTrainedVisionDirectory(receipt: receipt, variant: .holo31_4B,
            modelFileName: ComputerUseHoloRuntimeInputs.modelFileName, projectorFileName: ComputerUseHoloRuntimeInputs.projectorFileName)
        return ComputerUseHoloRuntimeInputs(modelURL: directory.appendingPathComponent(ComputerUseHoloRuntimeInputs.modelFileName),
            projectorURL: directory.appendingPathComponent(ComputerUseHoloRuntimeInputs.projectorFileName),
            llamaServerURL: try resolveBundledExecutable(runtimeDirectoryURL: runtimeDirectoryURL, enclosingBundleURL: enclosingBundleURL))
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
    /// Construct the native browser workflow without resolving or warming a
    /// model. Only a later visual proposal may require its package.
    func prepareBrowser(receipt: ComputerUseInstallationReceipt?) throws -> ComputerUseFaraBrowserExecutor

    /// Prepare the default-browser route without resolving or warming Fara until a visual proposal is needed.
    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?) throws -> any ComputerUseExecuting
    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?) throws -> any ComputerUseExecuting
    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?,
        nativeControlInputs: ComputerUseDefaultBrowserExecutor.NativeControlInputs?) throws -> any ComputerUseExecuting

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
    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?,
        nativeControlInputs: ComputerUseDefaultBrowserExecutor.NativeControlInputs?) throws -> any ComputerUseExecuting {
        try prepareDefaultBrowser(receipt: receipt, nativeFilePlanner: nativeFilePlanner)
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?) throws -> any ComputerUseExecuting {
        try prepareDefaultBrowser(receipt: receipt)
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?) throws -> any ComputerUseExecuting {
        try prepareBrowser(receipt: receipt)
    }

    func prepareBrowser(receipt: ComputerUseInstallationReceipt?) throws -> ComputerUseFaraBrowserExecutor {
        try ComputerUseFaraBrowserExecutor(journalDirectory: ComputerUseTaskJournalStore.defaultDirectory
            .deletingLastPathComponent().appendingPathComponent("Fara", isDirectory: true), propose: { _ in
                throw ComputerUseFaraBrowserExecutor.Failure.visualModelUnavailable
            })
    }

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
    private let localFileCatalogFactory: ComputerUseFaraBrowserExecutor.LocalFileCatalogFactory?
    private let browserActionAttestationLedger:
        ComputerUseBrowserActionAttestationLedger

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
        localFileCatalogFactory: ComputerUseFaraBrowserExecutor.LocalFileCatalogFactory? = nil,
        browserActionAttestationLedger:
            ComputerUseBrowserActionAttestationLedger =
                ComputerUseBrowserActionAttestationLedger()
    ) {
        self.resolver = resolver
        self.bundle = bundle
        self.runtime = runtime
        self.nativeControlInspectExchange = nativeControlInspectExchange
        self.browserRevalidationFailureObserver = browserRevalidationFailureObserver
        self.faraJournalDirectory = faraJournalDirectory
        self.nativeJournalDirectory = nativeJournalDirectory
        self.localFileCatalogFactory = localFileCatalogFactory
        self.browserActionAttestationLedger =
            browserActionAttestationLedger
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

    @MainActor private final class BrowserInputs {
        var value: ComputerUseFaraRuntimeInputs?
    }

    @MainActor private final class NativeControlInputsCache {
        var value: ComputerUseNativeTextRuntimeInputs?
    }

    func prepareBrowser(receipt: ComputerUseInstallationReceipt?) throws -> ComputerUseFaraBrowserExecutor {
        let inputs = BrowserInputs()
        return try makeFaraExecutor(resolveInputs: { [self] in try resolveFaraInputs(receipt: receipt, cached: inputs) })
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?) throws -> any ComputerUseExecuting {
        let inputs = BrowserInputs()
        return try makeDefaultBrowserExecutor(resolveInputs: { [self] in try resolveFaraInputs(receipt: receipt, cached: inputs) })
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?) throws -> any ComputerUseExecuting {
        let inputs = BrowserInputs()
        return try makeDefaultBrowserExecutor(
            resolveInputs: { [self] in try resolveFaraInputs(receipt: receipt, cached: inputs) },
            nativeFilePlanner: nativeFilePlanner)
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?,
        nativeControlInputs: ComputerUseDefaultBrowserExecutor.NativeControlInputs?) throws -> any ComputerUseExecuting {
        let inputs = BrowserInputs()
        return try makeDefaultBrowserExecutor(
            resolveInputs: { [self] in try resolveFaraInputs(receipt: receipt, cached: inputs) },
            nativeFilePlanner: nativeFilePlanner, nativeControlInputs: nativeControlInputs)
    }

    private func resolveFaraInputs(receipt: ComputerUseInstallationReceipt?, cached: BrowserInputs) throws -> ComputerUseFaraRuntimeInputs {
        try Task.checkCancellation()
        if let value = cached.value { return value }
        guard let receipt, receipt.modelVariant == .fara15_4B else {
            throw ComputerUseFaraBrowserExecutor.Failure.visualModelUnavailable
        }
        let package = try resolver.resolveAvailablePackage(receipt: receipt,
            runtimeDirectoryURL: Self.bundledRuntimeDirectoryURL(in: bundle), enclosingBundleURL: bundle.bundleURL)
        guard case .fara(let value) = package else { throw ComputerUseFaraBrowserExecutor.Failure.visualModelUnavailable }
        try Task.checkCancellation()
        cached.value = value
        return value
    }

    private func makeDefaultBrowserExecutor(
        resolveInputs: @escaping @MainActor @Sendable () throws -> ComputerUseFaraRuntimeInputs,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner? = nil,
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
            propose: propose, nativeFilePlanner: nativeFilePlanner, nativeControlPlanner: nativeControlPlanner,
            nativeBootstrapPlanner: nativeBootstrapPlanner,
            finishRun: { await runtime.shutdown() }, outcomeCheck: outcomeCheck,
            revalidationFailureObserver: browserRevalidationFailureObserver)
    }

    private func makeFaraExecutor(_ inputs: ComputerUseFaraRuntimeInputs) throws -> ComputerUseFaraBrowserExecutor {
        try makeFaraExecutor(resolveInputs: { inputs })
    }

    private func makeFaraExecutor(resolveInputs: @escaping @MainActor @Sendable () throws -> ComputerUseFaraRuntimeInputs) throws -> ComputerUseFaraBrowserExecutor {
        let runtime = self.runtime
        let propose: ComputerUseFaraBrowserExecutor.Propose = { input in
            let endpoint = try await runtime.activateFara(resolveInputs())
            return try await runtime.proposeFaraBrowser(endpoint: endpoint, input: input)
        }
        let readPage: ComputerUseFaraBrowserExecutor.ReadPage = { reading in
            let endpoint = try await runtime.activateFara(resolveInputs())
            return try await runtime.readFaraPage(endpoint: endpoint, reading: reading)
        }
        if let localFileCatalogFactory {
            return try ComputerUseFaraBrowserExecutor(journalDirectory: faraJournalDirectory,
                propose: propose, localFileCatalogFactory: localFileCatalogFactory,
                readPage: readPage, finishRun: { await runtime.shutdown() })
        }
        return try ComputerUseFaraBrowserExecutor(journalDirectory: faraJournalDirectory,
            propose: propose, readPage: readPage, finishRun: { await runtime.shutdown() })
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
        case .visualOnly(let inputs):
            return try await OSAtlasComputerUseExecutor.load(
                inputs: inputs,
                runtime: runtime,
                browserActionAttestationLedger:
                    browserActionAttestationLedger,
                progress: progress)
        case .visualAndSemantic(let installation):
            return try await OSAtlasComputerUseExecutor.load(
                installation: installation,
                runtime: runtime,
                browserActionAttestationLedger:
                    browserActionAttestationLedger,
                progress: progress)
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
