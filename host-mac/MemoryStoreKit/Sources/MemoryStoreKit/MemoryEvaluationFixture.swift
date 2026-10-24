#if DEBUG
import Foundation
import CryptoKit

/// Value-free receipt for one complete ordinary-memory snapshot.
public struct MemoryEvaluationSnapshotDigest: Sendable, Equatable {
    public let recordCount: Int
    public let sha256: String

    fileprivate init(recordCount: Int, sha256: String) {
        self.recordCount = recordCount
        self.sha256 = sha256
    }
}

private struct MemoryEvaluationDigestSnapshot: Encodable {
    let version = 1
    let records: [MemoryEvaluationDigestRecord]
}

private struct MemoryEvaluationDigestRecord: Encodable {
    let id: String
    let kind: String
    let body: String
    let source: String
    let observedAt: Int64
    let active: Bool
    let confidenceBits: String
    let sourceMessageID: String?
    let proposalID: String?
    let statementID: String?
    let candidateOrigin: String?
    let sourceReference: String?
    let sourceSpan: String?

    init(_ record: MemoryRecord) {
        id = record.id
        kind = record.kind.rawValue
        body = record.body
        source = record.source.rawValue
        observedAt = record.observedAt
        active = record.active
        confidenceBits = String(record.confidence.bitPattern)
        sourceMessageID = record.provenance.sourceMessageID
        proposalID = record.provenance.proposalID
        statementID = record.provenance.statementID
        candidateOrigin = record.provenance.candidateOrigin
        sourceReference = record.provenance.sourceReference
        sourceSpan = record.provenance.sourceSpan
    }
}

/// Synthetic ordinary-memory row used only by the opt-in DEBUG evaluation fixture.
/// This DTO cannot represent vault handles or secret values.
public struct MemoryEvaluationFixtureRecord: Sendable {
    public let id: String
    public let kind: OwnerRememberKind
    public let body: String
    public let observedAt: Int64
    public let active: Bool

    public init(id: String, kind: OwnerRememberKind, body: String,
                observedAt: Int64, active: Bool) {
        self.id = id
        self.kind = kind
        self.body = body
        self.observedAt = observedAt
        self.active = active
    }
}

/// A private SQLCipher fixture with an in-memory fake Keychain. Its fixed owner identity
/// limits the writer to the exact synthetic evaluation task that created it.
public final class MemoryEvaluationFixture: @unchecked Sendable {
    public let service: PersonalMemoryService
    public let binding: MemoryStoreBinding
    public let ownerID: String
    public let sessionID: String
    public let taskID: String
    private let root: URL
    private let keychain: EvaluationFixtureKeychain
    private let namespace: KeychainNamespace
    private let closeLock = NSLock()
    private var closed = false

    fileprivate init(service: PersonalMemoryService, binding: MemoryStoreBinding,
                     ownerID: String, sessionID: String, taskID: String, root: URL,
                     keychain: EvaluationFixtureKeychain, namespace: KeychainNamespace) {
        self.service = service
        self.binding = binding
        self.ownerID = ownerID
        self.sessionID = sessionID
        self.taskID = taskID
        self.root = root
        self.keychain = keychain
        self.namespace = namespace
    }

