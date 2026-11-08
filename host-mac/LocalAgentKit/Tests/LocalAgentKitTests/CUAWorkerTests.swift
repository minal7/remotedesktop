import CoreGraphics
import XCTest
@testable import LocalAgentKit

private final class FramedWorld: SceneSource, @unchecked Sendable {
    var scene: Scene
    var captures = 0
    init(_ scene: Scene) { self.scene = scene }
    func build(_ options: SceneBuilder.Options) async -> Scene { scene }
    func captureForSettling(rect: CGRect) async -> ScreenFrame? {
        captures += 1
        guard let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return nil }
        return ScreenFrame(image: image, rect: rect)
    }
}

private func call(_ arguments: String) -> String {
    "I will act.\n<tool_call>\n{\"name\":\"computer_use\",\"arguments\":{\(arguments)}}\n</tool_call>"
}
private func screen(_ labels: [(String, CGRect)] = [], title: String = "Window", secureFocus: Bool = false) -> Scene {
    var scene = Scene()
    scene.appName = "App"
    scene.bundleID = "com.example.App"
    scene.windowTitle = title
    scene.windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    scene.elements = labels.enumerated().map {
        UIElement(id: $0.offset + 1, role: "button", label: $0.element.0, frame: $0.element.1, source: .accessibility)
    }
    if secureFocus {
        scene.elements.append(UIElement(id: 99, role: "field", label: "Password", frame: CGRect(x: 0, y: 900, width: 100, height: 20),
                                        focused: true, secure: true, editable: true, source: .accessibility))
    }
    scene.fingerprint = title + labels.map(\.0).joined()
    return scene
}

