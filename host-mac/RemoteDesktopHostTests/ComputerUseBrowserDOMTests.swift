import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserDOMTests: XCTestCase {
    func testNativeClarificationExpiryRejectsAnswersAndReleasesTheRetainedTargetWithoutAnotherRequest() async throws {
        let fixture = try await DOMFixture(body: "<label>Origin<input value='old'></label><label>Destination<input value='keep'></label>")
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000)
        let planner = DOMClarificationFixturePlanner()
        let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory, now: { now })
        _ = try await executor.execute(taskID: "q1", prompt: "Put \"blue\" in a field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "q1"))
        XCTAssertEqual(pending.expiresAt, Date(timeIntervalSince1970: 1_600))
        let answer = try pending.goal.answering(pending.question, with: "Destination")
        now = pending.expiresAt
        do { _ = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: answer, progress: { _ in }); XCTFail("An expired goal cannot run") }
        catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        XCTAssertNil(try executor.clarification(taskID: "q1")); XCTAssertEqual(planner.goals.count, 1)
        weak var retainedTarget: ComputerUseBrowserTextTarget?
        let timed = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: DOMClarificationFixturePlanner(), browserTargetProvider: { taskID in
                let target = ComputerUseBrowserTextTarget(browser: fixture.browser,
                    document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
                retainedTarget = target
                return target
            }, clarificationLifetime: 0.05)
        _ = try await timed.execute(taskID: "timed", prompt: "Put \"blue\" in a field.", progress: { _ in })
        XCTAssertNotNil(retainedTarget)
        // Observe object lifetime without querying the executor: expiration
        // must release private retention even when no next request arrives.
        try await fixture.wait { retainedTarget == nil }
        XCTAssertNil(try timed.clarification(taskID: "timed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNativeClarificationExecutesTheRetainedLongGoalWithFreshValuesAndNoAnswerReplay() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="origin" value="old"></label><label>Destination<textarea id="destination">keep</textarea></label>
            <script>document.querySelector('#destination').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));
            fetch('/signal').then(() => { document.querySelector('#origin').value = 'fresh'; fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMClarificationFixturePlanner()
        let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
        let literal = "  e\u{301} 😀\n" + String(repeating: "x", count: 5_000) + "  "
        let prompt = "Put \"" + literal + "\" in a field."
        for _ in 0..<2 {
            let question = try await executor.execute(taskID: "q1", prompt: prompt, progress: { _ in })
            guard case .clarificationRequired = question else { return XCTFail("The unresolved goal needs a question") }
        }
        XCTAssertEqual(planner.goals.count, 1, "Replaying the question cannot ask the model again")
        let pending = try XCTUnwrap(executor.clarification(taskID: "q1"))
        XCTAssertTrue(pending.goal.userTurns[0].utf8.elementsEqual(prompt.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        let goal = try pending.goal.answering(pending.question, with: "Destination")
        for _ in 0..<2 {
            let result: ComputerUseExecutionResult
            do { result = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: goal, progress: { _ in }) }
            catch { return XCTFail("Retained long-goal continuation failed: \(error)") }
            guard case .completed = result else { return XCTFail("The exact retained goal should complete") }
        }
        try await fixture.wait { fixture.editedValues.count == 1 }
        XCTAssertTrue(fixture.editedValues[0].utf8.elementsEqual(literal.utf8))
        XCTAssertEqual(planner.goals, [pending.goal, goal]); XCTAssertEqual(planner.fieldValues.last, ["fresh", "keep"])
        XCTAssertNil(try executor.clarification(taskID: "q1")); XCTAssertNil(try executor.clarification(taskID: "a1"))
        do {
            _ = try await executor.execute(taskID: "a1", prompt: goal.taskIdentityText, progress: { _ in })
            XCTFail("A raw prompt cannot impersonate the retained continuation identity")
        } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        XCTAssertEqual(fixture.editedValues.count, 1)
    }

    func testNativeClarificationPreservesTwoQuestionsAndEachQuestionTaskIdentity() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label><label>Destination<textarea>keep</textarea></label>
            <script>document.querySelectorAll('input,textarea').forEach(e => e.addEventListener('input', () => fetch('/input-event')));</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMClarificationFixturePlanner(answersNeeded: 2)
        let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "q1", prompt: "Put an exact value in a field.", progress: { _ in })
        let first = try XCTUnwrap(executor.clarification(taskID: "q1"))
        let firstAnswer = try first.goal.answering(first.question, with: "Destination")
        for _ in 0..<2 {
            let result = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: firstAnswer, progress: { _ in })
            guard case .clarificationRequired = result else { return XCTFail("The value is still missing") }
        }
        let second = try XCTUnwrap(executor.clarification(taskID: "a1"))
        XCTAssertEqual(second.goal, firstAnswer); XCTAssertEqual(second.scope, first.scope)
        XCTAssertNil(try executor.clarification(taskID: "q1")); XCTAssertEqual(planner.goals.count, 2)
        let final = try second.goal.answering(second.question, with: "\"  ready\n\"")
        let result: ComputerUseExecutionResult
        do { result = try await executor.continueClarification(taskID: "a2", originatingTaskID: "a1", goal: final, progress: { _ in }) }
        catch { return XCTFail("Second-answer continuation failed: \(error)") }
        guard case .completed = result else { return XCTFail("Both answers should compile one complete goal") }
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        XCTAssertEqual(planner.goals.last, final); XCTAssertEqual(final.userTurns.count, 3)
        XCTAssertEqual(fixture.server.count("/input-event"), 1)
    }

    func testNativeClarificationDetectsSingleLineValueSanitizationWithoutReplayOrAnotherQuestion() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label><label>Destination<input id="destination" value="keep"></label>
            <script>document.querySelector('#destination').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMClarificationFixturePlanner()
        let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "q1", prompt: "Put \"blue\n\" in a field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "q1"))
        let answer = try pending.goal.answering(pending.question, with: "Destination")
        for _ in 0..<2 {
            do { _ = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: answer, progress: { _ in }); XCTFail("A sanitized value is not the requested result") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        }
        try await fixture.wait { fixture.editedValues.count == 1 }
        XCTAssertEqual(fixture.editedValues, ["blue"]); XCTAssertEqual(planner.goals.count, 2)
        XCTAssertNil(try executor.clarification(taskID: "q1")); XCTAssertNil(try executor.clarification(taskID: "a1"))
    }

    func testNativeClarificationRejectsRewrittenGoalsAndConsumesAChangedFormWithoutRediscovery() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label><label>Destination<input id="destination" value="keep"></label>
            <script>document.querySelector('#destination').addEventListener('input', () => fetch('/input-event'));
            fetch('/signal').then(() => { const e = document.querySelector('#destination'); e.replaceWith(e.cloneNode(true)); fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMClarificationFixturePlanner()
        let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "q1", prompt: "Put \"blue\" in a field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "q1"))
        let valid = try pending.goal.answering(pending.question, with: "Destination")
        let rewritten = try ComputerUseUnresolvedTextGoal(userRequest: "Put \"red\" in a field.").answering(pending.question, with: "Destination")
        for (origin, goal) in [("wrong-task", valid), ("q1", rewritten), ("q1", try pending.goal.answering("Forged question", with: "Destination"))] {
            do { _ = try await executor.continueClarification(taskID: "a1", originatingTaskID: origin, goal: goal, progress: { _ in }); XCTFail("An answer cannot rewrite the retained goal") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        }
        XCTAssertEqual(try executor.clarification(taskID: "q1"), pending)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { _ = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: valid, progress: { _ in }); XCTFail("A replacement form cannot inherit the goal") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertNil(try executor.clarification(taskID: "q1"))
        do { _ = try await executor.continueClarification(taskID: "a2", originatingTaskID: "q1", goal: valid, progress: { _ in }); XCTFail("A failed transfer cannot be rediscovered or replayed") }
        catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        XCTAssertEqual(planner.goals.count, 1); XCTAssertEqual(fixture.server.count("/input-event"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNativeClarificationCancellationDeclineAndTurnLimitLeaveNoPendingAuthorityOrEffects() async throws {
        for scenario in ["cancel", "decline", "limit", "new-request"] {
            let fixture = try await DOMFixture(body: """
                <label>Origin<input value="old"></label><label>Destination<input value="keep"></label>
                <script>document.querySelectorAll('input').forEach(e => e.addEventListener('input', () => fetch('/input-event')));</script>
                """)
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMClarificationFixturePlanner(answersNeeded: scenario == "limit" ? 10 : 1, declinesAnswer: scenario == "decline")
            let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
            _ = try await executor.execute(taskID: "q1", prompt: "Put \"blue\" in a field.", progress: { _ in })
            var pending = try XCTUnwrap(executor.clarification(taskID: "q1"))
            if scenario == "cancel" || scenario == "new-request" {
                if scenario == "cancel" { executor.invalidateClarification(taskID: "q1") }
                else { _ = try await executor.execute(taskID: "new", prompt: "Put \"red\" in a field.", progress: { _ in }) }
                let answer = try pending.goal.answering(pending.question, with: "Destination")
                do { _ = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: answer, progress: { _ in }); XCTFail("Old authority must be gone") }
                catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
            } else {
                for index in 1...(scenario == "limit" ? 3 : 1) {
                    let answer = try pending.goal.answering(pending.question, with: "Destination")
                    let result = try await executor.continueClarification(taskID: "a\(index)", originatingTaskID: pending.taskID, goal: answer, progress: { _ in })
                    if scenario == "decline" || index == 3 {
                        guard case .unableToComplete = result else { return XCTFail("A terminal decline must not reopen routing or another question") }
                        XCTAssertNil(try executor.clarification(taskID: "a\(index)"))
                    } else { pending = try XCTUnwrap(executor.clarification(taskID: "a\(index)")) }
                }
            }
            XCTAssertNil(try executor.clarification(taskID: "q1")); XCTAssertEqual(fixture.server.count("/input-event"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    private func clarificationExecutor(fixture: DOMFixture, planner: DOMClarificationFixturePlanner, directory: URL,
                                       now: @escaping () -> Date = Date.init) -> ComputerUseNativeTextExecutor {
        ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, editOverride: { _, _ in XCTFail("A retained browser answer cannot use native AX input") },
            browserTargetProvider: { taskID in ComputerUseBrowserTextTarget(browser: fixture.browser,
                document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false) }, now: now)
    }

    func testClarificationTransferPreservesObjectsReadsFreshValuesAndRetiresOldTaskAuthority() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="target" value="old"></label><label>Destination<input value="keep"></label>
            <script>document.querySelector('#target').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));
            fetch('/signal').then(() => { document.querySelector('#target').value = 'changed while answering'; fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let before = try await fixture.target.fields(), scope = try fixture.target.clarificationScope()
        let priorOperation = ComputerUseTaskContract.digest(["completed-before-clarification"])
        try await fixture.target.apply(.init(targetID: before[0].snapshot.targetID, mode: .replaceAll, text: "old"),
            expected: before[0].snapshot, operationID: priorOperation)
        try await fixture.wait { fixture.editedValues == ["old"] }
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        let next = try await fixture.target.continuingForClarification(taskID: "answer")
        XCTAssertEqual(next.fields.map { $0.snapshot.targetID }, before.map { $0.snapshot.targetID })
        XCTAssertEqual(next.fields[0].snapshot.value, "changed while answering")
        XCTAssertEqual(try next.target.clarificationScope(), scope)
        XCTAssertEqual(fixture.editedValues, ["old"], "Refreshing a clarification must not dispatch input")
        let receiptSurvived = try await next.target.didDispatchInput(operationID: priorOperation)
        XCTAssertTrue(receiptSurvived, "Re-observation must not erase completed input receipts")
        do { _ = try await fixture.target.read(targetID: before[0].snapshot.targetID); XCTFail("The old task must lose authority") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        let current = next.fields[0].snapshot
        try await next.target.apply(.init(targetID: current.targetID, mode: .replaceAll, text: "answer applied"),
            expected: current, operationID: ComputerUseTaskContract.digest(["clarification-answer"]))
        try await fixture.wait { fixture.editedValues == ["old", "answer applied"] }
        XCTAssertEqual(fixture.editedValues.count, 2)
    }

    func testClarificationTransferRejectsChangedFieldMembershipIdentityLabelsAndDocumentRoot() async throws {
        let changes = [
            "field.replaceWith(field.cloneNode(true));",
            "field.remove(); document.querySelector('#first').appendChild(field);",
            "document.querySelector('#first').firstChild.textContent = 'Renamed';",
            "document.body.appendChild(document.querySelector('#first').cloneNode(true));",
            "field.style.display = 'none';",
            "document.documentElement.replaceWith(document.documentElement.cloneNode(true));"
        ]
        for change in changes {
            let fixture = try await DOMFixture(body: """
                <label id="first">Origin<input id="target" value="old"></label><label>Destination<input value="keep"></label>
                <script>document.querySelector('#target').addEventListener('input', () => fetch('/input-event'));
                fetch('/signal').then(() => { const field = document.querySelector('#target'); \(change) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            _ = try await fixture.target.fields()
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { _ = try await fixture.target.continuingForClarification(taskID: "answer"); XCTFail("A changed form cannot inherit the pending goal: \(change)") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(fixture.server.count("/input-event"), 0)
        }
    }

    func testLiteralNoOpReceiptReconcilesCancelledInputAndRequiresEveryRepeatedEvent() async throws {
        var running: Task<Void, Error>?
        let fixture = try await DOMFixture(body: """
            <label>Notes<input value="same"></label>
            <script>document.querySelector('input').addEventListener('input', () => {
              fetch('/input-event'); const until = performance.now() + 150; while (performance.now() < until) {}
            });</script>
            """, domScriptDidDispatch: { if $0 == .edit { running?.cancel() } })
        defer { fixture.close() }
        let fields = try await fixture.target.fields(), field = try XCTUnwrap(fields.first)
        let contract = try ComputerUseTextTaskContract(taskID: "literal-noop", prompt: "Put same in Notes twice", fields: fields,
            edits: Array(repeating: .init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "same"), count: 2))
        func task(recovered: ComputerUseTextStepJournal? = nil) throws -> ComputerUseTextTask {
            try .init(contract: contract, recovered: recovered, read: { try await fixture.target.read(targetID: $0) },
                apply: { _, _ in XCTFail("Use identified DOM input") },
                applyWithIdentity: { try await fixture.target.apply($0, expected: $1, operationID: $2) },
                didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) },
                persist: { _ in }, mayAct: { true })
        }
        let unsent = ComputerUseTextStepJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
            contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: [.attempted, .planned])
        do { try await task(recovered: unsent).run(); XCTFail("Matching values cannot prove the unsent first operation") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(fixture.server.count("/input-event"), 0)
        let first = try task()
        running = Task { try await first.run() }
        do { try await running!.value; XCTFail("The first callback was cancelled") } catch is CancellationError {}
        running = nil
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do { _ = try await fixture.target.read(targetID: field.snapshot.targetID); break }
            catch ComputerUseBrowserError.busy {
                guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let resumed = try task(recovered: first.journal)
        try await resumed.run(); try await resumed.run()
        try await fixture.wait { fixture.server.count("/input-event") == 2 }
        XCTAssertEqual(resumed.journal.statuses, [.verified, .verified])
        let reconstructed = try task(recovered: resumed.journal)
        try await reconstructed.run()
        XCTAssertEqual(fixture.server.count("/input-event"), 2, "Both explicit operations ran once; recovery and replay added none")
    }

    func testBrowserCopyReceiptDistinguishesUnsentNoOpFromCancelledDeliveredInput() async throws {
        var running: Task<Void, Error>?
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="same"></label><label>Destination<input id="target" value="same"></label>
            <script>document.querySelector('#target').addEventListener('input', () => {
              fetch('/input-event'); const until = performance.now() + 150; while (performance.now() < until) {}
            });</script>
            """, domScriptDidDispatch: { if $0 == .edit { running?.cancel() } })
        defer { fixture.close() }
        let fields = try await fixture.target.fields()
        let contract = try ComputerUseTextTaskContract(taskID: "copy-noop", prompt: "Copy Origin to Destination", fields: fields,
            operations: [.copyField(sourceTargetID: fields[0].snapshot.targetID, targetID: fields[1].snapshot.targetID, mode: .replaceAll)],
            unchangedTargetIDs: [fields[0].snapshot.targetID])
        func task(recovered: ComputerUseTextStepJournal? = nil) throws -> ComputerUseTextTask {
            try .init(contract: contract, recovered: recovered, read: { try await fixture.target.read(targetID: $0) },
                apply: { _, _ in XCTFail("Copy needs its bound source") },
                applyCopyWithIdentity: { edit, before, source, operationID in
                    try await fixture.target.apply(edit, expected: before, operationID: operationID, copySource: source)
                }, didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) },
                persist: { _ in }, mayAct: { true })
        }
        let unsent = ComputerUseTextStepJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
            contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: [.attempted])
        do { try await task(recovered: unsent).run(); XCTFail("The matching initial value cannot prove dispatch") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(fixture.server.count("/input-event"), 0)
        let delivered = try task()
        running = Task { try await delivered.run() }
        do { try await running!.value; XCTFail("The dispatched call is cancelled before its callback") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do { _ = try await fixture.target.read(targetID: fields[1].snapshot.targetID); break }
            catch ComputerUseBrowserError.busy {
                guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await task(recovered: delivered.journal).run()
        XCTAssertEqual(fixture.server.count("/input-event"), 1, "Reconstruction uses the document receipt, not another input event")
    }

    func testCopyUsesBoundSourceBytesAndCannotSubstituteLiteralOrReplayOperation() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<textarea>  東京\ne\u{301} 😀  </textarea></label><label>Destination<textarea></textarea></label>
            <script>document.querySelectorAll('textarea')[1].addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));</script>
            """)
        defer { fixture.close() }
        let fields = try await fixture.target.fields(), source = fields[0].snapshot, target = fields[1].snapshot
        let operationID = ComputerUseTaskContract.digest(["copy-once"])
        do {
            try await fixture.target.apply(.init(targetID: target.targetID, mode: .replaceAll, text: "invented"),
                expected: target, operationID: operationID, copySource: source)
            XCTFail("Copy reference cannot authorize substituted literal bytes")
        } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        try await fixture.target.apply(.init(targetID: target.targetID, mode: .replaceAll, text: source.value),
            expected: target, operationID: operationID, copySource: source)
        let copied = try requireDOM(try await fixture.target.read(targetID: target.targetID))
        XCTAssertTrue(copied.value.utf8.elementsEqual(source.value.utf8))
        do {
            try await fixture.target.apply(.init(targetID: target.targetID, mode: .replaceAll, text: source.value),
                expected: copied, operationID: operationID, copySource: source)
            XCTFail("A copy operation ID cannot replay")
        } catch { XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain) }
        try await fixture.wait { fixture.editedValues.count == 1 }
        XCTAssertTrue(fixture.editedValues[0].utf8.elementsEqual(source.value.utf8))
    }

    func testChangedOrReplacedCopySourceRejectsBeforeDestinationInput() async throws {
        for change in ["source.value = 'changed';", "source.replaceWith(source.cloneNode(true));"] {
            let fixture = try await DOMFixture(body: """
                <label>Origin<input id="source" value="private source"></label><label>Destination<input id="target"></label>
                <script>document.querySelector('#target').addEventListener('input', () => fetch('/input-event'));
                fetch('/signal').then(() => { const source = document.querySelector('#source'); \(change) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let fields = try await fixture.target.fields(), source = fields[0].snapshot, target = fields[1].snapshot
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            do {
                try await fixture.target.apply(.init(targetID: target.targetID, mode: .replaceAll, text: source.value),
                    expected: target, operationID: ComputerUseTaskContract.digest(["stale-copy"]), copySource: source)
                XCTFail("A valid destination alone cannot authorize copying a stale source")
            } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
            let unchanged = try requireDOM(try await fixture.target.read(targetID: target.targetID))
            XCTAssertEqual(unchanged.value, ""); XCTAssertEqual(fixture.server.count("/input-event"), 0)
        }
    }

    func testNativeExecutorCopiesWithoutAXInputAndDetectsSourceMutationDuringPageInput() async throws {
        for mutatesSource in [false, true] {
            let mutation = mutatesSource ? "document.querySelector('#source').value = 'changed by page';" : ""
            let fixture = try await DOMFixture(body: """
                <label>Origin<input id="source" value="private source"></label><label>Destination<input id="target"></label>
                <script>document.querySelector('#target').addEventListener('input', e => {
                  \(mutation) fetch('/edited?value=' + encodeURIComponent(e.target.value));
                });</script>
                """)
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMCopyFixturePlanner()
            let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
                planner: planner, editOverride: { _, _ in XCTFail("DOM copy cannot use AX input") },
                browserTargetProvider: { taskID in
                    ComputerUseBrowserTextTarget(browser: fixture.browser, document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
                })
            for _ in 0..<2 {
                do {
                    let result = try await executor.execute(taskID: "copy", prompt: "Copy the current Origin into Destination", progress: { _ in })
                    if mutatesSource { XCTFail("A source changed during input cannot report completion") }
                    else if case .completed = result {} else { XCTFail("The copy should complete") }
                } catch {
                    if !mutatesSource { throw error }
                    XCTAssertTrue([ComputerUseTextTaskError.uncertainEffect, .incompleteOutcome].contains(error as? ComputerUseTextTaskError ?? .invalidPlan))
                }
            }
            try await fixture.wait { fixture.editedValues.count == 1 }
            XCTAssertEqual(fixture.editedValues, ["private source"])
            XCTAssertEqual(planner.calls, 1)
        }
    }

    func testQuotedTargetNameCannotBecomeAnIntermediateInputThroughTheProductionTextExecutor() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Destination<input></label>
            <script>document.querySelector('input').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMFixturePlanner()
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, editOverride: { _, _ in XCTFail("DOM request cannot reach AX input") },
            browserTargetProvider: { taskID in
                ComputerUseBrowserTextTarget(browser: fixture.browser, document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
            })
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "quoted", prompt: #"Set "Destination" to "Berlin"."#, progress: { _ in })
            guard case .completed = result else { return XCTFail("The complete quoted command should compile") }
        }
        try await fixture.wait { fixture.editedValues.count == 1 }
        XCTAssertEqual(fixture.editedValues, ["Berlin"], "Neither the field label nor a duplicate edit may be entered")
        XCTAssertEqual(planner.calls, 0, "A complete literal command needs no model interpretation")
    }

    func testIsolatedWorldReadsNativeValuesAndOmitsProtectedHiddenAndDisabledFields() async throws {
        let fixture = try await DOMFixture(body: """
            <label for="origin">Origin</label><input id="origin" value="Oslo">
            <input aria-label="Password" type="password" value="never expose this">
            <input aria-label="Code" autocomplete="one-time-code" value="123456">
            <input aria-label="Card" autocomplete="cc-number" value="4111111111111111">
            <input aria-label="Hidden" hidden value="hidden"><input aria-label="Locked" readonly value="locked">
            <input aria-label="Disabled" disabled value="disabled"><div style="opacity:0"><input aria-label="Invisible" value="invisible"></div>
            <fieldset disabled><input aria-label="Disabled by group" value="group private"></fieldset>
            <div id="shadow"></div><script>
            globalThis.__remoteDesktopTextV1 = {run: () => ({status:'ok',fields:[{label:'Forged'}]})};
            Object.defineProperty(HTMLInputElement.prototype, 'value', {get() {return 'forged';}, set(v) {}});
            const shadow = document.querySelector('#shadow').attachShadow({mode:'open'});
            shadow.innerHTML = '<label>Destination<input value="Bergen"></label>';
            </script>
            """)
        defer { fixture.close() }
        let fields = try await fixture.target.fields()
        XCTAssertEqual(fields.map(\.label), ["Origin", "Destination"])
        XCTAssertEqual(fields.map { $0.snapshot.value }, ["Oslo", "Bergen"])
        XCTAssertTrue(fields.allSatisfy { !$0.snapshot.isSecure && $0.snapshot.isEditable })
        XCTAssertNotEqual(fields[0].snapshot.targetID, fields[1].snapshot.targetID)
    }

    func testExactUnicodeReplaceInsertAppendAndDuplicateOperationAreIndependentlyObserved() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Notes<textarea>old</textarea></label>
            <script>document.querySelector('textarea').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));</script>
            """)
        defer { fixture.close() }
        let field = try requireDOM(try await fixture.target.fields().first)
        XCTAssertEqual(field.label, "Notes", "A textarea's private initial value must not become its model-visible label")
        let payloads: [(ComputerUseTextEditMode, String, String)] = [
            (.replaceAll, "  東京\ne\u{301} 😀  ", "  東京\ne\u{301} 😀  "),
            (.insert, "next", "  東京\ne\u{301} 😀  next"),
            (.append, "\nend ", "  東京\ne\u{301} 😀  next\nend ")]
        var current = field.snapshot
        for (index, entry) in payloads.enumerated() {
            let operation = ComputerUseTaskContract.digest(["edit", String(index)])
            let edit = ComputerUseTextPlanEdit(targetID: current.targetID, mode: entry.0, text: entry.1)
            try await fixture.target.apply(edit, expected: current, operationID: operation)
            let next = try requireDOM(try await fixture.target.read(targetID: current.targetID))
            XCTAssertTrue(next.value.utf8.elementsEqual(entry.2.utf8))
            XCTAssertEqual(next.selection, NSRange(location: entry.2.utf16.count, length: 0))
            do { try await fixture.target.apply(edit, expected: current, operationID: operation); XCTFail("The script must reject a repeated operation ID") }
            catch { XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain) }
            current = next
        }
        try await fixture.wait { fixture.editedValues.count == 3 }
        XCTAssertEqual(fixture.editedValues, payloads.map { $0.2 })
    }

    func testRemovedAndReinsertedSameObjectCannotReviveItsOldHandle() async throws {
        let fixture = try await DOMFixture(body: """
            <label for="origin">Origin</label><input id="origin" value="old">
            <script>fetch('/signal').then(() => {const e = document.querySelector('input'); e.remove(); document.body.append(e); fetch('/changed');});</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let field = try requireDOM(try await fixture.target.fields().first)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        XCTAssertTrue(fixture.browser.validate(fixture.document), "The URL/navigation token alone still matches")
        let stale = try await fixture.target.read(targetID: field.snapshot.targetID)
        XCTAssertNil(stale)
        do { try await fixture.target.apply(.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "wrong"),
            expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["stale"])); XCTFail("Removed handles cannot revive") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
    }

    func testIdenticalReplacementAndDocumentRootReplacementRejectOldTargets() async throws {
        for script in ["const e = document.querySelector('input'); e.replaceWith(e.cloneNode(true));",
                       "const replacement = document.documentElement.cloneNode(true); document.replaceChild(replacement, document.documentElement);"] {
            let fixture = try await DOMFixture(body: """
                <label for="origin">Origin</label><input id="origin" value="old">
                <script>fetch('/signal').then(() => {\(script) fetch('/changed');});</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let field = try requireDOM(try await fixture.target.fields().first)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            let stale = try await fixture.target.read(targetID: field.snapshot.targetID)
            XCTAssertNil(stale)
            do { try await fixture.target.apply(.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "wrong"),
                expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["stale"])); XCTFail("Matching HTML does not retain element authority") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        }
    }

    func testLabelOrFormDestinationChangePreventsTheEffect() async throws {
        for script in ["document.querySelector('label').firstChild.data = 'Another field';",
                       "document.querySelector('form').action = '/different-destination';"] {
            let fixture = try await DOMFixture(body: """
                <form action="/original"><label>Origin<input value="old"></label></form>
                <script>fetch('/signal').then(() => {\(script) fetch('/changed');});</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let field = try requireDOM(try await fixture.target.fields().first)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            let stale = try await fixture.target.read(targetID: field.snapshot.targetID)
            XCTAssertNil(stale)
            do { try await fixture.target.apply(.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "wrong"),
                expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["stale"])); XCTFail("Changed identity or destination must reject before mutation") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        }
    }

    func testDifferentBrowserAndNewTaskCannotUseAnEarlierTarget() async throws {
        let first = try await DOMFixture(body: "<label>Origin<input value='first'></label>")
        let second = try await DOMFixture(body: "<label>Origin<input value='second'></label>")
        defer { first.close(); second.close() }
        let field = try requireDOM(try await first.target.fields().first)
        _ = try await second.target.fields()
        do { try await second.target.apply(.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "wrong"),
            expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["wrong-context"])); XCTFail("One context cannot resolve another context's target") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        _ = try first.browser.acquireCurrentDocument(taskID: "new-task")
        do { _ = try await first.target.read(targetID: field.snapshot.targetID); XCTFail("A task handoff invalidates the previous owner") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
    }

    func testInputHandlerDivergenceStaysUncertainWithoutReplayThroughSharedTextTask() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label>
            <script>document.querySelector('input').addEventListener('input', e => { e.target.value = 'rejected'; fetch('/input-event'); });</script>
            """)
        defer { fixture.close() }
        let fields = try await fixture.target.fields()
        let field = try XCTUnwrap(fields.first)
        let contract = try ComputerUseTextTaskContract(taskID: "dom", prompt: "Set Origin to Paris", fields: fields,
            edits: [.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "Paris")])
        var durable: ComputerUseTextStepJournal?
        let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
            apply: { _, _ in XCTFail("DOM must receive the real step identity") },
            applyWithIdentity: { edit, expected, operation in
                XCTAssertEqual(durable?.statuses, [.attempted])
                try await fixture.target.apply(edit, expected: expected, operationID: operation)
            }, persist: { durable = $0 }, mayAct: { true })
        for _ in 0..<2 {
            do { try await task.run(); XCTFail("A DOM setter return cannot prove that the page accepted its value") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        }
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        XCTAssertEqual(durable?.statuses, [.uncertain])
        XCTAssertEqual(fixture.server.count("/input-event"), 1)
    }

    func testNativeExecutorUsesDOMFieldsRetainsItsPlanAndChecksUneditedFields() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label><label>Destination<input value="retained"></label>
            <script>document.querySelectorAll('input').forEach(e => e.addEventListener('input', () => fetch('/input-event')));</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMFixturePlanner()
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, editOverride: { _, _ in XCTFail("The native AX injector must not receive an owned browser target") },
            browserTargetProvider: { taskID in
                ComputerUseBrowserTextTarget(browser: fixture.browser, document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
            })
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "goal", prompt: "Set Origin to Paris and leave Destination unchanged", progress: { _ in })
            guard case .completed = result else { return XCTFail("The DOM form must use the existing verified text task") }
        }
        XCTAssertEqual(planner.calls, 1)
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        XCTAssertEqual(fixture.server.count("/input-event"), 1)
    }

    func testMissingLabelsAndTooManyFieldsCannotProduceAPartialObservation() async throws {
        for body in ["<label>Named<input></label><input>", String(repeating: "<label>Field<input></label>", count: 17)] {
            let fixture = try await DOMFixture(body: body)
            defer { fixture.close() }
            do { _ = try await fixture.target.fields(); XCTFail("An incomplete form must not appear complete to the planner") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .unsupportedDocument) }
        }
    }

    func testCancellationAndDeadlineKeepInFlightScriptOwnedUntilItsCallbackWithoutReplay() async throws {
        for cancellation in [true, false] {
            var allowed = true
            var running: Task<Void, Error>?
            defer { running = nil }
            let fixture = try await DOMFixture(body: """
                <label>Origin<input value="old"></label><script>
                document.querySelector('input').addEventListener('input', () => {
                  const until = performance.now() + 700; while (performance.now() < until) {}
                  fetch('/input-event');
                });</script>
                """, domTimeout: cancellation ? .seconds(5) : .milliseconds(100),
                domScriptDidDispatch: { command in
                    if cancellation && command == .edit { allowed = false; running?.cancel() }
                }, mayAct: { allowed })
            defer { fixture.close() }
            let fields = try await fixture.target.fields()
            let field = try XCTUnwrap(fields.first)
            let contract = try ComputerUseTextTaskContract(taskID: "interrupted", prompt: "Set Origin to Paris", fields: fields,
                edits: [.init(targetID: field.snapshot.targetID, mode: .replaceAll, text: "Paris")])
            let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
                apply: { _, _ in XCTFail("DOM needs the shared operation identity") },
                applyWithIdentity: { try await fixture.target.apply($0, expected: $1, operationID: $2) },
                didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) },
                persist: { _ in }, mayAct: { allowed })
            running = Task { try await task.run() }
            do { try await running?.value; XCTFail("An interrupted in-flight script cannot complete its task") }
            catch {
                if cancellation { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, .documentUnresponsive) }
            }
            XCTAssertEqual(task.journal.statuses, [cancellation ? .attempted : .uncertain])
            do { _ = try fixture.browser.acquireCurrentDocument(taskID: "competing"); XCTFail("A new owner cannot overtake the pending WebKit callback") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .busy) }
            allowed = true
            try await fixture.wait { fixture.server.count("/input-event") == 1 }
            let deadline = ContinuousClock.now + .seconds(5)
            while true {
                do { _ = try await fixture.target.read(targetID: field.snapshot.targetID); break }
                catch ComputerUseBrowserError.busy {
                    guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await task.run()
            XCTAssertEqual(task.journal.statuses, [.verified])
            XCTAssertEqual(fixture.server.count("/input-event"), 1, "Resume reconciles the late delivered edit instead of sending it again")
        }
    }

    func testInputSideEffectOnAnUneditedFieldPreventsWholeTaskCompletion() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="origin" value="old"></label><label>Destination<input id="destination" value="retained"></label>
            <script>document.querySelector('#origin').addEventListener('input', () => {
              document.querySelector('#destination').value = 'changed'; fetch('/input-event');
            });</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: DOMFixturePlanner(), browserTargetProvider: { taskID in
                ComputerUseBrowserTextTarget(browser: fixture.browser, document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
            })
        for _ in 0..<2 {
            do { _ = try await executor.execute(taskID: "goal", prompt: "Set Origin to Paris and leave Destination unchanged", progress: { _ in }); XCTFail("All unchanged-field constraints must hold") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
        }
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        XCTAssertEqual(fixture.server.count("/input-event"), 1)
    }
}

@MainActor
private final class DOMFixture {
    let server: OwnedBrowserHTTPFixture
    let browser: ComputerUseOwnedBrowser
    let document: ComputerUseBrowserDocument
    let target: ComputerUseBrowserTextTarget

    init(body: String, heldSignal: Bool = false, domTimeout: Duration = .seconds(5),
         domScriptDidDispatch: ((ComputerUseBrowserDOMCommand) -> Void)? = nil, mayAct: @escaping () -> Bool = { true }) async throws {
        server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: "<!doctype html><meta charset='utf-8'>" + body),
                                                     "/signal": .init(held: heldSignal)])
        let base = try await server.start()
        browser = ComputerUseOwnedBrowser(presentsWindow: false, domTimeout: domTimeout, domScriptDidDispatch: domScriptDidDispatch, mayAct: mayAct)
        do {
            try browser.claim(taskID: "fixture")
            document = try await browser.navigate(taskID: "fixture", operationID: "open", to: base.appendingPathComponent("form"))
            target = ComputerUseBrowserTextTarget(browser: browser, document: document, requiresFrontmost: false)
        } catch { browser.close(); server.stop(); throw error }
    }
    func close() { browser.close(); server.stop() }
    var editedValues: [String] {
        server.requestedPaths.filter { $0.hasPrefix("/edited?") }.compactMap {
            URLComponents(string: "http://localhost" + $0)?.queryItems?.first(where: { $0.name == "value" })?.value
        }
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class DOMFixturePlanner: ComputerUseTextGoalPlanning {
    var calls = 0
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let first = try XCTUnwrap(fields.first(where: { $0.label == "Origin" }))
        return .edits([.init(targetID: first.snapshot.targetID, mode: .replaceAll, text: "Paris")],
                      unchangedTargetIDs: fields.filter { $0.label != "Origin" }.map { $0.snapshot.targetID })
    }
}

@MainActor
private final class DOMClarificationFixturePlanner: ComputerUseTextGoalPlanning {
    let answersNeeded: Int
    let declinesAnswer: Bool
    var goals: [ComputerUseUnresolvedTextGoal] = []
    var fieldValues: [[String]] = []
    init(answersNeeded: Int = 1, declinesAnswer: Bool = false) { self.answersNeeded = answersNeeded; self.declinesAnswer = declinesAnswer }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        try await propose(goal: ComputerUseUnresolvedTextGoal(userRequest: prompt), fields: fields)
    }
    func propose(goal: ComputerUseUnresolvedTextGoal, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        goals.append(goal); fieldValues.append(fields.map { $0.snapshot.value })
        if goal.userTurns.count <= answersNeeded { return .clarification }
        if declinesAnswer { return .unsupported }
        let target = try XCTUnwrap(fields.first(where: { $0.label == "Destination" }))
        let catalog = try ComputerUseTextPayloadCatalog(goal: goal)
        let value = try XCTUnwrap(catalog.payloads["p1"])
        return .edits([.init(targetID: target.snapshot.targetID, mode: .replaceAll, text: value)],
            unchangedTargetIDs: fields.filter { $0.snapshot.targetID != target.snapshot.targetID }.map { $0.snapshot.targetID })
    }
}

@MainActor
private final class DOMCopyFixturePlanner: ComputerUseTextGoalPlanning {
    var calls = 0
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let source = try XCTUnwrap(fields.first(where: { $0.label == "Origin" }))
        let target = try XCTUnwrap(fields.first(where: { $0.label == "Destination" }))
        return .fieldOperations([.copyField(sourceTargetID: source.snapshot.targetID, targetID: target.snapshot.targetID, mode: .replaceAll)],
            unchangedTargetIDs: [source.snapshot.targetID])
    }
}

private func requireDOM<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
