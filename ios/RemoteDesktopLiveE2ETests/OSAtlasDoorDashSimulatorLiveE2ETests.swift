import XCTest

/// Simulator-driven acceptance for the shipped iOS -> CloudKit -> installed
/// OS-Atlas visual-computer-use path.
///
/// This test intentionally does not create or launch a fixture application.
/// Before opting in, prepare a real DoorDash checkout/review page in Safari
/// with the restaurant, item, complete itemized quote, and ETA visible at the
/// same time. Keep only Safari and the iOS Simulator visible. The task is
/// strictly observational: it may bring Safari forward, but any click, typing,
/// scrolling, navigation, approval request, or purchase attempt fails the
/// acceptance run.
final class OSAtlasDoorDashSimulatorLiveE2ETests: XCTestCase {
    private enum EnvironmentKey {
        static let liveSuite = "RUN_COMPUTER_USE_LIVE_E2E"
        static let thisTest = "RUN_OSATLAS_DOORDASH_SIMULATOR_E2E"
        static let restaurant = "OSATLAS_DOORDASH_EXPECTED_RESTAURANT"
        static let item = "OSATLAS_DOORDASH_EXPECTED_ITEM"
        static let subtotal = "OSATLAS_DOORDASH_EXPECTED_SUBTOTAL"
        static let deliveryFee = "OSATLAS_DOORDASH_EXPECTED_DELIVERY_FEE"
        static let serviceFee = "OSATLAS_DOORDASH_EXPECTED_SERVICE_FEE"
        static let tax = "OSATLAS_DOORDASH_EXPECTED_TAX"
        static let total = "OSATLAS_DOORDASH_EXPECTED_TOTAL"
        static let eta = "OSATLAS_DOORDASH_EXPECTED_ETA"
    }

    private struct ExpectedQuote {
        let restaurant: String
        let item: String
        let subtotal: String
        let deliveryFee: String
        let serviceFee: String
        let tax: String
        let total: String
        let eta: String

        init(environment: [String: String]) throws {
            restaurant = try Self.text(EnvironmentKey.restaurant, in: environment)
            item = try Self.text(EnvironmentKey.item, in: environment)
            subtotal = try Self.money(EnvironmentKey.subtotal, in: environment)
            deliveryFee = try Self.money(EnvironmentKey.deliveryFee, in: environment)
            serviceFee = try Self.money(EnvironmentKey.serviceFee, in: environment)
            tax = try Self.money(EnvironmentKey.tax, in: environment)
            total = try Self.money(EnvironmentKey.total, in: environment)
            eta = try Self.eta(EnvironmentKey.eta, in: environment)
        }

        var labeledFields: [(label: String, expected: String)] {
            [
                ("Restaurant", restaurant),
                ("Item", item),
                ("Subtotal", subtotal),
                ("Delivery fee", deliveryFee),
                ("Service fee", serviceFee),
                ("Tax", tax),
                ("Total", total),
                ("ETA", eta),
            ]
        }

        private static func text(
            _ key: String,
            in environment: [String: String]
        ) throws -> String {
            let value = try required(key, in: environment)
            guard value.count <= 160,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ConfigurationError.invalidValue(key)
            }
            return value
        }

        private static func money(
            _ key: String,
            in environment: [String: String]
        ) throws -> String {
            let value = try required(key, in: environment)
            guard value.range(
                of: #"^\$[0-9]+(?:\.[0-9]{2})$"#,
                options: .regularExpression) != nil else {
                throw ConfigurationError.invalidValue(key)
            }
            return value
        }

        private static func eta(
            _ key: String,
            in environment: [String: String]
        ) throws -> String {
            let value = try required(key, in: environment)
            guard value.range(
                of: #"^[0-9]+\s*[-–—]\s*[0-9]+\s*(?:min|mins|minutes)$"#,
                options: [.regularExpression, .caseInsensitive]) != nil else {
                throw ConfigurationError.invalidValue(key)
            }
            return value
        }

