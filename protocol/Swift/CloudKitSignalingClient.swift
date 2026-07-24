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
        #if targetEnvironment(simulator)
        // CKContainer intentionally traps (rather than throwing) when a
        // simulator app was installed with CODE_SIGNING_ALLOWED=NO. Keep local
        // Bonjour discovery usable in diagnostics and surface a normal error
        // for CloudKit-backed actions instead of crashing at app launch.
        let codeResources = Bundle.main.bundleURL
            .appendingPathComponent("_CodeSignature/CodeResources")
        guard FileManager.default.fileExists(atPath: codeResources.path) else {
            throw SignalingError.iCloudUnavailable(
                "This Simulator copy can’t use iCloud because it was installed without code signing. In Xcode, select your Development Team and use Run to reinstall it.")
        }
        #endif
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

public struct CloudKitHostAdvertisement: Identifiable, Equatable, Sendable {
    public let senderID: String
    public let hostName: String
    public let pairingCode: String
    public let updatedAt: Date
    public let computerUseCapability: ComputerUseCapability

    public var id: String { senderID }

    public init(
        senderID: String,
        hostName: String,
        pairingCode: String,
        updatedAt: Date,
        computerUseCapability: ComputerUseCapability = .unavailable
    ) {
        self.senderID = senderID
        self.hostName = hostName
        self.pairingCode = pairingCode
        self.updatedAt = updatedAt
        self.computerUseCapability = computerUseCapability
    }
}

