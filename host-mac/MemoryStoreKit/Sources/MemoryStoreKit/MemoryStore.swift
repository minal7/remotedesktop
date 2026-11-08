import CSQLCipherBridge
import Foundation

public protocol MemoryKeyProvider: Sendable {
    func loadKey() throws -> Data
    func destroyKey() throws
}

public enum MemoryStoreError: Error, Equatable {
    case disabled
    case invalidKey
    case invalidQuery
    case cryptoUnavailable
    case authenticationFailed
    case storageFailure(Int32)
    case closed
    case erasurePending
    case invalidInput
    case commandConflict
    case recordNotFound
    case contentPresent
}

public enum MemoryKind: String, Sendable, CaseIterable, Codable {
    case profile
    case fact
    case episode
}

/// The only provenance the first store accepts. There is deliberately no model/page case.
public enum MemorySource: String, Sendable, CaseIterable, Codable {
    case ownerMessage = "owner_message"
    case ownerConfirmed = "owner_confirmed"
}

struct OrdinaryMemoryExportRow: Sendable {
    let id: String
    let kind: String
    let body: String
    let source: String
    let observedAt: Int64
    let active: Bool
    let confidence: Double
}

struct OwnerProposalReceipt: Sendable {
    let ownerID: String
    let sessionID: String
    let taskID: String
    let commandKey: String
    let recordID: String
    let expiresAt: Int64
}

