import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserResultReviewTests: XCTestCase {
    private typealias Review = ComputerUseBrowserResultReview
    private typealias Input = ComputerUseBrowserResultReviewInput
    private typealias F = ResultReviewFixture

    func testReviewKeepsTheCompleteClarifiedGoalAndSurroundingRecordsWithoutNativeAuthority() async throws {
        let original = try F.goal(), state = ComputerUseBrowserGoalClarification(input: original)
        let goals = BrowserResearchGoalFixture(); goals.questionTopic = .location
        let proposal = try await goals.propose(original)
        let owner = try ComputerUseBrowserGoalClarification.Context(controllerID: "private-controller", controllerSessionID: "private-session", browserSessionDigest: nil)
        let question = try state.issue(proposal: proposal, topic: .location, requirementIDs: [proposal.requirements[0].id], context: owner)
        let goal = try state.consume(questionID: question.id, answerTaskID: "private-answer", answer: "Montréal e\u{301} 😀\nDo not buy.", context: owner)
        let (page, reading, input) = try F.input(goal: goal)
        let context = try F.object(Data(input.contextJSON.utf8)), retained = try XCTUnwrap(context["goal"] as? [String: Any])
        XCTAssertEqual(retained["request"] as? String, original.prompt)
        XCTAssertEqual((retained["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, original.referenceMilliseconds)
        XCTAssertEqual(retained["timeZone"] as? String, original.timeZoneIdentifier)
        XCTAssertEqual((retained["clarifications"] as? [[String: Any]])?.first?["answer"] as? String, goal.userTurns[1])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(context["page"]), options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: F.object(Data(page.contextJSON.utf8)), options: [.sortedKeys]))
        XCTAssertTrue(input.textIDs.contains("t4"), "Page-wide qualifiers must survive the first grouping")
        XCTAssertTrue(input.permitsOfferAssertions)
        let groups = try XCTUnwrap(context["candidates"] as? [[String: Any]])
        XCTAssertEqual((groups[0]["fields"] as? [[String: Any]])?.count, reading.selections[0].fields.count)
        for hidden in [goal.taskID, goal.digest, question.id, "private-controller", "private-session", "private-answer", "callback-secret", "private-name"] {
            XCTAssertFalse(input.contextJSON.contains(hidden))
        }
        XCTAssertFalse(String(reflecting: input).contains("Concert Alpha"))
    }

    func testClosedReviewAccountsForEveryFieldAndRejectsInconsistentOrInventedFacts() throws {
        let (_, _, input) = try F.input()
        let valid = try F.content(), review = try Review.decode(content: valid, input: input)
        XCTAssertEqual(review.candidates[0].association, .singleOffer)
        XCTAssertEqual(review.candidates[0].fields[1].price, .exact)
        let qualified = try Review.decode(content: F.content(price: "qualified", qualifiers: ["t4"]), input: input)
        XCTAssertEqual(qualified.candidates[0].fields[1].qualifierTextIDs, ["t4"])
        let page = try Review.decode(content: F.content(price: "unknown", scope: "page"), input: input)
        XCTAssertEqual(page.candidates[0].fields[1].scope, .page)
        let unknown = try Review.decode(content: F.content(association: "unknown", price: "unknown", scope: "unknown", titleScope: "unknown"), input: input)
        XCTAssertEqual(unknown.candidates[0].association, .unknown)
        let invalid = [#"{"candidates":[]}"#, valid + valid, valid + String(repeating: " ", count: 16_384),
            valid.replacingOccurrences(of: "\"candidates\":", with: "\"complete\":true,\"candidates\":"),
            valid.replacingOccurrences(of: "\"association\":", with: "\"association\":\"unknown\",\"association\":"),
            valid.replacingOccurrences(of: "\"qualifiers\":[]", with: "\"qualifiers\":[],\"amount\":40"),
            valid.replacingOccurrences(of: "\"notPrice\"", with: "\"exact\""),
            try F.content(price: "notPrice"), try F.content(price: "qualified"),
            try F.content(scope: "page"), try F.content(titleScope: "page"),
            try F.content(association: "mixedOffers"), try F.content(association: "unknown"),
            try F.content(qualifiers: ["t4", "t4"]), try F.content(qualifiers: ["invented"]),
            try F.content(qualifiers: ["l1"]), try F.content(qualifiers: ["g0"]),
            try F.json(["candidates":[["association":"singleOffer", "fields":[F.field("offer", "notPrice")]]]]),
            try F.json(["candidates":[["association":"singleOffer", "fields":[F.field("offer", "notPrice"), F.field("offer", "exact"), F.field("page", "notPrice")]]]])]
        for content in invalid {
            XCTAssertThrowsError(try Review.decode(content: content, input: input)) {
                XCTAssertEqual($0 as? ComputerUseBrowserResultReviewError, .invalidProposal)
            }
        }
        XCTAssertFalse(String(reflecting: qualified).contains("t4"))
    }

    func testIncompleteProjectionAndReferenceLimitsCannotProducePositiveOfferAssertions() throws {
        for snapshot in [F.page(truncated: true), F.page(embedded: true), F.page(omittedStructure: true), F.page(extraTexts: 90)] {
            let (_, _, input) = try F.input(snapshot: snapshot)
            XCTAssertFalse(input.permitsOfferAssertions)
            XCTAssertThrowsError(try Review.decode(content: F.content(), input: input))
            let review = try Review.decode(content: F.content(association: "unknown", price: "qualified", scope: "page", titleScope: "unknown", qualifiers: ["t4"]), input: input)
            XCTAssertEqual(review.candidates[0].fields[1].price, .qualified)
            let request = try F.local(ResultReviewTransport()).makeRequest(input), body = try F.object(XCTUnwrap(request.httpBody))
            let format = try XCTUnwrap(body["response_format"] as? [String: Any]), contract = try XCTUnwrap(format["json_schema"] as? [String: Any])
            let schema = try F.json(XCTUnwrap(contract["schema"]))
            XCTAssertFalse(schema.contains("singleOffer")); XCTAssertFalse(schema.contains("\"offer\""))
        }
        let (_, _, input) = try F.input(snapshot: F.page(extraTexts: 12))
        XCTAssertTrue(input.permitsOfferAssertions)
        let nine = (1...9).map { "t\($0 + 4)" }
        XCTAssertThrowsError(try Review.decode(content: F.content(price: "qualified", qualifiers: nine), input: input))
        let manyFields: [[String: Any]] = [F.field("offer", "notPrice")] + (1...16).map { _ in F.field("offer", "exact") }
        XCTAssertThrowsError(try Review.decode(content: F.json(["candidates":[["association":"singleOffer", "fields":manyFields]]]), input: input))
    }

    func testReviewIsBoundToExactGoalSnapshotContentsAndOriginalFieldRoles() throws {
        let goal = try F.goal(), (page, proposal, input) = try F.input(goal: goal)
        let review = try Review.decode(content: F.content(), input: input)
        let reviewed = try proposal.reviewed(review, goal: goal)
        XCTAssertEqual(reviewed.selections, proposal.selections); XCTAssertEqual(reviewed.review, review)
        XCTAssertEqual(try reviewed.reviewed(review, goal: goal), reviewed)
        let alternative = try Review.decode(content: F.content(price: "qualified", qualifiers: ["t4"]), input: input)
        XCTAssertNotEqual(review.digest, alternative.digest)
        XCTAssertThrowsError(try reviewed.reviewed(alternative, goal: goal))
        for changed in [try F.input(snapshot: F.page(id: String(repeating: "b", count: 32))).2,
                        try F.input(snapshot: F.page(price: "USD 400")).2,
                        try F.input(snapshot: F.page(destination: "https://example.invalid/changed-secret")).2,
                        try F.input(otherPriceRole: true).2,
                        try F.input(goal: F.goal(taskID: "different-root")).2,
                        try F.input(goal: F.goal(prompt: "Find flights under USD 50. Do not buy.")).2] {
            XCTAssertThrowsError(try review.validate(for: changed)) {
                XCTAssertEqual($0 as? ComputerUseBrowserResultReviewError, .inputChanged)
            }
        }
        XCTAssertThrowsError(try Input(goal: F.goal(taskID: "different-root"), page: page, proposal: proposal))
        let changedPage = try ComputerUseBrowserResultPageInput(page: F.page(price: "USD 400"))
        XCTAssertThrowsError(try Input(goal: goal, page: changedPage, proposal: proposal))
    }

    func testTransportUsesTheExactBoundedRequestAndSkipsEmptyReadings() async throws {
        let (_, _, input) = try F.input(), response = try F.envelope(F.content())
        for count in [0, -1, 3_009] {
            let transport = ResultReviewTransport(response: response, count: count)
            do { _ = try await F.local(transport).propose(input); XCTFail("Unadmitted context cannot infer") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .contextLimit) }
            let calls = await transport.calls
            XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, 0)
        }
        let transport = ResultReviewTransport(response: response, count: 3_008)
        _ = try await F.local(transport).propose(input)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        let request = requests[0], body = try F.object(XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:54321/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token-value")
        XCTAssertGreaterThan(request.timeoutInterval, 0); XCTAssertLessThanOrEqual(request.timeoutInterval, 30)
        XCTAssertEqual(body["temperature"] as? Int, 0)
        XCTAssertEqual(body["top_p"] as? Int, 1); XCTAssertEqual(body["top_k"] as? Int, 0)
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["cache_prompt"] as? Bool, false)
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], input.contextJSON)
        XCTAssertEqual(messages[0]["content"], ComputerUseLocalBrowserResultReviewPlanner.instructions)
        let format = try XCTUnwrap(body["response_format"] as? [String: Any]), contract = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(contract["name"] as? String, "browser_result_review_v1")
        let goal = try F.goal(), page = try ComputerUseBrowserResultPageInput(page: F.page())
        let empty = try ComputerUseBrowserResultProposal.decode(content: #"{"candidates":[]}"#, input: page, goal: goal)
        let emptyInput = try Input(goal: goal, page: page, proposal: empty), unused = ResultReviewTransport()
        let result = try await F.local(unused).propose(emptyInput), calls = await unused.calls
        XCTAssertTrue(result.candidates.isEmpty); XCTAssertEqual(calls.counts, 0); XCTAssertEqual(calls.completions, 0)
    }

    func testMalformedModelEnvelopesAndCancellationCannotPublishReview() async throws {
        let (_, _, input) = try F.input(), response = try F.envelope(F.content())
        let source = String(decoding: response, as: UTF8.self)
        let invalid = [Data(), Data([0xff]), Data(source.replacingOccurrences(of: "fixture-model", with: "other-model").utf8),
            Data(source.replacingOccurrences(of: "\"stop\"", with: "\"length\"").utf8),
            Data(source.replacingOccurrences(of: "\"assistant\"", with: "\"user\"").utf8),
            Data(source.replacingOccurrences(of: "\"assistant\"", with: "\"assistant\",\"tool_calls\":[{}]").utf8),
            Data(source.replacingOccurrences(of: "\"assistant\"", with: "\"assistant\",\"refusal\":\"No\"").utf8),
            Data(source.replacingOccurrences(of: "\"stop\"", with: "\"stop\",\"finish_reason\":\"stop\"").utf8)]
        for response in invalid {
            do { _ = try await F.local(ResultReviewTransport(response: response)).propose(input); XCTFail("Invalid envelope cannot publish") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .invalidProposal) }
        }
        for afterCount in [true, false] {
            let transport = ResultReviewTransport(response: response, cancelCount: afterCount, cancelCompletion: !afterCount)
            let planner = try F.local(transport), running = Task { try await planner.propose(input) }
            do { _ = try await running.value; XCTFail("A cancelled reply cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            let calls = await transport.calls
            XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, afterCount ? 0 : 1)
        }
    }

    func testCompositeRejectsStaleReaderAndReviewerRepliesAndReusesAnExactReview() async throws {
        let goal = try F.goal(), (page, proposal, input) = try F.input(goal: goal), reviewer = ResultReviewReply()
        let composite = ComputerUseReviewedBrowserResultPlanner(reader: FixedReviewReading(value: proposal), reviewer: reviewer)
        let result = try await composite.propose(goal: goal, page: page)
        XCTAssertEqual(reviewer.inputs, [input]); XCTAssertEqual(result.selections, proposal.selections)
        let reused = ComputerUseReviewedBrowserResultPlanner(reader: FixedReviewReading(value: result), reviewer: reviewer)
        let reusedResult = try await reused.propose(goal: goal, page: page)
        XCTAssertEqual(reusedResult, result)
        XCTAssertEqual(reviewer.inputs.count, 1)
        let changedPage = try ComputerUseBrowserResultPageInput(page: F.page(price: "USD 400"))
        do { _ = try await composite.propose(goal: goal, page: changedPage); XCTFail("The first reading must match before review") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .inputChanged) }
        XCTAssertEqual(reviewer.inputs.count, 1)
        reviewer.replacement = try Review.decode(content: F.content(), input: F.input(snapshot: F.page(price: "USD 400")).2)
        do { _ = try await composite.propose(goal: goal, page: page); XCTFail("A cached foreign review cannot attach") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .inputChanged) }
        let empty = try ComputerUseBrowserResultProposal.decode(content: #"{"candidates":[]}"#, input: page, goal: goal)
        let noReview = ResultReviewReply(), emptyComposite = ComputerUseReviewedBrowserResultPlanner(reader: FixedReviewReading(value: empty), reviewer: noReview)
        let emptyResult = try await emptyComposite.propose(goal: goal, page: page)
        XCTAssertTrue(try XCTUnwrap(emptyResult.review).candidates.isEmpty); XCTAssertTrue(noReview.inputs.isEmpty)
    }

    func testNativeDriverCarriesReviewConcernsAndWholeGoalIntoLinkPlanningWithoutCompleting() async throws {
        typealias Status = ComputerUseBrowserResultAssessment.Status
        let cases: [(String, String, String, String, Status)] = [
            ("singleOffer", "exact", "offer", "offer", .quotedValueMatches),
            ("singleOffer", "qualified", "offer", "offer", .reviewQualifiedPrice),
            ("singleOffer", "unknown", "page", "offer", .reviewPageContext),
            ("singleOffer", "unknown", "unknown", "offer", .reviewUnresolved),
            ("mixedOffers", "unknown", "unknown", "unknown", .reviewMixedOffers),
            ("unknown", "unknown", "unknown", "unknown", .reviewUnresolved)]
        for (association, price, scope, titleScope, expected) in cases {
            let reviewer = ResultReviewReply(); reviewer.association = association; reviewer.price = price
            reviewer.scope = scope; reviewer.titleScope = titleScope
            let composite = ComputerUseReviewedBrowserResultPlanner(reader: NativeReviewReading(), reviewer: reviewer)
            let fixture = try await ResearchDriverFixture.make(additionalCardHTML: "<p>From</p>", candidateBodyHTML: "<p>USD 40</p>")
            defer { fixture.close() }
            let links = ResultReviewLinks(), driver = ComputerUseBrowserResearchDriver(goalPlanner: ResultReviewGoal(), resultPlanner: composite,
                searchPlanner: fixture.search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(), planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: links),
                now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
            let result = try await driver.executeBrowserResearch(taskID: ResearchDriverFixture.root, prompt: ResearchDriverFixture.prompt, tools: fixture.tools, progress: { _ in })
            guard case .browserResearchProgress = result else { return XCTFail("Even an exact label is not a completed research answer") }
            let input = try XCTUnwrap(links.inputs.first), context = try F.object(Data(input.contextJSON.utf8))
            let goal = try XCTUnwrap(context["goal"] as? [String: Any]), reviews = try XCTUnwrap(context["field_review"] as? [[String: Any]])
            XCTAssertEqual(goal["request"] as? String, ResearchDriverFixture.prompt)
            XCTAssertEqual(reviews[0]["association"] as? String, association)
            let assessment = try XCTUnwrap(context["requirement_assessment"] as? [String: Any])
            let candidates = try XCTUnwrap(assessment["candidates"] as? [[String: Any]])
            XCTAssertEqual(candidates[0]["requirements"] as? [String], ["reviewRequirementUnresolved", expected.rawValue, "needsSemanticVerification"])
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
            let owner = try fixture.owner(), batch = try await owner.readCandidates(), review = try XCTUnwrap(batch.review)
            try await fixture.browser.validateResultReview(review, reading: batch, goal: owner.input)
            let qualifierIDs = review.candidates[0].fields[1].qualifierTextIDs
            XCTAssertTrue(qualifierIDs.allSatisfy { id in batch.surroundingTexts.contains { $0.id == id && $0.text == "From" } })
            XCTAssertEqual(try XCTUnwrap(batch.requirementAssessment).candidates[0].quotes[0].source, "USD 40")
            XCTAssertFalse(input.contextJSON.contains(fixture.base.absoluteString))
        }
    }

    func testNativeCandidateAndLinkIdentityIncludeTheReviewAndRejectStaleEvidence() async throws {
        let fixture = try await ResearchDriverFixture.make(additionalCardHTML: "<p>From</p>", candidateBodyHTML: "<p>USD 40</p>")
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), goal = owner.input, document = try XCTUnwrap(fixture.browser.currentDocument(taskID: owner.taskID))
        let evidence = try await fixture.browser.observePage(document: document), page = try ComputerUseBrowserResultPageInput(page: evidence.page)
        let proposal = try await NativeReviewReading().propose(goal: goal, page: page), input = try Input(goal: goal, page: page, proposal: proposal)
        let first = ResultReviewReply(), second = ResultReviewReply(); second.price = "qualified"
        let firstReview = try await first.propose(input), secondReview = try await second.propose(input)
        let a = try await fixture.browser.prepareResultCandidates(proposal.reviewed(firstReview, goal: goal), goal: goal, evidence: evidence)
        let b = try await fixture.browser.prepareResultCandidates(proposal.reviewed(secondReview, goal: goal), goal: goal, evidence: evidence)
        XCTAssertNotEqual(a.candidates[0].id, b.candidates[0].id)
        let aInput = try ComputerUseBrowserLinkSelectionInput(goal: goal, candidates: a, history: owner.confirmedNavigationHistory)
        let bInput = try ComputerUseBrowserLinkSelectionInput(goal: goal, candidates: b, history: owner.confirmedNavigationHistory)
        let choice = try ComputerUseBrowserLinkProposal.decode(content: #"{"candidate":-1,"link":""}"#, input: aInput)
        XCTAssertThrowsError(try choice.choice(for: bInput))
        do { try await fixture.browser.validateResultReview(firstReview, reading: b, goal: goal); XCTFail("Review mismatch") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .inputChanged) }
        try await fixture.browser.validateResultReview(secondReview, reading: b, goal: goal)
        owner.pause(); fixture.state.allowed = false
        do { try await fixture.browser.validateResultReview(secondReview, reading: b, goal: goal); XCTFail("No authority during login") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        fixture.state.allowed = true; try await owner.resumeAfterUserControl()
        _ = try await owner.readCandidates()
        do { try await fixture.browser.validateResultReview(secondReview, reading: b, goal: goal); XCTFail("Old snapshot superseded") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
    }

    func testPauseReturnsBeforeAStalledReviewAndResumeKeepsTheOriginalSearch() async throws {
        let gate = BrowserResearchGate(), reviewer = ResultReviewReply()
        reviewer.beforeReply = { await gate.suspend() }
        let fixture = try await ResearchDriverFixture.make(resultPlanner: ComputerUseReviewedBrowserResultPlanner(reader: NativeReviewReading(), reviewer: reviewer), candidateBodyHTML: "<p>USD 40</p>")
        defer { gate.release(); fixture.close() }
        let delivered = expectation(description: "Review Pause delivered before reviewer return")
        let running = Task { defer { delivered.fulfill() }; return try await fixture.start() }
        try await gate.waitUntilStarted()
        let owner = try fixture.owner(), original = owner.input
        owner.pause(); XCTAssertTrue(owner.isOperating)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertFalse(owner.isOperating)
        XCTAssertThrowsError(try fixture.planningWorker.requireAvailable()) {
            XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .busy)
        }
        gate.release()
        do { _ = try await running.value; XCTFail("Late review cannot pass Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(owner.input, original)
        reviewer.beforeReply = nil
        try await waitForAvailablePlanningWorker(fixture.planningWorker)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertGreaterThanOrEqual(reviewer.inputs.count, 2)
    }

    func testInvalidReviewRetainsTheNativeOwnerAndResumeDoesNotRepeatTheSearch() async throws {
        let reviewer = ResultReviewReply(); reviewer.price = "notPrice"
        let fixture = try await ResearchDriverFixture.make(resultPlanner: ComputerUseReviewedBrowserResultPlanner(reader: NativeReviewReading(), reviewer: reviewer), candidateBodyHTML: "<p>USD 40</p>")
        defer { fixture.close() }
        var nativeFallbacks = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeFallbacks += 1; return nil }, browserResearch: fixture.driver)
        let result = try await executor.execute(taskID: ResearchDriverFixture.root, modelPrompt: "Old assistant history", currentUserPrompt: ResearchDriverFixture.prompt,
            conversation: [], tools: fixture.tools, progress: { _ in })
        guard case .userInterventionRequired = result else { return XCTFail("Invalid review cannot finish or replace the task") }
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(nativeFallbacks, 0); XCTAssertTrue(fixture.policy.goals.isEmpty)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        reviewer.price = "exact"
        _ = try await fixture.resume()
        XCTAssertTrue(try fixture.owner() === owner); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.policy.goals, [original])
    }

    func testPageChangeWhileReviewingCannotPublishOrNavigateTheOldReading() async throws {
        let gate = BrowserResearchGate(), reviewer = ResultReviewReply()
        reviewer.beforeReply = { await gate.suspend() }
        let fixture = try await ResearchDriverFixture.make(resultPlanner: ComputerUseReviewedBrowserResultPlanner(reader: NativeReviewReading(), reviewer: reviewer), candidateBodyHTML: "<p>USD 40</p>")
        defer { gate.release(); fixture.close() }
        let running = Task { try await fixture.start() }
        try await gate.waitUntilStarted()
        let owner = try fixture.owner(), original = owner.input
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "new-document-during-review", to: fixture.base.appendingPathComponent("beta"))
        gate.release()
        let result = try await running.value
        guard case .userInterventionRequired = result else { return XCTFail("Stale evidence needs reconciliation") }
        XCTAssertEqual(owner.input, original); XCTAssertTrue(fixture.policy.goals.isEmpty)
        XCTAssertEqual(fixture.server.count("/details"), 0)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search])
    }
}

