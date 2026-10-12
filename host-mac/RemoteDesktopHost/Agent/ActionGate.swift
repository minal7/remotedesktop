import CryptoKit
import Foundation

enum AgentLoopResult: Equatable {
    case completed(answer: String), failed(reason: String), pendingApproval(AgentApprovalRequest)
    case askUser(AgentUserQuestion), handoff(reason: String), paused, cancelled
}

struct AgentUserQuestion: Equatable {
    let id: UUID
    let question: String
    let choices: [String]?
}

enum AgentLoopError: Error, Equatable {
    case alreadyRunning, invalidConfiguration, noMatchingApproval, noPendingQuestion
    case recordingFailed(String), journalFailed(String)
}

enum AgentRiskTier: String { case low, medium, high }

struct AgentTrustIdentity: Hashable {
    let kind: AgentScope.Kind
    let identity: String
}

enum AgentAccessDecision: Equatable {
    case allowed
    case approvalRequired(String, trustIdentity: AgentTrustIdentity?)
    case denied(String)
}

@MainActor
protocol AgentTrustStore: AnyObject {
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool
    func markTrusted(kind: AgentScope.Kind, identity: String) throws
}

@MainActor
protocol AgentAllowPolicy: AnyObject {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity?
}

struct AgentApprovalRequest: Equatable {
    struct ReviewField: Equatable { let label: String; let value: String }
    let id: UUID
    let taskID: String
    let scopeIdentity: String
    let fingerprint: String
    let riskTier: AgentRiskTier
    let reason: String
    let action: AgentAction
    var reviewFields: [ReviewField] = []
}

struct AgentGateEvaluation: Equatable {
    let result: AgentGateResult
    let approval: AgentApprovalRequest?
}

@MainActor
final class AgentActionGate {
    private struct TrustKey: Hashable {
        let kind: AgentScope.Kind
        let identity: String
    }

    private struct PendingApproval {
        let request: AgentApprovalRequest
        let trustKey: TrustKey?
    }

    private struct FingerprintPayload: Encodable {
        struct Target: Encodable {
            let id: Int
            let role: String
            let name: String
            let state: [String]
        }

        struct EditableValue: Encodable {
            let id: Int
            let role: String
            let name: String
            let value: String?
            let selection: [Int]?
        }

        let taskID: String
        let scopeKind: String
        let scopeIdentity: String
        let surface: String
        let title: String
        let action: AgentAction
        let targets: [Target]
        let pageContext: [String]
        let editableValues: [EditableValue]
        let authorityDigest: String?
    }

    private struct Assessment {
        let risk: AgentRiskTier
        let fingerprint: String
        let reason: String?
        let trustKey: TrustKey?
        let deniedReason: String?
    }

    private let trustStore: AgentTrustStore
    private let allowPolicy: AgentAllowPolicy
    private var pendingApprovals: [UUID: PendingApproval] = [:]

    init(trustStore: AgentTrustStore, allowPolicy: AgentAllowPolicy) {
        self.trustStore = trustStore
        self.allowPolicy = allowPolicy
    }

    func evaluate(_ resolved: AgentResolvedAction, expectedScope: AgentScope) throws -> AgentGateEvaluation {
        let assessment = try assess(resolved, expectedScope: expectedScope)
        if let reason = assessment.deniedReason {
            return AgentGateEvaluation(result: result(.rejected, reason, assessment, resolved.frame.scope), approval: nil)
        }
        guard let reason = assessment.reason else {
            return AgentGateEvaluation(result: result(.allowed, "Allowed by the host action policy.", assessment, resolved.frame.scope), approval: nil)
        }

        var request = AgentApprovalRequest(id: UUID(), taskID: expectedScope.taskID,
                                           scopeIdentity: expectedScope.identity, fingerprint: assessment.fingerprint,
                                           riskTier: assessment.risk, reason: reason, action: resolved.action)
        request.reviewFields = resolved.frame.observation.elements.filter { isEditable($0) && !isSecure($0) }
            .compactMap { element in element.value.map { .init(label: element.name.isEmpty ? element.role : element.name, value: $0) } }
        pendingApprovals[request.id] = PendingApproval(request: request, trustKey: assessment.trustKey)
        return AgentGateEvaluation(result: result(.needsApproval, reason, assessment, resolved.frame.scope), approval: request)
    }

