import XCTest

/// Read-only device prerequisites shared by the opted-in Computer Use UI tests.
/// This intentionally observes SpringBoard without activating it or interacting
/// with account-verification UI.
enum ComputerUseLiveE2EPreflight {
    static let appleAccountVerificationFailureMessage =
        "USER INTERVENTION REQUIRED: Complete Apple Account Verification in iPhone Air Simulator Settings, then rerun this live acceptance test. The test did not dismiss the alert or enter Apple Account credentials."
    private static let simulatorRegistrationSettleInterval: TimeInterval = 7

    private enum Failure: Error {
        case appleAccountVerificationRequired
    }

    /// `xcodebuild test-without-building` installs the UI target immediately
    /// before XCTest launches it. Simulator can briefly run that first process
    /// before LaunchServices has committed the app's CloudKit entitlements,
    /// causing cloudd to create an anonymous account and cache `.noAccount`.
    /// A bounded prelaunch followed by one ordinary relaunch exercises the
    /// shipped app after registration, without mocking or bypassing CloudKit.
    static func launchAfterSimulatorRegistrationSettles(
        _ app: XCUIApplication
    ) throws {
        app.launch()
        try requireNoAppleAccountVerification()

        #if targetEnvironment(simulator)
        let deadline = Date().addingTimeInterval(
            simulatorRegistrationSettleInterval)
        repeat {
            RunLoop.current.run(
                until: min(
                    deadline,
                    Date().addingTimeInterval(0.1)))
        } while Date() < deadline

        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        try requireNoAppleAccountVerification()
        #endif
    }

    static func requireNoAppleAccountVerification() throws {
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard")
        let alertTitle = "Apple Account Verification"
        let titledAlert = springboard.alerts.matching(
            NSPredicate(format: "label == %@", alertTitle)).firstMatch
        let titledText = springboard.staticTexts.matching(
            NSPredicate(format: "label == %@", alertTitle)).firstMatch
        let deadline = Date().addingTimeInterval(2)

        repeat {
            if titledAlert.exists || titledText.exists {
                XCTFail(appleAccountVerificationFailureMessage)
                throw Failure.appleAccountVerificationRequired
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }
}

/// Fixed-label, artifact-free cleanup for opted-in Computer Use UI tests.
/// It never touches the streamed screen or a macOS prompt. Approval is denied
/// through the shipped card; otherwise active work is paused and stopped
/// through the same controls a person uses. A cleanup action is not considered
/// complete until the corresponding host-authored terminal response arrives.
enum ComputerUseLiveE2ECleanup {
    static let stoppedResponse =
        "AI: Stopped. You're in control of the Mac."
    static let approvalCanceledResponse =
        "AI: Canceled. No action was taken."

    @discardableResult
    static func finishPendingTask(
        in app: XCUIApplication,
        previousAssistantCount: Int,
        timeout: TimeInterval = 60
    ) -> Bool {
        let stopped = app.staticTexts.matching(
            NSPredicate(format: "label == %@", stoppedResponse))
        let approvalCanceled = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                approvalCanceledResponse))
        let assistantMessages = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI: "))
        let approvalCancel = app.buttons["Cancel"]
        let takeControl = app.buttons["computer-use-take-control"]
        let stop = app.buttons["computer-use-stop-task"]
        let hideKeyboard = app.buttons["computer-use-hide-remote-keyboard"]
        let deadline = Date().addingTimeInterval(timeout)
        let stoppedCountBefore = stopped.count
        let approvalCanceledCountBefore = approvalCanceled.count
        var requestedApprovalCancellation = false
        var requestedStop = false

        repeat {
            if requestedStop, stopped.count > stoppedCountBefore { return true }
            if requestedApprovalCancellation,
               approvalCanceled.count > approvalCanceledCountBefore {
                return true
            }

            // A task that reached any terminal assistant response before the
            // cleanup controls appeared is already ledger-complete. Once this
            // helper requests a specific cancellation path, require its exact
            // terminal response instead of accepting an unrelated message.
            if !requestedApprovalCancellation,
               !requestedStop,
               assistantMessages.count > previousAssistantCount {
                return true
            }

            if hideKeyboard.exists && hideKeyboard.isHittable {
                hideKeyboard.tap()
            }

            if !requestedApprovalCancellation,
               !requestedStop,
               approvalCancel.exists,
               approvalCancel.isHittable {
                approvalCancel.tap()
                requestedApprovalCancellation = true
            } else if !requestedApprovalCancellation,
                      stop.exists,
                      stop.isHittable {
                stop.tap()
                requestedStop = true
            } else if !requestedApprovalCancellation,
                      !requestedStop,
                      takeControl.exists,
                      takeControl.isHittable {
                takeControl.tap()
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return false
    }
}
