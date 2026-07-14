import CryptoKit
import Foundation

/// Installs the pinned native MCP server only when `install` is explicitly
/// called. Initializing this actor, asking for status, and building a launch
/// configuration never download, unpack, or execute third-party code.
actor MacControlMCPInstaller {
    struct Update: Equatable, Sendable {
        enum Phase: String, Sendable {
            case preparing
            case downloading
            case verifyingArchive
            case extracting
            case validatingTrust
            case ready
        }

        let phase: Phase
        let fraction: Double
        let downloadedByteCount: Int64?
        let totalByteCount: Int64?
        let detail: String
    }

    enum DurableStatus: Equatable, Sendable {
        case notInstalled
        case downloadPresent(downloadedByteCount: Int64, totalByteCount: Int64)
        case repairRequired
        case ready(MacControlMCPInstallationReceipt)
    }

    enum InstallError: LocalizedError, Equatable {
        case invalidArchiveSize(expected: Int64, actual: Int64)
        case checksumMismatch
        case invalidReceipt
        case activationFailed

        var errorDescription: String? {
            switch self {
            case .invalidArchiveSize(let expected, let actual):
                return "The MCP download was incomplete (expected \(expected) bytes, received \(actual))."
            case .checksumMismatch:
                return "The MCP download did not match its published SHA-256 and was not installed."
            case .invalidReceipt:
                return "The existing MCP installation receipt is invalid."
            case .activationFailed:
                return "The verified MCP app could not be activated."
            }
        }
    }

    nonisolated static let interruptedInstallationMarkerName = ".installation-in-progress"

    nonisolated static var defaultComputerUseRootDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Model", isDirectory: true)
    }

    nonisolated static var defaultInstallationRootDirectory: URL {
        defaultComputerUseRootDirectory
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("mac-control-mcp", isDirectory: true)
    }

    private let manifest: MacControlMCPArtifactManifest
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let downloadSession: URLSession
    private let downloadChunkByteCount: Int64
    private let archiveExtractor: any MacControlMCPArchiveExtracting
    private let trustValidator: any MacControlMCPTrustValidating

    init(
        manifest: MacControlMCPArtifactManifest = .current,
        rootDirectory: URL = MacControlMCPInstaller.defaultInstallationRootDirectory,
        fileManager: FileManager = .default,
        downloadSession: URLSession = .shared,
        downloadChunkByteCount: Int64 = 512 * 1_024,
        archiveExtractor: (any MacControlMCPArchiveExtracting)? = nil,
        trustValidator: (any MacControlMCPTrustValidating)? = nil
    ) {
        self.manifest = manifest
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.downloadSession = downloadSession
        self.downloadChunkByteCount = max(1, downloadChunkByteCount)
        self.archiveExtractor = archiveExtractor
            ?? SystemMacControlMCPArchiveExtractor(fileManager: fileManager)
        self.trustValidator = trustValidator
            ?? MacControlMCPTrustValidator(fileManager: fileManager)
    }

    func durableStatus() async -> DurableStatus {
        if let receipt = await currentInstallation() {
            return .ready(receipt)
        }
        if fileManager.fileExists(atPath: receiptURL.path)
            || fileManager.fileExists(atPath: activeVersionDirectory.path) {
            return .repairRequired
        }
        guard let size = fileSize(at: archiveURL), size > 0 else {
            return .notInstalled
        }
        return .downloadPresent(
            downloadedByteCount: min(size, manifest.archiveByteCount),
            totalByteCount: manifest.archiveByteCount)
    }

    func currentInstallation() async -> MacControlMCPInstallationReceipt? {
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(
                  MacControlMCPInstallationReceipt.self,
                  from: data),
              receipt.schemaVersion == MacControlMCPInstallationReceipt.currentSchemaVersion,
              receipt.packageVersion == manifest.version,
              receipt.archiveSHA256.lowercased() == manifest.archiveSHA256.lowercased(),
              receipt.executableSHA256 == nil
                || receipt.executableSHA256?.lowercased()
                    == manifest.executableSHA256.lowercased(),
              receipt.bundleIdentifier == manifest.bundleIdentifier,
              receipt.teamIdentifier == manifest.teamIdentifier,
              receipt.signingIdentity == manifest.signingIdentity,
              URL(fileURLWithPath: receipt.appBundlePath).standardizedFileURL == activeAppURL,
              URL(fileURLWithPath: receipt.binaryPath).standardizedFileURL == activeBinaryURL,
              fileManager.fileExists(atPath: activeAppURL.path),
              fileManager.isExecutableFile(atPath: activeBinaryURL.path) else {
            return nil
        }

        do {
            guard try Self.sha256(activeBinaryURL)
                == manifest.executableSHA256.lowercased() else {
                return nil
            }
            let evidence = try await trustValidator.validate(
                appURL: activeAppURL,
                manifest: manifest)
            guard evidence.bundleIdentifier == manifest.bundleIdentifier,
                  evidence.teamIdentifier == manifest.teamIdentifier,
                  evidence.signingIdentity == manifest.signingIdentity,
                  evidence.hasHardenedRuntime,
                  evidence.isUniversalBinary,
                  evidence.gatekeeperAcceptedNotarization else {
                return nil
            }
            guard receipt.executableSHA256?.lowercased()
                != manifest.executableSHA256.lowercased() else {
                return receipt
            }
            let upgradedReceipt = MacControlMCPInstallationReceipt(
                packageVersion: receipt.packageVersion,
                archiveSHA256: receipt.archiveSHA256,
                appBundlePath: receipt.appBundlePath,
                binaryPath: receipt.binaryPath,
                executableSHA256: manifest.executableSHA256.lowercased(),
                bundleIdentifier: receipt.bundleIdentifier,
                teamIdentifier: receipt.teamIdentifier,
                signingIdentity: receipt.signingIdentity,
                installedAt: receipt.installedAt)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(upgradedReceipt).write(to: receiptURL, options: .atomic)
            return upgradedReceipt
        } catch {
            return nil
        }
    }

    func install(
        progress: @MainActor @Sendable @escaping (Update) -> Void
    ) async throws -> MacControlMCPInstallationReceipt {
        if let existing = await currentInstallation() {
            await progress(Update(
                phase: .ready,
                fraction: 1,
                downloadedByteCount: manifest.archiveByteCount,
                totalByteCount: manifest.archiveByteCount,
                detail: "Mac control is installed"))
            return existing
        }

        try Task.checkCancellation()
        await progress(Update(
            phase: .preparing,
            fraction: 0,
            downloadedByteCount: fileSize(at: archiveURL),
            totalByteCount: manifest.archiveByteCount,
            detail: "Preparing Mac control…"))

        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: versionsDirectory,
            withIntermediateDirectories: true)
        try Data("installing\n".utf8).write(
            to: interruptedInstallationMarkerURL,
            options: .atomic)

        var request = URLRequest(url: manifest.downloadURL)
        request.timeoutInterval = 60 * 30
        let archiveByteCount = manifest.archiveByteCount
        let downloader = ComputerUseHTTPDownloader(
            destination: archiveURL,
            expectedByteCount: archiveByteCount,
            chunkByteCount: downloadChunkByteCount,
            session: downloadSession,
            fileManager: fileManager,
            progress: { fraction in
                let bytes = Int64(
                    (Double(archiveByteCount) * fraction).rounded(.down))
                progress(Self.downloadUpdate(
                    downloadedByteCount: bytes,
                    totalByteCount: archiveByteCount))
            })
        try await downloader.download(request)

        try Task.checkCancellation()
        await progress(Update(
            phase: .verifyingArchive,
            fraction: 0.72,
            downloadedByteCount: manifest.archiveByteCount,
            totalByteCount: manifest.archiveByteCount,
            detail: "Verifying the published download…"))
        do {
            try verifyArchive()
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }

        try Task.checkCancellation()
        await progress(Update(
            phase: .extracting,
            fraction: 0.78,
            downloadedByteCount: manifest.archiveByteCount,
            totalByteCount: manifest.archiveByteCount,
            detail: "Unpacking the signed Mac app…"))
        try? fileManager.removeItem(at: stagingDirectory)
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        let stagedAppURL = try await archiveExtractor.extract(
            archiveURL: archiveURL,
            destinationDirectory: stagingDirectory,
            manifest: manifest)

        try Task.checkCancellation()
        await progress(Update(
            phase: .validatingTrust,
            fraction: 0.86,
            downloadedByteCount: manifest.archiveByteCount,
            totalByteCount: manifest.archiveByteCount,
            detail: "Checking Developer ID and notarization…"))
        let evidence = try await trustValidator.validate(
            appURL: stagedAppURL,
            manifest: manifest)
        let stagedBinaryURL = stagedAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(manifest.executableName)
        guard try Self.sha256(stagedBinaryURL)
                == manifest.executableSHA256.lowercased(),
              evidence.bundleIdentifier == manifest.bundleIdentifier,
              evidence.teamIdentifier == manifest.teamIdentifier,
              evidence.signingIdentity == manifest.signingIdentity,
              evidence.hasHardenedRuntime,
              evidence.isUniversalBinary,
              evidence.gatekeeperAcceptedNotarization else {
            throw InstallError.activationFailed
        }

        try Task.checkCancellation()
        try? fileManager.removeItem(at: activeVersionDirectory)
        do {
            try fileManager.moveItem(
                at: stagingDirectory,
                to: activeVersionDirectory)
        } catch {
            throw InstallError.activationFailed
        }
        guard fileManager.fileExists(atPath: activeAppURL.path),
              fileManager.isExecutableFile(atPath: activeBinaryURL.path) else {
            try? fileManager.removeItem(at: activeVersionDirectory)
            throw InstallError.activationFailed
        }

        let receipt = MacControlMCPInstallationReceipt(
            packageVersion: manifest.version,
            archiveSHA256: manifest.archiveSHA256.lowercased(),
            appBundlePath: activeAppURL.path,
            binaryPath: activeBinaryURL.path,
            executableSHA256: manifest.executableSHA256.lowercased(),
            bundleIdentifier: manifest.bundleIdentifier,
            teamIdentifier: manifest.teamIdentifier,
            signingIdentity: manifest.signingIdentity,
            installedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try? fileManager.removeItem(at: interruptedInstallationMarkerURL)

        await progress(Update(
            phase: .ready,
            fraction: 1,
            downloadedByteCount: manifest.archiveByteCount,
            totalByteCount: manifest.archiveByteCount,
            detail: "Mac control is installed"))
        return receipt
    }

    func launchConfiguration() async throws -> MacControlMCPLaunchConfiguration {
        guard let receipt = await currentInstallation() else {
            throw InstallError.invalidReceipt
        }
        return MacControlMCPLaunchConfiguration(
            receipt: receipt,
            stateDirectory: stateDirectory)
    }

    nonisolated static func downloadUpdate(
        downloadedByteCount: Int64,
        totalByteCount: Int64
    ) -> Update {
        let total = max(1, totalByteCount)
        let downloaded = min(max(0, downloadedByteCount), total)
        let byteFraction = Double(downloaded) / Double(total)
        let downloadedText = ByteCountFormatter.string(
            fromByteCount: downloaded,
            countStyle: .file)
        let totalText = ByteCountFormatter.string(
            fromByteCount: total,
            countStyle: .file)
        return Update(
            phase: .downloading,
            fraction: 0.05 + byteFraction * 0.65,
            downloadedByteCount: downloaded,
            totalByteCount: total,
            detail: "Downloading Mac control… \(downloadedText) of \(totalText)")
    }

    private var downloadsDirectory: URL {
        rootDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var archiveURL: URL {
        downloadsDirectory.appendingPathComponent(manifest.archiveFileName)
    }

    private var versionsDirectory: URL {
        rootDirectory.appendingPathComponent("Versions", isDirectory: true)
    }

    private var activeVersionDirectory: URL {
        versionsDirectory.appendingPathComponent(manifest.version, isDirectory: true)
    }

    private var stagingDirectory: URL {
        versionsDirectory.appendingPathComponent(".\(manifest.version)-staging", isDirectory: true)
    }

    private var activeAppURL: URL {
        activeVersionDirectory
            .appendingPathComponent(manifest.appBundleName, isDirectory: true)
            .standardizedFileURL
    }

    private var activeBinaryURL: URL {
        activeAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(manifest.executableName)
            .standardizedFileURL
    }

    private var receiptURL: URL {
        rootDirectory.appendingPathComponent("active-installation.json")
    }

    private var interruptedInstallationMarkerURL: URL {
        rootDirectory.appendingPathComponent(Self.interruptedInstallationMarkerName)
    }

    private var stateDirectory: URL {
        rootDirectory.appendingPathComponent("State", isDirectory: true)
    }

    private func verifyArchive() throws {
        let size = fileSize(at: archiveURL) ?? -1
        guard size == manifest.archiveByteCount else {
            throw InstallError.invalidArchiveSize(
                expected: manifest.archiveByteCount,
                actual: size)
        }
        guard try Self.sha256(archiveURL) == manifest.archiveSHA256.lowercased() else {
            throw InstallError.checksumMismatch
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
