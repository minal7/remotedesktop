import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentTaskExecutorTests: XCTestCase {
    func testSameTaskReusesLoopAndRejectsPromptChanges() async throws {
        let fixture = ExecutorFixture(replies: [[.action(.askUser(question: "Choose", choices: nil))]])
        let executor = AgentTaskExecutor { taskID, prompt in
            fixture.factoryCount += 1
            return try fixture.makeLoop(taskID: taskID, prompt: prompt)
        }

        let result = try await executor.execute(taskID: "task-a", prompt: "Original request")
        guard case .askUser = result else { return XCTFail("Expected a pending question") }
        XCTAssertEqual(executor.activeTaskID, "task-a")
        XCTAssertEqual(executor.activePrompt, "Original request")
        let originalLoop = try XCTUnwrap(executor.activeLoop)
        let repeated = try await executor.execute(taskID: "task-a", prompt: "Original request")
        XCTAssertEqual(repeated, result)
        XCTAssertTrue(executor.activeLoop === originalLoop)
        XCTAssertEqual(fixture.factoryCount, 1)
        do {
            _ = try await executor.execute(taskID: "task-a", prompt: "Changed request")
            XCTFail("A task must not be rebound to a different prompt")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .promptChanged) }
        XCTAssertTrue(executor.activeLoop === originalLoop)
    }

    func testQuestionIDAndTaskIDMustMatchBeforeAnswering() async throws {
        let fixture = ExecutorFixture(replies: [[
            .action(.askUser(question: "Choose one", choices: ["A", "B"])),
            .action(.done(answer: "Done"))
        ]])
        let executor = makeExecutor(fixture)
        let result = try await executor.execute(taskID: "task-q", prompt: "Pick")
        guard case .askUser(let question) = result else { return XCTFail("Expected a question") }

        do {
            _ = try await executor.answer(taskID: "task-q", questionID: UUID(), answer: "A")
            XCTFail("A stale question id must not be accepted")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .staleQuestion) }
        do {
            _ = try await executor.answer(taskID: "another-task", questionID: question.id, answer: "A")
            XCTFail("A different task id must not be accepted")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .taskMismatch) }

        let answer = try await executor.answer(taskID: "task-q", questionID: question.id, answer: "A")
        XCTAssertEqual(answer, .completed(answer: "Done"))
        XCTAssertEqual(fixture.factoryCount, 1)
    }

    func testApprovalRequestMustBelongToActiveTaskAndPendingStep() async throws {
        let fixture = ExecutorFixture(replies: [[.action(.click(target: .element(id: 1), button: nil, count: nil))]])
        let executor = makeExecutor(fixture)
        let result = try await executor.execute(taskID: "task-approval", prompt: "Click")
        guard case .pendingApproval(let request) = result else { return XCTFail("Expected approval") }

        let forged = AgentApprovalRequest(id: UUID(), taskID: request.taskID, scopeIdentity: request.scopeIdentity,
            fingerprint: request.fingerprint, riskTier: request.riskTier, reason: request.reason, action: request.action)
        do {
            _ = try await executor.resumeApproval(taskID: "task-approval", request: forged, approved: true)
            XCTFail("A stale approval id must not be accepted")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .staleApproval) }
        let altered = AgentApprovalRequest(id: request.id, taskID: request.taskID,
            scopeIdentity: request.scopeIdentity, fingerprint: request.fingerprint, riskTier: request.riskTier,
            reason: "Changed request", action: request.action)
        do {
            _ = try await executor.resumeApproval(taskID: "task-approval", request: altered, approved: true)
            XCTFail("Approval metadata must match the exact pending request")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .staleApproval) }
        do {
            _ = try await executor.resumeApproval(taskID: "other-task", request: request, approved: true)
            XCTFail("Approval cannot cross task scope")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .taskMismatch) }
        XCTAssertEqual(fixture.environment.executed.count, 0)
    }

    func testNewTaskCannotReplaceAnUnfinishedLoopUntilCancelCompletes() async throws {
        let fixture = ExecutorFixture(replies: [[.action(.askUser(question: "Continue?", choices: nil))]])
        let executor = makeExecutor(fixture)
        _ = try await executor.execute(taskID: "old", prompt: "Old task")

        do {
            _ = try await executor.execute(taskID: "new", prompt: "New task")
            XCTFail("An unfinished loop must retain ownership")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .taskAlreadyActive("old")) }
        XCTAssertEqual(executor.activeTaskID, "old")
        XCTAssertEqual(fixture.factoryCount, 1)

        try await executor.cancel()
        XCTAssertNil(executor.activeTaskID)
        XCTAssertEqual(fixture.recorder.footer?.outcome, "cancelled")
    }

    func testCancellationKeepsOwnershipUntilActiveEffectUnwinds() async throws {
        let fixture = ExecutorFixture(replies: [[.action(.click(target: .element(id: 1), button: nil, count: nil))]],
                                      blockExecution: true, trustedWeb: true)
        let executor = makeExecutor(fixture)
        let execution = Task { try await executor.execute(taskID: "task-cancel", prompt: "Click") }
        while !fixture.environment.executionStarted { await Task.yield() }
        executor.requestCancellation()
        do {
            _ = try await executor.execute(taskID: "replacement", prompt: "Do something else")
            XCTFail("The synchronous cancellation fence must reject new work")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .cancellationInProgress) }
        let cancel = Task { try await executor.cancel() }
        await Task.yield()
        do {
            _ = try await executor.execute(taskID: "replacement", prompt: "Do something else")
            XCTFail("Ownership cannot move while cancellation is unwinding")
        } catch { XCTAssertEqual(error as? AgentTaskExecutorError, .cancellationInProgress) }
        try await cancel.value

        guard case .cancelled = try await execution.value else { return XCTFail("Expected cancelled execution") }
        XCTAssertNil(executor.activeTaskID)
        XCTAssertEqual(fixture.journal.uncertain.count, 1)
        XCTAssertEqual(fixture.environment.executed.count, 1)
    }

    func testCompletedLoopCanBeReplacedByNextTask() async throws {
        let fixture = ExecutorFixture(replies: [[.action(.done(answer: "First"))], [.action(.done(answer: "Second"))]])
        let executor = makeExecutor(fixture)
        let first = try await executor.execute(taskID: "first", prompt: "One")
        let second = try await executor.execute(taskID: "second", prompt: "Two")
        XCTAssertEqual(first, .completed(answer: "First"))
        XCTAssertEqual(second, .completed(answer: "Second"))
        XCTAssertEqual(fixture.factoryCount, 2)
        XCTAssertEqual(executor.activeTaskID, "second")
    }

    func testExecuteResumesAnExistingPausedLoopWithoutReplacingIt() async throws {
        let fixture = ExecutorFixture(replies: [[.action(.done(answer: "Resumed"))]])
        let executor = AgentTaskExecutor { taskID, prompt in
            fixture.factoryCount += 1
            let loop = try fixture.makeLoop(taskID: taskID, prompt: prompt)
            await loop.pause()
            return loop
        }

        let result = try await executor.execute(taskID: "paused-task", prompt: "Continue")
        XCTAssertEqual(result, .completed(answer: "Resumed"))
        XCTAssertEqual(fixture.factoryCount, 1)
        XCTAssertEqual(fixture.environment.resumeCount, 1)
        XCTAssertEqual(executor.activeTaskID, "paused-task")
    }

    private func makeExecutor(_ fixture: ExecutorFixture) -> AgentTaskExecutor {
        AgentTaskExecutor { taskID, prompt in
            fixture.factoryCount += 1
            return try fixture.makeLoop(taskID: taskID, prompt: prompt)
        }
    }
}

