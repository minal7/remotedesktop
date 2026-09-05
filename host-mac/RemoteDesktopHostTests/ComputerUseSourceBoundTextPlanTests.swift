import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseSourceBoundTextPlanTests: XCTestCase {
    func testTypedRequirementsOfferOnlyTaskMentionsAndCannotAttachEditsToADecline() throws {
        let connection = try ComputerUseTextModelConnection(baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "fictional-test-token", modelAlias: "test-native")
        func variants(_ prompt: String) throws -> [[String: Any]] {
            let request = try ComputerUseLocalTextGoalPlanner(connection: connection, contract: .sourceBoundV5)
                .makeRequest(catalog: .init(prompt), fields: fields)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let requirements = try XCTUnwrap(properties["requirements"] as? [String: Any])
            return try XCTUnwrap((requirements["items"] as? [String: Any])?["oneOf"] as? [[String: Any]])
        }
        let choices = try variants(#"Set "Destination" to "private value"."#)
        XCTAssertEqual(choices.count, 4)
        for choice in choices {
            let properties = try XCTUnwrap(choice["properties"] as? [String: Any])
            let kind = try XCTUnwrap((properties["kind"] as? [String: Any])?["const"] as? String)
            let edits = try XCTUnwrap(properties["edits"] as? [String: Any])
            let preserve = try XCTUnwrap(properties["preserve"] as? [String: Any])
            if kind == "edits" {
                let item = try XCTUnwrap(edits["items"] as? [String: Any])
                let target = try XCTUnwrap((item["properties"] as? [String: Any])?["target"] as? [String: Any])
                XCTAssertEqual(target["enum"] as? [String], ["p1"], "Unmentioned labels and quoted values cannot be advertised as target mentions")
            } else { XCTAssertEqual(edits["const"] as? [String], []) }
            if kind != "constraint" { XCTAssertEqual(preserve["const"] as? [String], []) }
        }
        let missing = try variants("Change City to Paris.")
        let kinds = missing.compactMap { (($0["properties"] as? [String: Any])?["kind"] as? [String: Any])?["const"] as? String }
        XCTAssertFalse(kinds.contains("edits"), "A task without a field mention cannot invent one from an opaque ID")
    }

    func testSourceFirstSchemaChangesDeclarationOrderWithoutChangingInstructionsOrConstraints() throws {
        let connection = try ComputerUseTextModelConnection(baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "fictional-test-token", modelAlias: "test-native")
        let catalog = try ComputerUseTextPayloadCatalog(#"Set "Origin" to "Paris"."#)
        let before = try ComputerUseLocalTextGoalPlanner(connection: connection, contract: .sourceBoundV3).makeRequest(catalog: catalog, fields: fields)
        let after = try ComputerUseLocalTextGoalPlanner(connection: connection, contract: .sourceBoundV4).makeRequest(catalog: catalog, fields: fields)
        let oldData = try XCTUnwrap(before.httpBody), newData = try XCTUnwrap(after.httpBody)
        let oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? NSDictionary)
        let newObject = try XCTUnwrap(JSONSerialization.jsonObject(with: newData) as? NSDictionary)
        XCTAssertEqual(oldObject, newObject, "Only declaration ordering may change in this comparison")
        let text = String(decoding: newData, as: UTF8.self)
        XCTAssertTrue(text.contains(#""properties":{"source":{"type":"string"},"kind":"#))
        XCTAssertTrue(String(decoding: oldData, as: UTF8.self).contains(#""properties":{"edits":"#))
        XCTAssertNotEqual(oldData, newData)
        XCTAssertEqual(after.httpBody, try ComputerUseLocalTextGoalPlanner(connection: connection, contract: .sourceBoundV4)
            .makeRequest(catalog: catalog, fields: fields).httpBody, "The ordered wire contract remains deterministic")
    }

    private var fields: [ComputerUseTextField] {
        ["Origin", "Destination"].enumerated().map { index, label in
            .init(label: label, snapshot: .init(targetID: "target-\(index)", value: "private existing text",
                selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))
        }
    }
    private func edit(_ field: String = "f1", _ target: String = "Origin", _ value: String = "Paris", _ mode: String = "replaceAll") -> [String: String] {
        ["fieldID": field, "target": target, "value": value, "mode": mode]
    }
    private func row(_ source: String, _ kind: String = "edits", _ edits: [[String: String]] = [],
                     preserve: [[String: String]] = []) -> [String: Any] {
        ["source": source, "kind": kind, "edits": edits, "preserve": preserve]
    }
    private func decode(_ prompt: String, _ rows: [[String: Any]], fields: [ComputerUseTextField]? = nil) throws -> ComputerUseTextGoalProposal {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": rows]), as: UTF8.self)
        return try ComputerUseSourceBoundTextPlan.decode(content: content, catalog: .init(prompt), fields: fields ?? self.fields)
    }

    func testExactLiteralRolesAndExplicitBackReferenceCompileOrderedEdits() throws {
        let prompt = "Replace Origin with \"  東京\ne\u{301} 😀  \", then append \" / Tacoma\" to it."
        let plan = try decode(prompt, [row("Replace Origin with [exact quoted payload p1],", "edits", [edit("f1", "Origin", "p1")]),
                                      row("then append [exact quoted payload p2] to it.", "edits", [edit("f1", "it", "p2", "append")])])
        XCTAssertEqual(plan, .edits([.init(targetID: "target-0", mode: .replaceAll, text: "  東京\ne\u{301} 😀  "),
                                    .init(targetID: "target-0", mode: .append, text: " / Tacoma")], unchangedTargetIDs: ["target-1"]))
    }

    func testMissingAddedReorderedAndPartialSourceTokensRejectTheWholeProposal() throws {
        let prompt = "Set Origin to Paris, then open Calendar."
        for sources in [["Set Origin to Paris,"], ["Set Origin to Paris, then open Calendar"],
                        ["Set Origin to Paris, then do not open Calendar."], ["then open Calendar.", "Set Origin to Paris,"]] {
            XCTAssertThrowsError(try decode(prompt, sources.map { row($0, "edits", [edit()]) }))
        }
        XCTAssertEqual(try decode(prompt, [row("Set Origin to Paris,", "edits", [edit()]),
                                          row("then open Calendar.", "other")]), .unsupported)
        XCTAssertThrowsError(try decode("Do not set Origin to Paris.", [row("Set Origin to Paris.", "edits", [edit()])]))
    }

    func testQuotedTargetOccurrenceCannotAlsoAuthorizeAnInputPayload() throws {
        let prompt = #"Set "Destination" to "Berlin"."#
        let source = "Set [exact quoted payload p1] to [exact quoted payload p2]."
        XCTAssertThrowsError(try decode(prompt, [row(source, "edits", [edit("f2", "p1", "p1"), edit("f2", "p1", "p2")])]))
        XCTAssertEqual(try decode(prompt, [row(source, "edits", [edit("f2", "p1", "p2")])]),
            .edits([.init(targetID: "target-1", mode: .replaceAll, text: "Berlin")], unchangedTargetIDs: ["target-0"]))
        XCTAssertEqual(try decode(#"Set "Origin" to "Origin"."#, [row(source, "edits", [edit("f1", "p1", "p2")])]),
            .edits([.init(targetID: "target-0", mode: .replaceAll, text: "Origin")], unchangedTargetIDs: ["target-1"]))
    }

    func testCrossClausePayloadAndFabricatedTargetProofsRejectBeforeEditing() throws {
        let prompt = #"Set Origin to "Paris", then set Destination to "Berlin"."#
        let first = row("Set Origin to [exact quoted payload p1],", "edits", [edit("f1", "Origin", "p1")])
        let second = "then set Destination to [exact quoted payload p2]."
        for proposed in [edit("f2", "Destination", "p1"), edit("f1", "Destination", "p2"),
                         edit("f2", "Origin", "p2"), edit("f2", "Destination", "payload")] {
            XCTAssertThrowsError(try decode(prompt, [first, row(second, "edits", [proposed])]))
        }
        XCTAssertThrowsError(try decode("Set Origin to Paris.", [row("Set Origin to Paris.", "edits", [edit("f1", "Origin", "Par")])]))
    }

    func testDuplicateBindingCannotProduceExtraEditsButRepeatedClausesCan() throws {
        XCTAssertThrowsError(try decode("Set Origin to Paris.", [row("Set Origin to Paris.", "edits", [edit(), edit()])]))
        XCTAssertThrowsError(try decode("Set Origin to Paris.", [row("Set Origin to Paris.", "edits", [edit(), edit("f1", "Origin", "Paris", "append")])]))
        let plan = try decode("Set Origin to Paris, then set Origin to Paris.",
            [row("Set Origin to Paris,", "edits", [edit()]), row("then set Origin to Paris.", "edits", [edit()])])
        XCTAssertEqual(plan, .edits([.init(targetID: "target-0", mode: .replaceAll, text: "Paris"),
                                    .init(targetID: "target-0", mode: .replaceAll, text: "Paris")], unchangedTargetIDs: ["target-1"]))
        let both = try decode("Set Origin and Destination to Paris.",
            [row("Set Origin and Destination to Paris.", "edits", [edit(), edit("f2", "Destination")])])
        XCTAssertEqual(both, .edits([.init(targetID: "target-0", mode: .replaceAll, text: "Paris"),
                                    .init(targetID: "target-1", mode: .replaceAll, text: "Paris")]))
    }

    func testUnchangedFieldProofCannotBeDroppedOrContradictedByAnEdit() throws {
        let prompt = "Do not change Origin. Set Destination to Paris."
        let constraint = row("Do not change Origin.", "constraint", preserve: [["fieldID": "f1", "target": "Origin"]])
        XCTAssertEqual(try decode(prompt, [constraint, row("Set Destination to Paris.", "edits", [edit("f2", "Destination")])]),
            .edits([.init(targetID: "target-1", mode: .replaceAll, text: "Paris")], unchangedTargetIDs: ["target-0"]))
        XCTAssertThrowsError(try decode("Do not change Origin. Set Origin to Paris.",
            [constraint, row("Set Origin to Paris.", "edits", [edit()])]))
        XCTAssertThrowsError(try decode(prompt, [row("Do not change Origin.", "constraint", preserve: [["fieldID": "f2", "target": "Origin"]]),
                                               row("Set Destination to Paris.", "edits", [edit("f2", "Destination")])]))
        XCTAssertThrowsError(try decode("Do not change Origin.", [row("Do not change Origin.", "constraint", [edit()])]))
    }

    func testAmbiguousLabelsAndUnboundBackReferencesCannotChooseAnArbitraryField() throws {
        let duplicate = [fields[0], ComputerUseTextField(label: "origin", snapshot: fields[1].snapshot)]
        XCTAssertEqual(try decode("Set Origin to Paris.", [row("Set Origin to Paris.", "edits", [edit()])], fields: duplicate), .clarification)
        XCTAssertThrowsError(try decode("Append Paris to it.", [row("Append Paris to it.", "edits", [edit("f1", "it", "Paris", "append")])]))
        let prompt = "Set Origin and Destination to Paris, then append Rome to it."
        XCTAssertThrowsError(try decode(prompt, [row("Set Origin and Destination to Paris,", "edits", [edit(), edit("f2", "Destination")]),
                                               row("then append Rome to it.", "edits", [edit("f1", "it", "Rome", "append")])]))
    }

    func testSourceSpacingNormalizationDoesNotNormalizeTheUnquotedPayload() throws {
        let prompt = "Set Origin to San  Francisco."
        let source = "Set Origin to San Francisco."
        XCTAssertThrowsError(try decode(prompt, [row(source, "edits", [edit("f1", "Origin", "San Francisco")])]))
        XCTAssertEqual(try decode(prompt, [row(source, "edits", [edit("f1", "Origin", "San  Francisco")])]),
            .edits([.init(targetID: "target-0", mode: .replaceAll, text: "San  Francisco")], unchangedTargetIDs: ["target-1"]))
        XCTAssertThrowsError(try decode("Set Origin to e\u{301}.", [row("Set Origin to e\u{301}.", "edits", [edit("f1", "Origin", "é")])]))
    }

    func testCandidateRequestRetainsExactBudgetAndStrictEnvelopeWithoutExposingValues() async throws {
        let transport = SourceBoundFixtureTransport()
        let planner = ComputerUseLocalTextGoalPlanner(connection: try .init(baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "fictional-test-token", modelAlias: "test-native"), transport: transport, contract: .sourceBoundV3)
        let catalog = try ComputerUseTextPayloadCatalog(#"Set "Origin" to "private payload"."#)
        let request = try planner.makeRequest(catalog: catalog, fields: fields)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], ComputerUseSourceBoundTextPlan.instructions)
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        for value in ["private payload", "private existing text", "target-0"] { XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(value)) }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": [
            row("Set [exact quoted payload p1] to [exact quoted payload p2].", "edits", [edit("f1", "p1", "p2")])]]), as: UTF8.self)
        for finish in ["length", "tool_calls"] {
            let envelope = try JSONSerialization.data(withJSONObject: ["model": "test-native", "choices": [["finish_reason": finish,
                "message": ["role": "assistant", "content": content]]]])
            XCTAssertThrowsError(try planner.decode(envelope, catalog: catalog, fields: fields))
        }
        do { _ = try await planner.propose(prompt: "Set Origin to Paris.", fields: fields); XCTFail("Exact token overflow must stop inference") }
        catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .contextLimit) }
        let calls = await transport.completions
        XCTAssertEqual(calls, 0)
    }
}

private actor SourceBoundFixtureTransport: ComputerUseTextModelTransport {
    private(set) var completions = 0
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { 3_009 }
    func complete(request: URLRequest) async throws -> Data { completions += 1; return Data() }
}
