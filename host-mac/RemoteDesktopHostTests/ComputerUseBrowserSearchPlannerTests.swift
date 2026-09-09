import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserSearchPlannerTests: XCTestCase {
    func testNativeDateTermsKeepTheSourceClockAndWholeDateBounds() throws {
        for (source, expected) in [("today. ", "2026-09-09"), ("tomorrow. ", "2026-09-10"),
            ("before tomorrow. ", "before 2026-09-10"), ("after today. ", "after 2026-09-09"),
            ("on or before tomorrow. ", "on or before 2026-09-10"), ("on or after today. ", "on or after 2026-09-09"),
            ("from today through tomorrow. ", "from 2026-09-09 through 2026-09-10"), ("2026-10-16. ", "2026-10-16")] {
            let goal = try dateGoal(source), values = ComputerUseBrowserSearchQuery.dateTerms(for: goal)
            XCTAssertEqual(values.map(\.text), [expected]); XCTAssertEqual(values.first?.requirementIndices, [1])
            let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"requirement":0,"text":"concerts"},{"date":"date2"}]}"#, interpretation: goal)
            XCTAssertEqual(query.query, "concerts " + expected)
            XCTAssertEqual(try query.requirementIndices(in: goal), [0, 1])
            let term = try XCTUnwrap(query.terms.last)
            XCTAssertNotNil(term.dateNormalizationIdentity)
            XCTAssertEqual(term.sources.first?.sourceByteCount, source.utf8.count)
            XCTAssertEqual(term.sources.first?.sourceByteOffset, "Find concerts. ".utf8.count)
            XCTAssertEqual(term.sources.first?.requirementID, goal.requirements[1].id)
            XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(1, source.trimmingCharacters(in: .whitespacesAndNewlines))]), interpretation: goal))
            XCTAssertFalse(String(reflecting: term).contains(expected))
        }
    }

    func testDateTermRetainsEverySplitAnswerSourceAndItsAcceptedClock() throws {
        let initial = try dateGoal(nil), original = initial.input
        var clock = try date("2026-09-09T23:59:00Z")
        let state = ComputerUseBrowserGoalClarification(input: original, now: { clock }), context = try clarificationContext()
        let question = try state.issue(proposal: initial, topic: .date, requirementIDs: [initial.requirements[0].id], context: context)
        clock = try date("2026-09-10T00:01:00Z")
        let updated = try state.consume(questionID: question.id, answerTaskID: "date", answer: "from today through tomorrow", context: context)
        let parts = ["from to", "day through ", "tomorrow"]
        let goal = try decodeDateRows(dateRows(nil) + parts.map { dateRow($0, turn: 1, field: "location") }, input: updated)
        let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"requirement":0,"text":"concerts"},{"date":"date3"}]}"#, interpretation: goal)
        XCTAssertEqual(query.query, "concerts from 2026-09-10 through 2026-09-11")
        XCTAssertEqual(try query.requirementIndices(in: goal), [0, 2, 3, 4])
        XCTAssertEqual(query.terms.last?.sources.map(\.sourceByteCount), parts.map { $0.utf8.count })
        XCTAssertEqual(query.terms.last?.sources.map(\.sourceTurnIndex), [1, 1, 1])
        for (index, text) in [(2, "to"), (3, "day"), (4, "tomorrow")] {
            XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(index, text)]), interpretation: goal))
        }
        XCTAssertEqual(updated.rootDateContext, original.rootDateContext)
    }

    func testOnlyTheActiveReplacementDateCanSupplyANativeSearchTerm() throws {
        let initial = try dateGoal("before tomorrow. ")
        var clock = try date("2026-09-09T23:59:00Z")
        let state = ComputerUseBrowserGoalClarification(input: initial.input, now: { clock }), context = try clarificationContext()
        let oldQuery = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"date":"date2"}]}"#, interpretation: initial)
        let question = try state.issue(proposal: initial, topic: .replaceDate, requirementIDs: [initial.requirements[1].id], context: context)
        clock = try date("2026-09-10T00:01:00Z")
        let updated = try state.consume(questionID: question.id, answerTaskID: "date", answer: "tomorrow", context: context)
        let goal = try decodeDateRows(dateRows("before tomorrow. ") + [dateRow("tomorrow", turn: 1)], input: updated)
        XCTAssertEqual(ComputerUseBrowserSearchQuery.dateTerms(for: goal).map(\.id), ["date4"])
        let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"requirement":0,"text":"concerts"},{"date":"date4"}]}"#, interpretation: goal)
        XCTAssertEqual(query.query, "concerts 2026-09-11")
        XCTAssertThrowsError(try oldQuery.requirementIndices(in: goal))
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"date":"date2"}]}"#, interpretation: goal))
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(1, "tomorrow")]), interpretation: goal))
        let unresolvedState = ComputerUseBrowserGoalClarification(input: initial.input, now: { clock })
        let unresolvedQuestion = try unresolvedState.issue(proposal: initial, topic: .replaceDate, requirementIDs: [initial.requirements[1].id], context: context)
        let unresolvedInput = try unresolvedState.consume(questionID: unresolvedQuestion.id, answerTaskID: "compound", answer: "tomorrow evening", context: context)
        let unresolved = try decodeDateRows(dateRows("before tomorrow. ") + [dateRow("tomorrow evening", turn: 1)], input: unresolvedInput)
        XCTAssertTrue(ComputerUseBrowserScalarRequirements(proposal: unresolved).hasUncompiledDateReplacements)
        XCTAssertTrue(ComputerUseBrowserSearchQuery.dateTerms(for: unresolved).isEmpty)
        for value in [#"{"terms":[{"date":"date2"}]}"#, #"{"terms":[{"date":"date4"}]}"#,
            try content([(0, "concerts")]), try content([(3, "tomorrow")])] {
            XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: value, interpretation: unresolved))
        }
    }

    func testHistoricalUncompiledDateCannotEscapeThroughAReclassifiedLiteralTerm() throws {
        let initial = try dateGoal("before tomorrow. "), state = ComputerUseBrowserGoalClarification(input: initial.input)
        let context = try clarificationContext()
        let question = try state.issue(proposal: initial, topic: .location, requirementIDs: [initial.requirements[0].id], context: context)
        let updated = try state.consume(questionID: question.id, answerTaskID: "location", answer: "Paris", context: context)
        let goal = try decodeDateRows([dateRow("Find concerts. before ", role: "outcome", field: "category"),
            dateRow("tomorrow. ", field: "category"), dateRow("Under USD 50.", field: "price"), dateRow("Paris", turn: 1, field: "location")], input: updated)
        let catalog = try XCTUnwrap(ComputerUseBrowserSearchQuery.dateTermContext(for: goal))
        XCTAssertEqual(catalog["required_requirements"] as? [Int], [0, 1])
        XCTAssertTrue(ComputerUseBrowserSearchQuery.dateTerms(for: goal).isEmpty)
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(1, "tomorrow")]), interpretation: goal))
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"date":"date2"}]}"#, interpretation: goal))
        let unresolved = try dateGoal("next Friday. ")
        XCTAssertTrue(ComputerUseBrowserSearchQuery.dateTerms(for: unresolved).isEmpty)
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(1, "Friday")]), interpretation: unresolved))
        let title = try proposal(["Find Tomorrow Never Dies tickets."])
        XCTAssertEqual(try ComputerUseBrowserSearchQuery.decode(content: content([(0, "Tomorrow Never Dies")]), interpretation: title).query, "Tomorrow Never Dies")
    }

    func testNativeDateTermSchemaRejectsInventedHybridRepeatedAndReorderedValues() throws {
        let goal = try dateGoal("before 2026-10-16. ")
        for value in [#"{"terms":[{"date":"date99"}]}"#, #"{"terms":[{"date":true}]}"#,
            #"{"terms":[{"date":"date2","text":"2026-10-16"}]}"#, #"{"terms":[{"date":"date2","requirement":1}]}"#,
            #"{"terms":[{"date":"date2"},{"date":"date2"}]}"#, #"{"terms":[{"date":"date2"},{"requirement":0,"text":"concerts"}]}"#,
            #"{"terms":[{"requirement":1,"text":"2026-10-16"}]}"#, #"{"terms":[{"date":" date2"}]}"#,
            #"{"terms":[{"date":"date2","date":"date2"}]}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: value, interpretation: goal))
        }
        XCTAssertEqual(try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"date":"date2"}]}"#, interpretation: goal).query, "before 2026-10-16")
        let first = String(repeating: "😀", count: 256), second = String(repeating: "😁", count: 253)
        for extra in ["", "a"] {
            let rows = [dateRow(first + " ", role: "outcome", field: "category"), dateRow(second + extra + " ", field: "category"), dateRow("tomorrow")]
            let input = try ComputerUseBrowserGoalInput(taskID: "date-query-bytes", prompt: first + " " + second + extra + " tomorrow",
                referenceDate: date("2026-09-09T23:58:00Z"), timeZoneIdentifier: "UTC")
            let bounded = try decodeDateRows(rows, input: input)
            let payload = try ResearchAnswerFixture.json(["terms":[["requirement":0, "text":first], ["requirement":1, "text":second + extra], ["date":"date3"]]])
            if extra.isEmpty { XCTAssertEqual(try ComputerUseBrowserSearchQuery.decode(content: payload, interpretation: bounded).query?.utf8.count, 2_048) }
            else { XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: payload, interpretation: bounded)) }
        }
    }

    func testSearchPlannerReceivesNativeDateCatalogueWithoutNativeIdentities() throws {
        let goal = try dateGoal("tomorrow. "), planner = try localPlanner(SearchFixtureTransport(response: Data()))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(planner.makeRequest(goal).httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]]), text = try XCTUnwrap(messages[1]["content"])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(context["version"] as? Int, 3)
        let catalog = try XCTUnwrap(context["date_terms"] as? [String: Any])
        XCTAssertEqual(catalog["version"] as? Int, 1); XCTAssertEqual(catalog["required_requirements"] as? [Int], [1])
        let values = try XCTUnwrap(catalog["values"] as? [[String: Any]])
        XCTAssertEqual(values.first?["text"] as? String, "2026-09-10")
        XCTAssertEqual(values.first?["requirements"] as? [Int], [1])
        let format = try XCTUnwrap(body["response_format"] as? [String: Any]), schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "browser_search_query_v2")
        let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"date":"date2"}]}"#, interpretation: goal)
        for hidden in [goal.digest, goal.input.rootDigest, try XCTUnwrap(query.terms.first?.dateNormalizationIdentity)] { XCTAssertFalse(text.contains(hidden)) }
    }

    func testSearchTermsRetainExactUnicodeSourceOffsetsAndCompleteGoalIdentity() throws {
        let sources = ["Find concerts in Montréal e\u{301} 😀. ", "Under USD 50. ", "Do not buy."]
        let interpretation = try proposal(sources, roles: ["outcome", "condition", "prohibition"])
        let query = try ComputerUseBrowserSearchQuery.decode(content: content([(0, "concerts"), (0, "Montréal e\u{301} 😀"), (1, "USD 50")]),
            interpretation: interpretation)
        XCTAssertEqual(query.query, "concerts Montréal e\u{301} 😀 USD 50")
        XCTAssertEqual(query.goalDigest, interpretation.input.digest); XCTAssertEqual(query.interpretationDigest, interpretation.digest)
        XCTAssertEqual(query.terms.map(\.sourceByteOffset), [5, 17, sources[0].utf8.count + 6])
        for term in query.terms {
            let bytes = Data(interpretation.input.userTurns[term.sourceTurnIndex].utf8)
            XCTAssertEqual(bytes.subdata(in: term.sourceByteOffset..<(term.sourceByteOffset + term.text.utf8.count)), Data(term.text.utf8))
            XCTAssertFalse(String(reflecting: term).contains(term.text))
        }
        XCTAssertFalse(String(reflecting: query).contains("Montréal"))
        XCTAssertEqual(interpretation.input.prompt, sources.joined())
        let empty = try ComputerUseBrowserSearchQuery.decode(content: "{\"terms\":[]}", interpretation: interpretation)
        XCTAssertNil(empty.query); XCTAssertEqual(empty.goalDigest, interpretation.input.digest)
        XCTAssertNotEqual(empty.digest, query.digest)
    }

    func testSearchQueryRejectsInventedReorderedProhibitedAndMalformedTerms() throws {
        let interpretation = try proposal(["Find concerts in Montréal e\u{301}. ", "Under USD 50. ", "Do not buy."],
            roles: ["outcome", "condition", "prohibition"])
        let invalid = [
            "{\"terms\":[],\"url\":\"https://example.com\"}", "{\"terms\":null}", "{\"terms\":[],\"terms\":[]}",
            "{\"terms\":[{\"requirement\":true,\"text\":\"concerts\"}]}",
            "{\"terms\":[{\"requirement\":0.5,\"text\":\"concerts\"}]}",
            "{\"terms\":[{\"requirement\":0,\"text\":\"concerts\",\"turn\":0}]}",
            try content([(-1, "concerts")]), try content([(3, "concerts")]), try content([(0, "movies")]),
            try content([(0, "Montréal é")]), try content([(2, "buy")]), try content([(1, "USD 50"), (0, "concerts")]),
            try content([(0, "Montréal"), (0, "concerts")]), try content([(0, "concerts"), (0, "concerts")]),
            try content([(0, " concerts ")]), try content([(0, "")]), try content([(0, "concerts\n")]),
            try content(Array(repeating: (0, "concerts"), count: 13)),
            "{\"terms\":[]}" + String(repeating: " ", count: 16_384)
        ]
        for value in invalid {
            XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: value, interpretation: interpretation)) {
                XCTAssertEqual($0 as? ComputerUseBrowserSearchPlanError, .invalidProposal)
            }
        }
        let ordered = try proposal(["Find tickets. ", "Sort cheapest first."], roles: ["outcome", "order"])
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(1, "cheapest")]), interpretation: ordered))
    }

    func testSearchQueryEnforcesUTF8AndScalarBoundsWithoutTruncation() throws {
        let first = String(repeating: "😀", count: 256), second = String(repeating: "😁", count: 255) + "€"
        let atLimit = try proposal([first + " ", second], roles: ["outcome", "condition"])
        let accepted = try ComputerUseBrowserSearchQuery.decode(content: content([(0, first), (1, second)]), interpretation: atLimit)
        XCTAssertEqual(accepted.query?.utf8.count, 2_048)
        let oversized = String(repeating: "😁", count: 256)
        let overLimit = try proposal([first + " ", oversized], roles: ["outcome", "condition"])
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(0, first), (1, oversized)]), interpretation: overLimit))
        let longTerm = String(repeating: "a", count: 257), scalarLimit = try proposal([longTerm])
        XCTAssertThrowsError(try ComputerUseBrowserSearchQuery.decode(content: content([(0, longTerm)]), interpretation: scalarLimit))
        let repeated = try proposal(["tickets tickets"])
        let twice = try ComputerUseBrowserSearchQuery.decode(content: content([(0, "tickets"), (0, "tickets")]), interpretation: repeated)
        XCTAssertEqual(twice.terms.map(\.sourceByteOffset), [0, 8], "Repeated text must use distinct source occurrences")
    }

    func testLocalSearchPlannerKeepsWholeGoalAndFixedRuntimeRequestWithoutBrowserContext() async throws {
        let interpretation = try proposal(["Find concert tickets tomorrow. ", "Do not buy."], roles: ["outcome", "prohibition"])
        let transport = SearchFixtureTransport(response: try envelope(content([(0, "concert tickets")]))), planner = try localPlanner(transport)
        let result = try await planner.propose(interpretation)
        XCTAssertEqual(result.query, "concert tickets")
        let requests = await transport.requests, calls = await transport.calls
        XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, 1)
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].url?.absoluteString, "http://127.0.0.1:54321/v1/chat/completions")
        XCTAssertEqual(requests[0].timeoutInterval, 30)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["temperature"] as? Int, 0)
        XCTAssertEqual(body["cache_prompt"] as? Bool, false); XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2); XCTAssertEqual(messages[0]["content"], ComputerUseLocalBrowserSearchPlanner.instructions)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        XCTAssertEqual(Set(context.keys), ["version", "goal", "requirements"])
        let goal = try XCTUnwrap(context["goal"] as? [String: Any])
        XCTAssertEqual(goal["request"] as? String, interpretation.input.prompt)
        XCTAssertEqual(goal["referenceUnixMilliseconds"] as? Int64, interpretation.input.referenceMilliseconds)
        XCTAssertEqual(goal["timeZone"] as? String, interpretation.input.timeZoneIdentifier); XCTAssertNil(goal["taskID"])
        let requirements = try XCTUnwrap(context["requirements"] as? [[String: Any]])
        XCTAssertEqual(requirements.compactMap { $0["source"] as? String }.joined(), interpretation.input.prompt)
        let format = try XCTUnwrap(body["response_format"] as? [String: Any]), schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "browser_search_query_v1")
        let unsupported = try proposal(["Open Calculator."], roles: ["unsupported"], disposition: "unsupported")
        XCTAssertThrowsError(try planner.makeRequest(unsupported))
    }

    func testLocalSearchPlannerRejectsOverflowCancellationAndUntrustedResponses() async throws {
        let interpretation = try proposal(["Find tickets."])
        for mode in ["zero", "overflow", "at-limit", "cancel-count", "cancel-completion"] {
            let transport = SearchFixtureTransport(response: try envelope("{\"terms\":[]}"),
                count: mode == "zero" ? 0 : (mode == "overflow" ? 3_009 : 3_008),
                cancelCount: mode == "cancel-count", cancelCompletion: mode == "cancel-completion")
            let planner = try localPlanner(transport)
            let task = Task { try await planner.propose(interpretation) }
            do { _ = try await task.value; XCTAssertEqual(mode, "at-limit") }
            catch {
                if mode.hasPrefix("cancel") { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserSearchPlanError, .contextLimit) }
            }
            let calls = await transport.calls
            XCTAssertEqual(calls.counts, 1); XCTAssertEqual(calls.completions, ["at-limit", "cancel-completion"].contains(mode) ? 1 : 0)
        }
        let invalid = [Data("not JSON".utf8), try envelope("{\"terms\":[]}", model: "foreign"),
            try envelope("{\"terms\":[]}", finish: "length"), try envelope("{\"terms\":[]}", role: "user"),
            try envelope("{\"terms\":[]}", tools: [["function":["name":"navigate"]]]), try envelope("{\"url\":\"https://example.com\"}")]
        for response in invalid {
            let planner = try localPlanner(SearchFixtureTransport(response: response))
            do { _ = try await planner.propose(interpretation); XCTFail("An invalid response cannot supply a query") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserSearchPlanError, .invalidProposal) }
        }
    }

    func testOwnerSearchPlanningRequiresCurrentInterpretationAndRetainsExactAnswers() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = SearchOwnerFixture()
        defer { browser.close() }
        let input = try proposal(["Find tickets."]).input
        let owner = ComputerUseBrowserResearchTask(input: input, browser: browser, goalPlanner: BrowserResearchGoalFixture(),
            resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
        do { _ = try await owner.planInitialSearch(using: planner); XCTFail("Interpret the whole request first") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .interpretationRequired) }
        let interpretation = try await owner.interpretGoal()
        let original = try await owner.planInitialSearch(using: planner)
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        do { _ = try await owner.planInitialSearch(using: planner); XCTFail("An unanswered question blocks search planning") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .questionPending) }
        let answer = "  Paris e\u{301} 😀\n  "
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: answer, controllerID: "phone", controllerSessionID: "session")
        do { _ = try await owner.planInitialSearch(using: planner); XCTFail("The answer requires a new interpretation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .interpretationRequired) }
        _ = try await owner.interpretGoal()
        let current = try await owner.planInitialSearch(using: planner)
        XCTAssertEqual(planner.inputs.map(\.input.userTurns), [[input.prompt], [input.prompt, answer]])
        XCTAssertNotEqual(current.goalDigest, original.goalDigest)
        XCTAssertEqual(owner.input.rootDigest, input.rootDigest); XCTAssertEqual(owner.input.referenceMilliseconds, input.referenceMilliseconds)
        planner.replacement = original
        do { _ = try await owner.planInitialSearch(using: planner); XCTFail("An old revision cannot supply the current query") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .goalChanged) }
        let alternateRows = owner.input.userTurns.enumerated().map { index, source -> [String: Any] in
            ["turn":index, "source":source, "role":index == 0 ? "outcome" : "condition", "field":"other", "relation":"unspecified", "values":[]]
        }
        let alternateData = try JSONSerialization.data(withJSONObject: ["disposition":"research", "requirements":alternateRows,
            "question":["topic":"none", "requirements":[]] as [String: Any]])
        let alternate = try ComputerUseBrowserGoalProposal.decode(content: String(decoding: alternateData, as: UTF8.self), input: owner.input)
        planner.replacement = try .decode(content: content([(0, "tickets")]), interpretation: alternate)
        do { _ = try await owner.planInitialSearch(using: planner); XCTFail("The same goal with a different interpretation is not the owner's current source ledger") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .goalChanged) }
        XCTAssertNil(browser.taskID, "Query planning must not claim or open a browser")
    }

    func testOwnerSearchPlanningHoldsCancellationUntilUnwindAndRequiresExplicitHandback() async throws {
        for retires in [false, true] {
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = SearchOwnerFixture(), gate = BrowserResearchGate()
            defer { gate.release(); browser.close() }
            let owner = ComputerUseBrowserResearchTask(input: try proposal(["Find tickets."]).input, browser: browser,
                goalPlanner: BrowserResearchGoalFixture(), resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
            _ = try await owner.interpretGoal()
            planner.beforeReply = { await gate.suspend() }
            let running = Task { try await owner.planInitialSearch(using: planner) }
            try await gate.waitUntilStarted()
            if retires { owner.retire() } else { owner.pause() }
            XCTAssertTrue(owner.isOperating)
            do { try await owner.resumeAfterUserControl(); XCTFail("The old operation still owns the slot") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, retires ? .retired : .busy) }
            gate.release()
            do { _ = try await running.value; XCTFail("A late query cannot escape cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(owner.isOperating)
            if !retires {
                planner.beforeReply = nil
                try await owner.resumeAfterUserControl()
                _ = try await owner.planInitialSearch(using: planner)
                XCTAssertEqual(planner.inputs.count, 2)
            }
            XCTAssertNil(browser.taskID)
        }
    }

    private func date(_ value: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: value)) }
    private func dateRow(_ source: String, turn: Int = 0, role: String = "condition", field: String = "date") -> [String: Any] {
        ["turn":turn, "source":source, "role":role, "field":field, "relation":"unspecified", "values":[String]()]
    }
    private func dateRows(_ source: String?) -> [[String: Any]] {
        [dateRow("Find concerts. ", role: "outcome", field: "category")]
            + (source.map { [dateRow($0)] } ?? []) + [dateRow("Under USD 50.", field: "price")]
    }
    private func dateGoal(_ source: String?) throws -> ComputerUseBrowserGoalProposal {
        let rows = dateRows(source)
        let input = try ComputerUseBrowserGoalInput(taskID: "native-date-terms", prompt: rows.map { $0["source"] as! String }.joined(),
            referenceDate: date("2026-09-09T23:58:00Z"), timeZoneIdentifier: "UTC")
        return try decodeDateRows(rows, input: input)
    }
    private func decodeDateRows(_ rows: [[String: Any]], input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        try .decode(content: ResearchAnswerFixture.json(["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]] as [String: Any]]), input: input)
    }
    private func clarificationContext() throws -> ComputerUseBrowserGoalClarification.Context {
        try .init(controllerID: "phone", controllerSessionID: "session", browserSessionDigest: nil)
    }
    private func proposal(_ sources: [String], roles: [String]? = nil, disposition: String = "research") throws -> ComputerUseBrowserGoalProposal {
        let input = try ComputerUseBrowserGoalInput(taskID: "root", prompt: sources.joined(),
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
        let rows = sources.enumerated().map { index, source -> [String: Any] in
            ["turn":0, "source":source, "role":roles?[index] ?? "outcome", "field":"category", "relation":"unspecified", "values":[]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["disposition":disposition, "requirements":rows,
            "question":["topic":"none", "requirements":[]] as [String: Any]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
    private func content(_ terms: [(Int, String)]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["terms":terms.map { ["requirement":$0.0, "text":$0.1] as [String: Any] }]), as: UTF8.self)
    }
    private func envelope(_ content: String, model: String = "fixture-model", finish: String = "stop", role: String = "assistant", tools: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model":model, "choices":[["finish_reason":finish,
            "message":["role":role, "content":content, "tool_calls":tools] as [String: Any]]]])
    }
    private func localPlanner(_ transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserSearchPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: transport)
    }
}

