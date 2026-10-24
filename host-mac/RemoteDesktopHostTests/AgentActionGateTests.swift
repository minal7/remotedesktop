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

    func testHistoricalB1Web015CountryEnterProposalsRequireApprovalWithoutDispatch() throws {
        // Reconstructed from B1 run b1-smoke20-20261020T080335Z, episode
        // a72f146c-f5bd-4884-8d32-821292a5c2a0, steps 1 and 4. The source
        // episode SHA-256 is 76bd8fa8d77da3baa2a42aea21ce0632fc67a18dbecd11a144c31a5574b977c6.
        // Both original gate records said allowed/low; step 1 dispatched Enter.
        let scope = AgentScope(taskID: "a72f146c-f5bd-4884-8d32-821292a5c2a0",
                               kind: .web,
                               identity: "64789:1792464735.745687:4294")
        let country = AgentElement(
            id: 14, role: "AXPopUpButton", name: "Country", value: nil,
            state: ["visible"],
            bbox: .init(x: 1051.111111111111, y: 111.11111111111111,
                        width: 78.51851851851852, height: 15.555555555555555),
            inView: true)
        let countryFocus = AgentFocus(
            id: 14, role: "AXPopUpButton", name: "Country", valuePrefix: "",
            selection: .init(start: 0, end: 0))
        let gate = AgentActionGate(
            trustStore: MemoryTrustStore(trusted: ["web:http://127.0.0.1:8765"]),
            allowPolicy: TestAllowPolicy())

        for step in [1, 4] {
            let observation = AgentObservation(
                task: "Select Canada as the Country. Do not press Save.",
                surface: .web(url: "http://127.0.0.1:8765/forms.html", title: "General form controls"),
                screenshot: "",
                elements: [country],
                focus: countryFocus,
                history: [],
                budget: .init(step: step, maxSteps: 10))
            let frame = AgentFrame(observation: observation, scope: scope)
            let resolved = AgentResolvedAction(
                action: .key(chord: "Enter"), frame: frame, targets: [],
                targetContextLabel: nil, surfaceReadOnly: false)

            let evaluation = try gate.evaluate(resolved, expectedScope: scope)
            XCTAssertEqual(evaluation.result.decision, .needsApproval, "Historical B1 step \(step)")
            XCTAssertEqual(evaluation.result.riskTier, "high", "Historical B1 step \(step)")
            let approval = try XCTUnwrap(evaluation.approval)
            let declined = try gate.resolveApproval(approval.id, approved: false,
                                                    resolved: resolved, expectedScope: scope)
            XCTAssertEqual(declined.result.decision, .rejected)
            XCTAssertEqual(declined.result.reason, "rejected: user declined")
        }
        // This test has no AgentEnvironment or execute path; it only evaluates
        // the two historical proposals and declines their gate requests.
    }

    func testNativeEnterUsesFocusedAndExactDefaultButtonEvidence() throws {
        let scope = AgentScope(taskID: "task-1", kind: .app, identity: "com.example.editor")
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["app:com.example.editor"]), allowPolicy: TestAllowPolicy())
        let filename = element(20, "AXTextField", "Filename")
        let focus = AgentFocus(id: 20, role: "AXTextField", name: "Filename", valuePrefix: "", selection: .init(start: 0, end: 0))
        let unrelatedSend = element(21, "AXButton", "Send")
        func nativeFrame(_ evidence: AgentDefaultButtonEvidence, elements: [AgentElement], focus: AgentFocus?) -> AgentFrame {
            .init(observation: observation(.app(bundleID: scope.identity, title: "Document"), elements: elements, focus: focus),
                scope: scope, defaultButtonEvidence: evidence)
        }
        func enter(_ evidence: AgentDefaultButtonEvidence, elements: [AgentElement] = [filename, unrelatedSend]) -> AgentResolvedAction {
            .init(action: .key(chord: "enter"),
                frame: nativeFrame(evidence, elements: elements, focus: focus), targets: [])
        }

        XCTAssertEqual(try gate.evaluate(enter(.knownNone), expectedScope: scope).result.decision, .allowed,
            "A known absence of a default button makes unrelated window buttons irrelevant.")
        XCTAssertEqual(try gate.evaluate(enter(.button(identity: "send-1", role: "AXButton", name: "Send")),
            expectedScope: scope).result.decision, .needsApproval)
        let activeSheet = element(24, "AXSheet", "Open Dialog")
        XCTAssertEqual(try gate.evaluate(enter(.unknown, elements: [filename, unrelatedSend, activeSheet]),
            expectedScope: scope).result.decision, .needsApproval,
            "An active sheet makes the window default-button evidence unknown and stays conservative.")
        XCTAssertEqual(try gate.evaluate(enter(.button(identity: "save-1", role: "AXButton", name: "Save")),
            expectedScope: scope).result.decision, .allowed)
        XCTAssertEqual(try gate.evaluate(enter(.button(identity: "empty-1", role: "AXButton", name: "")),
            expectedScope: scope).result.decision, .needsApproval,
            "An unlabeled default button cannot be treated as harmless.")
        let modifiedEnter = AgentResolvedAction(action: .key(chord: "cmd+Return"),
            frame: nativeFrame(.button(identity: "save-1", role: "AXButton", name: "Save"),
                elements: [filename, unrelatedSend], focus: focus), targets: [])
        XCTAssertEqual(try gate.evaluate(modifiedEnter, expectedScope: scope).result.decision, .needsApproval,
            "Modified Enter shortcuts stay conservative even when the default button is ordinary.")

        let send = element(22, "AXButton", "Send")
        let sendFocus = AgentFocus(id: 22, role: "AXButton", name: "Send", valuePrefix: "", selection: .init(start: 0, end: 0))
        let focusedSend = AgentResolvedAction(action: .key(chord: "enter"),
            frame: nativeFrame(.knownNone, elements: [send], focus: sendFocus), targets: [])
        XCTAssertEqual(try gate.evaluate(focusedSend, expectedScope: scope).result.decision, .needsApproval)

        let secure = element(23, "AXSecureTextField", "Password")
        let secureFocus = AgentFocus(id: 23, role: "AXSecureTextField", name: "Password", valuePrefix: "", selection: .init(start: 0, end: 0))
        let secureEnter = AgentResolvedAction(action: .key(chord: "enter"),
            frame: nativeFrame(.unknown, elements: [secure], focus: secureFocus), targets: [])
        XCTAssertEqual(try gate.evaluate(secureEnter, expectedScope: scope).result.decision, .rejected)

        let defaultSend = enter(.button(identity: "send-1", role: "AXButton", name: "Send"))
        let approval = try XCTUnwrap(gate.evaluate(defaultSend, expectedScope: scope).approval)
        let changedDefault = enter(.knownNone)
        XCTAssertEqual(try gate.resolveApproval(approval.id, approved: true,
            resolved: changedDefault, expectedScope: scope).result.decision, .rejected,
            "Approval must be bound to the observed default button.")
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
        for action in [AgentAction.type(target: nil, text: "private", mode: .replace),
                       .key(chord: "A"),
                       .select(target: .element(id: 4), option: "private")] {
            let result = try gate.evaluate(.init(action: action, frame: secureFrame, targets: [secure]), expectedScope: scope).result
            XCTAssertEqual(result.decision, .rejected)
            XCTAssertEqual(result.reason, "Credentials require you to take over on your Mac; never send passwords or codes in chat.")
        }
        let code = element(5, "textfield", "One-time code", value: "")
        XCTAssertEqual(try gate.evaluate(.init(action: .type(target: .element(id: 5), text: "123456", mode: .replace),
            frame: frame(scope, elements: [code]), targets: [code]), expectedScope: scope).result.decision, .rejected)
    }

    func testPersonalDataRetrievalControlsAreOwnerOnlyEvenWhenTrusted() throws {
        let scope = webScope()
        let retrievalLabels = ["contact info AutoFill", "Auto Fill Credit Card", "Use Saved Passwords", "Use saved contact"]
        for trusted in [false, true] {
            let trust = trusted ? Set(["web:https://example.test"]) : []
            let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: trust), allowPolicy: TestAllowPolicy())
            for (index, label) in retrievalLabels.enumerated() {
                let control = element(60 + index, "AXButton", label)
                // The environment has resolved this point to the current visible candidate.
                let action = AgentAction.click(target: .point(x: 208, y: 168), button: nil, count: nil)
                let resolved = AgentResolvedAction(action: action,
                    frame: frame(scope, elements: [control]), targets: [control],
                    targetContextLabel: "point over \(label)")
                let result = try gate.evaluate(resolved, expectedScope: scope).result
                XCTAssertEqual(result.decision, .rejected, "\(label), trusted=\(trusted)")
                XCTAssertEqual(result.reason, AgentCredentialRule.personalDataRetrievalDeniedReason)
            }
        }
    }

    func testOrdinaryAddressEmailAndNameFieldsRemainEditable() throws {
        let scope = webScope()
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
                                   allowPolicy: TestAllowPolicy())
        for (index, label) in ["Street address", "Contact email", "Full name"].enumerated() {
            let field = element(70 + index, "AXTextField", label, value: "")
            let action = AgentAction.type(target: .element(id: field.id), text: "synthetic", mode: .replace)
            let result = try gate.evaluate(.init(action: action,
                frame: frame(scope, elements: [field]), targets: [field]), expectedScope: scope).result
            XCTAssertEqual(result.decision, .allowed, label)
        }
        for (index, label) in ["Contact information", "Credit card"].enumerated() {
            let role = index == 0 ? "AXLink" : "AXPopUpButton"
            let option = element(74 + index, role, label)
            let click = AgentResolvedAction(action: .click(target: .element(id: option.id), button: nil, count: nil),
                frame: frame(scope, elements: [option]), targets: [option])
            XCTAssertEqual(try gate.evaluate(click, expectedScope: scope).result.decision, .allowed, label)
        }
        for (index, label) in ["Use saved address", "Use stored phone number"].enumerated() {
            let source = element(77 + index, "AXButton", label)
            let click = AgentResolvedAction(action: .click(target: .element(id: source.id), button: nil, count: nil),
                frame: frame(scope, elements: [source]), targets: [source])
            XCTAssertEqual(try gate.evaluate(click, expectedScope: scope).result.reason,
                           AgentCredentialRule.personalDataRetrievalDeniedReason, label)
        }
        let retrievalSource = element(79, "AXButton", "Use saved address")
        let drag = AgentResolvedAction(action: .drag(from: .point(x: 10, y: 10), to: .point(x: 20, y: 20)),
            frame: frame(scope, elements: [retrievalSource]), targets: [retrievalSource])
        XCTAssertEqual(try gate.evaluate(drag, expectedScope: scope).result.reason,
                       AgentCredentialRule.personalDataRetrievalDeniedReason)
    }

    func testPersonalDataRetrievalKeyboardActivationIsDeniedButEscapeAndNavigationRemainAvailable() throws {
        let scope = webScope(), gate = AgentActionGate(
            trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        let control = element(76, "AXMenuItem", "Use Saved Passwords")
        let focus = AgentFocus(id: control.id, role: control.role, name: control.name,
            valuePrefix: "", selection: .init(start: 0, end: 0))
        for chord in ["Enter", "Return", "Space", "cmd+enter"] {
            let action = AgentResolvedAction(action: .key(chord: chord),
                frame: frame(scope, elements: [control], focus: focus), targets: [])
            let result = try gate.evaluate(action, expectedScope: scope).result
            XCTAssertEqual(result.decision, .rejected, chord)
            XCTAssertEqual(result.reason, AgentCredentialRule.personalDataRetrievalDeniedReason)
        }
        for chord in ["Escape", "Tab", "ArrowDown"] {
            let action = AgentResolvedAction(action: .key(chord: chord),
                frame: frame(scope, elements: [control], focus: focus), targets: [])
            XCTAssertEqual(try gate.evaluate(action, expectedScope: scope).result.decision, .allowed, chord)
        }
        let type = AgentResolvedAction(action: .type(target: .element(id: control.id), text: "synthetic", mode: .replace),
            frame: frame(scope, elements: [control], focus: focus), targets: [control])
        XCTAssertEqual(try gate.evaluate(type, expectedScope: scope).result.decision, .rejected)
    }

    func testApprovalRevalidationHardDeniesNewlyResolvedAutoFillTarget() throws {
        let scope = webScope()
        let gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]),
                                   allowPolicy: ApprovalRequiredTestPolicy())
        let ordinaryField = element(80, "AXTextField", "Street address", value: "")
        let action = AgentAction.type(target: .element(id: ordinaryField.id), text: "synthetic", mode: .replace)
        let first = AgentResolvedAction(action: action, frame: frame(scope, elements: [ordinaryField]), targets: [ordinaryField])
        let approval = try XCTUnwrap(gate.evaluate(first, expectedScope: scope).approval)

        let retrievalControl = element(80, "AXButton", "contact info AutoFill")
        let rebound = AgentResolvedAction(action: action,
            frame: frame(scope, elements: [retrievalControl]), targets: [retrievalControl],
            targetContextLabel: "contact info AutoFill")
        let result = try gate.resolveApproval(approval.id, approved: true,
            resolved: rebound, expectedScope: scope).result
        XCTAssertEqual(result.decision, .rejected)
        XCTAssertEqual(result.reason, AgentCredentialRule.personalDataRetrievalDeniedReason)
    }

    func testCredentialQuestionsRequireHandoffButTerminalReportsDoNotBlock() throws {
        let scope = webScope(), gate = AgentActionGate(trustStore: MemoryTrustStore(trusted: ["web:https://example.test"]), allowPolicy: TestAllowPolicy())
        for action in [AgentAction.askUser(question: "Please provide your password or verification code.", choices: nil),
                       .askUser(question: "Please take over and enter the verification code locally, then tell me when you're done.", choices: nil)] {
            let result = try gate.evaluate(resolved(action, scope), expectedScope: scope).result
            XCTAssertEqual(result.decision, .rejected)
            XCTAssertEqual(result.reason, "Credentials require you to take over on your Mac; never send passwords or codes in chat.")
        }
        for action in [AgentAction.done(answer: "The page shows Account password and One-time verification code fields; I did not interact with them."),
                       .fail(reason: "The page is asking for a one-time verification code; I did not enter anything.")] {
            let evaluation = try gate.evaluate(resolved(action, scope), expectedScope: scope)
            XCTAssertEqual(evaluation.result.decision, .allowed)
            XCTAssertNil(evaluation.approval)
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
                       title: String = "Inbox", url: String = "https://example.test/",
                       defaultButton: AgentDefaultButtonEvidence = .unknown) -> AgentFrame {
        .init(observation: observation(.web(url: url, title: title), elements: elements, focus: focus),
              scope: scope, defaultButtonEvidence: defaultButton)
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
@MainActor private final class ApprovalRequiredTestPolicy: AgentAllowPolicy {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision {
        .approvalRequired("Test approval required.", trustIdentity: nil)
    }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? { nil }
}
