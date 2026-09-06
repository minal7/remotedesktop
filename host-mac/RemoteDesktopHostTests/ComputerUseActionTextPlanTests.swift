import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseActionTextPlanTests: XCTestCase {
    private var fields: [ComputerUseTextField] {
        ["Origin", "Destination"].enumerated().map { index, name in
            .init(label: name, snapshot: .init(targetID: "private-target-\(index)", value: "private existing value \(index)",
                selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))
        }
    }
    private func planner(transport: any ComputerUseTextModelTransport = ActionTransport(),
                         contract: ComputerUseLocalTextGoalPlanner.Contract = .textActionsV10) throws -> ComputerUseLocalTextGoalPlanner {
        try .init(connection: .init(baseURL: URL(string: "http://127.0.0.1:49123")!, bearerToken: "fictional-test-token", modelAlias: "test-native"),
            transport: transport, contract: contract)
    }
    private func operation(_ action: String, target: String = "f2", arguments: [String: String], mode: String = "replaceAll") -> [String: String] {
        arguments.merging(["action": action, "targetFieldID": target, "mode": mode]) { _, new in new }
    }
    private func content(_ operations: [[String: String]], disposition: String = "supported") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["disposition": disposition, "operations": operations]), as: UTF8.self)
    }
    private func decode(_ prompt: String, _ operations: [[String: String]], disposition: String = "supported",
                        targets: [ComputerUseTextField]? = nil) throws -> ComputerUseTextGoalProposal {
        try ComputerUseActionTextPlan.decode(content: content(operations, disposition: disposition), catalog: .init(prompt), fields: targets ?? fields)
    }

    func testSchemaChoosesActionBeforeSourceAndTargetAndRestrictsLiteralIDs() throws {
        for prompt in [#"Set "Origin" to "private exact payload"."#, "Copy Origin into Destination."] {
            let request = try planner().makeRequest(catalog: .init(prompt), fields: fields)
            let data = try XCTUnwrap(request.httpBody), string = String(decoding: data, as: UTF8.self)
            for secret in ["private exact payload", "private existing value", "private-target-"] { XCTAssertFalse(string.contains(secret)) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            let named = try XCTUnwrap(format["json_schema"] as? [String: Any])
            let schema = try XCTUnwrap(named["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let operations = try XCTUnwrap(properties["operations"] as? [String: Any])
            let items = try XCTUnwrap(operations["items"] as? [String: Any])
            let variants = try XCTUnwrap(items["oneOf"] as? [[String: Any]])
            let quoted = variants.first { (($0["properties"] as? [String: Any])?["action"] as? [String: String])?["const"] == "enterLiteral" }
            if prompt.contains("\"") {
                let arguments = try XCTUnwrap(quoted?["properties"] as? [String: Any])
                XCTAssertEqual((arguments["literalID"] as? [String: Any])?["enum"] as? [String], ["p1", "p2"])
                XCTAssertNil(arguments["text"])
            } else { XCTAssertNil(quoted, "An empty literal enum must not enter the grammar") }
            XCTAssertTrue(string.contains(#""properties":{"action":{"const":"copyField"},"sourceFieldID":"#))
            let source = try XCTUnwrap(string.range(of: #""properties":{"action":{"const":"copyField"},"sourceFieldID":"#))
            let suffix = String(string[source.lowerBound...])
            XCTAssertLessThan(try XCTUnwrap(suffix.range(of: "sourceFieldID")?.lowerBound),
                              try XCTUnwrap(suffix.range(of: "targetFieldID")?.lowerBound))
        }
    }

    func testExplicitActionsPreserveDirectionPayloadOriginAndRepeatedStepIdentity() async throws {
        let prompt = #"Put "  東京 é 😀  " in Origin, then copy Origin into Destination twice."#
        let operations = [operation("enterLiteral", target: "f1", arguments: ["literalID": "p1"]),
                          operation("copyField", arguments: ["sourceFieldID": "f1"]),
                          operation("copyField", arguments: ["sourceFieldID": "f1"])]
        let transport = ActionTransport(content: try content(operations))
        let result = try await planner(transport: transport).propose(prompt: prompt, fields: fields)
        guard case .fieldOperations(let plan, let unchanged) = result else { return XCTFail("Expected typed actions") }
        XCTAssertEqual(plan, [.enterText(.init(targetID: fields[0].snapshot.targetID, mode: .replaceAll, text: "  東京 e\u{301} 😀  ")),
            .copyField(sourceTargetID: fields[0].snapshot.targetID, targetID: fields[1].snapshot.targetID, mode: .replaceAll),
            .copyField(sourceTargetID: fields[0].snapshot.targetID, targetID: fields[1].snapshot.targetID, mode: .replaceAll)])
        let contract = try ComputerUseTextTaskContract(taskID: "actions", prompt: prompt, fields: fields, operations: plan, unchangedTargetIDs: unchanged)
        XCTAssertEqual(Set(contract.steps.map(\.id)).count, 3)
        XCTAssertTrue(contract.steps.allSatisfy { $0.payload.utf8.elementsEqual("  東京 e\u{301} 😀  ".utf8) })
        XCTAssertEqual(contract.steps[1].copySource?.targetID, fields[0].snapshot.targetID)
        XCTAssertEqual(contract.steps[2].copySource?.targetID, fields[0].snapshot.targetID)
        let calls = await transport.completions
        XCTAssertEqual(calls, 1)
        let literal = try decode(#"Put "Origin" in Destination."#, [operation("enterLiteral", arguments: ["literalID": "p1"])])
        XCTAssertEqual(literal, .fieldOperations([.enterText(.init(targetID: fields[1].snapshot.targetID, mode: .replaceAll, text: "Origin"))],
            unchangedTargetIDs: [fields[0].snapshot.targetID]))
    }

    func testUnquotedAuthorityExcludesGeneratedMarkersAndQuotedContent() throws {
        let prompt = #"Put "private quoted text" in Destination."#
        let catalog = try ComputerUseTextPayloadCatalog(prompt)
        for value in ["p1", "exact quoted payload", "[exact quoted payload p1]", "private quoted text"] {
            XCTAssertNil(catalog.resolveUnquoted(value))
            XCTAssertNil(catalog.resolve(reference: "", userText: value, originalTask: catalog.projectedTask),
                "The existing production planner must reject synthetic source text too")
            XCTAssertThrowsError(try decode(prompt, [operation("enterUnquoted", arguments: ["text": value])]))
        }
        let separated = try ComputerUseTextPayloadCatalog(#"before"hidden"after"#)
        XCTAssertNil(separated.resolveUnquoted("beforeafter"))
        XCTAssertNil(separated.resolveUnquoted("before after"))
        XCTAssertEqual(separated.resolveUnquoted("before"), "before")
        let exact = try ComputerUseTextPayloadCatalog("Put cafe\u{301} in Origin.")
        XCTAssertNil(exact.resolveUnquoted("café"))
        XCTAssertEqual(exact.resolveUnquoted("cafe\u{301}"), "cafe\u{301}")
        let actualID = #"Put p1 in Origin and "literal" in Destination."#
        let resolved = try decode(actualID, [operation("enterUnquoted", target: "f1", arguments: ["text": "p1"])])
        XCTAssertEqual(resolved, .fieldOperations([.enterText(.init(targetID: fields[0].snapshot.targetID, mode: .replaceAll, text: "p1"))],
            unchangedTargetIDs: [fields[1].snapshot.targetID]))
        let markerWords = try ComputerUseTextPayloadCatalog("Put exact quoted payload in Destination.")
        XCTAssertEqual(markerWords.resolveUnquoted("exact quoted payload"), "exact quoted payload", "Real user words must remain available")
    }

    func testStrictActionDecoderRejectsMixedInventedAndMissingBindings() throws {
        let prompt = #"Put "Origin" in Destination."#
        for item in [operation("enterLiteral", arguments: ["literalID": "Origin"]),
                     operation("enterLiteral", arguments: ["literalID": "f1"]),
                     operation("enterLiteral", arguments: ["literalID": "p1", "sourceFieldID": "f1"]),
                     operation("enterUnquoted", arguments: ["text": "invented"]),
                     operation("copyField", arguments: ["sourceFieldID": "f3"]),
                     operation("copyField", arguments: ["sourceFieldID": "f1", "literalID": "p1"]),
                     operation("generateText", arguments: ["text": "hello"])] {
            XCTAssertThrowsError(try decode(prompt, [item]))
        }
        XCTAssertThrowsError(try decode("Copy City into Destination.", [operation("copyField", arguments: ["sourceFieldID": "f1"])]))
        XCTAssertThrowsError(try decode(prompt, [operation("enterLiteral", arguments: ["literalID": "p1"])], disposition: "unsupported"))
        XCTAssertThrowsError(try decode(prompt, []))
        let duplicate = fields + [.init(label: "origin", snapshot: .init(targetID: "third", value: "private",
            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))]
        XCTAssertEqual(try decode("Copy Origin into Destination.", [operation("copyField", arguments: ["sourceFieldID": "f1"])], targets: duplicate), .clarification)
    }

    func testActionPlannerKeepsExactBudgetAndEligibilityChecksBeforeInference() async throws {
        for contract in [ComputerUseLocalTextGoalPlanner.Contract.textActionsV10, .textActionsV11] {
        let oversized = ActionTransport(tokenCount: 3_009)
        do { _ = try await planner(transport: oversized, contract: contract).propose(prompt: "Copy Origin into Destination.", fields: fields); XCTFail("Overflow must stop") }
        catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .contextLimit) }
        let calls = await oversized.completions
        XCTAssertEqual(calls, 0)
        let protected = [ComputerUseTextField(label: "Password", snapshot: .init(targetID: "secure", value: "secret",
            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: true))]
        let unused = ActionTransport()
        let result = try await planner(transport: unused, contract: contract).propose(prompt: "Copy Password into Destination.", fields: protected + fields)
        XCTAssertEqual(result, .unsupported)
        let protectedCalls = await unused.completions
        XCTAssertEqual(protectedCalls, 0)
        }
    }

    func testLiteralTextLookupDoesNotAliasFieldsOrRevealOtherPayloads() throws {
        let prompt = #"Put "Origin" in Destination, then put "private supplied text" in Origin."#
        let catalog = try ComputerUseTextPayloadCatalog(prompt)
        let request = try planner(contract: .textActionsV11).makeRequest(catalog: catalog, fields: fields)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages.last?["content"]).utf8)) as? [String: Any])
        XCTAssertNil(context["literalFieldMatches"])
        XCTAssertEqual(context["literalTextByID"] as? [String: String], ["p1": "Origin"])
        XCTAssertEqual(context["literalPayloadIDs"] as? [String], ["p1", "p2"])
        XCTAssertEqual(context["task"] as? String, #"Put "Origin" in Destination, then put [exact quoted payload p2] in Origin."#)
        let raw = String(decoding: data, as: UTF8.self)
        for secret in ["private supplied text", "private existing value", "private-target-"] { XCTAssertFalse(raw.contains(secret)) }
        var before = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(planner().makeRequest(catalog: catalog, fields: fields).httpBody)) as? [String: Any])
        var after = body
        before.removeValue(forKey: "messages"); after.removeValue(forKey: "messages")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: after, options: [.sortedKeys]), "Schema and sampling are unchanged")
        XCTAssertThrowsError(try ComputerUseLocalTextGoalPlanner.context(catalog: catalog, fields: fields,
            includeQuotedFieldMatches: true, includeLiteralTextLookup: true), "Conflicting identity and text metadata must not be composed")
    }

    func testLiteralSpellingAndCopyAmbiguityRemainIndependentOfLabelMatches() async throws {
        let duplicate = fields + [.init(label: "ORIGIN", snapshot: .init(targetID: "third", value: "private duplicate",
            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))]
        let prompt = #"Put "origin" in Destination."#
        let catalog = try ComputerUseTextPayloadCatalog(prompt)
        let text = try ComputerUseLocalTextGoalPlanner.context(catalog: catalog, fields: duplicate,
            preserveQuotedFieldNames: true, includeLiteralTextLookup: true)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(context["literalTextByID"] as? [String: String], ["p1": "origin"], "Retain user spelling, not the observed label's case")
        let transport = ActionTransport(content: try content([operation("enterLiteral", arguments: ["literalID": "p1"])]))
        let entered = try await planner(transport: transport, contract: .textActionsV11).propose(prompt: prompt, fields: duplicate)
        XCTAssertEqual(entered, .fieldOperations([.enterText(.init(targetID: fields[1].snapshot.targetID, mode: .replaceAll, text: "origin"))],
            unchangedTargetIDs: [fields[0].snapshot.targetID, "third"]))
        let copying = ActionTransport(content: try content([operation("copyField", arguments: ["sourceFieldID": "f1"])]))
        let copied = try await planner(transport: copying, contract: .textActionsV11).propose(prompt: #"Copy the "origin" field into Destination."#, fields: duplicate)
        XCTAssertEqual(copied, .clarification, "A literal does not require disambiguating a source field; a copy does")
    }
}

private actor ActionTransport: ComputerUseTextModelTransport {
    private(set) var completions = 0
    let tokenCount: Int; let content: String
    init(tokenCount: Int = 500, content: String = #"{"disposition":"unsupported","operations":[]}"#) {
        self.tokenCount = tokenCount; self.content = content
    }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { tokenCount }
    func complete(request: URLRequest) async throws -> Data {
        completions += 1
        return try JSONSerialization.data(withJSONObject: ["model": "test-native", "choices": [["finish_reason": "stop",
            "message": ["role": "assistant", "content": content]]]])
    }
}
