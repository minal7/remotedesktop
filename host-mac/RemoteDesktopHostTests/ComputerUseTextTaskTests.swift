import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextTaskTests: XCTestCase {
    func testCopiedValuesFollowEarlierStepsAndKeepSourceProvenanceAcrossReplay() async throws {
        let fields = [field("origin", "private seed"), field("destination", "old")]
        let contract = try ComputerUseTextTaskContract(taskID: "copy-chain", prompt: "Replace, copy and append", fields: fields,
            operations: [.enterText(.init(targetID: "origin", mode: .replaceAll, text: "  e\u{301} 😀  ")),
                         .copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll),
                         .copyField(sourceTargetID: "destination", targetID: "origin", mode: .append)])
        XCTAssertEqual(contract.steps.map(\.payload), Array(repeating: "  e\u{301} 😀  ", count: 3))
        XCTAssertEqual(contract.steps.map { $0.copySource?.targetID }, [nil, "origin", "destination"])
        XCTAssertEqual(contract.finalValues["origin"], "  e\u{301} 😀    e\u{301} 😀  ")
        var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var effects = 0
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] }, apply: { edit, current in
            effects += 1
            state[edit.targetID] = self.field(edit.targetID, edit.mode == .append ? current.value + edit.text : edit.text).snapshot
        }, persist: { journal in
            let encoded = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
            XCTAssertFalse(encoded.contains("private seed")); XCTAssertFalse(encoded.contains("😀"))
        }, mayAct: { true })
        try await task.run(); try await task.run()
        XCTAssertEqual(effects, 3); XCTAssertEqual(task.journal.statuses, [.verified, .verified, .verified])
    }

    func testCopySourceIdentityAndPayloadOriginCannotBeSubstitutedInRecovery() throws {
        let fields = [field("origin", "same"), field("other", "same"), field("destination")]
        func contract(_ source: String) throws -> ComputerUseTextTaskContract {
            try .init(taskID: "copy-identity", prompt: "Copy the chosen source", fields: fields,
                      operations: [.copyField(sourceTargetID: source, targetID: "destination", mode: .replaceAll)])
        }
        let first = try contract("origin"), second = try contract("other")
        let literal = try ComputerUseTextTaskContract(taskID: "copy-identity", prompt: "Copy the chosen source", fields: fields,
            edits: [.init(targetID: "destination", mode: .replaceAll, text: "same")])
        XCTAssertEqual(first.steps[0].after, second.steps[0].after)
        XCTAssertNotEqual(first.contractDigest, second.contractDigest)
        XCTAssertNotEqual(first.steps[0].id, literal.steps[0].id)
        let journal = ComputerUseTextStepJournal(taskID: first.taskID, promptDigest: first.promptDigest,
            contractDigest: first.contractDigest, stepIDs: first.steps.map(\.id), statuses: [.verified])
        XCTAssertThrowsError(try ComputerUseTextTask(contract: second, recovered: journal, read: { _ in nil },
            apply: { _, _ in XCTFail("Wrong source cannot acquire recovery authority") }, persist: { _ in }, mayAct: { true }))
    }

    func testChangedCopySourceCannotReachEffectAndSourceMutationDuringInputIsUncertain() async throws {
        for mutateDuringInput in [false, true] {
            let fields = [field("origin", "private source"), field("destination")]
            let contract = try ComputerUseTextTaskContract(taskID: "copy-race", prompt: "Copy Origin to Destination", fields: fields,
                operations: [.copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll)])
            var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
            var effects = 0
            let task = try ComputerUseTextTask(contract: contract, read: { state[$0] }, apply: { edit, _ in
                effects += 1; state[edit.targetID] = self.field(edit.targetID, edit.text).snapshot
                state["origin"] = self.field("origin", "changed during input").snapshot
            }, persist: { journal in
                if !mutateDuringInput && journal.statuses.contains(.attempted) {
                    state["origin"] = self.field("origin", "changed before dispatch").snapshot
                }
            }, mayAct: { true })
            do { try await task.run(); XCTFail("A changed copy source cannot produce successful completion") }
            catch {
                if mutateDuringInput { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
                else { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
            }
            do { try await task.run(); XCTFail("Changed source cannot authorize replay") } catch {}
            XCTAssertEqual(effects, mutateDuringInput ? 1 : 0)
        }
    }

    func testCancellationDuringFinalCopySourceReadPreventsInput() async throws {
        let fields = [field("origin", "private source"), field("destination")]
        let contract = try ComputerUseTextTaskContract(taskID: "copy-cancel", prompt: "Copy Origin to Destination", fields: fields,
            operations: [.copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll)])
        let state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var attempted = false, effects = 0
        var suspended: CheckedContinuation<ComputerUseTextSnapshot?, Never>?
        let task = try ComputerUseTextTask(contract: contract, read: { id in
            if attempted && id == "origin" { return await withCheckedContinuation { suspended = $0 } }
            return state[id]
        }, apply: { _, _ in effects += 1 }, persist: { attempted = $0.statuses.contains(.attempted) }, mayAct: { true })
        let running = Task { try await task.run() }
        while suspended == nil { await Task.yield() }
        running.cancel(); suspended?.resume(returning: state["origin"])
        do { try await running.value; XCTFail("Cancelled source read cannot dispatch input") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects, 0)
    }

    func testCopyPreflightRejectsMissingProtectedAndOversizedSourcesAndRetainsSelfCopy() throws {
        let target = field("destination", "x")
        let protected = ComputerUseTextField(label: "secret", snapshot: .init(targetID: "origin", value: "secret",
            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: true))
        for fields in [[target], [protected, target], [field("origin", String(repeating: "x", count: 65_537)), target]] {
            XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "invalid-copy", prompt: "Copy field", fields: fields,
                operations: [.copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll)]))
        }
        let selfCopy = try ComputerUseTextTaskContract(taskID: "self-copy", prompt: "Append the field to itself", fields: [target],
            operations: [.copyField(sourceTargetID: "destination", targetID: "destination", mode: .append)])
        XCTAssertEqual(selfCopy.finalValues["destination"], "xx")
    }

    func testCompleteQuotedCommandsBindTargetAndValueRolesWithoutExtraEdits() throws {
        let fields = [field("origin"), field("destination")]
        let examples: [(String, [ComputerUseTextPlanEdit])] = [
            (#"Set "Destination" to "Berlin"."#, [.init(targetID: "destination", mode: .replaceAll, text: "Berlin")]),
            (#"Set "origin" to "Destination", and "destination" to "Origin"."#,
             [.init(targetID: "origin", mode: .replaceAll, text: "Destination"), .init(targetID: "destination", mode: .replaceAll, text: "Origin")]),
            (#"Please set "origin" to "Paris", then set "origin" to "Paris"."#,
             [.init(targetID: "origin", mode: .replaceAll, text: "Paris"), .init(targetID: "origin", mode: .replaceAll, text: "Paris")]),
            ("Set “origin” to “  東京\ne\u{301} 😀  ”.", [.init(targetID: "origin", mode: .replaceAll, text: "  東京\ne\u{301} 😀  ")]),
            (#"Set "origin" to ""."#, [.init(targetID: "origin", mode: .replaceAll, text: "")])]
        for (prompt, expected) in examples {
            let result = try ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: fields)
            guard case .edits(let edits, let unchanged) = result else { return XCTFail("Complete grammar did not compile") }
            XCTAssertEqual(edits, expected)
            XCTAssertEqual(Set(unchanged), Set(fields.map { $0.snapshot.targetID }).subtracting(expected.map(\.targetID)))
        }
    }

    func testQuotedCommandCompilerRejectsPartialGoalsAndClarifiesUnboundTargets() throws {
        let fields = [field("origin"), field("destination")]
        for prompt in [#"Set "origin" to "Paris", then submit"#, #"Do not set "origin" to "Paris""#,
                       #"Set "missing" to "Paris", then open Calendar"#, #"Maybe set "origin" to "Paris"?"#,
                       #"Set "origin" to "Paris" or "destination" to "Berlin""#,
                       #"Set [exact quoted payload p1] to "Paris". "origin""#,
                       #"Put "Origin" in Destination."#] {
            XCTAssertNil(try ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: fields), prompt)
        }
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Set "missing" to "Paris"."#, fields: fields), .clarification)
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Set "origin" to "Paris"."#,
            fields: fields + [field("ORIGIN")]), .clarification)
    }

    func testAsynchronousFinalReadCannotStartAnEditAfterCancellationOrTakeover() async throws {
        for cancelTask in [false, true] {
            let initial = field("origin")
            let contract = try ComputerUseTextTaskContract(taskID: "async-read", prompt: "Set Origin to Paris", fields: [initial],
                edits: [.init(targetID: "origin", mode: .replaceAll, text: "Paris")])
            var allowed = true
            var reads = 0
            var effects = 0
            var suspended: CheckedContinuation<ComputerUseTextSnapshot?, Never>?
            let task = try ComputerUseTextTask(contract: contract, read: { _ in
                reads += 1
                if reads == 2 { return await withCheckedContinuation { suspended = $0 } }
                return initial.snapshot
            }, apply: { _, _ in effects += 1 }, persist: { _ in }, mayAct: { allowed })
            let running = Task { try await task.run() }
            while suspended == nil { await Task.yield() }
            if cancelTask { running.cancel() } else { allowed = false }
            suspended?.resume(returning: initial.snapshot)
            do { try await running.value; XCTFail("A stale asynchronous read cannot authorize the next effect") }
            catch {
                if cancelTask { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
            }
            XCTAssertEqual(effects, 0)
        }
    }

    func testMissingSelectionCannotBecomeAnInventedCaretAfterEarlierEdit() throws {
        let initial = ComputerUseTextField(label: "Email", snapshot: .init(targetID: "email", value: "old@example.invalid",
            selection: NSRange(location: NSNotFound, length: 0), isEditable: true, isSecure: false))
        let replacement = ComputerUseTextPlanEdit(targetID: "email", mode: .replaceAll, text: "new@example.invalid")
        _ = try ComputerUseTextTaskContract(taskID: "replace", prompt: "Replace email", fields: [initial], edits: [replacement])
        XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "mixed", prompt: "Replace and insert", fields: [initial],
            edits: [replacement, .init(targetID: "email", mode: .insert, text: "missing-caret")]))
    }

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

    func testChangedFieldDuringJournalWriteCannotReachTextMutationAdapter() async throws {
        let initial = field("origin")
        var current = initial.snapshot
        let contract = try ComputerUseTextTaskContract(taskID: "t", prompt: "Paris", fields: [initial],
            edits: [ComputerUseTextPlanEdit(targetID: "origin", mode: .replaceAll, text: "Paris")])
        let task = try ComputerUseTextTask(contract: contract, read: { _ in current },
            apply: { _, _ in XCTFail("The field changed after preflight and before dispatch") },
            persist: { _ in current = self.field("origin", "changed externally").snapshot }, mayAct: { true })
        do { try await task.run(); XCTFail("The changed precondition must reject input") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
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
