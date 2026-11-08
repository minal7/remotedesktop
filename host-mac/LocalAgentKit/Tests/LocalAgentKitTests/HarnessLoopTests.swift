import CoreGraphics
import XCTest
@testable import LocalAgentKit

/// Scripted world: each build returns the current scene; actions can swap it.
final class FakeWorld: SceneSource, @unchecked Sendable {
    var scene: Scene
    var builds = 0
    init(_ scene: Scene) { self.scene = scene }
    func build(_ options: SceneBuilder.Options) async -> Scene { builds += 1; return scene }
    func captureForSettling(rect: CGRect) async -> ScreenFrame? { nil }
}

final class FakeInput: InputSink, @unchecked Sendable {
    var clicks: [CGPoint] = []
    var typed: [String] = []
    var keys: [CGKeyCode] = []
    var allowed = true
    var onClick: ((CGPoint) -> Void)?
    var onType: ((String) -> Void)?
    func mayAct() -> Bool { allowed }
    func move(to point: CGPoint) async throws {}
    func click(at point: CGPoint, right: Bool, count: Int) async throws {
        guard allowed else { throw ActuationError.stopped }
        clicks.append(point); onClick?(point)
    }
    func drag(from: CGPoint, to: CGPoint) async throws {}
    func scroll(at point: CGPoint, dx: Int, dy: Int) async throws {}
    func key(code: CGKeyCode, flags: CGEventFlags) async throws { keys.append(code) }
    func type(_ text: String) async throws { typed.append(text); onType?(text) }
    func perform(_ effect: () throws -> Void) throws { try effect() }
}

