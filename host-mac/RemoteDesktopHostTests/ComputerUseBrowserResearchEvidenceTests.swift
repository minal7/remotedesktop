import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchEvidenceTests: XCTestCase {
    func testDriverRetainsValidatedReadingsAcrossNavigationAndRecallsWithoutAnotherLoad() async throws {
        let planner = EvidenceSequencePlanner(steps: [.follow, .recall(0), .none])
        let fixture = try await ResearchDriverFixture.make(linkPlanner: planner, candidateBodyHTML: "<p>USD 40</p>")
        defer { fixture.close() }
        let result = try await fixture.start()
        guard case .browserResearchProgress = result else { return XCTFail("Readings are not a completed answer") }
        let owner = try fixture.owner(), evidence = try owner.researchEvidence(for: owner.input)
        XCTAssertEqual(evidence.count, 2); XCTAssertEqual(planner.inputs.count, 3)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 1)
        XCTAssertEqual(fixture.server.count("/offers"), 0)
        let context = try object(planner.inputs[2].contextJSON), recalled = try XCTUnwrap(context["recalled_readings"] as? [[String: Any]])
        XCTAssertEqual(recalled.count, 1); XCTAssertEqual(recalled[0]["reading"] as? Int, 0)
        XCTAssertEqual(recalled[0]["historical"] as? Bool, true)
        let observation = try XCTUnwrap(recalled[0]["observation"] as? [String: Any]), page = try XCTUnwrap(observation["page"] as? [String: Any])
        let records = try XCTUnwrap(page["records"] as? [[String: Any]])
        XCTAssertTrue(records.contains { $0["text"] as? String == "USD 40" })
        XCTAssertTrue(records.allSatisfy { ($0["id"] as? String)?.hasPrefix("r0/") == true })
        let retained = try await owner.revalidateCandidates()
        XCTAssertEqual(try owner.researchEvidence(for: owner.input).count, 2)
        try await fixture.browser.validateResultCandidates(retained, goal: owner.input)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink])
        XCTAssertFalse(String(reflecting: evidence).contains("USD"))
    }

    func testHistoricalReferencesAreNamespacedButObservedTextAndQualifiersStayIntact() async throws {
        let reader = BrowserResearchResultFixture(); reader.selectedLinkLabel = "Alpha details"
        let reviewed = ComputerUseReviewedBrowserResultPlanner(reader: reader, reviewer: EvidenceReviewFixture())
        let fixture = try await ResearchDriverFixture.make(resultPlanner: reviewed, additionalCardHTML: "<p>From t1 l1 g1</p>")
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), current = try await owner.revalidateCandidates(), evidence = try owner.researchEvidence(for: owner.input)
        let context = try evidence.recall(0, goal: owner.input), observation = try XCTUnwrap(context["observation"] as? [String: Any])
        let page = try XCTUnwrap(observation["page"] as? [String: Any]), records = try XCTUnwrap(page["records"] as? [[String: Any]])
        let from = try XCTUnwrap(records.first { $0["text"] as? String == "From t1 l1 g1" })
        let review = try XCTUnwrap(observation["field_review"] as? [[String: Any]]), fields = try XCTUnwrap(review[0]["fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["qualifiers"] as? [String], [try XCTUnwrap(from["id"] as? String)])
        let candidates = try XCTUnwrap(observation["candidates"] as? [[String: Any]])
        XCTAssertTrue(try XCTUnwrap(candidates[0]["container"] as? String).hasPrefix("r0/g"))
        let historicalLink = try XCTUnwrap((candidates[0]["links"] as? [String])?.first)
        let input = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence)
        XCTAssertThrowsError(try ComputerUseBrowserLinkProposal.decode(content: json(["candidate":0, "link":historicalLink]), input: input))
        let serialized = try json(context)
        for hidden in [fixture.base.absoluteString, owner.input.digest, current.candidates[0].id] { XCTAssertFalse(serialized.contains(hidden)) }
        XCTAssertTrue(serialized.contains("From t1 l1 g1"), "Source prose is not rewritten when IDs are namespaced")
    }

    func testClarificationKeepsHistoricalGoalMeaningAndRejectsForeignRootsOrSessions() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input, interpretation = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id], controllerID: "phone", controllerSessionID: "session")
        let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Montréal e\u{301} 😀. Do not buy.", controllerID: "phone", controllerSessionID: "session")
        _ = try await fixture.resume()
        let current = try await owner.revalidateCandidates(), evidence = try owner.researchEvidence(for: updated)
        XCTAssertEqual(evidence.count, 2); XCTAssertEqual(updated.rootDigest, original.rootDigest)
        XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
        let catalog = try evidence.catalog(goal: updated, current: current)
        XCTAssertEqual(catalog.map { $0["current_goal_revision"] as? Bool }, [false, true])
        let old = try evidence.recall(0, goal: updated)
        XCTAssertEqual(old["accepted_answer_count_at_reading"] as? Int, 0)
        XCTAssertEqual(old["current_goal_revision"] as? Bool, false)
        XCTAssertThrowsError(try evidence.validate(goal: original), "A later ledger cannot be rolled back to an earlier answer prefix")
        let otherRoot = try ComputerUseBrowserGoalInput(taskID: "foreign", prompt: original.prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: original.timeZoneIdentifier)
        XCTAssertThrowsError(try evidence.validate(goal: otherRoot))
        let foreign = try await ResearchDriverFixture.make()
        defer { foreign.close() }
        _ = try await foreign.start()
        let foreignOwner = try foreign.owner(), foreignReading = try await foreignOwner.revalidateCandidates()
        let initialArchive = try foreignOwner.researchEvidence(for: foreignOwner.input)
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: updated, candidates: current, history: owner.confirmedNavigationHistory, evidence: initialArchive))
        var custom = ComputerUseBrowserResearchEvidence(goal: original)
        try custom.record(foreignReading, goal: original)
        XCTAssertThrowsError(try custom.record(current, goal: updated)) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchEvidenceError, .inputChanged)
        }
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testRecallContractRejectsUnlistedHybridRepeatedAndStaleRequests() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), current = try await owner.revalidateCandidates(), evidence = try owner.researchEvidence(for: owner.input)
        let input = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence)
        XCTAssertEqual(input.recallableReadingIndices, [0])
        let proposal = try ComputerUseBrowserLinkProposal.decode(content: #"{"reading":0}"#, input: input)
        XCTAssertEqual(try proposal.requestedReading(for: input), 0)
        XCTAssertThrowsError(try proposal.choice(for: input), "Recall is not a no-selection link result")
        for content in [#"{"reading":1}"#, #"{"reading":-1}"#, #"{"reading":true}"#, #"{"reading":0.5}"#,
                        #"{"reading":0,"reading":0}"#, #"{"reading":0,"candidate":-1,"link":""}"#, #"{"reading":0,"complete":true}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserLinkProposal.decode(content: content, input: input))
        }
        let recalled = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence, recalledReadings: [0])
        XCTAssertThrowsError(try ComputerUseBrowserLinkProposal.decode(content: #"{"reading":0}"#, input: recalled))
        XCTAssertThrowsError(try proposal.requestedReading(for: recalled))
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence, recalledReadings: [0, 0]))
        _ = try await owner.readCandidates()
        let expanded = try owner.researchEvidence(for: owner.input)
        let changedArchive = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: expanded)
        XCTAssertThrowsError(try proposal.requestedReading(for: changedArchive), "The archive is bound even when the supplied current reading is unchanged")
    }

    func testRecallRunsWithoutCurrentLinksAndExactCountingKeepsEveryRecalledPage() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        fixture.results.selectedLinkLabel = nil
        let owner = try fixture.owner(), current = try await owner.readCandidates(), evidence = try owner.researchEvidence(for: owner.input)
        let input = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence)
        XCTAssertFalse(input.hasSelectableLinks); XCTAssertTrue(input.hasPlanningChoices)
        let transport = EvidenceTransport(responses: [#"{"reading":0}"#, #"{"candidate":-1,"link":""}"#])
        let adapter = ComputerUseModelBrowserResearchPlanning(sourcePlan: { try fixture.policy.sources(for: $0) }, linkPlanner: try local(transport))
        let choice = try await adapter.selectLink(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence)
        XCTAssertNil(choice)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4); XCTAssertEqual(requests[0].httpBody, requests[1].httpBody); XCTAssertEqual(requests[2].httpBody, requests[3].httpBody)
        let body = try object(String(decoding: XCTUnwrap(requests[2].httpBody), as: UTF8.self)), messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try object(XCTUnwrap(messages[1]["content"]))
        XCTAssertEqual((context["recalled_readings"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((context["goal"] as? [String: Any])?["request"] as? String, owner.input.prompt)
        let overBudget = EvidenceTransport(responses: [#"{"reading":0}"#], counts: [3_008, 3_009])
        let bounded = ComputerUseModelBrowserResearchPlanning(sourcePlan: { try fixture.policy.sources(for: $0) }, linkPlanner: try local(overBudget))
        do { _ = try await bounded.selectLink(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence); XCTFail("Cannot shorten recalled evidence to fit") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserLinkPlanError, .contextLimit) }
        let calls = await overBudget.calls
        XCTAssertEqual(calls.counts, 2); XCTAssertEqual(calls.completions, 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    func testPauseDuringRecallKeepsValidatedHistoryAndJoinsBeforeExplicitHandback() async throws {
        let gate = BrowserResearchGate(), planner = EvidenceSequencePlanner(steps: [.follow, .recall(0), .none])
        planner.beforeReply = { count in if count == 3 { await gate.suspend() } }
        let fixture = try await ResearchDriverFixture.make(linkPlanner: planner)
        defer { gate.release(); fixture.close() }
        let running = Task { try await fixture.start() }
        try await gate.waitUntilStarted()
        let owner = try fixture.owner(), original = owner.input, before = try owner.researchEvidence(for: original)
        XCTAssertEqual(before.count, 2)
        owner.pause(); XCTAssertTrue(owner.isOperating)
        XCTAssertThrowsError(try owner.researchEvidence(for: original))
        gate.release()
        do { _ = try await running.value; XCTFail("A recalled reply cannot pass Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating)
        planner.beforeReply = nil
        try await owner.resumeAfterUserControl()
        XCTAssertEqual(try owner.researchEvidence(for: original).digest, before.digest)
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(try owner.researchEvidence(for: original).count, 3)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 1)
        XCTAssertEqual(fixture.server.count("/offers"), 0)
        owner.retire()
        XCTAssertThrowsError(try owner.researchEvidence(for: original)) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .retired)
        }
    }

    func testCancelledOrRetiredReaderCannotAppendUnvalidatedLateEvidence() async throws {
        for retire in [false, true] {
            let gate = BrowserResearchGate(), fixture = try await ResearchDriverFixture.make()
            defer { gate.release(); fixture.close() }
            fixture.results.beforeReply = { await gate.suspend() }
            let running = Task { try await fixture.start() }
            try await gate.waitUntilStarted()
            let owner = try fixture.owner(), original = owner.input
            XCTAssertEqual(try owner.researchEvidence(for: original).count, 0)
            if retire { owner.retire() } else { owner.pause() }
            gate.release()
            do { _ = try await running.value; XCTFail("Late unvalidated reading cannot publish") }
            catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .retired) }
            fixture.results.beforeReply = nil
            if !retire {
                try await owner.resumeAfterUserControl()
                XCTAssertEqual(try owner.researchEvidence(for: original).count, 0)
                _ = try await fixture.resume()
                XCTAssertEqual(try owner.researchEvidence(for: original).count, 1)
            } else { XCTAssertThrowsError(try owner.researchEvidence(for: original)) }
        }
    }

    func testEvidenceCapacityPreservesExistingReadingsAndDeduplicatesOnlyTheSameObservation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), first = try await owner.revalidateCandidates()
        let second = try await owner.readCandidates(), third = try await owner.readCandidates()
        var archive = ComputerUseBrowserResearchEvidence(goal: owner.input, readingLimit: 2)
        try archive.record(first, goal: owner.input); try archive.record(second, goal: owner.input)
        let digest = archive.digest
        try archive.record(first, goal: owner.input)
        XCTAssertEqual(archive.count, 2); XCTAssertEqual(archive.digest, digest)
        XCTAssertThrowsError(try archive.requireCapacity()) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchEvidenceError, .limitReached)
        }
        XCTAssertThrowsError(try archive.record(third, goal: owner.input))
        XCTAssertEqual(archive.count, 2); XCTAssertEqual(archive.digest, digest)
        XCTAssertEqual(try archive.recall(0, goal: owner.input)["reading"] as? Int, 0)
        XCTAssertThrowsError(try archive.recall(2, goal: owner.input))
    }

    func testRecallLoopIsBoundedAndRetainsAllPreviouslyRequestedReadings() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        for _ in 0..<8 { _ = try await owner.readCandidates() }
        let current = try await owner.revalidateCandidates(), evidence = try owner.researchEvidence(for: owner.input)
        let planner = EvidenceSequencePlanner(steps: (0..<8).map { .recall($0) } + [.none])
        let adapter = ComputerUseModelBrowserResearchPlanning(sourcePlan: { try fixture.policy.sources(for: $0) }, linkPlanner: planner)
        let choice = try await adapter.selectLink(goal: owner.input, candidates: current, history: owner.confirmedNavigationHistory, evidence: evidence)
        XCTAssertNil(choice); XCTAssertEqual(planner.inputs.count, 9)
        for (count, input) in planner.inputs.enumerated() {
            let context = try object(input.contextJSON), rows = try XCTUnwrap(context["recalled_readings"] as? [[String: Any]])
            XCTAssertEqual(rows.map { $0["reading"] as? Int }, Array(0..<count).map { Optional($0) })
        }
        XCTAssertTrue(planner.inputs[8].recallableReadingIndices.isEmpty)
        XCTAssertEqual(try owner.researchEvidence(for: owner.input).count, 9)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserLinkPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
    }
}

