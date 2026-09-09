import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResearchOptionSelectionTests: XCTestCase {
    private let prompt = "Find concerts. Use general admission. Keep date unchanged. Do not buy."

    func testNativeCandidateDiscoveryDoesNotConsumeBindingsOrDispatchEvents() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let intent = try await OptionSelectionFixture.intent(fixture)
        for _ in 0..<40 {
            let choices = try await fixture.browser.optionSelectionChoices(in: intent.evidence)
            XCTAssertEqual(choices.count, 1); XCTAssertEqual(choices[0].controlID, intent.controlID)
            XCTAssertEqual(choices[0].optionIDs.count, 2); XCTAssertTrue(choices[0].optionIDs.contains(intent.optionID))
        }
        let target = try await fixture.browser.prepareOptionSelection(intent)
        try await fixture.browser.validateOptionSelection(target)
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    func testPlannerInspectsExactScopesThenOffersOnlyFullyObservedNativeChoices() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), count = fixture.actions.inputs.count
        configureActions(fixture)
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .selectOption(let control, let option, let requirement) = action.step else { return XCTFail("Expected a freshly scoped selection") }
        XCTAssertEqual(requirement, 1); XCTAssertEqual(fixture.actions.inputs.count, count + 5)
        let metadata = fixture.actions.inputs[count], scoped = action.input
        XCTAssertFalse(metadata.contextJSON.contains("General admission USD 40 total")); XCTAssertFalse(metadata.contextJSON.contains("2026-09-20"))
        XCTAssertTrue(scoped.contextJSON.contains("General admission USD 40 total")); XCTAssertTrue(scoped.contextJSON.contains("Admission conditions"))
        XCTAssertTrue(scoped.contextJSON.contains("2026-09-20")); XCTAssertFalse(scoped.contextJSON.contains("privateUnscoped"))
        XCTAssertTrue(scoped.optionInspectionControlIDs.isEmpty); XCTAssertEqual(scoped.optionReadControls.count, 3)
        XCTAssertTrue(scoped.optionChoices.contains { $0.controlID == control && $0.optionIDs.contains(option) })
        XCTAssertEqual(try object(scoped.contextJSON)["version"] as? Int, 15)
        for invalid in [selection("c999", option), selection(control, "o999"), selection(control, option, requirement: 3),
            "{\"select_option\":{\"control\":\"\(control)\",\"option\":\"\(option)\",\"requirement\":true}}",
            "{\"select_option\":{\"control\":\"\(control)\",\"option\":\"\(option)\",\"requirement\":1,\"text\":\"buy\"}}",
            try inspect(metadata), "{\"inspect_options\":[{\"control\":\"\(control)\",\"requirement\":3}]}"] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: invalid, input: scoped))
        }
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: selection(control, option), input: metadata))
        let local = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let body = try ResearchAnswerFixture.object(XCTUnwrap(local.makeRequest(scoped).httpBody))
        XCTAssertEqual(((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["name"] as? String, "browser_research_action_v15")
        XCTAssertFalse(owner.hasPendingOptionSelection); XCTAssertTrue(try journals(fixture).isEmpty)
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    func testDriverSelectsOnceThenReadsFreshEvidenceUnderTheCompleteTask() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        configureActions(fixture)
        guard case .browserResearchProgress(let report)? = try await fixture.start() else { return XCTFail("These facts support only a partial report") }
        let owner = try fixture.owner()
        try await wait { fixture.server.count("/chosen") == 1 }
        XCTAssertEqual(owner.input.prompt, prompt); XCTAssertEqual(report.goalRevision, owner.input.digest)
        XCTAssertFalse(owner.hasPendingOptionSelection); XCTAssertEqual(owner.optionSelectionHistory.map(\.outcome), [.selected])
        XCTAssertEqual(owner.optionSelectionHistory.map(\.didDispatch), [true])
        XCTAssertEqual(try journals(fixture).map(\.statuses), [[.verified]])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .selectOption }.count, 1)
        XCTAssertTrue(fixture.state.commands.contains(.observeResearchControls)); XCTAssertFalse(fixture.state.commands.contains(.edit))
        let after = try XCTUnwrap(fixture.actions.inputs.last)
        XCTAssertEqual(after.optionSelectionHistory, owner.optionSelectionHistory)
        XCTAssertTrue(after.contextJSON.contains("2026-09-20")); XCTAssertFalse(after.contextJSON.contains(owner.optionSelectionHistory[0].operationID))
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { $0.interpretation.input == owner.input })
    }

    func testResultReadingReusesTheRevalidatedExplicitScopeAfterOptionInspection() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), before = fixture.state.commands.filter { $0 == .observeResearchControls }.count
        fixture.actions.select = { input in input.optionReadControls.isEmpty ? try self.inspect(input) : #"{"read_results":true}"# }
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(action.step, .readResults); XCTAssertTrue(action.readControls.isEmpty); XCTAssertEqual(action.input.optionReadControls.count, 2)
        let candidates = try await owner.readCandidates(for: action)
        let controls = candidates.surroundingControls + candidates.candidates.flatMap(\.controls)
        XCTAssertEqual(controls.first { $0.control.label == "Date" }?.state?.value, "2026-09-20")
        XCTAssertEqual(controls.first { $0.control.label == "Ticket type" }?.state?.kind, .composite)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, before + 1)
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    func testAlreadySelectedChoiceIsRecordedAsAnObservationWithoutAnInputEvent() async throws {
        let fixture = try await make(alreadySelected: true)
        defer { fixture.close() }
        configureActions(fixture, first: true)
        _ = try await fixture.start()
        let owner = try fixture.owner(), record = try XCTUnwrap(owner.optionSelectionHistory.first)
        XCTAssertEqual(record.outcome, .selected); XCTAssertEqual(record.didDispatch, false)
        XCTAssertEqual(fixture.server.count("/chosen"), 0); XCTAssertEqual(try journals(fixture).first?.statuses, [.verified])
        let history = try XCTUnwrap(object(XCTUnwrap(fixture.actions.inputs.last).contextJSON)["option_selection_history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["did_dispatch"] as? Bool, false)
        XCTAssertEqual(owner.input.prompt, prompt.replacingOccurrences(of: "Use general admission.", with: "Use VIP tickets."))
    }

    func testPauseDuringInspectionJoinsTheReadAndDiscardsSpeculativeChoiceAuthority() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        configureActions(fixture)
        fixture.state.onCommand = { command in
            guard command == .observeResearchControls else { return }
            fixture.state.onCommand = nil
            fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)?.pause()
        }
        do { _ = try await fixture.start(); XCTFail("An interrupted inspection cannot select an option") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertFalse(owner.isOperating); XCTAssertFalse(owner.hasPendingOptionSelection)
        XCTAssertTrue(try journals(fixture).isEmpty); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { $0.optionReadControls.isEmpty })
        _ = try fixture.browser.acquireCurrentDocument(taskID: owner.taskID)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/chosen") == 1 }
        XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.optionSelectionHistory.map(\.outcome), [.selected])
    }

    func testPauseBeforeSelectionBlocksOtherWorkAndHandbackRetiresOnlyUnsentInput() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        configureActions(fixture); pauseBeforeDispatch(fixture)
        do { _ = try await fixture.start(); XCTFail("Pause must retain the journaled stage") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), original = owner.input, pending = try XCTUnwrap(journals(fixture).first)
        XCTAssertTrue(owner.hasPendingOptionSelection); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(pending.statuses, [.attempted]); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Pending selection blocks planning") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .optionSelectionPending) }
        do { _ = try await owner.readCandidates(); XCTFail("Pending selection blocks new readings") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .optionSelectionPending) }
        do { _ = try await owner.interpretGoal(); XCTFail("Pending selection blocks goal changes") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .optionSelectionPending) }
        XCTAssertThrowsError(try owner.issueQuestion(topic: .source, requirementIDs: [], controllerID: "phone", controllerSessionID: "session")) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .optionSelectionPending)
        }
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/chosen") == 1 }
        XCTAssertEqual(owner.optionSelectionHistory.map(\.outcome), [.retiredUnsent, .selected]); XCTAssertEqual(owner.input, original)
        let retired = try XCTUnwrap(journals(fixture).first { $0.taskID == pending.taskID })
        XCTAssertEqual(retired.statuses, pending.statuses); XCTAssertNotNil(retired.retirementDigest)
        XCTAssertEqual(retired.contractDigest, pending.contractDigest); XCTAssertFalse(owner.hasPendingOptionSelection)
    }

    func testPauseDuringNativeSelectionKeepsTheHistoricalReceiptWithoutReplaying() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        configureActions(fixture)
        fixture.state.onCommand = { command in
            guard command == .selectOption else { return }
            fixture.state.onCommand = nil
            fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)?.pause()
        }
        do { _ = try await fixture.start(); XCTFail("Cancelled dispatch cannot publish progress") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), pending = try XCTUnwrap(journals(fixture).first)
        XCTAssertTrue(owner.hasPendingOptionSelection); XCTAssertFalse(owner.isOperating)
        try await wait { fixture.server.count("/chosen") == 1 }
        try await Task.sleep(for: .milliseconds(2100))
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertFalse(owner.hasPendingOptionSelection); XCTAssertEqual(owner.optionSelectionHistory.map(\.outcome), [.selected])
        XCTAssertEqual(try journals(fixture).first?.taskID, pending.taskID); XCTAssertEqual(try journals(fixture).first?.statuses, [.verified])
        XCTAssertEqual(fixture.server.count("/chosen"), 1)
    }

    func testFailedAttemptAndRetirementStoresKeepTheOriginalOwnerPending() async throws {
        for retirement in [false, true] {
            let fixture = try await make()
            defer { fixture.close() }
            configureActions(fixture)
            if retirement {
                pauseBeforeDispatch(fixture)
                do { _ = try await fixture.start(); XCTFail("Expected an unsent attempt") }
                catch { XCTAssertTrue(error is CancellationError) }
                try await fixture.owner().resumeAfterUserControl()
                fixture.state.failureAtWrite = fixture.state.writes + 1
                guard case .userInterventionRequired = try await fixture.resume() else { return XCTFail("Retirement durability must remain pending") }
            } else {
                fixture.state.onCommand = { command in
                    guard command == .validateOptionSelection else { return }
                    fixture.state.onCommand = nil; fixture.state.failureAtWrite = fixture.state.writes + 1
                }
                guard case .userInterventionRequired? = try await fixture.start() else { return XCTFail("Attempt durability must remain pending") }
            }
            let owner = try fixture.owner(), before = try XCTUnwrap(journals(fixture).first)
            XCTAssertTrue(owner.hasPendingOptionSelection); XCTAssertTrue(owner.optionSelectionHistory.isEmpty)
            XCTAssertEqual(fixture.server.count("/chosen"), 0); XCTAssertEqual(before.statuses, [.attempted])
            XCTAssertEqual(before.retirementDigest != nil, retirement)
            fixture.state.failureAtWrite = nil
            _ = try await fixture.resume()
            try await wait { fixture.server.count("/chosen") == 1 }
            let saved = try XCTUnwrap(journals(fixture).first { $0.taskID == before.taskID })
            XCTAssertEqual(saved.contractDigest, before.contractDigest)
            XCTAssertEqual(owner.optionSelectionHistory.map(\.outcome), retirement ? [.retiredUnsent, .selected] : [.selected])
            XCTAssertEqual(saved.statuses, retirement ? [.attempted] : [.verified])
        }
    }

    func testRetirementCannotRebaseAChangedObservedDateIntoAFreshSelection() async throws {
        let signal = OptionSelectionFixture.signal("document.getElementById('date').value='2026-09-21';")
        let fixture = try await make(extra: signal, heldSignal: true)
        defer { fixture.close() }
        configureActions(fixture); pauseBeforeDispatch(fixture)
        do { _ = try await fixture.start(); XCTFail("Expected a pending selection") }
        catch { XCTAssertTrue(error is CancellationError) }
        let owner = try fixture.owner(), original = owner.input
        try await wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
        try await owner.resumeAfterUserControl()
        guard case .userInterventionRequired(let message) = try await fixture.resume() else { return XCTFail("Changed baseline must not authorize a replacement") }
        XCTAssertTrue(message.contains("criterion")); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(owner.optionSelectionHistory.map(\.outcome), [.retiredUnsent]); XCTAssertFalse(owner.hasPendingOptionSelection)
        XCTAssertEqual(try journals(fixture).count, 1); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        let context = try XCTUnwrap(fixture.actions.inputs.last).contextJSON
        XCTAssertTrue(context.contains("2026-09-20")); XCTAssertTrue(context.contains("2026-09-21"))
    }

    func testUnconfirmedSelectionBlocksNewDecisionsAndStopRetiresTheOwner() async throws {
        let fixture = try await make(handler: "fetch('/chosen');")
        defer { fixture.close() }
        configureActions(fixture)
        guard case .userInterventionRequired? = try await fixture.start() else { return XCTFail("A click is not a verified selection") }
        let owner = try fixture.owner(), decisions = fixture.actions.inputs.count
        guard case .userInterventionRequired = try await fixture.resume() else { return XCTFail("Uncertain selection must stay pending") }
        XCTAssertTrue(owner.hasPendingOptionSelection); XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertTrue(owner.optionSelectionHistory.isEmpty); XCTAssertEqual(try journals(fixture).first?.statuses, [.uncertain])
        try await wait { fixture.server.count("/chosen") == 1 }
        owner.retire(); XCTAssertFalse(owner.hasPendingOptionSelection)
        do { _ = try await owner.resumeOptionSelection(); XCTFail("Stop cannot resume a retired choice") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .retired) }
    }

    func testLoginBeforeSelectionPreparationUsesHandbackAndExpiresTheOldProposal() async throws {
        let signal = OptionSelectionFixture.signal("document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');")
        let fixture = try await make(extra: signal, heldSignal: true)
        defer { fixture.close() }
        _ = try await fixture.start(); configureActions(fixture)
        let owner = try fixture.owner(), original = owner.input, old = try await owner.planNextAction(using: fixture.actions)
        try await wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
        do { _ = try await owner.selectOption(for: old); XCTFail("Authentication must interrupt preparation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertFalse(owner.hasPendingOptionSelection); XCTAssertTrue(try journals(fixture).isEmpty)
        owner.pause()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "selection-login-return", to: fixture.base.appendingPathComponent("account-ready"))
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.selectOption(for: old); XCTFail("Handback cannot revive the pre-login proposal") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        fixture.actions.select = nil
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original); XCTAssertTrue(owner.optionSelectionHistory.isEmpty)
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    private func make(handler: String? = nil, extra: String = "", heldSignal: Bool = false, alreadySelected: Bool = false) async throws -> ResearchDriverFixture {
        let body = OptionSelectionFixture.page(handler: handler).replacingOccurrences(of: "<h2>Concert Alpha</h2>",
            with: "<h2>Concert Alpha</h2><a href='/details'>Alpha details</a>") + extra
        let criterion = alreadySelected ? "Use VIP tickets. " : "Use general admission. "
        let fixture = try await ResearchDriverFixture.make(request: "Find concerts. " + criterion + "Keep date unchanged. Do not buy.", heldSignal: heldSignal, searchBodyHTML: body)
        fixture.goal.select = { _ in
            try ResearchAnswerFixture.json(["disposition":"research","requirements":[
                ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
                ["turn":0,"source":criterion,"role":"condition","field":"other","relation":"unspecified","values":[]],
                ["turn":0,"source":"Keep date unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
                ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]],
                "question":["topic":"none","requirements":[]]])
        }
        fixture.policy.choices = [false]
        return fixture
    }
    private func configureActions(_ fixture: ResearchDriverFixture, first: Bool = false) {
        fixture.actions.select = { input in
            if input.optionSelectionHistory.last?.outcome == .selected { return try self.read(input) }
            if let review = try EffectScopeFixture.response(input) { return review }
            if let choice = input.optionChoices.first { return self.selection(choice.controlID, try XCTUnwrap(first ? choice.optionIDs.first : choice.optionIDs.last)) }
            return try self.inspect(input)
        }
    }
    private func scope(_ input: ComputerUseBrowserActionInput) throws -> [[String: Any]] {
        let owner = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Ticket type" })
        let date = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Date" })
        return [["control":owner.id,"requirement":1],["control":date.id,"requirement":2]]
    }
    private func inspect(_ input: ComputerUseBrowserActionInput) throws -> String { try ResearchAnswerFixture.json(["inspect_options":scope(input)]) }
    private func read(_ input: ComputerUseBrowserActionInput) throws -> String { try ResearchAnswerFixture.json(["read_results":true,"read_controls":scope(input)]) }
    private func selection(_ control: String, _ option: String, requirement: Int = 1) -> String {
        "{\"select_option\":{\"control\":\"\(control)\",\"option\":\"\(option)\",\"requirement\":\(requirement)}}"
    }
    private func pauseBeforeDispatch(_ fixture: ResearchDriverFixture) {
        fixture.state.onCommand = { command in
            guard command == .validateOptionSelection else { return }
            fixture.state.onCommand = nil
            fixture.state.onWrite = {
                fixture.state.onWrite = nil
                fixture.tools.ownedBrowserResearch(taskID: ResearchDriverFixture.root)?.pause()
            }
        }
    }
    private func object(_ text: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(text.utf8)) }
    private func journals(_ fixture: ResearchDriverFixture) throws -> [ComputerUseTaskJournal] {
        let directory = fixture.directory.appendingPathComponent("Research/OptionSelections")
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
