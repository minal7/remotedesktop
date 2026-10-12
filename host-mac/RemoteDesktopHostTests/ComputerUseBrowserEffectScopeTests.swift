import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Authored regression scenarios, pending permission for execution.
@MainActor
final class ComputerUseBrowserEffectScopeTests: XCTestCase {
    func testOmittedDateBlocksOpeningUntilAdditiveReadingAndFreshReview() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page())
        defer { fixture.close() }
        let initial = try await inspect(fixture)
        let date = try control("Date", initial), privateID = try control("Private notes", initial)
        XCTAssertTrue(initial.effectReviewControlIDs.contains(date)); XCTAssertTrue(initial.popupControlIDs.isEmpty)
        XCTAssertFalse(initial.contextJSON.contains("2026-09-20")); XCTAssertFalse(initial.contextJSON.contains("privateUnscoped"))
        let reviewed = try retaining(initial, review(initial))
        XCTAssertTrue(reviewed.popupControlIDs.isEmpty); XCTAssertEqual(reviewed.effectAdditionalReadControlIDs, [date])
        let extensionAction = try ComputerUseBrowserActionProposal.decode(content: XCTUnwrap(EffectScopeFixture.response(reviewed)), input: reviewed)
        XCTAssertEqual(extensionAction.step, .extendInspection)
        XCTAssertEqual(extensionAction.readControls, initial.optionReadControls + [.init(controlID: date, requirementIndex: 2)])
        let evidence = try await fixture.browser.observeResearchControls(for: extensionAction)
        let extended = try input(evidence, reads: extensionAction.readControls)
        XCTAssertTrue(extended.effectControlReviews.isEmpty); XCTAssertEqual(extended.effectReviewNextControlIDs, [privateID])
        XCTAssertTrue(extended.popupControlIDs.isEmpty); XCTAssertTrue(extended.contextJSON.contains("2026-09-20"))
        XCTAssertThrowsError(try retaining(extended, initial.effectControlReviews + [review(initial)]))
        let ready = try retaining(extended, review(extended))
        XCTAssertTrue(ready.effectScopeAllowsActions); XCTAssertEqual(ready.popupControlIDs, [try control("Ticket type", ready)])
        XCTAssertFalse(ready.contextJSON.contains("privateUnscoped")); XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    func testReviewRejectsMissingReorderedDuplicateForeignAndUntypedReferences() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page())
        defer { fixture.close() }
        let value = try await inspect(fixture), rows = try EffectScopeFixture.rows(value)
        XCTAssertEqual(rows.count, 2)
        var cases: [[[String: Any]]] = [[], Array(rows.dropLast()), Array(rows.reversed()), [rows[0], rows[0]]]
        for (key, replacement) in [("control", "c999" as Any), ("requirements", [true] as Any),
            ("evidence", ["t999"] as Any), ("evidence", [] as Any), ("extra", "ignored" as Any),
            ("relationship", "probably" as Any), ("requirements", [2, 2] as Any)] {
            var changed = rows; changed[0][key] = replacement; cases.append(changed)
        }
        var borrowed = rows; borrowed[0]["evidence"] = [value.effectReviewNextControlIDs[0], value.effectReviewNextControlIDs[1]]
        cases.append(borrowed)
        for rows in cases {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["review_controls":rows]), input: value))
        }
        let valid = try review(value)
        XCTAssertEqual(valid.entries.map(\.controlID), value.effectReviewNextControlIDs)
        XCTAssertThrowsError(try retaining(value, [valid, valid]))
    }

    func testReviewIsBoundToExactSnapshotAndOriginalGoal() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page())
        defer { fixture.close() }
        let value = try await inspect(fixture), reviewed = try review(value)
        let fresh = try await fixture.browser.observePage(document: fixture.document)
        XCTAssertThrowsError(try input(fresh, reads: [], reviews: [reviewed]))
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID,
            prompt: EffectScopeFixture.prompt.replacingOccurrences(of: "Use general admission.", with: "Use VIP tickets."),
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let changed = try ComputerUseBrowserGoalProposal.decode(content: EffectScopeFixture.goalJSON().replacingOccurrences(of: "Use general admission.", with: "Use VIP tickets."), input: goal)
        XCTAssertThrowsError(try ComputerUseBrowserActionInput(interpretation: changed, evidence: value.evidence,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [],
            optionReadControls: value.optionReadControls, effectControlReviews: [reviewed]))
    }

    func testMultipleReviewPartsStayBoundedAndCannotReleasePendingControls() async throws {
        let extra = (0..<13).map { "<label>Newsletter preference \($0)<input value='private-value-\($0)'></label>" }.joined()
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page() + extra)
        defer { fixture.close() }
        var value = try await inspect(fixture, includeDate: true), parts = 0
        while !value.effectReviewNextControlIDs.isEmpty {
            XCTAssertFalse(value.effectScopeAllowsActions); XCTAssertTrue(value.popupControlIDs.isEmpty)
            XCTAssertLessThanOrEqual(value.effectReviewNextControlIDs.count, 4)
            let json = try XCTUnwrap(EffectScopeFixture.response(value))
            XCTAssertLessThanOrEqual(json.utf8.count, 896)
            XCTAssertFalse(value.contextJSON.contains("private-value-")); XCTAssertFalse(value.contextJSON.contains("privateUnscoped"))
            value = try retaining(value, review(value)); parts += 1
            guard parts <= 64 else { return XCTFail("Review must terminate within its control bound") }
        }
        XCTAssertGreaterThan(parts, 1); XCTAssertEqual(value.effectControlReviews.flatMap(\.entries).count, 14)
        XCTAssertTrue(value.effectScopeAllowsActions); XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    func testOpaqueControlMetadataCannotBeClearedByReviewingVisibleControls() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page() + "<div role=tree tabindex=0 aria-label='Travel criteria'>Opaque settings</div>")
        defer { fixture.close() }
        let value = try await inspect(fixture, includeDate: true)
        XCTAssertTrue(value.evidence.page.omittedControls); XCTAssertTrue(value.evidence.page.omittedControlMetadata)
        XCTAssertFalse(value.effectReviewMetadataComplete)
        XCTAssertThrowsError(try review(value), "Even authored unrelated classifications cannot erase missing metadata")
        let rows = value.effectReviewNextControlIDs.map { ["control":$0,"relationship":"unknown","requirements":[],"evidence":[$0]] as [String: Any] }
        let decision = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["review_controls":rows]), input: value)
        guard case .reviewControls(let review) = decision.step else { return XCTFail("Expected unresolved review") }
        let reviewed = try retaining(value, review)
        XCTAssertFalse(reviewed.effectScopeAllowsActions); XCTAssertTrue(reviewed.popupControlIDs.isEmpty)
        XCTAssertThrowsError(try ComputerUseBrowserEffectScopeReview(input: reviewed))
    }

    func testKnownLazyOwnerDoesNotPretendItsUnavailableValueIsMissingMetadata() async throws {
        let body = "<button type=button role=combobox aria-label='Ticket type' aria-controls=choices aria-expanded=false>Choose type</button>"
        let fixture = try await ControlStateFixture(body: body)
        defer { fixture.close() }
        let value = try await inspect(fixture)
        XCTAssertTrue(value.evidence.page.omittedControls); XCTAssertFalse(value.evidence.page.omittedControlMetadata)
        XCTAssertEqual(value.evidence.page.controlStates.first?.kind, .unavailable)
        XCTAssertTrue(value.effectReviewMetadataComplete); XCTAssertTrue(value.effectScopeAllowsActions)
        let intent = try ComputerUseBrowserPopupIntent(interpretation: value.interpretation, evidence: value.evidence,
            controlID: XCTUnwrap(value.popupControlIDs.first), requirementIndex: 1, scopeReview: .init(input: value))
        _ = try await fixture.browser.preparePopup(intent)
        XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    func testScopeExtensionCannotDropReassignDuplicateOrReadUnrelatedControls() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page())
        defer { fixture.close() }
        let initial = try await inspect(fixture), value = try retaining(initial, review(initial))
        let date = try control("Date", value), owner = try control("Ticket type", value), privateID = try control("Private notes", value)
        let rows: [[[String: Any]]] = [[], [["control":owner,"requirement":2]], [["control":date,"requirement":1]],
            [["control":privateID,"requirement":1]], [["control":date,"requirement":2],["control":date,"requirement":2]]]
        for rows in rows {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["extend_inspection":rows]), input: value))
        }
        let extensionAction = try ComputerUseBrowserActionProposal.decode(content: XCTUnwrap(EffectScopeFixture.response(value)), input: value)
        XCTAssertEqual(Array(extensionAction.readControls.prefix(initial.optionReadControls.count)), initial.optionReadControls)
        XCTAssertEqual(extensionAction.readControls.last, .init(controlID: date, requirementIndex: 2))
        XCTAssertTrue(value.popupControlIDs.isEmpty)
    }

    func testNativeChangeDuringReviewInvalidatesTheOriginalScopedEvidence() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page() + OptionSelectionFixture.signal("document.getElementById('date').value='2026-09-21';"), heldSignal: true)
        defer { fixture.close() }
        let value = try await inspect(fixture, includeDate: true), ready = try retaining(value, review(value))
        try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { try await fixture.browser.validatePageEvidence(ready.evidence); XCTFail("A semantic review cannot freshen a changed native baseline") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertTrue(ready.contextJSON.contains("2026-09-20")); XCTAssertFalse(ready.contextJSON.contains("2026-09-21"))
        XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    func testCompletedReviewEntersPopupAndSelectionContractsWithoutRawValues() async throws {
        for expanded in [false, true] {
            let fixture = try await ControlStateFixture(body: EffectScopeFixture.page(expanded: expanded))
            defer { fixture.close() }
            var value = try await inspect(fixture, includeDate: true)
            while !value.effectScopeAllowsActions {
                let action = try ComputerUseBrowserActionProposal.decode(content: XCTUnwrap(EffectScopeFixture.response(value)), input: value)
                if case .reviewControls(let review) = action.step { value = try retaining(value, review) }
                else {
                    XCTAssertEqual(action.step, .extendInspection)
                    value = try input(await fixture.browser.observeResearchControls(for: action), reads: action.readControls)
                }
            }
            let proof = try ComputerUseBrowserEffectScopeReview(input: value), owner = try control("Ticket type", value)
            XCTAssertEqual(proof.readControls, value.optionReadControls)
            XCTAssertEqual(String(reflecting: proof), "BrowserEffectScopeReview")
            let unreviewed = try input(value.evidence, reads: value.optionReadControls)
            let citation = try XCTUnwrap(unreviewed.effectReviewEvidenceIDs.first { !unreviewed.effectReviewControlIDs.contains($0) })
            let otherRows = try EffectScopeFixture.rows(unreviewed).map { row -> [String: Any] in
                var row = row; row["evidence"] = (row["evidence"] as? [String] ?? []) + [citation]; return row
            }
            let proposal = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["review_controls":otherRows]), input: unreviewed)
            guard case .reviewControls(let otherReview) = proposal.step else { return XCTFail("Expected a separately cited scope review") }
            let otherProof = try ComputerUseBrowserEffectScopeReview(input: retaining(unreviewed, otherReview))
            XCTAssertNotEqual(proof.digest, otherProof.digest)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("effect-scope-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let contract: ComputerUseTaskContract
            if expanded {
                let choices = try await fixture.browser.optionSelectionChoices(in: value.evidence)
                let option = try XCTUnwrap(choices.first?.optionIDs.last)
                let intent = try ComputerUseBrowserOptionSelectionIntent(interpretation: value.interpretation, evidence: value.evidence,
                    controlID: owner, optionID: option, requirementIndex: 1, scopeReview: proof)
                let target = try await fixture.browser.prepareOptionSelection(intent)
                let differentlyReviewed = try ComputerUseBrowserOptionSelectionIntent(interpretation: value.interpretation, evidence: value.evidence,
                    controlID: owner, optionID: option, requirementIndex: 1, scopeReview: otherProof)
                XCTAssertEqual(differentlyReviewed.baselineDigest, intent.baselineDigest)
                XCTAssertNotEqual(target.payloadDigest, ComputerUseBrowserOptionSelectionTarget(intent: differentlyReviewed, binding: target.binding).payloadDigest)
                contract = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory).contract
            } else {
                let intent = try ComputerUseBrowserPopupIntent(interpretation: value.interpretation, evidence: value.evidence,
                    controlID: owner, requirementIndex: 1, scopeReview: proof)
                let target = try await fixture.browser.preparePopup(intent)
                let differentlyReviewed = try ComputerUseBrowserPopupIntent(interpretation: value.interpretation, evidence: value.evidence,
                    controlID: owner, requirementIndex: 1, scopeReview: otherProof)
                XCTAssertEqual(differentlyReviewed.baselineDigest, intent.baselineDigest)
                XCTAssertNotEqual(target.payloadDigest, ComputerUseBrowserPopupTarget(intent: differentlyReviewed, binding: target.binding).payloadDigest)
                contract = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory).contract
            }
            XCTAssertEqual(contract.steps[0].operation.payloadVersion, 3)
            let journal = ComputerUseTaskJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
                contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: [.planned])
            let serialized = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
            for privateValue in ["2026-09-20", "privateUnscoped", EffectScopeFixture.prompt] { XCTAssertFalse(serialized.contains(privateValue)) }
            XCTAssertEqual(fixture.server.count("/opened"), 0); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        }
    }

    func testActionInstructionsFollowAvailableCapabilitiesAndKeepTheWholeGoal() async throws {
        let fixture = try await ControlStateFixture(body: EffectScopeFixture.page())
        defer { fixture.close() }
        let metadata = try input(await fixture.browser.observePage(document: fixture.document), reads: [])
        let scoped = try await inspect(fixture)
        let before = ComputerUseLocalBrowserActionPlanner.instructions(for: metadata)
        let after = ComputerUseLocalBrowserActionPlanner.instructions(for: scoped)
        XCTAssertFalse(before.contains("effect_scope accounts")); XCTAssertTrue(after.contains("effect_scope accounts"))
        XCTAssertFalse(after.contains("Return {\"form\"")); XCTAssertFalse(after.contains("When history_destinations"))
        XCTAssertFalse(after.contains("When option_choices")); XCTAssertTrue(after.contains("Account access uses visible user handoff"))
        let local = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let body = try ResearchAnswerFixture.object(XCTUnwrap(local.makeRequest(scoped).httpBody))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, after); XCTAssertEqual(messages[1]["content"] as? String, scoped.contextJSON)
        XCTAssertTrue(scoped.contextJSON.contains(EffectScopeFixture.prompt)); XCTAssertFalse(scoped.contextJSON.contains("privateUnscoped"))
    }

    private func control(_ label: String, _ value: ComputerUseBrowserActionInput) throws -> String {
        try XCTUnwrap(value.evidence.page.controls.first { $0.label == label }?.id)
    }
    private func input(_ evidence: ComputerUseBrowserPageEvidence, reads: [ComputerUseBrowserControlRead],
                       reviews: [ComputerUseBrowserEffectControlReview] = []) throws -> ComputerUseBrowserActionInput {
        try .init(interpretation: EffectScopeFixture.goal(taskID: evidence.document.taskID), evidence: evidence, navigationHistory: [],
            formHistory: [], latestForm: nil, changedFormTargetIDs: [],
            popupControlIDs: evidence.page.controls.filter { $0.compositeRole == "combobox" && !$0.disabled }.map(\.id),
            allowOptionInspection: reads.isEmpty, optionReadControls: reads, effectControlReviews: reviews)
    }
    private func inspect(_ fixture: ControlStateFixture, includeDate: Bool = false) async throws -> ComputerUseBrowserActionInput {
        let metadata = try input(await fixture.browser.observePage(document: fixture.document), reads: [])
        var reads = [["control":try control("Ticket type", metadata),"requirement":1] as [String: Any]]
        if includeDate { reads.append(["control":try control("Date", metadata),"requirement":2]) }
        let action = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["inspect_options":reads]), input: metadata)
        return try input(await fixture.browser.observeResearchControls(for: action), reads: action.readControls)
    }
    private func review(_ value: ComputerUseBrowserActionInput) throws -> ComputerUseBrowserEffectControlReview {
        let action = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["review_controls":EffectScopeFixture.rows(value)]), input: value)
        guard case .reviewControls(let review) = action.step else { throw ComputerUseBrowserActionPlanError.invalidProposal }; return review
    }
    private func retaining(_ value: ComputerUseBrowserActionInput, _ review: ComputerUseBrowserEffectControlReview) throws -> ComputerUseBrowserActionInput {
        try retaining(value, value.effectControlReviews + [review])
    }
    private func retaining(_ value: ComputerUseBrowserActionInput, _ reviews: [ComputerUseBrowserEffectControlReview]) throws -> ComputerUseBrowserActionInput {
        try input(value.evidence, reads: value.optionReadControls, reviews: reviews)
    }

}

