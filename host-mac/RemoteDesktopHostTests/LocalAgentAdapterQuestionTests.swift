import CoreGraphics
import LocalAgentKit
import XCTest
@testable import RemoteDesktopHost

/// Questions the local agent asks must reach the phone, and a task that ends while waiting
/// for one must not block the next request. Both failed on the first Release iPad run.
@MainActor
final class LocalAgentAdapterQuestionTests: XCTestCase {
    private final class ScriptedModel: ModelClient, @unchecked Sendable {
        let decision: String
        init(_ decision: String) { self.decision = decision }
        func complete(_ request: ModelRequest) async throws -> ModelReply {
            if request.schema == ToolSchema.planSchema { return ModelReply(text: #"{"steps":["do the thing"]}"#) }
            if request.schema == ToolSchema.verdictSchema { return ModelReply(text: #"{"finished":true,"missing":""}"#) }
            return ModelReply(text: decision, promptTokens: 10)
        }
    }

    private final class StillWorld: SceneSource, @unchecked Sendable {
        func build(_ options: SceneBuilder.Options) async -> Scene {
            var scene = Scene()
            scene.appName = "App"; scene.bundleID = "com.example.App"; scene.windowTitle = "Window"
            scene.windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
            scene.elements = [UIElement(id: 1, role: "button", label: "Next",
                                        frame: CGRect(x: 10, y: 50, width: 80, height: 20), source: .ocr)]
            scene.fingerprint = "Next"
            return scene
        }
        func captureForSettling(rect: CGRect) async -> ScreenFrame? { nil }
    }

    private final class NoInput: InputSink, @unchecked Sendable {
        func mayAct() -> Bool { true }
        func move(to point: CGPoint) async throws {}
        func click(at point: CGPoint, right: Bool, count: Int) async throws {}
        func drag(from: CGPoint, to: CGPoint) async throws {}
        func scroll(at point: CGPoint, dx: Int, dy: Int) async throws {}
        func key(code: CGKeyCode, flags: CGEventFlags) async throws {}
        func type(_ text: String) async throws {}
        func perform(_ effect: () throws -> Void) throws { try effect() }
    }

    private func adapter(asking decision: String) -> LocalAgentCapabilityAdapter {
        LocalAgentCapabilityAdapter(runtimeLabel: "test") { goal, prior in
            var configuration = HarnessConfiguration()
            configuration.supportsVision = false
            configuration.settleLimit = 0.01
            return AgentHarness(goal: goal, model: ScriptedModel(decision), actuator: Actuator(input: NoInput()),
                                builder: StillWorld(), configuration: configuration, priorContext: prior)
        }
    }

    private var tools: ComputerUseHostTools { ComputerUseHostTools(injector: InputInjector(), mayAct: { false }) }

    func testFreeTextQuestionReachesThePhoneWithoutChoices() async throws {
        let agent = adapter(asking: #"{"step":1,"thought":"t","tool":"ask_user","text":"Which flight date?"}"#)
        let result = try await agent.execute(taskID: "task-1", prompt: "Find a flight", trustedUserPrompt: "Find a flight",
                                             tools: tools, progress: { _ in })
        guard case .clarificationRequired = result else { return XCTFail("Expected a question, got \(result)") }
        let question = try XCTUnwrap(agent.clarification(taskID: "task-1"))
        XCTAssertNil(question.choices, "An empty choice list is invalid in the protocol")
        XCTAssertEqual(question.question, "Which flight date?")
    }

    func testModelChoicesAreCleanedToWhatThePhoneAccepts() async throws {
        let long = String(repeating: "x", count: 700)
        let labels = ["A", "A", "  ", long] + (1...12).map { "Option \($0)" }
        let json = labels.map { "\"\($0)\"" }.joined(separator: ",")
        let agent = adapter(asking: #"{"step":1,"thought":"t","tool":"ask_user","text":"Which one?","choices":[\#(json)]}"#)
        _ = try await agent.execute(taskID: "task-2", prompt: "Pick one", trustedUserPrompt: "Pick one",
                                    tools: tools, progress: { _ in })
        let choices = try XCTUnwrap(agent.clarification(taskID: "task-2")?.choices)
        XCTAssertEqual(choices.count, ComputerUseClarificationChoice.maximumChoices)
        XCTAssertEqual(choices.first?.label, "A")
        XCTAssertEqual(choices[1].label.utf8.count, ComputerUseClarificationChoice.maximumDisplayBytes)
        XCTAssertNoThrow(try ComputerUseClarificationChoice.validate(choices))
    }

    func testATaskLeftWaitingDoesNotBlockTheNextRequest() async throws {
        let agent = adapter(asking: #"{"step":1,"thought":"t","tool":"ask_user","text":"Which one?"}"#)
        _ = try await agent.execute(taskID: "task-3", prompt: "First", trustedUserPrompt: "First",
                                    tools: tools, progress: { _ in })
        // The manager drops the question, as it does when a task ends while one is open.
        agent.invalidateClarification(taskID: "task-3")
        let next = try await agent.execute(taskID: "task-4", prompt: "Second", trustedUserPrompt: "Second",
                                           tools: tools, progress: { _ in })
        guard case .clarificationRequired = next else { return XCTFail("The new request should run, got \(next)") }
    }
}
