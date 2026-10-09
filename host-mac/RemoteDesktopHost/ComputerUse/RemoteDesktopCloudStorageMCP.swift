import CryptoKit
import Darwin
import Foundation
import OSLog

/// Host-owned local sync-folder copy service. The model supplies only a source,
/// an offered provider ID, and a relative folder; destination paths and hashes
/// are always recomputed by the host.
enum RemoteDesktopCloudStorageMCP {
    static let serverID = "com.threadmark.remotedesktop.host.cloud-storage-mcp"
    static let toolName = "save_to_cloud_storage"
    static let reviewedDescription = "Copy a user-selected local file into an installed cloud-storage sync folder. The host verifies the copy and reports upload status separately."
    private static let relativeFolderPattern = #"^(?:$|(?:(?!\.\.?(/|$))[^/\\:\u0000]+)(?:/(?:(?!\.\.?(/|$))[^/\\:\u0000]+))*)$"#

    static func inputSchema(providers: [RemoteDesktopCloudStorage.Provider]) -> MCPJSONValue {
        var providerSchema: [String: MCPJSONValue] = [
            "type": .string("string"), "minLength": .integer(1), "maxLength": .integer(256),
            "description": .string(providers.isEmpty
                ? "No local sync provider is installed. Ask the user to install and sign in to a sync app."
                : "Installed accounts: " + providers.map { "\($0.id): \($0.label)" }.joined(separator: "; ")),
        ]
        if !providers.isEmpty { providerSchema["enum"] = .array(providers.map { .string($0.id) }) }
        return .object([
            "type": .string("object"),
            "properties": .object([
                "source_path": .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(4_096)]),
                "provider_id": .object(providerSchema),
                "relative_folder": .object([
                    "type": .string("string"),
                    "description": .string("Provider-relative folder segments only; empty means the provider root. The host preserves the source filename."),
                    "maxLength": .integer(1_024),
                    "pattern": .string(relativeFolderPattern),
                ]),
            ]),
            "required": .array(["source_path", "provider_id", "relative_folder"].map(MCPJSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    /// Executable schema. These host fields are accepted only because the host
    /// adds them after validation; `prepare` never trusts model-supplied values.
    fileprivate static func executableSchema(providers: [RemoteDesktopCloudStorage.Provider]) -> MCPJSONValue {
        guard case .object(var root) = inputSchema(providers: providers),
              case .object(var properties)? = root["properties"],
              case .array(let required)? = root["required"] else { return inputSchema(providers: providers) }
        properties["source_sha256"] = .object(["type": .string("string"), "pattern": .string("^[0-9a-f]{64}$")])
        properties["destination_path"] = .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(4_096)])
        properties["existing_destination_sha256"] = .object(["type": .array([.string("string"), .string("null")])])
        root["properties"] = .object(properties)
        return .object(root)
    }
}

struct RemoteDesktopCloudStorage: Sendable {
    struct Provider: Equatable, Sendable {
        let id: String
        let label: String
        let rootURL: URL
    }

    struct Prepared: Equatable, Sendable {
        let arguments: [String: MCPJSONValue]
        let needsReplacementApproval: Bool
    }

