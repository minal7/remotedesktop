import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseBrowserScalarRequirementsTests: XCTestCase {
    private typealias Scalar = ComputerUseBrowserScalarRequirements

    func testQuantityChoiceLabelsRequireOneCompleteExactCountAndOptionalUnit() {
        let cases: [(String, Int64, Scalar.QuantityUnit?)] = [("2", 2, nil), ("  two  adults  ", 2, .adults),
            ("1 child", 1, .children), ("0 children", 0, .children), ("03 tickets", 3, .tickets), ("1998 people", 1998, .people)]
        for (label, count, unit) in cases {
            let value = Scalar.exactQuantityChoiceLabel(label)
            XCTAssertEqual(value?.count, count, label); XCTAssertEqual(value?.unit, unit, label)
        }
        for label in ["", "-1", "+2", "2.0", "2+", "2–3", "at most 2", "exactly 2", "for 2", "2 adults and 1 child",
                      "2 adults aged 12+", "2 tickets $99", "2 packages", "1999 people", "999999999999999999999"] {
            XCTAssertNil(Scalar.exactQuantityChoiceLabel(label), label)
        }
    }

    func testPartyMeaningAndComponentSourcesSurviveEverySupportedRowBoundary() throws {
        let partitions: [([String], [[Int]])] = [(["2 adults and 1 child."], [[1], [1]]),
            (["2 adults ", "and ", "1 child."], [[1], [3]]), (["2", " adults and ", "1", " child."], [[1, 2], [3, 4]]),
            (["2 ad", "ults and 1 ch", "ild."], [[1, 2], [2, 3]])]
        for (parts, expectedSources) in partitions {
            let rows = [row("Find concerts in Montréal. ", role: "outcome")] + parts.map { row($0, field: ["and ", " adults and ", " child."].contains($0) ? "other" : "quantity") }
            let ledger = Scalar(proposal: try proposal(rows)), ids = Array(ledger.entries.dropFirst().map(\.requirementID))
            for index in 1..<ledger.entries.count {
                let bound = try condition(ledger, at: index)
                XCTAssertEqual(bound.predicate, .party(try XCTUnwrap(Scalar.PartyComposition(adults: 2, children: 1))))
                XCTAssertEqual(bound.sourceRequirementIDs, ids)
                XCTAssertTrue(ledger.nativeScalarSourceIDs.contains(bound.requirementID))
            }
            let normalized = ComputerUseBrowserResearchFormInput.normalizations(for: ledger.proposal)
            XCTAssertEqual(normalized.map(\.value), ["2", "1", "3"])
            XCTAssertEqual(normalized.map(\.unit), ["adults", "children", "people"])
            XCTAssertEqual(normalized.map(\.requirementIndices), expectedSources + [Array(1...parts.count)])
        }
    }

    func testPartyGroupingDoesNotChooseOverlappingGroupsOrEraseProhibitionsAndBounds() throws {
        let rows = [row("Find concerts. ", role: "outcome"), row("2 adults ", field: "quantity"), row("and "),
            row("1 child ", field: "quantity"), row("and "), row("3 adults.", field: "quantity")]
        let ledger = Scalar(proposal: try proposal(rows))
        for entry in ledger.entries.dropFirst() { XCTAssertEqual(entry.resolution, .unresolved(.ambiguousPartyScope)) }
        XCTAssertTrue(ComputerUseBrowserResearchFormInput.normalizations(for: ledger.proposal).isEmpty)
        for first in [row("2 adults ", role: "prohibition", field: "quantity"), row("at least 2 adults ", field: "quantity")] {
            let held = Scalar(proposal: try proposal([row("Find concerts. ", role: "outcome"), first, row("and 1 child.", field: "quantity")]))
            XCTAssertFalse(held.entries.contains { if case .bound(let condition) = $0.resolution, case .party = condition.predicate { return true }; return false })
        }
        for modifier in ["at least ", "at most ", "not ", "without "] {
            let held = Scalar(proposal: try proposal([row("Find concerts. ", role: "outcome"), row(modifier),
                row("2 adults ", field: "quantity"), row("and 1 child.", field: "quantity")]))
            for entry in held.entries.dropFirst(2) { XCTAssertEqual(entry.resolution, .unresolved(.ambiguousPartyScope)) }
            XCTAssertTrue(ComputerUseBrowserResearchFormInput.normalizations(for: held.proposal).isEmpty)
        }
    }

    func testMixedPartyGrammarKeepsBothCategoriesAndCanonicalizesTheirOrder() throws {
        let party = try XCTUnwrap(Scalar.PartyComposition(adults: 2, children: 1))
        for source in ["2 adults and 1 child", "1 child, 2 adults", "for two adults & one child.",
            "exactly 2 adults, and 1 child", "2 adults 1 child"] {
            let bound = try compile(source, field: "quantity")
            XCTAssertEqual(bound.predicate, .party(party))
            XCTAssertEqual(bound.evaluate(.party(party)), .satisfied)
            XCTAssertEqual(bound.evaluate(.quantity(3, .people)), .unverifiable)
        }
        XCTAssertEqual(try compile("2 adults and 0 children", field: "quantity").predicate,
            .party(try XCTUnwrap(Scalar.PartyComposition(adults: 2, children: 0))))
        for source in ["2 adults or 1 child", "2 adults and 1 adult", "2 adults and 1 infant", "2 adults and 1 child aged 8",
            "at least 2 adults and 1 child", "2 adults and 1000 children", "2 tickets and 1 child"] {
            XCTAssertEqual(try resolution(source, field: "quantity"), .unresolved(.unrecognizedSource))
        }
        XCTAssertEqual(try resolution("2 adults and 1 child", field: "quantity", relation: "above"), .unresolved(.contradictoryProposal))
    }

    func testMixedPartyCapacityNeedsEachRequestedCategoryAndHonorsAnAdditionalTotal() throws {
        let party = try XCTUnwrap(Scalar.PartyComposition(adults: 2, children: 1))
        XCTAssertEqual(party.total, 3)
        XCTAssertEqual(party.compareCapacity(adults: 3, children: 2), .satisfied)
        XCTAssertEqual(party.compareCapacity(adults: 1, children: 2), .notSatisfied)
        XCTAssertEqual(party.compareCapacity(adults: 2, children: 1, people: 2), .notSatisfied)
        XCTAssertEqual(party.compareCapacity(adults: 2, children: 1, people: 3), .satisfied)
        XCTAssertEqual(party.compareCapacity(adults: nil, children: nil, people: 3), .unverifiable)
        XCTAssertEqual(party.compareCapacity(adults: 3, children: nil), .unverifiable)
        XCTAssertEqual(party.compareCapacity(adults: -1, children: 1), .unverifiable)
        let noChildren = try XCTUnwrap(Scalar.PartyComposition(adults: 2, children: 0))
        XCTAssertEqual(noChildren.compareCapacity(adults: 2, children: nil), .satisfied)
        let condition = try compile("2 adults and 1 child", field: "quantity")
        let larger = try XCTUnwrap(Scalar.PartyComposition(adults: 3, children: 2))
        XCTAssertEqual(condition.compareLiteral(.party(larger)), .notSatisfied)
        XCTAssertEqual(condition.compareProposedCapacity(.party(larger)), .satisfied)
        XCTAssertNil(Scalar.PartyComposition(adults: -1, children: 1))
        XCTAssertNil(Scalar.PartyComposition(adults: 2, children: 1000))
    }

    func testSingularQuantitiesKeepTheirUnitsAndBareCountsRequireAUnit() throws {
        let aliases: [(String, Scalar.QuantityUnit)] = [("result", .results), ("option", .options), ("flight", .flights),
            ("concert", .concerts), ("movie", .movies), ("ticket", .tickets), ("person", .people),
            ("persons", .people), ("adult", .adults), ("child", .children)]
        for (literal, unit) in aliases {
            XCTAssertEqual(try compile("1 " + literal, field: "quantity").predicate, .quantity(.equal, 1, unit))
        }
        for source in ["2", "three", "at least 2", "for exactly 1."] {
            XCTAssertEqual(try resolution(source, field: "quantity"), .unresolved(.missingQuantityUnit))
        }
        XCTAssertEqual(try resolution("at least 2", field: "quantity", relation: "below"), .unresolved(.contradictoryProposal))
        for source in ["1000 tickets", "-1 ticket", "1.5 adults", "2 infants", "tickets"] {
            XCTAssertEqual(try resolution(source, field: "quantity"), .unresolved(.unrecognizedSource))
        }
    }

    func testScalarLedgerRetainsEveryRequirementAndUnresolvedDisposition() throws {
        let rows = [row("Find flights ", role: "outcome", field: "category"),
            row("from San Francisco ", field: "origin"), row("to Los Angeles ", field: "destination"),
            row("on 2026-09-20 ", field: "date"), row("under USD 500 total including fees. ", field: "price"),
            row("Do not book. ", role: "prohibition"), row("Compare again.", role: "order")]
        let ledger = Scalar(proposal: try proposal(rows))
        XCTAssertEqual(ledger.entries.map(\.requirementID), ledger.proposal.requirements.map(\.id))
        XCTAssertEqual(ledger.entries.count, rows.count)
        XCTAssertEqual(ledger.unresolvedRequirementIDs, [0, 1, 2, 5, 6].map { ledger.entries[$0].requirementID })
        _ = try condition(ledger, at: 3); _ = try condition(ledger, at: 4)
        XCTAssertEqual(ledger.proposal.requirements.compactMap { ledger.proposal.source(of: $0) }.joined(), ledger.proposal.input.prompt)
        for text in [String(describing: ledger), String(reflecting: ledger), String(reflecting: try condition(ledger, at: 4))] {
            XCTAssertFalse(text.contains("San Francisco")); XCTAssertFalse(text.contains("500"))
        }
        for disposition in ["unsupported", "clarification"] {
            let unresolved = Scalar(proposal: try proposal(rows, disposition: disposition))
            XCTAssertEqual(unresolved.unresolvedRequirementIDs, unresolved.entries.map(\.requirementID))
            for entry in unresolved.entries { XCTAssertEqual(entry.resolution, .unresolved(.unresolvedDisposition)) }
        }
    }

    func testQuantityComparisonsKeepTicketAndResultUnitsDistinct() throws {
        let cases: [(String, Scalar.Comparison, [Scalar.Evaluation])] = [
            ("three tickets", .equal, [.notSatisfied, .satisfied, .notSatisfied]),
            ("at least 3 tickets", .atLeast, [.notSatisfied, .satisfied, .satisfied]),
            ("at most 3 tickets", .atMost, [.satisfied, .satisfied, .notSatisfied]),
            ("more than 3 tickets", .above, [.notSatisfied, .notSatisfied, .satisfied]),
            ("fewer than 3 tickets", .below, [.satisfied, .notSatisfied, .notSatisfied])]
        for (source, comparison, expected) in cases {
            let bound = try compile(source, field: "quantity")
            XCTAssertEqual(bound.predicate, .quantity(comparison, 3, .tickets))
            XCTAssertEqual([2, 3, 4].map { bound.evaluate(.quantity($0, .tickets)) }, expected)
            XCTAssertEqual(bound.evaluate(.quantity(3, .results)), .unverifiable)
            XCTAssertEqual(bound.evaluate(.quantity(-1, .tickets)), .unverifiable)
            XCTAssertEqual(bound.evaluate(.day(try civil("2026-09-20"))), .unverifiable)
        }
        for unit in [Scalar.QuantityUnit.results, .options, .flights, .concerts, .movies] {
            let bound = try compile("and exactly 10 \(unit.rawValue).", field: "quantity")
            XCTAssertEqual(bound.predicate, .quantity(.equal, 10, unit))
        }
        XCTAssertEqual(try compile("0 results", field: "quantity").evaluate(.quantity(0, .results)), .satisfied)
        XCTAssertEqual(try compile("999 results", field: "quantity").evaluate(.quantity(999, .results)), .satisfied)
    }

    func testQuantityScopesDistinguishListingsTicketInventoryAndPartyWithoutConvertingUnits() throws {
        let groups: [(Scalar.QuantityScope, [Scalar.QuantityUnit])] = [
            (.resultSet, [.results, .options, .flights, .concerts, .movies]),
            (.ticketInventory, [.tickets]), (.party, [.people, .adults, .children])]
        for (scope, units) in groups {
            for unit in units {
                XCTAssertEqual(unit.scope, scope)
                let condition = try compile("two \(unit.rawValue)", field: "quantity")
                XCTAssertEqual(condition.predicate, .quantity(.equal, 2, unit))
                for other in groups.flatMap({ $0.1 }) where other != unit {
                    XCTAssertEqual(condition.compareLiteral(.quantity(2, other)), .unverifiable)
                }
            }
        }
        XCTAssertFalse(Scalar.QuantityUnit.tickets.isPartySize)
        // An arithmetic count comparison is still not an availability test:
        // a page's number may mean stock, pack size or a purchase limit.
        XCTAssertEqual(try compile("two tickets", field: "quantity").compareLiteral(.quantity(3, .tickets)), .notSatisfied)
    }

    func testProposedCapacityArithmeticRequiresMatchingInventoryUnitsAndAnExactOrMinimumRequest() throws {
        for unit in [Scalar.QuantityUnit.tickets, .people, .adults, .children] {
            for source in ["two", "at least 2"] {
                let bound = try compile("\(source) \(unit.rawValue)", field: "quantity")
                XCTAssertEqual([1, 2, 3].map { bound.compareProposedCapacity(.quantity($0, unit)) }, [.notSatisfied, .satisfied, .satisfied])
                XCTAssertEqual(bound.compareProposedCapacity(.quantity(-1, unit)), .unverifiable)
                for other in [Scalar.QuantityUnit.results, .tickets, .people, .adults, .children] where other != unit {
                    XCTAssertEqual(bound.compareProposedCapacity(.quantity(3, other)), .unverifiable)
                }
            }
            let above = try compile("more than 2 \(unit.rawValue)", field: "quantity")
            XCTAssertEqual(above.compareProposedCapacity(.quantity(2, unit)), .notSatisfied)
            XCTAssertEqual(above.compareProposedCapacity(.quantity(3, unit)), .satisfied)
            for source in ["at most 2", "fewer than 2"] {
                XCTAssertEqual(try compile("\(source) \(unit.rawValue)", field: "quantity").compareProposedCapacity(.quantity(3, unit)), .unverifiable)
            }
        }
        XCTAssertEqual(try compile("two results", field: "quantity").compareProposedCapacity(.quantity(3, .results)), .unverifiable)
        let tickets = try compile("two tickets", field: "quantity")
        XCTAssertEqual(tickets.compareLiteral(.quantity(3, .tickets)), .notSatisfied, "Literal equality keeps its original meaning")
        XCTAssertEqual(tickets.compareProposedCapacity(.day(try civil("2027-01-16"))), .unverifiable)
    }

    func testPriceComparisonUsesExactDecimalAndStrictOrInclusiveBounds() throws {
        let cases: [(String, Scalar.Comparison, [Scalar.Evaluation])] = [
            ("under", .below, [.satisfied, .notSatisfied, .notSatisfied]),
            ("at most", .atMost, [.satisfied, .satisfied, .notSatisfied]),
            ("over", .above, [.notSatisfied, .notSatisfied, .satisfied]),
            ("at least", .atLeast, [.notSatisfied, .satisfied, .satisfied]),
            ("exactly", .equal, [.notSatisfied, .satisfied, .notSatisfied])]
        for (source, comparison, expected) in cases {
            let bound = try compile("\(source) USD 1,234.50 per ticket including fees", field: "price")
            XCTAssertEqual(bound.predicate, .price(comparison, try amount(123_450), .perTicket, .included))
            let actual = try [123_449, 123_450, 123_451].map {
                bound.evaluate(.price(try amount($0), .perTicket, .included, isExact: true))
            }
            XCTAssertEqual(actual, expected)
        }
        for (source, hundredths) in [("USD 0", Int64(0)), ("USD 0.1", 10), ("USD 0.29", 29), ("USD 999,999,999.99", 99_999_999_999)] {
            let bound = try compile("exactly " + source, field: "price")
            XCTAssertEqual(bound.predicate, .price(.equal, try amount(hundredths), .unspecified, .unspecified))
        }
        XCTAssertNil(Scalar.Amount(hundredths: -1, currency: .usd))
        XCTAssertNil(Scalar.Amount(hundredths: 100_000_000_000, currency: .usd))
    }

    func testPriceEvaluationCannotInventCurrencyBasisFeesOrExactness() throws {
        let bound = try compile("under $500 total including fees", field: "price")
        let dollars = try amount(49_999, currency: .dollarSymbol)
        XCTAssertEqual(bound.evaluate(.price(dollars, .total, .included, isExact: true)), .satisfied)
        XCTAssertEqual(bound.evaluate(.price(try amount(49_999), .total, .included, isExact: true)), .unverifiable,
            "A dollar symbol does not establish USD")
        XCTAssertEqual(bound.evaluate(.price(dollars, .perPerson, .included, isExact: true)), .unverifiable)
        XCTAssertEqual(bound.evaluate(.price(dollars, .unspecified, .included, isExact: true)), .unverifiable)
        XCTAssertEqual(bound.evaluate(.price(dollars, .total, .excluded, isExact: true)), .unverifiable)
        XCTAssertEqual(bound.evaluate(.price(dollars, .total, .unspecified, isExact: true)), .unverifiable)
        XCTAssertEqual(bound.evaluate(.price(dollars, .total, .included, isExact: false)), .unverifiable,
            "A starting-at or estimated amount is not an exact offer price")
        for currency in [Scalar.Currency.usd, .eur, .gbp, .cad, .aud, .jpy, .dollarSymbol, .euroSymbol, .poundSymbol, .yenSymbol] {
            let condition = try compile("exactly \(currency.rawValue) 15 per person excluding fees", field: "price")
            XCTAssertEqual(condition.predicate, .price(.equal, try amount(1_500, currency: currency), .perPerson, .excluded))
        }
        let unspecified = try compile("under USD 500", field: "price")
        XCTAssertEqual(unspecified.predicate, .price(.below, try amount(50_000), .unspecified, .unspecified))
        // This only compares the scalar explicitly requested. Separate offer
        // scope, provenance and completeness gates remain necessary.
        XCTAssertEqual(unspecified.evaluate(.price(try amount(49_999), .perTicket, .unspecified, isExact: true)), .satisfied)
    }

    func testRelativeDaysUseOriginalClockAndCalendarAcrossDaylightSaving() throws {
        let clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z"))
        let rows = [row("Find movie tickets ", role: "outcome"), row("today ", field: "date"), row("and tomorrow.", field: "date")]
        let input = try proposal(rows, referenceDate: clock, timeZone: "America/Los_Angeles")
        let ledger = Scalar(proposal: input)
        let today = try condition(ledger, at: 1), tomorrow = try condition(ledger, at: 2)
        XCTAssertEqual(today.evaluate(.day(try civil("2026-03-07"))), .satisfied)
        XCTAssertEqual(tomorrow.evaluate(.day(try civil("2026-03-08"))), .satisfied)
        XCTAssertEqual(tomorrow.evaluate(.day(try civil("2026-03-09"))), .notSatisfied,
            "Adding 86,400 seconds to the reference instant crosses to March 9 locally")
        let resumed = Scalar(proposal: input)
        XCTAssertEqual(resumed.entries, ledger.entries, "Recompilation has no new wall-clock input")
        let utc = Scalar(proposal: try proposal(rows, referenceDate: clock, timeZone: "UTC"))
        XCTAssertEqual(try condition(utc, at: 1).evaluate(.day(try civil("2026-03-08"))), .satisfied)
        XCTAssertNotEqual(try condition(utc, at: 1).id, today.id)
    }

    func testCivilDatesRejectInvalidDaysAndPreserveRangeEndpoints() throws {
        for (year, month, day) in [(2026, 2, 29), (1900, 2, 29), (2026, 4, 31), (2026, 0, 1), (2026, 13, 1), (0, 1, 1), (10_000, 1, 1)] {
            XCTAssertNil(Scalar.CivilDay(year: year, month: month, day: day))
        }
        XCTAssertNotNil(Scalar.CivilDay(year: 2000, month: 2, day: 29))
        XCTAssertEqual(try civil("0001-01-01").iso8601, "0001-01-01")
        let cases: [(String, [Scalar.Evaluation])] = [
            ("on 2028-02-29", [.notSatisfied, .satisfied, .notSatisfied]),
            ("before 2028-02-29", [.satisfied, .notSatisfied, .notSatisfied]),
            ("on or before 2028-02-29", [.satisfied, .satisfied, .notSatisfied]),
            ("after 2028-02-29", [.notSatisfied, .notSatisfied, .satisfied]),
            ("on or after 2028-02-29", [.notSatisfied, .satisfied, .satisfied])]
        for (source, expected) in cases {
            let bound = try compile(source, field: "date")
            XCTAssertEqual(try ["2028-02-28", "2028-02-29", "2028-03-01"].map { bound.evaluate(.day(try civil($0))) }, expected)
        }
        let range = try compile("from 2028-02-29 through 2028-03-01", field: "date", relation: "between")
        XCTAssertEqual(range.evaluate(.day(try civil("2028-02-29"))), .satisfied)
        XCTAssertEqual(range.evaluate(.day(try civil("2028-03-01"))), .satisfied)
        XCTAssertEqual(range.evaluate(.day(try civil("2028-03-02"))), .notSatisfied)
        for source in ["on 2026-02-29", "from 2028-03-01 through 2028-02-29"] {
            XCTAssertEqual(try resolution(source, field: "date"), .unresolved(.invalidValue))
        }
    }

    func testSourceComparatorOverridesMissingHintsAndRejectsContradictoryInterpretation() throws {
        let source = "under USD 500"
        let bound = try compile(source, field: "price", values: ["USD", "500"])
        XCTAssertEqual(bound.predicate, .price(.below, try amount(50_000), .unspecified, .unspecified))
        XCTAssertEqual(try compile(source, field: "price").predicate, bound.predicate,
            "Value hints are not argument authority")
        XCTAssertEqual(try compile(source, field: "price", relation: "below").predicate, bound.predicate)
        for relation in ["atMost", "above", "equal", "exclude"] {
            XCTAssertEqual(try resolution(source, field: "price", relation: relation), .unresolved(.contradictoryProposal))
        }
        XCTAssertEqual(try resolution("before 2026-09-20", field: "date", relation: "later"), .unresolved(.contradictoryProposal))
        XCTAssertEqual(try resolution("three tickets", field: "quantity", relation: "atLeast"), .unresolved(.contradictoryProposal))
        XCTAssertEqual(try resolution(source, field: "date"), .unresolved(.unrecognizedSource), "A model-selected field cannot substitute for parsing source")
        let rows = [row("Find tickets ", role: "outcome"), row(source, role: "prohibition", field: "price", relation: "below")]
        XCTAssertEqual(Scalar(proposal: try proposal(rows)).entries[1].resolution, .unresolved(.notScalar))
        let splitNegation = Scalar(proposal: try proposal([row("Find tickets ", role: "outcome"),
            row("not "), row(source, field: "price")]))
        XCTAssertEqual(splitNegation.entries[1].resolution, .unresolved(.notScalar))
        XCTAssertEqual(try condition(splitNegation, at: 2).predicate, bound.predicate,
            "A locally bound fragment does not resolve the separate negation; whole-goal logic remains uncompiled")
    }

    func testUnsupportedNegationAlternativesSuffixesAndValuesRemainUnresolved() throws {
        let cases: [(String, String)] = [
            ("not under USD 500", "price"), ("under USD 500 or above USD 700", "price"),
            ("under USD 500 and buy them", "price"), ("under USD 500 unless sold out", "price"),
            ("around USD 500", "price"), ("under USD -5", "price"), ("under USD 1.001", "price"),
            ("under USD 1,23", "price"), ("under USD 5%", "price"), ("under CHF 500", "price"),
            ("under USD 1e3", "price"), ("under USD 1.000,00", "price"), ("under USD 1000000000", "price"),
            ("three", "quantity"), ("three tickets or four results", "quantity"), ("1000 tickets", "quantity"),
            ("-1 results", "quantity"), ("1.5 tickets", "quantity"), ("Find three flights", "quantity"),
            ("tomorrow at 7 pm", "date"), ("on 2026-09-20 or 2026-09-21", "date"), ("not tomorrow", "date")]
        for (source, field) in cases {
            let result = try resolution(source, field: field)
            guard case .unresolved = result else { XCTFail("Unsupported source was bound: \(source)"); continue }
        }
        for source in ["next Friday", "on Monday", "between 2026-09-20 and 2026-09-22"] {
            XCTAssertEqual(try resolution(source, field: "date"), .unresolved(.ambiguousDate))
        }
        XCTAssertEqual(try resolution("including fees", field: "fees"), .unresolved(.notScalar),
            "A separate fees clause still needs semantic association with the relevant price")
    }

    func testConditionIdentityBindsOriginalTaskClockAndSourceOccurrence() throws {
        let rows = [row("Find tickets ", role: "outcome"), row("under USD 500 ", field: "price"), row("under USD 500 ", field: "price")]
        let ledger = Scalar(proposal: try proposal(rows))
        let first = try condition(ledger, at: 1), repeated = try condition(ledger, at: 2)
        XCTAssertEqual(first.predicate, repeated.predicate)
        XCTAssertNotEqual(first.id, repeated.id); XCTAssertNotEqual(first.requirementID, repeated.requirementID)
        for proposal in [try proposal(rows, taskID: "another-task"),
            try proposal(rows, referenceDate: Date(timeIntervalSince1970: 1_800_000_001))] {
            let other = try condition(Scalar(proposal: proposal), at: 1)
            XCTAssertNotEqual(other.id, first.id); XCTAssertEqual(other.predicate, first.predicate)
        }
        XCTAssertEqual(try condition(Scalar(proposal: ledger.proposal), at: 1), first)
    }

    private func proposal(_ rows: [[String: Any]], taskID: String = "scalar-research-task",
                          referenceDate: Date = Date(timeIntervalSince1970: 1_800_000_000), timeZone: String = "America/Los_Angeles",
                          disposition: String = "research") throws -> ComputerUseBrowserGoalProposal {
        let prompt = try rows.map { try XCTUnwrap($0["source"] as? String) }.joined()
        let input = try ComputerUseBrowserGoalInput(taskID: taskID, prompt: prompt, referenceDate: referenceDate, timeZoneIdentifier: timeZone)
        let question: [String: Any] = ["topic":disposition == "clarification" ? "date" : "none",
            "requirements":disposition == "clarification" ? [0] : []]
        let data = try JSONSerialization.data(withJSONObject: ["disposition":disposition, "requirements":rows, "question":question], options: [.sortedKeys])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
    private func row(_ source: String, role: String = "condition", field: String = "other", relation: String = "unspecified", values: [String] = []) -> [String: Any] {
        ["turn":0, "source":source, "role":role, "field":field, "relation":relation, "values":values]
    }
    private func resolution(_ source: String, field: String, relation: String = "unspecified", values: [String] = []) throws -> Scalar.Resolution {
        Scalar(proposal: try proposal([row("Find tickets. ", role: "outcome"), row(source, field: field, relation: relation, values: values)])).entries[1].resolution
    }
    private func compile(_ source: String, field: String, relation: String = "unspecified", values: [String] = []) throws -> Scalar.Condition {
        let value = try resolution(source, field: field, relation: relation, values: values)
        guard case .bound(let condition) = value else { throw FixtureError.unresolved }
        return condition
    }
    private func condition(_ ledger: Scalar, at index: Int) throws -> Scalar.Condition {
        guard case .bound(let condition) = ledger.entries[index].resolution else { throw FixtureError.unresolved }
        return condition
    }
    private func amount(_ hundredths: Int64, currency: Scalar.Currency = .usd) throws -> Scalar.Amount {
        try XCTUnwrap(.init(hundredths: hundredths, currency: currency))
    }
    private func civil(_ iso: String) throws -> Scalar.CivilDay {
        let values = iso.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { throw FixtureError.invalidDate }
        return try XCTUnwrap(.init(year: values[0], month: values[1], day: values[2]))
    }
    private enum FixtureError: Error { case unresolved, invalidDate }
}
