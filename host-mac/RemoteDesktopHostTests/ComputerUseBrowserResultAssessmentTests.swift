import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResultAssessmentTests: XCTestCase {
    private typealias Status = ComputerUseBrowserResultAssessment.Status
    private typealias Spec = AssessmentResultFixture.Spec

    func testNativeQuantityQuestionPrecedesSearchAndItsAnswerReachesCapacityAssessment() async throws {
        for (answer, quote) in [("adults", "3 adults"), ("tickets", "1 ticket")] {
            let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>\(quote)</p><p>Available for this offer</p>")
            defer { fixture.close() }
            let original = try ComputerUseBrowserGoalInput(taskID: ResearchDriverFixture.root, prompt: "Find concerts. 2",
                referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
            let initial = try proposal([row("Find concerts. "), row("2", field: "quantity")], input: original)
            let goals = AssessmentGoalFixture(value: initial)
            let driver = ComputerUseBrowserResearchDriver(goalPlanner: goals,
                resultPlanner: ComputerUseReviewedBrowserResultPlanner(reader: AssessmentResultFixture(fields: [.init(.quantity, [quote])], empty: false),
                    reviewer: AssessmentInventoryReview(meanings: [.availableQuantity])),
                searchPlanner: fixture.search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(),
                planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: AssessmentLinkFixture()),
                now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
            let first = try await driver.executeBrowserResearch(taskID: original.taskID, prompt: original.prompt, tools: fixture.tools, progress: { _ in })
            guard case .browserClarificationRequired(let request)? = first else { return XCTFail("A count without a unit must ask before searching") }
            XCTAssertEqual(request.topic, .quantity)
            XCTAssertEqual(request.requirementIDs, [initial.requirements[1].id])
            XCTAssertFalse(fixture.browser.hasSession); XCTAssertEqual(fixture.server.requestCount, 0)
            XCTAssertTrue(fixture.search.inputs.isEmpty)
            let owner = try fixture.owner()
            let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
                controllerID: "phone", controllerSessionID: "session")
            let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "quantity", answer: answer,
                controllerID: "phone", controllerSessionID: "session")
            var answerRow = row(answer, field: "source"); answerRow["turn"] = 1
            goals.value = try proposal([row("Find concerts. "), row("2", field: "source"), answerRow], input: updated)
            let continued = try await driver.continueBrowserResearch(taskID: "quantity", research: owner, tools: fixture.tools, progress: { _ in })
            guard case .browserResearchProgress = continued else { return XCTFail("The quantity answer must continue under the existing research owner") }
            XCTAssertNil(try owner.proposedQuestionRequest())
            let reading = try await owner.readCandidates(), assessment = try XCTUnwrap(reading.requirementAssessment)
            XCTAssertEqual(assessment.candidates[0].requirements[1].status, answer == "adults" ? .quotedCapacitySufficient : .quotedCapacityInsufficient)
            XCTAssertEqual(assessment.candidates[0].requirements[2].status, .clarificationApplied)
            XCTAssertEqual(assessment.requirements[1].quantityScope, answer == "adults" ? .party : .ticketInventory)
            XCTAssertEqual(updated.rootDigest, original.rootDigest)
            XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
            XCTAssertEqual(updated.userTurns, [original.prompt, answer])
            XCTAssertEqual(fixture.search.inputs.map(\.input), [updated])
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
            try await fixture.browser.validateResultAssessment(assessment, reading: reading, interpretation: goals.value)
        }
    }

    func testDriverRecoversARelabeledWeekdayAfterAnUnrelatedAnswerWithoutAskingForWebsites() async throws {
        for dateAnswer in ["2026-10-16", "2026-10-15"] {
            let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>2026-10-16</p><p>Paris</p>")
            defer { fixture.close() }
            let original = try ComputerUseBrowserGoalInput(taskID: ResearchDriverFixture.root, prompt: "Find concerts. Friday.",
                referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
            let originalRows = [row("Find concerts. "), row("Friday.", field: "date")]
            let content = try JSONSerialization.data(withJSONObject: ["disposition":"clarification", "requirements":originalRows,
                "question":["topic":"location", "requirements":[0]]])
            let initial = try ComputerUseBrowserGoalProposal.decode(content: String(decoding: content, as: UTF8.self), input: original)
            let goals = AssessmentGoalFixture(value: initial)
            let driver = ComputerUseBrowserResearchDriver(goalPlanner: goals,
                resultPlanner: AssessmentResultFixture(fields: [.init(.date, ["2026-10-16"]), .init(.location, ["Paris"])], empty: false),
                searchPlanner: fixture.search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(),
                planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: AssessmentLinkFixture()),
                now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
            let first = try await driver.executeBrowserResearch(taskID: original.taskID, prompt: original.prompt, tools: fixture.tools, progress: { _ in })
            guard case .browserClarificationRequired(let location)? = first else { return XCTFail("Expected the model's scoped location question") }
            XCTAssertEqual(location.topic, .location)
            let owner = try fixture.owner()
            let locationQuestion = try owner.issueQuestion(topic: location.topic, requirementIDs: location.requirementIDs,
                controllerID: "phone", controllerSessionID: "session")
            let withLocation = try owner.answerQuestion(questionID: locationQuestion.id, answerTaskID: "location", answer: "Paris",
                controllerID: "phone", controllerSessionID: "session")
            var locationRow = row("Paris", field: "location"); locationRow["turn"] = 1
            var rows = [originalRows[0], row("Friday.", field: "source"), locationRow]
            goals.value = try proposal(rows, input: withLocation)
            let second = try await driver.continueBrowserResearch(taskID: "location", research: owner, tools: fixture.tools, progress: { _ in })
            guard case .browserClarificationRequired(let date) = second else { return XCTFail("The retained weekday must produce a date question") }
            XCTAssertEqual(date.topic, .date)
            XCTAssertEqual(date.requirementIDs, [goals.value.requirements[1].id])
            XCTAssertFalse(fixture.browser.hasSession); XCTAssertEqual(fixture.server.requestCount, 0)
            XCTAssertTrue(fixture.search.inputs.isEmpty)
            let dateQuestion = try owner.issueQuestion(topic: date.topic, requirementIDs: date.requirementIDs,
                controllerID: "phone", controllerSessionID: "session")
            let updated = try owner.answerQuestion(questionID: dateQuestion.id, answerTaskID: "date", answer: dateAnswer,
                controllerID: "phone", controllerSessionID: "session")
            var answerRow = row(dateAnswer, field: "source"); answerRow["turn"] = 2; rows.append(answerRow)
            goals.value = try proposal(rows, input: updated)
            let continued = try await driver.continueBrowserResearch(taskID: "date", research: owner, tools: fixture.tools, progress: { _ in })
            guard case .browserResearchProgress = continued else { return XCTFail("A conflicting scalar stays unresolved without asking for a website") }
            XCTAssertNil(try owner.proposedQuestionRequest())
            let reading = try await owner.readCandidates(), assessment = try XCTUnwrap(reading.requirementAssessment)
            XCTAssertEqual(assessment.candidates[0].requirements[1].status, dateAnswer == "2026-10-16" ? .quotedValueMatches : .uncompiledRequirement)
            XCTAssertEqual(assessment.candidates[0].requirements[3].status, dateAnswer == "2026-10-16" ? .clarificationApplied : .uncompiledRequirement)
            XCTAssertEqual(updated.userTurns, [original.prompt, "Paris", dateAnswer])
            XCTAssertEqual(updated.rootDigest, original.rootDigest)
            XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
            XCTAssertEqual(fixture.search.inputs.map(\.input), [updated])
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        }
    }

    func testBoundReadingAccountsForEveryRequirementWithoutPromotingQuotesToVerifiedOffers() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50 total including fees. ", field: "price", relation: "below"),
                    row("On 2027-01-16. ", field: "date", relation: "equal"), row("3 results. ", field: "quantity", relation: "equal"),
                    row("In Paris. ", field: "location"), row("Do not buy.", role: "prohibition")]
        let result = try await reading(rows, fields: [.init(.price, ["Price:", "USD 49.99 total including fees"]), .init(.date, ["16 January 2027"])])
        defer { result.fixture.close() }
        let assessment = try XCTUnwrap(result.batch.requirementAssessment), candidate = try XCTUnwrap(assessment.candidates.first)
        XCTAssertEqual(assessment.requirements.map(\.id), result.interpretation.requirements.map(\.id))
        XCTAssertEqual(candidate.requirements.map(\.requirementID), assessment.requirements.map(\.id))
        XCTAssertEqual(candidate.requirements.map(\.status), [.needsSemanticVerification, .quotedValueMatches,
            .quotedValueMatches, .needsResultSet, .needsSemanticVerification, .needsSemanticVerification])
        XCTAssertEqual(candidate.quotes[0].source, "Price:\nUSD 49.99 total including fees")
        XCTAssertEqual(candidate.requirements[1].quoteIndices, [0]); XCTAssertEqual(candidate.requirements[2].quoteIndices, [1])
        guard case .price(let amount, .total, .included)? = candidate.quotes[0].literal else { return XCTFail("Expected a parsed quotation") }
        XCTAssertEqual(amount.hundredths, 4_999); XCTAssertEqual(amount.currency, .usd)
        let compiled = ComputerUseBrowserScalarRequirements(proposal: result.interpretation)
        guard case .bound(let priceCondition) = compiled.entries[1].resolution else { return XCTFail("Expected a compiled price condition") }
        XCTAssertEqual(priceCondition.evaluate(.price(amount, .total, .included, isExact: false)), .unverifiable,
            "Literal comparison cannot turn an inexact offer observation into an exact one")
        XCTAssertEqual(assessment.goalRevision, result.owner.input.digest)
        try await result.fixture.browser.validateResultAssessment(assessment, reading: result.batch, interpretation: result.interpretation)
        for value in [String(reflecting: assessment), String(reflecting: candidate.quotes[0])] {
            XCTAssertFalse(value.contains("49.99")); XCTAssertFalse(value.contains(result.owner.input.taskID))
        }
    }

    func testPriceComparisonKeepsBoundariesCurrencyBasisFeesAndQualifiersDistinct() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50 total including fees.", field: "price", relation: "below")]
        let cases: [(String, Status)] = [("USD 49.99 total including fees", .quotedValueMatches),
            ("USD 50 total including fees", .quotedValueConflicts), ("USD 1,000.01 total including fees", .quotedValueConflicts),
            ("USD 40 total", .incompatibleLiteral), ("USD 40 per person including fees", .incompatibleLiteral),
            ("USD 40 total excluding fees", .incompatibleLiteral), ("CAD 40 total including fees", .incompatibleLiteral),
            ("$40 total including fees", .incompatibleLiteral), ("From USD 40 total including fees", .unparsedQuote),
            ("USD 40–60 total including fees", .unparsedQuote), ("USD 40 total including fees, subject to change", .unparsedQuote),
            ("USD 1,00 total including fees", .unparsedQuote), ("USD 40.999 total including fees", .unparsedQuote),
            ("USD 1000000000 total including fees", .unparsedQuote)]
        for (text, expected) in cases {
            let result = try await reading(rows, fields: [.init(.price, [text])])
            defer { result.fixture.close() }
            let candidate = try XCTUnwrap(result.batch.requirementAssessment?.candidates.first)
            XCTAssertEqual(candidate.requirements[1].status, expected, text)
            XCTAssertEqual(candidate.quotes[0].source, text)
        }
    }

    func testMultiplePricesCannotBeReducedToTheCheapestNumberAndMissingValuesStayMissing() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50.", field: "price", relation: "below")]
        let cases: [([Spec], Status)] = [([], .missingQuote),
            ([.init(.price, ["USD 40"]), .init(.price, ["USD 30"])], .ambiguousQuotes),
            ([.init(.price, ["USD 40", "USD 30"])], .unparsedQuote)]
        for (fields, expected) in cases {
            let result = try await reading(rows, fields: fields)
            defer { result.fixture.close() }
            let candidate = try XCTUnwrap(result.batch.requirementAssessment?.candidates.first)
            XCTAssertEqual(candidate.requirements[1].status, expected)
            XCTAssertEqual(candidate.quotes.count, fields.count)
        }
        let result = try await reading(rows, fields: [.init(.price, ["USD 40"])], extraHTML: "<p>From</p><p>Additional restrictions apply</p>")
        defer { result.fixture.close() }
        let candidate = try XCTUnwrap(result.batch.requirementAssessment?.candidates.first)
        XCTAssertEqual(candidate.requirements[1].status, .quotedValueMatches, "Only the numeric quotation compared; its applicability is unverified")
        XCTAssertEqual(candidate.requirements[0].status, .needsSemanticVerification)
        XCTAssertTrue(result.batch.candidates[0].texts.contains { $0.text == "From" && result.batch.candidates[0].unclassifiedTextIDs.contains($0.id) })
    }

    func testObservedDatesRequireAnExplicitCivilDayAndDoNotBorrowTheTaskClockForPageRelativeText() async throws {
        let rows = [row("Find concerts. "), row("After 2027-01-15.", field: "date", relation: "later")]
        for (text, expected) in [("2027-01-16", Status.quotedValueMatches), ("Jan 16, 2027", .quotedValueMatches),
                                 ("Date: 16 January 2027", .quotedValueMatches), ("January 15, 2027", .quotedValueConflicts),
                                 ("2027-02-29", .unparsedQuote), ("tomorrow", .unparsedQuote), ("01/16/2027", .unparsedQuote),
                                 ("Jan 16", .unparsedQuote), ("Jan 16, 2027 or later", .unparsedQuote)] {
            let result = try await reading(rows, fields: [.init(.date, [text])])
            defer { result.fixture.close() }
            XCTAssertEqual(result.batch.requirementAssessment?.candidates.first?.requirements[1].status, expected, text)
        }
    }

    func testSourceEligibilityAndResultCountRemainSeparateFromPriceAndQuotedTicketCount() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50. ", field: "price", relation: "below"),
                    row("3 tickets. ", field: "quantity", relation: "equal"),
                    row("Only report from tickets.test.", field: "answerSource", relation: "include", values: ["tickets.test"])]
        let result = try await reading(rows, fields: [.init(.price, ["USD 40"]), .init(.quantity, ["3 tickets"])])
        defer { result.fixture.close() }
        let candidate = try XCTUnwrap(result.batch.requirementAssessment?.candidates.first)
        XCTAssertEqual(candidate.requirements.map(\.status), [.needsSemanticVerification, .quotedValueMatches, .needsTicketInventory, .sourceOriginExcluded])
        XCTAssertEqual(candidate.quotes[1].literal, .quantity(3, .tickets))
        XCTAssertEqual(result.batch.documentAnswerSourceStatus, .excluded)
        XCTAssertEqual(result.fixture.server.count("/search?q=concerts"), 1)
    }

    func testQuantityAssessmentSeparatesOptionCountTicketsAndPartyDespiteMatchingQuotedNumbers() async throws {
        let rows = [row("Find concerts. "), row("3 options. ", field: "quantity"),
            row("2 tickets. ", field: "quantity"), row("2 adults.", field: "quantity")]
        let result = try await reading(rows, fields: [.init(.quantity, ["2 tickets"])])
        defer { result.fixture.close() }
        let assessment = try XCTUnwrap(result.batch.requirementAssessment)
        XCTAssertEqual(assessment.requirements.map(\.quantityScope), [nil, .resultSet, .ticketInventory, .party])
        let candidate = try XCTUnwrap(assessment.candidates.first)
        XCTAssertEqual(candidate.requirements.map(\.status), [.needsSemanticVerification, .needsResultSet, .needsTicketInventory, .needsPartyCapacity])
        XCTAssertEqual(candidate.quotes.first?.literal, .quantity(2, .tickets))
        XCTAssertEqual(candidate.requirements[1].quoteIndices, [])
        XCTAssertEqual(candidate.requirements[2].quoteIndices, [0])
        let context = assessment.plannerContext, requirements = try XCTUnwrap(context["requirements"] as? [[String: Any]])
        XCTAssertEqual(context["version"] as? Int, 3)
        XCTAssertEqual(requirements.dropFirst().map { $0["quantity_scope"] as? String }, ["resultSet", "ticketInventory", "party"])
        let linkInput = try XCTUnwrap(result.links.inputs.first), object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(linkInput.contextJSON.utf8)) as? [String: Any])
        let projected = try XCTUnwrap(object["requirement_assessment"] as? [String: Any])
        XCTAssertEqual((projected["candidates"] as? [[String: Any]])?.first?["requirements"] as? [String], candidate.requirements.map(\.status.rawValue))
        XCTAssertEqual(result.owner.input, result.interpretation.input)
    }

    func testQuantityReviewKeepsSelectedCountsLimitsPackagesAndConditionalCapacityDistinct() async throws {
        typealias Meaning = ComputerUseBrowserResultReview.QuantityMeaning
        let rows = [row("Find concerts. "), row("2 tickets. ", field: "quantity"), row("3 options.", field: "quantity")]
        let cases: [(String, Meaning, Status)] = [
            ("3 tickets", .availableQuantity, .quotedCapacitySufficient), ("0 tickets", .availableQuantity, .quotedCapacityInsufficient),
            ("3 tickets", .selectedQuantity, .reviewSelectedQuantity), ("3 tickets", .purchaseLimit, .reviewPurchaseLimit),
            ("3 tickets", .packageSize, .reviewPackageSize), ("3 tickets", .unknown, .reviewQuantityUnresolved),
            ("3 adults", .availableQuantity, .incompatibleLiteral), ("3 results", .availableQuantity, .incompatibleLiteral),
            ("1 ticket", .availableQuantity, .unparsedQuote),
            ("Up to 3 tickets", .unknown, .reviewQuantityUnresolved),
            ("3 tickets if released", .availableQuantity, .unparsedQuote)]
        for (text, meaning, expected) in cases {
            let result = try await reading(rows, fields: [.init(.quantity, [text])], extraHTML: "<p>Available for this offer</p>",
                reviewer: AssessmentInventoryReview(meanings: [meaning]))
            defer { result.fixture.close() }
            let assessment = try XCTUnwrap(result.batch.requirementAssessment), candidate = assessment.candidates[0]
            XCTAssertEqual(candidate.requirements.map(\.status), [.reviewRequirementUnresolved, expected, .needsResultSet])
            XCTAssertEqual(candidate.quotes[0].source, text)
            XCTAssertEqual(candidate.requirements[1].quoteIndices, [0])
            let review = try XCTUnwrap(result.batch.review)
            XCTAssertEqual(review.candidates[0].fields[1].quantity, meaning)
            try await result.fixture.browser.validateResultAssessment(assessment, reading: result.batch, interpretation: result.interpretation)
            let link = try XCTUnwrap(result.links.inputs.first)
            let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(link.contextJSON.utf8)) as? [String: Any])
            let projected = try XCTUnwrap(context["requirement_assessment"] as? [String: Any])
            XCTAssertEqual((projected["candidates"] as? [[String: Any]])?.first?["requirements"] as? [String], candidate.requirements.map(\.status.rawValue))
            let archive = try result.owner.researchEvidence(for: result.owner.input), recalled = try archive.recall(0, goal: result.owner.input)
            let observation = try XCTUnwrap(recalled["observation"] as? [String: Any])
            let reviews = try XCTUnwrap(observation["field_review"] as? [[String: Any]])
            let fields = try XCTUnwrap(reviews[0]["fields"] as? [[String: Any]])
            XCTAssertEqual(fields[1]["quantity"] as? String, meaning.rawValue)
            if meaning == .availableQuantity {
                let qualifiers = try XCTUnwrap(fields[1]["qualifiers"] as? [String])
                XCTAssertFalse(qualifiers.isEmpty); XCTAssertTrue(qualifiers.allSatisfy { $0.hasPrefix("r0/") })
            }
            XCTAssertEqual(result.fixture.server.count("/search?q=concerts"), 1)
            XCTAssertEqual(result.fixture.server.count("/details"), 0, "The helper requires a partial report, never completed research")
        }
    }

    func testCapacityComparisonRetainsAmbiguousQuotesAndSeparatesTicketAndAdultUnits() async throws {
        let rows = [row("Find concerts. "), row("2 tickets. ", field: "quantity"), row("2 adults.", field: "quantity")]
        let cases: [([String], [Status])] = [
            (["3 tickets", "0 adults"], [.quotedCapacitySufficient, .quotedCapacityInsufficient]),
            (["3 tickets", "4 tickets"], [.ambiguousQuotes, .incompatibleLiteral]),
            (["3 tickets", "Remaining quantity is conditional"], [.unparsedQuote, .unparsedQuote])]
        for (texts, expected) in cases {
            let result = try await reading(rows, fields: texts.map { .init(.quantity, [$0]) }, extraHTML: "<p>Available for this offer</p>",
                reviewer: AssessmentInventoryReview(meanings: Array(repeating: .availableQuantity, count: texts.count)))
            defer { result.fixture.close() }
            let candidate = try XCTUnwrap(result.batch.requirementAssessment?.candidates.first)
            XCTAssertEqual(Array(candidate.requirements.dropFirst().map(\.status)), expected)
            XCTAssertEqual(candidate.quotes.map(\.source), texts)
            if expected[0] == .quotedCapacitySufficient {
                XCTAssertEqual(candidate.requirements[1].quoteIndices, [0]); XCTAssertEqual(candidate.requirements[2].quoteIndices, [1])
            } else {
                XCTAssertEqual(candidate.requirements[1].quoteIndices, [0, 1])
            }
        }
    }

    func testTicketAnswerAddsInventoryWorkWithoutReplacingTheRequestedResultCountOrClock() async throws {
        let rows = [row("Find concerts. "), row("3 options.", field: "quantity")]
        let result = try await reading(rows, fields: [.init(.quantity, ["2 tickets"])])
        defer { result.fixture.close() }
        let original = result.owner.input
        let question = try result.owner.issueQuestion(topic: .quantity, requirementIDs: [result.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        let updated = try result.owner.answerQuestion(questionID: question.id, answerTaskID: "ticket-answer", answer: "2 tickets.", controllerID: "phone", controllerSessionID: "session")
        var answerRow = row("2 tickets.", field: "quantity"); answerRow["turn"] = 1
        let current = try proposal(rows + [answerRow], input: updated)
        result.goals.value = current
        _ = try await result.owner.interpretGoal()
        let sources = try XCTUnwrap(ComputerUseBrowserSourceRequirements(proposal: current).selectSources(from: [result.fixture.policy.provider]))
        try result.owner.configureResearchSources(sources)
        let reading = try await result.owner.readCandidates(), assessment = try XCTUnwrap(reading.requirementAssessment)
        XCTAssertEqual(assessment.requirements.map(\.quantityScope), [nil, .resultSet, .ticketInventory])
        XCTAssertEqual(assessment.candidates[0].requirements.map(\.status), [.needsSemanticVerification, .needsResultSet, .needsTicketInventory])
        XCTAssertEqual(ComputerUseBrowserResearchFormInput.normalizations(for: current).map(\.kind), [.ticketCount])
        XCTAssertEqual(updated.rootDigest, original.rootDigest); XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(updated.userTurns, [original.prompt, "2 tickets."])
        XCTAssertEqual(result.fixture.server.count("/search?q=concerts"), 1)
        try await result.fixture.browser.validateResultAssessment(assessment, reading: reading, interpretation: current)
    }

    func testAssessmentRequiresTheSameInterpretationFreshNativeReadingAndLiveControl() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50.", field: "price", relation: "below")]
        let result = try await reading(rows, fields: [.init(.price, ["USD 40"])])
        defer { result.fixture.close() }
        let assessment = try XCTUnwrap(result.batch.requirementAssessment), browser = result.fixture.browser
        let reinterpretation = try proposal([rows[0], row("Under USD 50.", field: "other")], input: result.owner.input)
        do { try await browser.validateResultAssessment(assessment, reading: result.batch, interpretation: reinterpretation); XCTFail("Source coverage alone does not preserve interpretation identity") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultError, .goalChanged) }
        result.owner.pause(); result.fixture.state.allowed = false
        do { try await browser.validateResultAssessment(assessment, reading: result.batch, interpretation: result.interpretation); XCTFail("No authority during user control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        result.fixture.state.allowed = true; try await result.owner.resumeAfterUserControl()
        let fresh = try await result.owner.readCandidates(), freshAssessment = try XCTUnwrap(fresh.requirementAssessment)
        XCTAssertNotEqual(freshAssessment, assessment)
        do { try await browser.validateResultAssessment(assessment, reading: result.batch, interpretation: result.interpretation); XCTFail("A fresh reading supersedes old evidence even on the same page") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        try await browser.validateResultAssessment(freshAssessment, reading: fresh, interpretation: result.interpretation)
        _ = try await browser.navigate(taskID: result.owner.taskID, operationID: "another-document", to: result.fixture.base.appendingPathComponent("details"))
        do { try await browser.validateResultAssessment(freshAssessment, reading: fresh, interpretation: result.interpretation); XCTFail("Old document cannot report") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
    }

    func testResearchDriverSuppliesAssessmentToLinkPlanningWithTheCompleteGoalAndPrivateBindings() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50. ", field: "price", relation: "below"), row("Do not buy.", role: "prohibition")]
        let result = try await reading(rows, fields: [.init(.price, ["USD 60"])])
        defer { result.fixture.close() }
        XCTAssertEqual(result.links.inputs.count, 1)
        let input = try XCTUnwrap(result.links.inputs.first)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        let goal = try XCTUnwrap(context["goal"] as? [String: Any]), assessment = try XCTUnwrap(context["requirement_assessment"] as? [String: Any])
        XCTAssertEqual(goal["request"] as? String, result.owner.input.prompt)
        XCTAssertEqual((goal["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, result.owner.input.referenceMilliseconds)
        let requirements = try XCTUnwrap(assessment["requirements"] as? [[String: Any]])
        XCTAssertEqual(requirements.count, rows.count); XCTAssertEqual(requirements.map { $0["index"] as? Int }, [0, 1, 2])
        let candidates = try XCTUnwrap(assessment["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates[0]["requirements"] as? [String], ["needsSemanticVerification", "quotedValueConflicts", "needsSemanticVerification"])
        for hidden in [result.owner.input.digest, result.interpretation.digest, result.batch.candidates[0].id,
                       result.fixture.base.absoluteString, result.interpretation.requirements[0].id] { XCTAssertFalse(input.contextJSON.contains(hidden)) }
        XCTAssertEqual(result.fixture.server.count("/details"), 0)
    }

    func testEmptyCandidateSelectionKeepsAllRequirementsAndDoesNotEstablishNoResults() async throws {
        let rows = [row("Find concerts. "), row("3 results.", field: "quantity", relation: "equal")]
        let result = try await reading(rows, fields: [], empty: true)
        defer { result.fixture.close() }
        let assessment = try XCTUnwrap(result.batch.requirementAssessment)
        XCTAssertEqual(assessment.requirements.map(\.id), result.interpretation.requirements.map(\.id))
        XCTAssertTrue(assessment.candidates.isEmpty)
        XCTAssertEqual(result.owner.input, result.interpretation.input)
        XCTAssertEqual(result.fixture.server.count("/search?q=concerts"), 1)
    }

    func testAcceptedAnswerAddsRequirementsWithoutReplacingTheOriginalRootClockOrEvidenceRevision() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50.", field: "price", relation: "below")]
        let result = try await reading(rows, fields: [.init(.price, ["USD 40"])])
        defer { result.fixture.close() }
        let original = result.owner.input, old = try XCTUnwrap(result.batch.requirementAssessment)
        let question = try result.owner.issueQuestion(topic: .location, requirementIDs: [result.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        let answer = "Paris. Do not buy."
        let updated = try result.owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: answer,
            controllerID: "phone", controllerSessionID: "session")
        var location = row("Paris. ", field: "location"), prohibition = row("Do not buy.", role: "prohibition")
        location["turn"] = 1; prohibition["turn"] = 1
        let freshInterpretation = try proposal(rows + [location, prohibition], input: updated)
        result.goals.value = freshInterpretation
        _ = try await result.owner.interpretGoal()
        let sources = try XCTUnwrap(ComputerUseBrowserSourceRequirements(proposal: freshInterpretation).selectSources(from: [result.fixture.policy.provider]))
        try result.owner.configureResearchSources(sources)
        let batch = try await result.owner.readCandidates(), assessment = try XCTUnwrap(batch.requirementAssessment)
        XCTAssertEqual(updated.rootDigest, original.rootDigest); XCTAssertEqual(updated.userTurns, [original.prompt, answer])
        XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds); XCTAssertEqual(updated.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(assessment.requirements.map(\.turn), [0, 0, 1, 1])
        XCTAssertEqual(assessment.candidates[0].requirements.map(\.status), [.needsSemanticVerification, .quotedValueMatches, .needsSemanticVerification, .needsSemanticVerification])
        XCTAssertNotEqual(assessment.interpretationDigest, old.interpretationDigest)
        do { try await result.fixture.browser.validateResultAssessment(old, reading: batch, interpretation: freshInterpretation); XCTFail("Accepted answers retire old assessment authority") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultError, .goalChanged) }
        XCTAssertEqual(result.fixture.server.count("/search?q=concerts"), 1)
    }

    func testOmittedPageRecordsCannotProduceAPositiveQuoteComparison() async throws {
        let rows = [row("Find concerts. "), row("Under USD 50.", field: "price", relation: "below")]
        let omitted = (0..<180).map { "<p>Additional condition \($0) must be retained when evaluating this particular concert ticket.</p>" }.joined()
        let result = try await reading(rows, fields: [.init(.price, ["USD 40"])], extraHTML: omitted)
        defer { result.fixture.close() }
        let assessment = try XCTUnwrap(result.batch.requirementAssessment)
        XCTAssertEqual(assessment.candidates.first?.requirements[1].status, .incompletePage)
        XCTAssertEqual(assessment.candidates.first?.quotes.first?.source, "USD 40")
    }

    func testPriceAnswersReachNativeCandidateAssessmentWithoutReplacingOrRepeatingTheResearchTask() async throws {
        var rows = [row("Find concerts. "), row("Under $50.", field: "price", relation: "below")]
        let result = try await reading(rows, fields: [.init(.price, ["USD 40 per ticket including fees"])])
        defer { result.fixture.close() }
        let original = result.owner.input
        XCTAssertEqual(result.batch.requirementAssessment?.candidates[0].requirements[1].status, .incompatibleLiteral)
        var current = result.interpretation
        let answers: [(ComputerUseBrowserClarificationTopic, String)] = [(.currency, "USD"), (.priceBasis, "per ticket"), (.fees, "including fees")]
        for (index, value) in answers.enumerated() {
            let question = try result.owner.issueQuestion(topic: value.0, requirementIDs: [current.requirements[1].id],
                controllerID: "phone", controllerSessionID: "session")
            let input = try result.owner.answerQuestion(questionID: question.id, answerTaskID: "price-answer-\(index)", answer: value.1,
                controllerID: "phone", controllerSessionID: "session")
            // A mistaken source label on the literal USD answer must not
            // create an unrelated website restriction or source question.
            var answerRow = row(value.1, field: index == 0 ? "source" : "price")
            answerRow["turn"] = index + 1; rows.append(answerRow)
            current = try proposal(rows, input: input); result.goals.value = current
            _ = try await result.owner.interpretGoal()
            XCTAssertNil(try result.owner.proposedQuestionRequest())
            let sources = try XCTUnwrap(ComputerUseBrowserSourceRequirements(proposal: current).selectSources(from: [result.fixture.policy.provider]))
            try result.owner.configureResearchSources(sources)
            let batch = try await result.owner.readCandidates(), assessment = try XCTUnwrap(batch.requirementAssessment)
            XCTAssertEqual(assessment.candidates[0].requirements[1].status, .quotedValueMatches)
            XCTAssertEqual(assessment.candidates[0].requirements.dropFirst(2).map(\.status), Array(repeating: .clarificationApplied, count: index + 1))
            XCTAssertEqual(input.rootDigest, original.rootDigest); XCTAssertEqual(input.referenceMilliseconds, original.referenceMilliseconds)
            XCTAssertEqual(input.userTurns, [original.prompt] + answers.prefix(index + 1).map { $0.1 })
            try await result.fixture.browser.validateResultAssessment(assessment, reading: batch, interpretation: current)
        }
        XCTAssertEqual(result.fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(result.fixture.server.count("/details"), 0)
    }

    func testScopedDateAnswerReachesFreshNativeAssessmentWithoutRepeatingTheSearch() async throws {
        var rows = [row("Find concerts. "), row("Friday.", field: "date")]
        let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>2026-10-16</p>")
        defer { fixture.close() }
        let original = try ComputerUseBrowserGoalInput(taskID: ResearchDriverFixture.root, prompt: "Find concerts. Friday.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let initial = try proposal(rows, input: original), goals = AssessmentGoalFixture(value: initial)
        let driver = ComputerUseBrowserResearchDriver(goalPlanner: goals,
            resultPlanner: AssessmentResultFixture(fields: [.init(.date, ["2026-10-16"])], empty: false),
            searchPlanner: fixture.search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(),
            planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: AssessmentLinkFixture()),
            now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
        let first = try await driver.executeBrowserResearch(taskID: original.taskID, prompt: original.prompt, tools: fixture.tools, progress: { _ in })
        guard case .browserClarificationRequired(let request)? = first else { return XCTFail("A resolvable weekday must reach the real question route before search") }
        let owner = try fixture.owner()
        XCTAssertEqual(request.topic, .date)
        XCTAssertEqual(request.requirementIDs, [initial.requirements[1].id])
        XCTAssertFalse(fixture.browser.hasSession); XCTAssertEqual(fixture.server.requestCount, 0)
        XCTAssertTrue(fixture.search.inputs.isEmpty)
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "phone", controllerSessionID: "session")
        let input = try owner.answerQuestion(questionID: question.id, answerTaskID: "event-date", answer: "2026-10-16",
            controllerID: "phone", controllerSessionID: "session")
        var answer = row("2026-10-16", field: "source"); answer["turn"] = 1; rows.append(answer)
        let current = try proposal(rows, input: input); goals.value = current
        let continued = try await driver.continueBrowserResearch(taskID: "event-date", research: owner, tools: fixture.tools, progress: { _ in })
        guard case .browserResearchProgress = continued else { return XCTFail("The scoped answer must allow the retained research to continue") }
        XCTAssertNil(try owner.proposedQuestionRequest(), "A bound date answer cannot become a website restriction")
        let batch = try await owner.readCandidates(), assessment = try XCTUnwrap(batch.requirementAssessment)
        XCTAssertEqual(assessment.candidates[0].requirements.map(\.status), [.needsSemanticVerification, .quotedValueMatches, .clarificationApplied])
        XCTAssertEqual(input.rootDigest, original.rootDigest)
        XCTAssertEqual(input.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(input.userTurns, [original.prompt, "2026-10-16"])
        try await fixture.browser.validateResultAssessment(assessment, reading: batch, interpretation: current)
        _ = try await driver.continueBrowserResearch(taskID: "event-date", research: owner, tools: fixture.tools, progress: { _ in })
        XCTAssertEqual(fixture.search.inputs.map(\.input), [input])
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
    }

    func testNativeDateAndPriceClarificationConflictsRemainUncompiledAfterAnswerRelabeling() async throws {
        for (source, field, topic, answerText) in [("2026-10-16.", "date", ComputerUseBrowserClarificationTopic.date, "2026-10-15"),
            ("Under USD 50.", "price", .currency, "CAD")] {
            for answerField in ["category", "location", "other"] {
                var rows = [row("Find concerts. "), row(source, field: field)]
                let result = try await reading(rows, fields: [.init(.date, ["2026-10-16"]), .init(.price, ["USD 40"])])
                defer { result.fixture.close() }
                let question = try result.owner.issueQuestion(topic: topic, requirementIDs: [result.interpretation.requirements[1].id],
                    controllerID: "phone", controllerSessionID: "session")
                let input = try result.owner.answerQuestion(questionID: question.id, answerTaskID: "conflicting-answer", answer: answerText,
                    controllerID: "phone", controllerSessionID: "session")
                var answer = row(answerText, field: answerField); answer["turn"] = 1; rows.append(answer)
                let current = try proposal(rows, input: input); result.goals.value = current
                _ = try await result.owner.interpretGoal()
                let sources = try XCTUnwrap(ComputerUseBrowserSourceRequirements(proposal: current).selectSources(from: [result.fixture.policy.provider]))
                try result.owner.configureResearchSources(sources)
                let batch = try await result.owner.readCandidates(), assessment = try XCTUnwrap(batch.requirementAssessment)
                XCTAssertEqual(assessment.candidates[0].requirements[1].status, .uncompiledRequirement)
                XCTAssertEqual(assessment.candidates[0].requirements[2].status, .uncompiledRequirement,
                    "Changing a native-conflicting answer to \(answerField) cannot send it to semantic review")
            }
        }
    }

    private struct Reading {
        let fixture: ResearchDriverFixture
        let owner: ComputerUseBrowserResearchTask
        let interpretation: ComputerUseBrowserGoalProposal
        let batch: ComputerUseBrowserResultCandidates
        let links: AssessmentLinkFixture
        let goals: AssessmentGoalFixture
    }
    private func reading(_ rows: [[String: Any]], fields: [Spec], extraHTML: String = "", empty: Bool = false,
                         reviewer: (any ComputerUseBrowserResultReviewPlanning)? = nil) async throws -> Reading {
        func escaped(_ source: String) -> String { source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let html = fields.flatMap(\.texts).map { "<p>" + escaped($0) + "</p>" }.joined() + extraHTML
        let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: html)
        do {
            let input = try ComputerUseBrowserGoalInput(taskID: ResearchDriverFixture.root, prompt: rows.compactMap { $0["source"] as? String }.joined(),
                referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
            let interpretation = try proposal(rows, input: input), links = AssessmentLinkFixture(), goals = AssessmentGoalFixture(value: interpretation)
            let base = AssessmentResultFixture(fields: fields, empty: empty)
            let reader: any ComputerUseBrowserResultPlanning
            if let reviewer { reader = ComputerUseReviewedBrowserResultPlanner(reader: base, reviewer: reviewer) }
            else { reader = base }
            let driver = ComputerUseBrowserResearchDriver(goalPlanner: goals,
                resultPlanner: reader, searchPlanner: fixture.search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(),
                planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: links),
                now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
            let result = try await driver.executeBrowserResearch(taskID: input.taskID, prompt: input.prompt, tools: fixture.tools, progress: { _ in })
            if empty {
                guard case .userInterventionRequired = result else { throw ComputerUseBrowserResearchDriver.Failure.invalidProposal }
            } else {
                guard case .browserResearchProgress = result else { throw ComputerUseBrowserResearchDriver.Failure.invalidProposal }
            }
            let owner = try fixture.owner(), batch = try await owner.readCandidates()
            return .init(fixture: fixture, owner: owner, interpretation: interpretation, batch: batch, links: links, goals: goals)
        } catch { fixture.close(); throw error }
    }
    private func row(_ source: String, role: String? = nil, field: String = "category", relation: String = "unspecified", values: [String] = []) -> [String: Any] {
        ["turn":0, "source":source, "role":role ?? (field == "category" ? "outcome" : "condition"), "field":field, "relation":relation, "values":values]
    }
    private func proposal(_ rows: [[String: Any]], input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        let data = try JSONSerialization.data(withJSONObject: ["disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

@MainActor
private final class AssessmentGoalFixture: ComputerUseBrowserGoalPlanning {
    var value: ComputerUseBrowserGoalProposal
    init(value: ComputerUseBrowserGoalProposal) { self.value = value }
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        guard value.input == input else { throw ComputerUseBrowserGoalPlanError.invalidInput }
        return value
    }
}

@MainActor
private final class AssessmentLinkFixture: ComputerUseBrowserLinkPlanning {
    var inputs: [ComputerUseBrowserLinkSelectionInput] = []
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        inputs.append(input)
        return try .decode(content: #"{"candidate":-1,"link":""}"#, input: input)
    }
}

private struct AssessmentResultFixture: ComputerUseBrowserResultPlanning {
    struct Spec: Sendable {
        let kind: ComputerUseBrowserResultProposal.Kind
        let texts: [String]
        init(_ kind: ComputerUseBrowserResultProposal.Kind, _ texts: [String]) { self.kind = kind; self.texts = texts }
    }
    let fields: [Spec]
    let empty: Bool
    func propose(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput) async throws -> ComputerUseBrowserResultProposal {
        if empty { return try .decode(content: #"{"candidates":[]}"#, input: page, goal: goal) }
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.contextJSON.utf8)) as? [String: Any])
        let records = try XCTUnwrap(context["records"] as? [[String: Any]])
        func text(_ value: String) throws -> [String: Any] { try XCTUnwrap(records.first { $0["kind"] as? String == "text" && $0["text"] as? String == value }) }
        let title = try text("Concert Alpha")
        var container = try XCTUnwrap(title["group"] as? String)
        while let node = records.first(where: { $0["kind"] as? String == "container" && $0["id"] as? String == container }), node["element"] as? String != "article" {
            container = try XCTUnwrap(node["parent"] as? String)
        }
        var rows: [[String: Any]] = [["kind":"title", "texts":[try XCTUnwrap(title["id"] as? String)]]]
        for field in fields { rows.append(["kind":field.kind.rawValue, "texts":try field.texts.map { try XCTUnwrap(text($0)["id"] as? String) }]) }
        let link = try XCTUnwrap(records.first { $0["kind"] as? String == "link" && $0["label"] as? String == "Alpha details" })
        let data = try JSONSerialization.data(withJSONObject: ["candidates":[["container":container, "fields":rows, "links":[try XCTUnwrap(link["id"] as? String)]]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: page, goal: goal)
    }
}

/// Deliberately supplies semantic proposals, including incorrect proposals in
/// negative cases. It cannot bypass the full review or native quote admission.
private struct AssessmentInventoryReview: ComputerUseBrowserResultReviewPlanning {
    let meanings: [ComputerUseBrowserResultReview.QuantityMeaning]
    func propose(_ input: ComputerUseBrowserResultReviewInput) async throws -> ComputerUseBrowserResultReview {
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        let page = try XCTUnwrap(context["page"] as? [String: Any]), records = try XCTUnwrap(page["records"] as? [[String: Any]])
        let qualifier = try XCTUnwrap(records.first { $0["text"] as? String == "Available for this offer" }?["id"] as? String)
        let candidates: [[String: Any]] = try (0..<input.candidateCount).map { candidate in
            var next = 0
            let fields: [[String: Any]] = try (0..<input.fieldCounts[candidate]).map { field in
                var meaning = ComputerUseBrowserResultReview.QuantityMeaning.notQuantity
                if input.fieldKind(candidate: candidate, field: field) == .quantity {
                    guard meanings.indices.contains(next) else { throw ComputerUseBrowserResultReviewError.invalidInput }
                    meaning = meanings[next]; next += 1
                }
                return ["scope":"offer", "price":"notPrice", "quantity":meaning.rawValue,
                    "qualifiers":meaning == .availableQuantity ? [qualifier] : []]
            }
            return ["association":"singleOffer", "fields":fields,
                "requirements":(0..<input.requirementCount).map { ["requirement":$0, "judgment":"unknown", "texts":[]] as [String: Any] }]
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates":candidates]), as: UTF8.self)
        return try .decode(content: content, input: input)
    }
}
