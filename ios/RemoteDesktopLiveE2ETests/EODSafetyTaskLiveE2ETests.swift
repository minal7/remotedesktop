import XCTest

/// One opt-in task through the unmodified Release app. The Mac-side runner
/// supplies the existing Safety-15 prompt and independently scores the fixture.
final class EODSafetyTaskLiveE2ETests: XCTestCase {
    func testPreparedSafetyCase() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_COMPUTER_USE_LIVE_E2E"] == "1",
              environment["RUN_EOD_SAFETY_LIVE_E2E"] == "1" else {
            throw XCTSkip("Safety-15 requires an exclusive, operator-observed Release host session.")
        }
        guard let identifier = environment["EOD_SAFETY_CASE"],
              (1...15).map({ String(format: "safety-%03d", $0) }).contains(identifier),
              let prompt = environment["EOD_SAFETY_PROMPT"], !prompt.isEmpty,
              let hostLabel = environment["EOD_SAFETY_HOST_LABEL"],
              hostLabel.hasPrefix("Use AI Computer Use on ") else {
            throw fail("Missing prepared case or exact host label.")
        }
        let app = XCUIApplication()
        try ComputerUseLiveE2EPreflight.launchAfterSimulatorRegistrationSettles(app)
        try requireNoPrompt(in: app)
        let hosts = app.buttons.matching(NSPredicate(format: "label == %@", hostLabel))
        guard try wait(seconds: 45, app: app, until: { hosts.count == 1 }) else {
            throw fail("The exact prepared host is not uniquely available.")
        }
        hosts.element(boundBy: 0).tap()
        let local = app.descendants(matching: .any)["computer-use-local-connection"]
        let composer = app.textFields.matching(NSPredicate(
            format: "placeholderValue == %@", "Tell your Mac what to do")).firstMatch
        guard try wait(seconds: 45, app: app, until: {
            local.exists && composer.exists && composer.isEnabled
        }) else { throw fail("Authenticated local conversation did not become ready.") }
        guard !app.buttons["computer-use-stop-task"].exists,
              !app.buttons["computer-use-resume-ai"].exists,
              !app.buttons["computer-use-approval-deny"].exists else {
            if app.buttons["computer-use-approval-deny"].exists {
                attachDiagnostics(named: "prior-approval-\(identifier)") {
                    self.approvalDetails(in: app)
                }
            }
            throw fail("An earlier task needs attention; no request was sent.")
        }
        let assistants = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AI: "))
        let users = app.staticTexts.matching(NSPredicate(format: "label == %@", "You: \(prompt)"))
        let assistantCount = assistants.count
        let userCount = users.count
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send request"]
        guard try wait(seconds: 10, app: app, until: { send.exists && send.isEnabled }) else {
            throw fail("The prepared request could not be sent.")
        }
        emit("BEGIN", ["case": identifier, "host": hostLabel])
        let started = ProcessInfo.processInfo.systemUptime
        send.tap()
        let status = app.descendants(matching: .any)["computer-use-status"]
        let outcomes = ["Task completed": "completed", "Unable to complete": "failed",
                        "User intervention required": "handoff"]
        while ProcessInfo.processInfo.systemUptime - started < 300 {
            try requireNoPrompt(in: app, context: identifier)
            if app.buttons["computer-use-approval-deny"].exists {
                // Keep the request visible. This test never grants or denies it.
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                attachDiagnostics(named: "approval-\(identifier)") {
                    self.approvalDetails(in: app)
                }
                emit("TERMINAL", ["case": identifier, "outcome": "pending_approval",
                    "elapsed": elapsed, "answer": "",
                    "needs_human": true])
                return
            }
            if users.count > userCount, assistants.count > assistantCount,
               let value = status.value as? String, let outcome = outcomes[value] {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                attachDiagnostics(named: "terminal-\(identifier)") {
                    "outcome=\(value)\n" + self.approvalDetails(in: app)
                }
                XCTAssertEqual(users.count, userCount + 1, "The task must be sent exactly once.")
                emit("TERMINAL", ["case": identifier, "outcome": outcome,
                    "elapsed": elapsed,
                    "answer": assistants.element(boundBy: assistants.count - 1).label,
                    "needs_human": outcome == "handoff"])
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        // Stop only this submitted task; do not dismiss or approve any prompt.
        try requireNoPrompt(in: app, context: identifier)
        let stop = app.buttons["computer-use-stop-task"]
        if stop.exists && stop.isHittable { stop.tap() }
        emit("TERMINAL", ["case": identifier, "outcome": "timeout", "answer": "",
            "elapsed": ProcessInfo.processInfo.systemUptime - started, "needs_human": true])
        throw fail("No terminal outcome within 300 seconds; inspect the host before continuing.")
    }

    private func requireNoPrompt(in app: XCUIApplication, context: String = "pre-task") throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardCount = springboard.alerts.count
        let appCount = app.alerts.count
        let unexpectedAppAlert = (0..<appCount).contains { index in
            app.alerts.element(boundBy: index).identifier != "computer-use-approval-card"
        }
        if springboardCount > 0 || unexpectedAppAlert {
            attachDiagnostics(named: "alert-\(context)") {
                var details = "springboard.alerts.count=\(springboardCount)\napp.alerts.count=\(appCount)"
                for index in 0..<springboardCount {
                    details += "\nspringboard.alerts[\(index)]:\n\(springboard.alerts.element(boundBy: index).debugDescription)"
                }
                for index in 0..<appCount {
                    details += "\napp.alerts[\(index)]:\n\(app.alerts.element(boundBy: index).debugDescription)"
                }
                return details + "\n" + self.approvalDetails(in: app)
            }
            throw fail("Unexpected system/application prompt; no prompt was dismissed.")
        }
    }

    private func approvalDetails(in app: XCUIApplication) -> String {
        let identifiers = ["computer-use-status", "computer-use-approval-outcome", "computer-use-approval-deny"]
        return identifiers.map { identifier in
            let element = app.descendants(matching: .any)[identifier]
            return element.exists
                ? "\(identifier):\n\(element.debugDescription)"
                : "\(identifier): not present"
        }.joined(separator: "\n")
    }

    private func attachDiagnostics(named name: String, details: () -> String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-screenshot-\(timestamp)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let text = XCTAttachment(string: "timestamp_utc=\(timestamp)\n\(details())")
        text.name = "\(name)-accessibility-\(timestamp)"
        text.lifetime = .keepAlways
        add(text)
    }

    private func wait(seconds: TimeInterval, app: XCUIApplication, until predicate: () -> Bool) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try requireNoPrompt(in: app)
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return predicate()
    }

    private func emit(_ kind: String, _ fields: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print("EOD_SAFETY_\(kind) \(line)")
        }
    }

    private enum Failure: Error { case blocked(String) }
    private func fail(_ reason: String) -> Failure {
        emit("BLOCKED", ["reason": reason])
        XCTFail(reason)
        return .blocked(reason)
    }
}
