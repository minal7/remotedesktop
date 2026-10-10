import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextEditorTests: XCTestCase {
    func testSameFieldCaretValueAndProtectionChangesStopBeforeAnotherUnicodeStroke() async throws {
        for route in ["native", "visual-tools"] {
            for change in ["caret", "value", "secure", "read-only"] {
                let fields = NativeFields(setter: .unicode), events = UnicodeStrokeEvents()
                let injector = InputInjector(eventPoster: { events.record($0) })
                var applied = 0, changed = false
                fields.beforeRead = { [weak fields] in
                    guard let fields else { return }
                    let input = events.downTexts
                    guard input.count > applied else { return }
                    for text in input.dropFirst(applied) { fields.receiveUnicode(text) }
                    applied = input.count
                    guard !changed else { return }
                    changed = true
                    switch change {
                    case "caret": fields.selections["destination"] = NSRange(location: 0, length: 0)
                    case "value": fields.setValue("destination", "Intervening text")
                    case "secure": fields.secureIDs.insert("destination")
                    default: fields.readOnlyIDs.insert("destination")
                    }
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let planner = NativePlanner(operations: [.enterText(.init(targetID: "destination", mode: .replaceAll, text: "Paris"))])
                let executor = ComputerUseNativeTextExecutor(injector: injector, mayAct: { true }, journalDirectory: directory,
                    planner: planner, nativeTarget: fields)
                let tools = ComputerUseHostTools(injector: injector, mayAct: { true }, nativeTextTarget: fields)
                await assertError(.deliveryUncertain) {
                    if route == "native" {
                        _ = try await executor.execute(taskID: "same-field-drift", prompt: "Apply the requested form edits", progress: { _ in })
                    } else { try await tools.editFocusedText("Paris", mode: .replaceAll) }
                }
                XCTAssertTrue(changed, route + "/" + change)
                XCTAssertEqual(events.downTexts, ["P"]); XCTAssertEqual(events.upTexts, ["P"])
                XCTAssertEqual(fields.values["destination"], change == "value" ? "Intervening text" : "P")
                if route == "native" {
                    do {
                        _ = try await executor.execute(taskID: "same-field-drift", prompt: "Apply the requested form edits", progress: { _ in })
                        XCTFail("An uncertain Unicode effect must not replay")
                    } catch {}
                    XCTAssertEqual(events.downTexts, ["P"]); XCTAssertEqual(events.upTexts, ["P"])
                    let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "same-field-drift"))
                    XCTAssertEqual(journal.statuses, [.uncertain]); XCTAssertEqual(planner.calls, 1)
                }
            }
        }
    }

    func testUnicodeStrokeAdmissionRejectsChangedStateAndInvalidUnitsWithoutPosting() async throws {
        let events = UnicodeStrokeEvents(), field = Field("old")
        let injector = InputInjector(eventPoster: { events.record($0) })
        let expected = field.snapshot
        let accepted = await injector.applyTextStroke("x", ifAllowed: {
            field.selection = NSRange(location: 0, length: 0)
            return true
        }, beforePosting: { field.snapshot == expected })
        XCTAssertFalse(accepted); XCTAssertTrue(events.downTexts.isEmpty); XCTAssertTrue(events.upTexts.isEmpty)
        for invalid in ["", "ab"] {
            let accepted = await injector.applyTextStroke(invalid, ifAllowed: { true }, beforePosting: {
                XCTFail("Reject a non-stroke before admission"); return true
            })
            XCTAssertFalse(accepted)
        }
        let cancelled = Task {
            await injector.applyTextStroke("x", ifAllowed: { true }, beforePosting: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            })
        }
        let cancellationResult = await cancelled.value
        XCTAssertFalse(cancellationResult)
        XCTAssertTrue(events.downTexts.isEmpty); XCTAssertTrue(events.upTexts.isEmpty)
        let grapheme = "👨‍👩‍👧‍👦"
        let posted = await injector.applyTextStroke(grapheme, ifAllowed: { true })
        XCTAssertTrue(posted)
        XCTAssertEqual(events.downTexts.count, 1); XCTAssertEqual(events.upTexts.count, 1)
        XCTAssertTrue(events.downTexts.joined().utf8.elementsEqual(grapheme.utf8))
        XCTAssertTrue(events.upTexts.joined().utf8.elementsEqual(grapheme.utf8))
    }

    func testNativeAndVisualUnicodeDeliveryPreserveExactPayloadAndEditMode() async throws {
        let payload = "  e\u{301} 😀 👨‍👩‍👧‍👦 東京\n  "
        for route in ["native", "visual-tools"] {
            for mode in [ComputerUseTextEditMode.insert, .replaceAll, .append] {
                let fields = NativeFields(setter: .unicode), events = UnicodeStrokeEvents()
                fields.selections["destination"] = NSRange(location: 1, length: 1)
                let injector = InputInjector(eventPoster: { events.record($0) })
                var applied = 0
                fields.beforeRead = { [weak fields] in
                    guard let fields else { return }
                    let input = events.downTexts
                    for text in input.dropFirst(applied) { fields.receiveUnicode(text) }
                    applied = input.count
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                if route == "native" {
                    let planner = NativePlanner(operations: [.enterText(.init(targetID: "destination", mode: mode, text: payload))])
                    let executor = ComputerUseNativeTextExecutor(injector: injector, mayAct: { true }, journalDirectory: directory,
                        planner: planner, nativeTarget: fields)
                    for _ in 0..<2 {
                        let result = try await executor.execute(taskID: "exact-strokes", prompt: "Apply the requested form edits", progress: { _ in })
                        guard case .completed = result else { return XCTFail("The complete exact edit should verify") }
                    }
                    XCTAssertEqual(planner.calls, 1)
                    let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "exact-strokes"))
                    XCTAssertEqual(journal.statuses, [.verified])
                } else {
                    let tools = ComputerUseHostTools(injector: injector, mayAct: { true }, nativeTextTarget: fields)
                    try await tools.editFocusedText(payload, mode: mode)
                }
                let expected = mode == .insert ? "o" + payload + "d" : mode == .append ? "old" + payload : payload
                XCTAssertTrue(try XCTUnwrap(fields.values["destination"]).utf8.elementsEqual(expected.utf8), route)
                XCTAssertTrue(events.downTexts.joined().utf8.elementsEqual(payload.utf8))
                XCTAssertTrue(events.upTexts.joined().utf8.elementsEqual(payload.utf8))
                XCTAssertEqual(events.downTexts.count, payload.count)
                XCTAssertEqual(fields.selections["destination"], NSRange(location: (mode == .insert ? 1 : mode == .append ? 3 : 0) + payload.utf16.count, length: 0))
                XCTAssertEqual(fields.values["retained"], "keep"); XCTAssertTrue(fields.edits.isEmpty)
            }
        }
    }

    func testHostToolsVerifyTargetReadbackAfterSetterMovesFocus() async throws {
        let expected = "person@example.com"
        for setter in [NativeFields.Setter.whole, .selected] {
            let fields = NativeFields(setter: setter)
            fields.afterInput = { [weak fields] in fields?.focusedID = "autocomplete" }
            let tools = ComputerUseHostTools(injector: InputInjector(eventPoster: { _ in XCTFail("A supported AX setter must not post keys") }),
                mayAct: { true }, nativeTextTarget: fields)

            do { try await tools.editFocusedText(expected, mode: .replaceAll) }
            catch { XCTFail("The retained target has the exact edited value after focus moves: \(error)") }

            XCTAssertEqual(fields.values["destination"], expected)
            XCTAssertEqual(fields.focusedID, "autocomplete")
            XCTAssertEqual(fields.edits.count, 1)
            XCTAssertEqual(fields.focusCalls, 0)
        }
    }

    func testHostToolsTargetSpecificReadbackStillRejectsWrongOrReplacedTarget() async throws {
        for outcome in ["wrong-value", "replaced-target"] {
            let fields = NativeFields(setter: .whole)
            fields.afterInput = { [weak fields] in
                guard let fields else { return }
                if outcome == "wrong-value" { fields.setValue("destination", "different value") }
                else { fields.values.removeValue(forKey: "destination") }
                fields.focusedID = "autocomplete"
            }
            let tools = ComputerUseHostTools(injector: InputInjector(eventPoster: { _ in XCTFail("A supported AX setter must not post keys") }),
                mayAct: { true }, nativeTextTarget: fields)

            do {
                try await tools.editFocusedText("person@example.com", mode: .replaceAll)
                XCTFail("Target-specific readback must still require the exact original target and value")
            } catch {
                XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain)
            }
            XCTAssertEqual(fields.focusedID, "autocomplete")
            XCTAssertEqual(fields.edits.count, 1)
            XCTAssertEqual(fields.focusCalls, 0)
        }
    }

    func testHostToolsUnicodeReadbackStopsWhenFocusMovesAfterFirstGrapheme() async throws {
        let fields = NativeFields(setter: .unicode), events = UnicodeStrokeEvents()
        var applied = 0
        fields.beforeRead = { [weak fields] in
            guard let fields else { return }
            let input = events.downTexts
            guard input.count > applied else { return }
            for text in input.dropFirst(applied) { fields.receiveUnicode(text) }
            applied = input.count
            if applied == 1 { fields.focusedID = "autocomplete" }
        }
        let tools = ComputerUseHostTools(injector: InputInjector(eventPoster: { events.record($0) }),
            mayAct: { true }, nativeTextTarget: fields)

        await assertError(.deliveryUncertain) {
            try await tools.editFocusedText("ab", mode: .insert)
        }

        XCTAssertEqual(events.downTexts, ["a"])
        XCTAssertEqual(events.upTexts, ["a"])
        XCTAssertEqual(fields.values["destination"], "olda")
        XCTAssertEqual(fields.focusCalls, 0)
    }

    func testHostToolsTextEditStillRejectsProtectionAndLostOwnership() async throws {
        for reason in ["secure", "read-only", "paused"] {
            let fields = NativeFields(setter: .whole)
            if reason == "secure" { fields.secureIDs.insert("destination") }
            if reason == "read-only" { fields.readOnlyIDs.insert("destination") }
            let tools = ComputerUseHostTools(injector: InputInjector(eventPoster: { _ in XCTFail("Rejected edit must not post keys") }),
                mayAct: { reason != "paused" }, nativeTextTarget: fields)
            do {
                try await tools.editFocusedText("new", mode: .replaceAll)
                XCTFail("Expected \(reason) to reject the edit")
            } catch {
                let expected: ComputerUseTextEditError = reason == "secure" ? .secureTarget
                    : reason == "read-only" ? .unavailableTarget : .interrupted
                XCTAssertEqual(error as? ComputerUseTextEditError, expected)
            }
            XCTAssertTrue(fields.edits.isEmpty)
            XCTAssertEqual(fields.focusCalls, 0)
        }

        let fields = NativeFields(setter: .whole)
        var active = true
        fields.afterInput = { [weak fields] in fields?.focusedID = "autocomplete"; active = false }
        let tools = ComputerUseHostTools(injector: InputInjector(eventPoster: { _ in XCTFail("The AX setter should not post keys") }),
            mayAct: { active }, nativeTextTarget: fields)
        await assertError(.interrupted) {
            try await tools.editFocusedText("new", mode: .replaceAll)
        }
        XCTAssertEqual(fields.edits.count, 1, "The already-dispatched setter is retained but not reported as complete")
        XCTAssertEqual(fields.focusCalls, 0)
    }

    func testVerificationReadCannotReturnSuccessAfterDeadlineTakeoverOrCancellation() async throws {
        for reason in ["deadline", "takeover", "cancel", "context"] {
            let field = Field("old")
            var now: TimeInterval = 0, hasPosted = false
            var editor = ComputerUseTextEditor(read: {
                if hasPosted {
                    if reason == "deadline" { now = 61 }
                    if reason == "takeover" { field.allowed = false }
                    if reason == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return field.snapshot
            }, select: { _, _ in XCTFail("Whole-value setter needs no selection"); return false },
                replaceSelectedText: { _, _ in XCTFail("Do not fall back"); return nil },
                postUnicode: { _, _ in XCTFail("Do not fall back") }, mayAct: { field.allowed })
            editor.uptime = { now }
            editor.replaceValue = { value, _ in field.value = value; hasPosted = true; return true }
            editor.validateContext = {
                if hasPosted && reason == "context" { throw ComputerUseTextTaskError.incompleteOutcome }
            }
            let snapshot = field.snapshot
            let execution = Task { try await editor.edit("new", mode: .replaceAll, expected: snapshot) }
            do { try await execution.value; XCTFail("An exact value after invalidation is not success") }
            catch {
                if reason == "context" { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
                else { XCTAssertEqual(error as? ComputerUseTextEditError, reason == "deadline" ? .deadlineExceeded : .interrupted) }
            }
            XCTAssertTrue(hasPosted); XCTAssertEqual(field.value, "new", "Retain the effect without reporting completion")
        }
    }

    func testUnicodeCannotAdvanceUntilThePrecedingValueAndCaretAreConfirmed() async throws {
        let field = Field("old", selection: NSRange(location: 1, length: 1))
        var pending: String?, waits = 0, posted: [String] = []
        var editor = ComputerUseTextEditor(read: { field.snapshot }, select: { _, _ in false },
            replaceSelectedText: { _, _ in nil }, postUnicode: { text, expected in
                XCTAssertNil(pending, "No new event while an earlier one is unconfirmed")
                XCTAssertEqual(field.snapshot, expected)
                pending = text; posted.append(text)
            }, mayAct: { true })
        editor.wait = {
            waits += 1
            if waits.isMultiple(of: 2), let text = pending { field.insert(text); pending = nil }
        }
        try await editor.edit("😀x", expected: field.snapshot)
        XCTAssertEqual(posted, ["😀", "x"]); XCTAssertNil(pending); XCTAssertEqual(waits, 4)
        XCTAssertEqual(field.value, "o😀xd"); XCTAssertEqual(field.selection, NSRange(location: 4, length: 0))
    }

    func testContextDriftBetweenTextAdaptersStopsSelectionSettersAndLaterChunks() async throws {
        for stage in ["value-probe", "selection", "selected-probe", "first-chunk"] {
            let field = Field("old")
            var contextValid = true, calls: [String] = []
            var editor = ComputerUseTextEditor(read: { field.snapshot }, select: { range, expected in
                XCTAssertEqual(expected, field.snapshot)
                calls.append("selection"); field.selection = range
                if stage == "selection" { contextValid = false }
                return true
            }, replaceSelectedText: { _, expected in
                XCTAssertEqual(expected, field.snapshot)
                calls.append("selected-probe")
                if stage == "selected-probe" { contextValid = false }
                return nil
            }, postUnicode: { text, expected in
                XCTAssertEqual(expected, field.snapshot)
                calls.append("chunk"); field.insert(text); contextValid = false
            }, mayAct: { true })
            editor.replaceValue = { _, expected in
                XCTAssertEqual(expected, field.snapshot)
                calls.append("value-probe")
                if stage == "value-probe" { contextValid = false }
                return nil
            }
            editor.validateContext = { if !contextValid { throw ComputerUseTextTaskError.incompleteOutcome } }
            do { try await editor.edit("12345678901234567890123", mode: .replaceAll, expected: field.snapshot); XCTFail("Changed context must stop the next effect") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
            let expectedCalls: [String: [String]] = ["value-probe": ["value-probe"],
                "selection": ["value-probe", "selection"], "selected-probe": ["value-probe", "selection", "selected-probe"],
                "first-chunk": ["value-probe", "selection", "selected-probe", "chunk"]]
            XCTAssertEqual(calls, try XCTUnwrap(expectedCalls[stage]))
            XCTAssertEqual(field.value, stage == "first-chunk" ? "1" : "old")
        }
    }

    func testContextReadCannotRetargetAnEditOrOutliveItsDeadline() async throws {
        for reason in ["target", "selection", "deadline", "takeover"] {
            let field = Field("old")
            var now: TimeInterval = 0, effects = 0
            var editor = ComputerUseTextEditor(read: { field.snapshot }, select: { _, _ in effects += 1; return true },
                replaceSelectedText: { _, _ in effects += 1; return true }, postUnicode: { _, _ in effects += 1 }, mayAct: { field.allowed })
            editor.replaceValue = { _, _ in effects += 1; return true }
            editor.uptime = { now }
            editor.validateContext = {
                switch reason {
                case "target": field.id = "different-field"
                case "selection": field.selection = NSRange(location: 0, length: 0)
                case "deadline": now = 61
                default: field.allowed = false
                }
            }
            do { try await editor.edit("new", mode: .replaceAll, expected: field.snapshot); XCTFail("A stale context read cannot authorize a setter") }
            catch {
                let expected: ComputerUseTextEditError = reason == "deadline" ? .deadlineExceeded : reason == "takeover" ? .interrupted : .preconditionChanged
                XCTAssertEqual(error as? ComputerUseTextEditError, expected)
            }
            XCTAssertEqual(effects, 0); XCTAssertEqual(field.value, "old")
        }
    }

    func testNativeFocusAndSelectionSideEffectsStopLiteralAndCopyBeforeText() async throws {
        for stage in ["focus", "selection"] {
            for copy in [false, true] {
                let fields = NativeFields(setter: .selected)
                let mutate: () -> Void = { [weak fields] in fields?.setValue(copy ? "source" : "retained", "changed") }
                if stage == "focus" { fields.afterFocus = mutate } else { fields.afterSelection = mutate }
                let planner = NativePlanner(operations: [copy
                    ? .copyField(sourceTargetID: "source", targetID: "destination", mode: .replaceAll)
                    : .enterText(.init(targetID: "destination", mode: .replaceAll, text: "Paris"))])
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let executor = ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("Unexpected Unicode event") }),
                    mayAct: { true }, journalDirectory: directory, planner: planner, nativeTarget: fields)
                do { _ = try await executor.execute(taskID: "native-context", prompt: "Apply the requested form edits", progress: { _ in }); XCTFail("Focus/selection changed a required value") }
                catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
                do { _ = try await executor.execute(taskID: "native-context", prompt: "Apply the requested form edits", progress: { _ in }); XCTFail("An uncertain edit must not replay") } catch {}
                XCTAssertTrue(fields.edits.isEmpty); XCTAssertEqual(fields.values["destination"], "old")
                XCTAssertEqual(fields.focusCalls, 1); XCTAssertEqual(planner.calls, 1)
                let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "native-context"))
                XCTAssertEqual(journal.statuses, [.uncertain])
            }
        }
    }

    func testNativeUnicodeStopsAtChangedFocusOrRequirementAndReleasesThePendingKey() async throws {
        for reason in ["focus", "source", "unchanged"] {
            let fields = NativeFields(setter: .unicode)
            let events = PacedEventCounts()
            let injector = InputInjector(eventPoster: { _ = events.record($0.type) })
            var changed = false
            fields.beforeRead = { [weak fields] in
                guard let fields, events.counts.down > 0, !changed else { return }
                changed = true
                if reason == "focus" { fields.focusedID = "other" }
                else { fields.setValue(reason == "source" ? "source" : "retained", "changed") }
            }
            let planner = NativePlanner(operations: [reason == "source"
                ? .copyField(sourceTargetID: "source", targetID: "destination", mode: .replaceAll)
                : .enterText(.init(targetID: "destination", mode: .replaceAll, text: "Paris"))])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = ComputerUseNativeTextExecutor(injector: injector, mayAct: { true }, journalDirectory: directory,
                planner: planner, nativeTarget: fields)
            do { _ = try await executor.execute(taskID: "native-keys", prompt: "Apply the requested form edits", progress: { _ in }); XCTFail("The first key invalidated further input") }
            catch {
                if reason == "focus" { XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain) }
                else { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
            }
            XCTAssertTrue(changed); XCTAssertEqual(events.counts.down, 1); XCTAssertEqual(events.counts.up, 1)
            do { _ = try await executor.execute(taskID: "native-keys", prompt: "Apply the requested form edits", progress: { _ in }); XCTFail("No replay after partial Unicode input") } catch {}
            XCTAssertEqual(events.counts.down, 1); XCTAssertEqual(events.counts.up, 1)
            XCTAssertTrue(fields.edits.isEmpty, "Only the recorded CGEvent path was attempted")
            let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "native-keys"))
            XCTAssertEqual(journal.statuses, [.uncertain])
        }
    }

    func testNativeDispatchPreservesTargetsAcrossCopiesRepeatedEditsAndUnrelatedReads() async throws {
        for setter in [NativeFields.Setter.whole, .selected] {
            let fields = NativeFields(setter: setter)
            fields.afterInput = { [weak fields] in fields?.setValue("other", "freely changed") }
            let planner = NativePlanner(operations: [
                .enterText(.init(targetID: "source", mode: .replaceAll, text: "Tokyo")),
                .copyField(sourceTargetID: "source", targetID: "destination", mode: .replaceAll),
                .copyField(sourceTargetID: "source", targetID: "source", mode: .append),
                .enterText(.init(targetID: "source", mode: .append, text: "!")),
                .enterText(.init(targetID: "source", mode: .append, text: "!"))])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("AX input must not emit keys") }),
                mayAct: { true }, journalDirectory: directory, planner: planner, nativeTarget: fields)
            for _ in 0..<2 {
                let result = try await executor.execute(taskID: "native-chain", prompt: "Apply the requested form edits", progress: { _ in })
                guard case .completed = result else { return XCTFail("Every intended native edit must verify") }
            }
            XCTAssertEqual(fields.edits, ["source=Tokyo", "destination=Tokyo", "source=TokyoTokyo", "source=TokyoTokyo!", "source=TokyoTokyo!!"])
            XCTAssertEqual(fields.values, ["source": "TokyoTokyo!!", "destination": "Tokyo", "retained": "keep", "other": "freely changed"])
            XCTAssertEqual(fields.focusCalls, 5); XCTAssertEqual(planner.calls, 1)
            let journal = try XCTUnwrap(try ComputerUseTextStepStore(directory: directory).load(taskID: "native-chain"))
            XCTAssertEqual(journal.statuses, Array(repeating: .verified, count: 5))
        }
    }

    @MainActor private final class NativePlanner: ComputerUseTextGoalPlanning {
        let operations: [ComputerUseTextGoalOperation]
        var calls = 0
        init(operations: [ComputerUseTextGoalOperation]) { self.operations = operations }
        func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
            calls += 1
            return .fieldOperations(operations, unchangedTargetIDs: ["retained"])
        }
    }

    @MainActor private final class NativeFields: ComputerUseNativeTextTarget {
        enum Setter: Equatable { case whole, selected, unicode }
        let setter: Setter
        var values = ["source": "Paris", "destination": "old", "retained": "keep", "other": "free"]
        var selections: [String: NSRange] = [:]
        var secureIDs = Set<String>(), readOnlyIDs = Set<String>()
        var focusedID = "destination", focusCalls = 0
        var edits: [String] = []
        var beforeRead: (() -> Void)?, afterFocus: (() -> Void)?, afterSelection: (() -> Void)?, afterInput: (() -> Void)?
        init(setter: Setter) { self.setter = setter }
        func fields() -> [ComputerUseTextField] {
            ["source", "destination", "retained", "other"].compactMap { id in
                snapshot(targetID: id).map { .init(label: id.capitalized, snapshot: $0) }
            }
        }
        func snapshot() -> ComputerUseTextSnapshot? {
            beforeRead?()
            return snapshot(targetID: focusedID)
        }
        func snapshot(targetID: String) -> ComputerUseTextSnapshot? {
            beforeRead?()
            guard let value = values[targetID] else { return nil }
            return .init(targetID: targetID, value: value, selection: selections[targetID] ?? NSRange(location: value.utf16.count, length: 0),
                isEditable: !readOnlyIDs.contains(targetID), isSecure: secureIDs.contains(targetID))
        }
        func focus(expected: ComputerUseTextSnapshot) throws -> Bool {
            guard snapshot(targetID: expected.targetID) == expected else { throw ComputerUseTextEditError.preconditionChanged }
            focusedID = expected.targetID; focusCalls += 1; afterFocus?(); return true
        }
        func select(_ range: NSRange, expected: ComputerUseTextSnapshot) throws -> Bool {
            try require(expected); selections[expected.targetID] = range; afterSelection?(); return true
        }
        func replaceSelectedText(_ text: String, expected: ComputerUseTextSnapshot) throws -> Bool? {
            try require(expected)
            guard setter == .selected else { return nil }
            guard let range = Range(expected.selection, in: expected.value) else { throw ComputerUseTextEditError.invalidSelection }
            apply(expected.value.replacingCharacters(in: range, with: text), targetID: expected.targetID)
            return true
        }
        func replaceWebValue(_ value: String, expected: ComputerUseTextSnapshot) throws -> Bool? {
            try require(expected)
            guard setter == .whole else { return nil }
            apply(value, targetID: expected.targetID); return true
        }
        func setValue(_ id: String, _ value: String) {
            values[id] = value; selections[id] = NSRange(location: value.utf16.count, length: 0)
        }
        func receiveUnicode(_ text: String) {
            let value = values[focusedID]!
            let selection = selections[focusedID] ?? NSRange(location: value.utf16.count, length: 0)
            let range = Range(selection, in: value)!
            values[focusedID] = value.replacingCharacters(in: range, with: text)
            selections[focusedID] = NSRange(location: selection.location + text.utf16.count, length: 0)
        }
        private func require(_ expected: ComputerUseTextSnapshot) throws {
            guard snapshot() == expected else { throw ComputerUseTextEditError.preconditionChanged }
        }
        private func apply(_ value: String, targetID: String) {
            setValue(targetID, value); edits.append(targetID + "=" + value); afterInput?()
        }
    }

    func testEmptyUnicodeFallbackCannotClaimInputButSupportedSetterCan() async throws {
        for mode in [ComputerUseTextEditMode.insert, .replaceAll, .append] {
            let field = Field()
            await assertError(.selectionUnsupported) {
                try await field.editor.edit("", mode: mode, expected: field.snapshot)
            }
            XCTAssertTrue(field.posted.isEmpty); XCTAssertEqual(field.axAttempts, 0)
            field.axSupported = true
            try await field.editor.edit("", mode: mode, expected: field.snapshot)
            XCTAssertEqual(field.axAttempts, 1); XCTAssertTrue(field.posted.isEmpty)
        }
    }

    @MainActor private final class Field {
        var id = "app-launch/window/document/field"
        var value: String
        var selection: NSRange
        var secure = false
        var allowed = true
        var axSupported = false
        var axAttempts = 0
        var posted: [String] = []
        var afterPost: (() -> Void)?
        var delivery: ((String) -> String)?
        init(_ value: String = "", selection: NSRange? = nil) {
            self.value = value
            self.selection = selection ?? NSRange(location: value.utf16.count, length: 0)
        }
        var snapshot: ComputerUseTextSnapshot {
            ComputerUseTextSnapshot(targetID: id, value: value, selection: selection,
                                   isEditable: true, isSecure: secure)
        }
        func insert(_ text: String) {
            let range = Range(selection, in: value)!
            value.replaceSubrange(range, with: text)
            selection = NSRange(location: selection.location + text.utf16.count, length: 0)
        }
        var editor: ComputerUseTextEditor {
            var editor = ComputerUseTextEditor(
                read: { self.snapshot },
                select: { range, _ in self.selection = range; return true },
                replaceSelectedText: { text, _ in
                    guard self.axSupported else { return nil }
                    self.axAttempts += 1
                    self.insert(self.delivery?(text) ?? text)
                    return true
                },
                postUnicode: { text, _ in
                    self.posted.append(text)
                    self.insert(self.delivery?(text) ?? text)
                    self.afterPost?()
                },
                mayAct: { self.allowed })
            editor.wait = { await Task.yield() }
            editor.verificationAttempts = 3
            return editor
        }
    }

    func testSlowPreflightCannotStartMutationAfterDeadline() async throws {
        let field = Field("old")
        var now: TimeInterval = 0
        var editor = ComputerUseTextEditor(
            read: { now = 11; return field.snapshot },
            select: { _, _ in XCTFail("Expired selection mutation"); return true },
            replaceSelectedText: { _, _ in XCTFail("Expired text mutation"); return true },
            postUnicode: { _, _ in XCTFail("Expired Unicode input") }, mayAct: { true })
        editor.maximumDuration = 10
        editor.uptime = { now }
        editor.replaceValue = { _, _ in XCTFail("Expired whole-value mutation"); return true }
        do { try await editor.edit("new", mode: .replaceAll, expected: field.snapshot); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .deadlineExceeded) }
        XCTAssertEqual(field.value, "old")
    }

    func testExactWhitespaceUnicodeAndLongTextSurviveVerifiedChunks() async throws {
        let payload = "  \n東京 e\u{301} 👨‍👩‍👧‍👦 😀\n" + String(repeating: "x", count: 2_000) + "\n  "
        let field = Field()
        try await field.editor.edit(payload, expected: field.snapshot)
        XCTAssertTrue(field.value.utf8.elementsEqual(payload.utf8))
        XCTAssertTrue(field.posted.joined().utf8.elementsEqual(payload.utf8))
        XCTAssertTrue(field.posted.allSatisfy { $0.count == 1 })
    }

    func testInsertReplaceAndAppendHaveDistinctVerifiedResults() async throws {
        let field = Field("hello world", selection: NSRange(location: 6, length: 5))
        try await field.editor.edit("earth", expected: field.snapshot)
        XCTAssertEqual(field.value, "hello earth")
        try await field.editor.edit("new", mode: .replaceAll, expected: field.snapshot)
        XCTAssertEqual(field.value, "new")
        field.selection = NSRange(location: 0, length: 0)
        try await field.editor.edit(" tail", mode: .append, expected: field.snapshot)
        XCTAssertEqual(field.value, "new tail")
    }

    func testSameValueCanBeEnteredIntoTwoDistinctFields() async throws {
        let origin = Field()
        let destination = Field()
        destination.id = "another-field"
        for field in [origin, destination] {
            try await field.editor.edit("San Francisco", expected: field.snapshot)
        }
        XCTAssertEqual(origin.value, destination.value)
        XCTAssertFalse(origin.posted.isEmpty)
        XCTAssertFalse(destination.posted.isEmpty)
    }

    func testDroppedInputIsUncertainAndNeverReplayed() async throws {
        let field = Field()
        field.delivery = { String($0.dropLast()) }
        await assertError(.deliveryUncertain) {
            try await field.editor.edit(String(repeating: "a", count: 80), expected: field.snapshot)
        }
        XCTAssertEqual(field.posted.count, 1)
        XCTAssertTrue(field.value.isEmpty)
    }

    func testAutoCorrectionDivergenceIsNotReportedAsSuccess() async throws {
        let field = Field()
        field.delivery = { _ in "corrected" }
        await assertError(.deliveryUncertain) {
            try await field.editor.edit("literal", expected: field.snapshot)
        }
        XCTAssertEqual(field.posted, ["l"])
    }

    func testPauseAfterFirstChunkStopsBeforeAnySecondChunk() async throws {
        let field = Field()
        field.afterPost = { field.allowed = false }
        await assertError(.interrupted) {
            try await field.editor.edit(String(repeating: "a", count: 80), expected: field.snapshot)
        }
        XCTAssertEqual(field.value.count, 1)
        XCTAssertEqual(field.posted.count, 1)
    }

    func testTargetReplacementDuringEditDoesNotTypeIntoNewField() async throws {
        let field = Field()
        field.afterPost = { field.id = "new-document-same-position" }
        await assertError(.deliveryUncertain) {
            try await field.editor.edit(String(repeating: "a", count: 80), expected: field.snapshot)
        }
        XCTAssertEqual(field.posted.count, 1)
    }

    func testChangedInitialValueOrSelectionRejectsBeforeInput() async throws {
        let field = Field("original")
        let initial = field.snapshot
        field.selection = NSRange(location: 0, length: 0)
        await assertError(.preconditionChanged) {
            try await field.editor.edit("text", expected: initial)
        }
        field.value = "changed"
        await assertError(.preconditionChanged) {
            try await field.editor.edit("text", expected: initial)
        }
        XCTAssertTrue(field.posted.isEmpty)
    }

    func testOversizedAndProtectedPayloadsRejectBeforeInput() async throws {
        let field = Field()
        await assertError(.payloadTooLarge) {
            try await field.editor.edit(String(repeating: "a", count: 65_537), expected: field.snapshot)
        }
        field.secure = true
        await assertError(.secureTarget) {
            try await field.editor.edit("protected", expected: field.snapshot)
        }
        XCTAssertTrue(field.posted.isEmpty)
        XCTAssertEqual(field.axAttempts, 0)
    }

    func testAXEditIsReadBackWithoutPostingUnicode() async throws {
        let field = Field("replace me", selection: NSRange(location: 0, length: 10))
        field.axSupported = true
        try await field.editor.edit("  exact\n", expected: field.snapshot)
        XCTAssertEqual(field.value, "  exact\n")
        XCTAssertEqual(field.axAttempts, 1)
        XCTAssertTrue(field.posted.isEmpty)
    }

    func testFailedAXDeliveryNeverFallsBackToDuplicateUnicode() async throws {
        let field = Field()
        field.axSupported = true
        field.delivery = { String($0.prefix(2)) }
        await assertError(.deliveryUncertain) {
            try await field.editor.edit("longer", expected: field.snapshot)
        }
        XCTAssertEqual(field.axAttempts, 1)
        XCTAssertTrue(field.posted.isEmpty)
        XCTAssertEqual(field.value, "lo")
    }

    func testHostVerifiedActionPropagatesMissingInputInsteadOfSuccess() async throws {
        let field = Field()
        field.delivery = { _ in "" }
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { _ in XCTFail("No live input") }),
            mayAct: { true }, textEditor: field.editor)
        await assertError(.deliveryUncertain) {
            try await tools.performVerified(.typeText("hello"))
        }
    }

    func testApprovalTextDigestChangesForSelectionContentAndDocument() {
        let field = Field("text")
        let initial = field.snapshot.preconditionDigest
        field.selection = NSRange(location: 0, length: 0)
        XCTAssertNotEqual(initial, field.snapshot.preconditionDigest)
        field.value = "other"
        XCTAssertNotEqual(initial, field.snapshot.preconditionDigest)
        field.id = "other document"
        XCTAssertNotEqual(initial, field.snapshot.preconditionDigest)
    }

    func testAccessibilitySetterCannotStartAfterTakeoverClosesInputGate() throws {
        let injector = InputInjector(eventPoster: { _ in XCTFail("No native events") })
        var allowed = true
        var effects = 0
        try injector.performHostEffectIfAllowed(ifAllowed: { allowed }) { effects += 1 }
        XCTAssertTrue(injector.interruptAutomation { allowed = false; return true })
        XCTAssertThrowsError(try injector.performHostEffectIfAllowed(ifAllowed: { allowed }) {
            effects += 1
        })
        XCTAssertEqual(effects, 1)
    }

    func testHostBrowserCommandRechecksGateBeforePostingAndReleasesKey() throws {
        let events = HostCommandEventProbe()
        let injector = InputInjector(eventPoster: { events.record($0.type) })

        XCTAssertThrowsError(try injector.applyHostKeyStroke(usage: 0x0F, modifiers: 1 << 3,
            ifAllowed: { events.isAllowed }, beforePosting: { events.closeGate() }))
        XCTAssertEqual(events.counts.down, 0, "A gate revoked at the final boundary must post no key")
        XCTAssertEqual(events.counts.up, 0)

        events.openGate()
        try injector.applyHostKeyStroke(usage: 0x0F, modifiers: 1 << 3,
            ifAllowed: { events.isAllowed }, beforePosting: {})
        XCTAssertEqual(events.counts.down, 1)
        XCTAssertEqual(events.counts.up, 1, "A host command posts one complete, released keystroke")

        events.closeGateOnNextDown()
        events.openGate()
        try injector.applyHostKeyStroke(usage: 0x0F, modifiers: 1 << 3,
            ifAllowed: { events.isAllowed }, beforePosting: {})
        XCTAssertEqual(events.counts.down, 2)
        XCTAssertEqual(events.counts.up, 2, "Key-up must still post if the gate closes after key-down")
        XCTAssertFalse(events.isAllowed)
    }

    func testWholeValueSetterFailureNeverFallsBackToAnotherEffect() async {
        let field = Field("original")
        field.axSupported = true
        var editor = field.editor
        editor.replaceValue = { _, _ in field.value = "partial"; return false }
        await assertError(.deliveryUncertain) {
            try await editor.edit("complete", mode: .replaceAll, expected: field.snapshot)
        }
        XCTAssertEqual(field.axAttempts, 0)
        XCTAssertTrue(field.posted.isEmpty)
    }

    func testTextDeadlineStopsAfterCurrentAttemptWithoutReplayingIt() async {
        let field = Field()
        var now: TimeInterval = 0
        var editor = field.editor
        editor.uptime = { now }
        field.afterPost = { now = 61 }
        await assertError(.deadlineExceeded) {
            try await editor.edit(String(repeating: "x", count: 100), expected: field.snapshot)
        }
        XCTAssertEqual(field.posted.count, 1)
        XCTAssertEqual(field.value.count, 1)
    }

    func testPacedUnicodeTakeoverReleasesStrokeAndStartsNoFurtherKey() async {
        let began = expectation(description: "A Unicode key started")
        let events = PacedEventCounts()
        let injector = InputInjector(eventPoster: { event in
            if events.record(event.type) == 1 { began.fulfill() }
        })
        var allowed = true
        let task = Task { await injector.applyTextPaced(String(repeating: "x", count: 100), ifAllowed: { allowed }) }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(injector.interruptAutomation { allowed = false; return true })
        let closed = events.counts
        let completed = await task.value
        XCTAssertFalse(completed)
        XCTAssertEqual(events.counts.down, closed.down)
        XCTAssertEqual(events.counts.up, closed.up)
        XCTAssertEqual(events.counts.down, events.counts.up)
    }

    private func assertError(
        _ expected: ComputerUseTextEditError,
        file: StaticString = #filePath, line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ComputerUseTextEditError, expected, file: file, line: line)
        }
    }
}

