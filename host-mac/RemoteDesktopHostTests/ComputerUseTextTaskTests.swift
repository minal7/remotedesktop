import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextTaskTests: XCTestCase {
    private func field(_ id: String, _ value: String = "") -> ComputerUseTextField {
        ComputerUseTextField(label: id, snapshot: ComputerUseTextSnapshot(
            targetID: id, value: value, selection: NSRange(location: value.utf16.count, length: 0),
            isEditable: true, isSecure: false))
    }

    func testSamePayloadInTwoFieldsHasDistinctStepsAndVerifiesBoth() async throws {
        let fields = [field("origin"), field("destination")]
        let edits = fields.map { ComputerUseTextPlanEdit(targetID: $0.snapshot.targetID, mode: .replaceAll, text: "Paris") }
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Both Paris", fields: fields, edits: edits)
        XCTAssertNotEqual(contract.steps[0].id, contract.steps[1].id)
        var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var attempted = false
        var count = 0
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] }, apply: { edit, _ in
            XCTAssertTrue(attempted, "Attempt must be persisted before effect")
            count += 1
            state[edit.targetID] = self.field(edit.targetID, edit.text).snapshot
        }, persist: { journal in attempted = journal.statuses.contains(.attempted) }, mayAct: { true })
        try await task.run()
        try await task.run()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(task.journal.statuses, [.verified, .verified])
    }

    func testResumeReconcilesDeliveredEditWithoutDuplicatingIt() async throws {
        let fields = [field("origin"), field("destination")]
        let edits = fields.map { ComputerUseTextPlanEdit(targetID: $0.snapshot.targetID, mode: .append, text: "Paris") }
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Both Paris", fields: fields, edits: edits)
        var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var count = 0
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] }, apply: { edit, _ in
            count += 1
            state[edit.targetID] = self.field(edit.targetID, edit.text).snapshot
            if count == 1 { throw CancellationError() }
        }, persist: { _ in }, mayAct: { true })
        do { try await task.run(); XCTFail("Expected interruption") } catch is CancellationError {}
        XCTAssertEqual(task.journal.statuses, [.attempted, .planned])
        try await task.run()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(task.journal.statuses, [.verified, .verified])
    }

    func testPartialDeliveryIsUncertainAndNeverRetried() async throws {
        let initial = field("origin")
        var current = initial.snapshot
        var count = 0
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Paris", fields: [initial],
            edits: [ComputerUseTextPlanEdit(targetID: "origin", mode: .append, text: "Paris")])
        let task = try ComputerUseTextTask(contract: contract, read: { _ in current }, apply: { _, _ in
            count += 1
            current = self.field("origin", "Par").snapshot
            throw ComputerUseTextEditError.deliveryUncertain
        }, persist: { _ in }, mayAct: { true })
        do { try await task.run(); XCTFail("Expected uncertainty") } catch {}
        do { try await task.run(); XCTFail("Expected uncertainty") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(count, 1)
    }

    func testChangedEarlierFieldPreventsNextEffectAndFalseCompletion() async throws {
        let fields = [field("origin"), field("destination")]
        var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Both Paris", fields: fields,
            edits: fields.map { ComputerUseTextPlanEdit(targetID: $0.snapshot.targetID, mode: .replaceAll, text: "Paris") })
        var count = 0
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] }, apply: { edit, _ in
            count += 1
            state[edit.targetID] = self.field(edit.targetID, edit.text).snapshot
        }, persist: { _ in }, mayAct: { true })
        do {
            try await task.run { _, _ in state["origin"] = self.field("origin", "changed").snapshot }
            XCTFail("Expected stale outcome")
        } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
        XCTAssertEqual(count, 1)
    }

    func testPersistenceFailurePreventsEffect() async throws {
        let initial = field("origin")
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Paris", fields: [initial],
            edits: [ComputerUseTextPlanEdit(targetID: "origin", mode: .replaceAll, text: "Paris")])
        let task = try ComputerUseTextTask(contract: contract, read: { _ in initial.snapshot },
            apply: { _, _ in XCTFail("Cannot act before durable attempt") },
            persist: { _ in throw ComputerUseTextTaskError.journalMismatch }, mayAct: { true })
        do { try await task.run(); XCTFail("Expected journal failure") } catch {}
    }

    func testOrderedEditsOnSameFieldUseTheirOwnPreconditions() async throws {
        let initial = field("origin", "old")
        var current = initial.snapshot
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Seattle / Tacoma", fields: [initial], edits: [
            ComputerUseTextPlanEdit(targetID: "origin", mode: .replaceAll, text: "Seattle"),
            ComputerUseTextPlanEdit(targetID: "origin", mode: .append, text: " / Tacoma")])
        let task = try ComputerUseTextTask(contract: contract, read: { _ in current }, apply: { edit, _ in
            current = self.field("origin", edit.mode == .append ? current.value + edit.text : edit.text).snapshot
        }, persist: { _ in }, mayAct: { true })
        try await task.run()
        XCTAssertEqual(current.value, "Seattle / Tacoma")
    }

    func testLiteralCatalogPreservesMultipleExactValuesAndRejectsInventedText() throws {
        let prompt = "Origin: \"  東京\n\". Destination: “e\u{301} 😀”."
        let catalog = try ComputerUseTextPayloadCatalog(prompt)
        XCTAssertEqual(catalog.payloads["p1"], "  東京\n")
        XCTAssertEqual(catalog.payloads["p2"], "e\u{301} 😀")
        XCTAssertFalse(catalog.projectedTask.contains("東京"))
        XCTAssertNil(catalog.resolve(reference: "p3", userText: "", originalTask: prompt))
        XCTAssertNil(catalog.resolve(reference: "", userText: "Boston", originalTask: prompt))
        XCTAssertNil(catalog.resolve(reference: "", userText: "é", originalTask: prompt))
    }
}
