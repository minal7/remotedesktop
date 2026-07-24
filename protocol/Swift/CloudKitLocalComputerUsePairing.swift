import CloudKit
import CryptoKit
import Foundation

/// A classified failure to resolve the current CloudKit account owner.
///
/// Only the transient cases permit callers to keep using a previously
/// confirmed, device-local binding while waiting for CloudKit to recover.
public enum CloudKitAccountBindingResolutionError:
    Error, Equatable, LocalizedError, Sendable {
    case temporarilyUnavailable
    case couldNotDetermine
    case noAccount
    case restricted

    public var preservesConfirmedBinding: Bool {
        switch self {
        case .temporarilyUnavailable, .couldNotDetermine:
            return true
        case .noAccount, .restricted:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .temporarilyUnavailable:
            return "The Apple Account is temporarily unavailable to CloudKit."
        case .couldNotDetermine:
            return "CloudKit could not determine the current Apple Account."
        case .noAccount:
            return "This device is not signed into an Apple Account."
        case .restricted:
            return "Access to the Apple Account is restricted on this device."
        }
    }
}

/// An opaque, non-secret binding to the current user of one CloudKit
/// container. The underlying CloudKit user record name is never persisted or
/// logged; callers use this digest to keep device-local credentials separated
/// when the signed-in Apple Account changes.
public struct CloudKitAccountBinding:
    Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isCanonicalDigest(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String {
        "CloudKitAccountBinding(<redacted>)"
    }

    /// Resolves the current private-database owner for this exact container.
    /// `userRecordID()` is the supported opaque current-user identifier; it
    /// does not require Contacts discoverability or expose an Apple ID.
    public static func current(
        containerIdentifier: String
    ) async throws -> Self {
        try CloudKitEntitlements.validate(
            containerIdentifier: containerIdentifier)
        let container = CKContainer(identifier: containerIdentifier)
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw resolutionError(for: error)
        }
        if let statusError = resolutionError(for: status) {
            throw statusError
        }
        let userRecordID: CKRecord.ID
        do {
            userRecordID = try await container.userRecordID()
        } catch {
            throw resolutionError(for: error)
        }
        return try derived(
            containerIdentifier: containerIdentifier,
            userRecordName: userRecordID.recordName)
    }

    static func resolutionError(
        for status: CKAccountStatus
    ) -> CloudKitAccountBindingResolutionError? {
        switch status {
        case .available:
            return nil
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        case .couldNotDetermine:
            return .couldNotDetermine
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        @unknown default:
            return .couldNotDetermine
        }
    }

    static func resolutionError(
        for error: Error
    ) -> CloudKitAccountBindingResolutionError {
        guard let cloudKit = error as? CKError else {
            return .couldNotDetermine
        }
        return resolutionError(for: cloudKit.code)
    }

    /// Authentication and permission failures are account-boundary failures,
    /// not ordinary transport outages. Keeping an old local credential alive
    /// for either would let a signed-out or restricted process impersonate the
    /// last confirmed CloudKit owner.
    static func resolutionError(
        for code: CKError.Code
    ) -> CloudKitAccountBindingResolutionError {
        switch code {
        case .notAuthenticated:
            return .noAccount
        case .permissionFailure:
            return .restricted
        case .accountTemporarilyUnavailable, .networkUnavailable,
             .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost:
            return .temporarilyUnavailable
        default:
            // An operation error is not proof that the user signed out or is
            // restricted. Only a resolved account status may clear the cache.
            return .couldNotDetermine
        }
    }

    /// Pure derivation kept internal so both app targets can prove stable and
    /// cross-account/container separation without making a CloudKit request.
    static func derived(
        containerIdentifier: String,
        userRecordName: String
    ) throws -> Self {
        guard isBoundedIdentifier(containerIdentifier, maximumBytes: 512),
              isBoundedIdentifier(userRecordName, maximumBytes: 4_096) else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }
        let material = Data(
            "RemoteDesktop.CloudKitAccountBinding.v1\n\(containerIdentifier)\n\(userRecordName)"
                .utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        guard let binding = Self(rawValue: digest) else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }
        return binding
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x61 && byte <= 0x66)
            }
    }

    private static func isBoundedIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            }
    }
}

/// Bounded, expiry-aware memory for requests which this host already rejected
/// or answered. Entries live only through the request's original validity
/// window; malformed records without a usable timestamp receive at most one
/// full window from observation. The fixed ceiling prevents a private-database
/// flood from turning duplicate suppression into process-lifetime growth.
struct LocalComputerUsePairingReplayRetention {
    private struct Entry {
        let expiresAt: Date
        let insertionOrder: UInt64
    }

    init(
        validityWindow: TimeInterval,
        maximumEntries: Int,
        clock: @escaping @Sendable () -> Date
    ) {
        precondition(validityWindow > 0)
        precondition(maximumEntries > 0)
        self.validityWindow = validityWindow
        self.maximumEntries = maximumEntries
        self.clock = clock
    }

    var count: Int { entries.count }

    mutating func shouldHandle(recordName: String) -> Bool {
        pruneExpired()
        return entries[recordName] == nil
    }

    mutating func recordHandled(
        recordName: String,
        requestCreatedAt: Date?
    ) {
        let now = clock()
        pruneExpired(at: now)
        guard entries[recordName] == nil else { return }

        // A forged far-future timestamp must not extend retention beyond one
        // validity window. A legitimately older request is retained only for
        // the portion of its original window which remains.
        let maximumExpiry = now.addingTimeInterval(validityWindow)
        let requestedExpiry: Date
        if let requestCreatedAt,
           requestCreatedAt.timeIntervalSinceReferenceDate.isFinite {
            requestedExpiry = requestCreatedAt.addingTimeInterval(
                validityWindow)
        } else {
            requestedExpiry = maximumExpiry
        }
        let expiresAt = min(max(requestedExpiry, now), maximumExpiry)

        if entries.count >= maximumEntries,
           let victim = entries.min(by: { left, right in
               if left.value.expiresAt != right.value.expiresAt {
                   return left.value.expiresAt < right.value.expiresAt
               }
               return left.value.insertionOrder
                   < right.value.insertionOrder
           })?.key {
            entries.removeValue(forKey: victim)
        }

        entries[recordName] = Entry(
            expiresAt: expiresAt,
            insertionOrder: nextInsertionOrder)
        nextInsertionOrder &+= 1
    }

    private mutating func pruneExpired() {
        pruneExpired(at: clock())
    }

    private mutating func pruneExpired(at now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private let validityWindow: TimeInterval
    private let maximumEntries: Int
    private let clock: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var nextInsertionOrder: UInt64 = 0
}

enum BoundedCloudKitRecordError: Error, Equatable {
    case queryLimitExceeded
    case retentionUnavailable
}

/// Shared bounded page accumulator for every private-CloudKit polling path.
/// A query which advertises another page at the hard ceiling is incomplete:
/// callers must not act on a prefix while an attacker-controlled suffix remains
/// unseen.
struct BoundedCloudKitRecordAccumulator<Element> {
    init(
        maximumObservedRecords: Int,
        maximumPages: Int
    ) {
        precondition(maximumObservedRecords > 0)
        precondition(maximumPages > 0)
        self.maximumObservedRecords = maximumObservedRecords
        self.maximumPages = maximumPages
    }

    private(set) var records: [Element] = []
    private(set) var observedRecordCount = 0
    private(set) var observedPageCount = 0

    mutating func append(
        _ successfulRecords: [Element],
        observedRecordCount pageObservedRecordCount: Int,
        hasMore: Bool
    ) throws {
        guard pageObservedRecordCount >= successfulRecords.count,
              pageObservedRecordCount >= 0,
              observedPageCount < maximumPages,
              observedRecordCount <= maximumObservedRecords
                - pageObservedRecordCount else {
            throw BoundedCloudKitRecordError.queryLimitExceeded
        }

        let newObservedRecordCount = observedRecordCount
            + pageObservedRecordCount
        let newObservedPageCount = observedPageCount + 1
        guard !hasMore
                || (newObservedRecordCount < maximumObservedRecords
                    && newObservedPageCount < maximumPages) else {
            throw BoundedCloudKitRecordError.queryLimitExceeded
        }

        records.append(contentsOf: successfulRecords)
        observedRecordCount = newObservedRecordCount
        observedPageCount = newObservedPageCount
    }

