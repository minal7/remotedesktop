import CloudKit
import Foundation

/// Point-to-point CloudKit transport for computer-use prompts and state.
/// Both apps use the user's private database, matching the existing signaling
/// privacy model. The host may accept any session ID for its current pairing
/// code; an iOS client scopes reads to its own session ID.
public actor CloudKitComputerUseChannel {
    public init(
        containerIdentifier: String,
        pairingCode: String,
        sessionID: String? = nil,
        senderID: String = DeviceIdentity.get(),
        targetID: String? = nil,
        startedAt: Date = Date()
    ) {
        self.containerIdentifier = containerIdentifier
        self.pairingCode = pairingCode
        self.sessionID = sessionID
        self.senderID = senderID
        self.targetID = targetID
        self.startedAt = startedAt
    }

    @discardableResult
    public func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String? = nil,
        sessionID explicitSessionID: String? = nil,
        messageID explicitMessageID: String? = nil
    ) async throws -> ComputerUseEnvelope {
        let destination = explicitTargetID ?? targetID
        guard let destination, !destination.isEmpty else {
            throw SignalingError.transport("The AI host could not be identified. Return to Devices and try again.")
        }
        let messageSessionID = explicitSessionID ?? sessionID
        guard let messageSessionID, !messageSessionID.isEmpty else {
            throw SignalingError.transport("The AI session could not be identified. Start a new session and try again.")
        }

        try await ensureAccountAvailable()
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: senderID,
            targetID: destination,
            pairingCode: pairingCode,
            sessionID: messageSessionID,
            kind: kind,
            body: body)
        let record = try Self.record(for: envelope)

        do {
            try await saveStableRecord(record, matching: envelope)
            return envelope
        } catch {
            throw Self.userFacingError(error, operation: "send the AI request")
        }
    }

    public func poll() async throws -> [ComputerUseEnvelope] {
        try await ensureAccountAvailable()
        try? await flushPendingAcknowledgements()
        let cutoff = max(startedAt, Date(timeIntervalSinceNow: -Self.staleSeconds))
        let predicate = NSPredicate(
            format: "targetID == %@ AND createdAt > %@",
            senderID,
            cutoff as NSDate)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let desiredKeys = [
            "senderID", "targetID", "pairingCode", "kind", "payload", "createdAt",
        ]
        var results: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        do {
            var response = try await retryingCloudKit {
                try await database.records(
                    matching: query,
                    inZoneWith: nil,
                    desiredKeys: desiredKeys,
                    resultsLimit: 100)
            }
            results.append(contentsOf: response.matchResults)
            while let cursor = response.queryCursor {
                response = try await retryingCloudKit {
                    try await database.records(
                        continuingMatchFrom: cursor,
                        desiredKeys: desiredKeys,
                        resultsLimit: 100)
                }
                results.append(contentsOf: response.matchResults)
            }
        } catch let error as CKError where error.code == .unknownItem {
            return []
        } catch {
            throw Self.userFacingError(error, operation: "check AI progress")
        }

        var envelopes: [ComputerUseEnvelope] = []
        for (recordID, result) in results {
            guard !consumedRecordIDs.contains(recordID) else { continue }
            guard case .success(let record) = result,
                  let envelope = Self.envelope(from: record),
                  envelope.pairingCode == pairingCode,
                  targetID == nil || envelope.senderID == targetID,
                  sessionID == nil || envelope.sessionID == sessionID else {
                continue
            }
            envelopes.append(envelope)
        }
        return envelopes
    }

    /// Called only after the receiver has applied the messages. This avoids
    /// losing pause/cancel if the process exits between CloudKit deletion and
    /// local handling. Privileged prompts are additionally deduplicated by
    /// the host's durable task ledger.
    public func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        let ids = Set(envelopes.map {
            CKRecord.ID(recordName: "WebRTCSignal-ComputerUse-\($0.id)")
        })
        // Mark only after the caller confirms it applied the envelope. A host
        // can therefore defer a privileged prompt that arrived just before
        // the WebRTC hello authorization without losing it in this process.
        consumedRecordIDs.formUnion(ids)
        pendingAcknowledgementIDs.formUnion(ids)
        try await flushPendingAcknowledgements()
    }

    private func flushPendingAcknowledgements() async throws {
        let ids = Array(pendingAcknowledgementIDs)
        for start in stride(from: 0, to: ids.count, by: 200) {
            let end = min(start + 200, ids.count)
            let batch = Array(ids[start ..< end])
            do {
                try await retryingCloudKit {
                    try await delete(recordIDs: batch)
                }
                pendingAcknowledgementIDs.subtract(batch)
                consumedRecordIDs.subtract(batch)
            } catch let cloudKit as CKError
                where Self.isIdempotentDeleteResult(cloudKit) {
                pendingAcknowledgementIDs.subtract(batch)
                consumedRecordIDs.subtract(batch)
                continue
            } catch let cloudKit as CKError where cloudKit.code == .partialFailure {
                guard let partials = cloudKit.userInfo[CKPartialErrorsByItemIDKey]
                    as? [CKRecord.ID: Error] else {
                    throw cloudKit
                }
                let retryIDs = Set(partials.compactMap { id, error in
                    (error as? CKError)?.code == .unknownItem ? nil : id
                })
                let completedIDs = Set(batch).subtracting(retryIDs)
                pendingAcknowledgementIDs.subtract(completedIDs)
                consumedRecordIDs.subtract(completedIDs)
                if !retryIDs.isEmpty { throw cloudKit }
            }
        }
    }

    /// Reuse the already-deployed signaling record shape. Computer Use values
    /// live inside the existing `payload` string, so Production CloudKit does
    /// not need a new record type or new query indexes.
    public nonisolated static let recordType = "WebRTCSignal"
    public nonisolated static let staleSeconds: TimeInterval = 60 * 60
    private nonisolated static let stableSaveAttemptLimit = 4

    private let containerIdentifier: String
    private let pairingCode: String
    private let sessionID: String?
    private let senderID: String
    private let targetID: String?
    private let startedAt: Date
    private var consumedRecordIDs: Set<CKRecord.ID> = []
    private var pendingAcknowledgementIDs: Set<CKRecord.ID> = []
    private var cachedContainer: CKContainer?
    private var cachedDatabase: CKDatabase?

    private var container: CKContainer {
        if let cachedContainer { return cachedContainer }
        let value = CKContainer(identifier: containerIdentifier)
        cachedContainer = value
        return value
    }

    private var database: CKDatabase {
        if let cachedDatabase { return cachedDatabase }
        let value = container.privateCloudDatabase
        cachedDatabase = value
        return value
    }

    /// Saves one stable message ID without allowing a retry to become invisible
    /// across a receiver restart. If the first response was lost, CloudKit
    /// returns the existing server record. Refresh that exact logical message's
    /// `createdAt` using the server change tag so a receiver whose bounded poll
    /// window starts later can observe it. A colliding ID with different
    /// contents is rejected rather than overwritten.
    private func saveStableRecord(
        _ originalRecord: CKRecord,
        matching envelope: ComputerUseEnvelope
    ) async throws {
        var candidate = originalRecord
        var lastError: Error?

        for _ in 0 ..< Self.stableSaveAttemptLimit {
            do {
                _ = try await retryingCloudKit {
                    try await database.save(candidate)
                }
                return
            } catch let cloudKit as CKError
                where cloudKit.code == .serverRecordChanged {
                guard let serverRecord = cloudKit.serverRecord else {
                    throw cloudKit
                }
                candidate = try Self.refreshedConflictRecord(
                    serverRecord,
                    matching: envelope,
                    refreshedAt: Date())
                lastError = cloudKit
            } catch let cloudKit as CKError
                where cloudKit.code == .unknownItem
                    && candidate.recordChangeTag != nil {
                // The receiver can acknowledge/delete the old record between
                // our conflict and merged save. Recreate the same message ID
                // with a fresh timestamp; receiver-side idempotency still
                // prevents duplicate task execution.
                candidate = try Self.record(for: envelope, createdAt: Date())
                lastError = cloudKit
            } catch {
                throw error
            }
        }

        throw lastError ?? SignalingError.transport(
            "The AI request could not be refreshed in iCloud.")
    }

    private func ensureAccountAvailable() async throws {
        try CloudKitEntitlements.validate(containerIdentifier: containerIdentifier)
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw Self.userFacingError(error, operation: "reach iCloud")
        }
        guard status == .available else {
            throw SignalingError.iCloudUnavailable(
                "Sign into iCloud on both devices so AI Computer Use can securely reach your Mac.")
        }
    }

    private func delete(recordIDs: [CKRecord.ID]) async throws {
        let operation = CKModifyRecordsOperation(
            recordsToSave: nil,
            recordIDsToDelete: recordIDs)
        operation.savePolicy = .allKeys
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }
    }

    private func retryingCloudKit<Value>(
        operation: () async throws -> Value
    ) async throws -> Value {
        let delays: [Duration] = [
            .milliseconds(400), .seconds(1), .seconds(2), .seconds(4),
        ]
        for delay in delays {
            do {
                return try await operation()
            } catch {
                guard Self.isTransientCloudKitError(error),
                      !Task.isCancelled else { throw error }
                try await Task.sleep(for: delay)
            }
        }
        return try await operation()
    }

    private nonisolated static func isTransientCloudKitError(_ error: Error) -> Bool {
        guard let cloudKit = error as? CKError else { return false }
        switch cloudKit.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isIdempotentDeleteResult(_ error: CKError) -> Bool {
        if error.code == .unknownItem { return true }
        guard error.code == .partialFailure,
              let partials = error.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error],
              !partials.isEmpty else { return false }
        return partials.values.allSatisfy {
            ($0 as? CKError)?.code == .unknownItem
        }
    }

    private struct StoredPayload: Codable {
        let messageID: String
        let sessionID: String
        let body: String
    }

    nonisolated static func record(
        for envelope: ComputerUseEnvelope,
        createdAt: Date? = nil
    ) throws -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: "WebRTCSignal-ComputerUse-\(envelope.id)"))
        record["senderID"] = envelope.senderID as CKRecordValue
        record["targetID"] = envelope.targetID as CKRecordValue
        record["pairingCode"] = envelope.pairingCode as CKRecordValue
        record["kind"] = "computerUse.\(envelope.kind.rawValue)" as CKRecordValue
        record["payload"] = try Self.storedPayload(for: envelope) as CKRecordValue
        record["createdAt"] = (createdAt ?? envelope.createdAt) as CKRecordValue
        return record
    }

    /// Pure conflict-merge policy kept internal so unit tests can prove that a
    /// pre-start request becomes newer than the receiver's start boundary while
    /// retaining one record ID and one exact logical payload.
    nonisolated static func refreshedConflictRecord(
        _ serverRecord: CKRecord,
        matching envelope: ComputerUseEnvelope,
        refreshedAt: Date
    ) throws -> CKRecord {
        guard let stored = Self.envelope(from: serverRecord),
              stored.id == envelope.id,
              stored.senderID == envelope.senderID,
              stored.targetID == envelope.targetID,
              stored.pairingCode == envelope.pairingCode,
              stored.sessionID == envelope.sessionID,
              stored.kind == envelope.kind,
              stored.body == envelope.body else {
            throw SignalingError.transport(
                "An existing AI request used the same identifier with different contents. Start a new session and try again.")
        }

        let currentCreatedAt = serverRecord["createdAt"] as? Date ?? .distantPast
        serverRecord["createdAt"] = max(currentCreatedAt, refreshedAt) as CKRecordValue
        return serverRecord
    }

    private nonisolated static func storedPayload(for envelope: ComputerUseEnvelope) throws -> String {
        let data = try JSONEncoder().encode(StoredPayload(
            messageID: envelope.id,
            sessionID: envelope.sessionID,
            body: envelope.body))
        guard let value = String(data: data, encoding: .utf8) else {
            throw SignalingError.transport("The AI request could not be encoded.")
        }
        return value
    }

    private nonisolated static func envelope(from record: CKRecord) -> ComputerUseEnvelope? {
        guard let senderID = record["senderID"] as? String,
              let targetID = record["targetID"] as? String,
              let pairingCode = record["pairingCode"] as? String,
              let kindRaw = record["kind"] as? String,
              kindRaw.hasPrefix("computerUse."),
              let kind = ComputerUseEnvelope.Kind(
                rawValue: String(kindRaw.dropFirst("computerUse.".count))),
              let payloadString = record["payload"] as? String,
              let payloadData = payloadString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(StoredPayload.self, from: payloadData) else {
            return nil
        }
        return ComputerUseEnvelope(
            id: payload.messageID,
            senderID: senderID,
            targetID: targetID,
            pairingCode: pairingCode,
            sessionID: payload.sessionID,
            kind: kind,
            body: payload.body,
            createdAt: (record["createdAt"] as? Date) ?? record.creationDate ?? Date())
    }

    private nonisolated static func userFacingError(_ error: Error, operation: String) -> Error {
        if let signaling = error as? SignalingError { return signaling }
        if let cloudKit = error as? CKError, cloudKit.code == .notAuthenticated {
            return SignalingError.iCloudUnavailable(
                "Sign into iCloud on both devices so AI Computer Use can securely reach your Mac.")
        }
        return SignalingError.transport(
            "Couldn't \(operation) through iCloud: \(error.localizedDescription)")
    }
}
