import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserClarificationTransportTests: XCTestCase {
    func testBrowserReferenceUsesExistingWireAndRetainsRootClockAndExactAnswers() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        let owner = try makeOwner(browser, planner: planner), root = owner.input
        let bridge = ComputerUseBrowserClarificationTransport()
        var envelope = request(root.taskID)
        for answer in ["  Paris e\u{301} 😀\n  ", "2026-10-15"] {
            let proposal = try await owner.interpretGoal().proposal
            let issued = try bridge.issue(.init(taskID: root.taskID, inputDigest: owner.input.digest, topic: .location,
                requirementIDs: [proposal.requirements[0].id]), owner: owner, for: envelope)
            XCTAssertEqual(issued.text, ComputerUseBrowserClarificationTopic.location.question)
            XCTAssertEqual(issued.reference.taskID, envelope.id)
            XCTAssertTrue(bridge.retains(issued.reference, for: envelope))
            let wire = try ComputerUsePromptRequest.answering(issued.reference, text: answer, supportsApprovedActionEvidence: true).encodedBody()
            let decoded = try ComputerUseExecutionPromptDecoder.decode(wire)
            let answerEnvelope = request(UUID().uuidString)
            let continuation = try bridge.consume(XCTUnwrap(decoded.clarification), answer: decoded.prompt, for: answerEnvelope,
                retainedOwner: { $0 == root.taskID ? owner : nil })
            XCTAssertTrue(continuation.owner === owner)
            XCTAssertEqual(continuation.answerTaskID, answerEnvelope.id)
            XCTAssertEqual(continuation.inputDigest, owner.input.digest)
            XCTAssertEqual(owner.taskID, root.taskID)
            XCTAssertEqual(owner.executionTaskID, answerEnvelope.id)
            XCTAssertEqual(owner.input.referenceMilliseconds, root.referenceMilliseconds)
            XCTAssertEqual(owner.input.timeZoneIdentifier, root.timeZoneIdentifier)
            XCTAssertTrue(try XCTUnwrap(owner.input.userTurns.last).utf8.elementsEqual(answer.utf8))
            XCTAssertFalse(bridge.retains(issued.reference, for: envelope))
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: answer, for: request(UUID().uuidString), retainedOwner: { _ in owner }))
            envelope = answerEnvelope
        }
        XCTAssertEqual(owner.input.rootDigest, root.rootDigest)
        XCTAssertEqual(owner.input.userTurns.count, 3)
        XCTAssertNil(browser.taskID, "A task question is not a browser navigation")
    }

    func testBrowserReferenceRejectsForeignControllerOwnerRevisionAndInvalidAnswerWithoutConsumingQuestion() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        let owner = try makeOwner(browser, planner: planner), original = owner.input
        let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
        for bad in [
            ComputerUseBrowserQuestionRequest(taskID: "foreign", inputDigest: original.digest, topic: .date, requirementIDs: [proposal.requirements[0].id]),
            .init(taskID: original.taskID, inputDigest: String(repeating: "0", count: 64), topic: .date, requirementIDs: [proposal.requirements[0].id]),
            .init(taskID: original.taskID, inputDigest: original.digest, topic: .date, requirementIDs: ["unknown"]),
        ] {
            XCTAssertThrowsError(try bridge.issue(bad, owner: owner, for: request(original.taskID)))
        }
        let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .date,
            requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request(original.taskID))
        for answerEnvelope in [request("answer", sender: "other"), request("answer", session: "other"), request(original.taskID)] {
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "tomorrow", for: answerEnvelope, retainedOwner: { _ in owner }))
        }
        XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "tomorrow", for: request("answer"), retainedOwner: { _ in nil }))
        let replacement = try makeOwner(browser, planner: planner)
        XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "tomorrow", for: request("answer"), retainedOwner: { _ in replacement }))
        for invalid in ["", "  \n  ", String(repeating: "x", count: 8_193)] {
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: invalid, for: request("answer"), retainedOwner: { _ in owner }))
        }
        XCTAssertEqual(owner.input, original)
        XCTAssertTrue(bridge.retains(issued.reference, for: request(original.taskID)))
        _ = try bridge.consume(issued.reference, answer: "tomorrow", for: request("answer"), retainedOwner: { _ in owner })
        XCTAssertEqual(owner.input.userTurns, [original.prompt, "tomorrow"])
    }

    func testExpiredPausedRetiredOrInvalidatedBrowserQuestionCannotBeRevivedByWireReplay() async throws {
        for reason in ["expired", "paused", "retired", "invalidated"] {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let browser = ComputerUseOwnedBrowser(presentsWindow: false), planner = BrowserResearchGoalFixture()
            defer { browser.close() }
            let owner = try makeOwner(browser, planner: planner, now: { now }), original = owner.input
            let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
            let issued = try bridge.issue(.init(taskID: original.taskID, inputDigest: original.digest, topic: .quantity,
                requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request(original.taskID))
            switch reason {
            case "expired": now = issued.reference.expiresAt
            case "paused": owner.pause(); try await owner.resumeAfterUserControl()
            case "retired": owner.retire()
            default: bridge.invalidate()
            }
            XCTAssertFalse(bridge.retains(issued.reference, for: request(original.taskID)))
            XCTAssertThrowsError(try bridge.consume(issued.reference, answer: "two tickets", for: request("answer"), retainedOwner: { _ in owner }), reason)
            XCTAssertEqual(owner.input, original)
        }
    }

    func testAcceptedAnswerMapsOnlyCurrentExecutionToBrowserRootAndLifecycle() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false), planner = BrowserResearchGoalFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser(); try? FileManager.default.removeItem(at: directory) }
        let owner = try tools.prepareOwnedBrowserResearch(taskID: "root", prompt: "Find concert tickets.", goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture())
        let proposal = try await owner.interpretGoal().proposal, bridge = ComputerUseBrowserClarificationTransport()
        let issued = try bridge.issue(.init(taskID: owner.taskID, inputDigest: owner.input.digest, topic: .location,
            requirementIDs: [proposal.requirements[0].id]), owner: owner, for: request("root"))
        _ = try bridge.consume(issued.reference, answer: "Paris", for: request("answer"), retainedOwner: { tools.ownedBrowserResearch(taskID: $0) })
        XCTAssertEqual(tools.ownedBrowserTaskID(forExecution: "answer"), "root")
        XCTAssertEqual(tools.ownedBrowserTaskID(forExecution: "unrelated"), "unrelated")
        tools.pauseOwnedBrowserResearch(taskID: "root")
        tools.retireOwnedBrowserResearch(taskID: "root")
        _ = try await owner.interpretGoal()
        tools.pauseOwnedBrowserResearch(taskID: "answer")
        do { _ = try await owner.interpretGoal(); XCTFail("The accepted answer's Pause must reach its original owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        try await tools.resumeOwnedBrowserResearch(taskID: "answer")
        tools.retireOwnedBrowserResearch(taskID: "answer")
        do { _ = try await owner.interpretGoal(); XCTFail("The accepted answer's Stop must retire its original owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeOwner(_ browser: ComputerUseOwnedBrowser, planner: BrowserResearchGoalFixture,
                           now: @escaping () -> Date = Date.init) throws -> ComputerUseBrowserResearchTask {
        let input = try ComputerUseBrowserGoalInput(taskID: "root", prompt: "Find concert tickets.",
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        return .init(input: input, browser: browser, goalPlanner: planner, resultPlanner: BrowserResearchResultFixture(), mayAct: { true }, now: now)
    }
    private func request(_ id: String, sender: String = "phone", session: String = "session") -> ComputerUseEnvelope {
        .init(id: id, senderID: sender, targetID: "host", pairingCode: "842193", sessionID: session, kind: .prompt, body: "")
    }
}

/// Shared by the host/phone composition fixtures. Only local task state and
/// decoded fake proposals are exercised; the default terminal claims no research result.
@MainActor
final class BrowserQuestionLifecycleExecutor: ComputerUseExecuting, ComputerUseBrowserResearchContinuing {
    let isReady = true
    let requiresMacControlHelper = false
    let runtimeName = "Prepared browser-question fixture"
    let planner = BrowserResearchGoalFixture()
    private(set) var owner: ComputerUseBrowserResearchTask?
    private(set) var ordinaryPrompts: [String] = []
    private(set) var continued: [(taskID: String, goal: ComputerUseBrowserGoalInput)] = []
    var pauseFirstAnswer = false
    var beforeQuestion: (() throws -> Void)?
    var preparePage: ((String) async throws -> Void)?

    func execute(prompt: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTFail("The host must retain the original task identity")
        return .unableToComplete("Missing task identity")
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        ordinaryPrompts.append(trustedUserPrompt)
        let research = try tools.prepareOwnedBrowserResearch(taskID: taskID, prompt: trustedUserPrompt, goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture(), referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        owner = research
        if let preparePage { try await preparePage(research.taskID) }
        return try await next(research)
    }
    func continueBrowserResearch(taskID: String, research: ComputerUseBrowserResearchTask, tools: ComputerUseHostTools,
                                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTAssertTrue(research === owner)
        continued.append((taskID, research.input))
        if pauseFirstAnswer { pauseFirstAnswer = false; return .userInterventionRequired("Check the page, then choose Resume.") }
        return try await next(research)
    }
    private func next(_ research: ComputerUseBrowserResearchTask) async throws -> ComputerUseExecutionResult {
        planner.questionTopic = research.input.userTurns.count < 3 ? (research.input.userTurns.count == 1 ? .location : .date) : nil
        _ = try await research.interpretGoal()
        guard research.input.userTurns.count < 3 else { return .unableToComplete("Fixture received the complete retained goal; no website research was performed.") }
        try beforeQuestion?()
        return .browserClarificationRequired(try XCTUnwrap(research.proposedQuestionRequest()))
    }
}