/// Answers from a list; the last answer repeats. Plan and verdict requests are
/// recognized by their schema, so scripts only list actual decisions.
final class FakeModel: ModelClient, @unchecked Sendable {
    var decisions: [String]
    var verdicts: [String] = [#"{"finished":true,"missing":""}"#]
    var failures: [Error] = []
    var prompts: [ModelRequest] = []
    var hang = false
    var planSteps = ["do the thing"]
    private var index = 0
    private var verdictIndex = 0
    private var hangContinuation: CheckedContinuation<Void, Error>?

    init(_ decisions: [String]) { self.decisions = decisions }

    func complete(_ request: ModelRequest) async throws -> ModelReply {
        prompts.append(request)
        if request.schema == ToolSchema.planSchema { 
            let list = planSteps.map { "\"\($0)\"" }.joined(separator: ",")
            return ModelReply(text: "{\"steps\":[\(list)]}")
        }
        if request.schema == ToolSchema.verdictSchema {
            let reply = verdicts[min(verdictIndex, verdicts.count - 1)]
            verdictIndex += 1
            return ModelReply(text: reply)
        }
        if !failures.isEmpty { throw failures.removeFirst() }
        if hang {
            try await withCheckedThrowingContinuation { hangContinuation = $0 }
        }
        let reply = decisions[min(index, decisions.count - 1)]
        index += 1
        return ModelReply(text: reply, promptTokens: 10)
    }

    func cancelInFlight() {
        hangContinuation?.resume(throwing: CancellationError())
        hangContinuation = nil
    }
}

private func element(_ id: Int, _ label: String, role: String = "button", y: CGFloat = 50, secure: Bool = false, editable: Bool = false) -> UIElement {
    UIElement(id: id, role: role, label: label, frame: CGRect(x: 10, y: y, width: 80, height: 20), secure: secure, editable: editable, source: .ocr)
}

private func scene(_ elements: [UIElement], app: String = "App", title: String = "Window") -> Scene {
    var scene = Scene()
    scene.appName = app
    scene.bundleID = "com.example." + app
    scene.pid = 0
    scene.windowTitle = title
    scene.windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    scene.elements = elements
    scene.fingerprint = elements.map(\.label).joined(separator: "|") + title
    return scene
}

private func click(_ id: Int) -> String { #"{"step":1,"thought":"t","tool":"click","id":\#(id)}"# }
private let done = #"{"step":1,"thought":"t","tool":"done","text":"All done"}"#

final class HarnessLoopTests: XCTestCase {
    private func harness(_ model: FakeModel, _ world: FakeWorld, _ input: FakeInput, configure: (inout HarnessConfiguration) -> Void = { _ in }) -> AgentHarness {
        var configuration = HarnessConfiguration()
        configuration.supportsVision = false
        configuration.settleLimit = 0.01
        configure(&configuration)
        return AgentHarness(goal: "do the thing", model: model, actuator: Actuator(input: input), builder: world, configuration: configuration)
    }

    func testCompletesWhenVerified() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let input = FakeInput()
        input.onClick = { _ in world.scene = scene([element(2, "Finished")], title: "Result") }
        let outcome = await harness(FakeModel([click(1), done]), world, input).run()
        XCTAssertEqual(outcome, .completed(answer: "All done", verified: true))
        XCTAssertEqual(input.clicks.count, 1)
    }

    func testRejectedDoneKeepsWorkingAndTellsTheModelWhatsMissing() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let model = FakeModel([done, click(1), done])
        model.verdicts = [#"{"finished":false,"missing":"the file isn't saved"}"#, #"{"finished":true,"missing":""}"#]
        let input = FakeInput()
        input.onClick = { _ in world.scene = scene([element(2, "Saved")], title: "Saved") }
        let outcome = await harness(model, world, input).run()
        XCTAssertEqual(outcome, .completed(answer: "All done", verified: true))
        let decisionPrompts = model.prompts.filter { $0.schema != ToolSchema.planSchema && $0.schema != ToolSchema.verdictSchema }
        XCTAssertTrue(decisionPrompts[1].messages.last!.text.contains("the file isn't saved"))
    }

    func testNeverRepeatsAnActionThatDidNothingAndEventuallyAsksForHelp() async {
        let world = FakeWorld(scene([element(1, "Dead button")]))
        let input = FakeInput()
        let model = FakeModel([click(1)])
        model.verdicts = [#"{"finished":false,"missing":"not yet"}"#]
        let outcome = await harness(model, world, input).run()
        guard case .needsAnswer(let question) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(question.question.lowercased().contains("try"))
        XCTAssertEqual(input.clicks.count, 1, "a dead control is clicked once, not seven times")
    }

    /// The first real run's failure: every click "works", and nothing gets anywhere.
    func testLoopWithVisibleEffectsStillStops() async {
        let world = FakeWorld(scene([element(1, "File"), element(2, "New")]))
        var generation = 0
        let input = FakeInput()
        input.onClick = { _ in
            generation += 1
            world.scene = scene([element(1, "File"), element(2, "New")], title: "Untitled \(generation)")
        }
        let looping = FakeModel([click(1), click(2)])
        looping.verdicts = [#"{"finished":false,"missing":"not yet"}"#]
        let outcome = await harness(looping, world, input) { $0.maximumSteps = 60 }.run()
        guard case .needsAnswer = outcome else { return XCTFail("\(outcome)") }
        XCTAssertLessThan(input.clicks.count, 45)
    }

    func testConsequentialActionWaitsForApprovalThenRunsOnce() async {
        let world = FakeWorld(scene([element(1, "Send")]))
        let input = FakeInput()
        input.onClick = { _ in world.scene = scene([element(2, "Sent")], title: "Sent") }
        let agent = harness(FakeModel([click(1), done]), world, input)
        guard case .needsApproval(let request) = await agent.run() else { return XCTFail() }
        XCTAssertEqual(input.clicks.count, 0, "nothing happens before approval")
        let outcome = await agent.resume(approval: request.id, approved: true)
        XCTAssertEqual(outcome, .completed(answer: "All done", verified: true))
        XCTAssertEqual(input.clicks.count, 1)
    }

    func testDenialEndsTheTaskWithoutTryingAnotherWay() async {
        let world = FakeWorld(scene([element(1, "Delete"), element(2, "Remove")]))
        let input = FakeInput()
        let model = FakeModel([click(1), click(2)])
        let agent = harness(model, world, input)
        guard case .needsApproval(let first) = await agent.run() else { return XCTFail() }
        guard case .failed(let reason) = await agent.resume(approval: first.id, approved: false) else {
            return XCTFail("a declined step must end the task, not look for another route")
        }
        XCTAssertTrue(reason.contains("declined"))
        XCTAssertEqual(input.clicks.count, 0)
    }

    func testApprovalIsVoidIfTheTargetChangedWhileWaiting() async {
        let world = FakeWorld(scene([element(1, "Send")]))
        let input = FakeInput()
        let model = FakeModel([click(1), done])
        let agent = harness(model, world, input)
        guard case .needsApproval(let request) = await agent.run() else { return XCTFail() }
        world.scene = scene([element(1, "Delete everything")])
        _ = await agent.resume(approval: request.id, approved: true)
        XCTAssertEqual(input.clicks.count, 0, "approving Send must never press something else")
    }

    func testPasswordFieldIsHandedOverAndNothingIsTyped() async {
        let world = FakeWorld(scene([element(1, "Password", role: "field", secure: true, editable: true)]))
        let input = FakeInput()
        let typeIt = #"{"step":1,"thought":"t","tool":"type","id":1,"text":"hunter2"}"#
        guard case .handoff = await harness(FakeModel([typeIt]), world, input).run() else { return XCTFail() }
        XCTAssertTrue(input.typed.isEmpty)
    }

    func testAskUserThenContinueWithTheAnswerInThePrompt() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let ask = #"{"step":1,"thought":"t","tool":"ask_user","text":"Which one?","choices":["A","B"]}"#
        let model = FakeModel([ask, done])
        let agent = harness(model, world, FakeInput())
        guard case .needsAnswer(let question) = await agent.run() else { return XCTFail() }
        XCTAssertEqual(question.choices, ["A", "B"])
        let result1 = await agent.resume(answer: "B please")
        XCTAssertEqual(result1, .completed(answer: "All done", verified: true))
        XCTAssertTrue(model.prompts.contains { $0.messages.first!.text.contains("User added: B please") })
    }

    func testStopDuringAModelCallReturnsPromptly() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let model = FakeModel([click(1)])
        model.hang = true
        let input = FakeInput()
        let agent = harness(model, world, input)
        let task = Task { await agent.run() }
        try? await Task.sleep(for: .milliseconds(200))
        let started = Date()
        agent.cancelRequested = true
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(input.clicks.isEmpty)
    }

    func testPauseThenResumeContinuesTheSameTask() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let model = FakeModel([done])
        model.hang = true
        let agent = harness(model, world, FakeInput())
        let task = Task { await agent.run() }
        try? await Task.sleep(for: .milliseconds(200))
        agent.pauseRequested = true
        let result2 = await task.value
        XCTAssertEqual(result2, .paused)
        model.hang = false
        let result3 = await agent.resumeAfterPause()
        XCTAssertEqual(result3, .completed(answer: "All done", verified: true))
    }