    private let maximumObservedRecords: Int
    private let maximumPages: Int
}

/// Compatibility wrapper which preserves the existing local-pairing error
/// contract while sharing the accumulator implementation with signaling and
/// Computer Use.
struct LocalComputerUsePairingRecordAccumulator<Element> {
    init(
        maximumObservedRecords: Int,
        maximumPages: Int
    ) {
        base = BoundedCloudKitRecordAccumulator(
            maximumObservedRecords: maximumObservedRecords,
            maximumPages: maximumPages)
    }

    var records: [Element] { base.records }
    var observedRecordCount: Int { base.observedRecordCount }
    var observedPageCount: Int { base.observedPageCount }

    mutating func append(
        _ successfulRecords: [Element],
        observedRecordCount: Int,
        hasMore: Bool
    ) throws {
        do {
            try base.append(
                successfulRecords,
                observedRecordCount: observedRecordCount,
                hasMore: hasMore)
        } catch BoundedCloudKitRecordError.queryLimitExceeded {
            throw LocalComputerUseCloudPairingError.queryLimitExceeded
        }
    }

    private var base: BoundedCloudKitRecordAccumulator<Element>
}

struct BoundedCloudKitReplayRetention {
    private struct Entry {
        let expiresAt: Date
        let insertionOrder: UInt64
    }

    init(
        validityWindow: TimeInterval,
        maximumEntries: Int,
        clock: @escaping @Sendable () -> Date
    ) {
        precondition(validityWindow > 0)
        precondition(maximumEntries > 0)
        self.validityWindow = validityWindow
        self.maximumEntries = maximumEntries
        self.clock = clock
    }

    var count: Int { entries.count }

    mutating func contains(recordName: String) -> Bool {
        pruneExpired()
        return entries[recordName] != nil
    }

    /// Reserves replay state without evicting a still-live identity. Returning
    /// false is a fail-closed capacity signal: the caller must not apply a
    /// partially remembered CloudKit batch.
    mutating func reserve(
        recordName: String,
        createdAt: Date?
    ) -> Bool {
        let now = clock()
        pruneExpired(at: now)
        if entries[recordName] != nil { return true }
        guard entries.count < maximumEntries else { return false }

        let maximumExpiry = now.addingTimeInterval(validityWindow)
        let requestedExpiry: Date
        if let createdAt,
           createdAt.timeIntervalSinceReferenceDate.isFinite {
            requestedExpiry = createdAt.addingTimeInterval(validityWindow)
        } else {
            requestedExpiry = maximumExpiry
        }
        entries[recordName] = Entry(
            expiresAt: min(max(requestedExpiry, now), maximumExpiry),
            insertionOrder: nextInsertionOrder)
        nextInsertionOrder &+= 1
        return true
    }

    private mutating func pruneExpired() {
        pruneExpired(at: clock())
    }

    private mutating func pruneExpired(at now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private let validityWindow: TimeInterval
    private let maximumEntries: Int
    private let clock: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var nextInsertionOrder: UInt64 = 0
}

struct BoundedCloudKitTrackedRecord: Codable, Equatable {
    let recordName: String
    let deleteAfter: Date
}

protocol BoundedCloudKitOwnedRecordStore: Sendable {
    /// `nil` means stored state exists but cannot be decoded safely. Callers
    /// must fail closed rather than treating lost cleanup identities as an
    /// empty store.
    func load(namespace: String) -> [BoundedCloudKitTrackedRecord]?
    @discardableResult
    func save(
        _ records: [BoundedCloudKitTrackedRecord],
        namespace: String
    ) -> Bool
}

final class UserDefaultsBoundedCloudKitOwnedRecordStore:
    BoundedCloudKitOwnedRecordStore, @unchecked Sendable {
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(namespace: String) -> [BoundedCloudKitTrackedRecord]? {
        let storageKey = key(namespace: namespace)
        guard defaults.object(forKey: storageKey) != nil else { return [] }
        guard let data = defaults.data(forKey: storageKey),
              data.count <= Self.maximumEncodedBytes else {
            return nil
        }
        return try? JSONDecoder().decode(
            [BoundedCloudKitTrackedRecord].self,
            from: data)
    }

    @discardableResult
    func save(
        _ records: [BoundedCloudKitTrackedRecord],
        namespace: String
    ) -> Bool {
        let storageKey = key(namespace: namespace)
        guard !records.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return defaults.object(forKey: storageKey) == nil
        }
        guard let data = try? JSONEncoder().encode(records),
              data.count <= Self.maximumEncodedBytes else {
            return false
        }
        defaults.set(data, forKey: storageKey)
        return defaults.data(forKey: storageKey) == data
    }

    private func key(namespace: String) -> String {
        "RemoteDesktop.BoundedCloudKitOwnedRecords.\(namespace)"
    }

    private static let maximumEncodedBytes = 512 * 1_024
    private let defaults: UserDefaults
}

/// Persisted cleanup identities for sender-owned CloudKit records. Capacity is
/// a write barrier: a new CloudKit save is forbidden until confirmed deletion
/// frees a durable slot.
struct BoundedCloudKitOwnedRecordLifecycle {
    enum TrackResult: Equatable {
        case tracked
        case cleanupRequired([String])
        case retentionUnavailable
    }

    init(
        namespace: String,
        validityWindow: TimeInterval,
        maximumEntries: Int,
        clock: @escaping @Sendable () -> Date,
        store: any BoundedCloudKitOwnedRecordStore,
        ownsRecordName: @escaping @Sendable (String) -> Bool
    ) {
        precondition(validityWindow > 0)
        precondition(maximumEntries > 0)
        self.namespace = namespace
        self.validityWindow = validityWindow
        self.maximumEntries = maximumEntries
        self.clock = clock
        self.store = store
        self.ownsRecordName = ownsRecordName

        let now = clock()
        let maximumRestoredExpiry = now.addingTimeInterval(validityWindow)
        let loaded = store.load(namespace: namespace)
        let restored = (loaded ?? [])
            .filter {
                ownsRecordName($0.recordName)
                    && $0.deleteAfter.timeIntervalSinceReferenceDate.isFinite
            }
            .map {
                BoundedCloudKitTrackedRecord(
                    recordName: $0.recordName,
                    deleteAfter: min(
                        $0.deleteAfter,
                        maximumRestoredExpiry))
            }
        let grouped = Dictionary(grouping: restored, by: \.recordName)
            .compactMap { _, duplicates in
                duplicates.min(by: { $0.deleteAfter < $1.deleteAfter })
            }
            .sorted(by: Self.sortsBefore)
        let overflowCount = max(0, grouped.count - maximumEntries)
        restorationOverflowRecordNames = Array(grouped.prefix(overflowCount))
            .map(\.recordName)
        tracked = Dictionary(
            uniqueKeysWithValues: grouped.map {
                ($0.recordName, $0)
            })
        retentionAvailable = false
        retentionAvailable = loaded != nil && persist(tracked)
    }

    var count: Int { tracked.count }

    func recordsDueForCleanup() -> [String] {
        let now = clock()
        return tracked.values
            .filter { $0.deleteAfter <= now }
            .sorted(by: Self.sortsBefore)
            .map(\.recordName)
    }

    func recordsForShutdownCleanup() -> [String] {
        tracked.values.sorted(by: Self.sortsBefore).map(\.recordName)
    }

