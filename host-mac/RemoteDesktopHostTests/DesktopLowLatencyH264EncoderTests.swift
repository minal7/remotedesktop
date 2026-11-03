#if DEBUG
import Foundation
import LiveKitWebRTC
import VideoToolbox
import XCTest
@testable import RemoteDesktopHost

final class DesktopLowLatencyH264EncoderTests: XCTestCase {
    func testSessionCreationFailureUsesStockEncoderAndPreservesRateUpdates() {
        let fallback = RecordingFallbackEncoder()
        let encoder = DesktopLowLatencyH264Encoder(fallback: fallback) { _, _, _, _ in -1 }
        let settings = LKRTCVideoEncoderSettings()
        settings.width = 1280; settings.height = 720; settings.startBitrate = 8_000; settings.maxFramerate = 60
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertEqual(fallback.bitrates.last?.1, 30)
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
    func setCallback(_ callback: RTCVideoEncoderCallback?) {}
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int { startCount += 1; return 0 }
    func release() -> Int { releaseCount += 1; return 0 }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int { 0 }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { bitrates.append((bitrateKbit, framerate)); return 0 }
    func implementationName() -> String { "test stock fallback" }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
}
#endif
