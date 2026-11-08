#if DEBUG
import XCTest
@testable import RemoteDesktop

final class LatencyClockEstimateTests: XCTestCase {
    func testRequiresFiftyFiniteSamplesAndUsesLowestRTTQuartile() throws {
        let low = (0..<13).map { _ in (rtt: 0.010, offset: 2.0) }
        let high = (0..<37).map { _ in (rtt: 0.100, offset: 9.0) }
        XCTAssertNil(LatencyClockEstimate.calculate(Array((low + high).dropLast())))
        let estimate = try XCTUnwrap(LatencyClockEstimate.calculate(high + low))
        XCTAssertEqual(estimate.offset, 2, accuracy: 0.000001)
        XCTAssertEqual(estimate.rtt, 0.010, accuracy: 0.000001)
        XCTAssertEqual(estimate.uncertainty, 0.005, accuracy: 0.000001)
        XCTAssertNil(LatencyClockEstimate.calculate(low + Array(high.dropLast()) + [(rtt: .nan, offset: 0)]))
    }
}
#endif