public final class MemoryStore: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let keyProvider: any MemoryKeyProvider
    private let databaseURL: URL
    private let lock = NSLock()
    private var erasurePending = false
    private var keyDestroyed = false
    private var erased = false
    private var failNextErasureCloseForTesting = false

    /// Non-value diagnostic for package tests that prove peer handles close before erasure.
    var hasOpenHandleForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return handle != nil
    }

    /// Inert until peer erasure-close is wired; lets package RED tests inject teardown failure.
    func injectNextErasureCloseFailureForTesting() {
        lock.lock(); defer { lock.unlock() }
        failNextErasureCloseForTesting = true
    }

    private init(handle: OpaquePointer, keyProvider: any MemoryKeyProvider, databaseURL: URL) {
        self.handle = handle
        self.keyProvider = keyProvider
        self.databaseURL = databaseURL
    }

    deinit {
        var current = handle
        if current != nil { _ = memory_sqlcipher_close(&current) }
    }

    /// Disabled composition returns before asking any key provider for material.
    public static func open(enabled: Bool, databaseURL: URL,
                            keyProvider: any MemoryKeyProvider) throws -> MemoryStore? {
        guard enabled else { return nil }
        guard !databaseURL.path.utf8.contains(0) else { throw MemoryStoreError.invalidInput }
        var key = try keyProvider.loadKey()
        defer { key.resetBytes(in: 0..<key.count) }
        guard key.count == 32 else { throw MemoryStoreError.invalidKey }
        var opened: OpaquePointer?
        let status = databaseURL.path.withCString { path in
            key.withUnsafeBytes { bytes in
                memory_sqlcipher_open(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                                     bytes.count, &opened)
            }
        }
        try Self.check(status)
        guard let opened else { throw MemoryStoreError.cryptoUnavailable }
        let schemaStatus = memory_sqlcipher_create_schema(opened)
        do { try Self.check(schemaStatus) }
        catch {
            var toClose: OpaquePointer? = opened
            _ = memory_sqlcipher_close(&toClose)
            throw error
        }
        return MemoryStore(handle: opened, keyProvider: keyProvider, databaseURL: databaseURL)
    }

    /// Raw store writer for this unlinked module. Source/provenance are caller data, not authorization.
    func upsert(_ record: MemoryRecord) throws {
        guard Self.validText(record.id, maximumBytes: 512),
              Self.validText(record.body, maximumBytes: 32_768),
              Self.validOptionalText(record.provenance.sourceMessageID, maximumBytes: 512),
              Self.validOptionalText(record.provenance.proposalID, maximumBytes: 512),
              Self.validOptionalText(record.provenance.statementID, maximumBytes: 512),
              Self.validOptionalText(record.provenance.candidateOrigin, maximumBytes: 32),
              Self.validOptionalText(record.provenance.sourceReference, maximumBytes: 1024),
              Self.validOptionalText(record.provenance.sourceSpan, maximumBytes: 1024) else {
            throw MemoryStoreError.invalidInput
        }
        try withHandle { db in
            let status = Self.withUTF8Bytes(record.id) { id in
                Self.withUTF8Bytes(record.kind.rawValue) { kind in
                    Self.withUTF8Bytes(record.body) { body in
                        Self.withUTF8Bytes(record.source.rawValue) { source in
                            Self.withOptionalUTF8Bytes(record.provenance.sourceMessageID) { messageID in
                                    Self.withOptionalUTF8Bytes(record.provenance.proposalID) { proposalID in
                                        Self.withOptionalUTF8Bytes(record.provenance.statementID) { statementID in
                                         Self.withOptionalUTF8Bytes(record.provenance.candidateOrigin) { origin in
                                          Self.withOptionalUTF8Bytes(record.provenance.sourceReference) { sourceReference in
                                           Self.withOptionalUTF8Bytes(record.provenance.sourceSpan) { sourceSpan in
                                            memory_sqlcipher_upsert_record(db,
                                                id.baseAddress, id.count, kind.baseAddress, kind.count,
                                                body.baseAddress, body.count, source.baseAddress, source.count,
                                                messageID.baseAddress, messageID.count,
                                                proposalID.baseAddress, proposalID.count,
                                                statementID.baseAddress, statementID.count,
                                                origin.baseAddress, origin.count, sourceReference.baseAddress,
                                                sourceReference.count, sourceSpan.baseAddress, sourceSpan.count,
                                                record.observedAt, record.active ? 1 : 0, record.confidence)
                                           }
                                          }
                                         }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            try Self.check(status)
        }
    }

    func commitOwnerCommand(_ record: MemoryRecord, commandKey: String, payloadDigest: Data,
                            receipt: (ownerID: String, sessionID: String, taskID: String, expiresAt: Int64)? = nil) throws -> (recordID: String, idempotent: Bool) {
        guard Self.validText(commandKey, maximumBytes: 1024), payloadDigest.count == 32 else {
            throw MemoryStoreError.invalidInput
        }
        return try withHandle { db in
            var result: UnsafeMutablePointer<CChar>?
            var idempotent: Int32 = 0
            let status = Self.withUTF8Bytes(commandKey) { command in
                payloadDigest.withUnsafeBytes { digest in
                    Self.withUTF8Bytes(record.id) { id in
                        Self.withUTF8Bytes(record.kind.rawValue) { kind in
                            Self.withUTF8Bytes(record.body) { body in
                                Self.withUTF8Bytes(record.source.rawValue) { source in
                                    Self.withOptionalUTF8Bytes(record.provenance.sourceMessageID) { message in
                                        Self.withOptionalUTF8Bytes(record.provenance.proposalID) { proposal in
                                            Self.withOptionalUTF8Bytes(record.provenance.statementID) { statement in
                                             Self.withOptionalUTF8Bytes(receipt?.ownerID) { owner in
                                              Self.withOptionalUTF8Bytes(receipt?.sessionID) { session in
                                               Self.withOptionalUTF8Bytes(receipt?.taskID) { task in
                                                Self.withOptionalUTF8Bytes(record.provenance.candidateOrigin) { origin in
                                                 Self.withOptionalUTF8Bytes(record.provenance.sourceReference) { sourceReference in
                                                  Self.withOptionalUTF8Bytes(record.provenance.sourceSpan) { sourceSpan in
                                                memory_sqlcipher_commit_owner_command(db,
                                                    command.baseAddress, command.count,
                                                    digest.bindMemory(to: UInt8.self).baseAddress, digest.count,
                                                    id.baseAddress, id.count, kind.baseAddress, kind.count,
                                                    body.baseAddress, body.count, source.baseAddress, source.count,
                                                    message.baseAddress, message.count, proposal.baseAddress, proposal.count,
                                                    statement.baseAddress, statement.count,
                                                    owner.baseAddress, owner.count, session.baseAddress, session.count,
                                                    task.baseAddress, task.count, receipt?.expiresAt ?? 0,
                                                    origin.baseAddress, origin.count, sourceReference.baseAddress,
                                                    sourceReference.count, sourceSpan.baseAddress, sourceSpan.count,
                                                    record.observedAt,
                                                    record.confidence, &result, &idempotent)
                                                  }
                                                 }
                                                }
                                               }
                                              }
                                             }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if status == MemorySQLCipherStatusConflict { throw MemoryStoreError.commandConflict }
            try Self.check(status)
            guard let result else { throw MemoryStoreError.storageFailure(-1) }
            defer { memory_sqlcipher_free_text(result) }
            return (String(cString: result), idempotent == 1)
        }
    }

    func commitOwnerEdit(expected: MemoryRecord?, revisionMatches: Bool, replacement: MemoryRecord,
                         commandKey: String, payloadDigest: Data) throws -> (recordID: String, idempotent: Bool) {
        guard Self.validText(commandKey, maximumBytes: 1024), payloadDigest.count == 32,
              replacement.body.utf8.count <= 4_096 else { throw MemoryStoreError.invalidInput }
        let expectedBytes = expected.map(Self.encodeEditRecord) ?? Data()
        let replacementBytes = Self.encodeEditRecord(replacement)
        return try withHandle { db in
            var result: UnsafeMutablePointer<CChar>?
            var idempotent: Int32 = 0
            let status = Self.withUTF8Bytes(commandKey) { command in
                payloadDigest.withUnsafeBytes { digest in
                    expectedBytes.withUnsafeBytes { expectedBuffer in
                        replacementBytes.withUnsafeBytes { replacementBuffer in
                            memory_sqlcipher_edit_owner_record(db,
                                command.baseAddress, command.count,
                                digest.bindMemory(to: UInt8.self).baseAddress, digest.count,
                                expectedBuffer.bindMemory(to: UInt8.self).baseAddress, expectedBuffer.count,
                                revisionMatches ? 1 : 0,
                                replacementBuffer.bindMemory(to: UInt8.self).baseAddress, replacementBuffer.count,
                                &result, &idempotent)
                        }
                    }
                }
            }
            if status == MemorySQLCipherStatusConflict { throw MemoryStoreError.commandConflict }
            if status == MemorySQLCipherStatusNotFound { throw MemoryStoreError.recordNotFound }
            try Self.check(status)
            guard let result else { throw MemoryStoreError.storageFailure(-1) }
            defer { memory_sqlcipher_free_text(result) }
            return (String(cString: result), idempotent == 1)
        }
    }

    func proposalReceipt(id: String) throws -> OwnerProposalReceipt? {
        guard Self.validText(id, maximumBytes: 512) else { throw MemoryStoreError.invalidInput }
        return try withHandle { db in
            var receipt = MemorySQLCipherProposalReceipt()
            let status = Self.withUTF8Bytes(id) {
                memory_sqlcipher_get_proposal_receipt(db, $0.baseAddress, $0.count, &receipt)
            }
            try Self.check(status)
            defer { memory_sqlcipher_free_proposal_receipt(&receipt) }
            guard let owner = receipt.ownerID, let session = receipt.sessionID,
                  let task = receipt.taskID, let command = receipt.commandKey,
                  let record = receipt.recordID else { return nil }
            return OwnerProposalReceipt(ownerID: String(cString: owner), sessionID: String(cString: session),
                taskID: String(cString: task), commandKey: String(cString: command),
                recordID: String(cString: record), expiresAt: receipt.expiresAt)
        }
    }

    func upsertVaultDisplay(_ value: VaultHandleDisplay) throws {
        let handle = value.id.uuidString
        let label = value.displayText
        try withHandle { db in
            let status = Self.withUTF8Bytes(handle) { handleBytes in
                Self.withUTF8Bytes(label) { displayBytes in
                    memory_sqlcipher_upsert_vault_display(db, handleBytes.baseAddress, handleBytes.count,
                                                         displayBytes.baseAddress, displayBytes.count)
                }
            }
            try Self.check(status)
        }
    }

    func reserveVaultCreate(commandKey: String, ownerID: String, itemID: UUID,
                            kind: OwnerVaultEntryKind) throws {
        try withHandle { db in
            let status = Self.withUTF8Bytes(commandKey) { command in
                Self.withUTF8Bytes(ownerID) { owner in
                    Self.withUTF8Bytes(itemID.uuidString.lowercased()) { item in
                        Self.withUTF8Bytes(kind.rawValue) { kindBytes in
                            memory_sqlcipher_reserve_vault_create(db,
                                command.baseAddress, command.count, owner.baseAddress, owner.count,
                                item.baseAddress, item.count, kindBytes.baseAddress, kindBytes.count)
                        }
                    }
                }
            }
            try Self.check(status)
        }
    }

    func completeVaultCreate(commandKey: String, ownerID: String, itemID: UUID,
                             displayText: String) throws {
        try withHandle { db in
            let status = Self.withUTF8Bytes(commandKey) { command in
                Self.withUTF8Bytes(ownerID) { owner in
                    Self.withUTF8Bytes(itemID.uuidString.lowercased()) { item in
                        Self.withUTF8Bytes(displayText) { display in
                            memory_sqlcipher_complete_vault_create(db,
                                command.baseAddress, command.count, owner.baseAddress, owner.count,
                                item.baseAddress, item.count, display.baseAddress, display.count)
                        }
                    }
                }
            }
            try Self.check(status)
        }
    }

    func vaultCreateStatus(commandKey: String, ownerID: String) throws -> VaultCreateReservation {
        try withHandle { db in
            var status = MemorySQLCipherVaultCreateStatus()
            let result = Self.withUTF8Bytes(commandKey) { command in
                Self.withUTF8Bytes(ownerID) { owner in
                    memory_sqlcipher_vault_create_status(db, command.baseAddress, command.count,
                        owner.baseAddress, owner.count, &status)
                }
            }
            defer { memory_sqlcipher_free_vault_create_status(&status) }
            try Self.check(result)
            guard let itemText = status.itemID.flatMap({ String(validatingCString: $0) }),
                  let itemID = UUID(uuidString: itemText),
                  let kindText = status.kind.flatMap({ String(validatingCString: $0) }),
                  let kind = OwnerVaultEntryKind(rawValue: kindText),
                  itemText == Self.itemIDCanonical(itemText),
                  (status.state == 0 || status.state == 1) else {
                throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
            }
            let display: String?
            if status.state == 0 {
                guard status.displayText == nil else {
                    throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
                }
                display = nil
            } else {
                guard let raw = status.displayText, let decoded = String(validatingCString: raw) else {
                    throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
                }
                display = decoded
            }
            if let display, !Self.validVaultCreateDisplay(display, kind: kind) {
                throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
            }
            return VaultCreateReservation(itemID: itemID, kind: kind,
                state: status.state == 0 ? .pending : .completed, displayText: display)
        }
    }

    func enrollVaultApprovalKey(ownerID: String, peerID: String, publicKey: Data) throws {
        guard publicKey.count == 65 else { throw MemoryStoreError.invalidInput }
        try withHandle { db in
            try Self.withUTF8Bytes(ownerID) { owner in
                try Self.withUTF8Bytes(peerID) { peer in
                    let status = publicKey.withUnsafeBytes { key in
                        memory_sqlcipher_enroll_vault_approval_key(db,
                            owner.baseAddress, owner.count, peer.baseAddress, peer.count,
                            key.bindMemory(to: UInt8.self).baseAddress, key.count)
                    }
                    try Self.check(status)
                }
            }
        }
    }

    func vaultApprovalKey(ownerID: String, peerID: String) throws -> Data? {
        try withHandle { db in
            try Self.withUTF8Bytes(ownerID) { owner in
                try Self.withUTF8Bytes(peerID) { peer in
                    var bytes: UnsafeMutablePointer<UInt8>?
                    var length = 0
                    let status = memory_sqlcipher_get_vault_approval_key(db,
                        owner.baseAddress, owner.count, peer.baseAddress, peer.count,
                        &bytes, &length)
                    if status == MemorySQLCipherStatusNotFound { return nil }
                    try Self.check(status)
                    guard length == 65, let bytes else {
                        memory_sqlcipher_free_bytes(bytes)
                        throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
                    }
                    defer { memory_sqlcipher_free_bytes(bytes) }
                    return Data(bytes: bytes, count: length)
                }
            }
        }
    }

    private static func itemIDCanonical(_ value: String) -> String { value.lowercased() }

    private static func validVaultCreateDisplay(_ value: String, kind: OwnerVaultEntryKind) -> Bool {
        switch kind {
        case .address: return value == VaultDisplayLabel.homeAddress.rawValue || value == VaultDisplayLabel.workAddress.rawValue
        case .phone: return value == VaultDisplayLabel.mobilePhone.rawValue
        case .membership: return value == VaultDisplayLabel.membership.rawValue
        case .identity: return value == VaultDisplayLabel.identityDocument.rawValue
        case .paymentCard:
            for brand in VaultCardBrand.allCases {
                let prefix = "\(brand.rawValue) ending in "
                guard value.hasPrefix(prefix) else { continue }
                let tail = value.dropFirst(prefix.count)
                guard tail.count == 4 + ", expires 00/0000".count,
                      tail.prefix(4).utf8.allSatisfy({ (48...57).contains($0) }),
                      tail.dropFirst(4).hasPrefix(", expires ") else { return false }
                let date = tail.dropFirst(4 + ", expires ".count)
                let parts = date.split(separator: "/")
                guard parts.count == 2, let month = Int(parts[0]), let year = Int(parts[1]),
                      (1...12).contains(month), (2000...2200).contains(year),
                      String(format: "%02d", month) == parts[0], String(year) == parts[1] else { return false }
                return true
            }
            return false
        }
    }

    // Durable, value-free inventory used by the coordinated whole-product Forget path.
    // These entry points intentionally remain internal; callers must not create vault fields
    // until registerVaultItem has committed successfully.
    func registerVaultItem(_ id: UUID) throws {
        let identifier = id.uuidString.lowercased()
        try withHandle { db in
            try Self.check(Self.withUTF8Bytes(identifier) {
                memory_sqlcipher_register_vault_item(db, $0.baseAddress, $0.count)
            })
        }
    }

    func beginVaultErasure() throws {
        lock.lock(); defer { lock.unlock() }
        if erased { return }
        if erasurePending { return }
        guard let handle else { throw MemoryStoreError.closed }
        try Self.check(memory_sqlcipher_begin_vault_erasure(handle))
    }

    func vaultItemIDsForErasure() throws -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        if erased { return [] }
        if erasurePending { return [] }
        guard let handle else { throw MemoryStoreError.closed }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        try Self.check(memory_sqlcipher_vault_inventory(handle, &bytes, &length))
        guard length % 36 == 0, length <= 1024 * 36 else {
            memory_sqlcipher_free_bytes(bytes)
            throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
        }
        guard let bytes else { return [] }
        defer { memory_sqlcipher_free_bytes(bytes) }
        let raw = UnsafeBufferPointer(start: bytes, count: length)
        var identifiers: [UUID] = []
        identifiers.reserveCapacity(length / 36)
        for offset in stride(from: 0, to: length, by: 36) {
            let chunk = raw[offset..<(offset + 36)]
            guard let string = String(bytes: chunk, encoding: .utf8),
                  let identifier = UUID(uuidString: string),
                  identifier.uuidString.lowercased() == string else {
                throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
            }
            identifiers.append(identifier)
        }
        return identifiers
    }

    func completeVaultItemErasure() throws {
        lock.lock(); defer { lock.unlock() }
        if erased { return }
        if erasurePending { return }
        guard let handle else { throw MemoryStoreError.closed }
        try Self.check(memory_sqlcipher_complete_vault_erasure(handle))
    }

    func requireActive() throws {
        try withHandle { _ in () }
    }

    func isVaultErasurePending() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if erased { return false }
        if erasurePending { return true }
        guard let handle else { throw MemoryStoreError.closed }
        var pending: Int32 = 0
        try Self.check(memory_sqlcipher_vault_erasure_pending(handle, &pending))
        guard pending == 0 || pending == 1 else {
            throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
        }
        return pending == 1
    }

    /// Confirms that no app-owned memory or metadata remains before initializing a generation.
    func requireEmptyForInitialization() throws {
        try withHandle { db in
            try Self.check(memory_sqlcipher_require_empty_for_initialization(db))
        }
    }

    func get(id: String) throws -> MemoryRecord? {
        guard Self.validText(id, maximumBytes: 512) else { throw MemoryStoreError.invalidInput }
        return try withHandle { db in
            var row: UnsafeMutablePointer<MemorySQLCipherSearchRow>?
            let status = Self.withUTF8Bytes(id) { memory_sqlcipher_get(db, $0.baseAddress, $0.count, &row) }
            try Self.check(status)
            guard let row else { return nil }
            defer { memory_sqlcipher_free_search_rows(row, 1) }
            return Self.record(from: row.pointee)
        }
    }

    /// Read records for a UI list. The bound limits this query to at most 500 rows.
    func list(includeInactive: Bool = true, limit: Int = 200) throws -> [MemoryRecord] {
        guard (1...500).contains(limit) else { throw MemoryStoreError.invalidInput }
        return try withHandle { db in
            var rows: UnsafeMutablePointer<MemorySQLCipherSearchRow>?
            var count = 0
            try Self.check(memory_sqlcipher_list(db, includeInactive ? 1 : 0, Int32(limit), &rows, &count))
            guard let rows else { return [] }
            defer { memory_sqlcipher_free_search_rows(rows, count) }
            return (0..<count).compactMap { Self.record(from: rows[$0]) }
        }
    }

    func ownerRecordsPage(query: String?, afterRecordID: String?, limit: Int) throws -> [MemoryRecord] {
        guard (1...32).contains(limit), Self.validOptionalText(afterRecordID, maximumBytes: 512),
              Self.validOptionalText(query, maximumBytes: 2048) else { throw MemoryStoreError.invalidInput }
        if let query, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemoryStoreError.invalidQuery
        }
        return try withHandle { db in
            var rows: UnsafeMutablePointer<MemorySQLCipherSearchRow>?
            var count = 0
            let status = Self.withOptionalUTF8Bytes(query) { queryBytes in
                Self.withOptionalUTF8Bytes(afterRecordID) { afterBytes in
                    memory_sqlcipher_owner_page(db,
                        query == nil ? nil : queryBytes.baseAddress, queryBytes.count,
                        afterRecordID == nil ? nil : afterBytes.baseAddress, afterBytes.count,
                        Int32(limit + 1), &rows, &count)
                }
            }
            try Self.check(status)
            guard let rows else { return [] }
            defer { memory_sqlcipher_free_search_rows(rows, count) }
            var records: [MemoryRecord] = []
            records.reserveCapacity(count)
            for index in 0..<count {
                guard let record = Self.record(from: rows[index]) else {
                    throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
                }
                records.append(record)
            }
            return records
        }
    }

    func ordinaryExportRows(limit: Int, maximumBodyBytes: Int,
                            maximumTotalBytes: Int) throws -> [OrdinaryMemoryExportRow] {
        guard (1...501).contains(limit), (1...1_048_576).contains(maximumBodyBytes) else {
            throw MemoryStoreError.invalidInput
        }
        guard (1...1_048_576).contains(maximumTotalBytes) else { throw MemoryStoreError.invalidInput }
        return try withHandle { db in
            var rows: UnsafeMutablePointer<MemorySQLCipherExportRow>?
            var count = 0
            try Self.check(memory_sqlcipher_export_rows(db, Int32(limit), maximumBodyBytes,
                                                        maximumTotalBytes, &rows, &count))
            guard let rows else { return [] }
            defer { memory_sqlcipher_free_export_rows(rows, count) }
            var result: [OrdinaryMemoryExportRow] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let row = rows[index]
                guard let idPointer = row.identifier, let kindPointer = row.recordType,
                      let bodyPointer = row.body, let sourcePointer = row.source,
                      let id = String(validatingCString: idPointer),
                      let kind = String(validatingCString: kindPointer),
                      let body = String(validatingCString: bodyPointer),
                      let source = String(validatingCString: sourcePointer) else {
                    throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
                }
                result.append(OrdinaryMemoryExportRow(id: id, kind: kind,
                    body: body, source: source, observedAt: row.observedAt,
                    active: row.status == 1, confidence: row.confidence))
            }
            return result
        }
    }

    func setActive(_ active: Bool, id: String) throws {
        guard Self.validText(id, maximumBytes: 512) else { throw MemoryStoreError.invalidInput }
        try withHandle { db in
            try Self.check(Self.withUTF8Bytes(id) {
                memory_sqlcipher_update_status(db, $0.baseAddress, $0.count, active ? 1 : 0)
            })
        }
    }

    func search(_ query: String, limit: Int = 10) throws -> [MemoryMatch] {
        guard (1...50).contains(limit), Self.validText(query, maximumBytes: 2048),
              !query.isEmpty else { throw MemoryStoreError.invalidQuery }
        return try withHandle { db in
            var rows: UnsafeMutablePointer<MemorySQLCipherSearchRow>?
            var count = 0
            let queryBytes = Array(query.utf8)
            let status = queryBytes.withUnsafeBufferPointer {
                memory_sqlcipher_search(db, $0.baseAddress, $0.count, Int32(limit), &rows, &count)
            }
            try Self.check(status)
            guard let rows else { return [] }
            defer { memory_sqlcipher_free_search_rows(rows, count) }
            return (0..<count).compactMap { index in
                let row = rows[index]
                guard let record = Self.record(from: row) else { return nil }
                return MemoryMatch(record: record, rank: row.bm25Rank)
            }
        }
    }

    func forget(id: String) throws {
        guard Self.validText(id, maximumBytes: 512) else { throw MemoryStoreError.invalidInput }
        try withHandle { db in
            let status = Self.withUTF8Bytes(id) {
                memory_sqlcipher_delete(db, $0.baseAddress, $0.count)
            }
            try Self.check(status)
        }
    }

    /// Logical deletion followed by close and key destruction. File removal is best-effort
    /// cleanup, not a claim of physical erasure on copy-on-write or SSD storage.
    func forgetAll() throws {
        lock.lock()
        defer { lock.unlock() }
        if erased { return }
        if let active = handle {
            try Self.check(memory_sqlcipher_delete_all(active))
            erasurePending = true
            try Self.check(memory_sqlcipher_checkpoint(active))
            var current: OpaquePointer? = active
            try Self.check(memory_sqlcipher_close(&current))
            handle = nil
        } else {
            erasurePending = true
        }
        if !keyDestroyed {
            try keyProvider.destroyKey()
            keyDestroyed = true
        }
        for suffix in ["-wal", "-shm", "-journal", ""] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        erased = true
        erasurePending = false
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        if erasurePending { throw MemoryStoreError.erasurePending }
        guard let active = handle else { return }
        try Self.check(memory_sqlcipher_checkpoint(active))
        var current: OpaquePointer? = active
        try Self.check(memory_sqlcipher_close(&current))
        handle = nil
    }

    /// Closes a peer connection after the durable erasure fence. No checkpoint or key operation
    /// is attempted here; the initiating service owns key deletion after every peer is closed.
    func closeForErasure() throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextErasureCloseForTesting {
            failNextErasureCloseForTesting = false
            throw MemoryStoreError.storageFailure(-1)
        }
        guard let active = handle else { return }
        var current: OpaquePointer? = active
        try Self.check(memory_sqlcipher_close(&current))
        handle = nil
    }

    private func withHandle<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if erasurePending { throw MemoryStoreError.erasurePending }
        guard let handle else { throw MemoryStoreError.closed }
        try Self.check(memory_sqlcipher_require_active(handle))
        return try operation(handle)
    }

    private static func check(_ status: MemorySQLCipherStatus) throws {
        switch status {
        case MemorySQLCipherStatusOK: return
        case MemorySQLCipherStatusCryptoUnavailable: throw MemoryStoreError.cryptoUnavailable
        case MemorySQLCipherStatusAuthenticationFailed: throw MemoryStoreError.authenticationFailed
        case MemorySQLCipherStatusConflict: throw MemoryStoreError.commandConflict
        case MemorySQLCipherStatusNotFound: throw MemoryStoreError.recordNotFound
        case MemorySQLCipherStatusErasurePending: throw MemoryStoreError.erasurePending
        case MemorySQLCipherStatusContentPresent: throw MemoryStoreError.contentPresent
        default: throw MemoryStoreError.storageFailure(Int32(status.rawValue))
        }
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.utf8.contains(0)
    }

    private static func validOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        return validText(value, maximumBytes: maximumBytes)
    }

    private static func record(from row: MemorySQLCipherSearchRow) -> MemoryRecord? {
        guard let id = row.identifier, let kindText = row.recordType,
              let kind = MemoryKind(rawValue: String(cString: kindText)),
              let body = row.body, let sourceText = row.source,
              let source = MemorySource(rawValue: String(cString: sourceText)) else { return nil }
        return MemoryRecord(id: String(cString: id), kind: kind, body: String(cString: body),
            source: source, observedAt: row.observedAt, active: row.status == 1,
            confidence: row.confidence, provenance: MemoryProvenance(
                sourceMessageID: row.sourceMessageID.map { String(cString: $0) },
                proposalID: row.proposalID.map { String(cString: $0) },
                statementID: row.statementID.map { String(cString: $0) },
                candidateOrigin: row.candidateOrigin.map { String(cString: $0) },
                sourceReference: row.sourceReference.map { String(cString: $0) },
                sourceSpan: row.sourceSpan.map { String(cString: $0) }))
    }

    private static func withUTF8Bytes<T>(_ value: String,
                                         _ operation: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        let bytes = Array(value.utf8)
        return try bytes.withUnsafeBufferPointer(operation)
    }

    private static func withOptionalUTF8Bytes<T>(_ value: String?,
        _ operation: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        let bytes = Array((value ?? "").utf8)
        return try bytes.withUnsafeBufferPointer(operation)
    }

    private static func encodeEditRecord(_ record: MemoryRecord) -> Data {
        var result = Data()
        let required = [record.id, record.kind.rawValue, record.body, record.source.rawValue]
        let optional = [record.provenance.sourceMessageID, record.provenance.proposalID,
            record.provenance.statementID, record.provenance.candidateOrigin,
            record.provenance.sourceReference, record.provenance.sourceSpan]
        for value in required {
            appendEditField(Data(value.utf8), to: &result)
        }
        var timestamp = UInt64(bitPattern: record.observedAt).bigEndian
        withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }
        result.append(record.active ? 1 : 0)
        var confidence = record.confidence.bitPattern.bigEndian
        withUnsafeBytes(of: &confidence) { result.append(contentsOf: $0) }
        for value in optional {
            appendEditField(Data((value ?? "").utf8), to: &result)
        }
        return result
    }

    private static func appendEditField(_ field: Data, to result: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(field)
    }
}
