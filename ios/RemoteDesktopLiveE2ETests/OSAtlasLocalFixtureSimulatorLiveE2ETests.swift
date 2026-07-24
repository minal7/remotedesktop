import XCTest
import UIKit
import Vision

/// Opt-in shipped-path acceptance for the real configuration-matched signed
/// iOS client, its authenticated local LAN broker, the signed macOS host,
/// installed OS-Atlas checkpoint, native macOS input injection, fresh visual
/// sidecar frames, and a typed terminal result.
///
/// The Mac prerequisite is the repository's local-only Safari fixture. It has
/// no form action or network capability. The request starts in an unrelated
/// frontmost app, so the host must open Safari first. The installed OS-Atlas
/// checkpoint must ground one harmless setup-button click before the host can
/// enter the exact token and scroll until the production local OCR validator
/// can return the exact facts.
final class OSAtlasLocalFixtureSimulatorLiveE2ETests: XCTestCase {
    private enum EnvironmentKey {
        static let liveSuite = "RUN_COMPUTER_USE_LIVE_E2E"
        static let thisTest = "RUN_OSATLAS_LOCAL_FIXTURE_SIMULATOR_E2E"
    }

    private static let fixtureToken = "LOCAL-QUOTE-7421"
    private static let promptChannelReadyTimeout: TimeInterval = 45
    private static let visualSidecarLiveTimeout: TimeInterval = 45
    private static let freshCalculatorFrameTimeout: TimeInterval = 20
    private static let screenCaptureConsentGuidance =
        "macOS needs your permission before AI can use the screen. On the Mac, choose Allow in the “RemoteDesktopHost” screen-and-audio access prompt, then tap Let AI continue. AI won’t click this system permission prompt or open System Settings."
    private static let screenCaptureConsentTimeout: TimeInterval = 15 * 60
    private static let expectedFields: [(label: String, value: String)] = [
        ("Restaurant", "Pizzeria Uno"),
        ("Item", "Large Pepperoni Pizza"),
        ("Subtotal", "$24.99"),
        ("Delivery fee", "$2.99"),
        ("Service fee", "$3.75"),
        ("Tax", "$2.78"),
        ("Total", "$34.51"),
        ("ETA", "28–38 min"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment[EnvironmentKey.liveSuite] == "1" else {
            throw XCTSkip(
                "Use the RemoteDesktopLiveE2E scheme for live Computer Use acceptance.")
        }
        guard environment[EnvironmentKey.thisTest] == "1" else {
            throw XCTSkip(
                "Set \(EnvironmentKey.thisTest)=1 only after LocalDeliveryQuote.html is freshly loaded in a background Safari tab, its setup button is still unclicked, and Calculator is genuinely frontmost.")
        }
    }

    func testLocalFixtureUsesShippedHybridAppFirstNativeTypeAndScrollBeforeVisibleQuote() throws {
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

        try ComputerUseLiveE2EPreflight
            .launchAfterSimulatorRegistrationSettles(app)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The shipped iOS client did not reach the foreground in Simulator.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on ")).firstMatch
        let legacyPairButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Pair local AI Computer Use on ")).firstMatch
        XCTAssertTrue(
            readyButton.waitForExistence(timeout: 90),
            "The iOS client did not automatically pair with the same-iCloud local AI host.")
        XCTAssertFalse(
            legacyPairButton.exists,
            "The shipped client must never ask for a local AI access key.")
        XCTAssertFalse(
            app.textFields["Pairing code"].exists,
            "The shipped client must not expose a pairing-code entry field.")
        XCTAssertTrue(
            readyButton.isHittable,
            "Use AI must be directly tappable in Simulator.")
        readyButton.tap()

        let promptChannel = app.descendants(matching: .any).matching(
            identifier: "computer-use-local-prompt-channel").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: Self.promptChannelReadyTimeout) {
                promptChannel.exists
                    && (promptChannel.value as? String) == "Ready"
            },
            "The TLS-authenticated local AI prompt channel did not become Ready within \(Int(Self.promptChannelReadyTimeout)) seconds. This assertion is independent of the optional visual sidecar. Last value: \(String(describing: promptChannel.value))")

