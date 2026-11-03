import XCTest

/// Opt-in Release app-to-host task attempts. Typed completion is only a transport
/// result; the operator must independently check each task's answer or artifact.
/// Run individual methods to resume only attempts that have not been performed.
final class EODSimpleTaskLiveE2ETests: XCTestCase {
    private static var needsHuman = false

    private enum TaskKind: String, CaseIterable {
        case apple, wikipedia, summary, textEdit, finder, openApp, search, calculator

        func prompt(uniqueSuffix: String) -> String {
            switch self {
            case .apple:
                return "Go to apple.com and tell me the starting price of the MacBook Air."
            case .wikipedia:
                return "Look up the population of Lisbon on Wikipedia and tell me the population and its reference date."
            case .summary:
                return "Open https://www.iana.org/domains/reserved and summarise what it says about example domains."
            case .textEdit:
                return "Create a new TextEdit document that says 'Meeting notes for Monday' and save it to Documents as AgentEval-EOD-\(uniqueSuffix).txt. Do not replace an existing file."
            case .finder:
                return "In Finder, make a folder called AgentEval-EOD-\(uniqueSuffix) on the Desktop. Do not change an existing folder."
            case .openApp:
                return "Open Calculator."
            case .search:
                return "Search the web for who designed the Sydney Opera House and tell me the answer and the source."
            case .calculator:
                return "Open Calculator, clear it, multiply 7 by 8, and tell me the result shown on its display."
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !Self.needsHuman else { throw XCTSkip("An earlier attempt needs human attention; no further tasks were sent.") }
        guard ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_LIVE_E2E"] == "1",
              ProcessInfo.processInfo.environment["RUN_EOD_SIMPLE_LIVE_E2E"] == "1" else {
            throw XCTSkip("Opt in to RUN_EOD_SIMPLE_LIVE_E2E only with the intended Release host, test data and an exclusive Mac-control window.")
        }
    }

    private func perform(_ task: TaskKind, run: Int) throws {
        let app = XCUIApplication()
        try ComputerUseLiveE2EPreflight.launchAfterSimulatorRegistrationSettles(app)
        guard app.wait(for: .runningForeground, timeout: 10) else {
            throw fail("The client did not enter the foreground.")
        }
        try requireNoSystemPrompt(in: app)
        let hosts = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Use AI Computer Use on "))
        guard wait(seconds: 45, until: { hosts.count > 0 }) else {
            throw fail("No paired AI-ready host appeared.")
        }
        guard hosts.count == 1 else {
            throw fail("More than one ready host is visible; select the intended host manually before this run.")
        }
        let host = hosts.element(boundBy: 0)
        let hostLabel = host.label
        host.tap()
        let local = app.descendants(matching: .any)["computer-use-local-connection"]
        let composer = app.textFields.matching(NSPredicate(
            format: "placeholderValue == %@", "Tell your Mac what to do")).firstMatch
        guard wait(seconds: 45, until: { local.exists && composer.exists && composer.isEnabled }) else {
            throw fail("The authenticated local conversation did not become ready.")
        }
        try requireNoSystemPrompt(in: app)
        guard !app.buttons["computer-use-stop-task"].exists,
              !app.buttons["computer-use-resume-ai"].exists else {
            throw fail("An earlier task is still active. Resolve it before another attempt.")
        }
        let suffix = "\(task.rawValue)-\(run)-\(UUID().uuidString.prefix(8))"
        let prompt = task.prompt(uniqueSuffix: suffix)
        let assistantMessages = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AI: "))
        let priorAssistantCount = assistantMessages.count
        let userMessages = app.staticTexts.matching(NSPredicate(format: "label == %@", "You: \(prompt)"))
        let priorUserCount = userMessages.count
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send request"]
        guard wait(seconds: 10, until: { send.exists && send.isEnabled }) else {
            throw fail("The request could not be sent.")
        }
        print("EOD_BEGIN task=\(task.rawValue) run=\(run) host=\(hostLabel) marker=\(suffix) prompt=\(prompt)")
        send.tap()
        let started = Date()
        let status = app.descendants(matching: .any)["computer-use-status"]
        let deadline = Date().addingTimeInterval(300)
        var outcome = ""
        repeat {
            try requireNoSystemPrompt(in: app, context: suffix)
            guard !app.buttons["computer-use-approval-deny"].exists else {
                // Leave the approval visible. This test never grants or denies it.
                Self.needsHuman = true
                attachDiagnostics(
                    named: "approval-\(suffix)",
                    details: { self.approvalDetails(in: app) })
                throw fail("EOD_NEEDS_USER task=\(task.rawValue) run=\(run): approval requested; no action selected.")
            }
            if userMessages.count > priorUserCount,
               assistantMessages.count > priorAssistantCount,
               let value = status.value as? String,
               ["Task completed", "Unable to complete", "User intervention required"].contains(value) {
                outcome = value
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        if outcome.isEmpty {
            Self.needsHuman = true
            // Only the app's own Stop control is allowed; never dismiss OS UI.
            let stop = app.buttons["computer-use-stop-task"]
            if stop.exists && stop.isHittable { stop.tap() }
            throw fail("EOD_TIMEOUT task=\(task.rawValue) run=\(run): no typed terminal outcome in 300 seconds.")
        }
        let answer = assistantMessages.count > priorAssistantCount
            ? assistantMessages.element(boundBy: assistantMessages.count - 1).label : ""
        attachDiagnostics(
            named: "terminal-\(suffix)",
            details: { "outcome=\(outcome)\n" + self.approvalDetails(in: app) })
        print("EOD_TERMINAL task=\(task.rawValue) run=\(run) elapsed=\(Date().timeIntervalSince(started)) outcome=\(outcome) answer=\(answer)")
        XCTAssertEqual(userMessages.count, priorUserCount + 1, "A request must be sent exactly once.")
        XCTAssertEqual(outcome, "Task completed", "This attempt did not complete; retain its failure or needs-you result.")
        print("EOD_REVIEW_REQUIRED task=\(task.rawValue) run=\(run) marker=\(suffix): check only this task's host episode and created artifact before assigning PASS.")
    }

    private func requireNoSystemPrompt(in app: XCUIApplication, context: String = "pre-task") throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardCount = springboard.alerts.count
        let appCount = app.alerts.count
        if springboardCount > 0 || appCount > 0 {
            Self.needsHuman = true
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
            throw fail("EOD_NEEDS_USER: a system or application alert is visible. No alert was dismissed.")
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

    private func wait(seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return predicate()
    }

    private enum Failure: Error { case blocked(String) }
    private func fail(_ reason: String) -> Failure {
        print(reason)
        XCTFail(reason)
        return .blocked(reason)
    }
    func test01AppleRun1() throws { try perform(.apple, run: 1) }
    func test01AppleRun2() throws { try perform(.apple, run: 2) }
    func test01AppleRun3() throws { try perform(.apple, run: 3) }
    func test01AppleRun4() throws { try perform(.apple, run: 4) }
    func test01AppleRun5() throws { try perform(.apple, run: 5) }
    func test02WikipediaRun1() throws { try perform(.wikipedia, run: 1) }
    func test02WikipediaRun2() throws { try perform(.wikipedia, run: 2) }
    func test02WikipediaRun3() throws { try perform(.wikipedia, run: 3) }
    func test02WikipediaRun4() throws { try perform(.wikipedia, run: 4) }
    func test02WikipediaRun5() throws { try perform(.wikipedia, run: 5) }
    func test03SummaryRun1() throws { try perform(.summary, run: 1) }
    func test03SummaryRun2() throws { try perform(.summary, run: 2) }
    func test03SummaryRun3() throws { try perform(.summary, run: 3) }
    func test03SummaryRun4() throws { try perform(.summary, run: 4) }
    func test03SummaryRun5() throws { try perform(.summary, run: 5) }
    func test04TextEditRun1() throws { try perform(.textEdit, run: 1) }
    func test04TextEditRun2() throws { try perform(.textEdit, run: 2) }
    func test04TextEditRun3() throws { try perform(.textEdit, run: 3) }
    func test04TextEditRun4() throws { try perform(.textEdit, run: 4) }
    func test04TextEditRun5() throws { try perform(.textEdit, run: 5) }
    func test05FinderRun1() throws { try perform(.finder, run: 1) }
    func test05FinderRun2() throws { try perform(.finder, run: 2) }
    func test05FinderRun3() throws { try perform(.finder, run: 3) }
    func test05FinderRun4() throws { try perform(.finder, run: 4) }
    func test05FinderRun5() throws { try perform(.finder, run: 5) }
    func test06OpenAppRun1() throws { try perform(.openApp, run: 1) }
    func test06OpenAppRun2() throws { try perform(.openApp, run: 2) }
    func test06OpenAppRun3() throws { try perform(.openApp, run: 3) }
    func test06OpenAppRun4() throws { try perform(.openApp, run: 4) }
    func test06OpenAppRun5() throws { try perform(.openApp, run: 5) }
    func test07SearchRun1() throws { try perform(.search, run: 1) }
    func test07SearchRun2() throws { try perform(.search, run: 2) }
    func test07SearchRun3() throws { try perform(.search, run: 3) }
    func test07SearchRun4() throws { try perform(.search, run: 4) }
    func test07SearchRun5() throws { try perform(.search, run: 5) }
    func test08CalculatorRun1() throws { try perform(.calculator, run: 1) }
    func test08CalculatorRun2() throws { try perform(.calculator, run: 2) }
    func test08CalculatorRun3() throws { try perform(.calculator, run: 3) }
    func test08CalculatorRun4() throws { try perform(.calculator, run: 4) }
    func test08CalculatorRun5() throws { try perform(.calculator, run: 5) }
}
