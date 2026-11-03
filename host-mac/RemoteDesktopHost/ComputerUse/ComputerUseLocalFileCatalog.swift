import Darwin
import Foundation
import UniformTypeIdentifiers
import CoreServices
import OSLog

/// Metadata-only inventory for files inside one host-approved directory.
/// Candidate IDs are local references; they never encode or expose a path.
struct ComputerUseLocalFileCatalog: Sendable {
    enum FileKind: String, Equatable, Sendable { case any, presentation, spreadsheet, document }
    enum SortField: String, Equatable, Sendable { case modifiedAt, createdAt, addedToDirectoryAt }
    enum SortDirection: String, Equatable, Sendable { case ascending, descending }
    enum FolderScope: String, CaseIterable, Equatable, Sendable { case all, downloads, documents, desktop, iCloud }

    struct ApprovedRoot: Equatable, Sendable {
        let label: String
        let scope: FolderScope
        let url: URL

        init(label: String, scope: FolderScope, url: URL) {
            self.label = label
            self.scope = scope
            self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    struct Sort: Equatable, Sendable {
        let field: SortField
        let direction: SortDirection
    }

    struct Query: Equatable, Sendable {
        static let maximumNameContainsUTF8Bytes = 512
        let fileKind: FileKind
        let sort: Sort?
        let nameContains: String
        let folderScope: FolderScope

        init(fileKind: FileKind = .any, sort: Sort? = nil, nameContains: String = "",
             folderScope: FolderScope = .all) {
            self.fileKind = fileKind
            self.sort = sort
            self.nameContains = nameContains
            self.folderScope = folderScope
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
        let folderLabel: String

        init(id: String, displayName: String, contentTypeIdentifier: String?, fileExtension: String,
             byteCount: Int64, modifiedAt: Date?, createdAt: Date?, addedToDirectoryAt: Date?,
             folderLabel: String = "") {
            self.id = id
            self.displayName = displayName
            self.contentTypeIdentifier = contentTypeIdentifier
            self.fileExtension = fileExtension
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
            self.createdAt = createdAt
            self.addedToDirectoryAt = addedToDirectoryAt
            self.folderLabel = folderLabel
        }
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
        case spotlightUnavailable
        case spotlightTimedOut
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
        let rootURL: URL
        let identity: FileIdentity
    }

    private let taskID: String
    private let approvedRoots: [ApprovedRoot]
    private let usesSpotlight: Bool
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
    private static let spotlightLogger = Logger(
        subsystem: "com.threadmark.remotedesktop",
        category: "LocalFileCatalog")

    init(taskID: String, approvedDirectory: URL, pageSize: Int = 64,
         maximumCandidates: Int = 4096, maximumEntriesScanned: Int = 16_384) throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 256 else { throw Failure.invalidTask }
        guard approvedDirectory.isFileURL else { throw Failure.invalidDirectory }
        self.taskID = taskID
        let root = approvedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let scope: FolderScope
        switch root.lastPathComponent.lowercased() {
        case "downloads": scope = .downloads
        case "documents": scope = .documents
        case "desktop": scope = .desktop
        case "com~apple~clouddocs": scope = .iCloud
        default: scope = .all
        }
        self.approvedRoots = [ApprovedRoot(label: scope == .iCloud ? "iCloud Drive" : root.lastPathComponent,
            scope: scope, url: root)]
        self.usesSpotlight = false
        self.pageSize = min(max(pageSize, 1), 128)
        self.maximumCandidates = min(max(maximumCandidates, 1), 4096)
        self.maximumEntriesScanned = min(max(maximumEntriesScanned, 1), 65_536)
    }

    init(taskID: String, approvedRoots: [ApprovedRoot], pageSize: Int = 64,
         maximumCandidates: Int = 4096, maximumEntriesScanned: Int = 16_384,
         usesSpotlight: Bool = false) throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 256 else { throw Failure.invalidTask }
        guard !approvedRoots.isEmpty, approvedRoots.count <= 4,
              approvedRoots.allSatisfy({ $0.url.isFileURL && !$0.label.isEmpty && $0.scope != .all }),
              Set(approvedRoots.map(\.scope)).count == approvedRoots.count else {
            throw Failure.invalidDirectory
        }
        self.taskID = taskID
        self.approvedRoots = approvedRoots
        self.usesSpotlight = usesSpotlight
        self.pageSize = min(max(pageSize, 1), 128)
        self.maximumCandidates = min(max(maximumCandidates, 1), 4096)
        self.maximumEntriesScanned = min(max(maximumEntriesScanned, 1), 65_536)
    }

