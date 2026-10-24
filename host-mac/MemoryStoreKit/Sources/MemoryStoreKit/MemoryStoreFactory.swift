import Darwin
import Foundation

/// The app-facing encrypted memory boundary. It intentionally exposes owner-authorized memory
/// operations, not the lower-level vault or arbitrary SQL storage APIs. Managed vault items are
/// inventoried before writes so whole-product Forget can remove the exact items it created.
public final class PersonalMemoryService: @unchecked Sendable {
    public let writer: OwnerMemoryWriter
    let store: MemoryStore
    private let vault: KeychainVault
    let vaultLease: VaultLifecycleLease
    fileprivate let fillRevocation: VaultFillRevocationDomain
    let keychainClient: any KeychainClient
    let keychainNamespace: KeychainNamespace
    let storageRoot: URL
    let generationBinding: MemoryStoreBinding?

    fileprivate init(store: MemoryStore, authorize: @escaping OwnerMemoryAuthorizer,
                     isTaskActive: @escaping OwnerTaskLiveness,
                     policy: @escaping OwnerMemoryPolicyProvider,
                     client: any KeychainClient, namespace: KeychainNamespace, root: URL,
                     generationBinding: MemoryStoreBinding?) {
        self.store = store
        keychainClient = client
        keychainNamespace = namespace
        storageRoot = root
        self.generationBinding = generationBinding
        fillRevocation = VaultFillRevocationDomain {
            try store.requireActive()
            if try store.isVaultErasurePending() { throw MemoryStoreError.erasurePending }
        }
        writer = OwnerMemoryWriter(store: store, authorize: authorize,
                                   isTaskActive: isTaskActive, policy: policy)
        vault = KeychainVault(client: client, namespace: namespace)
        vaultLease = VaultLifecycleLease(root: root)
    }

    public func close() throws {
        guard !writer.isActiveOnCurrentThread else { throw MemoryStoreError.erasurePending }
        fillRevocation.revoke(.serviceClosed)
        try writer.beginForget()
        try store.close()
    }

    /// Used only before a UUID generation is published. Unpublished generations are never
    /// exposed to a host session, so this check does not manufacture owner authority.
    func isEmptyForGenerationPublication() throws -> Bool {
        try store.requireActive()
        try store.requireEmptyForInitialization()
        return true
    }

    /// Package-test injection point for peer teardown failure.
    func failNextStoreCloseForErasureForTesting() {
        store.injectNextErasureCloseFailureForTesting()
    }

    func storeVaultSecret(_ value: VaultSecretValue, for itemID: VaultItemID,
                          field: VaultSecretField) throws {
        do {
            try vaultLease.withExclusive {
                try store.requireActive()
                try store.registerVaultItem(itemID.uuid)
                try vault.store(value, for: itemID, field: field)
                try store.requireActive()
            }
        } catch {
            throw MemoryFactoryError.vaultOperationFailed
        }
    }

    func withVaultSecret(for itemID: VaultItemID, field: VaultSecretField,
                         _ body: (VaultSecretValue) throws -> Void) throws {
        do {
            try vaultLease.withExclusive {
                try store.requireActive()
                try vault.withSecret(for: itemID, field: field) { value in
                    // A Forget may publish its durable fence while this connection waits for
                    // Keychain. Revalidate after the copy and before the caller can observe it.
                    try store.requireActive()
                    try body(value)
                }
            }
        } catch {
            throw MemoryFactoryError.vaultOperationFailed
        }
    }

