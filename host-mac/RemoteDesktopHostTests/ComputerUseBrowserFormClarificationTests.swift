import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormClarificationTests: XCTestCase {
    private let prompt = "Find concerts. Leave Reference unchanged. Do not buy."
    private let body = """
        <form action='/filtered'><label>Category<select name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
        <label>City<input name='city'></label><button>Search</button></form>
        <label>Reference<input value='private-reference'></label>
        """

    func testExactSourceProjectionHandlesSplitsMergesAndUnicodeWithoutChangingHistoricalMeaning() async throws {
        let text = "Find concerts in Montréal e\u{301}. Leave Reference unchanged."
        let goal = try ComputerUseBrowserGoalInput(taskID: "source", prompt: text, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let original = try proposal(goal, parts: [text])
        let source = try ComputerUseBrowserFormSource(index: 0, interpretation: original)
        let split = try proposal(goal, parts: ["Find concerts in ", "Montréal e\u{301}. ", "Leave Reference unchanged."])
        XCTAssertEqual(try source.indices(in: split), [0, 1, 2])
        let preservation = try ComputerUseBrowserFormSource(index: 2, interpretation: split)
        XCTAssertEqual(try preservation.indices(in: original), [0])
        XCTAssertEqual(preservation.source, "Leave Reference unchanged.")
        let altered = try ComputerUseBrowserGoalInput(taskID: "source", prompt: text.precomposedStringWithCanonicalMapping,
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertFalse(altered.continues(goal))
        XCTAssertThrowsError(try source.indices(in: proposal(altered, parts: [altered.prompt])))
    }

    func testGoalLineageRejectsSiblingAnswersChangedClockAndShorterHistory() async throws {
        let root = try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let first = try descendant(root, answerID: "a", answer: "Paris"), sibling = try descendant(root, answerID: "b", answer: "London")
        let second = try descendant(first, answerID: "c", answer: "Include fees.")
        XCTAssertTrue(first.continues(root)); XCTAssertTrue(second.continues(first)); XCTAssertTrue(second.continues(root))
        XCTAssertFalse(root.continues(first)); XCTAssertFalse(first.continues(second)); XCTAssertFalse(sibling.continues(first))
        for other in [try ComputerUseBrowserGoalInput(taskID: "other", prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles"),
                      try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt, referenceDate: ResearchDriverFixture.date.addingTimeInterval(1), timeZoneIdentifier: "America/Los_Angeles"),
                      try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")] {
            XCTAssertFalse(second.continues(other))
        }
    }

    private func action(_ input: ComputerUseBrowserActionInput, queryWhenReady: Bool = true) throws -> String {
        let hasPrevious = !input.queryBoundControlIDs.isEmpty
        let cityIndex = input.interpretation.requirements.firstIndex { $0.sourceTurnIndex == 1 } ?? 0
        if let review = try FormEffectScopeFixture.response(input, editing: hasPrevious ? ["City":[cityIndex]] : ["Category":[0]],
            retaining: hasPrevious ? ["Category":[0]] : [:], deferring: hasPrevious ? [:] : ["City":[0]]) { return review }
        let context = try object(input.contextJSON), verified = context["verified_form_stage"] as? [String: Any]
        let edits = verified?["edits"] as? [[String: Any]] ?? []
        if queryWhenReady, let city = input.evidence.page.controls.first(where: { $0.label == "City" }),
           edits.contains(where: { $0["control"] as? String == city.id }), let query = input.queryControlIDs.first {
            return try json(["query":query])
        }
        guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
        let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
        let index = try XCTUnwrap(input.interpretation.requirements.indices.first { input.interpretation.source(of: input.interpretation.requirements[$0])?.contains("Leave Reference unchanged.") == true })
        return try json(["form":form,"preserve":[["control":reference.id,"requirement":index]]])
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }
    private func categoryPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try self.alias("Category", in: input), field = try input.field(for: alias)
        let option = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
        return try json(["edits":[["field":alias,"choice":option.id,"requirement":0]],"preserve":[]])
    }
    private func cityPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let index = try XCTUnwrap(input.interpretation.requirements.indices.first { input.interpretation.requirements[$0].sourceTurnIndex == 1 })
        return try json(["edits":[["field":try alias("City", in: input),"terms":[["requirement":index,"text":"Paris"]]]],"preserve":[]])
    }
    private func descendant(_ root: ComputerUseBrowserGoalInput, answerID: String, answer: String) throws -> ComputerUseBrowserGoalInput {
        let owner = ComputerUseBrowserGoalClarification(input: root, now: { ResearchDriverFixture.date })
        let context = try ComputerUseBrowserGoalClarification.Context(controllerID: "phone", controllerSessionID: "session", browserSessionDigest: nil)
        let proposal = try self.proposal(root, parts: [root.prompt])
        let question = try owner.issue(proposal: proposal, topic: .location, requirementIDs: [proposal.requirements[0].id], context: context)
        return try owner.consume(questionID: question.id, answerTaskID: answerID, answer: answer, context: context)
    }
    private func proposal(_ input: ComputerUseBrowserGoalInput, parts: [String]) throws -> ComputerUseBrowserGoalProposal {
        try .decode(content: proposalContent(input, parts: parts), input: input)
    }
    private func proposalContent(_ input: ComputerUseBrowserGoalInput, parts: [String]) throws -> String {
        var rows: [[String: Any]] = parts.enumerated().map { index, part in
            ["turn":0,"source":part,"role":index == 0 ? "outcome" : part.hasPrefix("Do not") ? "prohibition" : "condition",
                "field":index == 0 ? "category" : "other","relation":"unspecified","values":[]]
        }
        rows += input.clarifications.enumerated().map { index, turn in
            ["turn":index + 1,"source":turn.answer,"role":"condition","field":turn.topic == .fees ? "fees" : "location","relation":"unspecified","values":[]]
        }
        return try json(["disposition":"research","requirements":rows,"question":["topic":"none","requirements":[]]])
    }
    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func object(_ value: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) }
}
