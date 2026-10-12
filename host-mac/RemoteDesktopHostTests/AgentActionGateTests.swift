import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentActionGateTests: XCTestCase {
    func testHighRiskTargetRequiresApprovalAndFingerprintIgnoresMovedBounds() throws {
        let store = MemoryTrustStore()
        let policy = TestAllowPolicy()
        let gate = AgentActionGate(trustStore: store, allowPolicy: policy)
        let initial = button(id: 3, name: "Send")
        let scope = webScope()
        let first = resolved(.click(target: .element(id: 3), button: nil, count: nil), scope: scope,
                             elements: [initial])

        let evaluation = try gate.evaluate(first, expectedScope: scope)
        let approval = try XCTUnwrap(evaluation.approval)
        XCTAssertEqual(evaluation.result.decision, .needsApproval)
        XCTAssertEqual(approval.riskTier, .high)

        let moved = button(id: 3, name: "Send", x: 99)
        let fresh = resolved(first.action, scope: scope, elements: [moved])
        let approved = try gate.resolveApproval(approval.id, approved: true, resolved: fresh, expectedScope: scope)
        XCTAssertEqual(approved.result.decision, .allowed)
        XCTAssertTrue(try store.isTrusted(kind: .web, identity: "https://example.test"))
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true, resolved: fresh,
                                                expectedScope: scope).result.decision, .rejected)
    }

    func testApprovalRejectsChangedSemanticTargetAndIsConsumed() throws {
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let scope = webScope()
        let original = resolved(.click(target: .element(id: 8), button: nil, count: nil), scope: scope,
                                elements: [button(id: 8, name: "Continue")])
        let approval = try XCTUnwrap(gate.evaluate(original, expectedScope: scope).approval)
        let changed = resolved(original.action, scope: scope, elements: [button(id: 8, name: "Delete")])

        let result = try gate.resolveApproval(approval.id, approved: true, resolved: changed, expectedScope: scope)
        XCTAssertEqual(result.result.decision, .rejected)
        XCTAssertTrue(result.result.reason.contains("changed"))
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true, resolved: original,
                                                expectedScope: scope).result.decision, .rejected)
    }

    func testUnrelatedSubmitControlDoesNotMakeOrdinaryTypingHighRisk() throws {
        let scope = webScope()
        let textbox = AgentElement(id: 5, role: "textbox", name: "Display name", value: "Ada",
                                   state: ["enabled", "editable"],
                                   bbox: .init(x: 1, y: 2, width: 80, height: 12), inView: true)
        let submit = button(id: 6, name: "Submit")
        let frame = frame(scope: scope, elements: [textbox, submit])
        let action = AgentAction.type(target: .element(id: 5), text: "Ada Lovelace; submit later", mode: .replace)
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
                                   allowPolicy: TestAllowPolicy())

        let result = try gate.evaluate(AgentResolvedAction(action: action, frame: frame, targets: [textbox]),
                                       expectedScope: scope).result
        XCTAssertEqual(result.decision, .allowed)
        XCTAssertEqual(result.riskTier, "low")
    }

    func testEnterOnAFormRequiresHighRiskApproval() throws {
        let scope = webScope()
        let field = AgentElement(id: 10, role: "textbox", name: "Search", value: "", state: ["enabled"],
                                 bbox: .init(x: 1, y: 1, width: 50, height: 12), inView: true)
        let focus = AgentFocus(id: 10, role: "textbox", name: "Search", valuePrefix: "",
                               selection: .init(start: 0, end: 0))
        let frame = frame(scope: scope, elements: [field], focus: focus)
        let action = AgentAction.key(chord: "enter")
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
                                   allowPolicy: TestAllowPolicy())

        let result = try gate.evaluate(AgentResolvedAction(action: action, frame: frame, targets: []),
                                       expectedScope: scope)
        XCTAssertEqual(result.result.decision, .needsApproval)
        XCTAssertEqual(result.approval?.riskTier, .high)
    }

    func testApprovalFingerprintBindsNonsecureFormValues() throws {
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let scope = webScope()
        let send = button(id: 1, name: "Send")
        let originalField = AgentElement(id: 2, role: "textbox", name: "Message", value: "Original",
                                         state: ["enabled", "editable"],
                                         bbox: .init(x: 2, y: 3, width: 100, height: 20), inView: true)
        let action = AgentAction.click(target: .element(id: 1), button: nil, count: nil)
        let originalFrame = frame(scope: scope, elements: [send, originalField])
        let approval = try XCTUnwrap(gate.evaluate(AgentResolvedAction(action: action, frame: originalFrame,
                                                                       targets: [send]), expectedScope: scope).approval)
        let changedField = AgentElement(id: 2, role: "textbox", name: "Message", value: "Changed",
                                        state: ["enabled", "editable"],
                                        bbox: .init(x: 2, y: 3, width: 100, height: 20), inView: true)
        let changedFrame = frame(scope: scope, elements: [send, changedField])

        let result = try gate.resolveApproval(approval.id, approved: true,
            resolved: AgentResolvedAction(action: action, frame: changedFrame, targets: [send]),
            expectedScope: scope)
        XCTAssertEqual(result.result.decision, .rejected)
        XCTAssertTrue(result.result.reason.contains("changed"))
    }

    func testCredentialEntryIsRejectedEvenWhenSurfaceIsTrusted() throws {
        let secure = AgentElement(id: 4, role: "AXSecureTextField", name: "Account entry", value: nil,
                                  state: ["enabled"], bbox: .init(x: 1, y: 2, width: 40, height: 12), inView: true)
        let focus = AgentFocus(id: 4, role: "textbox", name: "Account entry", valuePrefix: "",
                               selection: .init(start: 0, end: 0))
        let scope = webScope()
        let frame = frame(scope: scope, elements: [secure], focus: focus)
        let action = AgentAction.type(target: nil, text: "secret material", mode: .replace)
        let resolved = AgentResolvedAction(action: action, frame: frame, targets: [])
        let store = MemoryTrustStore(trusted: ["web:https://example.test"])
        let gate = AgentActionGate(trustStore: store, allowPolicy: TestAllowPolicy())

        let result = try gate.evaluate(resolved, expectedScope: scope).result
        XCTAssertEqual(result.decision, .rejected)
        XCTAssertTrue(result.reason.contains("Credential fields are blocked"))
    }

    func testApprovalBindsCompleteHostPayloadBeyondModelVisiblePrefix() throws {
        let scope = webScope()
        let send = button(id: 1, name: "Send")
        let action = AgentAction.click(target: .element(id: 1), button: nil, count: nil)
        var original = frame(scope: scope, elements: [send])
        original.authorityDigest = String(repeating: "a", count: 64)
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let request = try XCTUnwrap(gate.evaluate(.init(action: action, frame: original, targets: [send]),
                                                 expectedScope: scope).approval)
        var changed = original
        changed.authorityDigest = String(repeating: "b", count: 64)
        let result = try gate.resolveApproval(request.id, approved: true,
            resolved: .init(action: action, frame: changed, targets: [send]), expectedScope: scope)
        XCTAssertEqual(result.result.decision, .rejected)
    }

    func testSupplyingLocalFilesRequiresApprovalOnATrustedSurface() throws {
        let scope = webScope()
        let target = button(id: 2, name: "Choose a file")
        let action = AgentAction.setFiles(target: .element(id: 2), fileIDs: ["opaque-file-id"])
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
                                   allowPolicy: TestAllowPolicy())
        let result = try gate.evaluate(.init(action: action, frame: frame(scope: scope, elements: [target]),
                                             targets: [target]), expectedScope: scope)
        XCTAssertEqual(result.result.decision, .needsApproval)
        XCTAssertEqual(result.approval?.riskTier, .high)
    }

    func testSelectCannotBypassCredentialEntryRule() throws {
        let scope = webScope()
        let secure = AgentElement(id: 4, role: "AXSecureTextField", name: "Account entry", value: nil,
                                  state: ["enabled"], bbox: .init(x: 1, y: 2, width: 40, height: 12), inView: true)
        let action = AgentAction.select(target: .element(id: 4), option: "credential material")
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
                                   allowPolicy: TestAllowPolicy())
        let result = try gate.evaluate(.init(action: action, frame: frame(scope: scope, elements: [secure]),
                                             targets: [secure]), expectedScope: scope)
        XCTAssertEqual(result.result.decision, .rejected)
        XCTAssertTrue(result.result.reason.contains("Credential fields are blocked"))
    }

    func testOpenAppWithoutRegistryIdentityIsRejectedAndCannotAuthorizeTransition() throws {
        let scope = webScope()
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let action = AgentAction.openApp(name: "Unresolved app")
        let resolved = AgentResolvedAction(action: action, frame: frame(scope: scope), targets: [])
        XCTAssertEqual(try gate.evaluate(resolved, expectedScope: scope).result.decision, .rejected)
        let appFrame = observation(surface: .app(bundleID: "com.example.unknown", title: nil))
        XCTAssertFalse(gate.matchesOpenedSurface(action: action, from: scope, observation: appFrame))
    }

    func testOpenURLTransitionRequiresExactOriginAndAppTransitionUsesResolvedBundleID() throws {
        let scope = webScope()
        let policy = TestAllowPolicy(appIdentity: "com.example.editor")
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: policy)
        let urlAction = AgentAction.openURL(url: "https://destination.example/path")
        XCTAssertTrue(gate.matchesOpenedSurface(action: urlAction, from: scope,
            observation: observation(surface: .web(url: "https://destination.example/other", title: nil))))
        XCTAssertFalse(gate.matchesOpenedSurface(action: urlAction, from: scope,
            observation: observation(surface: .web(url: "https://other.example/", title: nil))))

        let appAction = AgentAction.openApp(name: "Editor")
        XCTAssertTrue(gate.matchesOpenedSurface(action: appAction, from: scope,
            observation: observation(surface: .app(bundleID: "com.example.editor", title: nil))))
        XCTAssertFalse(gate.matchesOpenedSurface(action: appAction, from: scope,
            observation: observation(surface: .app(bundleID: "com.example.other", title: nil))))
    }

    func testTrustOriginCanonicalizesDefaultPortsAndIPv6Hosts() throws {
        let scope = webScope()
        let httpsGate = AgentActionGate(
            trustStore: MemoryTrustStore(trusted: ["web:https://destination.example"]),
            allowPolicy: TestAllowPolicy())
        let httpsAction = AgentAction.openURL(url: "https://destination.example:443/path")
        let httpsFrame = frame(scope: scope)
        let httpsResult = try httpsGate.evaluate(
            AgentResolvedAction(action: httpsAction, frame: httpsFrame, targets: []), expectedScope: scope).result
        XCTAssertEqual(httpsResult.decision, .allowed)

        let ipv6Gate = AgentActionGate(
            trustStore: MemoryTrustStore(trusted: ["web:http://[::1]"]), allowPolicy: TestAllowPolicy())
        let ipv6Action = AgentAction.openURL(url: "http://[::1]:80/path")
        let ipv6Result = try ipv6Gate.evaluate(
            AgentResolvedAction(action: ipv6Action, frame: httpsFrame, targets: []), expectedScope: scope).result
        XCTAssertEqual(ipv6Result.decision, .allowed)
    }

    private func resolved(_ action: AgentAction, scope: AgentScope,
                          elements: [AgentElement]) -> AgentResolvedAction {
        let value = frame(scope: scope, elements: elements)
        let targets: [AgentElement]
        if case let .click(target, _, _) = action, case let .element(id) = target {
            targets = elements.filter { $0.id == id }
        } else { targets = [] }
        return AgentResolvedAction(action: action, frame: value, targets: targets)
    }

    private func frame(scope: AgentScope, elements: [AgentElement] = [],
                       focus: AgentFocus? = nil) -> AgentFrame {
        AgentFrame(observation: observation(surface: .web(url: "https://example.test/", title: "Inbox"),
                                            elements: elements, focus: focus), scope: scope)
    }

    private func observation(surface: AgentSurface, elements: [AgentElement] = [],
                             focus: AgentFocus? = nil) -> AgentObservation {
        AgentObservation(task: "A generic test task", surface: surface, screenshot: "",
                         elements: elements, focus: focus, history: [], budget: .init(step: 0, maxSteps: 40))
    }

    private func button(id: Int, name: String, x: Double = 1) -> AgentElement {
        AgentElement(id: id, role: "button", name: name, value: nil, state: ["enabled"],
                     bbox: .init(x: x, y: 2, width: 40, height: 12), inView: true)
    }

    private func webScope() -> AgentScope {
        AgentScope(taskID: "task-1", kind: .web, identity: "tab-opaque-1")
    }
}

@MainActor
private final class MemoryTrustStore: AgentTrustStore {
    private var identities: Set<String>
    init(trusted: Set<String> = []) { identities = trusted }
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool {
        identities.contains("\(kind.rawValue):\(identity)")
    }
    func markTrusted(kind: AgentScope.Kind, identity: String) throws {
        identities.insert("\(kind.rawValue):\(identity)")
    }
}

@MainActor
private final class TestAllowPolicy: AgentAllowPolicy {
    private let appIdentity: String?
    init(appIdentity: String? = nil) { self.appIdentity = appIdentity }
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? {
        guard case .openApp = action, let appIdentity else { return nil }
        return AgentTrustIdentity(kind: .app, identity: appIdentity)
    }
}
