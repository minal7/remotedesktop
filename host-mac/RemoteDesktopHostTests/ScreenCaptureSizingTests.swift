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
