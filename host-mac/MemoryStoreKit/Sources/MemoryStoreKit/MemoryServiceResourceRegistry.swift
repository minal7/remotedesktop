import Darwin
import Foundation

/// Tracks only weak references to live resources sharing a physical memory root. Strong snapshots
/// are short-lived; cleanup snapshots are refreshed while the caller holds the root lease.
final class MemoryServiceResourceRegistry: @unchecked Sendable {
    static let shared = MemoryServiceResourceRegistry()

    struct Snapshot {
        let stores: [MemoryStore]
        let writers: [OwnerMemoryWriter]
        let fillDomains: [VaultFillRevocationDomain]
    }

    private struct RootID: Hashable { let device: UInt64; let inode: UInt64 }
    private struct Key: Hashable {
        let root: RootID
        let databaseNamespace: String
        let vaultNamespace: String
    }

    private final class Entry {
        let key: Key
        weak var store: MemoryStore?
        weak var writer: OwnerMemoryWriter?
        weak var fillDomain: VaultFillRevocationDomain?
        init(key: Key, store: MemoryStore, writer: OwnerMemoryWriter,
             fillDomain: VaultFillRevocationDomain) {
            self.key = key; self.store = store; self.writer = writer; self.fillDomain = fillDomain
        }
        var isLive: Bool { store != nil || writer != nil || fillDomain != nil }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    private init() {}

    func register(root: URL, namespace: KeychainNamespace, store: MemoryStore,
                  writer: OwnerMemoryWriter, fillDomain: VaultFillRevocationDomain) throws {
        let rootID = try Self.rootID(root)
        let key = Key(root: rootID, databaseNamespace: namespace.databaseKeyService,
                      vaultNamespace: namespace.vaultService)
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { !$0.isLive }
        try Self.requireCompatible(entries, rootID: rootID, key: key)
        entries.append(Entry(key: key, store: store, writer: writer, fillDomain: fillDomain))
    }

    func requireCompatible(root: URL, namespace: KeychainNamespace) throws {
        let rootID = try Self.rootID(root)
        let key = Key(root: rootID, databaseNamespace: namespace.databaseKeyService,
                      vaultNamespace: namespace.vaultService)
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { !$0.isLive }
        try Self.requireCompatible(entries, rootID: rootID, key: key)
    }

    func snapshot(root: URL, namespace: KeychainNamespace) throws -> Snapshot {
        let rootID = try Self.rootID(root)
        let key = Key(root: rootID, databaseNamespace: namespace.databaseKeyService,
                      vaultNamespace: namespace.vaultService)
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { !$0.isLive }
        try Self.requireCompatible(entries, rootID: rootID, key: key)
        let matching = entries.filter { $0.key == key }
        return Snapshot(stores: Self.unique(matching.compactMap(\.store)),
                        writers: Self.unique(matching.compactMap(\.writer)),
                        fillDomains: Self.unique(matching.compactMap(\.fillDomain)))
    }

    private static func unique<T: AnyObject>(_ values: [T]) -> [T] {
        var seen = Set<ObjectIdentifier>()
        return values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private static func requireCompatible(_ entries: [Entry], rootID: RootID, key: Key) throws {
        guard !entries.contains(where: { $0.key.root == rootID && $0.key != key && $0.isLive }) else {
            throw MemoryFactoryError.unsafeDirectory
        }
    }

    private static func rootID(_ root: URL) throws -> RootID {
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { throw MemoryFactoryError.unsafeDirectory }
        return RootID(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
