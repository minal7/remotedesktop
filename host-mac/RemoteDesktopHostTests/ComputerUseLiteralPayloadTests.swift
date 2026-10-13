import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseLiteralPayloadTests: XCTestCase {
    func testPreservesWhitespaceNewlinesAndBackslashesExactly() throws {
        let text = "  \nTokyo 東京 e\u{301} 😀 \\path\n  "
        let payload = try XCTUnwrap(ComputerUseLiteralPayload.singleQuotedPayload(
            in: "Type \"\(text)\" into the focused field."))
        XCTAssertEqual(payload.text, text)
    }

    func testAmbiguousMultipleQuotesAreNotSilentlyAssignedToTheWrongField() {
        XCTAssertNil(ComputerUseLiteralPayload.singleQuotedPayload(
            in: "Click \"Name\" then type \"Seattle\"."))
        XCTAssertNil(ComputerUseLiteralPayload.singleQuotedPayload(in: "Type \"unfinished"))
    }

    func testTrailingPathSeparatorAndNestedStraightQuotesRemainLiteral() throws {
        XCTAssertEqual(ComputerUseLiteralPayload.singleQuotedPayload(in: "Type \"C:\\\".")?.text, "C:\\")
        XCTAssertEqual(ComputerUseLiteralPayload.singleQuotedPayload(in: "Type “He said \"hello\".”.")?.text,
                       "He said \"hello\".")
    }

    func testReferenceCannotResolveAgainstAnotherTaskOrTruncatedPrefix() throws {
        let task = "Type \"\(String(repeating: "x", count: 2_000))\"."
        let payload = try XCTUnwrap(ComputerUseLiteralPayload.singleQuotedPayload(in: task))
        XCTAssertEqual(ComputerUseLiteralPayload.resolve(payload.id, in: task)?.count, 2_000)
        XCTAssertNil(ComputerUseLiteralPayload.resolve(payload.id, in: "Type \"different\"."))
        XCTAssertNil(ComputerUseLiteralPayload.resolve(String(payload.id.prefix(50)), in: task))
    }


}