@MainActor
final class ComputerUseBrowserRequirementReviewTests: XCTestCase {
    private typealias F = ResultReviewFixture
    private typealias Review = ComputerUseBrowserResultReview

    private func input(snapshot: ComputerUseBrowserPageSnapshot? = nil) async throws
        -> (ComputerUseBrowserGoalProposal, ComputerUseBrowserResultPageInput, ComputerUseBrowserResultProposal, ComputerUseBrowserResultReviewInput) {
        let goal = try F.goal(), interpretation = try await ResultReviewGoal().propose(goal)
        let (page, proposal, _) = try F.input(goal: goal, snapshot: snapshot)
        return (interpretation, page, proposal, try .init(goal: goal, page: page, proposal: proposal, interpretation: interpretation))
    }
    private func content(_ judgments: [(String, [String])], association: String = "singleOffer") throws -> String {
        let fieldScope = association == "singleOffer" ? "offer" : "unknown"
        return try F.json(["candidates":[["association":association,
            "fields":[F.field(fieldScope, "notPrice"), F.field(fieldScope, association == "singleOffer" ? "exact" : "unknown")],
            "requirements":judgments.enumerated().map { ["requirement":$0.offset, "judgment":$0.element.0, "texts":$0.element.1] as [String: Any] }]]])
    }

