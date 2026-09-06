import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseFieldCopyPlanTests: XCTestCase {
    private var fields: [ComputerUseTextField] {
        ["Origin", "Destination"].enumerated().map { index, name in
            .init(label: name, snapshot: .init(targetID: "private-target-\(index)", value: "private hidden field value \(index)",
                selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))
        }
    }
    private func operation(_ destination: String, _ payload: [String: String], mode: String = "replaceAll") -> [String: Any] {
        ["fieldID": destination, "mode": mode, "payload": payload]
    }
    private func decode(_ prompt: String, _ operations: [[String: Any]], disposition: String = "supported",
                        targets: [ComputerUseTextField]? = nil) throws -> ComputerUseTextGoalProposal {
        let source = String(decoding: try JSONSerialization.data(withJSONObject: ["disposition": disposition, "operations": operations]), as: UTF8.self)
        return try ComputerUseFieldCopyPlan.decode(content: source, catalog: .init(prompt), fields: targets ?? fields)
    }
    private func planner(transport: any ComputerUseTextModelTransport = CopyOverflowTransport(),
                         contract: ComputerUseLocalTextGoalPlanner.Contract = .fieldCopyV7) throws -> ComputerUseLocalTextGoalPlanner {
        try .init(connection: .init(baseURL: URL(string: "http://127.0.0.1:49123")!, bearerToken: "fictional-test-token", modelAlias: "test-native"),
                  transport: transport, contract: contract)
    }

    func testCopyAndSuppliedPayloadsRemainDifferentTypesThroughOrderedCompilation() throws {
        let value = "  東京 e\u{301} 😀  "
        let prompt = "Set Origin to \"\(value)\", then copy Origin into Destination."
        let result = try decode(prompt, [operation("f1", ["kind": "suppliedText", "value": "p1"]),
                                        operation("f2", ["kind": "fieldValue", "fieldID": "f1"])])
        guard case .fieldOperations(let operations, let unchanged) = result else { return XCTFail("Expected typed field operations") }
        XCTAssertEqual(operations, [.enterText(.init(targetID: fields[0].snapshot.targetID, mode: .replaceAll, text: value)),
                                     .copyField(sourceTargetID: fields[0].snapshot.targetID, targetID: fields[1].snapshot.targetID, mode: .replaceAll)])
        let contract = try ComputerUseTextTaskContract(taskID: "copy", prompt: prompt, fields: fields, operations: operations, unchangedTargetIDs: unchanged)
        XCTAssertTrue(contract.steps[1].payload.utf8.elementsEqual(value.utf8))
        XCTAssertEqual(contract.steps[1].copySource?.targetID, fields[0].snapshot.targetID)
        XCTAssertEqual(contract.finalValues[fields[1].snapshot.targetID], value)
    }

    func testCopySchemaAndExactBudgetNeverExposeExistingValuesOrRegenerateLiterals() async throws {
        for contract in [ComputerUseLocalTextGoalPlanner.Contract.fieldCopyV7, .fieldOperationsV8, .fieldOperationsV9] {
        let transport = CopyOverflowTransport()
        let candidate = try planner(transport: transport, contract: contract)
        let prompt = #"Set Origin to "private supplied payload", then copy Origin to Destination."#
        let request = try candidate.makeRequest(catalog: .init(prompt), fields: fields)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        for secret in ["private supplied payload", "private hidden field value", "private-target-"] { XCTAssertFalse(body.contains(secret)) }
        XCTAssertTrue(body.contains(#""properties":{"kind":{"const":"fieldValue"},"fieldID":"#))
        XCTAssertTrue(body.contains(#""max_tokens":1024"#))
        do { _ = try await candidate.propose(prompt: prompt, fields: fields); XCTFail("Input overflow must stop before inference") }
        catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .contextLimit) }
        let count = await transport.completions
        XCTAssertEqual(count, 0)
        }
    }

    func testQuotedNameContextPreservesSyntaxWithoutReleasingOtherPayloadsOrCurrentValues() throws {
        let request = #"Set "Destination" to "private supplied text", then put "Origin" in Destination."#
        let catalog = try ComputerUseTextPayloadCatalog(request)
        let serialized = try ComputerUseLocalTextGoalPlanner.context(catalog: catalog, fields: fields,
            includeQuotedFieldMatches: true, preserveQuotedFieldNames: true)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any])
        XCTAssertEqual(context["task"] as? String,
            #"Set "Destination" to [exact quoted payload p2], then put "Origin" in Destination."#)
        XCTAssertEqual(context["literalPayloadIDs"] as? [String], ["p1", "p2", "p3"])
        XCTAssertFalse(serialized.contains("private supplied text"))
        XCTAssertFalse(serialized.contains("private hidden field value"))
        XCTAssertFalse(serialized.contains("private-target-"))
        XCTAssertEqual(catalog.payloads["p2"], "private supplied text")
        XCTAssertEqual(catalog.payloads["p3"], "Origin", "A visible label can still be a supplied payload")
        XCTAssertEqual(catalog.projectedTask,
            "Set [exact quoted payload p1] to [exact quoted payload p2], then put [exact quoted payload p3] in Destination.")
        let copied = try ComputerUseLocalTextGoalPlanner.context(catalog: .init(#"Copy the "Origin" field into the "Destination" field."#),
            fields: fields, includeQuotedFieldMatches: true, preserveQuotedFieldNames: true)
        let copyContext = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        XCTAssertEqual(copyContext["task"] as? String, #"Copy the "Origin" field into the "Destination" field."#)
    }

    func testQuotedNameCandidateChangesOnlyContextAndLeavesUnmatchedRequestsByteIdentical() throws {
        let before = try planner(contract: .fieldOperationsV8), after = try planner(contract: .fieldOperationsV9)
        for prompt in ["Copy Origin into Destination twice.", #"Put "private literal" in Destination."#] {
            XCTAssertEqual(try before.makeRequest(catalog: .init(prompt), fields: fields).httpBody,
                           try after.makeRequest(catalog: .init(prompt), fields: fields).httpBody)
        }
        let catalog = try ComputerUseTextPayloadCatalog(#"Type the literal word "Origin" in Destination."#)
        var left = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(before.makeRequest(catalog: catalog, fields: fields).httpBody)) as? [String: Any])
        var right = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(after.makeRequest(catalog: catalog, fields: fields).httpBody)) as? [String: Any])
        var leftMessages = try XCTUnwrap(left.removeValue(forKey: "messages") as? [[String: String]])
        var rightMessages = try XCTUnwrap(right.removeValue(forKey: "messages") as? [[String: String]])
        XCTAssertEqual(leftMessages.removeFirst(), rightMessages.removeFirst(), "Instructions must not change in this comparison")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: right, options: [.sortedKeys]), "Schema and sampling must stay fixed")
        XCTAssertEqual(leftMessages.count, 1); XCTAssertEqual(rightMessages.count, 1)
        XCTAssertNotEqual(leftMessages[0]["content"], rightMessages[0]["content"])
        let response = Data(#"{"model":"test-native","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\"disposition\":\"supported\",\"operations\":[{\"fieldID\":\"f2\",\"mode\":\"replaceAll\",\"payload\":{\"kind\":\"suppliedText\",\"value\":\"p1\"}}]}"}}]}"#.utf8)
        XCTAssertEqual(try before.decode(response, catalog: catalog, fields: fields),
                       try after.decode(response, catalog: catalog, fields: fields), "Execution binding stays unchanged")
    }

    func testUnifiedPlannerRetainsLiteralAndCopiedOriginsWhenTheirBytesWouldMatch() throws {
        let prompt = #"Put "Origin" in Destination, then copy Origin to Destination."#
        let literal = operation("f2", ["kind": "suppliedText", "value": "p1"])
        let copied = operation("f2", ["kind": "fieldValue", "fieldID": "f1"])
        let candidate = try planner(contract: .fieldOperationsV8)
        func response(_ operations: [[String: Any]]) throws -> Data {
            let content = String(decoding: try JSONSerialization.data(withJSONObject: ["disposition": "supported", "operations": operations]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["model": "test-native", "choices": [["finish_reason": "stop",
                "message": ["role": "assistant", "content": content]]]])
        }
        let source = ComputerUseTextField(label: "Origin", snapshot: .init(targetID: fields[0].snapshot.targetID,
            value: "Origin", selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))
        let targets = [source, fields[1]], catalog = try ComputerUseTextPayloadCatalog(prompt)
        let result = try candidate.decode(response([literal, copied]), catalog: catalog, fields: targets)
        guard case .fieldOperations(let operations, let unchanged) = result else { return XCTFail("Expected typed operations") }
        let contract = try ComputerUseTextTaskContract(taskID: "origins", prompt: prompt, fields: targets,
            operations: operations, unchangedTargetIDs: unchanged)
        XCTAssertEqual(contract.steps.map(\.payload), ["Origin", "Origin"])
        XCTAssertNil(contract.steps[0].copySource)
        XCTAssertEqual(contract.steps[1].copySource?.targetID, source.snapshot.targetID)
        let singleLiteral = try candidate.decode(response([literal]), catalog: .init(#"Type the literal word "Origin" in Destination."#), fields: targets)
        XCTAssertEqual(singleLiteral, .fieldOperations([.enterText(.init(targetID: fields[1].snapshot.targetID, mode: .replaceAll, text: "Origin"))],
            unchangedTargetIDs: [source.snapshot.targetID]))
        XCTAssertThrowsError(try planner().decode(response([literal]), catalog: catalog, fields: targets),
            "The historical fallback must still reject literal-only plans")
    }

    func testUnifiedPlannerRejectsUntaggedMixedAndUnownedLiteralPayloads() throws {
        let candidate = try planner(contract: .fieldOperationsV8)
        let catalog = try ComputerUseTextPayloadCatalog(#"Put "  é 東京 😀  " in Destination."#)
        func response(_ object: [String: Any], reason: String = "stop") throws -> Data {
            let content = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["model": "test-native", "choices": [["finish_reason": reason,
                "message": ["role": "assistant", "content": content]]]])
        }
        let valid: [String: Any] = ["disposition": "supported", "operations": [operation("f2", ["kind": "suppliedText", "value": "p1"])]]
        guard case .fieldOperations(let operations, _) = try candidate.decode(response(valid), catalog: catalog, fields: fields),
              case .enterText(let edit) = operations.first else { return XCTFail("Expected host-owned literal") }
        XCTAssertTrue(edit.text.utf8.elementsEqual("  e\u{301} 東京 😀  ".utf8))
        for object in [
            ["disposition": "supported", "edits": [["fieldID": "f2", "mode": "replaceAll", "value": "p1"]]],
            ["disposition": "supported", "operations": [operation("f2", ["kind": "suppliedText", "value": "invented"])]],
            ["disposition": "unsupported", "operations": [operation("f2", ["kind": "suppliedText", "value": "p1"])]],
            ["disposition": "supported", "operations": [operation("f2", ["kind": "fieldValue", "fieldID": "f1", "value": "p1"])]]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try candidate.decode(response(object), catalog: catalog, fields: fields))
        }
        XCTAssertThrowsError(try candidate.decode(response(valid, reason: "length"), catalog: catalog, fields: fields))
    }

    func testMalformedMixedInventedAndUnmentionedCopyReferencesCannotBecomeInput() throws {
        let prompt = "Copy Origin into Destination."
        for payload in [["kind": "fieldValue", "fieldID": "f1", "value": "invented"],
                        ["kind": "fieldValue", "fieldID": "f3"],
                        ["kind": "fieldValue", "fieldID": "private-target-0"],
                        ["kind": "suppliedText", "value": "f1"],
                        ["kind": "generatedText", "value": "hello"]] {
            XCTAssertThrowsError(try decode(prompt, [operation("f2", payload)]))
        }
        XCTAssertThrowsError(try decode("Copy City into Destination.", [operation("f2", ["kind": "fieldValue", "fieldID": "f1"])]))
        XCTAssertThrowsError(try decode("Copy Origin into City.", [operation("f2", ["kind": "fieldValue", "fieldID": "f1"])]))
        XCTAssertThrowsError(try decode("Put Paris in Origin and leave Destination alone.",
            [operation("f1", ["kind": "suppliedText", "value": "Paris"])]), "This fallback cannot reinterpret a declined goal as pure literal edits")
        XCTAssertThrowsError(try decode(prompt, [operation("f2", ["kind": "fieldValue", "fieldID": "f1"])], disposition: "unsupported"))
    }

    func testQuotedSourceLabelsAndAmbiguousSourcesHaveDistinctOutcomes() throws {
        let result = try decode(#"Copy the "Origin" field into the "Destination" field."#,
            [operation("f2", ["kind": "fieldValue", "fieldID": "f1"])])
        XCTAssertEqual(result, .fieldOperations([.copyField(sourceTargetID: fields[0].snapshot.targetID, targetID: fields[1].snapshot.targetID, mode: .replaceAll)],
            unchangedTargetIDs: [fields[0].snapshot.targetID]))
        let duplicated = fields + [.init(label: "origin", snapshot: .init(targetID: "third", value: "private third",
            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))]
        XCTAssertEqual(try decode("Copy Origin into Destination.", [operation("f2", ["kind": "fieldValue", "fieldID": "f1"])], targets: duplicated), .clarification)
        XCTAssertEqual(try decode("Copy City into Destination.", [], disposition: "clarification"), .clarification)
    }

    func testFallbackPreservesPrimaryEditsClarificationAndErrorsWithoutAnotherPlannerCall() async throws {
        for result in [ComputerUseTextGoalProposal.clarification, .edits([.init(targetID: "x", mode: .replaceAll, text: "exact")])] {
            let primary = CopyProposalFixture(result: result), secondary = CopyProposalFixture(result: .unsupported)
            let actual = try await ComputerUseFieldCopyFallbackPlanner(primary: primary, fieldCopy: secondary).propose(prompt: "task", fields: fields)
            XCTAssertEqual(actual, result); XCTAssertEqual(secondary.calls, 0)
        }
        let primary = CopyProposalFixture(result: .unsupported, fails: true), secondary = CopyProposalFixture(result: .unsupported)
        do { _ = try await ComputerUseFieldCopyFallbackPlanner(primary: primary, fieldCopy: secondary).propose(prompt: "task", fields: fields); XCTFail("A failed primary cannot fall through") }
        catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .invalidResponse) }
        XCTAssertEqual(secondary.calls, 0)
    }

    func testFallbackAcceptsOnlyAWholeCopyPlanOrADeclineAndHonorsCancellation() async throws {
        let copy = ComputerUseTextGoalProposal.fieldOperations([.copyField(sourceTargetID: "a", targetID: "b", mode: .replaceAll)])
        for result in [copy, .unsupported, .clarification] {
            let primary = CopyProposalFixture(result: .unsupported), secondary = CopyProposalFixture(result: result)
            let actual = try await ComputerUseFieldCopyFallbackPlanner(primary: primary, fieldCopy: secondary).propose(prompt: "task", fields: fields)
            XCTAssertEqual(actual, result); XCTAssertEqual(primary.calls, 1); XCTAssertEqual(secondary.calls, 1)
        }
        for result in [ComputerUseTextGoalProposal.edits([]), .fieldOperations([.enterText(.init(targetID: "a", mode: .replaceAll, text: "invented"))])] {
            do {
                _ = try await ComputerUseFieldCopyFallbackPlanner(primary: CopyProposalFixture(result: .unsupported), fieldCopy: CopyProposalFixture(result: result))
                    .propose(prompt: "task", fields: fields)
                XCTFail("A declined whole goal cannot become its literal prefix")
            } catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .invalidResponse) }
        }
        let primary = CopyProposalFixture(result: .unsupported, cancels: true), secondary = CopyProposalFixture(result: copy)
        let fallback = ComputerUseFieldCopyFallbackPlanner(primary: primary, fieldCopy: secondary), targets = fields
        let running = Task { try await fallback.propose(prompt: "task", fields: targets) }
        do { _ = try await running.value; XCTFail("Cancellation must stop capability fallback") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(secondary.calls, 0)
    }
}

private actor CopyOverflowTransport: ComputerUseTextModelTransport {
    private(set) var completions = 0
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { 3_009 }
    func complete(request: URLRequest) async throws -> Data { completions += 1; return Data() }
}

@MainActor
private final class CopyProposalFixture: ComputerUseTextGoalPlanning {
    let result: ComputerUseTextGoalProposal
    let fails: Bool
    let cancels: Bool
    var calls = 0
    init(result: ComputerUseTextGoalProposal, fails: Bool = false, cancels: Bool = false) {
        self.result = result; self.fails = fails; self.cancels = cancels
    }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        if fails { throw ComputerUseLocalTextPlanError.invalidResponse }
        if cancels { withUnsafeCurrentTask { $0?.cancel() } }
        return result
    }
}
