import XCTest

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
