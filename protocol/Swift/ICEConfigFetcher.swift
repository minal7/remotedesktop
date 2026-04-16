import CloudKit
import Foundation
import os

/// Fetches the single well-known `ICEConfig` record from the CloudKit
/// **Public DB**. One record, `recordName == "default"`, holds the STUN
/// URL list the clients use. Editing this one record in the Dashboard
/// rotates STUN providers for every user — no code change, no release.
///
/// ## Why Public DB
/// The STUN list is the same for every user on the planet. Putting it
/// in the Public DB means one source of truth that any signed-in
/// CloudKit client can read without us operating a server.
///
/// ## Fallback
/// If the fetch fails (offline, record missing, schema not yet promoted)
/// we fall back to a small hardcoded list so first-run and offline dev
/// still work. The Dashboard record is authoritative when reachable.
public struct ICEConfig: Sendable, Equatable {
    public let stunURLs: [String]
    public let turnURLs: [String]
    public let turnUsername: String?
    public let turnCredential: String?
    public let updatedAt: Date?

    public init(
        stunURLs: [String],
        turnURLs: [String] = [],
        turnUsername: String? = nil,
        turnCredential: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.stunURLs = stunURLs
        self.turnURLs = turnURLs
        self.turnUsername = turnUsername
        self.turnCredential = turnCredential
        self.updatedAt = updatedAt
    }

    /// Baked-in fallback. Keep short and well-known — these are only
    /// used when the Public DB fetch fails. STUN-only; TURN requires
    /// credentials from the CloudKit record.
    public static let fallback = ICEConfig(
        stunURLs: [
            "stun:stun.l.google.com:19302",
            "stun:stun.cloudflare.com:3478",
        ],
        updatedAt: nil)
}

public actor ICEConfigFetcher {
    public init(containerIdentifier: String, recordName: String = "default") {
        self.containerIdentifier = containerIdentifier
        self.recordID = CKRecord.ID(recordName: recordName)
    }

    /// Fetches the `ICEConfig` record. Returns `ICEConfig.fallback` on
    /// any error so callers always get a usable config. The first
    /// successful fetch in a process lifetime is memoized.
    public func get() async -> ICEConfig {
        if let cached { return cached }
        let config = await fetchOrFallback()
        cached = config
        return config
    }

    // MARK: Internals

    private let containerIdentifier: String
    private let recordID: CKRecord.ID
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.signaling", category: "ice-config")
    private var cached: ICEConfig?
    private var container: CKContainer?
    private var database: CKDatabase?

    private func fetchOrFallback() async -> ICEConfig {
        let database: CKDatabase
        do {
            database = try publicDatabase()
        } catch {
            log.info("ICEConfig fetch skipped because CloudKit isn't available (\(String(describing: error), privacy: .public)); using fallback")
            return .fallback
        }

        // Cap the fetch at 3 s — CloudKit without entitlements (unit tests,
        // simulator without iCloud) can otherwise block indefinitely. The
        // fallback list is fine on a cold start; the authoritative record
        // will be picked up on the next session.
        let result = await withTaskGroup(of: ICEConfig?.self) { group -> ICEConfig? in
            group.addTask { [database, recordID, log] in
                do {
                    let record = try await database.record(for: recordID)
                    let urls = (record["stunURLs"] as? [String]) ?? []
                    guard !urls.isEmpty else {
                        log.info("ICEConfig record present but stunURLs empty; using fallback")
                        return nil
                    }
                    let turnURLs = (record["turnURLs"] as? [String]) ?? []
                    let turnUsername = record["turnUsername"] as? String
                    let turnCredential = record["turnCredential"] as? String
                    let updatedAt = record["updatedAt"] as? Date
                    return ICEConfig(
                        stunURLs: urls,
                        turnURLs: turnURLs,
                        turnUsername: turnUsername,
                        turnCredential: turnCredential,
                        updatedAt: updatedAt)
                } catch {
                    log.info("ICEConfig fetch failed (\(String(describing: error), privacy: .public)); using fallback")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value ?? nil
        }
        return result ?? .fallback
    }

    private func publicDatabase() throws -> CKDatabase {
        try CloudKitEntitlements.validate(containerIdentifier: containerIdentifier)

        if let database {
            return database
        }

        let container = CKContainer(identifier: containerIdentifier)
        let database = container.publicCloudDatabase
        self.container = container
        self.database = database
        return database
    }
}
