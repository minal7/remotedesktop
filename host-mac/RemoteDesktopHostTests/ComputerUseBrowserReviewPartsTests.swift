import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserReviewPartsTests: XCTestCase {
    func testPartsCoverEveryCandidateFieldAndRequirementWithinTheOutputBound() throws {
        let input = try ReviewPartsFixture.input(), parts = try ComputerUseBrowserReviewPart.plan(input)
        XCTAssertFalse(try ComputerUseBrowserReviewPart.wholeOutputFits(input))
        XCTAssertGreaterThan(parts.count, input.candidateCount)
        XCTAssertLessThanOrEqual(parts.count, ComputerUseBrowserReviewPart.maximumParts)
        for candidate in 0..<input.candidateCount {
            let selected = parts.filter { $0.candidate == candidate }
            XCTAssertEqual(selected.flatMap(\.fields), Array(0..<input.fieldCounts[candidate]))
            XCTAssertEqual(selected.flatMap(\.requirements), Array(0..<input.requirementCount))
        }
        for part in parts {
            XCTAssertLessThanOrEqual(try part.maximumCanonicalOutputBytes, ComputerUseBrowserReviewPart.maximumOutputBytes)
            var context = try ReviewPartsFixture.object(Data(part.contextJSON.utf8))
            let scope = try XCTUnwrap(context.removeValue(forKey: "requested_output") as? [String: Any])
            XCTAssertEqual(scope["candidate"] as? Int, part.candidate)
            XCTAssertEqual(scope["fields"] as? [Int], part.fields)
            XCTAssertEqual(scope["requirements"] as? [Int], part.requirements)
            XCTAssertEqual(NSDictionary(dictionary: context), NSDictionary(dictionary: try ReviewPartsFixture.object(Data(input.contextJSON.utf8))))
        }
    }

    func testAssemblyRejectsMissingDuplicateForeignAndConflictingParts() throws {
        let input = try ReviewPartsFixture.input(), parts = try ComputerUseBrowserReviewPart.plan(input)
        var assembly = try ComputerUseBrowserReviewAssembly(input: input, parts: parts)
        XCTAssertThrowsError(try ComputerUseBrowserResultReview.assemble(assembly))
        let first = try ComputerUseBrowserReviewPartReply.decode(ReviewPartsFixture.reply(parts[0]), part: parts[0])
        try assembly.append(first)
        XCTAssertThrowsError(try assembly.append(first))
        XCTAssertThrowsError(try ComputerUseBrowserResultReview.assemble(assembly))
        XCTAssertEqual(parts[0].candidate, parts[1].candidate)
        let conflict = try ComputerUseBrowserReviewPartReply.decode(ReviewPartsFixture.reply(parts[1], association: "mixedOffers"), part: parts[1])
        XCTAssertThrowsError(try assembly.append(conflict))
        let other = try ReviewPartsFixture.input(root: "another-root"), foreign = try ComputerUseBrowserReviewPart.plan(other)
        let foreignReply = try ComputerUseBrowserReviewPartReply.decode(ReviewPartsFixture.reply(foreign[1]), part: foreign[1])
        XCTAssertThrowsError(try assembly.append(foreignReply))
        XCTAssertThrowsError(try ComputerUseBrowserReviewAssembly(input: input, parts: Array(parts.dropLast())))
        for part in parts.dropFirst() {
            try assembly.append(.decode(ReviewPartsFixture.reply(part, association: part.candidate == 1 ? "mixedOffers" : "unknown"), part: part))
        }
        let review = try ComputerUseBrowserResultReview.assemble(assembly)
        XCTAssertEqual(review.candidates[0].association, .unknown); XCTAssertEqual(review.candidates[1].association, .mixedOffers)
        XCTAssertEqual(review.candidates.count, input.candidateCount)
        XCTAssertEqual(review.candidates.map { $0.requirements?.count }, Array(repeating: input.requirementCount, count: input.candidateCount))
        try review.validate(for: input)
    }

    func testPartDecoderRejectsChangedIndicesUnknownReferencesAndDuplicateJSONKeys() throws {
        let input = try ReviewPartsFixture.input(), parts = try ComputerUseBrowserReviewPart.plan(input)
        let part = try XCTUnwrap(parts.first { $0.fields.count > 1 && !$0.requirements.isEmpty })
        let valid = try ReviewPartsFixture.reply(part), body = try ReviewPartsFixture.object(Data(valid.utf8))
        var changedCandidate = body; changedCandidate["candidate"] = part.candidate + 1
        var reversed = body; reversed["fields"] = Array(try XCTUnwrap(body["fields"] as? [[String: Any]]).reversed())
        var missing = body; missing["requirements"] = []
        var invented = body, rows = try XCTUnwrap(body["requirements"] as? [[String: Any]])
        rows[0]["texts"] = ["not-observed"]; invented["requirements"] = rows
        for value in [changedCandidate, reversed, missing, invented] {
            XCTAssertThrowsError(try ComputerUseBrowserReviewPartReply.decode(ReviewPartsFixture.json(value), part: part))
        }
        let duplicate = valid.replacingOccurrences(of: "\"candidate\":", with: "\"candidate\":0,\"candidate\":")
        XCTAssertThrowsError(try ComputerUseBrowserReviewPartReply.decode(duplicate, part: part))
    }

    func testCompleteAssemblyStillRequiresTheOriginalWholeReviewValidation() throws {
        let input = try ReviewPartsFixture.input(), parts = try ComputerUseBrowserReviewPart.plan(input)
        var assembly = try ComputerUseBrowserReviewAssembly(input: input, parts: parts)
        for (index, part) in parts.enumerated() {
            var body = try ReviewPartsFixture.object(Data(ReviewPartsFixture.reply(part).utf8))
            if index == 0 {
                var fields = try XCTUnwrap(body["fields"] as? [[String: Any]])
                // A syntactically valid enum cannot make a title an exact
                // price or turn unknown scope into an offer assertion.
                fields[0]["price"] = "exact"; body["fields"] = fields
            }
            try assembly.append(.decode(ReviewPartsFixture.json(body), part: part))
        }
        XCTAssertThrowsError(try ComputerUseBrowserResultReview.assemble(assembly))
    }

    func testLocalPlannerCompletesBoundedPartsWithFullContextAndOneSharedDeadline() async throws {
        let input = try ReviewPartsFixture.input(), transport = try ReviewPartsTransport(input: input)
        let planner = try ReviewPartsFixture.planner(transport)
        let review = try await planner.propose(input), calls = await transport.calls
        let partCount = try ComputerUseBrowserReviewPart.plan(input).count
        XCTAssertEqual(calls.counts.count, partCount)
        XCTAssertEqual(calls.completions.count, partCount)
        XCTAssertEqual(review.candidates.map { $0.requirements?.count }, Array(repeating: input.requirementCount, count: input.candidateCount))
        for (index, request) in calls.completions.enumerated() {
            XCTAssertEqual(request.httpBody, calls.counts[index].httpBody)
            XCTAssertGreaterThan(request.timeoutInterval, 0)
            XCTAssertLessThanOrEqual(request.timeoutInterval, calls.counts[index].timeoutInterval)
            if index > 0 { XCTAssertLessThanOrEqual(request.timeoutInterval, calls.completions[index - 1].timeoutInterval) }
            let body = try ReviewPartsFixture.object(XCTUnwrap(request.httpBody)), format = try XCTUnwrap(body["response_format"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(format["json_schema"] as? [String: Any])["name"] as? String, "browser_result_review_part_v1")
            XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        }
    }

    func testCancellationInvalidPartAndLaterContextFailureCannotPublishAPrefixOrStartAnotherPart() async throws {
        let input = try ReviewPartsFixture.input()
        for mode in ["cancel", "invalid", "context"] {
            let transport = try ReviewPartsTransport(input: input, mode: mode), planner = try ReviewPartsFixture.planner(transport)
            let work = Task { try await planner.propose(input) }
            do { _ = try await work.value; XCTFail("A partial review is not publishable") }
            catch {
                if mode == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertNotNil(error as? ComputerUseBrowserResultReviewError) }
            }
            let calls = await transport.calls
            XCTAssertEqual(calls.completions.count, 1)
            XCTAssertEqual(calls.counts.count, mode == "context" ? 2 : 1)
        }
        let unused = try ReviewPartsTransport(input: input)
        do { _ = try await ReviewPartsFixture.planner(unused, budget: .zero).propose(input); XCTFail("An expired review cannot infer") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .deadlineExceeded) }
        let calls = await unused.calls
        XCTAssertTrue(calls.counts.isEmpty); XCTAssertTrue(calls.completions.isEmpty)
    }

    func testExcessiveReviewPlanStopsBeforeInferenceWithoutDroppingRequirements() async throws {
        let input = try ReviewPartsFixture.input(candidates: 8, requirements: 32)
        XCTAssertEqual(input.requirementCount, 32); XCTAssertEqual(input.candidateCount, 8)
        XCTAssertThrowsError(try ComputerUseBrowserReviewPart.plan(input))
        let transport = try ReviewPartsTransport(input: input, skipsPlan: true)
        do { _ = try await ReviewPartsFixture.planner(transport).propose(input); XCTFail("The work budget cannot silently omit requirements") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .contextLimit) }
        let calls = await transport.calls
        XCTAssertTrue(calls.counts.isEmpty); XCTAssertTrue(calls.completions.isEmpty)
    }

    func testReviewDeadlineCancelsAndJoinsAnInFlightCountOrCompletion() async throws {
        let input = try ReviewPartsFixture.input()
        for mode in ["stallCount", "stallComplete"] {
            let transport = try ReviewPartsTransport(input: input, mode: mode)
            let planner = try ReviewPartsFixture.planner(transport, budget: .seconds(1))
            do { _ = try await planner.propose(input); XCTFail("A stalled transport cannot finish the review") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .deadlineExceeded) }
            let calls = await transport.calls, cancelledWaits = await transport.cancelledWaits
            let isWaiting = await transport.isWaiting
            XCTAssertEqual(calls.counts.count, 1)
            XCTAssertEqual(calls.completions.count, mode == "stallCount" ? 0 : 1)
            XCTAssertEqual(cancelledWaits, 1)
            XCTAssertFalse(isWaiting, "The deadline must join cleanup before releasing its owner")
        }
    }

}

