import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextEditorTests: XCTestCase {
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
            XCTAssertEqual(field.value, stage == "first-chunk" ? "1234567890123456" : "old")
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
                isEditable: true, isSecure: false)
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
        XCTAssertEqual(field.value, payload)
        XCTAssertEqual(field.posted.joined(), payload)
        XCTAssertTrue(field.posted.allSatisfy { $0.count <= 16 })
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
        XCTAssertEqual(field.value.count, 15)
    }

    func testAutoCorrectionDivergenceIsNotReportedAsSuccess() async throws {
        let field = Field()
        field.delivery = { _ in "corrected" }
        await assertError(.deliveryUncertain) {
            try await field.editor.edit("literal", expected: field.snapshot)
        }
        XCTAssertEqual(field.posted, ["literal"])
    }

    func testPauseAfterFirstChunkStopsBeforeAnySecondChunk() async throws {
        let field = Field()
        field.afterPost = { field.allowed = false }
        await assertError(.interrupted) {
            try await field.editor.edit(String(repeating: "a", count: 80), expected: field.snapshot)
        }
        XCTAssertEqual(field.value.count, 16)
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
        XCTAssertEqual(field.value.count, 16)
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