    func testRequirementReviewRetainsExactGoalFragmentsAndProducesOnlyCitedJudgments() async throws {
        let (interpretation, _, proposal, input) = try await self.input()
        let context = try F.object(Data(input.contextJSON.utf8)), requirements = try XCTUnwrap(context["requirements"] as? [[String: Any]])
        XCTAssertEqual(requirements.count, 3)
        for (index, requirement) in interpretation.requirements.enumerated() {
            XCTAssertEqual(requirements[index]["index"] as? Int, index)
            XCTAssertEqual(requirements[index]["source"] as? String, interpretation.source(of: requirement))
            XCTAssertEqual(requirements[index]["sourceByteOffset"] as? Int, requirement.sourceByteOffset)
            XCTAssertEqual(requirements[index]["role"] as? String, requirement.role.rawValue)
        }
        XCTAssertEqual(requirements.map { $0["candidate_judgment_allowed"] as? Bool }, [true, true, false])
        XCTAssertFalse(input.contextJSON.contains(interpretation.input.taskID))
        XCTAssertFalse(input.contextJSON.contains("callback-secret"))
        let review = try Review.decode(content: content([("supports", ["t1"]), ("conflicts", ["t2", "t4"]), ("unknown", [])]), input: input)
        XCTAssertEqual(review.candidates[0].requirements?.map(\.judgment), [.supports, .conflicts, .unknown])
        XCTAssertEqual(review.candidates[0].requirements?[1].textIDs, ["t2", "t4"])
        let bound = try proposal.reviewed(review, goal: interpretation.input, interpretation: interpretation)
        XCTAssertEqual(bound.review, review)
        XCTAssertThrowsError(try proposal.reviewed(review, goal: interpretation.input), "Losing the interpreted requirement scope cannot reuse a review")
        XCTAssertFalse(String(reflecting: review).contains("t4"))
    }