private enum ReviewPartsFixture {
    static func input(root: String = "review-parts", candidates: Int = 4, requirements: Int = 8) throws -> ComputerUseBrowserResultReviewInput {
        let sources = (0..<requirements).map { $0 == 0 ? "Find concerts. " : "Check detail \($0). " }
        let goal = try ComputerUseBrowserGoalInput(taskID: root, prompt: sources.joined(), referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "UTC")
        let rows: [[String: Any]] = sources.enumerated().map { ["turn":0, "source":$0.element,
            "role":$0.offset == 0 ? "outcome" : "condition", "field":$0.offset == 0 ? "category" : "other", "relation":"unspecified", "values":[]] }
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: json(["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]]]), input: goal)
        var texts: [ComputerUseBrowserPageSnapshot.Text] = [], containers: [ComputerUseBrowserPageSnapshot.Container] = [.init(id: "g0", parentID: nil, kind: "body")]
        var selections: [[String: Any]] = []
        for candidate in 0..<candidates {
            let group = "g\(candidate + 1)", ids = (0..<3).map { "t\(candidate * 3 + $0 + 1)" }
            containers.append(.init(id: group, parentID: "g0", kind: "article"))
            for (index, text) in ["Concert \(candidate)", "USD 40", "Paris"].enumerated() { texts.append(.init(id: ids[index], containerID: group, text: text)) }
            selections.append(["container":group, "fields":zip(["title", "price", "location"], ids).map { ["kind":$0.0, "texts":[$0.1]] as [String: Any] }, "links":[]])
        }
        let page = try ComputerUseBrowserResultPageInput(page: .init(id: String(repeating: "a", count: 32), texts: texts, links: [], truncated: false,
            omittedEmbeddedContent: false, containers: containers, omittedStructure: false))
        let proposal = try ComputerUseBrowserResultProposal.decode(content: json(["candidates":selections]), input: page, goal: goal)
        return try .init(goal: goal, page: page, proposal: proposal, interpretation: interpretation)
    }
    static func reply(_ part: ComputerUseBrowserReviewPart, association: String = "unknown") throws -> String {
        try json(["candidate":part.candidate, "association":association,
            "fields":part.fields.map { ["field":$0, "scope":"unknown",
                "price":part.input.fieldKind(candidate: part.candidate, field: $0) == .price ? "unknown" : "notPrice", "qualifiers":[]] as [String: Any] },
            "requirements":part.requirements.map { ["requirement":$0, "judgment":"unknown", "texts":[]] as [String: Any] }])
    }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    static func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    static func planner(_ transport: any ComputerUseTextModelTransport, budget: Duration = .seconds(30)) throws -> ComputerUseLocalBrowserResultReviewPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: transport, budget: budget)
    }
}