    func resolveApproval(_ requestID: UUID, approved: Bool, resolved: AgentResolvedAction,
                         expectedScope: AgentScope) throws -> AgentGateEvaluation {
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else {
            return rejection("Approval is missing, stale, or already used.", resolved.frame.scope)
        }
        let request = pending.request
        guard request.taskID == expectedScope.taskID,
              request.scopeIdentity == expectedScope.identity,
              resolved.frame.scope == expectedScope,
              resolved.action == request.action else {
            return rejection("Approval no longer matches the task, surface, or action.", resolved.frame.scope, request.fingerprint)
        }
        guard approved else {
            return rejection("The requested action was not approved.", resolved.frame.scope, request.fingerprint)
        }

        let assessment = try assess(resolved, expectedScope: expectedScope)
        guard assessment.deniedReason == nil, assessment.fingerprint == request.fingerprint else {
            return rejection(assessment.deniedReason ?? "The approved target or context changed.", resolved.frame.scope, assessment.fingerprint, assessment.risk)
        }
        if let trustKey = pending.trustKey {
            try trustStore.markTrusted(kind: trustKey.kind, identity: trustKey.identity)
        }
        return AgentGateEvaluation(
            result: result(.allowed, "Approved for this exact action.", assessment, resolved.frame.scope),
            approval: nil)
    }

    func cancelPendingApproval(_ requestID: UUID) {
        pendingApprovals.removeValue(forKey: requestID)
    }

    func matchesOpenedSurface(action: AgentAction, from scope: AgentScope,
                              observation: AgentObservation) -> Bool {
        switch action {
        case let .openURL(url):
            guard case let .web(openedURL, _) = observation.surface,
                  let expected = destinationKey(for: .openURL(url: url), scope: scope),
                  let actual = destinationKey(for: .openURL(url: openedURL), scope: scope) else { return false }
            return expected.kind == actual.kind && expected.identity == actual.identity
        case .openApp:
            guard let expected = allowPolicy.resolvedTrustIdentity(for: action, in: scope),
                  case let .app(bundleID, _) = observation.surface else { return false }
            return expected.kind == .app && expected.identity == bundleID
        default:
            return false
        }
    }

    private func assess(_ resolved: AgentResolvedAction, expectedScope: AgentScope) throws -> Assessment {
        let scope = resolved.frame.scope
        let fingerprint = try fingerprint(for: resolved)
        guard scope == expectedScope else {
            return Assessment(risk: .high, fingerprint: fingerprint, reason: nil, trustKey: nil,
                              deniedReason: "The action moved outside the task's bound surface.")
        }
        do { try resolved.action.validate() }
        catch {
            return Assessment(risk: .high, fingerprint: fingerprint, reason: nil, trustKey: nil,
                              deniedReason: "The action failed contract validation.")
        }
        if isCredentialEntry(resolved) {
            return Assessment(risk: .high, fingerprint: fingerprint, reason: nil, trustKey: nil,
                              deniedReason: "Credential fields are blocked; hand off to the user.")
        }

        let baseRisk = riskTier(for: resolved)
        let accessDecision = allowPolicy.decision(for: resolved.action, in: scope)
        let destination = destinationKey(for: resolved.action, scope: scope)
        if case .openApp = resolved.action, destination == nil {
            return Assessment(risk: baseRisk, fingerprint: fingerprint, reason: nil, trustKey: nil,
                              deniedReason: "The host app registry could not resolve the requested app.")
        }
        let trustKey = destination ?? surfaceTrustKey(resolved.frame.observation.surface)
        let trusted = try trustStore.isTrusted(kind: trustKey.kind, identity: trustKey.identity)
        var reasons: [String] = []
        var grantKey: TrustKey?
        var risk = baseRisk

        switch accessDecision {
        case .denied(let reason):
            return Assessment(risk: risk, fingerprint: fingerprint, reason: nil, trustKey: nil, deniedReason: reason)
        case .approvalRequired(let reason, let trustIdentity):
            reasons.append(reason)
            if let trustIdentity { grantKey = TrustKey(kind: trustIdentity.kind, identity: trustIdentity.identity) }
        case .allowed: break
        }
        if risk == .high { reasons.append("This action may commit, delete, share, or change permissions.") }
        if !trusted && requiresBoundSurfaceApproval(resolved.action) {
            reasons.append("This is the first use of an untrusted app or site.")
            grantKey = trustKey
            if risk == .low { risk = .medium }
        } else if risk == .medium && hasUnlabeledTarget(resolved) && !trusted {
            reasons.append("The target is unlabeled on an untrusted surface.")
        }
        return Assessment(risk: risk, fingerprint: fingerprint, reason: reasons.first, trustKey: grantKey,
                          deniedReason: nil)
    }

