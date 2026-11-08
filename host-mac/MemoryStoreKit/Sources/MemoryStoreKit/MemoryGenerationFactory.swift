import Darwin
import Foundation

extension MemoryStoreFactory {
    /// Fake-Keychain seam for binding a confirmed initialization command to its captured source.
    static func initializeAfterForgetBindingForTesting(
        enabled: Bool,
        expectedBinding: MemoryStoreBinding,
        commandID: UUID,
        client: any KeychainClient,
        random: any MemoryKeyRandomSource,
        stateStore: (any MemoryGenerationStateStore)? = nil,
        transitionLock: (any MemoryGenerationTransitionLock)? = nil,
        observer: (any MemoryGenerationInitializationObserver)? = nil
    ) throws -> MemoryStoreBinding? {
        guard enabled else { return nil }
        guard expectedBinding.hasConsistentReference() else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        let generation = try initializeAfterForgetForTesting(enabled: true,
            expectedGeneration: expectedBinding.generation, commandID: commandID,
            client: client, random: random, stateStore: stateStore,
            transitionLock: transitionLock, observer: observer,
            expectedBinding: expectedBinding)
        guard let generation else { throw MemoryFactoryError.forgetRecoveryRequired }
        return MemoryStoreBinding(generation: generation, device: expectedBinding.device,
                                  inode: expectedBinding.inode)
    }

    /// Captures immutable generation identity without creating a database or key.
    static func captureBindingForTesting(
        enabled: Bool, root: URL, client: any KeychainClient,
        namespace: KeychainNamespace,
        stateStore: (any MemoryGenerationStateStore)? = nil,
        transitionLock: (any MemoryGenerationTransitionLock)? = nil
    ) throws -> MemoryStoreBinding? {
        guard enabled else { return nil }
        let canonicalRoot = root.standardizedFileURL
        let store = stateStore ?? KeychainMemoryGenerationStateStore(client: client)
        return try withGenerationTransitionLease(at: canonicalRoot, injected: transitionLock) {
            let identity = try generationRootIdentity(canonicalRoot)
            let item = store.stateItem(baseNamespace: namespace)
            let generation: MemoryStoreGeneration
            do {
                let state = try MemoryGenerationState.decode(store.read(item),
                    device: identity.device, inode: identity.inode, namespace: namespace)
                generation = generationDescriptor(state.active, parentRoot: canonicalRoot,
                                                  baseNamespace: namespace)
            } catch KeychainBoundaryError.missingItem {
                generation = MemoryStoreGeneration.legacy(root: canonicalRoot, namespace: namespace)
            }
            try validateGenerationDescriptor(generation, parentRoot: canonicalRoot,
                baseNamespace: namespace, requireRoot: true)
            return MemoryStoreBinding(generation: generation, device: identity.device,
                                      inode: identity.inode)
        }
    }

    static func openBoundGenerationForTesting(
        enabled: Bool, binding: MemoryStoreBinding, client: any KeychainClient,
        random: any MemoryKeyRandomSource,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider,
        stateStore: (any MemoryGenerationStateStore)? = nil
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        let generation = binding.generation
        guard binding.hasConsistentReference() else { throw MemoryFactoryError.forgetRecoveryRequired }
        return try LocalMemoryGenerationTransitionLock().withExclusive(at: generation.parentRoot) {
            try validateBindingRoot(binding)
            let store = stateStore ?? KeychainMemoryGenerationStateStore(client: client)
            let item = store.stateItem(baseNamespace: generation.baseNamespace)
            let identity = try generationRootIdentity(generation.parentRoot)
            let current: MemoryGenerationState?
            do {
                current = try MemoryGenerationState.decode(store.read(item),
                    device: identity.device, inode: identity.inode,
                    namespace: generation.baseNamespace)
            } catch KeychainBoundaryError.missingItem { current = nil }
            guard (current?.active ?? MemoryStoreGeneration.legacyIdentifier) == generation.identifier,
                  current?.transition?.status != .preparing else {
                throw MemoryFactoryError.forgetRecoveryRequired
            }
            try validateGenerationDescriptor(generation, parentRoot: generation.parentRoot,
                baseNamespace: generation.baseNamespace, requireRoot: true)
            return try open(enabled: true, root: generation.root, client: client, random: random,
                namespace: generation.namespace, authorize: authorize,
                isTaskActive: isTaskActive, policy: policy, generationBinding: binding)
        }
    }