private final class PacedEventCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var down = 0
    private var up = 0
    func record(_ type: CGEventType) -> Int {
        lock.lock(); defer { lock.unlock() }
        if type == .keyDown { down += 1 }
        if type == .keyUp { up += 1 }
        return down + up
    }
    var counts: (down: Int, up: Int) {
        lock.lock(); defer { lock.unlock() }
        return (down, up)
    }
}

private final class HostCommandEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var closeOnDown = false
    private var down = 0
    private var up = 0

    var isAllowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed
    }
    var counts: (down: Int, up: Int) {
        lock.lock(); defer { lock.unlock() }
        return (down, up)
    }
    func openGate() {
        lock.lock(); defer { lock.unlock() }
        allowed = true
    }
    func closeGate() {
        lock.lock(); defer { lock.unlock() }
        allowed = false
    }
    func closeGateOnNextDown() {
        lock.lock(); defer { lock.unlock() }
        closeOnDown = true
    }
    func record(_ type: CGEventType) {
        lock.lock(); defer { lock.unlock() }
        if type == .keyDown {
            down += 1
            if closeOnDown { allowed = false; closeOnDown = false }
        } else if type == .keyUp {
            up += 1
        }
    }
}

private final class UnicodeStrokeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var down: [String] = [], up: [String] = []
    func record(_ event: CGEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return }
        var count = 0, units = [UniChar](repeating: 0, count: 128)
        units.withUnsafeMutableBufferPointer {
            event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count, unicodeString: $0.baseAddress)
        }
        let text = String(decoding: units.prefix(count), as: UTF16.self)
        lock.lock(); defer { lock.unlock() }
        if event.type == .keyDown { down.append(text) } else { up.append(text) }
    }
    var downTexts: [String] { lock.lock(); defer { lock.unlock() }; return down }
    var upTexts: [String] { lock.lock(); defer { lock.unlock() }; return up }
}
