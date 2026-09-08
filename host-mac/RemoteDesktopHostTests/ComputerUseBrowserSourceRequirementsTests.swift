import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserSourceRequirementsTests: XCTestCase {
    func testAnswerRestrictionsKeepAuxiliarySearchAvailableWhileNavigationRestrictionsSelectAnotherProvider() throws {
        let search = try provider("https://search.test/search"), site = try provider("https://tickets.test/search")
        for field in ["answerSource", "navigationSource"] {
            let rows = [row("Find concert tickets. "), row("Only use tickets.test.", field: field, values: ["tickets.test"])]
            let proposal = try proposal(rows), compiled = ComputerUseBrowserSourceRequirements(proposal: proposal)
            let sources = try XCTUnwrap(compiled.selectSources(from: [search, site]))
            XCTAssertTrue(compiled.unresolved.isEmpty)
            XCTAssertEqual(sources.provider, field == "answerSource" ? search : site)
            XCTAssertEqual(sources.policy.permits(url("https://search.test/results")), field == "answerSource")
            if field == "answerSource" {
                XCTAssertFalse(sources.answerPolicy.permitsEvidenceFrom(url("https://search.test/results")))
                XCTAssertTrue(sources.answerPolicy.permitsEvidenceFrom(url("https://tickets.test/offers")))
                XCTAssertFalse(sources.answerPolicy.permitsEvidenceFrom(url("https://www.tickets.test/offers")))
                XCTAssertFalse(sources.answerPolicy.permitsEvidenceFrom(url("https://tickets.test.attacker.test")))
                XCTAssertFalse(sources.answerPolicy.permitsEvidenceFrom(url("http://tickets.test")))
            } else { XCTAssertNil(try compiled.selectSources(from: [search]), "No implicit provider exception") }
            XCTAssertEqual(compiled.goal, proposal.input); XCTAssertEqual(compiled.interpretationDigest, proposal.digest)
        }
    }

    func testSourceCompilationPreservesAlternativesIntersectionsExclusionsAndCrossScopeConflicts() throws {
        let search = try provider("https://search.test/search")
        var rows = [row("Find tickets. "), row("Use a.test or b.test. ", field: "answerSource", values: ["a.test", "b.test"]),
                    row("Also only b.test or c.test. ", field: "answerSource", values: ["b.test", "c.test"])]
        let sources = try XCTUnwrap(ComputerUseBrowserSourceRequirements(proposal: proposal(rows)).selectSources(from: [search]))
        XCTAssertTrue(sources.answerPolicy.permitsEvidenceFrom(url("https://b.test")))
        for host in ["a.test", "c.test"] { XCTAssertFalse(sources.answerPolicy.permitsEvidenceFrom(url("https://" + host))) }
        rows.append(row("Exclude b.test.", role: "prohibition", field: "answerSource", relation: "exclude", values: ["b.test"]))
        let conflict = ComputerUseBrowserSourceRequirements(proposal: try proposal(rows))
        XCTAssertEqual(Set(conflict.unresolved.map(\.reason)), [.contradictorySources])
        XCTAssertNil(try conflict.selectSources(from: [search]))
        for restriction in [row("Only visit a.test. ", field: "navigationSource", values: ["a.test"]),
                            row("Never visit b.test. ", role: "prohibition", field: "navigationSource", relation: "exclude", values: ["b.test"])] {
            let proposal = try proposal([row("Find tickets. "), restriction, row("Only report from b.test.", field: "answerSource", values: ["b.test"])])
            let compiled = ComputerUseBrowserSourceRequirements(proposal: proposal)
            XCTAssertFalse(compiled.unresolved.isEmpty); XCTAssertNil(try compiled.selectSources(from: [search]))
        }
    }

    func testUnsupportedOriginsPreferencesAndAmbiguousScopeCannotBeDroppedOrWidened() throws {
        let search = try provider("https://search.test/search")
        for value in ["Ticketmaster", "https://a.test/events", "https://a.test/?q=concerts", "https://a.test/#login",
                      "https://user:password@a.test", "https://a.test./", "*.a.test", "a.test,", "https://é.test", "https://a%2Etest"] {
            let compiled = ComputerUseBrowserSourceRequirements(proposal: try proposal([
                row("Find tickets. "), row("Only report from a.test or " + value, field: "answerSource", values: ["a.test", value])]))
            XCTAssertEqual(compiled.unresolved.first?.reason, .invalidOrigin, value)
            XCTAssertNil(try compiled.selectSources(from: [search]), value)
        }
        for (field, role, relation) in [("source", "condition", "include"), ("answerSource", "order", "include"),
                                       ("navigationSource", "condition", "unspecified"), ("answerSource", "prohibition", "include")] {
            let compiled = ComputerUseBrowserSourceRequirements(proposal: try proposal([
                row("Find tickets. "), row("Prefer a.test, depending on availability.", role: role, field: field, relation: relation, values: ["a.test"])]))
            XCTAssertFalse(compiled.unresolved.isEmpty); XCTAssertNil(try compiled.selectSources(from: [search]))
        }
        for (source, hint) in [("https://a.test/events", "a.test"), ("https://a.test/events", "https://a.test"),
                               ("https://a.test?category=movies", "https://a.test"), ("mail@a.test", "a.test"),
                               ("a.test.attacker.test", "a.test"), ("a.test:8443", "a.test")] {
            let compiled = ComputerUseBrowserSourceRequirements(proposal: try proposal([
                row("Find tickets. "), row("Only report from " + source, field: "answerSource", values: [hint])]))
            XCTAssertEqual(compiled.unresolved.first?.reason, .invalidOrigin)
            XCTAssertNil(try compiled.selectSources(from: [search]), "A copied substring is not the entire website reference")
        }
        let unsupported = try proposal([row("Find tickets.", role: "unsupported")], disposition: "unsupported")
        XCTAssertNil(try ComputerUseBrowserSourceRequirements(proposal: unsupported).selectSources(from: [search]))
    }

    func testHostSourceQuestionKeepsRootAndRequiresACompleteFreshInterpretationAfterAnswer() async throws {
        let rows = [row("Find concert tickets. "), row("Use tickets.test.", field: "source", values: ["tickets.test"])]
        let initial = try proposal(rows), planner = SourceGoalFixture(initial), browser = ComputerUseOwnedBrowser(presentsWindow: false)
        defer { browser.close() }
        let owner = ComputerUseBrowserResearchTask(input: initial.input, browser: browser, goalPlanner: planner,
            resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
        _ = try await owner.interpretGoal()
        let request = try XCTUnwrap(owner.proposedQuestionRequest())
        XCTAssertEqual(request.topic, .source); XCTAssertEqual(request.requirementIDs, [initial.requirements[1].id])
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "phone", controllerSessionID: "session")
        let answer = "Only report results from tickets.test. Auxiliary browsing is allowed."
        XCTAssertThrowsError(try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: answer,
            controllerID: "other-phone", controllerSessionID: "session"))
        let revised = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: answer,
            controllerID: "phone", controllerSessionID: "session")
        XCTAssertEqual(revised.userTurns, [initial.input.prompt, answer]); XCTAssertEqual(revised.rootDigest, initial.input.rootDigest)
        XCTAssertEqual(revised.referenceMilliseconds, initial.input.referenceMilliseconds)
        XCTAssertEqual(revised.timeZoneIdentifier, initial.input.timeZoneIdentifier)
        XCTAssertThrowsError(try owner.proposedQuestionRequest())
        let newRows = [rows[0], row("Use tickets.test.", field: "answerSource", values: ["tickets.test"]),
                       row(answer, field: "answerSource", values: ["tickets.test"], turn: 1)]
        planner.proposal = try proposal(newRows, input: revised)
        let interpreted = try await owner.interpretGoal()
        XCTAssertNil(try owner.proposedQuestionRequest())
        let sources = try XCTUnwrap(interpreted.sources.selectSources(from: [provider("https://search.test/search")]))
        try owner.configureResearchSources(sources)
        XCTAssertEqual(sources.policy.goalRevision, revised.digest)
        XCTAssertFalse(sources.answerPolicy.permitsEvidenceFrom(url("https://search.test")))
        XCTAssertNil(browser.taskID, "Interpreting and clarifying sources allocates no browser session")
        XCTAssertThrowsError(try owner.answerQuestion(questionID: question.id, answerTaskID: "again", answer: answer,
            controllerID: "phone", controllerSessionID: "session"))
    }

    func testSourceQuestionCanClarifySourceProhibitionsWithoutAdmittingUnrelatedQuestionScopes() throws {
        let rows = [row("Find tickets. "), row("Never use tickets.test.", role: "prohibition", field: "source", relation: "exclude", values: ["tickets.test"])]
        let proposed = try proposal(rows), state = ComputerUseBrowserGoalClarification(input: proposed.input)
        let context = try ComputerUseBrowserGoalClarification.Context(controllerID: "phone", controllerSessionID: "session", browserSessionDigest: nil)
        XCTAssertThrowsError(try state.issue(proposal: proposed, topic: .location, requirementIDs: [proposed.requirements[1].id], context: context))
        let question = try state.issue(proposal: proposed, topic: .source, requirementIDs: [proposed.requirements[1].id], context: context)
        XCTAssertEqual(question.scope[0].source, "Never use tickets.test.")
        XCTAssertEqual(question.text, ComputerUseBrowserClarificationTopic.source.question)
    }

    func testNativeCandidateEvidenceUsesItsCommittedOriginNotAllowedSiteNamesInPageText() async throws {
        let fixture = try await ResearchDriverFixture.make(additionalCardHTML: "<p>Official offers from allowed.test</p>")
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), document = try await fixture.browser.acquireObservedDocument(taskID: owner.taskID)
        let evidence = try await fixture.browser.observePage(document: document), page = try ComputerUseBrowserResultPageInput(page: evidence.page)
        let proposal = try await fixture.results.propose(goal: owner.input, page: page)
        let allowed = try ComputerUseBrowserAnswerSourcePolicy(goal: owner.input, allowedOrigins: [ComputerUseBrowserSourceOrigin(fixture.base)])
        let excluded = try ComputerUseBrowserAnswerSourcePolicy(goal: owner.input, allowedOrigins: [ComputerUseBrowserSourceOrigin(url("https://allowed.test"))])
        let unconfigured = try await fixture.browser.prepareResultCandidates(proposal, goal: owner.input, evidence: evidence)
        let auxiliary = try await fixture.browser.prepareResultCandidates(proposal, goal: owner.input, evidence: evidence, answerPolicy: excluded)
        let eligible = try await fixture.browser.prepareResultCandidates(proposal, goal: owner.input, evidence: evidence, answerPolicy: allowed)
        XCTAssertEqual(unconfigured.documentAnswerSourceStatus, .unconfigured)
        XCTAssertEqual(auxiliary.documentAnswerSourceStatus, .excluded); XCTAssertEqual(eligible.documentAnswerSourceStatus, .permitted)
        XCTAssertNotEqual(auxiliary.candidates[0].id, eligible.candidates[0].id)
        for batch in [unconfigured, auxiliary] {
            do { try await fixture.browser.validateResultAnswerSource(batch, goal: owner.input, policy: allowed); XCTFail("An unbound or auxiliary source is not answer evidence") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
        }
        do { try await fixture.browser.validateResultAnswerSource(auxiliary, goal: owner.input, policy: excluded); XCTFail("Even the exact policy rejects excluded evidence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
        try await fixture.browser.validateResultAnswerSource(eligible, goal: owner.input, policy: allowed)
        let foreign = try ComputerUseBrowserAnswerSourcePolicy(goal: goal("Find tickets.", id: "foreign"))
        do { _ = try await fixture.browser.prepareResultCandidates(proposal, goal: owner.input, evidence: evidence, answerPolicy: foreign); XCTFail("Foreign goal policy") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResultError, .goalChanged) }
        let input = try ComputerUseBrowserLinkSelectionInput(goal: owner.input, candidates: auxiliary, history: owner.confirmedNavigationHistory)
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        XCTAssertEqual(content["document_answer_source_status"] as? String, "excluded")
        XCTAssertFalse(input.contextJSON.contains(excluded.digest))
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "changed-answer-document", to: fixture.base.appendingPathComponent("details"))
        do { try await fixture.browser.validateResultAnswerSource(eligible, goal: owner.input, policy: allowed); XCTFail("Matching origin does not revive evidence from an old document") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
    }

    func testCompilerAdapterDriverKeepsAuxiliaryPageIneligibleAndSourceSelectionImmutableAcrossResume() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        let rows = [row("Find concerts. "), row("Only report results from tickets.test.", field: "answerSource", values: ["tickets.test"])]
        let initial = try proposal(rows, id: ResearchDriverFixture.root, date: ResearchDriverFixture.date)
        let links = SourceLinkFixture(), goals = SourceGoalFixture(initial)
        let driver = ComputerUseBrowserResearchDriver(goalPlanner: goals, resultPlanner: fixture.results, searchPlanner: fixture.search,
            planning: ComputerUseModelBrowserResearchPlanning(providers: [fixture.policy.provider], linkPlanner: links),
            now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
        let result = try await driver.executeBrowserResearch(taskID: initial.input.taskID, prompt: initial.input.prompt, tools: fixture.tools, progress: { _ in })
        guard case .userInterventionRequired = result else { return XCTFail("A search page is not a verified answer") }
        let owner = try fixture.owner(), batch = try await owner.readCandidates()
        XCTAssertEqual(owner.input, initial.input); XCTAssertEqual(batch.documentAnswerSourceStatus, .excluded)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1); XCTAssertEqual(fixture.server.count("/details"), 0)
        let widened = try ComputerUseBrowserResearchSources(goal: owner.input, provider: fixture.policy.provider)
        XCTAssertThrowsError(try owner.configureResearchSources(widened), "Answer-only changes are still policy changes")
        owner.pause(); try await owner.resumeAfterUserControl()
        _ = try await driver.continueBrowserResearch(taskID: owner.executionTaskID, research: owner, tools: fixture.tools, progress: { _ in })
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(links.inputs.count, 2); XCTAssertTrue(links.inputs.allSatisfy { $0.contextJSON.contains("\"document_answer_source_status\":\"excluded\"") })
    }

    func testPauseDuringNativeSourceInstallationRetainsTheWholeAnswerPolicy() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        var owner: ComputerUseBrowserResearchTask?
        let input = try goal("Find concerts.")
        owner = ComputerUseBrowserResearchTask(input: input, browser: fixture.browser, goalPlanner: BrowserResearchGoalFixture(),
            resultPlanner: fixture.results, mayAct: { true })
        let retained = try XCTUnwrap(owner)
        _ = try await retained.interpretGoal()
        // Admit/capture a native session with no configured source plan yet.
        try fixture.browser.claim(taskID: input.taskID)
        _ = try await fixture.browser.navigate(taskID: input.taskID, operationID: "seed", to: fixture.base.appendingPathComponent("details"))
        _ = try await retained.readCandidates()
        let sources = try ComputerUseBrowserResearchSources(goal: input, provider: fixture.policy.provider,
            answerAllowedOrigins: [ComputerUseBrowserSourceOrigin(url("https://tickets.test"))])
        fixture.state.onMayAct = { fixture.state.onMayAct = nil; owner?.pause() }
        do { try retained.configureResearchSources(sources); XCTFail("Pause must withhold successful publication") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        try await retained.resumeAfterUserControl()
        let widened = try ComputerUseBrowserResearchSources(goal: input, provider: fixture.policy.provider)
        XCTAssertThrowsError(try retained.configureResearchSources(widened), "A native installation pinned both policies before Pause")
        try retained.configureResearchSources(sources)
        let candidates = try await retained.readCandidates()
        XCTAssertEqual(candidates.documentAnswerSourceStatus, .excluded)
        retained.retire(); owner = nil
    }

    private func url(_ value: String) -> URL { URL(string: value)! }
    private func provider(_ value: String) throws -> ComputerUseBrowserSearchProvider { try .init(endpoint: url(value), queryParameter: "q") }
    private func goal(_ prompt: String, id: String = "source-root", date: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: id, prompt: prompt, referenceDate: date, timeZoneIdentifier: "America/Los_Angeles")
    }
    private func row(_ source: String, role: String? = nil, field: String = "category", relation: String? = nil,
                     values: [String] = [], turn: Int = 0) -> [String: Any] {
        ["turn":turn, "source":source, "role":role ?? (field == "category" ? "outcome" : "condition"), "field":field,
         "relation":relation ?? (field == "category" ? "unspecified" : "include"), "values":values]
    }
    private func proposal(_ rows: [[String: Any]], input: ComputerUseBrowserGoalInput? = nil, id: String = "source-root",
                          date: Date = Date(timeIntervalSince1970: 1_800_000_000), disposition: String = "research") throws -> ComputerUseBrowserGoalProposal {
        let input = try input ?? goal(rows.compactMap { $0["source"] as? String }.joined(), id: id, date: date)
        let data = try JSONSerialization.data(withJSONObject: ["disposition":disposition, "requirements":rows, "question":["topic":"none", "requirements":[]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

@MainActor
private final class SourceGoalFixture: ComputerUseBrowserGoalPlanning {
    var proposal: ComputerUseBrowserGoalProposal
    init(_ proposal: ComputerUseBrowserGoalProposal) { self.proposal = proposal }
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        guard input == proposal.input else { throw ComputerUseBrowserGoalPlanError.invalidInput }
        return proposal
    }
}

@MainActor
private final class SourceLinkFixture: ComputerUseBrowserLinkPlanning {
    var inputs: [ComputerUseBrowserLinkSelectionInput] = []
    func propose(_ input: ComputerUseBrowserLinkSelectionInput) async throws -> ComputerUseBrowserLinkProposal {
        inputs.append(input)
        return try .decode(content: #"{"candidate":-1,"link":""}"#, input: input)
    }
}