    static func recoverBoundGenerationForTesting(
        enabled: Bool, binding: MemoryStoreBinding, client: any KeychainClient,
        fileOperations: any ForgetRecoveryFileOperations = LocalForgetRecoveryFileOperations(),
        stateStore: (any MemoryGenerationStateStore)? = nil
    ) throws -> Bool {
        guard enabled else { return false }
        let generation = binding.generation
        guard binding.hasConsistentReference() else { throw MemoryFactoryError.forgetRecoveryRequired }
        try validateBindingRoot(binding)
        return try LocalMemoryGenerationTransitionLock().withExclusive(at: generation.parentRoot) {
            try validateBindingRoot(binding)
            return try recoverGenerationForTesting(enabled: true, generation: generation,
                client: client, fileOperations: fileOperations, stateStore: stateStore)
        }
    }

    /// Internal generation-state seam. Production remains on the legacy factory until a
    /// generation-bound owner command is wired into the host coordinator.
    static func captureGenerationForTesting(
        enabled: Bool,
        root: URL,
        client: any KeychainClient,
        namespace: KeychainNamespace,
        stateStore: (any MemoryGenerationStateStore)? = nil,
        transitionLock: (any MemoryGenerationTransitionLock)? = nil
    ) throws -> MemoryStoreGeneration? {
        guard enabled else { return nil }
        let canonicalRoot = root.standardizedFileURL
        let store = stateStore ?? KeychainMemoryGenerationStateStore(client: client)
        return try withGenerationTransitionLease(at: canonicalRoot, injected: transitionLock) {
            let identity = try generationRootIdentity(canonicalRoot)
            let item = store.stateItem(baseNamespace: namespace)
            let state: MemoryGenerationState
            do {
                let bytes = try store.read(item)
                state = try MemoryGenerationState.decode(bytes, device: identity.device,
                    inode: identity.inode, namespace: namespace)
            } catch KeychainBoundaryError.missingItem {
                return MemoryStoreGeneration.legacy(root: canonicalRoot, namespace: namespace)
            }
            let generation = generationDescriptor(state.active, parentRoot: canonicalRoot,
                                                  baseNamespace: namespace)
            try validateGenerationDescriptor(generation, parentRoot: canonicalRoot,
                                            baseNamespace: namespace, requireRoot: true)
            return generation
        }
    }

