import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormPlannerTests: XCTestCase {
    func testPartyChoiceCoverageComparesCountAndNativeChoiceIdentitySeparately() throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        let adultValue = try XCTUnwrap(values.first { $0.unit == "adults" }), childValue = try XCTUnwrap(values.first { $0.unit == "children" })
        func option(_ label: String, disabled: Bool = false, hidden: Bool = false) -> ComputerUseBrowserPageSnapshot.Control.Option {
            .init(id: "native-choice", label: label, value: "private-provider-code", disabled: disabled, hidden: hidden, groupLabel: "Unverified provider category")
        }
        for label in ["2", "02", "two adults", "2 Adults"] { XCTAssertTrue(adultValue.matchesChoice(option(label)), label) }
        for label in ["2 children", "2 people", "2 tickets", "2+", "2 adults aged 12+", "3 adults"] { XCTAssertFalse(adultValue.matchesChoice(option(label)), label) }
        XCTAssertFalse(adultValue.matchesChoice(option("2 adults", disabled: true)))
        XCTAssertFalse(adultValue.matchesChoice(option("2 adults", hidden: true)))
        let total = try XCTUnwrap(values.first(where: \.isPartyTotal))
        XCTAssertTrue(total.matchesChoice(option("3 people")))
        XCTAssertNil(ComputerUseBrowserFormProposal.Payload.normalizedChoice(id: "total-choice", value: total).partyCriterion)
        let tickets = ComputerUseBrowserResearchFormInput.Normalization(id: "tickets", requirementIndex: 1, kind: .ticketCount, value: "2", unit: "tickets")
        XCTAssertTrue(tickets.matchesChoice(option("2 tickets"))); XCTAssertFalse(tickets.matchesChoice(option("2 people")))
        XCTAssertNil(ComputerUseBrowserFormProposal.Payload.normalizedChoice(id: "ticket-choice", value: tickets).partyCriterion)
        let adult = try XCTUnwrap(ComputerUseBrowserFormPartyCriterion(adultValue, selectedChoiceID: "native-adult-choice"))
        let child = try XCTUnwrap(ComputerUseBrowserFormPartyCriterion(childValue, selectedChoiceID: "native-child-choice"))
        XCTAssertEqual(adult.value, "2"); XCTAssertEqual(adult.nativeValue, "native-adult-choice")
        let numeric = try XCTUnwrap(ComputerUseBrowserFormPartyCriterion(adultValue))
        XCTAssertNotEqual(adult.identity, numeric.identity)
        let alternate = try XCTUnwrap(ComputerUseBrowserFormPartyCriterion(adultValue, selectedChoiceID: "other-adult-choice"))
        XCTAssertNotEqual(adult.identity, alternate.identity)
        func coverage(_ native: String, changed: Set<String> = []) -> ComputerUseBrowserFormPartyCoverage? {
            ComputerUseBrowserFormPartyCoverage.collect(normalizations: values, records: ["adult":adult, "child":child],
                values: ["adult":native, "child":"native-child-choice"], changedTargets: changed).first
        }
        XCTAssertEqual(coverage("native-adult-choice")?.allComponentsRecorded, true)
        for native in ["2", "other-adult-choice"] { XCTAssertEqual(coverage(native)?.components.map(\.state), [.changed, .recorded]) }
        XCTAssertEqual(coverage("native-adult-choice", changed: ["adult"])?.components.map(\.state), [.changed, .recorded])
        let publicRecord = adult.context(partyAlias: "party1")
        XCTAssertEqual(Set(publicRecord.keys), ["party", "unit", "value"])
        XCTAssertFalse(try ResearchAnswerFixture.json(publicRecord).contains(adult.nativeValue))
    }

    func testCountLinkedChoiceDecoderRequiresTheObservedOptionAndCompleteNormalization() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category")]
            + ["2", " adults and ", "1", " child. "].map { row($0, field: "quantity") }
            + [row("on 2026-10-17.", field: "date")])
        let body = countChoiceForm() + "<label>Other<input type='number' value='1'></label>"
        let fixture = try await FormPlannerFixture(goal: goal, body: body)
        defer { fixture.close() }
        let input = fixture.input, adult = input.evidence.fields[0], child = input.evidence.fields[1]
        let choice = try XCTUnwrap(adult.control.options.first { $0.label == "2 adults" && !$0.disabled && !$0.hidden })
        let childChoice = try XCTUnwrap(child.control.options.first { $0.label == "1 child" })
        let accepted = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "choice":choice.id, "normalized":"value2-adults"]]), input: input)
        let edit = try XCTUnwrap(accepted.edits.first), contract = try XCTUnwrap(accepted.textContract(for: input))
        XCTAssertTrue(input.hasNormalizedChoices); XCTAssertTrue(contract.steps[0].isChoiceSelection)
        XCTAssertEqual(contract.steps[0].after, choice.id)
        XCTAssertEqual(try accepted.sources(for: edit).flatMap { try $0.indices(in: goal) }, [1, 2])
        XCTAssertEqual(edit.payload.partyCriterion?.nativeValue, choice.id); XCTAssertEqual(edit.payload.partyCriterion?.value, "2")
        let context = try object(Data(input.contextJSON.utf8))
        XCTAssertEqual(context["version"] as? Int, 23); XCTAssertNotNil(context["date_terms"])
        XCTAssertFalse(input.contextJSON.contains("private-adult-two"))
        let request = try local(FormPlannerTransport(content: "{}")).makeRequest(input)
        let requestBody = try object(XCTUnwrap(request.httpBody))
        let format = try XCTUnwrap(requestBody["response_format"] as? [String: Any])
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "browser_form_plan_v18")
        let root = try XCTUnwrap(schema["schema"] as? [String: Any]), alternatives = try XCTUnwrap(root["oneOf"] as? [[String: Any]])
        let properties = try XCTUnwrap(alternatives.first?["properties"] as? [String: Any])
        let editSchema = try XCTUnwrap(properties["edits"] as? [String: Any]), items = try XCTUnwrap(editSchema["items"] as? [String: Any])
        let variants = try XCTUnwrap(items["oneOf"] as? [[String: Any]])
        XCTAssertTrue(variants.contains { Set($0["required"] as? [String] ?? []) == ["field", "choice", "normalized"] })
        let generic = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "choice":choice.id, "requirement":1]]), input: input)
        XCTAssertNil(generic.edits.first?.payload.partyCriterion)
        let invalid: [[String: Any]] = [
            ["field":"field1", "choice":childChoice.id, "normalized":"value2-adults"],
            ["field":"field1", "choice":"private-adult-two", "normalized":"value2-adults"],
            ["field":"field1", "choice":choice.id, "normalized":"value2-children"],
            ["field":"field1", "choice":choice.id, "normalized":"value2-people"],
            ["field":"field1", "choice":choice.id, "normalized":"value6"],
            ["field":"field1", "normalized":"value2-adults"],
            ["field":"field3", "choice":choice.id, "normalized":"value2-adults"],
            ["field":"field1", "choice":choice.id, "normalized":"value2-adults", "requirement":1]]
        for row in invalid { XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([row]), input: input)) }
        for option in adult.control.options where option.disabled || option.hidden {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "choice":option.id, "normalized":"value2-adults"]]), input: input))
        }
    }

    func testNormalizedPassengerChoicesKeepBothCategoriesThroughNativeExecutionAndQuery() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        for ready in [0, 1, 2] {
            var edits = 0
            let fixture = try await FormPlannerFixture(goal: goal, body: countChoiceForm(ready: ready),
                additionalRoutes: ["/results?adults=private-adult-two&children=private-child-one":.init(body: "<p>Preliminary result</p>")],
                domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
            let owner = fixture.owner(journalDirectory: directory)
            defer { owner.retire() }
            _ = try await owner.interpretGoal()
            let input = try await owner.prepareFormInput()
            let adult = try XCTUnwrap(input.evidence.fields[0].control.options.first { $0.label == "2 adults" && !$0.disabled && !$0.hidden })
            let child = try XCTUnwrap(input.evidence.fields[1].control.options.first { $0.label == "1 child" })
            let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([
                ["field":"field1", "choice":adult.id, "normalized":"value2-adults"],
                ["field":"field2", "choice":child.id, "normalized":"value2-children"]]), input: input)
            let receipt = try await owner.executeForm(proposed, input: input)
            let next = try await owner.prepareFormInput(), continuation = try XCTUnwrap(next.previous)
            XCTAssertEqual(receipt.editCount, 2 - ready); XCTAssertEqual(receipt.verifiedWithoutInputCount, ready)
            XCTAssertEqual(edits, 2 - ready); XCTAssertEqual(continuation.inputOperationIDs.count, edits)
            XCTAssertEqual(continuation.stateProofsByTarget.count, ready)
            XCTAssertEqual(continuation.partyCoverage.first?.allComponentsRecorded, true)
            XCTAssertEqual(Set(continuation.partyCriteria.values.map(\.nativeValue)), [adult.id, child.id])
            XCTAssertEqual(Set(continuation.partyCriteria.values.map(\.value)), ["2", "1"])
            let control = try XCTUnwrap(next.evidence.page.page.controls.first { $0.kind == "submit" })
            _ = try await owner.openFormQuery(after: receipt, controlID: control.id, evidence: next.evidence.page)
            XCTAssertEqual(fixture.server.count("/results?adults=private-adult-two&children=private-child-one"), 1)
            XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(owner.input, goal.input)
            let action = try await owner.planNextAction(using: PartyCoverageActionFixture())
            let context = try object(Data(action.input.contextJSON.utf8)), rows = try XCTUnwrap(context["form_history"] as? [[String: Any]])
            let snapshot = try XCTUnwrap(rows.first?["party_criteria_at_stage"] as? [String: Any])
            let party = try XCTUnwrap((snapshot["parties"] as? [[String: Any]])?.first)
            XCTAssertEqual(party["current_native_requirement"] as? String, "same_counts")
            XCTAssertEqual((party["components_at_stage"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["recorded", "recorded"])
            XCTAssertEqual(snapshot["current_field_verification"] as? Bool, false)
        }
    }

    func testChangedCountOptionLabelCannotUseAnEarlierNormalizedChoiceProposal() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let body = countChoiceForm() + "<script>fetch('/signal').then(()=>{document.getElementById('adult-two').textContent='3 adults';fetch('/changed');});</script>"
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: goal, body: body, heldSignal: true,
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let choice = try XCTUnwrap(input.evidence.fields[0].control.options.first { $0.label == "2 adults" && !$0.disabled && !$0.hidden })
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "choice":choice.id, "normalized":"value2-adults"]]), input: input)
        try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { _ = try await owner.executeForm(proposed, input: input); XCTFail("Changed option meaning must invalidate the native proposal") }
        catch { }
        XCTAssertEqual(edits, 0); XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.formPartyHistory.isEmpty)
    }

    private func countChoiceForm(ready: Int = 0) -> String {
        """
        <form action='/results'><label>Adults<select name='adults'><option value='private-adult-one'>1 adult</option>
        <option id='adult-two' value='private-adult-two' \(ready > 0 ? "selected" : "")>2 adults</option>
        <option disabled value='private-disabled-two'>2 adults</option><option hidden value='private-hidden-two'>2 adults</option></select></label>
        <label>Children<select name='children'><option value='private-child-zero'>0 children</option>
        <option value='private-child-one' \(ready > 1 ? "selected" : "")>1 child</option></select></label><button>Search</button></form>
        """
    }

    func testPartyTotalsUseWholeSourceGroupsWithoutCombiningSeparateParties() throws {
        let outcome = row("Find concerts in Montréal. ", role: "outcome", field: "category")
        for (parts, expected) in [(["2", " adults and ", "1", " child."], "3"),
                                  (["0 children and 2 adults."], "2"), (["999 adults and 999 children."], "1998")] {
            let goal = try proposal(rows: [outcome] + parts.map { row($0, field: "quantity") })
            let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
            let total = try XCTUnwrap(values.first(where: \.isPartyTotal))
            XCTAssertEqual(total.value, expected); XCTAssertEqual(total.unit, "people")
            XCTAssertEqual(total.requirementIndices, Array(1...parts.count))
            XCTAssertEqual(Set(values.compactMap(\.partySourceID)).count, 1)
            XCTAssertEqual(values.filter(\.isPartyComponent).count, 2)
            XCTAssertNil(ComputerUseBrowserFormPartyCriterion(total))
            let coverage = ComputerUseBrowserFormPartyCoverage.collect(normalizations: values, records: [:], values: ["total":expected])
            XCTAssertEqual(coverage.first?.components.map(\.state), [.missing, .missing])
            XCTAssertEqual(coverage.first?.allComponentsRecorded, false)
        }
        let separate = try proposal(rows: [outcome, row("2 adults and 1 child. ", field: "quantity"), row("1 adult and 3 children.", field: "quantity")])
        let totals = ComputerUseBrowserResearchFormInput.normalizations(for: separate).filter(\.isPartyTotal)
        XCTAssertEqual(totals.map(\.value), ["3", "4"])
        XCTAssertEqual(totals.map(\.requirementIndices), [[1], [2]])
        XCTAssertEqual(Set(totals.compactMap(\.partySourceID)).count, 2)
        for parts in [["2 adults. ", "1 child."], ["at most 2 adults and 1 child."], ["2 adults and 1 child and 3 adults."]] {
            let goal = try proposal(rows: [outcome] + parts.map { row($0, field: "quantity") })
            XCTAssertFalse(ComputerUseBrowserResearchFormInput.normalizations(for: goal).contains(where: \.isPartyTotal))
        }
    }

    func testAggregatePartySearchKeepsBothCategoryObligationsAfterNavigation() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category")]
            + ["2", " adults and ", "1", " child. "].map { row($0, field: "quantity") }
            + [row("on 2026-10-17.", field: "date")])
        for initial in [1, 3] {
            var edits = 0
            let body = "<form action='/results'><label>People<input type='number' name='people' min='1' max='8' value='\(initial)'></label><button>Search</button></form>"
            let fixture = try await FormPlannerFixture(goal: goal, body: body,
                additionalRoutes: ["/results?people=3":.init(body: "<p>Preliminary search</p>")],
                domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
            let owner = fixture.owner(journalDirectory: directory)
            defer { owner.retire() }
            _ = try await owner.interpretGoal()
            let input = try await owner.prepareFormInput()
            let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-people"]]), input: input)
            let sources = try proposed.sources(for: XCTUnwrap(proposed.edits.first))
            XCTAssertEqual(try sources.flatMap { try $0.indices(in: goal) }, [1, 2, 3, 4])
            let context = try object(Data(input.contextJSON.utf8))
            XCTAssertEqual(context["version"] as? Int, 22); XCTAssertNotNil(context["date_terms"])
            let total = try XCTUnwrap((context["normalized_values"] as? [[String: Any]])?.first { $0["unit"] as? String == "people" })
            XCTAssertEqual(total["requirements"] as? [Int], [1, 2, 3, 4]); XCTAssertEqual(total["party"] as? String, "party1")
            let receipt = try await owner.executeForm(proposed, input: input)
            let next = try await owner.prepareFormInput(), continuation = try XCTUnwrap(next.previous)
            XCTAssertEqual(receipt.editCount, initial == 3 ? 0 : 1)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, initial == 3 ? 1 : 0)
            XCTAssertEqual(edits, receipt.editCount); XCTAssertEqual(Array(continuation.finalValues.values), ["3"])
            XCTAssertTrue(continuation.partyCriteria.isEmpty)
            XCTAssertEqual(continuation.partyCoverage.first?.components.map(\.state), [.missing, .missing])
            XCTAssertEqual(continuation.partyCoverage.first?.allComponentsRecorded, false)
            let control = try XCTUnwrap(next.evidence.page.page.controls.first { $0.kind == "submit" })
            _ = try await owner.openFormQuery(after: receipt, controlID: control.id, evidence: next.evidence.page)
            XCTAssertEqual(fixture.server.count("/results?people=3"), 1)
            XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(owner.input, goal.input)
            let action = try await owner.planNextAction(using: PartyCoverageActionFixture())
            let historyContext = try object(Data(action.input.contextJSON.utf8))
            let history = try XCTUnwrap(historyContext["form_history"] as? [[String: Any]])
            let snapshot = try XCTUnwrap(history.first?["party_criteria_at_stage"] as? [String: Any])
            XCTAssertEqual(snapshot["current_field_verification"] as? Bool, false)
            let party = try XCTUnwrap((snapshot["parties"] as? [[String: Any]])?.first)
            XCTAssertEqual(party["current_native_requirement"] as? String, "same_counts")
            XCTAssertEqual((party["components_at_stage"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["missing", "missing"])
        }
    }

    func testDerivedTotalCannotRetainAnEarlierCategoryRecordWithTheSameNumber() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 0 children.", field: "quantity")])
        // Authored decisions deliberately change the proposed meaning of one
        // field. Exact numeric equality cannot retain the earlier category.
        let fixture = try await FormPlannerFixture(goal: goal, body: "<form action='/results'><label>Count<input type='number' name='count' value='1'></label><button>Search</button></form>")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let first = try await owner.prepareFormInput()
        let adult = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-adults"]]), input: first)
        _ = try await owner.executeForm(adult, input: first)
        let second = try await owner.prepareFormInput()
        XCTAssertEqual(second.previous?.partyCoverage.first?.components.map(\.state), [.recorded, .missing])
        let total = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-people"]]), input: second)
        let receipt = try await owner.executeForm(total, input: second)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        let third = try await owner.prepareFormInput(), continuation = try XCTUnwrap(third.previous)
        XCTAssertTrue(continuation.partyCriteria.isEmpty)
        XCTAssertEqual(continuation.partyCoverage.first?.components.map(\.state), [.missing, .missing])
        XCTAssertEqual(continuation.inputOperationIDs.count, 1); XCTAssertEqual(continuation.stateProofsByTarget.count, 1)
        XCTAssertNotEqual(continuation.digest, second.previous?.digest)
    }

    func testEveryQuestionDecoderRequiresTheWholeIntroducedDateAnswer() async throws {
        for parts in [["on 2026-", "10-16."], ["from 2026-10-16 ", "through 2026-10-18"], ["Fri", "day."]] {
            let (goal, rows) = try introducedScalarGoal(parts: parts)
            let fixture = try await FormPlannerFixture(goal: goal)
            defer { fixture.close() }
            let actionInput = try ComputerUseBrowserActionInput(interpretation: goal, evidence: fixture.input.evidence.page,
                navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
            for topic in ["date", "replaceDate"] {
              for indices in [[1], [2], [1, 2]] {
                let question: [String: Any] = ["topic":topic, "requirements":indices]
                let content = try ResearchAnswerFixture.json(["question":question])
                let goalContent = try ResearchAnswerFixture.json(["disposition":"clarification", "requirements":rows, "question":question])
                if indices.count == 1 {
                    XCTAssertThrowsError(try ComputerUseBrowserGoalProposal.decode(content: goalContent, input: goal.input))
                    XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: content, input: actionInput))
                    XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: fixture.input))
                } else {
                    let ids = indices.map { goal.requirements[$0].id }
                    XCTAssertEqual(try ComputerUseBrowserGoalProposal.decode(content: goalContent, input: goal.input).question?.requirementIDs, ids)
                    XCTAssertEqual(try ComputerUseBrowserActionProposal.decode(content: content, input: actionInput).questionRequest?.requirementIDs, ids)
                    XCTAssertEqual(try ComputerUseBrowserFormProposal.decode(content: content, input: fixture.input).question?.requirementIDs, ids)
                }
              }
            }
        }
    }

    func testExplicitDateReplacementRequiresFreshFormCriteriaBeforeQuerying() async throws {
        try await verifyExplicitDateReplacementRequiresFreshFormCriteria(splitOriginal: false)
    }

    func testRepartitionedOriginalDateStillRequiresFreshFormCriteriaAfterReplacement() async throws {
        try await verifyExplicitDateReplacementRequiresFreshFormCriteria(splitOriginal: true)
    }

    func testNativeDateInputUsesTheAcceptedAnswerClockAfterMidnight() async throws {
        try await verifyDateInputUsesAnswerClock(kind: "date")
    }

    func testTextDateInputSubmitsTheNativeAnswerDateAfterMidnight() async throws {
        try await verifyDateInputUsesAnswerClock(kind: "text")
    }

    private func verifyDateInputUsesAnswerClock(kind: String) async throws {
        let before = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-09T23:59:00Z"))
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-10T00:01:00Z"))
        let original = try ComputerUseBrowserGoalInput(taskID: "form-answer-clock", prompt: "Find flights.", referenceDate: before, timeZoneIdentifier: "UTC")
        let initial = try decodeGoal([row("Find flights.", role: "outcome", field: "category")], input: original)
        var clock = before
        let clarification = ComputerUseBrowserGoalClarification(input: original, now: { clock })
        let context = try ComputerUseBrowserGoalClarification.Context(controllerID: "phone", controllerSessionID: "session", browserSessionDigest: nil)
        let question = try clarification.issue(proposal: initial, topic: .date, requirementIDs: [initial.requirements[0].id], context: context)
        clock = after
        let updated = try clarification.consume(questionID: question.id, answerTaskID: "date", answer: "tomorrow", context: context)
        var answer = row("tomorrow", field: "date"); answer["turn"] = 1
        let goal = try decodeGoal([row("Find flights.", role: "outcome", field: "category"), answer], input: updated)
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: goal,
            body: "<form action='/results'><label>Departure<input name='departure' type='\(kind)'></label><button>Search</button></form>",
            additionalRoutes: ["/results?departure=2026-09-11":.init(body: "<p>Accepted answer date received</p>")],
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let action = try await owner.planNextAction(using: IntroducedDateActionFixture(indices: [1]))
        let input = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(input.normalizations.map(\.value), ["2026-09-11"])
        let modelGoal = try XCTUnwrap(try object(Data(input.contextJSON.utf8))["goal"] as? [String: Any])
        let turns = try XCTUnwrap(modelGoal["clarifications"] as? [[String: Any]])
        let answerClock = try XCTUnwrap(turns[0]["dateContext"] as? [String: Any])
        XCTAssertEqual((answerClock["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, Int64(after.timeIntervalSince1970 * 1_000))
        let proposedEdits: [[String: Any]] = kind == "date" ? [["field":"field1", "normalized":"value2"]] : [["field":"field1", "terms":[["date":"date2"]]]]
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan(proposedEdits), input: input)
        XCTAssertEqual(try proposed.sources(for: XCTUnwrap(proposed.edits.first)).map(\.source), ["tomorrow"])
        let receipt = try await owner.executeForm(proposed, input: input)
        XCTAssertEqual(edits, 1); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(owner.input, updated); XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
        let page = try await owner.observeFormResultPage(after: receipt)
        let query = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" }).id
        _ = try await owner.openFormQuery(after: receipt, controlID: query, evidence: page)
        XCTAssertEqual(fixture.server.count("/results?departure=2026-09-10"), 0)
        XCTAssertEqual(fixture.server.count("/results?departure=2026-09-11"), 1)
    }

    private func verifyExplicitDateReplacementRequiresFreshFormCriteria(splitOriginal: Bool) async throws {
        var rows = [row("Find flights. ", role: "outcome", field: "category"), row("2026-10-16. ", field: "date"), row("Leave Reference unchanged.")]
        let initial = try proposal(rows: rows), goals = DateReplacementGoalFixture(value: initial)
        var edits = 0, queryPreparations = 0
        let fixture = try await FormPlannerFixture(goal: initial,
            body: "<form action='/results'><label>Departure<input name='departure' type='date'></label><label>Reference<input value='private-reference'></label><button>Search</button></form>",
            additionalRoutes: ["/results?departure=2026-10-17":.init(body: "<p>Updated date received</p>")],
            domScriptDidDispatch: { if $0 == .edit { edits += 1 }; if $0 == .prepareFormQuery { queryPreparations += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = ComputerUseBrowserResearchTask(input: initial.input, browser: fixture.browser, goalPlanner: goals,
            resultPlanner: BrowserResearchResultFixture(), navigationJournalDirectory: directory, mayAct: { true })
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let firstAction = try await owner.planNextAction(using: IntroducedDateActionFixture(indices: [1], preservationIndex: 2))
        let first = try await owner.prepareFormInput(for: firstAction)
        let oldPlan = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2"]],
            preserve: [["field":"field2", "requirement":2]]), input: first)
        let oldReceipt = try await owner.executeForm(oldPlan, input: first)
        XCTAssertEqual(edits, 1)
        let question = try owner.issueQuestion(topic: .replaceDate, requirementIDs: [initial.requirements[1].id],
            controllerID: "phone", controllerSessionID: "session")
        let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "new-date", answer: "2026-10-17",
            controllerID: "phone", controllerSessionID: "session")
        var answer = row("2026-10-17", field: "date"); answer["turn"] = 1; rows.append(answer)
        if splitOriginal { rows = [rows[0], row("2026-", field: "location"), row("10-16. ", field: "location"), rows[2], answer] }
        let preservationIndex = splitOriginal ? 3 : 2, replacementIndex = splitOriginal ? 4 : 3
        let retiredIndices = splitOriginal ? [1, 2] : [1]
        let current = try decodeGoal(rows, input: updated); goals.value = current
        _ = try await owner.interpretGoal()
        let oldPage = try await owner.observeFormResultPage(after: oldReceipt)
        let control = try XCTUnwrap(oldPage.page.controls.first { $0.kind == "submit" }).id
        do { _ = try await owner.prepareFormQuery(after: oldReceipt, controlID: control, evidence: oldPage); XCTFail("The old date is no longer a current criterion") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .inputChanged) }
        do { _ = try await owner.openFormQuery(after: oldReceipt, controlID: control, evidence: oldPage); XCTFail("A native receipt cannot authorize the superseded date") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .inputChanged) }
        XCTAssertEqual(queryPreparations, 0); XCTAssertEqual(edits, 1)
        XCTAssertEqual(owner.confirmedFormHistory, [oldReceipt])
        let action = try await owner.planNextAction(using: IntroducedDateActionFixture(indices: [replacementIndex], preservationIndex: preservationIndex))
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        XCTAssertTrue(Set(retiredIndices).isDisjoint(with: action.input.readableRequirementIndices))
        XCTAssertTrue(Set(retiredIndices).isDisjoint(with: action.input.effectFieldRequirementIndices))
        let actionContext = try object(Data(action.input.contextJSON.utf8))
        XCTAssertEqual(actionContext["version"] as? Int, 30)
        XCTAssertEqual(actionContext["retired_task_purpose_requirements"] as? [Int], retiredIndices)
        let prepared = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(prepared.requiredRepairFieldAliases, ["field1"])
        XCTAssertEqual(prepared.requiredPreservation.count, 1)
        XCTAssertEqual(prepared.normalizations.map(\.value), ["2026-10-17"])
        XCTAssertEqual(try object(Data(prepared.contextJSON.utf8))["version"] as? Int, 21)
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2"]],
            preserve: [["field":"field2", "requirement":preservationIndex]]), input: prepared))
        let newPlan = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value\(replacementIndex + 1)"]],
            preserve: [["field":"field2", "requirement":preservationIndex]]), input: prepared)
        let newReceipt = try await owner.executeForm(newPlan, input: prepared)
        XCTAssertEqual(edits, 2); XCTAssertEqual(owner.confirmedFormHistory, [oldReceipt, newReceipt])
        let page = try await owner.observeFormResultPage(after: newReceipt)
        let query = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" }).id
        _ = try await owner.openFormQuery(after: newReceipt, controlID: query, evidence: page)
        XCTAssertEqual(fixture.server.count("/results?departure=2026-10-16"), 0)
        XCTAssertEqual(fixture.server.count("/results?departure=2026-10-17"), 1)
        XCTAssertEqual(owner.input.userTurns, [initial.input.prompt, "2026-10-17"])
    }

    func testSharedQuestionAdmissionRetainsNativeMissingQuantityUnitsAfterRelabeling() async throws {
        let (goal, rows) = try introducedScalarGoal(parts: ["2"], topic: .quantity)
        let fixture = try await FormPlannerFixture(goal: goal)
        defer { fixture.close() }
        let actionInput = try ComputerUseBrowserActionInput(interpretation: goal, evidence: fixture.input.evidence.page,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
        let question: [String: Any] = ["topic":"quantity", "requirements":[1]]
        let content = try ResearchAnswerFixture.json(["question":question])
        let goalContent = try ResearchAnswerFixture.json(["disposition":"clarification", "requirements":rows, "question":question])
        let ids = [goal.requirements[1].id]
        XCTAssertEqual(try ComputerUseBrowserGoalProposal.decode(content: goalContent, input: goal.input).question?.requirementIDs, ids)
        XCTAssertEqual(try ComputerUseBrowserActionProposal.decode(content: content, input: actionInput).questionRequest?.requirementIDs, ids)
        XCTAssertEqual(try ComputerUseBrowserFormProposal.decode(content: content, input: fixture.input).question?.requirementIDs, ids)
        XCTAssertTrue(ComputerUseBrowserResearchFormInput.normalizations(for: goal).isEmpty)
    }

    func testIntroducedDateNormalizationRequiresEveryReviewedSourceAndKeepsNativeProvenance() async throws {
        try await verifyIntroducedDateSourceProvenance(kind: "date")
    }

    func testTextDateTermsRequireEveryReviewedSourceAndKeepNativeProvenance() async throws {
        try await verifyIntroducedDateSourceProvenance(kind: "text")
    }

    private func verifyIntroducedDateSourceProvenance(kind: String) async throws {
        let (goal, _) = try introducedScalarGoal(parts: ["on 2026-", "10-16."])
        for indices in [[1], [2], [1, 2]] {
            var edits = 0
            let fixture = try await FormPlannerFixture(goal: goal,
                body: "<form action='/results'><label>Departure<input name='departure' type='\(kind)'></label><button>Search</button></form>",
                domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
            let owner = fixture.owner(journalDirectory: directory)
            defer { owner.retire() }
            _ = try await owner.interpretGoal()
            let action = try await owner.planNextAction(using: IntroducedDateActionFixture(indices: indices))
            let input = try await owner.prepareFormInput(for: action)
            XCTAssertEqual(input.fieldIntentRequirements["field1"], indices)
            XCTAssertEqual(input.normalizations.count, 1)
            XCTAssertEqual(input.normalizations.first?.requirementIndices, [1, 2])
            let context = try object(Data(input.contextJSON.utf8))
            let normalized = try XCTUnwrap(context["normalized_values"] as? [[String: Any]])
            XCTAssertEqual(normalized.first?["requirements"] as? [Int], [1, 2])
            let proposedEdits: [[String: Any]] = kind == "date" ? [["field":"field1", "normalized":"value2"]] : [["field":"field1", "terms":[["date":"date2"]]]]
            let content = try plan(proposedEdits)
            if indices.count == 1 {
                XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: input))
                XCTAssertEqual(edits, 0)
            } else {
                let proposed = try ComputerUseBrowserFormProposal.decode(content: content, input: input)
                let sources = try proposed.sources(for: XCTUnwrap(proposed.edits.first))
                XCTAssertEqual(try sources.flatMap { try $0.indices(in: goal) }, [1, 2])
                XCTAssertEqual(sources.map(\.source), ["on 2026-", "10-16."])
                _ = try await owner.executeForm(proposed, input: input)
                XCTAssertEqual(edits, 1); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            }
            XCTAssertEqual(owner.input, goal.input)
            XCTAssertEqual(fixture.server.count("/results?departure=2026-10-16"), 0)
        }
    }

    func testDateTextTermsPreserveBoundsAndRejectIncompatibleFieldKinds() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("before tomorrow.", field: "date")])
        for kind in ["text", "search", "textarea", "url", "email", "tel", "date", "number"] {
            let control = kind == "textarea" ? "<textarea name='date'></textarea>" : "<input name='date' type='\(kind)'>"
            let fixture = try await FormPlannerFixture(goal: goal, body: "<form><label>Departure\(control)</label><button>Search</button></form>")
            defer { fixture.close() }
            let input = fixture.input
            let content = try plan([["field":"field1", "terms":[["date":"date2"]]]])
            if ["text", "search", "textarea"].contains(kind) {
                let proposed = try ComputerUseBrowserFormProposal.decode(content: content, input: input)
                let contract = try XCTUnwrap(proposed.textContract(for: input))
                XCTAssertEqual(contract.steps.map(\.after), ["before 2026-03-08"])
                let request = try local(FormPlannerTransport(content: content)).makeRequest(input)
                let body = try object(XCTUnwrap(request.httpBody)), format = try XCTUnwrap(body["response_format"] as? [String: Any])
                XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_form_plan_v17")
                XCTAssertEqual(try object(Data(input.contextJSON.utf8))["version"] as? Int, 21)
            } else { XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: input)) }
            for source in ["tomorrow", "before tomorrow."] {
                XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "terms":[["requirement":1, "text":source]]]]), input: input))
            }
            XCTAssertEqual(fixture.server.count("/results"), 0)
        }
    }

    private func introducedScalarGoal(parts: [String], topic: ComputerUseBrowserClarificationTopic = .date) throws -> (ComputerUseBrowserGoalProposal, [[String: Any]]) {
        let initial = try proposal(rows: [row("Find flights.", role: "outcome", field: "category")])
        let state = ComputerUseBrowserGoalClarification(input: initial.input)
        let context = try ComputerUseBrowserGoalClarification.Context(controllerID: "phone", controllerSessionID: "session",
            browserSessionDigest: String(repeating: "a", count: 64))
        let question = try state.issue(proposal: initial, topic: topic, requirementIDs: [initial.requirements[0].id], context: context)
        let updated = try state.consume(questionID: question.id, answerTaskID: "date-answer", answer: parts.joined(), context: context)
        let rows = [row(initial.input.prompt, role: "outcome", field: "category")] + parts.map { source -> [String: Any] in
            var value = row(source, field: "location"); value["turn"] = 1; return value
        }
        return (try decodeGoal(rows, input: updated), rows)
    }

    func testPartyIdentitySurvivesSourceRepartitionButDoesNotCrossTaskRoots() throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let original = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        let identity = try XCTUnwrap(original.first?.partySourceID)
        for parts in [["2 adults and ", "1 child."], ["2", " adults and ", "1", " child."], ["2 ad", "ults and 1 ch", "ild."]] {
            let repartitioned = try decodeGoal([row("Find concerts. ", role: "outcome", field: "category")]
                + parts.map { row($0, field: "quantity") }, input: goal.input)
            let current = ComputerUseBrowserResearchFormInput.normalizations(for: repartitioned)
            XCTAssertEqual(current.map(\.partySourceID), [identity, identity, identity])
            XCTAssertEqual(current.map(\.value), original.map(\.value))
        }
        let foreignInput = try ComputerUseBrowserGoalInput(taskID: "another-party-task", prompt: goal.input.userTurns[0],
            referenceDate: XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z")), timeZoneIdentifier: "America/Los_Angeles")
        let foreign = try decodeGoal([row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")], input: foreignInput)
        XCTAssertNotEqual(ComputerUseBrowserResearchFormInput.normalizations(for: foreign).first?.partySourceID, identity)
    }

    func testPartyCoverageRequiresDistinctCompletedComponentsAndCurrentValues() throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        let adult = try XCTUnwrap(ComputerUseBrowserFormPartyCriterion(XCTUnwrap(values.first { $0.unit == "adults" })))
        let child = try XCTUnwrap(ComputerUseBrowserFormPartyCriterion(XCTUnwrap(values.first { $0.unit == "children" })))
        func coverage(_ records: [String: ComputerUseBrowserFormPartyCriterion], _ current: [String: String], changed: Set<String> = []) throws -> ComputerUseBrowserFormPartyCoverage {
            try XCTUnwrap(ComputerUseBrowserFormPartyCoverage.collect(normalizations: values, records: records, values: current, changedTargets: changed).first)
        }
        let unverified = try coverage([:], ["adult":"2", "child":"1"])
        XCTAssertEqual(unverified.components.map(\.state), [.missing, .missing]); XCTAssertFalse(unverified.allComponentsRecorded)
        let partial = try coverage(["adult":adult], ["adult":"2", "child":"1"])
        XCTAssertEqual(partial.components.map(\.state), [.recorded, .missing]); XCTAssertFalse(partial.allComponentsRecorded)
        let complete = try coverage(["adult":adult, "child":child], ["adult":"2", "child":"1"])
        XCTAssertTrue(complete.allComponentsRecorded)
        let duplicate = try coverage(["adult":adult, "secondAdult":adult, "child":child], ["adult":"2", "secondAdult":"2", "child":"1"])
        XCTAssertEqual(duplicate.components.map(\.state), [.ambiguous, .recorded]); XCTAssertFalse(duplicate.allComponentsRecorded)
        for current in [["adult":"2", "child":"0"], ["adult":"2"], ["adult":"2", "child":"01"]] {
            XCTAssertEqual(try coverage(["adult":adult, "child":child], current).components.map(\.state), [.recorded, .changed])
        }
        XCTAssertEqual(try coverage(["adult":adult, "child":child], ["adult":"2", "child":"1"], changed: ["child"]).components.map(\.state), [.recorded, .changed])
        let foreign = try proposal(rows: [row("Find movies. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let foreignValues = ComputerUseBrowserResearchFormInput.normalizations(for: foreign)
        let crossTask = ComputerUseBrowserFormPartyCoverage.collect(normalizations: foreignValues, records: ["adult":adult, "child":child], values: ["adult":"2", "child":"1"])
        XCTAssertEqual(crossTask.first?.components.map(\.state), [.missing, .missing])
        XCTAssertFalse(String(describing: adult).contains(adult.partySourceID))
    }

    func testCompletedAdultStageLeavesMatchingChildDefaultMissingUntilVerified() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 1))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let first = try await owner.prepareFormInput()
        let initialContext = try object(Data(first.contextJSON.utf8))
        XCTAssertEqual(initialContext["version"] as? Int, 22)
        let initialCoverage = try XCTUnwrap(initialContext["party_criteria"] as? [[String: Any]])
        XCTAssertEqual(initialCoverage.first?["party"] as? String, "party1")
        let normalizedContext = try XCTUnwrap(initialContext["normalized_values"] as? [[String: Any]])
        XCTAssertEqual(normalizedContext.compactMap { $0["party"] as? String }, ["party1", "party1", "party1"])
        XCTAssertEqual((initialCoverage.first?["components"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["missing", "missing"])
        let adultPlan = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-adults"]]), input: first)
        let adultReceipt = try await owner.executeForm(adultPlan, input: first)
        XCTAssertTrue(adultReceipt.isCompleteStage); XCTAssertEqual(adultReceipt.editCount, 1)
        let action = try await owner.planNextAction(using: PartyCoverageActionFixture())
        let actionContext = try object(Data(action.input.contextJSON.utf8))
        XCTAssertEqual(actionContext["version"] as? Int, 25)
        let stage = try XCTUnwrap(actionContext["verified_form_stage"] as? [String: Any])
        XCTAssertEqual(stage["complete_stage"] as? Bool, true)
        let actionCoverage = try XCTUnwrap(stage["party_criteria"] as? [[String: Any]])
        XCTAssertEqual(actionCoverage.first?["all_components_recorded"] as? Bool, false)
        XCTAssertEqual((actionCoverage.first?["components"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["recorded", "missing"])
        let actionEdits = try XCTUnwrap(stage["edits"] as? [[String: Any]])
        XCTAssertEqual((actionEdits.first?["party_component"] as? [String: Any])?["unit"] as? String, "adults")
        XCTAssertEqual((actionEdits.first?["party_component"] as? [String: Any])?["party"] as? String, "party1")
        let second = try await owner.prepareFormInput(), prior = try XCTUnwrap(second.previous)
        XCTAssertEqual(prior.partyCoverage.first?.components.map(\.state), [.recorded, .missing])
        XCTAssertEqual(prior.partyCriteria.count, 1)
        for identity in first.normalizations.compactMap(\.partySourceID) + Array(prior.partyCriteria.keys) {
            XCTAssertFalse(first.contextJSON.contains(identity)); XCTAssertFalse(second.contextJSON.contains(identity))
            XCTAssertFalse(action.input.contextJSON.contains(identity))
        }
        let context = try object(Data(second.contextJSON.utf8))
        let previous = try XCTUnwrap(context["previous_edits"] as? [[String: Any]])
        XCTAssertEqual((previous.first?["party_component"] as? [String: Any])?["unit"] as? String, "adults")
        let childPlan = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field2", "normalized":"value2-children"]]), input: second)
        let childReceipt = try await owner.executeForm(childPlan, input: second)
        XCTAssertEqual(childReceipt.editCount, 0); XCTAssertEqual(childReceipt.verifiedWithoutInputCount, 1)
        let third = try await owner.prepareFormInput(), complete = try XCTUnwrap(third.previous)
        XCTAssertEqual(complete.partyCoverage.first?.allComponentsRecorded, true)
        XCTAssertEqual(complete.partyCriteria.count, 2); XCTAssertEqual(complete.stageIDs.count, 2)
        XCTAssertEqual(complete.inputOperationIDs.count, 1); XCTAssertEqual(complete.stateProofsByTarget.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory, [adultReceipt, childReceipt])
        XCTAssertEqual(owner.formPartyHistory.count, 2)
        XCTAssertEqual(owner.formPartyHistory[0].parties.first?.components.map(\.state), [.recorded, .missing])
        XCTAssertEqual(owner.formPartyHistory[1].parties.first?.components.map(\.state), [.recorded, .recorded])
    }

    func testPartyRecordsUseBothObservationAndMixedNativeCompletionOrigins() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        for children in [0, 1] {
            var edits = 0
            let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 2, children: children),
                domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
            let owner = fixture.owner(journalDirectory: directory)
            defer { owner.retire() }
            _ = try await owner.interpretGoal()
            let input = try await owner.prepareFormInput()
            let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([
                ["field":"field1", "normalized":"value2-adults"], ["field":"field2", "normalized":"value2-children"]]), input: input)
            let receipt = try await owner.executeForm(proposed, input: input)
            let next = try await owner.prepareFormInput(), continuation = try XCTUnwrap(next.previous)
            XCTAssertEqual(receipt.editCount, children == 0 ? 1 : 0)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, children == 0 ? 1 : 2)
            XCTAssertEqual(edits, receipt.editCount); XCTAssertEqual(continuation.inputOperationIDs.count, edits)
            XCTAssertEqual(continuation.stateProofsByTarget.count, receipt.verifiedWithoutInputCount)
            XCTAssertEqual(continuation.partyCoverage.first?.allComponentsRecorded, true)
            let context = try object(Data(next.contextJSON.utf8)), criteria = try XCTUnwrap(context["previous_criteria"] as? [[String: Any]])
            XCTAssertEqual(criteria.compactMap { ($0["party_component"] as? [String: Any])?["unit"] as? String }, ["adults", "children"])
        }
    }

    func testNewCriterionPurposeCannotInheritAnEarlierPartyComponentWithTheSameNumber() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"),
            row("2 adults and 1 child. ", field: "quantity"), row("2 tickets.", field: "quantity")])
        // The selector's proposed meaning is not native provider semantics.
        // This fixture exercises invalidation when a later plan changes that purpose.
        let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 0))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let first = try await owner.prepareFormInput()
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([
            ["field":"field1", "normalized":"value2-adults"], ["field":"field2", "normalized":"value2-children"]]), input: first)
        _ = try await owner.executeForm(proposed, input: first)
        let second = try await owner.prepareFormInput()
        XCTAssertEqual(second.previous?.partyCoverage.first?.allComponentsRecorded, true)
        let replacement = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value3"]]), input: second)
        let receipt = try await owner.executeForm(replacement, input: second)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        let third = try await owner.prepareFormInput(), continuation = try XCTUnwrap(third.previous)
        XCTAssertEqual(continuation.partyCoverage.first?.components.map(\.state), [.missing, .recorded])
        XCTAssertEqual(continuation.partyCriteria.count, 1)
        XCTAssertEqual(continuation.inputOperationIDs.count, 2)
        XCTAssertNotEqual(continuation.digest, second.previous?.digest)
    }

    func testPartialPartyQueryRemainsExploratoryAndDoesNotInventChildVerification() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 0),
            additionalRoutes: ["/results?adults=2&children=0":.init(body: "<p>Preliminary search</p>")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-adults"]]), input: input)
        let receipt = try await owner.executeForm(proposed, input: input)
        let next = try await owner.prepareFormInput()
        XCTAssertEqual(next.previous?.partyCoverage.first?.components.map(\.state), [.recorded, .missing])
        let control = try XCTUnwrap(next.evidence.page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: receipt, controlID: control.id, evidence: next.evidence.page)
        XCTAssertEqual(fixture.server.count("/results?adults=2&children=0"), 1)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(owner.input, goal.input)
        XCTAssertEqual(next.previous?.partyCoverage.first?.allComponentsRecorded, false)
        let action = try await owner.planNextAction(using: PartyCoverageActionFixture())
        XCTAssertTrue(action.input.usesFormPartyHistoryContext); XCTAssertTrue(action.input.needsPlanningDecision)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty); XCTAssertNil(action.input.queryReceipt)
        let context = try object(Data(action.input.contextJSON.utf8))
        XCTAssertEqual(context["version"] as? Int, 25); XCTAssertTrue(context["verified_form_stage"] is NSNull)
        let history = try XCTUnwrap(context["form_history"] as? [[String: Any]])
        let snapshot = try XCTUnwrap(history.first?["party_criteria_at_stage"] as? [String: Any])
        XCTAssertEqual(snapshot["historical"] as? Bool, true); XCTAssertEqual(snapshot["current_field_verification"] as? Bool, false)
        let parties = try XCTUnwrap(snapshot["parties"] as? [[String: Any]])
        XCTAssertEqual(parties.first?["party"] as? String, "party1")
        XCTAssertEqual(parties.first?["current_native_requirement"] as? String, "same_counts")
        XCTAssertEqual((parties.first?["components_at_stage"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["recorded", "missing"])
        let native = try XCTUnwrap(owner.formPartyHistory.first)
        XCTAssertFalse(action.input.contextJSON.contains(native.continuationDigest))
        XCTAssertFalse(action.input.contextJSON.contains(native.sessionIdentity))
        for source in native.parties.map(\.sourceID) { XCTAssertFalse(action.input.contextJSON.contains(source)) }
        XCTAssertTrue(ComputerUseLocalBrowserActionPlanner.instructions(for: action.input).contains("party_criteria_at_stage"))
    }

    func testPartyHistorySurvivesIdenticalNewFormWithoutTransferringFieldVerification() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 0),
            additionalRoutes: ["/results?adults=2&children=0":.init(body: partyForm(adults: 2, children: 1))])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let first = try await owner.prepareFormInput()
        let firstPlan = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-adults"]]), input: first)
        let firstReceipt = try await owner.executeForm(firstPlan, input: first)
        let page = try await owner.observeFormResultPage(after: firstReceipt)
        let control = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: firstReceipt, controlID: control.id, evidence: page)
        let second = try await owner.prepareFormInput()
        XCTAssertNil(second.previous); XCTAssertNotEqual(first.evidence.page.document, second.evidence.page.document)
        XCTAssertEqual(owner.formPartyHistory.count, 1)
        let context = try object(Data(second.contextJSON.utf8)), parties = try XCTUnwrap(context["party_criteria"] as? [[String: Any]])
        XCTAssertEqual((parties.first?["components"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["missing", "missing"])
        let secondPlan = try ComputerUseBrowserFormProposal.decode(content: plan([
            ["field":"field1", "normalized":"value2-adults"], ["field":"field2", "normalized":"value2-children"]]), input: second)
        let secondReceipt = try await owner.executeForm(secondPlan, input: second)
        XCTAssertEqual(secondReceipt.editCount, 0); XCTAssertEqual(secondReceipt.verifiedWithoutInputCount, 2)
        let third = try await owner.prepareFormInput(), continuation = try XCTUnwrap(third.previous)
        XCTAssertEqual(continuation.stageIDs, [secondReceipt.stageID]); XCTAssertTrue(continuation.inputOperationIDs.isEmpty)
        XCTAssertEqual(continuation.partyCoverage.first?.allComponentsRecorded, true)
        XCTAssertEqual(owner.formPartyHistory.map(\.receipt), [firstReceipt, secondReceipt])
        XCTAssertEqual(owner.formPartyHistory[0].parties.first?.components.map(\.state), [.recorded, .missing])
        XCTAssertEqual(owner.formPartyHistory[1].parties.first?.components.map(\.state), [.recorded, .recorded])
        owner.retire()
        XCTAssertTrue(owner.formPartyHistory.isEmpty)
    }

    func testPartyHistoryRejectsForeignSessionsMissingReceiptsAndDuplicateSnapshots() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 0))
        let other = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 0))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); other.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-adults"]]), input: input)
        let receipt = try await owner.executeForm(proposed, input: input), history = try XCTUnwrap(owner.formPartyHistory.first)
        XCTAssertThrowsError(try ComputerUseBrowserActionInput(interpretation: goal, evidence: other.input.evidence.page,
            navigationHistory: [], formHistory: [receipt], latestForm: nil, changedFormTargetIDs: [], formPartyHistory: [history]))
        for receipts: [ComputerUseBrowserResearchFormReceipt] in [[], [receipt]] {
            let snapshots = receipts.isEmpty ? [history] : [history, history]
            XCTAssertThrowsError(try ComputerUseBrowserActionInput(interpretation: goal, evidence: input.evidence.page,
                navigationHistory: [], formHistory: receipts, latestForm: nil, changedFormTargetIDs: [], formPartyHistory: snapshots))
        }
    }

    func testHistoricalPartySnapshotKeepsItsCountsWhenARepartitionedAnswerBecomesUnresolved() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"), row("2 adults and 1 child.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal, body: partyForm(adults: 1, children: 0))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "normalized":"value2-adults"]]), input: input)
        let receipt = try await owner.executeForm(proposed, input: input), snapshot = try XCTUnwrap(owner.formPartyHistory.first)
        for answer in ["2 adults", "3 adults"] {
            let state = ComputerUseBrowserGoalClarification(input: goal.input)
            let scope = try ComputerUseBrowserGoalClarification.Context(controllerID: "fixture-controller", controllerSessionID: "fixture-session",
                browserSessionDigest: String(repeating: "a", count: 64))
            let question = try state.issue(proposal: goal, topic: .quantity, requirementIDs: [goal.requirements[1].id], context: scope)
            let revised = try state.consume(questionID: question.id, answerTaskID: "party-answer", answer: answer, context: scope)
            var answerRow = row(answer, field: "quantity"); answerRow["turn"] = 1
            let current = try decodeGoal([row("Find concerts. ", role: "outcome", field: "category")]
                + ["2", " adults and ", "1", " child."].map { row($0, role: "prohibition", field: "navigationSource") }
                + [answerRow], input: revised)
            let action = try ComputerUseBrowserActionInput(interpretation: current, evidence: input.evidence.page,
                navigationHistory: [], formHistory: [receipt], latestForm: nil, changedFormTargetIDs: [], formPartyHistory: [snapshot])
            let context = try object(Data(action.contextJSON.utf8)), rows = try XCTUnwrap(context["form_history"] as? [[String: Any]])
            XCTAssertEqual(rows.first?["current_goal_revision"] as? Bool, false)
            let recorded = try XCTUnwrap(rows.first?["party_criteria_at_stage"] as? [String: Any])
            XCTAssertEqual(recorded["accepted_answer_count_at_stage"] as? Int, 0)
            let parties = try XCTUnwrap(recorded["parties"] as? [[String: Any]])
            XCTAssertEqual(parties.first?["current_native_requirement"] as? String, answer == "2 adults" ? "same_counts" : "unresolved")
            let components = try XCTUnwrap(parties.first?["components_at_stage"] as? [[String: Any]])
            XCTAssertEqual(components.compactMap { $0["value"] as? String }, ["2", "1"])
            XCTAssertEqual(components.compactMap { $0["state"] as? String }, ["recorded", "missing"])
            let sources = try XCTUnwrap(parties.first?["sources"] as? [[String: Any]])
            XCTAssertEqual(sources.first?["requirements"] as? [Int], [1, 2, 3, 4])
            XCTAssertTrue(context["verified_form_stage"] is NSNull)
        }
        XCTAssertEqual(owner.formPartyHistory, [snapshot])
    }

    private func partyForm(adults: Int, children: Int) -> String {
        """
        <form action='/results'><label>Adults<input type='number' name='adults' min='1' max='8' value='\(adults)'></label>
        <label>Children<input type='number' name='children' min='0' max='8' value='\(children)'></label><button>Search</button></form>
        """
    }

    func testSplitPartyNormalizationsIdentifyEveryCountAndUnitSourceRow() throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category")]
            + ["2", " adults and ", "1", " child."].map { row($0, field: "quantity") })
        let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        XCTAssertEqual(values.map(\.id), ["value2-adults", "value2-children", "value2-people"])
        XCTAssertEqual(values.map(\.requirementIndex), [1, 3, 1])
        XCTAssertEqual(values.map(\.requirementIndices), [[1, 2], [3, 4], [1, 2, 3, 4]])
        XCTAssertEqual(values.map(\.value), ["2", "1", "3"])
        XCTAssertEqual(values.map(\.unit), ["adults", "children", "people"])
    }

    func testSplitPartySourcesReachNativeFormProvenanceAndOneQuery() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category")]
            + ["2", " adults and ", "1", " child."].map { row($0, field: "quantity") })
        let body = """
        <form action='/results'><label>Adults<input type='number' name='adults' min='1' max='8' value='1'></label>
        <label>Children<input type='number' name='children' min='0' max='8' value='0'></label><button>Search</button></form>
        """
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: goal, body: body,
            additionalRoutes: ["/results?adults=2&children=1":.init(body: "<p>Search received</p>")],
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let content = try plan([["field":"field1", "normalized":"value2-adults"], ["field":"field2", "normalized":"value2-children"]])
        let proposed = try await owner.planForm(input, using: local(FormPlannerTransport(content: content)))
        let context = try object(Data(input.contextJSON.utf8))
        XCTAssertEqual(context["version"] as? Int, 22)
        let normalized = try XCTUnwrap(context["normalized_values"] as? [[String: Any]])
        XCTAssertEqual(normalized.map { $0["requirements"] as? [Int] }, [[1, 2], [3, 4], [1, 2, 3, 4]])
        for (index, expected) in [[1, 2], [3, 4]].enumerated() {
            let sources = try proposed.sources(for: proposed.edits[index])
            XCTAssertEqual(try sources.flatMap { try $0.indices(in: goal) }, expected)
            XCTAssertEqual(sources.map(\.source), expected.compactMap { goal.source(of: goal.requirements[$0]) })
        }
        XCTAssertEqual(edits, 0)
        let receipt = try await owner.executeForm(proposed, input: input)
        let page = try await owner.observeFormResultPage(after: receipt), control = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" }).id
        _ = try await owner.openFormQuery(after: receipt, controlID: control, evidence: page)
        XCTAssertEqual(edits, 2); XCTAssertEqual(fixture.server.count("/results?adults=2&children=1"), 1)
        XCTAssertEqual(owner.input, goal.input)
    }
    func testMixedPartyNormalizationsHaveSeparateStableUnitsUnderOneRequirement() throws {
        for source in ["2 adults and 1 child. ", "1 child and 2 adults. "] {
            let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"),
                row(source, field: "quantity"), row("3 options.", field: "quantity")])
            let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
            XCTAssertEqual(values.map(\.id), ["value2-adults", "value2-children", "value2-people"])
            XCTAssertEqual(values.map(\.requirementIndex), [1, 1, 1])
            XCTAssertEqual(values.map(\.kind), [.partySize, .partySize, .partySize])
            XCTAssertEqual(values.map(\.unit), ["adults", "children", "people"])
            XCTAssertEqual(values.map(\.value), ["2", "1", "3"])
        }
    }

    func testMixedPartyCountsReachBothNativeFieldsAndOneVerifiedQuery() async throws {
        let goal = try proposal(rows: [row("Find concert options. ", role: "outcome", field: "category"),
            row("two adults and one child. ", field: "quantity"), row("three options.", field: "quantity")])
        let body = """
        <form action='/results'><label>Adults<input type='number' name='adults' min='1' max='8' value='1'></label>
        <label>Children<input type='number' name='children' min='0' max='8' value='0'></label><button>Search</button></form>
        """
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: goal, body: body,
            additionalRoutes: ["/results?adults=2&children=1":.init(body: "<p>Search received</p>")],
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let content = try plan([["field":"field1", "normalized":"value2-adults"], ["field":"field2", "normalized":"value2-children"]])
        let proposed = try await owner.planForm(input, using: local(FormPlannerTransport(content: content)))
        XCTAssertEqual(input.normalizations.map(\.requirementIndex), [1, 1, 1])
        XCTAssertEqual(input.normalizations.map(\.value), ["2", "1", "3"])
        XCTAssertEqual(edits, 0)
        let receipt = try await owner.executeForm(proposed, input: input)
        let page = try await owner.observeFormResultPage(after: receipt), control = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" }).id
        let first = try await owner.openFormQuery(after: receipt, controlID: control, evidence: page)
        let repeated = try await owner.openFormQuery(after: receipt, controlID: control, evidence: page)
        XCTAssertEqual(first, repeated); XCTAssertEqual(edits, 2)
        XCTAssertEqual(fixture.server.count("/results?adults=2&children=1"), 1)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(owner.input, goal.input)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.formQuery])
    }

    func testCarriedPreservationRejectsConflictingReferencesAndCannotBecomeAnEdit() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal(preserveReference: true))
        defer { fixture.close() }
        let original = fixture.input, field = original.evidence.fields[5]
        let required = ComputerUseBrowserControlPreservation(controlID: field.control.id, requirementIndex: 7)
        let input = try ComputerUseBrowserResearchFormInput(interpretation: original.interpretation, evidence: original.evidence,
            selectedFormID: XCTUnwrap(field.control.form?.id), preservedControls: [required])
        XCTAssertFalse(input.editableFieldAliases.contains("field6"))
        let edits: [[String: Any]] = [["field":"field2","terms":[["requirement":2,"text":"Paris"]]]]
        let omitted = try ComputerUseBrowserFormProposal.decode(content: plan(edits), input: input)
        let repeated = try ComputerUseBrowserFormProposal.decode(content: plan(edits, preserve: [["field":"field6","requirement":7]]), input: input)
        XCTAssertEqual(omitted, repeated); XCTAssertEqual(omitted.preserved, input.requiredPreservation)
        for rows: [[String: Any]] in [[["field":"field6","requirement":0]], [["field":"field6","requirement":6]]] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan(edits, preserve: rows), input: input))
        }
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field6","terms":[["requirement":2,"text":"Paris"]]]]), input: input))
        for references in [[required, required], [.init(controlID: "missing", requirementIndex: 7)], [.init(controlID: field.control.id, requirementIndex: 99)]] {
            XCTAssertThrowsError(try ComputerUseBrowserResearchFormInput(interpretation: original.interpretation, evidence: original.evidence,
                selectedFormID: field.control.form?.id, preservedControls: references))
        }
        let contract = try XCTUnwrap(omitted.textContract(for: input))
        XCTAssertEqual(contract.unchangedValues, [field.editable.snapshot.targetID:"private-reference"])
    }

    func testNormalizationsSeparateExactPartyCountsFromResultCountsBoundsAndRanges() throws {
        let goal = try proposal(rows: [row("Find flights. ", role: "outcome"), row("tomorrow. ", field: "date"),
            row("for two people. ", field: "quantity"), row("three adults. ", field: "quantity"), row("0 children. ", field: "quantity"),
            row("three options. ", field: "quantity"), row("two tickets. ", field: "quantity"),
            row("at most four people. ", field: "quantity"), row("after tomorrow. ", field: "date"),
            row("from 2026-03-09 to 2026-03-12. ", field: "date"), row("not tomorrow.", field: "date")])
        let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        XCTAssertEqual(values.map(\.requirementIndex), [1, 2, 3, 4, 6])
        XCTAssertEqual(values.map(\.value), ["2026-03-08", "2", "3", "0", "2"])
        XCTAssertEqual(values.map(\.unit), ["civilDay", "people", "adults", "children", "tickets"])
        XCTAssertEqual(values.map(\.kind), [.date, .partySize, .partySize, .partySize, .ticketCount])
        for value in values { XCTAssertFalse(String(reflecting: value).contains(value.id)) }
        let ledger = ComputerUseBrowserScalarRequirements(proposal: goal)
        XCTAssertEqual(ledger.entries.count, goal.requirements.count)
        for index in [2, 3, 4] {
            guard case .bound(let condition) = ledger.entries[index].resolution,
                  case .quantity(.equal, _, let unit) = condition.predicate else { return XCTFail("Expected a bound party count") }
            XCTAssertTrue(unit.isPartySize)
        }
    }

    func testPartySizeAssessmentDoesNotCountResultCardsAsTravelerEvidence() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"),
            row("for two people. ", field: "quantity"), row("three options.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal,
            body: FormPlannerFixture.body + "<article><h2>Concert Alpha</h2><p>Party of two</p></article>")
        defer { fixture.close() }
        let document = try fixture.browser.acquireCurrentDocument(taskID: goal.input.taskID)
        let evidence = try await fixture.browser.observePage(document: document)
        let proposal = try await BrowserResearchResultFixture().propose(goal: goal.input, page: .init(page: evidence.page))
        let reading = try await fixture.browser.prepareResultCandidates(proposal, goal: goal.input, evidence: evidence, interpretation: goal)
        let assessment = try ComputerUseBrowserResultAssessment(interpretation: goal, reading: reading)
        let statuses = try XCTUnwrap(assessment.candidates.first).requirements.map(\.status)
        XCTAssertEqual(statuses, [.needsSemanticVerification, .needsPartyCapacity, .needsResultSet])
    }

    func testTicketNormalizationsDoNotTurnResultsBoundsOrAmbiguousCountsIntoBookingQuantities() throws {
        let goal = try proposal(rows: [row("Find concert options. ", role: "outcome", field: "category"),
            row("two tickets. ", field: "quantity"), row("three options. ", field: "quantity"),
            row("two people. ", field: "quantity"), row("at most four tickets. ", field: "quantity"),
            row("at least three tickets. ", field: "quantity"), row("zero tickets. ", field: "quantity"),
            row("two tickets or three tickets.", field: "quantity")])
        let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        XCTAssertEqual(values.map(\.requirementIndex), [1, 3])
        XCTAssertEqual(values.map(\.kind), [.ticketCount, .partySize])
        XCTAssertEqual(values.map(\.unit), ["tickets", "people"])
        XCTAssertEqual(values.map(\.value), ["2", "2"])
        XCTAssertEqual(values.map(\.id), ["value2", "value4"])
        XCTAssertEqual(ComputerUseBrowserScalarRequirements(proposal: goal).entries.count, goal.requirements.count)
    }

    func testTicketAndAdultCountsReachDistinctNativeFieldsAndOneVerifiedQuery() async throws {
        let goal = try proposal(rows: [row("Find concert options. ", role: "outcome", field: "category"),
            row("three options. ", field: "quantity"), row("two tickets. ", field: "quantity"), row("two adults.", field: "quantity")])
        let body = """
        <form action='/results'><label>Tickets<input type='number' name='tickets' min='1' max='8' value='1'></label>
        <label>Adults<input type='number' name='adults' min='1' max='8' value='1'></label>
        <label>Results shown<input type='number' name='shown' value='5'></label><button>Search</button></form>
        """
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: goal, body: body,
            additionalRoutes: ["/results?tickets=2&adults=2&shown=5":.init(body: "<p>Search received</p>")],
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        XCTAssertEqual(input.normalizations.map(\.kind), [.ticketCount, .partySize])
        XCTAssertEqual(input.normalizations.map(\.unit), ["tickets", "adults"])
        XCTAssertEqual(input.normalizations.map(\.requirementIndex), [2, 3])
        let content = try plan([["field":"field1", "normalized":"value3"], ["field":"field2", "normalized":"value4"]])
        let transport = FormPlannerTransport(content: content), planner = try local(transport)
        let proposed = try await owner.planForm(input, using: planner)
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0].httpBody, calls[1].httpBody)
        let request = try object(XCTUnwrap(calls.last?.httpBody))
        let messages = try XCTUnwrap(request["messages"] as? [[String: String]])
        XCTAssertEqual(messages.last?["content"], input.contextJSON)
        let format = try XCTUnwrap(request["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_form_plan_v8")
        XCTAssertEqual(try object(Data(input.contextJSON.utf8))["version"] as? Int, 9)
        let normalized = try XCTUnwrap(object(Data(input.contextJSON.utf8))["normalized_values"] as? [[String: Any]])
        XCTAssertEqual(normalized.map { $0["kind"] as? String }, ["ticketCount", "partySize"])
        XCTAssertEqual(edits, 0)
        let receipt = try await owner.executeForm(proposed, input: input)
        let page = try await owner.observeFormResultPage(after: receipt), control = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" }).id
        let first = try await owner.openFormQuery(after: receipt, controlID: control, evidence: page)
        let repeated = try await owner.openFormQuery(after: receipt, controlID: control, evidence: page)
        XCTAssertEqual(first, repeated); XCTAssertEqual(edits, 2)
        XCTAssertEqual(fixture.server.count("/results?tickets=2&adults=2&shown=5"), 1)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(owner.input, goal.input)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.formQuery])
        XCTAssertFalse(owner.hasPendingFormNavigation)
    }

    func testTicketCountRetainsNativeTypeAndRepresentabilityChecksBeforeAnyInput() async throws {
        let goal = try proposal(rows: [row("Find concert tickets. ", role: "outcome", field: "category"), row("two tickets.", field: "quantity")])
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: goal, body: """
        <form><label>Tickets<input type='number' min='1' max='1'></label>
        <label>Note<input></label><label>Day<input type='date'></label><button>Search</button></form>
        """, domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        defer { fixture.close() }
        for field in ["field2", "field3"] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":field,"normalized":"value2"]]), input: fixture.input))
        }
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1","normalized":"2"]]), input: fixture.input))
        let owner = fixture.owner()
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), planner = FormProposalFixture(content: try plan([["field":"field1","normalized":"value2"]]))
        do { _ = try await owner.planForm(input, using: planner); XCTFail("The observed maximum cannot hold two tickets") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .valueNotRepresentable) }
        XCTAssertEqual(planner.inputs.count, 1); XCTAssertEqual(edits, 0); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
    }

    func testCompleteGoalProducesSourceTextHostDatePartySizeAndExactChoiceContract() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input, selected = input.evidence.fields[4].control.options[1]
        let content = try plan([
            ["field":"field1", "terms":[["requirement":1, "text":"Montréal e\u{301}"]]],
            ["field":"field2", "terms":[["requirement":2, "text":"Paris"]]],
            ["field":"field3", "normalized":"value4"], ["field":"field4", "normalized":"value5"],
            ["field":"field5", "choice":selected.id, "requirement":5]], preserve: [["field":"field6", "requirement":7]])
        let proposal = try ComputerUseBrowserFormProposal.decode(content: content, input: input)
        let contract = try XCTUnwrap(proposal.textContract(for: input))
        XCTAssertEqual(contract.steps.map(\.after), ["Montréal e\u{301}", "Paris", "2026-03-08", "2", selected.id])
        XCTAssertEqual(contract.taskID, input.interpretation.input.taskID)
        XCTAssertEqual(contract.promptDigest, ComputerUseTextTaskContract.digest(input.contextJSON))
        XCTAssertEqual(contract.unchangedValues, [input.evidence.fields[5].editable.snapshot.targetID:"private-reference"])
        XCTAssertEqual(contract.steps.map(\.dependency), [nil] + contract.steps.dropLast().map { Optional($0.id) })
        try await fixture.target.validateRepresentability(of: contract)
        let before = try await fixture.target.read(targetID: contract.steps[0].targetID)
        XCTAssertEqual(before?.value, "old-origin", "Planning and preflight must not type")
        XCTAssertFalse(proposal.isUnavailable); XCTAssertNil(try proposal.questionRequest(for: input))
        XCTAssertFalse(String(reflecting: proposal).contains("Montréal"))
        XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testNativeChoiceIdentityExecutesDuplicateLabelsWithoutAllowingLiteralIDConfusion() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input, field = input.evidence.fields[4], choices = field.control.options
        XCTAssertEqual(choices[0].label, choices[1].label); XCTAssertNotEqual(choices[0].id, choices[1].id)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field5", "choice":choices[1].id, "requirement":5]]), input: input)
        let contract = try XCTUnwrap(proposal.textContract(for: input))
        let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
            apply: { _, _ in XCTFail("Use the native operation identity") }, applyWithIdentity: { try await fixture.target.apply($0) },
            didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) }, persist: { _ in }, mayAct: { true })
        try await task.run()
        let after = try await fixture.target.read(targetID: field.editable.snapshot.targetID)
        XCTAssertEqual(after?.value, choices[1].id)
        let continuation = try task.verifiedContinuation(), dispatched = try await fixture.target.didDispatchInput(operationID: continuation.inputOperationIDs[0])
        XCTAssertTrue(dispatched)
        for text in [choices[1].id, choices[1].label] {
            XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "literal", prompt: "A literal is not an option reference",
                fields: [field.editable], edits: [.init(targetID: field.editable.snapshot.targetID, mode: .replaceAll, text: text)]))
        }
        for option in ["foreign", choices[2].id] {
            XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "choice", prompt: "Only an available native option",
                fields: [field.editable], operations: [.selectChoice(targetID: field.editable.snapshot.targetID, choiceID: option)]))
        }
    }

    func testNativeContractAllowsSiteUpdatesExceptForExplicitUserPreservation() async throws {
        for preserve in [false, true] {
            let body = FormPlannerFixture.body + """
                <script>document.querySelector('select').addEventListener('change', () => {
                  document.querySelector('input[value="private-reference"]').value = 'automatic-reference';
                });</script>
                """
            let fixture = try await FormPlannerFixture(goal: proposal(preserveReference: preserve), body: body)
            defer { fixture.close() }
            let input = fixture.input, selected = input.evidence.fields[4].control.options[1].id
            let proposal = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field5", "choice":selected, "requirement":5]],
                preserve: preserve ? [["field":"field6", "requirement":7]] : []), input: input)
            let contract = try XCTUnwrap(proposal.textContract(for: input))
            XCTAssertEqual(contract.unchangedValues.count, preserve ? 1 : 0)
            var operationID: String?
            let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
                apply: { _, _ in XCTFail("Use identified native input") }, applyWithIdentity: {
                    operationID = $0.operationID; try await fixture.target.apply($0)
                }, didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) }, persist: { _ in }, mayAct: { true })
            do { try await task.run(); XCTAssertFalse(preserve, "A user's explicit invariant cannot be silently dropped") }
            catch { XCTAssertTrue(preserve, "An unconstrained site update must not fail the edit") }
            let dispatched = try await fixture.target.didDispatchInput(operationID: XCTUnwrap(operationID))
            XCTAssertTrue(dispatched)
            let current = try await fixture.target.read(targetID: input.evidence.fields[5].editable.snapshot.targetID)
            XCTAssertEqual(current?.value, "automatic-reference")
        }
    }

    func testStrictProposalRejectsInventedValuesWrongKindsHybridRootsAndUnscopedQuestions() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input, hidden = input.evidence.fields[4].control.options[2].id
        let invalid = [
            #"{"edits":[]}"#, #"{"unavailable":false}"#, #"{"unavailable":true,"edits":[]}"#,
            #"{"edits":[],"edits":[]}"#, #"{"complete":true}"#,
            try plan([["field":"field1", "terms":[["requirement":1, "text":"Montreal"]]]]),
            try plan([["field":"field1", "terms":[["requirement":6, "text":"book"]]]]),
            try plan([["field":"field1", "terms":[["requirement":true, "text":"Paris"]]]]),
            try plan([["field":"field3", "terms":[["requirement":3, "text":"tomorrow"]]]]),
            try plan([["field":"field4", "normalized":"value4"]]),
            try plan([["field":"field3", "normalized":"value5"]]),
            try plan([["field":"field3", "normalized":"2026-03-08"]]),
            try plan([["field":"field1", "normalized":"value4"]]),
            try plan([["field":"field1", "choice":input.evidence.fields[4].control.options[0].id, "requirement":5]]),
            try plan([["field":"field5", "choice":hidden, "requirement":5]]),
            try plan([["field":"field5", "choice":"private-basic", "requirement":5]]),
            try plan([["field":"field5", "choice":input.evidence.fields[4].control.options[0].id, "requirement":6]]),
            try plan([["field":"Origin", "terms":[["requirement":1, "text":"Montréal"]]]]),
            try plan(Array(repeating: ["field":"field3", "normalized":"value4"], count: 2)),
            try plan([["field":"field3", "normalized":"value4"]], preserve: [["field":"field3", "requirement":7]]),
            try plan([["field":"field3", "normalized":"value4"]], preserve: [["field":"field6", "requirement":7], ["field":"field6", "requirement":7]]),
            try plan([["field":"field3", "normalized":"value4"]], preserve: [["field":"unknown", "requirement":7]]),
            #"{"question":{"topic":"password","requirements":[0]}}"#,
            #"{"question":{"topic":"date","requirements":[1]}}"#,
            #"{"question":{"topic":"date","requirements":[3,3]}}"#,
            #"{"question":{"topic":"date","requirements":[true]}}"#,
            #"{"question":{"topic":"date","requirements":[]}}"#]
        for content in invalid {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: input)) {
                XCTAssertEqual($0 as? ComputerUseBrowserResearchFormError, .invalidProposal)
            }
        }
    }

    func testTextTermsPreserveSourceBytesOrderAndWholeGoalWithoutTypingProhibitions() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input
        let content = try plan([["field":"field1", "terms":[["requirement":0, "text":"flights"], ["requirement":1, "text":"Montréal e\u{301}"]]]])
        let accepted = try ComputerUseBrowserFormProposal.decode(content: content, input: input)
        guard case .text(let text) = accepted.edits[0].payload else { return XCTFail("Expected retained source terms") }
        XCTAssertEqual(text.query, "flights Montréal e\u{301}")
        for term in text.terms {
            let bytes = Data(input.interpretation.input.userTurns[term.sourceTurnIndex].utf8)
            XCTAssertEqual(bytes.subdata(in: term.sourceByteOffset..<(term.sourceByteOffset + term.text.utf8.count)), Data(term.text.utf8))
        }
        for terms in [
            [["requirement":1, "text":"Montréal é"]],
            [["requirement":2, "text":"Paris"], ["requirement":0, "text":"flights"]],
            [["requirement":1, "text":"Montréal"], ["requirement":1, "text":"Montréal"]]] as [[[String: Any]]] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "terms":terms]]), input: input))
        }
        XCTAssertTrue(input.contextJSON.contains("Do not book."))
        XCTAssertEqual(ComputerUseBrowserScalarRequirements(proposal: input.interpretation).entries.count, 8)
    }

    func testProposalRejectsAnIdenticalLookingForeignPageAndChangedGoalInput() async throws {
        let first = try await FormPlannerFixture(goal: proposal()), second = try await FormPlannerFixture(goal: proposal())
        defer { first.close(); second.close() }
        let proposed = try ComputerUseBrowserFormProposal.decode(content: #"{"question":{"topic":"date","requirements":[3]}}"#, input: first.input)
        XCTAssertThrowsError(try proposed.validate(for: second.input))
        XCTAssertThrowsError(try proposed.textContract(for: second.input))
        XCTAssertThrowsError(try proposed.questionRequest(for: second.input))
        let changed = try ComputerUseBrowserGoalInput(taskID: first.goal.input.taskID, prompt: first.goal.input.prompt,
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "UTC")
        let rows = try first.goal.requirements.map { requirement -> [String: Any] in
            row(try XCTUnwrap(first.goal.source(of: requirement)), role: requirement.role.rawValue, field: requirement.field.rawValue)
        }
        let interpretation = try decodeGoal(rows, input: changed)
        let foreignClock = try ComputerUseBrowserResearchFormInput(interpretation: interpretation, evidence: first.input.evidence)
        XCTAssertThrowsError(try proposed.validate(for: foreignClock))
    }

    func testOwnerRevalidatesAndPreflightsBeforePublishingButDoesNotEdit() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal(), body: FormPlannerFixture.body.replacingOccurrences(of: "max='8'", with: "max='1'"))
        defer { fixture.close() }
        let owner = fixture.owner()
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), planner = FormProposalFixture(content: #"{"preserve":[],"edits":[{"field":"field4","normalized":"value5"}]}"#)
        do { _ = try await owner.planForm(input, using: planner); XCTFail("The native number field cannot represent this party size") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .valueNotRepresentable) }
        XCTAssertEqual(planner.inputs.count, 1)
        do { try await owner.revalidateFormInput(input); XCTFail("A failed plan cannot retain usable form input") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .inputChanged) }
        XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testPauseDuringFormPlanningJoinsThePlannerAndRequiresFreshHandbackInput() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal()), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        let owner = fixture.owner(), planner = FormProposalFixture(content: #"{"preserve":[],"edits":[{"field":"field3","normalized":"value4"}]}"#)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        planner.beforeReply = { await gate.suspend() }
        let running = Task { try await owner.planForm(input, using: planner) }
        try await gate.waitUntilStarted()
        owner.pause(); XCTAssertTrue(owner.isOperating)
        do { try await owner.resumeAfterUserControl(); XCTFail("Handback must wait for the actual planner to unwind") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        gate.release()
        do { _ = try await running.value; XCTFail("A late model response cannot survive Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating)
        planner.beforeReply = nil
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        try await owner.resumeAfterUserControl()
        let fresh = try await owner.prepareFormInput(), result = try await owner.planForm(fresh, using: planner)
        XCTAssertEqual(fresh.interpretation.input, input.interpretation.input)
        XCTAssertEqual(result.edits.count, 1); XCTAssertEqual(planner.inputs.count, 2)
        try await owner.revalidateFormInput(fresh)
        XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testPageValueDriftDuringPlanningRejectsTheProposalBeforeInput() async throws {
        let body = FormPlannerFixture.body + """
            <script>fetch('/signal').then(() => { document.querySelector('input').value = 'changed privately'; fetch('/changed'); });</script>
            """
        let fixture = try await FormPlannerFixture(goal: proposal(), body: body, heldSignal: true)
        defer { fixture.close() }
        let owner = fixture.owner(), planner = FormProposalFixture(content: #"{"preserve":[],"edits":[{"field":"field2","terms":[{"requirement":2,"text":"Paris"}]}]}"#)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        planner.beforeReply = {
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
        }
        do { _ = try await owner.planForm(input, using: planner); XCTFail("Another field's changed value invalidates the complete preconditions") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(fixture.server.count("/changed"), 1); XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testTypedQuestionIsScopedToTheOriginalGoalAndUnavailableIsNotCompletion() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let owner = fixture.owner()
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), planner = FormProposalFixture(content: #"{"question":{"topic":"date","requirements":[3]}}"#)
        let result = try await owner.planForm(input, using: planner), question = try XCTUnwrap(result.questionRequest(for: input))
        XCTAssertEqual(question.taskID, input.interpretation.input.taskID); XCTAssertEqual(question.inputDigest, input.interpretation.input.digest)
        XCTAssertEqual(question.requirementIDs, [input.interpretation.requirements[3].id]); XCTAssertNil(try result.textContract(for: input))
        let issued = try owner.issueQuestion(topic: question.topic, requirementIDs: question.requirementIDs, controllerID: "phone", controllerSessionID: "session")
        XCTAssertEqual(issued.scope[0].source, input.interpretation.source(of: input.interpretation.requirements[3]))
        let unavailable = try ComputerUseBrowserFormProposal.decode(content: #"{"unavailable":true}"#, input: input)
        XCTAssertTrue(unavailable.isUnavailable); XCTAssertNil(try unavailable.textContract(for: input))
        XCTAssertEqual(owner.input, input.interpretation.input)
    }

    func testLocalPlannerCountsTheExactCompleteRequestAndNeverTruncatesToFit() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        for count in [3_008, 3_009, 0] {
            let transport = FormPlannerTransport(content: #"{"unavailable":true}"#, count: count), planner = try local(transport)
            do {
                let result = try await planner.propose(fixture.input)
                XCTAssertEqual(count, 3_008); XCTAssertTrue(result.isUnavailable)
            } catch { XCTAssertNotEqual(count, 3_008); XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .contextLimit) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, count == 3_008 ? 2 : 1)
            if requests.count == 2 { XCTAssertEqual(requests[0].httpBody, requests[1].httpBody) }
            let request = try XCTUnwrap(requests.first), body = try object(XCTUnwrap(request.httpBody))
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], fixture.input.contextJSON)
            XCTAssertEqual(messages[0]["content"], ComputerUseLocalBrowserFormPlanner.instructions)
            XCTAssertEqual(request.timeoutInterval, 30); XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token-value")
            XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["cache_prompt"] as? Bool, false)
            XCTAssertNil(body["tools"]); XCTAssertFalse(messages[1]["content"]?.contains("private-reference") ?? true)
        }
    }

    func testLocalPlannerChecksCancellationBeforeAndAfterEachTransportBoundary() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        for point in ["before", "count", "completion"] {
            let transport = FormPlannerTransport(content: #"{"unavailable":true}"#, cancelAt: point), planner = try local(transport)
            let running = Task {
                if point == "before" { withUnsafeCurrentTask { $0?.cancel() } }
                return try await planner.propose(fixture.input)
            }
            do { _ = try await running.value; XCTFail("Cancellation must not publish a form proposal") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, point == "before" ? 0 : point == "count" ? 1 : 2)
        }
    }

    func testOwnerExecutesRetainedFormOnceAndPreparesQueryFromVerifiedNativeInput() async throws {
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), content = try plan([
            ["field":"field1", "terms":[["requirement":1, "text":"Montréal e\u{301}"]]],
            ["field":"field3", "normalized":"value4"], ["field":"field4", "normalized":"value5"]],
            preserve: [["field":"field6", "requirement":7]])
        let planner = FormProposalFixture(content: content), proposed = try await owner.planForm(input, using: planner)
        let receipt = try await owner.executeForm(proposed, input: input)
        let repeated = try await owner.executeForm(proposed, input: input), resumed = try await owner.resumeForm()
        XCTAssertEqual(repeated, receipt); XCTAssertEqual(resumed, receipt)
        XCTAssertEqual(edits, 3); XCTAssertEqual(planner.inputs.count, 1); XCTAssertFalse(owner.hasPendingForm)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(owner.input, input.interpretation.input)
        let records = try stageJournals(directory)
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[receipt.stageID]?.statuses, [.verified, .verified, .verified])
        let page = try await owner.observeFormResultPage(after: receipt), button = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        let query = try await owner.prepareFormQuery(after: receipt, controlID: button.id, evidence: page)
        XCTAssertEqual(query.taskID, owner.taskID)
        XCTAssertFalse(fixture.server.requestedPaths.contains { $0.hasPrefix("/results") })
        let data = try stageJournalData(directory).map { String(decoding: $0, as: UTF8.self) }.joined()
        for privateText in ["Montréal", "private-reference", input.interpretation.input.prompt, "Origin", "2026-03-08"] {
            XCTAssertFalse(data.contains(privateText))
        }
    }

    func testFormStageCancellationBeforeDispatchRetainsAttemptAndBlocksReplacementWork() async throws {
        var owner: ComputerUseBrowserResearchTask?, edits = 0, writes = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let current = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: { writes += 1; if writes == 1 { owner?.pause() } })
        })
        owner = current
        _ = try await current.interpretGoal()
        let input = try await current.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        do { _ = try await current.executeForm(proposed, input: input); XCTFail("Pause after the durable attempt must stop before input") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(edits, 0); XCTAssertTrue(current.hasPendingForm)
        XCTAssertEqual(try stageJournals(directory).values.first?.statuses, [.attempted])
        try await current.resumeAfterUserControl()
        let operations: [@MainActor () async throws -> Void] = [{ _ = try await current.prepareFormInput() }, { _ = try await current.readCandidates() }, { _ = try await current.interpretGoal() }]
        for work in operations {
            do { try await work(); XCTFail("An unresolved form stage cannot be replaced") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .formPending) }
        }
        XCTAssertThrowsError(try current.issueQuestion(topic: .date, requirementIDs: [input.interpretation.requirements[3].id],
            controllerID: "phone", controllerSessionID: "session")) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .formPending)
        }
        do { _ = try await current.resumeForm(); XCTFail("No native receipt exists; the attempt cannot be replayed") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(edits, 0); XCTAssertEqual(try stageJournals(directory).values.first?.statuses, [.uncertain])
    }

    func testFormStagePauseJoinsDispatchedWebKitWorkBeforeReleasingExecutionLease() async throws {
        var edits = 0
        let body = FormPlannerFixture.body + """
            <script>document.querySelector('input').addEventListener('input', () => {
              const request = new XMLHttpRequest(); request.open('GET', '/held-input', false); request.send();
            });</script>
            """
        let fixture = try await FormPlannerFixture(goal: proposal(), body: body, additionalRoutes: ["/held-input":.init(held: true)],
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.server.releaseHeldResponses(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field1", "terms":[["requirement":1, "text":"Montréal"]]]]), input: input)
        let running = Task { try await owner.executeForm(proposed, input: input) }
        try await fixture.wait { fixture.server.count("/held-input") == 1 }
        owner.pause()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(owner.isOperating)
        let stageID = try XCTUnwrap(stageJournals(directory).keys.first)
        let store = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Research Forms").appendingPathComponent(stageID))
        let journal = try store.load(taskID: owner.taskID)
        XCTAssertThrowsError(try store.acquireExecution(taskID: owner.taskID, expected: journal)) {
            XCTAssertEqual($0 as? ComputerUseTaskJournalStore.StoreError, .busy)
        }
        do { try await owner.resumeAfterUserControl(); XCTFail("An input call still owns the stage") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        fixture.server.releaseHeldResponses()
        do { _ = try await running.value; XCTFail("The caller remains cancelled after native completion") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(edits, 1)
        try await owner.resumeAfterUserControl()
        let resumed = try await owner.resumeForm(), receipt = try XCTUnwrap(resumed)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(edits, 1); XCTAssertEqual(fixture.server.count("/held-input"), 1)
        XCTAssertEqual(try stageJournals(directory)[receipt.stageID]?.statuses, [.verified])
    }

    func testFormStageReopensFailedStoreAndReconcilesVisibleVerifiedWriteWithoutReplay() async throws {
        var writes = 0, edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: { writes += 1; if writes == 2 { throw ComputerUseTaskJournalStore.StoreError.unavailable } })
        })
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        do { _ = try await owner.executeForm(proposed, input: input); XCTFail("A failed commit cannot publish success") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        XCTAssertEqual(edits, 1); XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.hasPendingForm)
        XCTAssertEqual(try stageJournals(directory).values.first?.statuses, [.verified])
        let resumed = try await owner.resumeForm(), receipt = try XCTUnwrap(resumed)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt]); XCTAssertEqual(edits, 1)
        XCTAssertFalse(owner.hasPendingForm)
    }

    func testFormStageFailedAttemptWriteCannotTreatMatchingManualValueAsItsOwnEffect() async throws {
        var writes = 0, edits = 0
        let body = FormPlannerFixture.body + """
            <script>fetch('/signal').then(() => {
              document.querySelector('input[type=date]').value = '2026-03-08'; fetch('/changed');
            });</script>
            """
        let fixture = try await FormPlannerFixture(goal: proposal(), body: body, heldSignal: true,
            domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: { writes += 1; if writes == 1 { throw ComputerUseTaskJournalStore.StoreError.unavailable } })
        })
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        do { _ = try await owner.executeForm(proposed, input: input); XCTFail("The failed attempt write must prevent input") } catch { }
        XCTAssertEqual(edits, 0)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { _ = try await owner.resumeForm(); XCTFail("Manual value equality cannot supply the missing native receipt") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(edits, 0); XCTAssertTrue(owner.hasPendingForm)
        XCTAssertEqual(try stageJournals(directory).values.first?.statuses, [.uncertain])
    }

    func testFormStageRefreshesUnsentObservationNonceWithoutReplanningTheContract() async throws {
        var owner: ComputerUseBrowserResearchTask?, stores = 0, edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let current = fixture.owner(journalDirectory: directory, makeStore: { location in
            let store = try ComputerUseTaskJournalStore(directory: location)
            stores += 1; if stores == 1 { owner?.pause() }
            return store
        })
        owner = current
        _ = try await current.interpretGoal()
        let input = try await current.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        do { _ = try await current.executeForm(proposed, input: input); XCTFail("Pause during admission must keep the stage unsent") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(edits, 0); XCTAssertTrue(try stageJournals(directory).isEmpty)
        try await current.resumeAfterUserControl()
        let resumed = try await current.resumeForm(), receipt = try XCTUnwrap(resumed)
        XCTAssertEqual(edits, 1); XCTAssertEqual(stores, 2)
        let original = try XCTUnwrap(proposed.textContract(for: input, stageID: receipt.stageID))
        XCTAssertEqual(original.contractDigest, receipt.contractDigest)
        XCTAssertEqual(current.input, input.interpretation.input)
    }

    func testNewFormStageKeepsOriginalGoalAndUsesAnotherJournalNamespace() async throws {
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let first = try await owner.prepareFormInput(), firstPlan = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field1", "terms":[["requirement":1, "text":"Montréal"]]]]), input: first)
        let firstReceipt = try await owner.executeForm(firstPlan, input: first)
        let second = try await owner.prepareFormInput(), secondPlan = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field2", "terms":[["requirement":2, "text":"Paris"]]]]), input: second)
        let secondReceipt = try await owner.executeForm(secondPlan, input: second)
        XCTAssertEqual(firstReceipt.index, 0); XCTAssertEqual(secondReceipt.index, 1)
        XCTAssertNotEqual(firstReceipt.stageID, secondReceipt.stageID); XCTAssertNotEqual(firstReceipt.contractDigest, secondReceipt.contractDigest)
        XCTAssertEqual(firstReceipt.taskID, secondReceipt.taskID); XCTAssertEqual(firstReceipt.goalRevision, secondReceipt.goalRevision)
        XCTAssertEqual(owner.confirmedFormHistory, [firstReceipt, secondReceipt]); XCTAssertEqual(try stageJournals(directory).count, 2)
        do { _ = try await owner.executeForm(firstPlan, input: first); XCTFail("An older form proposal cannot start a third stage") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .formUnavailable) }
        XCTAssertEqual(edits, 2)
    }

    func testReplacementOwnerCannotReconstructChangedNativeBindingsFromAnOldStageJournal() async throws {
        let goal = try proposal(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await FormPlannerFixture(goal: goal), owner = first.owner(journalDirectory: directory)
        defer { owner.retire(); first.close() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), firstPlan = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        let original = try await owner.executeForm(firstPlan, input: input)
        owner.retire(); first.close()
        var edits = 0
        let second = try await FormPlannerFixture(goal: goal, domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        defer { second.close() }
        let replacement = second.owner(journalDirectory: directory)
        defer { replacement.retire() }
        _ = try await replacement.interpretGoal()
        let fresh = try await replacement.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: fresh)
        do { _ = try await replacement.executeForm(proposed, input: fresh); XCTFail("A new browser must not replay an older form stage") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        XCTAssertEqual(edits, 0); XCTAssertTrue(replacement.hasPendingForm)
        XCTAssertEqual(try stageJournals(directory)[original.stageID]?.contractDigest, original.contractDigest)
    }

    func testRetireAndCloseReleasePendingNativeJoinWithoutPublishingAFormReceipt() async throws {
        let body = FormPlannerFixture.body + """
            <script>document.querySelector('input').addEventListener('input', () => {
              const request = new XMLHttpRequest(); request.open('GET', '/held-input', false); request.send();
            });</script>
            """
        let fixture = try await FormPlannerFixture(goal: proposal(), body: body, additionalRoutes: ["/held-input":.init(held: true)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.server.releaseHeldResponses(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field1", "terms":[["requirement":1, "text":"Montréal"]]]]), input: input)
        let running = Task { try await owner.executeForm(proposed, input: input) }
        try await fixture.wait { fixture.server.count("/held-input") == 1 }
        owner.retire()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(owner.isOperating)
        fixture.browser.close()
        do { _ = try await running.value; XCTFail("Closing the browser must only release cleanup, never publish a receipt") }
        catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchFormStage.Failure == .retired) }
        XCTAssertFalse(owner.isOperating); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        let stageID = try XCTUnwrap(stageJournals(directory).keys.first)
        let store = try ComputerUseTaskJournalStore(directory: directory.appendingPathComponent("Research Forms").appendingPathComponent(stageID))
        let record = try store.load(taskID: input.interpretation.input.taskID)
        let lease = try store.acquireExecution(taskID: input.interpretation.input.taskID, expected: record)
        lease.release()
    }

    func testFormStageRejectsChangedPageBeforeAnyDurableAttemptOrInput() async throws {
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), body: FormPlannerFixture.body + """
            <script>fetch('/signal').then(() => { document.body.insertAdjacentHTML('beforeend', '<p>Changed search context</p>'); fetch('/changed'); });</script>
            """, heldSignal: true, domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), proposed = try ComputerUseBrowserFormProposal.decode(
            content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { _ = try await owner.executeForm(proposed, input: input); XCTFail("Fresh field IDs alone do not preserve a changed planning context") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .inputChanged) }
        XCTAssertEqual(edits, 0); XCTAssertTrue(try stageJournals(directory).isEmpty)
        XCTAssertTrue(owner.hasPendingForm)
    }

    func testOwnerJournalsFormQueryOnceUnderTheOriginalGoalAndKeepsHistoricalReceipts() async throws {
        var edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory)
        defer { owner.retire() }
        let (form, page, control) = try await prepareQuery(owner)
        let original = owner.input
        let first = try await owner.openFormQuery(after: form, controlID: control, evidence: page)
        let repeated = try await owner.openFormQuery(after: form, controlID: control, evidence: page)
        let resumed = try await owner.resumeFormNavigation()
        XCTAssertEqual(first, repeated); XCTAssertEqual(first, resumed)
        XCTAssertEqual(edits, 1); XCTAssertEqual(queryRequests(fixture), 1)
        XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.confirmedFormHistory, [form])
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.formQuery])
        XCTAssertEqual(owner.confirmedNavigationHistory.first?.goalRevision, original.digest)
        XCTAssertFalse(owner.hasPendingFormNavigation); XCTAssertFalse(owner.hasPendingNavigation)
        let journal = try queryJournal(directory)
        XCTAssertEqual(journal.promptDigest, original.rootDigest); XCTAssertEqual(journal.statuses, [.verified])
        XCTAssertEqual(journal.stepIDs, [first.document.operationID])
        let text = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        for value in ["2026-03-08", "private-reference", "/results", "old-origin", original.prompt] { XCTAssertFalse(text.contains(value)) }
    }

    func testUnsentFormQueryRefreshesAfterHandbackWithoutChangingItsOperationOrEditingAgain() async throws {
        for failRefresh in [false, true] {
            var owner: ComputerUseBrowserResearchTask?, queryWrites = 0, edits = 0
            let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
            let current = fixture.owner(journalDirectory: directory, makeStore: { location in
                try .init(directory: location, afterReplacement: {
                    if location.lastPathComponent == "Observed Destinations" {
                        queryWrites += 1
                        if queryWrites == 1 { owner?.pause() }
                        if failRefresh && queryWrites == 2 { throw ComputerUseTaskJournalStore.StoreError.unavailable }
                    }
                })
            })
            owner = current
            let (form, page, control) = try await prepareQuery(current)
            do { _ = try await current.openFormQuery(after: form, controlID: control, evidence: page); XCTFail("Pause must leave the query unsent") }
            catch { XCTAssertTrue(error is CancellationError) }
            let before = try queryJournal(directory)
            XCTAssertEqual(before.statuses, [.planned]); XCTAssertEqual(queryRequests(fixture), 0)
            XCTAssertTrue(current.hasPendingNavigation); XCTAssertTrue(current.hasPendingFormNavigation)
            try await current.resumeAfterUserControl()
            do { _ = try await current.prepareFormInput(); XCTFail("A pending submission cannot be replaced by another edit stage") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .navigationPending) }
            if failRefresh {
                do { _ = try await current.resumeFormNavigation(); XCTFail("A failed replacement must preserve both known bindings") }
                catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
                XCTAssertEqual(try queryJournal(directory).statuses, [.planned]); XCTAssertEqual(queryRequests(fixture), 0)
            }
            let resumed = try await current.resumeFormNavigation(), receipt = try XCTUnwrap(resumed)
            let after = try queryJournal(directory)
            XCTAssertEqual(after.taskID, before.taskID); XCTAssertEqual(after.stepIDs, before.stepIDs)
            XCTAssertEqual(after.promptDigest, before.promptDigest); XCTAssertNotEqual(after.contractDigest, before.contractDigest)
            XCTAssertEqual(after.statuses, [.verified]); XCTAssertEqual(after.stepIDs, [receipt.document.operationID])
            XCTAssertEqual(queryRequests(fixture), 1); XCTAssertEqual(edits, 1)
            XCTAssertEqual(current.confirmedNavigationHistory.count, 1)
        }
    }

    func testFormQueryReconcilesAVisibleVerifiedWriteFailureWithoutRepreparingOrReloading() async throws {
        var queryWrites = 0, preparations = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .prepareFormQuery { preparations += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let owner = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: {
                if location.lastPathComponent == "Observed Destinations" {
                    queryWrites += 1
                    if queryWrites == 3 { throw ComputerUseTaskJournalStore.StoreError.unavailable }
                }
            })
        })
        defer { owner.retire() }
        let (form, page, control) = try await prepareQuery(owner)
        do { _ = try await owner.openFormQuery(after: form, controlID: control, evidence: page); XCTFail("A failed verified write cannot publish navigation") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        XCTAssertEqual(try queryJournal(directory).statuses, [.verified]); XCTAssertTrue(owner.hasPendingFormNavigation)
        XCTAssertTrue(owner.confirmedNavigationHistory.isEmpty); XCTAssertEqual(queryRequests(fixture), 1)
        let calls = preparations
        _ = try await owner.resumeFormNavigation()
        XCTAssertEqual(preparations, calls); XCTAssertEqual(queryRequests(fixture), 1)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.formQuery])
    }

    func testAttemptedFormQueryWithoutNativeReceiptCannotBeReplannedOrSubmittedAgain() async throws {
        var owner: ComputerUseBrowserResearchTask?, queryWrites = 0, preparations = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), domScriptDidDispatch: { if $0 == .prepareFormQuery { preparations += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let current = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: {
                if location.lastPathComponent == "Observed Destinations" {
                    queryWrites += 1; if queryWrites == 2 { owner?.pause() }
                }
            })
        })
        owner = current
        let (form, page, control) = try await prepareQuery(current)
        do { _ = try await current.openFormQuery(after: form, controlID: control, evidence: page); XCTFail("Pause after attempt must stop the load") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(queryRequests(fixture), 0); XCTAssertEqual(try queryJournal(directory).statuses, [.uncertain])
        try await current.resumeAfterUserControl()
        let calls = preparations
        do { _ = try await current.resumeFormNavigation(); XCTFail("An attempted query requires its original native receipt") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .observedNavigationUncertain) }
        XCTAssertEqual(queryRequests(fixture), 0); XCTAssertEqual(preparations, calls)
        XCTAssertTrue(current.hasPendingFormNavigation); XCTAssertTrue(current.confirmedNavigationHistory.isEmpty)
    }

    func testUnsentQueryRejectsChangedPrivateDestinationAndParametersOrVisibleContext() async throws {
        for mutation in ["action", "value", "page"] {
            var owner: ComputerUseBrowserResearchTask?, writes = 0
            let script: String
            switch mutation {
            case "action": script = "document.querySelector('form').action = '/changed-destination';"
            case "value": script = "document.querySelector('[name=reference]').value = 'changed-reference';"
            default: script = "document.body.insertAdjacentHTML('beforeend', '<p>Changed context</p>');"
            }
            let fixture = try await FormPlannerFixture(goal: proposal(), body: FormPlannerFixture.body + """
                <script>fetch('/signal').then(() => { \(script) fetch('/changed'); });</script>
                """, heldSignal: true)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
            let current = fixture.owner(journalDirectory: directory, makeStore: { location in
                try .init(directory: location, afterReplacement: {
                    if location.lastPathComponent == "Observed Destinations" { writes += 1; if writes == 1 { owner?.pause() } }
                })
            })
            owner = current
            let (form, page, control) = try await prepareQuery(current)
            do { _ = try await current.openFormQuery(after: form, controlID: control, evidence: page); XCTFail("Retain the planned query") }
            catch { XCTAssertTrue(error is CancellationError) }
            let before = try queryJournal(directory)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            try await current.resumeAfterUserControl()
            do { _ = try await current.resumeFormNavigation(); XCTFail("A fresh nonce cannot authorize a different query") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, mutation == "value" ? .formQueryUnavailable : .pageChanged) }
            XCTAssertEqual(try queryJournal(directory), before)
            XCTAssertEqual(queryRequests(fixture), 0); XCTAssertEqual(fixture.server.count("/changed-destination"), 0)
            XCTAssertTrue(current.hasPendingFormNavigation)
        }
    }

    func testPendingQueryCannotSwitchItsSubmitterOrAcceptAnotherGoalAnswer() async throws {
        var owner: ComputerUseBrowserResearchTask?, writes = 0
        let body = FormPlannerFixture.body.replacingOccurrences(of: "</form>", with: "<button>Another search</button></form>")
        let fixture = try await FormPlannerFixture(goal: proposal(), body: body)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let current = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: {
                if location.lastPathComponent == "Observed Destinations" { writes += 1; if writes == 1 { owner?.pause() } }
            })
        })
        owner = current
        let (form, page, control) = try await prepareQuery(current)
        let other = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" && $0.id != control })
        do { _ = try await current.openFormQuery(after: form, controlID: control, evidence: page); XCTFail("Retain the original submitter") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await current.resumeAfterUserControl()
        do { _ = try await current.openFormQuery(after: form, controlID: other.id, evidence: page); XCTFail("A pending query cannot switch buttons") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .formUnavailable) }
        XCTAssertThrowsError(try current.issueQuestion(topic: .date,
            requirementIDs: [try proposal().requirements[3].id], controllerID: "phone", controllerSessionID: "session")) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .navigationPending)
        }
        XCTAssertEqual(queryRequests(fixture), 0)
        _ = try await current.resumeFormNavigation()
        XCTAssertEqual(queryRequests(fixture), 1)
    }

    func testFormQueryHandbackCannotReplaceOriginalFieldAuthorityAfterLoginNavigation() async throws {
        var owner: ComputerUseBrowserResearchTask?, writes = 0, edits = 0
        let fixture = try await FormPlannerFixture(goal: proposal(), additionalRoutes: [
            "/account":.init(body: "<label>Password<input type='password' autocomplete='current-password'></label>"),
            "/account-ready":.init(body: FormPlannerFixture.body)], domScriptDidDispatch: { if $0 == .edit { edits += 1 } })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { owner?.retire(); fixture.close(); try? FileManager.default.removeItem(at: directory) }
        let current = fixture.owner(journalDirectory: directory, makeStore: { location in
            try .init(directory: location, afterReplacement: {
                if location.lastPathComponent == "Observed Destinations" { writes += 1; if writes == 1 { owner?.pause() } }
            })
        })
        owner = current
        let (form, page, control) = try await prepareQuery(current), original = current.input
        do { _ = try await current.openFormQuery(after: form, controlID: control, evidence: page); XCTFail("Keep the query pending across manual control") }
        catch { XCTAssertTrue(error is CancellationError) }
        let before = try queryJournal(directory), base = page.document.committedURL.deletingLastPathComponent()
        _ = try await fixture.browser.navigate(taskID: current.taskID, operationID: "manual-account", to: base.appendingPathComponent("account"))
        do { try await current.resumeAfterUserControl(); XCTFail("The password page still requires manual control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        do { _ = try await current.resumeFormNavigation(); XCTFail("Query recovery cannot implicitly take back control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        _ = try await fixture.browser.navigate(taskID: current.taskID, operationID: "manual-ready", to: base.appendingPathComponent("account-ready"))
        try await current.resumeAfterUserControl()
        do { _ = try await current.resumeFormNavigation(); XCTFail("An identical-looking authenticated form has different native authority") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(current.input, original); XCTAssertEqual(try queryJournal(directory), before)
        XCTAssertEqual(queryRequests(fixture), 0); XCTAssertEqual(edits, 1); XCTAssertTrue(current.hasPendingFormNavigation)
    }

    private func prepareQuery(_ owner: ComputerUseBrowserResearchTask) async throws -> (ComputerUseBrowserResearchFormReceipt, ComputerUseBrowserPageEvidence, String) {
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        let proposed = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field3", "normalized":"value4"]]), input: input)
        let form = try await owner.executeForm(proposed, input: input)
        let page = try await owner.observeFormResultPage(after: form)
        return (form, page, try XCTUnwrap(page.page.controls.first { $0.kind == "submit" }).id)
    }
    private func queryRequests(_ fixture: FormPlannerFixture) -> Int { fixture.server.requestedPaths.filter { $0.hasPrefix("/results?") }.count }
    private func queryJournal(_ directory: URL) throws -> ComputerUseTaskJournal {
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Observed Destinations"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count == 1, let file = files.first else { throw ComputerUseBrowserResearchFormNavigation.Failure.invalidIntent }
        return try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: file))
    }

    private func stageJournalData(_ directory: URL) throws -> [Data] {
        let forms = directory.appendingPathComponent("Research Forms")
        guard FileManager.default.fileExists(atPath: forms.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: forms, includingPropertiesForKeys: nil).flatMap { stage in
            try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try Data(contentsOf: $0) }
        }
    }
    private func stageJournals(_ directory: URL) throws -> [String: ComputerUseTaskJournal] {
        let forms = directory.appendingPathComponent("Research Forms")
        guard FileManager.default.fileExists(atPath: forms.path) else { return [:] }
        var values: [String: ComputerUseTaskJournal] = [:]
        for stage in try FileManager.default.contentsOfDirectory(at: forms, includingPropertiesForKeys: nil) {
            for file in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                values[stage.lastPathComponent] = try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: file))
            }
        }
        return values
    }

    private func local(_ transport: FormPlannerTransport) throws -> ComputerUseLocalBrowserFormPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value",
            modelAlias: ComputerUseNativeTextRuntimeInputs.modelAlias), transport: transport)
    }
    private func plan(_ edits: [[String: Any]], preserve: [[String: Any]] = []) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: ["edits":edits, "preserve":preserve]), as: UTF8.self) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func row(_ source: String, role: String = "condition", field: String = "other") -> [String: Any] {
        ["turn":0, "source":source, "role":role, "field":field, "relation":"unspecified", "values":[]]
    }
    private func proposal(rows: [[String: Any]]? = nil, preserveReference: Bool = true) throws -> ComputerUseBrowserGoalProposal {
        let rows = rows ?? [row("Find flights ", role: "outcome", field: "category"), row("from Montréal e\u{301} ", field: "origin"),
            row("to Paris ", field: "destination"), row("tomorrow ", field: "date"), row("for two people. ", field: "quantity"),
            row("Use refundable economy. "), row("Do not book. ", role: "prohibition")] + (preserveReference ? [row("Leave Reference unchanged.")] : [])
        let prompt = try rows.map { try XCTUnwrap($0["source"] as? String) }.joined()
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z"))
        let input = try ComputerUseBrowserGoalInput(taskID: "form-planning", prompt: prompt, referenceDate: date, timeZoneIdentifier: "America/Los_Angeles")
        return try decodeGoal(rows, input: input)
    }
    private func decodeGoal(_ rows: [[String: Any]], input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        let data = try JSONSerialization.data(withJSONObject: ["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]] as [String: Any]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

@MainActor
private final class FormPlannerFixture {
    static let body = """
        <form action='/results'>
          <label>Origin<input name='origin' value='old-origin'></label><label>Destination<input name='destination' value='old-destination'></label>
          <label>Departure<input name='departure' type='date'></label><label>People<input name='people' type='number' min='1' max='8'></label>
          <label>Cabin<select name='cabin'><optgroup label='Basic'><option value='private-basic'>Economy</option></optgroup>
            <optgroup label='Refundable'><option value='private-flexible'>Economy</option></optgroup><option hidden>Hidden</option></select></label>
          <label>Reference<input name='reference' value='private-reference'></label><button>Search</button>
        </form>
        """
    let goal: ComputerUseBrowserGoalProposal
    let server: OwnedBrowserHTTPFixture
    let browser: ComputerUseOwnedBrowser
    let target: ComputerUseBrowserTextTarget
    let input: ComputerUseBrowserResearchFormInput
    let planningWorker = ComputerUsePlanningWorker()
    init(goal: ComputerUseBrowserGoalProposal, body: String? = nil, heldSignal: Bool = false,
         additionalRoutes: [String: OwnedBrowserHTTPFixture.Response] = [:],
         domScriptDidDispatch: ((ComputerUseBrowserDOMCommand) -> Void)? = nil) async throws {
        self.goal = goal
        var routes = additionalRoutes
        routes["/form"] = .init(body: "<!doctype html><meta charset='utf-8'>" + (body ?? Self.body))
        routes["/signal"] = .init(held: heldSignal)
        server = try .init(routes: routes)
        let base = try await server.start()
        browser = .init(presentsWindow: false, domScriptDidDispatch: domScriptDidDispatch, mayAct: { true })
        do {
            try browser.claim(taskID: goal.input.taskID)
            let document = try await browser.navigate(taskID: goal.input.taskID, operationID: "form-open", to: base.appendingPathComponent("form"))
            target = .init(browser: browser, document: document, requiresFrontmost: false)
            let page = try await browser.observePage(document: document), fields = try await target.fields()
            input = try .init(interpretation: goal, evidence: await target.bindFields(fields, to: page))
        } catch { browser.close(); server.stop(); throw error }
    }
    func owner(journalDirectory: URL? = nil, makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) -> ComputerUseBrowserResearchTask {
        .init(input: goal.input, browser: browser, goalPlanner: FormGoalFixture(goal: goal),
            resultPlanner: BrowserResearchResultFixture(), navigationJournalDirectory: journalDirectory, navigationStore: makeStore,
            planningWorker: planningWorker, mayAct: { true })
    }
    func close() { browser.close(); server.stop() }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct PartyCoverageActionFixture: ComputerUseBrowserActionPlanning {
    func propose(_ input: ComputerUseBrowserActionInput) async throws -> ComputerUseBrowserActionProposal {
        try .decode(content: #"{"unavailable":true}"#, input: input)
    }
}

private struct IntroducedDateActionFixture: ComputerUseBrowserActionPlanning {
    let indices: [Int]
    var preservationIndex: Int? = nil
    func propose(_ input: ComputerUseBrowserActionInput) async throws -> ComputerUseBrowserActionProposal {
        if let review = try FormEffectScopeFixture.response(input, editing: ["Departure":indices],
            preserving: preservationIndex.map { ["Reference":$0] } ?? [:]) {
            return try .decode(content: review, input: input)
        }
        let form = try XCTUnwrap(input.formIDs.first)
        return try .decode(content: ResearchAnswerFixture.json(["form":form, "preserve":[]]), input: input)
    }
}

@MainActor
private final class DateReplacementGoalFixture: ComputerUseBrowserGoalPlanning {
    var value: ComputerUseBrowserGoalProposal
    init(value: ComputerUseBrowserGoalProposal) { self.value = value }
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        guard value.input == input else { throw ComputerUseBrowserGoalPlanError.invalidInput }
        return value
    }
}

private struct FormGoalFixture: ComputerUseBrowserGoalPlanning {
    let goal: ComputerUseBrowserGoalProposal
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        guard goal.input == input else { throw ComputerUseBrowserGoalPlanError.invalidInput }
        return goal
    }
}
@MainActor
private final class FormProposalFixture: ComputerUseBrowserFormPlanning {
    let content: String
    var beforeReply: (@MainActor () async throws -> Void)?
    private(set) var inputs: [ComputerUseBrowserResearchFormInput] = []
    init(content: String) { self.content = content }
    func propose(_ input: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserFormProposal {
        inputs.append(input)
        if let beforeReply { try await beforeReply() }
        return try .decode(content: content, input: input)
    }
}
private actor FormPlannerTransport: ComputerUseTextModelTransport {
    let content: String
    let count: Int
    let cancelAt: String?
    private(set) var requests: [URLRequest] = []
    init(content: String, count: Int = 100, cancelAt: String? = nil) { self.content = content; self.count = count; self.cancelAt = cancelAt }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest)
        if cancelAt == "count" { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request)
        if cancelAt == "completion" { withUnsafeCurrentTask { $0?.cancel() } }
        return try JSONSerialization.data(withJSONObject: ["model":ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices":[["index":0, "finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
}
