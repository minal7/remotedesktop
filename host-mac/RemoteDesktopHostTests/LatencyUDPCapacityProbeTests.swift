#if DEBUG
import CryptoKit
import XCTest
@testable import RemoteDesktopHost

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

#if DEBUG
private final class CapacityFakeMappingToken: HostPortMappingToken {
    let canceled: () -> Void
    init(_ canceled: @escaping () -> Void) { self.canceled = canceled }
    func cancel() { canceled() }
}

extension LatencyUDPCapacityProbeTests {
    func testHandshakeRequiresFreshChallengeAndRejectsReplayAndExpiry() throws {
        let client = Data(repeating: 1, count: 16), server = Data(repeating: 2, count: 16)
        var state = LatencyUDPCapacityHandshake(startedAt: 100)
        XCTAssertFalse(state.permitsLoad(now: 101))
        XCTAssertFalse(state.confirm(client, now: 101))
        let pair = try XCTUnwrap(state.challenge(client: client, server: server, now: 101))
        XCTAssertNil(state.challenge(client: client, server: server, now: 102))
        XCTAssertFalse(state.confirm(Data(repeating: 3, count: 32), now: 102))
        XCTAssertTrue(state.confirm(pair, now: 102))
        XCTAssertFalse(state.confirm(pair, now: 103))
        XCTAssertTrue(state.permitsLoad(now: 201.9))
        XCTAssertFalse(state.permitsLoad(now: 202))
        var expired = LatencyUDPCapacityHandshake(startedAt: 100)
        XCTAssertNil(expired.challenge(client: client, server: server, now: 110))
    }

    func testWallRateUsesElapsedStepTimeEvenWhenSenderStalls() {
        XCTAssertEqual(LatencyUDPCapacitySender.wallActiveSeconds(authenticatedAt: 100, step: 0, now: 113), 3)
        XCTAssertEqual(LatencyUDPCapacitySender.wallActiveSeconds(authenticatedAt: 100, step: 0, now: 130), 15)
        XCTAssertEqual(LatencyUDPCapacitySender.wallActiveSeconds(authenticatedAt: 100, step: 1, now: 125), 0)
    }

    func testEchoPhaseSeparatesBaselineLoadAndCooldown() {
        XCTAssertEqual(LatencyUDPCapacitySender.echoPhase(step: -1, phase: -0.1), 0)
        XCTAssertEqual(LatencyUDPCapacitySender.echoPhase(step: 0, phase: 14.9), 1)
        XCTAssertEqual(LatencyUDPCapacitySender.echoPhase(step: 0, phase: 15), 2)
        XCTAssertEqual(LatencyUDPCapacitySender.echoPhase(step: 1, phase: 16), 1)
    }

    func testEchoRowsRetainOnlyValidHostTimesAndRtt() throws {
        let reply = try XCTUnwrap(LatencyUDPCapacitySender.echoRecord(t0: 100, t1: 100.025))
        XCTAssertEqual(reply["t0HostS"], 100)
        XCTAssertEqual(reply["t1HostS"], 100.025)
        XCTAssertEqual(try XCTUnwrap(reply["rttMs"]), 25, accuracy: 0.001)
        let missing = try XCTUnwrap(LatencyUDPCapacitySender.echoRecord(t0: 101, t1: nil))
        XCTAssertNil(missing["rttMs"])
        XCTAssertNil(LatencyUDPCapacitySender.echoRecord(t0: 101, t1: 100))
        XCTAssertNil(LatencyUDPCapacitySender.echoRecord(t0: .nan, t1: nil))
    }

    func testStaleOrOutstandingCountersCannotClaimLoss() {
        XCTAssertNil(LatencyUDPCapacitySender.lossThroughFinalSnapshot(sent: 100, received: 90, finalSnapshot: false, inFlight: 0))
        XCTAssertNil(LatencyUDPCapacitySender.lossThroughFinalSnapshot(sent: 100, received: 90, finalSnapshot: true, inFlight: 1))
        XCTAssertNil(LatencyUDPCapacitySender.lossThroughFinalSnapshot(sent: 100, received: 101, finalSnapshot: true, inFlight: 0))
        XCTAssertEqual(LatencyUDPCapacitySender.lossThroughFinalSnapshot(sent: 100, received: 90, finalSnapshot: true, inFlight: 0), 10)
    }

    func testMappingReleasedExactlyOnceIncludingLateAdoption() {
        let released = expectation(description: "both owned mapping tokens released")
        released.expectedFulfillmentCount = 2
        let first = CapacityFakeMappingToken { released.fulfill() }
        let late = CapacityFakeMappingToken { released.fulfill() }
        let lease = LatencyUDPCapacityMappingLease()
        lease.adopt(first); lease.close(); lease.close(); lease.adopt(late)
        wait(for: [released], timeout: 2)
    }

    func testStopBeforeStartCompletesOnceWithoutNetworking() throws {
        let done = expectation(description: "sender stopped once")
        let lock = NSLock(); var completions = 0
        var sender: LatencyUDPCapacitySender? = try XCTUnwrap(LatencyUDPCapacitySender(lanAddress: "unused", offer: { _ in }, requestSnapshot: {}, completion: { _ in
            lock.lock(); completions += 1; lock.unlock(); done.fulfill()
        }))
        sender?.stop(); sender?.stop(); sender = nil
        wait(for: [done], timeout: 2)
        lock.lock(); let observed = completions; lock.unlock()
        XCTAssertEqual(observed, 1)
    }
}
#endif
