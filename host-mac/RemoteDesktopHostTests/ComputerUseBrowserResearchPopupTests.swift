import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchPopupTests: XCTestCase {
    func testPlannerOffersOnlyCurrentNativePopupCandidatesAndBindsExactRequirement() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page(unsupported: true))
        defer { fixture.close() }
        configureGoal(fixture)
        fixture.policy.choices = [false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = action.input, id = try XCTUnwrap(input.popupControlIDs.first)
        XCTAssertEqual(input.popupControlIDs.count, 1); XCTAssertTrue(input.needsPlanningDecision)
        XCTAssertEqual(try object(input.contextJSON)["version"] as? Int, 13)
        XCTAssertFalse(input.contextJSON.contains(fixture.base.absoluteString))
        XCTAssertFalse(input.contextJSON.contains("General admission"), "Candidate discovery reads no option values")
        let proposal = try ComputerUseBrowserActionProposal.decode(content: opening(id), input: input)
        XCTAssertEqual(proposal.step, .openPopup(id, 0)); XCTAssertTrue(proposal.readControls.isEmpty)
        let forbidden = try XCTUnwrap(input.interpretation.requirements.firstIndex { $0.role == .prohibition })
        for content in [opening("c999"), opening(id, requirement: forbidden),
            "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":true}}",
            "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":0.5}}",
            "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":0,\"value\":\"buy\"}}",
            "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":0},\"read_results\":true}"] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: content, input: input))
        }
        let local = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let body = try ResearchAnswerFixture.object(XCTUnwrap(local.makeRequest(input).httpBody))
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_research_action_v13")
        XCTAssertEqual(fixture.server.count("/opened"), 0)
        let unoffered = try ComputerUseBrowserActionInput(interpretation: input.interpretation, evidence: input.evidence,
            navigationHistory: owner.confirmedNavigationHistory, formHistory: [], latestForm: nil, changedFormTargetIDs: [])
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: opening(id), input: unoffered))
    }

    func testDriverOpensOnceThenReadsFreshOptionsUnderTheCompleteOriginalGoal() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page())
        defer { fixture.close() }
        configure(fixture)
        let result = try await fixture.start(), owner = try fixture.owner()
        guard case .browserResearchProgress(let report)? = result else { return XCTFail("Only a partial report is supported by these page facts") }
        XCTAssertEqual(report.goalRevision, owner.input.digest)
        try await wait { fixture.server.count("/opened") == 1 }
        XCTAssertFalse(owner.hasPendingPopup); XCTAssertEqual(owner.popupHistory.map(\.outcome), [.opened])
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search])
        XCTAssertEqual(owner.input.prompt, fixture.request)
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { $0.interpretation.input == owner.input })
        let before = try XCTUnwrap(fixture.actions.inputs.first), after = try XCTUnwrap(fixture.actions.inputs.last)
        XCTAssertNotEqual(before.evidence.page.id, after.evidence.page.id); XCTAssertTrue(after.popupControlIDs.isEmpty)
        XCTAssertEqual(after.popupHistory, owner.popupHistory)
        let context = try object(after.contextJSON), history = try XCTUnwrap(context["popup_history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0]["outcome"] as? String, "opened")
        XCTAssertFalse(after.contextJSON.contains(owner.popupHistory[0].operationID))
        XCTAssertTrue(fixture.state.commands.contains(.observeResearchControls))
        XCTAssertFalse(fixture.state.commands.contains(.edit)); XCTAssertFalse(fixture.state.commands.contains(.prepareFormQuery))
        XCTAssertEqual(try journals(fixture).map(\.statuses), [[.verified]])
    }

    func testPauseBeforeDispatchBlocksNewWorkAndHandbackRetiresOnlyTheUnsentBinding() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page())
        defer { fixture.close() }
        configure(fixture); pauseBeforeDispatch(fixture)
        do { _ = try await fixture.start(); XCTFail("Pause must retain the journaled pending stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertTrue(owner.hasPendingPopup); XCTAssertTrue(owner.popupHistory.isEmpty)
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(fixture.server.count("/opened"), 0)
        let pending = try XCTUnwrap(journals(fixture).first)
        XCTAssertEqual(pending.statuses, [.attempted])
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.interpretGoal(); XCTFail("Pending popup blocks interpretation and goal replacement") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .popupPending) }
        do { _ = try await owner.readCandidates(); XCTFail("Pending popup blocks new page evidence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .popupPending) }
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Pending popup blocks a fresh action") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .popupPending) }
        XCTAssertThrowsError(try owner.issueQuestion(topic: .source, requirementIDs: [], controllerID: "phone", controllerSessionID: "session")) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .popupPending)
        }
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/opened") == 1 }
        XCTAssertEqual(owner.input, original); XCTAssertFalse(owner.hasPendingPopup)
        XCTAssertEqual(owner.popupHistory.map(\.outcome), [.retiredUnsent, .opened])
        let tombstone = try XCTUnwrap(journals(fixture).first { $0.taskID == pending.taskID })
        XCTAssertEqual(tombstone.statuses, pending.statuses); XCTAssertNotNil(tombstone.retirementDigest)
        XCTAssertEqual(tombstone.contractDigest, pending.contractDigest)
    }

    func testPauseDuringNativeDispatchRetainsHistoricalOpeningWithoutASecondClick() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page())
        defer { fixture.close() }
        configure(fixture)
        fixture.state.onCommand = { command in
            guard command == .openPopup, let owner = fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root) else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await fixture.start(); XCTFail("The cancelled caller cannot publish task progress") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), pending = try XCTUnwrap(journals(fixture).first)
        XCTAssertTrue(owner.hasPendingPopup); XCTAssertFalse(owner.isOperating)
        try await wait { fixture.server.count("/opened") == 1 }
        // The native script records the immediate opening before its callback.
        // Querying that historical fact does not restart the observation window.
        try await Task.sleep(for: .milliseconds(2100))
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.server.count("/opened"), 1)
        XCTAssertEqual(owner.popupHistory.map(\.outcome), [.opened]); XCTAssertFalse(owner.hasPendingPopup)
        XCTAssertEqual(try journals(fixture).first?.taskID, pending.taskID)
        XCTAssertEqual(try journals(fixture).first?.statuses, [.verified])
    }

    func testFailedAttemptReplacementReopensExactStoreBeforeAnyNativeDispatch() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page())
        defer { fixture.close() }
        configure(fixture)
        fixture.state.onCommand = { command in
            guard command == .validatePopup else { return }
            fixture.state.onCommand = nil; fixture.state.failureAtWrite = fixture.state.writes + 1
        }
        guard case .userInterventionRequired? = try await fixture.start() else { return XCTFail("Failed durability must keep the task pending") }
        let owner = try fixture.owner(), before = try XCTUnwrap(journals(fixture).first)
        XCTAssertEqual(before.statuses, [.attempted]); XCTAssertTrue(owner.hasPendingPopup)
        XCTAssertEqual(fixture.server.count("/opened"), 0); XCTAssertTrue(owner.popupHistory.isEmpty)
        fixture.state.failureAtWrite = nil
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/opened") == 1 }
        let after = try XCTUnwrap(journals(fixture).first)
        XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.contractDigest, before.contractDigest)
        XCTAssertEqual(after.statuses, [.verified]); XCTAssertEqual(owner.popupHistory.map(\.outcome), [.opened])
    }

    func testFailedRetirementPublicationReopensTombstoneBeforeChoosingAFreshTarget() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page())
        defer { fixture.close() }
        configure(fixture); pauseBeforeDispatch(fixture)
        do { _ = try await fixture.start(); XCTFail("Expected the prepared pending stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner()
        try await owner.resumeAfterUserControl() // Supersedes the original metadata snapshot.
        fixture.state.failureAtWrite = fixture.state.writes + 1
        guard case .userInterventionRequired = try await fixture.resume() else { return XCTFail("Unconfirmed retirement cannot release planning") }
        let tombstone = try XCTUnwrap(journals(fixture).first)
        XCTAssertNotNil(tombstone.retirementDigest); XCTAssertEqual(tombstone.statuses, [.attempted])
        XCTAssertTrue(owner.hasPendingPopup); XCTAssertTrue(owner.popupHistory.isEmpty)
        XCTAssertEqual(fixture.server.count("/opened"), 0)
        let decisions = fixture.actions.inputs.count
        fixture.state.failureAtWrite = nil
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/opened") == 1 }
        XCTAssertGreaterThan(fixture.actions.inputs.count, decisions)
        XCTAssertEqual(owner.popupHistory.map(\.outcome), [.retiredUnsent, .opened])
        XCTAssertEqual(owner.popupHistory.first?.digest, tombstone.retirementDigest)
        XCTAssertEqual(try journals(fixture).first(where: { $0.taskID == tombstone.taskID }), tombstone)
    }

    func testUnconfirmedNativeOpeningRemainsPendingAcrossDriverContinuations() async throws {
        let fixture = try await ResearchDriverFixture.make(searchBodyHTML: page(handler: "fetch('/opened');"))
        defer { fixture.close() }
        configure(fixture)
        for _ in 0..<2 {
            let result: ComputerUseExecutionResult? = fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root) == nil
                ? try await fixture.start() : try await fixture.resume()
            guard case .userInterventionRequired? = result else { return XCTFail("A click without opening is not progress") }
        }
        let owner = try fixture.owner()
        XCTAssertTrue(owner.hasPendingPopup); XCTAssertTrue(owner.popupHistory.isEmpty)
        XCTAssertEqual(fixture.actions.inputs.count, 1); XCTAssertEqual(fixture.server.count("/opened"), 1)
        XCTAssertEqual(try journals(fixture).first?.statuses, [.uncertain])
        XCTAssertEqual(owner.input.prompt, fixture.request)
        owner.retire()
        XCTAssertFalse(owner.hasPendingPopup); XCTAssertTrue(owner.popupHistory.isEmpty)
        do { _ = try await owner.resumePopup(); XCTFail("Stop cannot resume an old native operation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
    }

    func testLoginBeforePopupPreparationUsesHandbackAndExpiresTheOldProposal() async throws {
        let fixture = try await ResearchDriverFixture.make(heldSignal: true, searchBodyHTML: page() + """
            <script>fetch('/signal').then(() => { document.body.insertAdjacentHTML('beforeend',
            '<label>Password<input type=password></label>'); fetch('/changed'); });</script>
            """)
        defer { fixture.close() }
        configureGoal(fixture)
        fixture.policy.choices = [false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), original = owner.input
        fixture.actions.select = { input in self.opening(try XCTUnwrap(input.popupControlIDs.first)) }
        let old = try await owner.planNextAction(using: fixture.actions)
        try await wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
        do { _ = try await owner.openPopup(for: old); XCTFail("Authentication must interrupt before preparation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertFalse(owner.hasPendingPopup); XCTAssertEqual(fixture.server.count("/opened"), 0)
        owner.pause()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-login-return", to: fixture.base.appendingPathComponent("account-ready"))
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.openPopup(for: old); XCTFail("Explicit handback cannot reuse the pre-login proposal") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        fixture.actions.select = nil
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original); XCTAssertTrue(owner.popupHistory.isEmpty)
    }

    private func configure(_ fixture: ResearchDriverFixture) {
        configureGoal(fixture)
        fixture.policy.choices = [false]
        fixture.actions.select = { input in
            if let id = input.popupControlIDs.first { return self.opening(id) }
            if !input.readableControlIDs.isEmpty {
                return try ResearchAnswerFixture.json(["read_results":true, "read_controls":input.readableControlIDs.map { ["control":$0, "requirement":0] as [String: Any] }])
            }
            return #"{"read_results":true}"#
        }
    }
    private func configureGoal(_ fixture: ResearchDriverFixture) {
        fixture.goal.select = { _ in
            try ResearchAnswerFixture.json(["disposition":"research", "requirements":[
                ["turn":0, "source":"Find concerts ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
                ["turn":0, "source":"under USD 50. ", "role":"condition", "field":"price", "relation":"unspecified", "values":[]],
                ["turn":0, "source":"Do not buy.", "role":"prohibition", "field":"other", "relation":"unspecified", "values":[]]],
                "question":["topic":"none", "requirements":[]]])
        }
    }
    private func pauseBeforeDispatch(_ fixture: ResearchDriverFixture) {
        fixture.state.onCommand = { command in
            guard command == .validatePopup else { return }
            fixture.state.onCommand = nil
            fixture.state.onWrite = {
                fixture.state.onWrite = nil
                fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)?.pause()
            }
        }
    }
    private func page(handler: String = "this.setAttribute('aria-expanded','true'); document.getElementById('choices').hidden=false; fetch('/opened');", unsupported: Bool = false) -> String {
        """
        <article><h2>Concert Alpha</h2><a href='/details'>Alpha details</a>
        <button type=button role=combobox aria-label='Ticket type' aria-controls=choices aria-expanded=false onclick="\(handler)">Choose type</button>
        <div id=choices role=listbox aria-label='Ticket types' hidden><div role=option aria-selected=false>General admission</div></div>
        </article>
        """
        + (unsupported ? "<button role=combobox aria-label='Unsupported submit' aria-controls=choices aria-expanded=false>Submit</button>" : "")
    }
    private func opening(_ id: String, requirement: Int = 0) -> String {
        "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":\(requirement)}}"
    }
    private func object(_ string: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(string.utf8)) }
    private func journals(_ fixture: ResearchDriverFixture) throws -> [ComputerUseTaskJournal] {
        let directory = fixture.directory.appendingPathComponent("Research/Popups")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
