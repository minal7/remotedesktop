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
        self.expectedByteCount = expectedByteCount
        self.chunkByteCount = max(1, chunkByteCount)
        self.session = session
        self.fileManager = fileManager
        self.progress = progress
    }

    func download(_ request: URLRequest) async throws {
        guard expectedByteCount > 0 else {
            throw DownloadError.invalidDownloadedSize(
                expected: expectedByteCount,
                actual: 0)
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var offset = try resumableOffset()
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
                try append(contentsOf: temporaryURL)
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
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporaryURL, to: destination)
                offset = actualSize

            default:
                throw DownloadError.httpStatus(response.statusCode)
            }

            await progress(Double(offset) / Double(expectedByteCount))
        }

        let finalSize = try Self.fileSize(at: destination, fileManager: fileManager)
        guard finalSize == expectedByteCount else {
            throw DownloadError.invalidDownloadedSize(
                expected: expectedByteCount,
                actual: finalSize)
        }
    }

    private func resumableOffset() throws -> Int64 {
        guard fileManager.fileExists(atPath: destination.path) else { return 0 }
        let size = try Self.fileSize(at: destination, fileManager: fileManager)
        guard size >= 0, size <= expectedByteCount else {
            try fileManager.removeItem(at: destination)
            return 0
        }
        return size
    }

    private func append(contentsOf source: URL) throws {
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
}