    mutating func track(
        recordName: String,
        createdAt: Date,
        refreshesDeadline: Bool
    ) -> TrackResult {
        guard retentionAvailable, ownsRecordName(recordName) else {
            return .retentionUnavailable
        }
        let now = clock()
        let maximumExpiry = now.addingTimeInterval(validityWindow)
        let requestedExpiry = createdAt.timeIntervalSinceReferenceDate.isFinite
            ? createdAt.addingTimeInterval(validityWindow)
            : maximumExpiry
        let candidate = BoundedCloudKitTrackedRecord(
            recordName: recordName,
            deleteAfter: min(max(requestedExpiry, now), maximumExpiry))

        if let existing = tracked[recordName] {
            var updated = tracked
            updated[recordName] = BoundedCloudKitTrackedRecord(
                recordName: recordName,
                deleteAfter: refreshesDeadline
                    ? max(existing.deleteAfter, candidate.deleteAfter)
                    : min(existing.deleteAfter, candidate.deleteAfter))
            guard persist(updated) else { return .retentionUnavailable }
            tracked = updated
            return .tracked
        }

        guard tracked.count < maximumEntries else {
            let requiredCleanupCount = tracked.count - maximumEntries + 1
            return .cleanupRequired(tracked.values
                .sorted(by: Self.sortsBefore)
                .prefix(requiredCleanupCount)
                .map(\.recordName))
        }

        var updated = tracked
        updated[recordName] = candidate
        guard persist(updated) else { return .retentionUnavailable }
        tracked = updated
        return .tracked
    }

    @discardableResult
    mutating func markCleaned(
        recordNames: some Sequence<String>
    ) -> Bool {
        guard retentionAvailable else { return false }
        var updated = tracked
        for recordName in recordNames {
            updated.removeValue(forKey: recordName)
        }
        guard persist(updated) else { return false }
        tracked = updated
        return true
    }

    static func namespace(
        purpose: String,
        containerIdentifier: String,
        senderID: String,
        accountBinding: CloudKitAccountBinding
    ) -> String {
        let material = Data(
            "RemoteDesktop.BoundedCloudKitOwnedRecords.v1\n\(purpose)\n\(containerIdentifier)\n\(senderID)\n\(accountBinding.rawValue)"
                .utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func persist(
        _ values: [String: BoundedCloudKitTrackedRecord]
    ) -> Bool {
        store.save(
            values.values.sorted(by: Self.sortsBefore),
            namespace: namespace)
    }

    private static func sortsBefore(
        _ left: BoundedCloudKitTrackedRecord,
        _ right: BoundedCloudKitTrackedRecord
    ) -> Bool {
        if left.deleteAfter != right.deleteAfter {
            return left.deleteAfter < right.deleteAfter
        }
        return left.recordName < right.recordName
    }

    private let namespace: String
    private let validityWindow: TimeInterval
    private let maximumEntries: Int
    private let clock: @Sendable () -> Date
    private let store: any BoundedCloudKitOwnedRecordStore
    private let ownsRecordName: @Sendable (String) -> Bool
    private var tracked: [String: BoundedCloudKitTrackedRecord]
    private var retentionAvailable: Bool
    let restorationOverflowRecordNames: [String]
}

enum BoundedCloudKitDeleteAccounting {
    static func confirmedRecordIDs(
        in batch: [CKRecord.ID],
        result: Result<Void, Error>
    ) -> Set<CKRecord.ID> {
        switch result {
        case .success:
            return Set(batch)
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.domain == CKErrorDomain,
                  let code = CKError.Code(rawValue: nsError.code) else {
                return []
            }
            if code == .unknownItem { return Set(batch) }
            guard code == .partialFailure,
                  let failures = nsError.userInfo[CKPartialErrorsByItemIDKey]
                    as? [CKRecord.ID: Error] else { return [] }
            return Set(batch.filter { id in
                guard let failure = failures[id] else { return true }
                let item = failure as NSError
                return item.domain == CKErrorDomain
                    && item.code == CKError.Code.unknownItem.rawValue
            })
        }
    }
}

struct LocalComputerUsePairingTrackedResponse: Codable, Equatable {
    let recordName: String
    let deleteAfter: Date
}

/// Small persistence seam for host-owned response IDs. The payload contains
/// record names and expiry dates only; credentials and Apple Account identity
/// never enter this store.
protocol LocalComputerUsePairingResponseStore: Sendable {
    /// `nil` means persisted state exists but cannot be read safely. Treating
    /// that state as an empty ledger would permit a new CloudKit write after
    /// losing the exact record IDs required for cleanup.
    func load(
        namespace: String
    ) -> [LocalComputerUsePairingTrackedResponse]?
    @discardableResult
    func save(
        _ responses: [LocalComputerUsePairingTrackedResponse],
        namespace: String
    ) -> Bool
}

final class UserDefaultsLocalComputerUsePairingResponseStore:
    LocalComputerUsePairingResponseStore, @unchecked Sendable {
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(
        namespace: String
    ) -> [LocalComputerUsePairingTrackedResponse]? {
        let storageKey = key(namespace: namespace)
        guard defaults.object(forKey: storageKey) != nil else { return [] }
        guard let data = defaults.data(forKey: storageKey),
              data.count <= Self.maximumEncodedBytes else {
            return nil
        }
        return try? JSONDecoder().decode(
            [LocalComputerUsePairingTrackedResponse].self,
            from: data)
    }

    @discardableResult
    func save(
        _ responses: [LocalComputerUsePairingTrackedResponse],
        namespace: String
    ) -> Bool {
        let storageKey = key(namespace: namespace)
        guard !responses.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return defaults.object(forKey: storageKey) == nil
        }
        guard let data = try? JSONEncoder().encode(responses),
              data.count <= Self.maximumEncodedBytes else {
            return false
        }
        defaults.set(data, forKey: storageKey)
        return defaults.data(forKey: storageKey) == data
    }

    private func key(namespace: String) -> String {
        "RemoteDesktop.CloudKitLocalPairing.responses.\(namespace)"
    }

    private static let maximumEncodedBytes = 128 * 1_024
    private let defaults: UserDefaults
}

/// Persisted, bounded ledger of response records owned by one host/account.
/// A newly constructed ledger represents a subsequent app run and therefore
/// exposes expired records for best-effort CloudKit deletion immediately.
struct LocalComputerUsePairingResponseLifecycle {
    enum TrackResult: Equatable {
        case tracked
        case cleanupRequired([String])
        case retentionUnavailable
    }

    init(
        namespace: String,
        validityWindow: TimeInterval,
        maximumEntries: Int,
        clock: @escaping @Sendable () -> Date,
        store: any LocalComputerUsePairingResponseStore
    ) {
        precondition(validityWindow > 0)
        precondition(maximumEntries > 0)
        self.namespace = namespace
        self.validityWindow = validityWindow
        self.maximumEntries = maximumEntries
        self.clock = clock
        self.store = store

        let now = clock()
        let maximumRestoredExpiry = now.addingTimeInterval(validityWindow)
        let loaded = store.load(namespace: namespace)
        let restored = (loaded ?? [])
            .filter {
                Self.isOwnedPairingRecordName($0.recordName)
                    && $0.deleteAfter.timeIntervalSinceReferenceDate.isFinite
            }
            .map {
                LocalComputerUsePairingTrackedResponse(
                    recordName: $0.recordName,
                    deleteAfter: min(
                        $0.deleteAfter,
                        maximumRestoredExpiry))
            }
        let grouped = Dictionary(grouping: restored, by: \.recordName)
            .compactMap { _, duplicates in
                duplicates.min(by: { $0.deleteAfter < $1.deleteAfter })
            }
            .sorted(by: Self.sortsBefore)
        let overflowCount = max(0, grouped.count - maximumEntries)
        restorationOverflow = Array(grouped.prefix(overflowCount))
            .map(\.recordName)
        // Do not discard overflow cleanup identities before CloudKit confirms
        // deletion. A later startup must retry every failed/partial deletion.
        tracked = Dictionary(
            uniqueKeysWithValues: grouped.map {
                ($0.recordName, $0)
            })
        retentionAvailable = false
        retentionAvailable = loaded != nil && persist(tracked)
    }

