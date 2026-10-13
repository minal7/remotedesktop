#if DEBUG
import Foundation

struct AgentEvalApprovalCandidate {
    let taskID: String
    let requestID: String
    let fingerprint: String
    let approvalScope: String
    let resolvedScope: String
    let riskTier: String
    let action: AgentAction
    let currentURL: String?
    let expectedURL: String?
    var currentApp: String? = nil
    var expectedApp: String? = nil
    let targetRoles: [String]
    let hasSensitiveTarget: Bool
    let hasSyntheticFileRoot: Bool
}

enum AgentEvalApprovalPolicy {
    static func permits(_ candidate: AgentEvalApprovalCandidate,
                        request: AgentEvalRequest) -> Bool {
        guard candidate.taskID == request.taskID,
              UUID(uuidString: candidate.requestID) != nil,
              candidate.approvalScope == candidate.resolvedScope,
              isFingerprint(candidate.fingerprint),
              !candidate.hasSensitiveTarget else { return false }
        guard isApprovedSurface(candidate, request: request) else { return false }
        if candidate.riskTier == "high" {
            guard request.allowsFixtureCommit else { return false }
            switch candidate.action {
            case .click, .key: return true
            case .setFiles(_, let fileIDs):
                return candidate.hasSyntheticFileRoot && !fileIDs.isEmpty
            default: return false
            }
        }
        guard ["low", "medium"].contains(candidate.riskTier) else { return false }
        if case .openURL(let destination) = candidate.action {
            guard let expectedURL = candidate.expectedURL else { return false }
            return origin(destination) == origin(expectedURL)
        }
        if case .openApp = candidate.action { return false }
        if case .setFiles = candidate.action { return false }
        return true
    }

    private static func isApprovedSurface(_ candidate: AgentEvalApprovalCandidate,
                                          request: AgentEvalRequest) -> Bool {
        if let currentURL = candidate.currentURL, let expectedURL = candidate.expectedURL {
            return origin(currentURL) == origin(expectedURL) && origin(expectedURL) != nil
                && isApprovedFixtureOrigin(expectedURL) && isApprovedFixtureOrigin(currentURL)
                && request.allowsFixtureInteraction
        }
        guard let currentApp = candidate.currentApp, let expectedApp = candidate.expectedApp,
              currentApp == expectedApp, request.start.app != nil, request.allowsStartInteraction,
              ["low", "medium"].contains(candidate.riskTier) else { return false }
        switch candidate.action {
        case .click, .type, .key, .scroll, .select, .wait: return true
        default: return false
        }
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }

    private static func origin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func isApprovedFixtureOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased() else { return false }
        return host == "127.0.0.1"
    }
}
#endif
