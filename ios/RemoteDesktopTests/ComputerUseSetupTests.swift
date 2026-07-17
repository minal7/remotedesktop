import XCTest
@testable import RemoteDesktop

@MainActor
final class ComputerUseSetupTests: XCTestCase {
    func test_setupRequest_roundTripsStableIdempotencyKey() throws {
        let request = ComputerUseSetupRequest(requestID: "request-1")

        let decoded = try ComputerUseSetupRequest.decodeBody(request.encodedBody())

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.idempotencyKey, "computer-use-setup-v2")
    }

    func test_setupProgress_clampsFractionDuringInitAndDecode() throws {
        let high = ComputerUseSetupProgress(
            requestID: "request-1",
            phase: .downloadingModel,
            fractionCompleted: 1.7,
            detail: "Downloading AI…")
        XCTAssertEqual(high.fractionCompleted, 1)

        let body = """
        {
          "requestID": "request-2",
          "phase": "installingPackages",
          "fractionCompleted": -0.5,
          "detail": "Preparing AI…"
        }
        """
        let decoded = try ComputerUseSetupProgress.decodeBody(body)
        XCTAssertEqual(decoded.fractionCompleted, 0)
        XCTAssertEqual(decoded.idempotencyKey, ComputerUseSetupRequest.currentIdempotencyKey)
    }

    func test_approvalPayloadsRoundTripAndBoundUserFacingCopy() throws {
        let request = ComputerUseApprovalRequest(
            requestID: "approval-1",
            taskID: "task-1",
            message: String(repeating: "x", count: 700),
            details: [
                .init(label: "To", value: "codex-acceptance@example.invalid"),
                .init(label: "Subject", value: "Remote Desktop acceptance test"),
                .init(label: "Message", value: "This is a safe local acceptance test."),
            ],
            confirmLabel: "Send email")
        XCTAssertEqual(request.message.count, 500)
        XCTAssertEqual(
            try ComputerUseApprovalRequest.decodeBody(request.encodedBody()),
            request)
        XCTAssertEqual(request.details?.first?.label, "To")
        XCTAssertEqual(request.confirmLabel, "Send email")

        let legacy = try ComputerUseApprovalRequest.decodeBody(#"{"requestID":"legacy","taskID":"task","message":"Continue?"}"#)
        XCTAssertNil(legacy.details)
        XCTAssertNil(legacy.confirmLabel)

        let response = ComputerUseApprovalResponse(
            requestID: request.requestID,
            approved: true)
        XCTAssertEqual(
            try ComputerUseApprovalResponse.decodeBody(response.encodedBody()),
            response)

        let update = ComputerUseTaskUpdate(taskID: "task-1", text: "Working")
        XCTAssertEqual(
            try ComputerUseTaskUpdate.decodeBody(update.encodedBody()),
            update)

        let control = ComputerUseControlRequest(
            taskID: "task-1",
            revision: 7)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(control.encodedBody()),
            control)
    }

    func test_taskUpdateTerminalOutcomesRoundTripAndLegacyPayloadStillDecodes() throws {
        let outcomes: [ComputerUseTerminalOutcome] = [
            .taskCompleted,
            .userInterventionRequired,
            .unableToComplete,
        ]

        for outcome in outcomes {
            let update = ComputerUseTaskUpdate(
                taskID: "task-\(outcome.rawValue)",
                text: "Result for \(outcome.rawValue)",
                appliedControlRevision: 4,
                outcome: outcome)

            XCTAssertEqual(
                try ComputerUseTaskUpdate.decodeBody(update.encodedBody()),
                update)
        }

        let legacy = try ComputerUseTaskUpdate.decodeBody(
            #"{"taskID":"legacy-task","text":"Legacy result","appliedControlRevision":3}"#)
        XCTAssertEqual(legacy.taskID, "legacy-task")
        XCTAssertEqual(legacy.text, "Legacy result")
        XCTAssertEqual(legacy.appliedControlRevision, 3)
        XCTAssertNil(legacy.outcome)

        let future = try ComputerUseTaskUpdate.decodeBody(
            #"{"taskID":"future-task","text":"Future result","outcome":"deferredByPolicy"}"#)
        XCTAssertEqual(future.taskID, "future-task")
        XCTAssertEqual(future.text, "Future result")
        XCTAssertNil(
            future.outcome,
            "An unknown future outcome must not reject the correlated update")
    }

    func test_typedAssistantUpdatesExposeAndApplyAllTerminalOutcomes() async throws {
        let rows: [(ComputerUseTerminalOutcome, String, String)] = [
            (
                .taskCompleted,
                "The requested task is complete.",
                "Task completed — ready for another request"),
            (
                .userInterventionRequired,
                "Please choose which account I should use.",
                "Your input is required before your Mac can continue"),
            (
                .unableToComplete,
                "Could not complete this request — retry?",
                "Unable to complete — ready for another request"),
        ]

        for (outcome, text, expectedStatus) in rows {
            let channel = FakeComputerUseSessionChannel()
            let model = ComputerUseSessionModel(
                hostName: "Studio Mac",
                pairingCode: "123456",
                hostID: "HOST-\(UUID().uuidString)",
                sessionID: "session-1",
                pendingStore: InMemoryComputerUsePendingPromptStore(),
                channel: channel)
            model.start()
            model.sendPrompt("Exercise \(outcome.rawValue)")
            let sentPrompt = await waitForSentMessage(
                kind: .prompt,
                channel: channel)
            let prompt = try XCTUnwrap(sentPrompt)

            try await channel.enqueueHostEnvelope(
                kind: .assistant,
                body: ComputerUseTaskUpdate(
                    taskID: prompt.id,
                    text: text,
                    outcome: outcome).encodedBody())
            await waitUntil { model.latestTerminalOutcome == outcome }

            XCTAssertEqual(model.latestTerminalOutcome, outcome)
            XCTAssertEqual(model.state, .ready)
            XCTAssertTrue(model.messages.contains {
                $0.author == .assistant && $0.text == text
            })
            XCTAssertFalse(model.hasActivePrompt)
            XCTAssertNil(model.interventionGuidance)
            XCTAssertEqual(model.statusText, expectedStatus)
            model.stop()
        }
    }

    func test_newPromptPersistenceFailureClearsPreviousTerminalOutcome() async throws {
        let store = InMemoryComputerUsePendingPromptStore(
            failAfterSuccessfulSaves: 1)
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: "HOST-\(UUID().uuidString)",
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        model.start()

        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "Calculator is open.",
                outcome: .taskCompleted).encodedBody())
        await waitUntil { model.latestTerminalOutcome == .taskCompleted }
        XCTAssertEqual(model.state, .ready)

        model.sendPrompt("Open Notes")

        XCTAssertNil(model.latestTerminalOutcome)
        XCTAssertEqual(
            model.state,
            .error("Couldn’t securely save this request, so it was not sent."))
        XCTAssertEqual(
            model.statusText,
            "Request not sent — secure recovery storage is unavailable")
        XCTAssertNil(ComputerUseTerminalStatusStyle(
            model.latestTerminalOutcome))
        let promptAttempts = await channel.sendAttemptCount(kind: .prompt)
        XCTAssertEqual(
            promptAttempts,
            1,
            "The unsaved request must not be transmitted")
    }

    func test_typedStatusUpdatesExposeAndApplyAllTerminalOutcomes() async throws {
        let guidance = "Finish signing in yourself, then resume."
        let rows: [(ComputerUseTerminalOutcome, String, String, ComputerUseSessionModel.State)] = [
            (.taskCompleted, "Task complete.", "Task complete.", .ready),
            (
                .userInterventionRequired,
                ComputerUseStatusSignal.userIntervention(guidance),
                guidance,
                .paused),
            (.unableToComplete, "Task cannot be completed.", "Task cannot be completed.", .ready),
        ]

        for (outcome, text, displayedText, expectedState) in rows {
            let channel = FakeComputerUseSessionChannel()
            let model = ComputerUseSessionModel(
                hostName: "Studio Mac",
                pairingCode: "123456",
                hostID: "HOST-\(UUID().uuidString)",
                sessionID: "session-1",
                pendingStore: InMemoryComputerUsePendingPromptStore(),
                channel: channel)
            model.start()
            model.sendPrompt("Exercise status \(outcome.rawValue)")
            let sentPrompt = await waitForSentMessage(
                kind: .prompt,
                channel: channel)
            let prompt = try XCTUnwrap(sentPrompt)

            try await channel.enqueueHostEnvelope(
                kind: .status,
                body: ComputerUseTaskUpdate(
                    taskID: prompt.id,
                    text: text,
                    outcome: outcome).encodedBody())
            await waitUntil { model.latestTerminalOutcome == outcome }

            XCTAssertEqual(model.latestTerminalOutcome, outcome)
            XCTAssertEqual(model.state, expectedState)
            XCTAssertEqual(model.statusText, displayedText)
            if outcome == .userInterventionRequired {
                XCTAssertTrue(model.hasActivePrompt)
                XCTAssertEqual(model.interventionGuidance, guidance)
            } else {
                XCTAssertFalse(model.hasActivePrompt)
                XCTAssertNil(model.interventionGuidance)
            }
            model.stop()
        }
    }

    func test_resumingOrWorkingClearsStaleInterventionOutcome() async throws {
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: "HOST-\(UUID().uuidString)",
            sessionID: "session-1",
            pendingStore: InMemoryComputerUsePendingPromptStore(),
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Continue after I sign in")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        let status = ComputerUseStatusSignal.userIntervention(
            "Finish signing in, then resume.")

        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: status,
                outcome: .userInterventionRequired).encodedBody())
        await waitUntil {
            model.latestTerminalOutcome == .userInterventionRequired
        }
        _ = await waitForSentMessage(kind: .pause, channel: channel)

        model.applyHostStatus("working")
        XCTAssertNil(model.latestTerminalOutcome)
        XCTAssertEqual(model.state, .working)

        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: status,
                appliedControlRevision: 1,
                outcome: .userInterventionRequired).encodedBody())
        await waitUntil {
            model.latestTerminalOutcome == .userInterventionRequired
        }
        model.resumeAI()
        XCTAssertNil(model.latestTerminalOutcome)
        XCTAssertEqual(model.state, .working)
    }

    func test_versionedPausedAcknowledgementPreservesTypedInterventionGuidance() async throws {
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: "HOST-\(UUID().uuidString)",
            sessionID: "session-1",
            pendingStore: InMemoryComputerUsePendingPromptStore(),
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Continue after I sign in")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        let guidance = "Finish signing in to Contoso, then tap Let AI continue."

        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: ComputerUseStatusSignal.userIntervention(guidance),
                outcome: .userInterventionRequired).encodedBody())
        await waitUntil {
            model.latestTerminalOutcome == .userInterventionRequired
                && model.interventionGuidance == guidance
        }
        _ = await waitForSentMessage(kind: .pause, channel: channel)

        let acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }

        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(
            model.latestTerminalOutcome,
            .userInterventionRequired)
        XCTAssertEqual(model.interventionGuidance, guidance)
        XCTAssertEqual(model.statusText, guidance)
    }

    func test_typedTerminalOutcomesSelectNonSuccessStatusStyles() {
        let completed = ComputerUseTerminalStatusStyle(.taskCompleted)
        XCTAssertEqual(completed, .completed)
        XCTAssertEqual(completed?.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(completed?.tint, .green)

        let clarification = ComputerUseTerminalStatusStyle(
            .userInterventionRequired)
        XCTAssertEqual(clarification, .userIntervention)
        XCTAssertEqual(clarification?.systemImage, "hand.raised.fill")
        XCTAssertEqual(clarification?.tint, .orange)

        let unable = ComputerUseTerminalStatusStyle(.unableToComplete)
        XCTAssertEqual(unable, .unable)
        XCTAssertEqual(unable?.systemImage, "exclamationmark.triangle.fill")
        XCTAssertEqual(unable?.tint, .red)
        XCTAssertNil(ComputerUseTerminalStatusStyle(nil))
    }

    func test_userInterventionStatusEntersManualControlWithResumeGuidance() {
        let guidance = "DoorDash needs you to sign in yourself, then tap Let AI continue."
        let status = ComputerUseStatusSignal.userIntervention(guidance)
        XCTAssertEqual(
            ComputerUseStatusSignal.userInterventionMessage(from: status),
            guidance)
        XCTAssertNil(ComputerUseStatusSignal.userInterventionMessage(
            from: "Sign in to an unrelated app"))

        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: FakeComputerUseSessionChannel())
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }

        model.applyHostStatus(status)

        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.statusText, guidance)
        XCTAssertEqual(model.interventionGuidance, guidance)
    }

    func test_sessionTakeControlPausesLocallyAndSendsPauseControl() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        let taskID = try XCTUnwrap(sentPrompt?.id)
        model.applyHostStatus("working")

        model.takeControl()

        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.statusText, "AI paused — you're in control")
        XCTAssertNil(model.interventionGuidance)
        let sentPause = await waitForSentMessage(kind: .pause, channel: channel)
        let pause = try XCTUnwrap(sentPause)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(pause.body),
            ComputerUseControlRequest(taskID: taskID, revision: 1))
    }

    func test_sessionResumeAIMarksWorkingAndSendsResumeControl() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Continue the current task")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        let taskID = try XCTUnwrap(sentPrompt?.id)
        model.applyHostStatus(ComputerUseStatusSignal.userIntervention(
            "Finish signing in, then resume."))

        model.resumeAI()

        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Asking AI to continue…")
        XCTAssertNil(model.interventionGuidance)
        let sentResume = await waitForSentMessage(kind: .resume, channel: channel)
        let resume = try XCTUnwrap(sentResume)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(resume.body),
            ComputerUseControlRequest(taskID: taskID, revision: 2))
    }

    func test_sessionStopCurrentTaskSendsCancelForActivePrompt() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        XCTAssertNotNil(sentPrompt)
        XCTAssertTrue(model.hasActivePrompt)

        model.stopCurrentTask()

        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Stopping the task…")
        let sentCancel = await waitForSentMessage(kind: .cancel, channel: channel)
        let cancel = try XCTUnwrap(sentCancel)
        let prompt = try XCTUnwrap(sentPrompt)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(cancel.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 1))
    }

    func test_controlRevisionPersistsAcrossSessionModelRecreation() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let firstChannel = FakeComputerUseSessionChannel()
        let first = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: firstChannel)

        first.start()
        first.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: firstChannel)
        let prompt = try XCTUnwrap(sentPrompt)
        first.takeControl()
        let sentFirstPause = await waitForSentMessage(
            kind: .pause,
            channel: firstChannel)
        let firstPause = try XCTUnwrap(sentFirstPause)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(firstPause.body).revision,
            1)
        first.stop()

        let secondChannel = FakeComputerUseSessionChannel()
        let restored = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: secondChannel)
        defer {
            restored.stop()
            store.remove(hostID: hostID)
        }
        restored.start()
        _ = await waitForSentMessage(
            kind: .pause,
            channel: secondChannel)
        restored.takeControl()
        await waitUntilAsync {
            await secondChannel.sendAttemptCount(kind: .pause) == 2
        }
        let sentSecondPause = await secondChannel.sentMessages().last(where: {
            $0.kind == .pause
        })
        let secondPause = try XCTUnwrap(sentSecondPause)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(secondPause.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 2))
    }

    func test_restoredTypedPauseReplaysExactRevisionAndPreservesGuidance() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let firstChannel = FakeComputerUseSessionChannel()
        let first = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: firstChannel)
        first.start()
        first.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: firstChannel)
        let prompt = try XCTUnwrap(sentPrompt)
        first.takeControl()
        let sentPause = await waitForSentMessage(
            kind: .pause,
            channel: firstChannel)
        _ = try XCTUnwrap(sentPause)
        let guidance = "Check the Mac, then tap Let AI continue when you're ready."
        try await firstChannel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: ComputerUseStatusSignal.userIntervention(guidance),
                appliedControlRevision: 1,
                outcome: .userInterventionRequired).encodedBody())
        await waitUntil {
            first.latestTerminalOutcome == .userInterventionRequired
                && first.interventionGuidance == guidance
        }
        first.stop()

        let recoveryChannel = FakeComputerUseSessionChannel()
        let recovered = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: recoveryChannel)
        defer { recovered.stop() }
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertEqual(
            recovered.latestTerminalOutcome,
            .userInterventionRequired)
        XCTAssertEqual(recovered.interventionGuidance, guidance)
        XCTAssertEqual(recovered.statusText, guidance)
        recovered.start()
        let replayedPause = await waitForSentMessage(
            kind: .pause,
            channel: recoveryChannel)
        let replayed = try XCTUnwrap(replayedPause)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(replayed.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 1))
        let acknowledgedBefore = await recoveryChannel.acknowledgedEnvelopeCount()
        try await recoveryChannel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await recoveryChannel.acknowledgedEnvelopeCount()
                > acknowledgedBefore
        }
        XCTAssertEqual(
            recovered.latestTerminalOutcome,
            .userInterventionRequired)
        XCTAssertEqual(recovered.interventionGuidance, guidance)
        XCTAssertEqual(recovered.statusText, guidance)
        let promptAttempts = await recoveryChannel.sendAttemptCount(kind: .prompt)
        XCTAssertEqual(promptAttempts, 0)
    }

    func test_restoredCancelIsAbsorbingAndNeverRefreshesPrompt() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let firstChannel = FakeComputerUseSessionChannel()
        let first = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: firstChannel)
        first.start()
        first.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: firstChannel)
        let prompt = try XCTUnwrap(sentPrompt)
        first.stopCurrentTask()
        let sentCancel = await waitForSentMessage(
            kind: .cancel,
            channel: firstChannel)
        _ = try XCTUnwrap(sentCancel)
        first.stop()

        let recoveryChannel = FakeComputerUseSessionChannel()
        let recovered = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: recoveryChannel)
        defer { recovered.stop() }
        XCTAssertTrue(recovered.isCancellationPending)
        recovered.start()
        let replayedCancel = await waitForSentMessage(
            kind: .cancel,
            channel: recoveryChannel)
        let replayed = try XCTUnwrap(replayedCancel)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(replayed.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 1))
        recovered.resumeAI()
        recovered.takeControl()
        recovered.stopCurrentTask()
        for _ in 0..<10 { await Task.yield() }
        let promptAttempts = await recoveryChannel.sendAttemptCount(kind: .prompt)
        let cancelAttempts = await recoveryChannel.sendAttemptCount(kind: .cancel)
        let resumeAttempts = await recoveryChannel.sendAttemptCount(kind: .resume)
        let pauseAttempts = await recoveryChannel.sendAttemptCount(kind: .pause)
        XCTAssertEqual(promptAttempts, 0)
        XCTAssertEqual(cancelAttempts, 1)
        XCTAssertEqual(resumeAttempts, 0)
        XCTAssertEqual(pauseAttempts, 0)
    }

    func test_restoredResumeReplaysExactRevisionAndRefreshesPrompt() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let firstChannel = FakeComputerUseSessionChannel()
        let first = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: firstChannel)
        first.start()
        first.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: firstChannel)
        let prompt = try XCTUnwrap(sentPrompt)
        first.takeControl()
        _ = await waitForSentMessage(kind: .pause, channel: firstChannel)
        first.resumeAI()
        _ = await waitForSentMessage(kind: .resume, channel: firstChannel)
        first.stop()

        let recoveryChannel = FakeComputerUseSessionChannel()
        let recovered = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: recoveryChannel)
        defer { recovered.stop() }
        recovered.start()
        let replayedResume = await waitForSentMessage(
            kind: .resume,
            channel: recoveryChannel)
        let replayed = try XCTUnwrap(replayedResume)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(replayed.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 2))
        let refreshedPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: recoveryChannel)
        _ = try XCTUnwrap(refreshedPrompt)
    }

    func test_versionedControlAcknowledgementsRejectOlderAndGenericStatuses() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)

        model.takeControl()
        let sentPause = await waitForSentMessage(
            kind: .pause,
            channel: channel)
        _ = try XCTUnwrap(sentPause)
        var acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "working").encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.statusText, "AI paused — you're in control")

        acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .paused)

        model.resumeAI()
        let sentResume = await waitForSentMessage(
            kind: .resume,
            channel: channel)
        _ = try XCTUnwrap(sentResume)
        acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Asking AI to continue…")

        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "working",
                appliedControlRevision: 2).encodedBody())
        await waitUntil {
            model.state == .working
                && model.statusText == "Your Mac is working on it…"
        }
    }

    func test_resumeRejectsStaleInterventionButAcceptsCurrentPausedState() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)

        model.takeControl()
        _ = await waitForSentMessage(kind: .pause, channel: channel)
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 1).encodedBody())
        await waitUntil { model.state == .paused }

        model.resumeAI()
        _ = await waitForSentMessage(kind: .resume, channel: channel)
        var acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: ComputerUseStatusSignal.userIntervention(
                    "Use the Mac, then resume."),
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Asking AI to continue…")

        acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 2).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.statusText, "AI paused — you're in control")
    }

    func test_staleAssistantCannotCompleteTaskAfterNewerStopIntent() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        model.stopCurrentTask()
        let sentCancel = await waitForSentMessage(
            kind: .cancel,
            channel: channel)
        _ = try XCTUnwrap(sentCancel)

        var acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        let staleText = "Calculator was opened."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: staleText).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertTrue(model.hasActivePrompt)
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Stopping the task…")
        XCTAssertFalse(model.messages.contains { $0.text == staleText })

        acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        let stoppedText = "Stopped. You're in control of the Mac."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: stoppedText,
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        await waitUntil { !model.hasActivePrompt }
        XCTAssertTrue(model.messages.contains { $0.text == stoppedText })
        XCTAssertFalse(model.messages.contains { $0.text == staleText })
    }

    func test_cancelReadyAcknowledgementRetriesExactPromptUntilTerminalAssistant() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel,
            promptRefreshInterval: .milliseconds(80))
        defer { model.stop() }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        model.stopCurrentTask()
        let sentCancel = await waitForSentMessage(
            kind: .cancel,
            channel: channel)
        _ = try XCTUnwrap(sentCancel)
        await channel.failNextSend(kind: .prompt)

        let acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "ready",
                appliedControlRevision: 1).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .prompt) >= 3
        }

        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(
            model.statusText,
            "Stop confirmed — waiting for the final result…")
        var promptAttempts = await channel.sendAttemptCount(kind: .prompt)
        let completedPrompts = await channel.completedSendCount(kind: .prompt)
        XCTAssertEqual(
            completedPrompts,
            promptAttempts - 1,
            "The immediate recovery replay should fail once before the periodic retry succeeds")
        let bodies = await channel.promptBodies()
        let ids = await channel.promptIDs()
        XCTAssertTrue(bodies.allSatisfy { $0 == prompt.body })
        XCTAssertTrue(ids.allSatisfy { $0 == prompt.id })

        let attemptsBeforeContinuedReplay = promptAttempts
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .prompt)
                > attemptsBeforeContinuedReplay
        }
        promptAttempts = await channel.sendAttemptCount(kind: .prompt)

        let terminalText = "Stopped. You're in control of the Mac."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: terminalText,
                appliedControlRevision: 1).encodedBody())
        await waitUntil {
            !model.hasActivePrompt && model.state == .ready
        }
        try await Task.sleep(for: .milliseconds(20))
        let attemptsAfterTerminal = await channel.sendAttemptCount(kind: .prompt)
        try await Task.sleep(for: .milliseconds(180))
        let finalPromptAttempts = await channel.sendAttemptCount(kind: .prompt)

        XCTAssertEqual(
            finalPromptAttempts,
            attemptsAfterTerminal,
            "Terminal assistant output must stop exact-prompt recovery replay")
        XCTAssertGreaterThanOrEqual(attemptsAfterTerminal, promptAttempts)
        XCTAssertNil(store.load(hostID: hostID, pairingCode: "123456"))
    }

    func test_setupRequiredStatusTerminallyClearsActiveAndPersistedPrompt() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel,
            promptRefreshInterval: .milliseconds(30))
        defer { model.stop() }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        XCTAssertNotNil(store.load(hostID: hostID, pairingCode: "123456"))

        let acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "setupRequired").encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        await waitUntil { !model.hasActivePrompt }
        let promptAttemptsAfterStatus = await channel.sendAttemptCount(
            kind: .prompt)
        try await Task.sleep(for: .milliseconds(90))
        let finalPromptAttempts = await channel.sendAttemptCount(kind: .prompt)

        XCTAssertEqual(
            model.state,
            .error("Finish AI model setup on the Mac first."))
        XCTAssertEqual(model.statusText, "AI setup is required on this Mac")
        XCTAssertNil(model.retryPrompt)
        XCTAssertNil(store.load(hostID: hostID, pairingCode: "123456"))
        XCTAssertEqual(
            finalPromptAttempts,
            promptAttemptsAfterStatus,
            "A terminal setup-required status must cancel prompt refresh")
    }

    func test_rawStatusAfterTerminalAssistantCannotResurrectReadyTask() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        let terminalText = "Calculator is open."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: terminalText).encodedBody())
        await waitUntil {
            !model.hasActivePrompt && model.state == .ready
        }
        let terminalMessages = model.messages
        let acknowledgedBefore = await channel.acknowledgedEnvelopeCount()

        await channel.enqueueHostEnvelope(kind: .status, body: "working")
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.statusText, "Ready for another request")
        XCTAssertEqual(model.messages, terminalMessages)
        XCTAssertFalse(model.hasActivePrompt)
    }

    func test_takeControlCancelsTheOlderTaskResponseTimeout() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel,
            responseTimeoutDuration: .milliseconds(50))
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        _ = try XCTUnwrap(sentPrompt)

        model.takeControl()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.statusText, "AI paused — you're in control")
    }

    func test_resumeCancelAndDenialEachInstallFreshConfirmationTimeouts() async throws {
        let cases: [(kind: String, expected: String)] = [
            ("resume", "No update yet."),
            ("cancel", "The Mac hasn’t confirmed Stop yet."),
            ("denial", "The Mac hasn’t confirmed cancellation yet."),
        ]

        for row in cases {
            let hostID = "HOST-\(UUID().uuidString)"
            let store = ComputerUsePendingPromptStore()
            let channel = FakeComputerUseSessionChannel()
            let model = ComputerUseSessionModel(
                hostName: "Studio Mac",
                pairingCode: "123456",
                hostID: hostID,
                sessionID: "session-1",
                pendingStore: store,
                channel: channel,
                responseTimeoutDuration: .milliseconds(50))
            model.start()
            model.sendPrompt("Move the selected card")
            let sentPrompt = await waitForSentMessage(
                kind: .prompt,
                channel: channel)
            let prompt = try XCTUnwrap(sentPrompt)

            switch row.kind {
            case "resume":
                model.applyHostStatus("paused")
                model.resumeAI()
                let sentResume = await waitForSentMessage(
                    kind: .resume,
                    channel: channel)
                _ = try XCTUnwrap(sentResume)
            case "cancel":
                model.stopCurrentTask()
                let sentCancel = await waitForSentMessage(
                    kind: .cancel,
                    channel: channel)
                _ = try XCTUnwrap(sentCancel)
            default:
                let approval = ComputerUseApprovalRequest(
                    requestID: "deny-\(UUID().uuidString)",
                    taskID: prompt.id,
                    message: "Move the selected card?",
                    confirmLabel: "Approve once")
                try await channel.enqueueHostEnvelope(
                    kind: .approvalRequest,
                    body: approval.encodedBody())
                await waitUntil {
                    if case .approvalRequired(approval) = model.state { return true }
                    return false
                }
                model.respondToApproval(approval, approved: false)
                let sentApproval = await waitForSentMessage(
                    kind: .approvalResponse,
                    channel: channel)
                _ = try XCTUnwrap(sentApproval)
            }

            await waitUntil {
                model.statusText.hasPrefix(row.expected)
            }
            model.stop()
            store.remove(hostID: hostID)
        }
    }

    func test_sessionApprovalDenialSendsFalseAndConsumesHostCancellation() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        let taskID = try XCTUnwrap(sentPrompt?.id)
        let approval = ComputerUseApprovalRequest(
            requestID: "deny-approval",
            taskID: taskID,
            message: "Move the selected card?",
            confirmLabel: "Approve once")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: approval.encodedBody())
        await waitUntil {
            if case .approvalRequired = model.state { return true }
            return false
        }

        model.respondToApproval(approval, approved: false)

        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(
            model.statusText,
            "Cancellation sent — waiting for your Mac…")
        let sentResponse = await waitForSentMessage(
            kind: .approvalResponse,
            channel: channel)
        let responseEnvelope = try XCTUnwrap(sentResponse)
        let response = try ComputerUseApprovalResponse.decodeBody(
            responseEnvelope.body)
        XCTAssertEqual(response.requestID, approval.requestID)
        XCTAssertFalse(response.approved)

        let cancellation = "Canceled. No action was taken."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: taskID,
                text: cancellation).encodedBody())
        await waitUntil {
            !model.hasActivePrompt && model.messages.contains {
                $0.author == .assistant && $0.text == cancellation
            }
        }
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.statusText, "Ready for another request")
    }

    func test_duplicateApprovalDeliveryCannotResurrectSubmittedDecision() async throws {
        for approved in [true, false] {
            let hostID = "HOST-\(UUID().uuidString)"
            let store = ComputerUsePendingPromptStore()
            let channel = FakeComputerUseSessionChannel(
                cancellationIgnoringBlockedSendKind: .approvalResponse)
            let model = ComputerUseSessionModel(
                hostName: "Studio Mac",
                pairingCode: "123456",
                hostID: hostID,
                sessionID: "session-1",
                pendingStore: store,
                channel: channel)
            model.start()
            model.sendPrompt("Move the selected card")
            let sentPrompt = await waitForSentMessage(
                kind: .prompt,
                channel: channel)
            let prompt = try XCTUnwrap(sentPrompt)
            let approval = ComputerUseApprovalRequest(
                requestID: "duplicate-\(approved)-\(UUID().uuidString)",
                taskID: prompt.id,
                message: "Move the selected card?",
                confirmLabel: "Approve once")
            try await channel.enqueueHostEnvelope(
                kind: .approvalRequest,
                body: approval.encodedBody())
            await waitUntil {
                if case .approvalRequired(approval) = model.state { return true }
                return false
            }

            model.respondToApproval(approval, approved: approved)
            await waitUntilAsync {
                await channel.sendAttemptCount(kind: .approvalResponse) == 1
            }
            let acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
            try await channel.enqueueHostEnvelope(
                kind: .approvalRequest,
                body: approval.encodedBody())
            await waitUntilAsync {
                await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
            }

            if approved {
                XCTAssertEqual(model.state, .working)
                XCTAssertEqual(
                    model.statusText,
                    "Approved — your Mac is continuing…")
            } else {
                XCTAssertEqual(model.state, .working)
                XCTAssertEqual(
                    model.statusText,
                    "Cancellation sent — waiting for your Mac…")
            }

            await channel.releaseBlockedSend()
            let sentDecision = await waitForSentMessage(
                kind: .approvalResponse,
                channel: channel)
            _ = try XCTUnwrap(sentDecision)
            let terminal = approved
                ? "The selected card was moved."
                : "Canceled. No action was taken."
            try await channel.enqueueHostEnvelope(
                kind: .assistant,
                body: ComputerUseTaskUpdate(
                    taskID: prompt.id,
                    text: terminal).encodedBody())
            await waitUntil { !model.hasActivePrompt }
            model.stop()
            store.remove(hostID: hostID)
        }
    }

    func test_approvalDecisionSurvivesRelaunchAndRetriesExactBytes() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let firstChannel = FakeComputerUseSessionChannel(
            failingKinds: [.approvalResponse])
        let first = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: firstChannel)
        first.start()
        first.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: firstChannel)
        let prompt = try XCTUnwrap(sentPrompt)
        let request = ComputerUseApprovalRequest(
            requestID: "durable-decision",
            taskID: prompt.id,
            message: "Move the selected card?",
            confirmLabel: "Approve once")
        try await firstChannel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: request.encodedBody())
        await waitUntil {
            if case .approvalRequired(request) = first.state { return true }
            return false
        }
        first.respondToApproval(request, approved: false)
        await waitUntil {
            first.statusText == "Cancellation not confirmed yet — retrying the same choice…"
        }
        let persistedBody = try XCTUnwrap(
            store.load(hostID: hostID, pairingCode: "123456")?
                .approvalDecision?.responseBody)
        first.stop()

        let recoveryChannel = FakeComputerUseSessionChannel()
        let recovered = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: recoveryChannel)
        defer { recovered.stop() }
        XCTAssertEqual(recovered.state, .working)
        recovered.start()
        let retried = await waitForSentMessage(
            kind: .approvalResponse,
            channel: recoveryChannel)
        XCTAssertEqual(try XCTUnwrap(retried).body, persistedBody)
        guard case .working = recovered.state else {
            return XCTFail("A durable decision must not reopen its approval card")
        }

        try await recoveryChannel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "Canceled. No action was taken.").encodedBody())
        await waitUntil { !recovered.hasActivePrompt }
        XCTAssertNil(store.load(
            hostID: hostID,
            pairingCode: "123456"))
    }

    func test_safetyInterventionClearsApprovalAndRestoresDurablePause() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let firstChannel = FakeComputerUseSessionChannel()
        let first = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: firstChannel)
        first.start()
        first.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: firstChannel)
        let prompt = try XCTUnwrap(sentPrompt)
        let approval = ComputerUseApprovalRequest(
            requestID: "interrupted-approval",
            taskID: prompt.id,
            message: "Move the selected card?",
            confirmLabel: "Approve once",
            appliedControlRevision: 0)
        try await firstChannel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: approval.encodedBody())
        await waitUntil {
            if case .approvalRequired(approval) = first.state { return true }
            return false
        }

        first.respondToApproval(approval, approved: true)
        let sentApproval = await waitForSentMessage(
            kind: .approvalResponse,
            channel: firstChannel)
        _ = try XCTUnwrap(sentApproval)
        XCTAssertNotNil(store.load(
            hostID: hostID,
            pairingCode: "123456")?.approvalDecision)

        let guidance = "Use the Mac, then resume."
        try await firstChannel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: ComputerUseStatusSignal.userIntervention(guidance),
                appliedControlRevision: 0).encodedBody())
        let sentFreshPause = await waitForSentMessage(
            kind: .pause,
            channel: firstChannel)
        let freshPause = try XCTUnwrap(sentFreshPause)
        XCTAssertEqual(first.state, .paused)
        XCTAssertEqual(first.statusText, guidance)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(freshPause.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 1))
        let persistedPause = try XCTUnwrap(store.load(
            hostID: hostID,
            pairingCode: "123456"))
        XCTAssertNil(persistedPause.approvalDecision)
        XCTAssertEqual(persistedPause.lastControlKind, .pause)
        XCTAssertEqual(persistedPause.controlRevision, 1)
        first.stop()

        let recoveryChannel = FakeComputerUseSessionChannel()
        let recovered = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: recoveryChannel)
        defer { recovered.stop() }
        XCTAssertEqual(recovered.state, .paused)
        recovered.start()
        let sentReplayedPause = await waitForSentMessage(
            kind: .pause,
            channel: recoveryChannel)
        let replayedPause = try XCTUnwrap(sentReplayedPause)
        XCTAssertEqual(
            try ComputerUseControlRequest.decodeBody(replayedPause.body),
            ComputerUseControlRequest(taskID: prompt.id, revision: 1))
        let approvalAttempts = await recoveryChannel.sendAttemptCount(
            kind: .approvalResponse)
        let promptAttempts = await recoveryChannel.sendAttemptCount(kind: .prompt)
        XCTAssertEqual(approvalAttempts, 0)
        XCTAssertEqual(promptAttempts, 0)
    }

    func test_approvalPhaseIgnoresSameRevisionStatusAndRetriesLockedDecision() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        model.takeControl()
        _ = await waitForSentMessage(kind: .pause, channel: channel)
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "paused",
                appliedControlRevision: 1).encodedBody())
        await waitUntil { model.state == .paused }
        model.resumeAI()
        _ = await waitForSentMessage(kind: .resume, channel: channel)

        let request = ComputerUseApprovalRequest(
            requestID: "revision-two-approval",
            taskID: prompt.id,
            message: "Move the selected card?",
            confirmLabel: "Approve once",
            appliedControlRevision: 2)
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: request.encodedBody())
        await waitUntil {
            if case .approvalRequired(request) = model.state { return true }
            return false
        }
        var acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "working",
                appliedControlRevision: 2).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .approvalRequired(request))

        model.respondToApproval(request, approved: false)
        _ = await waitForSentMessage(kind: .approvalResponse, channel: channel)
        acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .status,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: "working",
                appliedControlRevision: 2).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(
            model.statusText,
            "Cancellation sent — waiting for your Mac…")

        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: request.encodedBody())
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .approvalResponse) == 2
        }
        XCTAssertEqual(model.state, .working)
    }

    func test_staleApprovalRequestCannotOverridePendingCancel() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        model.stopCurrentTask()
        _ = await waitForSentMessage(kind: .cancel, channel: channel)
        let acknowledgedBefore = await channel.acknowledgedEnvelopeCount()
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: ComputerUseApprovalRequest(
                requestID: "stale-before-stop",
                taskID: prompt.id,
                message: "Move the selected card?",
                confirmLabel: "Approve once",
                appliedControlRevision: 0).encodedBody())
        await waitUntilAsync {
            await channel.acknowledgedEnvelopeCount() > acknowledgedBefore
        }
        XCTAssertTrue(model.isCancellationPending)
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Stopping the task…")
    }

    func test_controlIsNotSentWhenRevisionCannotBePersisted() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore(
            failAfterSuccessfulSaves: 1)
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        _ = try XCTUnwrap(sentPrompt)
        model.takeControl()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.state, .paused)
        XCTAssertTrue(model.statusText.contains("Couldn’t safely save Pause"))
        let pauseAttempts = await channel.sendAttemptCount(kind: .pause)
        XCTAssertEqual(pauseAttempts, 0)
        XCTAssertNil(store.load(
            hostID: hostID,
            pairingCode: "123456")?.controlRevision)
    }

    func test_approvalIsNotSentWhenDecisionCannotBePersisted() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore(
            failAfterSuccessfulSaves: 1)
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        model.start()
        model.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(kind: .prompt, channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        let request = ComputerUseApprovalRequest(
            requestID: "unsaved-decision",
            taskID: prompt.id,
            message: "Move the selected card?",
            confirmLabel: "Approve once")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: request.encodedBody())
        await waitUntil {
            if case .approvalRequired(request) = model.state { return true }
            return false
        }
        model.respondToApproval(request, approved: true)
        XCTAssertEqual(model.state, .approvalRequired(request))
        XCTAssertEqual(
            model.statusText,
            "Couldn’t safely save your choice. No response was sent.")
        let attempts = await channel.sendAttemptCount(kind: .approvalResponse)
        XCTAssertEqual(attempts, 0)
    }

    func test_sessionStopDuringCancellationIgnoringPromptSendPreventsPostStopMutationAndTimeout() async {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            cancellationIgnoringBlockedSendKind: .prompt)
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }

        model.start()
        model.sendPrompt("Open Calculator")
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .prompt) == 1
        }
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Sending securely through iCloud…")

        model.stop()
        await channel.releaseBlockedSend()
        await waitUntilAsync {
            await channel.completedSendCount(kind: .prompt) == 1
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(
            model.statusText,
            "Sending securely through iCloud…",
            "A send that returns after stop must not publish a success state")
        XCTAssertNil(model.retryPrompt)
        XCTAssertEqual(
            privateOptionalIsNil(named: "responseTimeoutTask", in: model),
            true,
            "A send that returns after stop must not schedule response work")
    }

    func test_sessionStopRejectsNewPromptAndControlSends() async {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer { store.remove(hostID: hostID) }

        model.stop()
        model.sendPrompt("Open Calculator")
        model.takeControl()
        model.resumeAI()
        model.stopCurrentTask()
        for _ in 0..<10 { await Task.yield() }

        let sentMessages = await channel.sentMessages()
        XCTAssertTrue(sentMessages.isEmpty)
        XCTAssertFalse(model.hasActivePrompt)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.statusText, "Ready for a request")
    }

    func test_restoredSessionBlocksAllTrafficUntilStartThenReplaysExactRecovery() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = InMemoryComputerUsePendingPromptStore()
        let messageID = "restored-message"
        let prompt = "Move the selected card"
        let wireBody = try ComputerUsePromptRequest(
            prompt: prompt,
            conversation: [
                ComputerUseConversationTurn(
                    role: .user,
                    text: "Open the project board"),
            ]).encodedBody()
        let approval = ComputerUseApprovalRequest(
            requestID: "restored-approval",
            taskID: messageID,
            message: "Move the selected card?",
            confirmLabel: "Approve once",
            appliedControlRevision: 0)
        let responseBody = try ComputerUseApprovalResponse(
            requestID: approval.requestID,
            approved: true,
            taskID: messageID,
            appliedControlRevision: 0).encodedBody()
        let pending = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: "123456",
            sessionID: "session-1",
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: Date(),
            approvalDecision: ComputerUsePendingApprovalDecision(
                request: approval,
                approved: true,
                responseBody: responseBody))
        XCTAssertTrue(store.save(pending))
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: channel)
        defer { model.stop() }
        let stateBeforeAttempts = model.state
        let statusBeforeAttempts = model.statusText

        XCTAssertFalse(model.isConnected)
        model.sendPrompt("Start a different task")
        model.retryLastPrompt()
        model.takeControl()
        model.resumeAI()
        model.stopCurrentTask()
        model.respondToApproval(approval, approved: false)
        for _ in 0..<10 { await Task.yield() }

        for kind: ComputerUseEnvelope.Kind in [
            .prompt,
            .pause,
            .resume,
            .cancel,
            .approvalResponse,
        ] {
            let attempts = await channel.sendAttemptCount(kind: kind)
            XCTAssertEqual(
                attempts,
                0,
                "\(kind.rawValue) must stay blocked before authenticated start")
        }
        XCTAssertEqual(model.state, stateBeforeAttempts)
        XCTAssertEqual(model.statusText, statusBeforeAttempts)
        XCTAssertEqual(model.retryPrompt, prompt)
        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456"),
            pending)

        model.start()

        XCTAssertTrue(model.isConnected)
        await waitUntilAsync {
            let promptAttempts = await channel.sendAttemptCount(kind: .prompt)
            let approvalAttempts = await channel.sendAttemptCount(
                kind: .approvalResponse)
            return promptAttempts == 1 && approvalAttempts == 1
        }
        let sent = await channel.sentMessages()
        let recoveredPrompt = try XCTUnwrap(sent.last(where: {
            $0.kind == .prompt
        }))
        let recoveredApproval = try XCTUnwrap(sent.last(where: {
            $0.kind == .approvalResponse
        }))
        XCTAssertEqual(recoveredPrompt.id, messageID)
        XCTAssertEqual(recoveredPrompt.body, wireBody)
        XCTAssertEqual(recoveredApproval.body, responseBody)
    }

    func test_sessionStopDuringCancellationIgnoringPollDoesNotConsumeReturnedEnvelopes() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            blocksPollUntilReleased: true)
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }

        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        let assistantText = "Calculator is open."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: assistantText).encodedBody())
        await waitUntilAsync {
            await channel.pollAttemptCount() == 1
        }
        let messagesBeforeStop = model.messages
        let statusBeforeStop = model.statusText

        model.stop()
        await channel.releaseBlockedPoll()
        await waitUntilAsync {
            await channel.completedPollCount() == 1
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.messages, messagesBeforeStop)
        XCTAssertFalse(model.messages.contains { $0.text == assistantText })
        XCTAssertTrue(model.hasActivePrompt)
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, statusBeforeStop)
        let acknowledgedCount = await channel.acknowledgedEnvelopeCount()
        XCTAssertEqual(acknowledgedCount, 0)
    }

    func test_sessionPauseSendFailureKeepsManualControlAndExplainsFallback() async {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(failingKinds: [.pause])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        XCTAssertNotNil(sentPrompt)

        model.takeControl()

        await waitUntil {
            model.statusText == "Couldn’t reach AI through iCloud. Touch the live screen to take control immediately."
        }
        XCTAssertEqual(model.state, .paused)
        let pauseAttempts = await channel.sendAttemptCount(kind: .pause)
        XCTAssertEqual(pauseAttempts, 1)
    }

    func test_sessionResumeSendFailureReturnsToPausedWithRetryGuidance() async {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(failingKinds: [.resume])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        XCTAssertNotNil(sentPrompt)
        model.applyHostStatus("paused")

        model.resumeAI()

        await waitUntil {
            model.statusText == "Couldn’t resume AI yet. Check iCloud and try again."
        }
        XCTAssertEqual(model.state, .paused)
        let resumeAttempts = await channel.sendAttemptCount(kind: .resume)
        XCTAssertEqual(resumeAttempts, 1)
    }

    func test_sessionCancelSendFailureKeepsAbsorbingStopPending() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(failingKinds: [.cancel])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        _ = try XCTUnwrap(sentPrompt)

        model.stopCurrentTask()

        await waitUntil {
            model.statusText == "Stop is still pending. The same safe request will be retried."
        }
        XCTAssertEqual(model.state, .working)
        XCTAssertTrue(model.isCancellationPending)
        model.resumeAI()
        model.takeControl()
        XCTAssertTrue(model.isCancellationPending)
        let cancelAttempts = await channel.sendAttemptCount(kind: .cancel)
        XCTAssertEqual(cancelAttempts, 1)
    }

    func test_sessionApprovalSendFailureKeepsDurableChoiceLocked() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            failingKinds: [.approvalResponse])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Move the selected card")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)
        let request = ComputerUseApprovalRequest(
            requestID: "approval-that-must-be-restored",
            taskID: prompt.id,
            message: "Move the selected card?",
            details: [.init(label: "Exact action", value: "Move the selected card")],
            confirmLabel: "Approve once")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: request.encodedBody())
        await waitUntil {
            if case .approvalRequired(request) = model.state { return true }
            return false
        }

        model.respondToApproval(request, approved: true)

        await waitUntil {
            model.statusText == "Approval not confirmed yet — retrying the same choice…"
        }
        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456")?
                .approvalDecision?.request.requestID,
            request.requestID)
        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456")?
                .approvalDecision?.approved,
            true)
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: request.encodedBody())
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .approvalResponse) == 2
        }
        XCTAssertEqual(model.state, .working)
        let approvalResponseAttempts = await channel.sendAttemptCount(
            kind: .approvalResponse)
        XCTAssertEqual(approvalResponseAttempts, 2)
    }

    func test_sessionDelayedPauseFailureCannotOverwriteNewerResumeIntent() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            failingKinds: [.pause],
            cancellationIgnoringBlockedSendKind: .pause)
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        _ = try XCTUnwrap(sentPrompt)
        model.applyHostStatus("working")

        model.takeControl()
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .pause) == 1
        }
        model.resumeAI()
        let sentResume = await waitForSentMessage(
            kind: .resume,
            channel: channel)
        _ = try XCTUnwrap(sentResume)

        XCTAssertEqual(model.state, .working)
        XCTAssertEqual(model.statusText, "Asking AI to continue…")

        await channel.releaseBlockedSend()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(
            model.state,
            .working,
            "An older pause failure must not reinstate manual-control UI after Resume")
        XCTAssertEqual(
            model.statusText,
            "Asking AI to continue…",
            "An older pause failure must not replace the newer Resume status")
    }

    func test_sessionDelayedCancelFailureCannotOverwriteTerminalHostResult() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            failingKinds: [.cancel],
            cancellationIgnoringBlockedSendKind: .cancel)
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Open Calculator")
        let sentPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let prompt = try XCTUnwrap(sentPrompt)

        model.stopCurrentTask()
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .cancel) == 1
        }

        let terminalText = "Stopped. You're in control of the Mac."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: prompt.id,
                text: terminalText,
                appliedControlRevision: 1).encodedBody())
        await waitUntil {
            !model.hasActivePrompt && model.messages.contains {
                $0.author == .assistant && $0.text == terminalText
            }
        }
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.statusText, "Ready for another request")

        await channel.releaseBlockedSend()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(
            model.state,
            .ready,
            "A delayed cancel transport failure must not resurrect a completed task")
        XCTAssertEqual(model.statusText, "Ready for another request")
        XCTAssertFalse(model.hasActivePrompt)
    }

    func test_sessionDelayedApprovalFailureCannotReplaceNewTaskApproval() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            failingKinds: [.approvalResponse],
            cancellationIgnoringBlockedSendKind: .approvalResponse)
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Move the first card")
        let sentFirstPrompt = await waitForSentMessage(
            kind: .prompt,
            channel: channel)
        let firstPrompt = try XCTUnwrap(sentFirstPrompt)
        let firstApproval = ComputerUseApprovalRequest(
            requestID: "first-approval",
            taskID: firstPrompt.id,
            message: "Move the first card?",
            confirmLabel: "Approve once")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: firstApproval.encodedBody())
        await waitUntil {
            if case .approvalRequired(firstApproval) = model.state { return true }
            return false
        }

        model.respondToApproval(firstApproval, approved: true)
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .approvalResponse) == 1
        }

        let terminalText = "The first card was moved."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: firstPrompt.id,
                text: terminalText).encodedBody())
        await waitUntil {
            !model.hasActivePrompt && model.messages.contains {
                $0.author == .assistant && $0.text == terminalText
            }
        }

        model.sendPrompt("Move the second card")
        await waitUntilAsync {
            await channel.sendAttemptCount(kind: .prompt) == 2
        }
        let promptIDs = await channel.promptIDs()
        let secondPromptID = try XCTUnwrap(promptIDs.last)
        let secondApproval = ComputerUseApprovalRequest(
            requestID: "second-approval",
            taskID: secondPromptID,
            message: "Move the second card?",
            confirmLabel: "Approve once")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: secondApproval.encodedBody())
        await waitUntil {
            if case .approvalRequired(secondApproval) = model.state { return true }
            return false
        }

        await channel.releaseBlockedSend()
        for _ in 0..<10 { await Task.yield() }

        guard case .approvalRequired(let current) = model.state else {
            return XCTFail("The newer task's approval disappeared")
        }
        XCTAssertEqual(
            current,
            secondApproval,
            "A delayed failure from the completed task must not restore its stale approval")
        XCTAssertTrue(model.hasActivePrompt)
    }

    func test_approvalCardHeightKeepsActionsReachableAcrossPhoneAndPadLayouts() {
        XCTAssertEqual(
            ComputerUseApprovalCardLayout.maximumHeight(
                for: CGSize(width: 390, height: 844)),
            460,
            accuracy: 0.01)
        XCTAssertEqual(
            ComputerUseApprovalCardLayout.maximumHeight(
                for: CGSize(width: 844, height: 390)),
            280.8,
            accuracy: 0.01)
        XCTAssertEqual(
            ComputerUseApprovalCardLayout.maximumHeight(
                for: CGSize(width: 1_024, height: 1_366)),
            460,
            accuracy: 0.01)
    }

    func test_approvalPayloadPreservesEightKilobyteDetailExactly() throws {
        let body = String(repeating: "x", count: 8_000)
        let request = ComputerUseApprovalRequest(
            taskID: "task-8kb",
            message: "Review the exact email body.",
            details: [.init(label: "Body", value: body)])

        let decoded = try ComputerUseApprovalRequest.decodeBody(request.encodedBody())

        XCTAssertEqual(decoded.details?.first?.value, body)
    }

    func test_mailRequestShieldsLiveScreenFromSubmissionThroughApprovalAndCompletionUntilExplicitReveal() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Send the exact neighborhood update email.")
        XCTAssertTrue(
            model.isLiveScreenPrivacyShielded,
            "Mail pixels must be covered before the request leaves the phone")
        var promptIDs: [String] = []
        for _ in 0..<100 where promptIDs.isEmpty {
            promptIDs = await channel.promptIDs()
            if promptIDs.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let taskID = try XCTUnwrap(promptIDs.last)
        let approval = ComputerUseApprovalRequest(
            requestID: "mail-approval",
            taskID: taskID,
            message: "Send this email through Mail on your Mac?",
            details: [
                .init(label: "From", value: "Your default account in Mail"),
                .init(label: "To", value: "organizer@example.invalid"),
                .init(label: "Subject", value: "Food drive"),
                .init(label: "Message", value: "Thanks for helping."),
            ],
            confirmLabel: "Send email")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: approval.encodedBody())
        await waitUntil {
            if case .approvalRequired = model.state { return true }
            return false
        }
        XCTAssertTrue(
            model.isLiveScreenPrivacyShielded,
            "The exact approval must appear without revealing the Mac behind it")

        model.respondToApproval(approval, approved: true)

        XCTAssertTrue(model.isLiveScreenPrivacyShielded)
        let completion = "Mail accepted the approved email for sending."
        try await channel.enqueueHostEnvelope(
            kind: .assistant,
            body: ComputerUseTaskUpdate(
                taskID: taskID,
                text: completion).encodedBody())
        await waitUntil {
            model.messages.contains {
                $0.author == .assistant && $0.text == completion
            }
        }
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(
            model.isLiveScreenPrivacyShielded,
            "A terminal Mail response must not reveal unrelated desktop pixels")

        model.revealLiveScreen()

        XCTAssertFalse(model.isLiveScreenPrivacyShielded)
    }

    func test_mailClarificationAnswerReenablesShieldFromScopedConversation() async {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let question = "Who should receive the email, and what should it say?"
        let channel = FakeComputerUseSessionChannel(
            assistantReplies: [question])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()

        model.sendPrompt("Send an email")
        XCTAssertTrue(model.isLiveScreenPrivacyShielded)
        await waitUntil {
            model.messages.contains {
                $0.author == .assistant && $0.text == question
            }
        }

        model.revealLiveScreen()
        XCTAssertFalse(model.isLiveScreenPrivacyShielded)

        model.sendPrompt("To alex@example.invalid. Say the meeting is at 3.")

        XCTAssertTrue(
            model.isLiveScreenPrivacyShielded,
            "A scoped Mail clarification answer must be covered before resend")
    }

    func test_restoredPendingMailRequestStartsPrivacyShielded() throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        defer { store.remove(hostID: hostID) }
        let prompt = "Draft an email to alex@example.invalid saying Hello."
        let body = try ComputerUsePromptRequest(prompt: prompt).encodedBody()
        store.save(ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: "123456",
            sessionID: "session-1",
            messageID: "message-1",
            prompt: prompt,
            wireBody: body,
            createdAt: Date()))

        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: FakeComputerUseSessionChannel())
        defer { model.stop() }

        XCTAssertTrue(model.isLiveScreenPrivacyShielded)
        XCTAssertTrue(model.hasActivePrompt)
    }

    func test_visualOSAtlasAndOrdinaryMCPRequestsRemainUnshielded() {
        let prompts = [
            "Use Safari to get a read-only DoorDash delivery quote and stop before checkout.",
            "Open Calculator and work out a 20 percent restaurant tip.",
            "Open the Mail app and show my inbox window.",
        ]

        for prompt in prompts {
            let hostID = "HOST-\(UUID().uuidString)"
            let store = ComputerUsePendingPromptStore()
            let model = ComputerUseSessionModel(
                hostName: "Studio Mac",
                pairingCode: "123456",
                hostID: hostID,
                sessionID: "session-1",
                pendingStore: store,
                channel: FakeComputerUseSessionChannel())
            model.start()
            model.sendPrompt(prompt)

            XCTAssertFalse(
                model.isLiveScreenPrivacyShielded,
                "Visual work must stay visible for: \(prompt)")

            model.stop()
            store.remove(hostID: hostID)
        }
    }

    func test_nonMailApprovalDoesNotRetainLiveScreenPrivacyShield() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()
        model.sendPrompt("Move the selected card.")
        XCTAssertFalse(model.isLiveScreenPrivacyShielded)
        var promptIDs: [String] = []
        for _ in 0..<100 where promptIDs.isEmpty {
            promptIDs = await channel.promptIDs()
            if promptIDs.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let taskID = try XCTUnwrap(promptIDs.last)
        let approval = ComputerUseApprovalRequest(
            requestID: "drag-approval",
            taskID: taskID,
            message: "Drag this item?",
            details: [.init(label: "Exact action", value: "Move the selected card")],
            confirmLabel: "Approve once")
        try await channel.enqueueHostEnvelope(
            kind: .approvalRequest,
            body: approval.encodedBody())
        await waitUntil {
            if case .approvalRequired = model.state { return true }
            return false
        }
        XCTAssertFalse(model.isLiveScreenPrivacyShielded)

        model.respondToApproval(approval, approved: true)

        XCTAssertFalse(model.isLiveScreenPrivacyShielded)
    }

    func test_promptPayloadCarriesBoundedRecentConversationAndLegacyFallback() throws {
        let turns = (0..<16).map { index in
            ComputerUseConversationTurn(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "turn-\(index)")
        }
        let request = ComputerUsePromptRequest(
            prompt: "To alex@example.com. Say the meeting is at 3.",
            conversation: turns)

        let decoded = try ComputerUsePromptRequest.decodeBody(request.encodedBody())

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.conversation.count,
            ComputerUsePromptRequest.maximumConversationTurns)
        XCTAssertEqual(decoded.conversation.first?.text, "turn-4")
        XCTAssertTrue(decoded.modelPrompt.contains("Assistant: turn-15"))
        XCTAssertTrue(decoded.modelPrompt.contains("Current user request:"))

        let legacy = ComputerUsePromptRequest.decodeCompatibleBody("Open Notes")
        XCTAssertEqual(legacy.prompt, "Open Notes")
        XCTAssertTrue(legacy.conversation.isEmpty)
    }

    func test_rowAction_mapsSetupProgressReadyAndRetryStates() {
        let host = makeHost(capability: .setupRequired)
        let progress = ComputerUseSetupProgress(
            requestID: "request-1",
            phase: .downloadingModel,
            fractionCompleted: 0.42,
            detail: "Downloading AI…")

        XCTAssertEqual(
            ComputerUseRowAction.resolve(host: host, state: .setupRequired),
            .setup)
        XCTAssertEqual(
            ComputerUseRowAction.resolve(host: host, state: .installing(progress)),
            .progress(progress))
        XCTAssertEqual(
            ComputerUseRowAction.resolve(host: host, state: .ready),
            .useAI)
        XCTAssertEqual(
            ComputerUseRowAction.resolve(host: host, state: .failed("Try again")),
            .retry("Try again"))
    }

    func test_rowAction_explainsAIRequirementsWithoutCloudKitHostIdentity() {
        let host = makeHost(senderID: nil, capability: .setupRequired)

        guard case .unavailable(let message) = ComputerUseRowAction.resolve(
            host: host,
            state: .setupRequired) else {
            return XCTFail("Expected an explanatory unavailable action")
        }
        XCTAssertTrue(message.contains("same Apple Account"))
    }

    func test_coordinator_downgradesCachedReadyWhenHostRequiresSetupAgain() {
        let channel = FakeComputerUseSetupChannel(responseBatches: [])
        let coordinator = ComputerUseSetupCoordinator { _, _ in channel }
        let ready = makeHost(capability: .ready)
        coordinator.reconcile(hosts: [ready])
        XCTAssertEqual(coordinator.state(for: ready), .ready)

        let reset = makeHost(capability: .setupRequired)
        coordinator.reconcile(hosts: [reset])
        XCTAssertEqual(coordinator.state(for: reset), .setupRequired)
    }

    func test_coordinator_rebindsSetupWhenHostPairingCodeChanges() async {
        let channel = FakeComputerUseSetupChannel(responseBatches: [])
        let coordinator = ComputerUseSetupCoordinator { _, _ in channel }
        let first = makeHost(code: "123456", capability: .setupRequired)
        coordinator.startSetup(for: first)
        await Task.yield()

        let restarted = makeHost(code: "654321", capability: .setupRequired)
        coordinator.reconcile(hosts: [restarted])
        XCTAssertEqual(coordinator.state(for: restarted), .setupRequired)
    }

    func test_coordinator_sendsOneRequestForDuplicateTapsAndBecomesReady() async throws {
        let progress = ComputerUseSetupProgress(
            requestID: "host-installation",
            phase: .ready,
            fractionCompleted: 1,
            detail: "AI Computer Use is ready")
        let channel = FakeComputerUseSetupChannel(
            responseBatches: [[try progressEnvelope(progress)]])
        let coordinator = ComputerUseSetupCoordinator { _, _ in channel }
        let host = makeHost(capability: .setupRequired)

        coordinator.startSetup(for: host)
        coordinator.startSetup(for: host)

        await waitUntil {
            coordinator.state(for: host) == .ready
        }

        let sent = await channel.sentMessages()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.kind, .setupRequest)
        let request = try XCTUnwrap(sent.first).body
        let decoded = try ComputerUseSetupRequest.decodeBody(request)
        XCTAssertEqual(sent.first?.id, decoded.requestID)
        XCTAssertEqual(
            decoded.idempotencyKey,
            ComputerUseSetupRequest.currentIdempotencyKey)
    }

    func test_coordinatorResumesMonitoringWhenRelaunchedDuringHostInstall() async throws {
        let ready = ComputerUseSetupProgress(
            requestID: "host-installation",
            phase: .ready,
            fractionCompleted: 1,
            detail: "AI Computer Use is ready")
        let channel = FakeComputerUseSetupChannel(
            responseBatches: [[try progressEnvelope(ready)]])
        let coordinator = ComputerUseSetupCoordinator { _, _ in channel }
        let host = makeHost(capability: ComputerUseCapability(
            state: .installing,
            detail: "Downloading AI on this Mac"))

        // A new app process has no in-memory setup state. Reconciliation with
        // the host advertisement must recreate the idempotent monitor without
        // asking the user to tap Set up AI again.
        coordinator.reconcile(hosts: [host])

        await waitUntil { coordinator.state(for: host) == .ready }
        let sent = await channel.sentMessages()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.kind, .setupRequest)
    }

    func test_coordinatorIgnoresMalformedProgressAndContinuesToReady() async throws {
        let malformed = ComputerUseEnvelope(
            senderID: "HOST-ID",
            targetID: "IOS-ID",
            pairingCode: "123456",
            sessionID: "setup-session",
            kind: .setupProgress,
            body: "not-json")
        let ready = ComputerUseSetupProgress(
            requestID: "host-installation",
            phase: .ready,
            fractionCompleted: 1,
            detail: "AI Computer Use is ready")
        let channel = FakeComputerUseSetupChannel(responseBatches: [
            [malformed],
            [try progressEnvelope(ready)],
        ])
        let coordinator = ComputerUseSetupCoordinator { _, _ in channel }
        let host = makeHost(capability: .setupRequired)

        coordinator.startSetup(for: host)

        await waitUntil { coordinator.state(for: host) == .ready }
    }

    func test_progressPolicyNeverRegressesOrReturnsToIndeterminate() {
        let current = ComputerUseSetupProgress(
            requestID: "request",
            phase: .downloadingModel,
            fractionCompleted: 0.64,
            detail: "2 GB of 3 GB")
        let delayed = ComputerUseSetupProgress(
            requestID: "request",
            phase: .downloadingModel,
            fractionCompleted: 0.22,
            detail: "700 MB of 3 GB")
        XCTAssertEqual(
            ComputerUseSetupProgressPolicy.merge(
                current: current,
                incoming: delayed),
            current)

        let newerIndeterminate = ComputerUseSetupProgress(
            requestID: "request",
            phase: .verifying,
            detail: "Checking the downloaded files")
        let merged = ComputerUseSetupProgressPolicy.merge(
            current: current,
            incoming: newerIndeterminate)
        XCTAssertEqual(merged.phase, .verifying)
        XCTAssertEqual(merged.fractionCompleted, 0.64)
        XCTAssertEqual(merged.detail, "Checking the downloaded files")
    }

    func test_coordinator_surfacesFailureAndRetryKeepsIdempotencyKey() async throws {
        let failed = ComputerUseSetupProgress(
            requestID: "host-installation-1",
            phase: .failed,
            fractionCompleted: 0.3,
            detail: "Setup stopped",
            errorMessage: "The download could not be verified.")
        let ready = ComputerUseSetupProgress(
            requestID: "host-installation-2",
            phase: .ready,
            fractionCompleted: 1,
            detail: "AI Computer Use is ready")
        let channel = FakeComputerUseSetupChannel(responseBatches: [
            [try progressEnvelope(failed)],
            [try progressEnvelope(ready)],
        ])
        let coordinator = ComputerUseSetupCoordinator { _, _ in channel }
        let host = makeHost(capability: .setupRequired)

        coordinator.startSetup(for: host)
        await waitUntil {
            coordinator.state(for: host) == .failed("The download could not be verified.")
        }

        coordinator.startSetup(for: host)
        await waitUntil {
            coordinator.state(for: host) == .ready
        }

        let sent = await channel.sentMessages()
        XCTAssertEqual(sent.count, 2)
        let requests = try sent.map { try ComputerUseSetupRequest.decodeBody($0.body) }
        XCTAssertNotEqual(requests[0].requestID, requests[1].requestID)
        XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
    }

    func test_pendingPromptStoreRoundTripsEncryptedRecoveryRecord() {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        defer { store.remove(hostID: hostID) }
        let pending = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: "123456",
            sessionID: "session-1",
            messageID: "message-1",
            prompt: "Open Notes",
            wireBody: #"{"conversation":[],"prompt":"Open Notes","version":1}"#,
            createdAt: Date(),
            controlRevision: 3,
            lastControlKind: .pause,
            interventionGuidance:
                "Finish signing in, then tap Let AI continue.")

        store.save(pending)

        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456"),
            pending)
        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456")?.exactWireBody,
            pending.wireBody)
        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456")?
                .interventionGuidance,
            "Finish signing in, then tap Let AI continue.")
    }

    func test_legacyPendingPromptRecordDecodesWithoutRevisionOrDecisionFields() throws {
        let data = Data(#"""
        {
          "hostID":"HOST-LEGACY",
          "pairingCode":"123456",
          "sessionID":"session-legacy",
          "messageID":"message-legacy",
          "prompt":"Open Notes",
          "createdAt":0
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(
            ComputerUsePendingPrompt.self,
            from: data)

        XCTAssertEqual(decoded.exactWireBody, "Open Notes")
        XCTAssertNil(decoded.controlRevision)
        XCTAssertNil(decoded.lastControlKind)
        XCTAssertNil(decoded.approvalDecision)
        XCTAssertNil(decoded.interventionGuidance)
    }

    func test_sessionSendsClarificationAnswerWithRecentChatContext() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            assistantReplies: [
                "Who should receive the email, and what should it say?",
                "I’m ready to continue.",
            ])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()

        model.sendPrompt("Send an email")
        await waitUntil {
            model.messages.contains {
                $0.author == .assistant && $0.text.contains("Who should receive")
            }
        }
        model.sendPrompt("To alex@example.com. Say the meeting is at 3.")
        await waitUntil(timeoutIterations: 350) {
            model.messages.filter { $0.author == .assistant }.count == 2
        }

        let bodies = await channel.promptBodies()
        XCTAssertEqual(bodies.count, 2)
        let followUp = try ComputerUsePromptRequest.decodeBody(bodies[1])
        XCTAssertEqual(
            followUp.prompt,
            "To alex@example.com. Say the meeting is at 3.")
        XCTAssertEqual(followUp.conversation, [
            ComputerUseConversationTurn(role: .user, text: "Send an email"),
            ComputerUseConversationTurn(
                role: .assistant,
                text: "Who should receive the email, and what should it say?"),
        ])
    }

    func test_sessionDoesNotSendCompletedFoodOrderAsNewTaskContext() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(
            assistantReplies: [
                "Done. Your previous order was placed.",
                "Before I start the order, what would you like?",
            ])
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }
        model.start()

        model.sendPrompt(
            "Order one fried rice from Panda Express for delivery to my default address using Uber Eats.")
        await waitUntil {
            model.messages.contains {
                $0.author == .assistant && $0.text.contains("previous order was placed")
            }
        }

        model.sendPrompt("Order food")
        await waitUntil(timeoutIterations: 350) {
            model.messages.filter { $0.author == .assistant }.count == 2
        }

        let bodies = await channel.promptBodies()
        XCTAssertEqual(bodies.count, 2)
        let newTask = try ComputerUsePromptRequest.decodeBody(bodies[1])
        XCTAssertEqual(newTask.prompt, "Order food")
        XCTAssertTrue(
            newTask.conversation.isEmpty,
            "A completed order must not become context for a new visual-planner task")
    }

    func test_sessionRetryReusesExactStructuredWireBody() async {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        let channel = FakeComputerUseSessionChannel(failuresBeforeSuccess: 1)
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            sessionID: "session-1",
            pendingStore: store,
            channel: channel)
        defer {
            model.stop()
            store.remove(hostID: hostID)
        }

        model.start()
        model.sendPrompt("Open Notes")
        await waitUntil { model.retryPrompt != nil }
        model.retryLastPrompt()
        var bodies: [String] = []
        for _ in 0..<100 where bodies.count < 2 {
            bodies = await channel.promptBodies()
            if bodies.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        }

        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertNoThrow(try ComputerUsePromptRequest.decodeBody(bodies[0]))
    }

    func test_sessionRestoreResendsPersistedWireBodyExactly() async throws {
        let hostID = "HOST-\(UUID().uuidString)"
        let store = ComputerUsePendingPromptStore()
        defer { store.remove(hostID: hostID) }
        let body = try ComputerUsePromptRequest(
            prompt: "Panda Express, one order, deliver to my default address.",
            conversation: [
                ComputerUseConversationTurn(
                    role: .user,
                    text: "Order fried rice using Uber Eats"),
                ComputerUseConversationTurn(
                    role: .assistant,
                    text: "Which restaurant, how many, and delivery or pickup?"),
            ]).encodedBody()
        store.save(ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: "123456",
            sessionID: "session-1",
            messageID: "message-1",
            prompt: "Panda Express, one order, deliver to my default address.",
            wireBody: body,
            createdAt: Date()))
        let channel = FakeComputerUseSessionChannel()
        let model = ComputerUseSessionModel(
            hostName: "Studio Mac",
            pairingCode: "123456",
            hostID: hostID,
            pendingStore: store,
            channel: channel)
        defer { model.stop() }

        model.start()
        await waitUntil { model.messages.count == 3 }
        await waitUntil {
            // Polling is deliberately not required for recovery resend.
            model.hasActivePrompt
        }

        var bodies: [String] = []
        for _ in 0..<100 where bodies.isEmpty {
            bodies = await channel.promptBodies()
            if bodies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(bodies.first, body)
        XCTAssertEqual(model.messages.first?.text, "Order fried rice using Uber Eats")
    }

    private func makeHost(
        senderID: String? = "HOST-ID",
        code: String = "123456",
        capability: ComputerUseCapability
    ) -> LocalHostAdvertisement {
        LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: code,
            source: .cloudKit,
            senderID: senderID,
            computerUseCapability: capability)
    }

    private func progressEnvelope(
        _ progress: ComputerUseSetupProgress
    ) throws -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            senderID: "HOST-ID",
            targetID: "IOS-ID",
            pairingCode: "123456",
            sessionID: "setup-session",
            kind: .setupProgress,
            body: try progress.encodedBody())
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for setup state")
    }

    private func waitForSentMessage(
        kind: ComputerUseEnvelope.Kind,
        channel: FakeComputerUseSessionChannel,
        timeoutIterations: Int = 100
    ) async -> ComputerUseEnvelope? {
        for _ in 0..<timeoutIterations {
            if let message = await channel.sentMessages().last(where: {
                $0.kind == kind
            }) {
                return message
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(kind.rawValue) message")
        return nil
    }

    private func waitUntilAsync(
        timeoutIterations: Int = 100,
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous test state")
    }

    private func privateOptionalIsNil(named label: String, in value: Any) -> Bool? {
        guard let property = Mirror(reflecting: value).children.first(where: {
            $0.label == label
        }) else {
            return nil
        }
        let optional = Mirror(reflecting: property.value)
        guard optional.displayStyle == .optional else { return nil }
        return optional.children.isEmpty
    }
}

private actor FakeComputerUseSetupChannel: ComputerUseSetupChannel {
    struct SentMessage: Sendable {
        let id: String
        let kind: ComputerUseEnvelope.Kind
        let body: String
    }

    private var responseBatches: [[ComputerUseEnvelope]]
    private var sent: [SentMessage] = []

    init(responseBatches: [[ComputerUseEnvelope]]) {
        self.responseBatches = responseBatches
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let id = explicitMessageID ?? UUID().uuidString
        sent.append(SentMessage(id: id, kind: kind, body: body))
        return ComputerUseEnvelope(
            id: id,
            senderID: "IOS-ID",
            targetID: explicitTargetID ?? "HOST-ID",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "setup-session",
            kind: kind,
            body: body)
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        guard !responseBatches.isEmpty else { return [] }
        return responseBatches.removeFirst()
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func sentMessages() -> [SentMessage] {
        sent
    }
}

private actor FakeComputerUseSessionChannel: ComputerUseSessionChannel {
    private enum Failure: Error {
        case requestedFailure
    }

    private var failuresBeforeSuccess: Int
    private var assistantReplies: [String]
    private let failingKinds: [ComputerUseEnvelope.Kind]
    private let cancellationIgnoringBlockedSendKind: ComputerUseEnvelope.Kind?
    private let blocksPollUntilReleased: Bool
    private var sentPromptBodies: [String] = []
    private var sentPromptIDs: [String] = []
    private var sent: [ComputerUseEnvelope] = []
    private var attemptedKinds: [ComputerUseEnvelope.Kind] = []
    private var completedKinds: [ComputerUseEnvelope.Kind] = []
    private var incoming: [ComputerUseEnvelope] = []
    private var blockedSendReleased = false
    private var blockedSendContinuation: CheckedContinuation<Void, Never>?
    private var pollAttempts = 0
    private var completedPolls = 0
    private var pollReleased = false
    private var blockedPollContinuation: CheckedContinuation<Void, Never>?
    private var acknowledgedCount = 0
    private var failuresRemainingByKind: [String: Int] = [:]

    init(
        failuresBeforeSuccess: Int = 0,
        assistantReplies: [String] = [],
        failingKinds: [ComputerUseEnvelope.Kind] = [],
        cancellationIgnoringBlockedSendKind: ComputerUseEnvelope.Kind? = nil,
        blocksPollUntilReleased: Bool = false
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.assistantReplies = assistantReplies
        self.failingKinds = failingKinds
        self.cancellationIgnoringBlockedSendKind = cancellationIgnoringBlockedSendKind
        self.blocksPollUntilReleased = blocksPollUntilReleased
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let id = explicitMessageID ?? UUID().uuidString
        attemptedKinds.append(kind)
        if kind == .prompt {
            sentPromptBodies.append(body)
            sentPromptIDs.append(id)
        }
        if kind == cancellationIgnoringBlockedSendKind,
           !blockedSendReleased {
            await withCheckedContinuation { continuation in
                blockedSendContinuation = continuation
            }
        }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw Failure.requestedFailure
        }
        if let remaining = failuresRemainingByKind[kind.rawValue],
           remaining > 0 {
            failuresRemainingByKind[kind.rawValue] = remaining - 1
            throw Failure.requestedFailure
        }
        if failingKinds.contains(where: { $0.rawValue == kind.rawValue }) {
            throw Failure.requestedFailure
        }

        let envelope = ComputerUseEnvelope(
            id: id,
            senderID: "IOS-ID",
            targetID: explicitTargetID ?? "HOST-ID",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "session-1",
            kind: kind,
            body: body)
        sent.append(envelope)
        completedKinds.append(kind)
        if kind == .prompt, !assistantReplies.isEmpty {
            let reply = assistantReplies.removeFirst()
            let update = ComputerUseTaskUpdate(taskID: id, text: reply)
            incoming.append(ComputerUseEnvelope(
                senderID: "HOST-ID",
                targetID: "IOS-ID",
                pairingCode: "123456",
                sessionID: "session-1",
                kind: .assistant,
                body: try update.encodedBody()))
        }
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        pollAttempts += 1
        if blocksPollUntilReleased, !pollReleased {
            await withCheckedContinuation { continuation in
                blockedPollContinuation = continuation
            }
        }
        while incoming.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = incoming
        incoming.removeAll()
        completedPolls += 1
        return result
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        acknowledgedCount += envelopes.count
    }

    func promptBodies() -> [String] {
        sentPromptBodies
    }

    func promptIDs() -> [String] {
        sentPromptIDs
    }

    func sentMessages() -> [ComputerUseEnvelope] {
        sent
    }

    func sendAttemptCount(kind: ComputerUseEnvelope.Kind) -> Int {
        attemptedKinds.filter { $0.rawValue == kind.rawValue }.count
    }

    func completedSendCount(kind: ComputerUseEnvelope.Kind) -> Int {
        completedKinds.filter { $0.rawValue == kind.rawValue }.count
    }

    func releaseBlockedSend() {
        blockedSendReleased = true
        blockedSendContinuation?.resume()
        blockedSendContinuation = nil
    }

    func pollAttemptCount() -> Int {
        pollAttempts
    }

    func completedPollCount() -> Int {
        completedPolls
    }

    func releaseBlockedPoll() {
        pollReleased = true
        blockedPollContinuation?.resume()
        blockedPollContinuation = nil
    }

    func acknowledgedEnvelopeCount() -> Int {
        acknowledgedCount
    }

    func failNextSend(kind: ComputerUseEnvelope.Kind) {
        failuresRemainingByKind[kind.rawValue, default: 0] += 1
    }

    func enqueueHostEnvelope(
        kind: ComputerUseEnvelope.Kind,
        body: String
    ) {
        incoming.append(ComputerUseEnvelope(
            senderID: "HOST-ID",
            targetID: "IOS-ID",
            pairingCode: "123456",
            sessionID: "session-1",
            kind: kind,
            body: body))
    }
}

private final class InMemoryComputerUsePendingPromptStore:
    ComputerUsePendingPromptStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records: [String: ComputerUsePendingPrompt] = [:]
    private var remainingSuccessfulSaves: Int?

    init(failAfterSuccessfulSaves: Int? = nil) {
        remainingSuccessfulSaves = failAfterSuccessfulSaves
    }

    func load(
        hostID: String,
        pairingCode: String
    ) -> ComputerUsePendingPrompt? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[hostID],
              record.pairingCode == pairingCode else { return nil }
        return record
    }

    @discardableResult
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let remainingSuccessfulSaves {
            guard remainingSuccessfulSaves > 0 else { return false }
            self.remainingSuccessfulSaves = remainingSuccessfulSaves - 1
        }
        records[pending.hostID] = pending
        return true
    }

    func remove(hostID: String) {
        lock.lock()
        records[hostID] = nil
        lock.unlock()
    }
}