    enum UploadState: String, Equatable, Sendable {
        case uploaded
        case uploading
        case unknown
    }

    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidArguments
        case providerUnavailable
        case sourceUnavailable
        case destinationUnavailable
        case destinationExists
        case destinationChanged
        case sourceChanged
        case coordinationFailed
        case copyFailed
        case receiptMismatch

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "The cloud-storage request is invalid."
            case .providerUnavailable: "Set up and sign in to a local sync app, or choose an installed cloud-storage folder."
            case .sourceUnavailable: "The source file is unavailable or outside an approved local folder."
            case .destinationUnavailable: "The destination folder is unavailable or outside the selected provider."
            case .destinationExists: "The destination already exists and must be approved before replacement."
            case .destinationChanged: "The destination changed after approval, so it was not replaced."
            case .sourceChanged: "The source changed after preparation, so it was not copied."
            case .coordinationFailed: "macOS could not coordinate access to the files."
            case .copyFailed: "The verified cloud-folder copy could not be completed."
            case .receiptMismatch: "The copy returned no matching host verification."
            }
        }
    }

    typealias UploadResourceReader = @Sendable (URL) throws -> UploadState?

    private let homeURL: URL
    private let uploadTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let uploadResourceReader: UploadResourceReader
    private let beforePublish: @Sendable () throws -> Void
    private let worker: ComputerUseBlockingOperationWorker

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        uploadTimeout: TimeInterval = 60,
        pollInterval: TimeInterval = 2,
        uploadResourceReader: @escaping UploadResourceReader = RemoteDesktopCloudStorage.readUploadState,
        beforePublish: @escaping @Sendable () throws -> Void = {}
    ) {
        // Preserve the caller's canonical realpath spelling. Foundation's
        // resolvingSymlinksInPath maps /private/var back to the /var symlink
        // alias on macOS, which would make strict component checks fail.
        self.homeURL = Self.canonicalExistingURL(homeURL)
        self.uploadTimeout = min(max(uploadTimeout, 0), 60)
        self.pollInterval = min(max(pollInterval, 0.05), 10)
        self.uploadResourceReader = uploadResourceReader
        self.beforePublish = beforePublish
        self.worker = ComputerUseBlockingOperationWorker(label: "com.threadmark.remotedesktop.cloud-storage")
    }

    func providers() throws -> [Provider] {
        try Self.enumerateProviders(homeURL: homeURL)
    }

    static func validateArguments(_ arguments: [String: MCPJSONValue]) throws {
        let base: Set<String> = ["source_path", "provider_id", "relative_folder"]
        let host: Set<String> = ["source_sha256", "destination_path", "existing_destination_sha256"]
        guard Set(arguments.keys).isSubset(of: base.union(host)),
              case .string(let source)? = arguments["source_path"],
              !source.isEmpty, source.utf8.count <= 4_096,
              source.hasPrefix("/"), !source.contains("\0"),
              !source.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              case .string(let provider)? = arguments["provider_id"],
              !provider.isEmpty, provider.utf8.count <= 256,
              case .string(let folder)? = arguments["relative_folder"],
              folder.utf8.count <= 1_024,
              isValidRelativeFolder(folder) else { throw Failure.invalidArguments }
        if let hash = arguments["source_sha256"] {
            guard case .string(let value) = hash, isSHA256(value) else { throw Failure.invalidArguments }
        }
        if let destination = arguments["destination_path"] {
            guard case .string(let value) = destination, value.hasPrefix("/"),
                  value.utf8.count <= 4_096, !value.contains("\0") else { throw Failure.invalidArguments }
        }
        if let existing = arguments["existing_destination_sha256"] {
            switch existing {
            case .null: break
            case .string(let value) where isSHA256(value): break
            default: throw Failure.invalidArguments
            }
        }
    }

    func prepare(arguments: [String: MCPJSONValue]) async throws -> Prepared {
        try Self.validateArguments(arguments)
        try Task.checkCancellation()
        guard case .string(let sourcePath)? = arguments["source_path"],
              case .string(let providerID)? = arguments["provider_id"],
              case .string(let relativeFolder)? = arguments["relative_folder"] else {
            throw Failure.invalidArguments
        }
        let canonical = try await worker.perform(timeout: 20) {
            let providers = try Self.enumerateProviders(homeURL: self.homeURL)
            guard let provider = providers.first(where: { $0.id == providerID }) else { throw Failure.providerUnavailable }
            let roots = Self.approvedSourceRoots(homeURL: self.homeURL)
            let source = URL(fileURLWithPath: sourcePath)
            guard Self.isRegularNonSymlinkFile(source), Self.hasNoSymlinkComponents(source),
                  Self.isContained(source, in: roots) else { throw Failure.sourceUnavailable }
            let targetFolder = try Self.destinationFolder(provider: provider, relativeFolder: relativeFolder)
            let destination = targetFolder.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            guard Self.isContained(destination, in: [provider.rootURL]) else {
                throw Failure.destinationUnavailable
            }
            let sourceHash = try Self.sha256(file: source)
            let existingHash: String?
            if Self.pathExists(destination) {
                guard Self.isRegularNonSymlinkFile(destination) else { throw Failure.destinationUnavailable }
                existingHash = try Self.sha256(file: destination)
            } else {
                existingHash = nil
            }
            return (destination.path, sourceHash, existingHash)
        }
        try Task.checkCancellation()
        var prepared = arguments
        prepared["source_sha256"] = .string(canonical.1)
        prepared["destination_path"] = .string(canonical.0)
        prepared["existing_destination_sha256"] = canonical.2.map(MCPJSONValue.string) ?? .null
        return Prepared(arguments: prepared, needsReplacementApproval: canonical.2 != nil)
    }

    func perform(arguments: [String: MCPJSONValue]) async throws -> MCPToolResult {
        try Self.validateArguments(arguments)
        guard case .string(let sourcePath)? = arguments["source_path"],
              case .string(let providerID)? = arguments["provider_id"],
              case .string(let relativeFolder)? = arguments["relative_folder"],
              case .string(let expectedSourceHash)? = arguments["source_sha256"],
              case .string(let destinationPath)? = arguments["destination_path"],
              let existingValue = arguments["existing_destination_sha256"] else { throw Failure.invalidArguments }
        let expectedExistingHash: String?
        switch existingValue {
        case .null: expectedExistingHash = nil
        case .string(let value) where Self.isSHA256(value): expectedExistingHash = value
        default: throw Failure.invalidArguments
        }
        try Task.checkCancellation()
        let cancellation = CancellationFlag(deadlineUptime: ProcessInfo.processInfo.systemUptime + 45)
        let validated: (URL, Provider, String)
        do {
            validated = try await withTaskCancellationHandler {
                try await worker.perform(timeout: 45) {
                    defer { cancellation.cancel() }
                    let providers = try Self.enumerateProviders(homeURL: self.homeURL)
                    guard let provider = providers.first(where: { $0.id == providerID }) else { throw Failure.providerUnavailable }
                    let roots = Self.approvedSourceRoots(homeURL: self.homeURL)
                    let source = URL(fileURLWithPath: sourcePath)
                    guard Self.isRegularNonSymlinkFile(source), Self.hasNoSymlinkComponents(source),
                          Self.isContained(source, in: roots) else { throw Failure.sourceUnavailable }
                    let targetFolder = try Self.destinationFolder(provider: provider, relativeFolder: relativeFolder)
                    let destination = targetFolder.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                    guard destination.path == destinationPath, Self.isContained(destination, in: [provider.rootURL]) else { throw Failure.destinationUnavailable }
                    try cancellation.check()
                    let actualSourceHash = try Self.sha256(file: source, checking: cancellation)
                    guard actualSourceHash == expectedSourceHash else { throw Failure.sourceChanged }
                    let actualExistingHash: String?
                    if Self.pathExists(destination) {
                        guard Self.isRegularNonSymlinkFile(destination) else { throw Failure.destinationUnavailable }
                        actualExistingHash = try Self.sha256(file: destination)
                    } else { actualExistingHash = nil }
                    guard actualExistingHash == expectedExistingHash else {
                        if expectedExistingHash == nil { throw Failure.destinationExists }
                        throw Failure.destinationChanged
                    }
                    try cancellation.check()
                    try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                    guard Self.isContained(targetFolder, in: [provider.rootURL]),
                          Self.hasNoSymlinkComponents(targetFolder) else { throw Failure.destinationUnavailable }
                    try cancellation.check()

                    var stage: URL?
                    var staged = false
                    defer { if staged, let stage { try? FileManager.default.removeItem(at: stage) } }
                    var coordinationError: NSError?
                    var operationFailure: Failure?
                    let coordinator = NSFileCoordinator(filePresenter: nil)
                    let destinationOptions: NSFileCoordinator.WritingOptions = expectedExistingHash == nil ? [] : .forReplacing
                    coordinator.coordinate(readingItemAt: source, options: .withoutChanges,
                                           writingItemAt: destination, options: destinationOptions,
                                           error: &coordinationError) { coordinatedSource, coordinatedDestination in
                        do {
                            try cancellation.check()
                            guard coordinatedDestination.path == destinationPath,
                                  Self.isContained(coordinatedDestination, in: [provider.rootURL]),
                                  Self.hasNoSymlinkComponents(coordinatedDestination.deletingLastPathComponent()),
                                  coordinatedSource.path == source.path,
                                  Self.isRegularNonSymlinkFile(coordinatedSource),
                                  Self.hasNoSymlinkComponents(coordinatedSource),
                                  Self.isContained(coordinatedSource, in: roots) else { throw Failure.destinationUnavailable }
                            let stageURL = destination.deletingLastPathComponent()
                                .appendingPathComponent(".remote-desktop-\(UUID().uuidString).staged", isDirectory: false)
                            stage = stageURL
                            guard !Self.pathExists(stageURL) else { throw Failure.copyFailed }
                            staged = true
                            try FileManager.default.copyItem(at: coordinatedSource, to: stageURL)
                            try cancellation.check()
                            guard try Self.sha256(file: stageURL, checking: cancellation) == expectedSourceHash else { throw Failure.copyFailed }
                            let nowExists = Self.pathExists(coordinatedDestination)
                            guard Self.isContained(coordinatedDestination, in: [provider.rootURL]),
                                  Self.hasNoSymlinkComponents(coordinatedDestination.deletingLastPathComponent()),
                                  Self.isRegularNonSymlinkFile(stageURL) else { throw Failure.destinationUnavailable }
                            if nowExists && !Self.isRegularNonSymlinkFile(coordinatedDestination) {
                                throw Failure.destinationUnavailable
                            }
                            let nowHash = nowExists ? try Self.sha256(file: coordinatedDestination) : nil
                            guard nowHash == expectedExistingHash else {
                                if expectedExistingHash == nil { throw Failure.destinationExists }
                                throw Failure.destinationChanged
                            }
                            try beforePublish()
                            try cancellation.withActivePublication {
                                if expectedExistingHash == nil {
                                    guard renamex_np(stageURL.path, coordinatedDestination.path, UInt32(RENAME_EXCL)) == 0 else {
                                        throw Failure.destinationExists
                                    }
                                } else {
                                    guard rename(stageURL.path, coordinatedDestination.path) == 0 else { throw Failure.copyFailed }
                                }
                                staged = false
                            }
                        } catch is CancellationError {
                            operationFailure = nil
                        } catch {
                            operationFailure = error as? Failure ?? .copyFailed
                        }
                    }
                    if let operationFailure { throw operationFailure }
                    if let coordinationError { throw Failure.coordinationFailed }
                    try cancellation.check()
                    guard try Self.sha256(file: destination) == expectedSourceHash else { throw Failure.copyFailed }
                    return (destination, provider, actualSourceHash)
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            cancellation.cancel()
            throw error
        }
        try Task.checkCancellation()
        let uploadState = try await waitForUploadState(at: validated.0)
        let state = uploadState.rawValue
        let folder = relativeFolder
        let receipt: MCPJSONValue = .object([
            "status": .string("copied"),
            "provider_id": .string(validated.1.id),
            "provider_label": .string(validated.1.label),
            "relative_folder": .string(folder),
            "destination_path": .string(validated.0.path),
            "source_sha256": .string(validated.2),
            "destination_sha256": .string(try await worker.perform(timeout: 15) { try Self.sha256(file: validated.0) }),
            "upload_state": .string(state),
        ])
        let text: String
        switch uploadState {
        case .uploaded: text = "Saved to \(validated.1.label)\(folder.isEmpty ? "" : " › \(folder)") · uploaded"
        case .unknown: text = "copied, upload status unknown"
        case .uploading: text = "Copied to \(validated.1.label)\(folder.isEmpty ? "" : " › \(folder)"); upload is still pending."
        }
        return try MCPToolResult(text: text, structuredContent: receipt, isError: false, wasTruncated: false)
    }

    static func verified(call: MCPToolCall, result: MCPToolResult, trustedUserPrompt: String) throws -> MCPApprovedActionResult {
        let preparedKeys: Set<String> = ["source_path", "provider_id", "relative_folder", "source_sha256", "destination_path", "existing_destination_sha256"]
        guard call.serverID == RemoteDesktopCloudStorageMCP.serverID,
              call.toolName == RemoteDesktopCloudStorageMCP.toolName,
              call.risk == .approvalRequired,
              Set(call.arguments.keys) == preparedKeys,
              (try? validateArguments(call.arguments)) != nil,
              case .string? = call.arguments["source_sha256"],
              case .string? = call.arguments["destination_path"],
              call.arguments["existing_destination_sha256"] != nil,
              !result.isError, !result.wasTruncated,
              case .object(let fields)? = result.structuredContent,
              Set(fields.keys) == Set(["status", "provider_id", "provider_label", "relative_folder", "destination_path", "source_sha256", "destination_sha256", "upload_state"]),
              fields["status"] == .string("copied"),
              fields["provider_id"] == call.arguments["provider_id"],
              fields["destination_path"] == call.arguments["destination_path"],
              fields["source_sha256"] == call.arguments["source_sha256"],
              fields["destination_sha256"] == call.arguments["source_sha256"],
              fields["relative_folder"] == call.arguments["relative_folder"],
              case .string(let label)? = fields["provider_label"], !label.isEmpty,
              case .string(let uploadState)? = fields["upload_state"], UploadState(rawValue: uploadState) != nil else {
            throw Failure.receiptMismatch
        }
        let response: String
        switch uploadState {
        case UploadState.uploaded.rawValue: response = "Saved to \(label)\(folderSuffix(fields)) · uploaded"
        case UploadState.unknown.rawValue: response = "copied, upload status unknown"
        default: response = "Copied to \(label)\(folderSuffix(fields)); upload is still pending."
        }
        _ = trustedUserPrompt // Receipt proves the exact copy; prompt text is never used as evidence.
        return .init(callDigest: call.canonicalDigest, response: response,
                     completionPromptDigest: try MCPDigest.sha256(of: .string(trustedUserPrompt)))
    }

    private func waitForUploadState(at url: URL) async throws -> UploadState {
        let deadline = ProcessInfo.processInfo.systemUptime + uploadTimeout
        var state = try await readUploadState(at: url, timeout: min(5, max(0.001, uploadTimeout)))
        while state != .uploaded, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            try await Task.sleep(for: .seconds(min(pollInterval, remaining)))
            let readTimeout = min(5, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
            state = try await readUploadState(at: url, timeout: readTimeout)
        }
        try Task.checkCancellation()
        return state
    }

    private func readUploadState(at url: URL, timeout: TimeInterval) async throws -> UploadState {
        do {
            return try await worker.perform(timeout: timeout) {
                try self.uploadResourceReader(url) ?? .unknown
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown
        }
    }

    private static func readUploadState(_ url: URL) throws -> UploadState? {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
        if values.ubiquitousItemIsUploaded == true { return .uploaded }
        if values.ubiquitousItemIsUploading == true || values.ubiquitousItemIsUploaded == false { return .uploading }
        return .unknown
    }

    private static func enumerateProviders(homeURL: URL) throws -> [Provider] {
        let cloudStorage = homeURL.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        var result: [Provider] = []
        if let entries = try? FileManager.default.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      hasNoSymlinkComponents(entry) else { continue }
                let name = entry.lastPathComponent
                result.append(Provider(id: "cloudstorage:" + name, label: name, rootURL: canonicalExistingURL(entry)))
            }
        }
        let iCloud = homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if isDirectoryNonSymlink(iCloud), hasNoSymlinkComponents(iCloud) {
            result.append(Provider(id: "icloud-drive", label: "iCloud Drive", rootURL: canonicalExistingURL(iCloud)))
        }
        return result
    }

    private static func canonicalExistingURL(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: url.hasDirectoryPath)
    }

    private static func approvedSourceRoots(homeURL: URL) -> [URL] {
        ["Documents", "Desktop", "Downloads"].map { homeURL.appendingPathComponent($0, isDirectory: true) }
            + [homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)]
    }

    private static func destinationFolder(provider: Provider, relativeFolder: String) throws -> URL {
        let target = relativeFolder.isEmpty ? provider.rootURL : relativeFolder.split(separator: "/").reduce(provider.rootURL) { $0.appendingPathComponent(String($1), isDirectory: true) }
        guard isContained(target, in: [provider.rootURL]), hasNoSymlinkComponents(provider.rootURL) else {
            throw Failure.destinationUnavailable
        }
        var cursor = provider.rootURL
        for component in relativeFolder.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            if pathExists(cursor) {
                guard isDirectoryNonSymlink(cursor), hasNoSymlinkComponents(cursor) else { throw Failure.destinationUnavailable }
            } else { break }
        }
        return target
    }

    private static func isValidRelativeFolder(_ folder: String) -> Bool {
        if folder.isEmpty { return true }
        guard !folder.hasPrefix("/"), !folder.contains("\\"), !folder.contains("\0") else { return false }
        return folder.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":")
        }
    }

    private static func isContained(_ url: URL, in roots: [URL]) -> Bool {
        let path = url.path
        return roots.contains { root in
            let rootPath = root.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    private static func hasNoSymlinkComponents(_ url: URL) -> Bool {
        let path = url.path
        guard path.hasPrefix("/") else { return false }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            var info = stat()
            guard lstat(cursor.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        }
        return true
    }

    private static func isDirectoryNonSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func sha256(file url: URL) throws -> String {
        try sha256(file: url, checking: nil)
    }

    private static func sha256(file url: URL, checking cancellation: CancellationFlag?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try cancellation?.check()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func folderSuffix(_ fields: [String: MCPJSONValue]) -> String {
        guard case .string(let folder)? = fields["relative_folder"], !folder.isEmpty else { return "" }
        return " › \(folder)"
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private let deadlineUptime: TimeInterval
        init(deadlineUptime: TimeInterval = .infinity) { self.deadlineUptime = deadlineUptime }
        func cancel() { lock.withLock { isCancelled = true } }
        func withActivePublication<Value>(_ operation: () throws -> Value) throws -> Value {
            try lock.withLock {
                if ProcessInfo.processInfo.systemUptime >= deadlineUptime { isCancelled = true }
                guard !isCancelled else { throw CancellationError() }
                return try operation()
            }
        }
        func check() throws {
            let cancelled = lock.withLock { () -> Bool in
                if ProcessInfo.processInfo.systemUptime >= deadlineUptime { isCancelled = true }
                return isCancelled
            }
            if cancelled { throw CancellationError() }
        }
    }
}

actor RemoteDesktopCloudStorageMCPClientSession: MCPClientSessioning {
    private static let logger = Logger(subsystem: "com.threadmark.remotedesktop", category: "CloudStorageMCP")

    private struct ActiveExecution {
        let id: UUID
        let task: Task<MCPToolResult, Error>
    }

    private let processGeneration: UInt64
    private let storage: RemoteDesktopCloudStorage
    private var identity: MCPProcessIdentity?
    private var activeExecution: ActiveExecution?

    init(processGeneration: UInt64, storage: RemoteDesktopCloudStorage = .init()) {
        self.processGeneration = processGeneration
        self.storage = storage
    }

    func start() async throws -> MCPProcessIdentity {
        if let identity { return identity }
        let value = MCPProcessIdentity(serverID: RemoteDesktopCloudStorageMCP.serverID,
                                       processGeneration: processGeneration,
                                       processIdentifier: getpid(),
                                       binaryPath: Bundle.main.bundleURL.path,
                                       launchedAt: Date())
        identity = value
        return value
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] {
        guard identity?.processGeneration == processGeneration else { throw MCPClientError.notRunning }
        let available = try storage.providers()
        return [try MCPAllowedTool(serverID: RemoteDesktopCloudStorageMCP.serverID,
                                   processGeneration: processGeneration,
                                   toolName: RemoteDesktopCloudStorageMCP.toolName,
                                   description: RemoteDesktopCloudStorageMCP.reviewedDescription,
                                   inputSchema: RemoteDesktopCloudStorageMCP.executableSchema(providers: available),
                                   risk: .approvalRequired,
                                   approval: MCPApprovalDisplay(summary: "Save a copy to cloud storage", details: "Copy the selected file into the chosen local sync folder. Existing files require replacement approval.", confirmLabel: "Save copy"))]
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        guard identity?.processGeneration == processGeneration,
              call.serverID == RemoteDesktopCloudStorageMCP.serverID,
              call.processGeneration == processGeneration,
              call.toolName == RemoteDesktopCloudStorageMCP.toolName else { throw MCPClientError.staleCall }
        guard activeExecution == nil else {
            throw MCPClientError.transport("A cloud-storage operation is already active in this session.")
        }
        let id = UUID()
        let task = Task { try await storage.perform(arguments: call.arguments) }
        activeExecution = ActiveExecution(id: id, task: task)
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if activeExecution?.id == id { activeExecution = nil }
            return result
        } catch {
            if activeExecution?.id == id { activeExecution = nil }
            Self.logger.error("Cloud-storage execution failed error_class=\(Self.errorClass(error), privacy: .public)")
            throw error
        }
    }

    func stop() async {
        identity = nil
        activeExecution?.task.cancel()
    }

    private static func errorClass(_ error: Error) -> String {
        if error is CancellationError { return "CancellationError" }
        if let failure = error as? RemoteDesktopCloudStorage.Failure {
            switch failure {
            case .invalidArguments: return "Storage.invalidArguments"
            case .providerUnavailable: return "Storage.providerUnavailable"
            case .sourceUnavailable: return "Storage.sourceUnavailable"
            case .destinationUnavailable: return "Storage.destinationUnavailable"
            case .destinationExists: return "Storage.destinationExists"
            case .destinationChanged: return "Storage.destinationChanged"
            case .sourceChanged: return "Storage.sourceChanged"
            case .coordinationFailed: return "Storage.coordinationFailed"
            case .copyFailed: return "Storage.copyFailed"
            case .receiptMismatch: return "Storage.receiptMismatch"
            }
        }
        if let failure = error as? ComputerUseBlockingOperationWorker.Failure {
            switch failure {
            case .busy: return "Worker.busy"
            case .timedOut: return "Worker.timedOut"
            }
        }
        if let error = error as? MCPClientError {
            switch error {
            case .cancelled: return "MCP.cancelled"
            case .mutationAmbiguous: return "MCP.mutationAmbiguous"
            case .staleCall: return "MCP.staleCall"
            case .notRunning: return "MCP.notRunning"
            default: return "MCP.other"
            }
        }
        return "other"
    }
}