    var count: Int { tracked.count }

    var restorationOverflowRecordNames: [String] {
        restorationOverflow
    }

    func recordsDueForCleanup() -> [String] {
        let now = clock()
        return tracked.values
            .filter { $0.deleteAfter <= now }
            .sorted(by: Self.sortsBefore)
            .map(\.recordName)
    }

    func recordsForShutdownCleanup() -> [String] {
        tracked.values.sorted(by: Self.sortsBefore).map(\.recordName)
    }

    var nextCleanupDate: Date? {
        tracked.values.map(\.deleteAfter).min()
    }

    /// Reserves one durable cleanup slot before the caller writes CloudKit.
    /// When full, no local identity is removed: the caller must confirm deletion
    /// of every returned record, call `markCleaned`, and retry this method. This
    /// makes a failed deletion a write barrier instead of an orphaning event.
    mutating func track(
        recordName: String,
        responseCreatedAt: Date
    ) -> TrackResult {
        guard retentionAvailable else {
            return .retentionUnavailable
        }
        guard Self.isOwnedPairingRecordName(recordName) else {
            return .cleanupRequired([])
        }
        let now = clock()
        let maximumExpiry = now.addingTimeInterval(validityWindow)
        let requestedExpiry: Date
        if responseCreatedAt.timeIntervalSinceReferenceDate.isFinite {
            requestedExpiry = responseCreatedAt.addingTimeInterval(
                validityWindow)
        } else {
            requestedExpiry = maximumExpiry
        }
        let deleteAfter = min(max(requestedExpiry, now), maximumExpiry)
        let candidate = LocalComputerUsePairingTrackedResponse(
            recordName: recordName,
            deleteAfter: deleteAfter)

        if let existing = tracked[recordName] {
            // Re-observing a deterministic response ID cannot extend its
            // original retention deadline.
            var updated = tracked
            updated[recordName] = LocalComputerUsePairingTrackedResponse(
                recordName: recordName,
                deleteAfter: min(existing.deleteAfter, candidate.deleteAfter))
            guard persist(updated) else {
                retentionAvailable = false
                return .retentionUnavailable
            }
            tracked = updated
            return .tracked
        }

        guard tracked.count < maximumEntries else {
            let requiredCleanupCount = tracked.count - maximumEntries + 1
            let cleanupCandidates = tracked.values
                .sorted(by: Self.sortsBefore)
                .prefix(requiredCleanupCount)
                .map(\.recordName)
            return .cleanupRequired(cleanupCandidates)
        }

        var updated = tracked
        updated[recordName] = candidate
        guard persist(updated) else {
            retentionAvailable = false
            return .retentionUnavailable
        }
        tracked = updated
        return .tracked
    }

    @discardableResult
    mutating func markCleaned(
        recordNames: some Sequence<String>
    ) -> Bool {
        guard retentionAvailable else { return false }
        var updated = tracked
        var changed = false
        for recordName in recordNames {
            changed = updated.removeValue(forKey: recordName) != nil
                || changed
        }
        guard changed else { return true }
        guard persist(updated) else {
            retentionAvailable = false
            return false
        }
        tracked = updated
        return true
    }

    private func persist(
        _ values: [String: LocalComputerUsePairingTrackedResponse]
    ) -> Bool {
        store.save(
            values.values.sorted(by: Self.sortsBefore),
            namespace: namespace)
    }

    private static func sortsBefore(
        _ left: LocalComputerUsePairingTrackedResponse,
        _ right: LocalComputerUsePairingTrackedResponse
    ) -> Bool {
        if left.deleteAfter != right.deleteAfter {
            return left.deleteAfter < right.deleteAfter
        }
        return left.recordName < right.recordName
    }

    private static func isOwnedPairingRecordName(_ value: String) -> Bool {
        let prefixes = [
            "WebRTCSignal-LocalCredentialRequest-",
            "WebRTCSignal-LocalCredentialResponse-",
        ]
        guard let prefix = prefixes.first(where: value.hasPrefix),
              value.utf8.count <= 128 else {
            return false
        }
        let suffix = String(value.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return false }
        return uuid.uuidString == suffix.uppercased()
    }

    private let namespace: String
    private let validityWindow: TimeInterval
    private let maximumEntries: Int
    private let clock: @Sendable () -> Date
    private let store: any LocalComputerUsePairingResponseStore
    private var tracked: [String: LocalComputerUsePairingTrackedResponse]
    private var retentionAvailable: Bool
    private let restorationOverflow: [String]
}

/// Zero-code enrollment for the authenticated LAN Computer Use channel.
///
/// Both peers exchange only ephemeral public keys and an encrypted copy of the
/// LAN credential through the user's private CloudKit database. The record
/// deliberately reuses the deployed `WebRTCSignal` fields, so Release builds
/// do not depend on a new Production schema or query index.
actor CloudKitLocalComputerUsePairing {
    static let requestKind = "localCredential.request.v2"
    static let responseKind = "localCredential.response.v2"
    static let staleSeconds: TimeInterval = 5 * 60
    static let clockSkewSeconds: TimeInterval = 5
    static let maximumReplayEntries = 512
    static let maximumTrackedResponses = 256
    static let maximumQueryRecords = 500
    static let maximumQueryPages = 10

    init(
        containerIdentifier: String,
        senderID: String = DeviceIdentity.get(),
        startedAt: Date? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        responseStore: any LocalComputerUsePairingResponseStore =
            UserDefaultsLocalComputerUsePairingResponseStore()
    ) {
        self.containerIdentifier = containerIdentifier
        self.senderID = senderID
        self.startedAt = startedAt ?? clock()
        self.clock = clock
        self.responseStore = responseStore
        replayRetention = LocalComputerUsePairingReplayRetention(
            validityWindow: Self.staleSeconds,
            maximumEntries: Self.maximumReplayEntries,
            clock: clock)
    }

    /// Requests the exact fingerprint advertised by the selected nearby Mac.
    /// CloudKit account membership authenticates the enrollment request; an
    /// ephemeral key agreement keeps the credential opaque to CloudKit.
    func requestCredential(
        hostID: String,
        pairingCode: String,
        expectedCredentialID: String,
        accountBinding: CloudKitAccountBinding,
        timeout: Duration = .seconds(20)
    ) async throws -> LocalComputerUseCredential {
        guard !senderID.isEmpty else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }
        try await ensureCurrentAccount(matches: accountBinding)
        try await prepareResponseLifecycle(accountBinding: accountBinding)
        await cleanupExpiredTrackedResponses()
        let context = try LocalComputerUseCloudPairingWire.makeRequest(
            clientID: senderID,
            hostID: hostID,
            pairingCode: pairingCode,
            expectedCredentialID: expectedCredentialID,
            accountBinding: accountBinding,
            createdAt: clock())
        let requestID = context.record.recordID
        var responseIDs: [CKRecord.ID] = []

        do {
            try await ensureCurrentAccount(matches: accountBinding)
            guard await trackOwnedPairingRecord(context.record) else {
                throw LocalComputerUseCloudPairingError
                    .recordRetentionUnavailable
            }
            // Tracking may await bounded cleanup. Revalidate again at the
            // durable-write boundary so a concurrent account switch cannot
            // redirect this request into another private database.
            try await ensureCurrentAccount(matches: accountBinding)
            _ = try await retryingCloudKit {
                try await ensureCurrentAccount(matches: accountBinding)
                try await database.save(context.record)
            }
            try await ensureCurrentAccount(matches: accountBinding)

            let deadline = ContinuousClock.now.advanced(by: timeout)
            var lastValidationError: Error?
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let records = try await records(
                    targetedTo: senderID,
                    since: context.createdAt.addingTimeInterval(-5))
                for record in records where
                    LocalComputerUseCloudPairingWire.kind(of: record)
                        == Self.responseKind {
                    guard LocalComputerUseCloudPairingWire.responseRequestID(
                        from: record) == context.requestID else {
                        continue
                    }
                    responseIDs.append(record.recordID)
                    let credential: LocalComputerUseCredential
                    do {
                        credential = try LocalComputerUseCloudPairingWire
                            .openResponse(
                                record,
                                request: context)
                    } catch {
                        lastValidationError = error
                        continue
                    }
                    // Do not persist a credential delivered while an Apple
                    // Account switch raced the CloudKit exchange.
                    try await ensureCurrentAccount(matches: accountBinding)
                    await cleanupOwnedRequestAndPeerResponses(
                        requestID: requestID,
                        responseIDs: responseIDs)
                    return credential
                }
                try await Task.sleep(for: .milliseconds(500))
            }

            await cleanupOwnedRequestAndPeerResponses(
                requestID: requestID,
                responseIDs: responseIDs)
            if Task.isCancelled { throw CancellationError() }
            if let lastValidationError { throw lastValidationError }
            throw LocalComputerUseCloudPairingError.timedOut
        } catch {
            await cleanupOwnedRequestAndPeerResponses(
                requestID: requestID,
                responseIDs: responseIDs)
            throw Self.userFacingError(error)
        }
    }

