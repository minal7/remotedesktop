import CoreGraphics
import XCTest
@testable import LocalAgentKit

final class ToolDecodingTests: XCTestCase {
    func testDecodesEachShape() throws {
        XCTAssertEqual(try ToolSchema.decode(#"{"step":2,"thought":"x","tool":"click","id":12}"#).call, .click(id: 12, right: false, double: false))
        XCTAssertEqual(try ToolSchema.decode(#"{"step":1,"thought":"x","tool":"type","id":7,"text":"Hi","clear":true}"#).call,
                       .type(id: 7, text: "Hi", clear: true, submit: false))
        XCTAssertEqual(try ToolSchema.decode(#"{"step":1,"thought":"x","tool":"key","text":"cmd+s"}"#).call, .key("cmd+s"))
        XCTAssertEqual(try ToolSchema.decode(#"{"step":1,"thought":"x","tool":"done","text":"ok"}"#).call, .done("ok"))
        XCTAssertEqual(try ToolSchema.decode(#"{"step":3,"thought":"x","tool":"look"}"#).planStep, 3)
    }

    func testMissingArgumentExplainsItself() {
        XCTAssertThrowsError(try ToolSchema.decode(#"{"step":1,"thought":"x","tool":"click"}"#)) { error in
            XCTAssertTrue(String(describing: error).contains("id"))
        }
    }

    func testIgnoresTextAroundJSON() throws {
        let call = try ToolSchema.decode("```json\n{\"step\":1,\"thought\":\"a } b\",\"tool\":\"look\"}\n```").call
        XCTAssertEqual(call, .look)
    }

    func testSchemaIsValidJSONAndForcesStepFirst() throws {
        let schema = ToolSchema.decisionSchema()
        let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        XCTAssertEqual(object?["required"] as? [String], ["step", "thought", "tool"])
    }
}

final class MemoryTests: XCTestCase {
    private func memory() -> WorkingMemory { WorkingMemory(goal: "g", estimator: TokenEstimator()) }

    private func rec(_ action: String, effect: Bool = true, scene: String = "s") -> WorkingMemory.Record {
        .init(step: 0, action: action, result: "r", hadEffect: effect, fingerprint: action, sceneFingerprint: scene)
    }

    func testAdvancingFoldsFinishedDetail() {
        let m = memory()
        m.setPlan(["a", "b", "c"])
        m.record(rec("one")); m.record(rec("two"))
        m.advance(toStep: 2)
        XCTAssertTrue(m.plan[0].done)
        XCTAssertFalse(m.plan[1].done)
        XCTAssertEqual(m.records.count, 1)
        XCTAssertTrue(m.rollup.contains("Finished: a"))
    }

    func testCannotGoBackwards() {
        let m = memory()
        m.setPlan(["a", "b", "c"])
        m.advance(toStep: 3)
        m.advance(toStep: 1)
        XCTAssertEqual(m.currentPlanIndex, 2)
    }

    func testOutOfRangeStepIsIgnored() {
        let m = memory()
        m.setPlan(["a", "b"])
        m.advance(toStep: 9)
        XCTAssertEqual(m.currentPlanIndex, 0)
    }

    func testHistoryStaysInsideItsBudgetHoweverLongTheTask() {
        let estimator = TokenEstimator()
        let m = WorkingMemory(goal: "g", estimator: estimator)
        for index in 0..<500 { m.record(rec("clicked a rather long described element number \(index)")) }
        let rendered = m.renderHistory(tokens: 200)
        XCTAssertLessThan(estimator.estimate(rendered), 260)
        XCTAssertLessThanOrEqual(m.records.count, 24)
        XCTAssertTrue(rendered.contains("number 499"), "the newest action must always be visible")
    }
}

final class SupervisorTests: XCTestCase {
    private func rec(_ action: String, effect: Bool, scene: String = "s") -> WorkingMemory.Record {
        .init(step: 0, action: action, result: "r", hadEffect: effect, fingerprint: action, sceneFingerprint: scene)
    }

    func testEscalatesAsNothingChanges() {
        var supervisor = Supervisor()
        let two = [rec("a", effect: false), rec("b", effect: false)]
        guard case .showScreenshot = supervisor.inspect(records: two, stepsSincePlanProgress: 2, sceneFingerprint: "x") else { return XCTFail() }
        let four = two + two
        guard case .replan = supervisor.inspect(records: four, stepsSincePlanProgress: 4, sceneFingerprint: "x") else { return XCTFail() }
        let seven = four + four
        guard case .askForHelp = supervisor.inspect(records: seven, stepsSincePlanProgress: 8, sceneFingerprint: "x") else { return XCTFail() }
    }

    /// The real failure from the first live run: File, New, File, New, each "working".
    func testCatchesLoopWhereEveryActionHasAnEffect() {
        var supervisor = Supervisor()
        let loop = (0..<6).map { rec($0 % 2 == 0 ? "click file" : "click new", effect: true, scene: "s\($0)") }
        guard case .showScreenshot = supervisor.inspect(records: loop, stepsSincePlanProgress: 6, sceneFingerprint: "x") else {
            return XCTFail("a File/New loop must be noticed even though the screen changes each time")
        }
    }

    func testAPlanStepThatDragsOnForcesReplanThenHelp() {
        var supervisor = Supervisor()
        let records = (0..<3).map { rec("action \($0)", effect: true) }
        guard case .replan = supervisor.inspect(records: records, stepsSincePlanProgress: 14, sceneFingerprint: "a") else { return XCTFail() }
        guard case .replan = supervisor.inspect(records: records, stepsSincePlanProgress: 14, sceneFingerprint: "b") else { return XCTFail() }
        guard case .askForHelp = supervisor.inspect(records: records, stepsSincePlanProgress: 14, sceneFingerprint: "c") else { return XCTFail() }
    }

    func testRefusesExactRepeatOnSameScreenOnly() {
        let records = [rec("click save", effect: false, scene: "s1")]
        XCTAssertTrue(Supervisor.isPointlessRepeat(fingerprint: "click save", isWait: false, records: records, sceneFingerprint: "s1"))
        XCTAssertFalse(Supervisor.isPointlessRepeat(fingerprint: "click save", isWait: false, records: records, sceneFingerprint: "s2"))
        XCTAssertFalse(Supervisor.isPointlessRepeat(fingerprint: "click save", isWait: true, records: records, sceneFingerprint: "s1"))
    }
}

final class SafetyTests: XCTestCase {
    private func scene(_ elements: [UIElement], app: String = "Safari", bundle: String = "com.apple.Safari") -> Scene {
        var scene = Scene()
        scene.appName = app
        scene.bundleID = bundle
        scene.elements = elements
        return scene
    }

    private func button(_ label: String, id: Int = 1) -> UIElement {
        UIElement(id: id, role: "button", label: label, frame: CGRect(x: 0, y: 0, width: 50, height: 20))
    }

    private func needsApproval(_ decision: SafetyPolicy.Decision) -> Bool {
        if case .approve = decision { return true }
        return false
    }

    func testConsequentialButtonsNeedApproval() {
        for label in ["Send", "Delete", "Buy now", "Pay $20", "Place your order", "Empty Trash", "Publish", "Move to Trash", "Submit", "Confirm purchase"] {
            let decision = SafetyPolicy().evaluate(.click(id: 1, right: false, double: false), scene: scene([button(label)]))
            XCTAssertTrue(needsApproval(decision), label)
        }
    }

    func testEverydayNavigationDoesNot() {
        for label in ["Search", "Sign in", "New", "Save", "Open", "Next", "Bookmarks", "Facebook", "Resend code", "Format", "Sender", "Postal code"] {
            let decision = SafetyPolicy().evaluate(.click(id: 1, right: false, double: false), scene: scene([button(label)]))
            XCTAssertEqual(decision, .allow, label)
        }
    }

    func testPasswordFieldsAreHandedToThePerson() {
        var field = UIElement(id: 2, role: "field", label: "Password", frame: .zero, secure: true, editable: true)
        field.handle = nil
        let decision = SafetyPolicy().evaluate(.type(id: 2, text: "hunter2", clear: false, submit: false), scene: scene([field]))
        guard case .handoff = decision else { return XCTFail("\(decision)") }
    }

    func testReturnInMessagingAppNeedsApproval() {
        XCTAssertTrue(needsApproval(SafetyPolicy().evaluate(.key("return"), scene: scene([], app: "Messages", bundle: "com.apple.MobileSMS"))))
        XCTAssertEqual(SafetyPolicy().evaluate(.key("return"), scene: scene([])), .allow)
        XCTAssertTrue(needsApproval(SafetyPolicy().evaluate(.key("cmd+return"), scene: scene([]))))
    }

    func testCommandAppsAlwaysAsk() {
        let terminal = scene([], app: "Terminal", bundle: "com.apple.Terminal")
        XCTAssertTrue(needsApproval(SafetyPolicy().evaluate(.type(id: nil, text: "rm -rf x", clear: false, submit: true), scene: terminal)))
        XCTAssertTrue(needsApproval(SafetyPolicy().evaluate(.openApp("Terminal"), scene: scene([]))))
    }

    func testKeychainIsOffLimits() {
        guard case .handoff = SafetyPolicy().evaluate(.openApp("Keychain Access"), scene: scene([])) else { return XCTFail() }
    }

    func testNonWebSchemesAreRefused() {
        guard case .refuse = SafetyPolicy().evaluate(.openURL("file:///etc/passwd"), scene: scene([])) else { return XCTFail() }
        guard case .refuse = SafetyPolicy().evaluate(.openURL("javascript:alert(1)"), scene: scene([])) else { return XCTFail() }
    }

    func testPixelClickNearAButtonIsJudgedByThatButton() {
        var s = scene([UIElement(id: 1, role: "text", label: "Delete account", frame: CGRect(x: 100, y: 100, width: 80, height: 20), source: .ocr)])
        s.windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertTrue(needsApproval(SafetyPolicy().evaluate(.clickAt(x: 140, y: 110), scene: s)))
    }

    func testCardNumbersNeedApproval() {
        XCTAssertTrue(SafetyPolicy.looksLikeCardNumber("4242 4242 4242 4242"))
        XCTAssertFalse(SafetyPolicy.looksLikeCardNumber("1234 5678 1234 5678"))
        XCTAssertFalse(SafetyPolicy.looksLikeCardNumber("hello 4242"))
    }
}

final class RenderingTests: XCTestCase {
    private func elements(_ count: Int) -> [UIElement] {
        (0..<count).map { UIElement(id: $0 + 1, role: "button", label: "Button number \($0)", frame: CGRect(x: 0, y: CGFloat($0) * 20, width: 80, height: 20)) }
    }

    func testListingFitsBudgetAndSaysWhatItDropped() {
        var scene = Scene()
        scene.appName = "A"
        scene.elements = elements(2_000)
        let estimator = TokenEstimator()
        let output = SceneRenderer.render(scene, tokens: 300, estimator: estimator)
        XCTAssertLessThan(estimator.estimate(output.text), 340)
        XCTAssertGreaterThan(output.omitted, 0)
        XCTAssertTrue(output.text.contains("find can search"))
    }

    func testFocusedAndKeywordMatchesSurviveTruncation() {
        var scene = Scene()
        scene.elements = elements(1_000)
        scene.elements[900].focused = true
        scene.elements[901].label = "Invoice export"
        let output = SceneRenderer.render(scene, tokens: 200, estimator: TokenEstimator(), keywords: ["invoice"])
        XCTAssertTrue(output.shownIDs.contains(901))
        XCTAssertTrue(output.shownIDs.contains(902))
    }

    func testOutputKeepsScreenOrder() {
        var scene = Scene()
        scene.elements = elements(5)
        scene.elements[4].focused = true
        let output = SceneRenderer.render(scene, tokens: 500, estimator: TokenEstimator())
        let first = output.text.range(of: "Button number 0")!.lowerBound
        let last = output.text.range(of: "Button number 4")!.lowerBound
        XCTAssertLessThan(first, last)
    }

    func testPasswordValuesNeverRender() {
        let element = UIElement(id: 1, role: "field", label: "Password", value: "hunter2", frame: .zero, secure: true, editable: true)
        XCTAssertFalse(SceneRenderer.line(for: element).contains("hunter2"))
    }
}

final class AllocatorTests: XCTestCase {
    func testIDsSurviveMovesAndStayUnique() {
        let allocator = ElementIDAllocator()
        var first = [UIElement(role: "button", label: "Save", frame: CGRect(x: 10, y: 10, width: 50, height: 20)),
                     UIElement(role: "button", label: "Save", frame: CGRect(x: 10, y: 400, width: 50, height: 20))]
        allocator.assign(&first)
        XCTAssertNotEqual(first[0].id, first[1].id)
        var moved = [UIElement(role: "button", label: "Save", frame: CGRect(x: 10, y: 10, width: 50, height: 20)),
                     UIElement(role: "button", label: "Save", frame: CGRect(x: 300, y: 700, width: 50, height: 20))]
        allocator.assign(&moved)
        XCTAssertEqual(moved[0].id, first[0].id)
        XCTAssertEqual(moved[1].id, first[1].id)
    }
}

final class DiffTests: XCTestCase {
    func testNoChangeIsSaidPlainly() {
        var scene = Scene()
        scene.elements = [UIElement(id: 1, role: "button", label: "A", frame: .zero)]
        let diff = SceneDiff(from: scene, to: scene)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summary, "nothing changed on screen")
    }

    func testSecureValuesNeverAppearInDiff() {
        var old = Scene(), new = Scene()
        old.elements = [UIElement(id: 1, role: "field", label: "Password", value: "a", frame: .zero, secure: true)]
        new.elements = [UIElement(id: 1, role: "field", label: "Password", value: "hunter2", frame: .zero, secure: true)]
        XCTAssertFalse(SceneDiff(from: old, to: new).summary.contains("hunter2"))
    }
}

final class KeyMapTests: XCTestCase {
    func testParsesCommonChords() throws {
        XCTAssertEqual(try KeyMap.parse("cmd+s").code, 1)
        XCTAssertTrue(try KeyMap.parse("Command + Shift + G").flags.contains([.maskCommand, .maskShift]))
        XCTAssertEqual(try KeyMap.parse("Return").code, 36)
        XCTAssertEqual(try KeyMap.parse("arrowdown").code, 125)
        XCTAssertThrowsError(try KeyMap.parse("hyper+s"))
    }
}

final class ChunkingTests: XCTestCase {
    func testChunksRespectSizeAndCap() {
        let text = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
        let chunks = AgentHarness.chunk(text, size: 500, maximumChunks: 3)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 520 })
    }
}

final class LegacyFocusTests: XCTestCase {
    private func label(_ text: String, x: CGFloat = 40, source: UIElement.Source = .ocr) -> UIElement {
        UIElement(id: 1, role: "text", label: text, frame: CGRect(x: x, y: 100, width: 70, height: 16), source: source)
    }

    func testAimsPastAPixelLabelIntoItsField() {
        var scene = Scene()
        scene.windowFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let point = Actuator.focusPoint(for: label("Customer:"), in: scene)
        XCTAssertEqual(point.x, 150)
        XCTAssertEqual(point.y, 108)
    }

    func testClicksTheElementItselfWhenItsARealControl() {
        var scene = Scene()
        scene.windowFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let element = label("Customer:", source: .accessibility)
        XCTAssertEqual(Actuator.focusPoint(for: element, in: scene), element.center)
    }

    func testStaysInsideTheWindow() {
        var scene = Scene()
        scene.windowFrame = CGRect(x: 0, y: 0, width: 120, height: 400)
        let element = label("Customer:")
        XCTAssertEqual(Actuator.focusPoint(for: element, in: scene), element.center)
    }
}

final class PreflightTests: XCTestCase {
    private func first(_ goal: String, url: String? = nil, apps: Set<String> = ["calculator", "disk utility"]) -> ToolCall? {
        Preflight.firstAction(for: goal, currentURL: url) { apps.contains($0.lowercased()) }
    }

    func testAddressInTheGoalIsOpenedDirectly() {
        XCTAssertEqual(first("Go to http://example.com/shop and buy a lamp"), .openURL("http://example.com/shop"))
        XCTAssertNil(first("Check the price", url: "http://example.com/shop"))
        XCTAssertNil(first("On http://example.com/shop check the price", url: "http://example.com/shop?q=1"))
    }

    func testOpensANamedAppOnlyWhenItExists() {
        XCTAssertEqual(first("Open Calculator and work out 2+2"), .openApp("Calculator"))
        XCTAssertEqual(first("please open Disk Utility."), .openApp("Disk Utility"))
        XCTAssertEqual(first("Open the Calculator app".replacingOccurrences(of: "the ", with: "")), .openApp("Calculator"))
        XCTAssertNil(first("Open my budget spreadsheet"))
        XCTAssertNil(first("Work out 2+2"))
    }
}

final class NoiseTests: XCTestCase {
    private func e(_ role: String, _ label: String) -> UIElement { UIElement(role: role, label: label, frame: .zero) }

    func testDropsRepeatsFragmentsAndMachineNames() {
        let kept = SceneBuilder.removeNoise([e("button", "Corner Shop"), e("text", "Corner Shop"), e("text", " · "), e("text", "Search products"), e("field", "Search products"),
                                             e("tab", "1f74777efe804451a44c01b1baa8e342")])
        XCTAssertEqual(kept.map(\.role), ["button", "field", "tab"])
        XCTAssertEqual(kept.last?.label, "")
    }

    func testKeepsTextThatIsActuallyContent() {
        let kept = SceneBuilder.removeNoise([e("text", "Total"), e("text", "$41.20"), e("button", "Pay")])
        XCTAssertEqual(kept.count, 3)
    }
}

final class SchemaConstraintTests: XCTestCase {
    func testIDsAreLimitedToThoseGiven() throws {
        let schema = ToolSchema.decisionSchema(ids: [3, 9])
        let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        let properties = object?["properties"] as? [String: Any]
        XCTAssertEqual((properties?["id"] as? [String: Any])?["enum"] as? [Int], [3, 9])
    }
}

final class EmptyReplyTests: XCTestCase {
    func testEmptyOrGarbageRepliesAreCorrectableNotFatal() {
        for reply in ["", "   ", "not json", "{"] {
            XCTAssertThrowsError(try ToolSchema.decode(reply)) { XCTAssertTrue($0 is ToolSchema.DecodeError, reply) }
        }
    }
}

final class CorrectionTests: XCTestCase {
    private func scene(_ elements: [UIElement]) -> Scene { var s = Scene(); s.elements = elements; return s }

    func testKeysThatAreReallyTextBecomeTyping() {
        XCTAssertEqual(AgentHarness.corrected(.key("34"), in: scene([])), .type(id: nil, text: "34", clear: false, submit: false))
        XCTAssertEqual(AgentHarness.corrected(.key("cmd+s"), in: scene([])), .key("cmd+s"))
        XCTAssertEqual(AgentHarness.corrected(.key("return"), in: scene([])), .key("return"))
    }

    func testTypingAtAKeypadUsesTheKeyboardButNotWhenFieldsExist() {
        let button = UIElement(id: 3, role: "button", label: "3", frame: .zero)
        let field = UIElement(id: 4, role: "field", label: "Name", frame: .zero, editable: true)
        XCTAssertEqual(AgentHarness.corrected(.type(id: 3, text: "34", clear: false, submit: false), in: scene([button])),
                       .type(id: nil, text: "34", clear: false, submit: false))
        XCTAssertEqual(AgentHarness.corrected(.type(id: 3, text: "34", clear: false, submit: false), in: scene([button, field])),
                       .type(id: 3, text: "34", clear: false, submit: false))
    }

    func testGoToFolderSheetGetsItsReturn() {
        let label = UIElement(id: 1, role: "text", label: "Go to:", frame: .zero, source: .ocr)
        let field = UIElement(id: 2, role: "field", label: "", frame: .zero, focused: true, editable: true)
        XCTAssertEqual(AgentHarness.corrected(.type(id: 1, text: "/Users/a/b", clear: false, submit: false), in: scene([label, field])),
                       .type(id: 2, text: "/Users/a/b", clear: true, submit: true))
        XCTAssertEqual(AgentHarness.corrected(.type(id: nil, text: "/Users/a/b", clear: true, submit: false), in: scene([])),
                       .type(id: nil, text: "/Users/a/b", clear: true, submit: false))
    }
}