        private static func required(
            _ key: String,
            in environment: [String: String]
        ) throws -> String {
            guard let rawValue = environment[key] else {
                throw ConfigurationError.missingValue(key)
            }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw ConfigurationError.missingValue(key)
            }
            return value
        }
    }

    private enum ConfigurationError: LocalizedError {
        case missingValue(String)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let key):
                return "The opted-in DoorDash acceptance run is missing \(key)."
            case .invalidValue(let key):
                return "The opted-in DoorDash acceptance run has an invalid \(key)."
            }
        }
    }

    private var expectedQuote: ExpectedQuote!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment[EnvironmentKey.liveSuite] == "1" else {
            throw XCTSkip(
                "Use the RemoteDesktopLiveE2E scheme to run live Computer Use acceptance.")
        }
        guard environment[EnvironmentKey.thisTest] == "1" else {
            throw XCTSkip(
                "Set \(EnvironmentKey.thisTest)=1 only after a real, complete DoorDash quote is visible in Safari.")
        }
        expectedQuote = try ExpectedQuote(environment: environment)
    }

    func testPreparedDoorDashQuoteIsReadByInstalledOSAtlasThroughSimulator() throws {
        let app = XCUIApplication()
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
        XCTAssertTrue(readyButton.isHittable, "Use AI must be directly tappable in Simulator.")
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
            "The simulator Computer Use conversation did not become ready.")

        attachSimulatorScreenshot(named: "DoorDash quote - before request")

        let prompt = """
        Check the real DoorDash delivery quote already prepared in Safari. All details are visible at once. Do not place the order. This is read-only: use OPEN_APP only if Safari is not frontmost; do not activate controls, type, scroll, navigate, change the cart or address, or check out. Report exactly these semicolon-separated visible fields: Restaurant, Item, Subtotal, Delivery fee, Service fee, Tax, Total, and ETA.
        """
        let assistantCountBefore = assistantMessages(in: app).count
        composer.tap()
        composer.typeText(prompt)

        let sendButton = app.buttons["Send request"]
        XCTAssertTrue(
            waitUntil(timeout: 10) { sendButton.exists && sendButton.isEnabled },
            "The ordinary-language DoorDash request did not enable Send.")
        sendButton.tap()

        let sentMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "You: \(prompt)")).firstMatch
        XCTAssertTrue(
            sentMessage.waitForExistence(timeout: 10),
            "The exact read-only request was not shown in the simulator conversation.")

        let terminal = try waitForReadOnlyVisualResult(
            in: app,
            previousAssistantCount: assistantCountBefore,
            timeout: 240)
        XCTAssertTrue(
            terminal.sawVisualObservation,
            "The host returned without entering the OS-Atlas screenshot loop; this is not an actual-model acceptance result.")

        let response = terminal.assistantLabel.replacingOccurrences(
            of: "AI: ",
            with: "",
            options: .anchored)
        XCTAssertFalse(
            response.hasPrefix("I couldn't"),
            "Installed OS-Atlas failed the prepared DoorDash task: \(response)")
        assertExactQuoteFields(in: response)

        XCTAssertTrue(
            liveScreen.exists,
            "The result replaced the user-visible live screen instead of remaining in the Computer Use UI.")
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "The shipped iOS app left the foreground during the read-only quote task.")
        attachSimulatorScreenshot(named: "DoorDash quote - verified result")
    }

    private func waitForReadOnlyVisualResult(
        in app: XCUIApplication,
        previousAssistantCount: Int,
        timeout: TimeInterval
    ) throws -> (assistantLabel: String, sawVisualObservation: Bool) {
        let visualObservation = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "looking at the screen")).firstMatch
        let approval = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Approve before AI continues")).firstMatch
        let forbiddenInput = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label MATCHES[c] %@",
                #".*Step [0-9]+: (clicking|double-clicking|right-clicking|dragging|typing .+|scrolling .+|pressing Return|using a keyboard shortcut).*"#)).firstMatch
        let retry = app.buttons["Retry sending the last request"]
        let deadline = Date().addingTimeInterval(timeout)
        var sawVisualObservation = false

        repeat {
            if visualObservation.exists, !sawVisualObservation {
                sawVisualObservation = true
                attachSimulatorScreenshot(named: "DoorDash quote - OS-Atlas observing Safari")
            }
            if approval.exists {
                attachSimulatorScreenshot(named: "DoorDash quote - unexpected approval")
                XCTFail(
                    "A quote-reading task requested approval. No DoorDash control should be activated.")
                throw AcceptanceFailure.unexpectedInteraction
            }
            if forbiddenInput.exists {
                attachSimulatorScreenshot(named: "DoorDash quote - unexpected input")
                XCTFail(
                    "The read-only OS-Atlas run attempted input: \(forbiddenInput.label)")
                throw AcceptanceFailure.unexpectedInteraction
            }
            if retry.exists {
                XCTFail("The iOS-to-host request failed in transport before OS-Atlas completed it.")
                throw AcceptanceFailure.transportFailure
            }

            let messages = assistantMessages(in: app)
            if messages.count > previousAssistantCount {
                return (
                    messages.element(boundBy: messages.count - 1).label,
                    sawVisualObservation)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("No terminal DoorDash quote returned through the simulator within \(Int(timeout)) seconds.")
        throw AcceptanceFailure.timedOut
    }

    private enum AcceptanceFailure: Error {
        case unexpectedInteraction
        case transportFailure
        case timedOut
    }

    private func assertExactQuoteFields(in response: String) {
        for field in expectedQuote.labeledFields {
            guard let actual = extractedField(field.label, from: response) else {
                XCTFail("The OS-Atlas answer omitted the required \(field.label) field: \(response)")
                return
            }
            XCTAssertEqual(
                canonical(actual),
                canonical(field.expected),
                "OS-Atlas reported the wrong \(field.label) for the prepared real DoorDash quote.")
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
    }

    private func assistantMessages(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
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
