import CryptoKit
import Foundation
enum AgentLoopResult: Equatable { case completed(answer: String), failed(reason: String), pendingApproval(AgentApprovalRequest), askUser(AgentUserQuestion), handoff(reason: String), paused, cancelled }
struct AgentUserQuestion: Equatable { let id: UUID; let question: String; let choices: [String]? }
enum AgentLoopError: Error, Equatable { case alreadyRunning, invalidConfiguration, noMatchingApproval, noPendingQuestion, recordingFailed(String), journalFailed(String) }
enum AgentRiskTier: String { case low, medium, high }
struct AgentTrustIdentity: Hashable { let kind: AgentScope.Kind; let identity: String }
enum AgentAccessDecision: Equatable {
    case allowed
    case approvalRequired(String, trustIdentity: AgentTrustIdentity?)
    case denied(String)
}
@MainActor protocol AgentTrustStore: AnyObject {
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool
    func markTrusted(kind: AgentScope.Kind, identity: String) throws
}
@MainActor protocol AgentAllowPolicy: AnyObject {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity?
}
struct AgentApprovalRequest: Equatable {
    struct ReviewField: Equatable { let label: String; let value: String }
    let id: UUID; let taskID: String; let scopeIdentity: String; let fingerprint: String
    let riskTier: AgentRiskTier; let reason: String; let action: AgentAction
    var reviewFields: [ReviewField] = []
}
struct AgentGateEvaluation: Equatable { let result: AgentGateResult; let approval: AgentApprovalRequest? }
@MainActor
final class AgentActionGate {
    private struct TrustKey: Hashable { let kind: AgentScope.Kind; let identity: String }
    private struct PendingApproval { let request: AgentApprovalRequest; let trustKey: TrustKey? }
    private struct Fingerprint: Encodable {
        let task, surface, action: String
        let target: [String]
        let contextLabel: String
        let defaultButton: String
    }
    private struct Assessment { let risk: AgentRiskTier; let fingerprint: String; let reason: String?; let trustKey: TrustKey?; let deniedReason: String? }
    private let trustStore: AgentTrustStore
    private let allowPolicy: AgentAllowPolicy
    private var pendingApprovals: [UUID: PendingApproval] = [:]
    init(trustStore: AgentTrustStore, allowPolicy: AgentAllowPolicy) { self.trustStore = trustStore; self.allowPolicy = allowPolicy }
    func evaluate(_ resolved: AgentResolvedAction, expectedScope: AgentScope) throws -> AgentGateEvaluation {
        let assessment = try assess(resolved, expectedScope: expectedScope)
        if let reason = assessment.deniedReason {
            return .init(result: result(.rejected, reason, assessment, resolved.frame.scope), approval: nil)
        }
        guard let reason = assessment.reason else {
            return .init(result: result(.allowed, "Allowed by the host action policy.", assessment, resolved.frame.scope), approval: nil)
        }
        let request = AgentApprovalRequest(id: UUID(), taskID: expectedScope.taskID,
                                           scopeIdentity: expectedScope.identity, fingerprint: assessment.fingerprint,
                                           riskTier: assessment.risk, reason: reason, action: resolved.action)
        pendingApprovals[request.id] = .init(request: request, trustKey: assessment.trustKey)
        return .init(result: result(.needsApproval, reason, assessment, resolved.frame.scope), approval: request)
    }
    func resolveApproval(_ requestID: UUID, approved: Bool, resolved: AgentResolvedAction, expectedScope: AgentScope) throws -> AgentGateEvaluation {
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else {
            return rejection("Approval is missing, stale, or already used.", resolved.frame.scope)
        }
        let request = pending.request
        guard request.taskID == expectedScope.taskID, request.scopeIdentity == expectedScope.identity, resolved.frame.scope == expectedScope else {
            return rejection("Approval no longer matches the task or surface.", resolved.frame.scope, request.fingerprint)
        }
        guard approved else { return rejection("rejected: user declined", resolved.frame.scope, request.fingerprint) }
        let assessment = try assess(resolved, expectedScope: expectedScope)
        guard assessment.deniedReason == nil, assessment.fingerprint == request.fingerprint else {
            return rejection(assessment.deniedReason ?? "The approved action or target label changed.",
                             resolved.frame.scope, assessment.fingerprint, assessment.risk)
        }
        if let key = pending.trustKey { try trustStore.markTrusted(kind: key.kind, identity: key.identity) }
        return .init(result: result(.allowed, "Approved for this exact action.", assessment, resolved.frame.scope), approval: nil)
    }
    func cancelPendingApproval(_ requestID: UUID) { pendingApprovals.removeValue(forKey: requestID) }
    func matchesOpenedSurface(action: AgentAction, from scope: AgentScope, observation: AgentObservation) -> Bool {
        switch action {
        case let .openURL(url):
            guard case let .web(opened, _) = observation.surface, let expected = destinationKey(for: .openURL(url: url), scope: scope), let actual = destinationKey(for: .openURL(url: opened), scope: scope) else { return false }
            return expected == actual
        case .openApp:
            guard let expected = allowPolicy.resolvedTrustIdentity(for: action, in: scope),
                  case let .app(bundleID, _) = observation.surface else { return false }
            return expected.kind == .app && expected.identity == bundleID
        default: return false
        }
    }
    private func assess(_ resolved: AgentResolvedAction, expectedScope: AgentScope) throws -> Assessment {
        let scope = resolved.frame.scope
        let signature = try fingerprint(resolved)
        guard scope == expectedScope else { return .init(risk: .high, fingerprint: signature, reason: nil, trustKey: nil, deniedReason: "The action moved outside the task's bound surface.") }
        do { try resolved.action.validate() }
        catch { return .init(risk: .high, fingerprint: signature, reason: nil, trustKey: nil, deniedReason: "The action failed contract validation.") }
        if resolved.surfaceReadOnly && !isReadOnlyAction(resolved) {
            return .init(risk: .high, fingerprint: signature, reason: nil, trustKey: nil, deniedReason: "This surface is read-only.")
        }
        if isCredentialEntry(resolved) {
            return .init(risk: .high, fingerprint: signature, reason: nil, trustKey: nil, deniedReason: "Credentials require you to take over on your Mac; never send passwords or codes in chat.")
        }
        let risk = riskTier(for: resolved)
        let decision = allowPolicy.decision(for: resolved.action, in: scope)
        let destination = destinationKey(for: resolved.action, scope: scope)
        if case .openApp = resolved.action, destination == nil {
            return .init(risk: risk, fingerprint: signature, reason: nil, trustKey: nil, deniedReason: "The host app registry could not resolve the requested app.")
        }
        let surfaceKey = destination ?? surfaceTrustKey(resolved.frame.observation.surface)
        let trusted = try trustStore.isTrusted(kind: surfaceKey.kind, identity: surfaceKey.identity)
        var reasons: [String] = []
        var grantKey: TrustKey?
        switch decision {
        case .denied(let reason):
            return .init(risk: risk, fingerprint: signature, reason: nil, trustKey: nil, deniedReason: reason)
        case .approvalRequired(let reason, let identity):
            reasons.append(reason)
            if let identity { grantKey = .init(kind: identity.kind, identity: identity.identity) }
        case .allowed: break
        }
        if risk == .high { reasons.append("This action may commit, delete, share, or change permissions.") }
        if !trusted && requiresSurfaceTrust(resolved.action) {
            reasons.append("This is the first use of an untrusted app or site.")
            grantKey = surfaceKey
        }
        return .init(risk: risk == .low && !trusted && !reasons.isEmpty ? .medium : risk, fingerprint: signature, reason: reasons.first, trustKey: grantKey, deniedReason: nil)
    }
    private func isReadOnlyAction(_ resolved: AgentResolvedAction) -> Bool {
        switch resolved.action {
        case .scroll, .wait, .askUser, .done, .fail, .findFiles, .openURL, .openApp: return true
        case .click: return !hasHighRiskLabel(resolved)
        case .key(let chord):
            let key = chord.lowercased().filter(\.isLetter)
            return ["tab", "escape", "up", "down", "left", "right", "pageup", "pagedown", "home", "end"].contains(key)
        case .type, .select, .drag, .setFiles: return false
        }
    }
    private func isCredentialEntry(_ resolved: AgentResolvedAction) -> Bool {
        let message: String? = switch resolved.action { case .askUser(let q, let c): ([q] + (c ?? [])).joined(separator: " "); case .done(let a), .fail(let a): a; default: nil }
        if let message, AgentCredentialRule.isSensitive(role: "textfield", name: message, state: []) { return true }
        switch resolved.action { case .type, .key, .select: break; default: return false }
        if resolved.targets.contains(where: isSensitive) { return true }
        guard let focus = resolved.frame.observation.focus else { return false }
        return AgentCredentialRule.isSensitive(role: focus.role, name: focus.name, state: []) || resolved.frame.observation.elements.first(where: { $0.id == focus.id }).map(isSensitive) == true
    }
    private func isSensitive(_ element: AgentElement) -> Bool {
        AgentCredentialRule.isSensitive(role: element.role, name: element.name, state: element.state)
    }
    private func riskTier(for resolved: AgentResolvedAction) -> AgentRiskTier {
        if case .setFiles = resolved.action { return .high }
        if hasHighRiskLabel(resolved) { return .high }
        return .low
    }
    private func hasHighRiskLabel(_ resolved: AgentResolvedAction) -> Bool {
        switch resolved.action {
        case .click, .type, .key, .select, .drag, .setFiles: break
        default: return false
        }
        if isEnter(resolved.action), case .web = resolved.frame.observation.surface { return true }
        if isEnter(resolved.action) {
            if isModifiedEnter(resolved.action) { return true }
            let focusedRisk = focusedActionIsHighRisk(resolved.frame.observation)
            switch resolved.frame.defaultButtonEvidence {
            case .unknown:
                return true
            case .knownNone:
                return focusedRisk || !hasKnownActionableFocus(resolved.frame.observation)
            case .button(_, _, let name):
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
                return focusedRisk || containsHighRiskLabel(name) || !hasKnownActionableFocus(resolved.frame.observation)
            }
        }
        return (resolved.targets.map(\.name) + [resolved.targetContextLabel ?? ""]).contains(where: containsHighRiskLabel)
    }

