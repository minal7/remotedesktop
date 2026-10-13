import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentActionGateTests: XCTestCase {
    func testIrreversibleApprovalIgnoresCoordinatesAndUnrelatedPageState() throws {
        let store = MemoryTrustStore(), gate = AgentActionGate(trustStore: store, allowPolicy: TestAllowPolicy())
        let scope = webScope(), action = AgentAction.click(target: .element(id: 3), button: nil, count: nil)
        let initial = element(3, "button", "Send")
        let approval = try XCTUnwrap(gate.evaluate(resolved(action, scope, elements: [initial]), expectedScope: scope).approval)
        let unrelated = element(55, "textbox", "Comment", value: "Changed page text", x: 88)
        let movedTarget = element(99, "button", "Send", x: 200)
        let moved = resolved(.click(target: .element(id: 99), button: nil, count: nil), scope,
                             elements: [movedTarget, unrelated], title: "Another title")
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true, resolved: moved,
                                                expectedScope: scope).result.decision, .allowed)
        XCTAssertTrue(try store.isTrusted(kind: .web, identity: "https://example.test"))
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true, resolved: moved,
                                                expectedScope: scope).result.decision, .rejected)
    }

    func testChangedPointCoordinateInvalidatesApproval() throws {
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy()), scope = webScope()
        let original = resolved(.click(target: .point(x: 10, y: 20), button: nil, count: nil), scope, label: "Send")
        let approval = try XCTUnwrap(gate.evaluate(original, expectedScope: scope).approval)
        let moved = resolved(.click(target: .point(x: 11, y: 20), button: nil, count: nil), scope, label: "Send")
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true, resolved: moved,
                                                expectedScope: scope).result.decision, .rejected)
    }

    func testTargetLabelChangeInvalidatesAndConsumesApproval() throws {
        let gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy()), scope = webScope()
        let action = AgentAction.click(target: .point(x: 10, y: 10), button: nil, count: nil)
        let approval = try XCTUnwrap(gate.evaluate(resolved(action, scope, label: "Continue"), expectedScope: scope).approval)
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true,
            resolved: resolved(action, scope, label: "Delete"), expectedScope: scope).result.decision, .rejected)
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true,
            resolved: resolved(action, scope, label: "Continue"), expectedScope: scope).result.decision, .rejected)
    }

    func testOCRContextLabelRequiresIrreversibleApproval() throws {
        let scope = webScope()
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let result = try gate.evaluate(resolved(.click(target: .point(x: 10, y: 20), button: nil, count: nil),
                                                scope, label: "Delete"), expectedScope: scope)
        XCTAssertEqual(result.result.decision, .needsApproval)
        XCTAssertEqual(result.approval?.riskTier, .high)
    }

    func testOrdinaryTypingIsNotHighRiskBecausePageHasSubmitControl() throws {
        let scope = webScope(), field = element(5, "textbox", "Display name", value: "Ada")
        let submit = element(6, "button", "Submit")
        let action = AgentAction.type(target: .element(id: 5), text: "Ada; submit later", mode: .replace)
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let result = try gate.evaluate(.init(action: action, frame: frame(scope, elements: [field, submit]), targets: [field]),
                                       expectedScope: scope).result
        XCTAssertEqual(result.decision, .allowed)
        XCTAssertEqual(result.riskTier, "low")
    }

    func testEnterNeedsApprovalOnlyWhenCommitButtonIsPresent() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let field = element(10, "textbox", "Search", value: "")
        let plain = AgentResolvedAction(action: .key(chord: "enter"), frame: frame(scope, elements: [field]), targets: [])
        XCTAssertEqual(try gate.evaluate(plain, expectedScope: scope).result.decision, .allowed)
        let misleadingField = element(12, "textbox", "Submit", value: "")
        let noButton = AgentResolvedAction(action: .key(chord: "enter"), frame: frame(scope, elements: [misleadingField]), targets: [misleadingField])
        XCTAssertEqual(try gate.evaluate(noButton, expectedScope: scope).result.decision, .allowed)
        let submit = element(11, "button", "Submit")
        let commit = AgentResolvedAction(action: .key(chord: "enter"), frame: frame(scope, elements: [field, submit]), targets: [])
        XCTAssertEqual(try gate.evaluate(commit, expectedScope: scope).result.decision, .needsApproval)
    }

    func testApprovalBindsActionTypedTextAndFullURL() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let original = resolved(.type(target: nil, text: "send this", mode: .append), scope, label: "Submit")
        let textApproval = try XCTUnwrap(gate.evaluate(original, expectedScope: scope).approval)
        XCTAssertEqual(try gate.resolveApproval(textApproval.id, approved: true,
            resolved: resolved(.type(target: nil, text: "send that", mode: .append), scope, label: "Submit"),
            expectedScope: scope).result.decision, .rejected)
        let actionApproval = try XCTUnwrap(gate.evaluate(original, expectedScope: scope).approval)
        XCTAssertEqual(try gate.resolveApproval(actionApproval.id, approved: true,
            resolved: resolved(.type(target: nil, text: "send this", mode: .replace), scope, label: "Submit"),
            expectedScope: scope).result.decision, .rejected)
        let urlApproval = try XCTUnwrap(gate.evaluate(original, expectedScope: scope).approval)
        XCTAssertEqual(try gate.resolveApproval(urlApproval.id, approved: true,
            resolved: resolved(original.action, scope, url: "https://example.test/other", label: "Submit"),
            expectedScope: scope).result.decision, .rejected)
    }

    func testApprovalRejectsDifferentTaskAndDeclineIsOneShot() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let action = resolved(.click(target: .point(x: 1, y: 1), button: nil, count: nil), scope, label: "Send")
        let stale = try XCTUnwrap(gate.evaluate(action, expectedScope: scope).approval)
        let other = AgentScope(taskID: "other-task", kind: scope.kind, identity: scope.identity)
        XCTAssertEqual(try gate.resolveApproval(stale.id, approved: true, resolved: action, expectedScope: other).result.decision, .rejected)
        let declined = try XCTUnwrap(gate.evaluate(action, expectedScope: scope).approval)
        let denial = try gate.resolveApproval(declined.id, approved: false, resolved: action, expectedScope: scope)
        XCTAssertEqual(denial.result.decision, .rejected)
        XCTAssertEqual(denial.result.reason, "rejected: user declined")
        XCTAssertEqual(try gate.resolveApproval(declined.id, approved: true, resolved: action, expectedScope: scope).result.decision, .rejected)
    }

    func testReadOnlySurfaceRejectsMutationsWithoutElementsAndAllowsScrolling() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let frame = frame(scope)
        let type = AgentResolvedAction(action: .type(target: nil, text: "change", mode: .append), frame: frame, targets: [], surfaceReadOnly: true)
        let key = AgentResolvedAction(action: .key(chord: "enter"), frame: frame, targets: [], surfaceReadOnly: true)
        let scroll = AgentResolvedAction(action: .scroll(target: nil, direction: .down, amount: 20), frame: frame, targets: [], surfaceReadOnly: true)
        XCTAssertEqual(try gate.evaluate(type, expectedScope: scope).result.decision, .rejected)
        XCTAssertEqual(try gate.evaluate(key, expectedScope: scope).result.decision, .rejected)
        XCTAssertEqual(try gate.evaluate(scroll, expectedScope: scope).result.decision, .allowed)
    }

    func testSecureAndCredentialFieldsAreBlockedWhenTrusted() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let secure = element(4, "AXSecureTextField", "Account entry", value: nil)
        let focus = AgentFocus(id: 4, role: "textbox", name: "Account entry", valuePrefix: "", selection: .init(start: 0, end: 0))
        let secureFrame = frame(scope, elements: [secure], focus: focus)
        for action in [AgentAction.type(target: nil, text: "private", mode: .replace), .select(target: .element(id: 4), option: "private")] {
            let result = try gate.evaluate(.init(action: action, frame: secureFrame, targets: [secure]), expectedScope: scope).result
            XCTAssertEqual(result.decision, .rejected)
            XCTAssertTrue(result.reason.contains("Credential fields are blocked"))
        }
        let code = element(5, "textfield", "One-time code", value: "")
        XCTAssertEqual(try gate.evaluate(.init(action: .type(target: .element(id: 5), text: "123456", mode: .replace),
            frame: frame(scope, elements: [code]), targets: [code]), expectedScope: scope).result.decision, .rejected)
    }

    func testSupplyingFilesAlwaysRequiresApproval() throws {
        let scope = webScope(), target = element(2, "button", "Choose a file")
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let result = try gate.evaluate(.init(action: .setFiles(target: .element(id: 2), fileIDs: ["opaque-file-id"]),
            frame: frame(scope, elements: [target]), targets: [target]), expectedScope: scope)
        XCTAssertEqual(result.result.decision, .needsApproval)
        XCTAssertEqual(result.approval?.riskTier, .high)
    }

    func testOpenAppNeedsRegistryIdentityAndOpenedSurfaceMatch() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let unknown = AgentAction.openApp(name: "Unknown")
        XCTAssertEqual(try gate.evaluate(.init(action: unknown, frame: frame(scope), targets: []), expectedScope: scope).result.decision, .rejected)
        XCTAssertFalse(gate.matchesOpenedSurface(action: unknown, from: scope, observation: observation(.app(bundleID: "com.example.unknown", title: nil))))
        let known = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy(appIdentity: "com.example.editor"))
        XCTAssertTrue(known.matchesOpenedSurface(action: .openApp(name: "Editor"), from: scope,
            observation: observation(.app(bundleID: "com.example.editor", title: nil))))
    }

    func testOpenURLTransitionAndCanonicalTrustOrigin() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let action = AgentAction.openURL(url: "https://destination.example/path")
        XCTAssertTrue(gate.matchesOpenedSurface(action: action, from: scope,
            observation: observation(.web(url: "https://destination.example/other", title: nil))))
        XCTAssertFalse(gate.matchesOpenedSurface(action: action, from: scope,
            observation: observation(.web(url: "https://other.example/", title: nil))))
        let store = MemoryTrustStore(trusted: ["web:https://destination.example", "web:http://[::1]"])
        let trusted = AgentActionGate(trustStore: store, allowPolicy: TestAllowPolicy())
        for url in ["https://destination.example:443/path", "http://[::1]:80/path"] {
            XCTAssertEqual(try trusted.evaluate(.init(action: .openURL(url: url), frame: frame(scope), targets: []),
                                                expectedScope: scope).result.decision, .allowed)
        }
    }

    private func resolved(_ action: AgentAction, _ scope: AgentScope, elements: [AgentElement] = [],
                          title: String = "Inbox", url: String = "https://example.test/", label: String? = nil) -> AgentResolvedAction {
        let targets: [AgentElement]
        if case .click(.element(let id), _, _) = action { targets = elements.filter { $0.id == id } }
        else if case .type(.some(.element(let id)), _, _) = action { targets = elements.filter { $0.id == id } }
        else { targets = [] }
        return .init(action: action, frame: frame(scope, elements: elements, title: title, url: url), targets: targets, targetContextLabel: label)
    }
    private func frame(_ scope: AgentScope, elements: [AgentElement] = [], focus: AgentFocus? = nil,
                       title: String = "Inbox", url: String = "https://example.test/") -> AgentFrame {
        .init(observation: observation(.web(url: url, title: title), elements: elements, focus: focus), scope: scope)
    }
    private func observation(_ surface: AgentSurface, elements: [AgentElement] = [], focus: AgentFocus? = nil) -> AgentObservation {
        .init(task: "A generic test task", surface: surface, screenshot: "", elements: elements, focus: focus,
              history: [], budget: .init(step: 0, maxSteps: 40))
    }
    private func element(_ id: Int, _ role: String, _ name: String, value: String? = nil, x: Double = 1) -> AgentElement {
        .init(id: id, role: role, name: name, value: value, state: ["enabled"], bbox: .init(x: x, y: 2, width: 40, height: 12), inView: true)
    }
    private func webScope() -> AgentScope { .init(taskID: "task-1", kind: .web, identity: "tab-opaque-1") }
}

@MainActor private final class MemoryTrustStore: AgentTrustStore {
    private var identities: Set<String>
    init(trusted: Set<String> = []) { identities = trusted }
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool { identities.contains("\(kind.rawValue):\(identity)") }
    func markTrusted(kind: AgentScope.Kind, identity: String) throws { identities.insert("\(kind.rawValue):\(identity)") }
}
@MainActor private final class TestAllowPolicy: AgentAllowPolicy {
    private let appIdentity: String?
    init(appIdentity: String? = nil) { self.appIdentity = appIdentity }
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? {
        guard case .openApp = action, let appIdentity else { return nil }
        return .init(kind: .app, identity: appIdentity)
    }
}