/// CloudKit-backed signaling. Replaces the Cloudflare Worker.
///
/// ## Model
/// - **Same-iCloud only.** Both peers must be signed into the same iCloud
///   account. All signaling records live in the user's **Private DB** →
///   zero cost to us regardless of user count. An internal session binding
///   disambiguates multiple Macs owned by the same user; no person enters it.
/// - **Polling, not push.** During an active session we poll every 2 s.
///   CloudKit rate limit is 40 req/s/user; this is safely under it. Idle
///   clients / hosts poll nothing.
///
/// ## Record types
/// - `HostAdvertisement` — written while the host is ready. Discoverable by
///   the private internal session binding and stable host identity.
/// - `WebRTCSignal` — per-envelope record. `targetID` is the receiver's
///   `senderID`; `poll()` queries for records with `targetID == self`.
///
/// ## Cleanup
/// The session owner deletes its own records on `close()`. Stale records
/// older than 5 minutes are ignored on read and garbage-collected
/// opportunistically. Hosts refresh their advertisement while listening
/// so a long-running host does not age out before the client connects.
public actor CloudKitSignalingClient: SignalingChannel {
    // MARK: Public API

    public static let defaultStaleSeconds: TimeInterval = 300
    nonisolated static let maximumQueryRecords = 500
    nonisolated static let maximumQueryPages = 10
    nonisolated static let maximumTrackedOwnedRecords = 256
    nonisolated static let maximumConsumedRecords = 512

    public nonisolated static func advertisementRefreshInterval(
        staleSeconds: TimeInterval = defaultStaleSeconds
    ) -> TimeInterval {
        max(1, min(120, staleSeconds * 0.5))
    }

    public nonisolated static func advertisementRecordName(senderID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let suffix = String(senderID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return "HostAdvertisement-\(suffix)"
    }

    /// Capability metadata is also carried after a newline in the existing
    /// `hostName` field. Production containers that predate the optional AI
    /// columns can therefore advertise setup/readiness without a schema
    /// deployment; older clients render only the first line as the host name.
    nonisolated static func encodedHostName(
        _ hostName: String,
        capability: ComputerUseCapability
    ) -> String {
        let displayName = hostName
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (displayName?.isEmpty == false ? displayName! : "Mac")
        // Keep the backwards-compatible metadata comfortably below the size
        // expected of a display-name field even when an underlying error is
        // unusually verbose.
        let boundedDetail = String(capability.detail.prefix(512))
        let detail = Data(boundedDetail.utf8).base64EncodedString()
        return "\(safeName)\(computerUseHostNameMarker)\(capability.state.rawValue):\(detail)"
    }

    nonisolated static func decodedHostName(
        _ value: String
    ) -> (name: String, capability: ComputerUseCapability?) {
        guard let markerRange = value.range(of: computerUseHostNameMarker) else {
            return (value, nil)
        }
        let name = String(value[..<markerRange.lowerBound])
        let metadata = value[markerRange.upperBound...]
        guard let separator = metadata.firstIndex(of: ":"),
              let state = ComputerUseCapability.State(
                rawValue: String(metadata[..<separator])),
              let detailData = Data(
                base64Encoded: String(metadata[metadata.index(after: separator)...])),
              let detail = String(data: detailData, encoding: .utf8) else {
            return (name, nil)
        }
        return (name, ComputerUseCapability(state: state, detail: detail))
    }

    private nonisolated static let computerUseHostNameMarker =
        "\n#RemoteDesktopComputerUse:v1:"

    public nonisolated static func fetchAvailableHostAdvertisements(
        containerIdentifier: String,
        staleSeconds: TimeInterval = defaultStaleSeconds
    ) async throws -> [CloudKitHostAdvertisement] {
        try CloudKitEntitlements.validate(containerIdentifier: containerIdentifier)

        let container = CKContainer(identifier: containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {
                return []
            }
        } catch let error as CKError where error.code == .notAuthenticated {
            return []
        }

        let cutoff = Date(timeIntervalSinceNow: -staleSeconds)
        let predicate = NSPredicate(format: "createdAt > %@", cutoff as NSDate)
        let query = CKQuery(recordType: "HostAdvertisement", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let database = container.privateCloudDatabase
        let records: [CKRecord]
        do {
            records = try completeQueryRecords(
                try await boundedQueryRecords(
                    query,
                    in: database,
                    desiredKeys: [
                        "senderID", "pairingCode", "hostName", "createdAt",
                        "computerUseState", "computerUseDetail",
                    ]))
        } catch {
            guard Self.isAdvertisementSchemaCompatibilityError(error) else {
                throw error
            }
            // Production containers created by an older release do not know
            // the optional AI columns. Capability is still encoded in the
            // existing hostName field, so retry with the deployed key set.
            do {
                records = try completeQueryRecords(
                    try await boundedQueryRecords(
                        query,
                        in: database,
                        desiredKeys: [
                            "senderID", "pairingCode", "hostName", "createdAt",
                        ]))
            } catch let cloudKit as CKError where cloudKit.code == .unknownItem {
                return []
            }
        }

        var newestBySenderID: [String: CloudKitHostAdvertisement] = [:]
        for record in records {
            guard let advertisement = Self.hostAdvertisement(from: record) else {
                continue
            }

            if let existing = newestBySenderID[advertisement.senderID],
               existing.updatedAt >= advertisement.updatedAt {
                continue
            }
            newestBySenderID[advertisement.senderID] = advertisement
        }

        return newestBySenderID.values.sorted { lhs, rhs in
            let nameOrder = lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName)
            if nameOrder == .orderedSame {
                if lhs.pairingCode != rhs.pairingCode {
                    return lhs.pairingCode < rhs.pairingCode
                }
                return lhs.senderID < rhs.senderID
            }
            return nameOrder == .orderedAscending
        }
    }

    /// `code` is the legacy six-digit internal routing binding; it is never
    /// shown for manual entry. `role` determines whether
    /// `claim()` advertises (host) or looks up (client).
    /// `hostName` is only read when `role == .host`; it shows on the
    /// client's pairing screen.
    public init(
        containerIdentifier: String,
        code: String,
        role: SignalingEnvelope.Role,
        hostName: String? = nil,
        computerUseCapability: ComputerUseCapability = .unavailable,
        expectedTargetID: String? = nil,
        senderID: String = DeviceIdentity.get(),
        staleSeconds: TimeInterval = defaultStaleSeconds
    ) {
        self.containerIdentifier = containerIdentifier
        self.code = code
        self.role = role
        self.hostName = hostName
        self.computerUseCapability = computerUseCapability
        self.expectedTargetID = expectedTargetID
        self.senderID = senderID
        self.staleSeconds = staleSeconds
        consumedRecordRetention = BoundedCloudKitReplayRetention(
            validityWindow: staleSeconds,
            maximumEntries: Self.maximumConsumedRecords,
            clock: { Date() })
    }

    /// Host: writes a `HostAdvertisement` so clients can find us. Also
    /// deletes any leftover records from a prior run with the same code.
    /// Client: looks up the host by `pairingCode` and memoizes the
    /// `targetID` for subsequent `send()`s. Throws `SignalingError.hostUnavailable`
    /// if no advertisement exists.
    public func claim() async throws {
        try requireStableDeviceIdentity()
        try await ensureAccountAvailable()
        try await prepareOwnedRecordLifecycle()

        // Scrub durably tracked records from a prior process run before this
        // session creates new signaling state.
        try? await deleteOwnRecords(forPairingCode: code)

        switch role {
        case .host:
            try await writeAdvertisement()
        case .client:
            self.targetID = try await resolveHostSenderID()
        }
    }

    public func send(_ envelope: SignalingEnvelope) async throws {
        try requireStableDeviceIdentity()
        guard let peerID = try await resolveTargetID() else {
            throw SignalingError.transport("Peer not resolved yet; call claim() first.")
        }
        try await prepareOwnedRecordLifecycle()
        let record = CKRecord(
            recordType: "WebRTCSignal",
            recordID: CKRecord.ID(
                recordName: "WebRTCSignal-Signaling-\(UUID().uuidString)"))
        record["senderID"] = senderID as CKRecordValue
        record["targetID"] = peerID as CKRecordValue
        record["pairingCode"] = code as CKRecordValue
        record["kind"] = envelope.kind.rawValue as CKRecordValue
        record["payload"] = serializePayload(envelope.payload) as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        try await reserveOwnedRecord(
            record.recordID,
            createdAt: record["createdAt"] as? Date ?? Date(),
            refreshesDeadline: false)
        let database = try cloudKitDatabase()
        do {
            _ = try await retryingCloudKit("send signaling envelope") {
                try await revalidateOwnedRecordAccountBinding(
                    operation: "send signaling envelope")
                return try await database.save(record)
            }
        } catch {
            throw SignalingError.transport("CloudKit send failed: \(error.localizedDescription)")
        }
    }

    public func poll() async throws -> [SignalingEnvelope] {
        try requireStableDeviceIdentity()
        let cutoff = Date(timeIntervalSinceNow: -staleSeconds)
        let startedAt = self.startedAt
        let predicate = NSPredicate(
            format: "targetID == %@ AND createdAt > %@",
            senderID, max(cutoff, startedAt) as NSDate)
        let query = CKQuery(recordType: "WebRTCSignal", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let database = try cloudKitDatabase()
        let (matchResults, _) = try await queryRecords(query, in: database)
        do {
            // Reject the complete page set before replay retention changes if
            // CloudKit could not materialize even one observed record.
            return try consumePollQueryResults(matchResults)
        } catch BoundedCloudKitRecordError.retentionUnavailable {
            throw SignalingError.transport(
                "Too many signaling messages are waiting for bounded replay cleanup. Keep both apps open and try again shortly.")
        } catch {
            throw SignalingError.transport(
                "iCloud returned an incomplete signaling batch. Keep both apps open and try again.")
        }
    }

    /// Host-only keepalive for the `HostAdvertisement` record. Clients
    /// only consider advertisements with a fresh `createdAt`, so a host
    /// that is left running must keep that field current until pairing.
    public func refreshAdvertisement() async throws {
        guard role == .host else { return }
        try requireStableDeviceIdentity()
        guard let advertisementRecord else {
            try await writeAdvertisement()
            return
        }

        updateAdvertisementFields(on: advertisementRecord)
        try await reserveOwnedRecord(
            advertisementRecord.recordID,
            createdAt: advertisementRecord["createdAt"] as? Date ?? Date(),
            refreshesDeadline: true)

        let database = try cloudKitDatabase()
        do {
            let saved = try await saveAdvertisement(
                advertisementRecord,
                in: database,
                operation: "refresh pairing advertisement")
            self.advertisementRecord = saved
        } catch let refreshError {
            let staleRecord = self.advertisementRecord
            self.advertisementRecord = nil
            do {
                try await writeAdvertisement()
            } catch let recreateError {
                self.advertisementRecord = staleRecord
                throw SignalingError.transport(
                    "Couldn't refresh the pairing advertisement: \(refreshError.localizedDescription); recreate failed: \(recreateError.localizedDescription)")
            }
        }
    }

    /// Updates the capability included in the next advertisement refresh.
    /// HostSession calls this when model readiness changes.
    public func setComputerUseCapability(_ capability: ComputerUseCapability) {
        computerUseCapability = capability
    }

    /// Removes only the live `HostAdvertisement` record while keeping the
    /// signaling records needed by an active peer session.
    public func stopAdvertising() async {
        guard role == .host else { return }
        guard !senderID.isEmpty else { return }

        let recordID = advertisementRecord?.recordID
            ?? Self.advertisementRecordID(senderID: senderID)
        do {
            try await deleteRecordIDs([recordID])
            advertisementRecord = nil
        } catch {
            log.warning("advertisement delete failed (non-fatal): \(String(describing: error), privacy: .public)")
        }
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
    private var computerUseCapability: ComputerUseCapability
    private let expectedTargetID: String?
    private let senderID: String
    private let staleSeconds: TimeInterval
    private let startedAt = Date()
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.signaling", category: "cloudkit")

    private var targetID: String?
    private var consumedRecordRetention: BoundedCloudKitReplayRetention
    private let ownedRecordStore: any BoundedCloudKitOwnedRecordStore =
        UserDefaultsBoundedCloudKitOwnedRecordStore()
    private var ownedRecordLifecycle: BoundedCloudKitOwnedRecordLifecycle?
    private var ownedRecordAccountBinding: CloudKitAccountBinding?
    private var advertisementRecord: CKRecord?
    private var container: CKContainer?
    private var database: CKDatabase?

    private nonisolated static func advertisementRecordID(senderID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: advertisementRecordName(senderID: senderID))
    }

    nonisolated static func hostAdvertisement(from record: CKRecord) -> CloudKitHostAdvertisement? {
        guard let senderID = record["senderID"] as? String,
              senderID.isEmpty == false,
              let storedHostName = record["hostName"] as? String,
              storedHostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let pairingCode = record["pairingCode"] as? String,
              pairingCode.count == 6,
              pairingCode.allSatisfy(\.isNumber) else {
            return nil
        }

        let updatedAt = (record["createdAt"] as? Date)
            ?? record.modificationDate
            ?? record.creationDate
            ?? .distantPast
        let decoded = decodedHostName(storedHostName)
        let explicitState = ComputerUseCapability.State(
            rawValue: record["computerUseState"] as? String ?? "")
        let capability = explicitState.map {
            ComputerUseCapability(
                state: $0,
                detail: record["computerUseDetail"] as? String
                    ?? decoded.capability?.detail
                    ?? ComputerUseCapability.unavailable.detail)
        } ?? decoded.capability ?? .unavailable
        return CloudKitHostAdvertisement(
            senderID: senderID,
            hostName: decoded.name,
            pairingCode: pairingCode,
            updatedAt: updatedAt,
            computerUseCapability: capability)
    }

    private func ensureAccountAvailable() async throws {
        let container = try cloudKit().container
        let status: CKAccountStatus
        do {
            status = try await retryingCloudKit("check iCloud account") {
                try await container.accountStatus()
            }
        } catch {
            throw SignalingError.iCloudUnavailable(
                "Couldn't reach iCloud: \(error.localizedDescription)")
        }
        switch status {
        case .available:
            return
        case .noAccount:
            throw SignalingError.iCloudUnavailable(
                "Sign into iCloud on this device using the same Apple Account as your Mac, then try again. Remote Desktop only uses your private CloudKit database for the connection handshake.")
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

    private func requireStableDeviceIdentity() throws {
        guard !senderID.isEmpty else {
            throw SignalingError.transport(
                "This device could not securely save its connection identity. Restart the app and try again.")
        }
    }

    private func writeAdvertisement() async throws {
        let database = try cloudKitDatabase()
        let recordID = Self.advertisementRecordID(senderID: senderID)
        let record: CKRecord

        do {
            record = try await retryingCloudKit("load pairing advertisement") {
                try await database.record(for: recordID)
            }
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "HostAdvertisement", recordID: recordID)
        } catch {
            throw SignalingError.transport(
                "Couldn't load the pairing advertisement: \(error.localizedDescription)")
        }

        updateAdvertisementFields(on: record)
        try await reserveOwnedRecord(
            record.recordID,
            createdAt: record["createdAt"] as? Date ?? Date(),
            refreshesDeadline: true)
        do {
            let saved = try await saveAdvertisement(
                record,
                in: database,
                operation: "publish pairing advertisement")
            advertisementRecord = saved
        } catch {
            throw SignalingError.transport(
                "Couldn't publish the pairing advertisement: \(error.localizedDescription)")
        }
    }

    private func updateAdvertisementFields(on record: CKRecord) {
        Self.updateAdvertisementFields(
            on: record,
            senderID: senderID,
            pairingCode: code,
            hostName: hostName ?? "Mac",
            computerUseCapability: computerUseCapability)
    }

    /// Keep writes constrained to the fields deployed in the Production
    /// CloudKit schema. Capability metadata lives in `hostName` so hosts can
    /// advertise AI readiness without requiring a schema deployment.
    nonisolated static func updateAdvertisementFields(
        on record: CKRecord,
        senderID: String,
        pairingCode: String,
        hostName: String,
        computerUseCapability: ComputerUseCapability,
        createdAt: Date = Date()
    ) {
        record["senderID"] = senderID as CKRecordValue
        record["pairingCode"] = pairingCode as CKRecordValue
        record["hostName"] = Self.encodedHostName(
            hostName,
            capability: computerUseCapability) as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
    }

    private func saveAdvertisement(
        _ record: CKRecord,
        in database: CKDatabase,
        operation: String
    ) async throws -> CKRecord {
        try await retryingCloudKit(operation) {
            try await revalidateOwnedRecordAccountBinding(
                operation: operation)
            return try await database.save(record)
        }
    }

    nonisolated static func isAdvertisementSchemaCompatibilityError(_ error: Error) -> Bool {
        guard let cloudKit = error as? CKError else { return false }
        if cloudKit.code == .serverRejectedRequest
            || cloudKit.code == .invalidArguments
            || cloudKit.code == .unknownItem {
            return true
        }
        if cloudKit.code == .partialFailure,
           let partials = cloudKit.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error],
           !partials.isEmpty {
            return partials.values.allSatisfy(isAdvertisementSchemaCompatibilityError)
        }
        return false
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
        let records: [CKRecord]
        do {
            records = try Self.completeQueryRecords(matchResults)
        } catch {
            throw SignalingError.transport(
                "iCloud returned an incomplete host lookup. Keep both apps open and try again.")
        }
        if let id = Self.selectedHostSenderID(
            from: records,
            expectedTargetID: expectedTargetID) {
            return id
        }
        throw SignalingError.hostUnavailable
    }

    /// Selects only the Mac the user actually tapped when discovery supplied
    /// a stable CloudKit identity. Pairing codes are short and can collide;
    /// pinning the sender prevents a same-account advertisement from silently
    /// redirecting the session to a different Mac.
    nonisolated static func selectedHostSenderID(
        from records: [CKRecord],
        expectedTargetID: String?
    ) -> String? {
        let senderIDs = Set(records.compactMap { record -> String? in
            guard let senderID = record["senderID"] as? String,
                  !senderID.isEmpty else { return nil }
            return senderID
        })
        if let expectedTargetID {
            return senderIDs.contains(expectedTargetID)
                ? expectedTargetID
                : nil
        }
        guard senderIDs.count == 1 else { return nil }
        return senderIDs.first
    }

    /// A CloudKit query is one logical observation. Returning its successful
    /// subset would let an arbitrary failed record change offer selection or
    /// host discovery, so any per-record failure rejects the whole batch.
    nonisolated static func completeQueryRecords(
        _ matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) throws -> [CKRecord] {
        try matchResults.map { _, result in
            try result.get()
        }
    }

    /// CloudKit guarantees the requested sort descriptor but does not define
    /// tie ordering. Record names are unique within the queried zone; sender
    /// and wire fields retain a total fallback for synthetic/test records.
    nonisolated static func deterministicallyOrderedSignalingRecords(
        _ records: [CKRecord]
    ) -> [CKRecord] {
        records.sorted { lhs, rhs in
            let lhsTime = deterministicCreatedAt(lhs)
            let rhsTime = deterministicCreatedAt(rhs)
            if lhsTime != rhsTime { return lhsTime < rhsTime }

            let lhsName = lhs.recordID.recordName
            let rhsName = rhs.recordID.recordName
            if lhsName != rhsName { return lhsName < rhsName }

            let lhsSender = lhs["senderID"] as? String ?? ""
            let rhsSender = rhs["senderID"] as? String ?? ""
            if lhsSender != rhsSender { return lhsSender < rhsSender }

            let lhsKind = lhs["kind"] as? String ?? ""
            let rhsKind = rhs["kind"] as? String ?? ""
            if lhsKind != rhsKind { return lhsKind < rhsKind }

            let lhsPayload = lhs["payload"] as? String ?? ""
            let rhsPayload = rhs["payload"] as? String ?? ""
            return lhsPayload < rhsPayload
        }
    }

    private nonisolated static func deterministicCreatedAt(
        _ record: CKRecord
    ) -> TimeInterval {
        let value = (record["createdAt"] as? Date)?
            .timeIntervalSinceReferenceDate ?? -.greatestFiniteMagnitude
        return value.isFinite ? value : -.greatestFiniteMagnitude
    }

    private func resolveTargetID() async throws -> String? {
        if let targetID { return targetID }
        // The host learns its peer from the first inbound offer on the
        // WebRTCSignal poll and binds it with acceptOfferSenderID(_:).
        return nil
    }

    /// Atomically binds a host to the first offer sender it accepts. Repeated
    /// offers from that sender are allowed; a second sender can never replace
    /// the active peer, including when several records arrived in one poll.
    public func acceptOfferSenderID(_ id: String) -> Bool {
        guard role == .host, !id.isEmpty else { return false }
        if let targetID { return targetID == id }
        targetID = id
        return true
    }

    /// The host uses this identity to bind privileged Computer Use messages
    /// to the iOS peer that completed the active WebRTC pairing.
    public func resolvedPeerSenderID() -> String? {
        targetID
    }

    /// Rejects an incomplete CloudKit batch before applying any replay or peer
    /// selection state. Internal for focused regression tests.
    func consumePollQueryResults(
        _ matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) throws -> [SignalingEnvelope] {
        try consumePollRecords(Self.completeQueryRecords(matchResults))
    }

    /// Applies peer selection after imposing a total order independent of
    /// CloudKit page/array order.
    /// This is internal so both host and iOS regression suites can exercise
    /// the real record decoder without issuing a CloudKit query.
    func consumePollRecords(
        _ records: [CKRecord]
    ) throws -> [SignalingEnvelope] {
        var nextRetention = consumedRecordRetention
        let pending = Self.deterministicallyOrderedSignalingRecords(
            records.filter {
                !nextRetention.contains(recordName: $0.recordID.recordName)
            })
        let decoded = pending.map { record in
            (record: record, envelope: envelopeFrom(record))
        }

        let selectedSenderID: String?
        let selectedOfferIndex: Int?
        if let targetID {
            selectedSenderID = targetID
            selectedOfferIndex = nil
        } else if role == .host {
            selectedOfferIndex = decoded.firstIndex(where: {
                $0.envelope?.kind == .offer
            })
            selectedSenderID = selectedOfferIndex.flatMap {
                decoded[$0].envelope?.senderID
            }
        } else {
            selectedSenderID = nil
            selectedOfferIndex = nil
        }

        var envelopes: [SignalingEnvelope] = []
        for (index, item) in decoded.enumerated() {
            guard let envelope = item.envelope else {
                // Structurally invalid records can never become valid later.
                guard nextRetention.reserve(
                    recordName: item.record.recordID.recordName,
                    createdAt: item.record["createdAt"] as? Date
                ) else {
                    throw BoundedCloudKitRecordError.retentionUnavailable
                }
                continue
            }
            guard let selectedSenderID else {
                // Before a host has received an offer, defer valid ICE/bye
                // records so they can accompany that sender's later offer.
                continue
            }
            guard nextRetention.reserve(
                recordName: item.record.recordID.recordName,
                createdAt: item.record["createdAt"] as? Date
            ) else {
                throw BoundedCloudKitRecordError.retentionUnavailable
            }
            guard envelope.senderID == selectedSenderID else {
                // Once an offer sender is selected, records from any other
                // sender are permanently outside this pairing session.
                continue
            }
            if let selectedOfferIndex,
               index < selectedOfferIndex,
               envelope.kind != .ice {
                // ICE may legitimately trickle ahead of the offer. No other
                // unbound message is allowed to affect host session state.
                continue
            }
            envelopes.append(envelope)
        }
        consumedRecordRetention = nextRetention
        return envelopes
    }

    private func envelopeFrom(_ record: CKRecord) -> SignalingEnvelope? {
        guard let recordSenderID = record["senderID"] as? String,
              !recordSenderID.isEmpty,
              record["targetID"] as? String == senderID,
              record["pairingCode"] as? String == code,
              let createdAt = record["createdAt"] as? Date,
              let kindRaw = record["kind"] as? String,
              let kind = SignalingEnvelope.Kind(rawValue: kindRaw),
              let payloadString = record["payload"] as? String,
              let payload = deserializePayload(payloadString) else {
            return nil
        }
        // `role` on the envelope is advisory; the sender knows its own
        // role. Reconstruct from record fields.
        let role: SignalingEnvelope.Role = recordSenderID == senderID ? .host : .client
        return SignalingEnvelope(
            role: role,
            kind: kind,
            payload: payload,
            ts: createdAt.timeIntervalSince1970,
            senderID: recordSenderID)
    }

    private func deleteOwnRecords(forPairingCode _: String) async throws {
        guard let lifecycle = ownedRecordLifecycle else { return }
        let ids = lifecycle.recordsForShutdownCleanup().map {
            CKRecord.ID(recordName: $0)
        }
        let cleaned = await cleanupOwnedRecordIDs(ids)
        guard cleaned.count == ids.count else {
            throw SignalingError.transport(
                "Some signaling records are still waiting for iCloud cleanup.")
        }
        advertisementRecord = nil
    }

    private func deleteRecordIDs(_ ids: [CKRecord.ID]) async throws {
        guard !ids.isEmpty else { return }
        let cleaned = await cleanupOwnedRecordIDs(ids)
        guard cleaned.count == Set(ids).count else {
            throw SignalingError.transport(
                "Some signaling records are still waiting for iCloud cleanup.")
        }
    }

    private func prepareOwnedRecordLifecycle() async throws {
        if ownedRecordLifecycle != nil {
            guard ownedRecordAccountBinding != nil else {
                throw SignalingError.iCloudUnavailable(
                    "The signaling cleanup account binding is unavailable. Restart the app and try again.")
            }
            return
        }
        let binding = try await resolveCurrentAccountBinding(
            operation: "prepare signaling cleanup")
        let advertisementName = Self.advertisementRecordName(
            senderID: senderID)
        let lifecycle = BoundedCloudKitOwnedRecordLifecycle(
            namespace: BoundedCloudKitOwnedRecordLifecycle.namespace(
                purpose: "signaling",
                containerIdentifier: containerIdentifier,
                senderID: senderID,
                accountBinding: binding),
            validityWindow: staleSeconds,
            maximumEntries: Self.maximumTrackedOwnedRecords,
            clock: { Date() },
            store: ownedRecordStore,
            ownsRecordName: { recordName in
                Self.isOwnedRecordName(
                    recordName,
                    advertisementName: advertisementName)
            })
        ownedRecordAccountBinding = binding
        ownedRecordLifecycle = lifecycle
        _ = await cleanupOwnedRecordIDs(
            lifecycle.restorationOverflowRecordNames.map {
                CKRecord.ID(recordName: $0)
            })
    }

    private func resolveCurrentAccountBinding(
        operation: String
    ) async throws -> CloudKitAccountBinding {
        let container = try cloudKit().container
        let status: CKAccountStatus
        do {
            status = try await retryingCloudKit(
                "\(operation): check iCloud account"
            ) {
                try await container.accountStatus()
            }
        } catch {
            throw SignalingError.iCloudUnavailable(
                "Couldn't safely verify the Apple Account before \(operation).")
        }
        guard status == .available else {
            throw SignalingError.iCloudUnavailable(
                "The Apple Account is not available for \(operation).")
        }

        let userRecordID: CKRecord.ID
        do {
            userRecordID = try await retryingCloudKit(
                "\(operation): identify iCloud account"
            ) {
                try await container.userRecordID()
            }
        } catch {
            throw SignalingError.iCloudUnavailable(
                "Couldn't safely identify the Apple Account before \(operation).")
        }
        do {
            return try CloudKitAccountBinding.derived(
                containerIdentifier: containerIdentifier,
                userRecordName: userRecordID.recordName)
        } catch {
            throw SignalingError.iCloudUnavailable(
                "The Apple Account could not be safely bound before \(operation).")
        }
    }

    private func revalidateOwnedRecordAccountBinding(
        operation: String
    ) async throws {
        guard let expected = ownedRecordAccountBinding else {
            throw SignalingError.iCloudUnavailable(
                "The signaling account binding is unavailable before \(operation).")
        }
        let current = try await resolveCurrentAccountBinding(
            operation: operation)
        guard current == expected else {
            throw SignalingError.iCloudUnavailable(
                "The Apple Account changed before \(operation). Restart the app before continuing.")
        }
    }

    private func reserveOwnedRecord(
        _ recordID: CKRecord.ID,
        createdAt: Date,
        refreshesDeadline: Bool
    ) async throws {
        while var lifecycle = ownedRecordLifecycle {
            switch lifecycle.track(
                recordName: recordID.recordName,
                createdAt: createdAt,
                refreshesDeadline: refreshesDeadline) {
            case .tracked:
                ownedRecordLifecycle = lifecycle
                return
            case .retentionUnavailable:
                ownedRecordLifecycle = lifecycle
                throw SignalingError.transport(
                    "The signaling record could not be durably tracked for iCloud cleanup.")
            case .cleanupRequired(let recordNames):
                ownedRecordLifecycle = lifecycle
                let cleaned = await cleanupOwnedRecordIDs(recordNames.map {
                    CKRecord.ID(recordName: $0)
                })
                guard cleaned.count == recordNames.count else {
                    throw SignalingError.transport(
                        "Signaling is waiting for iCloud cleanup. Keep both apps open and try again shortly.")
                }
            }
        }
        throw SignalingError.transport(
            "The signaling record could not be durably tracked for iCloud cleanup.")
    }

    private func markOwnedRecordsCleaned(_ ids: [CKRecord.ID]) {
        guard var lifecycle = ownedRecordLifecycle,
              lifecycle.markCleaned(recordNames: ids.map(\.recordName)) else {
            return
        }
        ownedRecordLifecycle = lifecycle
    }

    @discardableResult
    private func cleanupOwnedRecordIDs(
        _ ids: [CKRecord.ID]
    ) async -> Set<CKRecord.ID> {
        let uniqueIDs = Set(ids).sorted {
            $0.recordName < $1.recordName
        }
        guard !uniqueIDs.isEmpty,
              let database = try? cloudKitDatabase() else { return [] }
        var cleaned: Set<CKRecord.ID> = []
        for start in stride(from: 0, to: uniqueIDs.count, by: 100) {
            let end = min(start + 100, uniqueIDs.count)
            let batch = Array(uniqueIDs[start..<end])
            do {
                try await revalidateOwnedRecordAccountBinding(
                    operation: "delete owned signaling records")
            } catch {
                log.warning("signaling cleanup account revalidation failed; retaining the durable cleanup ledger")
                return []
            }
            let operation = CKModifyRecordsOperation(
                recordsToSave: nil,
                recordIDsToDelete: batch)
            operation.savePolicy = .allKeys
            operation.isAtomic = false
            let result: Result<Void, Error> = await withCheckedContinuation {
                continuation in
                operation.modifyRecordsResultBlock = {
                    continuation.resume(returning: $0)
                }
                database.add(operation)
            }
            cleaned.formUnion(
                BoundedCloudKitDeleteAccounting.confirmedRecordIDs(
                    in: batch,
                    result: result))
        }
        do {
            try await revalidateOwnedRecordAccountBinding(
                operation: "release the signaling cleanup ledger")
        } catch {
            log.warning("signaling cleanup account changed before ledger release; retaining the durable cleanup ledger")
            return []
        }
        markOwnedRecordsCleaned(Array(cleaned))
        return cleaned
    }

    private nonisolated static func isOwnedRecordName(
        _ recordName: String,
        advertisementName: String
    ) -> Bool {
        if recordName == advertisementName { return true }
        let prefix = "WebRTCSignal-Signaling-"
        guard recordName.hasPrefix(prefix),
              recordName.utf8.count <= 128 else { return false }
        let suffix = String(recordName.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return false }
        return uuid.uuidString == suffix.uppercased()
    }

    private func retryingCloudKit<Value>(
        _ operation: String,
        run: () async throws -> Value
    ) async throws -> Value {
        let delays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
        ]

        for (attempt, delay) in delays.enumerated() {
            do {
                return try await run()
            } catch {
                guard Self.isTransientCloudKitError(error), !Task.isCancelled else {
                    throw error
                }
                log.warning("\(operation, privacy: .public) failed transiently on attempt \(attempt + 1, privacy: .public); retrying: \(String(describing: error), privacy: .public)")
                try await Task.sleep(for: delay)
            }
        }

        return try await run()
    }

    nonisolated static func isTransientCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code) else {
            return false
        }

        switch code {
        case .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .requestRateLimited,
             .zoneBusy:
            return true
        default:
            return false
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
            var accumulator = BoundedCloudKitRecordAccumulator<
                (CKRecord.ID, Result<CKRecord, Error>)>(
                    maximumObservedRecords: Self.maximumQueryRecords,
                    maximumPages: Self.maximumQueryPages)
            var page = try await database.records(
                matching: query,
                inZoneWith: nil,
                desiredKeys: nil,
                resultsLimit: 50)
            try accumulator.append(
                page.matchResults,
                observedRecordCount: page.matchResults.count,
                hasMore: page.queryCursor != nil)
            while let cursor = page.queryCursor {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: nil,
                    resultsLimit: 50)
                try accumulator.append(
                    page.matchResults,
                    observedRecordCount: page.matchResults.count,
                    hasMore: page.queryCursor != nil)
            }
            return (accumulator.records, nil)
        } catch BoundedCloudKitRecordError.queryLimitExceeded {
            throw SignalingError.transport(
                "Too many iCloud signaling records are waiting. Keep both apps open and try again shortly.")
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

    /// Host discovery has the same adversarial-prefix constraint as signaling:
    /// never present a partial first page as the complete set of selectable
    /// Macs. A cursor at either hard ceiling fails closed.
    private nonisolated static func boundedQueryRecords(
        _ query: CKQuery,
        in database: CKDatabase,
        desiredKeys: [CKRecord.FieldKey]
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        var accumulator = BoundedCloudKitRecordAccumulator<
            (CKRecord.ID, Result<CKRecord, Error>)>(
                maximumObservedRecords: maximumQueryRecords,
                maximumPages: maximumQueryPages)
        var page = try await database.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: desiredKeys,
            resultsLimit: 100)
        try accumulator.append(
            page.matchResults,
            observedRecordCount: page.matchResults.count,
            hasMore: page.queryCursor != nil)
        while let cursor = page.queryCursor {
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: desiredKeys,
                resultsLimit: 100)
            try accumulator.append(
                page.matchResults,
                observedRecordCount: page.matchResults.count,
                hasMore: page.queryCursor != nil)
        }
        return accumulator.records
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
