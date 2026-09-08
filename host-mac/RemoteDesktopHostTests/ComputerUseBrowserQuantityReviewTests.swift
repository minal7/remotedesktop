import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserQuantityReviewTests: XCTestCase {
    private typealias F = QuantityReviewFixture
    private typealias Review = ComputerUseBrowserResultReview

    func testQuantityContractRequiresMeaningForEveryFieldAndPreservesLegacyReviews() throws {
        let input = try F.input(), context = try F.object(input.contextJSON)
        XCTAssertTrue(input.hasQuantityFields); XCTAssertEqual(context["version"] as? Int, 3)
        XCTAssertEqual(context["quantity_meaning_required"] as? Bool, true)
        XCTAssertEqual(input.fieldKeys, ["scope", "price", "quantity", "qualifiers"])
        let requirements = try XCTUnwrap(context["requirements"] as? [[String: Any]])
        XCTAssertEqual(requirements[1]["candidate_judgment_allowed"] as? Bool, false)
        for meaning in Review.QuantityMeaning.allCases where meaning != .notQuantity {
            let review = try Review.decode(content: F.json(F.reply(input, meaning: meaning)), input: input)
            XCTAssertEqual(review.candidates[0].fields.map(\.quantity), [.notQuantity, meaning, .notQuantity])
            XCTAssertEqual(review.candidates[0].requirements?[1].judgment, .unknown)
        }
        for interpreted in [false, true] {
            let legacy = try F.input(quantity: false, interpreted: interpreted)
            let legacyContext = try F.object(legacy.contextJSON)
            XCTAssertFalse(legacy.hasQuantityFields); XCTAssertNil(legacyContext["quantity_meaning_required"])
            XCTAssertEqual(legacyContext["version"] as? Int, interpreted ? 2 : 1)
            let reply = F.reply(legacy), review = try Review.decode(content: F.json(reply), input: legacy)
            XCTAssertTrue(review.candidates[0].fields.allSatisfy { $0.quantity == nil })
            let unexpected = try F.changingField(reply, index: 0) { $0["quantity"] = "notQuantity" }
            XCTAssertThrowsError(try Review.decode(content: F.json(unexpected), input: legacy))
        }
    }

    func testAvailableQuantityRejectsMissingMeaningWrongScopePartialAndForeignCitations() throws {
        let input = try F.input(candidates: 2), valid = F.reply(input)
        var invalid: [[String: Any]] = []
        for replacement: Any in [NSNull(), "invented", "notQuantity", 3] {
            invalid.append(try F.changingField(valid, index: 1) { $0["quantity"] = replacement })
        }
        invalid.append(try F.changingField(valid, index: 1) { $0.removeValue(forKey: "quantity") })
        invalid.append(try F.changingField(valid, index: 0) { $0["quantity"] = "selectedQuantity" })
        for references in [[], ["t3"], ["t3", "t4", "t7"], ["t7", "t8"], ["invented"], ["t3", "t3"]] {
            invalid.append(try F.changingField(valid, index: 1) { $0["qualifiers"] = references })
        }
        for scope in ["page", "unknown"] {
            invalid.append(try F.changingField(valid, index: 1) { $0["scope"] = scope })
        }
        var mixed = valid, candidates = try XCTUnwrap(valid["candidates"] as? [[String: Any]])
        candidates[0]["association"] = "mixedOffers"; mixed["candidates"] = candidates; invalid.append(mixed)
        for value in invalid {
            XCTAssertThrowsError(try Review.decode(content: F.json(value), input: input)) {
                XCTAssertEqual($0 as? ComputerUseBrowserResultReviewError, .invalidProposal)
            }
        }
        let admitted = try Review.decode(content: F.json(valid), input: input)
        XCTAssertEqual(admitted.candidates[0].fields[1].qualifierTextIDs, ["t3", "t4"])
        let incomplete = try F.input(truncated: true)
        XCTAssertFalse(incomplete.permitsOfferAssertions)
        XCTAssertThrowsError(try Review.decode(content: F.json(F.reply(incomplete)), input: incomplete))
        XCTAssertFalse(try XCTUnwrap(incomplete.quantitySchema["enum"] as? [String]).contains("availableQuantity"))
    }

    func testQuantityPartsRetainMeaningWithinBoundsAndRequireCompleteNativeValidation() throws {
        let input = try F.input(candidates: 4, requirements: 8), parts = try ComputerUseBrowserReviewPart.plan(input)
        XCTAssertFalse(try ComputerUseBrowserReviewPart.wholeOutputFits(input))
        var assembly = try ComputerUseBrowserReviewAssembly(input: input, parts: parts)
        var invalidAssembly = try ComputerUseBrowserReviewAssembly(input: input, parts: parts)
        for part in parts {
            XCTAssertLessThanOrEqual(try part.maximumCanonicalOutputBytes, ComputerUseBrowserReviewPart.maximumOutputBytes)
            let reply = try F.partReply(part)
            XCTAssertLessThanOrEqual(try F.json(reply).utf8.count, try part.maximumCanonicalOutputBytes)
            try assembly.append(.decode(F.json(reply), part: part))
            var changed = reply
            var fields = try XCTUnwrap(reply["fields"] as? [[String: Any]])
            if part.candidate == 0, let index = part.fields.firstIndex(of: 1) {
                // The part is syntactically well-formed; final role/citation
                // admission must still reject this complete assembled review.
                fields[index]["quantity"] = "notQuantity"; changed["fields"] = fields
                for replacement: Any in [NSNull(), "invented"] {
                    var malformed = reply, badFields = try XCTUnwrap(reply["fields"] as? [[String: Any]])
                    badFields[index]["quantity"] = replacement; malformed["fields"] = badFields
                    XCTAssertThrowsError(try ComputerUseBrowserReviewPartReply.decode(F.json(malformed), part: part))
                }
            }
            try invalidAssembly.append(.decode(F.json(changed), part: part))
            var context = try F.object(part.contextJSON)
            context.removeValue(forKey: "requested_output")
            XCTAssertEqual(NSDictionary(dictionary: context), NSDictionary(dictionary: try F.object(input.contextJSON)))
        }
        let review = try Review.assemble(assembly), whole = try Review.decode(content: F.json(F.reply(input)), input: input)
        XCTAssertEqual(review, whole)
        XCTAssertThrowsError(try Review.assemble(invalidAssembly))
        let selected = try Review.decode(content: F.json(F.reply(input, meaning: .selectedQuantity)), input: input)
        XCTAssertNotEqual(review.digest, selected.digest)
        XCTAssertEqual(review.candidates.map { $0.fields[1].qualifierTextIDs }, [["t3", "t4"], ["t7", "t8"], ["t11", "t12"], ["t15", "t16"]])
    }

    func testWholeAndPartitionedLocalPlannersCarryTheExactQuantityContractAndInput() async throws {
        for count in [1, 4] {
            let input = try F.input(candidates: count, requirements: count == 1 ? 2 : 8)
            let isWhole = try ComputerUseBrowserReviewPart.wholeOutputFits(input)
            XCTAssertEqual(isWhole, count == 1)
            let transport = QuantityReviewTransport(input: input)
            let planner = try ComputerUseLocalBrowserResultReviewPlanner(connection: .init(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token", modelAlias: "fixture-model"), transport: transport)
            let review = try await planner.propose(input), calls = await transport.calls
            XCTAssertEqual(review, try Review.decode(content: F.json(F.reply(input)), input: input))
            let expected = isWhole ? 1 : try ComputerUseBrowserReviewPart.plan(input).count
            XCTAssertEqual(calls.counts.count, expected); XCTAssertEqual(calls.completions.count, expected)
            for (index, request) in calls.completions.enumerated() {
                XCTAssertEqual(request.httpBody, calls.counts[index].httpBody)
                let body = try F.object(String(decoding: XCTUnwrap(request.httpBody), as: UTF8.self))
                XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
                let format = try XCTUnwrap(body["response_format"] as? [String: Any]), contract = try XCTUnwrap(format["json_schema"] as? [String: Any])
                XCTAssertEqual(contract["name"] as? String, isWhole ? "browser_result_review_v3" : "browser_result_review_part_v2")
                let schema = try F.json(XCTUnwrap(contract["schema"]))
                XCTAssertTrue(schema.contains("availableQuantity")); XCTAssertTrue(schema.contains("selectedQuantity"))
                let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                var context = try F.object(XCTUnwrap(messages.last?["content"]))
                context.removeValue(forKey: "requested_output")
                XCTAssertEqual(NSDictionary(dictionary: context), NSDictionary(dictionary: try F.object(input.contextJSON)))
                XCTAssertGreaterThan(request.timeoutInterval, 0); XCTAssertLessThanOrEqual(request.timeoutInterval, 30)
            }
        }
    }
}

private enum QuantityReviewFixture {
    static func input(candidates: Int = 1, requirements: Int = 2, quantity: Bool = true,
                      interpreted: Bool = true, truncated: Bool = false) throws -> ComputerUseBrowserResultReviewInput {
        let sources = (0..<requirements).map { $0 == 0 ? "Find concerts. " : ($0 == 1 ? "Two tickets. " : "Check detail \($0). ") }
        let goal = try ComputerUseBrowserGoalInput(taskID: "quantity-review", prompt: sources.joined(),
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        let rows: [[String: Any]] = sources.enumerated().map {
            ["turn":0, "source":$0.element, "role":$0.offset == 0 ? "outcome" : "condition",
             "field":$0.offset == 0 ? "category" : ($0.offset == 1 ? "quantity" : "other"), "relation":"unspecified", "values":[]]
        }
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: json(["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]]]), input: goal)
        var texts: [ComputerUseBrowserPageSnapshot.Text] = []
        var containers: [ComputerUseBrowserPageSnapshot.Container] = [.init(id: "g0", parentID: nil, kind: "body")]
        var selections: [[String: Any]] = []
        for candidate in 0..<candidates {
            let group = "g\(candidate + 1)", ids = (0..<4).map { "t\(candidate * 4 + $0 + 1)" }
            containers.append(.init(id: group, parentID: "g0", kind: "article"))
            for (index, text) in ["Concert \(candidate)", "3 tickets", "Available", "For this date/type"].enumerated() {
                texts.append(.init(id: ids[index], containerID: group, text: text))
            }
            selections.append(["container":group, "fields":[["kind":"title", "texts":[ids[0]]],
                ["kind":quantity ? "quantity" : "other", "texts":[ids[1]]], ["kind":"availability", "texts":Array(ids.suffix(2))]], "links":[]])
        }
        let page = try ComputerUseBrowserResultPageInput(page: .init(id: String(repeating: "a", count: 32), texts: texts, links: [],
            truncated: truncated, omittedEmbeddedContent: false, containers: containers, omittedStructure: false))
        let proposal = try ComputerUseBrowserResultProposal.decode(content: json(["candidates":selections]), input: page, goal: goal)
        return try .init(goal: goal, page: page, proposal: proposal, interpretation: interpreted ? interpretation : nil)
    }
    static func reply(_ input: ComputerUseBrowserResultReviewInput, meaning: ComputerUseBrowserResultReview.QuantityMeaning = .availableQuantity) -> [String: Any] {
        let candidates: [[String: Any]] = (0..<input.candidateCount).map { candidate in
            let fields: [[String: Any]] = (0..<input.fieldCounts[candidate]).map { index in
                let isQuantity = input.fieldKind(candidate: candidate, field: index) == .quantity
                var field: [String: Any] = ["scope":"offer", "price":"notPrice", "qualifiers":isQuantity && meaning == .availableQuantity
                    ? input.fieldTextIDs(candidate: candidate, field: 2) : []]
                if input.hasQuantityFields { field["quantity"] = isQuantity ? meaning.rawValue : "notQuantity" }
                return field
            }
            var value: [String: Any] = ["association":"singleOffer", "fields":fields]
            if input.interpretation != nil {
                value["requirements"] = (0..<input.requirementCount).map { ["requirement":$0, "judgment":"unknown", "texts":[]] as [String: Any] }
            }
            return value
        }
        return ["candidates":candidates]
    }
    static func partReply(_ part: ComputerUseBrowserReviewPart) throws -> [String: Any] {
        try selectedReply(input: part.input, candidate: part.candidate, fields: part.fields, requirements: part.requirements)
    }
    static func selectedReply(input: ComputerUseBrowserResultReviewInput, candidate: Int, fields: [Int], requirements: [Int]) throws -> [String: Any] {
        let all = try XCTUnwrap(reply(input)["candidates"] as? [[String: Any]])
        let fieldRows = try XCTUnwrap(all[candidate]["fields"] as? [[String: Any]])
        let requirementRows = all[candidate]["requirements"] as? [[String: Any]] ?? []
        return ["candidate":candidate, "association":"singleOffer", "fields":fields.map { index in
            var field = fieldRows[index]; field["field"] = index; return field
        }, "requirements":requirements.map { requirementRows[$0] }]
    }
    static func changingField(_ reply: [String: Any], index: Int, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var value = reply, candidates = try XCTUnwrap(reply["candidates"] as? [[String: Any]])
        var fields = try XCTUnwrap(candidates[0]["fields"] as? [[String: Any]])
        change(&fields[index]); candidates[0]["fields"] = fields; value["candidates"] = candidates
        return value
    }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    static func object(_ value: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) }
}

private actor QuantityReviewTransport: ComputerUseTextModelTransport {
    let input: ComputerUseBrowserResultReviewInput
    private(set) var calls: (counts: [URLRequest], completions: [URLRequest]) = ([], [])
    init(input: ComputerUseBrowserResultReviewInput) { self.input = input }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { calls.counts.append(completionRequest); return 3_008 }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions.append(request)
        let body = try QuantityReviewFixture.object(String(decoding: XCTUnwrap(request.httpBody), as: UTF8.self))
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try QuantityReviewFixture.object(XCTUnwrap(messages.last?["content"]))
        let reply: [String: Any]
        if let requested = context["requested_output"] as? [String: Any] {
            reply = try QuantityReviewFixture.selectedReply(input: input, candidate: XCTUnwrap(requested["candidate"] as? Int),
                fields: XCTUnwrap(requested["fields"] as? [Int]), requirements: XCTUnwrap(requested["requirements"] as? [Int]))
        } else { reply = QuantityReviewFixture.reply(input) }
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model",
            "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":try QuantityReviewFixture.json(reply)]]]])
    }
}
