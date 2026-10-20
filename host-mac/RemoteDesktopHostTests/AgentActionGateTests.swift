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

    func testWebEnterAndReturnRequireApprovalWithoutReliableNonCommitSemantics() throws {
        let scope = webScope()
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let country = element(12, "AXPopUpButton", "Country")
        let countryFocus = AgentFocus(id: 12, role: "AXPopUpButton", name: "Country", valuePrefix: "", selection: .init(start: 0, end: 0))
        let ambiguous = AgentResolvedAction(action: .key(chord: "enter"), frame: frame(scope, elements: [country], focus: countryFocus), targets: [])
        let approval = try XCTUnwrap(gate.evaluate(ambiguous, expectedScope: scope).approval)
        XCTAssertEqual(approval.riskTier, .high)
        let exactApproval = try XCTUnwrap(gate.evaluate(ambiguous, expectedScope: scope).approval)
        XCTAssertEqual(try gate.resolveApproval(exactApproval.id, approved: true, resolved: ambiguous, expectedScope: scope).result.decision, .allowed)
        XCTAssertEqual(try gate.resolveApproval(exactApproval.id, approved: true, resolved: ambiguous, expectedScope: scope).result.decision, .rejected)

        let changedFocus = AgentFocus(id: 13, role: "AXTextArea", name: "Message", valuePrefix: "", selection: .init(start: 0, end: 0))
        let textArea = element(13, "AXTextArea", "Message")
        let textareaEnter = AgentResolvedAction(action: .key(chord: "enter"), frame: frame(scope, elements: [textArea], focus: changedFocus), targets: [])
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true, resolved: textareaEnter, expectedScope: scope).result.decision, .rejected)

        let textareaApproval = try XCTUnwrap(gate.evaluate(textareaEnter, expectedScope: scope).approval)
        XCTAssertEqual(textareaApproval.riskTier, .high)
        let declined = try gate.resolveApproval(textareaApproval.id, approved: false, resolved: textareaEnter, expectedScope: scope)
        XCTAssertEqual(declined.result.decision, .rejected)
        XCTAssertEqual(try gate.resolveApproval(textareaApproval.id, approved: true, resolved: textareaEnter, expectedScope: scope).result.decision, .rejected)

        let returnKey = AgentResolvedAction(action: .key(chord: "return"), frame: frame(scope), targets: [])
        XCTAssertEqual(try gate.evaluate(returnKey, expectedScope: scope).result.decision, .needsApproval)
        let navigation = AgentResolvedAction(action: .key(chord: "tab"), frame: frame(scope), targets: [])
        XCTAssertEqual(try gate.evaluate(navigation, expectedScope: scope).result.decision, .allowed)
    }

    func testNativeEnterKeepsOrdinaryFileActionsLowRiskAndRiskyLabelsHigh() throws {
        let scope = AgentScope(taskID: "task-1", kind: .app, identity: "com.example.editor")
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["app:com.example.editor"]), allowPolicy: TestAllowPolicy())
        let save = element(20, "AXButton", "Save")
        let saveEnter = AgentResolvedAction(action: .key(chord: "enter"), frame: .init(observation: observation(.app(bundleID: "com.example.editor", title: "Document"), elements: [save]), scope: scope), targets: [])
        XCTAssertEqual(try gate.evaluate(saveEnter, expectedScope: scope).result.decision, .allowed)
        let replace = element(21, "AXButton", "Replace")
        let replaceEnter = AgentResolvedAction(action: .key(chord: "enter"), frame: .init(observation: observation(.app(bundleID: "com.example.editor", title: "Document"), elements: [replace]), scope: scope), targets: [])
        XCTAssertEqual(try gate.evaluate(replaceEnter, expectedScope: scope).result.decision, .needsApproval)
        let delete = element(22, "AXButton", "Delete")
        let deleteEnter = AgentResolvedAction(action: .key(chord: "enter"), frame: .init(observation: observation(.app(bundleID: "com.example.editor", title: "Document"), elements: [delete]), scope: scope), targets: [])
        XCTAssertEqual(try gate.evaluate(deleteEnter, expectedScope: scope).result.decision, .needsApproval)
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
            XCTAssertEqual(result.reason, "Credentials require you to take over on your Mac; never send passwords or codes in chat.")
        }
        let code = element(5, "textfield", "One-time code", value: "")
        XCTAssertEqual(try gate.evaluate(.init(action: .type(target: .element(id: 5), text: "123456", mode: .replace),
            frame: frame(scope, elements: [code]), targets: [code]), expectedScope: scope).result.decision, .rejected)
    }

    func testCredentialLanguageInQuestionsAndCompletionAlwaysRequiresOwnerHandoff() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        for action in [AgentAction.askUser(question: "Please provide your credentials to continue.", choices: ["Password", "Verification code"]),
                       .done(answer: "Credentials verified; no further value is needed."),
                       .fail(reason: "Your passcode was checked; I will stop here.")] {
            let result = try gate.evaluate(resolved(action, scope), expectedScope: scope).result
            XCTAssertEqual(result.decision, .rejected)
            XCTAssertEqual(result.reason, "Credentials require you to take over on your Mac; never send passwords or codes in chat.")
        }
        let ordinary = AgentAction.askUser(question: "Which option should I choose?", choices: ["A", "B"])
        XCTAssertEqual(try gate.evaluate(resolved(ordinary, scope), expectedScope: scope).result.decision, .allowed)
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

    func testOrdinaryDisplayOrderStaysLowWhileCommitAndDestructiveLabelsStayHigh() throws {
        let scope = webScope()
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
            allowPolicy: TestAllowPolicy())
        let safeLabels = ["Display order", "Sort order", "Reading order", "Save", "Save As", "Create", "New Folder", "Rename"]
        for label in safeLabels {
            let resolved = resolved(.click(target: .point(x: 10, y: 10), button: nil, count: nil), scope, label: label)
            let result = try gate.evaluate(resolved, expectedScope: scope).result
            XCTAssertEqual(result.decision, .allowed, label)
            XCTAssertEqual(result.riskTier, "low", label)
        }
        let highLabels = ["Order", "Order tickets", "Order online", "Order $10", "Order now", "Place order",
            "Place an order", "Complete order", "Confirm order", "Confirm the order", "Confirm your order",
            "Commit changes", "Replace existing file", "Overwrite", "Delete", "Move to Trash", "Share"]
        for label in highLabels {
            let resolved = resolved(.click(target: .point(x: 10, y: 10), button: nil, count: nil), scope, label: label)
            let result = try gate.evaluate(resolved, expectedScope: scope).result
            XCTAssertEqual(result.decision, .needsApproval, label)
            XCTAssertEqual(result.riskTier, "high", label)
        }

        let displayOrderButton = element(40, "AXButton", "Display order")
        let enterDisplayOrder = AgentResolvedAction(action: .key(chord: "enter"),
            frame: frame(scope, elements: [displayOrderButton]), targets: [])
        XCTAssertEqual(try gate.evaluate(enterDisplayOrder, expectedScope: scope).result.decision, .needsApproval,
            "Web Enter remains ambiguous even when a nearby button label is low risk; its classification differs from clicking that button.")
        let orderButton = element(41, "AXButton", "Order")
        let clickOrder = resolved(.click(target: .element(id: 41), button: nil, count: nil), scope,
            elements: [orderButton])
        XCTAssertEqual(try gate.evaluate(clickOrder, expectedScope: scope).result.decision, .needsApproval)

        let untrustedGate = AgentActionGate(trustStore: MemoryTrustStore(), allowPolicy: TestAllowPolicy())
        let untrustedDisplayOrder = resolved(.click(target: .point(x: 10, y: 10), button: nil, count: nil),
            scope, label: "Display order")
        XCTAssertEqual(try untrustedGate.evaluate(untrustedDisplayOrder, expectedScope: scope).result.decision,
            .needsApproval, "Low-risk classification must preserve first-use surface approval.")
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
