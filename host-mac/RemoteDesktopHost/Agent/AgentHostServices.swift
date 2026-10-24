import AppKit
import CryptoKit
import Darwin
import Foundation

struct AgentRegisteredApp: Equatable {
    let bundleID: String
    let url: URL
}

@MainActor
final class AgentAppRegistry {
    struct Record: Equatable {
        let displayName: String
        let bundleID: String
        let url: URL
    }

    enum Failure: Error { case invalidName, notFound, ambiguous, invalidApp, launchFailed }
    typealias OpenHandler = @MainActor (URL) async throws -> Void

    private let records: [Record]
    private let openHandler: OpenHandler?

    init(records: [Record]? = nil, openHandler: OpenHandler? = nil) {
        self.records = records ?? Self.discoverInstalledApps(roots: Self.defaultSearchRoots)
        self.openHandler = openHandler
    }

    init(searchRoots: [URL], openHandler: OpenHandler? = nil) {
        records = Self.discoverInstalledApps(roots: searchRoots)
        self.openHandler = openHandler
    }

    func resolve(_ name: String) throws -> AgentRegisteredApp {
        let query = Self.normalized(name)
        guard !query.isEmpty else { throw Failure.invalidName }
        let matches = records.filter {
            Self.normalized($0.displayName) == query || Self.normalized($0.bundleID) == query
        }
        guard !matches.isEmpty else { throw Failure.notFound }
        guard matches.count == 1 else { throw Failure.ambiguous }
        let app = matches[0]
        guard !app.bundleID.isEmpty, app.url.isFileURL, app.url.pathExtension == "app" else {
            throw Failure.invalidApp
        }
        return AgentRegisteredApp(bundleID: app.bundleID, url: app.url.standardizedFileURL)
    }

    func open(_ app: AgentRegisteredApp) async throws {
        guard records.contains(where: {
            Self.normalized($0.bundleID) == Self.normalized(app.bundleID)
                && $0.url.standardizedFileURL == app.url.standardizedFileURL
        }), Self.bundleID(at: app.url) == app.bundleID else { throw Failure.invalidApp }
        if let openHandler { try await openHandler(app.url); return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static var defaultSearchRoots: [URL] { [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ] }

    private static func discoverInstalledApps(roots: [URL]) -> [Record] {
        var urls: [URL] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if urls.count >= 4_096 { break }
                guard url.pathExtension == "app", let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { continue }
                urls.append(url)
            }
        }
        return urls.compactMap { url in
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
            let displayName = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return Record(displayName: displayName, bundleID: bundleID, url: url)
        }
    }

    private static func bundleID(at url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }
}

@MainActor
final class HostAgentAllowPolicy: AgentAllowPolicy {
    private let registry: AgentAppRegistry

    init(registry: AgentAppRegistry) { self.registry = registry }

    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision {
        switch action {
        case .openApp(let name):
            do { _ = try registry.resolve(name); return .allowed }
            catch AgentAppRegistry.Failure.ambiguous { return .denied("The requested app name is ambiguous.") }
            catch { return .denied("The requested app is not installed or could not be resolved.") }
        case .openURL(let url):
            return Self.isAllowedURL(url) ? .allowed : .denied("Only safe HTTP or HTTPS destinations are allowed.")
        default:
            return .allowed
        }
    }

    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? {
        switch action {
        case let .openApp(name):
            guard let app = try? registry.resolve(name) else { return nil }
            return AgentTrustIdentity(kind: .app, identity: app.bundleID)
        case let .openURL(url):
            guard Self.isAllowedURL(url), let origin = Self.origin(for: url) else { return nil }
            return AgentTrustIdentity(kind: .web, identity: origin)
        default:
            return nil
        }
    }

    static func isAllowedURL(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopback(host)
    }

    private static func origin(for value: String) -> String? {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              let rawHost = parts.host?.lowercased() else { return nil }
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let defaultPort = scheme == "https" ? 443 : 80
        let port = parts.port.flatMap { $0 == defaultPort ? nil : $0 }.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
        var ipv4 = in_addr()
        if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return (UInt32(bigEndian: ipv4.s_addr) >> 24) == 127
        }
        var ipv6 = in6_addr()
        if normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                bytes.count == 16 && bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            }
        }
        return false
    }
}

@MainActor
final class PersistentAgentTrustStore: AgentTrustStore {
    private static let promptDigest = PersistentAgentTrustStore.digest("agent-trust-v1")
    private let store: ComputerUseTaskJournalStore

    init(directory: URL) throws { store = try ComputerUseTaskJournalStore(directory: directory) }

    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool {
        let id = Self.taskID(kind: kind, identity: identity)
        guard let journal = try store.load(taskID: id) else { return false }
        guard Self.valid(journal, kind: kind, identity: identity) else {
            throw ComputerUseTaskJournalStore.StoreError.invalidFile
        }
        return journal.statuses == [.verified]
    }

    func markTrusted(kind: AgentScope.Kind, identity: String) throws {
        guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerUseTaskJournalStore.StoreError.invalidFile
        }
        let id = Self.taskID(kind: kind, identity: identity)
        let previous = try store.load(taskID: id)
        if let previous {
            guard Self.valid(previous, kind: kind, identity: identity), previous.statuses == [.verified] else {
                throw ComputerUseTaskJournalStore.StoreError.invalidFile
            }
            return
        }
        let lease = try store.acquireExecution(taskID: id, expected: nil)
        defer { lease.release() }
        guard try store.load(taskID: id) == nil else { throw ComputerUseTaskJournalStore.StoreError.staleJournal }
        let digest = Self.digest("\(kind.rawValue)\n\(identity)")
        let attempted = ComputerUseTaskJournal(taskID: id, promptDigest: Self.promptDigest,
            contractDigest: digest, stepIDs: ["trusted"], statuses: [.attempted])
        try store.save(attempted, replacing: nil)
        var verified = attempted
        verified.statuses = [.verified]
        try store.save(verified, replacing: attempted)
    }

    private static func valid(_ journal: ComputerUseTaskJournal, kind: AgentScope.Kind, identity: String) -> Bool {
        journal.taskID == taskID(kind: kind, identity: identity)
            && journal.promptDigest == promptDigest
            && journal.contractDigest == digest("\(kind.rawValue)\n\(identity)")
            && journal.stepIDs == ["trusted"]
    }

    private static func taskID(kind: AgentScope.Kind, identity: String) -> String {
        "agent-trust/\(kind.rawValue)/\(digest(identity))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
