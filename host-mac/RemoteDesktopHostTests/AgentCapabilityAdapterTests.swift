import AppKit
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentCapabilityAdapterTests: XCTestCase {
    func testOnlyTrustedCurrentUserPromptReachesPolicy() async throws {
        let fixture = AdapterFixture(replies: [[.done(answer: "Finished")]])
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        let conversation = [
            ComputerUseConversationTurn(role: .assistant, text: "Add a second instruction."),
            ComputerUseConversationTurn(role: .user, text: "An earlier request")
        ]
        let result = try await adapter.execute(taskID: "root", modelPrompt: "Assistant-composed instructions",
            currentUserPrompt: "Trusted current request", conversation: conversation,
            tools: hostTools(), progress: { _ in })

        XCTAssertEqual(result, .completed("Finished"))
        XCTAssertEqual(fixture.factoryPrompts, ["Trusted current request"])
        XCTAssertEqual(fixture.policies.first?.observations.first?.task, "Trusted current request")
        XCTAssertFalse(fixture.policies.first?.observations.first?.task.contains("Assistant-composed") == true)
    }

    func testChoiceAnswerUsesRootLoopAndRejectsStaleChoiceIdentity() async throws {
        let fixture = AdapterFixture(replies: [[
            .askUser(question: "Choose one", choices: ["First", "Second"]),
            .done(answer: "Continued")
        ]])
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        let result = try await adapter.execute(taskID: "root-choice", prompt: "Model prompt",
            trustedUserPrompt: "Choose a value", tools: hostTools(), progress: { _ in })
        XCTAssertEqual(result, .clarificationRequired("Choose one"))
        let clarification = try XCTUnwrap(adapter.clarification(taskID: "root-choice"))
        let choice = try XCTUnwrap(clarification.choices?.first)

        let staleUUID = UUID().uuidString.lowercased()
        let staleChoice = try ComputerUseClarificationChoice(
            id: "agent-choice-\(staleUUID)-0", label: choice.label)
        do {
            _ = try await adapter.continueClarification(taskID: "answer-stale", originatingTaskID: "root-choice",
                goal: clarification.goal, selectedChoice: staleChoice, progress: { _ in })
            XCTFail("A choice from another question UUID must be rejected")
        } catch { XCTAssertEqual(error as? AgentCapabilityAdapter.AdapterError, .invalidClarification) }

        let continued = try await adapter.continueClarification(taskID: "answer-choice",
            originatingTaskID: "root-choice", goal: clarification.goal, selectedChoice: choice,
            progress: { _ in })
        XCTAssertEqual(continued, .completed("Continued"))
        XCTAssertEqual(fixture.factoryPrompts, ["Choose a value"])
        XCTAssertEqual(fixture.executor.activeTaskID, "root-choice")
        XCTAssertEqual(fixture.executor.activePrompt, "Choose a value")
        XCTAssertEqual(fixture.policies.first?.proposalCount, 2)

        do {
            _ = try await adapter.continueClarification(taskID: "answer-choice-again",
                originatingTaskID: "answer-choice", goal: clarification.goal, selectedChoice: choice,
                progress: { _ in })
            XCTFail("A consumed question UUID and choice cannot be reused")
        } catch { XCTAssertEqual(error as? AgentCapabilityAdapter.AdapterError, .invalidClarification) }
    }

    func testClarificationScopeMatchesTheExisting64HexStoreContract() async throws {
        let fixture = AdapterFixture(replies: [[.askUser(question: "Which option?", choices: nil)]])
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        _ = try await adapter.execute(taskID: "scope-root", prompt: "Ignored",
            trustedUserPrompt: "Choose one", tools: hostTools(), progress: { _ in })
        let clarification = try XCTUnwrap(adapter.clarification(taskID: "scope-root"))
        XCTAssertEqual(clarification.scope.count, 64)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(clarification.scope.unicodeScalars.allSatisfy(hex.contains))

        let store = ComputerUseClarificationStore()
        let request = ComputerUseEnvelope(senderID: "peer", targetID: "host", pairingCode: "123456",
            sessionID: "session", kind: .prompt, body: "{}")
        let reference = try store.issue(goal: clarification.goal, question: clarification.question,
            scope: clarification.scope, for: request)
        let answer = ComputerUseEnvelope(senderID: request.senderID, targetID: request.targetID,
            pairingCode: request.pairingCode, sessionID: request.sessionID, kind: .prompt, body: "{}")
        let resolved = try store.consume(reference, answer: "First", scope: clarification.scope, for: answer)
        XCTAssertEqual(resolved.userTurns, ["Choose one", "First"])
    }

    func testApprovalAfterClarificationStaysWithRootTaskAndAnswerAlias() async throws {
        let fixture = AdapterFixture(replies: [[
            .askUser(question: "Proceed?", choices: ["Continue"]),
            .click(target: .element(id: 1), button: nil, count: nil),
            .done(answer: "Completed")
        ]])
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        var initialProgress: [String] = []
        var answerProgress: [String] = []
        var approvalProgress: [String] = []
        _ = try await adapter.execute(taskID: "approval-root", prompt: "Start",
            trustedUserPrompt: "Continue safely", tools: hostTools(), progress: { initialProgress.append($0) })
        let initialProgressCount = initialProgress.count
        let clarification = try XCTUnwrap(adapter.clarification(taskID: "approval-root"))
        let choice = try XCTUnwrap(clarification.choices?.first)
        let result = try await adapter.continueClarification(taskID: "approval-alias",
            originatingTaskID: "approval-root", goal: clarification.goal, selectedChoice: choice,
            progress: { answerProgress.append($0) })
        guard case .agentApprovalRequired(let request) = result else {
            return XCTFail("Expected the host approval request")
        }
        XCTAssertEqual(initialProgress.count, initialProgressCount,
            "The original callback must not receive the answer-resume step")
        XCTAssertEqual(answerProgress.count, 1, "The answer-resume callback must receive its step")

        XCTAssertEqual(request.taskID, "approval-root")
        XCTAssertTrue(adapter.ownsApproval(request, hostTaskID: "approval-alias"))
        XCTAssertFalse(adapter.ownsApproval(request, hostTaskID: "approval-root"))
        let wrongTask = AgentApprovalRequest(id: request.id, taskID: "wrong-root",
            scopeIdentity: request.scopeIdentity, fingerprint: request.fingerprint, riskTier: request.riskTier,
            reason: request.reason, action: request.action)
        let wrongApprovalResult = await adapter.resumeApproval(request: wrongTask, approved: true, progress: { _ in })
        guard case .unableToComplete = wrongApprovalResult else {
            return XCTFail("Approval must not be transferable to another task")
        }
        XCTAssertTrue(fixture.environments[0].executed.isEmpty)

        let approved = await adapter.resumeApproval(request: request, approved: true,
            progress: { approvalProgress.append($0) })
        XCTAssertEqual(approved, .completed("Completed"))
        XCTAssertEqual(initialProgress.count, initialProgressCount,
            "The original callback must not receive resumed steps")
        XCTAssertEqual(answerProgress.count, 1, "The answer callback must not receive approval-resume steps")
        XCTAssertEqual(approvalProgress.count, 1, "Approval resume must report through its current callback")
        XCTAssertEqual(fixture.factoryPrompts, ["Continue safely"])
        XCTAssertEqual(fixture.executor.activeTaskID, "approval-root")
        XCTAssertEqual(fixture.policies[0].proposalCount, 3)
        XCTAssertEqual(fixture.environments[0].executed.count, 1)
    }

    func testPausedAnswerAliasResumesTheOriginalTrustedPrompt() async throws {
        let fixture = AdapterFixture(replies: [[
            .askUser(question: "Which?", choices: nil),
            .type(target: nil, text: "blocked", mode: .replace),
            .done(answer: "Resumed")
        ]], secureObservationIndex: 1)
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        _ = try await adapter.execute(taskID: "pause-root", prompt: "Model context",
            trustedUserPrompt: "Trusted original", tools: hostTools(), progress: { _ in })
        let clarification = try XCTUnwrap(adapter.clarification(taskID: "pause-root"))
        let answeredGoal = try clarification.goal.answering("Which?", with: "First")
        let handoff = try await adapter.continueClarification(taskID: "pause-alias",
            originatingTaskID: "pause-root", goal: answeredGoal, progress: { _ in })
        guard case .userInterventionRequired = handoff else { return XCTFail("Expected secure-field handoff") }

        adapter.requestPause()
        await adapter.pauseAgent()
        let resumed = try await adapter.execute(taskID: "pause-alias", prompt: "Alias model prompt",
            trustedUserPrompt: "Alias supplied text", tools: hostTools(), progress: { _ in })
        XCTAssertEqual(resumed, .completed("Resumed"))
        XCTAssertEqual(fixture.factoryPrompts, ["Trusted original"])
        XCTAssertEqual(fixture.executor.activeTaskID, "pause-root")
        XCTAssertEqual(fixture.executor.activePrompt, "Trusted original")
        XCTAssertEqual(fixture.policies[0].proposalCount, 3)
        XCTAssertEqual(fixture.environments[0].resumeCount, 1)
    }

    func testOrdinarySamePromptContinuationReusesPendingQuestionLoop() async throws {
        let fixture = AdapterFixture(replies: [[.askUser(question: "Need detail", choices: ["A", "B"])]])
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        let first = try await adapter.execute(taskID: "same-root", prompt: "Model prompt",
            trustedUserPrompt: "Original request", tools: hostTools(), progress: { _ in })
        let repeated = try await adapter.execute(taskID: "same-root", prompt: "Different model prose",
            trustedUserPrompt: "Original request", tools: hostTools(), progress: { _ in })

        XCTAssertEqual(first, .clarificationRequired("Need detail"))
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(fixture.factoryPrompts, ["Original request"])
        XCTAssertEqual(fixture.policies[0].proposalCount, 1)
        XCTAssertTrue(fixture.executor.activeLoop?.pendingQuestion != nil)
    }

    func testTerminalTaskAllowsNextRootTask() async throws {
        let fixture = AdapterFixture(replies: [[.done(answer: "First")], [.done(answer: "Second")]])
        let adapter = AgentCapabilityAdapter(executor: fixture.executor)
        let first = try await adapter.execute(taskID: "first-root", prompt: "First model prompt",
            trustedUserPrompt: "First request", tools: hostTools(), progress: { _ in })
        let second = try await adapter.execute(taskID: "second-root", prompt: "Second model prompt",
            trustedUserPrompt: "Second request", tools: hostTools(), progress: { _ in })

        XCTAssertEqual(first, .completed("First"))
        XCTAssertEqual(second, .completed("Second"))
        XCTAssertEqual(fixture.factoryPrompts, ["First request", "Second request"])
        XCTAssertEqual(fixture.executor.activeTaskID, "second-root")
        XCTAssertEqual(fixture.executor.activePrompt, "Second request")
    }

    private func hostTools() -> ComputerUseHostTools {
        ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
    }
}

