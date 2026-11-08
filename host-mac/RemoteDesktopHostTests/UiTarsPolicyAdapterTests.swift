import Foundation
import XCTest
@testable import RemoteDesktopHost

final class UiTarsPolicyAdapterTests: XCTestCase {
    func testScrollAcceptsReorderedNativeKeywordsAndKeepsFactor28Mapping() throws {
        let action = try canonicalAction("scroll(direction='down', start_box='(610,314)')")
        XCTAssertEqual(action["type"] as? String, "scroll")
        XCTAssertEqual(action["direction"] as? String, "down")
        XCTAssertEqual(action["amount"] as? Int, 400)
        let target = try XCTUnwrap(action["target"] as? [String: Double])
        XCTAssertEqual(target["x"]!, 610.0 / 1288.0 * 1280.0, accuracy: 0.000001)
        XCTAssertEqual(target["y"]!, 314.0 / 812.0 * 800.0, accuracy: 0.000001)
    }

    func testDragAcceptsReversedEndpointsWithoutSwappingTheirMeanings() throws {
        let action = try canonicalAction("drag(end_box='(900,600)', start_box='(100,200)')")
        XCTAssertEqual(action["type"] as? String, "drag")
        let from = try XCTUnwrap(action["from"] as? [String: Double])
        let to = try XCTUnwrap(action["to"] as? [String: Double])
        XCTAssertEqual(from["x"]!, 100.0 / 1288.0 * 1280.0, accuracy: 0.000001)
        XCTAssertEqual(from["y"]!, 200.0 / 812.0 * 800.0, accuracy: 0.000001)
        XCTAssertEqual(to["x"]!, 900.0 / 1288.0 * 1280.0, accuracy: 0.000001)
        XCTAssertEqual(to["y"]!, 600.0 / 812.0 * 800.0, accuracy: 0.000001)
    }

    func testTypeAcceptsModeBeforeContentAndPreservesEscapedQuotesAndCommas() throws {
        let action = try canonicalAction(#"type(mode='replace', content='north, east and \'quoted\' text')"#)
        XCTAssertEqual(action["type"] as? String, "type")
        XCTAssertEqual(action["mode"] as? String, "replace")
        XCTAssertEqual(action["text"] as? String, "north, east and 'quoted' text")
    }

    func testFindFilesAcceptsAnyOrderAndKeepsQuotedPunctuationLiteral() throws {
        let action = try canonicalAction(#"find_files(modified_after='2026-10-12', kind='document', query='quarter, \'final\'')"#)
        XCTAssertEqual(action["type"] as? String, "find_files")
        XCTAssertEqual(action["modified_after"] as? String, "2026-10-12")
        XCTAssertEqual(action["kind"] as? String, "document")
        XCTAssertEqual(action["query"] as? String, "quarter, 'final'")
    }

    func testDuplicateUnknownAndExecutableArgumentsRemainRejected() throws {
        for line in [
            "scroll(direction='down', start_box='(610,314)', direction='up')",
            "scroll(direction='down', start_box='(610,314)', surprise='value')",
            "scroll(direction=__import__('os'), start_box='(610,314)')",
            "type(content='safe'); wait()",
        ] {
            XCTAssertThrowsError(try canonicalAction(line), line)
        }
        XCTAssertThrowsError(try UIActionTextParser.canonicalJSON(
            "Thought: act.\nAction: wait()\nAction: wait()", imageSize: (1280, 800)))
    }

    private func canonicalAction(_ line: String) throws -> [String: Any] {
        let encoded = try UIActionTextParser.canonicalJSON(
            "Thought: act.\nAction: \(line)", imageSize: (1280, 800))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
    }
}
