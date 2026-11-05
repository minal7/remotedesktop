#if DEBUG
import Foundation
import CoreVideo
import LiveKitWebRTC
import VideoToolbox
import XCTest
@testable import RemoteDesktopHost

final class DesktopLowLatencyH264EncoderTests: XCTestCase {
    private func encoderFrame(_ timestamp: Int32) throws -> LKRTCVideoFrame {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixel)), rotation: ._0, timeStampNs: 1)
        frame.timeStamp = timestamp
        return frame
    }

    private func emit(_ callback: RTCVideoEncoderCallback, timestamp: UInt32, keyframe: Bool) {
        let image = LKRTCEncodedImage(); image.buffer = Data([1, 2]); image.timeStamp = timestamp
        image.frameType = LKRTCFrameType(rawValue: keyframe ? 3 : 4)!
        _ = callback(image, LKRTCCodecSpecificInfoH264())
    }

    func testKeyframeControlCoalescesAndConfirmsOnlyMatchingKeyOutput() throws {
        let events = EncoderTestEvents(), base = RecordingFallbackEncoder()
        let control = LatencyKeyframeControl { events.append($0) }
        let wrapper = LatencyObservedVideoEncoder(base: base, observe: { _ in }, control: control)
        XCTAssertEqual(control.requestKeyframe(), .unavailable)
        wrapper.setCallback { _, _ in true }
        XCTAssertEqual(wrapper.startEncode(with: LKRTCVideoEncoderSettings(), numberOfCores: 1), 0)
        XCTAssertEqual(control.requestKeyframe(), .accepted); XCTAssertEqual(control.requestKeyframe(), .coalesced)
        XCTAssertEqual(wrapper.encode(try encoderFrame(101), codecSpecificInfo: nil, frameTypes: [4]), 0)
        XCTAssertEqual(base.encodedTypes.last, [4, 3]); XCTAssertEqual(events.values, [.delivered])
        let callback = try XCTUnwrap(base.callback)
        emit(callback, timestamp: 102, keyframe: true); emit(callback, timestamp: 101, keyframe: false)
        XCTAssertEqual(events.values, [.delivered])
        emit(callback, timestamp: 101, keyframe: true)
        XCTAssertEqual(events.values, [.delivered, .observed])
        emit(callback, timestamp: 101, keyframe: true)
        XCTAssertEqual(events.values, [.delivered, .observed])
    }

    func testKeyframeControlRetriesNativeFailureWithoutClaimingDelivery() throws {
        let events = EncoderTestEvents(), base = RecordingFallbackEncoder()
        let control = LatencyKeyframeControl { events.append($0) }
        let wrapper = LatencyObservedVideoEncoder(base: base, observe: { _ in }, control: control)
        wrapper.setCallback { _, _ in true }
        _ = wrapper.startEncode(with: LKRTCVideoEncoderSettings(), numberOfCores: 1)
        XCTAssertEqual(control.requestKeyframe(), .accepted)
        base.encodeResult = -1
        XCTAssertEqual(wrapper.encode(try encoderFrame(1), codecSpecificInfo: nil, frameTypes: [4]), -1)
        XCTAssertEqual(events.values, [.encodeFailed]); XCTAssertEqual(control.requestKeyframe(), .coalesced)
        base.encodeResult = 0
        XCTAssertEqual(wrapper.encode(try encoderFrame(2), codecSpecificInfo: nil, frameTypes: [4]), 0)
        XCTAssertEqual(events.values, [.encodeFailed, .delivered]); XCTAssertEqual(base.encodedTypes.last, [4, 3])
        let callback = try XCTUnwrap(base.callback)
        emit(callback, timestamp: 1, keyframe: true); XCTAssertEqual(events.values, [.encodeFailed, .delivered])
        emit(callback, timestamp: 2, keyframe: true); XCTAssertEqual(events.values, [.encodeFailed, .delivered, .observed])
    }

    func testSynchronousOutputCannotClaimSuccessWhenNativeEncodeFails() throws {
        let events = EncoderTestEvents(), base = RecordingFallbackEncoder()
        let control = LatencyKeyframeControl { events.append($0) }
        let wrapper = LatencyObservedVideoEncoder(base: base, observe: { _ in }, control: control)
        wrapper.setCallback { _, _ in true }
        _ = wrapper.startEncode(with: LKRTCVideoEncoderSettings(), numberOfCores: 1)
        base.onEncode = { [weak base] frame in
            guard let callback = base?.callback else { return }
            let image = LKRTCEncodedImage(); image.buffer = Data([1]); image.timeStamp = UInt32(bitPattern: frame.timeStamp)
            image.frameType = LKRTCFrameType(rawValue: 3)!
            _ = callback(image, LKRTCCodecSpecificInfoH264())
        }
        defer { base.onEncode = nil }
        XCTAssertEqual(control.requestKeyframe(), .accepted)
        base.encodeResult = -1
        XCTAssertEqual(wrapper.encode(try encoderFrame(8), codecSpecificInfo: nil, frameTypes: [4]), -1)
        XCTAssertEqual(events.values, [.encodeFailed])
        base.encodeResult = 0
        XCTAssertEqual(wrapper.encode(try encoderFrame(9), codecSpecificInfo: nil, frameTypes: [4]), 0)
        XCTAssertEqual(events.values, [.encodeFailed, .delivered, .observed])
    }

    func testOldEncoderReleaseAndCallbacksCannotAffectReplacementOrClosedPeer() throws {
        let events = EncoderTestEvents(), control = LatencyKeyframeControl { events.append($0) }
        let first = RecordingFallbackEncoder(), second = RecordingFallbackEncoder()
        let old = LatencyObservedVideoEncoder(base: first, observe: { _ in }, control: control)
        let current = LatencyObservedVideoEncoder(base: second, observe: { _ in }, control: control)
        old.setCallback { _, _ in true }; current.setCallback { _, _ in true }
        _ = old.startEncode(with: LKRTCVideoEncoderSettings(), numberOfCores: 1)
        let oldCallback = try XCTUnwrap(first.callback)
        _ = current.startEncode(with: LKRTCVideoEncoderSettings(), numberOfCores: 1)
        _ = old.release()
        XCTAssertEqual(control.requestKeyframe(), .accepted)
        _ = current.encode(try encoderFrame(7), codecSpecificInfo: nil, frameTypes: [4])
        emit(oldCallback, timestamp: 7, keyframe: true)
        XCTAssertEqual(events.values, [.delivered])
        let currentCallback = try XCTUnwrap(second.callback)
        emit(currentCallback, timestamp: 7, keyframe: true)
        XCTAssertEqual(events.values, [.delivered, .observed])
        control.invalidate(); XCTAssertEqual(control.requestKeyframe(), .unavailable)
        emit(currentCallback, timestamp: 7, keyframe: true)
        XCTAssertEqual(events.values, [.delivered, .observed])
    }

    func testBundledDefaultH264UsesValidatedObjectiveCEncoderClass() throws {
        let factory = LKRTCDefaultVideoEncoderFactory()
        let info = try XCTUnwrap(factory.supportedCodecs().first { $0.name.uppercased() == "H264" })
        let encoder = try XCTUnwrap(factory.createEncoder(info) as? NSObject)
        XCTAssertTrue(NSStringFromClass(type(of: encoder)).hasSuffix("RTCVideoEncoderH264"))
        XCTAssertFalse(encoder.responds(to: NSSelectorFromString("build:")))
        if let nativeBuilder = NSProtocolFromString("LKRTCNativeVideoEncoderBuilder") {
            XCTAssertFalse(encoder.conforms(to: nativeBuilder))
        }
    }

    func testObservedEncoderForwardsRealCallbackAndCountsOnlyBytes() throws {
        let base = RecordingFallbackEncoder()
        var observed: [Int] = []
        let encoder = LatencyObservedVideoEncoder(base: base) { observed.append($0) }
        var delivered = 0
        encoder.setCallback { image, _ in delivered += image.buffer.count; return true }
        let image = LKRTCEncodedImage(); image.buffer = Data(repeating: 7, count: 123)
        XCTAssertTrue(try XCTUnwrap(base.callback)(image, LKRTCCodecSpecificInfoH264()))
        XCTAssertEqual(observed, [123]); XCTAssertEqual(delivered, 123)
        XCTAssertEqual(encoder.implementationName(), base.implementationName())
        XCTAssertEqual(encoder.resolutionAlignment, base.resolutionAlignment)
        XCTAssertEqual(encoder.supportsNativeHandle, base.supportsNativeHandle)
        encoder.setCallback(nil); XCTAssertNil(base.callback)
    }

    func testIndependentObserversDoNotMixLateEncoderCallbacks() throws {
        let first = RecordingFallbackEncoder(), second = RecordingFallbackEncoder()
        var firstSizes: [Int] = [], secondSizes: [Int] = []
        let old = LatencyObservedVideoEncoder(base: first) { firstSizes.append($0) }
        let current = LatencyObservedVideoEncoder(base: second) { secondSizes.append($0) }
        old.setCallback { _, _ in true }; current.setCallback { _, _ in true }
        let late = try XCTUnwrap(first.callback), active = try XCTUnwrap(second.callback)
        let frame = LKRTCEncodedImage(); frame.buffer = Data(repeating: 0, count: 8)
        _ = active(frame, LKRTCCodecSpecificInfoH264()); _ = late(frame, LKRTCCodecSpecificInfoH264())
        XCTAssertEqual(firstSizes, [8]); XCTAssertEqual(secondSizes, [8])
    }

    @available(macOS 26.0, *)
    func testCBRPropertiesAndLiveRateUpdateAreIsolatedFromF2() {
        let spec = DesktopCBRConfiguration.specification()
        XCTAssertNil(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl])
        let properties = Dictionary(uniqueKeysWithValues: DesktopCBRConfiguration.properties(fps: 60, bitrateKbps: 5_000).map { ($0.0 as String, $0.1) })
        XCTAssertNil(properties[kVTCompressionPropertyKey_AverageBitRate as String])
        XCTAssertNil(properties[kVTCompressionPropertyKey_DataRateLimits as String])
        XCTAssertNil(properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String])
        XCTAssertEqual((properties[kVTCompressionPropertyKey_ConstantBitRate as String] as? NSNumber)?.intValue, 5_000_000)
        XCTAssertEqual((properties[kVTCompressionPropertyKey_VBVBufferDuration as String] as? NSNumber)?.doubleValue ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual((properties[kVTCompressionPropertyKey_MaxKeyFrameInterval as String] as? NSNumber)?.intValue, 7200)
        var seen: [String: Int] = [:]
        XCTAssertTrue(DesktopCBRConfiguration.update(kbps: 3_000, fps: 60) { key, value in
            seen[key as String] = (value as? NSNumber)?.intValue; return noErr
        })
        XCTAssertEqual(seen[kVTCompressionPropertyKey_ConstantBitRate as String], 3_000_000)
        XCTAssertFalse(DesktopCBRConfiguration.update(kbps: 4_000, fps: 60) { key, _ in
            key == kVTCompressionPropertyKey_ConstantBitRate ? -1 : noErr
        })
    }

    func testCBRAcceptsLargerUncroppedNativeBufferAtConfiguredSize() throws {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        let native = LKRTCCVPixelBuffer(pixelBuffer: buffer, adaptedWidth: 32, adaptedHeight: 32,
                                       cropWidth: 64, cropHeight: 64, cropX: 0, cropY: 0)
        let settings = LKRTCVideoEncoderSettings(); settings.width = 32; settings.height = 32
        XCTAssertTrue(DesktopLowLatencyH264Encoder.acceptsCBRFrame(native, frameWidth: 32, frameHeight: 32, settings: settings))
        XCTAssertFalse(DesktopLowLatencyH264Encoder.acceptsCBRFrame(native, frameWidth: 16, frameHeight: 16, settings: settings))
        let cropped = LKRTCCVPixelBuffer(pixelBuffer: buffer, adaptedWidth: 32, adaptedHeight: 32,
                                        cropWidth: 32, cropHeight: 32, cropX: 0, cropY: 0)
        XCTAssertFalse(DesktopLowLatencyH264Encoder.acceptsCBRFrame(cropped, frameWidth: 32, frameHeight: 32, settings: settings))
    }

    @available(macOS 26.0, *)
    func testCBRReadbackTolerance() {
        XCTAssertTrue(DesktopCBRConfiguration.rateMatches(requested: 5_000_000, readback: 5_050_000))
        XCTAssertFalse(DesktopCBRConfiguration.rateMatches(requested: 5_000_000, readback: 5_050_001))
        XCTAssertFalse(DesktopCBRConfiguration.rateMatches(requested: 0, readback: 1))
    }

    @available(macOS 26.0, *)
    func testCBRRejectedConfigurationStartsNativeFallback() throws {
        let fallback = RecordingFallbackEncoder()
        var reachedVBV = false
        let encoder = DesktopLowLatencyH264Encoder(fallback: fallback, cbr: true, propertySetter: { _, key, _ in
            if key == kVTCompressionPropertyKey_VBVBufferDuration { reachedVBV = true; return -1 }
            return noErr
        })
        let settings = LKRTCVideoEncoderSettings()
        settings.width = 1280; settings.height = 720; settings.startBitrate = 4_000; settings.maxFramerate = 60
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        guard reachedVBV else { _ = encoder.release(); throw XCTSkip("Hardware VideoToolbox session unavailable") }
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertEqual(encoder.release(), 0)
    }

    @available(macOS 26.0, *)
    func testCBRRejectedLiveRateFallsBackOnNextFrame() throws {
        let fallback = RecordingFallbackEncoder()
        var rejectRate = false, sawRejectedUpdate = false
        let encoder = DesktopLowLatencyH264Encoder(fallback: fallback, cbr: true, propertySetter: { session, key, value in
            if rejectRate && key == kVTCompressionPropertyKey_ConstantBitRate {
                sawRejectedUpdate = true; return -1
            }
            return VTSessionSetProperty(session, key: key, value: value)
        })
        let settings = LKRTCVideoEncoderSettings()
        settings.width = 1280; settings.height = 720; settings.startBitrate = 4_000; settings.maxFramerate = 60
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        guard fallback.startCount == 0 else { _ = encoder.release(); throw XCTSkip("Hardware CBR/VBV unavailable") }
        rejectRate = true
        XCTAssertEqual(encoder.setBitrate(3_000, framerate: 60), 0)
        XCTAssertFalse(sawRejectedUpdate, "Rate changes wait for encode() so they cannot race a frame in flight")
        XCTAssertEqual(encoder.encode(try encoderFrame(1), codecSpecificInfo: nil, frameTypes: [4]), 0)
        XCTAssertTrue(sawRejectedUpdate)
        XCTAssertEqual(encoder.encode(try encoderFrame(2), codecSpecificInfo: nil, frameTypes: [4]), 0)
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertEqual(fallback.bitrates.last?.0, 3_000)
        XCTAssertEqual(encoder.release(), 0)
    }

    func testCBRSessionCreationFailureUsesStockAndForwardsRate() {
        let fallback = RecordingFallbackEncoder()
        var events: [[String: Any]] = []
        let encoder = DesktopLowLatencyH264Encoder(fallback: fallback, cbr: true, trace: { events.append($0) }) { _, _, _, _ in -1 }
        let settings = LKRTCVideoEncoderSettings()
        settings.width = 1280; settings.height = 720; settings.startBitrate = 4_000; settings.maxFramerate = 60
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertEqual(encoder.setBitrate(3_000, framerate: 60), 0)
        XCTAssertEqual(fallback.bitrates.last?.0, 3_000)
        XCTAssertEqual(events.last?["event"] as? String, "fallback")
        XCTAssertEqual(encoder.release(), 0)
    }

    func testHEVCKeyframeRequestSurvivesBusyAdmission() {
        var latch = LabHEVCKeyframeLatch()
        XCTAssertNil(latch.pending)
        latch.request(); let first = latch.pending
        latch.request(); latch.acknowledge(first!)
        XCTAssertNotNil(latch.pending)
        latch.acknowledge(latch.pending!); XCTAssertNil(latch.pending)
    }

    func testHEVCStaleCompletionCannotReleaseNewGenerationReservation() throws {
        let gate = LabHEVCDeliveryGate(); gate.start()
        let old = try XCTUnwrap(gate.reserve())
        gate.stop(); gate.start()
        let current = try XCTUnwrap(gate.reserve())
        gate.complete(old)
        XCTAssertNil(gate.reserve())
        gate.complete(current)
        XCTAssertNotNil(gate.reserve())
        gate.stop()
    }

    func testHEVCDeliveryStopDoesNotWaitForBlockedCallback() {
        let gate = LabHEVCDeliveryGate(); gate.start()
        let entered = expectation(description: "delivery entered")
        let stopped = expectation(description: "stop returned")
        let unblock = DispatchSemaphore(value: 0)
        let ticket = try! XCTUnwrap(gate.reserve())
        XCTAssertNil(gate.reserve())
        XCTAssertTrue(gate.deliver(ticket) { entered.fulfill(); _ = unblock.wait(timeout: .now() + 3) })
        wait(for: [entered], timeout: 1)
        DispatchQueue.global().async { gate.stop(); stopped.fulfill() }
        wait(for: [stopped], timeout: 0.5)
        XCTAssertNil(gate.reserve())
        gate.start(); XCTAssertNil(gate.reserve())
        unblock.signal()
    }

    @available(macOS 26.0, *)
    func testHEVCMetadataFailsClosedWhenClassMissing() {
        XCTAssertNil(LabHEVCEncoder.makeInfo(lookup: { _ in nil }))
        XCTAssertNotNil(LabHEVCEncoder.makeInfo())
    }

    @available(macOS 26.0, *)
    func testHEVCSPSRejectsWrongProfileTierAndLevel() {
        var rbsp = [UInt8](repeating: 0, count: 13); rbsp[1] = 1; rbsp[12] = 153
        func sps() -> Data { Data([0x42, 0x01] + rbsp) }
        XCTAssertTrue(LabHEVCEncoder.acceptsSPS(sps()))
        rbsp[1] = 2; XCTAssertFalse(LabHEVCEncoder.acceptsSPS(sps()))
        rbsp[1] = 0x21; XCTAssertFalse(LabHEVCEncoder.acceptsSPS(sps()))
        rbsp[1] = 0x41; XCTAssertFalse(LabHEVCEncoder.acceptsSPS(sps()))
        rbsp[1] = 1; rbsp[12] = 0; XCTAssertFalse(LabHEVCEncoder.acceptsSPS(sps()))
        rbsp[12] = 154; XCTAssertFalse(LabHEVCEncoder.acceptsSPS(sps()))
        XCTAssertFalse(LabHEVCEncoder.acceptsSPS(Data([0x42, 0x01])))
        rbsp[12] = 153
        XCTAssertTrue(LabHEVCEncoder.annexBContainsAcceptedSPS(Data([0, 0, 0, 1]) + sps()))
        rbsp[12] = 154
        XCTAssertFalse(LabHEVCEncoder.annexBContainsAcceptedSPS(Data([0, 0, 1]) + sps()))
        XCTAssertFalse(LabHEVCEncoder.annexBContainsAcceptedSPS(Data([0, 0, 0, 1, 0x40, 0x01])))
    }

    @available(macOS 26.0, *)
    func testHEVCCroppedFrameEncodesAndDecodes() throws {
        guard LabHEVCEncoder.preflight(), let info = LabHEVCEncoder.makeInfo(),
              let native = LKRTCDefaultVideoEncoderFactory().createEncoder(LKRTCVideoCodecInfo(name: "H265")),
              let decoder = LKRTCDefaultVideoDecoderFactory().createDecoder(LKRTCVideoCodecInfo(name: "H265")) else {
            throw XCTSkip("HEVC CBR/VBV hardware unavailable")
        }
        let decoded = expectation(description: "HEVC decoded")
        decoder.setCallback { _ in decoded.fulfill() }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), 0)
        let events = HEVCEventCapture()
        let encoder = LabHEVCEncoder(native: native, info: info, trace: { events.append($0) })
        encoder.setCallback { image, metadata in
            _ = decoder.decode(image, missingFrames: false, codecSpecificInfo: metadata, renderTimeMs: 0); return true
        }
        let settings = LKRTCVideoEncoderSettings(); settings.name = "H265"; settings.width = 320; settings.height = 240; settings.startBitrate = 3000; settings.maxFramerate = 60
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
        XCTAssertTrue(events.contains("configured"), "The test must exercise CBR, not its native fallback")
        XCTAssertEqual(encoder.setBitrate(2500, framerate: 60), 0)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel), kCVReturnSuccess)
        let nativeBuffer = LKRTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixel), adaptedWidth: 320, adaptedHeight: 240, cropWidth: 320, cropHeight: 240, cropX: 0, cropY: 0)
        let frame = LKRTCVideoFrame(buffer: nativeBuffer, rotation: ._0, timeStampNs: 1_000_000)
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [3]), 0)
        wait(for: [decoded], timeout: 5)
        XCTAssertTrue(events.appliedRateUpdate)
        XCTAssertFalse(events.contains("native_hevc_fallback"))
        XCTAssertEqual(encoder.release(), 0); XCTAssertEqual(decoder.release(), 0)
    }

    func testSessionCreationFailureUsesStockEncoderAndPreservesRateUpdates() {
        let fallback = RecordingFallbackEncoder()
        let encoder = DesktopLowLatencyH264Encoder(fallback: fallback) { _, _, _, _ in -1 }
        let settings = LKRTCVideoEncoderSettings()
        settings.width = 1280; settings.height = 720; settings.startBitrate = 8_000; settings.maxFramerate = 60
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertEqual(fallback.bitrates.last?.1, 60)
        XCTAssertEqual(encoder.implementationName(), "test stock fallback")
        XCTAssertEqual(encoder.setBitrate(6_000, framerate: 30), 0)
        XCTAssertEqual(fallback.bitrates.last?.0, 6_000)
        XCTAssertEqual(fallback.bitrates.last?.1, 30)
        XCTAssertEqual(encoder.release(), 0)
        XCTAssertEqual(fallback.releaseCount, 1)
    }

    func testLowLatencyConfigurationHasExpectedVideoToolboxProperties() {
        let spec = DesktopEncoderConfiguration.specification()
        XCTAssertEqual(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool, true)
        XCTAssertEqual(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool, true)
        let values = Dictionary(uniqueKeysWithValues: DesktopEncoderConfiguration.properties(fps: 30, bitrateKbps: 8_000))
        XCTAssertEqual((values[kVTCompressionPropertyKey_RealTime] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values[kVTCompressionPropertyKey_AllowFrameReordering] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((values[kVTCompressionPropertyKey_MaxFrameDelayCount] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values[kVTCompressionPropertyKey_ExpectedFrameRate] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((values[kVTCompressionPropertyKey_MaxKeyFrameInterval] as? NSNumber)?.intValue, 60)
        XCTAssertEqual((values[kVTCompressionPropertyKey_AverageBitRate] as? NSNumber)?.intValue, 8_000_000)
        XCTAssertEqual(values[kVTCompressionPropertyKey_ProfileLevel] as? String,
                       kVTProfileLevel_H264_ConstrainedHigh_AutoLevel as String)
    }

    func testSpeedHintMustBeSupportedAndAcceptedBeforeUsingExperimentalEncoder() {
        let key = kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
        let supported = [key: [:] as [String: String]] as CFDictionary
        let unsupported = ["another-property": [:] as [String: String]] as CFDictionary
        XCTAssertTrue(DesktopEncoderConfiguration.supportsSpeedHint(supported))
        XCTAssertFalse(DesktopEncoderConfiguration.supportsSpeedHint(unsupported))
        XCTAssertFalse(DesktopEncoderConfiguration.supportsSpeedHint(nil))

        let properties = DesktopEncoderConfiguration.properties(fps: 30, bitrateKbps: 8_000)
        var visited: [String] = []
        XCTAssertFalse(DesktopEncoderConfiguration.configure(properties, speedHintSupported: false) { key, _ in
            visited.append(key as String); return noErr
        })
        XCTAssertTrue(visited.isEmpty, "An unadvertised hint must not enable the experimental path")
        XCTAssertFalse(DesktopEncoderConfiguration.configure(properties, speedHintSupported: true) { property, _ in
            visited.append(property as String)
            return (property as String) == key ? -1 : noErr
        }, "A rejected speed hint must trigger stock-encoder fallback")
        XCTAssertTrue(visited.contains(key))
        XCTAssertTrue(DesktopEncoderConfiguration.configure(properties, speedHintSupported: true) { _, _ in noErr })
    }

    func testAVCCConversionPrependsParameterSetsAndRejectsTruncation() {
        let avcc = Data([0, 0, 0, 2, 0x65, 0xab, 0, 0, 0, 1, 0x41])
        let sps = Data([0x67, 0x64, 0x0c, 0x33])
        let pps = Data([0x68, 0xef])
        XCTAssertEqual(DesktopH264AnnexB.convert(avcc, lengthSize: 4, parameterSets: [sps, pps]),
                       Data([0, 0, 0, 1, 0x67, 0x64, 0x0c, 0x33, 0, 0, 0, 1, 0x68, 0xef,
                             0, 0, 0, 1, 0x65, 0xab, 0, 0, 0, 1, 0x41]))
        XCTAssertNil(DesktopH264AnnexB.convert(Data([0, 0, 0, 3, 0x65]), lengthSize: 4))
        XCTAssertNil(DesktopH264AnnexB.convert(Data([0, 0, 0, 0]), lengthSize: 4))
        XCTAssertNil(DesktopH264AnnexB.convert(Data([0, 0]), lengthSize: 4))
        XCTAssertTrue(DesktopH264AnnexB.isCompatibleSPS(sps))
        XCTAssertFalse(DesktopH264AnnexB.isCompatibleSPS(Data([0x67, 0x64, 0x00, 0x33])))
        XCTAssertFalse(DesktopH264AnnexB.isCompatibleSPS(Data([0x67, 0x64, 0x0c, 0x34])))
    }

    func testKeyframeRequestIsDelayedRatherThanLostDuringThrottle() {
        var gate = DesktopKeyframeGate()
        let first = gate.shouldForce(requested: true, now: 1)
        XCTAssertNotNil(first)
        XCTAssertNil(gate.shouldForce(requested: true, now: 1.1))
        gate.acknowledge(first!) // An older frame cannot clear the newer request.
        XCTAssertNil(gate.shouldForce(requested: false, now: 1.2))
        let second = gate.shouldForce(requested: false, now: 1.31)
        XCTAssertNotNil(second)
        // A dropped frame doesn't acknowledge the request, so it retries.
        let retry = gate.shouldForce(requested: false, now: 1.62)
        XCTAssertEqual(second, retry)
        gate.acknowledge(retry!)
        XCTAssertNil(gate.shouldForce(requested: false, now: 2))
    }

    func testBitrateAndFrameRateUpdatesAreBothApplied() {
        var values: [String: Int64] = [:]
        let ok = DesktopEncoderRate.apply(kbps: 8_000, fps: 60) { key, value in
            values[key as String] = (value as? NSNumber)?.int64Value
            return noErr
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(values[kVTCompressionPropertyKey_AverageBitRate as String], 8_000_000)
        XCTAssertEqual(values[kVTCompressionPropertyKey_ExpectedFrameRate as String], 60)
        XCTAssertEqual(values[kVTCompressionPropertyKey_MaxKeyFrameInterval as String], 120)
        XCTAssertFalse(DesktopEncoderRate.apply(kbps: 0, fps: 60) { _, _ in XCTFail("Invalid rate must not reach VideoToolbox"); return noErr })
        XCTAssertFalse(DesktopEncoderRate.apply(kbps: 8_000, fps: 60) { _, _ in -1 })
    }
}

private final class RecordingFallbackEncoder: NSObject, LKRTCVideoEncoder {
    var startCount = 0
    var releaseCount = 0
    var bitrates: [(UInt32, UInt32)] = []
    var callback: RTCVideoEncoderCallback?
    var encodedTypes: [[NSNumber]] = []
    var encodeResult = 0
    var onEncode: ((LKRTCVideoFrame) -> Void)?
    func setCallback(_ callback: RTCVideoEncoderCallback?) { self.callback = callback }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int { startCount += 1; return 0 }
    func release() -> Int { releaseCount += 1; return 0 }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        encodedTypes.append(frameTypes); onEncode?(frame); return encodeResult
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { bitrates.append((bitrateKbit, framerate)); return 0 }
    func implementationName() -> String { "test stock fallback" }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
}
private final class HEVCEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Any]] = []
    func append(_ value: [String: Any]) { lock.lock(); values.append(value); lock.unlock() }
    func contains(_ event: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0["event"] as? String == event } }
    var appliedRateUpdate: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0["event"] as? String == "rate_update" && $0["applied"] as? Bool == true } }
}