    /// Starts or resumes a single explicitly authorized reset transition. This seam is inert
    /// until generation binding is wired to a confirmed owner command.
    static func initializeAfterForgetForTesting(
        enabled: Bool,
        expectedGeneration: MemoryStoreGeneration,
        commandID: UUID,
        client: any KeychainClient,
        random: any MemoryKeyRandomSource,
        stateStore: (any MemoryGenerationStateStore)? = nil,
        transitionLock: (any MemoryGenerationTransitionLock)? = nil,
        observer: (any MemoryGenerationInitializationObserver)? = nil,
        expectedBinding: MemoryStoreBinding? = nil
    ) throws -> MemoryStoreGeneration? {
        guard enabled else { return nil }
        let parentRoot = expectedGeneration.parentRoot.standardizedFileURL
        let store = stateStore ?? KeychainMemoryGenerationStateStore(client: client)
        if let expectedBinding { try validateBindingRoot(expectedBinding) }
        return try withGenerationTransitionLease(at: parentRoot, injected: transitionLock) {
            let identity = try generationRootIdentity(parentRoot)
            if let expectedBinding {
                guard expectedBinding.generation == expectedGeneration,
                      expectedBinding.device == identity.device,
                      expectedBinding.inode == identity.inode else {
                    throw MemoryFactoryError.forgetRecoveryRequired
                }
                try validateBindingRoot(expectedBinding)
            }
            try validateGenerationDescriptor(expectedGeneration, parentRoot: parentRoot,
                baseNamespace: expectedGeneration.baseNamespace, requireRoot: true)
            let item = store.stateItem(baseNamespace: expectedGeneration.baseNamespace)
            let command = commandID.uuidString.lowercased()
            let currentState: MemoryGenerationState?
            do {
                currentState = try MemoryGenerationState.decode(store.read(item),
                    device: identity.device, inode: identity.inode,
                    namespace: expectedGeneration.baseNamespace)
            } catch KeychainBoundaryError.missingItem { currentState = nil }

            if let currentState, let transition = currentState.transition,
               transition.status == .committed, transition.commandID == command,
               transition.from == expectedGeneration.identifier {
                let target = generationDescriptor(transition.to, parentRoot: parentRoot,
                    baseNamespace: expectedGeneration.baseNamespace)
                try validateGenerationDescriptor(target, parentRoot: parentRoot,
                    baseNamespace: expectedGeneration.baseNamespace, requireRoot: true)
                try requireGenerationRemainsAvailable(target, client: client)
                return target
            }
            if let previous = currentState?.transition, previous.status == .committed,
               previous.commandID == command {
                throw MemoryFactoryError.forgetRecoveryRequired
            }

            var transition: MemoryGenerationTransition
            if let currentState, let pending = currentState.transition,
               pending.status == .preparing {
                guard pending.commandID == command,
                      pending.from == expectedGeneration.identifier,
                      currentState.active == expectedGeneration.identifier else {
                    throw MemoryFactoryError.forgetRecoveryRequired
                }
                transition = pending
            } else {
                let active = currentState?.active ?? MemoryStoreGeneration.legacyIdentifier
                guard active == expectedGeneration.identifier else {
                    throw MemoryFactoryError.forgetRecoveryRequired
                }
                let expected = generationDescriptor(active, parentRoot: parentRoot,
                    baseNamespace: expectedGeneration.baseNamespace)
                try validateGenerationDescriptor(expectedGeneration, parentRoot: parentRoot,
                    baseNamespace: expectedGeneration.baseNamespace, requireRoot: true)
                guard expected == expectedGeneration else { throw MemoryFactoryError.forgetRecoveryRequired }
                try VaultLifecycleLease(root: expected.root).withExclusive {
                    try ForgetRecoveryJournal.requireCompletedForget(client: client,
                        root: expected.root, namespace: expected.namespace)
                }
                let nextID = UUID().uuidString.lowercased()
                transition = MemoryGenerationTransition(commandID: command, from: active,
                    to: nextID, status: .preparing)
                let target = generationDescriptor(nextID, parentRoot: parentRoot,
                    baseNamespace: expectedGeneration.baseNamespace)
                try requireUnusedGenerationSlot(target, client: client)
                let reservedState = MemoryGenerationState(device: identity.device, inode: identity.inode,
                    databaseNamespace: expectedGeneration.baseNamespace.databaseKeyService,
                    vaultNamespace: expectedGeneration.baseNamespace.vaultService,
                    active: active, transition: transition)
                let bytes = try reservedState.encode()
                if currentState == nil {
                    do { try client.add(item, data: bytes) }
                    catch KeychainBoundaryError.duplicateItem {
                        let raced = try MemoryGenerationState.decode(store.read(item),
                            device: identity.device, inode: identity.inode,
                            namespace: expectedGeneration.baseNamespace)
                        guard raced.transition?.commandID == command,
                              raced.transition?.from == active,
                              raced.transition?.status == .preparing else {
                            throw MemoryFactoryError.forgetRecoveryRequired
                        }
                        guard let racedTransition = raced.transition else {
                            throw MemoryFactoryError.forgetRecoveryRequired
                        }
                        transition = racedTransition
                    }
                } else {
                    try store.replace(item, with: bytes)
                }
            }

            try observer?.reached(.afterReservation)
            let target = generationDescriptor(transition.to, parentRoot: parentRoot,
                baseNamespace: expectedGeneration.baseNamespace)
            try prepareGenerationStore(target, transition: transition, client: client,
                                       random: random, stateStore: store)
            try observer?.reached(.afterStorePrepared)
            try observer?.reached(.beforeCommit)
            let committed = MemoryGenerationState(device: identity.device, inode: identity.inode,
                databaseNamespace: expectedGeneration.baseNamespace.databaseKeyService,
                vaultNamespace: expectedGeneration.baseNamespace.vaultService,
                active: transition.to,
                transition: MemoryGenerationTransition(commandID: command,
                    from: transition.from, to: transition.to, status: .committed))
            try store.replace(item, with: committed.encode())
            try observer?.reached(.afterCommit)
            return target
        }
    }

