import CoreMedia
import XCTest
@testable import RemoteDesktopHost

final class ScreenCaptureSizingTests: XCTestCase {
    func test_normalizedCaptureDimensions_leaveEvenSizesUntouched() {
        let normalized = CaptureSizing.normalized(width: 1728, height: 1116)

        XCTAssertEqual(normalized.width, 1728)
        XCTAssertEqual(normalized.height, 1116)
    }

    func test_normalizedCaptureDimensions_roundDownOddSizesForVideoToolbox() {
        let normalized = CaptureSizing.normalized(width: 1728, height: 1117)

        XCTAssertEqual(normalized.width, 1728)
        XCTAssertEqual(normalized.height, 1116,
                       "H.264/420f frames must use even dimensions or VideoToolbox will reject them")
    }

    func test_normalizedCaptureDimensions_neverDropsBelowTwoPixels() {
        let normalized = CaptureSizing.normalized(width: 1, height: 1)

        XCTAssertEqual(normalized.width, 2)
        XCTAssertEqual(normalized.height, 2)
    }

    func test_backingPixelSize_usesScreenCaptureKitPointScale() {
        let size = CaptureSizing.backingPixelSize(
            widthInPoints: 1728,
            heightInPoints: 1117,
            pointPixelScale: 2)

        XCTAssertEqual(size.width, 3456)
        XCTAssertEqual(size.height, 2234)
    }

    func test_encoderSafeCaptureDimensions_keepRetinaLaptopNativeAtPreferredQuality() {
        let sourceMacroblocks = CaptureSizing.macroblockCount(width: 3456, height: 2234)
        let safe = CaptureSizing.encoderSafe(
            width: 3456,
            height: 2234,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(sourceMacroblocks, 30_240)
        XCTAssertEqual(safe.width, 3456)
        XCTAssertEqual(safe.height, 2234)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height)
                * 16 * 16 * Int(CaptureSizing.targetFramesPerSecond),
            251_658_240,
            "H.264 level 5.1 permits 983,040 macroblocks per second")
    }

    func test_encoderSafeCaptureDimensions_fallBackForLevel31Peer() {
        let safe = CaptureSizing.encoderSafe(
            width: 3456,
            height: 2234,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 1188)
        XCTAssertEqual(safe.height, 768)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame)
    }

    func test_encoderSafeCaptureDimensions_leaveCompliantFramesUntouched() {
        let safe = CaptureSizing.encoderSafe(
            width: 1280,
            height: 720,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 1280)
        XCTAssertEqual(safe.height, 720)
        XCTAssertEqual(CaptureSizing.macroblockCount(width: 1280, height: 720), 3_600)
    }

    func test_encoderSafeCaptureDimensions_preservePortraitOrientation() {
        let safe = CaptureSizing.encoderSafe(
            width: 2160,
            height: 3840,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 2160)
        XCTAssertEqual(safe.height, 3840)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)
    }

    func test_encoderSafeCaptureDimensions_capOversizedDisplayAt4K() {
        let safe = CaptureSizing.encoderSafe(
            width: 5120,
            height: 2880,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 3840)
        XCTAssertEqual(safe.height, 2160)
    }

    func test_encoderSafeCaptureDimensions_limitSoftwareCodecFallback() {
        let safe = CaptureSizing.encoderSafe(
            width: 3456,
            height: 2234,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.softwareCodecMaximumMacroblocksPerFrame)

        XCTAssertLessThan(safe.width, 3456)
        XCTAssertLessThan(safe.height, 2234)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.softwareCodecMaximumMacroblocksPerFrame)
    }

    func test_streamConfiguration_disablesAudioWhenMicrophoneIsNotGranted() {
        let configuration = ScreenCapture.streamConfiguration(
            width: 3456,
            height: 2234,
            audioEnabled: false)

        XCTAssertFalse(configuration.capturesAudio)
        XCTAssertEqual(configuration.width, 3456)
        XCTAssertEqual(configuration.height, 2234)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(configuration.queueDepth, DesktopVideoQuality.captureQueueDepth)
    }

    func test_streamConfiguration_enablesAudioOnlyForOptedInSession() {
        let configuration = ScreenCapture.streamConfiguration(
            width: 3456,
            height: 2234,
            audioEnabled: true)

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
    }

    func test_systemStoppedStreamError_isRecognizedAsRecoverableInterruption() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3821)

        XCTAssertTrue(ScreenCapture.isSystemStopped(error))
        XCTAssertFalse(ScreenCapture.isAlreadyStopped(error))
    }

    func test_alreadyStoppedStreamError_isNotSystemStopped() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3808)

        XCTAssertTrue(ScreenCapture.isAlreadyStopped(error))
        XCTAssertFalse(ScreenCapture.isSystemStopped(error))
    }

    func test_desktopVideoFactoriesAdvertiseHigherH264Level() throws {
        let encoderFactory = DesktopVideoEncoderFactory()
        let decoderFactory = DesktopVideoDecoderFactory()
        let encoderCodecs = encoderFactory.supportedCodecs()
        let decoderCodecs = decoderFactory.supportedCodecs()
        let encoderProfiles = encoderCodecs
            .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
            .compactMap { $0.parameters["profile-level-id"] }
        let decoderProfiles = decoderCodecs
            .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
            .compactMap { $0.parameters["profile-level-id"] }

        XCTAssertFalse(encoderProfiles.isEmpty)
        XCTAssertTrue(encoderProfiles.contains("640c33"))
        XCTAssertTrue(encoderProfiles.contains("42e01f"))
        XCTAssertEqual(decoderProfiles, encoderProfiles)

        let encoderCodec = try XCTUnwrap(encoderCodecs.first {
            $0.parameters["profile-level-id"] == "640c33"
        })
        let decoderCodec = try XCTUnwrap(decoderCodecs.first {
            $0.parameters["profile-level-id"] == "640c33"
        })
        XCTAssertNotNil(encoderFactory.createEncoder(encoderCodec))
        XCTAssertNotNil(decoderFactory.createDecoder(decoderCodec))
    }

    func test_h264LevelMappingRetainsLegacyAndRetinaLimits() {
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "1e"),
            1_620)
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "1f"),
            3_600)
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "2a"),
            8_704)
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "33"),
            32_768)
    }

    func test_h264Level1bUsesTheFullRFC6184ProfileLevelID() {
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "42b00b"),
            99,
            "Baseline level 1b uses constraint_set3_flag with level_idc 11")
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "42a00b"),
            396,
            "Baseline level 1.1 has level_idc 11 without constraint_set3_flag")
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "640009"),
            99,
            "Other profiles signal level 1b with level_idc 9")
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "not-hex"),
            DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame)
    }

    func test_senderPolicyPreservesResolutionAndClampsUnsafeRequests() {
        let policy = DesktopVideoQuality.senderPolicy(
            targetFramesPerSecond: 120,
            maximumBitrateKbps: 100_000,
            preference: "sharpness")

        XCTAssertEqual(policy.maximumFramesPerSecond, 30)
        XCTAssertEqual(policy.maximumBitrateBps, 30_000_000)
        XCTAssertEqual(policy.degradationPreference, .maintainResolution)
    }
}
