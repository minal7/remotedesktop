import XCTest

/// Opt-in matched-configuration acceptance for the local browser workbench's search and
/// persistent-loading scenarios over the authenticated LAN Computer Use path.
/// Each test submits one ordinary-language request from iOS. Safari must begin
/// in the background so app activation is part of the measured task.
///
/// Search runner preconditions:
/// - Freshly load `AcceptanceFixtures/LocalBrowserWorkbench.html#search` in
///   background Safari, with the fixture counters at zero.
/// - Make Calculator genuinely frontmost.
/// - Run matching host and iOS test configurations, with the
///   Simulator and Mac signed into the same Apple Account for zero-code pairing.
/// - Retain Mac-side postcondition evidence that the search field contains
///   exactly `downtown branch hours`, Click/Input/Submit events are exactly
///   2/21/1, and the exact result is visible.
///
/// Spinner runner preconditions are identical except Safari must contain a
/// fresh `LocalBrowserWorkbench.html#spinner`. That case must not interact with
/// the page and must settle into Unable to complete within the test bound.
final class OSAtlasLocalBrowserSearchSpinnerSimulatorLiveE2ETests:
    XCTestCase
{
    private enum EnvironmentKey {
        static let liveSuite = "RUN_COMPUTER_USE_LIVE_E2E"
        static let search =
            "RUN_OSATLAS_LOCAL_BROWSER_SEARCH_SIMULATOR_E2E"
        static let spinner =
            "RUN_OSATLAS_LOCAL_BROWSER_SPINNER_SIMULATOR_E2E"
        static let edge =
            "RUN_OSATLAS_LOCAL_BROWSER_EDGE_SIMULATOR_E2E"
    }

    private static let searchQuery = "downtown branch hours"
    private static let searchPrompt =
        "Please open Safari and use the local directory page already loaded there. Activate the visible Search field, type \"\(searchQuery)\" exactly once, press Return once to submit it, and tell me today's downtown branch hours."
    private static let searchResponse =
        "AI: Downtown branch hours — Today: 9:00 AM–5:00 PM"
    private static let spinnerPrompt =
        "Please open Safari and wait for the generated local inventory report on the page already loaded there to finish, then summarize the generated report."
    private static let spinnerResponse =
        "AI: I couldn't complete that task: The requested result was still loading after three checks, and no completed result became available."
    private static let journeyPrompt =
        "Please open Safari and use the local transit page already loaded there. Activate the only square-with-arrow icon to open route details in a new tab, select the Rates tab on that new page, and tell me the local express rate."
    private static let journeyResponse =
        "AI: Local express rate — $12.50"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[EnvironmentKey.liveSuite]
                == "1" else {
            throw XCTSkip(
                "Use the RemoteDesktopLiveE2E scheme for live Computer Use acceptance.")
        }
    }

    func testLocalDirectorySearchUsesOneNativeTypeAndOneSubmitBeforeExactResult()
        throws
    {
        try requireOptIn(
            EnvironmentKey.search,
            precondition: "fresh LocalBrowserWorkbench.html#search in background Safari with zero counters and Calculator frontmost")

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
                    "Cleanup could not stop the local-directory search safely; inspect the host and fixture before another live task.")
            }
        }
        installLocalNetworkInterruptionMonitor()

        let conversation = try openAuthenticatedLocalConversation(in: app)
        let submission = try submitSinglePrompt(
            Self.searchPrompt,
            in: app,
            composer: conversation.composer,
            taskWasSent: &taskWasSent,
            cleanupAssistantCount: &cleanupAssistantCount)

        let terminal = try waitForSearchResult(
            in: app,
            previousAssistantCount: submission.assistantCountBefore,
            timeout: 240)
        taskReachedTerminalResponse = true

        XCTAssertEqual(
            terminal.assistantLabel,
            Self.searchResponse,
            "Only the exact visible local-directory result is accepted.")
        XCTAssertTrue(
            terminal.progress.containsApplicationOpen,
            "The search completed without app-first Safari progress from Calculator.")
        XCTAssertEqual(
            terminal.progress.typeActionCount(
                characterCount: Self.searchQuery.count),
            1,
            "The exact search query must be entered by one native type action.")
        XCTAssertEqual(
            terminal.progress.allTypeActionCount,
            1,
            "The search path exposed an additional native type action.")
        XCTAssertTrue(
            terminal.progress.hasOrderedSearchSequence(
                characterCount: Self.searchQuery.count),
            "Expected ordered app-open, OS-Atlas pointer activation, native type, and Return/submit progress. Progress: \(terminal.progress.entries.joined(separator: " | "))")
        XCTAssertFalse(
            terminal.progress.containsUnsafeNonSearchAction,
            "The deterministic search used an unrelated drag, scroll, double-click, right-click, or keyboard shortcut.")

        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                status.exists
                    && (status.value as? String) == "Task completed"
                    && conversation.composer.exists
                    && conversation.composer.isEnabled
            },
            "The exact directory result did not retain the typed Task completed outcome.")
        XCTAssertFalse(
            hasApprovalOrIntervention(in: app),
            "The harmless local search unexpectedly required approval or user intervention.")
        XCTAssertFalse(
            hasActiveLifecycleControls(in: app),
            "The completed local search left lifecycle controls active.")
        XCTAssertEqual(
            assistantMessages(in: app).count,
            submission.assistantCountBefore + 1,
            "The local search produced more than one terminal assistant response.")
        assertSingleUserSubmission(submission, in: app)
        XCTAssertTrue(
            conversation.localConnection.exists,
            "The authenticated local connection disappeared after the search.")
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "The shipped iOS client left the foreground during search acceptance.")

        let evidence = XCTAttachment(string: """
        OUTCOME: task completed
        TRANSPORT: matched signed iOS -> TLS-authenticated local LAN broker -> signed macOS host
        ONE NATURAL-LANGUAGE SUBMISSION: true
        APP-FIRST SAFARI PROGRESS: \(terminal.progress.containsApplicationOpen)
        OS-ATLAS POINTER ACTIVATION BEFORE TYPE: true
        NATIVE TYPE ACTIONS: \(terminal.progress.allTypeActionCount)
        NATIVE RETURN/SUBMIT AFTER TYPE: true
        EXACT HOST-VERIFIED RESULT: Downtown branch hours — Today: 9:00 AM–5:00 PM
        REQUIRED RUNNER POSTCONDITION: field value = downtown branch hours; Click events = 2 (field activation + Return's synthetic submit click); Input events = 21; Submit events = 1
        """)
        evidence.name = "Local browser directory search evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testIconOnlyRouteOpensNewPageAndUsesTypedPlanningBeforeRawGrounding()
        throws
    {
        try requireOptIn(
            EnvironmentKey.edge,
            precondition: "fresh LocalBrowserWorkbench.html#journey in background Safari with zero counters and Calculator frontmost")

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
                    "Cleanup could not stop the icon-only route task safely.")
            }
        }
        installLocalNetworkInterruptionMonitor()

        let conversation = try openAuthenticatedLocalConversation(in: app)
        let submission = try submitSinglePrompt(
            Self.journeyPrompt,
            in: app,
            composer: conversation.composer,
            taskWasSent: &taskWasSent,
            cleanupAssistantCount: &cleanupAssistantCount)
        let terminal = try waitForSearchResult(
            in: app,
            previousAssistantCount: submission.assistantCountBefore,
            timeout: 300)
        taskReachedTerminalResponse = true

        XCTAssertEqual(
            terminal.assistantLabel,
            Self.journeyResponse,
            "Only the exact visible rate from the second local page is accepted.")
        XCTAssertTrue(
            terminal.progress.containsApplicationOpen,
            "The route task completed without opening Safari from Calculator.")
        XCTAssertGreaterThanOrEqual(
            terminal.progress.typedPlannerStepCount,
            2,
            "The two target-bearing steps did not expose typed semantic planning before pointer action.")
        XCTAssertEqual(
            terminal.progress.clickActionCount,
            2,
            "The route must use exactly one icon activation and one Rates-tab activation.")
        XCTAssertEqual(
            terminal.progress.waitActionCount,
            0,
            "The stable multipage route must not invent a wait action.")
        XCTAssertEqual(
            terminal.progress.allTypeActionCount,
            0,
            "The icon-and-tab route must not type into the browser.")
        XCTAssertFalse(
            terminal.progress.containsUnsafeJourneyAction,
            "The route used an unrelated drag, scroll, double-click, right-click, Return, or keyboard shortcut. Progress: \(terminal.progress.entries.joined(separator: " | "))")

        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                status.exists
                    && (status.value as? String) == "Task completed"
                    && conversation.composer.exists
                    && conversation.composer.isEnabled
            },
            "The exact route rate did not retain typed Task completed.")
        XCTAssertFalse(
            hasApprovalOrIntervention(in: app),
            "The harmless icon-and-tab route unexpectedly required approval or takeover.")
        XCTAssertFalse(
            hasActiveLifecycleControls(in: app),
            "The completed icon-and-tab route left lifecycle controls active.")
        XCTAssertEqual(
            assistantMessages(in: app).count,
            submission.assistantCountBefore + 1,
            "The icon-and-tab route produced more than one terminal response.")
        assertSingleUserSubmission(submission, in: app)
        XCTAssertTrue(conversation.localConnection.exists)
        XCTAssertEqual(app.state, .runningForeground)

        let evidence = XCTAttachment(string: """
        OUTCOME: task completed
        ONE NATURAL-LANGUAGE SUBMISSION: true
        APP-FIRST SAFARI PROGRESS: \(terminal.progress.containsApplicationOpen)
        TYPED SEMANTIC PLANNING STEPS: \(terminal.progress.typedPlannerStepCount)
        POINTER ACTIVATIONS: \(terminal.progress.clickActionCount)
        REQUIRED RUNNER ATTESTATION: Apple Foundation planner provenance plus task-bound raw point equality before host grounding for both pointer actions
        REQUIRED RUNNER POSTCONDITION: one new local browser page; Click events = 2; Route opens = 1; Tab selections = 1; exact local express rate visible
        """)
        evidence.name = "Icon-only multipage browser evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testPersistentSpinnerWaitsWithinBoundThenReturnsTypedUnableToComplete()
        throws
    {
        try requireOptIn(
            EnvironmentKey.spinner,
            precondition: "fresh LocalBrowserWorkbench.html#spinner in background Safari with zero counters and Calculator frontmost")

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
                    "Cleanup could not stop the bounded spinner task; inspect the host before another live task.")
            }
        }
        installLocalNetworkInterruptionMonitor()

        let conversation = try openAuthenticatedLocalConversation(in: app)
        let submission = try submitSinglePrompt(
            Self.spinnerPrompt,
            in: app,
            composer: conversation.composer,
            taskWasSent: &taskWasSent,
            cleanupAssistantCount: &cleanupAssistantCount)
        let startedAt = Date()
        let terminal = try waitForSpinnerOutcome(
            in: app,
            previousAssistantCount: submission.assistantCountBefore,
            timeout: 240)
        let elapsed = Date().timeIntervalSince(startedAt)
        taskReachedTerminalResponse = true

        XCTAssertTrue(
            terminal.progress.containsApplicationOpen,
            "The generated-report request returned without app-first Safari progress from Calculator.")
        XCTAssertEqual(
            terminal.progress.waitActionCount,
            3,
            "The persistent loading state must receive exactly three fresh bounded observations before the typed unable result.")
        XCTAssertLessThan(
            elapsed,
            240,
            "The persistent loading page did not terminate inside the live acceptance bound.")
        XCTAssertFalse(
            terminal.progress.containsBrowserInput,
            "The control-free spinner page received browser input. Progress: \(terminal.progress.entries.joined(separator: " | "))")

        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                status.exists
                    && (status.value as? String) == "Unable to complete"
                    && conversation.composer.exists
                    && conversation.composer.isEnabled
            },
            "The bounded persistent-loading result did not retain typed Unable to complete.")
        XCTAssertEqual(
            terminal.assistantLabel,
            Self.spinnerResponse,
            "The spinner must return only the exact host-authored persistent-loading result.")
        XCTAssertFalse(
            terminal.assistantLabel.localizedCaseInsensitiveContains(
                "report summary"),
            "The assistant fabricated a generated report from a page that never produced one.")
        XCTAssertFalse(
            hasApprovalOrIntervention(in: app),
            "A control-free persistent loading page incorrectly requested approval or manual takeover.")
        XCTAssertFalse(
            hasActiveLifecycleControls(in: app),
            "The terminal spinner outcome left lifecycle controls active.")
        XCTAssertEqual(
            assistantMessages(in: app).count,
            submission.assistantCountBefore + 1,
            "The spinner task produced more than one terminal assistant response.")
        assertSingleUserSubmission(submission, in: app)
        XCTAssertTrue(
            conversation.localConnection.exists,
            "The authenticated local connection disappeared after the spinner result.")
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "The shipped iOS client left the foreground during spinner acceptance.")

        let evidence = XCTAttachment(string: """
        OUTCOME: unable to complete
        TRANSPORT: matched signed iOS -> TLS-authenticated local LAN broker -> signed macOS host
        ONE NATURAL-LANGUAGE SUBMISSION: true
        APP-FIRST SAFARI PROGRESS: \(terminal.progress.containsApplicationOpen)
        OBSERVED WAIT ACTIONS: \(terminal.progress.waitActionCount)
        ELAPSED AFTER SUBMISSION: \(String(format: "%.2f", elapsed)) seconds
        BROWSER INPUT ACTIONS: 0
        TERMINAL BOUND: 240 seconds, 3 pending observations, and 25 total actions
        REQUIRED RUNNER POSTCONDITION: Click events = 0; Submit events = 0; Input events = 0
        """)
        evidence.name = "Local browser persistent-spinner evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private struct LocalConversation {
        let composer: XCUIElement
        let localConnection: XCUIElement
    }

    private struct Submission {
        let prompt: String
        let assistantCountBefore: Int
        let userCountBefore: Int
    }

    private struct TerminalObservation {
        let assistantLabel: String
        let progress: ProgressTrace
    }

    private struct ProgressTrace {
        private(set) var entries: [String] = []
        private var seen: Set<String> = []

        mutating func absorb(_ history: String) {
            for rawLine in history.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard line.range(
                    of: #"^Step [0-9]+: .+"#,
                    options: .regularExpression) != nil,
                      seen.insert(line).inserted else {
                    continue
                }
                entries.append(line)
            }
        }

        var containsApplicationOpen: Bool {
            contains(
                #"^Step [0-9]+: opening (?:an app|Safari).*"#)
        }

        var allTypeActionCount: Int {
            count(#"^Step [0-9]+: typing [0-9]+ characters.*"#)
        }

        func typeActionCount(characterCount: Int) -> Int {
            count(
                "^Step [0-9]+: typing \(characterCount) characters.*")
        }

        var waitActionCount: Int {
            count(#"^Step [0-9]+: waiting(?: for the Mac)?…?$"#)
        }

        var typedPlannerStepCount: Int {
            count(
                #"^Step [0-9]+: understanding the requested action…?$"#)
        }

        var clickActionCount: Int {
            count(#"^Step [0-9]+: clicking.*"#)
        }

        var containsBrowserInput: Bool {
            contains(
                #"^Step [0-9]+: (?:clicking|double-clicking|right-clicking|dragging|typing .+|scrolling .+|pressing Return|using a keyboard shortcut).*"#)
        }

        var containsUnsafeNonSearchAction: Bool {
            contains(
                #"^Step [0-9]+: (?:double-clicking|right-clicking|dragging|scrolling .+|using a keyboard shortcut).*"#)
        }

        var containsUnsafeJourneyAction: Bool {
            contains(
                #"^Step [0-9]+: (?:double-clicking|right-clicking|dragging|scrolling .+|pressing Return|using a keyboard shortcut).*"#)
        }

        func hasOrderedSearchSequence(characterCount: Int) -> Bool {
            guard let openIndex = firstIndex(
                    #"^Step [0-9]+: opening (?:an app|Safari).*"#),
                  let clickIndex = firstIndex(
                    #"^Step [0-9]+: clicking.*"#),
                  let typeIndex = firstIndex(
                    "^Step [0-9]+: typing \(characterCount) characters.*"),
                  let submitIndex = firstIndex(
                    #"^Step [0-9]+: pressing Return.*"#) else {
                return false
            }
            return openIndex < clickIndex
                && clickIndex < typeIndex
                && typeIndex < submitIndex
                && count(#"^Step [0-9]+: pressing Return.*"#) == 1
        }

        private func contains(_ pattern: String) -> Bool {
            firstIndex(pattern) != nil
        }

        private func firstIndex(_ pattern: String) -> Int? {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]) else {
                return nil
            }
            return entries.firstIndex { entry in
                expression.firstMatch(
                    in: entry,
                    range: NSRange(entry.startIndex..., in: entry)) != nil
            }
        }

        private func count(_ pattern: String) -> Int {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]) else {
                return 0
            }
            return entries.reduce(into: 0) { result, entry in
                if expression.firstMatch(
                    in: entry,
                    range: NSRange(entry.startIndex..., in: entry)) != nil {
                    result += 1
                }
            }
        }
    }

    private enum AcceptanceFailure: Error {
        case unmetPrecondition
        case transportFailure
        case unsafeAction
        case unexpectedOutcome
        case timedOut
    }

    private func requireOptIn(
        _ key: String,
        precondition: String
    ) throws {
        guard ProcessInfo.processInfo.environment[key] == "1" else {
            throw XCTSkip(
                "Set \(key)=1 only with \(precondition), matching host/iOS configurations, and a paired local AI host.")
        }
    }

    private func installLocalNetworkInterruptionMonitor() {
        addUIInterruptionMonitor(withDescription: "Local network access") {
            alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
    }

    private func openAuthenticatedLocalConversation(
        in app: XCUIApplication
    ) throws -> LocalConversation {
        try ComputerUseLiveE2EPreflight
            .launchAfterSimulatorRegistrationSettles(app)
        guard app.wait(for: .runningForeground, timeout: 10) else {
            XCTFail(
                "The shipped iOS client did not reach the foreground in Simulator.")
            throw AcceptanceFailure.unmetPrecondition
        }
        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()

        let readyButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Use AI Computer Use on ")).firstMatch
        let legacyPairButton = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Pair local AI Computer Use on ")).firstMatch
        guard readyButton.waitForExistence(timeout: 90) else {
            XCTFail(
                "The iOS client did not automatically pair with the same-iCloud local AI host.")
            throw AcceptanceFailure.unmetPrecondition
        }
        XCTAssertFalse(
            legacyPairButton.exists,
            "The shipped client must never ask for a local AI access key.")
        guard readyButton.isHittable else {
            XCTFail("Use AI was not directly tappable in Simulator.")
            throw AcceptanceFailure.unmetPrecondition
        }
        readyButton.tap()

        let localConnection = app.descendants(matching: .any).matching(
            identifier: "computer-use-local-connection").firstMatch
        guard localConnection.waitForExistence(timeout: 45) else {
            XCTFail(
                "The TLS-authenticated local AI conversation did not open in the shipped iOS UI.")
            throw AcceptanceFailure.transportFailure
        }

        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        guard waitUntil(timeout: 45, predicate: {
            composer.exists && composer.isEnabled
        }) else {
            XCTFail(
                "The local Computer Use conversation did not become ready for one prompt.")
            throw AcceptanceFailure.transportFailure
        }
        waitForConversationRenderingToSettle(in: app, composer: composer)
        return LocalConversation(
            composer: composer,
            localConnection: localConnection)
    }

    private func submitSinglePrompt(
        _ prompt: String,
        in app: XCUIApplication,
        composer: XCUIElement,
        taskWasSent: inout Bool,
        cleanupAssistantCount: inout Int
    ) throws -> Submission {
        let assistants = assistantMessages(in: app)
        let users = userMessages(in: app)
        let submission = Submission(
            prompt: prompt,
            assistantCountBefore: assistants.count,
            userCountBefore: users.count)
        cleanupAssistantCount = submission.assistantCountBefore

        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send request"]
        guard waitUntil(timeout: 10, predicate: {
            send.exists && send.isEnabled
        }) else {
            XCTFail("The browser request did not enable Send.")
            throw AcceptanceFailure.transportFailure
        }
        send.tap()
        taskWasSent = true

        let exactMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "You: \(prompt)")).firstMatch
        guard waitUntil(timeout: 10, predicate: {
            exactMessage.exists
                && userMessages(in: app).count
                    == submission.userCountBefore + 1
        }) else {
            XCTFail("The exact natural-language browser request was not shown.")
            throw AcceptanceFailure.transportFailure
        }
        XCTAssertEqual(
            users.count,
            submission.userCountBefore + 1,
            "The browser request was submitted more than once.")
        return submission
    }

    private func waitForSearchResult(
        in app: XCUIApplication,
        previousAssistantCount: Int,
        timeout: TimeInterval
    ) throws -> TerminalObservation {
        let approval = app.staticTexts["Approve before AI continues"]
        let intervention = app.descendants(matching: .any)[
            "computer-use-intervention-guidance"]
        let retry = app.buttons["Retry sending the last request"]
        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var progress = ProgressTrace()

        repeat {
            progress.absorb(progressHistory(in: app))
            if approval.exists || intervention.exists {
                XCTFail(
                    "The harmless local-directory search entered approval or manual takeover.")
                throw AcceptanceFailure.unexpectedOutcome
            }
            if retry.exists {
                XCTFail("The local-directory search failed in LAN transport.")
                throw AcceptanceFailure.transportFailure
            }

            let messages = assistantMessages(in: app)
            let messageCount = messages.count
            if messageCount > previousAssistantCount {
                let typedOutcome = status.exists
                    ? status.value as? String
                    : nil
                if typedOutcome == "Unable to complete" {
                    XCTFail(
                        "The local-directory result was incorrectly returned as unable to complete.")
                    throw AcceptanceFailure.unexpectedOutcome
                }
                guard typedOutcome == "Task completed",
                      composer.exists,
                      composer.isEnabled else {
                    RunLoop.current.run(
                        until: Date().addingTimeInterval(0.2))
                    continue
                }
                progress.absorb(progressHistory(in: app))
                return TerminalObservation(
                    assistantLabel: messages.element(
                        boundBy: messageCount - 1).label,
                    progress: progress)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "No terminal local-directory result returned within \(Int(timeout)) seconds.")
        throw AcceptanceFailure.timedOut
    }

    private func waitForSpinnerOutcome(
        in app: XCUIApplication,
        previousAssistantCount: Int,
        timeout: TimeInterval
    ) throws -> TerminalObservation {
        let approval = app.staticTexts["Approve before AI continues"]
        let intervention = app.descendants(matching: .any)[
            "computer-use-intervention-guidance"]
        let retry = app.buttons["Retry sending the last request"]
        let status = app.descendants(matching: .any).matching(
            identifier: "computer-use-status").firstMatch
        let composer = app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@",
                "Tell your Mac what to do")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var progress = ProgressTrace()

        repeat {
            progress.absorb(progressHistory(in: app))
            if progress.containsBrowserInput {
                XCTFail(
                    "The executor attempted input on the control-free spinner page. Progress: \(progress.entries.joined(separator: " | "))")
                throw AcceptanceFailure.unsafeAction
            }
            if approval.exists || intervention.exists {
                XCTFail(
                    "The control-free spinner entered approval or manual takeover.")
                throw AcceptanceFailure.unexpectedOutcome
            }
            if retry.exists {
                XCTFail("The spinner request failed in LAN transport.")
                throw AcceptanceFailure.transportFailure
            }

            let messages = assistantMessages(in: app)
            let messageCount = messages.count
            if messageCount > previousAssistantCount {
                let typedOutcome = status.exists
                    ? status.value as? String
                    : nil
                if typedOutcome == "Task completed" {
                    XCTFail(
                        "The persistent spinner fabricated a completed result.")
                    throw AcceptanceFailure.unexpectedOutcome
                }
                guard typedOutcome == "Unable to complete",
                      composer.exists,
                      composer.isEnabled else {
                    RunLoop.current.run(
                        until: Date().addingTimeInterval(0.2))
                    continue
                }
                progress.absorb(progressHistory(in: app))
                return TerminalObservation(
                    assistantLabel: messages.element(
                        boundBy: messageCount - 1).label,
                    progress: progress)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "The persistent loading page did not reach a bounded terminal response within \(Int(timeout)) seconds.")
        throw AcceptanceFailure.timedOut
    }

    /// The progress ledger is optional in older already-built products. Never
    /// access `value` unless the shipped element is present.
    private func progressHistory(in app: XCUIApplication) -> String {
        let progress = app.descendants(matching: .any).matching(
            identifier: "computer-use-progress-history").firstMatch
        guard progress.exists else { return "" }
        return progress.value as? String ?? ""
    }

    private func waitForConversationRenderingToSettle(
        in app: XCUIApplication,
        composer: XCUIElement
    ) {
        let deadline = Date().addingTimeInterval(5)
        var lastCounts: (assistant: Int, user: Int)?
        var stableSamples = 0
        repeat {
            let counts = (
                assistant: assistantMessages(in: app).count,
                user: userMessages(in: app).count)
            if let lastCounts,
               lastCounts.assistant == counts.assistant,
               lastCounts.user == counts.user,
               composer.exists,
               composer.isEnabled {
                stableSamples += 1
                if stableSamples >= 4 { return }
            } else {
                stableSamples = 0
                lastCounts = counts
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
    }

    private func hasApprovalOrIntervention(in app: XCUIApplication) -> Bool {
        app.staticTexts["Approve before AI continues"].exists
            || app.descendants(matching: .any)[
                "computer-use-intervention-guidance"].exists
    }

    private func hasActiveLifecycleControls(in app: XCUIApplication) -> Bool {
        app.buttons["computer-use-take-control"].exists
            || app.buttons["computer-use-resume-ai"].exists
            || app.buttons["computer-use-stop-task"].exists
    }

    private func assertSingleUserSubmission(
        _ submission: Submission,
        in app: XCUIApplication
    ) {
        XCTAssertEqual(
            userMessages(in: app).count,
            submission.userCountBefore + 1,
            "The one natural-language browser request was submitted more than once.")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@",
                    "You: \(submission.prompt)")).firstMatch.exists,
            "The exact browser request disappeared before its outcome was verified.")
    }

    private func assistantMessages(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI: "))
    }

    private func userMessages(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "You: "))
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
