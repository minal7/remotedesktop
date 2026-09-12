import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserControlRelevanceTests: XCTestCase {
    func testUnreadValuesRemainExplicitAndCannotClearMissingMetadata() throws {
        for missingMetadata in [false, true] {
            let input = try input(omittedControls: missingMetadata)
            XCTAssertEqual(input.controlMetadataComplete, !missingMetadata)
            XCTAssertEqual(input.unobservedControlIDs, ["c0", "c1"])
            let context = try object(input.contextJSON), page = try XCTUnwrap(context["page"] as? [String: Any])
            XCTAssertEqual(page["omitted_controls"] as? Bool, true)
            XCTAssertEqual(context["version"] as? Int, 6)
            let unknown = try ComputerUseBrowserResultReview.decode(content: json(body(input)), input: input)
            XCTAssertFalse(unknown.permitsAnswerWithUnobservedControls(for: 0))
            XCTAssertEqual(unknown.candidates[0].controls.map(\.relationship), [.unknown, .unknown])
            let proposal = try json(body(input, relationships: [.unrelated, .unrelated]))
            if missingMetadata { XCTAssertThrowsError(try ComputerUseBrowserResultReview.decode(content: proposal, input: input)) }
            else {
                let review = try ComputerUseBrowserResultReview.decode(content: proposal, input: input)
                XCTAssertTrue(review.permitsAnswerWithUnobservedControls(for: 0))
                XCTAssertNotEqual(review.digest, unknown.digest)
            }
        }
        let uninterpreted = try input(interpreted: false)
        XCTAssertThrowsError(try ComputerUseBrowserResultReview.decode(content: json(body(uninterpreted, relationships: [.unrelated, .unrelated])), input: uninterpreted))
        let missing = try input(controls: 0, omittedControls: true)
        let review = try ComputerUseBrowserResultReview.decode(content: json(body(missing)), input: missing)
        XCTAssertFalse(review.permitsAnswerWithUnobservedControls(for: 0), "An empty list cannot clear genuinely omitted controls")
    }

    func testWholeReviewRequiresExactCoverageAndObservedMetadataCitations() throws {
        let input = try input(), whole = body(input, relationships: [.unrelated, .unrelated])
        let base = try XCTUnwrap((whole["candidates"] as? [[String: Any]])?.first)
        let controls = try XCTUnwrap(base["controls"] as? [[String: Any]])
        let invalid: [Any] = [[], Array(controls.prefix(1)), controls + controls,
            [controls[0], controls[0]], Array(controls.reversed()), NSNull(),
            [["control":"c0", "relationship":"unrelated", "evidence":[]], controls[1]],
            [["control":"c0", "relationship":"unrelated", "evidence":["c0", "c0"]], controls[1]],
            [["control":"c0", "relationship":"unrelated", "evidence":["c0", "t999"]], controls[1]],
            [["control":"c0", "relationship":"unrelated", "evidence":["c0", "c1"]], controls[1]],
            [["control":"c0", "relationship":"unrelated", "evidence":["c0", "t3"]], controls[1]],
            [["control":"c0", "relationship":"unrelated", "evidence":["c0"], "value":"invented"], controls[1]]]
        for rows in invalid {
            var changed = try XCTUnwrap(whole["candidates"] as? [[String: Any]])
            changed[0]["controls"] = rows
            XCTAssertThrowsError(try ComputerUseBrowserResultReview.decode(content: json(["candidates":changed]), input: input))
        }
        let review = try ComputerUseBrowserResultReview.decode(content: json(whole), input: input)
        XCTAssertThrowsError(try review.validate(for: self.input(root: "different-task")))
        XCTAssertFalse(review.permitsAnswerWithUnobservedControls(for: -1))
        XCTAssertFalse(review.permitsAnswerWithUnobservedControls(for: input.candidateCount))
    }

    func testRelevanceIsPerCandidateAndCannotSupplyResultSupport() throws {
        let input = try input()
        let review = try ComputerUseBrowserResultReview.decode(content: json(body(input, relationships: [.unrelated, .relevant])), input: input)
        XCTAssertTrue(review.permitsAnswerWithUnobservedControls(for: 0)); XCTAssertFalse(review.permitsAnswerWithUnobservedControls(for: 1))
        XCTAssertEqual(review.candidates[1].controls.map(\.relationship), [.relevant, .relevant])
        let context = review.plannerContext
        XCTAssertEqual((context[0]["controls"] as? [[String: Any]])?.first?["relationship"] as? String, "unrelated")
        var rows = try XCTUnwrap(body(input, relationships: [.unrelated, .unrelated])["candidates"] as? [[String: Any]])
        var requirements = try XCTUnwrap(rows[0]["requirements"] as? [[String: Any]])
        requirements[0]["texts"] = ["c0"]
        rows[0]["requirements"] = requirements
        XCTAssertThrowsError(try ComputerUseBrowserResultReview.decode(content: json(["candidates":rows]), input: input))
    }

    func testSegmentedReviewAccountsForEveryControlWithinExistingBounds() throws {
        let input = try input(controls: 6), whole = body(input, relationships: [.unrelated, .relevant])
        XCTAssertFalse(try ComputerUseBrowserReviewPart.wholeOutputFits(input))
        let parts = try ComputerUseBrowserReviewPart.plan(input)
        XCTAssertLessThanOrEqual(parts.count, ComputerUseBrowserReviewPart.maximumParts)
        for candidate in 0..<input.candidateCount {
            XCTAssertEqual(parts.filter { $0.candidate == candidate }.flatMap(\.controls), input.unobservedControlIDs)
        }
        var assembly = try ComputerUseBrowserReviewAssembly(input: input, parts: parts)
        for part in parts {
            XCTAssertLessThanOrEqual(try part.maximumCanonicalOutputBytes, ComputerUseBrowserReviewPart.maximumOutputBytes)
            let context = try object(part.contextJSON), requested = try XCTUnwrap(context["requested_output"] as? [String: Any])
            XCTAssertEqual(requested["controls"] as? [String], part.controls)
            XCTAssertEqual(context["goal"] as? NSDictionary, try object(input.contextJSON)["goal"] as? NSDictionary)
            var output = try partBody(part, whole: whole)
            let saved = output.removeValue(forKey: "controls")
            XCTAssertThrowsError(try ComputerUseBrowserReviewPartReply.decode(json(output), part: part))
            output["controls"] = saved
            if !part.controls.isEmpty {
                var changed = output; changed["controls"] = []
                XCTAssertThrowsError(try ComputerUseBrowserReviewPartReply.decode(json(changed), part: part))
            }
            XCTAssertThrowsError(try ComputerUseBrowserResultReview.assemble(assembly))
            try assembly.append(.decode(json(output), part: part))
        }
        let assembled = try ComputerUseBrowserResultReview.assemble(assembly)
        let complete = try ComputerUseBrowserResultReview.decode(content: json(whole), input: input)
        XCTAssertEqual(assembled, complete)
        XCTAssertTrue(assembled.permitsAnswerWithUnobservedControls(for: 0)); XCTAssertFalse(assembled.permitsAnswerWithUnobservedControls(for: 1))
    }

    func testLocalRequestIncludesBoundedControlReviewWithoutInvokingTransport() throws {
        let input = try input(), planner = try ComputerUseLocalBrowserResultReviewPlanner(connection: .init(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let parts = try ComputerUseBrowserReviewPart.plan(input)
        for (index, part) in [nil, parts.first, parts.last].enumerated() {
            let request = try planner.makeRequest(input, part: part), body = try ResearchAnswerFixture.object(XCTUnwrap(request.httpBody))
            let format = try XCTUnwrap(body["response_format"] as? [String: Any]), schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
            XCTAssertEqual(schema["name"] as? String, part == nil ? "browser_result_review_v6" : "browser_result_review_part_v5")
            XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(request.timeoutInterval, 30)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], try part?.contextJSON ?? input.contextJSON)
            if let path = ProcessInfo.processInfo.environment["REPAIR_PLANNER_REQUEST_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(request.httpBody).write(to: directory.appendingPathComponent("unread-control-\(index).json"), options: .atomic)
            }
        }
    }

    func testDriverCanAnswerBesideUnrelatedNewsletterWithoutReadingItsValue() async throws {
        for relationship in [nil, ComputerUseBrowserControlRelevance.Relationship.unknown, .relevant, .unrelated] {
            let fixture = try await ResearchAnswerFixture.make(surroundingHTML: newsletter,
                controlRelationships: relationship.map { [$0] })
            defer { fixture.source.close() }
            let result = try await fixture.source.start(), owner = try fixture.source.owner()
            let reading = try await owner.revalidateCandidates()
            XCTAssertTrue(reading.omittedControls)
            XCTAssertEqual(reading.surroundingControls.first?.state?.kind, .unavailable)
            if relationship == .unrelated {
                guard case .browserResearchAnswer(let answer)? = result else { return XCTFail("An unrelated unread field should not suppress complete result facts") }
                try owner.validateAnswer(answer)
                XCTAssertTrue(answer.message.contains("Concert Alpha")); XCTAssertTrue(answer.message.contains("State unavailable"))
                XCTAssertFalse(answer.message.contains("privateMailbox"))
            } else {
                guard case .userInterventionRequired? = result else { return XCTFail("Relevant/unknown controls remain unresolved") }
                XCTAssertFalse(reading.review?.permitsAnswerWithUnobservedControls(for: 0) ?? true)
            }
            XCTAssertFalse(fixture.source.state.commands.contains(.observeResearchControls))
            XCTAssertFalse(fixture.source.state.commands.contains(.edit))
            for input in fixture.inputs {
                XCTAssertFalse(input.contextJSON.contains("privateMailbox"))
            }
            XCTAssertEqual(owner.input.prompt, fixture.source.request)
        }
    }

    func testOneCandidatesRelevanceCannotCompleteAnotherCandidatesRequirementCount() async throws {
        let fixture = try await ResearchAnswerFixture.make(count: 2, requested: 2, surroundingHTML: newsletter,
            controlRelationships: [.unrelated, .relevant])
        defer { fixture.source.close() }
        let result = try await fixture.source.start(), owner = try fixture.source.owner()
        guard case .userInterventionRequired? = result else { return XCTFail("One eligible result cannot satisfy two requested options") }
        let reading = try await owner.revalidateCandidates()
        XCTAssertEqual(reading.answerPage(goal: owner.input)?.candidateIndices, [0])
        XCTAssertTrue(fixture.inputs.allSatisfy { $0.answerCounts.isEmpty })
    }

    func testChangedMetadataAndHandbackInvalidateEarlierIrrelevance() async throws {
        for changesMetadata in [true, false] {
            let script = """
                <script>fetch('/signal').then(() => { document.getElementById('purpose').textContent='Required ticket eligibility email'; fetch('/changed'); });</script>
                """
            let fixture = try await ResearchAnswerFixture.make(surroundingHTML: newsletter + (changesMetadata ? script : ""),
                controlRelationships: [.unrelated], heldSignal: changesMetadata)
            defer { fixture.source.close() }
            guard case .browserResearchAnswer(let answer)? = try await fixture.source.start() else { return XCTFail("Expected initial answer") }
            let owner = try fixture.source.owner(), goal = owner.input
            if changesMetadata {
                fixture.source.server.releaseHeldResponses()
                let deadline = ContinuousClock.now + .seconds(5)
                while fixture.source.server.count("/changed") == 0 {
                    guard ContinuousClock.now < deadline else { return XCTFail("Fixture metadata did not change") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                do { _ = try await owner.revalidateCandidates(); XCTFail("Old metadata cannot support a new relationship") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            } else {
                owner.pause(); try await owner.resumeAfterUserControl()
            }
            XCTAssertThrowsError(try owner.validateAnswer(answer))
            XCTAssertEqual(owner.input, goal)
        }
    }

    private var newsletter: String { "<section><p>Optional newsletter subscription, separate from ticket offers</p><label><span id=purpose>Newsletter email</span><input type=email value=privateMailbox></label></section>" }

    private func input(root: String = "control-relevance", controls count: Int = 2, omittedControls: Bool = false,
                       interpreted: Bool = true) throws -> ComputerUseBrowserResultReviewInput {
        let sources = ["Find concerts. ", "Under USD 50. ", "Do not buy."]
        let goal = try ComputerUseBrowserGoalInput(taskID: root, prompt: sources.joined(), referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")
        let rows: [[String: Any]] = sources.enumerated().map { ["turn":0, "source":$0.element,
            "role":$0.offset == 0 ? "outcome" : ($0.offset == 1 ? "condition" : "prohibition"),
            "field":$0.offset == 0 ? "category" : ($0.offset == 1 ? "price" : "other"), "relation":"unspecified", "values":[]] }
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: json(["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]]]), input: goal)
        var containers: [ComputerUseBrowserPageSnapshot.Container] = [.init(id: "g0", parentID: nil, kind: "body")]
        var texts: [ComputerUseBrowserPageSnapshot.Text] = [], selections: [[String: Any]] = []
        for index in 0..<2 {
            let group = "g\(index + 1)", title = "t\(index * 2 + 1)", price = "t\(index * 2 + 2)"
            containers.append(.init(id: group, parentID: "g0", kind: "article"))
            texts += [.init(id: title, containerID: group, text: "Concert \(index)"), .init(id: price, containerID: group, text: "USD 40")]
            selections.append(["container":group, "fields":[["kind":"title", "texts":[title]], ["kind":"price", "texts":[price]]], "links":[]])
        }
        let controls: [ComputerUseBrowserPageSnapshot.Control] = (0..<count).map {
            .init(id: "c\($0)", containerID: "g0", label: "Optional newsletter email \($0)", kind: "email", name: "newsletter\($0)",
                disabled: false, readOnly: false, required: false, multiple: false, constraints: [:], options: [])
        }
        let states: [ComputerUseBrowserControlState] = controls.map { .init(controlID: $0.id, kind: .unavailable, value: nil, selectedOptionIDs: nil, checked: nil, indeterminate: nil) }
        let page = try ComputerUseBrowserResultPageInput(page: .init(id: String(repeating: "a", count: 32), texts: texts, links: [], controls: controls,
            truncated: false, omittedEmbeddedContent: false, omittedControls: omittedControls, containers: containers, omittedStructure: false,
            controlStates: states, controlStateObserved: true))
        let proposal = try ComputerUseBrowserResultProposal.decode(content: json(["candidates":selections]), input: page, goal: goal)
        return try .init(goal: goal, page: page, proposal: proposal, interpretation: interpreted ? interpretation : nil)
    }
    private func body(_ input: ComputerUseBrowserResultReviewInput, relationships: [ComputerUseBrowserControlRelevance.Relationship]? = nil) -> [String: Any] {
        ["candidates":(0..<input.candidateCount).map { candidate -> [String: Any] in
            var row: [String: Any] = ["association":"singleOffer", "fields":[
                ["scope":"offer", "price":"notPrice", "qualifiers":[]], ["scope":"offer", "price":"exact", "qualifiers":[]]],
                "requirements":(0..<input.requirementCount).map { index in
                    ["requirement":index, "judgment":index < 2 ? "supports" : "unknown",
                     "texts":index < 2 ? input.fieldTextIDs(candidate: candidate, field: index) : []] as [String: Any]
                }]
            if input.interpretation == nil { row.removeValue(forKey: "requirements") }
            if let relationships {
                row["controls"] = input.unobservedControlIDs.map { ["control":$0, "relationship":relationships[candidate].rawValue, "evidence":[$0]] as [String: Any] }
            }
            return row
        }]
    }
    private func partBody(_ part: ComputerUseBrowserReviewPart, whole: [String: Any]) throws -> [String: Any] {
        let candidate = try XCTUnwrap(whole["candidates"] as? [[String: Any]])[part.candidate]
        let fields = try XCTUnwrap(candidate["fields"] as? [[String: Any]]), requirements = try XCTUnwrap(candidate["requirements"] as? [[String: Any]])
        let controls = try XCTUnwrap(candidate["controls"] as? [[String: Any]])
        return ["candidate":part.candidate, "association":try XCTUnwrap(candidate["association"]),
            "fields":part.fields.map { index in var row = fields[index]; row["field"] = index; return row },
            "requirements":part.requirements.map { requirements[$0] },
            "controls":controls.filter { ($0["control"] as? String).map { part.controls.contains($0) } == true }]
    }
    private func json(_ value: Any) throws -> String { try ResearchAnswerFixture.json(value) }
    private func object(_ value: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(value.utf8)) }
}
