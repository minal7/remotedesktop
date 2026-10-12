import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

actor AgentFileCatalog {
    enum Failure: Error { case invalidQuery, unsafeRoot, unavailable, tooManyFiles, staleCandidate }

    private struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32
        let links: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct StoredFile: Sendable {
        let root: URL
        let components: [String]
        let name: String
        let ext: String
        let identity: Identity
        let digest: String
        let modifiedAt: Date
    }

    private let roots: [URL]
    private let maximumResults: Int
    private let maximumFileBytes: Int
    private let maximumSearchBytes: Int
    private var knownFiles: [String: StoredFile] = [:]

    init(authorizedRoots: [URL]? = nil, maximumResults: Int = 100,
         maximumFileBytes: Int = 20 * 1_024 * 1_024,
         maximumSearchBytes: Int = 64 * 1_024 * 1_024) {
        roots = (authorizedRoots ?? Self.defaultRoots()).map(\.standardizedFileURL)
        self.maximumResults = max(1, min(maximumResults, 500))
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumSearchBytes = max(self.maximumFileBytes, maximumSearchBytes)
    }

    func find(query: String, kind: String? = nil, modifiedAfter: String? = nil) async throws -> [AgentFileCandidate] {
        let terms = Self.terms(query)
        guard !terms.isEmpty, query.utf8.count <= 256,
              kind.map({ $0.utf8.count <= 128 }) ?? true else { throw Failure.invalidQuery }
        let cutoff = try Self.parseDate(modifiedAfter)
        let roots = self.roots, maxResults = maximumResults
        let maxFileBytes = maximumFileBytes, maxSearchBytes = maximumSearchBytes
        let found = try await Task.detached(priority: .utility) {
            try Self.scan(roots: roots, terms: terms, kind: kind, cutoff: cutoff,
                          maximumResults: maxResults, maximumFileBytes: maxFileBytes,
                          maximumSearchBytes: maxSearchBytes)
        }.value
        knownFiles = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.file) })
        return found.map(\.candidate)
    }

    func resolve(_ ids: [String]) async throws -> [AgentWebFile] {
        guard !ids.isEmpty, ids.count <= 10, Set(ids).count == ids.count,
              let files = Optional(ids.compactMap { knownFiles[$0] }), files.count == ids.count else {
            throw Failure.staleCandidate
        }
        let totalLimit = 32 * 1_024 * 1_024
        guard files.reduce(Int64(0), { $0 + $1.identity.size }) <= totalLimit else { throw Failure.tooManyFiles }
        let maxFileBytes = maximumFileBytes
        return try await Task.detached(priority: .utility) {
            try zip(ids, files).map { id, file in
                try Self.readAndValidate(file, id: id, maximumFileBytes: maxFileBytes)
            }
        }.value
    }

    /// Intended for a host-owned native file picker. The model receives only the opaque ID.
    func fileURL(for id: String) async throws -> URL {
        guard let file = knownFiles[id] else { throw Failure.staleCandidate }
        let maxFileBytes = maximumFileBytes
        return try await Task.detached(priority: .utility) {
            _ = try Self.readAndValidate(file, id: id, maximumFileBytes: maxFileBytes)
            return Self.url(root: file.root, components: file.components)
        }.value
    }

    private struct FoundFile: Sendable {
        let id: String
        let file: StoredFile
        let candidate: AgentFileCandidate
    }

    private struct SearchState {
        let terms: [String]
        let kind: String?
        let cutoff: Date?
        let maximumResults: Int
        let maximumFileBytes: Int
        let maximumSearchBytes: Int
        var bytesHashed = 0
        var filesInspected = 0
        var results: [FoundFile] = []
        var resultTextBytes = 0
        var stopped = false
    }

    private static func scan(roots: [URL], terms: [String], kind: String?, cutoff: Date?,
                             maximumResults: Int, maximumFileBytes: Int,
                             maximumSearchBytes: Int) throws -> [FoundFile] {
        var state = SearchState(terms: terms, kind: kind, cutoff: cutoff,
                                maximumResults: maximumResults, maximumFileBytes: maximumFileBytes,
                                maximumSearchBytes: maximumSearchBytes)
        for root in roots where !state.stopped {
            let fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if fd < 0 {
                if errno == ENOENT { continue }
                throw Failure.unsafeRoot
            }
            do { try walk(fd: fd, root: root, components: [], depth: 0, state: &state) }
            catch { Darwin.close(fd); throw error }
            Darwin.close(fd)
        }
        return state.results.sorted {
            if $0.file.modifiedAt != $1.file.modifiedAt { return $0.file.modifiedAt > $1.file.modifiedAt }
            return $0.file.name.localizedCaseInsensitiveCompare($1.file.name) == .orderedAscending
        }
    }

    private static func walk(fd: Int32, root: URL, components: [String], depth: Int,
                             state: inout SearchState) throws {
        guard depth <= 8, !state.stopped else { return }
        let duplicate = dup(fd)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw Failure.unavailable
        }
        defer { closedir(directory) }
        while let entry = readdir(directory), !state.stopped {
            state.filesInspected += 1
            if state.filesInspected > 10_000 { state.stopped = true; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            var info = stat()
            guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                let child = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard child >= 0 else { continue }
                do { try walk(fd: child, root: root, components: components + [name], depth: depth + 1, state: &state) }
                catch { close(child); throw error }
                close(child)
            } else if type == S_IFREG {
                try consider(fd: fd, name: name, info: info, root: root, components: components, state: &state)
            }
        }
    }

    private static func consider(fd: Int32, name: String, info: stat, root: URL,
                                 components: [String], state: inout SearchState) throws {
        guard info.st_nlink == 1, info.st_size >= 0, info.st_size <= Int64(state.maximumFileBytes),
              let modified = date(seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec)),
              state.cutoff.map({ modified > $0 }) ?? true else { return }
        let normalized = normalize(name)
        guard state.terms.allSatisfy(normalized.contains) else { return }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard !ext.isEmpty, matchesKind(ext, requested: state.kind) else { return }
        guard state.bytesHashed + Int(info.st_size) <= state.maximumSearchBytes else {
            state.stopped = true
            return
        }
        let fileDescriptor = name.withCString {
            openat(fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else { return }
        defer { close(fileDescriptor) }
        var opened = stat()
        guard fstat(fileDescriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1, identity(opened) == identity(info) else { return }
        let bytes = try readBytes(fileDescriptor, expectedSize: Int(info.st_size), maximumBytes: state.maximumFileBytes)
        var after = stat()
        guard fstat(fileDescriptor, &after) == 0, identity(after) == identity(info) else { return }
        state.bytesHashed += bytes.count
        let digest = sha256(bytes)
        let id = UUID().uuidString.lowercased()
        let file = StoredFile(root: root, components: components + [name], name: name, ext: ext,
                              identity: identity(info), digest: digest, modifiedAt: modified)
        let candidate = AgentFileCandidate(id: id, name: name,
            kind: UTType(filenameExtension: ext)?.localizedDescription ?? ext, modifiedAt: modified)
        state.results.append(FoundFile(id: id, file: file, candidate: candidate))
        state.results.sort(by: isNewer)
        if state.results.count > state.maximumResults { state.results.removeLast() }
        state.resultTextBytes = state.results.reduce(0) {
            $0 + $1.id.utf8.count + $1.candidate.name.utf8.count + ($1.candidate.kind?.utf8.count ?? 0) + 96
        }
        while state.resultTextBytes > 32 * 1_024, !state.results.isEmpty {
            state.results.removeLast()
            state.resultTextBytes = state.results.reduce(0) {
                $0 + $1.id.utf8.count + $1.candidate.name.utf8.count + ($1.candidate.kind?.utf8.count ?? 0) + 96
            }
        }
    }

    private static func readAndValidate(_ file: StoredFile, id: String, maximumFileBytes: Int) throws -> AgentWebFile {
        guard !file.components.isEmpty else { throw Failure.staleCandidate }
        let rootFD = file.root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw Failure.unsafeRoot }
        defer { close(rootFD) }
        var directoryFD = rootFD
        var openedDirectories: [Int32] = []
        for component in file.components.dropLast() {
            let next = component.withCString { openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else {
                openedDirectories.forEach { _ = close($0) }
                throw Failure.staleCandidate
            }
            directoryFD = next
            openedDirectories.append(next)
        }
        defer { openedDirectories.forEach { _ = close($0) } }
        guard let name = file.components.last else { throw Failure.staleCandidate }
        let descriptor = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Failure.staleCandidate }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              identity(before) == file.identity else { throw Failure.staleCandidate }
        let bytes = try readBytes(descriptor, expectedSize: Int(before.st_size), maximumBytes: maximumFileBytes)
        var after = stat()
        guard fstat(descriptor, &after) == 0, identity(after) == file.identity,
              sha256(bytes) == file.digest else { throw Failure.staleCandidate }
        return AgentWebFile(id: id, name: file.name,
            mimeType: UTType(filenameExtension: file.ext)?.preferredMIMEType ?? "application/octet-stream",
            lastModified: file.modifiedAt, bytes: bytes)
    }

    private static func readBytes(_ fd: Int32, expectedSize: Int, maximumBytes: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumBytes else { throw Failure.staleCandidate }
        var result = Data(capacity: expectedSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while result.count < expectedSize {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, min($0.count, expectedSize - result.count))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.staleCandidate }
            result.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw Failure.staleCandidate }
        return result
    }

    private static func identity(_ info: stat) -> Identity {
        Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            mode: UInt32(info.st_mode), owner: UInt32(info.st_uid), group: UInt32(info.st_gid), links: UInt64(info.st_nlink),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func date(seconds: Int, nanoseconds: Int) -> Date? {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    private static func isNewer(_ left: FoundFile, _ right: FoundFile) -> Bool {
        if left.file.modifiedAt != right.file.modifiedAt { return left.file.modifiedAt > right.file.modifiedAt }
        return left.file.name.localizedCaseInsensitiveCompare(right.file.name) == .orderedAscending
    }

    private static func matchesKind(_ ext: String, requested: String?) -> Bool {
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !requested.isEmpty else { return true }
        if ext == requested { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        let requestedType: UTType?
        switch requested {
        case "image": requestedType = .image
        case "text": requestedType = .text
        case "audio": requestedType = .audio
        case "movie", "video": requestedType = .movie
        case "pdf": requestedType = .pdf
        case "archive": requestedType = .archive
        default: requestedType = UTType(importedAs: requested)
        }
        if let requestedType, type.conforms(to: requestedType) { return true }
        return type.identifier.lowercased() == requested
    }

    private static func terms(_ query: String) -> [String] {
        normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func parseDate(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw Failure.invalidQuery }
        return date
    }

    private static func url(root: URL, components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1) }
    }

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultRoots() -> [URL] {
        let manager = FileManager.default
        return [manager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                manager.urls(for: .documentDirectory, in: .userDomainMask).first].compactMap { $0 }
    }
}