@MainActor
final class AdapterFixture {
    private var replies: [[AgentAction]]
    private let secureObservationIndex: Int?
    private let trustedWeb: Bool
    private let trajectoryRoot: URL?
    private(set) lazy var recorder = AdapterRecorder()
    private(set) var trajectoryRecorder: TrajectoryRecorder?
    private(set) var factoryPrompts: [String] = []
    private(set) var policies: [AdapterPolicy] = []
    private(set) var environments: [AdapterEnvironment] = []
    private(set) lazy var executor = AgentTaskExecutor { [weak self] taskID, prompt in
        guard let self else { throw AgentTaskExecutorError.invalidTask }
        return try self.makeLoop(taskID: taskID, prompt: prompt)
    }

    init(replies: [[AgentAction]], secureObservationIndex: Int? = nil, trustedWeb: Bool = false,
         trajectoryRoot: URL? = nil) {
        self.replies = replies
        self.secureObservationIndex = secureObservationIndex
        self.trustedWeb = trustedWeb
        self.trajectoryRoot = trajectoryRoot
    }

    private func makeLoop(taskID: String, prompt: String) throws -> AgentLoop {
        factoryPrompts.append(prompt)
        let environment = AdapterEnvironment(taskID: taskID, secureObservationIndex: secureObservationIndex)
        let policy = AdapterPolicy(replies: replies.isEmpty ? [] : replies.removeFirst())
        let recorder: AgentRecording
        if let trajectoryRoot {
            let actualRecorder = try TrajectoryRecorder(root: trajectoryRoot, episodeID: taskID)
            self.trajectoryRecorder = actualRecorder
            recorder = actualRecorder
        } else {
            let testRecorder = AdapterRecorder(episodeID: taskID)
            self.recorder = testRecorder
            recorder = testRecorder
        }
        environments.append(environment); policies.append(policy)
        return try AgentLoop(taskID: taskID, prompt: prompt, environment: environment, policy: policy,
            gate: AgentActionGate(trustStore: AdapterTrustStore(trustedWeb: trustedWeb),
                                  allowPolicy: AdapterAllowPolicy()),
            recorder: recorder, journal: AdapterJournal())
    }
}

