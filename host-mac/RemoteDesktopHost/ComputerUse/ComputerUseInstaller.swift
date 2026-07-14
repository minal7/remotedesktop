import CryptoKit
import Foundation

actor ComputerUseInstaller {
    nonisolated static let interruptedInstallationMarkerName = ".installation-in-progress"

    struct Update: Equatable, Sendable {
        enum Phase: String, Sendable {
            case preparing
            case downloadingModel
            case verifying
            case ready
        }

        let phase: Phase
        let fraction: Double?
        let detail: String
    }

    enum InstallError: LocalizedError, Equatable {
        case unsupportedProcessor
        case insufficientMemory(required: UInt64, available: UInt64)
        case insufficientDisk(required: Int64, available: Int64)
        case unexpectedHTTPStatus(Int)
        case invalidManifest(String)
        case invalidArtifact(String)
        case checksumMismatch(String)
        case invalidReceipt

        var errorDescription: String? {
            switch self {
            case .unsupportedProcessor:
                return "AI Computer Use currently requires a Mac with Apple silicon."
            case .insufficientMemory(let required, let available):
                return "This Mac needs at least \(Self.format(required)) of memory for AI Computer Use (\(Self.format(available)) available)."
            case .insufficientDisk(let required, let available):
                return "Free \(Self.format(UInt64(required))) of storage to install AI Computer Use (\(Self.format(UInt64(max(0, available)))) available)."
            case .unexpectedHTTPStatus(let status):
                return "The AI model server returned an unexpected response (\(status)). Try again later."
            case .invalidManifest(let reason):
                return "The AI model package definition is invalid (\(reason))."
            case .invalidArtifact(let file):
                return "The downloaded AI model package is incomplete or invalid (\(file))."
            case .checksumMismatch(let file):
                return "The AI model package could not be verified (\(file)). Delete it and try again."
            case .invalidReceipt:
                return "The existing AI installation is incomplete. Choose Retry to repair it."
            }
        }

        private static func format(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        }
    }

    private let manifest: ComputerUseArtifactManifest
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let legalResourceDirectory: URL?
    private let downloadSession: URLSession
    private let downloadChunkByteCount: Int64

    init(
        manifest: ComputerUseArtifactManifest = .current,
        rootDirectory: URL = HostComputerUseManager.modelDirectoryURL,
        fileManager: FileManager = .default,
        legalResourceDirectory: URL? = nil,
        downloadSession: URLSession = .shared,
        downloadChunkByteCount: Int64 = 16 * 1_024 * 1_024
    ) {
        self.manifest = manifest
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.legalResourceDirectory = legalResourceDirectory
        self.downloadSession = downloadSession
        self.downloadChunkByteCount = max(1, downloadChunkByteCount)
    }

    func currentInstallation() -> ComputerUseInstallationReceipt? {
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(
                ComputerUseInstallationReceipt.self,
                from: data),
              receipt.installationVersion == manifest.installationVersion,
              receipt.modelVariant == manifest.modelVariant else {
            return nil
        }

        let modelDirectory = URL(
            fileURLWithPath: receipt.modelDirectory,
            isDirectory: true)
        guard modelDirectory.resolvingSymlinksInPath().standardizedFileURL
            == activeModelDirectory.resolvingSymlinksInPath().standardizedFileURL,
              isInsideRoot(modelDirectory),
              manifest.modelArtifacts.allSatisfy({
                artifactLooksComplete($0, in: modelDirectory)
              }) else {
            return nil
        }
        for artifact in manifest.modelArtifacts {
            guard (try? verify(artifact, in: modelDirectory)) != nil,
                  (try? makeDataOnly(
                    modelDirectory.appendingPathComponent(artifact.fileName))) != nil else {
                return nil
            }
        }

        // Repair receipts created before the legal documents were bundled.
        // This is a local copy from the signed app, never another download.
        do {
            try installLegalDocuments(in: modelDirectory)
        } catch {
            return nil
        }
        try? fileManager.removeItem(at: interruptedInstallationMarkerURL)
        return receipt
    }

    /// A marker is written only after a user-requested setup passes preflight.
    /// It survives an abrupt process exit, allowing the next host launch to
    /// resume durable model bytes without another tap on the mobile client.
    func interruptedInstallationExists() -> Bool {
        fileManager.fileExists(atPath: interruptedInstallationMarkerURL.path)
    }

    func clearInterruptedInstallationMarker() {
        try? fileManager.removeItem(at: interruptedInstallationMarkerURL)
    }

    func install(
        progress: @MainActor @Sendable @escaping (Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt {
        if let existing = currentInstallation() {
            await progress(Update(
                phase: .ready,
                fraction: 1,
                detail: "AI Computer Use is installed"))
            return existing
        }

        try Task.checkCancellation()
        await progress(Update(
            phase: .preparing,
            fraction: 0,
            detail: "Checking this Mac…"))
        try preflight()
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true)
        try Data("installing\n".utf8).write(
            to: interruptedInstallationMarkerURL,
            options: .atomic)

        let modelDirectory = try await installModel(progress: progress)
        try Task.checkCancellation()

        await progress(Update(
            phase: .verifying,
            fraction: 0.96,
            detail: "Verifying the AI model…"))
        for artifact in manifest.modelArtifacts {
            try verify(artifact, in: modelDirectory)
        }
        try installLegalDocuments(in: modelDirectory)

        let receipt = ComputerUseInstallationReceipt(
            installationVersion: manifest.installationVersion,
            modelVariant: manifest.modelVariant,
            modelDirectory: modelDirectory.path,
            installedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        // The previous adapter package is no longer executable or discoverable.
        // Remove its app-managed data only after the verified
        // OS-Atlas receipt is durable, so migration never destroys the last
        // complete package before the replacement succeeds.
        try? fileManager.removeItem(at: legacyAdaptersDirectory)
        try? fileManager.removeItem(at: interruptedInstallationMarkerURL)

        await progress(Update(
            phase: .ready,
            fraction: 1,
            detail: "AI Computer Use is installed"))
        return receipt
    }

    func removeInstallation() throws {
        try? fileManager.removeItem(at: receiptURL)
        try? fileManager.removeItem(at: modelsDirectory)
        try? fileManager.removeItem(at: legacyAdaptersDirectory)
    }

    private var receiptURL: URL {
        rootDirectory.appendingPathComponent("active-installation.json")
    }

    private var interruptedInstallationMarkerURL: URL {
        rootDirectory.appendingPathComponent(Self.interruptedInstallationMarkerName)
    }

    private var modelsDirectory: URL {
        rootDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    private var legacyAdaptersDirectory: URL {
        rootDirectory.appendingPathComponent("Adapters", isDirectory: true)
    }

    private var activeModelDirectory: URL {
        modelsDirectory.appendingPathComponent(
            manifest.installationVersion,
            isDirectory: true)
    }

    func preflight() throws {
        #if !arch(arm64)
        throw InstallError.unsupportedProcessor
        #endif

        try validateManifest()

        let memory = ProcessInfo.processInfo.physicalMemory
        guard memory >= manifest.minimumMemoryBytes else {
            throw InstallError.insufficientMemory(
                required: manifest.minimumMemoryBytes,
                available: memory)
        }

        // The managed model directory and its immediate parent do not exist on
        // a fresh installation. Query the nearest existing ancestor so the
        // disk check works before creating application-support folders.
        let capacityProbeURL = Self.nearestExistingAncestor(
            of: rootDirectory,
            fileManager: fileManager)
        let values = try capacityProbeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage {
            let required = manifest.modelArtifacts.reduce(Int64(0)) {
                $0 + $1.byteCount
            } + 1_000_000_000
            guard available >= required else {
                throw InstallError.insufficientDisk(
                    required: required,
                    available: available)
            }
        }
    }

    nonisolated static func nearestExistingAncestor(
        of url: URL,
        fileManager: FileManager = .default
    ) -> URL {
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return candidate }
            candidate = parent
        }
        return candidate
    }

    /// Downloads the manifest's ordered list of immutable model-data files.
    /// Progress is based on verified and durably appended bytes across the
    /// entire package, so a resumed setup never appears stuck or jumps back.
    func installModel(
        progress: @MainActor @Sendable @escaping (Update) -> Void
    ) async throws -> URL {
        try validateManifest()
        let artifacts = manifest.modelArtifacts
        if artifacts.allSatisfy({
            (try? verify($0, in: activeModelDirectory)) != nil
        }) {
            for artifact in artifacts {
                try makeDataOnly(
                    activeModelDirectory.appendingPathComponent(artifact.fileName))
            }
            await reportModelProgress(
                downloadedByteCount: artifacts.reduce(0) { $0 + $1.byteCount },
                artifacts: artifacts,
                progress: progress)
            return activeModelDirectory
        }

        let staging = modelsDirectory.appendingPathComponent(
            ".\(manifest.installationVersion)-staging",
            isDirectory: true)
        // Each range-complete chunk is durable in this directory. An
        // interrupted process resumes from real on-disk bytes rather than
        // restarting a multi-gigabyte transfer.
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true)

        var completedArtifacts = Set<String>()
        var durableArtifactByteCounts: [String: Int64] = [:]
        for artifact in artifacts where artifactLooksComplete(artifact, in: staging) {
            do {
                try verify(artifact, in: staging)
                try makeDataOnly(staging.appendingPathComponent(artifact.fileName))
                completedArtifacts.insert(artifact.fileName)
                durableArtifactByteCounts[artifact.fileName] = artifact.byteCount
            } catch {
                // A same-size partial or corrupt artifact cannot be resumed
                // safely. Retain every other verified artifact in staging.
                try? fileManager.removeItem(at: staging.appendingPathComponent(
                    artifact.fileName))
            }
        }
        for artifact in artifacts where !completedArtifacts.contains(artifact.fileName) {
            durableArtifactByteCounts[artifact.fileName] = resumableByteCount(
                for: artifact,
                in: staging)
        }
        var durableDownloadedByteCount = durableArtifactByteCounts.values.reduce(0, +)
        await reportModelProgress(
            downloadedByteCount: durableDownloadedByteCount,
            artifacts: artifacts,
            progress: progress)

        for artifact in artifacts where !completedArtifacts.contains(artifact.fileName) {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(artifact.fileName)
            let bytesOutsideArtifact = durableDownloadedByteCount
                - (durableArtifactByteCounts[artifact.fileName] ?? 0)
            let downloader = ComputerUseHTTPDownloader(
                destination: destination,
                expectedByteCount: artifact.byteCount,
                chunkByteCount: downloadChunkByteCount,
                session: downloadSession,
                fileManager: fileManager,
                progress: { fraction in
                    let currentArtifactBytes = Int64(
                        (Double(artifact.byteCount) * fraction).rounded(.down))
                    progress(Self.modelProgressUpdate(
                        downloadedByteCount: bytesOutsideArtifact + currentArtifactBytes,
                        artifacts: artifacts))
                })
            var request = URLRequest(url: artifact.downloadURL)
            request.timeoutInterval = 60 * 60
            do {
                try await downloader.download(request)
            } catch let error as ComputerUseHTTPDownloader.DownloadError {
                if case .httpStatus(let status) = error {
                    throw InstallError.unexpectedHTTPStatus(status)
                }
                throw error
            }
            try verify(artifact, in: staging)
            try makeDataOnly(staging.appendingPathComponent(artifact.fileName))
            durableArtifactByteCounts[artifact.fileName] = artifact.byteCount
            durableDownloadedByteCount = bytesOutsideArtifact + artifact.byteCount
            await reportModelProgress(
                downloadedByteCount: durableDownloadedByteCount,
                artifacts: artifacts,
                progress: progress)
        }

        try fileManager.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true)
        try? fileManager.removeItem(at: activeModelDirectory)
        try fileManager.moveItem(at: staging, to: activeModelDirectory)
        return activeModelDirectory
    }

    private func validateManifest() throws {
        guard !manifest.installationVersion.isEmpty,
              !manifest.modelRepository.isEmpty,
              !manifest.modelRevision.isEmpty,
              !manifest.modelArtifacts.isEmpty else {
            throw InstallError.invalidManifest("missing required value")
        }
        var names = Set<String>()
        for artifact in manifest.modelArtifacts {
            let hash = artifact.sha256.lowercased()
            guard artifact.byteCount > 0,
                  artifact.fileName.hasSuffix(".gguf"),
                  artifact.fileName == URL(fileURLWithPath: artifact.fileName).lastPathComponent,
                  !artifact.fileName.contains("/"),
                  !artifact.fileName.contains("\\"),
                  names.insert(artifact.fileName).inserted,
                  hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }),
                  hash.contains(where: { $0 != "0" }),
                  artifact.downloadURL.scheme?.lowercased() == "https",
                  artifact.downloadURL.user == nil,
                  artifact.downloadURL.password == nil,
                  artifact.downloadURL.query == nil,
                  artifact.downloadURL.fragment == nil,
                  artifact.downloadURL.lastPathComponent == artifact.fileName else {
                throw InstallError.invalidManifest(artifact.fileName)
            }
        }
    }

    private func resumableByteCount(
        for artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        in directory: URL
    ) -> Int64 {
        let url = directory.appendingPathComponent(artifact.fileName)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        let size = number.int64Value
        guard size >= 0, size < artifact.byteCount else {
            try? fileManager.removeItem(at: url)
            return 0
        }
        return size
    }

    private func reportModelProgress(
        downloadedByteCount: Int64,
        artifacts: [ComputerUseArtifactManifest.DownloadableArtifact],
        progress: @MainActor @Sendable (Update) -> Void
    ) async {
        await progress(Self.modelProgressUpdate(
            downloadedByteCount: downloadedByteCount,
            artifacts: artifacts))
    }

    private nonisolated static func modelProgressUpdate(
        downloadedByteCount: Int64,
        artifacts: [ComputerUseArtifactManifest.DownloadableArtifact]
    ) -> Update {
        let totalByteCount = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
        let fraction = Self.installerFractionForModel(
            downloadedByteCount: downloadedByteCount,
            totalByteCount: totalByteCount)
        let downloaded = ByteCountFormatter.string(
            fromByteCount: min(max(0, downloadedByteCount), totalByteCount),
            countStyle: .file)
        let total = ByteCountFormatter.string(
            fromByteCount: totalByteCount,
            countStyle: .file)
        return Update(
            phase: .downloadingModel,
            fraction: fraction,
            detail: "Downloading OS-Atlas Pro… \(downloaded) of \(total)")
    }

    /// Maps verified or durably appended package bytes into the installer's
    /// 1–95% allocation. This remains monotonic across files and restarts.
    nonisolated static func installerFractionForModel(
        downloadedByteCount: Int64,
        totalByteCount: Int64
    ) -> Double {
        guard totalByteCount > 0 else { return 0.95 }
        let ratio = min(1, max(0,
            Double(downloadedByteCount) / Double(totalByteCount)))
        return 0.01 + ratio * 0.94
    }

    private func installLegalDocuments(in modelDirectory: URL) throws {
        guard isInsideRoot(modelDirectory) else {
            throw InstallError.invalidArtifact(modelDirectory.lastPathComponent)
        }
        for artifact in ComputerUseArtifactManifest.modelLegalArtifacts {
            let source = try legalResourceURL(for: artifact)
            try verifyBundledArtifact(artifact, at: source)
            if (try? verify(artifact, in: modelDirectory)) != nil {
                continue
            }
            try fileManager.createDirectory(
                at: modelDirectory,
                withIntermediateDirectories: true)
            let destination = modelDirectory.appendingPathComponent(artifact.fileName)
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try verify(artifact, in: modelDirectory)
            try makeDataOnly(destination)
        }
    }

    private func legalResourceURL(
        for artifact: ComputerUseArtifactManifest.BundledArtifact
    ) throws -> URL {
        if let legalResourceDirectory {
            return legalResourceDirectory.appendingPathComponent(artifact.fileName)
        }
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        guard let bundled = ComputerUseArtifactManifest.bundledLegalDocumentURL(
            artifact,
            bundles: bundles) else {
            throw InstallError.invalidArtifact(artifact.fileName)
        }
        return bundled
    }

    private func verifyBundledArtifact(
        _ artifact: ComputerUseArtifactManifest.BundledArtifact,
        at url: URL
    ) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == artifact.byteCount else {
            throw InstallError.invalidArtifact(artifact.fileName)
        }
        guard try Self.sha256(url) == artifact.sha256.lowercased() else {
            throw InstallError.checksumMismatch(artifact.fileName)
        }
    }

    private func artifactLooksComplete(
        _ artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        in directory: URL
    ) -> Bool {
        fileLooksComplete(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            in: directory)
    }

    private func verify(
        _ artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        in directory: URL
    ) throws {
        try verify(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            in: directory)
    }

    private func verify(
        _ artifact: ComputerUseArtifactManifest.BundledArtifact,
        in directory: URL
    ) throws {
        try verify(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            in: directory)
    }

    private func fileLooksComplete(
        fileName: String,
        byteCount: Int64,
        in directory: URL
    ) -> Bool {
        let url = directory.appendingPathComponent(fileName)
        let resolvedURL = url.resolvingSymlinksInPath()
        guard isInsideRoot(resolvedURL),
              let values = try? resolvedURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == byteCount else {
            return false
        }
        return true
    }

    private func verify(
        fileName: String,
        byteCount: Int64,
        sha256: String,
        in directory: URL
    ) throws {
        guard fileLooksComplete(
            fileName: fileName,
            byteCount: byteCount,
            in: directory) else {
            throw InstallError.invalidArtifact(fileName)
        }
        let url = directory.appendingPathComponent(fileName)
        let digest = try Self.sha256(url)
        guard digest == sha256.lowercased() else {
            try? fileManager.removeItem(at: url)
            throw InstallError.checksumMismatch(fileName)
        }
    }

    private func makeDataOnly(_ url: URL) throws {
        // Model and notice files are never executable. The signed app owns all
        // runtime code; downloaded bytes are private read/write data only.
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
