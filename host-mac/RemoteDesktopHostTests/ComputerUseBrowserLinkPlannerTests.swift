import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserLinkPlannerTests: XCTestCase {
    func testLinkRequestKeepsTheWholeClarifiedGoalAndBoundPageWithoutNativeAuthority() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.goal.base.questionTopic = .location
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        let request = try XCTUnwrap(owner.proposedQuestionRequest())
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "private-phone", controllerSessionID: "private-session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "private-answer", answer: "Montréal e\u{301} 😀\nDo not buy.",
            controllerID: "private-phone", controllerSessionID: "private-session")
        fixture.goal.base.questionTopic = nil
        _ = try await fixture.resume()
        let (input, batch) = try await reading(fixture)
        let planner = try local(LinkFixtureTransport()), requestData = try planner.makeRequest(input)
        let body = try object(XCTUnwrap(requestData.httpBody)), messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try object(Data(XCTUnwrap(messages[1]["content"]).utf8))
        XCTAssertEqual(Set(context.keys), ["version", "goal", "page", "candidates", "navigation_history", "document_answer_source_status", "requirement_assessment", "field_review", "reading_catalog", "recallable_readings", "recalled_readings"])
        XCTAssertEqual(context["version"] as? Int, 5)
        XCTAssertTrue(context["field_review"] is NSNull)
        XCTAssertEqual(context["document_answer_source_status"] as? String, "permitted")
        let goal = try XCTUnwrap(context["goal"] as? [String: Any])
        XCTAssertEqual(goal["request"] as? String, original.prompt)
        XCTAssertEqual((goal["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, original.referenceMilliseconds)
        XCTAssertEqual(goal["timeZone"] as? String, original.timeZoneIdentifier)
        let answers = try XCTUnwrap(goal["clarifications"] as? [[String: Any]])
        XCTAssertEqual(answers.first?["answer"] as? String, owner.input.userTurns[1])
        let history = try XCTUnwrap(context["navigation_history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0]["kind"] as? String, "search")
        let candidates = try XCTUnwrap(context["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates[0]["links"] as? [String], batch.candidates[0].selectedLinkIDs)
        for hidden in [owner.taskID, owner.input.digest, batch.candidates[0].id, question.id, "private-phone", "private-session", "private-answer", fixture.base.absoluteString] {
            XCTAssertFalse(input.contextJSON.contains(hidden))
        }
        XCTAssertFalse(String(reflecting: input).contains("Concert Alpha"))
        XCTAssertEqual(requestData.url?.absoluteString, "http://127.0.0.1:54321/v1/chat/completions")
        XCTAssertEqual(requestData.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token-value")
        XCTAssertEqual(requestData.timeoutInterval, 30); XCTAssertEqual(body["temperature"] as? Int, 0)
        XCTAssertEqual(body["top_p"] as? Int, 1); XCTAssertEqual(body["top_k"] as? Int, 0)
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["cache_prompt"] as? Bool, false)
        XCTAssertNil(body["tools"]); XCTAssertEqual(messages[0]["content"], ComputerUseLocalBrowserLinkPlanner.instructions)
        let format = try XCTUnwrap(body["response_format"] as? [String: Any]), schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "browser_result_link_v2")
    }

    func testLinkProposalAcceptsOnlyTheExactCandidateLinkPairOrNoSelection() async throws {
        let fixture = try await multiFixture()
        defer { fixture.close() }
        _ = try await fixture.start()
        let (input, batch) = try await reading(fixture)
        XCTAssertEqual(batch.candidates.count, 2)
        for index in 0..<2 {
            let link = try XCTUnwrap(batch.candidates[index].selectedLinkIDs.first)
            let proposal = try ComputerUseBrowserLinkProposal.decode(content: content(index, link), input: input)
            let choice = try XCTUnwrap(proposal.choice(for: input))
            XCTAssertEqual(choice.candidateID, batch.candidates[index].id); XCTAssertEqual(choice.linkID, link)
            XCTAssertFalse(String(reflecting: proposal).contains(choice.candidateID))
        }
        let first = try XCTUnwrap(batch.candidates[0].selectedLinkIDs.first), second = try XCTUnwrap(batch.candidates[1].selectedLinkIDs.first)
        let valid = try content(0, first)
        let invalid = [try content(0, second), try content(1, first), try content(2, first), try content(-2, ""),
            try content(-1, first), try content(0, ""), try content(0, "invented"),
            #"{"candidate":true,"link":""}"#, #"{"candidate":0.5,"link":""}"#,
            #"{"candidate":-1,"link":null}"#, #"{"candidate":-1,"link":"","complete":true}"#,
            #"{"candidate":-1,"link":"","candidate":-1}"#, #"{"candidate":-1,"link":"","link":""}"#,
            valid + valid, valid + String(repeating: " ", count: 1_024)]
        for response in invalid {
            XCTAssertThrowsError(try ComputerUseBrowserLinkProposal.decode(content: response, input: input)) {
                XCTAssertEqual($0 as? ComputerUseBrowserLinkPlanError, .invalidProposal)
            }
        }
        let none = try ComputerUseBrowserLinkProposal.decode(content: content(-1, ""), input: input)
        XCTAssertNil(try none.choice(for: input))
        let context = try object(Data(input.contextJSON.utf8)), page = try XCTUnwrap(context["page"] as? [String: Any])
        let records = try XCTUnwrap(page["records"] as? [[String: Any]])
        XCTAssertTrue(records.contains { $0["text"] as? String == "USD 35 excluding fees" })
        let groups = try XCTUnwrap(context["candidates"] as? [[String: Any]])
        XCTAssertFalse(try XCTUnwrap(groups[1]["unclassified_texts"] as? [String]).isEmpty)
    }

    func testLinkInputAndProposalRejectChangedGoalPageHistoryAndForeignBindings() async throws {
        let fixture = try await ResearchDriverFixture.make(), other = try await ResearchDriverFixture.make()
        defer { fixture.close(); other.close() }
        _ = try await fixture.start(); _ = try await other.start()
        let owner = try fixture.owner(), (input, batch) = try await reading(fixture)
        let proposal = try ComputerUseBrowserLinkProposal.decode(content: content(0, XCTUnwrap(batch.candidates[0].selectedLinkIDs.first)), input: input)
        let changedGoal = try ComputerUseBrowserGoalInput(taskID: owner.taskID, prompt: "Find movies.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: changedGoal, candidates: batch, history: owner.confirmedNavigationHistory))
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: batch,
            history: owner.confirmedNavigationHistory + owner.confirmedNavigationHistory))
        let withoutHistory = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: batch, history: [])
        XCTAssertThrowsError(try proposal.choice(for: withoutHistory))
        let (fresh, _) = try await reading(fixture), (foreign, _) = try await reading(other)
        for changed in [fresh, foreign] {
            XCTAssertNotEqual(changed, input)
            XCTAssertThrowsError(try proposal.choice(for: changed)) { XCTAssertEqual($0 as? ComputerUseBrowserLinkPlanError, .inputChanged) }
        }
        _ = try await other.driver.executeBrowserResearch(taskID: "other-root", prompt: "Find concerts tomorrow.",
            tools: other.tools, progress: { _ in })
        let foreignOwner = try XCTUnwrap(other.tools.ownedBrowserResearch(taskID: "other-root"))
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: batch,
            history: foreignOwner.confirmedNavigationHistory))
        XCTAssertEqual(fixture.server.count("/details"), 0); XCTAssertEqual(other.server.count("/details"), 0)
    }

    func testLinkTransportCountsTheExactRequestAndRejectsOverflowOrCancellation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let (input, _) = try await reading(fixture)
        for mode in ["negative", "zero", "overflow", "at-limit", "cancel-count", "cancel-completion"] {
            let count = mode == "negative" ? -1 : (mode == "zero" ? 0 : (mode == "overflow" ? 3_009 : 3_008))
            let transport = LinkFixtureTransport(count: count, cancelCount: mode == "cancel-count", cancelCompletion: mode == "cancel-completion")
            let planner = try local(transport), running = Task { try await planner.propose(input) }
            do { let proposal = try await running.value; XCTAssertEqual(mode, "at-limit"); XCTAssertNil(try proposal.choice(for: input)) }
            catch {
                if mode.hasPrefix("cancel") { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserLinkPlanError, .contextLimit) }
            }
            let calls = await transport.calls, requests = await transport.requests
            XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, ["at-limit", "cancel-completion"].contains(mode) ? 1 : 0)
            XCTAssertTrue(requests.allSatisfy { $0.httpBody == requests[0].httpBody })
        }
    }

    func testLinkResponseRejectsForeignOrUnfinishedEnvelopesAndEmptyChoicesNeedNoInference() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let (input, _) = try await reading(fixture), planner = try local(LinkFixtureTransport())
        let valid = String(decoding: try LinkFixtureTransport.envelope(content(-1, "")), as: UTF8.self)
        let invalid = [Data(), Data([0xff]), Data(valid.replacingOccurrences(of: "fixture-model", with: "foreign-model").utf8),
            Data(valid.replacingOccurrences(of: "\"stop\"", with: "\"length\"").utf8),
            Data(valid.replacingOccurrences(of: "\"assistant\"", with: "\"user\"").utf8),
            Data(valid.replacingOccurrences(of: "\"assistant\"", with: "\"assistant\",\"tool_calls\":[{}]").utf8),
            Data(valid.replacingOccurrences(of: "\"assistant\"", with: "\"assistant\",\"refusal\":\"No\"").utf8),
            Data(valid.replacingOccurrences(of: "\"stop\"", with: "\"stop\",\"finish_reason\":\"stop\"").utf8)]
        for response in invalid { XCTAssertThrowsError(try planner.decode(response, input: input)) }
        fixture.results.selectedLinkLabel = nil
        let (empty, _) = try await reading(fixture), transport = LinkFixtureTransport()
        XCTAssertFalse(empty.hasSelectableLinks)
        let result = try await local(transport).propose(empty)
        XCTAssertNil(try result.choice(for: empty))
        let calls = await transport.calls
        XCTAssertEqual(calls.counts, 0); XCTAssertEqual(calls.completions, 0)
    }

    func testModelLinkAdapterDrivesTheSelectedResultThroughCapabilityRouting() async throws {
        let transport = LinkFixtureTransport(selectedIndices: [1, -1]), local = try local(transport)
        let fixture = try await multiFixture(linkPlanner: local)
        defer { fixture.close() }
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil }, browserResearch: fixture.driver)
        let result = try await executor.execute(taskID: ResearchDriverFixture.root, modelPrompt: "Unrelated assistant history",
            currentUserPrompt: ResearchDriverFixture.prompt, conversation: [], tools: fixture.tools, progress: { _ in })
        guard case .browserResearchProgress = result else { return XCTFail("A selected page is not a verified research answer") }
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/beta"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertTrue(fixture.policy.goals.isEmpty, "The model adapter, not the earlier fixed-choice policy, supplies this proposal")
        let calls = await transport.calls
        XCTAssertEqual(calls.counts, 2); XCTAssertEqual(calls.completions, 2)
        XCTAssertEqual(try fixture.owner().confirmedNavigationHistory.map(\.kind), [.search, .resultLink])
    }

    func testModelLinkAdapterRejectsStaleRepliesAndJoinsSelectionCancellation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let (old, _) = try await reading(fixture), (_, fresh) = try await reading(fixture), reply = LinkReplyFixture()
        reply.replacement = try .decode(content: content(-1, ""), input: old)
        let bridge = ComputerUseModelBrowserResearchPlanning(sourcePlan: { try fixture.policy.sources(for: $0) }, linkPlanner: reply)
        do { _ = try await bridge.selectLink(goal: fixture.owner().input, candidates: fresh, history: fixture.owner().confirmedNavigationHistory); XCTFail("A no-selection answer is also bound to its original input") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserLinkPlanError, .inputChanged) }

        let suspendedReply = LinkReplyFixture(), gate = BrowserResearchGate()
        let controlled = try await ResearchDriverFixture.make(linkPlanner: suspendedReply)
        defer { gate.release(); controlled.close() }
        suspendedReply.beforeReply = { await gate.suspend() }
        let running = Task { try await controlled.start() }
        try await gate.waitUntilStarted()
        let owner = try controlled.owner()
        owner.pause(); XCTAssertTrue(owner.isOperating)
        gate.release()
        do { _ = try await running.value; XCTFail("A late local reply cannot pass Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(controlled.server.count("/details"), 0)
        suspendedReply.beforeReply = nil
        try await owner.resumeAfterUserControl()
        _ = try await controlled.resume()
        XCTAssertEqual(controlled.server.count("/search?q=concerts"), 1)
    }

    func testExpiredLinkDecisionStartsNoReadingOrSelectionAndKeepsEarlierEvidence() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input, archive = try owner.researchEvidence(for: owner.input)
        let commands = fixture.state.commands.count, reads = fixture.results.inputs.count
        for budget in [Duration.zero, .seconds(-1)] {
            do {
                _ = try await owner.planCandidateNavigation(budget: budget) { _, _ in
                    XCTFail("An expired decision cannot call a selector"); return nil
                }
                XCTFail("Expired selection cannot publish")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserLinkPlanError, .deadlineExceeded) }
        }
        XCTAssertEqual(fixture.results.inputs.count, reads); XCTAssertEqual(fixture.state.commands.count, commands)
        XCTAssertEqual(try owner.researchEvidence(for: original).digest, archive.digest)
        XCTAssertEqual(owner.input, original); XCTAssertFalse(owner.isOperating)
    }

    func testOneLinkDeadlineCancelsLaterRecallTokenCountingOrCompletionWithoutPublishing() async throws {
        for phase in ["count", "complete"] {
            let fixture = try await ResearchDriverFixture.make()
            defer { fixture.close() }
            _ = try await fixture.start()
            let owner = try fixture.owner(), original = owner.input, before = try owner.researchEvidence(for: owner.input)
            let transport = LinkDeadlineTransport(phase: phase)
            let planning = ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: try local(transport))
            do {
                _ = try await owner.planCandidateNavigation(budget: .seconds(1)) { goal, candidates in
                    try await planning.selectLink(goal: goal, candidates: candidates, history: owner.confirmedNavigationHistory,
                        evidence: owner.researchEvidence(for: goal))
                }
                XCTFail("Recall cannot restart the decision deadline")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserLinkPlanError, .deadlineExceeded) }
            let calls = await transport.calls, cancelled = await transport.cancelled, waiting = await transport.waiting
            XCTAssertEqual(calls.counts.count, 2); XCTAssertEqual(calls.completions.count, phase == "count" ? 1 : 2)
            XCTAssertTrue(cancelled); XCTAssertFalse(waiting); XCTAssertFalse(owner.isOperating)
            XCTAssertEqual(try owner.researchEvidence(for: original).count, before.count + 1, "The validated reading remains historical evidence")
            do { _ = try await owner.revalidateCandidates(); XCTFail("No timed-out selection can publish its current candidate cache") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .interpretationRequired) }
            let secondBody = try object(XCTUnwrap(calls.counts[1].httpBody))
            let messages = try XCTUnwrap(secondBody["messages"] as? [[String: String]])
            let context = try object(Data(XCTUnwrap(messages.last?["content"]).utf8))
            XCTAssertEqual((context["recalled_readings"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((context["goal"] as? [String: Any])?["request"] as? String, original.prompt)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
            let none = try await owner.planCandidateNavigation { _, _ in nil }
            XCTAssertNil(none); XCTAssertEqual(owner.input, original)
        }
    }

    func testTimedOutLinkSelectorKeepsOwnerBusyUntilCancellationCleanupJoins() async throws {
        let fixture = try await ResearchDriverFixture.make(), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        var cancelled = false, finished = false
        let work = Task {
            defer { finished = true }
            return try await owner.planCandidateNavigation(budget: .milliseconds(50)) { _, batch in
                do { try await Task.sleep(for: .seconds(60)) }
                catch {
                    cancelled = error is CancellationError
                    await gate.suspend() // Deliberately uncooperative cleanup.
                }
                let candidate = try XCTUnwrap(batch.candidates.first)
                return .init(candidateID: candidate.id, linkID: try XCTUnwrap(candidate.selectedLinkIDs.first))
            }
        }
        try await gate.waitUntilStarted()
        XCTAssertTrue(cancelled); XCTAssertTrue(owner.isOperating); XCTAssertFalse(finished)
        do { _ = try await owner.readCandidates(); XCTFail("A cancelled selector still owns the operation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        gate.release()
        do { _ = try await work.value; XCTFail("Late valid-looking choices cannot escape the deadline") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserLinkPlanError, .deadlineExceeded) }
        XCTAssertFalse(owner.isOperating); XCTAssertTrue(finished); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    func testLinkDecisionRevalidatesThePageEvenWhenTheSelectorReturnsNoChoice() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        do {
            _ = try await owner.planCandidateNavigation { _, _ in
                _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "changed-during-selection", to: fixture.base.appendingPathComponent("beta"))
                return nil
            }
            XCTFail("No selection cannot validate a superseded page")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    func testPauseDuringFinalLinkValidationJoinsNativeWorkAndRequiresExplicitHandback() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        var validationStarted = false
        do {
            _ = try await owner.planCandidateNavigation { _, candidates in
                fixture.state.onCommand = { command in
                    if command == .validatePageSnapshot {
                        fixture.state.onCommand = nil; validationStarted = true; owner.pause()
                    }
                }
                let candidate = try XCTUnwrap(candidates.candidates.first)
                return .init(candidateID: candidate.id, linkID: try XCTUnwrap(candidate.selectedLinkIDs.first))
            }
            XCTFail("A choice cannot publish through Pause during native validation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(validationStarted); XCTAssertFalse(owner.isOperating); XCTAssertTrue(owner.isPaused)
        XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.server.count("/details"), 0)
        try await owner.resumeAfterUserControl()
        let none = try await owner.planCandidateNavigation { _, _ in nil }
        XCTAssertNil(none); XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testLinkDeadlineReachesDriverAsAResumableOriginalTask() async throws {
        let fixture = try await ResearchDriverFixture.make(linkPlanner: LinkDeadlineReply())
        defer { fixture.close() }
        let result = try await fixture.start()
        guard case .userInterventionRequired(let message)? = result else { return XCTFail("A timeout cannot complete research") }
        XCTAssertTrue(message.contains("ran out of time")); XCTAssertTrue(message.contains("original task"))
        let owner = try fixture.owner()
        XCTAssertEqual(owner.input.prompt, ResearchDriverFixture.prompt); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(try owner.researchEvidence(for: owner.input).count, 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    private func reading(_ fixture: ResearchDriverFixture) async throws -> (ComputerUseBrowserLinkSelectionInput, ComputerUseBrowserResultCandidates) {
        let owner = try fixture.owner(), batch = try await owner.readCandidates()
        return (try .init(goal: owner.input, candidates: batch, history: owner.confirmedNavigationHistory), batch)
    }
    private func multiFixture(linkPlanner: (any ComputerUseBrowserLinkPlanning)? = nil) async throws -> ResearchDriverFixture {
        try await .make(linkPlanner: linkPlanner, resultPlanner: LinkCardsFixture(), additionalCardHTML:
            "<article><h2>Concert Beta</h2><p>USD 35 excluding fees</p><a href='/beta'>Beta details</a></article>")
    }
    private func content(_ candidate: Int, _ link: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["candidate":candidate, "link":link]), as: UTF8.self)
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserLinkPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: transport)
    }
}

private struct LinkDeadlineReply: ComputerUseBrowserLinkPlanning {
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        throw ComputerUseBrowserLinkPlanError.deadlineExceeded
    }
}

private actor LinkDeadlineTransport: ComputerUseTextModelTransport {
    let phase: String
    private(set) var calls: (counts: [URLRequest], completions: [URLRequest]) = ([], [])
    private(set) var cancelled = false
    private(set) var waiting = false
    init(phase: String) { self.phase = phase }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts.append(completionRequest)
        if phase == "count", calls.counts.count == 2 { try await stall() }
        return 100
    }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions.append(request)
        if phase == "complete", calls.completions.count == 2 { try await stall() }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages.last?["content"]).utf8)) as? [String: Any])
        let available = try XCTUnwrap(context["recallable_readings"] as? [Int])
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["reading":try XCTUnwrap(available.first)]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
    private func stall() async throws {
        waiting = true
        defer { waiting = false }
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = error is CancellationError; throw error }
    }
}

