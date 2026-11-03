import Darwin
import Foundation

/// Narrow unlink boundary so restart-recovery failures can be injected without touching the host.
protocol ForgetRecoveryFileOperations: Sendable {
    func removeItem(at url: URL) throws
}

struct LocalForgetRecoveryFileOperations: ForgetRecoveryFileOperations {
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// The exact Keychain item persists the fact that all inventoried vault deletes completed.
/// Keychain protects its payload; the payload contains no item IDs, values, or filesystem path.
enum ForgetRecoveryJournal {
    static let account = "forget-files-pending-v1"
    private static let prefix = "PMFR1"
    private static let maximumPayloadSize = 1_024

    static func item(namespace: KeychainNamespace) -> ExactKeychainItem {
        ExactKeychainItem(service: namespace.databaseKeyService + ".forget-recovery",
            account: account, protection: .deviceOnlyWhenUnlocked)
    }

    /// Canonical root device/inode and exact namespaces bind the marker without storing paths.
    static func payload(root: URL, namespace: KeychainNamespace) throws -> Data {
        let identity = try rootIdentity(root)
        let databaseNamespace = Data(namespace.databaseKeyService.utf8).base64EncodedString()
        let vaultNamespace = Data(namespace.vaultService.utf8).base64EncodedString()
        let value = "\(prefix)|\(identity.device)|\(identity.inode)|\(databaseNamespace)|\(vaultNamespace)"
        let data = Data(value.utf8)
        guard !data.isEmpty, data.count <= maximumPayloadSize else {
            throw MemoryFactoryError.unsafeForgetJournal
        }
        return data
    }

    static func prepare(client: any KeychainClient, root: URL,
                        namespace: KeychainNamespace) throws {
        // Refuse tampered paths before publishing a marker or allowing key teardown.
        _ = try validateCleanupPaths(root: root)
        let marker = item(namespace: namespace)
        let expected = try payload(root: root, namespace: namespace)
        do {
            let existing = try client.copy(marker)
            guard existing == expected else { throw MemoryFactoryError.unsafeForgetJournal }
        } catch KeychainBoundaryError.missingItem {
            do { try client.add(marker, data: expected) }
            catch KeychainBoundaryError.duplicateItem {
                let existing = try client.copy(marker)
                guard existing == expected else { throw MemoryFactoryError.unsafeForgetJournal }
            }
        }
    }

    static func requireNoPendingMarker(client: any KeychainClient, root: URL,
                                       namespace: KeychainNamespace) throws {
        do {
            let existing = try client.copy(item(namespace: namespace))
            guard existing == (try payload(root: root, namespace: namespace)) else {
                throw MemoryFactoryError.unsafeForgetJournal
            }
            throw MemoryFactoryError.forgetRecoveryRequired
        } catch KeychainBoundaryError.missingItem {
            return
        }
    }

    static func hasValidPendingMarker(client: any KeychainClient, root: URL,
                                      namespace: KeychainNamespace) throws -> Bool {
        do {
            let data = try client.copy(item(namespace: namespace))
            guard data.count <= maximumPayloadSize,
                  data == (try payload(root: root, namespace: namespace)) else {
                throw MemoryFactoryError.unsafeForgetJournal
            }
            return true
        } catch KeychainBoundaryError.missingItem {
            return false
        }
    }

    /// A fresh generation may be reserved only after the previous generation's exact Forget
    /// marker is valid and every old database artifact and its exact key are absent.
    static func requireCompletedForget(client: any KeychainClient, root: URL,
                                       namespace: KeychainNamespace) throws {
        guard try hasValidPendingMarker(client: client, root: root, namespace: namespace) else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        let files = try validateCleanupPaths(root: root)
        guard try files.allSatisfy({ try !validateRegularFile($0) }) else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        let key = ExactKeychainItem(service: namespace.databaseKeyService, account: "database-key",
                                    protection: .deviceOnlyWhenUnlocked)
        do {
            var bytes = try client.copy(key)
            bytes.resetBytes(in: 0..<bytes.count)
            throw MemoryFactoryError.forgetRecoveryRequired
        } catch KeychainBoundaryError.missingItem { }
    }

