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
    private func planner(transport: any ComputerUseTextModelTransport = CopyOverflowTransport()) throws -> ComputerUseLocalTextGoalPlanner {
        try .init(connection: .init(baseURL: URL(string: "http://127.0.0.1:49123")!, bearerToken: "fictional-test-token", modelAlias: "test-native"),
                  transport: transport, contract: .fieldCopyV7)
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
        let transport = CopyOverflowTransport()
        let candidate = try planner(transport: transport)
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
