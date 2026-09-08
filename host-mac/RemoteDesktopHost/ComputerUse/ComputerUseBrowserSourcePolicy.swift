import Foundation
import Darwin

/// A host-selected origin, never a suffix or a model-authored URL pattern.
/// Scheme and effective port are part of identity; subdomains require their
/// own entries. This describes document sources, not subresource isolation.
struct ComputerUseBrowserSourceOrigin: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let scheme: String
    private let host: String
    private let port: Int
    fileprivate var identity: String { "\(scheme)|\(host)|\(port)" }
    init(_ url: URL) throws {
        guard ComputerUseOwnedBrowser.validatedURL(url) != nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.hasSuffix("."), !host.contains("%"),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 91, 93].contains($0) }) else {
            throw ComputerUseBrowserError.sourceNotAllowed
        }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { throw ComputerUseBrowserError.sourceNotAllowed }
        self.scheme = scheme; self.host = try Self.canonicalHost(host); self.port = port
    }
    private static func canonicalHost(_ host: String) throws -> String {
        let unwrapped = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if unwrapped.contains(":") {
            var address = in6_addr(), buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard unwrapped.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1,
                  inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { throw ComputerUseBrowserError.sourceNotAllowed }
            return String(cString: buffer)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last else { throw ComputerUseBrowserError.sourceNotAllowed }
        if last.allSatisfy({ $0 >= "0" && $0 <= "9" }) || last.hasPrefix("0x") {
            // Reject abbreviated, octal/hex and integer IPv4 URL spellings;
            // a browser may otherwise resolve them to an excluded origin.
            var address = in_addr(), buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1,
                  inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { throw ComputerUseBrowserError.sourceNotAllowed }
            return String(cString: buffer)
        }
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw ComputerUseBrowserError.sourceNotAllowed }
        return host
    }
    var description: String { "BrowserSourceOrigin" }
    var debugDescription: String { description }
}

/// Native document-navigation policy for one complete goal revision. Model
/// proposals cannot construct origins from page labels or loosen this policy.
struct ComputerUseBrowserSourcePolicy: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let taskID: String
    let rootDigest: String
    let goalRevision: String
    let digest: String
    private let allowed: Set<ComputerUseBrowserSourceOrigin>?
    private let excluded: Set<ComputerUseBrowserSourceOrigin>
    init(goal: ComputerUseBrowserGoalInput, allowedOrigins: [ComputerUseBrowserSourceOrigin]? = nil,
         excludedOrigins: [ComputerUseBrowserSourceOrigin] = []) throws {
        guard (allowedOrigins?.count ?? 0) <= 32, excludedOrigins.count <= 32 else { throw ComputerUseBrowserError.sourceNotAllowed }
        taskID = goal.taskID; rootDigest = goal.rootDigest; goalRevision = goal.digest
        allowed = allowedOrigins.map { Set($0) }; excluded = Set(excludedOrigins)
        digest = ComputerUseTaskContract.digest(["browser-source-policy-v1", goal.digest,
            allowed == nil ? "unrestricted" : "allow-listed"]
            + (allowed?.map(\.identity).sorted() ?? []) + ["excluded"] + excluded.map(\.identity).sorted())
    }
    func permits(_ url: URL) -> Bool {
        guard let origin = try? ComputerUseBrowserSourceOrigin(url), !excluded.contains(origin) else { return false }
        return allowed?.contains(origin) ?? true
    }
    var description: String { "BrowserSourcePolicy" }
    var debugDescription: String { description }
}

/// Eligibility of the document supplying an answer's evidence, independently
/// of auxiliary navigation. This cannot establish the seller, offer, public
/// link, relevance or other requested facts merely from the document's origin.
struct ComputerUseBrowserAnswerSourcePolicy: Equatable, Sendable {
    private let origins: ComputerUseBrowserSourcePolicy
    let goalRevision: String
    let digest: String
    init(goal: ComputerUseBrowserGoalInput, allowedOrigins: [ComputerUseBrowserSourceOrigin]? = nil,
         excludedOrigins: [ComputerUseBrowserSourceOrigin] = []) throws {
        origins = try .init(goal: goal, allowedOrigins: allowedOrigins, excludedOrigins: excludedOrigins)
        goalRevision = goal.digest
        digest = ComputerUseTaskContract.digest(["browser-answer-source-policy-v1", origins.digest])
    }
    func permitsEvidenceFrom(_ url: URL) -> Bool { origins.permits(url) }
}

/// Provider, document constraints and answer sources are selected atomically.
/// An omitted plan retains the unresolved task instead of widening its scope.
struct ComputerUseBrowserResearchSources: Sendable {
    let provider: ComputerUseBrowserSearchProvider
    let policy: ComputerUseBrowserSourcePolicy
    let answerPolicy: ComputerUseBrowserAnswerSourcePolicy
    let digest: String
    init(goal: ComputerUseBrowserGoalInput, provider: ComputerUseBrowserSearchProvider,
         allowedOrigins: [ComputerUseBrowserSourceOrigin]? = nil, excludedOrigins: [ComputerUseBrowserSourceOrigin] = [],
         answerAllowedOrigins: [ComputerUseBrowserSourceOrigin]? = nil, answerExcludedOrigins: [ComputerUseBrowserSourceOrigin] = []) throws {
        let policy = try ComputerUseBrowserSourcePolicy(goal: goal, allowedOrigins: allowedOrigins, excludedOrigins: excludedOrigins)
        try provider.validateSourcePolicy(policy)
        let answerPolicy = try ComputerUseBrowserAnswerSourcePolicy(goal: goal,
            allowedOrigins: answerAllowedOrigins, excludedOrigins: answerExcludedOrigins)
        self.provider = provider; self.policy = policy; self.answerPolicy = answerPolicy
        digest = ComputerUseTaskContract.digest(["browser-research-sources-v1", provider.digest, policy.digest, answerPolicy.digest])
    }
}
