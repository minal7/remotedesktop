import XCTest
import AVFAudio
import CloudKit
@testable import RemoteDesktop

@MainActor
final class WebRTCTransportTests: XCTestCase {
    private let accountBinding = CloudKitAccountBinding(
        rawValue: String(repeating: "c", count: 64))!

    func test_localRecoveryReadFailureStopsBeforeHandshakeOrVisualConnection() async throws {
        let unexpectedTransport = RecordingTargetTransport(connected: XCTestExpectation(description: "unexpected connection"))
        let expectedBinding = accountBinding
        let model = SessionModel(
            transportFactory: { XCTFail("No fallback transport before recovery can be read"); return unexpectedTransport },
            computerUseVisualTransportFactory: { XCTFail("No visual connection before recovery can be read"); return unexpectedTransport },
            localAccountBindingValidator: { binding in
                guard binding == expectedBinding else { throw LocalComputerUseCloudPairingError.accountMismatch }
            },
            localComputerUseChannelConnector: { _, _, _, _, _, _, _ in
                XCTFail("Do not choose a new session or handshake while a saved session is unreadable")
                return IdleComputerUseSessionChannel()
            },
            localPendingStore: EmptyComputerUsePendingPromptStore(failRecoveryRead: true),
            accountChangeNotificationCenter: NotificationCenter())
        defer { model.disconnect() }
        model.connect(code: "123456", experience: .computerUse, computerUseHostID: "HOST-B", hostName: "Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
            localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.error == nil {
            guard ContinuousClock.now < deadline else { return XCTFail("Recovery read failure must become a connection error") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.state, .idle); XCTAssertNil(model.computerUseSession)
        XCTAssertTrue(model.error?.contains("saved request has been kept") == true)
        XCTAssertNil(unexpectedTransport.pairingCode)
    }

    func test_localRecoveryRechecksStorageAfterHandshakeWithoutOverwritingChangedOrUnreadableRecords() async throws {
        let pending = ComputerUsePendingPrompt(hostID: "HOST-B", pairingCode: "654321", sessionID: "saved-session",
            messageID: "saved-task", prompt: "Find concert tickets.", createdAt: Date(), localAccountBinding: accountBinding)
        let changed = ComputerUsePendingPrompt(hostID: pending.hostID, pairingCode: pending.pairingCode, sessionID: "new-session",
            messageID: "new-task", prompt: "Find movie tickets.", createdAt: Date(), localAccountBinding: accountBinding)
        for unreadable in [true, false] {
            let store = HandshakeRecoveryStore(before: pending,
                after: unreadable ? .failure(.unavailable) : .success(changed))
            let channel = IdleComputerUseSessionChannel()
            let unexpectedTransport = RecordingTargetTransport(connected: XCTestExpectation(description: "unexpected visual connection"))
            let connected = expectation(description: "handshake uses the original session")
            let model = SessionModel(
                computerUseVisualTransportFactory: { XCTFail("No visual connection when task recovery cannot finish"); return unexpectedTransport },
                localAccountBindingValidator: { _ in },
                localComputerUseChannelConnector: { _, _, _, _, sessionID, _, _ in
                    XCTAssertEqual(sessionID, pending.sessionID); connected.fulfill(); return channel
                },
                localPendingStore: store, accountChangeNotificationCenter: NotificationCenter())
            defer { model.disconnect() }
            model.connect(code: "123456", experience: .computerUse, computerUseHostID: pending.hostID, hostName: "Mac",
                localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
                localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
            await fulfillment(of: [connected], timeout: 3)
            let deadline = ContinuousClock.now + .seconds(3)
            while model.error == nil {
                guard ContinuousClock.now < deadline else { return XCTFail("Changed or unreadable recovery must stop connection") }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(model.state, .idle); XCTAssertNil(model.computerUseSession)
            XCTAssertTrue(model.error?.contains(unreadable ? "saved request has been kept" : "changed while connecting") == true)
            XCTAssertEqual(store.writeCount, 0); XCTAssertEqual(store.readCount, 2)
        }
    }

    func test_localRecoveryRebindsTheLatestQuestionDraftAndDoesNotReviveARemovedRecord() async throws {
        let reference = try ComputerUseClarificationReference(taskID: "saved-task", expiresAt: Date().addingTimeInterval(300))
        let question = try ComputerUsePendingQuestion(reference: reference, text: "Which city?", answerPolicy: nil,
            receivedAt: Date(), validUntil: reference.expiresAt, draft: "old draft")
        let request = ComputerUsePromptRequest(prompt: "Find concert tickets.")
        let pending = ComputerUsePendingPrompt(hostID: "HOST-B", pairingCode: "654321", sessionID: "saved-session",
            messageID: reference.taskID, prompt: request.prompt, wireBody: try request.encodedBody(), createdAt: Date(),
            localAccountBinding: accountBinding, question: question)
        let latest = pending.retainingQuestion(try question.withDraft("  e\u{301} Paris 😀\n"))
        for removed in [true, false] {
            let store = HandshakeRecoveryStore(before: pending, after: .success(removed ? nil : latest))
            let connected = expectation(description: "visual sidecar starts after recovery lookup")
            let visual = RecordingTargetTransport(connected: connected)
            let channel = IdleComputerUseSessionChannel()
            let model = SessionModel(computerUseVisualTransportFactory: { visual }, localAccountBindingValidator: { _ in },
                localComputerUseChannelConnector: { _, _, _, _, sessionID, _, _ in
                    XCTAssertEqual(sessionID, pending.sessionID); return channel
                }, localPendingStore: store, accountChangeNotificationCenter: NotificationCenter())
            defer { model.disconnect() }
            model.connect(code: "123456", experience: .computerUse, computerUseHostID: pending.hostID, hostName: "Mac",
                localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
                localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
            await fulfillment(of: [connected], timeout: 3)
            XCTAssertEqual(model.state, .connected); XCTAssertEqual(store.readCount, 2)
            let client = try XCTUnwrap(model.computerUseSession)
            XCTAssertFalse(client.hasActivePrompt)
            if removed {
                XCTAssertNil(store.snapshot); XCTAssertEqual(store.writeCount, 0)
                XCTAssertTrue(client.messages.isEmpty); XCTAssertEqual(client.composerMode, .request)
            } else {
                let saved = try XCTUnwrap(store.snapshot)
                XCTAssertEqual(saved, latest.rebindingPairingCode("123456")); XCTAssertEqual(store.writeCount, 1)
                XCTAssertTrue(try XCTUnwrap(saved.question?.draft).utf8.elementsEqual(try XCTUnwrap(latest.question?.draft).utf8))
                XCTAssertEqual(saved.question?.validUntil, question.validUntil)
                XCTAssertEqual(client.composerMode, .recoveringAnswer)
                XCTAssertEqual(client.messages.last?.text, question.text)
            }
        }
    }

    func test_localRecoveryConditionalRebindCannotOverwriteARecordChangedAfterTheFinalLookup() async throws {
        let original = ComputerUsePendingPrompt(hostID: "HOST-B", pairingCode: "654321", sessionID: "saved-session",
            messageID: "saved-task", prompt: "Find concerts.", createdAt: Date(), localAccountBinding: accountBinding)
        let newer = ComputerUsePendingPrompt(hostID: original.hostID, pairingCode: original.pairingCode, sessionID: original.sessionID,
            messageID: "newer-task", prompt: "Find movies.", createdAt: Date(), localAccountBinding: accountBinding)
        let store = HandshakeRecoveryStore(before: original, after: .success(original), replaceOnConditionalRead: newer)
        let channel = IdleComputerUseSessionChannel()
        let unexpectedTransport = RecordingTargetTransport(connected: XCTestExpectation(description: "unexpected visual connection"))
        let model = SessionModel(
            computerUseVisualTransportFactory: { XCTFail("No visual connection after a recovery ownership conflict"); return unexpectedTransport },
            localAccountBindingValidator: { _ in },
            localComputerUseChannelConnector: { _, _, _, _, _, _, _ in channel },
            localPendingStore: store, accountChangeNotificationCenter: NotificationCenter())
        defer { model.disconnect() }
        model.connect(code: "123456", experience: .computerUse, computerUseHostID: original.hostID, hostName: "Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
            localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.error == nil {
            guard ContinuousClock.now < deadline else { return XCTFail("A conflicting rebind must stop recovery") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.state, .idle); XCTAssertNil(model.computerUseSession)
        XCTAssertEqual(store.snapshot, newer); XCTAssertEqual(store.writeCount, 0)
        XCTAssertTrue(model.error?.contains("could not be saved safely") == true)
    }

    func test_remoteSessionOfferRequestsReceiveOnlyVideoAndHostAudio()
        async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _, _ in channel },
            iceConfigProvider: { .fallback })

        try await transport.connect(pairingCode: "123456")
        let snapshot = channel.snapshot()
        transport.disconnect(reason: "test")

        XCTAssertEqual(snapshot.claimCount, 1)
        XCTAssertEqual(snapshot.sent.count, 1)
        XCTAssertEqual(snapshot.sent.first?.kind, .offer)
        XCTAssertEqual(snapshot.sent.first?.payload["sdpType"], "offer")
        XCTAssertTrue(
            snapshot.sent.first?.payload["sdp"]?.contains("m=video") == true,
            "expected the client offer to negotiate a video m-line")
        XCTAssertTrue(
            snapshot.sent.first?.payload["sdp"]?.contains("m=audio") == true,
            "expected the client offer to negotiate an audio m-line for host audio")

        let sdp = try XCTUnwrap(snapshot.sent.first?.payload["sdp"])
        XCTAssertTrue(mediaSection("video", in: sdp).contains("a=recvonly"))
        XCTAssertTrue(mediaSection("audio", in: sdp).contains("a=recvonly"))
        XCTAssertFalse(mediaSection("video", in: sdp).contains("a=sendrecv"))
        XCTAssertFalse(mediaSection("audio", in: sdp).contains("a=sendrecv"))
        XCTAssertTrue(
            mediaSection("video", in: sdp).contains("profile-level-id=640c33"),
            "expected the client to offer hardware H.264 level 5.1 for a Retina desktop stream")
        XCTAssertTrue(
            mediaSection("video", in: sdp).contains("profile-level-id=42e01f"),
            "expected the client to retain its level-3.1 interoperability fallback")
    }

    func test_visualSidecarMediaPolicyOffersVideoWithoutHostAudio() async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _, _ in channel },
            iceConfigProvider: { .fallback },
            mediaPolicy: .computerUseVisualSidecar)

        try await transport.connect(
            pairingCode: "123456",
            expectedHostID: "HOST-B")
        let snapshot = channel.snapshot()
        transport.disconnect(reason: "test")

        XCTAssertEqual(snapshot.claimCount, 1)
        XCTAssertEqual(snapshot.sent.count, 1)
        let offer = try XCTUnwrap(snapshot.sent.first)
        XCTAssertEqual(offer.kind, .offer)
        let sdp = try XCTUnwrap(offer.payload["sdp"])
        XCTAssertTrue(
            sdp.contains("m=video"),
            "The visual sidecar must still request decoded Mac pixels.")
        XCTAssertFalse(
            sdp.contains("m=audio"),
            "The optional visual sidecar must not negotiate host audio.")
        XCTAssertTrue(mediaSection("video", in: sdp).contains("a=recvonly"))
        XCTAssertFalse(mediaSection("video", in: sdp).contains("a=sendrecv"))
    }

    func test_audioSessionPolicy_isPlaybackOnly() {
        XCTAssertEqual(RemoteAudioSessionPolicy.category, .playback)
        XCTAssertFalse(RemoteAudioSessionPolicy.categoryOptions.contains(.allowBluetoothHFP))
        XCTAssertFalse(RemoteAudioSessionPolicy.categoryOptions.contains(.defaultToSpeaker))
    }

    func test_disconnectDoesNotReportCancelledIceDeadlineAsFailure() async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _, _ in channel },
            iceConfigProvider: { .fallback })
        var disconnectReasons: [String] = []
        transport.onDisconnect = { reason in
            disconnectReasons.append(reason)
        }

        try await transport.connect(pairingCode: "123456")
        transport.disconnect(reason: "test")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(disconnectReasons.isEmpty)
    }

    func test_connectPassesSelectedHostIdentityToSignaling() async throws {
        let channel = FakeWebRTCSignalingChannel()
        var receivedHostID: String?
        let transport = WebRTCTransport(
            signalingFactory: { _, expectedHostID in
                receivedHostID = expectedHostID
                return channel
            },
            iceConfigProvider: { .fallback })

        try await transport.connect(
            pairingCode: "123456",
            expectedHostID: "HOST-B")
        transport.disconnect(reason: "test")

        XCTAssertEqual(receivedHostID, "HOST-B")
    }

    func test_sessionModelRejectsCloudOnlyComputerUseBeforeOpeningTransport()
        async {
        let connected = expectation(
            description: "cloud-only computer use must not connect")
        connected.isInverted = true
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(transportFactory: { transport })

        model.connect(
            code: "123456",
            experience: .computerUse,
            computerUseHostID: "HOST-B",
            hostName: "Studio Mac")
        await fulfillment(of: [connected], timeout: 0.05)

        XCTAssertNil(transport.pairingCode)
        XCTAssertNil(transport.expectedHostID)
        XCTAssertNil(model.computerUseSession)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.error?.contains("Secure local AI pairing") == true)
        model.reset()
    }

    func test_sessionModelRequiresAnActualDecodedFrameForVideoReadiness() async {
        let connected = expectation(description: "transport connect called")
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(transportFactory: { transport })

        model.connect(code: "123456")
        await fulfillment(of: [connected], timeout: 1)

        transport.onHostHello?(HostHello(
            app: "RemoteDesktop-Mac",
            version: "1.0",
            hostname: "Studio Mac",
            os: "macOS",
            audio: true,
            monitors: 1))
        XCTAssertEqual(model.state, .connected)
        guard case let .qos(targetFps, maxBitrateKbps, prefer)? =
                transport.sentMessages.last?.message else {
            return XCTFail("expected the client to request the desktop quality policy")
        }
        XCTAssertEqual(targetFps, DesktopVideoQuality.targetFramesPerSecond)
        XCTAssertEqual(maxBitrateKbps, DesktopVideoQuality.maximumBitrateKbps)
        XCTAssertEqual(prefer, "sharpness")
        XCTAssertFalse(
            model.hasReceivedVideoFrame,
            "A control-channel hello must not disguise a pending macOS capture-consent prompt as a live screen.")

        transport.onFirstVideoFrame?()
        XCTAssertTrue(model.hasReceivedVideoFrame)

        model.reset()
        XCTAssertFalse(model.hasReceivedVideoFrame)
    }

    func test_sessionModelRejectsMalformedLocalRouteBeforeOpeningTransport()
        async {
        let connected = expectation(
            description: "malformed local route must not connect")
        connected.isInverted = true
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(transportFactory: { transport })

        model.connect(
            code: "123456",
            experience: .computerUse,
            computerUseHostID: "HOST-B",
            hostName: "Studio Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(
                host: "studio-mac.local.",
                port: 44_444),
            localCredentialID: "NOT-A-SHA256-SELECTOR",
            localCloudAccountBinding: accountBinding)
        await fulfillment(of: [connected], timeout: 0.05)

        XCTAssertNil(transport.pairingCode)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.computerUseSession)
        XCTAssertTrue(model.error?.contains("Secure local AI pairing") == true)
        XCTAssertTrue(transport.sentMessages.isEmpty)
    }

    func test_sessionModelRequiresAccountBindingBeforeLocalComputerUse()
        async {
        let connected = expectation(
            description: "unbound local computer use must not connect")
        connected.isInverted = true
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(transportFactory: { transport })

        model.connect(
            code: "123456",
            experience: .computerUse,
            computerUseHostID: "HOST-B",
            hostName: "Studio Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(
                host: "studio-mac.local.",
                port: 44_444),
            localCredentialID: String(repeating: "b", count: 64))
        await fulfillment(of: [connected], timeout: 0.05)

        XCTAssertNil(transport.pairingCode)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.computerUseSession)
        XCTAssertTrue(model.error?.contains("same Apple Account") == true)
    }

    func test_accountSignOutImmediatelyEndsActiveRemoteSession() async {
        let connected = expectation(description: "transport connect called")
        let disconnected = expectation(
            description: "transport disconnected after account change")
        let transport = RecordingTargetTransport(
            connected: connected,
            disconnected: disconnected)
        let notifications = NotificationCenter()
        let model = SessionModel(
            transportFactory: { transport },
            localAccountBindingValidator: { _ in
                throw CloudKitAccountBindingResolutionError.noAccount
            },
            accountChangeNotificationCenter: notifications)

        model.connect(
            code: "123456",
            computerUseHostID: "HOST-B",
            hostName: "Studio Mac",
            localCloudAccountBinding: accountBinding)
        await fulfillment(of: [connected], timeout: 1)
        transport.onHostHello?(HostHello(
            app: "RemoteDesktop-Mac",
            version: "1.0",
            hostname: "Studio Mac",
            os: "macOS",
            audio: true,
            monitors: 1))
        XCTAssertEqual(model.state, .connected)

        notifications.post(
            name: NSNotification.Name.CKAccountChanged,
            object: nil)
        XCTAssertTrue(model.isCloudAccountRevalidationPending)
        await fulfillment(of: [disconnected], timeout: 1)

        guard case .ended(let reason) = model.state else {
            return XCTFail("Expected account sign-out to end the session")
        }
        XCTAssertTrue(reason.contains("Apple Account changed"))
        XCTAssertFalse(model.isCloudAccountRevalidationPending)
        XCTAssertTrue(
            transport.disconnectReasons.contains { $0.contains("Apple Account changed") })
    }

    func test_localVisualSidecarGatesInputOnCompatibleHelloAndFreshFrame() async {
        let connected = expectation(description: "sidecar connect called")
        let transport = RecordingTargetTransport(connected: connected)
        let sidecar = ComputerUseVisualSidecar(
            transportFactory: { transport })

        sidecar.start(
            pairingCode: "123456",
            expectedHostID: "HOST-B")
        await fulfillment(of: [connected], timeout: 1)

        XCTAssertEqual(sidecar.state, .connecting)
        XCTAssertEqual(transport.expectedHostID, "HOST-B")
        XCTAssertFalse(sidecar.sendDirectInput(.text("too-early")))

        // A decoded frame from an unacknowledged/stale peer is not enough.
        transport.onFirstVideoFrame?()
        XCTAssertEqual(sidecar.state, .connecting)
        XCTAssertFalse(sidecar.sendDirectInput(.text("still-too-early")))

        transport.onHostHello?(HostHello(
            app: "RemoteDesktop-Mac",
            version: "1.0",
            hostname: "Studio Mac",
            os: "macOS",
            audio: true,
            monitors: 1,
            orderedComputerUseControls:
                Config.orderedComputerUseControlsVersion))

        XCTAssertEqual(sidecar.state, .waitingForFreshFrame)
        XCTAssertFalse(sidecar.sendDirectInput(.text("without-display")))
        transport.onDisplay?(DisplayInfo(w: 1_920, h: 1_080, scale: 2))
        XCTAssertEqual(sidecar.state, .live)
        XCTAssertTrue(sidecar.sendDirectInput(.text("person-input")))
        XCTAssertEqual(transport.sentMessages.count, 2)
        guard case .qos = transport.sentMessages[0].message else {
            return XCTFail("Expected sidecar-only quality policy first")
        }
        guard case .text(let text) = transport.sentMessages[1].message else {
            return XCTFail("Expected fresh-frame-gated direct input")
        }
        XCTAssertEqual(text, "person-input")
        XCTAssertFalse(sidecar.sendDirectInput(.qos(
            targetFps: 1,
            maxBitrateKbps: 1,
            prefer: "must-not-cross")))
        XCTAssertEqual(transport.sentMessages.count, 2)
        sidecar.stop(preserveConfiguration: false)
    }

    func test_localVisualSidecarLossHidesPixelsAndFencesStaleCallbacks() async {
        let firstConnected = expectation(description: "first sidecar connect")
        let secondConnected = expectation(description: "resumed sidecar connect")
        let first = RecordingTargetTransport(connected: firstConnected)
        let second = RecordingTargetTransport(connected: secondConnected)
        var candidates: [RecordingTargetTransport] = [first, second]
        let sidecar = ComputerUseVisualSidecar(
            transportFactory: { candidates.removeFirst() })

        sidecar.start(
            pairingCode: "123456",
            expectedHostID: "HOST-B")
        await fulfillment(of: [firstConnected], timeout: 1)
        first.onHostHello?(compatibleComputerUseHello())
        first.onDisplay?(DisplayInfo(w: 1_920, h: 1_080, scale: 2))
        first.onFirstVideoFrame?()
        XCTAssertEqual(sidecar.state, .live)

        first.onDisconnect?("network lost")
        XCTAssertEqual(sidecar.state, .failed)
        XCTAssertFalse(sidecar.sendDirectInput(.text("after-loss")))

        // Account revalidation uses this same stop/resume path. Old callbacks
        // cannot resurrect stale pixels or send input into the new generation.
        sidecar.stop(preserveConfiguration: true)
        sidecar.resume()
        await fulfillment(of: [secondConnected], timeout: 1)
        XCTAssertEqual(sidecar.state, .connecting)
        first.onHostHello?(compatibleComputerUseHello())
        first.onFirstVideoFrame?()
        first.onDisconnect?("stale disconnect")
        XCTAssertEqual(sidecar.state, .connecting)

        second.onHostHello?(compatibleComputerUseHello())
        XCTAssertEqual(sidecar.state, .waitingForFreshFrame)
        second.onDisplay?(DisplayInfo(w: 1_920, h: 1_080, scale: 2))
        XCTAssertEqual(sidecar.state, .waitingForFreshFrame)
        second.onFirstVideoFrame?()
        XCTAssertEqual(sidecar.state, .live)
        XCTAssertTrue(sidecar.sendDirectInput(.text("current-generation")))
        XCTAssertEqual(second.sentMessages.count, 2)
        sidecar.stop(preserveConfiguration: false)
    }

    func test_localPromptSessionFencesSidecarAcrossAccountChangeAndSurvivesItsLoss()
        async throws {
        let firstConnected = expectation(description: "first visual sidecar")
        let resumedConnected = expectation(description: "resumed visual sidecar")
        let first = RecordingTargetTransport(connected: firstConnected)
        let resumed = RecordingTargetTransport(connected: resumedConnected)
        var sidecarCandidates = [first, resumed]
        let notifications = NotificationCenter()
        let validationGate = InitialLocalAccountValidationGate()
        let sessionChannel = IdleComputerUseSessionChannel()
        let expectedBinding = accountBinding
        let model = SessionModel(
            computerUseVisualTransportFactory: {
                sidecarCandidates.removeFirst()
            },
            localAccountBindingValidator: { binding in
                guard binding == expectedBinding else {
                    throw LocalComputerUseCloudPairingError.accountMismatch
                }
                try await validationGate.validate()
            },
            localComputerUseChannelConnector: {
                _, _, _, _, _, _, binding in
                guard binding == expectedBinding else {
                    throw LocalComputerUseCloudPairingError.accountMismatch
                }
                return sessionChannel
            },
            localPendingStore: EmptyComputerUsePendingPromptStore(),
            accountChangeNotificationCenter: notifications)

        model.connect(
            code: "123456",
            experience: .computerUse,
            computerUseHostID: "HOST-B",
            hostName: "Studio Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(
                host: "127.0.0.1",
                port: 443),
            localCredentialID: String(repeating: "b", count: 64),
            localCloudAccountBinding: accountBinding)
        await fulfillment(of: [firstConnected], timeout: 1)

        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(model.computerUseConnectionMode, .localPromptOnly)
        XCTAssertTrue(model.computerUseSession?.isConnected == true)
        XCTAssertTrue(model.isComputerUsePromptTransportReady)
        XCTAssertEqual(first.expectedHostID, "HOST-B")

        first.onHostHello?(compatibleComputerUseHello())
        first.onDisplay?(DisplayInfo(w: 1_920, h: 1_080, scale: 2))
        first.onFirstVideoFrame?()
        XCTAssertEqual(model.computerUseVisualSidecarState, .live)
        XCTAssertTrue(model.hasInteractiveRemoteScreen)

        notifications.post(
            name: NSNotification.Name.CKAccountChanged,
            object: nil)
        XCTAssertTrue(model.isCloudAccountRevalidationPending)
        XCTAssertFalse(model.isComputerUsePromptTransportReady)
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        XCTAssertTrue(model.computerUseSession?.isConnected == false)
        XCTAssertEqual(model.computerUseVisualSidecarState, .unavailable)

        let revalidationStarted = await validationGate.waitForCallCount(
            3,
            timeout: .seconds(1))
        XCTAssertTrue(
            revalidationStarted,
            "The account-change path did not start its causally required revalidation.")
        let validationCallCount = await validationGate.callCount()
        XCTAssertEqual(validationCallCount, 3)
        await validationGate.resumeRevalidation()
        await fulfillment(of: [resumedConnected], timeout: 1)

        XCTAssertFalse(model.isCloudAccountRevalidationPending)
        XCTAssertTrue(model.isComputerUsePromptTransportReady)
        XCTAssertTrue(model.computerUseSession?.isConnected == true)
        XCTAssertEqual(model.computerUseVisualSidecarState, .connecting)

        // No callback from the pre-account-change generation may reveal pixels
        // or fail the replacement sidecar.
        first.onHostHello?(compatibleComputerUseHello())
        first.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1))
        first.onFirstVideoFrame?()
        first.onDisconnect?("stale")
        XCTAssertEqual(model.computerUseVisualSidecarState, .connecting)

        resumed.onHostHello?(compatibleComputerUseHello())
        resumed.onDisplay?(DisplayInfo(w: 1_920, h: 1_080, scale: 2))
        resumed.onFirstVideoFrame?()
        XCTAssertEqual(model.computerUseVisualSidecarState, .live)
        XCTAssertTrue(model.hasInteractiveRemoteScreen)

        resumed.onDisconnect?("video lost")
        XCTAssertEqual(model.computerUseVisualSidecarState, .failed)
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        XCTAssertEqual(model.state, .connected)
        XCTAssertTrue(model.computerUseSession?.isConnected == true)
        XCTAssertTrue(model.isComputerUsePromptTransportReady)
        model.reset()
    }

    func test_wireHelloNegotiatesOrderedComputerUseControlsSeparately() throws {
        let data = ControlMessage.hello(proto: Config.protocolVersion).encoded(
            seq: 0,
            ts: 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let client = try XCTUnwrap(object["client"] as? [String: Any])

        XCTAssertEqual(object["proto"] as? Int, 1)
        XCTAssertEqual(
            client["orderedComputerUseControls"] as? Int,
            Config.orderedComputerUseControlsVersion)
    }

    func test_hostHelloDecodesOrderedComputerUseControlsCapability() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "t": "hello_ack",
            "proto": Config.protocolVersion,
            "host": [
                "app": "RemoteDesktop-Mac",
                "version": "0.2.0",
                "hostname": "Studio Mac",
                "os": "macOS",
            ],
            "caps": [
                "audio": true,
                "monitors": 1,
                "orderedComputerUseControls": 1,
            ],
        ])

        guard case .helloAck(let hello) = HostMessage.decode(data) else {
            return XCTFail("Expected a compatible host hello")
        }
        XCTAssertEqual(hello.orderedComputerUseControls, 1)
    }

    private func mediaSection(_ kind: String, in sdp: String) -> String {
        let marker = "m=\(kind)"
        guard let start = sdp.range(of: marker) else { return "" }
        let suffix = sdp[start.lowerBound...]
        if let next = suffix.dropFirst(marker.count).range(of: "\nm=") {
            return String(suffix[..<next.lowerBound])
        }
        return String(suffix)
    }

    private func compatibleComputerUseHello() -> HostHello {
        HostHello(
            app: "RemoteDesktop-Mac",
            version: "1.0",
            hostname: "Studio Mac",
            os: "macOS",
            audio: true,
            monitors: 1,
            orderedComputerUseControls:
                Config.orderedComputerUseControlsVersion)
    }
}