    /// Reopens only this fixture's private generation and hashes every ordinary record,
    /// including inactive rows. Bodies are input to the digest and are never returned.
    public func snapshotDigest() throws -> MemoryEvaluationSnapshotDigest {
        closeLock.lock()
        let isClosed = closed
        closeLock.unlock()
        guard !isClosed else { throw MemoryStoreError.closed }
        let captured = try MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keychain, namespace: namespace)
        guard captured == binding else { throw MemoryStoreError.invalidInput }
        guard let snapshotService = try MemoryStoreFactory.openForTesting(enabled: true,
            root: root, client: keychain, random: keychain, namespace: namespace,
            authorize: { $0 == OwnerMemoryContext(ownerID: self.ownerID,
                sessionID: self.sessionID, taskID: self.taskID) },
            isTaskActive: { owner, task in owner == self.ownerID && task == self.taskID },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }) else {
            throw MemoryStoreError.disabled
        }
        defer { try? snapshotService.close() }
        let context = OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID, taskID: taskID)
        let records = try snapshotService.writer.list(context: context, limit: 500)
        // list() is bounded at 500 and cannot distinguish exactly 500 from truncation.
        guard records.count < 500 else { throw MemoryStoreError.invalidInput }
        let rows = records.sorted { $0.id < $1.id }.map(MemoryEvaluationDigestRecord.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(MemoryEvaluationDigestSnapshot(records: rows))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return MemoryEvaluationSnapshotDigest(recordCount: records.count, sha256: digest)
    }

    public func close() throws {
        closeLock.lock()
        guard !closed else { closeLock.unlock(); return }
        closed = true
        closeLock.unlock()
        do { try service.close() }
        catch {
            closeLock.lock(); closed = false; closeLock.unlock()
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    deinit { try? close() }
}

private final class EvaluationFixtureKeychain: KeychainClient, MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExactKeychainItem: Data] = [:]
    private var nextByte: UInt8 = 0x41

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        items[item] = data
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard items.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }

    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[item] != nil else { throw KeychainBoundaryError.missingItem }
        items[item] = data
    }

    func bytes(count: Int) throws -> Data {
        guard count == 32 else { throw KeychainBoundaryError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        nextByte &+= 1
        return Data(repeating: nextByte, count: count)
    }
}

public extension MemoryStoreFactory {
    /// Creates one bounded, private DEBUG fixture using SQLCipher and an in-memory fake key store.
    /// This entry point never falls back to production paths, Keychain, or default namespaces.
    static func makeDebugEvaluationFixture(enabled: Bool,
        records: [MemoryEvaluationFixtureRecord], ownerID: String,
        sessionID: String, taskID: String) throws -> MemoryEvaluationFixture? {
        guard enabled else { return nil }
        guard validFixtureIdentity(ownerID, maximum: 128),
              validFixtureIdentity(sessionID, maximum: 128),
              validFixtureIdentity(taskID, maximum: 128),
              (1...8).contains(records.count),
              Set(records.map(\.id)).count == records.count,
              records.allSatisfy({
                  validFixtureIdentity($0.id, maximum: 128)
                      && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.body.utf8.count <= 2_048
              }) else {
            throw MemoryStoreError.invalidInput
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryEvaluation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let keys = EvaluationFixtureKeychain()
        let namespace = KeychainNamespace.testing(UUID().uuidString.lowercased())
        let context = OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID, taskID: taskID)
        var service: PersonalMemoryService?
        do {
            guard let opened = try openForTesting(enabled: true, root: root, client: keys,
                random: keys, namespace: namespace,
                authorize: { $0 == context },
                isTaskActive: { owner, task in owner == ownerID && task == taskID },
                policy: { OwnerMemoryPolicy(featureEnabled: true) }) else {
                throw MemoryStoreError.disabled
            }
            service = opened
            for record in records {
                try opened.store.upsert(MemoryRecord(id: record.id,
                    kind: record.kind == .profile ? .profile : .fact, body: record.body,
                    source: .ownerMessage, observedAt: record.observedAt, active: record.active,
                    provenance: MemoryProvenance(statementID: "debug-evaluation-fixture")))
            }
            guard let binding = try captureBindingForTesting(enabled: true, root: root,
                client: keys, namespace: namespace) else {
                throw MemoryStoreError.storageFailure(-1)
            }
            return MemoryEvaluationFixture(service: opened, binding: binding,
                ownerID: ownerID, sessionID: sessionID, taskID: taskID, root: root,
                keychain: keys, namespace: namespace)
        } catch {
            try? service?.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private func validFixtureIdentity(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
        && value.utf8.allSatisfy { (33...126).contains($0) }
}
#endif
