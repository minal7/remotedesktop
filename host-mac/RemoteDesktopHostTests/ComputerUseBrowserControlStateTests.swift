import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserControlStateTests: XCTestCase {
    func testResearchReadsActualNativeSelectionsWithoutSubmissionOrTextEntryValues() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><p>USD 40</p>
            <label>Date<input id=d type=date value=2026-09-20></label>
            <label>Ticket type<select id=s name=privateParameter><optgroup label='Admission rules'>
              <option value=privateFirst selected>Restricted ticket</option><option value=privateSecond>General admission</option>
            </optgroup></select></label><label>Accessible seating<input id=c type=checkbox checked></label>
            <label>Notes<input value=privateTypedValue></label><label>Unset date<input type=date></label>
            <label>Unset type<select multiple><option>Unselected type</option></select></label><button>Continue</button></article>
            <script>document.getElementById('d').value='2026-09-21'; document.getElementById('s').selectedIndex=1; document.getElementById('c').indeterminate=true;</script>
            """)
        defer { fixture.close() }
        let metadata = try await fixture.browser.observePage(document: fixture.document)
        XCTAssertFalse(metadata.page.controlStateObserved); XCTAssertTrue(metadata.page.controlStates.isEmpty)
        let reading = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        let page = reading.page, input = try ComputerUseBrowserResultPageInput(page: page)
        XCTAssertTrue(page.isWellFormed); XCTAssertTrue(page.controlStateObserved)
        let date = try fixture.state("Date", in: page), selected = try fixture.state("Ticket type", in: page)
        XCTAssertEqual(date.value, "2026-09-21")
        let control = try XCTUnwrap(page.controls.first { $0.label == "Ticket type" })
        XCTAssertEqual(selected.selectedOptionIDs, [control.options[1].id])
        XCTAssertEqual(selected.fieldSource(for: control), "Admission rules: General admission")
        XCTAssertEqual(try fixture.state("Accessible seating", in: page).indeterminate, true)
        let mixed = try fixture.state("Accessible seating", in: page)
        let mixedControl = try XCTUnwrap(page.controls.first { $0.label == "Accessible seating" })
        XCTAssertTrue(mixed.renderedObservation(for: mixedControl).contains("Checked: true; indeterminate: true."))
        for label in ["Accessible seating", "Unset date", "Unset type"] {
            let control = try XCTUnwrap(page.controls.first { $0.label == label })
            XCTAssertFalse(input.controlIDs.contains(control.id), "Mixed or absent selections cannot supply a positive field value")
        }
        XCTAssertEqual(try fixture.state("Notes", in: page).kind, .unavailable)
        for secret in ["privateFirst", "privateSecond", "privateParameter", "privateTypedValue"] {
            XCTAssertFalse(input.contextJSON.contains(secret), secret)
        }
        XCTAssertFalse(String(reflecting: date).contains("2026-09-21"))
        let context = try object(input.contextJSON)
        XCTAssertEqual(context["version"] as? Int, 4); XCTAssertEqual(context["omitted_controls"] as? Bool, true)
        let invalid = ComputerUseBrowserControlState(controlID: control.id, kind: .selection, value: nil,
            selectedOptionIDs: control.options.map(\.id), checked: nil, indeterminate: nil)
        XCTAssertFalse(invalid.isValid(for: control), "A single select cannot report multiple current choices")
    }

    func testPropertyOnlyChangesInvalidateResearchStateWithoutChangingMetadataSnapshots() async throws {
        for includeState in [false, true] {
            let fixture = try await ControlStateFixture(body: """
                <article><h2>Concert Alpha</h2><label>Date<input id=d type=date value=2026-09-20></label>
                <label>Type<select id=s><option>First</option><option>Second</option></select></label>
                <label>Accessible<input id=c type=checkbox checked></label></article>
                <script>fetch('/signal').then(() => { document.getElementById('d').value='2026-09-21'; document.getElementById('s').selectedIndex=1; document.getElementById('c').checked=false; fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let evidence = try await fixture.browser.observePage(document: fixture.document, includingControlState: includeState)
            let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts.",
                referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
            let input = try ComputerUseBrowserResultPageInput(page: evidence.page)
            let article = try XCTUnwrap(evidence.page.containers.first { $0.kind == "article" })
            let title = try XCTUnwrap(evidence.page.texts.first { $0.text == "Concert Alpha" })
            let proposal = try ComputerUseBrowserResultProposal.decode(content: ResearchAnswerFixture.json([
                "candidates":[["container":article.id, "fields":[["kind":"title", "texts":[title.id]]], "links":[]]]]), input: input, goal: goal)
            let candidates = try await fixture.browser.prepareResultCandidates(proposal, goal: goal, evidence: evidence)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            if includeState {
                do { try await fixture.browser.validatePageEvidence(evidence); XCTFail("Live property changes invalidate the captured selections") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                do { try await fixture.browser.validateResultCandidates(candidates, goal: goal); XCTFail("The old reading cannot be reused") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                do { _ = try await fixture.browser.prepareResultCandidates(proposal, goal: goal, evidence: evidence); XCTFail("The old proposal cannot be rebound") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                let fresh = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
                XCTAssertEqual(try fixture.state("Date", in: fresh.page).value, "2026-09-21")
                XCTAssertEqual(try fixture.state("Accessible", in: fresh.page).checked, false)
            } else {
                try await fixture.browser.validatePageEvidence(evidence)
                try await fixture.browser.validateResultCandidates(candidates, goal: goal)
            }
        }
    }

    func testResultControlReferencesAreNativeScopedAndCannotBecomeAvailableInventory() async throws {
        let fixture = try await ControlStateFixture(body: """
            <label>Global date<input type=date value=2026-09-20></label>
            <article><h2>Concert Alpha</h2><p>Available inventory</p><label>Tickets<input type=number value=2></label></article>
            """)
        defer { fixture.close() }
        let evidence = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        let input = try ComputerUseBrowserResultPageInput(page: evidence.page)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let article = try XCTUnwrap(evidence.page.containers.first { $0.kind == "article" })
        let title = try XCTUnwrap(evidence.page.texts.first { $0.text == "Concert Alpha" }), available = try XCTUnwrap(evidence.page.texts.first { $0.text == "Available inventory" })
        let count = try XCTUnwrap(evidence.page.controls.first { $0.label == "Tickets" }), global = try XCTUnwrap(evidence.page.controls.first { $0.label == "Global date" })
        func proposal(_ id: String) throws -> ComputerUseBrowserResultProposal {
            try .decode(content: ResearchAnswerFixture.json(["candidates":[["container":article.id, "fields":[
                ["kind":"title", "texts":[title.id], "controls":[]], ["kind":"quantity", "texts":[], "controls":[id]],
                ["kind":"availability", "texts":[available.id], "controls":[]]], "links":[]]]]), input: input, goal: goal)
        }
        XCTAssertThrowsError(try proposal(global.id)); XCTAssertThrowsError(try proposal("c999"))
        let selected = try proposal(count.id), reviewInput = try ComputerUseBrowserResultReviewInput(goal: goal, page: input, proposal: selected)
        func review(_ meaning: String) throws -> ComputerUseBrowserResultReview {
            let fields: [[String: Any]] = [
                ["scope":"offer", "price":"notPrice", "quantity":"notQuantity", "qualifiers":[]],
                ["scope":"offer", "price":"notPrice", "quantity":meaning, "qualifiers":[available.id]],
                ["scope":"offer", "price":"notPrice", "quantity":"notQuantity", "qualifiers":[]]]
            return try .decode(content: ResearchAnswerFixture.json(["candidates":[["association":"singleOffer", "fields":fields]]]), input: reviewInput)
        }
        XCTAssertThrowsError(try review("availableQuantity"))
        XCTAssertEqual(try review("selectedQuantity").candidates[0].fields[1].quantity, .selectedQuantity)
        let planner = try ComputerUseLocalBrowserResultPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let request = try planner.makeRequest(goal: goal, page: input), body = try ResearchAnswerFixture.object(XCTUnwrap(request.httpBody))
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_result_candidates_v2")
        XCTAssertEqual(try object(reviewInput.contextJSON)["version"] as? Int, 4)
    }

    func testDriverUsesTheSelectedDateAndReportsControlObservationsSeparatelyFromQuotes() async throws {
        for selected in ["2026-09-20", "2026-09-21"] {
            let fixture = try await ResearchAnswerFixture.make(extra: ("On 2026-09-20. ", "condition", "date"),
                controlHTML: "<label>Date<input type=date value='\(selected)' min=2026-09-01 max=2026-09-30></label><label>Type<select><option value=private-code>General admission</option></select></label>")
            defer { fixture.source.close() }
            let result = try await fixture.source.start(), owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
            let field = try XCTUnwrap(reading.candidates.first?.fields.first { $0.kind == .date })
            XCTAssertTrue(field.textIDs.isEmpty); XCTAssertEqual(field.controlIDs.count, 1)
            let status = try XCTUnwrap(reading.requirementAssessment?.candidates.first?.requirements[2].status)
            if selected == "2026-09-20" {
                guard case .browserResearchAnswer(let answer)? = result else { return XCTFail("Expected an answer grounded in the selected date") }
                try owner.validateAnswer(answer)
                XCTAssertEqual(status, .quotedValueMatches)
                for text in ["Native control observations", "General admission", "2026-09-20", "2026-09-01", "2026-09-30", "On 2026-09-20.", "Do not buy."] { XCTAssertTrue(answer.message.contains(text), text) }
                XCTAssertFalse(answer.message.contains("private-code"))
                XCTAssertFalse(answer.message.contains("│ Native control observations"))
            } else {
                guard case .userInterventionRequired? = result else { return XCTFail("A conflicting selected date cannot complete the request") }
                XCTAssertEqual(status, .quotedValueConflicts)
            }
            XCTAssertEqual(owner.input.prompt, fixture.source.request); XCTAssertEqual(fixture.source.server.count("/offers"), 0)
        }
    }

    func testSelectedQuantityDoesNotResolveARequestedInventoryCount() async throws {
        let fixture = try await ResearchAnswerFixture.make(inventory: 2, controlHTML: "<label>Tickets<input type=number value=2></label>")
        defer { fixture.source.close() }
        let result = try await fixture.source.start()
        guard case .userInterventionRequired? = result else { return XCTFail("Selection and stock must be reconciled before completion") }
        let owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
        XCTAssertEqual(reading.review?.candidates[0].fields.last?.quantity, .selectedQuantity)
        XCTAssertNil(try reading.answerEligibility(goal: owner.input, evidence: owner.researchEvidence(for: owner.input))?.selectionCounts.first)
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
    }

    func testAuthenticationAndUnscopedValuesRemainOutsideResearchState() async throws {
        let login = try await ControlStateFixture(body: "<label>Verification code<input type=number value=123456></label>")
        defer { login.close() }
        do { _ = try await login.browser.observePage(document: login.document, includingControlState: true); XCTFail("A numeric code still requires manual login") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><label>Notes<input value=privateNotes></label>
            <label>Saved code<input type=number readonly value=998877></label>
            <label>Saved choice<select disabled><option>First</option><option selected>Second</option></select></label>
            <label>Saved flag<input type=checkbox disabled checked></label>
            <label>Password<input type=password disabled value=privatePassword></label></article>
            """)
        defer { fixture.close() }
        let evidence = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        let input = try ComputerUseBrowserResultPageInput(page: evidence.page)
        XCTAssertTrue(evidence.page.omittedControls)
        XCTAssertEqual(try fixture.state("Notes", in: evidence.page).kind, .unavailable)
        XCTAssertEqual(try fixture.state("Saved code", in: evidence.page).kind, .unavailable)
        XCTAssertEqual(try fixture.state("Saved choice", in: evidence.page).kind, .unavailable)
        XCTAssertEqual(try fixture.state("Saved flag", in: evidence.page).kind, .unavailable)
        for value in ["privateNotes", "998877", "privatePassword"] { XCTAssertFalse(input.contextJSON.contains(value)) }
        XCTAssertTrue(input.controlIDs.isEmpty)
    }

    func testOversizedCompleteControlObservationsCannotBeTruncatedIntoAnAnswer() async throws {
        let options = (0..<14).map { "<option value='private-\($0)'>Type \($0) " + String(repeating: "x", count: 240) + "</option>" }.joined()
        let fixture = try await ResearchAnswerFixture.make(controlHTML: "<label>Ticket type<select>\(options)</select></label>")
        defer { fixture.source.close() }
        let result = try await fixture.source.start()
        guard case .userInterventionRequired? = result else { return XCTFail("Complete control qualifications must fit delivery") }
        let owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
        let eligibility = try XCTUnwrap(reading.answerEligibility(goal: owner.input, evidence: owner.researchEvidence(for: owner.input)))
        let selection = try eligibility.selection([0])
        XCTAssertThrowsError(try eligibility.answer(for: selection)) { XCTAssertEqual($0 as? ComputerUseBrowserLinkPlanError, .contextLimit) }
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
    }

    private func object(_ string: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(string.utf8)) }
}

private struct ControlStateUnusedTransport: ComputerUseTextModelTransport {
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { throw ComputerUseBrowserResultError.invalidProposal }
    func complete(request: URLRequest) async throws -> Data { throw ComputerUseBrowserResultError.invalidProposal }
}

@MainActor
private final class ControlStateFixture {
    let server: OwnedBrowserHTTPFixture
    let browser: ComputerUseOwnedBrowser
    let document: ComputerUseBrowserDocument
    init(body: String, heldSignal: Bool = false) async throws {
        server = try .init(routes: ["/page":.init(body: "<!doctype html><meta charset=utf-8>" + body), "/signal":.init(held: heldSignal)])
        browser = .init(presentsWindow: false)
        do {
            let base = try await server.start()
            try browser.claim(taskID: "control-fixture")
            document = try await browser.navigate(taskID: "control-fixture", operationID: "open", to: base.appendingPathComponent("page"))
        } catch { browser.close(); server.stop(); throw error }
    }
    func state(_ label: String, in page: ComputerUseBrowserPageSnapshot) throws -> ComputerUseBrowserControlState {
        let control = try XCTUnwrap(page.controls.first { $0.label == label })
        return try XCTUnwrap(page.controlStates.first { $0.controlID == control.id })
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func close() { browser.close(); server.stop() }
}
