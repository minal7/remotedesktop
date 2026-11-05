#if DEBUG
import CoreVideo
import XCTest
@testable import RemoteDesktop

final class RemoteVideoLatencyProbeTests: XCTestCase {
    private static func scalarScore(buffer: CVPixelBuffer, cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int,
                      screenWidth: Double, screenHeight: Double, rotation: Int,
                      reference: LatencyTextReference) -> LatencyTextPSNR.Result? {
        let begin = CACurrentMediaTime(), format = CVPixelBufferGetPixelFormatType(buffer)
        guard reference.valid, rotation == 0, screenWidth == Double(reference.screenWidth),
              screenHeight == Double(reference.screenHeight),
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard cropX >= 0, cropY >= 0, cropWidth > 0, cropHeight > 0,
              cropX <= width, cropY <= height, cropWidth <= width - cropX, cropHeight <= height - cropY,
              stride >= width else { return nil }
        let sx = Double(cropWidth) / screenWidth / Double(reference.scale)
        let sy = Double(cropHeight) / screenHeight / Double(reference.scale)
        let firstX = Double(cropX) + Double(reference.x) / screenWidth * Double(cropWidth)
        let firstY = Double(cropY) + Double(reference.y) / screenHeight * Double(cropHeight)
        var sum = 0.0
        reference.luma.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ref = raw.bindMemory(to: UInt8.self)
            for y in 0..<reference.height {
                let fy = max(Double(cropY), min(Double(cropY + cropHeight - 1), firstY + (Double(y) + 0.5) * sy - 0.5))
                let y0 = Int(fy), y1 = min(y0 + 1, cropY + cropHeight - 1), wy = fy - Double(y0)
                for x in 0..<reference.width {
                    let fx = max(Double(cropX), min(Double(cropX + cropWidth - 1), firstX + (Double(x) + 0.5) * sx - 0.5))
                    let x0 = Int(fx), x1 = min(x0 + 1, cropX + cropWidth - 1), wx = fx - Double(x0)
                    let a = Double(base[y0 * stride + x0]) * (1 - wx) + Double(base[y0 * stride + x1]) * wx
                    let b = Double(base[y1 * stride + x0]) * (1 - wx) + Double(base[y1 * stride + x1]) * wx
                    var decoded = a * (1 - wy) + b * wy
                    if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { decoded = max(0, min(255, (decoded - 16) * 255 / 219)) }
                    let difference = decoded - Double(ref[y * reference.width + x]); sum += difference * difference
                }
            }
        }
        let mse = sum / Double(reference.width * reference.height)
        return LatencyTextPSNR.Result(psnr: mse > 0 ? 10 * log10(255 * 255 / mse) : nil, exact: mse == 0,
                      elapsedMs: (CACurrentMediaTime() - begin) * 1_000)
    }

    func testTextReferenceRequiresExactLabOptInAndValidBoundedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var contrast = Data(repeating: 0, count: 512 * 128); contrast[0] = 255
        let reference = LatencyTextReference(version: 1, screenWidth: 320, screenHeight: 208,
            width: 512, height: 128, x: 64, y: 144, scale: 2, luma: contrast)
        let json: [String: Any] = ["version": 1, "screenWidth": 320, "screenHeight": 208,
            "width": 512, "height": 128, "x": 64, "y": 144, "scale": 2, "luma": reference.luma.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let env = ["LATENCY_LAB": "1", "LATENCY_TEXT_PSNR": "1"]
        XCTAssertNotNil(LatencyTextReference.load(environment: env, arguments: ["app", "LatencyProbe"], url: url))
        XCTAssertNil(LatencyTextReference.load(environment: [:], arguments: ["app", "LatencyProbe"], url: url))
        XCTAssertNil(LatencyTextReference.load(environment: env, arguments: ["app"], url: url))
        var noContrast = json; noContrast["luma"] = Data(repeating: 0, count: 512 * 128).base64EncodedString()
        try JSONSerialization.data(withJSONObject: noContrast).write(to: url)
        XCTAssertNil(LatencyTextReference.load(environment: env, arguments: ["app", "LatencyProbe"], url: url))
        try Data(repeating: 0, count: 200_001).write(to: url)
        XCTAssertNil(LatencyTextReference.load(environment: env, arguments: ["app", "LatencyProbe"], url: url))
    }

    func testTextPSNRFixedGridDistinguishesExactAndBlurred() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 416,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        var pixels = Data(count: 512 * 128)
        pixels.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for y in 0..<128 { for x in 0..<512 { out[y * 512 + x] = (x / 4) % 2 == 0 ? 0 : 255 } }
        }
        let reference = LatencyTextReference(version: 1, screenWidth: 320, screenHeight: 208,
            width: 512, height: 128, x: 64, y: 144, scale: 2, luma: pixels)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        for y in 0..<128 { for x in 0..<512 { base[(288 + y) * stride + 128 + x] = pixels[y * 512 + x] } }
        CVPixelBufferUnlockBaseAddress(image, [])
        func score() -> LatencyTextPSNR.Result? {
            LatencyTextPSNR.score(buffer: image, cropX: 0, cropY: 0, cropWidth: 640, cropHeight: 416,
                screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference)
        }
        let exact = try XCTUnwrap(score())
        XCTAssertTrue(exact.exact)
        let scalarExact = try XCTUnwrap(Self.scalarScore(buffer: image, cropX: 0, cropY: 0, cropWidth: 640, cropHeight: 416,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference))
        XCTAssertTrue(scalarExact.exact)
        let times = (0..<30).compactMap { _ in score()?.elapsedMs }.sorted()
        XCTAssertEqual(times.count, 30)
        print("Synthetic fixed-grid PSNR warm Simulator ms p50=\(times[14]) p95=\(times[28]); not device performance")
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        memset(base, 128, stride * 416)
        CVPixelBufferUnlockBaseAddress(image, [])
        let blurred = try XCTUnwrap(score())
        XCTAssertFalse(blurred.exact); XCTAssertEqual(try XCTUnwrap(blurred.psnr), 6.02, accuracy: 0.03)
        // Reconstruct a lower-resolution source onto the SAME reference grid;
        // comparing to a separately downscaled reference would hide this loss.
        var low: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 208,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &low), kCVReturnSuccess)
        let small = try XCTUnwrap(low)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(small, []), kCVReturnSuccess)
        let lowBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(small, 0)).assumingMemoryBound(to: UInt8.self)
        let lowStride = CVPixelBufferGetBytesPerRowOfPlane(small, 0)
        for y in 0..<64 { for x in 0..<256 { lowBase[(144 + y) * lowStride + 64 + x] = (x / 2) % 2 == 0 ? 0 : 255 } }
        CVPixelBufferUnlockBaseAddress(small, [])
        let reconstructed = try XCTUnwrap(LatencyTextPSNR.score(buffer: small, cropX: 0, cropY: 0, cropWidth: 320, cropHeight: 208,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference))
        XCTAssertFalse(reconstructed.exact)
        XCTAssertLessThan(try XCTUnwrap(reconstructed.psnr), 30)
        let scalarLow = try XCTUnwrap(Self.scalarScore(buffer: small, cropX: 0, cropY: 0, cropWidth: 320, cropHeight: 208,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference))
        XCTAssertEqual(try XCTUnwrap(reconstructed.psnr), try XCTUnwrap(scalarLow.psnr), accuracy: 0.1)
        let fractional = try XCTUnwrap(LatencyTextPSNR.score(buffer: small, cropX: 3, cropY: 2, cropWidth: 314, cropHeight: 203,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference))
        let scalarFractional = try XCTUnwrap(Self.scalarScore(buffer: small, cropX: 3, cropY: 2, cropWidth: 314, cropHeight: 203,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference))
        XCTAssertEqual(try XCTUnwrap(fractional.psnr), try XCTUnwrap(scalarFractional.psnr), accuracy: 0.1)
        XCTAssertNil(LatencyTextPSNR.score(buffer: image, cropX: 0, cropY: 0, cropWidth: 640, cropHeight: 416,
            screenWidth: 320, screenHeight: 208, rotation: 1, reference: reference))
        XCTAssertNil(LatencyTextPSNR.score(buffer: image, cropX: 1, cropY: 0, cropWidth: 640, cropHeight: 416,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: reference))
    }

    func testTextPSNRNormalizesVideoRangeAndRejectsUnsupportedFormat() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 416,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0))
        memset(base, 16, CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 416)
        CVPixelBufferUnlockBaseAddress(image, [])
        let ref = LatencyTextReference(version: 1, screenWidth: 320, screenHeight: 208,
            width: 512, height: 128, x: 64, y: 144, scale: 2, luma: Data(repeating: 0, count: 512 * 128))
        XCTAssertTrue(try XCTUnwrap(LatencyTextPSNR.score(buffer: image, cropX: 0, cropY: 0, cropWidth: 640, cropHeight: 416,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: ref)).exact)
        var bgra: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 416, kCVPixelFormatType_32BGRA, nil, &bgra), kCVReturnSuccess)
        XCTAssertNil(LatencyTextPSNR.score(buffer: try XCTUnwrap(bgra), cropX: 0, cropY: 0, cropWidth: 640, cropHeight: 416,
            screenWidth: 320, screenHeight: 208, rotation: 0, reference: ref))
    }

    func testTextQualityRecordRejectsUnsubmittedAndStaleSamples() {
        let probe = RemoteVideoLatencyProbe()
        let sample = probe.snapshot(decodedAt: 10, marker: 4)
        sample.textStatus = 1
        sample.textScore = .init(psnr: 30, exact: false, elapsedMs: 2)
        XCTAssertNil(probe.textQualityRecord(sample, presented: 10.1))
        sample.submittedTime = 10.05
        XCTAssertEqual(probe.textQualityRecord(sample, presented: 10.1)?["psnrDB"] as? Double, 30)
        probe.reset()
        XCTAssertNil(probe.textQualityRecord(sample, presented: 10.1))
    }

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