    func testRequirementReviewRejectsMissingReorderedInventedAndUnjustifiedJudgments() async throws {
        let (_, _, _, input) = try await self.input()
        let valid = try content([("supports", ["t1"]), ("supports", ["t2"]), ("unknown", [])])
        let variants = [try F.content(), try content([("supports", ["t1"])]),
            valid.replacingOccurrences(of: "\"requirement\":1", with: "\"requirement\":0"),
            valid.replacingOccurrences(of: "\"requirement\":1", with: "\"requirement\":1.5"),
            valid.replacingOccurrences(of: "\"judgment\":\"supports\"", with: "\"judgment\":\"verified\""),
            try content([("supports", []), ("supports", ["t2"]), ("unknown", [])]),
            try content([("supports", ["t4"]), ("supports", ["t2"]), ("unknown", [])]),
            try content([("supports", ["t1"]), ("conflicts", []), ("unknown", [])]),
            try content([("supports", ["t1"]), ("supports", ["t1", "t4"]), ("unknown", [])]),
            try content([("supports", ["t1"]), ("supports", ["invented"]), ("unknown", [])]),
            try content([("supports", ["t1"]), ("supports", ["l1"]), ("unknown", [])]),
            try content([("supports", ["t1", "t1"]), ("supports", ["t2"]), ("unknown", [])]),
            try content([("supports", ["t1"]), ("supports", ["t2"]), ("supports", ["t1"])]),
            try content([("supports", ["t1"]), ("unknown", []), ("unknown", [])], association: "mixedOffers")]
        for value in variants { XCTAssertThrowsError(try Review.decode(content: value, input: input), value) }
        let (_, _, _, incomplete) = try await self.input(snapshot: F.page(truncated: true))
        XCTAssertThrowsError(try Review.decode(content: valid, input: incomplete))
    }