    /// Host-side responder. Invalid, stale, mismatched, or replayed requests
    /// are ignored independently so one malformed private record cannot stall
    /// enrollment for the user's other devices.
    @discardableResult
    func respondToRequests(
        hostID: String,
        pairingCode: String,
        credential: LocalComputerUseCredential,
        accountBinding: CloudKitAccountBinding
    ) async throws -> Int {
        do {
            return try await respondToRequestsImpl(
                hostID: hostID,
                pairingCode: pairingCode,
                credential: credential,
                accountBinding: accountBinding)
        } catch {
            // When cancellation reaches an active poll, its response records
            // no longer have an owning responder. Preserve failed deletions in
            // the persisted ledger for the next startup to retry.
            if error is CancellationError || Task.isCancelled {
                await shutdown()
            }
            throw error
        }
    }

    private func respondToRequestsImpl(
        hostID: String,
        pairingCode: String,
        credential: LocalComputerUseCredential,
        accountBinding: CloudKitAccountBinding
    ) async throws -> Int {
        guard !senderID.isEmpty, senderID == hostID else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }
        try await ensureCurrentAccount(matches: accountBinding)
        try await prepareResponseLifecycle(accountBinding: accountBinding)
        await cleanupExpiredTrackedResponses()
        let now = clock()
        let cutoff = max(
            startedAt.addingTimeInterval(-Self.clockSkewSeconds),
            now.addingTimeInterval(-Self.staleSeconds))
        let candidates = try await records(targetedTo: hostID, since: cutoff)
        try Task.checkCancellation()
        // The private-database query may have crossed an account transition.
        // Revalidate before inspecting or answering anything it returned.
        try await ensureCurrentAccount(matches: accountBinding)
        var responseCount = 0