@MainActor
private final class EvidenceSequencePlanner: ComputerUseBrowserLinkPlanning {
    enum Step { case follow, recall(Int), none }
    var steps: [Step]
    var inputs: [ComputerUseBrowserLinkSelectionInput] = []
    var beforeReply: (@MainActor (Int) async -> Void)?
    init(steps: [Step]) { self.steps = steps }
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        inputs.append(input)
        if let beforeReply { await beforeReply(inputs.count) }
        let step = steps.isEmpty ? .none : steps.removeFirst(), content: String
        switch step {
        case .none: content = #"{"candidate":-1,"link":""}"#
        case .recall(let index): content = "{\"reading\":\(index)}"
        case .follow:
            let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
            let candidates = try XCTUnwrap(context["candidates"] as? [[String: Any]]), link = try XCTUnwrap((candidates[0]["links"] as? [String])?.first)
            content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidate":0, "link":link]), as: UTF8.self)
        }
        return try .decode(content: content, input: input)
    }
}

private struct EvidenceReviewFixture: ComputerUseBrowserResultReviewPlanning {
    func propose(_ input: ComputerUseBrowserResultReviewInput) async throws -> ComputerUseBrowserResultReview {
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        let page = try XCTUnwrap(context["page"] as? [String: Any]), records = try XCTUnwrap(page["records"] as? [[String: Any]])
        let id = try XCTUnwrap(records.first { $0["text"] as? String == "From t1 l1 g1" }?["id"] as? String)
        let data = try JSONSerialization.data(withJSONObject: ["candidates":[["association":"singleOffer", "fields":[["scope":"offer", "price":"notPrice", "qualifiers":[id]]]]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

private actor EvidenceTransport: ComputerUseTextModelTransport {
    var responses: [String]
    var counts: [Int]
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(responses: [String], counts: [Int] = []) { self.responses = responses; self.counts = counts }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest); calls.counts += 1
        return counts.isEmpty ? 100 : counts.removeFirst()
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request); calls.completions += 1
        let content = responses.isEmpty ? #"{"candidate":-1,"link":""}"# : responses.removeFirst()
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
}
