import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import RemoteDesktopHost

final class ScreenCaptureSizingTests: XCTestCase {
    func test_captureFrameMetadataRequiresCompleteStatus() {
        for status: Int? in [nil, -1, SCFrameStatus.idle.rawValue, SCFrameStatus.blank.rawValue,
                            SCFrameStatus.started.rawValue, SCFrameStatus.suspended.rawValue, SCFrameStatus.stopped.rawValue] {
            XCTAssertNil(frameMetadata(status: status))
        }
        XCTAssertNotNil(frameMetadata())
    }

    func test_captureFrameMetadataUsesDisplayClockAndPreservesIntegerMediaTime() throws {
        let exact: Int64 = 9_000_000_000_000_001
        let metadata = try XCTUnwrap(frameMetadata(presentationTime: CMTime(value: exact, timescale: 1_000_000_000)))
        XCTAssertEqual(metadata.captureTimeNanoseconds, 42_000_000_000)
        XCTAssertEqual(metadata.presentationTimeNanoseconds, exact, "Do not round through Double seconds")
        XCTAssertEqual(metadata.displayTimeHostTicks, displayTicks(seconds: 42))
        XCTAssertEqual(metadata.width, 800); XCTAssertEqual(metadata.height, 600)
        let third = try XCTUnwrap(frameMetadata(presentationTime: CMTime(value: 1, timescale: 3)))
        XCTAssertEqual(third.presentationTimeNanoseconds, 333_333_333)
        XCTAssertEqual(third.captureTimeNanoseconds, metadata.captureTimeNanoseconds, "Media PTS is not WindowServer display time")
    }

    func test_captureFrameMetadataDoesNotUseInvalidOrForeignEpochMediaTimeAsCaptureEvidence() throws {
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                     CMTime(value: -1, timescale: 1), CMTime(value: 1, timescale: 0),
                     CMTime(value: Int64.max, timescale: 1),
                     CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1)] {
            let metadata = try XCTUnwrap(frameMetadata(presentationTime: time))
            XCTAssertNil(metadata.presentationTimeNanoseconds)
            XCTAssertEqual(metadata.captureTimeNanoseconds, 42_000_000_000,
                           "Valid WindowServer timing does not depend on optional media timing")
        }
    }

    func test_captureFrameMetadataRejectsMissingZeroFutureDisplayTimeAndEmptyDimensions() {
        XCTAssertNil(frameMetadata(displayTime: nil))
        XCTAssertNil(frameMetadata(displayTime: 0))
        XCTAssertNil(frameMetadata(displayTime: displayTicks(seconds: 44)))
        XCTAssertNil(frameMetadata(width: 0))
        XCTAssertNil(frameMetadata(height: -1))
        XCTAssertNotNil(frameMetadata(displayTime: displayTicks(seconds: 43)), "The observation boundary itself is permitted")
    }

    func test_captureFrameOrderRejectsDuplicatesAndRegressionsWithoutAdvancingItsBoundary() throws {
        var order = CaptureVideoFrameOrder()
        let first = try XCTUnwrap(frameMetadata())
        let older = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 41)))
        let next = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))
        XCTAssertTrue(order.admit(first))
        XCTAssertFalse(order.admit(first))
        XCTAssertFalse(order.admit(older))
        let sameNanosecond = CaptureVideoFrameMetadata(displayTimeHostTicks: first.displayTimeHostTicks + 1,
            captureTimeNanoseconds: first.captureTimeNanoseconds, presentationTimeNanoseconds: 0, width: 800, height: 600)
        XCTAssertFalse(order.admit(sameNanosecond))
        XCTAssertTrue(order.admit(next))
        XCTAssertFalse(order.admit(first))
    }

    func test_capturedVideoFrameRetainsTheCompleteSampleBufferAndItsClockEvidence() throws {
        let sample = try captureSample()
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let frame = try XCTUnwrap(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        XCTAssertTrue(frame.imageBuffer === image)
        XCTAssertEqual(frame.metadata.width, 2); XCTAssertEqual(frame.metadata.height, 2)
        XCTAssertEqual(frame.metadata.captureTimeNanoseconds, 42_000_000_000)
        XCTAssertEqual(frame.metadata.presentationTimeNanoseconds, 3_500_000_000)
    }

    func test_capturedVideoFrameRejectsAbsentMalformedAndIncompleteAttachments() throws {
        let malformed: [(Any?, Any?)] = [
            (nil, NSNumber(value: displayTicks(seconds: 42))),
            (NSNumber(value: SCFrameStatus.complete.rawValue), nil),
            (NSNumber(value: false), NSNumber(value: displayTicks(seconds: 42))),
            (NSNumber(value: SCFrameStatus.complete.rawValue), NSNumber(value: true)),
            (NSNumber(value: 0.5), NSNumber(value: displayTicks(seconds: 42))),
            (NSNumber(value: SCFrameStatus.complete.rawValue), NSNumber(value: 5.5)),
            (NSNumber(value: SCFrameStatus.idle.rawValue), NSNumber(value: displayTicks(seconds: 42))),
        ]
        for (status, time) in malformed {
            let sample = try captureSample(status: status, displayTime: time)
            XCTAssertNil(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        }
        let sample = try captureSample()
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 41)))
    }

    func test_capturedVideoFrameRejectsInvalidAndNotReadyBuffers() throws {
        let pending = try captureSample(dataReady: false)
        XCTAssertTrue(pending.isValid); XCTAssertFalse(CMSampleBufferDataIsReady(pending))
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: pending, observedAtHostTime: displayTicks(seconds: 43)))
        let invalid = try captureSample()
        XCTAssertEqual(CMSampleBufferInvalidate(invalid), noErr)
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: invalid, observedAtHostTime: displayTicks(seconds: 43)))
    }

    private func displayTicks(seconds: Int64) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(value: seconds, timescale: 1))
    }

    private func frameMetadata(status: Int? = SCFrameStatus.complete.rawValue,
                               displayTime: UInt64? = CMClockConvertHostTimeToSystemUnits(CMTime(value: 42, timescale: 1)),
                               presentationTime: CMTime = CMTime(value: 7, timescale: 2),
                               width: Int = 800, height: Int = 600) -> CaptureVideoFrameMetadata? {
        CaptureVideoFrameMetadata.read(status: status,
            displayTimeHostTicks: displayTime,
            presentationTime: presentationTime, width: width, height: height,
            observedAtHostTime: displayTicks(seconds: 43))
    }

    private func captureSample(status: Any? = NSNumber(value: SCFrameStatus.complete.rawValue),
                               displayTime: Any? = NSNumber(value: CMClockConvertHostTimeToSystemUnits(CMTime(value: 42, timescale: 1))),
                               dataReady: Bool = true) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(image)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 7, timescale: 2), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer, dataReady: dataReady, makeDataReadyCallback: nil, makeDataReadyRefcon: nil,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        let rows = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) as? [NSMutableDictionary])
        let row = try XCTUnwrap(rows.first)
        if let status { row[SCStreamFrameInfo.status.rawValue] = status }
        if let displayTime {
            row[SCStreamFrameInfo.displayTime.rawValue] = displayTime
        }
        return result
    }

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