        for request in candidates where
            LocalComputerUseCloudPairingWire.kind(of: request)
                == Self.requestKind {
            let recordName = request.recordID.recordName
            guard replayRetention.shouldHandle(recordName: recordName),
                  !inFlightRequestIDs.contains(request.recordID) else {
                continue
            }
            let observedAt = clock()
            let requestCreatedAt = request["createdAt"] as? Date
            guard Self.isValidRequestTimestamp(
                requestCreatedAt,
                observedAt: observedAt
            ) else {
                replayRetention.recordHandled(
                    recordName: recordName,
                    requestCreatedAt: requestCreatedAt)
                await deleteBestEffort([request.recordID])
                continue
            }
            inFlightRequestIDs.insert(request.recordID)
            let response: CKRecord
            do {
                response = try LocalComputerUseCloudPairingWire.makeResponse(
                    to: request,
                    hostID: hostID,
                    pairingCode: pairingCode,
                    credential: credential,
                    accountBinding: accountBinding,
                    createdAt: observedAt)
            } catch LocalComputerUseCloudPairingError.requestNotForHost {
                inFlightRequestIDs.remove(request.recordID)
                replayRetention.recordHandled(
                    recordName: recordName,
                    requestCreatedAt: requestCreatedAt)
                await deleteBestEffort([request.recordID])
                continue
            } catch LocalComputerUseCloudPairingError.credentialMismatch {
                inFlightRequestIDs.remove(request.recordID)
                replayRetention.recordHandled(
                    recordName: recordName,
                    requestCreatedAt: requestCreatedAt)
                await deleteBestEffort([request.recordID])
                continue
            } catch LocalComputerUseCloudPairingError.invalidRecord {
                inFlightRequestIDs.remove(request.recordID)
                replayRetention.recordHandled(
                    recordName: recordName,
                    requestCreatedAt: requestCreatedAt)
                await deleteBestEffort([request.recordID])
                continue
            } catch LocalComputerUseCloudPairingError.accountMismatch {
                inFlightRequestIDs.remove(request.recordID)
                replayRetention.recordHandled(
                    recordName: recordName,
                    requestCreatedAt: requestCreatedAt)
                await deleteBestEffort([request.recordID])
                continue
            } catch {
                inFlightRequestIDs.remove(request.recordID)
                throw error
            }

            do {
                try Task.checkCancellation()
                // Check as close as possible to the durable write. A second
                // check below removes a response if the account changes while
                // CloudKit is saving it.
                try await ensureCurrentAccount(matches: accountBinding)
            } catch {
                inFlightRequestIDs.remove(request.recordID)
                throw error
            }

            // Persist the prospective ID before the save. CloudKit may commit
            // a write even when the client observes cancellation or a lost
            // server response; pre-tracking makes that ambiguous outcome
            // eligible for immediate and next-startup cleanup.
            guard await trackOwnedPairingRecord(response) else {
                inFlightRequestIDs.remove(request.recordID)
                // Do not create another CloudKit response unless its exact ID
                // is durably tracked. The request remains retryable after the
                // cleanup backlog can be reduced.
                throw LocalComputerUseCloudPairingError
                    .recordRetentionUnavailable
            }
            // The bounded tracker can await cleanup. Bind every retry to the
            // same Apple Account immediately before CloudKit sees the write.
            do {
                try await ensureCurrentAccount(matches: accountBinding)
            } catch {
                await cleanupTrackedResponseIDs([response.recordID])
                inFlightRequestIDs.remove(request.recordID)
                throw error
            }
            var createdResponse = false
            do {
                _ = try await retryingCloudKit {
                    try await ensureCurrentAccount(matches: accountBinding)
                    try await database.save(response)
                }
                createdResponse = true
            } catch let cloudKit as CKError where
                cloudKit.code == .serverRecordChanged {
                // The deterministic response ID proves that this request
                // already has a durable response. Treat the save conflict as
                // a replay, keep tracking that existing record, and do not
                // report a second response.
            } catch {
                // A transient or exhausted save must remain retryable. Actor
                // reentrancy cannot start a duplicate response while the save
                // is in flight, and only a durable response becomes handled.
                await cleanupTrackedResponseIDs([response.recordID])
                inFlightRequestIDs.remove(request.recordID)
                throw error
            }

            do {
                try Task.checkCancellation()
                try await ensureCurrentAccount(matches: accountBinding)
            } catch {
                await cleanupTrackedResponseIDs([response.recordID])
                inFlightRequestIDs.remove(request.recordID)
                throw error
            }

            inFlightRequestIDs.remove(request.recordID)
            replayRetention.recordHandled(
                recordName: recordName,
                requestCreatedAt: requestCreatedAt)
            if createdResponse { responseCount += 1 }
            await deleteBestEffort([request.recordID])
        }
        return responseCount
    }

    /// Best-effort terminal hook for an owner which can await pairing cleanup.
    /// If CloudKit is unavailable, entries stay persisted for a later host run.
    func shutdown() async {
        scheduledResponseCleanupTask?.cancel()
        scheduledResponseCleanupTask = nil
        guard let responseLifecycle else { return }
        let ids = responseLifecycle.recordsForShutdownCleanup().map {
            CKRecord.ID(recordName: $0)
        }
        await cleanupTrackedResponseIDs(ids)
    }

    private let containerIdentifier: String
    private let senderID: String
    private let startedAt: Date
    private let clock: @Sendable () -> Date
    private let responseStore: any LocalComputerUsePairingResponseStore
    private var replayRetention: LocalComputerUsePairingReplayRetention
    private var inFlightRequestIDs: Set<CKRecord.ID> = []
    private var responseLifecycleNamespace: String?
    private var responseLifecycleAccountBinding: CloudKitAccountBinding?
    private var responseLifecycle: LocalComputerUsePairingResponseLifecycle?
    private var scheduledResponseCleanupTask: Task<Void, Never>?
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

    private static func isValidRequestTimestamp(
        _ createdAt: Date?,
        observedAt: Date
    ) -> Bool {
        guard let createdAt else { return false }
        let age = observedAt.timeIntervalSince(createdAt)
        return age >= -clockSkewSeconds && age <= staleSeconds
    }

    private func prepareResponseLifecycle(
        accountBinding: CloudKitAccountBinding
    ) async throws {
        if let expected = responseLifecycleAccountBinding {
            guard expected == accountBinding else {
                throw LocalComputerUseCloudPairingError.accountMismatch
            }
            guard responseLifecycle != nil else {
                throw LocalComputerUseCloudPairingError
                    .recordRetentionUnavailable
            }
            return
        }
        let namespace = Self.responseNamespace(
            containerIdentifier: containerIdentifier,
            senderID: senderID,
            accountBinding: accountBinding)
        guard responseLifecycleNamespace != namespace else { return }

        let lifecycle = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: Self.staleSeconds,
            maximumEntries: Self.maximumTrackedResponses,
            clock: clock,
            store: responseStore)
        responseLifecycleNamespace = namespace
        responseLifecycleAccountBinding = accountBinding
        responseLifecycle = lifecycle

        // An older build or interrupted writer may have left more entries than
        // the current ceiling. Keep every identity persisted until CloudKit
        // confirms its deletion; failed and partial deletes retry on shutdown or
        // the next startup.
        let overflowIDs = lifecycle.restorationOverflowRecordNames.map {
            CKRecord.ID(recordName: $0)
        }
        await cleanupTrackedResponseIDs(overflowIDs)
    }

    private func cleanupExpiredTrackedResponses() async {
        guard let responseLifecycle else { return }
        let ids = responseLifecycle.recordsDueForCleanup().map {
            CKRecord.ID(recordName: $0)
        }
        await cleanupTrackedResponseIDs(ids)
        scheduleResponseCleanup()
    }

    private func trackOwnedPairingRecord(_ record: CKRecord) async -> Bool {
        while var lifecycle = responseLifecycle {
            switch lifecycle.track(
                recordName: record.recordID.recordName,
                responseCreatedAt: record["createdAt"] as? Date ?? clock()
            ) {
            case .tracked:
                responseLifecycle = lifecycle
                scheduleResponseCleanup()
                return true

            case .cleanupRequired(let recordNames):
                responseLifecycle = lifecycle
                guard !recordNames.isEmpty else { return false }
                let ids = recordNames.map { CKRecord.ID(recordName: $0) }
                let cleaned = await cleanupTrackedResponseIDs(ids)
                guard cleaned.count == ids.count else {
                    scheduleResponseCleanup()
                    return false
                }
                // Re-read the actor-owned lifecycle after the awaited delete;
                // another request may have used the newly freed slot.
                continue

            case .retentionUnavailable:
                responseLifecycle = lifecycle
                return false
            }
        }
        return false
    }

    private func cleanupOwnedRequestAndPeerResponses(
        requestID: CKRecord.ID,
        responseIDs: [CKRecord.ID]
    ) async {
        // This client created and durably tracks the request. The host owns and
        // tracks response IDs, so deleting those here is only an optimization;
        // a failed peer-response delete cannot erase the host's retry identity.
        await cleanupTrackedResponseIDs([requestID])
        await deleteBestEffort(responseIDs)
    }

    @discardableResult
    private func cleanupTrackedResponseIDs(
        _ ids: [CKRecord.ID]
    ) async -> Set<CKRecord.ID> {
        let cleaned = await deleteBestEffort(ids)
        guard !cleaned.isEmpty, var lifecycle = responseLifecycle else {
            return cleaned
        }
        do {
            try await ensureResponseLifecycleAccountCurrent()
        } catch {
            // Deletion may have completed as the account transitioned. Keep
            // the durable IDs so the original account can confirm them later.
            return []
        }
        guard lifecycle.markCleaned(
            recordNames: cleaned.map(\.recordName)
        ) else {
            responseLifecycle = lifecycle
            return []
        }
        responseLifecycle = lifecycle
        return cleaned
    }

    /// Keeps this short-lived actor alive only until its next response expiry.
    /// This closes the common stop/restart edge even when cancellation arrives
    /// between polling calls and the owner cannot explicitly await `shutdown`.
    /// A process exit still relies on the persisted next-startup cleanup path.
    private func scheduleResponseCleanup() {
        scheduledResponseCleanupTask?.cancel()
        guard let nextCleanupDate = responseLifecycle?.nextCleanupDate else {
            scheduledResponseCleanupTask = nil
            return
        }
        let remaining = nextCleanupDate.timeIntervalSince(clock())
        // Failed due deletions retry gently instead of creating a tight loop.
        let delay = max(remaining, remaining <= 0 ? 30 : 0)
        scheduledResponseCleanupTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await runScheduledResponseCleanup()
        }
    }

    private func runScheduledResponseCleanup() async {
        scheduledResponseCleanupTask = nil
        await cleanupExpiredTrackedResponses()
    }

    private static func responseNamespace(
        containerIdentifier: String,
        senderID: String,
        accountBinding: CloudKitAccountBinding
    ) -> String {
        let material = Data(
            "RemoteDesktop.CloudKitLocalPairing.responses.v1\n\(containerIdentifier)\n\(senderID)\n\(accountBinding.rawValue)"
                .utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func ensureCurrentAccount(
        matches expected: CloudKitAccountBinding
    ) async throws {
        do {
            try CloudKitEntitlements.validate(
                containerIdentifier: containerIdentifier)
            let status = try await retryingCloudKit {
                try await container.accountStatus()
            }
            if let statusError = CloudKitAccountBinding.resolutionError(
                for: status) {
                throw statusError
            }
            let userRecordID = try await retryingCloudKit {
                try await container.userRecordID()
            }
            let current = try CloudKitAccountBinding.derived(
                containerIdentifier: containerIdentifier,
                userRecordName: userRecordID.recordName)
            guard current == expected else {
                throw LocalComputerUseCloudPairingError.accountMismatch
            }
        } catch {
            throw Self.userFacingError(error)
        }
    }

    private func records(
        targetedTo targetID: String,
        since: Date
    ) async throws -> [CKRecord] {
        let predicate = NSPredicate(
            format: "targetID == %@ AND createdAt > %@",
            targetID,
            since as NSDate)
        let query = CKQuery(
            recordType: CloudKitComputerUseChannel.recordType,
            predicate: predicate)
        query.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
        ]
        let desiredKeys = [
            "senderID", "targetID", "pairingCode", "kind", "payload",
            "createdAt",
        ]
        var accumulator = LocalComputerUsePairingRecordAccumulator<CKRecord>(
            maximumObservedRecords: Self.maximumQueryRecords,
            maximumPages: Self.maximumQueryPages)
        do {
            var page = try await retryingCloudKit {
                try await database.records(
                    matching: query,
                    inZoneWith: nil,
                    desiredKeys: desiredKeys,
                    resultsLimit: 100)
            }
            var successfulRecords = try Self.successfulRecords(
                from: page.matchResults)
            try accumulator.append(
                successfulRecords,
                observedRecordCount: page.matchResults.count,
                hasMore: page.queryCursor != nil)
            while let cursor = page.queryCursor {
                page = try await retryingCloudKit {
                    try await database.records(
                        continuingMatchFrom: cursor,
                        desiredKeys: desiredKeys,
                        resultsLimit: 100)
                }
                successfulRecords = try Self.successfulRecords(
                    from: page.matchResults)
                try accumulator.append(
                    successfulRecords,
                    observedRecordCount: page.matchResults.count,
                    hasMore: page.queryCursor != nil)
            }
            return accumulator.records.sorted(by: Self.recordPrecedes)
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    @discardableResult
    private func deleteBestEffort(
        _ ids: [CKRecord.ID]
    ) async -> Set<CKRecord.ID> {
        let uniqueIDs = Set(ids).sorted {
            $0.recordName < $1.recordName
        }
        guard !uniqueIDs.isEmpty else { return [] }
        guard responseLifecycleAccountBinding != nil else { return [] }
        var cleaned: Set<CKRecord.ID> = []

        // CloudKit may reject very large modify operations. Small batches also
        // make partial-failure retry bookkeeping exact and bounded.
        for start in stride(from: 0, to: uniqueIDs.count, by: 100) {
            do {
                try await ensureResponseLifecycleAccountCurrent()
            } catch {
                return []
            }
            let end = min(start + 100, uniqueIDs.count)
            let batch = Array(uniqueIDs[start..<end])
            let operation = CKModifyRecordsOperation(
                recordsToSave: nil,
                recordIDsToDelete: batch)
            operation.savePolicy = .allKeys
            operation.isAtomic = false
            let result: Result<Void, Error> = await withCheckedContinuation {
                continuation in
                operation.modifyRecordsResultBlock = { result in
                    continuation.resume(returning: result)
                }
                database.add(operation)
            }
            do {
                try await ensureResponseLifecycleAccountCurrent()
            } catch {
                return []
            }
            switch result {
            case .success:
                cleaned.formUnion(batch)
            case .failure(let error):
                let cloudKit = error as? CKError
                if cloudKit?.code == .unknownItem {
                    cleaned.formUnion(batch)
                    continue
                }
                guard cloudKit?.code == .partialFailure,
                      let failures = cloudKit?.partialErrorsByItemID else {
                    continue
                }
                for id in batch {
                    guard let failure = failures[id] else {
                        cleaned.insert(id)
                        continue
                    }
                    if (failure as? CKError)?.code == .unknownItem {
                        cleaned.insert(id)
                    }
                }
            }
        }
        return cleaned
    }

    private func ensureResponseLifecycleAccountCurrent() async throws {
        guard let expected = responseLifecycleAccountBinding else {
            throw LocalComputerUseCloudPairingError
                .recordRetentionUnavailable
        }
        try await ensureCurrentAccount(matches: expected)
    }

    nonisolated static func successfulRecords(
        from matchResults: [
            (CKRecord.ID, Result<CKRecord, Error>)
        ]
    ) throws -> [CKRecord] {
        try matchResults.map { _, result in
            switch result {
            case .success(let record):
                return record
            case .failure(let error):
                throw error
            }
        }
    }

    nonisolated static func recordPrecedes(
        _ left: CKRecord,
        _ right: CKRecord
    ) -> Bool {
        let leftCreatedAt = left["createdAt"] as? Date ?? .distantPast
        let rightCreatedAt = right["createdAt"] as? Date ?? .distantPast
        if leftCreatedAt != rightCreatedAt {
            return leftCreatedAt < rightCreatedAt
        }
        if left.recordID.recordName != right.recordID.recordName {
            return left.recordID.recordName < right.recordID.recordName
        }
        let leftSender = left["senderID"] as? String ?? ""
        let rightSender = right["senderID"] as? String ?? ""
        return leftSender < rightSender
    }

    private func retryingCloudKit<Value>(
        _ operation: () async throws -> Value
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

    private static func isTransientCloudKitError(_ error: Error) -> Bool {
        guard let cloudKit = error as? CKError else { return false }
        switch cloudKit.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }

    private static func userFacingError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let pairing = error as? LocalComputerUseCloudPairingError {
            return pairing
        }
        if let resolution = error
            as? CloudKitAccountBindingResolutionError {
            switch resolution {
            case .noAccount, .restricted:
                return LocalComputerUseCloudPairingError
                    .iCloudAccountUnavailable
            case .temporarilyUnavailable, .couldNotDetermine:
                return LocalComputerUseCloudPairingError.transport(
                    resolution.localizedDescription)
            }
        }
        if let cloudKit = error as? CKError,
           cloudKit.code == .notAuthenticated {
            return LocalComputerUseCloudPairingError.iCloudAccountUnavailable
        }
        return LocalComputerUseCloudPairingError.transport(
            error.localizedDescription)
    }
}

enum LocalComputerUseCloudPairingError: Error, Equatable, LocalizedError {
    case invalidIdentity
    case invalidRecord
    case requestNotForHost
    case credentialMismatch
    case accountMismatch
    case queryLimitExceeded
    case recordRetentionUnavailable
    case timedOut
    case iCloudAccountUnavailable
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity, .invalidRecord, .requestNotForHost:
            return "The automatic local AI pairing response was invalid."
        case .credentialMismatch:
            return "The Mac changed its local AI identity. Waiting for its refreshed iCloud advertisement."
        case .accountMismatch:
            return "The Apple Account changed while automatic local AI pairing was in progress. Refresh devices and try again."
        case .queryLimitExceeded:
            return "Automatic local AI pairing found too many pending iCloud records and stopped safely. Keep both apps open while they clean up, then try again."
        case .recordRetentionUnavailable:
            return "Automatic local AI pairing is waiting for iCloud cleanup before it can create another record. Keep both apps open and try again shortly."
        case .timedOut:
            return "Automatic local AI pairing is taking longer than expected. Keep Remote Desktop Host open on the Mac."
        case .iCloudAccountUnavailable:
            return "Sign into the same Apple Account on this device and the Mac to pair local AI automatically."
        case .transport(let detail):
            return "Automatic local AI pairing could not reach iCloud: \(detail)"
        }
    }
}

