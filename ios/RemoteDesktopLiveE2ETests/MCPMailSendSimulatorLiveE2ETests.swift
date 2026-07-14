import XCTest

/// Simulator-visible acceptance for the real iOS -> CloudKit -> embedded MCP
/// -> Apple Mail path. The reserved `.invalid` recipients cannot identify a
/// real mailbox, and the test sends only after one exact mobile confirmation.
final class MCPMailSendSimulatorLiveE2ETests: XCTestCase {
    private let optInEnvironmentKey = "RUN_COMPUTER_USE_LIVE_E2E"

    private let toRecipient = "neighborhood-organizer@example.invalid"
    private let ccRecipient = "neighborhood-treasurer@example.invalid"
    private let subject = "Saturday food drive follow-up"
    private let body = "Thanks for coordinating Saturday's food drive. We collected 42 boxes, and I will send the volunteer schedule tomorrow."

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(optInEnvironmentKey)=1 to run the Simulator-visible MCP Mail send acceptance test.")
        }
    }

    func testSimulatorConfirmsThenSendsNonDeliverableMailThroughMCP() throws {
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

        // Exercise the interruption monitor without selecting a device when
        // the system permission alert is not present.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on ")).firstMatch
        XCTAssertTrue(
            readyButton.waitForExistence(timeout: 45),
            "An AI-ready release host did not appear in the Simulator.")
        XCTAssertTrue(readyButton.isHittable, "Use AI must be directly tappable.")
        readyButton.tap()

        let liveScreen = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Live interactive screen for ")).firstMatch
        XCTAssertTrue(
            liveScreen.waitForExistence(timeout: 45),
            "The Simulator did not show the live Mac screen before the MCP task began.")

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 45) { composer.exists && composer.isEnabled },
            "The connected Computer Use chat did not become ready for a request.")

        let prompt = "Send an email to \(toRecipient), CC \(ccRecipient), with subject \(subject) and body \(body)"
        composer.tap()
        composer.typeText(prompt)

        let sendRequest = app.buttons["Send request"]
        XCTAssertTrue(
            waitUntil(timeout: 10) { sendRequest.exists && sendRequest.isEnabled },
            "The complete everyday-language Mail request did not enable Send.")
        // Use a narrow, stable query and reserve the next assistant index for
        // this request. Enumerating the entire accessibility tree is unsafe
        // while the software keyboard and approval UI are transitioning.
        let assistantMessages = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI: "))
        let priorAssistantMessageCount = assistantMessages.count
        let currentRequestAssistant = assistantMessages.element(
            boundBy: priorAssistantMessageCount)
        let currentRequestBubble = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "You: \(prompt)"))
            .firstMatch
        let privacyShield = app.descendants(matching: .any).matching(
            identifier: "computer-use-approval-privacy-shield").firstMatch
        sendRequest.tap()

        guard waitUntil(timeout: 2, predicate: { privacyShield.exists }) else {
            XCTFail(
                "The live Mac screen was not hidden within two seconds of submitting the Mail request.")
            return
        }

        let approvalTitle = app.staticTexts["Approve before AI continues"]
        let sendQuestion = app.staticTexts[
            "Send this email through Mail on your Mac?"]
        let draftQuestion = app.staticTexts[
            "Create this email draft in Mail on your Mac?"]
        var currentRequestTerminatedBeforeApproval = false
        var planningPrivacyShieldDisappeared = false
        let reachedCurrentRequestOutcome = waitUntil(timeout: 120) {
            guard privacyShield.exists else {
                planningPrivacyShieldDisappeared = true
                return true
            }
            let approvalIsVisible = sendQuestion.exists || draftQuestion.exists
            if approvalIsVisible {
                return true
            }
            if assistantMessages.count > priorAssistantMessageCount,
               currentRequestBubble.exists,
               currentRequestAssistant.exists {
                currentRequestTerminatedBeforeApproval = true
                return true
            }
            return false
        }
        guard !planningPrivacyShieldDisappeared else {
            cancelPendingApproval(in: app)
            XCTFail(
                "The privacy shield disappeared while the current Mail request was being planned.")
            return
        }
        guard reachedCurrentRequestOutcome, sendQuestion.exists else {
            let terminalResponse = currentRequestTerminatedBeforeApproval
                && currentRequestAssistant.exists
                ? currentRequestAssistant.label
                : "none from the current request (ignored \(priorAssistantMessageCount) prior assistant message(s))"
            cancelPendingApproval(in: app)
            XCTFail(
                "The host did not produce the MCP Mail send approval. "
                    + "Terminal response: \(terminalResponse)")
            return
        }
        guard approvalTitle.exists else {
            cancelPendingApproval(in: app)
            XCTFail("The exact MCP action was not presented in the Simulator approval card.")
            return
        }
        guard privacyShield.exists else {
            cancelPendingApproval(in: app)
            XCTFail("The live Mac screen exposed unrelated content behind the approval card.")
            return
        }

        // These exact, host-validated fields are emitted by the MCP approval
        // presentation. A visual-model click approval cannot satisfy them.
        let exactValues = [toRecipient, ccRecipient, subject, body]
        for value in exactValues {
            let detail = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", value)).firstMatch
            guard detail.exists else {
                cancelPendingApproval(in: app)
                XCTFail("The MCP approval omitted or changed this exact value: \(value)")
                return
            }
        }

        let forbiddenDraft = app.buttons["Create draft"]
        guard !forbiddenDraft.exists else {
            cancelPendingApproval(in: app)
            XCTFail("The host proposed a draft instead of the explicitly requested confirmed send.")
            return
        }

        let sendEmail = app.buttons["Send email"]
        guard sendEmail.exists && sendEmail.isHittable else {
            cancelPendingApproval(in: app)
            XCTFail("The one-time Send email confirmation was not reachable in the Simulator.")
            return
        }
        guard privacyShield.exists else {
            cancelPendingApproval(in: app)
            XCTFail("The privacy shield disappeared while the exact Mail approval was pending.")
            return
        }
        keepScreenshot(named: "MCP Mail send approval", from: app)
        sendEmail.tap()

        let showMac = app.buttons["Show Mac"]
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                privacyShield.exists && showMac.exists && showMac.isHittable
            },
            "The opaque Mail privacy shield did not persist immediately after approval.")

        let expectedSuccess = "AI: Mail accepted the approved email for sending."
        var privacyShieldDisappeared = false
        let receivedCurrentRequestTerminalResponse = waitUntil(timeout: 120) {
            guard privacyShield.exists else {
                privacyShieldDisappeared = true
                return true
            }
            guard assistantMessages.count > priorAssistantMessageCount,
                  currentRequestBubble.exists,
                  currentRequestAssistant.exists else { return false }
            return true
        }
        XCTAssertFalse(
            privacyShieldDisappeared,
            "The live Mac screen became visible before the current Mail request completed.")
        XCTAssertTrue(
            receivedCurrentRequestTerminalResponse,
            "The embedded Mail MCP did not return a terminal result after send confirmation.")
        let terminalResponse = receivedCurrentRequestTerminalResponse
            && currentRequestAssistant.exists
            ? currentRequestAssistant.label
            : nil
        XCTAssertEqual(
            terminalResponse,
            expectedSuccess,
            "The current Mail request did not return the MCP server's accepted-for-sending result.")
        XCTAssertTrue(
            privacyShield.exists,
            "The live Mac screen must remain opaque after Mail completes so unrelated windows cannot show behind Mail.")
        XCTAssertTrue(
            showMac.exists && showMac.isHittable,
            "Only an explicit Show Mac action may reveal the desktop after Mail completes.")
        XCTAssertFalse(
            app.buttons["Create draft"].exists,
            "A draft action must not replace the explicitly confirmed send.")
        keepScreenshot(named: "MCP Mail send completion", from: app)
    }

    private func cancelPendingApproval(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        }
    }

    private func keepScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