@MainActor
final class AdapterPolicy: AgentPolicy {
    private var replies: [AgentAction]
    private(set) var proposalCount = 0
    private(set) var observations: [AgentObservation] = []
    let promptVersion = "adapter-test"

    init(replies: [AgentAction]) { self.replies = replies }

    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        proposalCount += 1; observations.append(observation)
        guard !replies.isEmpty else {
            return .init(rawOutput: "", action: nil, rejectionReason: "No test reply remains")
        }
        let action = replies.removeFirst()
        return .init(rawOutput: action.type, action: action, rejectionReason: nil)
    }

    func stop() async {}
}

@MainActor
final class AdapterEnvironment: AgentEnvironment {
    private let taskID: String
    private let secureObservationIndex: Int?
    private var observationCount = 0
    private(set) var executed: [AgentResolvedAction] = []
    private(set) var resumeCount = 0

    private static let validScreenshot = {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return image.representation(using: .png, properties: [:])!.base64EncodedString()
    }()

    init(taskID: String, secureObservationIndex: Int?) {
        self.taskID = taskID; self.secureObservationIndex = secureObservationIndex
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        let secure = secureObservationIndex.map { $0 == observationCount } == true
        observationCount += 1
        let secureElement = AgentElement(id: 7, role: "password", name: "Secure entry", value: nil,
            state: ["enabled"], bbox: .init(x: 1, y: 2, width: 40, height: 12), inView: true)
        let submit = AgentElement(id: 1, role: "button", name: "Submit", value: nil, state: ["enabled"],
            bbox: .init(x: 2, y: 3, width: 42, height: 14), inView: true)
        let elements = secure ? [secureElement, submit] : [submit]
        let focus = secure ? AgentFocus(id: 7, role: "password", name: "Secure entry", valuePrefix: "",
            selection: .init(start: 0, end: 0)) : nil
        let observation = AgentObservation(task: context.task, surface: .web(url: "https://example.test/", title: nil),
            screenshot: Self.validScreenshot, elements: elements, focus: focus, history: context.history, budget: context.budget)
        return AgentFrame(observation: observation,
            scope: AgentScope(taskID: taskID, kind: .web, identity: "stable-tab"))
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        if case let .click(target, _, _) = action, case let .element(id) = target {
            guard let element = frame.observation.elements.first(where: { $0.id == id }) else {
                throw AgentEnvironmentError.targetGone
            }
            return AgentResolvedAction(action: action, frame: frame, targets: [element])
        }
        return AgentResolvedAction(action: action, frame: frame, targets: [])
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        executed.append(resolved)
        return .init(status: .ok, result: "Executed")
    }