    private func result(_ decision: AgentGateDecision, _ reason: String, _ assessment: Assessment,
                        _ scope: AgentScope) -> AgentGateResult {
        AgentGateResult(decision: decision, reason: reason, fingerprint: assessment.fingerprint,
                        scopeIdentity: scope.identity, riskTier: assessment.risk.rawValue)
    }

    private func rejection(_ reason: String, _ scope: AgentScope, _ fingerprint: String? = nil,
                           _ risk: AgentRiskTier = .high) -> AgentGateEvaluation {
        AgentGateEvaluation(result: AgentGateResult(decision: .rejected, reason: reason,
                                                    fingerprint: fingerprint, scopeIdentity: scope.identity,
                                                    riskTier: risk.rawValue), approval: nil)
    }

    private func isCredentialEntry(_ resolved: AgentResolvedAction) -> Bool {
        switch resolved.action {
        case .type, .key, .select: break
        default: return false
        }
        let focus = resolved.frame.observation.focus
        let secureFocus = focus.map { value in
            AgentContractValidation.isSecureRoleOrState(role: value.role, state: [])
                || resolved.frame.observation.elements.first(where: { $0.id == value.id }).map(isSecure) == true
        } == true
        if case .type(let target, _, _) = resolved.action, let target = target,
           case .element(let id) = target,
           resolved.targets.first(where: { $0.id == id }).map(isSecure) == true { return true }
        return resolved.targets.contains(where: isSecure) || secureFocus
    }

    private func isSecure(_ element: AgentElement) -> Bool {
        AgentCredentialRule.isSensitive(role: element.role, name: element.name, state: element.state)
    }

