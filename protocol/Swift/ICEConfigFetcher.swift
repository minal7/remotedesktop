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
    public let updatedAt: Date?

    public init(
        stunURLs: [String],
        updatedAt: Date? = nil
    ) {
        self.stunURLs = stunURLs
        self.updatedAt = updatedAt
    }

    /// Baked-in fallback. Keep short and well-known — these are only
    /// used when the Public DB fetch fails.
    public static let fallback = ICEConfig(
        stunURLs: [
            "stun:stun.l.google.com:19302",
            "stun:stun.cloudflare.com:3478",
        ],
        updatedAt: nil)
}

private struct ICEConfigFetchTimedOut: Error, LocalizedError {
    var errorDescription: String? {
        "ICEConfig fetch timed out."
    }
}

private final class ICEConfigContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

public actor ICEConfigFetcher {
    private enum Source: String {
        case cloudKit = "cloudkit"
        case fallbackUnavailable = "fallback_unavailable"
        case fallbackEmpty = "fallback_empty_stun"
        case fallbackFetchFailure = "fallback_fetch_failure"
    }

    private struct FetchedConfig {
        let config: ICEConfig
        let source: Source
    }

    public init(containerIdentifier: String, recordName: String = "default") {
        self.containerIdentifier = containerIdentifier
        self.recordID = CKRecord.ID(recordName: recordName)
    }

    /// Fetches the `ICEConfig` record. Returns `ICEConfig.fallback` on
    /// any error so callers always get a usable config. The first
    /// successful fetch in a process lifetime is memoized.
    public func get() async -> ICEConfig {
        if let cached {
            logConfiguration(cached, reused: true)
            return cached.config
        }
        let fetched = await fetchOrFallback()
        cached = fetched
        logConfiguration(fetched, reused: false)
        return fetched.config
    }

    /// Clears the cached config so the next `get()` re-fetches from
    /// CloudKit. Call when the network topology changes (e.g. VPN
    /// connect/disconnect, Wi-Fi → cellular handoff) and the cached
    /// STUN list may no longer be appropriate.
    public func reset() {
        cached = nil
    }

    // MARK: Internals

    private let containerIdentifier: String
    private let recordID: CKRecord.ID
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.signaling", category: "ice-config")
    private var cached: FetchedConfig?
    private var container: CKContainer?
    private var database: CKDatabase?

    private func logConfiguration(_ fetched: FetchedConfig, reused: Bool) {
        let config = fetched.config
        log.notice("ICE configuration source=\(fetched.source.rawValue, privacy: .public) cached=\(reused, privacy: .public) stun_count=\(config.stunURLs.count, privacy: .public)")
    }

    private func fetchOrFallback() async -> FetchedConfig {
        let database: CKDatabase
        do {
            database = try publicDatabase()
        } catch {
            log.info("ICEConfig fetch skipped because CloudKit is unavailable; using fallback")
            return .init(config: .fallback, source: .fallbackUnavailable)
        }

        // Cap the fetch at 3 s. This uses a callback-based CloudKit wrapper
        // so the timeout can resume even if CloudKit's async bridge stalls.
        do {
            let record = try await fetchRecordWithTimeout(
                withID: recordID,
                from: database,
                timeout: 3)
            guard let config = Self.config(from: record) else {
                log.info("ICEConfig record present but stunURLs empty; using fallback")
                return .init(config: .fallback, source: .fallbackEmpty)
            }
            return .init(config: config, source: .cloudKit)
        } catch {
            log.info("ICEConfig fetch failed; using fallback")
            return .init(config: .fallback, source: .fallbackFetchFailure)
        }
    }

    static func config(from record: CKRecord) -> ICEConfig? {
        let urls = (record["stunURLs"] as? [String]) ?? []
        guard !urls.isEmpty else { return nil }
        let updatedAt = record["updatedAt"] as? Date
        return ICEConfig(stunURLs: urls, updatedAt: updatedAt)
    }

    private func fetchRecordWithTimeout(
        withID recordID: CKRecord.ID,
        from database: CKDatabase,
        timeout: TimeInterval
    ) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            let box = ICEConfigContinuationBox(continuation)
            database.fetch(withRecordID: recordID) { record, error in
                if let record {
                    box.resume(with: .success(record))
                } else if let error {
                    box.resume(with: .failure(error))
                } else {
                    box.resume(with: .failure(ICEConfigFetchTimedOut()))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(with: .failure(ICEConfigFetchTimedOut()))
            }
        }
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