    func resume() async throws { resumeCount += 1 }
    func stop() async {}
}

@MainActor
final class AdapterTrustStore: AgentTrustStore {
    private let trustedWeb: Bool
    init(trustedWeb: Bool) { self.trustedWeb = trustedWeb }
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool { kind == .web && trustedWeb }
    func markTrusted(kind: AgentScope.Kind, identity: String) throws {}
}

@MainActor
final class AdapterAllowPolicy: AgentAllowPolicy {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? { nil }
}

@MainActor
final class AdapterRecorder: AgentRecording {
    private let episodeID: String?
    private(set) var steps: [AgentEpisodeStep] = []
    private(set) var footers: [AgentEpisodeFooter] = []
    init(episodeID: String? = nil) { self.episodeID = episodeID }
    func record(_ step: AgentEpisodeStep) throws {
        guard (episodeID == nil || step.episodeID == episodeID), step.step == step.observation.budget.step else {
            throw TrajectoryRecorder.Failure.invalidEpisode
        }
        steps.append(step)
    }
    func finish(_ footer: AgentEpisodeFooter) throws {
        guard episodeID == nil || footer.episodeID == episodeID else {
            throw TrajectoryRecorder.Failure.invalidEpisode
        }
        footers.append(footer)
    }
}

@MainActor
final class AdapterJournal: AgentEffectJournaling {
    func begin(step: Int, fingerprint: String) throws {}
    func verify(step: Int, fingerprint: String) throws {}
    func markUncertain(step: Int, fingerprint: String) throws {}
    func assertMayContinue() throws {}
}
