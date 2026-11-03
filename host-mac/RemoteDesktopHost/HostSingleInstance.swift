import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func hostSingleInstanceFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// A per-user advisory lock that prevents two copies of the same app identity
/// from creating a HostSession or installing menu-bar chrome.
final class HostSingleInstanceLease {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}

enum HostSingleInstance {
    static func acquire(
        bundleIdentifier: String,
        lockDirectory: URL = defaultLockDirectory
    ) throws -> HostSingleInstanceLease? {
        guard !bundleIdentifier.isEmpty else { throw LockError.invalidIdentity }
        try prepareLockDirectory(lockDirectory)

        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let lockURL = lockDirectory.appendingPathComponent("\(digest).lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw LockError.fileSystem(errno) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1 else {
            let code = errno
            Darwin.close(descriptor)
            throw LockError.unsafeLockFile(code)
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LockError.fileSystem(code)
        }

        guard hostSingleInstanceFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw LockError.fileSystem(code)
        }
        return HostSingleInstanceLease(descriptor: descriptor)
    }

    static var defaultLockDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteDesktopHost/InstanceLocks", isDirectory: true)
    }

    private static func prepareLockDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid() else {
            throw LockError.unsafeLockDirectory(errno)
        }
        guard Darwin.chmod(url.path, 0o700) == 0 else {
            throw LockError.fileSystem(errno)
        }
    }

    enum LockError: Error {
        case invalidIdentity
        case unsafeLockDirectory(Int32)
        case unsafeLockFile(Int32)
        case fileSystem(Int32)
    }
}
