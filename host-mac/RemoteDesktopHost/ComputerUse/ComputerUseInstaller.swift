import CryptoKit
import Darwin
import Foundation

// Swift imports both `struct flock` and `flock(2)` from Darwin under the same
// name. Referencing the C symbol explicitly avoids the type/function ambiguity
// while retaining BSD whole-file-lock semantics (including separate opens in
// the same process, unlike process-scoped `fcntl` record locks).
@_silgen_name("flock")
private func computerUseFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

actor ComputerUseInstaller {
    nonisolated static let interruptedInstallationMarkerName = ".installation-in-progress"
    nonisolated static let deferredLegacyCleanupMarkerName = ".deferred-legacy-cleanup.json"
    nonisolated static let installationHeadroomBytes: Int64 = 1_000_000_000
    private nonisolated static let processLaunchIdentifier = UUID().uuidString

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

    /// Narrow filesystem seams used to prove fail-safe migration behavior.
    /// Receipt bytes are committed separately through the pinned root file
    /// descriptor; the hook may observe or reject that commit, but never owns
    /// the durable write itself.
    struct Operations: @unchecked Sendable {
        let prepareHardLink: @Sendable (URL, URL) throws -> Void
        let availableCapacity: @Sendable (URL) throws -> Int64?
        let prepareReceiptCommit: @Sendable (Data, URL) throws -> Void
        let prepareDeferredCleanup: @Sendable () throws -> Void
        let durabilityBarrier: @Sendable (String) -> Void

        init(
            createHardLink: @escaping @Sendable (URL, URL) throws -> Void,
            availableCapacity: @escaping @Sendable (URL) throws -> Int64?,
            prepareReceiptCommit: @escaping @Sendable (Data, URL) throws -> Void = { _, _ in },
            prepareDeferredCleanup: @escaping @Sendable () throws -> Void = {},
            durabilityBarrier: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            prepareHardLink = createHardLink
            self.availableCapacity = availableCapacity
            self.prepareReceiptCommit = prepareReceiptCommit
            self.prepareDeferredCleanup = prepareDeferredCleanup
            self.durabilityBarrier = durabilityBarrier
        }

        static func live(fileManager _: FileManager) -> Self {
            return Self(
                createHardLink: { _, _ in },
                availableCapacity: { url in
                    try url.resourceValues(forKeys: [
                        .volumeAvailableCapacityForImportantUsageKey,
                    ]).volumeAvailableCapacityForImportantUsage
                },
                prepareReceiptCommit: { _, _ in },
                prepareDeferredCleanup: {},
                durabilityBarrier: { _ in })
        }
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
        case unsafeManagedRoot

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
            case .unsafeManagedRoot:
                return "The AI model folder changed or is not privately owned by this user. Choose Retry after restoring the app-managed folder."
            }
        }

        private static func format(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        }
    }

    private let manifest: ComputerUseArtifactManifest
    private let legacyManifest: ComputerUseArtifactManifest?
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let legalResourceDirectory: URL?
    private let downloadSession: URLSession
    private let downloadChunkByteCount: Int64
    private let operations: Operations
    private let launchIdentifier: String

    init(
        manifest: ComputerUseArtifactManifest = .current,
        rootDirectory: URL = HostComputerUseManager.modelDirectoryURL,
        fileManager: FileManager = .default,
        legalResourceDirectory: URL? = nil,
        downloadSession: URLSession = .shared,
        downloadChunkByteCount: Int64 = 16 * 1_024 * 1_024,
        legacyManifest: ComputerUseArtifactManifest? = .legacyVisualOnly,
        operations: Operations? = nil,
        launchIdentifier: String = ComputerUseInstaller.processLaunchIdentifier
    ) {
        self.manifest = manifest
        self.legacyManifest = legacyManifest
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.legalResourceDirectory = legalResourceDirectory
        self.downloadSession = downloadSession
        self.downloadChunkByteCount = max(1, downloadChunkByteCount)
        self.operations = operations ?? .live(fileManager: fileManager)
        self.launchIdentifier = launchIdentifier
    }

    nonisolated static func installationLockURL(forRootDirectory root: URL) -> URL {
        root.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(stableInstallationLockName(for: root))
    }

    private nonisolated static func stableInstallationLockName(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return ".computer-use-installation-\(digest).lock"
    }

    /// Pins the app-managed root by descriptor. Mutating helpers below accept
    /// only validated relative components and use the *at(2) family throughout;
    /// pathname checks are defense-in-depth and never select a write target.
    private class ManagedRootPin: @unchecked Sendable {
        let rootDirectory: URL
        let descriptor: Int32
        fileprivate let device: dev_t
        fileprivate let inode: ino_t
        fileprivate let owner: uid_t

        init(rootDirectory: URL, descriptor: Int32, status: stat) {
            self.rootDirectory = rootDirectory
            self.descriptor = descriptor
            device = status.st_dev
            inode = status.st_ino
            owner = status.st_uid
        }

        deinit {
            Darwin.close(descriptor)
        }

        static func openExisting(rootDirectory: URL) throws -> ManagedRootPin {
            let root = rootDirectory.standardizedFileURL
            guard root.deletingLastPathComponent().path != root.path else {
                throw InstallError.unsafeManagedRoot
            }
            let descriptor = root.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw InstallError.unsafeManagedRoot
            }
            var shouldCloseDescriptor = true
            defer {
                if shouldCloseDescriptor { Darwin.close(descriptor) }
            }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            let pin = ManagedRootPin(
                rootDirectory: root,
                descriptor: descriptor,
                status: status)
            shouldCloseDescriptor = false
            try pin.validate()
            return pin
        }

        func validate() throws {
            try validateDescriptor()
            var pathStatus = stat()
            let result = rootDirectory.path.withCString {
                Darwin.lstat($0, &pathStatus)
            }
            guard result == 0,
                  pathStatus.st_mode & S_IFMT == S_IFDIR,
                  pathStatus.st_dev == device,
                  pathStatus.st_ino == inode,
                  pathStatus.st_uid == owner else {
                throw InstallError.unsafeManagedRoot
            }
        }

        fileprivate func validateDescriptor() throws {
            var descriptorStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
                  descriptorStatus.st_mode & S_IFMT == S_IFDIR,
                  descriptorStatus.st_dev == device,
                  descriptorStatus.st_ino == inode,
                  descriptorStatus.st_uid == owner,
                  owner == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
        }

        func openDirectory(
            _ components: [String],
            create: Bool = false
        ) throws -> Int32 {
            try validateDescriptor()
            var current = Darwin.dup(descriptor)
            guard current >= 0 else { throw Self.posixError() }
            var keepCurrent = false
            defer { if !keepCurrent { Darwin.close(current) } }
            for component in components {
                try Self.validateLeafName(component)
                if create {
                    let result = component.withCString {
                        Darwin.mkdirat(current, $0, S_IRWXU)
                    }
                    if result == 0 {
                        try Self.synchronize(current)
                    } else if errno != EEXIST {
                        throw Self.posixError()
                    }
                }
                let next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw InstallError.unsafeManagedRoot }
                var status = stat()
                guard Darwin.fstat(next, &status) == 0,
                      status.st_mode & S_IFMT == S_IFDIR,
                      status.st_uid == Darwin.geteuid() else {
                    Darwin.close(next)
                    throw InstallError.unsafeManagedRoot
                }
                Darwin.close(current)
                current = next
            }
            keepCurrent = true
            return current
        }

        func itemStatus(
            directory components: [String] = [],
            name: String
        ) throws -> stat? {
            try Self.validateLeafName(name)
            let directory = try openDirectory(components)
            defer { Darwin.close(directory) }
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return status }
            if errno == ENOENT { return nil }
            throw Self.posixError()
        }

        func openRegularFile(
            directory components: [String] = [],
            name: String,
            writable: Bool = false
        ) throws -> Int32 {
            try Self.validateLeafName(name)
            let directory = try openDirectory(components)
            defer { Darwin.close(directory) }
            let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
            let file = name.withCString { Darwin.openat(directory, $0, flags) }
            guard file >= 0 else { throw Self.posixError() }
            var shouldClose = true
            defer { if shouldClose { Darwin.close(file) } }
            var fileStatus = stat()
            var nameStatus = stat()
            let nameResult = name.withCString {
                Darwin.fstatat(directory, $0, &nameStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard Darwin.fstat(file, &fileStatus) == 0,
                  nameResult == 0,
                  fileStatus.st_mode & S_IFMT == S_IFREG,
                  nameStatus.st_mode & S_IFMT == S_IFREG,
                  fileStatus.st_uid == Darwin.geteuid(),
                  nameStatus.st_uid == Darwin.geteuid(),
                  fileStatus.st_dev == nameStatus.st_dev,
                  fileStatus.st_ino == nameStatus.st_ino else {
                throw InstallError.unsafeManagedRoot
            }
            shouldClose = false
            return file
        }

        func readData(
            directory components: [String] = [],
            name: String
        ) throws -> Data {
            let file = try openRegularFile(directory: components, name: name)
            defer { Darwin.close(file) }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(file, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                guard count > 0 else { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            return result
        }

        func writeAtomically(
            _ data: Data,
            directory components: [String] = [],
            name: String
        ) throws {
            try Self.validateLeafName(name)
            let directory = try openDirectory(components)
            defer { Darwin.close(directory) }
            if let existing = try itemStatus(directory: components, name: name),
               existing.st_mode & S_IFMT != S_IFREG {
                throw InstallError.unsafeManagedRoot
            }
            let temporaryName = ".\(name).\(UUID().uuidString).tmp"
            let temporaryDescriptor = temporaryName.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
            }
            guard temporaryDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var renamed = false
            defer {
                Darwin.close(temporaryDescriptor)
                if !renamed {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(directory, $0, 0)
                    }
                }
            }

            try data.withUnsafeBytes { rawBuffer in
                guard var address = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(temporaryDescriptor, address, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard written > 0 else { throw POSIXError(.EIO) }
                    remaining -= written
                    address = address.advanced(by: written)
                }
            }
            try Self.synchronize(temporaryDescriptor)
            let renameResult = temporaryName.withCString { temporaryPath in
                name.withCString { destinationPath in
                    Darwin.renameat(
                        directory,
                        temporaryPath,
                        directory,
                        destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            renamed = true
            try Self.synchronize(directory)
            try validateDescriptor()
        }

        func removeLeafIfPresent(
            directory components: [String] = [],
            name: String
        ) throws {
            try Self.validateLeafName(name)
            let directory = try openDirectory(components)
            defer { Darwin.close(directory) }
            if let status = try itemStatus(directory: components, name: name) {
                guard status.st_mode & S_IFMT == S_IFREG,
                      status.st_uid == Darwin.geteuid() else {
                    throw InstallError.unsafeManagedRoot
                }
            } else {
                return
            }
            let result = name.withCString {
                Darwin.unlinkat(directory, $0, 0)
            }
            guard result == 0 else { throw Self.posixError() }
            try Self.synchronize(directory)
            try validateDescriptor()
        }

        /// Removes only the named entry and never follows it. This is used for
        /// resumable staging artifacts, where an interrupted/corrupt regular
        /// file or a hostile symlink must be discarded without touching the
        /// symlink target. Recursive tree deletion remains stricter and rejects
        /// symlinks outright.
        func removeArtifactLeafIfPresent(
            directory components: [String],
            name: String
        ) throws {
            try Self.validateLeafName(name)
            let directory = try openDirectory(components)
            defer { Darwin.close(directory) }
            guard let status = try itemStatus(directory: components, name: name) else {
                return
            }
            guard (status.st_mode & S_IFMT == S_IFREG
                    || status.st_mode & S_IFMT == S_IFLNK),
                  status.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            let result = name.withCString { Darwin.unlinkat(directory, $0, 0) }
            guard result == 0 else { throw Self.posixError() }
            try Self.synchronize(directory)
            try validateDescriptor()
        }

        func setDataOnly(
            directory components: [String],
            name: String
        ) throws {
            let file = try openRegularFile(
                directory: components,
                name: name,
                writable: true)
            defer { Darwin.close(file) }
            var status = stat()
            guard Darwin.fstat(file, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == Darwin.geteuid(),
                  status.st_nlink >= 1 else {
                throw InstallError.unsafeManagedRoot
            }
            if status.st_nlink > 1 {
                // Legacy visual-model reuse intentionally shares immutable
                // data inodes across version names. Never chmod through one
                // of those names, because permissions belong to the inode and
                // would change for every alias. Verified non-executable data
                // is safe to retain with its existing read/write mode.
                guard status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0 else {
                    throw InstallError.unsafeManagedRoot
                }
                try Self.synchronize(file)
                return
            }
            guard Darwin.fchmod(file, S_IRUSR | S_IWUSR) == 0 else {
                throw Self.posixError()
            }
            try Self.synchronize(file)
        }

        func createHardLink(
            sourceDirectory: [String],
            sourceName: String,
            destinationDirectory: [String],
            destinationName: String
        ) throws {
            try Self.validateLeafName(sourceName)
            try Self.validateLeafName(destinationName)
            let source = try openDirectory(sourceDirectory)
            defer { Darwin.close(source) }
            let destination = try openDirectory(destinationDirectory)
            defer { Darwin.close(destination) }
            var sourceStatus = stat()
            let sourceResult = sourceName.withCString {
                Darwin.fstatat(source, $0, &sourceStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard sourceResult == 0,
                  sourceStatus.st_mode & S_IFMT == S_IFREG,
                  sourceStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            let linkResult = sourceName.withCString { sourcePath in
                destinationName.withCString { destinationPath in
                    Darwin.linkat(source, sourcePath, destination, destinationPath, 0)
                }
            }
            guard linkResult == 0 else { throw Self.posixError() }
            var destinationStatus = stat()
            let destinationResult = destinationName.withCString {
                Darwin.fstatat(
                    destination,
                    $0,
                    &destinationStatus,
                    AT_SYMLINK_NOFOLLOW)
            }
            guard destinationResult == 0,
                  destinationStatus.st_mode & S_IFMT == S_IFREG,
                  destinationStatus.st_uid == Darwin.geteuid(),
                  destinationStatus.st_dev == sourceStatus.st_dev,
                  destinationStatus.st_ino == sourceStatus.st_ino else {
                _ = destinationName.withCString {
                    Darwin.unlinkat(destination, $0, 0)
                }
                throw InstallError.unsafeManagedRoot
            }
            try Self.synchronize(destination)
        }

        func renameDirectory(
            parent components: [String],
            from sourceName: String,
            to destinationName: String
        ) throws {
            try Self.validateLeafName(sourceName)
            try Self.validateLeafName(destinationName)
            let parent = try openDirectory(components)
            defer { Darwin.close(parent) }
            var sourceStatus = stat()
            let sourceResult = sourceName.withCString {
                Darwin.fstatat(parent, $0, &sourceStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard sourceResult == 0,
                  sourceStatus.st_mode & S_IFMT == S_IFDIR,
                  sourceStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            let result = sourceName.withCString { source in
                destinationName.withCString { destination in
                    Darwin.renameat(parent, source, parent, destination)
                }
            }
            guard result == 0 else { throw Self.posixError() }
            try Self.synchronize(parent)
        }

        func removeTreeIfPresent(
            parent components: [String],
            name: String
        ) throws {
            try Self.validateLeafName(name)
            let parent = try openDirectory(components)
            defer { Darwin.close(parent) }
            var status = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statusResult != 0, errno == ENOENT { return }
            guard statusResult == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            // Validate the complete tree before the first unlink so a static
            // unsafe node cannot cause a partially completed uninstall. The
            // deletion pass repeats all checks to close swap races.
            try Self.validateDirectoryTree(parent: parent, name: name)
            try Self.removeDirectoryTree(parent: parent, name: name)
            try validateDescriptor()
        }

        func validateTreeIfPresent(
            parent components: [String],
            name: String
        ) throws {
            try Self.validateLeafName(name)
            let parent = try openDirectory(components)
            defer { Darwin.close(parent) }
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0, errno == ENOENT { return }
            guard result == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            try Self.validateDirectoryTree(parent: parent, name: name)
        }

        func synchronizeDirectory(_ components: [String]) throws {
            let directory = try openDirectory(components)
            defer { Darwin.close(directory) }
            try Self.synchronize(directory)
        }

        func directoryExists(_ components: [String]) -> Bool {
            guard let directory = try? openDirectory(components) else { return false }
            Darwin.close(directory)
            return true
        }

        fileprivate static func synchronize(_ descriptor: Int32) throws {
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
        }

        private static func removeDirectoryTree(
            parent: Int32,
            name: String
        ) throws {
            let directory = name.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard directory >= 0 else { throw InstallError.unsafeManagedRoot }
            defer { Darwin.close(directory) }
            var openedStatus = stat()
            guard Darwin.fstat(directory, &openedStatus) == 0,
                  openedStatus.st_mode & S_IFMT == S_IFDIR,
                  openedStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }

            for childName in try directoryEntryNames(directory) {
                try validateLeafName(childName)
                var childStatus = stat()
                let result = childName.withCString {
                    Darwin.fstatat(directory, $0, &childStatus, AT_SYMLINK_NOFOLLOW)
                }
                guard result == 0,
                      childStatus.st_uid == Darwin.geteuid() else {
                    throw InstallError.unsafeManagedRoot
                }
                switch childStatus.st_mode & S_IFMT {
                case S_IFREG:
                    let unlinkResult = childName.withCString {
                        Darwin.unlinkat(directory, $0, 0)
                    }
                    guard unlinkResult == 0 else { throw posixError() }
                case S_IFDIR:
                    try removeDirectoryTree(parent: directory, name: childName)
                default:
                    // In particular, never traverse or silently remove a
                    // symlink introduced into an app-managed tree.
                    throw InstallError.unsafeManagedRoot
                }
            }
            try synchronize(directory)

            var namedStatus = stat()
            let namedResult = name.withCString {
                Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard namedResult == 0,
                  namedStatus.st_mode & S_IFMT == S_IFDIR,
                  namedStatus.st_dev == openedStatus.st_dev,
                  namedStatus.st_ino == openedStatus.st_ino,
                  namedStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            let removeResult = name.withCString {
                Darwin.unlinkat(parent, $0, AT_REMOVEDIR)
            }
            guard removeResult == 0 else { throw posixError() }
            try synchronize(parent)
        }

        private static func validateDirectoryTree(
            parent: Int32,
            name: String
        ) throws {
            let directory = name.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard directory >= 0 else { throw InstallError.unsafeManagedRoot }
            defer { Darwin.close(directory) }
            var openedStatus = stat()
            guard Darwin.fstat(directory, &openedStatus) == 0,
                  openedStatus.st_mode & S_IFMT == S_IFDIR,
                  openedStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            for childName in try directoryEntryNames(directory) {
                try validateLeafName(childName)
                var status = stat()
                let result = childName.withCString {
                    Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard result == 0,
                      status.st_uid == Darwin.geteuid() else {
                    throw InstallError.unsafeManagedRoot
                }
                switch status.st_mode & S_IFMT {
                case S_IFREG:
                    break
                case S_IFDIR:
                    try validateDirectoryTree(parent: directory, name: childName)
                default:
                    throw InstallError.unsafeManagedRoot
                }
            }
            var namedStatus = stat()
            let namedResult = name.withCString {
                Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard namedResult == 0,
                  namedStatus.st_mode & S_IFMT == S_IFDIR,
                  namedStatus.st_dev == openedStatus.st_dev,
                  namedStatus.st_ino == openedStatus.st_ino,
                  namedStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
        }

        private static func directoryEntryNames(_ directory: Int32) throws -> [String] {
            let streamDescriptor = Darwin.dup(directory)
            guard streamDescriptor >= 0 else { throw posixError() }
            guard let stream = Darwin.fdopendir(streamDescriptor) else {
                Darwin.close(streamDescriptor)
                throw posixError()
            }
            var names: [String] = []
            errno = 0
            while let entry = Darwin.readdir(stream) {
                let childName = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if childName != "." && childName != ".." { names.append(childName) }
                errno = 0
            }
            let readError = errno
            Darwin.closedir(stream)
            guard readError == 0 else {
                errno = readError
                throw posixError()
            }
            return names
        }

        fileprivate static func validateLeafName(_ name: String) throws {
            guard !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.utf8.contains(0) else {
                throw InstallError.unsafeManagedRoot
            }
        }

        fileprivate static func posixError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private final class InstallationTransactionLease: ManagedRootPin, @unchecked Sendable {
        private let parentDescriptor: Int32
        private let parentDirectory: URL
        private let parentDevice: dev_t
        private let parentInode: ino_t
        private let rootLeafName: String
        private let lockName: String
        private let lockDescriptor: Int32
        private let lockDevice: dev_t
        private let lockInode: ino_t

        init(
            rootDirectory: URL,
            rootDescriptor: Int32,
            rootStatus: stat,
            parentDescriptor: Int32,
            parentDirectory: URL,
            parentStatus: stat,
            rootLeafName: String,
            lockName: String,
            lockDescriptor: Int32,
            lockStatus: stat
        ) {
            self.parentDescriptor = parentDescriptor
            self.parentDirectory = parentDirectory
            parentDevice = parentStatus.st_dev
            parentInode = parentStatus.st_ino
            self.rootLeafName = rootLeafName
            self.lockName = lockName
            self.lockDescriptor = lockDescriptor
            lockDevice = lockStatus.st_dev
            lockInode = lockStatus.st_ino
            super.init(
                rootDirectory: rootDirectory,
                descriptor: rootDescriptor,
                status: rootStatus)
        }

        deinit {
            _ = computerUseFlock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            Darwin.close(parentDescriptor)
        }

        static func acquire(
            rootDirectory: URL,
            fileManager: FileManager
        ) async throws -> InstallationTransactionLease {
            try Task.checkCancellation()
            let root = rootDirectory.standardizedFileURL
            let parent = root.deletingLastPathComponent().standardizedFileURL
            guard parent.path != root.path else {
                throw InstallError.unsafeManagedRoot
            }
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true)
            let parentDescriptor = parent.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentDescriptor >= 0 else { throw InstallError.unsafeManagedRoot }
            var shouldCloseParent = true
            defer { if shouldCloseParent { Darwin.close(parentDescriptor) } }
            var parentStatus = stat()
            guard Darwin.fstat(parentDescriptor, &parentStatus) == 0,
                  parentStatus.st_mode & S_IFMT == S_IFDIR,
                  parentStatus.st_uid == Darwin.geteuid() else {
                throw InstallError.unsafeManagedRoot
            }
            let rootLeafName = root.lastPathComponent
            try ManagedRootPin.validateLeafName(rootLeafName)
            let created = rootLeafName.withCString {
                Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
            }
            if created == 0 {
                try ManagedRootPin.synchronize(parentDescriptor)
            } else if errno != EEXIST {
                throw ManagedRootPin.posixError()
            }

            let rootDescriptor = rootLeafName.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard rootDescriptor >= 0 else {
                throw InstallError.unsafeManagedRoot
            }
            var shouldCloseRoot = true
            defer {
                if shouldCloseRoot { Darwin.close(rootDescriptor) }
            }
            var rootStatus = stat()
            guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
                  rootStatus.st_mode & S_IFMT == S_IFDIR,
                  rootStatus.st_uid == Darwin.geteuid(),
                  Darwin.fchmod(rootDescriptor, S_IRWXU) == 0 else {
                throw InstallError.unsafeManagedRoot
            }
            try ManagedRootPin.synchronize(rootDescriptor)

            let lockName = ComputerUseInstaller.stableInstallationLockName(for: root)
            let lockDescriptor = lockName.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
            }
            guard lockDescriptor >= 0 else {
                throw InstallError.unsafeManagedRoot
            }
            var shouldCloseLock = true
            defer {
                if shouldCloseLock { Darwin.close(lockDescriptor) }
            }
            var lockStatus = stat()
            guard Darwin.fstat(lockDescriptor, &lockStatus) == 0,
                  lockStatus.st_mode & S_IFMT == S_IFREG,
                  lockStatus.st_uid == Darwin.geteuid(),
                  lockStatus.st_nlink == 1,
                  Darwin.fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw InstallError.unsafeManagedRoot
            }
            try ManagedRootPin.synchronize(lockDescriptor)
            try ManagedRootPin.synchronize(parentDescriptor)

            while computerUseFlock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            let lease = InstallationTransactionLease(
                rootDirectory: root,
                rootDescriptor: rootDescriptor,
                rootStatus: rootStatus,
                parentDescriptor: parentDescriptor,
                parentDirectory: parent,
                parentStatus: parentStatus,
                rootLeafName: rootLeafName,
                lockName: lockName,
                lockDescriptor: lockDescriptor,
                lockStatus: lockStatus)
            shouldCloseRoot = false
            shouldCloseParent = false
            shouldCloseLock = false
            try lease.validate()
            return lease
        }

        override func validate() throws {
            try validateDescriptor()
            var parentDescriptorStatus = stat()
            var parentPathStatus = stat()
            let parentPathResult = parentDirectory.path.withCString {
                Darwin.lstat($0, &parentPathStatus)
            }
            var rootStatus = stat()
            let rootResult = rootLeafName.withCString {
                Darwin.fstatat(
                    parentDescriptor,
                    $0,
                    &rootStatus,
                    AT_SYMLINK_NOFOLLOW)
            }
            var lockStatus = stat()
            let result = lockName.withCString {
                Darwin.fstatat(
                    parentDescriptor,
                    $0,
                    &lockStatus,
                    AT_SYMLINK_NOFOLLOW)
            }
            guard Darwin.fstat(parentDescriptor, &parentDescriptorStatus) == 0,
                  parentPathResult == 0,
                  parentDescriptorStatus.st_mode & S_IFMT == S_IFDIR,
                  parentDescriptorStatus.st_dev == parentDevice,
                  parentDescriptorStatus.st_ino == parentInode,
                  parentDescriptorStatus.st_uid == Darwin.geteuid(),
                  parentPathStatus.st_mode & S_IFMT == S_IFDIR,
                  parentPathStatus.st_dev == parentDevice,
                  parentPathStatus.st_ino == parentInode,
                  parentPathStatus.st_uid == Darwin.geteuid(),
                  rootResult == 0,
                  rootStatus.st_mode & S_IFMT == S_IFDIR,
                  rootStatus.st_dev == device,
                  rootStatus.st_ino == inode,
                  rootStatus.st_uid == Darwin.geteuid(),
                  result == 0,
                  lockStatus.st_mode & S_IFMT == S_IFREG,
                  lockStatus.st_dev == lockDevice,
                  lockStatus.st_ino == lockInode,
                  lockStatus.st_uid == Darwin.geteuid(),
                  lockStatus.st_nlink == 1,
                  lockStatus.st_mode & 0o777 == S_IRUSR | S_IWUSR else {
                throw InstallError.unsafeManagedRoot
            }
        }
    }

    private struct DeferredLegacyCleanup: Codable, Equatable, Sendable {
        let replacementInstallationVersion: String
        let legacyInstallationVersion: String
        let createdByLaunchIdentifier: String
    }

    func currentInstallation() async -> ComputerUseInstallationReceipt? {
        guard let rootPin = try? ManagedRootPin.openExisting(
            rootDirectory: rootDirectory) else {
            return nil
        }

        // Ordinary status remains read-only. A narrowly scoped exception is a
        // cleanup record created by an earlier process launch: acquire the same
        // interprocess transaction lock, verify the full replacement once
        // under that lock, and only then retire the legacy package.
        guard deferredCleanupWasCreatedByEarlierLaunch(rootPin: rootPin) else {
            return currentInstallation(using: rootPin)
        }
        guard let lease = try? await acquireInstallationLease() else {
            return currentInstallation(using: rootPin)
        }
        guard let lockedReceipt = currentInstallation(using: lease) else {
            return nil
        }
        do {
            try performDeferredLegacyCleanup(
                afterVerifying: lockedReceipt,
                lease: lease)
            return lockedReceipt
        } catch {
            return (try? lease.validate()) == nil ? nil : lockedReceipt
        }
    }

    private func deferredCleanupWasCreatedByEarlierLaunch(
        rootPin: ManagedRootPin
    ) -> Bool {
        guard (try? rootPin.validate()) != nil,
              let data = try? rootPin.readData(
                name: Self.deferredLegacyCleanupMarkerName),
              let cleanup = try? JSONDecoder().decode(
                DeferredLegacyCleanup.self,
                from: data),
              cleanup.replacementInstallationVersion
                == manifest.installationVersion,
              cleanup.createdByLaunchIdentifier != launchIdentifier,
              (try? rootPin.validate()) != nil else {
            return false
        }
        return true
    }

    private func currentInstallation(
        using rootPin: ManagedRootPin
    ) -> ComputerUseInstallationReceipt? {
        guard (try? rootPin.validate()) != nil,
              let data = try? rootPin.readData(name: receiptURL.lastPathComponent),
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
        guard (receipt.modelDirectory as NSString).isAbsolutePath,
              modelDirectory.standardizedFileURL == activeModelDirectory.standardizedFileURL else {
            return nil
        }
        for artifact in manifest.modelArtifacts {
            guard (try? verifyReadOnly(
                artifact,
                directoryComponents: activeModelComponents,
                rootPin: rootPin)) != nil else {
                return nil
            }
        }
        guard (try? rootPin.validate()) != nil else { return nil }
        return receipt
    }

    /// A marker is written only after a user-requested setup passes preflight.
    /// It survives an abrupt process exit, allowing the next host launch to
    /// resume durable model bytes without another tap on the mobile client.
    func interruptedInstallationExists() -> Bool {
        guard let rootPin = try? ManagedRootPin.openExisting(
            rootDirectory: rootDirectory),
              (try? rootPin.validate()) != nil else {
            return false
        }
        guard let status = try? rootPin.itemStatus(
            name: Self.interruptedInstallationMarkerName) else {
            return false
        }
        return status.st_mode & S_IFMT == S_IFREG
    }

    func clearInterruptedInstallationMarker() async {
        guard fileManager.fileExists(atPath: rootDirectory.path),
              let lease = try? await acquireInstallationLease() else {
            return
        }
        try? lease.removeLeafIfPresent(name: Self.interruptedInstallationMarkerName)
    }

    func install(
        progress: @MainActor @Sendable @escaping (Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt {
        let lease = try await acquireInstallationLease()
        try lease.validate()

        if let existing = currentInstallation(using: lease) {
            for artifact in manifest.modelArtifacts {
                try lease.validate()
                try lease.setDataOnly(
                    directory: activeModelComponents,
                    name: artifact.fileName)
            }
            try installLegalDocuments(
                directoryComponents: activeModelComponents,
                rootPin: lease)
            try performDeferredLegacyCleanup(
                afterVerifying: existing,
                lease: lease)
            try lease.removeLeafIfPresent(
                name: Self.interruptedInstallationMarkerName)
            try lease.validate()
            await progress(Update(
                phase: .ready,
                fraction: 1,
                detail: "Local AI models are installed"))
            return existing
        }

        try Task.checkCancellation()
        // The interprocess lease is already held here. Capturing the legacy
        // plan under that lease prevents another installer instance from
        // committing a new receipt while this transaction retains stale
        // rollback state.
        let legacyDirectoryForCleanup = try legacyReusePlan(rootPin: lease)?
            .modelDirectory
        await progress(Update(
            phase: .preparing,
            fraction: 0,
            detail: "Checking this Mac…"))
        try lease.validate()
        try preflight(rootPin: lease)
        try lease.writeAtomically(
            Data("installing\n".utf8),
            name: Self.interruptedInstallationMarkerName)
        operations.durabilityBarrier("installation-marker")

        let modelDirectory = try await installModel(
            progress: progress,
            lease: lease)
        try Task.checkCancellation()
        try lease.validate()

        await progress(Update(
            phase: .verifying,
            fraction: 0.96,
            detail: "Verifying local AI models…"))
        for artifact in manifest.modelArtifacts {
            try verify(
                artifact,
                directoryComponents: activeModelComponents,
                rootPin: lease)
            try lease.validate()
        }
        try installLegalDocuments(
            directoryComponents: activeModelComponents,
            rootPin: lease)
        try lease.synchronizeDirectory(activeModelComponents)
        operations.durabilityBarrier("model-directory")

        let receipt = ComputerUseInstallationReceipt(
            installationVersion: manifest.installationVersion,
            modelVariant: manifest.modelVariant,
            modelDirectory: modelDirectory.path,
            installedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let receiptData = try encoder.encode(receipt)
        do {
            try operations.prepareReceiptCommit(receiptData, receiptURL)
            try lease.validate()
        } catch {
            // This hook runs before the atomic writer, so the prior receipt is
            // still authoritative and the uncommitted replacement can be
            // rolled back while the canonical root remains pinned.
            if (try? lease.validate()) != nil {
                try? lease.removeTreeIfPresent(
                    parent: modelsComponents,
                    name: manifest.installationVersion)
            }
            throw error
        }
        // Once renameat has made a new receipt visible, any later directory
        // fsync error has ambiguous crash durability. Never roll back the model
        // after this point: retaining both model generations is safe whether
        // the old or new receipt survives a power loss.
        try lease.writeAtomically(
            receiptData,
            name: receiptURL.lastPathComponent)
        operations.durabilityBarrier("receipt")
        try lease.validate()

        if let legacyDirectoryForCleanup,
           legacyDirectoryForCleanup.standardizedFileURL
            != modelDirectory.standardizedFileURL,
           let legacyManifest {
            let cleanup = DeferredLegacyCleanup(
                replacementInstallationVersion: manifest.installationVersion,
                legacyInstallationVersion: legacyManifest.installationVersion,
                createdByLaunchIdentifier: launchIdentifier)
            let cleanupEncoder = JSONEncoder()
            cleanupEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Cleanup is not eligible until this exact marker and its parent
            // entry have both crossed the strict descriptor-relative barrier.
            try lease.writeAtomically(
                cleanupEncoder.encode(cleanup),
                name: Self.deferredLegacyCleanupMarkerName)
            operations.durabilityBarrier("deferred-cleanup-marker")
        }
        // Legacy data intentionally survives this launch. Only a distinct
        // later launch that re-hashes the replacement package may remove it.
        try lease.removeLeafIfPresent(
            name: Self.interruptedInstallationMarkerName)
        operations.durabilityBarrier("installation-marker-removed")
        try lease.validate()

        await progress(Update(
            phase: .ready,
            fraction: 1,
            detail: "Local AI models are installed"))
        return receipt
    }

    func removeInstallation() async throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        let lease = try await acquireInstallationLease()
        try lease.validate()
        try lease.validateTreeIfPresent(
            parent: [],
            name: modelsDirectory.lastPathComponent)
        try lease.validateTreeIfPresent(
            parent: [],
            name: legacyAdaptersDirectory.lastPathComponent)
        try lease.removeLeafIfPresent(name: receiptURL.lastPathComponent)
        try removeManagedDirectoryIfPresent(
            named: modelsDirectory.lastPathComponent,
            rootPin: lease)
        try removeManagedDirectoryIfPresent(
            named: legacyAdaptersDirectory.lastPathComponent,
            rootPin: lease)
        try lease.removeLeafIfPresent(
            name: Self.deferredLegacyCleanupMarkerName)
        try lease.removeLeafIfPresent(
            name: Self.interruptedInstallationMarkerName)
        try lease.validate()
    }

    private var receiptURL: URL {
        rootDirectory.appendingPathComponent("active-installation.json")
    }

    private var interruptedInstallationMarkerURL: URL {
        rootDirectory.appendingPathComponent(Self.interruptedInstallationMarkerName)
    }

    private var deferredLegacyCleanupMarkerURL: URL {
        rootDirectory.appendingPathComponent(Self.deferredLegacyCleanupMarkerName)
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

    private var modelsComponents: [String] { [modelsDirectory.lastPathComponent] }

    private var activeModelComponents: [String] {
        modelsComponents + [manifest.installationVersion]
    }

    private var stagingDirectoryName: String {
        ".\(manifest.installationVersion)-staging"
    }

    private var stagingComponents: [String] {
        modelsComponents + [stagingDirectoryName]
    }

    private func acquireInstallationLease() async throws
        -> InstallationTransactionLease {
        try await InstallationTransactionLease.acquire(
            rootDirectory: rootDirectory,
            fileManager: fileManager)
    }

    func preflight() async throws {
        let lease = try await acquireInstallationLease()
        try preflight(rootPin: lease)
    }

    private func preflight(rootPin: ManagedRootPin) throws {
        #if !arch(arm64)
        throw InstallError.unsupportedProcessor
        #endif

        try rootPin.validate()
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
        let reusableBytes = try legacyReusePlan(rootPin: rootPin)?
            .reusableByteCount ?? 0
        let totalBytes = manifest.modelArtifacts.reduce(Int64(0)) {
            $0 + $1.byteCount
        }
        try ensureDiskCapacity(
            forModelBytes: max(0, totalBytes - reusableBytes),
            at: capacityProbeURL)
        try rootPin.validate()
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
        let lease = try await acquireInstallationLease()
        return try await installModel(progress: progress, lease: lease)
    }

    private func installModel(
        progress: @MainActor @Sendable @escaping (Update) -> Void,
        lease: InstallationTransactionLease
    ) async throws -> URL {
        try lease.validate()
        try validateManifest()
        let artifacts = manifest.modelArtifacts
        if artifacts.allSatisfy({
            (try? verifyReadOnly(
                $0,
                directoryComponents: activeModelComponents,
                rootPin: lease)) != nil
        }) {
            for artifact in artifacts {
                try lease.setDataOnly(
                    directory: activeModelComponents,
                    name: artifact.fileName)
            }
            await reportModelProgress(
                downloadedByteCount: artifacts.reduce(0) { $0 + $1.byteCount },
                artifacts: artifacts,
                progress: progress)
            try lease.validate()
            return activeModelDirectory
        }

        // Each range-complete chunk is durable in this directory. An
        // interrupted process resumes from real on-disk bytes rather than
        // restarting a multi-gigabyte transfer.
        let stagingDescriptor = try lease.openDirectory(
            stagingComponents,
            create: true)
        Darwin.close(stagingDescriptor)
        try lease.validate()

        var completedArtifacts = Set<String>()
        var durableArtifactByteCounts: [String: Int64] = [:]
        for artifact in artifacts where artifactLooksComplete(
            artifact,
            directoryComponents: stagingComponents,
            rootPin: lease) {
            do {
                try verify(
                    artifact,
                    directoryComponents: stagingComponents,
                    rootPin: lease)
                try lease.setDataOnly(
                    directory: stagingComponents,
                    name: artifact.fileName)
                completedArtifacts.insert(artifact.fileName)
                durableArtifactByteCounts[artifact.fileName] = artifact.byteCount
            } catch {
                // A same-size partial or corrupt artifact cannot be resumed
                // safely. Retain every other verified artifact in staging.
                try lease.removeArtifactLeafIfPresent(
                    directory: stagingComponents,
                    name: artifact.fileName)
            }
        }

        // Reuse is all-or-safe-fallback: only an exact legacy receipt and all
        // three exact, hash-verified visual artifacts are eligible. A failed
        // link or post-link inode check removes links created by this attempt,
        // recalculates required download storage, and continues over HTTPS.
        if let reusePlan = try legacyReusePlan(rootPin: lease) {
            var linkedArtifactNames: [String] = []
            do {
                for artifact in reusePlan.artifacts
                    where !completedArtifacts.contains(artifact.fileName) {
                    try Task.checkCancellation()
                    let source = reusePlan.modelDirectory.appendingPathComponent(
                        artifact.fileName)
                    let destination = modelsDirectory
                        .appendingPathComponent(stagingDirectoryName)
                        .appendingPathComponent(
                        artifact.fileName)
                    try lease.removeArtifactLeafIfPresent(
                        directory: stagingComponents,
                        name: artifact.fileName)
                    try operations.prepareHardLink(source, destination)
                    try lease.createHardLink(
                        sourceDirectory: reusePlan.directoryComponents,
                        sourceName: artifact.fileName,
                        destinationDirectory: stagingComponents,
                        destinationName: artifact.fileName)
                    linkedArtifactNames.append(artifact.fileName)
                    try verifyHardLink(
                        artifact,
                        sourceDirectory: reusePlan.directoryComponents,
                        destinationDirectory: stagingComponents,
                        rootPin: lease)
                    try lease.setDataOnly(
                        directory: stagingComponents,
                        name: artifact.fileName)
                    operations.durabilityBarrier(
                        "artifact:\(artifact.fileName)")
                    completedArtifacts.insert(artifact.fileName)
                    durableArtifactByteCounts[artifact.fileName] = artifact.byteCount
                }
            } catch {
                for fileName in linkedArtifactNames {
                    try? lease.removeArtifactLeafIfPresent(
                        directory: stagingComponents,
                        name: fileName)
                    completedArtifacts.remove(fileName)
                    durableArtifactByteCounts.removeValue(forKey: fileName)
                }
                if Task.isCancelled { throw CancellationError() }
                let remainingBytes = artifacts
                    .filter { !completedArtifacts.contains($0.fileName) }
                    .reduce(Int64(0)) { $0 + $1.byteCount }
                let capacityProbeURL = Self.nearestExistingAncestor(
                    of: rootDirectory,
                    fileManager: fileManager)
                try ensureDiskCapacity(
                    forModelBytes: remainingBytes,
                    at: capacityProbeURL)
            }
        }
        for artifact in artifacts where !completedArtifacts.contains(artifact.fileName) {
            durableArtifactByteCounts[artifact.fileName] = resumableByteCount(
                for: artifact,
                directoryComponents: stagingComponents,
                rootPin: lease)
        }
        var durableDownloadedByteCount = durableArtifactByteCounts.values.reduce(0, +)
        await reportModelProgress(
            downloadedByteCount: durableDownloadedByteCount,
            artifacts: artifacts,
            progress: progress)
        try lease.validate()

        for artifact in artifacts where !completedArtifacts.contains(artifact.fileName) {
            try Task.checkCancellation()
            let bytesOutsideArtifact = durableDownloadedByteCount
                - (durableArtifactByteCounts[artifact.fileName] ?? 0)
            let secureStagingDescriptor = try lease.openDirectory(stagingComponents)
            defer { Darwin.close(secureStagingDescriptor) }
            let downloader = try ComputerUseHTTPDownloader(
                destinationDirectoryDescriptor: secureStagingDescriptor,
                destinationFileName: artifact.fileName,
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
                try await download(
                    request,
                    with: downloader,
                    monitoring: lease)
            } catch let error as ComputerUseHTTPDownloader.DownloadError {
                if case .httpStatus(let status) = error {
                    throw InstallError.unexpectedHTTPStatus(status)
                }
                throw error
            }
            try lease.validate()
            try verify(
                artifact,
                directoryComponents: stagingComponents,
                rootPin: lease)
            try lease.setDataOnly(
                directory: stagingComponents,
                name: artifact.fileName)
            operations.durabilityBarrier("artifact:\(artifact.fileName)")
            durableArtifactByteCounts[artifact.fileName] = artifact.byteCount
            durableDownloadedByteCount = bytesOutsideArtifact + artifact.byteCount
            await reportModelProgress(
                downloadedByteCount: durableDownloadedByteCount,
                artifacts: artifacts,
                progress: progress)
            try lease.validate()
        }

        try lease.validate()
        try lease.synchronizeDirectory(stagingComponents)
        operations.durabilityBarrier("staging-directory")
        try lease.removeTreeIfPresent(
            parent: modelsComponents,
            name: manifest.installationVersion)
        try lease.renameDirectory(
            parent: modelsComponents,
            from: stagingDirectoryName,
            to: manifest.installationVersion)
        try lease.synchronizeDirectory(activeModelComponents)
        operations.durabilityBarrier("model-rename")
        try lease.validate()
        return activeModelDirectory
    }

    /// The network wait is the longest transaction suspension. Revalidate the
    /// pinned root and lock concurrently so a renamed/replaced root cancels the
    /// transfer rather than leaving pathname-based writes running until the
    /// entire artifact finishes.
    private func download(
        _ request: URLRequest,
        with downloader: ComputerUseHTTPDownloader,
        monitoring lease: InstallationTransactionLease
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await downloader.download(request)
                return true
            }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    try lease.validate()
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else {
                throw CancellationError()
            }
        }
    }

    private func validateManifest() throws {
        guard !manifest.installationVersion.isEmpty,
              manifest.installationVersion
                == URL(fileURLWithPath: manifest.installationVersion).lastPathComponent,
              !manifest.installationVersion.contains("/"),
              !manifest.installationVersion.contains("\\"),
              manifest.installationVersion != ".",
              manifest.installationVersion != "..",
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

    private struct LegacyReusePlan: Sendable {
        let modelDirectory: URL
        let directoryComponents: [String]
        let artifacts: [ComputerUseArtifactManifest.DownloadableArtifact]

        var reusableByteCount: Int64 {
            artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
        }
    }

    /// Returns a migration source only when the receipt, managed path,
    /// package identity, and all three source artifacts match exactly. Any
    /// drift simply disables reuse; it never edits or deletes legacy data.
    private func legacyReusePlan(
        rootPin: ManagedRootPin
    ) throws -> LegacyReusePlan? {
        try rootPin.validate()
        let receiptName = receiptURL.lastPathComponent
        guard let legacyManifest,
              legacyManifest.installationVersion != manifest.installationVersion,
              legacyManifest.modelVariant == manifest.modelVariant,
              legacyManifest.modelArtifacts.count == 3,
              !legacyManifest.modelArtifacts.contains(where: {
                $0.kind == .semanticRouterModel
              }),
              legacyManifest.modelArtifacts.filter({
                $0.kind == .textModelShard
              }).count >= 1,
              legacyManifest.modelArtifacts.filter({
                $0.kind == .visionProjector
              }).count == 1,
              manifest.modelArtifacts.count
                == legacyManifest.modelArtifacts.count + 1,
              manifest.modelArtifacts.filter({
                $0.kind == .semanticRouterModel
              }).count == 1,
              legacyManifest.modelArtifacts.allSatisfy({ legacyArtifact in
                manifest.modelArtifacts.contains(legacyArtifact)
              }),
              let data = try? rootPin.readData(name: receiptName),
              let receipt = try? JSONDecoder().decode(
                ComputerUseInstallationReceipt.self,
                from: data),
              receipt.installationVersion == legacyManifest.installationVersion,
              receipt.modelVariant == legacyManifest.modelVariant,
              (receipt.modelDirectory as NSString).isAbsolutePath else {
            return nil
        }

        let expectedDirectory = modelsDirectory.appendingPathComponent(
            legacyManifest.installationVersion,
            isDirectory: true).standardizedFileURL
        let receiptDirectory = URL(
            fileURLWithPath: receipt.modelDirectory,
            isDirectory: true).standardizedFileURL
        let directoryComponents = modelsComponents + [legacyManifest.installationVersion]
        guard receiptDirectory == expectedDirectory,
              rootPin.directoryExists(directoryComponents) else {
            return nil
        }

        do {
            for artifact in legacyManifest.modelArtifacts {
                try verifyReadOnly(
                    artifact,
                    directoryComponents: directoryComponents,
                    rootPin: rootPin)
                try rootPin.validate()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
        return LegacyReusePlan(
            modelDirectory: receiptDirectory,
            directoryComponents: directoryComponents,
            artifacts: legacyManifest.modelArtifacts)
    }

    private func ensureDiskCapacity(
        forModelBytes modelBytes: Int64,
        at capacityProbeURL: URL
    ) throws {
        let required = Self.requiredDiskBytes(forModelBytes: modelBytes)
        if let available = try operations.availableCapacity(capacityProbeURL),
           available < required {
            throw InstallError.insufficientDisk(
                required: required,
                available: available)
        }
    }

    nonisolated static func requiredDiskBytes(forModelBytes modelBytes: Int64) -> Int64 {
        let clamped = max(0, modelBytes)
        let (total, overflow) = clamped.addingReportingOverflow(
            installationHeadroomBytes)
        return overflow ? Int64.max : total
    }

    private func verifyHardLink(
        _ artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        sourceDirectory: [String],
        destinationDirectory: [String],
        rootPin: ManagedRootPin
    ) throws {
        try rootPin.validate()
        try verifyReadOnly(
            artifact,
            directoryComponents: sourceDirectory,
            rootPin: rootPin)
        try verifyReadOnly(
            artifact,
            directoryComponents: destinationDirectory,
            rootPin: rootPin)
        guard let sourceStatus = try rootPin.itemStatus(
                directory: sourceDirectory,
                name: artifact.fileName),
              let destinationStatus = try rootPin.itemStatus(
                directory: destinationDirectory,
                name: artifact.fileName),
              sourceStatus.st_dev == destinationStatus.st_dev,
              sourceStatus.st_ino == destinationStatus.st_ino else {
            throw InstallError.invalidArtifact(artifact.fileName)
        }
        try rootPin.validate()
    }

    private func performDeferredLegacyCleanup(
        afterVerifying receipt: ComputerUseInstallationReceipt,
        lease: InstallationTransactionLease
    ) throws {
        try lease.validate()
        guard receipt.installationVersion == manifest.installationVersion,
              receipt.modelVariant == manifest.modelVariant,
              let legacyManifest,
              let data = try? lease.readData(
                name: Self.deferredLegacyCleanupMarkerName),
              let cleanup = try? JSONDecoder().decode(
                DeferredLegacyCleanup.self,
                from: data),
              cleanup.replacementInstallationVersion
                == manifest.installationVersion,
              cleanup.legacyInstallationVersion
                == legacyManifest.installationVersion,
              cleanup.createdByLaunchIdentifier != launchIdentifier else {
            return
        }

        try operations.prepareDeferredCleanup()
        try lease.validate()
        try lease.validateTreeIfPresent(
            parent: modelsComponents,
            name: legacyManifest.installationVersion)
        try lease.validateTreeIfPresent(
            parent: [],
            name: legacyAdaptersDirectory.lastPathComponent)
        try lease.removeTreeIfPresent(
            parent: modelsComponents,
            name: legacyManifest.installationVersion)
        try removeManagedDirectoryIfPresent(
            named: legacyAdaptersDirectory.lastPathComponent,
            rootPin: lease)
        try lease.removeLeafIfPresent(name: Self.deferredLegacyCleanupMarkerName)
        operations.durabilityBarrier("legacy-cleanup")
        try lease.validate()
    }

    private func removeManagedDirectoryIfPresent(
        named name: String,
        rootPin: ManagedRootPin
    ) throws {
        try ManagedRootPin.validateLeafName(name)
        try rootPin.validate()
        try rootPin.removeTreeIfPresent(parent: [], name: name)
        try rootPin.validate()
    }

    private func resumableByteCount(
        for artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) -> Int64 {
        guard let status = try? rootPin.itemStatus(
                directory: directoryComponents,
                name: artifact.fileName),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == Darwin.geteuid() else {
            try? rootPin.removeArtifactLeafIfPresent(
                directory: directoryComponents,
                name: artifact.fileName)
            return 0
        }
        let size = status.st_size
        guard size >= 0, size < artifact.byteCount else {
            try? rootPin.removeArtifactLeafIfPresent(
                directory: directoryComponents,
                name: artifact.fileName)
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
            detail: "Downloading local AI models… \(downloaded) of \(total)")
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

    private func installLegalDocuments(
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) throws {
        try rootPin.validate()
        guard rootPin.directoryExists(directoryComponents) else {
            throw InstallError.invalidArtifact(directoryComponents.last ?? "Models")
        }
        for artifact in ComputerUseArtifactManifest.modelLegalArtifacts {
            let source = try legalResourceURL(for: artifact)
            try verifyBundledArtifact(artifact, at: source)
            if (try? verify(
                artifact,
                directoryComponents: directoryComponents,
                rootPin: rootPin)) != nil {
                try rootPin.setDataOnly(
                    directory: directoryComponents,
                    name: artifact.fileName)
                operations.durabilityBarrier("legal:\(artifact.fileName)")
                continue
            }
            let data = try Data(contentsOf: source)
            try rootPin.writeAtomically(
                data,
                directory: directoryComponents,
                name: artifact.fileName)
            try rootPin.validate()
            try verify(
                artifact,
                directoryComponents: directoryComponents,
                rootPin: rootPin)
            try rootPin.setDataOnly(
                directory: directoryComponents,
                name: artifact.fileName)
            operations.durabilityBarrier("legal:\(artifact.fileName)")
        }
        try rootPin.synchronizeDirectory(directoryComponents)
        try rootPin.validate()
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
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) -> Bool {
        fileLooksComplete(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            directoryComponents: directoryComponents,
            rootPin: rootPin)
    }

    private func verify(
        _ artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) throws {
        try verifyReadOnly(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            directoryComponents: directoryComponents,
            rootPin: rootPin)
    }

    private func verifyReadOnly(
        _ artifact: ComputerUseArtifactManifest.DownloadableArtifact,
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) throws {
        try verifyReadOnly(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            directoryComponents: directoryComponents,
            rootPin: rootPin)
    }

    private func verify(
        _ artifact: ComputerUseArtifactManifest.BundledArtifact,
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) throws {
        try verifyReadOnly(
            fileName: artifact.fileName,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            directoryComponents: directoryComponents,
            rootPin: rootPin)
    }

    private func fileLooksComplete(
        fileName: String,
        byteCount: Int64,
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) -> Bool {
        guard let status = try? rootPin.itemStatus(
                directory: directoryComponents,
                name: fileName),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_size == byteCount else {
            return false
        }
        return true
    }

    private func verifyReadOnly(
        fileName: String,
        byteCount: Int64,
        sha256: String,
        directoryComponents: [String],
        rootPin: ManagedRootPin
    ) throws {
        guard fileLooksComplete(
            fileName: fileName,
            byteCount: byteCount,
            directoryComponents: directoryComponents,
            rootPin: rootPin) else {
            throw InstallError.invalidArtifact(fileName)
        }
        let descriptor = try rootPin.openRegularFile(
            directory: directoryComponents,
            name: fileName)
        defer { Darwin.close(descriptor) }
        guard try Self.sha256(descriptor) == sha256.lowercased() else {
            throw InstallError.checksumMismatch(fileName)
        }
    }

    private static func sha256(_ descriptor: Int32) throws -> String {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw ManagedRootPin.posixError()
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManagedRootPin.posixError()
            }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