    /// Opens only a captured generation. It never follows a changed active pointer.
    static func openGenerationForTesting(
        enabled: Bool,
        generation: MemoryStoreGeneration,
        client: any KeychainClient,
        random: any MemoryKeyRandomSource,
        authorize: @escaping OwnerMemoryAuthorizer,
        isTaskActive: @escaping OwnerTaskLiveness,
        policy: @escaping OwnerMemoryPolicyProvider,
        stateStore: (any MemoryGenerationStateStore)? = nil
    ) throws -> PersonalMemoryService? {
        guard enabled else { return nil }
        let transitionLock = LocalMemoryGenerationTransitionLock()
        return try transitionLock.withExclusive(at: generation.parentRoot) {
            try validateGenerationDescriptor(generation, parentRoot: generation.parentRoot,
                baseNamespace: generation.baseNamespace, requireRoot: true)
            let item = (stateStore ?? KeychainMemoryGenerationStateStore(client: client))
                .stateItem(baseNamespace: generation.baseNamespace)
            let identity = try generationRootIdentity(generation.parentRoot)
            let current: MemoryGenerationState?
            do {
                current = try MemoryGenerationState.decode(
                    (stateStore ?? KeychainMemoryGenerationStateStore(client: client)).read(item),
                    device: identity.device, inode: identity.inode, namespace: generation.baseNamespace)
            } catch KeychainBoundaryError.missingItem { current = nil }
            let activeID = current?.active ?? MemoryStoreGeneration.legacyIdentifier
            guard activeID == generation.identifier,
                  current?.transition?.status != .preparing else {
                throw MemoryFactoryError.forgetRecoveryRequired
            }
            return try open(enabled: true, root: generation.root, client: client, random: random,
                namespace: generation.namespace, authorize: authorize, isTaskActive: isTaskActive,
                policy: policy, generationBinding: MemoryStoreBinding(generation: generation,
                    device: identity.device, inode: identity.inode))
        }
    }

    /// Recovers only the marker and files in a previously captured generation.
    static func recoverGenerationForTesting(
        enabled: Bool,
        generation: MemoryStoreGeneration,
        client: any KeychainClient,
        fileOperations: any ForgetRecoveryFileOperations = LocalForgetRecoveryFileOperations(),
        stateStore: (any MemoryGenerationStateStore)? = nil
    ) throws -> Bool {
        guard enabled else { return false }
        _ = stateStore
        try validateGenerationDescriptor(generation, parentRoot: generation.parentRoot,
            baseNamespace: generation.baseNamespace, requireRoot: true)
        let lease = VaultLifecycleLease(root: generation.root)
        return try lease.withExclusive {
            guard try ForgetRecoveryJournal.hasValidPendingMarker(client: client,
                root: generation.root, namespace: generation.namespace) else { return false }
            let participants = try MemoryServiceResourceRegistry.shared.snapshot(root: generation.root,
                namespace: generation.namespace)
            try PersonalMemoryService.recoveryCleanup(participants)
            return try ForgetRecoveryJournal.recover(client: client, root: generation.root,
                namespace: generation.namespace, fileOperations: fileOperations)
        }
    }

