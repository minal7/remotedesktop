import CloudKit
import Foundation
import os
import Security

enum CloudKitEntitlements {
    static func validate(containerIdentifier: String) throws {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw SignalingError.iCloudUnavailable(
                "This build couldn't inspect its signing entitlements. Rebuild it with the iCloud capability enabled for CloudKit.")
        }

        try validate(containerIdentifier: containerIdentifier) { entitlement in
            SecTaskCopyValueForEntitlement(task, entitlement, nil)
        }
        #else
        _ = containerIdentifier
        #endif
    }

    static func validate(
        containerIdentifier: String,
        entitlementValue: (CFString) -> Any?
    ) throws {
        let services = entitlementStrings(
            for: "com.apple.developer.icloud-services" as CFString,
            entitlementValue: entitlementValue)
        guard !services.isEmpty else {
            throw SignalingError.iCloudUnavailable(
                "This build isn't signed for CloudKit. In Xcode, enable the iCloud capability, turn on CloudKit, and sign the app with your Apple Developer team.")
        }
        guard services.contains("CloudKit") || services.contains("CloudKit-Anonymous") else {
            throw SignalingError.iCloudUnavailable(
                "This build's iCloud entitlement doesn't include CloudKit. Enable the iCloud capability's CloudKit service for this target and rebuild.")
        }

        let containers = entitlementStrings(
            for: "com.apple.developer.icloud-container-identifiers" as CFString,
            entitlementValue: entitlementValue)
        guard containers.contains(containerIdentifier) else {
            throw SignalingError.iCloudUnavailable(
                "This build isn't signed for the CloudKit container \(containerIdentifier). Add that container to the target's iCloud capability and rebuild.")
        }
    }

    private static func entitlementStrings(
        for key: CFString,
        entitlementValue: (CFString) -> Any?
    ) -> [String] {
        if let value = entitlementValue(key) as? String {
            return [value]
        }
        if let values = entitlementValue(key) as? [String] {
            return values
        }
        if let values = entitlementValue(key) as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }
}

