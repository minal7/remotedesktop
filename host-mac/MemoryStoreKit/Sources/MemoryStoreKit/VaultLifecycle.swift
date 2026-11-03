import Darwin
import Foundation

enum VaultLifecycleLeaseError: Error, Equatable {
    case busy
    case unsafeLock
    case reentrant
    case cancelled
    case unavailable
}

enum VaultLifecycleLeaseKind: Equatable {
    case vault
    case generationTransition
}

/// Serializes managed vault operations across service instances and processes.
/// The lock file is permanent for the storage root and is never unlinked.
final class VaultLifecycleLease: @unchecked Sendable {
    private static let reentrancyPrefix = "MemoryStoreKit.VaultLifecycleLease."
    private let root: URL
    private let lockURL: URL
    private let reentrancyKey: String

    init(root: URL, kind: VaultLifecycleLeaseKind = .vault) {
        self.root = root
        let name: String
        switch kind {
        case .vault: name = ".vault-lifecycle.lock"
        case .generationTransition: name = ".generation-transition.lock"
        }
        lockURL = root.appendingPathComponent(name, isDirectory: false)
        reentrancyKey = Self.reentrancyPrefix + name + "." + lockURL.path
    }

    var isHeldByCurrentThread: Bool {
        (Thread.current.threadDictionary[reentrancyKey] as? Int ?? 0) > 0
    }

    static func isHeldByCurrentThread(root: URL, kind: VaultLifecycleLeaseKind) -> Bool {
        let name = kind == .vault ? ".vault-lifecycle.lock" : ".generation-transition.lock"
        let key = reentrancyPrefix + name + "." + root.appendingPathComponent(name).path
        return (Thread.current.threadDictionary[key] as? Int ?? 0) > 0
    }

    func withExclusive<T>(timeout: TimeInterval = 1.0,
                          _ operation: () throws -> T) throws -> T {
        try withExclusiveObservingLock(timeout: timeout) { _ in try operation() }
    }

    /// The closure receives true only when this call atomically created the permanent lock file.
    /// This lets the first factory opening distinguish initial setup from a deleted generation.
    func withExclusiveObservingLock<T>(timeout: TimeInterval = 1.0,
                                       _ operation: (Bool) throws -> T) throws -> T {
        guard timeout.isFinite, timeout >= 0, timeout <= 10 else { throw VaultLifecycleLeaseError.unavailable }
        guard !currentTaskIsCancelled() else { throw VaultLifecycleLeaseError.cancelled }
        guard !isHeldByCurrentThread else { throw VaultLifecycleLeaseError.reentrant }

        var rootInfo = stat()
        guard root.path.withCString({ lstat($0, &rootInfo) }) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == getuid(), (rootInfo.st_mode & 0o777) == 0o700 else {
            throw VaultLifecycleLeaseError.unsafeLock
        }

        guard !currentTaskIsCancelled() else { throw VaultLifecycleLeaseError.cancelled }
        var createdLock = false
        var descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        if descriptor >= 0 {
            createdLock = true
        } else if errno == EEXIST {
            descriptor = lockURL.path.withCString {
                Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard descriptor >= 0 else { throw VaultLifecycleLeaseError.unsafeLock }
        defer { _ = Darwin.close(descriptor) }

        var lockInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0,
              lockURL.path.withCString({ lstat($0, &pathInfo) }) == 0,
              lockInfo.st_dev == pathInfo.st_dev, lockInfo.st_ino == pathInfo.st_ino,
              (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1,
              (lockInfo.st_mode & 0o777) == 0o600 else {
            throw VaultLifecycleLeaseError.unsafeLock
        }

        let deadline = DispatchTime.now() + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw VaultLifecycleLeaseError.unavailable
            }
            guard !currentTaskIsCancelled() else { throw VaultLifecycleLeaseError.cancelled }
            guard DispatchTime.now() < deadline else { throw VaultLifecycleLeaseError.busy }
            usleep(5_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard !currentTaskIsCancelled() else { throw VaultLifecycleLeaseError.cancelled }

        Thread.current.threadDictionary[reentrancyKey] = 1
        defer { Thread.current.threadDictionary.removeObject(forKey: reentrancyKey) }
        return try operation(createdLock)
    }

    private func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }
}
