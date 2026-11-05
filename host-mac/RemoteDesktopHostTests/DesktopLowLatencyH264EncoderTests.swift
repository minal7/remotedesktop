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
private final class EncoderTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LatencyKeyframeControl.Event] = []
    func append(_ event: LatencyKeyframeControl.Event) { lock.lock(); stored.append(event); lock.unlock() }
    var values: [LatencyKeyframeControl.Event] { lock.lock(); defer { lock.unlock() }; return stored }
}
#endif