        let liveScreen = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Live interactive screen for ")).firstMatch
        XCTAssertTrue(
            liveScreen.waitForExistence(
                timeout: Self.visualSidecarLiveTimeout),
            "The TLS prompt channel is ready, but B01's optional product media sidecar did not become live with a compatible host, current display metadata, and a fresh decoded frame within \(Int(Self.visualSidecarLiveTimeout)) seconds. Media remains independent of task transport, but is mandatory evidence for this visual acceptance case.")

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 45) { composer.exists && composer.isEnabled },
            "The Simulator conversation did not become ready over the authenticated local connection.")

        var initialStreamRecognition = ""
        XCTAssertTrue(
            waitUntil(timeout: Self.freshCalculatorFrameTimeout) {
                guard let recognized = fixtureProofRecognition(
                    in: liveScreen) else {
                    return false
                }
                initialStreamRecognition = recognized
                let text = canonical(recognized)
                return text.contains("calculator")
                    && !text.contains("safari")
                    && !text.contains("delivery quote setup")
                    && !text.contains("start local quote setup")
                    && !text.contains("fixture code")
            },
            "The visual sidecar reported live, but B01 did not decode the fresh Calculator starting frame within \(Int(Self.freshCalculatorFrameTimeout)) seconds. Safari, fixture, and stale-frame text are rejected. Vision last saw: \(initialStreamRecognition)")

        attachSimulatorScreenshot(named: "Local OS-Atlas fixture - before request")

        let prompt = """
        Please open Safari and use the local no-network delivery quote page that's already loaded there. First activate the visible Start local quote setup button, then enter the fixture code \(Self.fixtureToken) into the field labeled Fixture code. Scroll down until the whole itemized quote is visible and tell me the restaurant, item, subtotal, every fee, tax, total, and ETA. Don't sign in, check out, pay, or place an order.
        """
        let assistantCountBefore = assistantMessages(in: app).count
        let userMessages = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "You: "))
        let userCountBefore = userMessages.count
        cleanupAssistantCount = assistantCountBefore
        composer.tap()
        composer.typeText(prompt)

        let sendButton = app.buttons["Send request"]
        XCTAssertTrue(
            waitUntil(timeout: 10) { sendButton.exists && sendButton.isEnabled },
            "The local-fixture request did not enable Send.")
        sendButton.tap()
        taskWasSent = true

        let sentMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "You: \(prompt)")).firstMatch
        XCTAssertTrue(
            sentMessage.waitForExistence(timeout: 10),
            "The exact local-fixture request was not shown in the shipped conversation.")
        XCTAssertEqual(
            userMessages.count,
            userCountBefore + 1,
            "The one natural-language browser request was submitted more than once.")

        let terminal = try waitForFixtureResult(
            in: app,
            liveScreen: liveScreen,
            previousAssistantCount: assistantCountBefore,
            timeout: 300)
        taskReachedTerminalResponse = true
        XCTAssertEqual(
            assistantMessages(in: app).count,
            assistantCountBefore + 1,
            "The one browser request produced more than one terminal assistant response.")
        XCTAssertTrue(
            terminal.sawRequestedApplicationOpenProgress,
            "The task returned without app-first open progress.")
        XCTAssertTrue(
            terminal.sawSafariFixtureBeforeNativeType,
            "The stream never proved Safari and the requested fixture were foreground before native typing.")
        XCTAssertTrue(
            terminal.sawOSAtlasPointerClickProgress,
            "The task returned without visible progress for the required OS-Atlas-grounded setup click.")
        XCTAssertTrue(
            terminal.sawSetupActivationEffectBeforeNativeType,
            "The streamed fixture never showed the setup button's local activation effect after pointer-click progress and before native typing.")
        XCTAssertTrue(
            terminal.sawNativeTypeProgress,
            "The task returned without exposing native text-entry progress in the shipped UI.")
        XCTAssertTrue(
            terminal.sawNativeScrollProgress,
            "The task returned without exposing native scrolling progress in the shipped UI.")

        let response = terminal.assistantLabel.replacingOccurrences(
            of: "AI: ",
            with: "",
            options: .anchored)
        XCTAssertTrue(
            response.hasPrefix("Visible delivery quote — "),
            "Only the production complete-screen quote validator is accepted: \(response)")
        assertExactFixtureFields(in: response)

        // The quote text proves the visible browser postcondition. This
        // stable accessibility value separately proves that the iOS client
        // decoded the host's typed terminal outcome instead of inferring
        // success from assistant prose.
        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                (status.value as? String) == "Task completed"
                    && composer.exists
                    && composer.isEnabled
            },
            "iOS displayed the verified browser result but did not expose the typed task-completed outcome. Status value: \(String(describing: status.value))")
        XCTAssertFalse(
            app.buttons["computer-use-take-control"].exists
                || app.buttons["computer-use-resume-ai"].exists
                || app.buttons["computer-use-stop-task"].exists,
            "The completed browser task left lifecycle controls active.")
        XCTAssertEqual(
            userMessages.count,
            userCountBefore + 1,
            "The local browser task created more than one user request before reaching its terminal result.")

        var lastStreamRecognition = ""
        let streamProofIsVisible = waitUntil(timeout: 20) {
            guard let recognized = fixtureProofRecognition(in: liveScreen) else {
                return false
            }
            lastStreamRecognition = recognized
            return recognizedTextProvesUnlockedQuote(recognized)
        }
        XCTAssertTrue(
            streamProofIsVisible,
            "The streamed Mac never visibly showed the fixture's unlocked itemized quote. Vision last saw: \(lastStreamRecognition)")
        XCTAssertTrue(
            liveScreen.exists,
            "The terminal result replaced the user-visible live Mac screen.")
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "The shipped iOS app left the foreground during local OS-Atlas acceptance.")

        let evidence = XCTAttachment(string: """
        OUTCOME: task completed
        CONFIGURATION: matched signed iOS and macOS products under test
        PROMPT CHANNEL: TLS-authenticated local LAN broker; independently ready before visual media
        VISUAL SIDECAR: optional product media path; mandatory for B01; live only after compatible host hello, current display metadata, and a fresh decoded frame
        HYBRID ROUTE: host semantic app/type/scroll routing + installed OS-Atlas visual point grounding for the required setup control
        ONE NATURAL-LANGUAGE SUBMISSION: true
        INITIAL APP PROOF: streamed Calculator text was visible while Safari and local-fixture markers were absent
        APP-FIRST PROGRESS OBSERVED: \(terminal.sawRequestedApplicationOpenProgress)
        SAFARI-BEFORE-TYPE STREAM PROOF: \(terminal.sawSafariFixtureBeforeNativeType)
        OS-ATLAS POINTER-CLICK PROGRESS OBSERVED: \(terminal.sawOSAtlasPointerClickProgress)
        POINTER EFFECT BEFORE TYPE: \(terminal.sawSetupActivationEffectBeforeNativeType)
        NATIVE TYPE PROGRESS OBSERVED: \(terminal.sawNativeTypeProgress)
        NATIVE SCROLL PROGRESS OBSERVED: \(terminal.sawNativeScrollProgress)
        TYPE PROOF: exact token unlocked content that did not exist beforehand
        SCROLL PROOF: complete quote was outside the initial viewport
        FACT SOURCE: production local visible-quote OCR validator
        TERMINAL RESULT VERIFIED IN UI: true
        EXTERNAL EFFECTS: none; fixture CSP blocks all network and exposes only a local setup control, with no submit control
        """)
        evidence.name = "Local OS-Atlas shipped-path evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
        attachSimulatorScreenshot(named: "Local OS-Atlas fixture - verified result")
    }

    private func waitForFixtureResult(
        in app: XCUIApplication,
        liveScreen: XCUIElement,
        previousAssistantCount: Int,
        timeout: TimeInterval
    ) throws -> (
        assistantLabel: String,
        sawRequestedApplicationOpenProgress: Bool,
        sawSafariFixtureBeforeNativeType: Bool,
        sawOSAtlasPointerClickProgress: Bool,
        sawSetupActivationEffectBeforeNativeType: Bool,
        sawNativeTypeProgress: Bool,
        sawNativeScrollProgress: Bool
    ) {
        let nativeTypeProgress = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: typing 16 characters.*"#)).firstMatch
        let nativeScrollProgress = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: scrolling down.*"#)).firstMatch
        let relevantApplicationProgress = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: opening (?:an app|Safari for the delivery quote).*"#)).firstMatch
        let osAtlasPointerClickProgress = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: clicking.*"#)).firstMatch
        let unexpectedDragProgress = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: dragging.*"#)).firstMatch
        let approval = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Approve before AI continues")).firstMatch
        let intervention = app.descendants(matching: .any)[
            "computer-use-intervention-guidance"]
        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        let resume = app.buttons["computer-use-resume-ai"]
        let stop = app.buttons["computer-use-stop-task"]
        let humanResumeProof = app.descendants(matching: .any).matching(
            identifier: "computer-use-human-resume-proof").firstMatch
        let durableProgress = app.descendants(matching: .any).matching(
            identifier: "computer-use-progress-history").firstMatch
        let retry = app.buttons["Retry sending the last request"]
        var deadline = Date().addingTimeInterval(timeout)
        var sawRequestedApplicationOpenProgress = false
        var sawSafariFixtureBeforeNativeType = false
        var sawOSAtlasPointerClickProgress = false
        var sawSetupActivationEffectBeforeNativeType = false
        var sawNativeTypeProgress = false
        var sawNativeScrollProgress = false
        var nextStreamInspection = Date.distantPast
        var nextSetupEffectInspection = Date.distantPast

        func absorbDurableProgress() throws {
            guard durableProgress.exists,
                  let value = durableProgress.value as? String else { return }
            let options: String.CompareOptions = [
                .regularExpression, .caseInsensitive,
            ]
            let openRange = value.range(
                of: #"Step [0-9]+: opening (?:an app|Safari for the delivery quote)"#,
                options: options)
            let clickRange = value.range(
                of: #"Step [0-9]+: clicking"#,
                options: options)
            let typeRange = value.range(
                of: #"Step [0-9]+: typing 16 characters"#,
                options: options)
            let scrollRange = value.range(
                of: #"Step [0-9]+: scrolling down"#,
                options: options)

            if value.range(
                of: #"Step [0-9]+: dragging"#,
                options: options) != nil {
                XCTFail(
                    "The router substituted a drag for the required setup-control click.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if let typeRange {
                guard let clickRange,
                      clickRange.lowerBound < typeRange.lowerBound else {
                    XCTFail(
                        "Durable progress proves typing occurred before the required OS-Atlas click.")
                    throw AcceptanceFailure.unexpectedIntervention
                }
                sawNativeTypeProgress = true
            }
            if let scrollRange {
                guard let clickRange,
                      clickRange.lowerBound < scrollRange.lowerBound else {
                    XCTFail(
                        "Durable progress proves scrolling occurred before the required OS-Atlas click.")
                    throw AcceptanceFailure.unexpectedIntervention
                }
                sawNativeScrollProgress = true
            }
            sawRequestedApplicationOpenProgress =
                sawRequestedApplicationOpenProgress || openRange != nil
            sawOSAtlasPointerClickProgress =
                sawOSAtlasPointerClickProgress || clickRange != nil
        }

        repeat {
            try absorbDurableProgress()
            if intervention.exists {
                guard intervention.label == Self.screenCaptureConsentGuidance,
                      status.exists,
                      (status.value as? String) == "User intervention required",
                      resume.exists,
                      resume.isHittable,
                      stop.exists,
                      stop.isHittable,
                      !humanResumeProof.exists else {
                    XCTFail(
                        "The harmless fixture paused for an unexpected intervention or an incomplete person-controlled handoff.")
                    throw AcceptanceFailure.unexpectedIntervention
                }
                XCTContext.runActivity(
                    named: "Manual step: choose Allow in the macOS RemoteDesktopHost prompt, then tap Let AI continue"
                ) { _ in }
                try waitForScreenCaptureConsentResume(
                    in: app,
                    previousAssistantCount: previousAssistantCount,
                    timeout: Self.screenCaptureConsentTimeout)
                // Consent is a one-time prerequisite, not browser-task runtime.
                // Give the unchanged single request its full independent bound
                // after the person explicitly returns control.
                deadline = Date().addingTimeInterval(timeout)
            }
            if relevantApplicationProgress.exists {
                sawRequestedApplicationOpenProgress = true
            }
            if sawRequestedApplicationOpenProgress,
               !sawNativeTypeProgress,
               !sawSafariFixtureBeforeNativeType,
               Date() >= nextStreamInspection {
                nextStreamInspection = Date().addingTimeInterval(0.35)
                if let recognized = fixtureProofRecognition(in: liveScreen) {
                    let text = canonical(recognized)
                    sawSafariFixtureBeforeNativeType =
                        text.contains("safari")
                        && text.contains("delivery quote setup")
                        && text.contains("start local quote setup")
                        && text.contains("fixture code")
                }
            }
            if osAtlasPointerClickProgress.exists {
                sawOSAtlasPointerClickProgress = true
            }
            if sawOSAtlasPointerClickProgress,
               !nativeTypeProgress.exists,
               !sawSetupActivationEffectBeforeNativeType,
               Date() >= nextSetupEffectInspection {
                nextSetupEffectInspection = Date().addingTimeInterval(0.25)
                if let recognized = fixtureProofRecognition(in: liveScreen) {
                    let text = canonical(recognized)
                    sawSetupActivationEffectBeforeNativeType =
                        text.contains("local quote setup started")
                        && text.contains("fixture code field ready")
                }
            }
            if nativeTypeProgress.exists {
                guard sawOSAtlasPointerClickProgress else {
                    XCTFail(
                        "The router tried to type before OS-Atlas activated the required setup control.")
                    throw AcceptanceFailure.unexpectedIntervention
                }
                sawNativeTypeProgress = true
            }
            if nativeScrollProgress.exists {
                guard sawOSAtlasPointerClickProgress else {
                    XCTFail(
                        "The router tried to scroll before OS-Atlas activated the required setup control.")
                    throw AcceptanceFailure.unexpectedIntervention
                }
                sawNativeScrollProgress = true
            }
            if unexpectedDragProgress.exists {
                XCTFail(
                    "The router substituted a drag for the required setup-control click.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if approval.exists {
                XCTFail(
                    "The harmless fixture path unexpectedly selected an approval-gated action.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if retry.exists {
                XCTFail(
                    "The iOS-to-host request failed in transport before OS-Atlas completed the local fixture.")
                throw AcceptanceFailure.transportFailure
            }

            let messages = assistantMessages(in: app)
            if messages.count > previousAssistantCount {
                try absorbDurableProgress()
                return (
                    messages.element(boundBy: messages.count - 1).label,
                    sawRequestedApplicationOpenProgress,
                    sawSafariFixtureBeforeNativeType,
                    sawOSAtlasPointerClickProgress,
                    sawSetupActivationEffectBeforeNativeType,
                    sawNativeTypeProgress,
                    sawNativeScrollProgress)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "No terminal local-fixture quote returned through the Simulator within \(Int(timeout)) seconds.")
        throw AcceptanceFailure.timedOut
    }

    private func waitForScreenCaptureConsentResume(
        in app: XCUIApplication,
        previousAssistantCount: Int,
        timeout: TimeInterval
    ) throws {
        let guidance = app.descendants(matching: .any).matching(
            identifier: "computer-use-intervention-guidance").firstMatch
        let humanResumeProof = app.descendants(matching: .any).matching(
            identifier: "computer-use-human-resume-proof").firstMatch
        let approval = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Approve before AI continues"))
            .firstMatch
        let retry = app.buttons["Retry sending the last request"]
        let stopped = app.staticTexts[
            "AI: Stopped. You're in control of the Mac."]
        let deadline = Date().addingTimeInterval(timeout)
        var sawHumanResume = false

        repeat {
            if approval.exists {
                XCTFail(
                    "The macOS system consent was represented as an AI approval instead of person-only takeover.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if retry.exists {
                XCTFail(
                    "The consent resume failed in local transport before the browser task continued.")
                throw AcceptanceFailure.transportFailure
            }
            sawHumanResume = sawHumanResume || humanResumeProof.exists
            let assistantCount = assistantMessages(in: app).count
            if sawHumanResume,
               !guidance.exists || assistantCount > previousAssistantCount {
                return
            }
            if !sawHumanResume, assistantCount > previousAssistantCount {
                XCTFail(
                    "The browser task returned a terminal answer while macOS consent was still person-controlled.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if stopped.exists {
                XCTFail(
                    "The browser task was stopped instead of resumed after macOS consent.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if app.state != .runningForeground {
                XCTFail(
                    "The shipped iOS app left the foreground during macOS consent takeover.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if guidance.exists {
                guard guidance.label == Self.screenCaptureConsentGuidance else {
                    XCTFail(
                        "The macOS consent handoff changed into an unexpected intervention.")
                    throw AcceptanceFailure.unexpectedIntervention
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail(
            "The person did not choose Allow on the Mac and tap Let AI continue within the bounded \(Int(timeout / 60))-minute consent window. The test intentionally did not click the system prompt or stop the paused task.")
        throw AcceptanceFailure.timedOut
    }

    private enum AcceptanceFailure: Error {
        case unexpectedIntervention
        case transportFailure
        case timedOut
    }

    private func assertExactFixtureFields(in response: String) {
        for field in Self.expectedFields {
            guard let actual = extractedField(field.label, from: response) else {
                XCTFail(
                    "The locally validated quote omitted \(field.label): \(response)")
                return
            }
            XCTAssertEqual(
                canonical(actual),
                canonical(field.value),
                "The local fixture returned the wrong \(field.label).")
        }
    }

    private func extractedField(_ label: String, from response: String) -> String? {
        let escapedLabel = NSRegularExpression.escapedPattern(for: label)
        guard let expression = try? NSRegularExpression(
            pattern: "\\b\(escapedLabel):\\s*([^;]+)",
            options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: response,
                range: NSRange(response.startIndex..., in: response)),
              let valueRange = Range(match.range(at: 1), in: response) else {
            return nil
        }
        return String(response[valueRange])
    }

    private func canonical(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func fixtureProofRecognition(in liveScreen: XCUIElement) -> String? {
        guard liveScreen.exists,
              let image = liveScreen.screenshot().image.cgImage,
              let recognized = try? recognizedText(in: image) else {
            return nil
        }
        return recognized
    }

    private func recognizedTextProvesUnlockedQuote(_ recognized: String) -> Bool {
        let canonicalText = canonical(recognized)
        // The banner scrolls above the final viewport, and the smallest bottom
        // rows are not reliable at streamed scale. These three exact values all
        // exist only in the token-unlocked quote. Labels are deliberately not
        // used because Vision can heavily mangle tiny streamed text. Ignore the
        // leading currency glyph because it can read a dollar sign as "S".
        let requiredAmounts = ["24[.]99", "2[.]99", "3[.]75"]
        let hasRequiredAmounts = requiredAmounts.allSatisfy { amount in
                canonicalText.range(
                    of: "(?<![0-9])\(amount)(?![0-9])",
                    options: .regularExpression) != nil
            }
        let hasCompletionMarker = canonicalText.range(
            of: "(?<![0-9])34[.]51(?![0-9])",
            options: .regularExpression) != nil
            || canonicalText.contains("28-38 min")
            || canonicalText.contains("acceptance complete locally")
        return hasRequiredAmounts && hasCompletionMarker
    }

    private func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: image, orientation: .up)
            .perform([request])
        return (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }.joined(separator: " ")
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

    private func attachSimulatorScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