    static func recover(client: any KeychainClient, root: URL, namespace: KeychainNamespace,
                       fileOperations: any ForgetRecoveryFileOperations) throws -> Bool {
        let marker = item(namespace: namespace)
        let data: Data
        do { data = try client.copy(marker) }
        catch KeychainBoundaryError.missingItem { return false }
        guard data.count <= maximumPayloadSize,
              data == (try payload(root: root, namespace: namespace)) else {
            throw MemoryFactoryError.unsafeForgetJournal
        }

        // Validate all paths before deleting the key. The private root + lifecycle lease keep
        // this set bounded and serialize cooperating service instances across processes.
        let files = try validateCleanupPaths(root: root)
        let databaseKey = ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        do {
            var keyMaterial = try client.copy(databaseKey)
            keyMaterial.resetBytes(in: 0..<keyMaterial.count)
            try client.delete(databaseKey)
        } catch KeychainBoundaryError.missingItem { }
        do {
            var remainingKeyMaterial = try client.copy(databaseKey)
            remainingKeyMaterial.resetBytes(in: 0..<remainingKeyMaterial.count)
            throw MemoryFactoryError.unsafeForgetJournal
        } catch KeychainBoundaryError.missingItem { }

        // Sidecars first and DB last. Missing paths are expected after an interrupted retry.
        for file in files { try removeIfPresent(file, fileOperations: fileOperations) }
        return true
    }

    private static func rootIdentity(_ root: URL) throws -> (device: UInt64, inode: UInt64) {
        guard root.isFileURL, root.path.hasPrefix("/"),
              !root.path.split(separator: "/").contains("..") else {
            throw MemoryFactoryError.unsafeDirectory
        }
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            throw MemoryFactoryError.unsafeDirectory
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private static func validateCleanupPaths(root: URL) throws -> [URL] {
        _ = try rootIdentity(root)
        let database = root.appendingPathComponent("memory.sqlite", isDirectory: false)
        let files = ["-wal", "-shm", "-journal"].map {
            URL(fileURLWithPath: database.path + $0)
        } + [database]
        for file in files { _ = try validateRegularFile(file) }
        return files
    }

    private static func validateRegularFile(_ url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else { throw MemoryFactoryError.unsafeDatabase }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, (info.st_mode & 0o777) == 0o600 else {
            throw MemoryFactoryError.unsafeDatabase
        }
        return true
    }

    private static func removeIfPresent(_ url: URL,
                                        fileOperations: any ForgetRecoveryFileOperations) throws {
        guard try validateRegularFile(url) else { return }
        try fileOperations.removeItem(at: url)
        let stillExists = try validateRegularFile(url)
        guard !stillExists else { throw MemoryFactoryError.unsafeDatabase }
    }
}

extension MemoryStoreFactory {
    /// Completes an owner-authorized Forget after host quiescence. Disabled by default.
    static func recoverForgetForTesting(
        enabled: Bool,
        root: URL,
        client: any KeychainClient,
        namespace: KeychainNamespace,
        fileOperations: any ForgetRecoveryFileOperations = LocalForgetRecoveryFileOperations()
    ) throws -> Bool {
        guard enabled else { return false }
        guard try ForgetRecoveryJournal.hasValidPendingMarker(client: client, root: root,
            namespace: namespace) else { return false }
        let lease = VaultLifecycleLease(root: root)
        return try lease.withExclusive {
            guard try ForgetRecoveryJournal.hasValidPendingMarker(client: client, root: root,
                namespace: namespace) else { return false }
            let participants = try MemoryServiceResourceRegistry.shared.snapshot(root: root,
                namespace: namespace)
            try PersonalMemoryService.recoveryCleanup(participants)
            return try ForgetRecoveryJournal.recover(client: client, root: root,
                namespace: namespace, fileOperations: fileOperations)
        }
    }
}