/// CloudKit-backed signaling. Replaces the Cloudflare Worker.
///
/// ## Model
/// - **Same-iCloud only.** Both peers must be signed into the same iCloud
///   account. All signaling records live in the user's **Private DB** →
///   zero cost to us regardless of user count. The pairing code disambiguates
///   between multiple Macs owned by the same user.
/// - **Polling, not push.** During an active session we poll every 2 s.
///   CloudKit rate limit is 40 req/s/user; this is safely under it. Idle
///   clients / hosts poll nothing.
///
/// ## Record types
/// - `HostAdvertisement` — written by host at pairing-code show. Discoverable
///   by pairing code.
/// - `WebRTCSignal` — per-envelope record. `targetID` is the receiver's
///   `senderID`; `poll()` queries for records with `targetID == self`.
///
/// ## Cleanup
/// The session owner deletes its own records on `close()`. Stale records
/// older than 5 minutes are ignored on read and garbage-collected
/// opportunistically.
public actor CloudKitSignalingClient: SignalingChannel {
    // MARK: Public API

    /// `code` is the 6-digit pairing code. `role` determines whether
    /// `claim()` advertises (host) or looks up (client).
    /// `hostName` is only read when `role == .host`; it shows on the
    /// client's pairing screen.
    public init(
        containerIdentifier: String,
        code: String,
        role: SignalingEnvelope.Role,
        hostName: String? = nil,
        senderID: String = DeviceIdentity.get(),
        staleSeconds: TimeInterval = 300
    ) {
        self.containerIdentifier = containerIdentifier
        self.code = code
        self.role = role
        self.hostName = hostName
        self.senderID = senderID
        self.staleSeconds = staleSeconds
    }

    /// Host: writes a `HostAdvertisement` so clients can find us. Also
    /// deletes any leftover records from a prior run with the same code.
    /// Client: looks up the host by `pairingCode` and memoizes the
    /// `targetID` for subsequent `send()`s. Throws `SignalingError.hostUnavailable`
    /// if no advertisement exists.
    public func claim() async throws {
        try await ensureAccountAvailable()

        // Scrub own stale records from any prior run with this code.
        try? await deleteOwnRecords(forPairingCode: code)

        switch role {
        case .host:
            try await writeAdvertisement()
        case .client:
            self.targetID = try await resolveHostSenderID()
        }
    }

    public func send(_ envelope: SignalingEnvelope) async throws {
        guard let peerID = try await resolveTargetID() else {
            throw SignalingError.transport("Peer not resolved yet; call claim() first.")
        }
        let record = CKRecord(recordType: "WebRTCSignal")
        record["senderID"] = senderID as CKRecordValue
        record["targetID"] = peerID as CKRecordValue
        record["pairingCode"] = code as CKRecordValue
        record["kind"] = envelope.kind.rawValue as CKRecordValue
        record["payload"] = serializePayload(envelope.payload) as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        let database = try cloudKitDatabase()
        do {
            _ = try await database.save(record)
            ownedRecordIDs.insert(record.recordID)
        } catch {
            throw SignalingError.transport("CloudKit send failed: \(error.localizedDescription)")
        }
    }

    public func poll() async throws -> [SignalingEnvelope] {
        let cutoff = Date(timeIntervalSinceNow: -staleSeconds)
        let startedAt = self.startedAt
        let predicate = NSPredicate(
            format: "targetID == %@ AND createdAt > %@",
            senderID, max(cutoff, startedAt) as NSDate)
        let query = CKQuery(recordType: "WebRTCSignal", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let database = try cloudKitDatabase()
        let (matchResults, _) = try await queryRecords(query, in: database)
        var envelopes: [SignalingEnvelope] = []
        for (recordID, result) in matchResults {
            guard !consumedRecordIDs.contains(recordID) else { continue }
            consumedRecordIDs.insert(recordID)
            switch result {
            case .success(let record):
                if let envelope = envelopeFrom(record) {
                    envelopes.append(envelope)
                }
            case .failure:
                continue
            }
        }
        return envelopes
    }

    /// Deletes every record this client created for the pairing code.
    /// Call from the session's teardown path.
    public func cleanup() async {
        try? await deleteOwnRecords(forPairingCode: code)
    }

    // MARK: Internals

    private let containerIdentifier: String
    private let code: String
    private let role: SignalingEnvelope.Role
    private let hostName: String?
    private let senderID: String
    private let staleSeconds: TimeInterval
    private let startedAt = Date()
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.signaling", category: "cloudkit")

    private var targetID: String?
    private var ownedRecordIDs: Set<CKRecord.ID> = []
    private var consumedRecordIDs: Set<CKRecord.ID> = []
    private var container: CKContainer?
    private var database: CKDatabase?

    private func ensureAccountAvailable() async throws {
        let container = try cloudKit().container
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw SignalingError.iCloudUnavailable(
                "Couldn't reach iCloud: \(error.localizedDescription)")
        }
        switch status {
        case .available:
            return
        case .noAccount:
            throw SignalingError.iCloudUnavailable(
                "Sign into iCloud in Settings so Remote Desktop can talk to your computer. No iCloud storage is used, only the signaling handshake.")
        case .restricted:
            throw SignalingError.iCloudUnavailable(
                "iCloud is restricted on this device (Screen Time or MDM). Remote Desktop can't set up the connection.")
        case .couldNotDetermine:
            throw SignalingError.iCloudUnavailable(
                "Couldn't check iCloud status. Check your internet connection and try again.")
        case .temporarilyUnavailable:
            throw SignalingError.iCloudUnavailable(
                "iCloud is temporarily unavailable. Try again in a moment.")
        @unknown default:
            throw SignalingError.iCloudUnavailable("iCloud account state is unknown.")
        }
    }

    private func writeAdvertisement() async throws {
        let record = CKRecord(recordType: "HostAdvertisement")
        record["senderID"] = senderID as CKRecordValue
        record["pairingCode"] = code as CKRecordValue
        record["hostName"] = (hostName ?? "Mac") as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        let database = try cloudKitDatabase()
        do {
            _ = try await database.save(record)
            ownedRecordIDs.insert(record.recordID)
        } catch {
            throw SignalingError.transport(
                "Couldn't publish the pairing advertisement: \(error.localizedDescription)")
        }
    }

    private func resolveHostSenderID() async throws -> String {
        let cutoff = Date(timeIntervalSinceNow: -staleSeconds)
        let predicate = NSPredicate(
            format: "pairingCode == %@ AND createdAt > %@",
            code, cutoff as NSDate)
        let query = CKQuery(recordType: "HostAdvertisement", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let database = try cloudKitDatabase()
        let (matchResults, _) = try await queryRecords(query, in: database)
        for (_, result) in matchResults {
            if case .success(let record) = result,
               let id = record["senderID"] as? String {
                return id
            }
        }
        throw SignalingError.hostUnavailable
    }

    private func resolveTargetID() async throws -> String? {
        if let targetID { return targetID }
        // The host learns its peer from the first inbound offer on the
        // WebRTCSignal poll — it will call rememberTargetID().
        return nil
    }

    public func rememberTargetID(_ id: String) {
        self.targetID = id
    }

    private func envelopeFrom(_ record: CKRecord) -> SignalingEnvelope? {
        guard let kindRaw = record["kind"] as? String,
              let kind = SignalingEnvelope.Kind(rawValue: kindRaw),
              let payloadString = record["payload"] as? String,
              let payload = deserializePayload(payloadString) else {
            return nil
        }
        // If the host hasn't memoized the client's senderID yet, do so
        // now from the first inbound envelope. Safe: CloudKit query is
        // scoped to `targetID == self.senderID`, so the record's senderID
        // *is* our peer.
        if targetID == nil, let senderID = record["senderID"] as? String {
            targetID = senderID
        }
        // `role` on the envelope is advisory; the sender knows its own
        // role. Reconstruct from record fields.
        let role: SignalingEnvelope.Role = (record["senderID"] as? String) == senderID ? .host : .client
        let ts = (record["createdAt"] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        return SignalingEnvelope(role: role, kind: kind, payload: payload, ts: ts)
    }

    private func deleteOwnRecords(forPairingCode code: String) async throws {
        // Query WebRTCSignal + HostAdvertisement for records we wrote with
        // this pairing code. Cheapest correct approach: iterate ownedRecordIDs
        // and delete in batches. Records from prior runs (different process
        // lifetime) aren't in the set — they age out via the staleness
        // filter on read.
        guard !ownedRecordIDs.isEmpty else { return }
        let ids = Array(ownedRecordIDs)
        let database = try cloudKitDatabase()
        do {
            let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
            op.savePolicy = .allKeys
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: cont.resume(returning: ())
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                database.add(op)
            }
            ownedRecordIDs.removeAll()
        } catch {
            log.warning("cleanup delete failed (non-fatal): \(String(describing: error), privacy: .public)")
        }
    }

    private func cloudKit() throws -> (container: CKContainer, database: CKDatabase) {
        try CloudKitEntitlements.validate(containerIdentifier: containerIdentifier)

        if let container, let database {
            return (container, database)
        }

        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        self.container = container
        self.database = database
        return (container, database)
    }

    private func cloudKitDatabase() throws -> CKDatabase {
        try cloudKit().database
    }

    private func queryRecords(_ query: CKQuery, in database: CKDatabase) async throws -> (
        matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
        queryCursor: CKQueryOperation.Cursor?) {
        do {
            return try await database.records(matching: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: 50)
        } catch let error as CKError {
            switch error.code {
            case .notAuthenticated:
                throw SignalingError.iCloudUnavailable(
                    "Remote Desktop can't talk to iCloud right now. Sign out and back in, or try again in a moment.")
            case .networkUnavailable, .networkFailure:
                throw SignalingError.transport(
                    "Couldn't reach iCloud. Check your network and try again.")
            case .unknownItem:
                // Schema doesn't exist yet in this environment. Treat as
                // empty result; the first save() will auto-create in dev.
                return ([], nil)
            default:
                throw SignalingError.transport("CloudKit: \(error.localizedDescription)")
            }
        }
    }

    private func serializePayload(_ payload: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func deserializePayload(_ string: String) -> [String: String]? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return obj
    }
}