/// Explicit oracle for these authored concert fixtures only. Unknown controls
/// stay unknown; this is not a keyword policy in the production planner.
@MainActor
enum EffectScopeFixture {
    static let prompt = "Find concerts. Use general admission. Keep date unchanged. Do not buy."
    static func rows(_ input: ComputerUseBrowserActionInput) throws -> [[String: Any]] {
        try input.effectReviewNextControlIDs.map { id in
            let control = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id })
            let requirement: Int?
            if control.label == "Date" { requirement = 2 }
            else if control.label == "Ticket types" {
                let owner = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Ticket type" })
                requirement = try XCTUnwrap(input.optionReadControls.first { $0.controlID == owner.id }?.requirementIndex)
            } else { requirement = nil }
            let unrelated = control.label == "Private notes" || control.label == "Newsletter settings"
                || (0..<13).contains { control.label == "Newsletter preference \($0)" }
            return ["control":id,"relationship":requirement != nil ? "relevant" : (unrelated ? "unrelated" : "unknown"),
                "requirements":requirement.map { [$0] } ?? [],"evidence":[id]]
        }
    }
    static func response(_ input: ComputerUseBrowserActionInput) throws -> String? {
        if !input.effectReviewNextControlIDs.isEmpty { return try ResearchAnswerFixture.json(["review_controls":rows(input)]) }
        if !input.effectAdditionalReadControlIDs.isEmpty {
            let rows: [[String: Any]] = try input.effectAdditionalReadControlIDs.map { id in
                let entry = try XCTUnwrap(input.effectControlReviews.flatMap(\.entries).first { $0.controlID == id })
                return ["control":id,"requirement":try XCTUnwrap(entry.requirementIndices.first)]
            }
            return try ResearchAnswerFixture.json(["extend_inspection":rows])
        }
        return nil
    }
    static func goal(taskID: String) throws -> ComputerUseBrowserGoalProposal {
        let input = try ComputerUseBrowserGoalInput(taskID: taskID, prompt: prompt,
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        return try .decode(content: goalJSON(), input: input)
    }
    static func goalJSON() throws -> String {
        try ResearchAnswerFixture.json(["disposition":"research","requirements":[
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Use general admission. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Keep date unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]],
            "question":["topic":"none","requirements":[]]])
    }
    static func page(expanded: Bool = false) -> String {
        let original = OptionSelectionFixture.page().replacingOccurrences(of: "<h2>Concert Alpha</h2>", with: "<h2>Concert Alpha</h2><a href='/details'>Alpha details</a>")
        guard !expanded else { return original }
        return original.replacingOccurrences(of: "aria-expanded=true", with: "aria-expanded=false onclick=\"this.setAttribute('aria-expanded','true'); document.getElementById('choices').hidden=false; fetch('/opened');\"")
            .replacingOccurrences(of: "id=choices role=listbox", with: "id=choices role=listbox hidden")
    }
}
