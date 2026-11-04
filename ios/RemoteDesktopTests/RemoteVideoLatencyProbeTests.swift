#if DEBUG
import CoreVideo
import XCTest
@testable import RemoteDesktop

final class RemoteVideoLatencyProbeTests: XCTestCase {
    @MainActor
    func testBatteryMonitoringLeasesSurviveOverlapAndRestorePriorState() {
        var enabled = false
        var writes: [Bool] = []
        let lease = LatencyBatteryMonitoringLease(get: { enabled }, set: { enabled = $0; writes.append($0) })
        let first = lease.acquire()
        let second = lease.acquire()
        lease.release(first)
        lease.release(first)
        XCTAssertTrue(enabled)
        lease.release(second)
        XCTAssertFalse(enabled)
        XCTAssertEqual(writes, [true, false])

        enabled = true
        let third = lease.acquire()
        lease.release(third)
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes, [true, false])
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1040, 512,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func paint(_ buffer: CVPixelBuffer, id: UInt16, badBit: Int? = nil, grayBit: Int? = nil) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        XCTAssertGreaterThan(stride, 1040)
        memset(base, 0, stride * CVPixelBufferGetHeightOfPlane(buffer, 0))
        let word = UInt32(id) | (UInt32(id ^ 0xffff) << 16)
        let cell = floor(1000.0 * 0.42 / 32)
        let y = 8 + Int(390.0 / 500 * 500)
        for bit in 0..<32 {
            let x = 16 + Int((36 + (Double(bit) + 0.5) * cell) / 1000 * 1000)
            let set = ((word >> bit) & 1 == 1) != (badBit == bit)
            let value: UInt8 = grayBit == bit ? 128 : (set ? 235 : 16)
            for dy in -1...1 { for dx in -1...1 { base[(y + dy) * stride + x + dx] = value } }
        }
    }

    private func sample(_ buffer: CVPixelBuffer, cropWidth: Int = 1000) -> Int? {
        RemoteVideoLatencyProbe.sampleMarker(pixelBuffer: buffer, cropX: 16, cropY: 8,
            cropWidth: cropWidth, cropHeight: 500, screenWidth: 1000, screenHeight: 500)
    }

    func testMarkerSamplingOffRequiresExplicitLabOptIn() {
        XCTAssertTrue(RemoteVideoLatencyProbe.markerSamplingEnabled(environment: [:]))
        XCTAssertTrue(RemoteVideoLatencyProbe.markerSamplingEnabled(environment: ["LATENCY_SKIP_MARKER_SAMPLING": "1"]))
        XCTAssertTrue(RemoteVideoLatencyProbe.markerSamplingEnabled(environment: ["LATENCY_LAB": "1", "LATENCY_SKIP_MARKER_SAMPLING": "true"]))
        XCTAssertFalse(RemoteVideoLatencyProbe.markerSamplingEnabled(environment: ["LATENCY_LAB": "1", "LATENCY_SKIP_MARKER_SAMPLING": "1"]))
    }

    func testRenderRecordIncludesOnlyFiniteOptionalPacingTimes() {
        let sample = RemoteVideoLatencyProbe().snapshot(decodedAt: 10, marker: 42)
        sample.acquisitionRequestedTime = 9.99
        sample.acquisitionReturnedTime = 10.01
        sample.receiptDeliveryTime = 10.04
        let record = RemoteVideoLatencyProbe.renderRecord(sample, submitted: 10.02, presented: 10.03)
        XCTAssertEqual(record["type"] as? String, "render")
        XCTAssertEqual(record["acquisitionRequestedTime"] as? Double, 9.99)
        XCTAssertEqual(record["acquisitionReturnedTime"] as? Double, 10.01)
        XCTAssertEqual(record["receiptDeliveryTime"] as? Double, 10.04)
        XCTAssertNil(record["marker"])
        sample.receiptDeliveryTime = .infinity
        XCTAssertNil(RemoteVideoLatencyProbe.renderRecord(sample, submitted: 10.02, presented: 10.03)["receiptDeliveryTime"])
    }

    func testSamplesCroppedPaddedNV12AndRejectsCorruption() throws {
        let buffer = try makeBuffer()
        try paint(buffer, id: 0x1234)
        XCTAssertEqual(sample(buffer), 0x1234)
        XCTAssertNil(sample(buffer, cropWidth: 2000))
        XCTAssertNil(RemoteVideoLatencyProbe.sampleMarker(pixelBuffer: buffer, cropX: 16, cropY: 8,
            cropWidth: 1000, cropHeight: 500, screenWidth: 0, screenHeight: 500))
        var bgra: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1040, 512,
            kCVPixelFormatType_32BGRA, nil, &bgra), kCVReturnSuccess)
        XCTAssertNil(sample(try XCTUnwrap(bgra)))
        try paint(buffer, id: 0x1234, badBit: 20)
        XCTAssertNil(sample(buffer))
        try paint(buffer, id: 0x1234, grayBit: 3)
        XCTAssertNil(sample(buffer))
        try paint(buffer, id: 0)
        XCTAssertNil(sample(buffer))
    }

    func testLateFrameCannotContaminateNewSession() {
        let probe = RemoteVideoLatencyProbe()
        let old = probe.snapshot(decodedAt: 1, marker: 7)
        old.submittedTime = 1.01
        XCTAssertTrue(probe.isCurrent(old))
        probe.reset()
        XCTAssertFalse(probe.isCurrent(old))
        probe.presented(old, time: 1.02)
        XCTAssertNil(probe.renderPercentiles())
        let current = probe.snapshot(decodedAt: 2, marker: 8)
        current.submittedTime = 2.01
        probe.presented(current, time: 2.02)
        XCTAssertEqual(probe.renderPercentiles()?.0 ?? -1, 20, accuracy: 0.001)
        XCTAssertFalse(probe.hasRecentMarker()) // A redrawn old decode is not a fresh fixture.
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = probe.snapshot(decodedAt: now, marker: 9)
        fresh.submittedTime = now + 0.001
        probe.presented(fresh, time: now + 0.002)
        XCTAssertTrue(probe.hasRecentMarker(now: now + 0.1))
        XCTAssertFalse(probe.hasRecentMarker(now: now + 0.6))
    }
    func testDisplayChangeInvalidatesMarkerAndPendingFrame() {
        let probe = RemoteVideoLatencyProbe()
        probe.setDisplay(DisplayInfo(w: 1000, h: 500, scale: 2, fullDisplaySurface: true))
        let now = ProcessInfo.processInfo.systemUptime
        let first = probe.snapshot(decodedAt: now, marker: 5)
        first.submittedTime = now + 0.001
        probe.presented(first, time: now + 0.002)
        XCTAssertTrue(probe.hasRecentMarker(now: now + 0.1))
        let pending = probe.snapshot(decodedAt: now, marker: 6)
        pending.submittedTime = now + 0.001
        probe.setDisplay(DisplayInfo(w: 1200, h: 600, scale: 2, fullDisplaySurface: true))
        XCTAssertFalse(probe.hasRecentMarker(now: now + 0.1))
        XCTAssertFalse(probe.isCurrent(pending))
        probe.presented(pending, time: now + 0.002)
        XCTAssertFalse(probe.hasRecentMarker(now: now + 0.1))
        let next = probe.snapshot(decodedAt: now, marker: 7)
        next.submittedTime = now + 0.001
        probe.presented(next, time: now + 0.002)
        XCTAssertTrue(probe.hasRecentMarker(now: now + 0.1))
        probe.setDisplay(DisplayInfo(w: 1200, h: 600, scale: 2, fullDisplaySurface: false))
        XCTAssertFalse(probe.hasRecentMarker(now: now + 0.1))
        XCTAssertFalse(probe.isCurrent(next))
    }

}
#endif