final class CUADialectTests: XCTestCase {
    func testFaraClickUsesThousandGrid() {
        let reply = CUADialect.fara.parse(call(#""action":"left_click","coordinate":[500,250]"#), pointer: nil)
        XCTAssertEqual(reply.call, .pointAt(x: 500, y: 250, right: false, count: 1))
        XCTAssertEqual(reply.thought, "I will act.")
    }

    func testEvoCUAClickRescalesFromItsGrid() {
        let reply = CUADialect.evoCUA.parse("Action: Click OK\n<tool_call>\n{\"name\":\"computer_use\",\"arguments\":{\"action\":\"double_click\",\"coordinate\":[999,0]}}\n</tool_call>", pointer: nil)
        XCTAssertEqual(reply.call, .pointAt(x: 1_000, y: 0, right: false, count: 2))
        XCTAssertEqual(reply.thought, "Click OK")
    }

    func testToolCallOnOneLineAndMissingCloseBothParse() {
        let oneLine = #"<tool_call>{"name":"computer_use","arguments":{"action":"type","text":"hi"}}</tool_call>"#
        XCTAssertEqual(CUADialect.fara.parse(oneLine, pointer: nil).call, .typeAtFocus("hi"))
        let cutOff = #"<tool_call>{"name":"computer_use","arguments":{"action":"type","text":"hi"}}"#
        XCTAssertEqual(CUADialect.fara.parse(cutOff, pointer: nil).call, .typeAtFocus("hi"))
    }

    func testNoToolCallIsACorrectableProblem() {
        let reply = CUADialect.fara.parse("I think the answer is 4.", pointer: nil)
        XCTAssertNil(reply.call)
        XCTAssertNotNil(reply.problem)
    }

    func testBadCoordinatesAreRefused() {
        XCTAssertNotNil(CUADialect.fara.parse(call(#""action":"left_click","coordinate":["a"]"#), pointer: nil).problem)
        XCTAssertNotNil(CUADialect.fara.parse(call(#""action":"left_click""#), pointer: nil).problem)
        XCTAssertNotNil(CUADialect.fara.parse(call(#""action":"left_click","coordinate":[-5,10]"#), pointer: nil).problem)
    }

    func testOutOfRangeCoordinatesStayOnTheGrid() {
        let reply = CUADialect.fara.parse(call(#""action":"left_click","coordinate":[5000,20]"#), pointer: nil)
        XCTAssertEqual(reply.call, .pointAt(x: 1_000, y: 20, right: false, count: 1))
    }

    func testTerminateCarriesStatusAndAnswer() {
        let good = CUADialect.fara.parse(call(#""action":"terminate","answer":"42""#), pointer: nil)
        XCTAssertEqual(good.terminated?.success, true)
        XCTAssertEqual(good.terminated?.answer, "42")
        let bad = CUADialect.evoCUA.parse(call(#""action":"terminate","status":"failure""#), pointer: nil)
        XCTAssertEqual(bad.terminated?.success, false)
    }

    func testDragStartsWherePointerWas() {
        let reply = CUADialect.fara.parse(call(#""action":"left_click_drag","coordinate":[10,20]"#), pointer: (1, 2))
        XCTAssertEqual(reply.call, .dragAt(fromX: 1, fromY: 2, toX: 10, toY: 20))
        XCTAssertNotNil(CUADialect.fara.parse(call(#""action":"left_click_drag","coordinate":[10,20]"#), pointer: nil).problem)
    }

    func testShortcutsBecomeMacShortcuts() {
        XCTAssertEqual(CUADialect.macChord(["Control", "s"]), "cmd+s")
        XCTAssertEqual(CUADialect.macChord(["ctrl+shift+z"]), "cmd+shift+z")
        XCTAssertEqual(CUADialect.macChord(["Enter"]), "return")
        XCTAssertEqual(CUADialect.macChord(["ArrowDown"]), "down")
        XCTAssertEqual(CUADialect.macChord(["alt", "left"]), "cmd+[")
        XCTAssertEqual(CUADialect.macChord(["Home"]), "cmd+left")
        XCTAssertNil(CUADialect.macChord(["alt", "tab"]))
        XCTAssertNil(CUADialect.macChord(["notakey"]))
    }

    func testEvoPromptEmbedsItsTool() {
        XCTAssertTrue(CUADialect.evoSystemPrompt.contains("\"name\":\"computer_use\""))
        XCTAssertTrue(CUADialect.evoSystemPrompt.contains("The screen's resolution is 1000x1000"))
        XCTAssertTrue(CUADialect.faraSystemPrompt.contains("read_page_answer_question"))
    }
}

final class CUAWorkerLoopTests: XCTestCase {
    private func harness(_ model: FakeModel, _ world: FramedWorld, _ input: FakeInput, verifier: FakeModel? = nil,
                         configure: (inout HarnessConfiguration) -> Void = { _ in }) -> AgentHarness {
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.planFirst = false
        configure(&configuration)
        return AgentHarness(goal: "do the thing", model: verifier ?? FakeModel([""]), actuator: Actuator(input: input), builder: world,
                            configuration: configuration, worker: CUAWorker(model: model, dialect: .fara))
    }

    func testClickLandsWhereTheGridSaysAndTaskCompletes() async {
        let world = FramedWorld(screen([("Next", CGRect(x: 480, y: 240, width: 40, height: 20))]))
        let input = FakeInput()
        input.onClick = { _ in world.scene = screen(title: "After") }
        let model = FakeModel([call(#""action":"left_click","coordinate":[500,250]"#), call(#""action":"terminate","answer":"Finished""#)])
        let outcome = await harness(model, world, input).run()
        XCTAssertEqual(outcome, .completed(answer: "Finished", verified: true))
        XCTAssertEqual(input.clicks, [CGPoint(x: 500, y: 250)])
    }

    func testSafetyStillStopsADangerousClick() async {
        let world = FramedWorld(screen([("Delete Account", CGRect(x: 480, y: 240, width: 40, height: 20))]))
        let input = FakeInput()
        let model = FakeModel([call(#""action":"left_click","coordinate":[500,250]"#)])
        let outcome = await harness(model, world, input).run()
        guard case .needsApproval = outcome else { return XCTFail("expected approval, got \(outcome)") }
        XCTAssertTrue(input.clicks.isEmpty)
    }

    func testApprovalResumesTheSameJob() async {
        let world = FramedWorld(screen([("Delete Account", CGRect(x: 480, y: 240, width: 40, height: 20))]))
        let input = FakeInput()
        input.onClick = { _ in world.scene = screen(title: "Gone") }
        let model = FakeModel([call(#""action":"left_click","coordinate":[500,250]"#), call(#""action":"terminate","answer":"Deleted""#)])
        let agent = harness(model, world, input)
        guard case let .needsApproval(request) = await agent.run() else { return XCTFail("expected approval") }
        let outcome = await agent.resume(approval: request.id, approved: true)
        XCTAssertEqual(outcome, .completed(answer: "Deleted", verified: true))
        XCTAssertEqual(input.clicks.count, 1)
    }

    func testPasswordFieldIsHandedToThePerson() async {
        let world = FramedWorld(screen(secureFocus: true))
        let input = FakeInput()
        let outcome = await harness(FakeModel([call(#""action":"type","text":"secret""#)]), world, input).run()
        guard case .handoff = outcome else { return XCTFail("expected handoff, got \(outcome)") }
        XCTAssertTrue(input.typed.isEmpty)
    }

    func testPageTextCannotOverrideStop() async {
        let world = FramedWorld(screen())
        let input = FakeInput()
        let agent = harness(FakeModel([call(#""action":"wait","time":0.5"#)]), world, input)
        agent.cancelRequested = true
        let outcome = await agent.run()
        XCTAssertEqual(outcome, .cancelled)
    }

    func testRepeatedDeadActionsEndInsteadOfLooping() async {
        let world = FramedWorld(screen())
        let input = FakeInput()
        let model = FakeModel([call(#""action":"left_click","coordinate":[10,10]"#)])
        let outcome = await harness(model, world, input, configure: { $0.maximumSteps = 40 }).run()
        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertLessThanOrEqual(input.clicks.count, 3)
    }

    func testNoWindowMeansNoActions() async {
        var empty = screen()
        empty.windowFrame = .zero
        let world = FramedWorld(empty)
        let input = FakeInput()
        let outcome = await harness(FakeModel([call(#""action":"left_click","coordinate":[10,10]"#)]), world, input).run()
        guard case let .failed(reason) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertTrue(reason.contains("no window"), reason)
        XCTAssertTrue(input.clicks.isEmpty)
    }

    func testRepliesWithoutActionsGiveUp() async {
        let world = FramedWorld(screen())
        let outcome = await harness(FakeModel(["no idea"]), world, FakeInput()).run()
        guard case let .failed(reason) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertTrue(reason.contains("usable actions"), reason)
    }

    func testFailedCheckSendsTheWorkerBack() async {
        let world = FramedWorld(screen())
        let verifier = FakeModel([""])
        verifier.verdicts = [#"{"finished":false,"missing":"the file isn't saved"}"#, #"{"finished":true,"missing":""}"#]
        let model = FakeModel([call(#""action":"terminate","answer":"Saved""#)])
        let agent = harness(model, world, FakeInput(), verifier: verifier)
        let outcome = await agent.run()
        XCTAssertEqual(outcome, .completed(answer: "Saved", verified: true))
        let lastUser = model.prompts.last?.messages.last?.text ?? ""
        XCTAssertTrue(lastUser.contains("the file isn't saved"), lastUser)
    }

    func testOnlyTheKeptScreenshotsAreSent() async {
        let world = FramedWorld(screen())
        var answers: [String] = []
        for index in 0..<8 { answers.append(call(#""action":"left_click","coordinate":[\#(index * 100 + 50),50]"#)) }
        answers.append(call(#""action":"terminate","answer":"ok""#))
        let input = FakeInput()
        var flip = 0
        input.onClick = { _ in flip += 1; world.scene = screen(title: "T\(flip)") }
        let model = FakeModel(answers)
        _ = await harness(model, world, input).run()
        let requests = model.prompts.filter { $0.messages.first?.role == .system && $0.messages.first?.text == CUADialect.fara.systemPrompt }
        XCTAssertGreaterThan(requests.count, 6)
        for request in requests {
            XCTAssertLessThanOrEqual(request.messages.filter { $0.imageJPEG != nil }.count, CUADialect.fara.screenshotsKept)
        }
        XCTAssertTrue(requests.last?.messages.first(where: { $0.role == .user })?.text.contains("Step 1:") == true)
    }
}

final class OrchestratorTests: XCTestCase {
    private func planner(_ next: String, _ text: String, remember: [String] = [], app: String = "", url: String = "") -> String {
        let facts = remember.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"thought":"t","remember":["# + facts + #"],"next":""# + next + #"","app":""# + app + #"","url":""# + url + #"","text":""# + text + #""}"#
    }

    private func harness(planner: FakeModel, worker: FakeModel, _ world: FramedWorld, _ input: FakeInput) -> AgentHarness {
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.orchestrated = true
        return AgentHarness(goal: "do the thing", model: planner, actuator: Actuator(input: input), builder: world,
                            configuration: configuration, worker: CUAWorker(model: worker, dialect: .fara))
    }

    func testAFactFromOneJobReachesTheNext() async {
        let brain = FakeModel([planner("job", "Read the price"), planner("job", "Write the price", remember: ["Price is $89"]), planner("answer", "Wrote it")])
        let hands = FakeModel([call(#""action":"terminate","answer":"It costs $89""#), call(#""action":"terminate","answer":"Written""#)])
        let outcome = await harness(planner: brain, worker: hands, FramedWorld(screen()), FakeInput()).run()
        XCTAssertEqual(outcome, .completed(answer: "Wrote it", verified: true))
        XCTAssertTrue(hands.prompts[1].messages.contains { $0.text.contains("Price is $89") })
        XCTAssertFalse(hands.prompts[1].messages.contains { $0.text.contains("do the thing") }, "the worker only hears its own job")
        XCTAssertTrue(brain.prompts[1].messages.contains { $0.text.contains("It costs $89") })
    }

    func testThePlannerHearsAboutAFailedJob() async {
        let brain = FakeModel([planner("job", "First try"), planner("fail", "No way to do it")])
        let hands = FakeModel([call(#""action":"terminate","status":"failure","answer":"Button is missing""#)])
        let outcome = await harness(planner: brain, worker: hands, FramedWorld(screen()), FakeInput()).run()
        XCTAssertEqual(outcome, .failed(reason: "No way to do it"))
        XCTAssertTrue(brain.prompts[1].messages.contains { $0.text.contains("NOT finished: Button is missing") })
    }

    func testARejectedAnswerSendsThePlannerBackToWork() async {
        let brain = FakeModel([planner("answer", "All done"), planner("job", "Finish it"), planner("answer", "Really done")])
        let hands = FakeModel([call(#""action":"terminate","answer":"Saved""#)])
        hands.verdicts = [#"{"finished":false,"missing":"nothing was saved"}"#, #"{"finished":true,"missing":""}"#]
        let outcome = await harness(planner: brain, worker: hands, FramedWorld(screen()), FakeInput()).run()
        XCTAssertEqual(outcome, .completed(answer: "Really done", verified: true))
        XCTAssertTrue(brain.prompts.contains { $0.messages.contains { $0.text.contains("nothing was saved") } })
    }

    func testAJobsDangerousClickStillNeedsApprovalAndResumesInThatJob() async {
        let world = FramedWorld(screen([("Delete account", CGRect(x: 480, y: 240, width: 40, height: 20))]))
        let input = FakeInput()
        let brain = FakeModel([planner("job", "Delete it"), planner("answer", "Deleted")])
        let hands = FakeModel([call(#""action":"left_click","coordinate":[500,250]"#), call(#""action":"terminate","answer":"Gone""#)])
        let agent = harness(planner: brain, worker: hands, world, input)
        input.onClick = { _ in world.scene = screen(title: "After") }
        guard case let .needsApproval(request) = await agent.run() else { return XCTFail("expected an approval") }
        XCTAssertTrue(input.clicks.isEmpty)
        let outcome = await agent.resume(approval: request.id, approved: true)
        XCTAssertEqual(outcome, .completed(answer: "Deleted", verified: true))
        XCTAssertEqual(input.clicks.count, 1)
    }

    func testRepeatedFailuresAskThePerson() async {
        let brain = FakeModel([planner("job", "One"), planner("job", "Two"), planner("job", "Three")])
        let hands = FakeModel([call(#""action":"terminate","status":"failure","answer":"No""#)])
        guard case .needsAnswer = await harness(planner: brain, worker: hands, FramedWorld(screen()), FakeInput()).run() else {
            return XCTFail("expected a question")
        }
    }

    func testFollowsAppAndAddressBeforeTheJob() async {
        let input = FakeInput()
        let brain = FakeModel([planner("job", "Look", url: "http://127.0.0.1:1/a"), planner("answer", "Seen")])
        let hands = FakeModel([call(#""action":"terminate","answer":"Seen it""#)])
        let agent = harness(planner: brain, worker: hands, FramedWorld(screen()), input)
        let opened = OpenedURLs()
        agent.actuator.urlOpener = { await opened.add($0) }
        _ = await agent.run()
        let urls = await opened.urls
        XCTAssertEqual(urls.map(\.absoluteString), ["http://127.0.0.1:1/a"])
    }

    func testPlannerRepliesDecode() {
        XCTAssertEqual(PlannerDecision.decode(planner("job", "Do it", remember: ["x"], app: "Notes"))?.app, "Notes")
        XCTAssertNil(PlannerDecision.decode(#"{"next":"job","text":""}"#))
        XCTAssertNil(PlannerDecision.decode("no"))
    }
}

private actor OpenedURLs {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}

final class PointerSafetyTests: XCTestCase {
    private func scene(_ elements: [UIElement]) -> Scene {
        var scene = Scene()
        scene.appName = "Browser"
        scene.windowFrame = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        scene.elements = elements
        return scene
    }

    func testTheSelectedTabIsNotAnOrderButton() {
        let tab = UIElement(id: 1, role: "radio", label: "Order Stoneware Mug", frame: CGRect(x: 700, y: 0, width: 200, height: 30), source: .accessibility)
        XCTAssertEqual(SafetyPolicy().evaluate(.pointAt(x: 780, y: 20, right: false, count: 1), scene: scene([tab])), .allow)
    }

    func testTheLinkUnderThePointerDecidesNotItsNeighbour() {
        let order = UIElement(id: 1, role: "link", label: "Order this item", frame: CGRect(x: 100, y: 100, width: 120, height: 14), source: .accessibility)
        let back = UIElement(id: 2, role: "link", label: "Back to shop", frame: CGRect(x: 100, y: 116, width: 120, height: 14), source: .accessibility)
        XCTAssertEqual(SafetyPolicy().evaluate(.pointAt(x: 150, y: 123, right: false, count: 1), scene: scene([order, back])), .allow)
        guard case .approve = SafetyPolicy().evaluate(.pointAt(x: 150, y: 107, right: false, count: 1), scene: scene([order, back])) else {
            return XCTFail("the order link itself still needs approval")
        }
    }

    func testAMissNextToADangerousButtonStillAsks() {
        let delete = UIElement(id: 1, role: "button", label: "Delete account", frame: CGRect(x: 100, y: 100, width: 80, height: 20), source: .accessibility)
        guard case .approve = SafetyPolicy().evaluate(.pointAt(x: 190, y: 110, right: false, count: 1), scene: scene([delete])) else {
            return XCTFail("a near miss should still ask")
        }
    }

    func testAPageTitledLikeAnActionDoesNotCoverEverything() {
        let page = UIElement(id: 1, role: "text", label: "Order form", frame: CGRect(x: 0, y: 0, width: 1_000, height: 900), source: .accessibility)
        XCTAssertEqual(SafetyPolicy().evaluate(.pointAt(x: 500, y: 500, right: false, count: 1), scene: scene([page])), .allow)
    }
}

final class WorkerCorrectionTests: XCTestCase {
    func testAPlainPressThroughKeyDownWorks() {
        XCTAssertEqual(CUADialect.evoCUA.parse(call(#""action":"key_down","keys":["enter"]"#), pointer: nil).call, .key("return"))
        XCTAssertEqual(CUADialect.evoCUA.parse(call(#""action":"key_down","keys":["shift"]"#), pointer: nil).hold, ["shift"])
    }

    func testAnswersLoseMathMarkup() {
        XCTAssertEqual(CUADialect.cleanAnswer("\\boxed{58}"), "58")
        XCTAssertEqual(CUADialect.cleanAnswer(" plain "), "plain")
    }

    func testLoopsOfAnyShortLengthAreSeen() {
        func records(_ prints: [String]) -> [WorkingMemory.Record] {
            prints.enumerated().map { WorkingMemory.Record(step: $0.offset, action: $0.element, result: "r", hadEffect: true, fingerprint: $0.element, sceneFingerprint: "s") }
        }
        XCTAssertTrue(Supervisor.isCycling(records(["s", "t", "s", "t", "s", "t"])))
        XCTAssertTrue(Supervisor.isCycling(records(["a", "b", "c", "a", "b", "c", "a", "b", "c"])))
        XCTAssertFalse(Supervisor.isCycling(records(["a", "b", "a", "c", "a", "d"])))
    }

    func testASaveDialogGetsTheMacWayToChooseAFolder() {
        var scene = Scene()
        scene.elements = [UIElement(id: 1, role: "field", label: "Save As:", frame: .zero, editable: true, source: .accessibility)]
        XCTAssertTrue(Prompts.macHint(for: scene)?.contains("Command+Shift+G") == true)
        XCTAssertNil(Prompts.macHint(for: Scene()))
    }
}

final class AppMenuStripTests: XCTestCase {
    func testReachesTheAppsMenusButNotTheAppleMenuOrStatusItems() {
        let strip = ScreenCapturer.appMenuStrip(display: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 37)
        XCTAssertTrue(strip.contains(CGPoint(x: 120, y: 12)), "File menu")
        XCTAssertFalse(strip.contains(CGPoint(x: 18, y: 12)), "Apple menu")
        XCTAssertFalse(strip.contains(CGPoint(x: 1600, y: 12)), "status items")
        XCTAssertFalse(strip.contains(CGPoint(x: 120, y: 60)), "below the menu bar")
    }

    func testAHiddenMenuBarLeavesNothingToClick() {
        XCTAssertTrue(ScreenCapturer.appMenuStrip(display: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 0).isEmpty)
    }
}

final class TestRunFenceTests: XCTestCase {
    func testAppSwitchingShortcutsAreRecognised() {
        XCTAssertTrue(DirectInputSink.switchesApps(code: 48, flags: .maskCommand), "Command-Tab")
        XCTAssertTrue(DirectInputSink.switchesApps(code: 49, flags: .maskCommand), "Spotlight")
        XCTAssertFalse(DirectInputSink.switchesApps(code: 48, flags: []), "Tab between fields")
        XCTAssertFalse(DirectInputSink.switchesApps(code: 49, flags: .maskShift), "Shift-Space")
    }

    func testAFencedSinkRefusesInputAndNamesWhy() async {
        let sink = DirectInputSink(mayAct: { true }, fence: { "Zoom is in front" })
        do {
            try await sink.move(to: .zero)
            XCTFail("input went through the fence")
        } catch {
            XCTAssertTrue("\(error)".contains("Zoom"))
        }
    }
}

final class AppRoutingTests: XCTestCase {
    func testTheGoalStartsInWhicheverItNamesFirst() {
        let apps = ["LegacyInventory", "Google Chrome", "Mail"]
        func first(_ goal: String) -> ToolCall? { Preflight.firstAction(for: goal, currentURL: nil, openApps: apps) { _ in false } }
        XCTAssertEqual(first("Print from Legacy Inventory, then email it from my mail at https://mail.example.com"), .openApp("LegacyInventory"))
        XCTAssertEqual(first("Read https://news.example.com and put it in LegacyInventory"), .openURL("https://news.example.com"))
        XCTAssertEqual(first("Email Sam from my mail at https://mail.example.com"), .openURL("https://mail.example.com"), "lowercase mail isn't the app")
        XCTAssertNil(first("Tidy up my files"))
    }

    func testBareModifiersAreHeldAndOpenAppIsAvailable() {
        func reply(_ arguments: String) -> CUADialect.Reply {
            CUADialect.fara.parse("<tool_call>{\"name\":\"computer\",\"arguments\":\(arguments)}</tool_call>", pointer: nil)
        }
        XCTAssertEqual(reply(#"{"action":"key","keys":["ctrl"]}"#).hold, ["ctrl"])
        XCTAssertEqual(reply(#"{"action":"key_down","keys":["shift"]}"#).hold, ["shift"])
        XCTAssertEqual(reply(#"{"action":"key_up","keys":["shift"]}"#).hold, [])
        XCTAssertEqual(reply(#"{"action":"open_app","text":"QuickSheet"}"#).call, .openApp("QuickSheet"))
        XCTAssertEqual(reply(#"{"action":"key","keys":["ctrl","a"]}"#).hold, nil)
    }

    func testFramesAreAlwaysCapturedByApp() {
        let worker = CUAWorker(model: FakeModel([]), dialect: .fara)
        var scene = Scene()
        XCTAssertEqual(worker.frameMode(for: scene), .focus)
        scene.url = "https://example.com"
        XCTAssertEqual(worker.frameMode(for: scene), .focus)
        worker.frameOverride = .display
        XCTAssertEqual(worker.frameMode(for: scene), .display)
    }
}

final class FileDialogTests: XCTestCase {
    private func element(_ label: String, editable: Bool = false) -> UIElement {
        var element = UIElement(id: 1, role: editable ? "field" : "button", label: label, frame: .zero)
        element.editable = editable
        return element
    }
    private func picker() -> Scene {
        var scene = Scene()
        scene.elements = [element("Open"), element("Cancel")]
        return scene
    }

    func testAPathTypedIntoAPickerGoesStraightThere() {
        let plan = FileDialog.plan(typed: "LocalAgentEval/documents/a b.pdf", in: picker(), home: "/Users/me") { $0 == "/Users/me/LocalAgentEval/documents/a b.pdf" }
        XCTAssertEqual(plan, [.key("cmd+shift+g"), .key("cmd+a"), .typeAtFocus("/Users/me/LocalAgentEval/documents/a b.pdf"), .key("return")])
    }

    func testOnlyRealPathsInARealDialogAreTakenOver() {
        XCTAssertNil(FileDialog.plan(typed: "nothing/here.pdf", in: picker(), home: "/Users/me") { _ in false })
        XCTAssertNil(FileDialog.plan(typed: "report.pdf", in: picker(), home: "/Users/me") { _ in true })
        XCTAssertNil(FileDialog.plan(typed: "http://a/b", in: picker(), home: "/Users/me") { _ in true })
        XCTAssertNil(FileDialog.plan(typed: "a/b", in: Scene(), home: "/Users/me") { _ in true })
    }

    func testASaveDialogGoesToTheFolderThenNamesTheFile() {
        var scene = Scene()
        scene.elements = [element("Save As:", editable: true)]
        let plan = FileDialog.plan(typed: "~/docs/out.pdf", in: scene, home: "/Users/me") { $0.hasPrefix("/Users/me/docs") }
        XCTAssertEqual(plan, [.key("cmd+shift+g"), .key("cmd+a"), .typeAtFocus("/Users/me/docs/"), .key("return"), .key("cmd+a"), .typeAtFocus("out.pdf")])
    }

    func testATestRunCantBeSentOutOfItsFolder() {
        let root = "/Users/me/Eval"
        let real: (String) -> Bool = { $0.lowercased().hasPrefix("/users/me/documents") || $0.hasPrefix("/Users/me/Eval/documents") }
        XCTAssertTrue(FileDialog.leavesRoot(typed: "/Users/me/documents", in: picker(), root: root, home: "/Users/me", exists: real))
        XCTAssertTrue(FileDialog.leavesRoot(typed: "~/Documents/a.pdf", in: picker(), root: root, home: "/Users/me", exists: real))
        XCTAssertFalse(FileDialog.leavesRoot(typed: "documents/a.pdf", in: picker(), root: root, home: "/Users/me", exists: real), "relative means inside the test folder first")
        XCTAssertEqual(FileDialog.plan(typed: "documents/a.pdf", in: picker(), home: "/Users/me", root: root, exists: real)?[2], .typeAtFocus("/Users/me/Eval/documents/a.pdf"))
    }

    func testTheFrameKeepsOnlyTheAppsOwnAreas() {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = context.makeImage()!
        let result = ScreenCapturer.masked(image, keeping: [CGRect(x: 0, y: 0, width: 50, height: 10)], display: CGRect(x: 0, y: 0, width: 100, height: 100))!
        let bytes = CFDataGetBytePtr(result.dataProvider!.data!)!
        let row = result.bytesPerRow
        XCTAssertGreaterThan(bytes[row * 5 + 4 * 10], 200, "kept: top left, red")
        XCTAssertLessThan(bytes[row * 50 + 4 * 80], 100, "painted over: the rest")
    }
}

final class NearMissTests: XCTestCase {
    private func scene(_ frames: [CGRect]) -> Scene {
        var scene = Scene()
        scene.windowFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        scene.elements = frames.enumerated().map { UIElement(id: $0.offset, role: "button", label: "b\($0.offset)", frame: $0.element) }
        return scene
    }

    func testANarrowMissLandsOnTheButton() {
        let button = CGRect(x: 100, y: 100, width: 80, height: 20)
        XCTAssertEqual(SafetyPolicy.nearestControl(to: CGPoint(x: 140, y: 128), in: scene([button])), CGPoint(x: 140, y: 110))
    }

    func testAHitAFarMissAndATieStayPut() {
        let button = CGRect(x: 100, y: 100, width: 80, height: 20)
        XCTAssertNil(SafetyPolicy.nearestControl(to: CGPoint(x: 140, y: 110), in: scene([button])), "already on it")
        XCTAssertNil(SafetyPolicy.nearestControl(to: CGPoint(x: 140, y: 150), in: scene([button])), "too far")
        let other = CGRect(x: 100, y: 130, width: 80, height: 20)
        XCTAssertNil(SafetyPolicy.nearestControl(to: CGPoint(x: 140, y: 125), in: scene([button, other])), "could be either")
    }
}

final class WorkerConversationTests: XCTestCase {
    func testWhatWasSaidWithAScreenshotStaysThere() {
        let worker = CUAWorker(model: FakeModel([]), dialect: .fara)
        worker.begin(job: "do it")
        worker.feedback = "that missed"
        let first = worker.messages(current: Data([1]), hint: "hint")
        worker.addTurn(image: Data([1]), reply: "r", actionLine: "a")
        worker.feedback = nil
        let second = worker.messages(current: Data([2]))
        XCTAssertEqual(first[1].text, second[1].text, "an earlier turn must not change, or the cache is lost")
        XCTAssertTrue(second[1].text.contains("hint") && second[1].text.contains("that missed"))
    }

    func testAHintRepeatsOnlyWhenItChanges() {
        let worker = CUAWorker(model: FakeModel([]), dialect: .fara)
        XCTAssertEqual(worker.newHint("a"), "a")
        XCTAssertNil(worker.newHint("a"))
        XCTAssertEqual(worker.newHint("b"), "b")
    }

    func testMenuIsAnAction() {
        let raw = #"<tool_call>{"name":"computer","arguments":{"action":"menu","text":"File > Print"}}</tool_call>"#
        XCTAssertEqual(CUADialect.fara.parse(raw, pointer: nil).call, .menu("File > Print"))
    }
}

final class VerdictTests: XCTestCase {
    func testTheCheckerSaysItselfWhenItCantTell() {
        XCTAssertEqual(ToolSchema.decodeVerdict(#"{"finished":false,"missing":"a file","cannot_tell":true}"#)?.cannotTell, true)
        XCTAssertEqual(ToolSchema.decodeVerdict(#"{"finished":false,"missing":"a file","cannot_tell":false}"#)?.cannotTell, false)
        // Left out, it counts as a real problem rather than letting doubtful work through.
        XCTAssertEqual(ToolSchema.decodeVerdict(#"{"finished":false,"missing":"a file"}"#)?.cannotTell, false)
    }
}

final class WindowButtonTests: XCTestCase {
    func testTheTopLeftButtonsAreRecognised() {
        let window = CGRect(x: 100, y: 200, width: 600, height: 400)
        XCTAssertTrue(CUAWorker.isOnWindowButtons(CGPoint(x: 112, y: 212), window: window))
        XCTAssertFalse(CUAWorker.isOnWindowButtons(CGPoint(x: 300, y: 212), window: window), "the title")
        XCTAssertFalse(CUAWorker.isOnWindowButtons(CGPoint(x: 112, y: 300), window: window), "the document")
    }
}

final class FindBarSafetyTests: XCTestCase {
    func testReplaceOnlyAsksInADialog() {
        var scene = Scene()
        scene.appName = "WriteDoc"
        let button = UIElement(id: 1, role: "button", label: "Replace", frame: CGRect(x: 0, y: 0, width: 80, height: 30))
        scene.elements = [button]
        XCTAssertEqual(SafetyPolicy().evaluate(.click(id: 1, right: false, double: false), scene: scene), .allow)
        scene.hasModal = true
        guard case .approve = SafetyPolicy().evaluate(.click(id: 1, right: false, double: false), scene: scene) else { return XCTFail("a dialog's Replace should ask") }
    }
}

final class TestRunPointFenceTests: XCTestCase {
    func testTheDocksClearOverlayIsNotTheDock() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let bar = CGRect(x: 400, y: 1040, width: 900, height: 77)
        XCTAssertTrue(TestRunFence.dockPassesThrough(window: display, display: display, bar: bar, point: CGPoint(x: 335, y: 744)))
        XCTAssertFalse(TestRunFence.dockPassesThrough(window: display, display: display, bar: bar, point: CGPoint(x: 500, y: 1080)), "the icons stay off limits")
        XCTAssertFalse(TestRunFence.dockPassesThrough(window: display, display: display, bar: nil, point: CGPoint(x: 335, y: 744)), "unknown means refused")
        XCTAssertFalse(TestRunFence.dockPassesThrough(window: bar, display: display, bar: bar, point: CGPoint(x: 335, y: 744)), "a smaller Dock window is the Dock")
    }

    func testEveryPointerActionIsCheckedAgainstWhatIsUnderIt() async {
        let sink = DirectInputSink(mayAct: { true }, fence: { nil }, pointFence: { $0.x > 100 ? "Finder is there" : nil })
        let there = CGPoint(x: 200, y: 10), elsewhere = CGPoint(x: 50, y: 10)
        let attempts: [(String, () async throws -> Void)] = [
            ("move", { try await sink.move(to: there) }),
            ("click", { try await sink.click(at: there, right: false, count: 1) }),
            ("scroll", { try await sink.scroll(at: there, dx: 0, dy: 1) }),
            ("drag from", { try await sink.drag(from: there, to: elsewhere) }),
            ("drag to", { try await sink.drag(from: elsewhere, to: there) }),
        ]
        for (name, attempt) in attempts {
            do {
                try await attempt()
                XCTFail("\(name) went through the fence")
            } catch {
                XCTAssertTrue("\(error)".contains("Finder"), name)
            }
        }
    }
}

final class ScriptAddressSafetyTests: XCTestCase {
    private func scene(url: String?) -> Scene {
        var scene = Scene()
        scene.appName = "Browser"
        scene.url = url
        return scene
    }

    func testAScriptAddressIsRefusedInABrowser() {
        let page = scene(url: "https://example.com")
        guard case .refuse = SafetyPolicy().evaluate(.typeAtFocus(" JavaScript:alert(1)"), scene: page) else { return XCTFail("not refused") }
        guard case .refuse = SafetyPolicy().evaluate(.type(id: nil, text: "data:text/html,x", clear: false, submit: true), scene: page) else { return XCTFail("not refused") }
    }

    func testTheSameWordsAreFineOutsideABrowserAndInsideASentence() {
        XCTAssertEqual(SafetyPolicy().evaluate(.typeAtFocus("javascript: notes for class"), scene: scene(url: nil)), .allow)
        XCTAssertEqual(SafetyPolicy().evaluate(.typeAtFocus("I like javascript: it runs"), scene: scene(url: "https://example.com")), .allow)
    }
}

final class PlannerContextTests: XCTestCase {
    private func planner(_ next: String, _ text: String, remember: [String] = []) -> String {
        let facts = remember.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"thought":"t","remember":["# + facts + #"],"next":""# + next + #"","app":"","url":"","text":""# + text + #""}"#
    }

    private func harness(_ brain: FakeModel, _ hands: FakeModel, _ tune: (inout HarnessConfiguration) -> Void = { _ in }) -> AgentHarness {
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.orchestrated = true
        tune(&configuration)
        return AgentHarness(goal: "do the thing", model: brain, actuator: Actuator(input: FakeInput()), builder: FramedWorld(screen()),
                            configuration: configuration, worker: CUAWorker(model: hands, dialect: .fara))
    }

    private let finishedJob = call(#""action":"terminate","answer":"Done it""#)

    func testTheSharesFitInsideTheContext() {
        for context in [2_048, 4_096, 8_192, 16_384] {
            let budget = PlannerBudget(contextTokens: context)
            XCTAssertLessThan(budget.screenTokens + budget.factTokens + budget.logTokens + PlannerBudget.outputTokens, context + 1_000)
            XCTAssertGreaterThan(budget.logTokens, 0)
        }
        XCTAssertLessThan(PlannerBudget(contextTokens: 8_192).screenTokens + PlannerBudget(contextTokens: 8_192).factTokens
                          + PlannerBudget(contextTokens: 8_192).logTokens + PlannerBudget.outputTokens, 8_192)
    }

    func testOlderJobsAreSummarizedWhenTheyOutgrowTheirShare() async {
        let long = String(repeating: "x", count: 500)
        let brain = FakeModel([planner("job", "One"), planner("job", "Two"), planner("job", "Three"),
                               #"{"summary":"Jobs one and two went fine.","facts":[]}"#, planner("answer", "All done")])
        let hands = FakeModel([call(#""action":"terminate","answer":"\#(long)""#), call(#""action":"terminate","answer":"\#(long)""#), call(#""action":"terminate","answer":"\#(long)""#)])
        let outcome = await harness(brain, hands) { $0.plannerLogTokens = 500 }.run()
        XCTAssertEqual(outcome, .completed(answer: "All done", verified: true))
        let last = brain.prompts.last { $0.schema == PlannerDecision.schema }
        XCTAssertTrue(last?.messages.contains { $0.text.contains("Jobs one and two went fine.") } == true)
        XCTAssertTrue(brain.prompts.contains { $0.schema == CompactionSummary.schema })
    }

    func testAnExactValueSurvivesASummaryThatDropsIt() {
        var state = OrchestrationState()
        state.remember("Oak Stool costs $89")
        state.remember("Saved in ~/LocalAgentEval/notes")
        state.note("- Job: read\n  Result: ok")
        state.applyCompaction(summary: "Read the shop page and saved the note.", keptFacts: ["Saved in ~/LocalAgentEval/notes"], keepingNewest: 0,
                              budget: PlannerBudget(contextTokens: 8_192))
        XCTAssertTrue(state.facts.contains("Oak Stool costs $89"))
        XCTAssertEqual(state.facts.count, 2)
    }

    func testAnUnusableSummaryNeverStopsTheTask() async {
        let long = String(repeating: "y", count: 500)
        let brain = FakeModel([planner("job", "One"), planner("job", "Two"), "not json", planner("answer", "All done")])
        let hands = FakeModel([call(#""action":"terminate","answer":"\#(long)""#), call(#""action":"terminate","answer":"\#(long)""#)])
        let outcome = await harness(brain, hands) { $0.plannerLogTokens = 200 }.run()
        XCTAssertEqual(outcome, .completed(answer: "All done", verified: true))
    }

    func testAnOverflowShrinksThePromptInsteadOfRepeatingIt() async {
        let brain = FakeModel([planner("answer", "Done")])
        brain.failures = [ModelError.contextOverflow]
        let outcome = await harness(brain, FakeModel([])).run()
        XCTAssertEqual(outcome, .completed(answer: "Done", verified: true))
    }

    func testTheLastActionStillGetsAnAnswerToThePerson() async {
        let brain = FakeModel([planner("job", "Do it"), planner("answer", "It is 33,217")])
        let hands = FakeModel([finishedJob])
        let outcome = await harness(brain, hands) { $0.maximumJobs = 1 }.run()
        XCTAssertEqual(outcome, .completed(answer: "It is 33,217", verified: true))
        let last = brain.prompts.last { $0.schema == PlannerDecision.schema }
        XCTAssertTrue(last?.messages.contains { $0.text.contains("No more actions are possible") } == true)
    }

    func testOutOfRoomThePlannerCannotStartAnotherJob() async {
        let brain = FakeModel([planner("job", "Do it"), planner("job", "Do more")])
        let outcome = await harness(brain, FakeModel([finishedJob])) { $0.maximumJobs = 1 }.run()
        guard case .failed = outcome else { return XCTFail("expected a failure, got \(outcome)") }
    }
}

final class TaskJournalTests: XCTestCase {
    private func journal() -> TaskJournal {
        TaskJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testPersonalDetailsNeverReachTheRecord() {
        let request = TaskRecord(request: "Email sam@example.com my password is hunter2, call 415-555-0134, card 4242 4242 4242 4242, go to https://bank.example.com/acct/991?x=1, open ~/Documents/tax.pdf, ship to 12 Oak Tree Road").request
        for secret in ["sam@example.com", "hunter2", "555-0134", "4242", "/acct/991", "tax.pdf", "12 Oak"] {
            XCTAssertFalse(request.contains(secret), "\(secret) survived in: \(request)")
        }
        XCTAssertTrue(request.contains("bank.example.com"))
    }

    func testAnOrdinaryRequestKeepsItsMeaning() {
        XCTAssertEqual(TaskJournal.redact("Add the cheapest flour, eggs and milk to my cart for $12"), "Add the cheapest flour, eggs and milk to my cart for $12")
    }

    func testAResumedTaskStaysOneRecordAndKeepsItsVerdict() {
        let journal = journal()
        var record = TaskRecord(request: "Book a table")
        record.outcome = "paused"
        journal.record(record)
        journal.setFeedback(id: record.id, worked: true)
        record.outcome = "completed"
        journal.record(record)
        XCTAssertEqual(journal.records().count, 1)
        XCTAssertEqual(journal.records().first?.outcome, "completed")
        XCTAssertEqual(journal.records().first?.worked, true)
    }

    func testOldRecordsExpireAndTheCountIsCapped() {
        let journal = journal()
        let now = Date()
        journal.record(TaskRecord(startedAt: now.addingTimeInterval(-TaskJournal.retention - 60), request: "old"), now: now)
        journal.record(TaskRecord(startedAt: now, request: "new"), now: now)
        XCTAssertEqual(journal.records().map(\.request), ["new"])
    }

    func testAReportLeavesSitesOutUnlessAsked() {
        let journal = journal()
        var record = TaskRecord(request: "Check my lab results")
        record.sites = ["clinic.example.com"]
        journal.record(record)
        XCTAssertFalse(journal.report(ids: [record.id]).contains("clinic.example.com"))
        XCTAssertTrue(journal.report(ids: [record.id], includeSites: true).contains("clinic.example.com"))
        XCTAssertEqual(journal.report(ids: []).filter { !$0.isWhitespace }, "[]")
    }

    func testAFinishedRunRecordsItsShapeButNothingItTypedOrAnswered() async {
        let journal = journal()
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.orchestrated = true
        configuration.workerFirst = true
        let world = FramedWorld(screen())
        let brain = FakeModel([#"{"thought":"t","remember":[],"next":"answer","app":"","url":"","text":"Your balance is planner-answer-words"}"#])
        let hands = FakeModel([call(#""action":"type","text":"typed-secret-words""#), call(#""action":"terminate","answer":"worker-answer-words""#)])
        let agent = AgentHarness(goal: "Email sam@example.com", model: brain, actuator: Actuator(input: FakeInput()), builder: world,
                                 configuration: configuration, worker: CUAWorker(model: hands, dialect: .fara))
        agent.journal = journal
        agent.journalModels = ["planner-x", "worker-y"]
        _ = await agent.run()
        let record = try? XCTUnwrap(journal.records().first)
        XCTAssertEqual(record?.jobs, 1)
        XCTAssertEqual(record?.models, ["planner-x", "worker-y"])
        XCTAssertEqual(record?.request, "Email [email]")
        let stored = journal.report(ids: journal.records().map(\.id), includeSites: true)
        for leaked in ["typed-secret-words", "worker-answer-words", "planner-answer-words"] { XCTAssertFalse(stored.contains(leaked), leaked) }
    }
}

final class PlannerRoutingTests: XCTestCase {
    func testTheSamePageIsRecognisedHoweverItIsWritten() {
        XCTAssertTrue(AgentHarness.isSamePage("http://127.0.0.1:18931/shop", as: "127.0.0.1:18931/shop?q=mug"))
        XCTAssertTrue(AgentHarness.isSamePage("https://www.example.com/", as: "example.com/a"))
        XCTAssertFalse(AgentHarness.isSamePage("http://127.0.0.1:18931/report", as: "127.0.0.1:18931/shop"))
        XCTAssertFalse(AgentHarness.isSamePage("http://example.com", as: nil))
    }

    func testTheWorkerStartsOnTheGoalAsAskedWhenSetTo() async {
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.orchestrated = true
        configuration.workerFirst = true
        let brain = FakeModel([#"{"thought":"t","remember":[],"next":"answer","app":"","url":"","text":"All done"}"#])
        let hands = FakeModel([call(#""action":"terminate","answer":"Finished""#)])
        let agent = AgentHarness(goal: "do the whole thing", model: brain, actuator: Actuator(input: FakeInput()), builder: FramedWorld(screen()),
                                 configuration: configuration, worker: CUAWorker(model: hands, dialect: .fara))
        let outcome = await agent.run()
        XCTAssertEqual(outcome, .completed(answer: "Finished", verified: true))
        XCTAssertTrue(hands.prompts[0].messages.contains { $0.text.contains("do the whole thing") })
        XCTAssertEqual(brain.prompts.filter { $0.schema == PlannerDecision.schema }.count, 0)
    }
}

final class DialogHintTests: XCTestCase {
    private func scene(_ labels: [String]) -> Scene {
        var scene = Scene()
        scene.elements = labels.enumerated().map { UIElement(id: $0.offset + 1, role: "button", label: $0.element, frame: .zero, source: .accessibility) }
        return scene
    }

    func testThePrintSheetSteersAwayFromPaper() {
        let hint = Prompts.macHint(for: scene(["PDF", "Print", "Cancel"]))
        XCTAssertTrue(hint?.contains("Save as PDF") == true)
        XCTAssertTrue(hint?.contains("don't press Print") == true)
    }

    func testAFilePickerGetsTheGoToFolderShortcut() {
        XCTAssertTrue(Prompts.macHint(for: scene(["Open", "Cancel"]))?.contains("Command+Shift+G") == true)
    }

    func testAnOrdinaryWindowGetsNoHint() {
        XCTAssertNil(Prompts.macHint(for: scene(["Open in new tab", "Save All"])))
    }
}

final class SeeingPlannerTests: XCTestCase {
    func testAPlannerWithVisionGetsTheScreenAndIsToldSo() {
        let image = Data([1, 2, 3])
        let seeing = Prompts.orchestrator(goal: "g", facts: [], log: [], screen: "s", image: image)
        XCTAssertEqual(seeing.last?.imageJPEG, image)
        XCTAssertTrue(seeing[0].text.contains("You can see the screen"))
        let reading = Prompts.orchestrator(goal: "g", facts: [], log: [], screen: "s")
        XCTAssertNil(reading.last?.imageJPEG)
        XCTAssertTrue(reading[0].text.contains("You can't see"))
    }
}

final class WorkerWindowTests: XCTestCase {
    private func worker(context: Int?, turns count: Int) -> CUAWorker {
        let made = CUAWorker(model: FakeModel([]), dialect: .fara)
        made.contextTokens = context
        made.begin(job: "the job")
        for index in 0..<count { made.turns.append(.init(image: Data([UInt8(index)]), reply: "reply \(index)", actionLine: "action \(index)")) }
        return made
    }
    private func images(_ messages: [ModelMessage]) -> Int { messages.filter { $0.imageJPEG != nil }.count }

    func testWithRoomTheConversationOnlyGrowsSoTheCacheKeepsWorking() {
        let made = worker(context: 131_072, turns: 6)
        let before = made.messages(current: Data([9]))
        XCTAssertEqual(images(before), 7)
        made.turns.append(.init(image: Data([9]), reply: "next", actionLine: "next"))
        let after = made.messages(current: Data([10]))
        XCTAssertEqual(Array(after.prefix(before.count - 1)), Array(before.dropLast()), "everything before the new step is unchanged")
    }

    func testNearTheLimitOlderScreenshotsBecomeOneLineEach() {
        let made = worker(context: 10_000, turns: 8)
        XCTAssertFalse(made.compactIfNeeded(promptTokens: 6_000))
        XCTAssertTrue(made.compactIfNeeded(promptTokens: 7_500))
        let messages = made.messages(current: Data([9]))
        XCTAssertEqual(images(messages), made.dialect.screenshotsKept)
        XCTAssertTrue(messages.contains { $0.text.contains("action 0") })
        XCTAssertFalse(messages.contains { $0.text.contains("reply 0") })
        XCTAssertEqual(made.compactions, 1)
    }

    func testANewJobStartsClean() {
        let made = worker(context: 10_000, turns: 8)
        made.compact()
        made.begin(job: "another")
        made.turns.append(.init(image: Data([1]), reply: "r", actionLine: "a"))
        XCTAssertEqual(images(made.messages(current: Data([2]))), 2)
    }

    func testWithoutAContextItSlidesAsPublished() {
        XCTAssertEqual(images(worker(context: nil, turns: 8).messages(current: Data([9]))), CUADialect.fara.screenshotsKept)
    }
}

final class CheckingAndDialogTests: XCTestCase {
    private func planner(_ next: String, _ text: String) -> String {
        #"{"thought":"t","remember":[],"next":""# + next + #"","app":"","url":"","text":""# + text + #""}"#
    }

    func testTheSeeingModelChecksTheAnswerAndGetsTheScreen() async {
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.orchestrated = true
        let brain = FakeModel([planner("answer", "It is $129")])
        let hands = FakeModel([])
        let agent = AgentHarness(goal: "price?", model: brain, actuator: Actuator(input: FakeInput()), builder: FramedWorld(screen()),
                                 configuration: configuration, worker: CUAWorker(model: hands, dialect: .fara))
        let outcome = await agent.run()
        XCTAssertEqual(outcome, .completed(answer: "It is $129", verified: true))
        XCTAssertFalse(brain.prompts.contains { $0.schema == ToolSchema.verdictSchema }, "not the text-only planner")
        let check = hands.prompts.first { $0.schema == ToolSchema.verdictSchema }
        XCTAssertTrue(check?.messages.contains { $0.imageJPEG != nil } == true)
    }

    func testAPermissionDialogIsLeftForThePerson() async {
        var scene = screen()
        scene.bundleID = "com.apple.UserNotificationCenter"
        var configuration = HarnessConfiguration()
        configuration.settleLimit = 0.01
        configuration.orchestrated = true
        configuration.workerFirst = true
        let input = FakeInput()
        let hands = FakeModel([call(#""action":"left_click","coordinate":[500,250]"#)])
        let agent = AgentHarness(goal: "do it", model: FakeModel([]), actuator: Actuator(input: input), builder: FramedWorld(scene),
                                 configuration: configuration, worker: CUAWorker(model: hands, dialect: .fara))
        guard case .handoff = await agent.run() else { return XCTFail("expected a hand-off") }
        XCTAssertTrue(input.clicks.isEmpty)
        XCTAssertTrue(hands.prompts.isEmpty, "the model never even looks at it")
    }

    func testUploadingAFileAsksFirst() {
        var scene = Scene()
        scene.appName = "Browser"
        scene.elements = [UIElement(id: 1, role: "button", label: "Upload", frame: CGRect(x: 0, y: 0, width: 50, height: 20), source: .accessibility)]
        guard case .approve = SafetyPolicy().evaluate(.click(id: 1, right: false, double: false), scene: scene) else { return XCTFail("no approval") }
    }

    func testALocalFileAddressCantBeTypedIntoABrowser() {
        var scene = Scene()
        scene.url = "https://example.com"
        guard case .refuse = SafetyPolicy().evaluate(.typeAtFocus("file:///Users/me/secrets.txt"), scene: scene) else { return XCTFail("not refused") }
    }
}

final class NamedAppTests: XCTestCase {
    func testAnAppIsNamedByWholeWordsHoweverItIsSpaced() {
        XCTAssertTrue(OrchestrationState.names(goal: "Write it in Fixture Notes as exactly", oneOf: ["FixtureNotes"]))
        XCTAssertTrue(OrchestrationState.names(goal: "print from this Legacy Inventory app", oneOf: ["LegacyInventory", "Zoom"]))
        XCTAssertFalse(OrchestrationState.names(goal: "Email sam@example.com", oneOf: ["Mail"]))
        XCTAssertFalse(OrchestrationState.names(goal: "Find flights", oneOf: []))
    }
}

final class ArithmeticTests: XCTestCase {
    func testSumsComeOutRight() {
        XCTAssertEqual(Arithmetic.evaluate("62.30+14.50+23.20"), "100.00")
        XCTAssertEqual(Arithmetic.evaluate("$1,200.50 - $200.50"), "1000.00")
        XCTAssertEqual(Arithmetic.evaluate("(2+3)*4"), "20")
        XCTAssertEqual(Arithmetic.evaluate("10/4"), "2.5")
        XCTAssertEqual(Arithmetic.evaluate("-3+5"), "2")
    }

    func testWhatIsNotASumGivesNothing() {
        for text in ["", "hello", "1+", "1/0", "(1+2", "rm -rf /", String(repeating: "(", count: 100)] {
            XCTAssertNil(Arithmetic.evaluate(text), text)
        }
    }

    func testTheModelCanAskForASum() {
        let reply = CUADialect.fara.parse(#"<think>add</think><tool_call>{"name":"computer_use","arguments":{"action":"calculate","text":"1.50+2.50"}}</tool_call>"#, pointer: nil)
        XCTAssertEqual(reply.calculated, "1.50+2.50 = 4.00")
        XCTAssertNil(reply.call)
        XCTAssertNil(reply.problem)
    }
}

final class SavedFileTests: XCTestCase {
    func testADoubledExtensionIsPutRight() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wanted = folder.appendingPathComponent("inventory.pdf").path
        try Data("new".utf8).write(to: URL(fileURLWithPath: wanted + ".pdf"))
        XCTAssertTrue(FileDialog.undoDoubledExtension(wanted))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wanted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wanted + ".pdf"))
    }

    func testAnExistingFileIsNeverReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wanted = folder.appendingPathComponent("inventory.pdf").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: wanted))
        try Data("new".utf8).write(to: URL(fileURLWithPath: wanted + ".pdf"))
        XCTAssertFalse(FileDialog.undoDoubledExtension(wanted))
        XCTAssertEqual(try String(contentsOfFile: wanted, encoding: .utf8), "old")
    }
}

final class DropdownAndBareNameTests: XCTestCase {
    func testReturnOnADropdownOpensItInsteadOfSubmitting() {
        var scene = Scene()
        var dropdown = UIElement(id: 1, role: "AXPopUpButton", label: "Home branch", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        dropdown.focused = true
        scene.elements = [dropdown]
        XCTAssertEqual(CUAWorker.opensDropdown(.key("return"), in: scene), .key("space"))
        XCTAssertEqual(CUAWorker.opensDropdown(.key("tab"), in: scene), .key("tab"))
        scene.elements[0].role = "AXTextField"
        XCTAssertEqual(CUAWorker.opensDropdown(.key("return"), in: scene), .key("return"))
    }


    func testABareFileNameInASaveDialogStaysPut() {
        var scene = Scene()
        scene.elements = [UIElement(id: 1, role: "field", label: "Save As:", frame: CGRect(x: 0, y: 0, width: 100, height: 20), editable: true)]
        XCTAssertEqual(FileDialog.kind(of: scene), .save)
        XCTAssertFalse(FileDialog.leavesRoot(typed: "inventory.pdf", in: scene, root: "/Users/me/Eval", home: "/Users/me", exists: { _ in true }))
        XCTAssertTrue(FileDialog.leavesRoot(typed: "/Users/me/Documents/inventory.pdf", in: scene, root: "/Users/me/Eval", home: "/Users/me", exists: { _ in true }))
    }
}


final class RecoveryTests: XCTestCase {
    func testAClickNearTheTitleBarThatWouldSnapToCloseIsRefused() {
        var scene = Scene()
        scene.windowFrame = CGRect(x: 220, y: 100, width: 760, height: 652)
        // (32,47) lands at about 24,30 inside the window: just under the buttons' row.
        let close = CGRect(x: 228, y: 108, width: 14, height: 16)
        scene.windowButtons = [close]
        // Called anything at all, in any language, it's the frame that counts.
        scene.elements = [UIElement(id: 1, role: "button", label: "Fermer", frame: close)]
        XCTAssertTrue(CUAWorker.landsOnWindowButtons(x: 32, y: 47, in: scene))
        XCTAssertFalse(CUAWorker.landsOnWindowButtons(x: 500, y: 500, in: scene))
    }

    func testOnlyTheAppSwitchShortcutsCount() {
        XCTAssertTrue(CUAWorker.isAppSwitchKey("cmd+tab"))
        XCTAssertTrue(CUAWorker.isAppSwitchKey("alt+tab"))
        XCTAssertFalse(CUAWorker.isAppSwitchKey("tab"))
        XCTAssertFalse(CUAWorker.isAppSwitchKey("shift+tab"))
        XCTAssertFalse(CUAWorker.isAppSwitchKey("ctrl+tab"))
    }

    func testRepeatingWhatKeepsChangingThingsIsNotBeingStuck() {
        func record(_ scene: String) -> WorkingMemory.Record {
            WorkingMemory.Record(step: 1, action: "click", result: "x", hadEffect: true, fingerprint: "click at 810,114", sceneFingerprint: scene)
        }
        XCTAssertTrue(Supervisor.isAdvancing(["a", "b", "c", "d"].map(record)))
        XCTAssertFalse(Supervisor.isAdvancing(["a", "b", "a", "b"].map(record)))
        XCTAssertFalse(Supervisor.isAdvancing(["a", "b"].map(record)))
    }

    func testABareNameGoesToTheFolderTheGoalNames() {
        let exists: (String) -> Bool = { $0 == "/Users/me/Eval/documents/" }
        let goal = "Import customers.csv from Eval/documents, sort it, and export it as clean.csv in the same folder."
        XCTAssertEqual(FileDialog.folderNamed(in: goal, home: "/Users/me", exists: exists), "Eval/documents/")
        XCTAssertNil(FileDialog.folderNamed(in: "Copy from Eval/documents to Eval/backup", home: "/Users/me", exists: { _ in true }))
        XCTAssertNil(FileDialog.folderNamed(in: "Open http://a.test/b/c and write it down", home: "/Users/me", exists: { _ in true }))
        XCTAssertEqual(FileDialog.folderNamed(in: "Save it as Eval/documents/Trip.txt.", home: "/Users/me", exists: exists), "Eval/documents/")
    }
}

final class HumanCheckTests: XCTestCase {
    private func page(elements: Int, frames: [String] = ["https://shop.example/"]) -> Scene {
        var scene = Scene()
        scene.url = frames.first
        scene.frameURLs = frames
        scene.pageElementCount = elements
        return scene
    }

    func testAsksAboutShortPagesAndCheckFramesOnly() {
        XCTAssertNotNil(HumanCheck.pageToAsk(page(elements: 8)))
        XCTAssertNil(HumanCheck.pageToAsk(page(elements: 300)))
        XCTAssertNotNil(HumanCheck.pageToAsk(page(elements: 300, frames: ["https://shop.example/", "https://www.google.com/recaptcha/api2/anchor?k=1"])))
        XCTAssertNil(HumanCheck.pageToAsk(Scene()), "Not a web page")
    }

    func testReadsTheLastAnswerOnly() {
        XCTAssertTrue(HumanCheck.saysBlocked("<think>It wants a tick.</think> It wants proof.\nANSWER: YES"))
        XCTAssertFalse(HumanCheck.saysBlocked("It's a sign-in page, so not ANSWER: YES.\nANSWER: NO"))
        XCTAssertFalse(HumanCheck.saysBlocked("I'll click the box."), "No answer means no stop")
    }
}
