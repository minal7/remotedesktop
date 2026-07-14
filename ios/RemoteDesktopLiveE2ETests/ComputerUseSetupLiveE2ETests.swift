import XCTest

/// Manual acceptance coverage for the real iOS -> CloudKit -> macOS setup
/// path. This lives in an explicitly named scheme that injects a test-only
/// opt-in, so routine unit-test runs can never start a multi-gigabyte download.
final class ComputerUseSetupLiveE2ETests: XCTestCase {
    private let optInEnvironmentKey = "RUN_COMPUTER_USE_LIVE_E2E"

    private enum HostSetupState {
        case ready(XCUIElement)
        case progress(XCUIElement)
        case setup(XCUIElement)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(optInEnvironmentKey)=1 to run the phone-driven setup acceptance test.")
        }
    }

    func testPhoneCanStartSetupOrRecognizeAnAlreadyReadyHost() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The iOS client did not reach the foreground.")

        // Exercise the interruption monitor without tapping a device or setup
        // action when no permission alert is present.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let setupButtons = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Set up AI Computer Use on ",
                "Retry AI setup on "))
        let progressElements = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Setting up AI Computer Use on "))
        let readyButtons = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on "))

        guard let initialState = waitForHostState(
            ready: readyButtons.firstMatch,
            progress: progressElements.firstMatch,
            setup: setupButtons.firstMatch,
            timeout: 45
        ) else {
            XCTFail("A nearby AI-capable Mac did not appear in setup, progress, or ready state.")
            return
        }

        switch initialState {
        case .ready(let readyButton):
            assertReady(readyButton)
            return

        case .progress(let progressElement):
            assertProgress(progressElement)
            return

        case .setup(let setupButton):
            // A just-launched client can briefly render an older setup
            // advertisement while Bonjour/CloudKit refreshes. Give a ready
            // or in-progress state two polling intervals to supersede it
            // before sending any new setup request.
            if let settledState = waitForReadyOrProgress(
                ready: readyButtons.firstMatch,
                progress: progressElements.firstMatch,
                timeout: 6
            ) {
                switch settledState {
                case .ready(let readyButton):
                    assertReady(readyButton)
                case .progress(let progressElement):
                    assertProgress(progressElement)
                case .setup:
                    XCTFail("The setup-settling helper returned an invalid state.")
                }
                return
            }

            XCTAssertTrue(setupButton.exists, "The setup-capable Mac disappeared before setup began.")
            XCTAssertTrue(setupButton.isEnabled, "The phone-displayed setup action should be enabled.")
            setupButton.tap()
        }

        XCTAssertTrue(
            progressElements.firstMatch.waitForExistence(timeout: 90),
            "The phone did not receive queued/download progress from the Mac through CloudKit.")

        assertProgress(progressElements.firstMatch)
    }

    private func waitForHostState(
        ready: XCUIElement,
        progress: XCUIElement,
        setup: XCUIElement,
        timeout: TimeInterval
    ) -> HostSetupState? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            // Ready wins when multiple advertisements are briefly visible. It
            // is the only branch that guarantees this test cannot start an
            // unnecessary download on a host that is already usable.
            if ready.exists { return .ready(ready) }
            if progress.exists { return .progress(progress) }
            if setup.exists { return .setup(setup) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return nil
    }

    private func waitForReadyOrProgress(
        ready: XCUIElement,
        progress: XCUIElement,
        timeout: TimeInterval
    ) -> HostSetupState? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if ready.exists { return .ready(ready) }
            if progress.exists { return .progress(progress) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return nil
    }

    private func assertReady(_ readyButton: XCUIElement) {
        XCTAssertTrue(readyButton.isEnabled, "An already-ready AI host should remain usable.")
        XCTAssertTrue(readyButton.isHittable, "Use AI should be visible and accessible to the user.")
    }

    private func assertProgress(_ progressElement: XCUIElement) {
        let progressValue = progressElement.value as? String ?? ""
        XCTAssertFalse(progressValue.isEmpty, "Setup progress should include a user-facing phase or percentage.")
    }
}

/// Manual acceptance for the real phone -> CloudKit -> local host automation
/// loop. The ordinary test scheme never includes this target, and the
/// live scheme retains the explicit environment opt-in above.
final class ComputerUseTaskLiveE2ETests: XCTestCase {
    private let optInEnvironmentKey = "RUN_COMPUTER_USE_LIVE_E2E"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(optInEnvironmentKey)=1 to run the live Computer Use task test.")
        }
    }

    func testSinglePhonePromptCalculatesInCalculatorThroughLocalComputerUse() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The iOS client did not reach the foreground.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on ")).firstMatch
        XCTAssertTrue(
            readyButton.waitForExistence(timeout: 45),
            "An AI-ready Mac did not appear.")
        XCTAssertTrue(readyButton.isHittable, "Use AI must be directly tappable.")
        readyButton.tap()

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 45) { composer.exists && composer.isEnabled },
            "The connected Computer Use chat did not become ready for a request.")
        composer.tap()
        composer.typeText(
            "Open Calculator, clear it, calculate 27 times 43, and stop only when the Calculator display shows 1161.")

        let sendButton = app.buttons["Send request"]
        XCTAssertTrue(
            waitUntil(timeout: 10) { sendButton.exists && sendButton.isEnabled },
            "The typed one-prompt task did not enable Send.")
        sendButton.tap()

        // The host only emits this value-bearing completion after it has
        // cleared Calculator, entered the expression, and verified both the
        // expression and result through Accessibility. A generic "Done" is
        // intentionally insufficient for this end-to-end acceptance gate.
        let success = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@",
                "AI: Calculator displays 1161.")).firstMatch
        let failure = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI: I couldn't")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 150) { success.exists || failure.exists },
            "The host did not return a terminal result for the Calculator calculation task.")
        XCTAssertFalse(
            failure.exists,
            "Local Computer Use returned a failure: \(failure.label)")
        XCTAssertTrue(
            success.exists,
            "The host did not report the AX-verified Calculator result 1161.")
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return predicate()
    }
}
