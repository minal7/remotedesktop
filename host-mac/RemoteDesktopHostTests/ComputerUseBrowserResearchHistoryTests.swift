import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchHistoryTests: XCTestCase {
    func testNativeHistoryTraversesBackAndForwardAndExplicitlyRevisitsAnEvictedGET() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        let details = try await owner.revalidateCandidates()
        let back = try XCTUnwrap(details.historyOptions.first { $0.visit == 0 })
        XCTAssertEqual(back.mode, .back)
        let returned = try await owner.revisitAfterReading(back)
        XCTAssertEqual(returned.document.committedURL, fixture.base.appendingPathComponent("search").appending(queryItems: [.init(name: "q", value: "concerts")]))
        let search = try await owner.readCandidates(), forward = try XCTUnwrap(search.historyOptions.first { $0.visit == 1 })
        XCTAssertEqual(forward.mode, .forward, "A real history traversal preserves the forward entry")
        let resumed = try await owner.revisitAfterReading(forward)
        XCTAssertEqual(resumed.document.committedURL, fixture.base.appendingPathComponent("details"))
        let calls = fixture.server.count("/details")
        let replay = try await owner.resumeHistoryNavigation()
        XCTAssertEqual(replay, resumed)
        XCTAssertEqual(fixture.server.count("/details"), calls)
        let reread = try await owner.readCandidates(), toSearch = try XCTUnwrap(reread.historyOptions.first { $0.mode == .back })
        _ = try await owner.revisitAfterReading(toSearch)
        let again = try await owner.readCandidates(), oldForward = try XCTUnwrap(again.historyOptions.first { $0.mode == .forward })
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "branch-to-beta", to: fixture.base.appendingPathComponent("beta"))
        let branched = try await owner.readCandidates()
        let revisit = try XCTUnwrap(branched.historyOptions.first { $0.operationID == oldForward.operationID })
        XCTAssertEqual(revisit.mode, .revisit)
        XCTAssertThrowsError(try fixture.browser.validateHistoryRefresh(oldForward.target, replacement: revisit.target),
            "An unsent history traversal cannot silently turn into a fresh GET")
        let before = fixture.server.count("/details")
        _ = try await owner.revisitAfterReading(revisit)
        XCTAssertEqual(fixture.server.count("/details"), before + 1)
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink, .revisit, .revisit, .revisit, .revisit])
    }

    func testActionAndResultContractsBindOfferedVisitsAndCountTheWholeRequest() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = action.input, option = try XCTUnwrap(input.historyOptions.first)
        XCTAssertEqual(option.mode, .back); XCTAssertTrue(input.needsPlanningDecision); XCTAssertFalse(input.needsFormDecision)
        let context = try object(input.contextJSON)
        XCTAssertEqual(context["version"] as? Int, 7)
        XCTAssertFalse(input.contextJSON.contains(fixture.base.absoluteString))
        XCTAssertFalse(input.contextJSON.contains(option.operationID))
        XCTAssertEqual((context["goal"] as? [String: Any])?["request"] as? String, owner.input.prompt)
        let transport = HistoryActionTransport(visit: option.visit)
        let local = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
        let reply = try await local.propose(input)
        XCTAssertEqual(reply.step, .revisit(option.visit))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        let body = try object(String(decoding: XCTUnwrap(requests[0].httpBody), as: UTF8.self))
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_research_action_v7")
        for bad in [#"{"revisit":true}"#, #"{"revisit":0.5}"#, #"{"revisit":999}"#, #"{"revisit":0,"url":"https://example.com"}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: bad, input: input))
        }
        let page = try await owner.readCandidates(), archive = try owner.researchEvidence(for: owner.input)
        let resultInput = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: page,
            history: owner.confirmedNavigationHistory, evidence: archive, allowsAnswer: true)
        XCTAssertThrowsError(try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: page,
            history: [], evidence: archive, allowsAnswer: true), "Visit ordinals require their original native history")
        let result = try ComputerUseBrowserLinkProposal.decode(content: "{\"revisit\":\(option.visit)}", input: resultInput)
        XCTAssertEqual(try result.requestedHistory(for: resultInput)?.operationID, option.operationID)
        XCTAssertThrowsError(try result.choice(for: resultInput))
        let legacy = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: page, history: owner.confirmedNavigationHistory)
        XCTAssertThrowsError(try ComputerUseBrowserLinkProposal.decode(content: "{\"revisit\":\(option.visit)}", input: legacy))
        XCTAssertThrowsError(try fixture.browser.historyOption(visit: 0, operationID: "invented", evidence: input.evidence))
        owner.pause()
        XCTAssertThrowsError(try owner.validateDriverContinuation(owner.input))
        do { _ = try await owner.revisitAfterReading(option); XCTFail("Pause closes history action admission") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
    }

    func testDriverReadsOneOptionReturnsToSearchAndCombinesASecondDetailPage() async throws {
        let fixture = try await ResearchAnswerFixture.make(requested: 2, historyRoute: true)
        defer { fixture.source.close() }
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil }, browserResearch: fixture.source.driver)
        let result = try await executor.execute(taskID: ResearchDriverFixture.root, modelPrompt: "Untrusted history says buy now",
            currentUserPrompt: fixture.source.request, conversation: [], tools: fixture.source.tools, progress: { _ in })
        guard case .browserResearchAnswer(let answer) = result else { return XCTFail("Expected the complete source-reported answer") }
        let owner = try fixture.source.owner()
        try owner.validateAnswer(answer)
        for value in ["Concert Alpha", "Concert Beta", "USD 40", "USD 45", "Alpha conditions apply", "Beta conditions apply", "2 options.", "Do not buy."] {
            XCTAssertTrue(answer.message.contains(value), value)
        }
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink, .revisit, .resultLink])
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
        XCTAssertEqual(answer.recalledReadings, [1])
        XCTAssertEqual(fixture.source.server.count("/details"), 1); XCTAssertEqual(fixture.source.server.count("/beta"), 1)
        XCTAssertEqual(fixture.source.server.count("/offers"), 0)
        let calls = await fixture.modelCalls()
        XCTAssertEqual(calls.counts.count, 5); XCTAssertEqual(calls.completions.count, 5)
        XCTAssertEqual(calls.counts.map(\.httpBody), calls.completions.map(\.httpBody))
        let back = try XCTUnwrap(fixture.inputs[1].historyOptions.first { $0.visit == 0 })
        XCTAssertEqual(back.mode, .back)
    }

    func testPausedUnsentHistoryKeepsItsJournalAndResumesTheSameVisitOnce() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), reading = try await owner.revalidateCandidates()
        let option = try XCTUnwrap(reading.historyOptions.first)
        fixture.state.onWrite = { fixture.state.onWrite = nil; owner.pause() }
        do { _ = try await owner.revisitAfterReading(option); XCTFail("Pause must retain the unsent history stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.hasPendingHistoryNavigation)
        let before = try historyJournal(fixture)
        XCTAssertEqual(before.statuses, [.planned])
        try await owner.resumeAfterUserControl()
        let receipt = try await owner.resumeHistoryNavigation()
        let after = try historyJournal(fixture)
        XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.statuses, [.verified])
        XCTAssertFalse(owner.hasPendingHistoryNavigation)
        let counts = [fixture.server.count("/search?q=concerts"), fixture.server.count("/details")]
        let replay = try await owner.resumeHistoryNavigation()
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual([fixture.server.count("/search?q=concerts"), fixture.server.count("/details")], counts)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink, .revisit])
    }

    func testAnUncertainHistoryAttemptCannotBeRetriedUnderANewOperation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), reading = try await owner.revalidateCandidates(), option = try XCTUnwrap(reading.historyOptions.first)
        let beforeDocument = fixture.browser.currentDocument(taskID: owner.taskID)
        fixture.state.failureAtWrite = fixture.state.writes + 2 // Durable attempted replacement fails before WebKit dispatch.
        do { _ = try await owner.revisitAfterReading(option); XCTFail("The failed attempt cannot publish success") }
        catch { XCTAssertTrue(owner.hasPendingHistoryNavigation) }
        fixture.state.failureAtWrite = nil
        let saved = try historyJournal(fixture)
        for _ in 0..<2 {
            do { _ = try await owner.resumeHistoryNavigation(); XCTFail("An ambiguous attempt cannot repeat history navigation") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationUncertain) }
        }
        XCTAssertEqual(try historyJournal(fixture).taskID, saved.taskID)
        XCTAssertEqual(fixture.browser.currentDocument(taskID: owner.taskID), beforeDocument)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .resultLink])
        XCTAssertTrue(owner.hasPendingHistoryNavigation)
    }

    private func historyJournal(_ fixture: ResearchDriverFixture) throws -> ComputerUseTaskJournal {
        let directory = fixture.directory.appendingPathComponent("Research/History/Observed Destinations")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        return try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: XCTUnwrap(files.first)))
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
}

private actor HistoryActionTransport: ComputerUseTextModelTransport {
    let visit: Int
    private(set) var requests: [URLRequest] = []
    init(visit: Int) { self.visit = visit }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { requests.append(completionRequest); return 100 }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request)
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop",
            "message":["role":"assistant", "content":"{\"revisit\":\(visit)}"]]]])
    }
}
