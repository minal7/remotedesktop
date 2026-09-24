import Darwin
import Foundation
import UniformTypeIdentifiers

/// Metadata-only inventory for files inside one host-approved directory.
/// Candidate IDs are local references; they never encode or expose a path.
struct ComputerUseLocalFileCatalog {
    struct Candidate: Equatable, Sendable {
        let id: String
        let displayName: String
        let contentTypeIdentifier: String?
        let fileExtension: String
        let byteCount: Int64
        let modifiedAt: Date?
        let createdAt: Date?
        let addedToDirectoryAt: Date?
    }

    struct Page: Equatable, Sendable {
        let candidates: [Candidate]
        /// True only if the bounded directory scan reached its end. A caller
        /// must also consume every page before concluding there is no match.
        let isComplete: Bool
        let nextCursor: String?
    }

    enum Failure: Error, Equatable {
        case invalidTask
        case invalidDirectory
        case directoryUnavailable
        case entryMetadataUnavailable
        case foreignTask
        case unknownCursor
        case unknownCandidate
        case staleCandidate
    }

    private struct Metadata: Equatable {
        let byteCount: Int64
        let contentTypeIdentifier: String?
        let modifiedAt: Date?
        let createdAt: Date?
        let addedToDirectoryAt: Date?
    }

    private struct POSIXFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool
    }

    private struct FileIdentity: Equatable {
        let posix: POSIXFileIdentity
        let metadata: Metadata
    }

    private struct Record {
        let candidate: Candidate
        let url: URL
        let identity: FileIdentity
    }

    private let taskID: String
    private let approvedDirectory: URL
    private let pageSize: Int
    private let maximumCandidates: Int
    private let maximumEntriesScanned: Int
    private var records: [Record] = []
    private var candidateRecords: [String: Record] = [:]
    private var cursors: [String: Int] = [:]
    private var inventoryWasTruncated = false
    private var hasInventory = false

    init(taskID: String, approvedDirectory: URL, pageSize: Int = 64,
         maximumCandidates: Int = 4096, maximumEntriesScanned: Int = 16_384) throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 256 else { throw Failure.invalidTask }
        guard approvedDirectory.isFileURL else { throw Failure.invalidDirectory }
        self.taskID = taskID
        self.approvedDirectory = approvedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.pageSize = min(max(pageSize, 1), 128)
        self.maximumCandidates = min(max(maximumCandidates, 1), 4096)
        self.maximumEntriesScanned = min(max(maximumEntriesScanned, 1), 65_536)
    }

    mutating func discover() throws -> Page {
        records.removeAll(keepingCapacity: true)
        candidateRecords.removeAll(keepingCapacity: true)
        cursors.removeAll(keepingCapacity: true)
        inventoryWasTruncated = false
        hasInventory = false

        guard let rootIdentity = Self.lstat(approvedDirectory), rootIdentity.isDirectory else {
            throw Failure.invalidDirectory
        }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: approvedDirectory,
            includingPropertiesForKeys: [], options: [], errorHandler: { _, error in
                scanError = error
                return false
            }) else { throw Failure.directoryUnavailable }

        var scannedEntries = 0
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { throw Failure.entryMetadataUnavailable }
            scannedEntries += 1
            if scannedEntries > maximumEntriesScanned {
                inventoryWasTruncated = true
                break
            }
            guard let identity = Self.lstat(url) else { throw Failure.entryMetadataUnavailable }
            if identity.isSymbolicLink {
                enumerator.skipDescendants()
                continue
            }
            if identity.isDirectory {
                enumerator.skipDescendants()
                continue
            }
            guard identity.isRegularFile else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isContained(resolved, in: approvedDirectory) else { continue }
            let metadata = try Self.metadata(at: resolved, matching: identity)
            if records.count == maximumCandidates {
                inventoryWasTruncated = true
                break
            }
            let candidate = Candidate(id: UUID().uuidString.lowercased(),
                displayName: url.lastPathComponent,
                contentTypeIdentifier: metadata.contentTypeIdentifier,
                fileExtension: url.pathExtension,
                byteCount: metadata.byteCount, modifiedAt: metadata.modifiedAt,
                createdAt: metadata.createdAt, addedToDirectoryAt: metadata.addedToDirectoryAt)
            let record = Record(candidate: candidate, url: resolved,
                identity: FileIdentity(posix: identity, metadata: metadata))
            records.append(record)
            candidateRecords[candidate.id] = record
        }
        if scanError != nil { throw Failure.directoryUnavailable }
        hasInventory = true
        return page(startingAt: 0)
    }

    mutating func nextPage(after cursor: String) throws -> Page {
        guard hasInventory, let offset = cursors.removeValue(forKey: cursor) else { throw Failure.unknownCursor }
        return page(startingAt: offset)
    }

    func resolve(candidateID: String, taskID requestedTaskID: String) throws -> URL {
        guard requestedTaskID == taskID else { throw Failure.foreignTask }
        guard let record = candidateRecords[candidateID] else { throw Failure.unknownCandidate }
        var freshURL = record.url
        freshURL.removeAllCachedResourceValues()
        guard let freshIdentity = Self.lstat(freshURL), freshIdentity.isRegularFile,
              !freshIdentity.isSymbolicLink,
              Self.isContained(freshURL.standardizedFileURL.resolvingSymlinksInPath(), in: approvedDirectory) else {
            throw Failure.staleCandidate
        }
        let freshMetadata: Metadata
        do { freshMetadata = try Self.metadata(at: freshURL, matching: freshIdentity) }
        catch { throw Failure.staleCandidate }
        let currentIdentity = FileIdentity(posix: freshIdentity, metadata: freshMetadata)
        guard currentIdentity == record.identity else { throw Failure.staleCandidate }
        return freshURL
    }

    private mutating func page(startingAt offset: Int) -> Page {
        let end = min(offset + pageSize, records.count)
        let pageRecords = offset < end ? Array(records[offset..<end]) : []
        let cursor: String?
        if end < records.count {
            let token = UUID().uuidString.lowercased()
            cursors[token] = end
            cursor = token
        } else { cursor = nil }
        return Page(candidates: pageRecords.map(\.candidate), isComplete: !inventoryWasTruncated, nextCursor: cursor)
    }

    private static func lstat(_ url: URL) -> POSIXFileIdentity? {
        var value = stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
        let type = value.st_mode & mode_t(S_IFMT)
        return POSIXFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            byteCount: Int64(value.st_size), modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec),
            isDirectory: type == mode_t(S_IFDIR), isRegularFile: type == mode_t(S_IFREG),
            isSymbolicLink: type == mode_t(S_IFLNK))
    }

    private static func metadata(at url: URL, matching identity: POSIXFileIdentity) throws -> Metadata {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentTypeKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey])
        } catch { throw Failure.entryMetadataUnavailable }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, Int64(size) == identity.byteCount,
              let afterRead = lstat(freshURL), afterRead == identity else {
            throw Failure.entryMetadataUnavailable
        }
        let contentTypeIdentifier = values.contentType?.identifier
            ?? UTType(filenameExtension: url.pathExtension)?.identifier
        return Metadata(byteCount: Int64(size), contentTypeIdentifier: contentTypeIdentifier,
            modifiedAt: values.contentModificationDate, createdAt: values.creationDate,
            addedToDirectoryAt: values.addedToDirectoryDate)
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let pathComponents = candidate.standardizedFileURL.pathComponents
        return pathComponents.count > rootComponents.count && pathComponents.starts(with: rootComponents)
    }
}
