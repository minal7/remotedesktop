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
        let connection = try ComputerUseTextModelConnection(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token-value", modelAlias: "fixture-model")
        let planner = ComputerUseLocalBrowserResultPlanner(connection: connection, transport: ControlStateUnusedTransport())
        let request = try planner.makeRequest(goal: goal, page: input), body = try ResearchAnswerFixture.object(XCTUnwrap(request.httpBody))
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_result_candidates_v2")
        XCTAssertEqual(try object(reviewInput.contextJSON)["version"] as? Int, 5)
        if let path = ProcessInfo.processInfo.environment["REPAIR_PLANNER_REQUEST_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(request.httpBody).write(to: directory.appendingPathComponent("control-reading.json"), options: .atomic)
            let reviewer = ComputerUseLocalBrowserResultReviewPlanner(connection: connection, transport: ControlStateUnusedTransport())
            let parts: [ComputerUseBrowserReviewPart?] = try ComputerUseBrowserReviewPart.wholeOutputFits(reviewInput)
                ? [nil] : ComputerUseBrowserReviewPart.plan(reviewInput).map { Optional($0) }
            for (index, part) in parts.enumerated() {
                let request = try reviewer.makeRequest(reviewInput, part: part)
                try XCTUnwrap(request.httpBody).write(to: directory.appendingPathComponent("control-review-\(index).json"), options: .atomic)
            }
        }
    }

    func testDriverUsesTheSelectedDateAndReportsControlObservationsSeparatelyFromQuotes() async throws {
        for selected in ["2026-09-20", "2026-09-21"] {
            let fixture = try await ResearchAnswerFixture.make(extra: ("On 2026-09-20. ", "condition", "date"),
                controlHTML: "<label>Date<input type=date value='\(selected)' min=2026-09-01 max=2026-09-30></label><label>Type<select><option value=private-code>General admission</option></select></label>", resultDate: "2026-09-20")
            defer { fixture.source.close() }
            let result = try await fixture.source.start(), owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
            let field = try XCTUnwrap(reading.candidates.first?.fields.first { $0.kind == .date && !$0.controlIDs.isEmpty })
            XCTAssertTrue(field.textIDs.isEmpty); XCTAssertEqual(field.controlIDs.count, 1)
            let status = try XCTUnwrap(reading.requirementAssessment?.candidates.first?.requirements[2].status)
            if selected == "2026-09-20" {
                guard case .browserResearchAnswer(let answer)? = result else { return XCTFail("Expected an answer grounded in the selected date") }
                try owner.validateAnswer(answer)
                XCTAssertEqual(status, .quotedValueMatches)
                for text in ["Control observations", "General admission", "2026-09-20", "2026-09-01", "2026-09-30", "On 2026-09-20.", "Do not buy."] { XCTAssertTrue(answer.message.contains(text), text) }
                XCTAssertFalse(answer.message.contains("private-code"))
                XCTAssertFalse(answer.message.contains("│ Control observations"))
            } else {
                guard case .userInterventionRequired? = result else { return XCTFail("A conflicting selected date cannot complete the request") }
                XCTAssertEqual(status, .selectedValueConflicts)
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

    func testMatchingSelectionWithoutAResultDateKeepsTheOriginalTaskOpen() async throws {
        let fixture = try await ResearchAnswerFixture.make(extra: ("On 2026-09-20. ", "condition", "date"),
            controlHTML: "<label>Date<input type=date value=2026-09-20></label>")
        defer { fixture.source.close() }
        let result = try await fixture.source.start()
        guard case .userInterventionRequired? = result else { return XCTFail("A chosen setting does not establish the displayed result date") }
        let owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
        let assessment = try XCTUnwrap(reading.requirementAssessment)
        XCTAssertEqual(assessment.candidates[0].requirements[2].status, .needsResultObservation)
        XCTAssertEqual(assessment.candidates[0].quotes.last?.sourceKind, .controlState)
        XCTAssertTrue(try XCTUnwrap(assessment.candidates[0].quotes.last).textIDs.isEmpty)
        XCTAssertEqual(try object(ResearchAnswerFixture.json(assessment.plannerContext))["version"] as? Int, 4)
        XCTAssertTrue(fixture.inputs.allSatisfy { $0.answerCounts.isEmpty })
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
    }

    func testMatchingSelectionCannotReplaceAnEarlierDisplayedResultDate() async throws {
        let fixture = try await ResearchAnswerFixture.make(extra: ("On 2026-09-20. ", "condition", "date"),
            controlHTML: "<label>Date<input type=date value=2026-09-20></label>", resultDate: "2026-09-19")
        defer { fixture.source.close() }
        let result = try await fixture.source.start()
        guard case .userInterventionRequired? = result else { return XCTFail("Unrefreshed result text cannot inherit the chosen date") }
        let owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
        let candidate = try XCTUnwrap(reading.requirementAssessment?.candidates.first)
        XCTAssertEqual(candidate.requirements[2].status, .quotedValueConflicts)
        let dates = candidate.quotes.filter { $0.kind == .date }
        XCTAssertEqual(dates.map(\.sourceKind), [.pageText, .controlState])
        XCTAssertEqual(dates.map(\.source), ["Date: 2026-09-19", "2026-09-20"])
        XCTAssertTrue(fixture.inputs.allSatisfy { $0.answerCounts.isEmpty })
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
    }

    func testEveryProposedDateSelectionMustAgreeWithTheDisplayedResult() async throws {
        for second in ["2026-09-20", "2026-09-21"] {
            let fixture = try await ResearchAnswerFixture.make(extra: ("On 2026-09-20. ", "condition", "date"),
                controlHTML: "<label>First date<input type=date value=2026-09-20></label><label>Second date<input type=date value='\(second)'></label>", resultDate: "2026-09-20")
            defer { fixture.source.close() }
            let result = try await fixture.source.start(), owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
            let assessment = try XCTUnwrap(reading.requirementAssessment?.candidates.first)
            XCTAssertEqual(assessment.quotes.filter { $0.sourceKind == .controlState }.count, 2)
            if second == "2026-09-20" {
                guard case .browserResearchAnswer(let answer)? = result else { return XCTFail("Consistent settings and result text remain usable") }
                try owner.validateAnswer(answer)
                XCTAssertEqual(assessment.requirements[2].status, .quotedValueMatches)
                XCTAssertTrue(answer.message.contains("First date")); XCTAssertTrue(answer.message.contains("Second date"))
            } else {
                guard case .userInterventionRequired? = result else { return XCTFail("A matching selection cannot hide a conflicting one") }
                XCTAssertEqual(assessment.requirements[2].status, .selectedValueConflicts)
            }
            XCTAssertEqual(owner.input.prompt, fixture.source.request)
        }
    }

    func testControlAndMixedSourcesCannotSupportResultFactsThroughWholeOrSegmentedReview() async throws {
        for (kind, clause, displayed) in [("date", "On 2026-09-20.", "2026-09-20"),
            ("time", "At 19:00.", "19:00"), ("location", "In Paris.", "Paris"),
            ("availability", "With available seats.", "Seats available"), ("price", "Under USD 50.", "USD 40")] {
            let fixture = try await ControlStateFixture(body: "<article><h2>Concert Alpha</h2><p>\(displayed)</p><label>Chosen setting<select><option>\(displayed)</option></select></label></article>")
            defer { fixture.close() }
            let evidence = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
            let page = try ComputerUseBrowserResultPageInput(page: evidence.page)
            let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts. " + clause,
                referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
            let rows: [[String: Any]] = [
                ["turn":0, "source":"Find concerts. ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
                ["turn":0, "source":clause, "role":"condition", "field":kind, "relation":"unspecified", "values":[]]]
            let interpretation = try ComputerUseBrowserGoalProposal.decode(content: ResearchAnswerFixture.json([
                "disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]]), input: goal)
            let article = try XCTUnwrap(evidence.page.containers.first { $0.kind == "article" })
            let title = try XCTUnwrap(evidence.page.texts.first { $0.text == "Concert Alpha" })
            let result = try XCTUnwrap(evidence.page.texts.first { $0.text == displayed })
            let control = try XCTUnwrap(evidence.page.controls.first { $0.kind == "select" })
            for sourceKind in ["controlState", "mixed", "pageText"] {
                let texts = sourceKind == "controlState" ? [] : [result.id]
                let controls = sourceKind == "pageText" ? [] : [control.id]
                let proposal = try ComputerUseBrowserResultProposal.decode(content: ResearchAnswerFixture.json([
                    "candidates":[["container":article.id, "fields":[["kind":"title", "texts":[title.id], "controls":[]],
                        ["kind":kind, "texts":texts, "controls":controls]], "links":[]]]]), input: page, goal: goal)
                let input = try ComputerUseBrowserResultReviewInput(goal: goal, page: page, proposal: proposal, interpretation: interpretation)
                let fieldRows: [[String: Any]] = [["scope":"offer", "price":"notPrice", "qualifiers":[]],
                    ["scope":"offer", "price":kind == "price" ? "exact" : "notPrice", "qualifiers":[]]]
                let requirements: [[String: Any]] = [
                    ["requirement":0, "judgment":"supports", "texts":[title.id]],
                    ["requirement":1, "judgment":"supports", "texts":texts + controls]]
                let content = try ResearchAnswerFixture.json(["candidates":[["association":"singleOffer", "fields":fieldRows, "requirements":requirements]]])
                XCTAssertEqual(input.fieldAllowsResultSupport(candidate: 0, field: 1), sourceKind == "pageText")
                let context = try object(input.contextJSON)
                let contextCandidates = try XCTUnwrap(context["candidates"] as? [[String: Any]])
                let contextFields = try XCTUnwrap(contextCandidates[0]["fields"] as? [[String: Any]])
                XCTAssertEqual(contextFields[1]["source_kind"] as? String, sourceKind)
                XCTAssertEqual(contextFields[1]["result_support_allowed"] as? Bool, sourceKind == "pageText")
                if sourceKind == "pageText" { _ = try ComputerUseBrowserResultReview.decode(content: content, input: input) }
                else { XCTAssertThrowsError(try ComputerUseBrowserResultReview.decode(content: content, input: input), kind + ": " + sourceKind) }
                var unresolved = requirements, contextualFields = fieldRows
                unresolved[1]["judgment"] = "unknown"
                if kind == "price" && sourceKind != "pageText" { contextualFields[1]["price"] = "unknown" }
                let unresolvedReview = try ComputerUseBrowserResultReview.decode(content: ResearchAnswerFixture.json([
                    "candidates":[["association":"singleOffer", "fields":contextualFields, "requirements":unresolved]]]), input: input)
                if ["date", "price"].contains(kind) && sourceKind != "pageText" {
                    let reviewed = try proposal.reviewed(unresolvedReview, goal: goal, interpretation: interpretation)
                    let reading = try await fixture.browser.prepareResultCandidates(reviewed, goal: goal, evidence: evidence, interpretation: interpretation)
                    XCTAssertEqual(reading.requirementAssessment?.candidates[0].requirements[1].status,
                        sourceKind == "mixed" ? .unparsedSelection : .needsResultObservation)
                }

                let parts = try ComputerUseBrowserReviewPart.plan(input)
                var assembly = try ComputerUseBrowserReviewAssembly(input: input, parts: parts)
                for part in parts {
                    let fields = part.fields.map { index -> [String: Any] in var field = fieldRows[index]; field["field"] = index; return field }
                    let reply = try ResearchAnswerFixture.json(["candidate":0, "association":"singleOffer", "fields":fields,
                        "requirements":part.requirements.map { requirements[$0] }])
                    try assembly.append(.decode(reply, part: part))
                }
                if sourceKind == "pageText" { _ = try ComputerUseBrowserResultReview.assemble(assembly) }
                else { XCTAssertThrowsError(try ComputerUseBrowserResultReview.assemble(assembly)) }

                let planner = try ComputerUseLocalBrowserResultReviewPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
                for part in [nil, parts.first] {
                    let request = try planner.makeRequest(input, part: part)
                    let body = try ResearchAnswerFixture.object(XCTUnwrap(request.httpBody))
                    let format = try XCTUnwrap(body["response_format"] as? [String: Any])
                    XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String,
                        part == nil ? "browser_result_review_v5" : "browser_result_review_part_v4")
                }
            }
        }
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

struct ControlStateUnusedTransport: ComputerUseTextModelTransport {
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { throw ComputerUseBrowserResultError.invalidProposal }
    func complete(request: URLRequest) async throws -> Data { throw ComputerUseBrowserResultError.invalidProposal }
}

@MainActor
final class ControlStateFixture {
    let server: OwnedBrowserHTTPFixture
    let browser: ComputerUseOwnedBrowser
    let document: ComputerUseBrowserDocument
    init(body: String, heldSignal: Bool = false, domScriptDidDispatch: ((ComputerUseBrowserDOMCommand) -> Void)? = nil) async throws {
        server = try .init(routes: ["/page":.init(body: "<!doctype html><meta charset=utf-8>" + body), "/signal":.init(held: heldSignal)])
        browser = .init(presentsWindow: false, domScriptDidDispatch: domScriptDidDispatch, mayAct: { true })
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