    private static func generationDescriptor(_ identifier: String, parentRoot: URL,
                                             baseNamespace: KeychainNamespace) -> MemoryStoreGeneration {
        if identifier == MemoryStoreGeneration.legacyIdentifier {
            return .legacy(root: parentRoot, namespace: baseNamespace)
        }
        let root = parentRoot.appendingPathComponent("Generations", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        let suffix = ".generation." + identifier
        return MemoryStoreGeneration(identifier: identifier, parentRoot: parentRoot, root: root,
            namespace: KeychainNamespace(databaseKeyService: baseNamespace.databaseKeyService + suffix,
                vaultService: baseNamespace.vaultService + suffix), baseNamespace: baseNamespace)
    }

    /// The real cross-process lease is always held. An injected lock adds deterministic test
    /// scheduling but cannot stand in for the filesystem safety boundary.
    private static func withGenerationTransitionLease<T>(at root: URL,
        injected: (any MemoryGenerationTransitionLock)?,
        _ operation: () throws -> T) throws -> T {
        try LocalMemoryGenerationTransitionLock().withExclusive(at: root) {
            if let injected { return try injected.withExclusive(at: root, operation) }
            return try operation()
        }
    }

    private static func validateGenerationDescriptor(_ generation: MemoryStoreGeneration,
        parentRoot: URL, baseNamespace: KeychainNamespace, requireRoot: Bool) throws {
        guard isValidIdentifier(generation.identifier),
              generation.parentRoot == parentRoot,
              generation.baseNamespace == baseNamespace,
              generation == generationDescriptor(generation.identifier, parentRoot: parentRoot,
                                                   baseNamespace: baseNamespace) else {
            throw MemoryFactoryError.unsafeDirectory
        }
        if requireRoot { _ = try generationRootIdentity(generation.root) }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        if value == MemoryStoreGeneration.legacyIdentifier { return true }
        guard let id = UUID(uuidString: value) else { return false }
        return id.uuidString.lowercased() == value
    }

    private static func validateBindingRoot(_ binding: MemoryStoreBinding) throws {
        let generation = binding.generation
        guard binding.hasConsistentReference(),
              generation.parentRoot.path == generation.parentRoot.standardizedFileURL.path else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
        let identity = try generationRootIdentity(generation.parentRoot)
        guard identity.device == binding.device, identity.inode == binding.inode else {
            throw MemoryFactoryError.forgetRecoveryRequired
        }
    }

    private static func requireGenerationRemainsAvailable(
        _ generation: MemoryStoreGeneration, client: any KeychainClient
    ) throws {
        try VaultLifecycleLease(root: generation.root).withExclusive {
            let isForgotten = try ForgetRecoveryJournal.hasValidPendingMarker(client: client,
                root: generation.root, namespace: generation.namespace)
            guard !isForgotten else {
                throw MemoryFactoryError.forgetRecoveryRequired
            }
            let database = generation.root.appendingPathComponent("memory.sqlite", isDirectory: false)
            let sidecars = ["-wal", "-shm", "-journal"].map {
                URL(fileURLWithPath: database.path + $0)
            }
            guard try MemoryStoreFactory.validateDatabasePath(database) else {
                throw MemoryFactoryError.forgetRecoveryRequired
            }
            _ = try sidecars.map(MemoryStoreFactory.validateDatabasePath)
            let key = ExactKeychainItem(service: generation.namespace.databaseKeyService,
                account: "database-key", protection: .deviceOnlyWhenUnlocked)
            var bytes = try client.copy(key)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            guard bytes.count == 32 else { throw KeychainBoundaryError.invalidKey }
        }
    }

    private static func requireUnusedGenerationSlot(_ generation: MemoryStoreGeneration,
        client: any KeychainClient) throws {
        let generationsRoot = generation.root.deletingLastPathComponent()
        var parentInfo = stat()
        let parentResult = generationsRoot.path.withCString { lstat($0, &parentInfo) }
        if parentResult == 0 {
            guard (parentInfo.st_mode & S_IFMT) == S_IFDIR, parentInfo.st_uid == getuid(),
                  (parentInfo.st_mode & 0o777) == 0o700 else { throw MemoryFactoryError.unsafeDirectory }
        } else if errno != ENOENT {
            throw MemoryFactoryError.unsafeDirectory
        }
        var rootInfo = stat()
        guard generation.root.path.withCString({ lstat($0, &rootInfo) }) != 0, errno == ENOENT else {
            throw MemoryFactoryError.unsafeDirectory
        }
        let key = ExactKeychainItem(service: generation.namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        do { _ = try client.copy(key); throw MemoryFactoryError.unsafeDirectory }
        catch KeychainBoundaryError.missingItem { }
        let marker = ForgetRecoveryJournal.item(namespace: generation.namespace)
        do { _ = try client.copy(marker); throw MemoryFactoryError.unsafeForgetJournal }
        catch KeychainBoundaryError.missingItem { }
    }

    private static func generationRootIdentity(_ root: URL) throws -> (device: UInt64, inode: UInt64) {
        guard root.isFileURL, root.path == root.standardizedFileURL.path,
              !root.path.split(separator: "/").contains("..") else {
            throw MemoryFactoryError.unsafeDirectory
        }
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else { throw MemoryFactoryError.unsafeDirectory }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private static func prepareGenerationStore(_ generation: MemoryStoreGeneration,
        transition: MemoryGenerationTransition, client: any KeychainClient,
        random: any MemoryKeyRandomSource, stateStore: any MemoryGenerationStateStore) throws {
        guard isValidIdentifier(generation.identifier),
              generation.identifier != MemoryStoreGeneration.legacyIdentifier else {
            throw MemoryFactoryError.unsafeDirectory
        }
        guard let service = try MemoryStoreFactory.openReservedGenerationForInitialization(
            enabled: true, generation: generation, transition: transition,
            client: client, random: random, stateStore: stateStore) else {
            throw MemoryFactoryError.storageUnavailable
        }
        defer { try? service.close() }
        guard try service.isEmptyForGenerationPublication() else {
            throw MemoryFactoryError.incompleteNewStore
        }
        try service.close()
        try synchronizePreparedGeneration(generation.root)
    }

    private static func synchronizePreparedGeneration(_ root: URL) throws {
        let database = root.appendingPathComponent("memory.sqlite")
        for url in [database, URL(fileURLWithPath: database.path + "-wal"),
                    URL(fileURLWithPath: database.path + "-shm"),
                    URL(fileURLWithPath: database.path + "-journal")] {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                if errno == ENOENT { continue }
                throw MemoryFactoryError.unsafeDatabase
            }
            let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else { throw MemoryFactoryError.unsafeDatabase }
            defer { _ = Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw MemoryFactoryError.storageUnavailable }
        }
        for directory in [root,
            root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()] {
            let fd = directory.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw MemoryFactoryError.unsafeDirectory }
            defer { _ = Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw MemoryFactoryError.storageUnavailable }
        }
    }
}
