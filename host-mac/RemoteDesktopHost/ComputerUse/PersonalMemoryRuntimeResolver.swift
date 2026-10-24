import CryptoKit
import Darwin
import Foundation

enum PersonalMemoryRuntimeResolverError: Error, Equatable {
    case unavailable
    case invalidModel
}

/// Resolves only the pinned local embedding data package. The model is never
/// downloaded here, and executable code is resolved by the existing bundle
/// containment checker.
enum PersonalMemoryRuntimeResolver {
    static let modelIdentity = PersonalMemoryRuntimeInputs.modelIdentity
    static let modelFileName = PersonalMemoryRuntimeInputs.modelFileName
    static let modelByteCount = Int64(PersonalMemoryRuntimeInputs.modelByteCount)
    static let modelSHA256 = PersonalMemoryRuntimeInputs.modelSHA256
    static let embeddingDimensions = PersonalMemoryRuntimeInputs.embeddingDimensions

    @MainActor
    static func resolve(bundle: Bundle = .main) throws -> PersonalMemoryRuntimeInputs {
        let modelRoot = HostComputerUseManager.modelDirectoryURL
            .appendingPathComponent("MemoryEmbedding", isDirectory: true)
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: bundle)
        return try resolvePinned(
            modelRootURL: modelRoot,
            runtimeDirectoryURL: runtimeDirectory,
            enclosingBundleURL: bundle.bundleURL)
    }

    #if DEBUG
    /// Test seam for small temporary model files. Production resolution never
    /// accepts caller-selected artifact identity, size, digest, or runtime.
    static func resolveForTesting(
        modelRootURL: URL,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL,
        expectedModelByteCount: Int64,
        expectedModelSHA256: String,
        fileSHA256: (URL) throws -> String
    ) throws -> PersonalMemoryRuntimeInputs {
        try resolveConfigured(
            modelRootURL: modelRootURL,
            runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: enclosingBundleURL,
            expectedModelByteCount: expectedModelByteCount,
            expectedModelSHA256: expectedModelSHA256,
            fileSHA256: fileSHA256)
    }

    static func verifyFileDigestForTesting(
        at url: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws -> Bool {
        try sha256(file: url, expectedByteCount: expectedByteCount) == expectedSHA256
    }
    #endif

    private static func resolvePinned(
        modelRootURL: URL,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL
    ) throws -> PersonalMemoryRuntimeInputs {
        try resolveConfigured(
            modelRootURL: modelRootURL,
            runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: enclosingBundleURL,
            expectedModelByteCount: modelByteCount,
            expectedModelSHA256: modelSHA256,
            fileSHA256: { url in try sha256(file: url, expectedByteCount: modelByteCount) })
    }

    private static func resolveConfigured(
        modelRootURL: URL,
        runtimeDirectoryURL: URL,
        enclosingBundleURL: URL,
        expectedModelByteCount: Int64,
        expectedModelSHA256: String,
        fileSHA256: (URL) throws -> String
    ) throws -> PersonalMemoryRuntimeInputs {
        guard expectedModelByteCount > 0,
              expectedModelSHA256.utf8.count == 64,
              expectedModelSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              isStrictDirectory(modelRootURL) else {
            throw PersonalMemoryRuntimeResolverError.unavailable
        }

        let modelURL = modelRootURL.appendingPathComponent(modelFileName)
        let verified: Bool
        if expectedModelByteCount == modelByteCount && expectedModelSHA256 == modelSHA256 {
            verified = try sha256(file: modelURL, expectedByteCount: expectedModelByteCount) == expectedModelSHA256
        } else {
            verified = try isExactRegularFile(modelURL, expectedByteCount: expectedModelByteCount)
                && fileSHA256(modelURL) == expectedModelSHA256
        }
        guard verified else {
            throw PersonalMemoryRuntimeResolverError.invalidModel
        }

        let executable = try OSAtlasRuntimeInputResolver().resolveBundledExecutable(
            runtimeDirectoryURL: runtimeDirectoryURL,
            enclosingBundleURL: enclosingBundleURL)
        return PersonalMemoryRuntimeInputs(modelURL: modelURL, llamaServerURL: executable)
    }

    private static func isStrictDirectory(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Open the final model component with O_NOFOLLOW and verify the opened
    /// inode itself, avoiding a symlink swap between path inspection and hash.
    private static func isExactRegularFile(_ url: URL, expectedByteCount: Int64) throws -> Bool {
        let rootPath = url.deletingLastPathComponent().path
        let directoryFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { return false }
        defer { _ = close(directoryFD) }

        let fileFD = openat(directoryFD, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileFD >= 0 else { return false }
        defer { _ = close(fileFD) }

        var info = stat()
        guard fstat(fileFD, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == expectedByteCount else {
            return false
        }
        return true
    }

    private static func sha256(file url: URL, expectedByteCount: Int64) throws -> String {
        guard expectedByteCount > 0, expectedByteCount < Int64.max else {
            throw PersonalMemoryRuntimeResolverError.invalidModel
        }
        let directoryFD = open(url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw PersonalMemoryRuntimeResolverError.invalidModel }
        defer { _ = close(directoryFD) }
        let fd = openat(directoryFD, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw PersonalMemoryRuntimeResolverError.invalidModel }
        defer { _ = close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == expectedByteCount else {
            throw PersonalMemoryRuntimeResolverError.invalidModel
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var totalRead: Int64 = 0
        while true {
            let remainingWithOverflowCheck = expectedByteCount - totalRead + 1
            guard remainingWithOverflowCheck > 0 else {
                throw PersonalMemoryRuntimeResolverError.invalidModel
            }
            let readLimit = min(buffer.count, Int(remainingWithOverflowCheck))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, readLimit)
            }
            if count == 0 {
                guard totalRead == expectedByteCount else {
                    throw PersonalMemoryRuntimeResolverError.invalidModel
                }
                break
            }
            guard count > 0 else { throw PersonalMemoryRuntimeResolverError.invalidModel }
            totalRead += Int64(count)
            guard totalRead <= expectedByteCount else {
                throw PersonalMemoryRuntimeResolverError.invalidModel
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