    private func requiresBoundSurfaceApproval(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .type, .key, .scroll, .select, .drag, .openURL, .openApp, .setFiles: true
        case .findFiles, .wait, .askUser, .done, .fail: false
        }
    }

    private func destinationKey(for action: AgentAction, scope: AgentScope) -> TrustKey? {
        switch action {
        case let .openURL(url):
            guard let origin = Self.canonicalOrigin(url) else { return nil }
            return TrustKey(kind: .web, identity: origin)
        case .openApp:
            if let trustIdentity = allowPolicy.resolvedTrustIdentity(for: action, in: scope) {
                return TrustKey(kind: trustIdentity.kind, identity: trustIdentity.identity)
            }
            return nil
        default: return nil
        }
    }

    private func surfaceTrustKey(_ surface: AgentSurface) -> TrustKey {
        switch surface {
        case let .web(url, _):
            return TrustKey(kind: .web, identity: Self.canonicalOrigin(url) ?? url)
        case let .app(bundleID, _): return TrustKey(kind: .app, identity: bundleID)
        }
    }

    private static func canonicalOrigin(_ value: String) -> String? {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              let rawHost = parts.host?.lowercased(), !rawHost.isEmpty else { return nil }
        let host = rawHost.contains(":") ? "[\(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : rawHost
        let port = parts.port.flatMap { value -> Int? in
            if (scheme == "https" && value == 443) || (scheme == "http" && value == 80) { return nil }
            return value
        }.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func hasUnlabeledTarget(_ resolved: AgentResolvedAction) -> Bool {
        guard targetsUI(resolved.action) else { return false }
        return resolved.targets.isEmpty || resolved.targets.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func targetsUI(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .type, .key, .scroll, .select, .drag, .setFiles: true
        case .openURL, .openApp, .findFiles, .wait, .askUser, .done, .fail: false
        }
    }

    private func riskTier(for resolved: AgentResolvedAction) -> AgentRiskTier {
        // Supplying local file bytes can start a network upload immediately.
        if case .setFiles = resolved.action { return .high }
        if hasHighRiskContext(resolved) { return .high }
        if hasUnlabeledTarget(resolved) { return .medium }
        return .low
    }

    private func hasHighRiskContext(_ resolved: AgentResolvedAction) -> Bool {
        switch resolved.action {
        case .click, .type, .key, .select, .drag, .setFiles: break
        default: return false
        }
        var context = resolved.targets.flatMap { [$0.role, $0.name] }
        switch resolved.action {
        case .type, .key:
            if let focus = resolved.frame.observation.focus {
                context += [focus.role, focus.name]
                if let element = resolved.frame.observation.elements.first(where: { $0.id == focus.id }) {
                    context += [element.role, element.name]
                }
            }
            if isEnterKey(resolved.action) && hasFormContext(resolved.frame.observation) { return true }
        default: break
        }
        let dialogs = resolved.frame.observation.elements.filter(isDialogContext)
        if !dialogs.isEmpty {
            context += dialogs.flatMap { [$0.role, $0.name] + $0.state }
            context.append(resolved.frame.observation.surface.title ?? "")
        }
        return context.contains(where: containsHighRiskLabel)
    }

    private func containsHighRiskLabel(_ value: String) -> Bool {
        let pattern = #"\b(send|submit|pay(?:ment)?|delete|share|publish|purchase|sign[\s_-]*out|permissions?)\b"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isEnterKey(_ action: AgentAction) -> Bool {
        guard case let .key(chord) = action else { return false }
        return chord.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == "enter" || $0 == "return" }
    }

    private func hasFormContext(_ observation: AgentObservation) -> Bool {
        observation.elements.contains { element in
            let role = element.role.lowercased()
            return ["textbox", "textfield", "textarea", "combobox", "searchbox", "editor", "form"]
                .contains(where: { role.contains($0) })
        }
    }

    private func isDialogContext(_ element: AgentElement) -> Bool {
        let role = element.role.lowercased().filter { $0.isLetter }
        return ["dialog", "alertdialog", "sheet"].contains(role)
            || element.state.contains { ["modal", "dialog"].contains($0.lowercased()) }
    }

    private func isEditable(_ element: AgentElement) -> Bool {
        let role = element.role.lowercased()
        return ["textbox", "textfield", "textarea", "combobox", "searchbox", "editor"]
            .contains(where: { role.contains($0) })
            || element.state.contains { ["editable", "contenteditable"].contains($0.lowercased()) }
    }

    private func fingerprint(for resolved: AgentResolvedAction) throws -> String {
        let observation = resolved.frame.observation
        let targetSemantics = resolved.targets.map {
            FingerprintPayload.Target(id: $0.id, role: $0.role, name: $0.name, state: $0.state.sorted())
        }.sorted { ($0.id, $0.role, $0.name) < ($1.id, $1.role, $1.name) }
        let pageContext = observation.elements.map { "\($0.role)|\($0.name)|\($0.state.sorted().joined(separator: ","))" }.sorted()
        let editableValues = observation.elements.filter { isEditable($0) && !isSecure($0) }.map {
            FingerprintPayload.EditableValue(id: $0.id, role: $0.role, name: $0.name, value: $0.value,
                                             selection: nil)
        }
        let focusValues: [FingerprintPayload.EditableValue] = observation.focus.flatMap { focus in
            let focused = observation.elements.first(where: { $0.id == focus.id })
            let secure = AgentContractValidation.isSecureRoleOrState(role: focus.role, state: [])
                || focused.map(isSecure) == true
            guard !secure, focused.map(isEditable) == true else { return nil }
            return [FingerprintPayload.EditableValue(id: focus.id, role: focus.role, name: focus.name,
                                                     value: focus.valuePrefix,
                                                     selection: [focus.selection.start, focus.selection.end])]
        } ?? []
        let surface: String
        let title: String
        switch observation.surface {
        case let .web(url, surfaceTitle): surface = "web|\(url)"; title = surfaceTitle ?? ""
        case let .app(bundleID, surfaceTitle): surface = "app|\(bundleID)"; title = surfaceTitle ?? ""
        }
        let payload = FingerprintPayload(taskID: resolved.frame.scope.taskID,
                                        scopeKind: resolved.frame.scope.kind.rawValue,
                                        scopeIdentity: resolved.frame.scope.identity, surface: surface, title: title,
                                        action: resolved.action, targets: targetSemantics, pageContext: pageContext,
                                        editableValues: (editableValues + focusValues).sorted { $0.id < $1.id },
                                        authorityDigest: resolved.frame.authorityDigest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
