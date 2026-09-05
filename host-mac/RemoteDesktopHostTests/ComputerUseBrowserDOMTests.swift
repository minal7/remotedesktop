import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserDOMTests: XCTestCase {
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

private func requireDOM<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