private actor LinkFixtureTransport: ComputerUseTextModelTransport {
    let count: Int
    let cancelCount: Bool
    let cancelCompletion: Bool
    var selectedIndices: [Int]
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(count: Int = 100, cancelCount: Bool = false, cancelCompletion: Bool = false, selectedIndices: [Int] = []) {
        self.count = count; self.cancelCount = cancelCount; self.cancelCompletion = cancelCompletion; self.selectedIndices = selectedIndices
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts += 1; requests.append(completionRequest)
        if cancelCount { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions += 1; requests.append(request)
        if cancelCompletion { withUnsafeCurrentTask { $0?.cancel() } }
        let index = selectedIndices.isEmpty ? -1 : selectedIndices.removeFirst()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        let candidates = try XCTUnwrap(context["candidates"] as? [[String: Any]])
        let link: String
        if index == -1 { link = "" }
        else { link = try XCTUnwrap((candidates[index]["links"] as? [String])?.first) }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidate":index, "link":link]), as: UTF8.self)
        return try Self.envelope(content)
    }
    static func envelope(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop",
            "message":["role":"assistant", "content":content]]]], options: [.sortedKeys])
    }
}

@MainActor
private final class LinkReplyFixture: ComputerUseBrowserLinkPlanning {
    var replacement: ComputerUseBrowserLinkProposal?
    var beforeReply: (@MainActor () async -> Void)?
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        if let beforeReply { await beforeReply() }
        return try replacement ?? .decode(content: #"{"candidate":-1,"link":""}"#, input: input)
    }
}

private struct LinkCardsFixture: ComputerUseBrowserResultPlanning {
    func propose(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput) async throws -> ComputerUseBrowserResultProposal {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.contextJSON.utf8)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let candidates: [[String: Any]] = try ["Alpha", "Beta"].map { name in
            let title = try XCTUnwrap(records.first { $0["text"] as? String == "Concert \(name)" })
            var group = try XCTUnwrap(title["group"] as? String)
            while let container = records.first(where: { $0["kind"] as? String == "container" && $0["id"] as? String == group }),
                  container["element"] as? String != "article" { group = try XCTUnwrap(container["parent"] as? String) }
            let link = try XCTUnwrap(records.first { $0["label"] as? String == "\(name) details" })
            return ["container":group, "fields":[["kind":"title", "texts":[try XCTUnwrap(title["id"] as? String)]]],
                "links":[try XCTUnwrap(link["id"] as? String)]]
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates":candidates]), as: UTF8.self)
        return try .decode(content: content, input: page, goal: goal)
    }
}
