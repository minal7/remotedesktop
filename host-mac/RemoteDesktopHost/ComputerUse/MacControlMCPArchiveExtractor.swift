import Foundation

protocol MacControlMCPArchiveExtracting: Sendable {
    func extract(
        archiveURL: URL,
        destinationDirectory: URL,
        manifest: MacControlMCPArtifactManifest
    ) async throws -> URL
}

struct SystemMacControlMCPArchiveExtractor: MacControlMCPArchiveExtracting, @unchecked Sendable {
    enum ExtractionError: LocalizedError, Equatable {
        case unableToListArchive
        case unsafeArchiveEntry(String)
        case incompleteArchive
        case extractionFailed
        case symbolicLinkFound

        var errorDescription: String? {
            switch self {
            case .unableToListArchive:
                return "The downloaded MCP archive could not be inspected."
            case .unsafeArchiveEntry:
                return "The downloaded MCP archive contains an unsafe path."
            case .incompleteArchive:
                return "The downloaded MCP archive is missing required app files."
            case .extractionFailed:
                return "The downloaded MCP app could not be unpacked."
            case .symbolicLinkFound:
                return "The downloaded MCP app contains an unexpected symbolic link."
            }
        }
    }

    private let commandRunner: any MacControlMCPCommandRunning
    private let fileManager: FileManager

    init(
        commandRunner: any MacControlMCPCommandRunning = FoundationMacControlMCPCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func extract(
        archiveURL: URL,
        destinationDirectory: URL,
        manifest: MacControlMCPArtifactManifest
    ) async throws -> URL {
        let listing = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tzf", archiveURL.path])
        guard listing.terminationStatus == 0 else {
            throw ExtractionError.unableToListArchive
        }
        try Self.validateArchiveEntries(
            listing.standardOutput,
            manifest: manifest)

        try? fileManager.removeItem(at: destinationDirectory)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true)

        let extraction = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xzf", archiveURL.path,
                "-C", destinationDirectory.path,
                "--no-same-owner",
            ])
        guard extraction.terminationStatus == 0 else {
            throw ExtractionError.extractionFailed
        }

        let appURL = destinationDirectory
            .appendingPathComponent(manifest.appBundleName, isDirectory: true)
        let requiredPaths = [
            appURL.appendingPathComponent("Contents/Info.plist"),
            appURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(manifest.executableName),
            appURL.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
        ]
        guard requiredPaths.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw ExtractionError.incompleteArchive
        }
        try rejectSymbolicLinks(in: destinationDirectory)
        return appURL
    }

    static func validateArchiveEntries(
        _ listing: String,
        manifest: MacControlMCPArtifactManifest
    ) throws {
        let entries = listing
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        guard !entries.isEmpty else {
            throw ExtractionError.incompleteArchive
        }

        var normalizedEntries = Set<String>()
        for rawEntry in entries {
            guard !rawEntry.contains("\0"),
                  !rawEntry.contains("\\"),
                  !rawEntry.hasPrefix("/") else {
                throw ExtractionError.unsafeArchiveEntry(rawEntry)
            }
            let entry = rawEntry.hasSuffix("/")
                ? String(rawEntry.dropLast())
                : rawEntry
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first.map(String.init) == manifest.appBundleName,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw ExtractionError.unsafeArchiveEntry(rawEntry)
            }
            normalizedEntries.insert(entry)
        }

        let required = [
            manifest.appBundleName + "/Contents/Info.plist",
            manifest.appBundleName + "/Contents/MacOS/" + manifest.executableName,
            manifest.appBundleName + "/Contents/_CodeSignature/CodeResources",
        ]
        guard required.allSatisfy(normalizedEntries.contains) else {
            throw ExtractionError.incompleteArchive
        }
    }

    private func rejectSymbolicLinks(in root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }) else {
            throw ExtractionError.incompleteArchive
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ExtractionError.symbolicLinkFound
            }
        }
    }
}