    /// Creates a value-free authorization lifecycle within this service's revocation domain.
    func makeVaultFillAuthorizationLifecycle(
        draft: VaultFillApprovalDraft,
        currentRuntime: @escaping @Sendable () -> VaultFillRuntimeSnapshot,
        verifier: any VaultFillTrustedApprovalVerifier,
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws -> VaultFillAuthorizationLifecycle {
        try fillRevocation.requireActive()
        let lifecycle = VaultFillAuthorizationLifecycle(challenge: VaultFillApprovalChallenge(draft: draft),
            currentRuntime: currentRuntime, verifier: verifier,
            revocationDomain: fillRevocation, now: now, monotonicNow: monotonicNow)
        return try fillRevocation.withActive { lifecycle }
    }

    /// Permanently fences this service, purges writer-held proposals, and erases the encrypted
    /// memory database/key and managed vault items. The durable fence and inventory remain
    /// available when an exact-item deletion or key teardown fails, so this method can be retried.
    public func forgetAll() throws {
        guard !vaultLease.isHeldByCurrentThread else { throw MemoryFactoryError.memoryErasureFailed }
        do {
            let initial = try MemoryServiceResourceRegistry.shared.snapshot(
                root: storageRoot, namespace: keychainNamespace)
            try Self.preflight(initial)
            if try ForgetRecoveryJournal.hasValidPendingMarker(client: keychainClient,
                root: storageRoot, namespace: keychainNamespace) {
                try recoverPendingForget()
                return
            }

            // Preserve the preexisting fence-before-lease ordering: in-flight vault reads
            // revalidate against this durable tombstone after their Keychain operation returns.
            do { try store.beginVaultErasure() }
            catch {
                if try ForgetRecoveryJournal.hasValidPendingMarker(client: keychainClient,
                    root: storageRoot, namespace: keychainNamespace) {
                    try recoverPendingForget()
                    return
                }
                throw error
            }

            try vaultLease.withExclusive {
                // A completed peer Forget may have published its marker while this call waited.
                if try ForgetRecoveryJournal.hasValidPendingMarker(client: keychainClient,
                    root: storageRoot, namespace: keychainNamespace) {
                    let participants = try MemoryServiceResourceRegistry.shared.snapshot(
                        root: storageRoot, namespace: keychainNamespace)
                    try Self.preflight(participants)
                    try Self.revokeAndDrain(participants, reason: .memoryForgotten)
                    try Self.closeForRecovery(participants)
                    guard try ForgetRecoveryJournal.recover(client: keychainClient,
                        root: storageRoot, namespace: keychainNamespace,
                        fileOperations: LocalForgetRecoveryFileOperations()) else {
                        throw MemoryFactoryError.unsafeForgetJournal
                    }
                    return
                }
                let participants = try MemoryServiceResourceRegistry.shared.snapshot(
                    root: storageRoot, namespace: keychainNamespace)
                try Self.preflight(participants)
                try Self.revokeAndDrain(participants, reason: .memoryForgotten)
                let ids = try store.vaultItemIDsForErasure()
                try vault.forget(itemIDs: ids.map { VaultItemID(uuid: $0) })
                // The immutable recovery marker must exist before inventory completion,
                // database-key destruction, or file cleanup can begin.
                try ForgetRecoveryJournal.prepare(client: keychainClient,
                    root: storageRoot, namespace: keychainNamespace)
                try store.completeVaultItemErasure()
                try Self.closePeers(participants, excluding: store)
                // Keep database/key teardown in the same cross-process lease as vault deletion.
                try store.forgetAll()
            }
        } catch {
            throw MemoryFactoryError.memoryErasureFailed
        }
    }

    private func recoverPendingForget() throws {
        try vaultLease.withExclusive {
            guard try ForgetRecoveryJournal.hasValidPendingMarker(client: keychainClient,
                root: storageRoot, namespace: keychainNamespace) else {
                throw MemoryFactoryError.unsafeForgetJournal
            }
            let participants = try MemoryServiceResourceRegistry.shared.snapshot(
                root: storageRoot, namespace: keychainNamespace)
            try Self.preflight(participants)
            try Self.revokeAndDrain(participants, reason: .memoryForgotten)
            try Self.closeForRecovery(participants)
            guard try ForgetRecoveryJournal.recover(client: keychainClient,
                root: storageRoot, namespace: keychainNamespace,
                fileOperations: LocalForgetRecoveryFileOperations()) else {
                throw MemoryFactoryError.unsafeForgetJournal
            }
        }
    }

    private static func preflight(_ participants: MemoryServiceResourceRegistry.Snapshot) throws {
        guard !participants.writers.contains(where: \.isActiveOnCurrentThread) else {
            throw MemoryFactoryError.memoryErasureFailed
        }
    }

    private static func revokeAndDrain(_ participants: MemoryServiceResourceRegistry.Snapshot,
                                       reason: VaultFillInvalidationReason) throws {
        for domain in participants.fillDomains { domain.revoke(reason) }
        for writer in participants.writers { try writer.beginForget() }
    }

    private static func closePeers(_ participants: MemoryServiceResourceRegistry.Snapshot,
                                   excluding initiatingStore: MemoryStore) throws {
        for peer in participants.stores where peer !== initiatingStore { try peer.closeForErasure() }
    }

    private static func closeForRecovery(_ participants: MemoryServiceResourceRegistry.Snapshot) throws {
        for peer in participants.stores { try peer.closeForErasure() }
    }

    static func recoveryCleanup(_ participants: MemoryServiceResourceRegistry.Snapshot) throws {
        try preflight(participants)
        try revokeAndDrain(participants, reason: .memoryForgotten)
        try closeForRecovery(participants)
    }
}

public enum MemoryFactoryError: Error, Equatable {
    case invalidLocation
    case unsafeDirectory
    case unsafeDatabase
    case incompleteNewStore
    case storageUnavailable
    case vaultOperationFailed
    case memoryErasureFailed
    case forgetRecoveryRequired
    case unsafeForgetJournal
}

private struct ReservedGenerationOpenPermit {
    let root: URL
    let namespace: KeychainNamespace
    let commandID: String
}

extension MemoryFactoryError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .invalidLocation: return "Private memory storage location is unavailable."
        case .unsafeDirectory: return "Private memory storage directory is unsafe."
        case .unsafeDatabase: return "Private memory database path is unsafe."
        case .incompleteNewStore: return "Private memory store is incomplete; its key will not be replaced."
        case .storageUnavailable: return "Private memory storage could not be opened."
        case .vaultOperationFailed: return "Protected vault operation could not be completed."
        case .memoryErasureFailed: return "Owner memory erasure could not be completed."
        case .forgetRecoveryRequired: return "Owner memory erasure recovery requires explicit authorization."
        case .unsafeForgetJournal: return "Owner memory erasure recovery state is invalid."
        }
    }
    public var debugDescription: String { description }
}

