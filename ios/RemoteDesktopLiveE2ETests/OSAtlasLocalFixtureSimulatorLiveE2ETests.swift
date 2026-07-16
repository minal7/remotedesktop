import XCTest
import UIKit
import Vision

/// Opt-in shipped-path acceptance for the real Release iOS client,
/// Production CloudKit, signed macOS host, installed OS-Atlas checkpoint,
/// native macOS input injection, and streamed-screen result.
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

        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The shipped iOS client did not reach the foreground in Simulator.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on ")).firstMatch
        XCTAssertTrue(
            readyButton.waitForExistence(timeout: 45),
            "A Release iOS client could not find an AI-ready production host.")
        XCTAssertTrue(
            readyButton.isHittable,
            "Use AI must be directly tappable in Simulator.")
        readyButton.tap()

        let liveScreen = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Live interactive screen for ")).firstMatch
        XCTAssertTrue(
            liveScreen.waitForExistence(timeout: 45),
            "The user-visible live Mac screen did not appear in the shipped iOS UI.")

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 45) { composer.exists && composer.isEnabled },
            "The Simulator conversation did not become ready after receiving a real Mac video frame.")

        var initialStreamRecognition = ""
        XCTAssertTrue(
            waitUntil(timeout: 20) {
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
            "The live run did not begin with Calculator visible and Safari/fixture text absent. Vision saw: \(initialStreamRecognition)")

        attachSimulatorScreenshot(named: "Local OS-Atlas fixture - before request")

        let prompt = """
        Please open Safari and use the local no-network delivery quote page that's already loaded there. First activate the visible Start local quote setup button, then enter the fixture code \(Self.fixtureToken) into the field labeled Fixture code. Scroll down until the whole itemized quote is visible and tell me the restaurant, item, subtotal, every fee, tax, total, and ETA. Don't sign in, check out, pay, or place an order.
        """
        let assistantCountBefore = assistantMessages(in: app).count
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

        let terminal = try waitForFixtureResult(
            in: app,
            liveScreen: liveScreen,
            previousAssistantCount: assistantCountBefore,
            timeout: 300)
        taskReachedTerminalResponse = true
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
        OUTCOME: PASS
        TRANSPORT: Release iOS -> Production CloudKit -> signed macOS host
        HYBRID ROUTE: host semantic app/type/scroll routing + installed OS-Atlas visual point grounding for the required setup control
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
        let retry = app.buttons["Retry sending the last request"]
        let deadline = Date().addingTimeInterval(timeout)
        var sawRequestedApplicationOpenProgress = false
        var sawSafariFixtureBeforeNativeType = false
        var sawOSAtlasPointerClickProgress = false
        var sawSetupActivationEffectBeforeNativeType = false
        var sawNativeTypeProgress = false
        var sawNativeScrollProgress = false
        var nextStreamInspection = Date.distantPast
        var nextSetupEffectInspection = Date.distantPast

        repeat {
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
            if intervention.exists {
                XCTFail(
                    "The host paused for a manual prerequisite; satisfy macOS capture/accessibility consent and reload the local fixture before retrying.")
                throw AcceptanceFailure.unexpectedIntervention
            }
            if retry.exists {
                XCTFail(
                    "The iOS-to-host request failed in transport before OS-Atlas completed the local fixture.")
                throw AcceptanceFailure.transportFailure
            }

            let messages = assistantMessages(in: app)
            if messages.count > previousAssistantCount {
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
