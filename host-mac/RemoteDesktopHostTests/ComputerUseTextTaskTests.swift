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

    func testLiteralReferencesCannotAliasUnquotedUserTextOrFakeMarkers() throws {
        let prompt = "Set Origin to p1 and Destination to \"Boston\". Literal marker [exact quoted payload p2]."
        let catalog = try ComputerUseTextPayloadCatalog(prompt)
        XCTAssertNil(catalog.payloads["p1"])
        XCTAssertNil(catalog.payloads["p2"])
        XCTAssertEqual(catalog.payloads["p3"], "Boston")
        XCTAssertEqual(catalog.resolve(reference: "", userText: "p1", originalTask: prompt), "p1")
        XCTAssertTrue(catalog.projectedTask.contains("Destination to [exact quoted payload p3]"))
    }

    func testChangedUneditedConstraintPreventsFurtherInputAndCompletion() async throws {
        let fields = [field("origin"), field("destination", "keep")]
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Origin Paris; leave Destination unchanged",
            fields: fields, edits: [ComputerUseTextPlanEdit(targetID: "origin", mode: .replaceAll, text: "Paris")],
            unchangedTargetIDs: ["destination"])
        var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        state["destination"] = field("destination", "changed").snapshot
        var calls = 0
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] }, apply: { edit, _ in
            calls += 1
            state[edit.targetID] = self.field(edit.targetID, edit.text).snapshot
            state["destination"] = self.field("destination", "changed").snapshot
        }, persist: { _ in }, mayAct: { true })
        do { try await task.run(); XCTFail("Constraint changed before input") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
        XCTAssertEqual(calls, 0)
        state["destination"] = field("destination", "keep").snapshot
        do { try await task.run(); XCTFail("Constraint changed during input") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
        XCTAssertEqual(calls, 1)
    }

    func testRecoveryRejectsChangedPreconditionsOrDroppedConstraints() throws {
        let fields = [field("origin", "old"), field("destination", "keep")]
        let edits = [ComputerUseTextPlanEdit(targetID: "origin", mode: .replaceAll, text: "Paris")]
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "same request", fields: fields,
            edits: edits, unchangedTargetIDs: ["destination"])
        let original = try ComputerUseTextTask(contract: contract, read: { _ in nil },
            apply: { _, _ in XCTFail("No input during recovery validation") }, persist: { _ in }, mayAct: { true })
        let alternatives = [
            try ComputerUseTextTaskContract(taskID: "t", prompt: "same request", fields: fields, edits: edits),
            try ComputerUseTextTaskContract(taskID: "t", prompt: "same request",
                fields: [field("origin", "changed"), fields[1]], edits: edits, unchangedTargetIDs: ["destination"]),
            try ComputerUseTextTaskContract(taskID: "t", prompt: "same request",
                fields: [fields[0], field("destination", "different constraint")], edits: edits, unchangedTargetIDs: ["destination"])
        ]
        for alternative in alternatives {
            XCTAssertNotEqual(contract.contractDigest, alternative.contractDigest)
            XCTAssertThrowsError(try ComputerUseTextTask(contract: alternative, recovered: original.journal,
                read: { _ in nil }, apply: { _, _ in XCTFail("No input") }, persist: { _ in }, mayAct: { true })) {
                XCTAssertEqual($0 as? ComputerUseTextTaskError, .journalMismatch)
            }
        }
    }

    func testRecoveryRejectsImpossibleStatusOrder() throws {
        let fields = [field("origin"), field("destination")]
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Both Paris", fields: fields,
            edits: fields.map { ComputerUseTextPlanEdit(targetID: $0.snapshot.targetID, mode: .replaceAll, text: "Paris") })
        let journal = ComputerUseTextStepJournal(taskID: "t", promptDigest: contract.promptDigest,
            contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: [.planned, .verified])
        XCTAssertThrowsError(try ComputerUseTextTask(contract: contract, recovered: journal, read: { _ in nil },
            apply: { _, _ in XCTFail("No input") }, persist: { _ in }, mayAct: { true })) {
            XCTAssertEqual($0 as? ComputerUseTextTaskError, .journalMismatch)
        }
    }

    func testTakeoverDuringJournalWritePreventsInput() async throws {
        let initial = field("origin")
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Paris", fields: [initial],
            edits: [ComputerUseTextPlanEdit(targetID: "origin", mode: .replaceAll, text: "Paris")])
        var allowed = true
        let task = try ComputerUseTextTask(contract: contract, read: { _ in initial.snapshot },
            apply: { _, _ in XCTFail("Ownership was revoked after the initial preflight") },
            persist: { _ in allowed = false }, mayAct: { allowed })
        do { try await task.run(); XCTFail("Expected takeover") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
    }

    func testRequirementCoverageRejectsMissingNegationActionOrPayloadReference() {
        let task = "Do not send. Set Origin to [exact quoted payload p1], then open Calendar."
        XCTAssertTrue(ComputerUseTextRequirementCoverage.matches(sources: [
            "Do not send.", "Set Origin to [exact quoted payload p1],", "then open Calendar."], task: task))
        for altered in [
            "Do send. Set Origin to [exact quoted payload p1], then open Calendar.",
            "Do not send. Set Origin to [exact quoted payload p1].",
            "Do not send. Set Origin to [exact quoted payload p2], then open Calendar.",
            "Set Origin to [exact quoted payload p1], then open Calendar. Do not send."
        ] {
            XCTAssertFalse(ComputerUseTextRequirementCoverage.matches(sources: [altered], task: task))
        }
    }
}
