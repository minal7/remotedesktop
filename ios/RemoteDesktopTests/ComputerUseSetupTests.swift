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
            createdAt: Date())

        store.save(pending)

        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456"),
            pending)
        XCTAssertEqual(
            store.load(hostID: hostID, pairingCode: "123456")?.exactWireBody,
            pending.wireBody)
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
    private var sentPromptBodies: [String] = []
    private var sentPromptIDs: [String] = []
    private var incoming: [ComputerUseEnvelope] = []

    init(
        failuresBeforeSuccess: Int = 0,
        assistantReplies: [String] = []
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.assistantReplies = assistantReplies
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let id = explicitMessageID ?? UUID().uuidString
        if kind == .prompt {
            sentPromptBodies.append(body)
            sentPromptIDs.append(id)
        }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
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
        while incoming.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = incoming
        incoming.removeAll()
        return result
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func promptBodies() -> [String] {
        sentPromptBodies
    }

    func promptIDs() -> [String] {
        sentPromptIDs
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
