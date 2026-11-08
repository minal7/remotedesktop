import XCTest

/// Opt-in screenshots of the real remote-control UI. No text or pointer input
/// is sent to the Mac; only local keyboard/zoom controls are exercised.
final class EODReleaseUIReviewTests: XCTestCase {
    func testRemoteKeyboardPortraitAndLandscape() throws {
        guard ProcessInfo.processInfo.environment["RUN_EOD_RELEASE_UI_REVIEW"] == "1" else {
            throw XCTSkip("Opt in with the intended paired host and an unlocked test device.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        if app.state == .notRunning { app.launch() }
        else if app.state != .runningForeground { app.activate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try requireNoAlerts(app)
        let hosts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remote control "))
        XCTAssertTrue(hosts.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(hosts.count, 1, "Only the intended paired host may be selected.")
        record(app, name: "host-list-portrait")
        hosts.firstMatch.tap()
        let show = app.buttons["Show keyboard"]
        XCTAssertTrue(show.waitForExistence(timeout: 45))
        XCTAssertTrue(wait(15) { show.isEnabled && show.isHittable })
        try requireNoAlerts(app)
        record(app, name: "remote-idle-portrait")
        show.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(wait(5) { app.keyboards.firstMatch.exists })
            try requireNoAlerts(app)
            record(app, name: "remote-keyboard-\(name)")
            let dismissers = app.buttons.matching(NSPredicate(format: "label IN %@", ["Hide keyboard", "Hide remote keyboard"]))
            if ProcessInfo.processInfo.environment["RELEASE_UI_REQUIRE_SINGLE_HIDE"] == "1" {
                XCTAssertEqual(dismissers.count, 1, "Exactly one keyboard-hide control must be exposed.")
                XCTAssertTrue(dismissers.firstMatch.isHittable)
            }
        }
        let hide = app.buttons.matching(NSPredicate(format: "label IN %@", ["Hide keyboard", "Hide remote keyboard"])).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(hide)
        hide?.tap()
        XCTAssertTrue(wait(5) { !app.keyboards.firstMatch.exists })
        record(app, name: "remote-keyboard-dismissed-landscape")
    }

    private func requireNoAlerts(_ app: XCUIApplication) throws {
        if app.alerts.count > 0 || XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count > 0 {
            record(app, name: "unexpected-alert")
            XCTFail("An unexpected system or app alert appeared; it was left untouched.")
            throw NSError(domain: "EODReleaseUIReview", code: 1)
        }
    }

    private func record(_ app: XCUIApplication, name: String) {
        let utc = ISO8601DateFormatter().string(from: Date())
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-\(utc)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let controls = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show keyboard", "Hide keyboard", "Hide remote keyboard"]))
        let frames = controls.allElementsBoundByIndex.map { "\($0.label): frame=\($0.frame) hittable=\($0.isHittable)" }.joined(separator: "\n")
        let keyboardFrame = app.keyboards.firstMatch.exists ? String(describing: app.keyboards.firstMatch.frame) : "absent"
        let state = XCTAttachment(string: "timestamp_utc=\(utc)\nkeyboard_frame=\(keyboardFrame)\n\(frames)\n\(app.debugDescription)")
        state.name = "\(name)-accessibility-\(utc)"
        state.lifetime = .keepAlways
        add(state)
    }

    private func wait(_ seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return predicate()
    }
}