    func testRequirementCitationsCannotBorrowAnotherCandidateOrCutASelectedField() async throws {
        let goal = try F.goal(), interpretation = try await ResultReviewGoal().propose(goal)
        let snapshot = ComputerUseBrowserPageSnapshot(id: String(repeating: "a", count: 32), texts: [
            .init(id: "t1", containerID: "g1", text: "Concert Alpha"),
            .init(id: "t2", containerID: "g1", text: "USD 40"), .init(id: "t3", containerID: "g1", text: "Plus fees"),
            .init(id: "t4", containerID: "g2", text: "Concert Beta"), .init(id: "t5", containerID: "g2", text: "USD 30"),
            .init(id: "t6", containerID: "g2", text: "Unclassified Beta qualification")], links: [],
            truncated: false, omittedEmbeddedContent: false,
            containers: [.init(id: "g0", parentID: nil, kind: "body"), .init(id: "g1", parentID: "g0", kind: "article"),
                .init(id: "g2", parentID: "g0", kind: "article")], omittedStructure: false)
        let page = try ComputerUseBrowserResultPageInput(page: snapshot)
        let proposal = try ComputerUseBrowserResultProposal.decode(content: F.json(["candidates":[
            ["container":"g1", "fields":[["kind":"title", "texts":["t1"]], ["kind":"price", "texts":["t2", "t3"]]], "links":[]],
            ["container":"g2", "fields":[["kind":"title", "texts":["t4"]], ["kind":"price", "texts":["t5"]]], "links":[]]]]), input: page, goal: goal)
        let input = try ComputerUseBrowserResultReviewInput(goal: goal, page: page, proposal: proposal, interpretation: interpretation)
        for references in [["t2"], ["t2", "t3", "t5"], ["t2", "t3", "t6"], ["t2", "t3"]] {
            var first = try F.object(Data(content([("supports", ["t1"]), ("supports", references), ("unknown", [])]).utf8))
            let other = try F.object(Data(content([("supports", ["t4"]), ("supports", ["t5"]), ("unknown", [])]).utf8))
            first["candidates"] = try XCTUnwrap(first["candidates"] as? [[String: Any]]) + XCTUnwrap(other["candidates"] as? [[String: Any]])
            let encoded = try F.json(first)
            if references == ["t2", "t3"] { XCTAssertNoThrow(try Review.decode(content: encoded, input: input)) }
            else { XCTAssertThrowsError(try Review.decode(content: encoded, input: input)) }
        }
    }

