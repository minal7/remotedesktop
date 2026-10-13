import Darwin
import Foundation
import CryptoKit

// Avoid the Darwin struct/function name collision, as in the installer.
@_silgen_name("flock")
private func computerUseJournalFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Owner-only, atomic, fsync-backed journal writes before task effects. Values,
/// payloads, URLs and field labels are deliberately absent from this format.
final class ComputerUseTaskJournalStore {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private let descriptor: Int32
    private let operationLock = NSLock()
    private var writeFailed = false
    private var executionOwners: [String: WeakExecutionLease] = [:]
    private let afterReplacement: (() throws -> Void)?
    enum StoreError: Error, Equatable, LocalizedError {
        case unavailable, invalidFile, busy, staleJournal, invalidTransition

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Another operation is updating this task's saved progress. Check the Mac before starting another request."
            case .staleJournal:
                return "This task's saved progress changed. I couldn't safely continue from the older state. Check the Mac before starting another request."
            case .invalidFile, .invalidTransition, .unavailable:
                return "I couldn't safely read or save this task's progress. Check what happened on the Mac before starting another request."
            }
        }
    }

    /// The optional callback permits a fixture to fail after rename, when the
    /// new state is visible but its durable commit is still unconfirmed.
    init(directory: URL, afterReplacement: (() throws -> Void)? = nil) throws {
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
        self.afterReplacement = afterReplacement
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
        let name = ComputerUseTaskJournalStore.digest(taskID) + ".json"
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw StoreError.unavailable }
        return false
    }

    func load(taskID: String) throws -> ComputerUseTaskJournal? {
        try withJournalLock(taskID: taskID, exclusive: false) { try readJournal(taskID: taskID) }
    }

    /// Retained by one run through its actual return, including cancellation
    /// unwind. A newer runner must neither reconcile nor observe its effects
    /// while that owner is still inside an adapter call.
    func acquireExecution(taskID: String, expected: ComputerUseTaskJournal?) throws -> any ComputerUseTaskExecutionLease {
        try withStoreOperation {
            let stem = ComputerUseTaskJournalStore.digest(taskID)
            let name = stem + ".execution.lock"
            let fd = try openLock(name: name, exclusive: true)
            let lease = ExecutionLease(store: self, name: name, descriptor: fd)
            do {
                let journalLock = try openLock(name: stem + ".lock", exclusive: false)
                defer { close(journalLock) }
                guard Self.matches(try readJournal(taskID: taskID), expected) else { throw StoreError.staleJournal }
                try lease.assertOwnership()
                executionOwners[name] = WeakExecutionLease(lease)
                return lease
            } catch {
                lease.release()
                throw error
            }
        }
    }

    private final class WeakExecutionLease {
        weak var value: ExecutionLease?
        init(_ value: ExecutionLease) { self.value = value }
    }

    private final class ExecutionLease: ComputerUseTaskExecutionLease {
        private let store: ComputerUseTaskJournalStore
        private let name: String
        private let descriptor: Int32
        private let lock = NSLock()
        private var released = false

        init(store: ComputerUseTaskJournalStore, name: String, descriptor: Int32) {
            self.store = store
            self.name = name
            self.descriptor = descriptor
        }

        deinit { release() }

        var isActive: Bool { lock.withLock { !released } }

        func assertOwnership() throws {
            try lock.withLock {
                guard !released else { throw StoreError.unavailable }
                var held = stat(), current = stat()
                guard fstat(descriptor, &held) == 0, held.st_mode & S_IFMT == S_IFREG,
                      held.st_uid == getuid(), held.st_mode & 0o777 == 0o600, held.st_nlink == 1,
                      fstatat(store.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == held.st_dev, current.st_ino == held.st_ino else { throw StoreError.invalidFile }
            }
        }

        func release() {
            lock.withLock {
                guard !released else { return }
                released = true
                close(descriptor)
            }
        }
    }

    private func readJournal(taskID: String) throws -> ComputerUseTaskJournal? {
        let name = ComputerUseTaskJournalStore.digest(taskID) + ".json"
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw StoreError.unavailable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              (1...65_536).contains(info.st_size) else { throw StoreError.invalidFile }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 65_536 else { throw StoreError.invalidFile }
        let journal = try JSONDecoder().decode(ComputerUseTaskJournal.self, from: data)
        guard journal.taskID.utf8.elementsEqual(taskID.utf8), Self.isValid(journal) else { throw StoreError.invalidFile }
        return journal
    }

    /// Compare and advance under the same cross-instance lock. The caller must
    /// supply the last state it actually loaded or successfully committed;
    /// nil means it observed no journal. A failed comparison never authorizes
    /// an effect or refreshes that caller's expected state.
    func save(_ journal: ComputerUseTaskJournal, replacing expected: ComputerUseTaskJournal?) throws {
        guard Self.isValid(journal), expected.map(Self.isValid) ?? true else { throw StoreError.invalidFile }
        guard Self.isAllowedTransition(from: expected, to: journal) else { throw StoreError.invalidTransition }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 65_536 else { throw StoreError.invalidFile }
        try withJournalLock(taskID: journal.taskID, exclusive: true) {
            let current = try readJournal(taskID: journal.taskID)
            guard Self.matches(current, expected) else { throw StoreError.staleJournal }
            if Self.matches(current, journal) { return }
            // Once writing begins, an error can leave a visible replacement
            // whose fsync was not confirmed. This store cannot keep advancing
            // from its old in-memory expectation after that ambiguity.
            do { try replace(data, taskID: journal.taskID) }
            catch { writeFailed = true; throw error }
        }
    }

    /// Confirm the original attempted state before completing a native tail.
    /// A prior rename may be visible without confirmed directory durability.
    /// This requires the caller's active execution lease and exact saved state;
    /// it changes no identity or status and cannot authorize an absent attempt.
    func confirmPendingAttempt(_ expected: ComputerUseTaskJournal) throws {
        guard Self.isValid(expected), expected.retirementDigest == nil, expected.retainedPrefixCount == nil,
              let status = expected.statuses.first(where: { $0 != .verified }),
              status == .attempted || status == .uncertain else { throw StoreError.invalidTransition }
        try confirmRecoveredProgress(expected)
    }

    /// Reopening a visible replacement does not establish that its directory
    /// entry was committed. Confirm exact unretired progress under this store's
    /// execution lease before using it for recovery or reporting completion.
    func confirmRecoveredProgress(_ expected: ComputerUseTaskJournal) throws {
        guard Self.isValid(expected), expected.retirementDigest == nil, expected.retainedPrefixCount == nil else {
            throw StoreError.invalidTransition
        }
        try withJournalLock(taskID: expected.taskID, exclusive: true) {
            let name = ComputerUseTaskJournalStore.digest(expected.taskID) + ".execution.lock"
            guard let owner = executionOwners[name]?.value, owner.isActive else { throw StoreError.busy }
            try owner.assertOwnership()
            guard Self.matches(try readJournal(taskID: expected.taskID), expected) else { throw StoreError.staleJournal }
            guard fsync(descriptor) == 0 else { throw StoreError.unavailable }
        }
    }

    /// Retire an exact journal with no verified step under an execution lease.
    /// The capability must first prove and revoke its original native input
    /// IDs. A failed write remains ambiguous until a fresh leased load.
    func retireUnsent(_ retired: ComputerUseTaskJournal, replacing expected: ComputerUseTaskJournal?) throws {
        guard Self.isValid(retired), expected.map(Self.isValid) ?? true,
              retired.retainedPrefixCount == nil, expected?.retainedPrefixCount == nil,
              let digest = retired.retirementDigest, !retired.statuses.contains(.verified),
              expected.map({ Self.sameIdentity($0, retired) && $0.statuses == retired.statuses
                  && ($0.retirementDigest == nil || $0.retirementDigest == digest) }) ?? true else { throw StoreError.invalidTransition }
        try writeRetirement(retired, replacing: expected)
    }

    /// Keep the exact verified input prefix and retire its unsent remainder.
    /// Zero input steps may be retained only when the capability has a separate
    /// native observation proof. The caller must verify those native origins
    /// and revoke every remaining ID first. Statuses are never reset. This
    /// storage marker cannot itself authorize a continuation or an effect.
    func retireRemainingInput(_ retired: ComputerUseTaskJournal, replacing expected: ComputerUseTaskJournal) throws {
        guard Self.isValid(retired), Self.isValid(expected),
              let digest = retired.retirementDigest, let count = retired.retainedPrefixCount,
              Self.sameIdentity(expected, retired), expected.statuses == retired.statuses,
              (expected.retirementDigest == nil && expected.retainedPrefixCount == nil)
                || (expected.retirementDigest == digest && expected.retainedPrefixCount == count) else {
            throw StoreError.invalidTransition
        }
        try writeRetirement(retired, replacing: expected)
    }

    private func writeRetirement(_ retired: ComputerUseTaskJournal, replacing expected: ComputerUseTaskJournal?) throws {
        let data = try JSONEncoder().encode(retired)
        guard data.count <= 65_536 else { throw StoreError.invalidFile }
        try withJournalLock(taskID: retired.taskID, exclusive: true) {
            let name = ComputerUseTaskJournalStore.digest(retired.taskID) + ".execution.lock"
            guard let owner = executionOwners[name]?.value, owner.isActive else { throw StoreError.busy }
            try owner.assertOwnership()
            let current = try readJournal(taskID: retired.taskID)
            guard Self.matches(current, expected) else { throw StoreError.staleJournal }
            if Self.matches(current, retired) {
                guard fsync(descriptor) == 0 else { throw StoreError.unavailable }
                return
            }
            do { try replace(data, taskID: retired.taskID) }
            catch { writeFailed = true; throw error }
        }
    }

    private func replace(_ data: Data, taskID: String) throws {
        let temporary = ".pending-" + UUID().uuidString
        let name = ComputerUseTaskJournalStore.digest(taskID) + ".json"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Keep the owning handle alive through both synchronization calls.
        defer { try? handle.close(); unlinkat(descriptor, temporary, 0) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0 else { throw StoreError.unavailable }
        try afterReplacement?()
        guard fsync(descriptor) == 0 else { throw StoreError.unavailable }
    }

    private func withStoreOperation<Value>(_ body: () throws -> Value) throws -> Value {
        guard operationLock.try() else { throw StoreError.busy }
        defer { operationLock.unlock() }
        guard !writeFailed else { throw StoreError.unavailable }
        return try body()
    }

    private func withJournalLock<Value>(taskID: String, exclusive: Bool, _ body: () throws -> Value) throws -> Value {
        try withStoreOperation {
            let stem = ComputerUseTaskJournalStore.digest(taskID)
            var temporaryExecutionLock: Int32?
            defer { if let temporaryExecutionLock { close(temporaryExecutionLock) } }
            if exclusive {
                let executionName = stem + ".execution.lock"
                if let owner = executionOwners[executionName]?.value, owner.isActive {
                    try owner.assertOwnership()
                } else {
                    executionOwners.removeValue(forKey: executionName)
                    // A standalone writer must also stay out of a live run.
                    // Acquire in the same execution -> journal order as a run.
                    temporaryExecutionLock = try openLock(name: executionName, exclusive: true)
                }
            }
            let name = stem + ".lock"
            let fd = try openLock(name: name, exclusive: exclusive)
            defer { close(fd) }
            return try body()
        }
    }

    private func openLock(name: String, exclusive: Bool) throws -> Int32 {
        // Lock a stable sibling, never the replaceable journal inode. All
        // cooperating stores keep this file; unlinking it would split locks.
        let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw StoreError.invalidFile }
        guard computerUseJournalFlock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw StoreError.busy }
            throw StoreError.unavailable
        }
        var current = stat()
        guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino else { throw StoreError.invalidFile }
        transferred = true
        return fd
    }

    private static func isValid(_ journal: ComputerUseTaskJournal) -> Bool {
        func validID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard validID(journal.taskID), validDigest(journal.promptDigest), validDigest(journal.contractDigest),
              (1...64).contains(journal.stepIDs.count), journal.stepIDs.allSatisfy(validID),
              Set(journal.stepIDs).count == journal.stepIDs.count, journal.statuses.count == journal.stepIDs.count else { return false }
        if let digest = journal.retirementDigest {
            guard validDigest(digest) else { return false }
            if let count = journal.retainedPrefixCount {
                guard count >= 0, count < journal.statuses.count,
                      journal.statuses.prefix(count).allSatisfy({ $0 == .verified }),
                      !journal.statuses.dropFirst(count).contains(.verified) else { return false }
            } else if journal.statuses.contains(.verified) { return false }
        } else if journal.retainedPrefixCount != nil { return false }
        var sawUnverified = false
        for status in journal.statuses {
            if sawUnverified && status != .planned { return false }
            if status != .verified { sawUnverified = true }
        }
        return true
    }

    private static func sameIdentity(_ left: ComputerUseTaskJournal, _ right: ComputerUseTaskJournal) -> Bool {
        left.taskID.utf8.elementsEqual(right.taskID.utf8) && left.promptDigest == right.promptDigest
            && left.contractDigest == right.contractDigest && left.stepIDs.count == right.stepIDs.count
            && zip(left.stepIDs, right.stepIDs).allSatisfy { pair in pair.0.utf8.elementsEqual(pair.1.utf8) }
    }

    private static func matches(_ left: ComputerUseTaskJournal?, _ right: ComputerUseTaskJournal?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (left?, right?): return sameIdentity(left, right) && left.statuses == right.statuses
            && left.retirementDigest == right.retirementDigest && left.retainedPrefixCount == right.retainedPrefixCount
        default: return false
        }
    }

    private static func isAllowedTransition(from previous: ComputerUseTaskJournal?, to next: ComputerUseTaskJournal) -> Bool {
        guard previous?.retirementDigest == nil, next.retirementDigest == nil,
              previous?.retainedPrefixCount == nil, next.retainedPrefixCount == nil else { return false }
        guard let previous else {
            return next.statuses.allSatisfy { $0 == .planned }
                || (next.statuses.first == .attempted && next.statuses.dropFirst().allSatisfy { $0 == .planned })
        }
        guard sameIdentity(previous, next) else { return false }
        let changed = previous.statuses.indices.filter { previous.statuses[$0] != next.statuses[$0] }
        if changed.isEmpty { return true }
        guard changed.count == 1, let index = changed.first else { return false }
        switch (previous.statuses[index], next.statuses[index]) {
        case (.planned, .attempted), (.attempted, .verified), (.attempted, .uncertain), (.uncertain, .verified): return true
        default: return false
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remote Desktop Host/Computer Use Tasks/Text Steps", isDirectory: true)
    }
}

