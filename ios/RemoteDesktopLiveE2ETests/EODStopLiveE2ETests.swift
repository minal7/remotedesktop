import XCTest

/// Explicitly opted-in physical checks for the current test's own task. Never
/// approves, denies, resumes, dismisses system UI, or sends input to the Mac.
final class EODStopLiveE2ETests: XCTestCase {
    private enum Scenario: String { case running, approval }
    private enum Blocked: Error { case precondition }

    func testStopWhileRunning() throws { try exercise(.running) }
    func testStopWhileAwaitingApproval() throws { try exercise(.approval) }

    private func exercise(_ scenario: Scenario) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_COMPUTER_USE_LIVE_E2E"] == "1",
              environment["RUN_EOD_STOP_LIVE_E2E"] == "1" else {
            throw XCTSkip("Stop checks require an explicitly opted-in physical Release session.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("The two-second acceptance check requires a physical device.")
        #else
        continueAfterFailure = false
        let appName = environment["EOD_STOP_APPROVAL_APP"] ?? "Calculator"
        guard ["Calculator", "Notes", "TextEdit"].contains(appName) else {
            throw fail("Choose an explicitly permitted first-use app.")
        }
        let prompt = scenario == .approval ? "Open \(appName)." : "Open Calculator and type 12+30."
        let app = XCUIApplication()
        if app.state == .notRunning { app.launch() }
        else if app.state != .runningForeground { app.activate() }
        guard app.wait(for: .runningForeground, timeout: 10) else { throw fail("The client is not in the foreground.") }
        try requireNoRealAlert(app, label: "preflight")
        let hosts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Use AI Computer Use on "))
        guard try wait(seconds: 45, app: app, until: { hosts.count > 0 }), hosts.count == 1 else {
            throw fail("Exactly one AI-ready host must be visible.")
        }
        let hostLabel = hosts.element(boundBy: 0).label
        hosts.element(boundBy: 0).tap()
        let composer = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Tell your Mac what to do")).firstMatch
        guard try wait(seconds: 45, app: app, until: { composer.exists && composer.isEnabled }),
              !app.buttons["computer-use-stop-task"].exists,
              !app.buttons["computer-use-resume-ai"].exists,
              !app.descendants(matching: .any)["computer-use-approval-card"].exists else {
            capture(app, label: "preexisting-state")
            throw fail("A ready empty conversation is required; no request was sent.")
        }
        let userMessages = app.staticTexts.matching(NSPredicate(format: "label == %@", "You: \(prompt)"))
        let stoppedMessages = app.staticTexts.matching(NSPredicate(format: "label == %@", "AI: Stopped. You're in control of the Mac."))
        let priorUsers = userMessages.count, priorStops = stoppedMessages.count
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send request"]
        guard send.exists && send.isEnabled else { throw fail("The benign request cannot be sent.") }
        try requireNoRealAlert(app, label: "before-send")
        print("EOD_STOP_BEGIN scenario=\(scenario.rawValue) utc=\(timestamp()) host=\(hostLabel) prompt=\(prompt)")
        send.tap()
        let card = app.descendants(matching: .any)["computer-use-approval-card"]
        let stop = app.buttons["computer-use-stop-task"]
        let status = app.staticTexts["computer-use-status"]
        let resume = app.buttons["computer-use-resume-ai"]
        func isActiveRunningState() -> Bool {
            !card.exists && !resume.exists && status.exists
                && status.label == "Your Mac is working on it…"
                && stop.exists && stop.label == "Stop current task" && stop.isHittable
        }
        var observedExactUserMessage = false
        let ready = try wait(seconds: 60, app: app) {
            if userMessages.count == priorUsers + 1 { observedExactUserMessage = true }
            guard observedExactUserMessage else { return false }
            switch scenario {
            case .approval: return card.exists && self.isExactFirstUseApproval(in: app, appName: appName)
            case .running: return isActiveRunningState()
            }
        }
        guard ready else {
            capture(app, label: "\(scenario.rawValue)-before-stop")
            throw fail("The intended running or approval state was not observed; no Stop was sent.")
        }
        try requireNoRealAlert(app, label: "before-stop")
        guard observedExactUserMessage,
              (scenario == .approval ? card.exists && isExactFirstUseApproval(in: app, appName: appName)
                  : userMessages.count == priorUsers + 1 && isActiveRunningState()),
              stop.exists && stop.isHittable else {
            capture(app, label: "\(scenario.rawValue)-state-changed")
            throw fail("The intended state or its Stop control changed; no Stop was sent.")
        }
        let startedUTC = timestamp()
        let start = ProcessInfo.processInfo.systemUptime
        stop.tap()
        let deadline = start + 2
        var observedAt: TimeInterval?
        repeat {
            if stoppedMessages.count > priorStops {
                observedAt = ProcessInfo.processInfo.systemUptime
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while ProcessInfo.processInfo.systemUptime <= deadline
        let elapsed = (observedAt ?? ProcessInfo.processInfo.systemUptime) - start
        capture(app, label: "\(scenario.rawValue)-after-stop")
        print("EOD_STOP_RESULT scenario=\(scenario.rawValue) tap_utc=\(startedUTC) observed_utc=\(timestamp()) observed=\(observedAt != nil) elapsed_upper_bound_s=\(elapsed)")
        try requireNoRealAlert(app, label: "after-stop")
        guard observedAt != nil else { throw fail("The host's terminal Stop reply was not observed within two seconds.") }
        XCTAssertLessThanOrEqual(elapsed, 2, "The observed Stop response exceeded two seconds.")
        XCTAssertEqual(userMessages.count, priorUsers + 1, "The owned request must be sent exactly once.")
        // The host episode must be matched independently by its task prompt and
        // recorded timing. A timestamp alone cannot establish task identity.
        #endif
    }

    private func isExactFirstUseApproval(in app: XCUIApplication, appName: String) -> Bool {
        let reason = app.staticTexts["computer-use-approval-reason"]
        let action = app.descendants(matching: .any)["computer-use-approval-action"]
        guard reason.exists, reason.label == "This is the first use of an untrusted app or site.", action.exists else { return false }
        let label = action.label
        guard let start = label.firstIndex(of: "{"),
              let end = label.lastIndex(of: "}"), start <= end,
              let data = String(label[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return Set(object.keys) == ["type", "name"] && object["type"] == "open_app" && object["name"] == appName
    }

    private func requireNoRealAlert(_ app: XCUIApplication, label: String) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let unexpected = (0..<app.alerts.count).contains { index in
            let alert = app.alerts.element(boundBy: index)
            return alert.identifier != "computer-use-approval-card"
                && !alert.descendants(matching: .any)["computer-use-approval-card"].exists
        }
        if springboard.alerts.count > 0 || unexpected {
            capture(app, label: "alert-\(label)")
            throw fail("A system or unrelated application alert is visible; it was not dismissed.")
        }
    }

    private func wait(seconds: TimeInterval, app: XCUIApplication, until predicate: () -> Bool) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try requireNoRealAlert(app, label: "wait")
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func capture(_ app: XCUIApplication, label: String) {
        let time = timestamp()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "stop-\(label)-screenshot-\(time)"; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: "timestamp_utc=\(time)\n\(app.debugDescription)")
        hierarchy.name = "stop-\(label)-accessibility-\(time)"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func fail(_ message: String) -> Blocked { XCTFail(message); return .precondition }
}