    func testChangedInterpretationOrCitationCannotReuseReviewIdentity() async throws {
        let (interpretation, _, proposal, input) = try await self.input()
        let review = try Review.decode(content: content([("supports", ["t1"]), ("supports", ["t2"]), ("unknown", [])]), input: input)
        let changed = try Review.decode(content: content([("unknown", []), ("supports", ["t2"]), ("unknown", [])]), input: input)
        XCTAssertNotEqual(review.digest, changed.digest)
        let rows: [[String: Any]] = interpretation.requirements.map { requirement in
            ["turn":requirement.sourceTurnIndex, "source":interpretation.source(of: requirement)!,
             "role":requirement.role.rawValue, "field":requirement.field == .price ? "other" : requirement.field.rawValue,
             "relation":requirement.relation.rawValue, "values":requirement.values]
        }
        let other = try ComputerUseBrowserGoalProposal.decode(content: F.json(["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]]]), input: interpretation.input)
        XCTAssertThrowsError(try proposal.reviewed(review, goal: interpretation.input, interpretation: other))
        XCTAssertThrowsError(try review.validateInterpretation(other))
    }

    func testV2CompositeUsesOneExistingReviewCallAndRetainsTheCompleteMatrix() async throws {
        let (interpretation, page, proposal, input) = try await self.input()
        let response = try F.envelope(content([("supports", ["t1"]), ("supports", ["t2"]), ("unknown", [])]))
        let transport = ResultReviewTransport(response: response)
        let composite = ComputerUseReviewedBrowserResultPlanner(reader: FixedReviewReading(value: proposal), reviewer: try F.local(transport))
        let result = try await composite.propose(interpretation: interpretation, page: page)
        XCTAssertEqual(result.review?.candidates[0].requirements?.count, 3)
        let calls = await transport.calls, requests = await transport.requests
        XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, 1)
        let body = try F.object(XCTUnwrap(requests.first?.httpBody)), format = try XCTUnwrap(body["response_format"] as? [String: Any])
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "browser_result_review_v2")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], input.contextJSON)
        let reused = ComputerUseReviewedBrowserResultPlanner(reader: FixedReviewReading(value: result), reviewer: try F.local(transport))
        _ = try await reused.propose(interpretation: interpretation, page: page)
        let after = await transport.calls
        XCTAssertEqual(after.completions, 1, "An exactly bound review needs no additional model call")
        let stale = ComputerUseReviewedBrowserResultPlanner(reader: FixedReviewReading(value: result), reviewer: try F.local(transport))
        do { _ = try await stale.propose(goal: interpretation.input, page: page); XCTFail("A v2 review cannot lose its requirement binding") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultReviewError, .inputChanged) }
    }

    func testNativeResearchAssessmentKeepsContradictionsAndUnknownsAheadOfMatchingNumbers() async throws {
        let cases: [(String, String, ComputerUseBrowserResultAssessment.Status)] = [("supports", "50", .quotedValueMatches),
            ("supports", "30", .quotedValueConflicts), ("conflicts", "50", .reviewRequirementConflict), ("unknown", "50", .reviewRequirementUnresolved)]
        for (judgment, limit, expected) in cases {
            let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>USD 40</p>")
            defer { fixture.close() }
            let reviewer = ResultReviewReply(); reviewer.requirementPriceJudgment = judgment
            reviewer.requirementCategoryJudgment = "supports"
            let links = ResultReviewLinks(), reader = ComputerUseReviewedBrowserResultPlanner(reader: NativeReviewReading(), reviewer: reviewer)
            let driver = ComputerUseBrowserResearchDriver(goalPlanner: ResultReviewGoal(priceLimit: limit), resultPlanner: reader, searchPlanner: fixture.search,
                actionPlanner: fixture.actions, formPlanner: fixture.forms,
                planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: links),
                now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
            let result = try await driver.executeBrowserResearch(taskID: ResearchDriverFixture.root, prompt: "Find concerts under USD \(limit). Do not buy.",
                tools: fixture.tools, progress: { _ in })
            guard case .browserResearchProgress = result else { return XCTFail("Cited judgments remain incomplete research") }
            let owner = try fixture.owner(), batch = try await owner.revalidateCandidates()
            XCTAssertEqual(batch.requirementAssessment?.candidates[0].requirements[0].status, .reviewRequirementSupported)
            XCTAssertEqual(batch.requirementAssessment?.candidates[0].requirements[1].status, expected)
            XCTAssertEqual(reviewer.inputs.first?.interpretation?.input, owner.input)
            let archive = try owner.researchEvidence(for: owner.input), recalled = try archive.recall(0, goal: owner.input)
            let observation = try XCTUnwrap(recalled["observation"] as? [String: Any])
            let reviews = try XCTUnwrap(observation["field_review"] as? [[String: Any]])
            let requirements = try XCTUnwrap(reviews[0]["requirements"] as? [[String: Any]])
            XCTAssertEqual(requirements[1]["judgment"] as? String, judgment)
            XCTAssertTrue(try XCTUnwrap(requirements[1]["texts"] as? [String]).allSatisfy { $0.hasPrefix("r0/") })
            XCTAssertEqual(fixture.server.count("/details"), 0)
        }
    }
}