@MainActor
private final class RecordingTargetTransport: Transport {
    struct SentMessage {
        let message: ControlMessage
        let seq: UInt32
        let ts: UInt64
    }

    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private let connected: XCTestExpectation
    private let disconnected: XCTestExpectation?
    private(set) var pairingCode: String?
    private(set) var expectedHostID: String?
    private(set) var sentMessages: [SentMessage] = []
    private(set) var disconnectReasons: [String] = []

    init(
        connected: XCTestExpectation,
        disconnected: XCTestExpectation? = nil
    ) {
        self.connected = connected
        self.disconnected = disconnected
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        self.pairingCode = pairingCode
        self.expectedHostID = expectedHostID
        connected.fulfill()
    }

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        sentMessages.append(SentMessage(message: message, seq: seq, ts: ts))
    }
    func disconnect(reason: String) {
        disconnectReasons.append(reason)
        disconnected?.fulfill()
    }
}

private actor SuspendedAccountBindingValidator {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Error>?

    func validate() async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func callCount() -> Int { calls }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

private actor InitialLocalAccountValidationGate {
    private var calls = 0
    private var revalidationContinuation:
        CheckedContinuation<Void, Error>?

    func validate() async throws {
        calls += 1
        guard calls > 2 else { return }
        try await withCheckedThrowingContinuation { continuation in
            revalidationContinuation = continuation
        }
    }

    func callCount() -> Int { calls }

    func waitForCallCount(
        _ expectedCount: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while calls < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return calls >= expectedCount
    }

    func resumeRevalidation() {
        revalidationContinuation?.resume()
        revalidationContinuation = nil
    }
}

private actor IdleComputerUseSessionChannel: ComputerUseSessionChannel {
    private enum Failure: Error {
        case unexpectedSend
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        throw Failure.unexpectedSend
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
}

private final class EmptyComputerUsePendingPromptStore:
    ComputerUsePendingPromptStoring,
    @unchecked Sendable
{
    private let failRecoveryRead: Bool
    init(failRecoveryRead: Bool = false) { self.failRecoveryRead = failRecoveryRead }

    func readForLocalRecovery(hostID: String,
        localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt? {
        if failRecoveryRead { throw ComputerUsePendingPromptReadError.unavailable }
        return nil
    }

    func load(
        hostID: String,
        pairingCode: String
    ) -> ComputerUsePendingPrompt? {
        nil
    }

    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        true
    }

    func remove(hostID: String) {}
}

private final class HandshakeRecoveryStore: ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let before: ComputerUsePendingPrompt
    private let after: Result<ComputerUsePendingPrompt?, ComputerUsePendingPromptReadError>
    private var current: ComputerUsePendingPrompt?
    private var replaceOnConditionalRead: ComputerUsePendingPrompt?
    private var reads = 0
    private var writes = 0
    init(before: ComputerUsePendingPrompt, after: Result<ComputerUsePendingPrompt?, ComputerUsePendingPromptReadError>,
         replaceOnConditionalRead: ComputerUsePendingPrompt? = nil) {
        self.before = before; self.after = after; self.current = before
        self.replaceOnConditionalRead = replaceOnConditionalRead
    }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var snapshot: ComputerUsePendingPrompt? { lock.lock(); defer { lock.unlock() }; return current }
    func readForLocalRecovery(hostID: String, localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if reads == 1 { return before }
        current = try after.get()
        return current
    }
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        if let replaceOnConditionalRead {
            current = replaceOnConditionalRead
            self.replaceOnConditionalRead = nil
        }
        guard current?.hostID == hostID, current?.pairingCode == pairingCode else { return nil }
        return current
    }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        lock.lock(); defer { lock.unlock() }; writes += 1; current = pending; return true
    }
    func remove(hostID: String) { lock.lock(); defer { lock.unlock() }; writes += 1; current = nil }
}

private final class FakeWebRTCSignalingChannel: SignalingChannel, @unchecked Sendable {
    struct Snapshot {
        let claimCount: Int
        let sent: [SignalingEnvelope]
    }

    private let queue = DispatchQueue(label: "FakeWebRTCSignalingChannel")
    private var claimCount = 0
    private var sent: [SignalingEnvelope] = []

    func claim() async throws {
        queue.sync { claimCount += 1 }
    }

    func send(_ envelope: SignalingEnvelope) async throws {
        queue.sync { sent.append(envelope) }
    }

    func poll() async throws -> [SignalingEnvelope] {
        []
    }

    func snapshot() -> Snapshot {
        queue.sync { Snapshot(claimCount: claimCount, sent: sent) }
    }
}
