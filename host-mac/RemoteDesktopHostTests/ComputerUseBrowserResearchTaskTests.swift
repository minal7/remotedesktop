import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchTaskTests: XCTestCase {
    func testQuestionRequestRequiresCurrentInterpretationAndCannotEscapePauseOrRetirement() async throws {
        let planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { browser.close() }
        let owner = makeOwner(try goal(), browser: browser, planner: planner)
        XCTAssertThrowsError(try owner.proposedQuestionRequest()) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .interpretationRequired)
        }
        planner.questionTopic = .location
        _ = try await owner.interpretGoal()
        let proposal = try XCTUnwrap(owner.proposedQuestionRequest())
        XCTAssertEqual(proposal.taskID, owner.taskID); XCTAssertEqual(proposal.inputDigest, owner.input.digest)
        XCTAssertEqual(proposal.topic, .location)
        XCTAssertEqual(try owner.proposedQuestionRequest(), proposal)
        XCTAssertEqual(planner.inputs.count, 1, "Converting a current interpretation does not invoke the model again")
        let question = try owner.issueQuestion(topic: proposal.topic, requirementIDs: proposal.requirementIDs,
            controllerID: "controller", controllerSessionID: "session")
        XCTAssertThrowsError(try owner.proposedQuestionRequest()) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .questionPending)
        }
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Paris",
            controllerID: "controller", controllerSessionID: "session")
        planner.questionTopic = nil
        _ = try await owner.interpretGoal()
        XCTAssertNil(try owner.proposedQuestionRequest(), "Research disposition cannot manufacture a question")
        owner.pause()
        XCTAssertThrowsError(try owner.proposedQuestionRequest()) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .paused)
        }
        try await owner.resumeAfterUserControl()
        XCTAssertNil(try owner.proposedQuestionRequest())
        owner.retire()
        XCTAssertThrowsError(try owner.proposedQuestionRequest()) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .retired)
        }
        XCTAssertNil(browser.taskID)
    }

    func testResearchOwnerRetainsInterpretationAndRejectsForeignProposal() async throws {
        let planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { browser.close() }
        let input = try goal(), owner = makeOwner(input, browser: browser, planner: planner)
        planner.replacement = try goal(taskID: "foreign")
        do { _ = try await owner.interpretGoal(); XCTFail("A foreign proposal cannot become the canonical interpretation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .goalChanged) }
        planner.replacement = nil
        let interpreted = try await owner.interpretGoal()
        XCTAssertEqual(interpreted.proposal.input, input)
        XCTAssertEqual(interpreted.scalars.unresolvedRequirementIDs, interpreted.proposal.requirements.map(\.id))
        _ = try await owner.interpretGoal()
        XCTAssertEqual(planner.inputs.count, 2, "The current interpretation is retained, not inferred again")
        XCTAssertNil(browser.taskID, "Goal interpretation does not create or claim a browser")
        do { _ = try await owner.readCandidates(); XCTFail("Reading requires the actual owned page") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .browserRequired) }
    }

    func testResearchPauseHoldsCancelledOperationUntilActualUnwindAndExplicitResume() async throws {
        let gate = BrowserResearchGate(), planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { gate.release(); browser.close() }
        planner.beforeReply = { await gate.suspend() }
        let input = try goal(), owner = makeOwner(input, browser: browser, planner: planner)
        let running = Task { try await owner.interpretGoal() }
        try await gate.waitUntilStarted()
        owner.pause()
        XCTAssertTrue(owner.isOperating)
        do { try await owner.resumeAfterUserControl(); XCTFail("A cancelled task still owns the operation slot") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        do { _ = try await owner.interpretGoal(); XCTFail("Pause needs explicit handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        gate.release()
        do { _ = try await running.value; XCTFail("A late model result cannot publish after Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating)
        planner.beforeReply = nil
        try await owner.resumeAfterUserControl()
        _ = try await owner.interpretGoal()
        XCTAssertEqual(planner.inputs, [input, input])
    }

    func testParentCancellationRetainsExclusionWithoutInventingACompletedInterpretation() async throws {
        let gate = BrowserResearchGate(), planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { gate.release(); browser.close() }
        planner.beforeReply = { await gate.suspend() }
        let owner = makeOwner(try goal(), browser: browser, planner: planner)
        let running = Task { try await owner.interpretGoal() }
        try await gate.waitUntilStarted()
        running.cancel()
        do { _ = try await owner.interpretGoal(); XCTFail("Cancellation alone does not release the child operation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        gate.release()
        do { _ = try await running.value; XCTFail("Cancelled parent must not receive a successful result") }
        catch { XCTAssertTrue(error is CancellationError) }
        planner.beforeReply = nil
        _ = try await owner.interpretGoal()
        XCTAssertEqual(planner.inputs.count, 2)
    }

    func testResearchQuestionsPreserveRootAndInvalidateRevisionCaches() async throws {
        let planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { browser.close() }
        let input = try goal(), owner = makeOwner(input, browser: browser, planner: planner)
        let interpreted = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpreted.proposal.requirements[0].id],
            controllerID: "controller", controllerSessionID: "session")
        do { _ = try await owner.interpretGoal(); XCTFail("A pending question is not permission to infer again") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .questionPending) }
        XCTAssertThrowsError(try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Paris",
            controllerID: "other-controller", controllerSessionID: "session"))
        let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "  Paris\n",
            controllerID: "controller", controllerSessionID: "session")
        XCTAssertEqual(updated.taskID, input.taskID); XCTAssertEqual(updated.rootDigest, input.rootDigest)
        XCTAssertEqual(updated.referenceMilliseconds, input.referenceMilliseconds); XCTAssertEqual(updated.userTurns, [input.prompt, "  Paris\n"])
        do { _ = try await owner.readCandidates(); XCTFail("An answer requires a fresh interpretation before reading") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .interpretationRequired) }
        let fresh = try await owner.interpretGoal()
        XCTAssertEqual(fresh.proposal.input, updated); XCTAssertEqual(planner.inputs, [input, updated])
        XCTAssertThrowsError(try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "  Paris\n",
            controllerID: "controller", controllerSessionID: "session"))
    }

    func testExpiredQuestionAndPauseCannotLeavePhantomPendingState() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { browser.close() }
        let owner = ComputerUseBrowserResearchTask(input: try goal(), browser: browser, goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture(), mayAct: { true }, now: { now })
        let interpretation = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .date, requirementIDs: [interpretation.proposal.requirements[0].id],
            controllerID: "controller", controllerSessionID: "session")
        now = question.expiresAt
        XCTAssertThrowsError(try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "tomorrow",
            controllerID: "controller", controllerSessionID: "session")) {
            XCTAssertEqual($0 as? ComputerUseBrowserGoalClarification.Failure, .expired)
        }
        _ = try await owner.interpretGoal()
        let replacement = try owner.issueQuestion(topic: .date, requirementIDs: [interpretation.proposal.requirements[0].id],
            controllerID: "controller", controllerSessionID: "session")
        owner.pause(); try await owner.resumeAfterUserControl()
        XCTAssertNil(try owner.pendingQuestion(controllerID: "controller", controllerSessionID: "session"))
        XCTAssertThrowsError(try owner.answerQuestion(questionID: replacement.id, answerTaskID: "answer", answer: "tomorrow",
            controllerID: "controller", controllerSessionID: "session"))
        XCTAssertEqual(planner.inputs.count, 1)
    }

    func testRetirementCannotBeUndoneByLateModelReplyOrControlChange() async throws {
        let gate = BrowserResearchGate(), planner = BrowserResearchGoalFixture(), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        var mayAct = true
        defer { gate.release(); browser.close() }
        planner.beforeReply = { await gate.suspend() }
        let owner = ComputerUseBrowserResearchTask(input: try goal(), browser: browser, goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture(), mayAct: { mayAct })
        let running = Task { try await owner.interpretGoal() }
        try await gate.waitUntilStarted()
        owner.retire(); mayAct = false
        gate.release()
        do { _ = try await running.value; XCTFail("A retired owner cannot publish a late result") }
        catch { XCTAssertTrue(error is CancellationError) }
        mayAct = true
        do { try await owner.resumeAfterUserControl(); XCTFail("Control restoration cannot revive a stopped owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        do { _ = try await owner.interpretGoal(); XCTFail("Retirement is terminal") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
    }

    func testHostPreparationRetainsClockAndWiresPauseResumeStopAndReplacement() async throws {
        let planner = BrowserResearchGoalFixture(), reader = BrowserResearchResultFixture()
        let browser = ComputerUseOwnedBrowser(presentsWindow: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let navigation = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: navigation)
        defer { tools.closeOwnedBrowser(); try? FileManager.default.removeItem(at: directory) }
        let original = try goal()
        let owner = try tools.prepareOwnedBrowserResearch(taskID: original.taskID, prompt: original.prompt,
            goalPlanner: planner, resultPlanner: reader, referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        let retained = try tools.prepareOwnedBrowserResearch(taskID: original.taskID, prompt: original.prompt,
            goalPlanner: planner, resultPlanner: reader, referenceDate: Date(timeIntervalSince1970: 1_900_000_000), timeZoneIdentifier: "UTC")
        XCTAssertTrue(owner === retained); XCTAssertEqual(owner.input, original)
        XCTAssertThrowsError(try tools.prepareOwnedBrowserResearch(taskID: original.taskID, prompt: "Changed request",
            goalPlanner: planner, resultPlanner: reader))
        _ = try await owner.interpretGoal()
        tools.pauseOwnedBrowserResearch(taskID: original.taskID)
        do { _ = try await owner.interpretGoal(); XCTFail("Host Pause reaches the retained owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        try await tools.resumeOwnedBrowserResearch(taskID: original.taskID)
        _ = try await owner.interpretGoal()
        tools.stopOwnedBrowserActivity()
        do { _ = try await retained.interpretGoal(); XCTFail("Browser Stop retires the owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        let stopped = try tools.prepareOwnedBrowserResearch(taskID: original.taskID, prompt: original.prompt,
            goalPlanner: planner, resultPlanner: reader)
        XCTAssertTrue(stopped === owner, "Preparing a stopped root again cannot allocate a fresh owner")
        do { _ = try await stopped.interpretGoal(); XCTFail("Retrieving a stopped root cannot revive it") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
        let replacement = try tools.prepareOwnedBrowserResearch(taskID: "new-root", prompt: original.prompt, goalPlanner: planner, resultPlanner: reader)
        XCTAssertFalse(owner === replacement)
        _ = try await replacement.interpretGoal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Planning does not create effect journals")
        XCTAssertNil(browser.taskID)
    }

    private func goal(taskID: String = "research-root") throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: taskID, prompt: "Find concert tickets tomorrow.", referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
    }
    private func makeOwner(_ input: ComputerUseBrowserGoalInput, browser: ComputerUseOwnedBrowser, planner: BrowserResearchGoalFixture) -> ComputerUseBrowserResearchTask {
        .init(input: input, browser: browser, goalPlanner: planner, resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
    }
}

@MainActor
final class BrowserResearchGate {
    private var waiting: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
        }
    }
    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while waiting == nil {
            guard ContinuousClock.now < deadline else { throw FixtureFailure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func release() { let pending = waiting; waiting = nil; pending?.resume() }
    private enum FixtureFailure: Error { case didNotStart }
}

@MainActor
final class BrowserResearchGoalFixture: ComputerUseBrowserGoalPlanning {
    private(set) var inputs: [ComputerUseBrowserGoalInput] = []
    var replacement: ComputerUseBrowserGoalInput?
    var beforeReply: (@MainActor () async -> Void)?
    var questionTopic: ComputerUseBrowserClarificationTopic?
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        inputs.append(input)
        if let beforeReply { await beforeReply() } // Deliberately ignores cancellation until the fixture is released.
        let goal = replacement ?? input
        let rows: [[String: Any]] = goal.userTurns.enumerated().map { index, source in
            ["turn":index, "source":source, "role":index == 0 ? "outcome" : "condition",
                "field":index == 0 ? "category" : "other", "relation":"unspecified", "values":[]]
        }
        let question: [String: Any] = ["topic":questionTopic?.rawValue ?? "none", "requirements":questionTopic == nil ? [] : [0]]
        let data = try JSONSerialization.data(withJSONObject: ["disposition":questionTopic == nil ? "research" : "clarification",
            "question":question, "requirements":rows])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: goal)
    }
}

@MainActor
final class BrowserResearchResultFixture: ComputerUseBrowserResultPlanning {
    private(set) var inputs: [ComputerUseBrowserGoalInput] = []
    var beforeReply: (@MainActor () async -> Void)?
    func propose(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput) async throws -> ComputerUseBrowserResultProposal {
        inputs.append(goal)
        if let beforeReply { await beforeReply() }
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.contextJSON.utf8)) as? [String: Any])
        let records = try XCTUnwrap(context["records"] as? [[String: Any]])
        let title = try XCTUnwrap(records.first { $0["text"] as? String == "Concert Alpha" })
        var group = try XCTUnwrap(title["group"] as? String)
        while let container = records.first(where: { $0["kind"] as? String == "container" && $0["id"] as? String == group }),
              container["element"] as? String != "article" {
            group = try XCTUnwrap(container["parent"] as? String)
        }
        let field: [String: Any] = ["kind":"title", "texts":[try XCTUnwrap(title["id"] as? String)]]
        let candidate: [String: Any] = ["container":group, "fields":[field], "links":[]]
        let data = try JSONSerialization.data(withJSONObject: ["candidates":[candidate]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: page, goal: goal)
    }
}