private enum ResultReviewFixture {
    static func goal(taskID: String = "private-review-root", prompt: String = "Find concerts under USD 50. Do not buy.") throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: taskID, prompt: prompt, referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
    }
    static func page(id: String = String(repeating: "a", count: 32), price: String = "USD 40", destination: String = "https://example.invalid/offer?callback-secret",
                     truncated: Bool = false, embedded: Bool = false, omittedStructure: Bool = false, extraTexts: Int = 0) -> ComputerUseBrowserPageSnapshot {
        .init(id: id, texts: [
            .init(id: "t1", containerID: "g1", text: "Concert Alpha"), .init(id: "t2", containerID: "g1", text: price),
            .init(id: "t3", containerID: "g1", text: "2027-01-16"), .init(id: "t4", containerID: "g0", text: "From")]
                + (0..<extraTexts).map { .init(id: "t\($0 + 5)", containerID: "g0", text: "Surrounding condition \($0 + 1)") },
            links: [.init(id: "l1", label: "Details", destination: destination, textIDs: ["t1"], containerID: "g1")],
            controls: [.init(id: "c1", containerID: "g0", label: "Search", kind: "text", name: "private-name", disabled: false, readOnly: false,
                required: false, multiple: false, constraints: [:], options: [], form: nil)],
            truncated: truncated, omittedEmbeddedContent: embedded,
            containers: [.init(id: "g0", parentID: nil, kind: "body"), .init(id: "g1", parentID: "g0", kind: "article")], omittedStructure: omittedStructure)
    }
    static func input(goal: ComputerUseBrowserGoalInput? = nil, snapshot: ComputerUseBrowserPageSnapshot? = nil, otherPriceRole: Bool = false) throws -> (ComputerUseBrowserResultPageInput, ComputerUseBrowserResultProposal, ComputerUseBrowserResultReviewInput) {
        let goal = try goal ?? Self.goal(), page = try ComputerUseBrowserResultPageInput(page: snapshot ?? Self.page())
        let content = try json(["candidates":[["container":"g1", "fields":[["kind":"title", "texts":["t1"]], ["kind":otherPriceRole ? "other" : "price", "texts":["t2"]]], "links":["l1"]]]])
        let proposal = try ComputerUseBrowserResultProposal.decode(content: content, input: page, goal: goal)
        return (page, proposal, try .init(goal: goal, page: page, proposal: proposal))
    }
    static func field(_ scope: String, _ price: String, _ qualifiers: [String] = []) -> [String: Any] { ["scope":scope, "price":price, "qualifiers":qualifiers] }
    static func content(association: String = "singleOffer", price: String = "exact", scope: String = "offer", titleScope: String = "offer", qualifiers: [String] = []) throws -> String {
        try json(["candidates":[["association":association, "fields":[field(titleScope, "notPrice"), field(scope, price, qualifiers)]]]])
    }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    static func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    static func envelope(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model":"fixture-model", "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]], options: [.sortedKeys])
    }
    static func local(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserResultReviewPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: transport)
    }
}

