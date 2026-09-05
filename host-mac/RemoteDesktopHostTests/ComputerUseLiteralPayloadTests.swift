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

    func testLongExactTextUsesHostReferenceWithoutRelaxingModelTextLimit() throws {
        let text = String(repeating: "a", count: 2_000)
        let task = "Type \"\(text)\" into the focused field."
        let route = try XCTUnwrap(AppleFoundationVisualActionRouter.deterministicTextEntryRoute(
            for: task, history: [], availableDirectives: [.type]))
        guard case .literalTextReference(let id) = route.argument else {
            return XCTFail("A long literal must travel by reference")
        }
        XCTAssertEqual(ComputerUseLiteralPayload.resolve(id, in: task), text)
        XCTAssertFalse(SemanticNativeToolWireContract.isValidModelGeneratedText(text))
    }

    func testShortQuotedRoutePreservesLeadingAndTrailingWhitespace() throws {
        let text = "  exact\n  "
        let route = AppleFoundationVisualActionRouter.deterministicTextEntryRoute(
            for: "Type \"\(text)\" into the field.", history: [], availableDirectives: [.type])
        XCTAssertEqual(route?.argument, .text(text))
    }

    func testWhitespaceOnlyLiteralIsAHostPayload() throws {
        let task = "Insert \"  \n\" into the field."
        let route = try XCTUnwrap(AppleFoundationVisualActionRouter.deterministicTextEntryRoute(
            for: task, history: [], availableDirectives: [.type]))
        guard case .literalTextReference(let id) = route.argument else {
            return XCTFail("Exact whitespace must not disappear")
        }
        XCTAssertEqual(ComputerUseLiteralPayload.resolve(id, in: task), "  \n")
    }
}
