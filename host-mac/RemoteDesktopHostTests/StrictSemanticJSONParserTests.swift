import XCTest
@testable import RemoteDesktopHost

final class StrictSemanticJSONParserTests: XCTestCase {
    func testParsedIndicesPreserveIntegerPrecisionAndRejectNonIntegralValues() throws {
        for (source, expected) in [("0", 0), ("2.0", 2), ("2e0", 2),
                                   ("9007199254740993", 9_007_199_254_740_993),
                                   (String(Int.max), Int.max)] {
            var parser = StrictSemanticJSONParser(source)
            XCTAssertEqual(try parser.parse().exactInteger, expected, source)
        }
        for source in ["0.5", "-1.5", "1e100", "true", "\"2\"", "null"] {
            var parser = StrictSemanticJSONParser(source)
            XCTAssertNil(try parser.parse().exactInteger, source)
        }
    }
}
