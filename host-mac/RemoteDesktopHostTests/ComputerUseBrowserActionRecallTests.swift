import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserActionRecallTests: XCTestCase {
    func testRecallInformsCurrentFormAndQueryWithoutRepeatingSearchOrReading() async throws {
        let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>USD 40</p>", searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input, archive = try owner.researchEvidence(for: owner.input)
        let beforeCalls = fixture.actions.inputs.count, beforeReadings = fixture.results.inputs.count
        fixture.actions.select = { input in
            if input.recalledReadingIndices.isEmpty { return #"{"reading":0}"# }
            if let review = try FormEffectScopeFixture.response(input, editing: ["Query":[0]]) { return review }
            if let query = input.queryControlIDs.first { return try self.json(["query":query]) }
            return try self.json(["form":XCTUnwrap(input.formIDs.first), "preserve":[]])
        }
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(fixture.actions.inputs.count - beforeCalls, 4)
        XCTAssertEqual(action.input.recalledReadingIndices, [0])
        let context = try object(action.input.contextJSON), recalled = try XCTUnwrap(context["recalled_readings"] as? [[String: Any]])
        XCTAssertEqual((context["goal"] as? [String: Any])?["request"] as? String, original.prompt)
        let observation = try XCTUnwrap(recalled.first?["observation"] as? [String: Any])
        let page = try XCTUnwrap(observation["page"] as? [String: Any]), records = try XCTUnwrap(page["records"] as? [[String: Any]])
        XCTAssertTrue(records.contains { $0["text"] as? String == "USD 40" })
        XCTAssertTrue(records.allSatisfy { ($0["id"] as? String)?.hasPrefix("r0/") == true })
        XCTAssertFalse(action.input.formIDs.contains { $0.hasPrefix("r0/") })
        for hidden in [fixture.base.absoluteString, action.input.evidence.documentID, original.digest] {
            XCTAssertFalse(action.input.contextJSON.contains(hidden))
        }
        let form = try await owner.prepareFormInput(for: action)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"#, input: form)
        _ = try await owner.executeForm(proposal, input: form)
        let query = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = query.step else { return XCTFail("Recall must preserve the current verified form receipt") }
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertEqual(fixture.results.inputs.count, beforeReadings)
        XCTAssertEqual(try owner.researchEvidence(for: original).digest, archive.digest)
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .formQuery])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testRecallRetainsOldRequirementMeaningUnderCurrentClarifications() async throws {
        let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>USD 40</p>")
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input, interpretation = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id], controllerID: "phone", controllerSessionID: "session")
        let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Montréal e\u{301} 😀. Do not buy.", controllerID: "phone", controllerSessionID: "session")
        _ = try await fixture.resume()
        fixture.actions.select = { $0.recalledReadingIndices.isEmpty ? #"{"reading":0}"# : #"{"unavailable":true}"# }
        let action = try await owner.planNextAction(using: fixture.actions), context = try object(action.input.contextJSON)
        let catalog = try XCTUnwrap(context["reading_catalog"] as? [[String: Any]])
        XCTAssertEqual(catalog.first?["current_goal_revision"] as? Bool, false)
        let recalled = try XCTUnwrap(context["recalled_readings"] as? [[String: Any]])
        XCTAssertEqual(recalled.first?["current_goal_revision"] as? Bool, false)
        XCTAssertEqual(recalled.first?["accepted_answer_count_at_reading"] as? Int, 0)
        XCTAssertEqual(action.input.interpretation.input, updated)
        XCTAssertTrue(action.input.contextJSON.contains("Montréal"))
        XCTAssertEqual(updated.rootDigest, original.rootDigest)
        XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(updated.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testRecallRejectsUnknownRepeatedHybridAndChangedArchiveInputs() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), base = try await owner.planNextAction(using: fixture.actions).input
        let archive = try owner.researchEvidence(for: owner.input)
        let input = try actionInput(base, archive: archive)
        let proposal = try ComputerUseBrowserActionProposal.decode(content: #"{"reading":0}"#, input: input)
        XCTAssertEqual(proposal.step, .recall(0))
        for content in [#"{"reading":-1}"#, #"{"reading":1}"#, #"{"reading":0.5}"#, #"{"reading":true}"#,
            #"{"reading":0,"reading":0}"#, #"{"reading":0,"read_results":true}"#, #"{"reading":0,"complete":true}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: content, input: input))
        }
        let recalled = try actionInput(base, archive: archive, recalled: [0])
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: #"{"reading":0}"#, input: recalled))
        XCTAssertThrowsError(try proposal.validate(for: recalled))
        XCTAssertThrowsError(try actionInput(base, archive: archive, recalled: [0, 0]))
        XCTAssertThrowsError(try actionInput(base, archive: nil, recalled: [0]))
        let historicForm = "r0/" + (try XCTUnwrap(input.formIDs.first))
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: json(["form":historicForm,"preserve":[]]), input: recalled))
        _ = try await owner.readCandidates()
        let changed = try actionInput(base, archive: owner.researchEvidence(for: owner.input))
        XCTAssertThrowsError(try proposal.validate(for: changed))
        do { _ = try await owner.prepareFormInput(for: proposal); XCTFail("A recall proposal is not an executable form choice") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
    }

    func testActionRecallRejectsAnotherSessionEvenWithTheSameRootRequest() async throws {
        let fixture = try await ResearchDriverFixture.make(), other = try await ResearchDriverFixture.make()
        defer { fixture.close(); other.close() }
        _ = try await fixture.start(); _ = try await other.start()
        let owner = try fixture.owner(), foreignOwner = try other.owner()
        let input = try await owner.planNextAction(using: fixture.actions).input
        XCTAssertEqual(owner.input, foreignOwner.input)
        let foreign = try foreignOwner.researchEvidence(for: foreignOwner.input)
        XCTAssertThrowsError(try actionInput(input, archive: foreign)) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchEvidenceError, .inputChanged)
        }
        let otherRoot = try ComputerUseBrowserGoalInput(taskID: "foreign", prompt: owner.input.prompt,
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: owner.input.timeZoneIdentifier)
        XCTAssertThrowsError(try ComputerUseBrowserResearchEvidence(goal: otherRoot).actionCatalog(goal: owner.input, page: input.evidence))
    }

    func testRecallLimitKeepsEveryRequestedReadingAndRequiresOneFinalDecision() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        for _ in 0..<8 { _ = try await owner.readCandidates() }
        let archive = try owner.researchEvidence(for: owner.input)
        XCTAssertEqual(archive.count, 9)
        let before = fixture.actions.inputs.count
        fixture.actions.select = { input in
            if let index = input.recallableReadingIndices.first { return try self.json(["reading":index]) }
            return #"{"unavailable":true}"#
        }
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(fixture.actions.inputs.count - before, 9)
        XCTAssertEqual(action.input.recalledReadingIndices, Array(0..<8))
        XCTAssertTrue(action.input.recallableReadingIndices.isEmpty)
        XCTAssertEqual((try object(action.input.contextJSON)["recalled_readings"] as? [[String: Any]])?.count, 8)
        XCTAssertThrowsError(try actionInput(action.input, archive: archive, recalled: Array(0..<9)))
        XCTAssertEqual(try owner.researchEvidence(for: owner.input).digest, archive.digest)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    func testLocalPlannerRecallsWithoutFormsAndCountsTheEntireExpandedContext() async throws {
        let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>Unresolved fees</p>")
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        for counts in [[3_008, 3_008], [3_008, 3_009]] {
            let transport = ActionRecallTransport(counts: counts), planner = try local(transport)
            do {
                let action = try await owner.planNextAction(using: planner)
                XCTAssertEqual(counts.last, 3_008)
                XCTAssertFalse(action.input.needsFormDecision); XCTAssertTrue(action.input.needsPlanningDecision)
                XCTAssertEqual(action.step, .unavailable)
            } catch { XCTAssertEqual(counts.last, 3_009); XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .contextLimit) }
            let calls = await transport.calls
            XCTAssertEqual(calls.counts.count, 2)
            XCTAssertEqual(calls.completions.count, counts.last == 3_008 ? 2 : 1)
            for (index, request) in calls.completions.enumerated() { XCTAssertEqual(request.httpBody, calls.counts[index].httpBody) }
            let body = try object(String(decoding: XCTUnwrap(calls.counts.last?.httpBody), as: UTF8.self))
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let context = try object(XCTUnwrap(messages.last?["content"]))
            XCTAssertEqual((context["goal"] as? [String: Any])?["request"] as? String, owner.input.prompt)
            XCTAssertEqual((context["recalled_readings"] as? [[String: Any]])?.count, 1)
            XCTAssertTrue(try json(context).contains("Unresolved fees"))
            XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        }
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertFalse(owner.isOperating)
    }

    func testPauseDuringRecallJoinsThePlannerBeforeExplicitHandbackAndKeepsHistory() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input, archive = try owner.researchEvidence(for: owner.input)
        fixture.actions.select = { input in input.recalledReadingIndices.isEmpty ? #"{"reading":0}"# : #"{"read_results":true}"# }
        var calls = 0
        fixture.actions.beforeReply = { calls += 1; if calls == 2 { await gate.suspend() } }
        let work = Task { try await owner.planNextAction(using: fixture.actions) }
        try await gate.waitUntilStarted()
        owner.pause(); XCTAssertTrue(owner.isOperating)
        do { try await owner.resumeAfterUserControl(); XCTFail("Recall cleanup still owns the operation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        gate.release()
        do { _ = try await work.value; XCTFail("A paused recall cannot publish an action") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.actions.beforeReply = nil
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        XCTAssertFalse(owner.isOperating)
        try await owner.resumeAfterUserControl()
        XCTAssertNotEqual(try owner.researchEvidence(for: original).digest, archive.digest)
        XCTAssertEqual(try owner.researchEvidence(for: original).count, archive.count)
        let resumed = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(resumed.step, .readResults); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testDeadlineCancelsAndJoinsRecallAndAnExpiredDecisionStartsNoObservation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), archive = try owner.researchEvidence(for: owner.input)
        let before = fixture.state.commands.count
        do { _ = try await owner.planNextAction(using: fixture.actions, budget: .zero); XCTFail("An expired decision cannot observe") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .deadlineExceeded) }
        XCTAssertEqual(fixture.state.commands.count, before)
        var calls = 0, cancelled = false, waiting = false
        fixture.actions.select = { _ in #"{"reading":0}"# }
        fixture.actions.beforeReply = {
            calls += 1
            if calls == 2 {
                waiting = true; defer { waiting = false }
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = error is CancellationError; throw error }
            }
        }
        do { _ = try await owner.planNextAction(using: fixture.actions, budget: .seconds(1)); XCTFail("Recall cannot reset the deadline") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .deadlineExceeded) }
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        XCTAssertEqual(calls, 2); XCTAssertTrue(cancelled); XCTAssertFalse(waiting); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(try owner.researchEvidence(for: owner.input).digest, archive.digest)
        XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    func testPageChangeDuringRecallRejectsTheOldActionWithoutDiscardingEarlierReadings() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), archive = try owner.researchEvidence(for: owner.input)
        var calls = 0
        fixture.actions.select = { input in
            if input.recalledReadingIndices.isEmpty { return #"{"reading":0}"# }
            return try self.json(["form":XCTUnwrap(input.formIDs.first), "preserve":[]])
        }
        fixture.actions.beforeReply = {
            calls += 1
            if calls == 2 {
                _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "changed-during-recall", to: fixture.base.appendingPathComponent("beta"))
            }
        }
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("A historical reading cannot restore an old current page") }
        catch { XCTAssertTrue(error is ComputerUseBrowserError) }
        XCTAssertEqual(calls, 2); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(try owner.researchEvidence(for: owner.input).digest, archive.digest)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .formFields }.count, 0)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
    }

    func testActionDeadlineReachesDriverAsAnInterventionOnTheOriginalTask() async throws {
        let actions = BrowserResearchActionFixture()
        actions.beforeReply = { throw ComputerUseBrowserActionPlanError.deadlineExceeded }
        let fixture = try await ResearchDriverFixture.make(actionPlanner: actions)
        defer { fixture.close() }
        let result = try await fixture.start()
        guard case .userInterventionRequired(let message)? = result else { return XCTFail("A deadline cannot complete research") }
        XCTAssertTrue(message.contains("ran out of time")); XCTAssertTrue(message.contains("original task"))
        let owner = try fixture.owner()
        XCTAssertEqual(owner.input.prompt, ResearchDriverFixture.prompt); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    private func actionInput(_ base: ComputerUseBrowserActionInput, archive: ComputerUseBrowserResearchEvidence?, recalled: [Int] = []) throws -> ComputerUseBrowserActionInput {
        try .init(interpretation: base.interpretation, evidence: base.evidence, navigationHistory: [], formHistory: [],
            latestForm: nil, changedFormTargetIDs: [], researchEvidence: archive, recalledReadings: recalled)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserActionPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
    }
}

private actor ActionRecallTransport: ComputerUseTextModelTransport {
    let counts: [Int]
    private(set) var calls: (counts: [URLRequest], completions: [URLRequest]) = ([], [])
    init(counts: [Int]) { self.counts = counts }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        let index = calls.counts.count; calls.counts.append(completionRequest)
        return counts[index]
    }
    func complete(request: URLRequest) async throws -> Data {
        let first = calls.completions.isEmpty; calls.completions.append(request)
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model",
            "choices":[["finish_reason":"stop", "message":["role":"assistant",
                "content":first ? #"{"reading":0}"# : #"{"unavailable":true}"#]]]])
    }
}
