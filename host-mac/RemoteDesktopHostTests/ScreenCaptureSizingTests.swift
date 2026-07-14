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

    func test_encoderSafeCaptureDimensions_fitBundledH264Level31Profile() {
        let sourceMacroblocks = CaptureSizing.macroblockCount(width: 1728, height: 1116)
        let safe = CaptureSizing.encoderSafe(width: 1728, height: 1116)

        XCTAssertEqual(sourceMacroblocks, 7_560)
        XCTAssertGreaterThan(
            sourceMacroblocks,
            CaptureSizing.maximumH264Level31MacroblocksPerFrame)
        XCTAssertEqual(safe.width, 1188)
        XCTAssertEqual(safe.height, 768)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            CaptureSizing.maximumH264Level31MacroblocksPerFrame)
        XCTAssertEqual(
            Double(safe.width) / Double(safe.height),
            1728.0 / 1116.0,
            accuracy: 0.002)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height)
                * 16 * 16 * Int(CaptureSizing.targetFramesPerSecond),
            27_648_000,
            "H.264 level 3.1 permits 27,648,000 luma samples per second")
    }

    func test_encoderSafeCaptureDimensions_leaveCompliantFramesUntouched() {
        let safe = CaptureSizing.encoderSafe(width: 1280, height: 720)

        XCTAssertEqual(safe.width, 1280)
        XCTAssertEqual(safe.height, 720)
        XCTAssertEqual(CaptureSizing.macroblockCount(width: 1280, height: 720), 3_600)
    }

    func test_encoderSafeCaptureDimensions_preservePortraitOrientation() {
        let safe = CaptureSizing.encoderSafe(width: 1080, height: 1920)

        XCTAssertEqual(safe.width, 720)
        XCTAssertEqual(safe.height, 1280)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            CaptureSizing.maximumH264Level31MacroblocksPerFrame)
    }

    func test_streamConfiguration_disablesAudioWhenMicrophoneIsNotGranted() {
        let configuration = ScreenCapture.streamConfiguration(
            width: 1728,
            height: 1116,
            audioEnabled: false)

        XCTAssertFalse(configuration.capturesAudio)
        XCTAssertEqual(configuration.width, 1728)
        XCTAssertEqual(configuration.height, 1116)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 30))
    }

    func test_streamConfiguration_enablesAudioOnlyForOptedInSession() {
        let configuration = ScreenCapture.streamConfiguration(
            width: 1728,
            height: 1116,
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
}
