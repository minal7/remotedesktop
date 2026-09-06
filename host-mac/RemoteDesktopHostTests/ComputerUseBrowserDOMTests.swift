import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserDOMTests: XCTestCase {
    func testVisibleAuthenticationMetadataBlocksAllFormValuesIncludingEarlierFields() async throws {
        let controls = [
            #"<input type="password" value="private-password">"#,
            #"<input autocomplete="section-login one-time-code" value="123456">"#,
            #"<label>Enter your 6-digit verification code<input type="number" value="123456"></label>"#,
            #"<input aria-label="Password" aria-hidden="true" value="revealed-password">"#,
            #"<input id="otpCode" name="otp" value="123456">"#,
            #"<input placeholder="Authentication code" value="123456">"#,
            #"<input autocomplete="username" value="private-login-name">"#,
            #"<div role="textbox" aria-label="Verification code" contenteditable>123456</div>"#,
            #"<div id="auth-shadow"></div><script>document.querySelector('#auth-shadow').attachShadow({mode:'open'}).innerHTML = '<input aria-label="Recovery code" value="private-recovery">';</script>"#,
        ]
        for control in controls {
            let fixture = try await DOMFixture(body: "<label>Origin<input value='must-not-return'></label>" + control)
            defer { fixture.close() }
            do { _ = try await fixture.target.fieldsIfSupported(); XCTFail("Authentication must precede discovery, including fallback") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired, control) }
            XCTAssertTrue(fixture.editedValues.isEmpty)
        }
    }

    func testHiddenAuthenticationAndOrdinaryCodeOrPolicyLabelsDoNotBlockForms() async throws {
        let fixture = try await DOMFixture(body: """
            <input type="password" hidden value="hidden-secret">
            <input type="password" readonly value="saved-password">
            <fieldset disabled><input aria-label="Verification code" value="123456"></fieldset>
            <div style="display:none"><input autocomplete="one-time-code" value="123456"></div>
            <div style="opacity:0"><input aria-label="Verification code" value="123456"></div>
            <label>Airport code<input value="SFO"></label>
            <label>Password policy<textarea>Use a long password.</textarea></label>
            <label>Postal code<input value="94103"></label>
            """)
        defer { fixture.close() }
        let fields = try await fixture.target.fields()
        XCTAssertEqual(fields.map(\.label), ["Airport code", "Password policy", "Postal code"])
        XCTAssertEqual(fields.map { $0.snapshot.value }, ["SFO", "Use a long password.", "94103"])
    }

    func testAuthenticationAppearingAfterDiscoveryBlocksReadsAndDispatchWithoutConsumingReceipt() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="origin" value="old"></label>
            <script>
            document.addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));
            fetch('/signal').then(() => {
              const auth = document.createElement('input'); auth.type = 'password'; auth.value = 'private';
              document.body.append(auth); fetch('/auth-shown');
              fetch('/signal').then(() => { auth.remove(); fetch('/auth-cleared'); });
            });
            </script>
            """, heldSignal: true)
        defer { fixture.close() }
        let discovered = try await fixture.target.fields()
        let field = try XCTUnwrap(discovered.first).snapshot
        let edit = ComputerUseTextPlanEdit(targetID: field.targetID, mode: .replaceAll, text: "Paris")
        let operationID = ComputerUseTextTaskContract.digest("authentication-before-dispatch")
        let contract = try ComputerUseTextTaskContract(taskID: "authentication-fixture", prompt: "Set Origin to Paris",
            fields: [.init(label: "Origin", snapshot: field)], edits: [edit], unchangedTargetIDs: [])
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/auth-shown") == 1 && fixture.server.count("/signal") == 2 }
        let blocked: [() async throws -> Void] = [
            { _ = try await fixture.target.read(targetID: field.targetID) },
            { _ = try await fixture.target.reobserveRetainedFields() },
            { try await fixture.target.validateRepresentability(of: contract) },
            { try await fixture.target.apply(edit, expected: field, operationID: operationID) },
        ]
        for operation in blocked {
            do { try await operation(); XCTFail("A fresh authentication barrier must block every value/edit path") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        }
        let dispatched = try await fixture.target.didDispatchInput(operationID: operationID)
        XCTAssertFalse(dispatched)
        XCTAssertTrue(fixture.editedValues.isEmpty)
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/auth-cleared") == 1 }
        let after = try await fixture.target.read(targetID: field.targetID)
        XCTAssertEqual(after, field)
        // Direct adapter admission did not reserve an input identity. This is
        // not permission for a task journal to replay an uncertain attempt.
        try await fixture.target.apply(edit, expected: field, operationID: operationID)
        try await fixture.wait { fixture.editedValues.count == 1 }
        XCTAssertEqual(fixture.editedValues, ["Paris"])
    }

    func testAuthenticationAfterInputRetainsReceiptAndResumesRemainingNativeStepsOnce() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="origin" value="old"></label>
            <script>let count = 0; document.querySelector('#origin').addEventListener('input', e => {
              fetch('/edited?value=' + encodeURIComponent(e.target.value));
              if (++count !== 1) return;
              const auth = document.createElement('input'); auth.setAttribute('aria-label', 'Verification code');
              auth.value = '123456'; document.body.append(auth);
              fetch('/signal').then(() => { auth.remove(); fetch('/auth-cleared'); });
            });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMRepresentabilityFixturePlanner { fields in
            let field = try XCTUnwrap(fields.first).snapshot
            return .edits([.init(targetID: field.targetID, mode: .replaceAll, text: "Paris"),
                           .init(targetID: field.targetID, mode: .append, text: "!")], unchangedTargetIDs: [])
        }
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, browserTargetProvider: { taskID in
                ComputerUseBrowserTextTarget(browser: fixture.browser,
                    document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
            })
        let prompt = "Set Origin to Paris, then append !"
        do { _ = try await executor.execute(taskID: "auth-after-input", prompt: prompt, progress: { _ in }); XCTFail("Authentication blocks verification and the next input") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        try await fixture.wait { fixture.server.count("/signal") == 1 && fixture.editedValues.count == 1 }
        let paused = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "auth-after-input"))
        XCTAssertEqual(paused.statuses, [.uncertain, .planned])
        XCTAssertEqual(fixture.editedValues, ["Paris"])
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/auth-cleared") == 1 }
        let result = try await executor.execute(taskID: "auth-after-input", prompt: prompt, progress: { _ in })
        guard case .completed = result else { return XCTFail("Fresh values plus the original receipt must reconcile the first edit") }
        try await fixture.wait { fixture.editedValues.count == 2 }
        _ = try await executor.execute(taskID: "auth-after-input", prompt: prompt, progress: { _ in })
        XCTAssertEqual(fixture.editedValues, ["Paris", "Paris!"])
        XCTAssertEqual(planner.calls, 1)
    }

    func testAuthenticationDuringClarificationKeepsExactAnswerForExplicitResume() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label><label>Destination<input value="keep"></label>
            <script>
            document.addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));
            fetch('/signal').then(() => {
              const auth = document.createElement('input'); auth.autocomplete = 'one-time-code';
              auth.value = '123456'; document.body.append(auth); fetch('/auth-shown');
              fetch('/signal').then(() => { auth.remove(); fetch('/auth-cleared'); });
            });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMClarificationFixturePlanner()
        let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in a field.", progress: { _ in })
        let question = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try question.goal.answering(question.question, with: "Destination")
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/auth-shown") == 1 && fixture.server.count("/signal") == 2 }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Do not plan with authentication values") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertEqual(planner.goals.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/auth-cleared") == 1 }
        let result = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in })
        guard case .completed = result else { return XCTFail("The same retained answer must resume") }
        try await fixture.wait { fixture.editedValues.count == 1 }
        XCTAssertEqual(planner.goals.last, answer)
        XCTAssertEqual(planner.fieldValues.last, ["old", "keep"])
        XCTAssertEqual(fixture.editedValues, ["blue"])
    }

    func testRetainedFieldDriftAtDOMDispatchPreventsLiteralAndCopiedInputWithoutReplay() async throws {
        let cases: [(earlierEdit: Bool, copy: Bool, change: String)] = [
            (false, false, "field.value = 'changed';"),
            (true, false, "field.value = 'changed';"),
            (false, true, "field.replaceWith(field.cloneNode(true));"),
            (true, true, "field.setAttribute('aria-label', 'Different field');"),
            (false, true, "field.value = 'cafe\\u0301';")
        ]
        for scenario in cases {
            let fixture = try await DOMFixture(body: """
                <label>Source<input id="source" value="Paris"></label>
                <label>Retained<input id="retained" value="café"></label>
                <label>Destination<textarea id="target">old</textarea></label>
                <script>document.addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.id + ':' + e.target.value)));
                fetch('/signal').then(() => { const field = document.querySelector('#retained'); \(scenario.change) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let fields = try await fixture.target.fields()
            let source = try XCTUnwrap(fields.first { $0.label == "Source" }).snapshot
            let retained = try XCTUnwrap(fields.first { $0.label == "Retained" }).snapshot
            let destination = try XCTUnwrap(fields.first { $0.label == "Destination" }).snapshot
            var operations: [ComputerUseTextGoalOperation] = scenario.earlierEdit
                ? [.enterText(.init(targetID: retained.targetID, mode: .replaceAll, text: "café"))] : []
            operations.append(scenario.copy ? .copyField(sourceTargetID: source.targetID, targetID: destination.targetID, mode: .replaceAll)
                : .enterText(.init(targetID: destination.targetID, mode: .replaceAll, text: "Paris")))
            let contract = try ComputerUseTextTaskContract(taskID: "dom-constraint-race", prompt: "Keep the required field intact",
                fields: fields, operations: operations, unchangedTargetIDs: scenario.earlierEdit ? [] : [retained.targetID])
            var durable: ComputerUseTextStepJournal?, rejectedOperation: String?, dispatches = 0
            let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
                apply: { _, _ in XCTFail("Use the complete DOM dispatch") }, applyWithIdentity: { dispatch in
                    dispatches += 1
                    if dispatch.edit.targetID == destination.targetID {
                        XCTAssertEqual(durable?.statuses.last, .attempted)
                        XCTAssertEqual(dispatch.requiredValues, [retained.targetID: "café"])
                        XCTAssertEqual(dispatch.copySource?.targetID, scenario.copy ? source.targetID : nil)
                        rejectedOperation = dispatch.operationID
                        // Every host read has already succeeded. Mutate the
                        // real page before the isolated check-and-edit call.
                        try await fixture.wait { fixture.server.count("/signal") == 1 }
                        fixture.server.releaseHeldResponses()
                        try await fixture.wait { fixture.server.count("/changed") == 1 }
                    }
                    try await fixture.target.apply(dispatch)
                }, didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) },
                persist: { durable = $0 }, mayAct: { true })
            do { try await task.run(); XCTFail("DOM dispatch must reject stale retained authority") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome, "\(scenario)") }
            XCTAssertEqual(task.journal.statuses, scenario.earlierEdit ? [.verified, .uncertain] : [.uncertain])
            let rejectedID = try XCTUnwrap(rejectedOperation)
            let hasReceipt = try await fixture.target.didDispatchInput(operationID: rejectedID)
            XCTAssertFalse(hasReceipt, "Rejected input cannot create a dispatch receipt")
            do { try await task.run(); XCTFail("An uncertain attempt cannot replay") } catch {}
            XCTAssertEqual(dispatches, scenario.earlierEdit ? 2 : 1)
            let after = try await fixture.target.read(targetID: destination.targetID)
            XCTAssertEqual(after?.value, "old"); XCTAssertEqual(after?.selection, destination.selection)
            if scenario.earlierEdit { try await fixture.wait { fixture.editedValues.count == 1 } }
            XCTAssertEqual(fixture.editedValues, scenario.earlierEdit ? ["retained:café"] : [])
        }
    }

    func testDOMDispatchRejectsUnboundOrChangedConstraintsWithoutConsumingInputIdentity() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Destination<input value="old"></label><label>Retained<input value="keep"></label>
            <script>document.addEventListener('input', () => fetch('/input-event'));</script>
            """)
        defer { fixture.close() }
        let fields = try await fixture.target.fields()
        let destination = try XCTUnwrap(fields.first { $0.label == "Destination" }).snapshot
        let retained = try XCTUnwrap(fields.first { $0.label == "Retained" }).snapshot
        let operationID = ComputerUseTextTaskContract.digest("unbound-constraint")
        for unknown in [true, false] {
            do {
                try await fixture.target.apply(.init(targetID: destination.targetID, mode: .replaceAll, text: "Paris"),
                    expected: destination, operationID: operationID,
                    requiredValues: unknown ? ["different-document-field": "keep"] : [retained.targetID: "different required value"])
                XCTFail("An unbound or mismatched constraint cannot be silently dropped")
            } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, unknown ? .staleTarget : .incompleteOutcome) }
            let after = try await fixture.target.read(targetID: destination.targetID)
            let hasReceipt = try await fixture.target.didDispatchInput(operationID: operationID)
            XCTAssertEqual(after, destination); XCTAssertFalse(hasReceipt)
            XCTAssertEqual(fixture.server.count("/input-event"), 0)
        }
        // Exercise the low-level adapter independently: a rejection must not
        // consume its one-use input ID. The task engine still prohibits replay
        // of an attempted step, as covered by the preceding task-level cases.
        try await fixture.target.apply(.init(targetID: destination.targetID, mode: .replaceAll, text: "Paris"),
            expected: destination, operationID: operationID, requiredValues: [retained.targetID: "keep"])
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        let after = try await fixture.target.read(targetID: destination.targetID)
        let hasReceipt = try await fixture.target.didDispatchInput(operationID: operationID)
        XCTAssertEqual(after?.value, "Paris"); XCTAssertTrue(hasReceipt)
    }

    func testProductionDOMDispatchPreservesLatestConstraintsAcrossCopiesAndRepeatedEdits() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="origin" value="old"></label>
            <label>Destination<textarea id="destination">prior</textarea></label>
            <label>Retained<input id="retained" value="keep"></label>
            <label>Other<input id="other" value="free"></label>
            <script>let sequence = 0; document.addEventListener('input', e => {
              document.querySelector('#other').value = 'freely changed';
              const values = ['origin', 'destination', 'retained', 'other'].map(id => document.getElementById(id).value);
              fetch('/edited?value=' + encodeURIComponent(JSON.stringify([String(++sequence), e.target.id, ...values])));
            });</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMRepresentabilityFixturePlanner { fields in
            let origin = try XCTUnwrap(fields.first { $0.label == "Origin" }).snapshot.targetID
            let destination = try XCTUnwrap(fields.first { $0.label == "Destination" }).snapshot.targetID
            let retained = try XCTUnwrap(fields.first { $0.label == "Retained" }).snapshot.targetID
            return .fieldOperations([.enterText(.init(targetID: origin, mode: .replaceAll, text: "Paris")),
                .copyField(sourceTargetID: origin, targetID: destination, mode: .replaceAll),
                .enterText(.init(targetID: origin, mode: .append, text: "!")),
                .enterText(.init(targetID: origin, mode: .append, text: "!"))], unchangedTargetIDs: [retained])
        }
        let native = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, editOverride: { _, _ in XCTFail("Owned DOM input cannot fall through to AX") },
            browserTargetProvider: { taskID in ComputerUseBrowserTextTarget(browser: fixture.browser,
                document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false) })
        let executor = ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in
            XCTFail("This exact form goal must stay in its reviewed capability")
            throw ComputerUseTextTaskError.invalidPlan
        })
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let prompt = "Set Origin to Paris, copy Origin to Destination, append ! to Origin twice, and leave Retained unchanged."
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "retained-chain", prompt: prompt,
                trustedUserPrompt: prompt, tools: tools, progress: { _ in })
            guard case .completed = result else { return XCTFail("Every exact step and retained value must verify") }
        }
        try await fixture.wait { fixture.editedValues.count == 4 }
        let observed = try fixture.editedValues.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
        XCTAssertEqual(observed, [["1", "origin", "Paris", "prior", "keep", "freely changed"],
            ["2", "destination", "Paris", "Paris", "keep", "freely changed"],
            ["3", "origin", "Paris!", "Paris", "keep", "freely changed"],
            ["4", "origin", "Paris!!", "Paris", "keep", "freely changed"]])
        XCTAssertEqual(planner.calls, 1)
        let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "retained-chain"))
        XCTAssertEqual(journal.statuses, Array(repeating: .verified, count: 4))
    }

    func testCompleteTextCommandsUseProductionStepReceiptsForRepeatedLiteralsCopiesAndTargetReferences() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input id="origin" value="old"></label>
            <label>Destination<textarea id="destination">prior</textarea></label>
            <label>Retained<input id="retained" value="keep"></label>
            <script>let sequence = 0; document.addEventListener('input', e => {
              const values = ['origin', 'destination', 'retained'].map(id => document.getElementById(id).value);
              fetch('/edited?value=' + encodeURIComponent(JSON.stringify([String(++sequence), e.target.id, ...values])));
            });</script>
            """)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMRepresentabilityFixturePlanner { _ in
            XCTFail("A complete explicit text task must retain its compiled argument roles")
            return .unsupported
        }
        let native = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, editOverride: { _, _ in XCTFail("Owned DOM input cannot fall through to AX") },
            browserTargetProvider: { taskID in ComputerUseBrowserTextTarget(browser: fixture.browser,
                document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false) })
        let executor = ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in
            XCTFail("The entire compiled form goal must stay in its reviewed capability")
            throw ComputerUseTextTaskError.invalidPlan
        })
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let prompt = #"Set "Origin" to "Paris" twice, copy the "Origin" field into "Destination", append "!" to the same field twice, then replace "Origin" with the text "Destination"."#
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "compiled-text-sequence", prompt: prompt,
                trustedUserPrompt: prompt, tools: tools, progress: { _ in })
            guard case .completed = result else { return XCTFail("Every requested operation and preserved value must verify") }
        }
        try await fixture.wait { fixture.editedValues.count == 6 }
        let observed = try fixture.editedValues.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
        XCTAssertEqual(observed, [
            ["1", "origin", "Paris", "prior", "keep"],
            ["2", "origin", "Paris", "prior", "keep"],
            ["3", "destination", "Paris", "Paris", "keep"],
            ["4", "destination", "Paris", "Paris!", "keep"],
            ["5", "destination", "Paris", "Paris!!", "keep"],
            ["6", "origin", "Destination", "Paris!!", "keep"],
        ])
        XCTAssertEqual(planner.calls, 0)
        let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "compiled-text-sequence"))
        XCTAssertEqual(journal.statuses, Array(repeating: .verified, count: 6))
        XCTAssertEqual(Set(journal.stepIDs).count, 6, "Explicit repetition must retain distinct operation identities")
    }

    func testClaimedClarificationResumesSameFormAfterObservationOrPlanningCancellation() async throws {
        for stage in ["observation", "planning"] {
            var answerTask: Task<ComputerUseExecutionResult, Error>?
            var shouldCancelObservation = stage == "observation"
            let fixture = try await DOMFixture(body: """
                <label>Origin<input value="old"></label><label>Destination<textarea>keep</textarea></label>
                <script>document.querySelector('textarea').addEventListener('input', e => fetch('/edited?value=' + encodeURIComponent(e.target.value)));</script>
                """, domScriptDidDispatch: { command in
                    if command == .reobserve && shouldCancelObservation { shouldCancelObservation = false; answerTask?.cancel() }
                })
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMClarificationFixturePlanner()
            let native = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
            var desktopCalls = 0
            let executor = ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in
                desktopCalls += 1
                throw ComputerUseNativeTextExecutor.Failure.invalidClarification
            })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
            _ = try await executor.execute(taskID: "q", prompt: "Put \"  blue\n\" in a field.", trustedUserPrompt: "Put \"  blue\n\" in a field.", tools: tools, progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "q"))
            let goal = try pending.goal.answering(pending.question, with: "Destination")
            if stage == "planning" { planner.beforeAnswer = { try await Task.sleep(for: .seconds(30)) } }
            answerTask = Task { try await executor.continueClarification(taskID: "a", originatingTaskID: "q", goal: goal, progress: { _ in }) }
            if stage == "planning" { try await fixture.wait { planner.goals.count == 2 }; answerTask?.cancel() }
            do { _ = try await answerTask?.value; XCTFail("The answer must pause before input") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)") }
            planner.beforeAnswer = nil
            XCTAssertTrue(fixture.editedValues.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            do {
                _ = try await executor.execute(taskID: "a", prompt: goal.taskIdentityText,
                    trustedUserPrompt: goal.taskIdentityText, tools: tools, progress: { _ in })
                XCTFail("A raw prompt cannot replace a claimed answer before its edit contract exists")
            } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
            let result: ComputerUseExecutionResult
            do { result = try await executor.continueClarification(taskID: "a", originatingTaskID: "q", goal: goal, progress: { _ in }) }
            catch { return XCTFail("Resume after \(stage) cancellation failed: \(error)") }
            guard case .completed = result else { return XCTFail("The same answer must resume") }
            _ = try await executor.continueClarification(taskID: "a", originatingTaskID: "q", goal: goal, progress: { _ in })
            try await fixture.wait { fixture.editedValues == ["  blue\n"] }
            XCTAssertEqual(fixture.editedValues.count, 1); XCTAssertEqual(desktopCalls, 0)
            XCTAssertEqual(planner.goals.last, goal)
        }
    }

    func testPreparedClarificationCannotResumeAfterCancellationExpiryOrFormReplacement() async throws {
        for reason in ["cancel", "expiry", "replacement"] {
            let fixture = try await DOMFixture(body: """
                <label>Origin<input value="old"></label><label>Destination<textarea>keep</textarea></label>
                <script>document.querySelector('textarea').addEventListener('input', () => fetch('/input-event'));
                fetch('/signal').then(() => { const e = document.querySelector('textarea'); e.replaceWith(e.cloneNode(true)); fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMClarificationFixturePlanner()
            var now = Date()
            let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory, now: { now })
            _ = try await executor.execute(taskID: "q", prompt: "Put \"blue\" in a field.", progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "q"))
            let goal = try pending.goal.answering(pending.question, with: "Destination")
            planner.beforeAnswer = { try await Task.sleep(for: .seconds(30)) }
            let task = Task { try await executor.continueClarification(taskID: "a", originatingTaskID: "q", goal: goal, progress: { _ in }) }
            try await fixture.wait { planner.goals.count == 2 }; task.cancel()
            do { _ = try await task.value; XCTFail("Planning should be cancelled") } catch { XCTAssertTrue(error is CancellationError) }
            planner.beforeAnswer = nil
            switch reason {
            case "cancel": executor.invalidateClarification(taskID: "a")
            case "expiry": now = pending.expiresAt
            default:
                try await fixture.wait { fixture.server.count("/signal") == 1 }
                fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
            }
            for _ in 0..<2 {
                do { _ = try await executor.continueClarification(taskID: "a", originatingTaskID: "q", goal: goal, progress: { _ in }); XCTFail("Invalidated prepared state must not run: \(reason)") }
                catch { XCTAssertTrue(error as? ComputerUseNativeTextExecutor.Failure == .invalidClarification || error as? ComputerUseBrowserError == .pageChanged) }
            }
            XCTAssertEqual(planner.goals.count, 2); XCTAssertEqual(fixture.server.count("/input-event"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

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
        let result = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: answer, progress: { _ in })
        guard case .unableToComplete = result else { return XCTFail("Reject an incompatible result before input") }
        do { _ = try await executor.continueClarification(taskID: "a1", originatingTaskID: "q1", goal: answer, progress: { _ in }); XCTFail("The rejected answer cannot retain planning authority") }
        catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        let observed = ComputerUseBrowserTextTarget(browser: fixture.browser,
            document: try fixture.browser.acquireCurrentDocument(taskID: "audit"), requiresFrontmost: false)
        let values = try await observed.fields().map { $0.snapshot.value }
        XCTAssertEqual(values, ["old", "keep"])
        XCTAssertEqual(fixture.editedValues, []); XCTAssertEqual(planner.goals.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Rejection precedes journal creation")
        XCTAssertNil(try executor.clarification(taskID: "q1")); XCTAssertNil(try executor.clarification(taskID: "a1"))
    }

    func testUnrepresentableValuesRejectBeforeLiveSetterSelectionReceiptOrInput() async throws {
        let cases = [("<input type='text' value='keep'>", "a\nb"),
                     ("<input type='search' value='keep'>", "a\rb"),
                     ("<input type='tel' value='keep'>", "a\r\nb"),
                     ("<input type='url' value='keep'>", " https://example.test/path "),
                     ("<input type='email' value='keep'>", " person@example.test "),
                     ("<input type='email' multiple value='keep'>", "a@example.test, b@example.test"),
                     ("<textarea>keep</textarea>", "a\rb"),
                     ("<textarea>keep</textarea>", "a\r\nb")]
        for (html, payload) in cases {
            let fixture = try await DOMFixture(body: "<label>Value" + html + "</label>" + Self.representabilityAuditScript,
                heldSignal: true)
            defer { fixture.close() }
            let fields = try await fixture.target.fields(), initial = try XCTUnwrap(fields.first?.snapshot)
            let operation = ComputerUseTaskContract.digest(["rejected", html, payload])
            for _ in 0..<2 {
                do { try await fixture.target.apply(.init(targetID: initial.targetID, mode: .replaceAll, text: payload), expected: initial, operationID: operation)
                    XCTFail("The native value round trip changes these bytes: \(html)") }
                catch { XCTAssertEqual(error as? ComputerUseTextEditError, .valueNotRepresentable, html) }
                let after = try await fixture.target.read(targetID: initial.targetID)
                XCTAssertEqual(after, initial, "No value or selection mutation")
                let dispatched = try await fixture.target.didDispatchInput(operationID: operation)
                XCTAssertFalse(dispatched)
            }
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { Self.representabilityAudit(fixture) != nil }
            let audit = try XCTUnwrap(Self.representabilityAudit(fixture))
            XCTAssertEqual(audit["events"], "0")
            XCTAssertEqual(audit["value0"], "keep")
            XCTAssertEqual(audit["start0"], initial.selection.location == NSNotFound ? "-1" : String(initial.selection.location))
            XCTAssertEqual(audit["end0"], initial.selection.location == NSNotFound ? "-1" : String(NSMaxRange(initial.selection)))
        }
    }

    func testRepresentableValuesKeepExactBytesAndAllThreeEditModes() async throws {
        let cases: [(String, ComputerUseTextEditMode, String, String)] = [
            ("<input type='text' value='keep'>", .replaceAll, "  e\u{301} 😀\t ", "  e\u{301} 😀\t "),
            ("<input type='search' value='keep'>", .append, " 😀 ", "keep 😀 "),
            ("<input type='tel' value='keep'>", .replaceAll, " +1 234 ", " +1 234 "),
            ("<input type='url' value='keep'>", .replaceAll, "https://example.test/x\u{a0}", "https://example.test/x\u{a0}"),
            ("<input type='url' value='keep'>", .insert, " ", "ke ep"),
            ("<input type='email' value='keep'>", .append, "@example.test", "keep@example.test"),
            ("<input type='email' multiple value='keep'>", .replaceAll, "a@example.test,b@example.test", "a@example.test,b@example.test"),
            ("<textarea>keep</textarea>", .replaceAll, " \ne\u{301} 😀\n ", " \ne\u{301} 😀\n "),
            ("<textarea>keep</textarea>", .replaceAll, "", "")]
        for (html, mode, payload, expected) in cases {
            let fixture = try await DOMFixture(body: "<label>Value" + html + "</label>" + Self.representabilityAuditScript,
                heldSignal: true)
            defer { fixture.close() }
            let fields = try await fixture.target.fields(), initial = try XCTUnwrap(fields.first?.snapshot)
            let contract = try ComputerUseTextTaskContract(taskID: "compatible", prompt: "Controlled text edit", fields: fields,
                edits: [.init(targetID: initial.targetID, mode: mode, text: payload)])
            for _ in 0..<2 { try await fixture.target.validateRepresentability(of: contract) }
            let beforeInput = try await fixture.target.read(targetID: initial.targetID)
            XCTAssertEqual(beforeInput, initial, "Repeated preflight must not move selection or change the value")
            let operation = contract.steps[0].id
            let beforeReceipt = try await fixture.target.didDispatchInput(operationID: operation)
            XCTAssertFalse(beforeReceipt)
            try await fixture.target.apply(.init(targetID: initial.targetID, mode: mode, text: payload), expected: initial, operationID: operation)
            let after = try await fixture.target.read(targetID: initial.targetID)
            XCTAssertTrue(try XCTUnwrap(after?.value).utf8.elementsEqual(expected.utf8))
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { Self.representabilityAudit(fixture) != nil }
            let audit = try XCTUnwrap(Self.representabilityAudit(fixture))
            XCTAssertEqual(audit["events"], "1")
            XCTAssertTrue(try XCTUnwrap(audit["value0"]).utf8.elementsEqual(expected.utf8), html)
        }
    }

    func testNativePreflightsEveryIntermediateAndCopiedResultBeforeAnyFieldChanges() async throws {
        for copy in [false, true] {
            let fixture = try await DOMFixture(body: "<label>Origin<textarea>old</textarea></label><label>Destination<input value='keep'></label>" + Self.representabilityAuditScript,
                heldSignal: true)
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMRepresentabilityFixturePlanner { fields in
                let source = try XCTUnwrap(fields.first(where: { $0.label == "Origin" })?.snapshot.targetID)
                let target = try XCTUnwrap(fields.first(where: { $0.label == "Destination" })?.snapshot.targetID)
                if copy {
                    return .fieldOperations([
                        .enterText(.init(targetID: source, mode: .replaceAll, text: "new\nvalue")),
                        .copyField(sourceTargetID: source, targetID: target, mode: .replaceAll)
                    ], unchangedTargetIDs: [])
                }
                return .edits([
                    .init(targetID: source, mode: .replaceAll, text: "first valid edit"),
                    .init(targetID: target, mode: .replaceAll, text: "incompatible\nintermediate"),
                    .init(targetID: target, mode: .replaceAll, text: "valid final value")
                ], unchangedTargetIDs: [])
            }
            let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
                planner: planner, browserTargetProvider: { taskID in
                    ComputerUseBrowserTextTarget(browser: fixture.browser,
                        document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
                })
            var desktopLoads = 0
            let coordinator = ComputerUseCapabilityExecutor(native: executor, desktopFactory: { _ in desktopLoads += 1; return DOMRoutingDesktopFixture() })
            let result = try await coordinator.execute(taskID: "whole-plan", prompt: "Carry out the planned form edits",
                trustedUserPrompt: "Carry out the planned form edits",
                tools: ComputerUseHostTools(injector: InputInjector(), mayAct: { true }), progress: { _ in })
            guard case .unableToComplete = result else { return XCTFail("The complete plan is incompatible before its first edit") }
            XCTAssertEqual(desktopLoads, 0, "An exact-text constraint failure cannot be routed around")
            XCTAssertEqual(planner.calls, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { Self.representabilityAudit(fixture) != nil }
            let audit = try XCTUnwrap(Self.representabilityAudit(fixture))
            XCTAssertEqual(audit["events"], "0")
            XCTAssertEqual(audit["value0"], "old"); XCTAssertEqual(audit["value1"], "keep")
        }
    }

    func testChangingAndRestoringEmailMultipleRetiresTheObservedField() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Addresses<input type="email" multiple value="keep"></label><script>
            fetch('/signal').then(() => { const e = document.querySelector('input'); e.multiple = false; e.multiple = true; fetch('/changed'); });
            </script>
            """, heldSignal: true)
        defer { fixture.close() }
        let fields = try await fixture.target.fields(), initial = try XCTUnwrap(fields.first?.snapshot)
        let contract = try ComputerUseTextTaskContract(taskID: "changed", prompt: "Controlled edit", fields: fields,
            edits: [.init(targetID: initial.targetID, mode: .replaceAll, text: "a@example.test,b@example.test")])
        try await fixture.target.validateRepresentability(of: contract)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { try await fixture.target.validateRepresentability(of: contract); XCTFail("A changed native value capability needs a new observation") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        do { try await fixture.target.apply(.init(targetID: initial.targetID, mode: .replaceAll, text: "a@example.test,b@example.test"), expected: initial, operationID: contract.steps[0].id); XCTFail("Earlier preflight cannot authorize a changed field") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
    }

    private static let representabilityAuditScript = """
        <script>
        const auditFields = [...document.querySelectorAll('input,textarea')]; let inputEvents = 0;
        for (const e of auditFields) { if (e.selectionStart !== null) e.setSelectionRange(2,2); e.addEventListener('input', () => inputEvents++); }
        fetch('/signal').then(() => {
          const values = {events:String(inputEvents)};
          auditFields.forEach((e,i) => { values['value'+i] = e.value; values['start'+i] = String(e.selectionStart ?? -1); values['end'+i] = String(e.selectionEnd ?? -1); });
          fetch('/audit?' + new URLSearchParams(values));
        });
        </script>
        """

    private static func representabilityAudit(_ fixture: DOMFixture) -> [String: String]? {
        guard let path = fixture.server.requestedPaths.first(where: { $0.hasPrefix("/audit?") }),
              let items = URLComponents(string: "http://localhost" + path.replacingOccurrences(of: "+", with: "%20"))?.queryItems,
              Set(items.map(\.name)).count == items.count else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
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

    func testBrowserClarificationCannotRenewExpiredOrInvalidatedAuthorityFromAPlannerOutcome() async throws {
        for invalidation in ["expiry", "explicit"] {
            for outcome in ["question", "unsupported", "edits"] {
                let fixture = try await DOMFixture(body: """
                    <label>Destination<input value="old"></label>
                    <script>document.querySelector('input').addEventListener('input', () => fetch('/input-event'));</script>
                    """)
                defer { fixture.close() }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                var now = Date(timeIntervalSince1970: 1_000)
                let planner = DOMClarificationFixturePlanner(declinesAnswer: outcome == "unsupported")
                if outcome == "question" { planner.answerProposal = .clarification }
                let executor = clarificationExecutor(fixture: fixture, planner: planner, directory: directory, now: { now })
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in a field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                planner.beforeAnswer = { [weak executor] in
                    if invalidation == "expiry" { now = pending.expiresAt }
                    else { executor?.invalidateClarification(taskID: "answer") }
                }
                let answer = try pending.goal.answering(pending.question, with: "Destination")
                do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Every planner outcome must respect the original clarification lifetime") }
                catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
                XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertNil(try executor.clarification(taskID: "answer"))
                XCTAssertEqual(planner.goals.count, 2); XCTAssertEqual(fixture.server.count("/input-event"), 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
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
                applyWithIdentity: { try await fixture.target.apply($0) },
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
                applyWithIdentity: { try await fixture.target.apply($0) }, didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) },
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
            <input aria-label="Password" type="password" hidden value="never expose this">
            <input aria-label="Code" autocomplete="one-time-code" hidden value="123456">
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
            applyWithIdentity: { dispatch in
                XCTAssertEqual(durable?.statuses, [.attempted])
                try await fixture.target.apply(dispatch)
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

    func testUnsupportedInitialBrowserFormPreservesWholeGoalThroughDesktopRouting() async throws {
        for body in ["<p>No form</p>", "<label>Named<input></label><input>",
                     String(repeating: "<label>Field<input></label>", count: 17)] {
            var discoveries = 0
            let fixture = try await DOMFixture(body: body + """
                <script>document.addEventListener('input', () => fetch('/input-event'));</script>
                """, domScriptDidDispatch: { if $0 == .fields { discoveries += 1 } })
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMFixturePlanner()
            let native = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
                planner: planner, editOverride: { _, _ in XCTFail("Discovery must not emit AX input") },
                browserTargetProvider: { taskID in ComputerUseBrowserTextTarget(browser: fixture.browser,
                    document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false) })
            let desktop = DOMRoutingDesktopFixture()
            var desktopLoads = 0
            let executor = ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in desktopLoads += 1; return desktop })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
            let goal = "Find flights from San Francisco to Los Angeles and compare prices. Do not book."
            let modelContext = "Earlier context\nCurrent request: " + goal
            let conversation = [ComputerUseConversationTurn(role: .assistant, text: "Earlier context")]
            for _ in 0..<2 {
                let result = try await executor.execute(taskID: "whole-goal", modelPrompt: modelContext,
                    currentUserPrompt: goal, conversation: conversation, tools: tools, progress: { _ in })
                XCTAssertEqual(result, desktop.result, "Declining a form is not completion of the whole task")
            }
            XCTAssertEqual(discoveries, 1, "Resume must retain the desktop route without rediscovering the form")
            XCTAssertEqual(desktopLoads, 1); XCTAssertEqual(planner.calls, 0)
            XCTAssertEqual(desktop.taskIDs, ["whole-goal", "whole-goal"])
            XCTAssertEqual(desktop.currentPrompts, [goal, goal])
            XCTAssertEqual(desktop.modelPrompts, [modelContext, modelContext])
            XCTAssertEqual(desktop.conversations, [conversation, conversation])
            XCTAssertNil(try executor.clarification(taskID: "whole-goal"))
            XCTAssertEqual(fixture.server.count("/input-event"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testInterruptedInitialBrowserDiscoveryCannotEnterDesktopFallback() async throws {
        for reason in ["before", "cancel", "takeover", "ownership"] {
            var allowed = reason != "before", browserAllowed = true, discoveries = 0
            var request: Task<ComputerUseExecutionResult, Error>?
            defer { request?.cancel(); request = nil }
            let fixture = try await DOMFixture(body: "<input>", domScriptDidDispatch: { command in
                guard command == .fields else { return }
                discoveries += 1
                if reason == "cancel" { request?.cancel() }
                if reason == "takeover" { allowed = false }
                if reason == "ownership" { browserAllowed = false }
            }, mayAct: { browserAllowed })
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMFixturePlanner()
            let native = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { allowed }, journalDirectory: directory,
                planner: planner, browserTargetProvider: { taskID in ComputerUseBrowserTextTarget(browser: fixture.browser,
                    document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false) })
            var desktopLoads = 0
            let executor = ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in desktopLoads += 1; return DOMRoutingDesktopFixture() })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed })
            request = Task { try await executor.execute(taskID: "interrupted", prompt: "Find movie showtimes",
                trustedUserPrompt: "Find movie showtimes", tools: tools, progress: { _ in }) }
            do { _ = try await request?.value; XCTFail("An interruption cannot become capability fallback") }
            catch {
                if reason == "cancel" { XCTAssertTrue(error is CancellationError) }
                else if reason == "ownership" { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
                else { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
            }
            XCTAssertEqual(discoveries, reason == "before" ? 0 : 1)
            XCTAssertEqual(desktopLoads, 0); XCTAssertEqual(planner.calls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testScopedAnswerCannotFallBackWhenPlannerDeclinesOrFormBecomesUnsupported() async throws {
        for changedForm in [false, true] {
            let fixture = try await DOMFixture(body: """
                <label>Origin<input value="old"></label><label>Destination<input value="keep"></label>
                <script>document.addEventListener('input', () => fetch('/input-event'));
                fetch('/signal').then(() => { document.body.append(document.createElement('input')); fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = DOMClarificationFixturePlanner(declinesAnswer: true)
            let native = clarificationExecutor(fixture: fixture, planner: planner, directory: directory)
            var desktopLoads = 0
            let executor = ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in desktopLoads += 1; return DOMRoutingDesktopFixture() })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
            let prompt = "Put \"blue\" in a field."
            _ = try await executor.execute(taskID: "question", prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
            let answer = try pending.goal.answering(pending.question, with: "Destination")
            if changedForm {
                try await fixture.wait { fixture.server.count("/signal") == 1 }
                fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
                do {
                    _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in })
                    XCTFail("A scoped answer cannot rediscover an unsupported form or enter desktop routing")
                } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            } else {
                let result = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in })
                guard case .unableToComplete = result else { return XCTFail("A declined answer stays within its retained goal") }
            }
            XCTAssertEqual(planner.goals.count, changedForm ? 1 : 2)
            XCTAssertEqual(desktopLoads, 0); XCTAssertEqual(fixture.server.count("/input-event"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeInputUncertaintyCannotReenterDesktopRouting() async throws {
        let fixture = try await DOMFixture(body: """
            <label>Origin<input value="old"></label><label>Destination<input value="keep"></label>
            <script>document.querySelector('input').addEventListener('input', e => { e.target.value = 'rejected'; fetch('/input-event'); });
            fetch('/signal').then(() => { document.body.append(document.createElement('input')); fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = DOMFixturePlanner()
        var discoveries = 0, desktopLoads = 0
        func makeExecutor(planner: any ComputerUseTextGoalPlanning) -> ComputerUseCapabilityExecutor {
            let native = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
                planner: planner, browserTargetProvider: { taskID in
                    discoveries += 1
                    return ComputerUseBrowserTextTarget(browser: fixture.browser,
                        document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
                })
            return ComputerUseCapabilityExecutor(native: native, desktopFactory: { _ in desktopLoads += 1; return DOMRoutingDesktopFixture() })
        }
        let executor = makeExecutor(planner: planner)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let prompt = "Set Origin to Paris and leave Destination unchanged"
        for _ in 0..<2 {
            do {
                _ = try await executor.execute(taskID: "uncertain", prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: { _ in })
                XCTFail("An uncertain native effect must not be repeated by either route")
            } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        }
        try await fixture.wait { fixture.server.count("/input-event") == 1 }
        XCTAssertEqual(fixture.server.count("/input-event"), 1)
        XCTAssertEqual(discoveries, 1); XCTAssertEqual(planner.calls, 1); XCTAssertEqual(desktopLoads, 0)
        // A recreated executor must check durable ownership before declining,
        // whether its new planner declines or the page no longer has a form
        // this capability can observe completely.
        let decliningPlanner = DOMRepresentabilityFixturePlanner { _ in .unsupported }
        for unsupportedForm in [false, true] {
            if unsupportedForm {
                try await fixture.wait { fixture.server.count("/signal") == 1 }
                fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
            }
            let recreated = makeExecutor(planner: decliningPlanner)
            do {
                _ = try await recreated.execute(taskID: "uncertain", prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: { _ in })
                XCTFail("A persisted attempt cannot become a fresh desktop task after executor replacement")
            } catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        }
        XCTAssertEqual(discoveries, 3); XCTAssertEqual(planner.calls, 1); XCTAssertEqual(decliningPlanner.calls, 1)
        XCTAssertEqual(desktopLoads, 0); XCTAssertEqual(fixture.server.count("/input-event"), 1)
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
                applyWithIdentity: { try await fixture.target.apply($0) },
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
private final class DOMRoutingDesktopFixture: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Routing fixture"
    let result = ComputerUseExecutionResult.unableToComplete("Recording handoff only; no desktop task is performed by this fixture.")
    var taskIDs: [String] = [], currentPrompts: [String] = [], modelPrompts: [String] = []
    var conversations: [[ComputerUseConversationTurn]] = []

    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTFail("Routing must retain the structured task boundary")
        return result
    }

    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        taskIDs.append(taskID); currentPrompts.append(currentUserPrompt)
        modelPrompts.append(modelPrompt); conversations.append(conversation)
        return result
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
private final class DOMRepresentabilityFixturePlanner: ComputerUseTextGoalPlanning {
    var calls = 0
    let proposal: ([ComputerUseTextField]) throws -> ComputerUseTextGoalProposal
    init(_ proposal: @escaping ([ComputerUseTextField]) throws -> ComputerUseTextGoalProposal) { self.proposal = proposal }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        return try proposal(fields)
    }
}

@MainActor
private final class DOMClarificationFixturePlanner: ComputerUseTextGoalPlanning {
    let answersNeeded: Int
    let declinesAnswer: Bool
    var goals: [ComputerUseUnresolvedTextGoal] = []
    var fieldValues: [[String]] = []
    var beforeAnswer: (() async throws -> Void)?
    var answerProposal: ComputerUseTextGoalProposal?
    init(answersNeeded: Int = 1, declinesAnswer: Bool = false) { self.answersNeeded = answersNeeded; self.declinesAnswer = declinesAnswer }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        try await propose(goal: ComputerUseUnresolvedTextGoal(userRequest: prompt), fields: fields)
    }
    func propose(goal: ComputerUseUnresolvedTextGoal, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        goals.append(goal); fieldValues.append(fields.map { $0.snapshot.value })
        if goal.userTurns.count <= answersNeeded { return .clarification }
        try await beforeAnswer?()
        if let answerProposal { return answerProposal }
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