private final class EncoderTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LatencyKeyframeControl.Event] = []
    func append(_ event: LatencyKeyframeControl.Event) { lock.lock(); stored.append(event); lock.unlock() }
    var values: [LatencyKeyframeControl.Event] { lock.lock(); defer { lock.unlock() }; return stored }

    func testCBRRatePolicyIgnoresSmallChanges() {
        var policy = LabCBRRatePolicy()
        XCTAssertEqual(policy.decide(requestKbps: 2400, now: 0, framesEncoded: 0), 2400)
        XCTAssertNil(policy.decide(requestKbps: 2424, now: 5, framesEncoded: 300))
        XCTAssertNil(policy.decide(requestKbps: 2000, now: 6, framesEncoded: 360))
    }

    func testCBRRatePolicyDropsFastAndRaisesAfterHold() {
        var policy = LabCBRRatePolicy()
        _ = policy.decide(requestKbps: 2400, now: 0, framesEncoded: 0)
        XCTAssertEqual(policy.decide(requestKbps: 1000, now: 2, framesEncoded: 120), 1000)
        XCTAssertNil(policy.decide(requestKbps: 500, now: 2.5, framesEncoded: 150), "one drop per second")
        XCTAssertEqual(policy.decide(requestKbps: 500, now: 3.1, framesEncoded: 186), 500)
        XCTAssertNil(policy.decide(requestKbps: 1000, now: 4, framesEncoded: 240))
        XCTAssertNil(policy.decide(requestKbps: 800, now: 5, framesEncoded: 300))
        XCTAssertEqual(policy.decide(requestKbps: 1200, now: 6.1, framesEncoded: 366), 800, "raises only to the lowest sustained request")
    }
}
#endif
