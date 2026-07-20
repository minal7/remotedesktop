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

/// The verified model receipt can describe either the currently shipped
/// visual package or a future visual + semantic package. Keeping that choice
/// explicit prevents a visual-only receipt from being rejected before the
/// existing on-device Foundation planner can be composed around OS-Atlas.
enum OSAtlasResolvedRuntimePackage: Equatable, Sendable {
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
    /// Zero semantic artifacts is the supported visual-only release shape;
    /// exactly one activates the two-model path. Any other count fails closed.
    func resolveAvailablePackage(
        receipt: ComputerUseInstallationReceipt,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> OSAtlasResolvedRuntimePackage {
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
protocol ComputerUseVisualExecutorLoading: AnyObject {
    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting

    func deactivate() async
}

/// Production bridge used by HostComputerUseManager. It searches only inside
/// the signed app bundle and never treats downloaded bytes as executable code.
@MainActor
final class OSAtlasVisualExecutorLoader: ComputerUseVisualExecutorLoading {
    private let resolver: OSAtlasRuntimeInputResolver
    private let bundle: Bundle
    private let runtime: OSAtlasLlamaRuntime

    init(
        resolver: OSAtlasRuntimeInputResolver = OSAtlasRuntimeInputResolver(),
        bundle: Bundle = .main,
        runtime: OSAtlasLlamaRuntime = .shared
    ) {
        self.resolver = resolver
        self.bundle = bundle
        self.runtime = runtime
    }

    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting {
        let runtimeDirectoryURL = try bundledRuntimeDirectoryURL()
        let package = try resolver.resolveAvailablePackage(
            receipt: receipt,
            runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: bundle.bundleURL)
        switch package {
        case .visualOnly(let inputs):
            return try await OSAtlasComputerUseExecutor.load(
                inputs: inputs,
                runtime: runtime,
                progress: progress)
        case .visualAndSemantic(let installation):
            return try await OSAtlasComputerUseExecutor.load(
                installation: installation,
                runtime: runtime,
                progress: progress)
        }
    }

    func deactivate() async {
        await runtime.shutdown()
    }

    private func bundledRuntimeDirectoryURL() throws -> URL {
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