    static func standardApprovedRoots(fileManager: FileManager = .default) -> [ApprovedRoot] {
        let home = fileManager.homeDirectoryForCurrentUser
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Documents", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads", isDirectory: true)
        let iCloud = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        let roots = [
            ApprovedRoot(label: "Documents", scope: .documents, url: documents),
            ApprovedRoot(label: "Desktop", scope: .desktop, url: desktop),
            ApprovedRoot(label: "Downloads", scope: .downloads, url: downloads),
            ApprovedRoot(label: "iCloud Drive", scope: .iCloud, url: iCloud),
        ]
        return roots.filter { root in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: root.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    mutating func discover() throws -> Page {
        try discover(query: Query())
    }

    mutating func discover(query: Query) throws -> Page {
        try discover(query: query, suppliedURLs: nil)
    }

    private mutating func discover(query: Query, suppliedURLs: [URL]?,
                                   spotlightResultCount: Int? = nil) throws -> Page {
        records.removeAll(keepingCapacity: true)
        candidateRecords.removeAll(keepingCapacity: true)
        cursors.removeAll(keepingCapacity: true)
        inventoryWasTruncated = (spotlightResultCount ?? 0) > maximumEntriesScanned
        hasInventory = false
        queryHasTiedSortValues = false
        queryHasMissingSortValues = false
        currentQuery = nil

        guard query.isValid else { throw Failure.invalidQuery }
        let roots = approvedRoots.filter {
            query.folderScope == .all || $0.scope == query.folderScope || $0.scope == .all
        }
        guard !roots.isEmpty else { throw Failure.invalidDirectory }
        let availableRoots = roots.filter { root in
            guard let identity = Self.lstat(root.url) else { return false }
            return identity.isDirectory
        }
        guard !availableRoots.isEmpty else { throw Failure.invalidDirectory }
        var entries: [(url: URL, root: ApprovedRoot)] = []
        if let suppliedURLs {
            for url in suppliedURLs.prefix(maximumEntriesScanned + 1) {
                guard let root = Self.root(containing: url, among: availableRoots) else { continue }
                entries.append((url, root))
            }
            if suppliedURLs.count > maximumEntriesScanned { inventoryWasTruncated = true }
        } else {
            var scannedEntries = 0
            var scanError = false
            for root in availableRoots {
                guard let rootIdentity = Self.lstat(root.url), rootIdentity.isDirectory else { continue }
                guard let enumerator = FileManager.default.enumerator(at: root.url,
                    includingPropertiesForKeys: [], options: [], errorHandler: { _, _ in
                        scanError = true
                        return false
                    }) else { continue }
                while let next = enumerator.nextObject() {
                    guard let url = next as? URL else { throw Failure.entryMetadataUnavailable }
                    scannedEntries += 1
                    if scannedEntries > maximumEntriesScanned {
                        inventoryWasTruncated = true
                        break
                    }
                    guard let identity = Self.lstat(url) else { throw Failure.entryMetadataUnavailable }
                    if identity.isSymbolicLink || identity.isDirectory {
                        enumerator.skipDescendants()
                        continue
                    }
                    if identity.isRegularFile { entries.append((url, root)) }
                }
                if inventoryWasTruncated { break }
            }
            if scanError { throw Failure.directoryUnavailable }
        }

        for entry in entries {
            let url = entry.url
            guard let identity = Self.lstat(url) else { throw Failure.entryMetadataUnavailable }
            guard identity.isRegularFile, !identity.isSymbolicLink else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isContained(resolved, in: entry.root.url) else { continue }
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
                createdAt: metadata.createdAt, addedToDirectoryAt: metadata.addedToDirectoryAt,
                folderLabel: entry.root.label)
            let record = Record(candidate: candidate, url: resolved,
                rootURL: entry.root.url,
                identity: FileIdentity(posix: identity, metadata: metadata))
            records.append(record)
            candidateRecords[candidate.id] = record
        }
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

    /// Returns a candidate only when the complete current inventory proves a
    /// unique selection. A date-sorted query may select a unique top-ranked
    /// candidate; an unranked query requires exactly one result in the entire
    /// inventory, not merely one item on the current page.
    func automaticSelectionCandidate(for query: Query) -> Candidate? {
        guard hasInventory, currentQuery == query, !inventoryWasTruncated else { return nil }
        switch rankedBestCandidates(for: query) {
        case .ids(let ids) where ids.count == 1: return candidateRecords[ids[0]]?.candidate
        case .unranked where records.count == 1: return records.first?.candidate
        case .ids, .unranked, .incomplete, .missingBestValue: return nil
        }
    }

    /// Performs bounded filesystem enumeration on its own serial worker. The
    /// caller's catalog is copied so a timeout/cancellation cannot publish a
    /// partial or late mutation back into task scope.
    func discoverOffMainActor(query: Query, timeout: TimeInterval = 20) async throws -> Discovery {
        let original = self
        if usesSpotlight {
            let deadline = Date().addingTimeInterval(max(0.001, timeout))
            let search = try await SpotlightQueryWaiter.search(
                roots: approvedRoots.filter {
                    query.folderScope == .all || $0.scope == query.folderScope || $0.scope == .all
                },
                nameContains: query.nameContains,
                maximumResults: maximumEntriesScanned + 1, timeout: timeout)
            let remaining = max(0.001, deadline.timeIntervalSinceNow)
            let discovery = try await Self.discoveryWorker.perform(timeout: remaining) {
                var catalog = original
                let page = try catalog.discover(query: query, suppliedURLs: search.urls,
                    spotlightResultCount: search.resultCount)
                return Discovery(catalog: catalog, page: page)
            }
            let sortField = query.sort?.field.rawValue ?? "none"
            let sortDirection = query.sort?.direction.rawValue ?? "none"
            let containsPathSeparator = query.nameContains.contains("/") || query.nameContains.contains("\\")
            Self.spotlightLogger.notice(
                "Spotlight discovery kind=\(query.fileKind.rawValue, privacy: .public) folder_scope=\(query.folderScope.rawValue, privacy: .public) sort_field=\(sortField, privacy: .public) direction=\(sortDirection, privacy: .public) filter_bytes=\(query.nameContains.utf8.count, privacy: .public) filter_has_path_separator=\(containsPathSeparator, privacy: .public) spotlight_result_count=\(search.resultCount, privacy: .public) candidate_count=\(discovery.catalog.records.count, privacy: .public) complete=\(discovery.page.isComplete, privacy: .public) has_next_cursor=\(discovery.page.nextCursor != nil, privacy: .public) has_tied_sort_values=\(discovery.page.hasTiedSortValues, privacy: .public) has_missing_sort_values=\(discovery.page.hasMissingSortValues, privacy: .public)")
            return discovery
        }
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
              Self.isContained(freshURL.standardizedFileURL.resolvingSymlinksInPath(), in: record.rootURL) else {
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

    private static func root(containing url: URL, among roots: [ApprovedRoot]) -> ApprovedRoot? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return roots
            .filter { isContained(resolved, in: $0.url) }
            .max { $0.url.pathComponents.count < $1.url.pathComponents.count }
    }

}

@MainActor
private final class SpotlightQueryWaiter {
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<Void, Error>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    static func search(roots: [ComputerUseLocalFileCatalog.ApprovedRoot], nameContains: String, maximumResults: Int,
                      timeout: TimeInterval) async throws -> (urls: [URL], resultCount: Int) {
        guard !roots.isEmpty else { throw ComputerUseLocalFileCatalog.Failure.invalidDirectory }
        let waiter = SpotlightQueryWaiter()
        try await waiter.wait(roots: roots, nameContains: nameContains, timeout: timeout)
        let resultCount = waiter.query.resultCount
        let urls: [URL] = (0..<min(resultCount, maximumResults)).compactMap { index in
            guard let item = waiter.query.result(at: index) as? NSMetadataItem else { return nil }
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL { return url }
            return (item.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
        }
        return (urls, resultCount)
    }

    private func wait(roots: [ComputerUseLocalFileCatalog.ApprovedRoot], nameContains: String, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        query.searchScopes = roots.map(\.url)
        query.predicate = nameContains.isEmpty
            ? NSPredicate(format: "kMDItemFSName != nil")
            : NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", nameContains)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: query,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.finish(.success(())) }
                }
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0.001, timeout))) }
                    catch { return }
                    self?.finish(.failure(ComputerUseLocalFileCatalog.Failure.spotlightTimedOut))
                }
                guard query.start() else {
                    finish(.failure(ComputerUseLocalFileCatalog.Failure.spotlightUnavailable))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        query.stop()
        continuation.resume(with: result)
    }
}