/// Pure wire and cryptographic policy, split from CloudKit I/O so malformed,
/// tampered, cross-host, and replay cases can be exercised deterministically.
enum LocalComputerUseCloudPairingWire {
    struct RequestContext {
        let requestID: String
        let clientID: String
        let hostID: String
        let pairingCode: String
        let expectedCredentialID: String
        let accountBinding: CloudKitAccountBinding
        let createdAt: Date
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let record: CKRecord
    }

    private struct RequestPayload: Codable {
        let version: Int
        let requestID: String
        let expectedCredentialID: String
        let accountBinding: String
        let clientPublicKey: String
    }

    private struct ResponsePayload: Codable {
        let version: Int
        let requestID: String
        let credentialID: String
        let accountBinding: String
        let hostPublicKey: String
        let sealedCredential: String
    }

    static func makeRequest(
        clientID: String,
        hostID: String,
        pairingCode: String,
        expectedCredentialID: String,
        accountBinding: CloudKitAccountBinding,
        requestID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> RequestContext {
        guard isCanonicalUUID(clientID),
              isCanonicalUUID(hostID),
              isCanonicalUUID(requestID),
              isPairingCode(pairingCode),
              isCredentialID(expectedCredentialID) else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let payload = RequestPayload(
            version: 2,
            requestID: requestID,
            expectedCredentialID: expectedCredentialID,
            accountBinding: accountBinding.rawValue,
            clientPublicKey: privateKey.publicKey.rawRepresentation
                .base64EncodedString())
        let record = CKRecord(
            recordType: CloudKitComputerUseChannel.recordType,
            recordID: CKRecord.ID(
                recordName: "WebRTCSignal-LocalCredentialRequest-\(requestID)"))
        record["senderID"] = clientID as CKRecordValue
        record["targetID"] = hostID as CKRecordValue
        record["pairingCode"] = pairingCode as CKRecordValue
        record["kind"] = CloudKitLocalComputerUsePairing.requestKind
            as CKRecordValue
        record["payload"] = try encoded(payload) as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        return RequestContext(
            requestID: requestID,
            clientID: clientID,
            hostID: hostID,
            pairingCode: pairingCode,
            expectedCredentialID: expectedCredentialID,
            accountBinding: accountBinding,
            createdAt: createdAt,
            privateKey: privateKey,
            record: record)
    }

    static func makeResponse(
        to record: CKRecord,
        hostID: String,
        pairingCode: String,
        credential: LocalComputerUseCredential,
        accountBinding: CloudKitAccountBinding,
        responseID: String? = nil,
        createdAt: Date = Date()
    ) throws -> CKRecord {
        guard isCanonicalUUID(hostID),
              isPairingCode(pairingCode),
              kind(of: record) == CloudKitLocalComputerUsePairing.requestKind,
              let clientID = record["senderID"] as? String,
              record["targetID"] as? String == hostID,
              record["pairingCode"] as? String == pairingCode else {
            throw LocalComputerUseCloudPairingError.requestNotForHost
        }
        guard isCanonicalUUID(clientID),
              let payload: RequestPayload = decoded(record),
              payload.version == 2,
              isCanonicalUUID(payload.requestID),
              let requestedAccountBinding = CloudKitAccountBinding(
                rawValue: payload.accountBinding),
              let clientPublicData = canonicalBase64(
                payload.clientPublicKey,
                byteCount: 32) else {
            if let payload: RequestPayload = decoded(record),
               payload.expectedCredentialID != credential.credentialID {
                throw LocalComputerUseCloudPairingError.credentialMismatch
            }
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
        guard requestedAccountBinding == accountBinding else {
            throw LocalComputerUseCloudPairingError.accountMismatch
        }
        guard payload.expectedCredentialID == credential.credentialID else {
            throw LocalComputerUseCloudPairingError.credentialMismatch
        }
        guard record.recordID.recordName ==
            "WebRTCSignal-LocalCredentialRequest-\(payload.requestID)" else {
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
        // The request UUID is the default response UUID. A replay therefore
        // targets the same CloudKit record and cannot create a second durable
        // response even after bounded in-memory retention is evicted or the
        // host restarts. Explicit IDs remain supported for wire fixtures.
        let resolvedResponseID = responseID ?? payload.requestID
        guard isCanonicalUUID(resolvedResponseID) else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }

        let clientPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            clientPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: clientPublicData)
        } catch {
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
        let hostPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let aad = try contextData(
            requestID: payload.requestID,
            clientID: clientID,
            hostID: hostID,
            pairingCode: pairingCode,
            credentialID: credential.credentialID,
            accountBinding: accountBinding)
        let key = try derivedKey(
            privateKey: hostPrivateKey,
            peerPublicKey: clientPublicKey,
            context: aad)
        let sealed = try AES.GCM.seal(
            credential.rawKey,
            using: key,
            authenticating: aad)
        guard let combined = sealed.combined else {
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
        let responsePayload = ResponsePayload(
            version: 2,
            requestID: payload.requestID,
            credentialID: credential.credentialID,
            accountBinding: accountBinding.rawValue,
            hostPublicKey: hostPrivateKey.publicKey.rawRepresentation
                .base64EncodedString(),
            sealedCredential: combined.base64EncodedString())
        let response = CKRecord(
            recordType: CloudKitComputerUseChannel.recordType,
            recordID: CKRecord.ID(
                recordName:
                    "WebRTCSignal-LocalCredentialResponse-\(resolvedResponseID)"))
        response["senderID"] = hostID as CKRecordValue
        response["targetID"] = clientID as CKRecordValue
        response["pairingCode"] = pairingCode as CKRecordValue
        response["kind"] = CloudKitLocalComputerUsePairing.responseKind
            as CKRecordValue
        response["payload"] = try encoded(responsePayload) as CKRecordValue
        response["createdAt"] = createdAt as CKRecordValue
        return response
    }

    static func openResponse(
        _ record: CKRecord,
        request: RequestContext
    ) throws -> LocalComputerUseCredential {
        guard kind(of: record) == CloudKitLocalComputerUsePairing.responseKind,
              record["senderID"] as? String == request.hostID,
              record["targetID"] as? String == request.clientID,
              record["pairingCode"] as? String == request.pairingCode,
              let payload: ResponsePayload = decoded(record),
              payload.version == 2,
              payload.requestID == request.requestID,
              payload.credentialID == request.expectedCredentialID,
              let responseAccountBinding = CloudKitAccountBinding(
                rawValue: payload.accountBinding),
              let hostPublicData = canonicalBase64(
                payload.hostPublicKey,
                byteCount: 32),
              let sealedData = canonicalBase64(
                payload.sealedCredential,
                byteCount: nil) else {
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
        guard responseAccountBinding == request.accountBinding else {
            throw LocalComputerUseCloudPairingError.accountMismatch
        }

        do {
            let hostPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: hostPublicData)
            let aad = try contextData(
                requestID: request.requestID,
                clientID: request.clientID,
                hostID: request.hostID,
                pairingCode: request.pairingCode,
                credentialID: request.expectedCredentialID,
                accountBinding: request.accountBinding)
            let key = try derivedKey(
                privateKey: request.privateKey,
                peerPublicKey: hostPublicKey,
                context: aad)
            let box = try AES.GCM.SealedBox(combined: sealedData)
            let rawKey = try AES.GCM.open(
                box,
                using: key,
                authenticating: aad)
            let credential = try LocalComputerUseCredential(rawKey: rawKey)
            guard credential.credentialID == request.expectedCredentialID else {
                throw LocalComputerUseCloudPairingError.credentialMismatch
            }
            return credential
        } catch let pairing as LocalComputerUseCloudPairingError {
            throw pairing
        } catch {
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
    }

    static func kind(of record: CKRecord) -> String? {
        record["kind"] as? String
    }

    static func responseRequestID(from record: CKRecord) -> String? {
        let payload: ResponsePayload? = decoded(record)
        return payload?.requestID
    }

    private static func contextData(
        requestID: String,
        clientID: String,
        hostID: String,
        pairingCode: String,
        credentialID: String,
        accountBinding: CloudKitAccountBinding
    ) throws -> Data {
        guard isCanonicalUUID(requestID),
              isCanonicalUUID(clientID),
              isCanonicalUUID(hostID),
              isPairingCode(pairingCode),
              isCredentialID(credentialID) else {
            throw LocalComputerUseCloudPairingError.invalidIdentity
        }
        return Data(
            "RemoteDesktop.localCredential.v2\n\(requestID)\n\(clientID)\n\(hostID)\n\(pairingCode)\n\(credentialID)\n\(accountBinding.rawValue)"
                .utf8)
    }

    private static func derivedKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        context: Data
    ) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(
            with: peerPublicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("RemoteDesktop.CloudKitPairing.v2".utf8),
            sharedInfo: context,
            outputByteCount: 32)
    }

    private static func encoded<Value: Encodable>(
        _ value: Value
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalComputerUseCloudPairingError.invalidRecord
        }
        return string
    }

    private static func decoded<Value: Decodable>(
        _ record: CKRecord
    ) -> Value? {
        guard let string = record["payload"] as? String,
              string.utf8.count <= 4_096,
              let data = string.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func canonicalBase64(
        _ value: String,
        byteCount: Int?
    ) -> Data? {
        guard value.utf8.count <= 512,
              let data = Data(base64Encoded: value),
              data.base64EncodedString() == value,
              byteCount == nil || data.count == byteCount else {
            return nil
        }
        return data
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString == value.uppercased()
    }

    private static func isPairingCode(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy(\.isNumber)
    }

    private static func isCredentialID(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x61 && byte <= 0x66)
            }
    }
}
