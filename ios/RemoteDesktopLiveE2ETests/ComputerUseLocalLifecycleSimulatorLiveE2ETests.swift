import XCTest
import UIKit
import Vision

/// Separately opted-in lifecycle acceptance for the shipped Release iOS UI,
/// Production CloudKit, current signed host, and direct WebRTC input path.
///
/// The only Mac surface is `AcceptanceFixtures/LocalDeliveryQuote.html`.
/// Its fixed manual token changes local DOM text and has no network, submit,
/// account, payment, or transaction capability.
final class ComputerUseLocalLifecycleSimulatorLiveE2ETests: XCTestCase {
    private enum EnvironmentKey {
        static let liveSuite = "RUN_COMPUTER_USE_LIVE_E2E"
        static let thisTest =
            "RUN_COMPUTER_USE_LOCAL_LIFECYCLE_SIMULATOR_E2E"
    }

    private static let manualToken = "HUMAN-CONTROL-2468"
    private static let localFixturePhrases = [
        "this page is a no-network test surface",
        "fixture code",
        "waiting for the local test token",
    ]
    private static let stoppedResponse =
        "AI: Stopped. You're in control of the Mac."

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment[EnvironmentKey.liveSuite] == "1" else {
            throw XCTSkip(
                "Use the RemoteDesktopLiveE2E scheme for live Computer Use acceptance.")
        }
        guard environment[EnvironmentKey.thisTest] == "1" else {
            throw XCTSkip(
                "Set \(EnvironmentKey.thisTest)=1 only with a fresh LocalDeliveryQuote.html tab selected in Safari and Simulator hardware-keyboard input disconnected.")
        }
    }

    func testTakeControlManualInputResumeTakeControlAndStopThroughCurrentHost() throws {
        let app = XCUIApplication()
        var taskWasSent = false
        var taskReachedTerminalResponse = false
        var cleanupAssistantCount = 0
        defer {
            if taskWasSent, !taskReachedTerminalResponse {
                XCTAssertTrue(
                    ComputerUseLiveE2ECleanup.finishPendingTask(
                        in: app,
                        previousAssistantCount: cleanupAssistantCount),
                    "Cleanup could not obtain a terminal host cancellation; do not continue with another live task until the current host is inspected.")
            }
        }

        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        app.launch()
        try require(
            app.wait(for: .runningForeground, timeout: 10),
            "The shipped iOS client did not reach the foreground in Simulator.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on ")).firstMatch
        try require(
            readyButton.waitForExistence(timeout: 45),
            "A Release iOS client could not find an AI-ready Production host.")
        try require(
            readyButton.isHittable,
            "Use AI was not directly tappable in the shipped UI.")
        readyButton.tap()

        let liveScreen = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Live interactive screen for ")).firstMatch
        try require(
            liveScreen.waitForExistence(timeout: 45),
            "The shipped UI did not expose a decoded live Mac screen.")

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        try require(
            waitUntil(timeout: 45) { composer.exists && composer.isEnabled },
            "The Computer Use composer never became ready after live video arrived.")

        let prompt = """
        Bring Safari to the foreground so the already-open local no-network delivery quote fixture is visible, then just wait for me while I validate the takeover controls. This task is intentionally nonterminal. If I take control, type the fixture's manual marker, and resume, keep waiting while that local proof remains visible until I take control again and stop the task. Never click, type, scroll, press Return, navigate, sign in, check out, pay, or place an order.
        """
        let assistantCountBefore = assistantMessages(in: app).count
        cleanupAssistantCount = assistantCountBefore
        composer.tap()
        composer.typeText(prompt)

        let sendButton = app.buttons["Send request"]
        try require(
            waitUntil(timeout: 10) { sendButton.exists && sendButton.isEnabled },
            "The nonterminal local lifecycle request did not enable Send.")
        sendButton.tap()
        taskWasSent = true

        let sentMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "You: \(prompt)")).firstMatch
        try require(
            sentMessage.waitForExistence(timeout: 10),
            "The exact lifecycle request was not shown in the shipped conversation.")

        let initialObservationTransition = try waitForActiveLocalFixture(
            in: app,
            liveScreen: liveScreen,
            previousAssistantCount: assistantCountBefore,
            timeout: 120)
        attachSimulatorScreenshot(named: "Lifecycle fixture - AI observing")

        let takeControl = app.buttons["computer-use-take-control"]
        try require(
            takeControl.exists && takeControl.isHittable,
            "Take control was not available while the signed host was actively observing.")
        takeControl.tap()

        try assertManualControlBoundary(in: app)
        try require(
            !takeControl.exists,
            "Take control remained available after the shipped UI entered person control.")
        try require(
            liveScreenMatchesLocalFixture(
                Self.localFixturePhrases,
                in: liveScreen),
            "The Safari fixture lost focus at the manual-control boundary; refusing to prepare input for an unrelated Mac app.")

        // XCUITest can make GCKeyboard appear connected even when Simulator's
        // Connect Hardware Keyboard setting is off. `XCUIApplication.typeText`
        // does not generate that GameController HID stream, so explicitly use
        // the shipped takeover strip's on-screen keyboard in both states.
        let manualControl = app.descendants(matching: .any).matching(
            identifier: "computer-use-manual-control").firstMatch
        let keyboard = app.buttons["Keyboard"]
        if !keyboard.waitForExistence(timeout: 5) || !keyboard.isHittable {
            manualControl.swipeLeft()
        }
        try require(
            waitUntil(timeout: 5) { keyboard.exists && keyboard.isHittable },
            "The shipped takeover strip did not expose its direct-to-Mac on-screen keyboard.")
        keyboard.tap()

        let hideKeyboard = app.buttons["computer-use-hide-remote-keyboard"]
        try require(
            hideKeyboard.waitForExistence(timeout: 5),
            "The direct-to-Mac software keyboard did not open.")
        try require(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "Simulator did not present the software keyboard capture surface.")
        let focusedCapture = app.descendants(matching: .any).matching(
            NSPredicate(format: "hasKeyboardFocus == 1"))
        try require(
            waitUntil(timeout: 5) { focusedCapture.count > 0 },
            "The shipped direct-to-Mac capture field never received iOS keyboard focus.")
        try require(
            hideKeyboard.isHittable,
            "The keyboard accessory did not expose a directly usable dismiss control before sending manual input.")

        // XCUIApplication emits the fixed token through the focused
        // CaptureField. The shipped field forwards text messages over WebRTC
        // and must produce visible proof in the focused Safari field on Mac.
        app.typeText(Self.manualToken)

        hideKeyboard.tap()
        try require(
            waitUntil(timeout: 5) { app.buttons["Keyboard"].exists },
            "The takeover keyboard did not close and restore the full-size live screen.")

        try require(
            waitUntil(timeout: 20) {
                self.liveScreenContainsRequiredPhrases(
                    ["manual remote input confirmed"],
                    in: liveScreen)
            },
            "The inert Mac fixture did not visibly confirm direct remote keyboard input.")
        try require(
            assistantMessages(in: app).count == assistantCountBefore,
            "The host completed the task during person control instead of remaining paused.")
        try assertPausedDwell(
            in: app,
            previousAssistantCount: assistantCountBefore,
            duration: 3)

        let resume = app.buttons["computer-use-resume-ai"]
        try require(
            resume.exists && resume.isHittable,
            "Let AI continue was not available after direct manual input.")
        let statusBeforeResume = statusElement(in: app).label
        resume.tap()

        let explicitResumeProof = app.descendants(matching: .any).matching(
            identifier: "computer-use-human-resume-proof").firstMatch
        try require(
            explicitResumeProof.waitForExistence(timeout: 5),
            "The shipped Resume action did not emit its fixed human-resume proof.")

        let resumedObservationTransition = try waitForResumedHostObservation(
            in: app,
            liveScreen: liveScreen,
            previousAssistantCount: assistantCountBefore,
            statusBeforeResume: statusBeforeResume,
            timeout: 120)

        try require(
            takeControl.exists && takeControl.isHittable,
            "Take control did not return after the same host task resumed.")
        takeControl.tap()

        try assertManualControlBoundary(in: app)
        try require(
            waitUntil(timeout: 5) { !explicitResumeProof.exists },
            "The first-resume marker did not clear at the second distinct takeover.")

        let stop = app.buttons["computer-use-stop-task"]
        try require(
            stop.exists && stop.isHittable,
            "Stop task was not available during the second person-controlled interval.")
        stop.tap()

        let terminalMessages = assistantMessages(in: app)
        try require(
            waitUntil(timeout: 60) {
                terminalMessages.count > assistantCountBefore
            },
            "The current signed host did not acknowledge Stop task terminally.")
        let terminal = terminalMessages.element(
            boundBy: terminalMessages.count - 1)
        try require(
            terminal.label == Self.stoppedResponse,
            "The host did not return the exact shipped cancellation response: \(terminal.label)")
        taskReachedTerminalResponse = true

        try require(
            waitUntil(timeout: 10) { composer.exists && composer.isEnabled },
            "The shipped conversation did not return to ready after host cancellation.")
        try require(
            !app.buttons["computer-use-stop-task"].exists
                && !app.buttons["computer-use-resume-ai"].exists
                && !app.buttons["computer-use-take-control"].exists,
            "Lifecycle controls remained in an active-task state after terminal Stop.")
        let stoppedLiveScreen = XCTAttachment(screenshot: liveScreen.screenshot())
        stoppedLiveScreen.name = "Lifecycle streamed screen immediately after Stop"
        stoppedLiveScreen.lifetime = .keepAlways
        add(stoppedLiveScreen)
        attachSimulatorScreenshot(named: "Lifecycle full UI immediately after Stop")
        try require(
            waitUntil(timeout: 20) {
                self.liveScreenContainsRequiredPhrases(
                    ["manual remote input confirmed"],
                    in: liveScreen)
            },
            "The inert fixture's manual-input proof was not preserved after Stop.")
        try require(
            liveScreen.exists && app.state == .runningForeground,
            "The shipped app or live Mac screen disappeared after lifecycle completion.")

        let evidence = XCTAttachment(string: """
        OUTCOME: PASS
        APP FIRST: ordinary request -> shipped host brought Safari foreground
        FIRST TAKEOVER: shipped Take control -> paused UI boundary
        DIRECT INPUT: reported iOS keyboard route -> WebRTC -> inert Safari fixture proof
        INITIAL HOST STATUS: "\(initialObservationTransition.before)" -> "\(initialObservationTransition.after)"
        RESUME: shipped Let AI continue marker + fresh host visual observation
        RESUMED HOST STATUS: "\(resumedObservationTransition.before)" -> "\(resumedObservationTransition.after)"
        SECOND TAKEOVER: resume marker cleared and paused UI boundary returned
        STOP: exact host response "Stopped. You're in control of the Mac."
        EXTERNAL EFFECTS: none; local fixture only
        """)
        evidence.name = "Local Computer Use lifecycle shipped-path evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
        attachSimulatorScreenshot(named: "Lifecycle fixture - stopped cleanly")
    }

    private func waitForActiveLocalFixture(
        in app: XCUIApplication,
        liveScreen: XCUIElement,
        previousAssistantCount: Int,
        timeout: TimeInterval
    ) throws -> StatusTransitionEvidence {
        let status = statusElement(in: app)
        let takeControl = app.buttons["computer-use-take-control"]
        let deadline = Date().addingTimeInterval(timeout)
        var nextVisualCheck = Date.distantPast
        var fixtureIsVisible = false
        var latestVisualEvidence = LocalFixtureVisualEvidence.unavailable
        var statusAtFixtureProof: String?

        repeat {
            try assertNoUnexpectedTaskOutcome(
                in: app,
                previousAssistantCount: previousAssistantCount)
            if !fixtureIsVisible, Date() >= nextVisualCheck {
                latestVisualEvidence = localFixtureVisualEvidence(
                    Self.localFixturePhrases,
                    in: liveScreen)
                fixtureIsVisible = latestVisualEvidence.matches
                nextVisualCheck = Date().addingTimeInterval(1)
            }
            let currentStatus = status.label
            if fixtureIsVisible,
               statusAtFixtureProof == nil,
               !currentStatus.isEmpty {
                statusAtFixtureProof = currentStatus
            }
            if let statusAtFixtureProof,
               currentStatus != statusAtFixtureProof,
               !currentStatus.isEmpty,
               !currentStatus.localizedCaseInsensitiveContains("AI paused"),
               takeControl.exists,
               takeControl.isHittable,
               fixtureIsVisible {
                return StatusTransitionEvidence(
                    before: statusAtFixtureProof,
                    after: currentStatus)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let diagnostics = XCTAttachment(string: """
        VISUAL EVIDENCE: \(latestVisualEvidence.diagnosticSummary)
        STATUS AT FIXTURE PROOF: \(statusAtFixtureProof ?? "unavailable")
        STATUS CURRENT: \(status.label)
        TAKE CONTROL EXISTS: \(takeControl.exists)
        TAKE CONTROL HITTABLE: \(takeControl.isHittable)
        """)
        diagnostics.name = "Local fixture matcher diagnostics"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
        XCTFail(
            "The signed host never exposed the focused local Safari fixture with active observation and Take control available.")
        throw AcceptanceFailure.timedOut
    }

    private func waitForResumedHostObservation(
        in app: XCUIApplication,
        liveScreen: XCUIElement,
        previousAssistantCount: Int,
        statusBeforeResume: String,
        timeout: TimeInterval
    ) throws -> StatusTransitionEvidence {
        let status = statusElement(in: app)
        let takeControl = app.buttons["computer-use-take-control"]
        let deadline = Date().addingTimeInterval(timeout)
        var nextVisualCheck = Date.distantPast
        var manualProofIsVisible = false

        repeat {
            try assertNoUnexpectedTaskOutcome(
                in: app,
                previousAssistantCount: previousAssistantCount)
            if !manualProofIsVisible, Date() >= nextVisualCheck {
                manualProofIsVisible = liveScreenContainsRequiredPhrases(
                    ["manual remote input confirmed"],
                    in: liveScreen)
                nextVisualCheck = Date().addingTimeInterval(1)
            }
            let currentStatus = status.label
            if manualProofIsVisible,
               currentStatus != statusBeforeResume,
               !currentStatus.isEmpty,
               !currentStatus.localizedCaseInsensitiveContains("AI paused"),
               takeControl.exists,
               takeControl.isHittable {
                return StatusTransitionEvidence(
                    before: statusBeforeResume,
                    after: currentStatus)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let diagnostics = XCTAttachment(string: """
        STATUS BEFORE RESUME: \(statusBeforeResume)
        STATUS CURRENT: \(status.label)
        MANUAL PROOF VISIBLE: \(manualProofIsVisible)
        TAKE CONTROL EXISTS: \(takeControl.exists)
        TAKE CONTROL HITTABLE: \(takeControl.isHittable)
        """)
        diagnostics.name = "Resumed host status-transition diagnostics"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
        XCTFail(
            "Let AI continue never produced fresh host visual-observation progress for the same task.")
        throw AcceptanceFailure.timedOut
    }

    private func assertManualControlBoundary(in app: XCUIApplication) throws {
        let manualControl = app.descendants(matching: .any).matching(
            identifier: "computer-use-manual-control").firstMatch
        let stop = app.buttons["computer-use-stop-task"]
        let resume = app.buttons["computer-use-resume-ai"]
        let status = statusElement(in: app)

        try require(
            waitUntil(timeout: 10) {
                manualControl.exists
                    && stop.exists
                    && resume.exists
                    && status.label.localizedCaseInsensitiveContains(
                        "AI paused")
            },
            "The shipped UI did not establish the complete person-controlled boundary.")
        try require(
            stop.isHittable && resume.isHittable,
            "Stop task and Let AI continue were not directly usable during takeover.")
    }

    private func assertPausedDwell(
        in app: XCUIApplication,
        previousAssistantCount: Int,
        duration: TimeInterval
    ) throws {
        let manualControl = app.descendants(matching: .any).matching(
            identifier: "computer-use-manual-control").firstMatch
        let stop = app.buttons["computer-use-stop-task"]
        let resume = app.buttons["computer-use-resume-ai"]
        let takeControl = app.buttons["computer-use-take-control"]
        let status = statusElement(in: app)
        let deadline = Date().addingTimeInterval(duration)

        repeat {
            try require(
                manualControl.exists
                    && stop.exists
                    && resume.exists
                    && !takeControl.exists
                    && status.label.localizedCaseInsensitiveContains(
                        "AI paused")
                    && assistantMessages(in: app).count
                        == previousAssistantCount
                    && app.state == .runningForeground,
                "The host or shipped UI left the person-controlled boundary during the paused dwell.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
    }

    private func assertNoUnexpectedTaskOutcome(
        in app: XCUIApplication,
        previousAssistantCount: Int
    ) throws {
        let approval = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Approve before AI continues")).firstMatch
        let intervention = app.descendants(matching: .any).matching(
            identifier: "computer-use-intervention-guidance").firstMatch
        let retry = app.buttons["Retry sending the last request"]
        let forbiddenInput = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: (clicking|double-clicking|right-clicking|dragging|typing .+|scrolling .+|pressing Return|using a keyboard shortcut).*"#)).firstMatch

        if approval.exists {
            XCTFail("The inert WAIT task unexpectedly requested approval.")
            throw AcceptanceFailure.unexpectedTaskOutcome
        }
        if intervention.exists {
            XCTFail(
                "The host requires a manual prerequisite. This test will not operate macOS privacy prompts.")
            throw AcceptanceFailure.unexpectedTaskOutcome
        }
        if retry.exists {
            XCTFail("The lifecycle control request failed in Production CloudKit transport.")
            throw AcceptanceFailure.transportFailure
        }
        if forbiddenInput.exists {
            XCTFail(
                "OS-Atlas attempted native input during a WAIT-only lifecycle task.")
            throw AcceptanceFailure.unexpectedTaskOutcome
        }
        if assistantMessages(in: app).count > previousAssistantCount {
            XCTFail(
                "The deliberately nonterminal task completed before lifecycle controls were exercised.")
            throw AcceptanceFailure.unexpectedTaskOutcome
        }
    }

    private func liveScreenContains(
        _ requiredPhrases: [String],
        in liveScreen: XCUIElement
    ) -> Bool {
        guard liveScreen.exists,
              let image = liveScreen.screenshot().image.cgImage,
              let recognized = try? recognizedText(in: image) else {
            return false
        }
        let text = canonical(recognized)
        return requiredPhrases.allSatisfy { text.contains(canonical($0)) }
    }

    /// Requires both the fixture text and its large heading geometry.
    /// Phrase-only OCR is unsafe here: another foreground app can quote the
    /// fixture instructions or show a tiny screenshot while still owning Mac
    /// keyboard focus.
    private func liveScreenMatchesLocalFixture(
        _ requiredPhrases: [String],
        in liveScreen: XCUIElement
    ) -> Bool {
        localFixtureVisualEvidence(requiredPhrases, in: liveScreen).matches
    }

    /// Once the full fixture identity and heading geometry have passed, later
    /// lifecycle checks only need the exact state marker. The confirmation
    /// banner expands the page and can move the original heading behind the
    /// shipped zoom controls without changing the streamed proof itself.
    private func liveScreenContainsRequiredPhrases(
        _ requiredPhrases: [String],
        in liveScreen: XCUIElement
    ) -> Bool {
        let evidence = localFixtureVisualEvidence(
            requiredPhrases,
            in: liveScreen)
        return !evidence.phraseMatches.isEmpty
            && evidence.phraseMatches.allSatisfy { $0 }
    }

    private func localFixtureVisualEvidence(
        _ requiredPhrases: [String],
        in liveScreen: XCUIElement
    ) -> LocalFixtureVisualEvidence {
        guard liveScreen.exists,
              let image = liveScreen.screenshot().image.cgImage,
              let observations = try? recognizedTextObservations(in: image)
        else {
            return .unavailable
        }

        let text = canonical(observations.map(\.text).joined(separator: " "))
        let headingObservations = observations.filter {
            canonical($0.text).contains("delivery quote setup")
        }
        let largestHeading = headingObservations.max {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }
        let phraseMatches = requiredPhrases.map {
            text.contains(canonical($0))
        }
        let fixtureKeywords: [String] = [
            "delivery", "quote", "setup", "local", "fixture", "waiting",
            "token", "code",
        ]
        let fixtureRelevantObservations: [String] = observations.compactMap {
            observation -> String? in
            let observationText = canonical(observation.text)
            guard fixtureKeywords.contains(where: { observationText.contains($0) })
            else { return nil }
            return String(
                format: "\"%@\" x=%.4f y=%.4f width=%.4f height=%.4f",
                observationText,
                observation.boundingBox.minX,
                observation.boundingBox.minY,
                observation.boundingBox.width,
                observation.boundingBox.height)
        }
        return LocalFixtureVisualEvidence(
            observationCount: observations.count,
            hasDeliveryWord: text.contains("delivery"),
            hasQuoteWord: text.contains("quote"),
            hasSetupWord: text.contains("setup"),
            headingWidth: largestHeading?.boundingBox.width ?? 0,
            headingHeight: largestHeading?.boundingBox.height ?? 0,
            phraseMatches: phraseMatches,
            fixtureRelevantObservations: fixtureRelevantObservations)
    }

    private func recognizedText(in image: CGImage) throws -> String {
        try recognizedTextObservations(in: image)
            .map(\.text)
            .joined(separator: " ")
    }

    private func recognizedTextObservations(
        in image: CGImage
    ) throws -> [(text: String, boundingBox: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: image, orientation: .up)
            .perform([request])
        return (request.results ?? []).compactMap {
            guard let candidate = $0.topCandidates(1).first else { return nil }
            return (candidate.string, $0.boundingBox)
        }
    }

    private func canonical(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func statusElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
    }

    private func assistantMessages(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI: "))
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String
    ) throws {
        guard condition() else {
            XCTFail(message())
            throw AcceptanceFailure.assertionFailed
        }
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

    private func attachSimulatorScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum AcceptanceFailure: Error {
        case assertionFailed
        case unexpectedTaskOutcome
        case transportFailure
        case timedOut
    }

    private struct StatusTransitionEvidence {
        let before: String
        let after: String
    }

    private struct LocalFixtureVisualEvidence {
        let observationCount: Int
        let hasDeliveryWord: Bool
        let hasQuoteWord: Bool
        let hasSetupWord: Bool
        let headingWidth: CGFloat
        let headingHeight: CGFloat
        let phraseMatches: [Bool]
        let fixtureRelevantObservations: [String]

        static let unavailable = LocalFixtureVisualEvidence(
            observationCount: 0,
            hasDeliveryWord: false,
            hasQuoteWord: false,
            hasSetupWord: false,
            headingWidth: 0,
            headingHeight: 0,
            phraseMatches: [],
            fixtureRelevantObservations: [])

        var matches: Bool {
            headingHeight >= 0.035
                && headingWidth >= 0.20
                && !phraseMatches.isEmpty
                && phraseMatches.allSatisfy { $0 }
        }

        var diagnosticSummary: String {
            "observations=\(observationCount), "
                + "delivery=\(hasDeliveryWord), quote=\(hasQuoteWord), "
                + "setup=\(hasSetupWord), "
                + String(
                    format: "headingWidth=%.4f, headingHeight=%.4f, ",
                    headingWidth,
                    headingHeight)
                + "requiredPhraseMatches=\(phraseMatches), "
                + "fixtureRelevantObservations="
                + fixtureRelevantObservations.joined(separator: " | ")
        }
    }
}