@MainActor
private final class ExecutorFixture {
    private var replies: [[ExecutorPolicy.Reply]]
    private let blockExecution: Bool
    private let trustedWeb: Bool
    var factoryCount = 0
    let environment: ExecutorEnvironment
    let recorder = ExecutorRecorder()
    let journal = ExecutorJournal()

    init(replies: [[ExecutorPolicy.Reply]], blockExecution: Bool = false, trustedWeb: Bool = false) {
        self.replies = replies; self.blockExecution = blockExecution; self.trustedWeb = trustedWeb
        environment = ExecutorEnvironment(blockExecution: blockExecution)
    }

    func makeLoop(taskID: String, prompt: String) throws -> AgentLoop {
        environment.bind(taskID: taskID)
        let policy = ExecutorPolicy(replies: replies.isEmpty ? [] : replies.removeFirst())
        return try AgentLoop(taskID: taskID, prompt: prompt, environment: environment, policy: policy,
            gate: AgentActionGate(trustStore: ExecutorTrustStore(trustedWeb: trustedWeb), allowPolicy: ExecutorAllowPolicy()),
            recorder: recorder, journal: journal)
    }
}

@MainActor
private final class ExecutorPolicy: AgentPolicy {
    enum Reply { case action(AgentAction) }
    let promptVersion = "executor-test"
    private var replies: [Reply]
    init(replies: [Reply]) { self.replies = replies }
    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        guard !replies.isEmpty else { return .init(rawOutput: "", action: nil, rejectionReason: "No reply") }
        guard case let .action(action) = replies.removeFirst() else { fatalError("Unexpected test reply") }
        return .init(rawOutput: action.type, action: action, rejectionReason: nil)
    }
    func stop() async {}
}