private actor ResultReviewTransport: ComputerUseTextModelTransport {
    let response: Data
    let count: Int
    let cancelCount: Bool
    let cancelCompletion: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(response: Data = Data(), count: Int = 100, cancelCount: Bool = false, cancelCompletion: Bool = false) {
        self.response = response; self.count = count; self.cancelCount = cancelCount; self.cancelCompletion = cancelCompletion
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        calls.counts += 1; requests.append(completionRequest)
        if cancelCount { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        calls.completions += 1; requests.append(request)
        if cancelCompletion { withUnsafeCurrentTask { $0?.cancel() } }
        return response
    }
}

private struct FixedReviewReading: ComputerUseBrowserResultPlanning {
    let value: ComputerUseBrowserResultProposal
    func propose(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput) async throws -> ComputerUseBrowserResultProposal { value }
}

@MainActor
private final class ResultReviewReply: ComputerUseBrowserResultReviewPlanning {
    var inputs: [ComputerUseBrowserResultReviewInput] = []
    var replacement: ComputerUseBrowserResultReview?
    var association = "singleOffer", price = "exact", scope = "offer", titleScope = "offer"
    var requirementPriceJudgment: String?
    var requirementCategoryJudgment: String?
    var beforeReply: (@MainActor () async -> Void)?
    func propose(_ input: ComputerUseBrowserResultReviewInput) async throws -> ComputerUseBrowserResultReview {
        inputs.append(input)
        if let beforeReply { await beforeReply() }
        if let replacement { return replacement }
        let context = try ResultReviewFixture.object(Data(input.contextJSON.utf8)), page = try XCTUnwrap(context["page"] as? [String: Any])
        let records = try XCTUnwrap(page["records"] as? [[String: Any]])
        let qualifiers: [String] = price == "qualified" ? [try XCTUnwrap(records.first { $0["text"] as? String == "From" }?["id"] as? String)] : []
        let content = try ResultReviewFixture.content(association: association, price: price, scope: scope, titleScope: titleScope, qualifiers: qualifiers)
        guard let interpretation = input.interpretation else { return try .decode(content: content, input: input) }
        var body = try ResultReviewFixture.object(Data(content.utf8))
        var candidates = try XCTUnwrap(body["candidates"] as? [[String: Any]])
        candidates[0]["requirements"] = interpretation.requirements.enumerated().map { index, requirement -> [String: Any] in
            if requirement.field == .category, let requirementCategoryJudgment {
                return ["requirement":index, "judgment":requirementCategoryJudgment, "texts":input.fieldTextIDs(candidate: 0, field: 0)]
            }
            let priceMatch = requirement.field == .price && association == "singleOffer" && scope == "offer" && price == "exact"
            return ["requirement":index, "judgment":priceMatch ? (requirementPriceJudgment ?? "supports") : "unknown",
                "texts":priceMatch ? input.fieldTextIDs(candidate: 0, field: 1) : []]
        }
        body["candidates"] = candidates
        return try .decode(content: ResultReviewFixture.json(body), input: input)
    }
}

private struct NativeReviewReading: ComputerUseBrowserResultPlanning {
    func propose(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput) async throws -> ComputerUseBrowserResultProposal {
        let context = try ResultReviewFixture.object(Data(page.contextJSON.utf8)), records = try XCTUnwrap(context["records"] as? [[String: Any]])
        let title = try XCTUnwrap(records.first { $0["text"] as? String == "Concert Alpha" })
        var container = try XCTUnwrap(title["group"] as? String)
        while let node = records.first(where: { $0["kind"] as? String == "container" && $0["id"] as? String == container }), node["element"] as? String != "article" {
            container = try XCTUnwrap(node["parent"] as? String)
        }
        let price = try XCTUnwrap(records.first { $0["text"] as? String == "USD 40" }), link = try XCTUnwrap(records.first { $0["label"] as? String == "Alpha details" })
        let content = try ResultReviewFixture.json(["candidates":[["container":container, "fields":[
            ["kind":"title", "texts":[try XCTUnwrap(title["id"] as? String)]], ["kind":"price", "texts":[try XCTUnwrap(price["id"] as? String)]]],
            "links":[try XCTUnwrap(link["id"] as? String)]]]])
        return try .decode(content: content, input: page, goal: goal)
    }
}

private struct ResultReviewGoal: ComputerUseBrowserGoalPlanning {
    var priceLimit = "50"
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        let rows: [[String: Any]] = [
            ["turn":0, "source":"Find concerts ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"under USD \(priceLimit). ", "role":"condition", "field":"price", "relation":"below", "values":[]],
            ["turn":0, "source":"Do not buy.", "role":"prohibition", "field":"other", "relation":"unspecified", "values":[]]]
        return try .decode(content: ResultReviewFixture.json(["disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]]), input: input)
    }
}

@MainActor
private final class ResultReviewLinks: ComputerUseBrowserLinkPlanning {
    var inputs: [ComputerUseBrowserLinkSelectionInput] = []
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        inputs.append(input)
        return try .decode(content: #"{"candidate":-1,"link":""}"#, input: input)
    }
}
