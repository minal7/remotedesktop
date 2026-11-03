import CryptoKit
import Darwin
import Foundation

/// Caller-owned AES-256 key wrapper. The key is never serialized or included in the result.
public struct SealedMemoryExportKey: Sendable {
    fileprivate let symmetricKey: SymmetricKey

    public init(_ key: SymmetricKey) throws {
        guard key.bitCount == 256 else { throw SealedMemoryExportError.invalidKey }
        symmetricKey = key
    }
}

/// Versioned encrypted output. The caller supplies the key and receives no plaintext DTOs.
public struct SealedMemoryExportEnvelope: Sendable, Equatable {
    public let formatVersion: UInt8
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    init(formatVersion: UInt8 = 1, nonce: Data, ciphertext: Data, authenticationTag: Data) {
        self.formatVersion = formatVersion
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

enum SealedMemoryExportError: Error, Equatable {
    case invalidKey
    case invalidBounds
    case tooLarge
    case staleBinding
    case unavailable
}

struct SealedMemoryExportRecord: Encodable {
    let id: String
    let kind: String
    let body: String
    let source: String
    let observedAt: Int64
    let active: Bool
    let confidence: Double
}

struct SealedMemoryExportPayload: Encodable {
    let format: String
    let records: [SealedMemoryExportRecord]
}

enum SealedMemoryExportCodec {
    static func authenticatedFormat(version: UInt8) -> Data {
        Data("personal-memory-export-v\(version)".utf8)
    }

    static func seal(_ payload: Data, using key: SealedMemoryExportKey) throws -> SealedMemoryExportEnvelope {
        let box = try AES.GCM.seal(payload, using: key.symmetricKey,
                                   authenticating: authenticatedFormat(version: 1))
        return SealedMemoryExportEnvelope(nonce: Data(box.nonce), ciphertext: box.ciphertext,
                                          authenticationTag: box.tag)
    }
}

extension PersonalMemoryService {
/// Caller supplies the AES-256 key; this Profile/Fact subset excludes episodes and full-owner
/// export, and only authenticated ciphertext leaves this service.
public func exportSealedMemory(context: OwnerMemoryContext, key: SealedMemoryExportKey,
                               maximumRecords: Int = 500,
                               maximumBytes: Int = 1_048_576) throws -> SealedMemoryExportEnvelope {
    guard (1...500).contains(maximumRecords), (1...1_048_576).contains(maximumBytes) else {
        throw SealedMemoryExportError.invalidBounds
    }
    try writer.preflightSealedExport(context: context)
    guard let binding = generationBinding else { throw SealedMemoryExportError.staleBinding }
    do {
        // Lock order matches bound initialization (generation then vault). The writer
        // operation is entered only after these locks, preserving Forget's vault→writer order.
        return try LocalMemoryGenerationTransitionLock().withExclusive(at: binding.generation.parentRoot) {
            try vaultLease.withExclusive {
                try validateExportBinding(binding)
                try store.requireActive()
                return try writer.withSealedExportOperation(context: context) { revalidate in
                    try Self.requireExportNotCancelled()
                    try validateExportBinding(binding)
                    try store.requireActive()
                    let rows = try store.ordinaryExportRows(limit: maximumRecords + 1,
                                                            maximumBodyBytes: maximumBytes,
                                                            maximumTotalBytes: maximumBytes)
                    guard rows.count <= maximumRecords else { throw SealedMemoryExportError.tooLarge }
                    var copiedBytes = 0
                    var records: [SealedMemoryExportRecord] = []
                    records.reserveCapacity(rows.count)
                    for row in rows {
                        guard let kind = MemoryKind(rawValue: row.kind),
                              kind == .profile || kind == .fact,
                              let source = MemorySource(rawValue: row.source) else {
                            throw SealedMemoryExportError.unavailable
                        }
                        copiedBytes += row.id.utf8.count + row.body.utf8.count +
                            row.kind.utf8.count + row.source.utf8.count + 48
                        guard copiedBytes <= maximumBytes else { throw SealedMemoryExportError.tooLarge }
                        records.append(SealedMemoryExportRecord(id: row.id, kind: kind.rawValue,
                            body: row.body, source: source.rawValue, observedAt: row.observedAt,
                            active: row.active, confidence: row.confidence))
                    }
                    _ = try revalidate()
                    try Self.requireExportNotCancelled()
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    var cleartext = try encoder.encode(SealedMemoryExportPayload(
                        format: "personal-memory-export-v1", records: records))
                    defer { cleartext.resetBytes(in: 0..<cleartext.count) }
                    guard cleartext.count <= maximumBytes else { throw SealedMemoryExportError.tooLarge }
                    _ = try revalidate()
                    try Self.requireExportNotCancelled()
                    let envelope = try SealedMemoryExportCodec.seal(cleartext, using: key)
                    try validateExportBinding(binding)
                    try store.requireActive()
                    _ = try revalidate()
                    try Self.requireExportNotCancelled()
                    return envelope
                }
            }
        }
    } catch let error as OwnerMemoryWriterError {
        throw error
    } catch let error as SealedMemoryExportError {
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw SealedMemoryExportError.unavailable
    }
}

private static func requireExportNotCancelled() throws {
    if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { throw CancellationError() }
}

private func validateExportBinding(_ binding: MemoryStoreBinding) throws {
    guard binding.hasConsistentReference() else { throw SealedMemoryExportError.staleBinding }
    let generation = binding.generation
    guard generation.namespace == keychainNamespace,
          generation.root.standardizedFileURL.path == storageRoot.standardizedFileURL.path else {
        throw SealedMemoryExportError.staleBinding
    }
    var rootInfo = stat()
    guard generation.parentRoot.path.withCString({ lstat($0, &rootInfo) }) == 0,
          (rootInfo.st_mode & S_IFMT) == S_IFDIR, rootInfo.st_uid == getuid(),
          (rootInfo.st_mode & 0o777) == 0o700,
          UInt64(rootInfo.st_dev) == binding.device, UInt64(rootInfo.st_ino) == binding.inode else {
        throw SealedMemoryExportError.staleBinding
    }
    if generation.identifier == MemoryStoreGeneration.legacyIdentifier {
        guard generation.root == generation.parentRoot,
              generation.namespace == generation.baseNamespace else {
            throw SealedMemoryExportError.staleBinding
        }
    } else {
        guard let uuid = UUID(uuidString: generation.identifier),
              uuid.uuidString.lowercased() == generation.identifier else {
            throw SealedMemoryExportError.staleBinding
        }
        let suffix = ".generation." + generation.identifier
        let expectedRoot = generation.parentRoot.appendingPathComponent("Generations", isDirectory: true)
            .appendingPathComponent(generation.identifier, isDirectory: true)
        guard generation.root == expectedRoot,
              generation.namespace.databaseKeyService == generation.baseNamespace.databaseKeyService + suffix,
              generation.namespace.vaultService == generation.baseNamespace.vaultService + suffix else {
            throw SealedMemoryExportError.staleBinding
        }
    }
    let item = KeychainMemoryGenerationStateStore(client: keychainClient)
        .stateItem(baseNamespace: generation.baseNamespace)
    do {
        let state = try MemoryGenerationState.decode(keychainClient.copy(item),
            device: binding.device, inode: binding.inode, namespace: generation.baseNamespace)
        guard state.active == generation.identifier, state.transition?.status != .preparing else {
            throw SealedMemoryExportError.staleBinding
        }
    } catch KeychainBoundaryError.missingItem {
        guard generation.identifier == MemoryStoreGeneration.legacyIdentifier else {
            throw SealedMemoryExportError.staleBinding
        }
    }
}

}