@MainActor
private final class ExecutorEnvironment: AgentEnvironment {
    private let blockExecution: Bool
    private var continuation: CheckedContinuation<AgentExecutionResult, Error>?
    private(set) var executionStarted = false
    private(set) var executed: [AgentResolvedAction] = []
    private(set) var stopCount = 0
    private(set) var resumeCount = 0
    private(set) var taskID = ""
    init(blockExecution: Bool) { self.blockExecution = blockExecution }
    func bind(taskID: String) { self.taskID = taskID }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        return frame(taskID: taskID, task: context.task)
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        if case let .click(target, _, _) = action, case let .element(id) = target,
           let element = frame.observation.elements.first(where: { $0.id == id }) {
            return .init(action: action, frame: frame, targets: [element])
        }
        return .init(action: action, frame: frame, targets: [])
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        executionStarted = true; executed.append(resolved)
        if blockExecution { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return .init(status: .ok, result: "Executed")
    }
    func suspend() async {
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
    func stop() async {
        stopCount += 1; continuation?.resume(throwing: CancellationError()); continuation = nil
    }
    func resume() async throws { resumeCount += 1 }

    private func frame(taskID: String, task: String) -> AgentFrame {
        let element = AgentElement(id: 1, role: "button", name: "Continue", value: nil, state: ["enabled"],
                                   bbox: .init(x: 1, y: 2, width: 40, height: 12), inView: true)
        let observation = AgentObservation(task: task, surface: .web(url: "https://example.test/", title: nil),
            screenshot: "", elements: [element], focus: nil, history: [], budget: .init(step: 0, maxSteps: 40))
        return .init(observation: observation, scope: .init(taskID: taskID, kind: .web, identity: "tab"))
    }
}

@MainActor
private final class ExecutorRecorder: AgentRecording {
    private(set) var footer: AgentEpisodeFooter?
    func record(_ step: AgentEpisodeStep) throws {}
    func finish(_ footer: AgentEpisodeFooter) throws { self.footer = footer }
}

@MainActor
private final class ExecutorJournal: AgentEffectJournaling {
    private(set) var uncertain: [Int] = []
    func begin(step: Int, fingerprint: String) throws {}
    func verify(step: Int, fingerprint: String) throws {}
    func markUncertain(step: Int, fingerprint: String) throws { uncertain.append(step) }
    func assertMayContinue() throws {}
}

@MainActor
private final class ExecutorTrustStore: AgentTrustStore {
    let trustedWeb: Bool
    init(trustedWeb: Bool) { self.trustedWeb = trustedWeb }
    func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool { kind == .web && trustedWeb }
    func markTrusted(kind: AgentScope.Kind, identity: String) throws {}
}

@MainActor
private final class ExecutorAllowPolicy: AgentAllowPolicy {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? { nil }
}
