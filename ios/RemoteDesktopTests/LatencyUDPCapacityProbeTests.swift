#if DEBUG
import CryptoKit
import XCTest
@testable import RemoteDesktop

final class LatencyUDPCapacityProbeTests: XCTestCase {
    func testAuthenticatedPacketRoundTripAndTampering() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let packet = LatencyUDPCapacityWire.Packet(kind: .data, step: 4, sequence: 987,
                                                  body: Data(repeating: 3, count: 100))
        let bytes = try XCTUnwrap(LatencyUDPCapacityWire.encode(packet, key: key))
        XCTAssertEqual(LatencyUDPCapacityWire.decode(bytes, key: key), packet)
        var changed = bytes; changed[changed.startIndex + 20] ^= 1
        XCTAssertNil(LatencyUDPCapacityWire.decode(changed, key: key))
        XCTAssertNil(LatencyUDPCapacityWire.decode(bytes, key: SymmetricKey(data: Data(repeating: 8, count: 32))))
    }

    func testStopRetainsReceiverUntilCleanupAfterOwnerReleases() throws {
        let stopped = expectation(description: "receiver stopped")
        var receiver: LatencyUDPCapacityReceiver? = try XCTUnwrap(
            LatencyUDPCapacityReceiver(host: "127.0.0.1", port: 9,
                keyData: Data(repeating: 1, count: 32), progress: { _, _, _ in stopped.fulfill() }))
        receiver?.stop(); receiver = nil
        wait(for: [stopped], timeout: 2)
    }

    func testForegroundAdmissionRejectsBackgroundBeforeOffer() {
        XCTAssertTrue(LatencyUDPCapacityForegroundPolicy.permitsStart(isActive: true))
        XCTAssertFalse(LatencyUDPCapacityForegroundPolicy.permitsStart(isActive: false))
    }

    func testRepeatProfileIsBoundedAndExactlySpecified() {
        XCTAssertEqual(LatencyUDPCapacityWire.ratesMbps, [5, 6, 7, 8, 10])
        XCTAssertEqual(LatencyUDPCapacityWire.baselineSeconds, 10)
        XCTAssertEqual(LatencyUDPCapacityWire.stepSeconds, 15)
        XCTAssertEqual(LatencyUDPCapacityWire.cooldownSeconds, 1)
        XCTAssertEqual(LatencyUDPCapacityWire.maximumSessionSeconds, 100)
        XCTAssertLessThan(36 * 1_000_000 * 15 / 8, LatencyUDPCapacityWire.maximumPayloadBytes)
    }

    func testPacketBoundsFailClosed() {
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        let packet = LatencyUDPCapacityWire.Packet(kind: .data, step: 0, sequence: 0,
                                                  body: Data(repeating: 0, count: 1_200))
        XCTAssertNil(LatencyUDPCapacityWire.encode(packet, key: key))
        XCTAssertNil(LatencyUDPCapacityWire.decode(Data(repeating: 0, count: 1_201), key: key))
        XCTAssertNil(LatencyUDPCapacityWire.decode(Data(), key: key))
    }

    func testUniqueDuplicateReorderedAndLateAccounting() {
        var counters = LatencyUDPCapacityReceiveCounters()
        counters.record(step: 0, sequence: 5, byteCount: 100, activeStep: 0)
        counters.record(step: 0, sequence: 5, byteCount: 100, activeStep: 0)
        counters.record(step: 0, sequence: 3, byteCount: 100, activeStep: 1)
        XCTAssertEqual(counters.steps[0].unique, 2)
        XCTAssertEqual(counters.steps[0].duplicate, 1)
        XCTAssertEqual(counters.steps[0].reordered, 1)
        XCTAssertEqual(counters.steps[0].late, 1)
        XCTAssertEqual(counters.steps[0].bytes, 200)
    }
}
#endif
