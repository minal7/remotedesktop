import Darwin
import Foundation

/// Owner-only, atomic, fsync-backed journal writes before task effects. Values,
/// payloads, URLs and field labels are deliberately absent from this format.
final class ComputerUseTaskJournalStore {
    private let descriptor: Int32
    enum StoreError: Error { case unavailable, invalidFile }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw StoreError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw StoreError.invalidFile
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    /// A capability may decline only a task it has never accepted. Probe
    /// without creating storage or following a journal symlink. Even a corrupt
    /// or dangling entry is evidence that the task is not known to be fresh;
    /// only ENOENT means absent. Recovery still uses the strict load() path.
    static func hasJournal(taskID: String, directory: URL) throws -> Bool {
        let fd = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            if errno == ENOENT { return false }
            throw StoreError.unavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw StoreError.invalidFile
        }
        let name = ComputerUseTextTaskContract.digest(taskID) + ".json"
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw StoreError.unavailable }
        return false
    }

    func load(taskID: String) throws -> ComputerUseTaskJournal? {
        let name = ComputerUseTextTaskContract.digest(taskID) + ".json"
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw StoreError.unavailable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              (1...65_536).contains(info.st_size) else { throw StoreError.invalidFile }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 65_536 else { throw StoreError.invalidFile }
        let journal = try JSONDecoder().decode(ComputerUseTaskJournal.self, from: data)
        guard journal.taskID == taskID else { throw StoreError.invalidFile }
        return journal
    }

    func save(_ journal: ComputerUseTaskJournal) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 65_536 else { throw StoreError.invalidFile }
        let temporary = ".pending-" + UUID().uuidString
        let name = ComputerUseTextTaskContract.digest(journal.taskID) + ".json"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { unlinkat(descriptor, temporary, 0) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0,
              fsync(descriptor) == 0 else { throw StoreError.unavailable }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remote Desktop Host/Computer Use Tasks/Text Steps", isDirectory: true)
    }
}

typealias ComputerUseTextStepStore = ComputerUseTaskJournalStore
