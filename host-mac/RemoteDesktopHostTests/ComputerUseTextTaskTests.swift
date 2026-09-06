import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextTaskTests: XCTestCase {
    func testChoiceContractsResolveLabelsAndPreserveIdentityThroughCopiesAndRepetition() throws {
        func choiceField(_ id: String, selected: String, choices: [(String, String)]) -> ComputerUseTextField {
            .init(label: id, snapshot: .init(targetID: id, value: selected, selection: NSRange(location: NSNotFound, length: 0),
                isEditable: true, isSecure: false), choices: choices.map { .init(id: $0.0, label: $0.1, disabled: false, hidden: false) })
        }
        let fields = [choiceField("Cabin", selected: "o1", choices: [("o1", "Economy"), ("o2", "Premium")]),
                      field("Summary", "old"), choiceField("Return", selected: "", choices: [("o3", "Premium")])]
        let prompt = #"Choose "Premium" from "Cabin" twice, copy the "Cabin" field into "Summary", then copy the "Summary" field into "Return"."#
        let proposal = try XCTUnwrap(ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: fields))
        guard case .fieldOperations(let operations, let unchanged) = proposal else { return XCTFail("Compile the entire mixed sequence") }
        let contract = try ComputerUseTextTaskContract(taskID: "choices", prompt: prompt, fields: fields, operations: operations, unchangedTargetIDs: unchanged)
        XCTAssertEqual(contract.steps.map(\.payload), ["o2", "o2", "Premium", "o3"])
        XCTAssertEqual(contract.steps.map(\.isChoiceSelection), [true, true, false, true])
        XCTAssertEqual(contract.steps.map(\.after), ["o2", "o2", "Premium", "o3"])
        XCTAssertEqual(contract.steps[2].copySource?.value, "o2", "Copy authority remains the selected object, not its presentation")
        XCTAssertEqual(contract.steps[3].copySource?.value, "Premium")
        XCTAssertEqual(Set(contract.steps.map(\.id)).count, 4)
        XCTAssertEqual(contract.finalValues, ["Cabin": "o2", "Summary": "Premium", "Return": "o3"])
        let unsupported = try ComputerUseQuotedTextRequest.compile(prompt: #"Select "Premium" in "Summary"."#, fields: fields)
        XCTAssertEqual(unsupported, .unsupported, "Selecting an option cannot be interpreted as typing into an ordinary text field")
        XCTAssertNil(try ComputerUseQuotedTextRequest.compile(prompt: prompt + " Then book the ticket.", fields: fields),
            "A matched selection prefix cannot complete additional work")
    }

    func testChoiceContractsRejectAmbiguousUnavailableAndUncompiledValuesBeforeAnyStep() throws {
        let cases: [(ComputerUseTextEditMode, String, [ComputerUseTextField.Choice])] = [
            (.replaceAll, "Premium", [.init(id: "o1", label: "Premium", disabled: false, hidden: false), .init(id: "o2", label: "Premium", disabled: false, hidden: false)]),
            (.replaceAll, "Premium", [.init(id: "o1", label: "Premium", disabled: true, hidden: false)]),
            (.replaceAll, "Premium", [.init(id: "o1", label: "Premium", disabled: false, hidden: true)]),
            (.replaceAll, "o1", [.init(id: "o1", label: "Premium", disabled: false, hidden: false)]),
            (.append, "Premium", [.init(id: "o1", label: "Premium", disabled: false, hidden: false)]),
            (.insert, "Premium", [.init(id: "o1", label: "Premium", disabled: false, hidden: false)])
        ]
        for (mode, value, choices) in cases {
            let choice = ComputerUseTextField(label: "Cabin", snapshot: .init(targetID: "Cabin", value: "",
                selection: NSRange(location: NSNotFound, length: 0), isEditable: true, isSecure: false), choices: choices)
            XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "unavailable-choice", prompt: "Controlled whole plan",
                fields: [field("Origin", "old"), choice], edits: [.init(targetID: "Origin", mode: .replaceAll, text: "Paris"),
                    .init(targetID: "Cabin", mode: mode, text: value)])) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .valueNotRepresentable)
            }
        }
    }

    func testTextTaskAcquiresRunOwnershipBeforeReadingAndReacquiresItForReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComputerUseTextStepStore(directory: directory), other = try ComputerUseTextStepStore(directory: directory)
        let initial = field("destination", "old")
        let contract = try ComputerUseTextTaskContract(taskID: "lease-text", prompt: "Replace Destination with Paris",
            fields: [initial], edits: [.init(targetID: "destination", mode: .replaceAll, text: "Paris")])
        var current = initial.snapshot, reads = 0, effects = 0, acquisitions = 0
        var expected = try store.load(taskID: contract.taskID)
        let held = try other.acquireExecution(taskID: contract.taskID, expected: nil)
        defer { held.release() }
        let task = try ComputerUseTextTask(contract: contract, recovered: expected,
            read: { _ in reads += 1; return current }, apply: { edit, _ in
                effects += 1; current = self.field("destination", edit.text).snapshot
            }, persist: { journal in
                try store.save(journal, replacing: expected)
                expected = journal
            }, acquireExecutionLease: {
                acquisitions += 1
                return try store.acquireExecution(taskID: contract.taskID, expected: expected)
            }, mayAct: { true })
        do { try await task.run(); XCTFail("The previous run still owns this task") }
        catch { XCTAssertEqual(error as? ComputerUseTextStepStore.StoreError, .busy) }
        XCTAssertEqual(reads, 0); XCTAssertEqual(effects, 0)
        held.release()
        try await task.run()
        try await task.run()
        XCTAssertEqual(current.value, "Paris"); XCTAssertEqual(effects, 1); XCTAssertEqual(acquisitions, 3)
        let latest = try other.load(taskID: contract.taskID)
        let released = try other.acquireExecution(taskID: contract.taskID, expected: latest)
        released.release()
    }

    func testRetainedValuesChangingDuringDurableAttemptStopLiteralAndCopyAdapters() async throws {
        for earlierEdit in [false, true] {
            for copy in [false, true] {
                let fields = [field("source", "Paris"), field("retained", "keep"), field("destination", "old")]
                var operations: [ComputerUseTextGoalOperation] = earlierEdit
                    ? [.enterText(.init(targetID: "retained", mode: .replaceAll, text: "keep"))] : []
                operations.append(copy ? .copyField(sourceTargetID: "source", targetID: "destination", mode: .replaceAll)
                    : .enterText(.init(targetID: "destination", mode: .replaceAll, text: "Paris")))
                let contract = try ComputerUseTextTaskContract(taskID: "retained-race", prompt: "Keep the required field intact",
                    fields: fields, operations: operations, unchangedTargetIDs: earlierEdit ? [] : ["retained"])
                var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
                var effects: [String] = []
                let task = try ComputerUseTextTask(contract: contract, read: { state[$0] },
                    apply: { _, _ in XCTFail("Use the identified adapter") }, applyWithIdentity: { dispatch in
                        effects.append(dispatch.edit.targetID)
                        state[dispatch.edit.targetID] = self.field(dispatch.edit.targetID, dispatch.edit.text).snapshot
                    }, persist: { journal in
                        if journal.statuses.last == .attempted { state["retained"] = self.field("retained", "changed").snapshot }
                    }, mayAct: { true })
                do { try await task.run(); XCTFail("A retained value changed after preflight") }
                catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
                XCTAssertEqual(task.journal.statuses, earlierEdit ? [.verified, .uncertain] : [.uncertain])
                do { try await task.run(); XCTFail("The rejected attempt must not replay") } catch {}
                XCTAssertEqual(effects, earlierEdit ? ["retained"] : [])
                XCTAssertEqual(state["destination"]?.value, "old")
            }
        }
    }

    func testRetainedValueReadHonorsCancellationAndTakeoverBeforeDispatch() async throws {
        for cancellation in [false, true] {
            let fields = [field("source", "Paris"), field("destination", "old"), field("retained", "keep")]
            let state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
            let contract = try ComputerUseTextTaskContract(taskID: "retained-stop", prompt: "Copy and keep retained unchanged",
                fields: fields, operations: [.copyField(sourceTargetID: "source", targetID: "destination", mode: .replaceAll)],
                unchangedTargetIDs: ["retained"])
            var attempted = false, allowed = true, effects = 0, interrupted = false
            var running: Task<Void, Error>?
            defer { running = nil }
            let task = try ComputerUseTextTask(contract: contract, read: { id in
                if attempted && id == "retained" {
                    interrupted = true
                    if cancellation { running?.cancel() } else { allowed = false }
                }
                return state[id]
            }, apply: { _, _ in effects += 1 }, applyWithIdentity: { _ in effects += 1 },
                persist: { attempted = $0.statuses.contains(.attempted) }, mayAct: { allowed })
            running = Task { try await task.run() }
            do { try await running!.value; XCTFail("The final retained read cannot authorize input after interruption") }
            catch {
                if cancellation { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
            }
            XCTAssertTrue(interrupted); XCTAssertEqual(effects, 0)
            XCTAssertEqual(task.journal.statuses, [cancellation ? .attempted : .uncertain])
        }
    }

    func testIdentifiedDispatchCarriesLatestConstraintsWithoutFreezingUnrelatedFields() async throws {
        let fields = [field("origin", "old"), field("destination", "prior"), field("retained", "keep"), field("unrelated", "free")]
        let contract = try ComputerUseTextTaskContract(taskID: "retained-chain", prompt: "Replace, copy, and append twice; keep retained",
            fields: fields, operations: [.enterText(.init(targetID: "origin", mode: .replaceAll, text: "Paris")),
                .copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll),
                .enterText(.init(targetID: "origin", mode: .append, text: "!")),
                .enterText(.init(targetID: "origin", mode: .append, text: "!"))], unchangedTargetIDs: ["retained"])
        let required: [[String: String]] = [["retained": "keep"], ["retained": "keep", "origin": "Paris"],
            ["retained": "keep", "origin": "Paris", "destination": "Paris"],
            ["retained": "keep", "origin": "Paris!", "destination": "Paris"]]
        var state = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var operationIDs: [String] = []
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] },
            apply: { _, _ in XCTFail("Copies and literals must use the same dispatch") }, applyWithIdentity: { dispatch in
                let index = operationIDs.count
                XCTAssertEqual(dispatch.requiredValues, required[index])
                XCTAssertEqual(dispatch.copySource?.targetID, index == 1 ? "origin" : nil)
                XCTAssertEqual(dispatch.copySource?.value, index == 1 ? "Paris" : nil)
                operationIDs.append(dispatch.operationID)
                let value = dispatch.edit.mode == .append ? dispatch.expected.value + dispatch.edit.text : dispatch.edit.text
                state[dispatch.edit.targetID] = self.field(dispatch.edit.targetID, value).snapshot
                state["unrelated"] = self.field("unrelated", "freely changed").snapshot
            }, persist: { _ in }, mayAct: { true })
        try await task.run(); try await task.run()
        XCTAssertEqual(operationIDs.count, 4); XCTAssertEqual(Set(operationIDs).count, 4)
        XCTAssertEqual(state["origin"]?.value, "Paris!!"); XCTAssertEqual(state["destination"]?.value, "Paris")
        XCTAssertEqual(state["retained"]?.value, "keep"); XCTAssertEqual(state["unrelated"]?.value, "freely changed")
        XCTAssertEqual(task.journal.statuses, Array(repeating: .verified, count: 4))
    }

    func testMatchingLiteralValuesCannotProveUnsentOrReconstructedInput() async throws {
        for initial in ["same", "different before external change"] {
            let contract = try ComputerUseTextTaskContract(taskID: "literal-no-receipt", prompt: "Put same in Notes",
                fields: [field("notes", initial)], edits: [.init(targetID: "notes", mode: .replaceAll, text: "same")])
            for status in [ComputerUseTaskStepStatus.attempted, .uncertain, .verified] {
                let journal = ComputerUseTextStepJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
                    contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: [status])
                let task = try ComputerUseTextTask(contract: contract, recovered: journal,
                    read: { _ in self.field("notes", "same").snapshot },
                    apply: { _, _ in XCTFail("Unproven input must not be replayed") }, persist: { _ in }, mayAct: { true })
                do { try await task.run(); XCTFail("Current value alone cannot establish dispatch") }
                catch { XCTAssertEqual(error as? ComputerUseTextTaskError, status == .verified ? .incompleteOutcome : .uncertainEffect) }
            }
        }
    }

    func testRepeatedLiteralNoOpsRequireSeparateReceiptsAcrossLostCompletionAndReplay() async throws {
        let initial = field("notes", "same")
        let contract = try ComputerUseTextTaskContract(taskID: "literal-twice", prompt: "Put same in Notes twice", fields: [initial],
            edits: Array(repeating: .init(targetID: "notes", mode: .replaceAll, text: "same"), count: 2))
        var receipts = Set<String>(), calls: [String] = []
        func task(recovered: ComputerUseTextStepJournal? = nil) throws -> ComputerUseTextTask {
            try .init(contract: contract, recovered: recovered, read: { _ in initial.snapshot },
                apply: { _, _ in XCTFail("Use identified input") }, applyWithIdentity: { dispatch in
                    calls.append(dispatch.operationID); receipts.insert(dispatch.operationID)
                    if calls.count == 1 { throw CancellationError() }
                }, didDispatchInput: { receipts.contains($0) }, persist: { _ in }, mayAct: { true })
        }
        let first = try task()
        do { try await first.run(); XCTFail("The first completion was lost") } catch is CancellationError {}
        XCTAssertEqual(first.journal.statuses, [.attempted, .planned])
        let resumed = try task(recovered: first.journal)
        try await resumed.run(); try await resumed.run()
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(Set(calls).count, 2)
        XCTAssertEqual(resumed.journal.statuses, [.verified, .verified])
    }

    func testLostLiteralReceiptStopsLaterInputEvenWhenAllValuesMatch() async throws {
        let fields = [field("first", "same"), field("second", "same")]
        let contract = try ComputerUseTextTaskContract(taskID: "lost-receipt", prompt: "Put same in both fields", fields: fields,
            edits: fields.map { .init(targetID: $0.snapshot.targetID, mode: .replaceAll, text: "same") })
        var receipts = Set<String>(), calls = 0
        let task = try ComputerUseTextTask(contract: contract,
            read: { id in fields.first { $0.snapshot.targetID == id }?.snapshot },
            apply: { _, _ in XCTFail("Use identified input") }, applyWithIdentity: { dispatch in calls += 1; receipts.insert(dispatch.operationID) },
            didDispatchInput: { receipts.contains($0) }, persist: { journal in
                if journal.statuses == [.verified, .planned] { receipts.removeAll() }
            }, mayAct: { true })
        do { try await task.run(); XCTFail("A missing earlier receipt must stop the next effect") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
        XCTAssertEqual(calls, 1)
    }

    func testMatchingCopyValuesCannotProveAnUnsentAttemptOrARecoveredDispatch() async throws {
        let fields = [field("origin", "same"), field("destination", "same")]
        let contract = try ComputerUseTextTaskContract(taskID: "copy-noop", prompt: "Copy Origin to Destination", fields: fields,
            operations: [.copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll)])
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        for previouslyVerified in [false, true] {
            let journal = ComputerUseTextStepJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
                contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: [previouslyVerified ? .verified : .attempted])
            let recovered = try ComputerUseTextTask(contract: contract, recovered: journal, read: { values[$0] },
                apply: { _, _ in XCTFail("Unproven copied input cannot be retried") }, persist: { _ in }, mayAct: { true })
            do { try await recovered.run(); XCTFail("A matching value is not a dispatch receipt") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, previouslyVerified ? .incompleteOutcome : .uncertainEffect) }
        }
    }

    func testIndependentCopyReceiptReconcilesLostCompletionWithoutRepeatingNoOpInput() async throws {
        let fields = [field("origin", "same"), field("destination", "same")]
        let contract = try ComputerUseTextTaskContract(taskID: "copy-receipt", prompt: "Copy Origin to Destination", fields: fields,
            operations: [.copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll)])
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.snapshot.targetID, $0.snapshot) })
        var receipts = Set<String>(), calls = 0
        let first = try ComputerUseTextTask(contract: contract, read: { values[$0] }, apply: { _, _ in XCTFail("Use bound copy adapter") },
            applyWithIdentity: { dispatch in
                calls += 1; receipts.insert(dispatch.operationID); throw CancellationError()
            }, didDispatchInput: { receipts.contains($0) }, persist: { _ in }, mayAct: { true })
        do { try await first.run(); XCTFail("The callback was lost") } catch is CancellationError {}
        let recovered = try ComputerUseTextTask(contract: contract, recovered: first.journal, read: { values[$0] },
            apply: { _, _ in XCTFail("Receipt must prevent replay") }, didDispatchInput: { receipts.contains($0) },
            persist: { _ in }, mayAct: { true })
        try await recovered.run()
        XCTAssertEqual(calls, 1); XCTAssertEqual(recovered.journal.statuses, [.verified])
    }

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

    func testCompleteTextCommandsPreserveModesAndRepeatedTargetReferences() throws {
        let fields = [field("origin", "old"), field("destination", "prior"), field("retained", "keep")]
        let prompt = #"Set "origin" to "start", type "!" into the field named "destination", append "?" to the same field twice, then replace "origin" with the text "destination"."#
        let proposal = try ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: fields)
        guard case .edits(let edits, let unchanged) = proposal else { return XCTFail("The complete text sequence must compile") }
        XCTAssertEqual(edits, [
            .init(targetID: "origin", mode: .replaceAll, text: "start"),
            .init(targetID: "destination", mode: .insert, text: "!"),
            .init(targetID: "destination", mode: .append, text: "?"),
            .init(targetID: "destination", mode: .append, text: "?"),
            .init(targetID: "origin", mode: .replaceAll, text: "destination"),
        ])
        XCTAssertEqual(unchanged, ["retained"])
        let contract = try ComputerUseTextTaskContract(taskID: "ordered-input", prompt: prompt, fields: fields,
            edits: edits, unchangedTargetIDs: unchanged)
        XCTAssertEqual(contract.finalValues, ["origin": "destination", "destination": "prior!??", "retained": "keep"])
        XCTAssertEqual(Set(contract.steps.map(\.id)).count, 5)
        XCTAssertEqual(contract.steps[3].before, "prior!?")
    }

    func testCompleteCopyCommandsRetainPayloadOriginsAndUpdatedSourceDependencies() throws {
        let fields = [field("origin", "private old value"), field("destination", "prior"), field("retained", "keep")]
        let prompt = #"Set "origin" to "first", copy the "origin" field into "destination", then append the current value of "destination" to "origin" twice."#
        guard case .fieldOperations(let operations, let unchanged) = try ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: fields)
        else { return XCTFail("Literal input and observed copying must have distinct origins") }
        XCTAssertEqual(operations, [
            .enterText(.init(targetID: "origin", mode: .replaceAll, text: "first")),
            .copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll),
            .copyField(sourceTargetID: "destination", targetID: "origin", mode: .append),
            .copyField(sourceTargetID: "destination", targetID: "origin", mode: .append),
        ])
        let contract = try ComputerUseTextTaskContract(taskID: "ordered-copy", prompt: prompt, fields: fields,
            operations: operations, unchangedTargetIDs: unchanged)
        XCTAssertEqual(contract.steps[1].copySource?.value, "first")
        XCTAssertEqual(contract.finalValues, ["origin": "firstfirstfirst", "destination": "first", "retained": "keep"])

        let selfCopyPrompt = #"Append the current value of "origin" to "origin" twice."#
        guard case .fieldOperations(let copies, _) = try ComputerUseQuotedTextRequest.compile(prompt: selfCopyPrompt, fields: [field("origin", "x")])
        else { return XCTFail("Whole-value self-copy has ordered dependencies") }
        let selfCopy = try ComputerUseTextTaskContract(taskID: "self-copy-twice", prompt: selfCopyPrompt,
            fields: [field("origin", "x")], operations: copies)
        XCTAssertEqual(selfCopy.steps.map { $0.copySource?.value }, ["x", "xx"])
        XCTAssertEqual(selfCopy.finalValues["origin"], "xxxx")
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Copy the text "origin" into "destination"."#, fields: fields),
            .edits([.init(targetID: "destination", mode: .replaceAll, text: "origin")], unchangedTargetIDs: ["origin", "retained"]))
    }

    func testCompleteTextCompilerRejectsPartialPlansAndAmbiguousRolesBeforeBinding() throws {
        let fields = [field("origin"), field("destination")]
        for prompt in [
            #"Copy "origin" into "destination"."#,
            #"Copy the "missing" field into "destination", then submit."#,
            #"Type "hello" into "missing", then open Mail."#,
            #"Write a warm welcome in "origin"."#,
            #"Set "origin" to "hello" if the page is ready."#,
            #"Set "origin" to "hello" and leave "destination" unchanged."#,
            #"Append "!" to the same "destination"."#,
            #"Insert "hello" into "origin" or "destination"."#,
            #"Set [exact quoted payload p1] to "value". "origin""#,
            #"Set "origin" to "hello", then."#,
        ] {
            XCTAssertNil(try ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: fields), prompt)
        }
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Append "!" to the same field."#, fields: fields), .clarification)
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(
            prompt: #"Set "destination" to "x", then copy the "origin" field into the same field."#, fields: fields), .clarification,
            "A newly mentioned source makes the later same-field reference ambiguous")
        guard case .fieldOperations(let beforeSource, _) = try ComputerUseQuotedTextRequest.compile(
            prompt: #"Set "destination" to "x", then replace the same field with the current value of "origin"."#, fields: fields)
        else { return XCTFail("A target reference before the new source mention still binds the earlier target") }
        XCTAssertEqual(beforeSource.last, .copyField(sourceTargetID: "origin", targetID: "destination", mode: .replaceAll))
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Copy the "missing" field into "destination"."#, fields: fields), .clarification)
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Type "hello" into "origin"."#,
            fields: fields + [field("ORIGIN")]), .clarification)
        let protected = ComputerUseTextField(label: "origin", snapshot: .init(targetID: "secret", value: "private",
            selection: .init(location: 0, length: 0), isEditable: true, isSecure: true))
        XCTAssertEqual(try ComputerUseQuotedTextRequest.compile(prompt: #"Copy the "origin" field into "destination"."#,
            fields: [protected, field("destination")]), .clarification)
    }

    func testCompleteTextCompilerSupportsEightOperationsWithoutModelQuoteLimitsOrByteChanges() throws {
        let payload = "  東京\ne\u{301} 😀; then copy [exact quoted payload p1] C:\\  "
        let clause = "Set “origin” to “\(payload)”"
        let prompt = Array(repeating: clause, count: 8).joined(separator: ", then ") + "."
        XCTAssertThrowsError(try ComputerUseTextPayloadCatalog(prompt),
            "The deterministic compiler must not widen the model's separate quoted-payload budget")
        guard case .edits(let edits, _) = try ComputerUseQuotedTextRequest.compile(prompt: prompt, fields: [field("origin")])
        else { return XCTFail("Eight operations may contain sixteen independent quoted arguments") }
        XCTAssertEqual(edits.count, 8)
        XCTAssertTrue(edits.allSatisfy { $0.text.utf8.elementsEqual(payload.utf8) })
        let repeated = try ComputerUseQuotedTextRequest.compile(prompt: #"Set "origin" to "x" exactly eight times."#, fields: [field("origin")])
        guard case .edits(let repeatedEdits, _) = repeated else { return XCTFail("An explicit repetition count must preserve every operation") }
        XCTAssertEqual(repeatedEdits.count, 8)
        XCTAssertNil(try ComputerUseQuotedTextRequest.compile(prompt: Array(repeating: clause, count: 9).joined(separator: ", then "), fields: [field("origin")]))
        XCTAssertNil(try ComputerUseQuotedTextRequest.compile(prompt: #"Append "!" to "origin" nine times."#, fields: [field("origin")]))
        XCTAssertThrowsError(try ComputerUseQuotedTextRequest.compile(prompt: "Set \"origin\" to \"unfinished", fields: [field("origin")]))
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
        var receipts = Set<String>()
        let task = try ComputerUseTextTask(contract: contract, read: { state[$0] },
            apply: { _, _ in XCTFail("Lost completion requires an independent receipt") }, applyWithIdentity: { dispatch in
            count += 1
            state[dispatch.edit.targetID] = self.field(dispatch.edit.targetID, dispatch.edit.text).snapshot
            receipts.insert(dispatch.operationID)
            if count == 1 { throw CancellationError() }
        }, didDispatchInput: { receipts.contains($0) }, persist: { _ in }, mayAct: { true })
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
            XCTAssertNotEqual(contract.steps.map(\.id), alternative.steps.map(\.id),
                "Each input identity must also bind its retained value requirements")
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