private actor ReviewPartsTransport: ComputerUseTextModelTransport {
    let parts: [ComputerUseBrowserReviewPart]
    let mode: String
    private(set) var calls: (counts: [URLRequest], completions: [URLRequest]) = ([], [])
    private(set) var cancelledWaits = 0
    private(set) var isWaiting = false
    init(input: ComputerUseBrowserResultReviewInput, mode: String = "normal", skipsPlan: Bool = false) throws {
        if skipsPlan { parts = [] } else { parts = try ComputerUseBrowserReviewPart.plan(input) }
        self.mode = mode
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts.append(completionRequest)
        if mode == "stallCount" { try await stall() }
        return mode == "context" && calls.counts.count == 2 ? 3_009 : 100
    }
    func complete(request: URLRequest) async throws -> Data {
        let index = calls.completions.count; calls.completions.append(request)
        if mode == "stallComplete" { try await stall() }
        let content: String
        if mode == "invalid" { content = #"{"candidate":-1}"# }
        else { content = try ReviewPartsFixture.reply(parts[index]) }
        if mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        return try JSONSerialization.data(withJSONObject: ["model":"fixture-model",
            "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
    private func stall() async throws {
        isWaiting = true
        defer { isWaiting = false }
        do { try await Task.sleep(for: .seconds(60)) }
        catch { if error is CancellationError { cancelledWaits += 1 }; throw error }
    }
}