@MainActor
private final class SearchOwnerFixture: ComputerUseBrowserSearchPlanning {
    private(set) var inputs: [ComputerUseBrowserGoalProposal] = []
    var replacement: ComputerUseBrowserSearchQuery?
    var beforeReply: (@MainActor () async -> Void)?
    func propose(_ interpretation: ComputerUseBrowserGoalProposal) async throws -> ComputerUseBrowserSearchQuery {
        inputs.append(interpretation)
        if let beforeReply { await beforeReply() }
        return try replacement ?? .decode(content: "{\"terms\":[{\"requirement\":0,\"text\":\"tickets\"}]}", interpretation: interpretation)
    }
}

private actor SearchFixtureTransport: ComputerUseTextModelTransport {
    let response: Data
    let count: Int
    let cancelCount: Bool
    let cancelCompletion: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var calls = (counts: 0, completions: 0)
    init(response: Data, count: Int = 100, cancelCount: Bool = false, cancelCompletion: Bool = false) {
        self.response = response; self.count = count; self.cancelCount = cancelCount; self.cancelCompletion = cancelCompletion
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest); calls.counts += 1
        if cancelCount { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request); calls.completions += 1
        if cancelCompletion { withUnsafeCurrentTask { $0?.cancel() } }
        return response
    }
}