    func testBadReferenceCostsAStepAndExplainsWhy() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let model = FakeModel([click(99), done])
        let input = FakeInput()
        _ = await harness(model, world, input).run()
        XCTAssertTrue(input.clicks.isEmpty)
        let decisions = model.prompts.filter { $0.schema != ToolSchema.planSchema && $0.schema != ToolSchema.verdictSchema }
        XCTAssertTrue(decisions[1].messages.last!.text.contains("[99] isn't on the screen"))
    }

    func testTransientModelFailureRetriesButPersistentFailureEndsHonestly() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let flaky = FakeModel([done])
        flaky.failures = [ModelError.timeout]
        let result4 = await harness(flaky, world, FakeInput()).run()
        XCTAssertEqual(result4, .completed(answer: "All done", verified: true))
        let broken = FakeModel([done])
        broken.failures = [ModelError.timeout, ModelError.timeout, ModelError.timeout]
        guard case .failed(let reason) = await harness(broken, world, FakeInput()).run() else { return XCTFail() }
        XCTAssertTrue(reason.contains("stopped responding"))
    }

    func testOverflowShrinksThePromptAndRetries() async {
        let world = FakeWorld(scene((0..<800).map { element($0 + 1, "Item number \($0)", y: CGFloat($0)) }))
        let model = FakeModel([done])
        model.failures = [ModelError.contextOverflow]
        let result5 = await harness(model, world, FakeInput()).run()
        XCTAssertEqual(result5, .completed(answer: "All done", verified: true))
        let decisions = model.prompts.filter { $0.schema != ToolSchema.planSchema && $0.schema != ToolSchema.verdictSchema }
        XCTAssertLessThan(decisions[1].messages.last!.text.count, decisions[0].messages.last!.text.count)
    }

    /// The point of the design: prompt size is flat no matter how long the task runs.
    func testPromptStaysInBudgetAcrossAVeryLongTask() async {
        let big = (0..<600).map { element($0 + 1, "A fairly long element label number \($0)", y: CGFloat($0)) }
        let world = FakeWorld(scene(big))
        var turn = 0
        let input = FakeInput()
        input.onClick = { _ in turn += 1; var next = scene(big, title: "Page \(turn)"); next.fingerprint = "scene\(turn)"; world.scene = next }
        // A long task that keeps moving, with varied actions and a growing note pile.
        var script: [String] = []
        for index in 0..<150 {
            let planStep = index / 5 + 1
            script.append(index % 3 == 2 ? #"{"step":\#(planStep),"thought":"t","tool":"note","text":"fact \#(index) \#(String(repeating: "x", count: 200))"}"#
                                         : #"{"step":\#(planStep),"thought":"t","tool":"click","id":\#(index % 500 + 1)}"#)
        }
        let model = FakeModel(script + [done])
        model.planSteps = (1...40).map { "Stage \($0) of the task" }
        let agent = harness(model, world, input) { $0.maximumSteps = 151; $0.budget = ContextBudget(contextTokens: 4_096); $0.settleLimit = 0 }
        _ = await agent.run()
        let estimator = TokenEstimator()
        let decisions = model.prompts.filter { $0.schema != ToolSchema.planSchema && $0.schema != ToolSchema.verdictSchema }
        XCTAssertGreaterThan(decisions.count, 100, "this has to be a genuinely long task")
        for prompt in decisions {
            let tokens = prompt.messages.reduce(0) { $0 + estimator.estimate($1.text) }
            XCTAssertLessThan(tokens, 4_096 - 260, "prompt must always fit a 4 K context")
        }
    }

    func testSchemaStopsOfferingAControlThatJustDidNothing() async {
        let world = FakeWorld(scene([element(1, "Dead"), element(2, "Other")]))
        let model = FakeModel([click(1), done])
        _ = await harness(model, world, FakeInput()).run()
        let schemas = model.prompts.compactMap(\.schema).filter { $0 != ToolSchema.planSchema && $0 != ToolSchema.verdictSchema }
        XCTAssertTrue(schemas[0].contains("\"enum\":[1,2]"))
        XCTAssertTrue(schemas[1].contains("\"enum\":[2]"), schemas[1])
    }

    func testTypingWithNoFocusGoesToTheOnlyFieldNeverIntoNothing() async {
        let field = element(5, "Search", role: "field", editable: true)
        let world = FakeWorld(scene([field, element(6, "Go")]))
        let input = FakeInput()
        input.onType = { text in world.scene = scene([element(5, "Search", role: "field", editable: true), element(6, "Go")], title: text) }
        let type = #"{"step":1,"thought":"t","tool":"type","text":"mug","clear":true}"#
        _ = await harness(FakeModel([type, done]), world, input).run()
        XCTAssertEqual(input.typed, ["mug"])
        XCTAssertEqual(input.clicks.count, 1, "the only field gets clicked first")
    }

    func testTextThatLandsNowhereIsRetriedExactlyOnceAfterARealClick() async {
        let world = FakeWorld(scene([element(5, "Search", role: "field", editable: true)]))
        let input = FakeInput()
        let type = #"{"step":1,"thought":"t","tool":"type","id":5,"text":"mug"}"#
        _ = await harness(FakeModel([type, done]), world, input).run()
        XCTAssertEqual(input.typed, ["mug", "mug"])
    }

    func testTypingWithSeveralUnfocusedFieldsIsRefusedWithChoices() async {
        let world = FakeWorld(scene([element(5, "Name", role: "field", editable: true), element(6, "Email", role: "field", y: 90, editable: true)]))
        let input = FakeInput()
        let model = FakeModel([#"{"step":1,"thought":"t","tool":"type","text":"x","clear":true}"#, done])
        _ = await harness(model, world, input).run()
        XCTAssertTrue(input.typed.isEmpty)
        XCTAssertTrue(input.keys.isEmpty, "clear must not press cmd+a and delete into nowhere")
        let decisions = model.prompts.filter { $0.schema != ToolSchema.planSchema && $0.schema != ToolSchema.verdictSchema }
        XCTAssertTrue(decisions[1].messages.last!.text.contains("[5]"))
    }

    func testEmptyDoneReturnsTheAnswerFromNotes() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let note = #"{"step":1,"thought":"t","tool":"note","text":"The price is $58"}"#
        let emptyDone = #"{"step":1,"thought":"t","tool":"done"}"#
        let outcome = await harness(FakeModel([note, emptyDone]), world, FakeInput()).run()
        XCTAssertEqual(outcome, .completed(answer: "The price is $58", verified: true))
    }

    func testAControlAlreadyUsedTwiceFromThisScreenStopsBeingOffered() async {
        let base = scene([element(1, "Toggle"), element(2, "Other")])
        let world = FakeWorld(base)
        let input = FakeInput()
        var flip = false
        input.onClick = { _ in
            flip.toggle()
            world.scene = flip ? scene([element(1, "Toggle"), element(2, "Other"), element(3, "Extra", y: 90)]) : base
        }
        let model = FakeModel([click(1), click(1), click(1), click(1), click(2), done])
        _ = await harness(model, world, input).run()
        let schemas = model.prompts.compactMap(\.schema).filter { $0.contains("\"step\"") }
        XCTAssertTrue(schemas.contains { $0.contains("\"enum\":[2]") }, "after two uses from this screen, [1] must be gone")
    }

    /// Live run: the form was saved, the model kept going, replanned, and overwrote its own work.
    func testGoingInCirclesAfterFinishingEndsTheTaskInsteadOfRedoingIt() async {
        let world = FakeWorld(scene([element(1, "Status: Saved 1 records")]))
        let model = FakeModel([click(1)])
        model.verdicts = [#"{"finished":true,"missing":""}"#]
        let input = FakeInput()
        guard case .completed(_, let verified) = await harness(model, world, input).run() else { return XCTFail() }
        XCTAssertTrue(verified)
        XCTAssertEqual(input.clicks.count, 1)
    }

    func testOneLineFieldWithAValueIsReplacedUnlessTheModelSaysOtherwise() async {
        var field = element(5, "Save As:", role: "field", editable: true)
        field.value = "Untitled.txt"
        let world = FakeWorld(scene([field]))
        let input = FakeInput()
        input.onType = { text in
            var updated = field
            updated.value = text
            world.scene = scene([updated])
        }
        let model = FakeModel([#"{"step":1,"thought":"t","tool":"type","id":5,"text":"budget.txt"}"#, done])
        _ = await harness(model, world, input).run()
        XCTAssertTrue(input.keys.contains(KeyMap.code(for: "a")!), "existing text must be selected and removed first")
    }

    func testAskForHelpStillHappensWhenTheCheckSaysNotFinished() async {
        let world = FakeWorld(scene([element(1, "Dead")]))
        let model = FakeModel([click(1)])
        model.verdicts = [#"{"finished":false,"missing":"nothing done"}"#]
        guard case .needsAnswer = await harness(model, world, FakeInput()).run() else { return XCTFail() }
    }

    func testStopGateBlocksInputAndEndsWithoutActing() async {
        let world = FakeWorld(scene([element(1, "Next")]))
        let input = FakeInput()
        input.allowed = false
        let agent = harness(FakeModel([click(1)]), world, input)
        let outcome = await agent.run()
        XCTAssertEqual(outcome, .paused)
        XCTAssertTrue(input.clicks.isEmpty)
    }
}
