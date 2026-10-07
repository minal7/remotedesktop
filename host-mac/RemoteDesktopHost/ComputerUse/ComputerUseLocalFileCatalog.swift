import Darwin
import Foundation
import UniformTypeIdentifiers

/// Metadata-only inventory for files inside one host-approved directory.
/// Candidate IDs are local references; they never encode or expose a path.
struct ComputerUseLocalFileCatalog: Sendable {
    enum FileKind: String, Equatable, Sendable { case any, presentation, spreadsheet, document }
    enum SortField: String, Equatable, Sendable { case modifiedAt, createdAt, addedToDirectoryAt }
    enum SortDirection: String, Equatable, Sendable { case ascending, descending }

    struct Sort: Equatable, Sendable {
        let field: SortField
        let direction: SortDirection
    }

    struct Query: Equatable, Sendable {
        static let maximumNameContainsUTF8Bytes = 512
        let fileKind: FileKind
        let sort: Sort?
        let nameContains: String

        init(fileKind: FileKind = .any, sort: Sort? = nil, nameContains: String = "") {
            self.fileKind = fileKind
            self.sort = sort
            self.nameContains = nameContains
        }

        var isValid: Bool { nameContains.utf8.count <= Self.maximumNameContainsUTF8Bytes }
    }

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
        let hasTiedSortValues: Bool
        let hasMissingSortValues: Bool
    }

    enum RankedBestCandidates: Equatable {
        case unranked
        case incomplete
        case missingBestValue
        case ids([String])
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
        case invalidQuery
    }

    private struct Metadata: Equatable, Sendable {
        let byteCount: Int64
        let contentTypeIdentifier: String?
        let modifiedAt: Date?
        let createdAt: Date?
        let addedToDirectoryAt: Date?
    }

    private struct POSIXFileIdentity: Equatable, Sendable {
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

    private struct FileIdentity: Equatable, Sendable {
        let posix: POSIXFileIdentity
        let metadata: Metadata
    }

    private struct Record: Sendable {
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
    private var currentQuery: Query?
    private var queryHasTiedSortValues = false
    private var queryHasMissingSortValues = false

    struct Discovery: Sendable {
        let catalog: ComputerUseLocalFileCatalog
        let page: Page
    }

    private static let discoveryWorker = ComputerUseBlockingOperationWorker(
        label: "com.threadmark.remotedesktop.computer-use.file-discovery")

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
        try discover(query: Query())
    }

    mutating func discover(query: Query) throws -> Page {
        records.removeAll(keepingCapacity: true)
        candidateRecords.removeAll(keepingCapacity: true)
        cursors.removeAll(keepingCapacity: true)
        inventoryWasTruncated = false
        hasInventory = false
        queryHasTiedSortValues = false
        queryHasMissingSortValues = false
        currentQuery = nil

        guard query.isValid else { throw Failure.invalidQuery }
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
            guard Self.matchesName(url.lastPathComponent, contains: query.nameContains) else { continue }
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
        records = records.filter { Self.matches($0.candidate, kind: query.fileKind) }
        if let sort = query.sort {
            let ordering = Self.sorted(records, by: sort)
            records = ordering.records
            queryHasTiedSortValues = ordering.hasTies
            queryHasMissingSortValues = ordering.hasMissingValues
        }
        currentQuery = query
        candidateRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.candidate.id, $0) })
        hasInventory = true
        return page(startingAt: 0)
    }

    /// Returns the complete top-ranked group for a date-sorted query. Page-wide
    /// tie flags are too coarse because they also include lower-ranked ties.
    func rankedBestCandidates(for query: Query) -> RankedBestCandidates {
        guard let sort = query.sort else { return .unranked }
        guard hasInventory, currentQuery == query, !inventoryWasTruncated,
              let first = records.first else { return .incomplete }
        guard !queryHasMissingSortValues else { return .missingBestValue }
        guard let firstValue = Self.date(for: first.candidate, field: sort.field) else {
            return .missingBestValue
        }
        let ids = records.prefix { Self.date(for: $0.candidate, field: sort.field) == firstValue }
            .map { $0.candidate.id }
        return ids.isEmpty ? .incomplete : .ids(ids)
    }

    /// Performs bounded filesystem enumeration on its own serial worker. The
    /// caller's catalog is copied so a timeout/cancellation cannot publish a
    /// partial or late mutation back into task scope.
    func discoverOffMainActor(query: Query, timeout: TimeInterval = 20) async throws -> Discovery {
        let original = self
        return try await Self.discoveryWorker.perform(timeout: timeout) {
            var catalog = original
            let page = try catalog.discover(query: query)
            return Discovery(catalog: catalog, page: page)
        }
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
        return Page(candidates: pageRecords.map(\.candidate), isComplete: !inventoryWasTruncated,
            nextCursor: cursor, hasTiedSortValues: queryHasTiedSortValues,
            hasMissingSortValues: queryHasMissingSortValues)
    }

    private static func matchesName(_ filename: String, contains fragment: String) -> Bool {
        guard !fragment.isEmpty else { return true }
        let locale = Locale(identifier: "en_US_POSIX")
        return filename.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .contains(fragment.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale))
    }

    private static func matches(_ candidate: Candidate, kind: FileKind) -> Bool {
        guard kind != .any else { return true }
        let fileExtension = candidate.fileExtension.lowercased()
        let contentType = candidate.contentTypeIdentifier.flatMap { UTType($0) }
        switch kind {
        case .any:
            return true
        case .presentation:
            return contentType?.conforms(to: .presentation) == true
                || ["ppt", "pptx", "pps", "ppsx", "pot", "potx", "odp", "key"].contains(fileExtension)
        case .spreadsheet:
            return contentType?.conforms(to: .spreadsheet) == true
                || ["xls", "xlsx", "xlsm", "xlsb", "csv", "ods", "numbers"].contains(fileExtension)
        case .document:
            return contentType?.conforms(to: .text) == true || contentType?.conforms(to: .pdf) == true
                || ["doc", "docx", "docm", "odt", "pdf", "rtf", "txt", "md", "pages"].contains(fileExtension)
        }
    }

    private static func sorted(_ records: [Record], by sort: Sort)
        -> (records: [Record], hasTies: Bool, hasMissingValues: Bool) {
        let values = records.map { date(for: $0.candidate, field: sort.field) }
        let datedValues = values.compactMap { $0 }
        let hasTies = Set(datedValues).count != datedValues.count
        let hasMissingValues = datedValues.count != values.count
        let ordered = records.sorted { lhs, rhs in
            let left = date(for: lhs.candidate, field: sort.field)
            let right = date(for: rhs.candidate, field: sort.field)
            switch (left, right) {
            case (.some(_), .none): return true
            case (.none, .some(_)): return false
            case (.some(let left), .some(let right)) where left != right:
                return sort.direction == .ascending ? left < right : left > right
            default: break
            }
            if lhs.candidate.displayName != rhs.candidate.displayName {
                return lhs.candidate.displayName.utf8.lexicographicallyPrecedes(rhs.candidate.displayName.utf8)
            }
            return lhs.url.path.utf8.lexicographicallyPrecedes(rhs.url.path.utf8)
        }
        return (ordered, hasTies, hasMissingValues)
    }

    private static func date(for candidate: Candidate, field: SortField) -> Date? {
        switch field {
        case .modifiedAt: return candidate.modifiedAt
        case .createdAt: return candidate.createdAt
        case .addedToDirectoryAt: return candidate.addedToDirectoryAt
        }
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
