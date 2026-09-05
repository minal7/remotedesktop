import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextEditorTests: XCTestCase {
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
                select: { self.selection = $0; return true },
                replaceSelectedText: { text in
                    guard self.axSupported else { return nil }
                    self.axAttempts += 1
                    self.insert(self.delivery?(text) ?? text)
                    return true
                },
                postUnicode: { text in
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
