import Darwin
import Foundation

/// Downloads an immutable model artifact in durable byte-range chunks.
///
/// Each completed chunk is appended to `destination` and synchronized before
/// the next request starts. If the host quits or the network drops, the next
/// setup attempt resumes from the on-disk byte count instead of restarting the
/// model-artifact download. The final SHA-256 verification remains the
/// authority for accepting the artifact.
final class ComputerUseHTTPDownloader: @unchecked Sendable {
    enum DownloadError: LocalizedError, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case invalidRangeResponse
        case invalidDownloadedSize(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The AI model server returned an invalid response."
            case .httpStatus(let status):
                return "The AI model server returned an unexpected response (\(status))."
            case .invalidRangeResponse:
                return "The AI model server could not resume the download safely."
            case .invalidDownloadedSize(let expected, let actual):
                return "The AI model download was incomplete (expected \(expected) bytes, received \(actual))."
            }
        }
    }

    private let destination: URL
    private let secureDestinationDirectoryDescriptor: Int32?
    private let secureDestinationFileName: String?
    private let expectedByteCount: Int64
    private let chunkByteCount: Int64
    private let session: URLSession
    private let fileManager: FileManager
    private let progress: @MainActor @Sendable (Double) -> Void

    init(
        destination: URL,
        expectedByteCount: Int64,
        chunkByteCount: Int64 = 16 * 1_024 * 1_024,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) {
        self.destination = destination
        secureDestinationDirectoryDescriptor = nil
        secureDestinationFileName = nil
        self.expectedByteCount = expectedByteCount
        self.chunkByteCount = max(1, chunkByteCount)
        self.session = session
        self.fileManager = fileManager
        self.progress = progress
    }

    /// Creates a downloader whose destination is a single leaf below an
    /// already-pinned directory descriptor. The duplicate stays open for this
    /// downloader's lifetime, and every write is made through `openat(2)` so a
    /// swapped managed pathname can never redirect model bytes.
    init(
        destinationDirectoryDescriptor: Int32,
        destinationFileName: String,
        expectedByteCount: Int64,
        chunkByteCount: Int64 = 16 * 1_024 * 1_024,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) throws {
        guard Self.isSafeLeafName(destinationFileName) else {
            throw DownloadError.invalidResponse
        }
        let duplicate = Darwin.dup(destinationDirectoryDescriptor)
        guard duplicate >= 0 else { throw Self.posixError() }
        destination = URL(fileURLWithPath: "/descriptor-relative")
            .appendingPathComponent(destinationFileName)
        secureDestinationDirectoryDescriptor = duplicate
        secureDestinationFileName = destinationFileName
        self.expectedByteCount = expectedByteCount
        self.chunkByteCount = max(1, chunkByteCount)
        self.session = session
        self.fileManager = fileManager
        self.progress = progress
    }

    deinit {
        if let secureDestinationDirectoryDescriptor {
            Darwin.close(secureDestinationDirectoryDescriptor)
        }
    }

    func download(_ request: URLRequest) async throws {
        guard expectedByteCount > 0 else {
            throw DownloadError.invalidDownloadedSize(
                expected: expectedByteCount,
                actual: 0)
        }

        let secureOutput = try openSecureOutputIfNeeded()
        defer {
            if let secureOutput { Darwin.close(secureOutput.descriptor) }
        }
        if secureOutput == nil {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        var offset = try resumableOffset(secureOutput: secureOutput)
        await progress(Double(offset) / Double(expectedByteCount))

        while offset < expectedByteCount {
            try Task.checkCancellation()
            let end = min(expectedByteCount - 1, offset + chunkByteCount - 1)
            var rangedRequest = request
            rangedRequest.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

            let (temporaryURL, response) = try await session.download(for: rangedRequest)
            guard let response = response as? HTTPURLResponse else {
                throw DownloadError.invalidResponse
            }

            switch response.statusCode {
            case 206:
                guard Self.contentRangeStarts(
                    response.value(forHTTPHeaderField: "Content-Range"),
                    at: offset) else {
                    throw DownloadError.invalidRangeResponse
                }
                let expectedChunkSize = end - offset + 1
                let actualChunkSize = try Self.fileSize(
                    at: temporaryURL,
                    fileManager: fileManager)
                guard actualChunkSize == expectedChunkSize else {
                    throw DownloadError.invalidDownloadedSize(
                        expected: expectedChunkSize,
                        actual: actualChunkSize)
                }
                try append(contentsOf: temporaryURL, secureOutput: secureOutput)
                offset += actualChunkSize

            case 200:
                // A server may ignore Range and return the complete artifact.
                // Accept it only when its exact size matches the pinned
                // manifest; otherwise never concatenate ambiguous bytes.
                let actualSize = try Self.fileSize(
                    at: temporaryURL,
                    fileManager: fileManager)
                guard actualSize == expectedByteCount else {
                    throw DownloadError.invalidDownloadedSize(
                        expected: expectedByteCount,
                        actual: actualSize)
                }
                if let secureOutput {
                    try replaceSecureOutput(
                        secureOutput,
                        contentsOf: temporaryURL)
                } else {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                    try synchronizeStandaloneDestination()
                }
                offset = actualSize

            default:
                throw DownloadError.httpStatus(response.statusCode)
            }

            await progress(Double(offset) / Double(expectedByteCount))
        }

        let finalSize: Int64
        if let secureOutput {
            try synchronize(secureOutput.descriptor)
            try validateSecureOutputIdentity(secureOutput)
            try synchronizeSecureDirectory()
            finalSize = try Self.fileSize(descriptor: secureOutput.descriptor)
        } else {
            finalSize = try Self.fileSize(at: destination, fileManager: fileManager)
        }
        guard finalSize == expectedByteCount else {
            throw DownloadError.invalidDownloadedSize(
                expected: expectedByteCount,
                actual: finalSize)
        }
    }

    private struct SecureOutput {
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
    }

    private func openSecureOutputIfNeeded() throws -> SecureOutput? {
        guard let directoryDescriptor = secureDestinationDirectoryDescriptor,
              let fileName = secureDestinationFileName else {
            return nil
        }
        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == Darwin.geteuid() else {
            throw DownloadError.invalidResponse
        }

        var created = false
        var descriptor = fileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT {
            descriptor = fileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
            }
            created = descriptor >= 0
        }
        guard descriptor >= 0 else { throw Self.posixError() }
        var shouldClose = true
        defer { if shouldClose { Darwin.close(descriptor) } }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw DownloadError.invalidResponse
        }
        let output = SecureOutput(
            descriptor: descriptor,
            device: status.st_dev,
            inode: status.st_ino)
        try validateSecureOutputIdentity(output)
        if created {
            try synchronize(descriptor)
            try synchronizeSecureDirectory()
        }
        shouldClose = false
        return output
    }

    private func resumableOffset(secureOutput: SecureOutput?) throws -> Int64 {
        if let secureOutput {
            var size = try Self.fileSize(descriptor: secureOutput.descriptor)
            guard size >= 0 else { throw DownloadError.invalidResponse }
            if size > expectedByteCount {
                try validateSecureOutputIdentity(secureOutput)
                guard Darwin.ftruncate(secureOutput.descriptor, 0) == 0 else {
                    throw Self.posixError()
                }
                try synchronize(secureOutput.descriptor)
                try validateSecureOutputIdentity(secureOutput)
                size = 0
            }
            return size
        }
        guard fileManager.fileExists(atPath: destination.path) else { return 0 }
        let size = try Self.fileSize(at: destination, fileManager: fileManager)
        guard size >= 0, size <= expectedByteCount else {
            try fileManager.removeItem(at: destination)
            return 0
        }
        return size
    }

    private func append(
        contentsOf source: URL,
        secureOutput: SecureOutput?
    ) throws {
        if let secureOutput {
            try validateSecureOutputIdentity(secureOutput)
            guard Darwin.lseek(secureOutput.descriptor, 0, SEEK_END) >= 0 else {
                throw Self.posixError()
            }
            try copy(source: source, to: secureOutput.descriptor)
            try synchronize(secureOutput.descriptor)
            try validateSecureOutputIdentity(secureOutput)
            return
        }
        if !fileManager.fileExists(atPath: destination.path) {
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.seekToEnd()
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    private func replaceSecureOutput(
        _ secureOutput: SecureOutput,
        contentsOf source: URL
    ) throws {
        try validateSecureOutputIdentity(secureOutput)
        guard Darwin.ftruncate(secureOutput.descriptor, 0) == 0,
              Darwin.lseek(secureOutput.descriptor, 0, SEEK_SET) >= 0 else {
            throw Self.posixError()
        }
        try copy(source: source, to: secureOutput.descriptor)
        try synchronize(secureOutput.descriptor)
        try validateSecureOutputIdentity(secureOutput)
    }

    private func copy(source: URL, to outputDescriptor: Int32) throws {
        let inputDescriptor = source.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard inputDescriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(inputDescriptor) }
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            try Task.checkCancellation()
            let readCount = Darwin.read(inputDescriptor, &buffer, buffer.count)
            if readCount < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            guard readCount > 0 else { break }
            var written = 0
            while written < readCount {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        outputDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        readCount - written)
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                written += result
            }
        }
    }

    private func validateSecureOutputIdentity(_ output: SecureOutput) throws {
        guard let directoryDescriptor = secureDestinationDirectoryDescriptor,
              let fileName = secureDestinationFileName else {
            throw DownloadError.invalidResponse
        }
        var descriptorStatus = stat()
        var nameStatus = stat()
        let nameResult = fileName.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &nameStatus,
                AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(output.descriptor, &descriptorStatus) == 0,
              nameResult == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              nameStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_uid == Darwin.geteuid(),
              nameStatus.st_uid == Darwin.geteuid(),
              descriptorStatus.st_nlink == 1,
              nameStatus.st_nlink == 1,
              descriptorStatus.st_dev == output.device,
              descriptorStatus.st_ino == output.inode,
              nameStatus.st_dev == output.device,
              nameStatus.st_ino == output.inode else {
            throw DownloadError.invalidResponse
        }
    }

    private func synchronizeSecureDirectory() throws {
        guard let descriptor = secureDestinationDirectoryDescriptor else {
            throw DownloadError.invalidResponse
        }
        try synchronize(descriptor)
    }

    private func synchronizeStandaloneDestination() throws {
        let descriptor = destination.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(descriptor) }
        try synchronize(descriptor)

        let parentDescriptor = destination.deletingLastPathComponent().path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(parentDescriptor) }
        try synchronize(parentDescriptor)
    }

    private func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw Self.posixError()
        }
    }

    private static func contentRangeStarts(_ value: String?, at offset: Int64) -> Bool {
        guard let value else { return false }
        let prefix = "bytes \(offset)-"
        return value.lowercased().hasPrefix(prefix)
    }

    private static func fileSize(
        at url: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw DownloadError.invalidResponse
        }
        return number.int64Value
    }

    private static func fileSize(descriptor: Int32) throws -> Int64 {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw DownloadError.invalidResponse
        }
        return status.st_size
    }

    private static func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.utf8.contains(0)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
