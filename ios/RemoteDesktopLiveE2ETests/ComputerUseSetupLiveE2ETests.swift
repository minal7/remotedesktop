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

    func testPhoneCanReachTerminalReadyStateForComputerUseSetup() throws {
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
            assertSetupReachesReady(readyButtons.firstMatch)
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
                    assertSetupReachesReady(readyButtons.firstMatch)
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
        assertSetupReachesReady(readyButtons.firstMatch)
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

    private func assertSetupReachesReady(_ readyButton: XCUIElement) {
        XCTAssertTrue(
            readyButton.waitForExistence(timeout: 30 * 60),
            "AI setup never reached the terminal ready state on the phone.")
        assertReady(readyButton)
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

/// Separately opted-in proof that a current signed host sends, and the Release
/// iOS client decodes, the typed terminal result carried by the production
/// Computer Use channel. The deliberately incomplete Mail request is stopped
/// by the host's deterministic clarification preflight before any Mac app,
/// model inference, approval, or external action can begin.
final class ComputerUseTypedTerminalOutcomeSimulatorLiveE2ETests: XCTestCase {
    private enum EnvironmentKey {
        static let liveSuite = "RUN_COMPUTER_USE_LIVE_E2E"
        static let thisTest =
            "RUN_COMPUTER_USE_TYPED_OUTCOME_SIMULATOR_E2E"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment[EnvironmentKey.liveSuite] == "1" else {
            throw XCTSkip(
                "Use the RemoteDesktopLiveE2E scheme for live Computer Use acceptance.")
        }
        guard environment[EnvironmentKey.thisTest] == "1" else {
            throw XCTSkip(
                "Set \(EnvironmentKey.thisTest)=1 to run the no-action typed-outcome acceptance test.")
        }
    }

    func testDeterministicClarificationCarriesTypedUserInterventionOutcome() throws {
        let app = XCUIApplication()
        var taskWasSent = false
        var taskReachedTerminalResponse = false
        var assistantCountBefore = 0
        defer {
            if taskWasSent, !taskReachedTerminalResponse {
                XCTAssertTrue(
                    ComputerUseLiveE2ECleanup.finishPendingTask(
                        in: app,
                        previousAssistantCount: assistantCountBefore),
                    "Cleanup could not obtain a terminal host response; inspect the current host before running another live task.")
            }
        }

        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The Release iOS client did not reach the foreground in Simulator.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButtons = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on "))
        XCTAssertTrue(
            waitUntil(timeout: 45) { readyButtons.count > 0 },
            "A current AI-ready Production host did not appear.")
        XCTAssertEqual(
            readyButtons.count,
            1,
            "More than one AI-ready Production host appeared; refusing to send the live request to an ambiguous first match.")
        let readyButton = readyButtons.element(boundBy: 0)
        XCTAssertTrue(
            readyButton.isHittable,
            "Use AI was not directly tappable in Simulator.")
        readyButton.tap()

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        let hostUpdateRequired = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Update Remote Desktop Host on this Mac before using AI Computer Use"))
            .firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 45) {
                (composer.exists && composer.isEnabled)
                    || hostUpdateRequired.exists
            },
            "The Computer Use conversation neither became ready nor reported a host compatibility error.")
        guard !hostUpdateRequired.exists else {
            XCTFail(
                "The installed signed Mac host is older than this Release iOS client. Install and relaunch the current host before verifying typed outcomes.")
            return
        }

        let prompt = "Send an email"
        let expectedClarification =
            "AI: Who should receive the email, and what should it say?"
        assistantCountBefore = assistantMessages(in: app).count
        let clarificationCountBefore = app.staticTexts.matching(
            NSPredicate(format: "label == %@", expectedClarification)).count
        composer.tap()
        composer.typeText(prompt)

        let sendButton = app.buttons["Send request"]
        XCTAssertTrue(
            waitUntil(timeout: 10) { sendButton.exists && sendButton.isEnabled },
            "The deterministic clarification prompt did not enable Send.")
        sendButton.tap()
        taskWasSent = true

        XCTAssertTrue(
            waitUntil(timeout: 60) {
                assistantMessages(in: app).count > assistantCountBefore
                    && app.staticTexts.matching(
                        NSPredicate(
                            format: "label == %@",
                            expectedClarification)).count > clarificationCountBefore
            },
            "The host did not append a new no-action deterministic clarification for this request.")
        taskReachedTerminalResponse = true

        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                (status.value as? String) == "User intervention required"
                    && composer.exists
                    && composer.isEnabled
            },
            "iOS displayed the clarification but did not expose the typed user-intervention outcome. Status value: \(String(describing: status.value))")
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "computer-use-intervention-guidance"].exists,
            "A terminal clarification was incorrectly shown as a resumable takeover.")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Approve before AI continues"))
                .firstMatch.exists,
            "The no-action clarification unexpectedly entered approval.")
        XCTAssertFalse(
            app.buttons["computer-use-take-control"].exists
                || app.buttons["computer-use-resume-ai"].exists
                || app.buttons["computer-use-stop-task"].exists,
            "Terminal clarification left lifecycle controls active.")
    }

    private func assistantMessages(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI: "))
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
