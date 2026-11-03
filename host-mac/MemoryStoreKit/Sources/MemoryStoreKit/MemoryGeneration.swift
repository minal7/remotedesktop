import Foundation

/// Immutable binding to one storage generation. Existing services retain this value for their
/// lifetime; erase and recovery must never resolve the active generation again.
struct MemoryStoreGeneration: Sendable, Equatable {
    let identifier: String
    let parentRoot: URL
    let root: URL
    let namespace: KeychainNamespace
    let baseNamespace: KeychainNamespace

    static let legacyIdentifier = "legacy-v1"

    static func legacy(root: URL, namespace: KeychainNamespace) -> Self {
        Self(identifier: legacyIdentifier, parentRoot: root,
             root: root, namespace: namespace, baseNamespace: namespace)
    }
}

/// Exact-item state boundary. Production uses a Keychain-backed implementation; tests can model
/// atomic replacement, interrupted writes, and malformed persisted records without Security.
protocol MemoryGenerationStateStore: Sendable {
    func read(_ item: ExactKeychainItem) throws -> Data
    func replace(_ item: ExactKeychainItem, with data: Data) throws
}

/// Serializes generation reservation and active-pointer publication across processes.
protocol MemoryGenerationTransitionLock: Sendable {
    func withExclusive<T>(at parentRoot: URL, _ operation: () throws -> T) throws -> T
}

enum MemoryGenerationInitializationPoint: Sendable {
    case afterReservation
    case afterStorePrepared
    case beforeCommit
    case afterCommit
}

/// Test-only fault/barrier seam around durable initialization boundaries.
protocol MemoryGenerationInitializationObserver: Sendable {
    func reached(_ point: MemoryGenerationInitializationPoint) throws
}

struct KeychainMemoryGenerationStateStore: MemoryGenerationStateStore {
    let client: any KeychainClient
    func read(_ item: ExactKeychainItem) throws -> Data { try client.copy(item) }
    func replace(_ item: ExactKeychainItem, with data: Data) throws {
        try client.replace(item, data: data)
    }
}

struct LocalMemoryGenerationTransitionLock: MemoryGenerationTransitionLock {
    func withExclusive<T>(at parentRoot: URL, _ operation: () throws -> T) throws -> T {
        try VaultLifecycleLease(root: parentRoot, kind: .generationTransition)
            .withExclusive(timeout: 10, operation)
    }
}

struct MemoryGenerationTransition: Equatable, Sendable {
    enum Status: String, Sendable { case preparing = "p", committed = "c" }
    let commandID: String
    let from: String
    let to: String
    let status: Status
}

struct MemoryGenerationState: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let databaseNamespace: String
    let vaultNamespace: String
    let active: String
    let transition: MemoryGenerationTransition?

    static let itemAccount = "active-generation-v1"
    static let maximumSize = 2_048

    func encode() throws -> Data {
        let transitionFields: [String]
        if let transition {
            transitionFields = [transition.status.rawValue, transition.commandID,
                                transition.from, transition.to]
        } else { transitionFields = ["n"] }
        let fields = ["PMGS1", String(device), String(inode),
            Data(databaseNamespace.utf8).base64EncodedString(),
            Data(vaultNamespace.utf8).base64EncodedString(), active] + transitionFields
        let data = Data(fields.joined(separator: "|").utf8)
        guard data.count <= Self.maximumSize else { throw MemoryFactoryError.unsafeDirectory }
        return data
    }

    static func decode(_ data: Data, device: UInt64, inode: UInt64,
                       namespace: KeychainNamespace) throws -> Self {
        guard data.count <= maximumSize, let text = String(data: data, encoding: .utf8) else {
            throw MemoryFactoryError.unsafeDirectory
        }
        let fields = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7 || fields.count == 10, fields[0] == "PMGS1",
              let parsedDevice = UInt64(fields[1]), String(parsedDevice) == fields[1], parsedDevice == device,
              let parsedInode = UInt64(fields[2]), String(parsedInode) == fields[2], parsedInode == inode,
              let databaseBytes = Data(base64Encoded: fields[3]), databaseBytes.base64EncodedString() == fields[3],
              databaseBytes == Data(namespace.databaseKeyService.utf8),
              let vaultBytes = Data(base64Encoded: fields[4]), vaultBytes.base64EncodedString() == fields[4],
              vaultBytes == Data(namespace.vaultService.utf8),
              validIdentifier(fields[5]) else { throw MemoryFactoryError.unsafeDirectory }
        let decodedTransition: MemoryGenerationTransition?
        if fields.count == 7 {
            guard fields[6] == "n" else { throw MemoryFactoryError.unsafeDirectory }
            decodedTransition = nil
        } else {
            guard let status = MemoryGenerationTransition.Status(rawValue: fields[6]),
                  let command = UUID(uuidString: fields[7]),
                  command.uuidString.lowercased() == fields[7],
                  validIdentifier(fields[8]), validGenerationID(fields[9]) else {
                throw MemoryFactoryError.unsafeDirectory
            }
            let transition = MemoryGenerationTransition(commandID: fields[7], from: fields[8],
                to: fields[9], status: status)
            guard transition.from != transition.to,
                  status == .preparing ? fields[5] == transition.from : fields[5] == transition.to else {
                throw MemoryFactoryError.unsafeDirectory
            }
            decodedTransition = transition
        }
        let state = Self(device: device, inode: inode,
            databaseNamespace: namespace.databaseKeyService, vaultNamespace: namespace.vaultService,
            active: fields[5], transition: decodedTransition)
        guard try state.encode() == data else { throw MemoryFactoryError.unsafeDirectory }
        if state.transition == nil, state.active != MemoryStoreGeneration.legacyIdentifier {
            throw MemoryFactoryError.unsafeDirectory
        }
        return state
    }

    private static func validIdentifier(_ value: String) -> Bool {
        if value == MemoryStoreGeneration.legacyIdentifier { return true }
        return validGenerationID(value)
    }

    private static func validGenerationID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

extension MemoryGenerationStateStore {
    func stateItem(baseNamespace: KeychainNamespace) -> ExactKeychainItem {
        ExactKeychainItem(service: baseNamespace.databaseKeyService + ".generation-state",
                          account: MemoryGenerationState.itemAccount,
                          protection: .deviceOnlyWhenUnlocked)
    }
}
