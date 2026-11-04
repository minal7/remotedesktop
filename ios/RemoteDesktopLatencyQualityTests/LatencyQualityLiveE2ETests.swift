#if DEBUG
import UIKit
import Vision
import XCTest

/// Untimed, opt-in capture of an already-running, controller-owned lab session.
/// The external controller owns app/fixture launch and cancellation cleanup.
final class LatencyQualityLiveE2ETests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.threadmark.remotedesktop.client")

    func testCaptureF4AAndB() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LATENCY_QUALITY_E2E"] == "1" else {
            throw XCTSkip("Requires a reserved iPad, Debug host, and synthetic text fixture.")
        }
        let earliest = try XCTUnwrap(environment["LATENCY_QUALITY_NOT_BEFORE"]
            .flatMap { ISO8601DateFormatter().date(from: $0) })
        guard Date() >= earliest else { throw Failure.notReady("Device handoff has not happened") }
        let referenceSize = try integers(environment["LATENCY_QUALITY_REFERENCE_PIXELS"], count: 2)
        let referenceCrop = try integers(environment["LATENCY_QUALITY_REFERENCE_CROP"], count: 4)
        guard referenceSize.allSatisfy({ $0 > 0 }),
              referenceCrop[2] >= 8, referenceCrop[3] >= 8,
              referenceCrop[0] <= referenceSize[0], referenceCrop[1] <= referenceSize[1],
              referenceCrop[2] <= referenceSize[0] - referenceCrop[0],
              referenceCrop[3] <= referenceSize[1] - referenceCrop[1] else {
            throw Failure.notReady("Invalid reference or screenshot geometry")
        }
        guard app.wait(for: .runningForeground, timeout: 10) else {
            throw Failure.notReady("The controller-owned lab app is not in the foreground")
        }
        try waitForFixture()
        try selectF4(false)
        defer { try? selectF4(false) }
        let a = try capture("A", crop: nil, referenceSize: referenceSize, referenceCrop: referenceCrop)
        try selectF4(true)
        let b = try capture("B", crop: a.crop, referenceSize: referenceSize, referenceCrop: referenceCrop)
        XCTAssertEqual(a.width, b.width, "Do not rotate or change viewport geometry between arms")
        XCTAssertEqual(a.height, b.height)
        let record: [String: Any] = [
            "capture": "untimed_synthetic_text", "acceptance": "not assessed",
            "image_pixels": [a.width, a.height],
            "crop_pixels": [Int(a.crop.minX), Int(a.crop.minY), Int(a.crop.width), Int(a.crop.height)],
            "reference_pixels": referenceSize, "reference_crop_pixels": referenceCrop,
            "a_capture_uptime_s": a.time, "b_capture_uptime_s": b.time,
            "a_requested_f4": false, "b_requested_f4": true,
            "requires": "Verify client trace applied settings and F4 render path before interpreting screenshots"
        ]
        let metadata = XCTAttachment(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
        metadata.name = "latency-quality-geometry.json"; metadata.lifetime = .keepAlways
        add(metadata)
    }

    private func integers(_ value: String?, count: Int) throws -> [Int] {
        let parts = try XCTUnwrap(value).split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == count, numbers.count == count,
              numbers.allSatisfy({ $0 >= 0 && $0 <= 16384 }) else {
            throw Failure.notReady("Invalid bounded pixel geometry")
        }
        return numbers
    }

    private func selectF4(_ enabled: Bool) throws {
        // LatencyQuality exposes the existing Debug button at launch. Do not
        // send a multi-touch gesture through the remote-input surface.
        let open = app.buttons["Latency lab"]
        guard open.waitForExistence(timeout: 10), open.isHittable else {
            throw Failure.notReady("Debug latency settings are unavailable")
        }
        open.tap()
        let reset = app.buttons["Reset all experiments"]
        guard reset.waitForExistence(timeout: 5) else { throw Failure.notReady("Lab settings did not open") }
        reset.tap()
        let toggle = app.switches["Metal rendering at 120 Hz (F4)"]
        guard toggle.waitForExistence(timeout: 5), toggle.value as? String == "0" else {
            throw Failure.notReady("Could not establish the all-off baseline")
        }
        if enabled { toggle.tap() }
        guard toggle.value as? String == (enabled ? "1" : "0") else {
            throw Failure.notReady("Renderer selection did not change")
        }
        app.buttons["Apply to this session"].tap()
        let expected = "Quality F4 \(enabled ? "on" : "off"): ready"
        let status = app.staticTexts["latency-video-statistics"]
        let ready = NSPredicate { _, _ in status.exists && status.label.contains(expected) }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 45) == .completed else {
            throw Failure.notReady("The requested renderer has not presented a current frame")
        }
        // Allow static encoder quality to settle outside all timed windows.
        Thread.sleep(forTimeInterval: 5)
        try waitForFixture()
    }

    private func waitForFixture() throws {
        let deadline = Date().addingTimeInterval(45)
        repeat {
            if !app.descendants(matching: .any)["remote-input-unavailable"].exists,
               let image = XCUIScreen.main.screenshot().image.cgImage,
               try fixtureVisible(in: image) { return }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw Failure.notReady("Synthetic fixture is not visible on a ready remote screen")
    }

    private func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").uppercased()
    }

    private func fixtureVisible(in image: CGImage) throws -> Bool {
        try recognizedText(in: image).contains("LATENCY SHARPNESS FIXTURE")
    }

    private func capture(_ arm: String, crop previousCrop: CGRect?, referenceSize: [Int], referenceCrop: [Int]) throws -> (width: Int, height: Int, time: Double, crop: CGRect) {
        let screenshot = XCUIScreen.main.screenshot().image
        guard screenshot.imageOrientation == .up else { throw Failure.notReady("Screenshot orientation is not upright") }
        let image = try XCTUnwrap(screenshot.cgImage)
        let appFrame = app.frame
        let screen = UIScreen.main.bounds
        guard appFrame.origin == .zero, abs(appFrame.width - screen.width) < 0.5,
              abs(appFrame.height - screen.height) < 0.5, appFrame.width > 0, appFrame.height > 0 else {
            throw Failure.notReady("App must fill the screen without an offset")
        }
        let sx = CGFloat(image.width) / appFrame.width, sy = CGFloat(image.height) / appFrame.height
        guard sx.isFinite, sy.isFinite, sx > 0, abs(sx - sy) < 0.001 else {
            throw Failure.notReady("Screenshot must have uniform pixel scale")
        }
        let scale = min(CGFloat(image.width) / CGFloat(referenceSize[0]), CGFloat(image.height) / CGFloat(referenceSize[1]))
        let originX = (CGFloat(image.width) - CGFloat(referenceSize[0]) * scale) / 2
        let originY = (CGFloat(image.height) - CGFloat(referenceSize[1]) * scale) / 2
        let left = (originX + CGFloat(referenceCrop[0]) * scale).rounded()
        let top = (originY + CGFloat(referenceCrop[1]) * scale).rounded()
        let right = (originX + CGFloat(referenceCrop[0] + referenceCrop[2]) * scale).rounded()
        let bottom = (originY + CGFloat(referenceCrop[1] + referenceCrop[3]) * scale).rounded()
        let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard previousCrop == nil || previousCrop == crop else {
            throw Failure.notReady("Screenshot crop does not match the fixed aspect-fit reference geometry")
        }
        let status = app.staticTexts["latency-video-statistics"], button = app.buttons["Latency lab"]
        guard status.exists, button.exists, !status.frame.isEmpty, !button.frame.isEmpty else {
            throw Failure.notReady("Quality overlay is unavailable")
        }
        guard status.value as? String == "Zoom 100 percent",
              status.label.contains("\(referenceSize[0])×\(referenceSize[1])") else {
            throw Failure.notReady("Reference must match the native stream size at Fit zoom")
        }
        let overlay = status.frame.union(button.frame).insetBy(dx: -8, dy: -8)
        let overlayPixels = CGRect(x: overlay.minX * sx, y: overlay.minY * sy,
                                   width: overlay.width * sx, height: overlay.height * sy)
        guard !overlayPixels.intersects(crop) else { throw Failure.notReady("Quality overlay intersects the text crop") }
        guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(crop),
              try fixtureVisible(in: image), let text = image.cropping(to: crop) else {
            throw Failure.notReady("Fixed synthetic text crop is invalid")
        }
        let recognized = try recognizedText(in: text).replacingOccurrences(of: " ", with: "")
        guard ["READABLETEXT", "1234567890", "RENDER", "11PT", "12PT", "13PT"].allSatisfy(recognized.contains),
              let png = UIImage(cgImage: text).pngData() else {
            throw Failure.notReady("The fixed crop does not contain the expected synthetic text at all three sizes")
        }
        // Attach only the fixture's known rectangle, mapped once from its
        // reference geometry and unchanged between arms.
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "latency-quality-\(arm).png"; attachment.lifetime = .keepAlways
        add(attachment)
        return (image.width, image.height, ProcessInfo.processInfo.systemUptime, crop)
    }

    private enum Failure: Error { case notReady(String) }
}
#endif