/// Owns the production path and key lifecycle. It returns before even resolving Application
/// Support when disabled. File-system setup and the first key operation share one process lock.
public enum MemoryStoreFactory {
    private static let openLock = NSLock()
    private static let applicationDirectory = "com.threadmark.remotedesktop.host"
    private static let memoryDirectory = "PersonalMemory"
    private static let databaseName = "memory.sqlite"

    private static func requestedProductionRoot() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            throw MemoryFactoryError.invalidLocation
        }
        return support.appendingPathComponent(applicationDirectory, isDirectory: true)
            .appendingPathComponent(memoryDirectory, isDirectory: true)
    }

    private static func resolvedProductionRoot() throws -> URL {
        let requested = try requestedProductionRoot()
        let resolved = try canonicalPrivateRootPath(requested.path)
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    public static func openProduction(
        enabled: Bool,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        let root = try requestedProductionRoot()
        let client = SystemKeychainClient()
        let random = SystemMemoryKeyRandomSource()
        let namespace = KeychainNamespace.production
        return try open(enabled: true, root: root, client: client, random: random,
                        namespace: namespace, authorize: authorize,
                        isTaskActive: isTaskActive, policy: policy)
    }

    /// Opens only the storage generation captured by an owner-authorized host request.
    /// This entry point remains unavailable until generation-bound host routing is enabled.
    public static func openProduction(
        enabled: Bool,
        expectedBinding: MemoryStoreBinding,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        guard expectedBinding.hasConsistentReference(),
              expectedBinding.generation.parentRoot == (try resolvedProductionRoot()),
              expectedBinding.generation.baseNamespace == .production else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        let client = SystemKeychainClient()
        return try openBoundGenerationForTesting(enabled: true, binding: expectedBinding,
            client: client, random: SystemMemoryKeyRandomSource(), authorize: authorize,
            isTaskActive: isTaskActive, policy: policy)
    }

    /// Captures current generation metadata only; it never creates a root, database, or key.
    public static func captureProductionBinding(enabled: Bool) throws -> MemoryStoreBinding? {
        guard enabled else { return nil }
        let root = try resolvedProductionRoot()
        var info = stat()
        let result = root.path.withCString { lstat($0, &info) }
        if result != 0, errno == ENOENT { return nil }
        return try captureBindingForTesting(enabled: true, root: root,
            client: SystemKeychainClient(), namespace: .production)
    }

    /// Explicitly starts a fresh generation only after the bound generation completed Forget.
    /// Disabled until a host owner-confirmation route is wired; the binding is correlation, not authority.
    public static func initializeAfterForgetProduction(
        enabled: Bool = false,
        expectedBinding: MemoryStoreBinding,
        commandID: UUID
    ) throws -> MemoryStoreBinding? {
        guard enabled else { return nil }
        guard expectedBinding.hasConsistentReference(),
              expectedBinding.generation.parentRoot == (try resolvedProductionRoot()),
              expectedBinding.generation.baseNamespace == .production else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        return try initializeAfterForgetBindingForTesting(enabled: true,
            expectedBinding: expectedBinding, commandID: commandID,
            client: SystemKeychainClient(), random: SystemMemoryKeyRandomSource())
    }

    /// Recovers only the generation named by the caller's previously captured binding.
    public static func recoverProductionForget(
        enabled: Bool = false,
        expectedBinding: MemoryStoreBinding
    ) throws -> Bool {
        guard enabled else { return false }
        guard expectedBinding.hasConsistentReference(),
              expectedBinding.generation.parentRoot == (try resolvedProductionRoot()),
              expectedBinding.generation.baseNamespace == .production else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        return try recoverBoundGenerationForTesting(enabled: true,
            binding: expectedBinding, client: SystemKeychainClient())
    }

    /// Explicitly completes an owner-authorized Forget after the host has quiesced.
    /// Disabled by default; callers must gate `enabled` on authenticated owner action.
    public static func recoverForgetProduction(enabled: Bool = false) throws -> Bool {
        guard enabled else { return false }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else {
            throw MemoryFactoryError.invalidLocation
        }
        let requestedRoot = support.appendingPathComponent(applicationDirectory, isDirectory: true)
            .appendingPathComponent(memoryDirectory, isDirectory: true)
        let client = SystemKeychainClient()
        do { _ = try client.copy(ForgetRecoveryJournal.item(namespace: .production)) }
        catch KeychainBoundaryError.missingItem { return false }
        var rootInfo = stat()
        let rootResult = requestedRoot.path.withCString { lstat($0, &rootInfo) }
        if rootResult != 0, errno == ENOENT { throw MemoryFactoryError.unsafeDirectory }
        let root = try preparePrivateRoot(requestedRoot)
        guard try ForgetRecoveryJournal.hasValidPendingMarker(client: client, root: root,
            namespace: .production) else { return false }
        let lease = VaultLifecycleLease(root: root)
        return try lease.withExclusive {
            guard try ForgetRecoveryJournal.hasValidPendingMarker(client: client, root: root,
                namespace: .production) else { return false }
            let participants = try MemoryServiceResourceRegistry.shared.snapshot(root: root,
                namespace: .production)
            try PersonalMemoryService.recoveryCleanup(participants)
            return try ForgetRecoveryJournal.recover(client: client, root: root,
                namespace: .production, fileOperations: LocalForgetRecoveryFileOperations())
        }
    }

    /// Test seam is internal and only accepts injected fake Keychain and randomness adapters.
    static func openForTesting(
        enabled: Bool, root: URL, client: any KeychainClient,
        random: any MemoryKeyRandomSource, namespace: KeychainNamespace,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        return try open(enabled: true, root: root, client: client, random: random,
                        namespace: namespace, authorize: authorize,
                        isTaskActive: isTaskActive, policy: policy)
    }

    static func open(
        enabled: Bool, root: URL, client: any KeychainClient,
        random: any MemoryKeyRandomSource, namespace: KeychainNamespace,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider,
        generationBinding: MemoryStoreBinding? = nil
    ) throws -> PersonalMemoryService? {
        try openCore(enabled: enabled, root: root, client: client, random: random,
            namespace: namespace, authorize: authorize, isTaskActive: isTaskActive,
            policy: policy, initializationPermit: nil, generationBinding: generationBinding)
    }

    static func openReservedGenerationForInitialization(
        enabled: Bool,
        generation: MemoryStoreGeneration,
        transition: MemoryGenerationTransition,
        client: any KeychainClient,
        random: any MemoryKeyRandomSource,
        stateStore: any MemoryGenerationStateStore
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        guard transition.status == .preparing,
              transition.to == generation.identifier,
              transition.to == UUID(uuidString: transition.to)?.uuidString.lowercased(),
              VaultLifecycleLease.isHeldByCurrentThread(root: generation.parentRoot,
                                                        kind: .generationTransition) else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        var parentInfo = stat()
        guard generation.parentRoot.path.withCString({ lstat($0, &parentInfo) }) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(), (parentInfo.st_mode & 0o777) == 0o700 else {
            throw MemoryFactoryError.unsafeDirectory
        }
        let expectedRoot = generation.parentRoot.appendingPathComponent("Generations", isDirectory: true)
            .appendingPathComponent(transition.to, isDirectory: true)
        let suffix = ".generation." + transition.to
        guard generation.root == expectedRoot,
              generation.namespace.databaseKeyService == generation.baseNamespace.databaseKeyService + suffix,
              generation.namespace.vaultService == generation.baseNamespace.vaultService + suffix else {
            throw MemoryFactoryError.unsafeDirectory
        }
        let stateItem = ExactKeychainItem(
            service: generation.baseNamespace.databaseKeyService + ".generation-state",
            account: MemoryGenerationState.itemAccount, protection: .deviceOnlyWhenUnlocked)
        let stateBytes = try stateStore.read(stateItem)
        let identity = try rootIdentityForGenerationState(generation.parentRoot)
        let state = try MemoryGenerationState.decode(stateBytes, device: identity.device,
            inode: identity.inode, namespace: generation.baseNamespace)
        guard state.active == transition.from, state.transition == transition else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        let canonicalParent = try preparePrivateRoot(generation.parentRoot)
        let canonicalRoot = try preparePrivateRoot(generation.root)
        let physicalExpectedRoot = canonicalParent.appendingPathComponent("Generations", isDirectory: true)
            .appendingPathComponent(transition.to, isDirectory: true)
        guard canonicalRoot == physicalExpectedRoot else { throw MemoryFactoryError.unsafeDirectory }
        let permit = ReservedGenerationOpenPermit(root: canonicalRoot,
            namespace: generation.namespace, commandID: transition.commandID)
        return try openCore(enabled: true, root: generation.root, client: client, random: random,
            namespace: generation.namespace, authorize: { _ in false },
            isTaskActive: { _, _ in false }, policy: { OwnerMemoryPolicy(featureEnabled: false) },
            initializationPermit: permit, generationBinding: nil)
    }

    private static func openCore(
        enabled: Bool, root: URL, client: any KeychainClient,
        random: any MemoryKeyRandomSource, namespace: KeychainNamespace,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider,
        initializationPermit: ReservedGenerationOpenPermit?,
        generationBinding: MemoryStoreBinding?
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        openLock.lock()
        defer { openLock.unlock() }
        do {
            let canonicalRoot = try preparePrivateRoot(root)
            let lease = VaultLifecycleLease(root: canonicalRoot)
            return try lease.withExclusiveObservingLock { createdLock in
                try MemoryServiceResourceRegistry.shared.requireCompatible(root: canonicalRoot,
                    namespace: namespace)
                let database = canonicalRoot.appendingPathComponent(databaseName, isDirectory: false)
                let sidecars = ["-wal", "-shm", "-journal"].map {
                    URL(fileURLWithPath: database.path + $0)
                }
                let databaseExists = try validateDatabasePath(database)
                var sidecarExists = try sidecars.map(validateDatabasePath).contains(true)
                try ForgetRecoveryJournal.requireNoPendingMarker(client: client,
                    root: canonicalRoot, namespace: namespace)
                let permitsResume = initializationPermit?.root == canonicalRoot &&
                    initializationPermit?.namespace == namespace
                if permitsResume {
                    let allowed = Set([".vault-lifecycle.lock", "memory.sqlite", "memory.sqlite-wal",
                                       "memory.sqlite-shm", "memory.sqlite-journal"])
                    let entries = try FileManager.default.contentsOfDirectory(atPath: canonicalRoot.path)
                    guard entries.allSatisfy({ allowed.contains($0) }) else {
                        throw MemoryFactoryError.unsafeDirectory
                    }
                }
                if permitsResume && !databaseExists && sidecarExists {
                    try removeUncommittedDatabaseSidecars(sidecars)
                    sidecarExists = false
                }
                if !databaseExists {
                    // Only the caller that atomically created the permanent lifecycle lock may
                    // create a normal store. A persisted preparing transition may narrowly
                    // resume the same unpublished UUID generation after a crash.
                    guard (createdLock || permitsResume), !sidecarExists else {
                        throw MemoryFactoryError.incompleteNewStore
                    }
                    if permitsResume {
                        let key = ExactKeychainItem(service: namespace.databaseKeyService,
                            account: "database-key", protection: .deviceOnlyWhenUnlocked)
                        do {
                            var bytes = try client.copy(key)
                            defer { bytes.resetBytes(in: 0..<bytes.count) }
                            guard bytes.count == 32 else { throw KeychainBoundaryError.invalidKey }
                        } catch KeychainBoundaryError.missingItem { }
                    }
                }

                let provider = KeychainMemoryKeyProvider(client: client, random: random,
                                                          namespace: namespace)
                if !databaseExists { _ = try provider.createKeyForNewStore(databaseURL: database) }
                guard let store = try MemoryStore.open(enabled: true, databaseURL: database,
                                                        keyProvider: provider) else {
                    throw MemoryFactoryError.storageUnavailable
                }
                if !databaseExists {
                    for file in [database] + sidecars { try secureNewStoreFile(file) }
                }
                _ = try validateDatabasePath(database)
                _ = try sidecars.map(validateDatabasePath)
                let service = PersonalMemoryService(store: store, authorize: authorize,
                    isTaskActive: isTaskActive, policy: policy,
                    client: client, namespace: namespace, root: canonicalRoot,
                    generationBinding: generationBinding)
                if try store.isVaultErasurePending() { try service.writer.beginForget() }
                try MemoryServiceResourceRegistry.shared.register(root: canonicalRoot,
                    namespace: namespace, store: store, writer: service.writer,
                    fillDomain: service.fillRevocation)
                return service
            }
        } catch let error as MemoryFactoryError {
            throw error
        } catch {
            // Do not expose file paths, SQLCipher diagnostics, Keychain details, or caller data.
            throw MemoryFactoryError.storageUnavailable
        }
    }

    private static func removeUncommittedDatabaseSidecars(_ sidecars: [URL]) throws {
        for file in sidecars where try validateDatabasePath(file) {
            try FileManager.default.removeItem(at: file)
            guard try !validateDatabasePath(file) else { throw MemoryFactoryError.unsafeDatabase }
        }
    }

    private static func rootIdentityForGenerationState(_ root: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else { throw MemoryFactoryError.unsafeDirectory }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    static func preparePrivateRoot(_ root: URL) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0) else {
            throw MemoryFactoryError.invalidLocation
        }
        let requestedPath = root.standardizedFileURL.path
        guard root.path == requestedPath,
              !requestedPath.split(separator: "/").contains("..") else {
            throw MemoryFactoryError.invalidLocation
        }
        let path = try canonicalPrivateRootPath(requestedPath)
        let components = path.split(separator: "/").map(String.init)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: true)
            let isOwnedRootComponent = index >= components.count - 2
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result != 0 {
                guard errno == ENOENT else { throw MemoryFactoryError.unsafeDirectory }
                do {
                    try FileManager.default.createDirectory(at: current,
                        withIntermediateDirectories: false,
                        attributes: isOwnedRootComponent ? [.posixPermissions: 0o700] : nil)
                } catch { throw MemoryFactoryError.unsafeDirectory }
                guard current.path.withCString({ lstat($0, &info) }) == 0 else {
                    throw MemoryFactoryError.unsafeDirectory
                }
            }
            let ownerIsCurrentUser = info.st_uid == getuid()
            let ownerIsSystem = info.st_uid == 0
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  ownerIsCurrentUser || ownerIsSystem else {
                throw MemoryFactoryError.unsafeDirectory
            }
            if isOwnedRootComponent {
                guard ownerIsCurrentUser else { throw MemoryFactoryError.unsafeDirectory }
                if (info.st_mode & 0o777) != 0o700 {
                    guard chmod(current.path, 0o700) == 0 else { throw MemoryFactoryError.unsafeDirectory }
                }
            } else if (info.st_mode & 0o022) != 0 &&
                        !(ownerIsSystem && (info.st_mode & S_ISVTX) != 0) {
                throw MemoryFactoryError.unsafeDirectory
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Resolve platform aliases such as /var to their physical path, while explicitly rejecting
    /// symlinks in either app-owned directory component before resolving the parent prefix.
    private static func canonicalPrivateRootPath(_ requested: String) throws -> String {
        let requestedComponents = requested.split(separator: "/").map(String.init)
        guard requestedComponents.count >= 2 else { throw MemoryFactoryError.invalidLocation }
        for candidate in [requested, URL(fileURLWithPath: requested).deletingLastPathComponent().path] {
            var info = stat()
            let result = candidate.withCString { lstat($0, &info) }
            if result == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                throw MemoryFactoryError.unsafeDirectory
            }
        }
        var ancestor = requested
        var missing: [String] = []
        while true {
            var info = stat()
            if ancestor.withCString({ lstat($0, &info) }) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw MemoryFactoryError.unsafeDirectory }
                let resolvedPointer = ancestor.withCString { realpath($0, nil) }
                guard let resolvedPointer else { throw MemoryFactoryError.unsafeDirectory }
                defer { free(resolvedPointer) }
                let resolved = String(cString: resolvedPointer)
                return ([resolved] + missing.reversed()).joined(separator: "/")
                    .replacingOccurrences(of: "//", with: "/")
            }
            guard errno == ENOENT else {
                throw MemoryFactoryError.unsafeDirectory
            }
            let component = URL(fileURLWithPath: ancestor).lastPathComponent
            missing.append(component)
            let parent = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
            guard parent != ancestor else { throw MemoryFactoryError.unsafeDirectory }
            ancestor = parent
        }
    }

    /// lstat rejects dangling symlinks and special files instead of following them.
    static func validateDatabasePath(_ url: URL) throws -> Bool {
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

    private static func secureNewStoreFile(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        if descriptor < 0 {
            guard errno == ENOENT else { throw MemoryFactoryError.unsafeDatabase }
            return
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw MemoryFactoryError.unsafeDatabase }
    }
}