    private func focusedActionIsHighRisk(_ observation: AgentObservation) -> Bool {
        guard let focus = observation.focus,
              let element = observation.elements.first(where: { $0.id == focus.id }),
              isActionableFocusRole(element.role), element.inView,
              !element.state.contains("disabled") else { return false }
        return containsHighRiskLabel(element.name)
    }

    private func hasKnownActionableFocus(_ observation: AgentObservation) -> Bool {
        guard let focus = observation.focus,
              let element = observation.elements.first(where: { $0.id == focus.id }) else { return false }
        return isActionableFocusRole(element.role) && element.inView && !element.state.contains("disabled")
    }

    private func isActionableFocusRole(_ role: String) -> Bool {
        switch role.lowercased() {
        case "axbutton", "axlink", "axmenuitem", "axmenubaritem", "axtextfield", "axtextarea",
             "axtextview", "axsearchfield", "axpopupbutton", "axcombobox", "axcheckbox", "axradiobutton":
            return true
        default: return false
        }
    }
    private func containsHighRiskLabel(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordinaryOrder = #"^(display|sort|reading|tab|navigation|ascending|descending|chronological|reverse|column|row)\s+order$"#
        if normalized.range(of: ordinaryOrder, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let pattern = #"\b(send|submit|pay|purchase|buy|commit|order|delete|remove|replace|overwrite|share|publish|post|transfer|trash|sign[\s_-]*out|allow|grant|install)\b"#
        return normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private func isEnter(_ action: AgentAction) -> Bool {
        guard case .key(let chord) = action else { return false }
        return chord.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == "enter" || $0 == "return" }
    }
    private func isModifiedEnter(_ action: AgentAction) -> Bool {
        guard case .key(let chord) = action else { return false }
        let keys = chord.lowercased().split(whereSeparator: { !$0.isLetter })
        guard keys.contains(where: { $0 == "enter" || $0 == "return" }) else { return false }
        return keys.contains { $0 != "enter" && $0 != "return" }
    }
    private func requiresSurfaceTrust(_ action: AgentAction) -> Bool {
        switch action {
        case .click, .type, .key, .scroll, .select, .drag, .openURL, .openApp, .setFiles: return true
        case .findFiles, .wait, .askUser, .done, .fail: return false
        }
    }
    private func destinationKey(for action: AgentAction, scope: AgentScope) -> TrustKey? {
        switch action {
        case .openURL(let url):
            guard let origin = Self.canonicalOrigin(url) else { return nil }
            return .init(kind: .web, identity: origin)
        case .openApp:
            guard let identity = allowPolicy.resolvedTrustIdentity(for: action, in: scope) else { return nil }
            return .init(kind: identity.kind, identity: identity.identity)
        default: return nil
        }
    }
    private func surfaceTrustKey(_ surface: AgentSurface) -> TrustKey {
        switch surface {
        case .web(let url, _): return .init(kind: .web, identity: Self.canonicalOrigin(url) ?? url)
        case .app(let bundleID, _): return .init(kind: .app, identity: bundleID)
        }
    }
    private func fingerprint(_ resolved: AgentResolvedAction) throws -> String {
        let observation = resolved.frame.observation
        let surface: String
        switch observation.surface {
        case .web(let url, _): surface = "web:\(url)"
        case .app(let bundleID, _): surface = "app:\(bundleID)"
        }
        let targets = resolved.targets.map { "\($0.role)|\($0.name)" }.sorted()
        let defaultButton = isEnter(resolved.action) && isApp(observation.surface)
            ? resolved.frame.defaultButtonEvidence.approvalFingerprint : ""
        let payload = Fingerprint(task: resolved.frame.scope.taskID, surface: surface,
            action: actionSemantics(resolved), target: targets,
            contextLabel: resolved.targetContextLabel ?? "", defaultButton: defaultButton)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
    }
    private func isApp(_ surface: AgentSurface) -> Bool {
        if case .app = surface { return true }
        return false
    }
    private func actionSemantics(_ resolved: AgentResolvedAction) -> String {
        let action = resolved.action
        switch action {
        case .click(let target, let button, let count): return "click|\(targetKey(target, resolved))|\(button?.rawValue ?? "left")|\(count ?? 1)"
        case .type(let target, let text, let mode): return "type|\(targetKey(target, resolved))|\(mode.rawValue)|\(hash(text))"
        case .key(let chord): return "key|\(chord)|\(targetKey(nil, resolved))"
        case .scroll(let target, let direction, let amount): return "scroll|\(targetKey(target, resolved))|\(direction.rawValue)|\(amount)"
        case .select(let target, let option): return "select|\(targetKey(target, resolved))|\(option)"
        case .drag(let from, let to): return "drag|\(targetKey(from, resolved))|\(targetKey(to, resolved))"
        case .openURL(let url): return "open_url|\(url)"
        case .openApp(let name): return "open_app|\(name)"
        case .findFiles(let query, let kind, let date): return "find_files|\(query)|\(kind ?? "")|\(date ?? "")"
        case .setFiles(let target, let ids): return "set_files|\(targetKey(target, resolved))|\(ids.joined(separator: ","))"
        case .wait(let seconds): return "wait|\(seconds)"
        case .askUser(let question, let choices): return "ask_user|\(question)|\(choices?.joined(separator: ",") ?? "")"
        case .done(let answer): return "done|\(answer)"
        case .fail(let reason): return "fail|\(reason)"
        }
    }
    private func targetKey(_ target: AgentTarget?, _ resolved: AgentResolvedAction) -> String {
        if let target {
            switch target {
            case .element(let id):
                guard let item = resolved.targets.first(where: { $0.id == id }) else { return "element" }
                return "element:\(item.role)|\(item.name)"
            case .point(let x, let y): return "point:\(x),\(y)"
            }
        }
        if let focus = resolved.frame.observation.focus { return "focus:\(focus.role)|\(focus.name)" }
        return "none"
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func result(_ decision: AgentGateDecision, _ reason: String, _ assessment: Assessment, _ scope: AgentScope) -> AgentGateResult {
        .init(decision: decision, reason: reason, fingerprint: assessment.fingerprint, scopeIdentity: scope.identity, riskTier: assessment.risk.rawValue)
    }
    private func rejection(_ reason: String, _ scope: AgentScope, _ fingerprint: String? = nil,
                           _ risk: AgentRiskTier = .high) -> AgentGateEvaluation {
        .init(result: .init(decision: .rejected, reason: reason, fingerprint: fingerprint,
                            scopeIdentity: scope.identity, riskTier: risk.rawValue), approval: nil)
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
}
