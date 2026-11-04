import XCTest
import AVFAudio
import CloudKit
import UIKit
import LiveKitWebRTC
@testable import RemoteDesktop

@MainActor
final class WebRTCTransportTests: XCTestCase {
    private let accountBinding = CloudKitAccountBinding(
        rawValue: String(repeating: "c", count: 64))!

    func test_iceDiagnosticsCountOnlyCandidateKindsAndReportCompleteRelayConfiguration() {
        var counts = ICECandidateDiagnosticCounts()
        counts.record("candidate:1 1 udp 1 192.0.2.1 4567 typ host")
        counts.record("candidate:2 1 udp 1 192.0.2.2 4567 typ srflx")
        counts.record("candidate:3 1 udp 1 192.0.2.3 4567 typ prflx")
        counts.record("candidate:4 1 udp 1 192.0.2.4 4567 typ relay")
        counts.record("candidate:5 1 udp 1 192.0.2.5 4567 typ unrecognized")
        counts.record("malformed")
        XCTAssertEqual(counts.host, 1)
        XCTAssertEqual(counts.serverReflexive, 1)
        XCTAssertEqual(counts.peerReflexive, 1)
        XCTAssertEqual(counts.relay, 1)
        XCTAssertEqual(counts.unknown, 2)
        XCTAssertFalse(counts.summary.contains("192.0.2"))
        XCTAssertFalse(counts.summary.contains("4567"))

        XCTAssertFalse(ICEConfig.fallback.hasCompleteTURNConfiguration)
        XCTAssertFalse(ICEConfig(stunURLs: [], turnURLs: ["turn:example.invalid"],
            turnUsername: "user", turnCredential: "").hasCompleteTURNConfiguration)
        XCTAssertFalse(ICEConfig(stunURLs: [], turnURLs: ["stun:example.invalid"],
            turnUsername: "user", turnCredential: "password").hasCompleteTURNConfiguration)
        XCTAssertTrue(ICEConfig(stunURLs: [], turnURLs: ["turns:example.invalid"],
            turnUsername: "user", turnCredential: "password").hasCompleteTURNConfiguration)
    }

    func test_candidatePixelsPrecedeFrameReadinessWithoutGrantingInput() async throws {
        let connected = expectation(description: "candidate pixels transport")
        let transport = RecordingTargetTransport(connected: connected)
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456")
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertFalse(session.mayRevealRemoteScreenPixels)
        transport.onHostHello?(compatibleComputerUseHello())
        XCTAssertFalse(session.mayRevealRemoteScreenPixels)
        transport.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1))
        XCTAssertTrue(session.mayRevealRemoteScreenPixels)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertNil(session.beginRemoteInputSource(.pointer, expectedInputGeneration: session.remoteInputGeneration))
        let count = transport.sentMessages.count
        session.send(.pointer(x: 10, y: 20, buttons: 1))
        XCTAssertEqual(transport.sentMessages.count, count)
        transport.onFirstVideoFrame?()
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
        transport.onVideoFrameUnavailable?()
        XCTAssertTrue(session.mayRevealRemoteScreenPixels, "Local frame loss cannot close the path needed to display its replacement")
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        transport.onInputUnavailable?()
        XCTAssertFalse(session.mayRevealRemoteScreenPixels)
    }

    func test_candidateVisibilityJoinsActivityCleanupAndRetainsConcurrentReturn() async throws {
        let (session, visual, _) = try await makePrivacyFixture()
        let owner = NSObject(), generation = session.remoteInputGeneration
        let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.send(.pointer(x: 10, y: 20, buttons: 1), from: pointer)
        var states: [Bool] = [], returned = false
        let observation = session.observeRemoteScreenVisibility(owner: owner) {
            states.append(session.mayRevealRemoteScreenPixels)
            if !session.mayRevealRemoteScreenPixels && !returned {
                returned = true
                XCTAssertTrue(visual.sentMessages.contains { if case .pointer(x: 10, y: 20, buttons: 0) = $0.message { return true }; return false },
                    "Held input must release before a surface loss closes its wire readiness")
                session.setApplicationInputActive(true)
            }
        }
        defer { session.removeRemoteScreenVisibilityObserver(observation); withExtendedLifetime(owner) {}; session.reset() }
        session.setApplicationInputActive(false)
        XCTAssertTrue(returned)
        XCTAssertTrue(states.contains(false)); XCTAssertEqual(states.last, true)
        XCTAssertTrue(session.inputActivity.allowsInput)
        XCTAssertTrue(session.mayRevealRemoteScreenPixels)
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        XCTAssertFalse(session.isRemoteInputSourceCurrent(pointer))
    }

    func test_sidecarCandidateDisplaySurvivesFrameLossButNotARepeatedHello() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture()
        defer { session.reset() }
        let display = session.display
        visual.onVideoFrameUnavailable?()
        XCTAssertEqual(session.computerUseVisualSidecarState, .waitingForFreshFrame)
        XCTAssertEqual(session.display, display)
        XCTAssertTrue(session.mayRevealRemoteScreenPixels)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertTrue(session.computerUseSession === prompt); XCTAssertTrue(session.isComputerUsePromptTransportReady)
        // A new hello while already waiting must still withdraw the old
        // display. Duplicate UI state text cannot hide that lifetime change.
        visual.onHostHello?(compatibleComputerUseHello())
        XCTAssertNil(session.display)
        XCTAssertFalse(session.mayRevealRemoteScreenPixels)
        visual.onDisplay?(DisplayInfo(w: 1024, h: 768, scale: 1))
        XCTAssertTrue(session.mayRevealRemoteScreenPixels)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        visual.onFirstVideoFrame?()
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
    }

    func test_nativeScreenDetachesForPrivacyAndPreparesAgainBeforeReadiness() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture()
        let window = try RemoteKeyboardTestWindow()
        let screen = RemoteScreenUIView()
        screen.frame = window.window.bounds
        screen.bindSession(session)
        visual.onDetachRenderer = { visual.onVideoFrameUnavailable?() }
        defer { visual.onDetachRenderer = nil; screen.stopCapture(); screen.removeFromSuperview(); window.close(); session.reset() }
        window.window.rootViewController?.view.addSubview(screen)
        XCTAssertEqual(visual.attachedRenderers.count, 1)
        XCTAssertTrue(prompt.sendPrompt("Draft an email to Alex."))
        XCTAssertFalse(session.mayRevealRemoteScreenPixels)
        XCTAssertEqual(visual.detachedRenderers.count, 1)
        XCTAssertFalse(session.isRemoteScreenSessionReady)
        XCTAssertTrue(session.shouldPrepareRemoteScreenRenderer, "Keep the native container and explicit Show Mac path available")
        XCTAssertTrue(visual.disconnectReasons.isEmpty)
        prompt.revealLiveScreen()
        XCTAssertTrue(session.mayRevealRemoteScreenPixels)
        XCTAssertEqual(visual.attachedRenderers.count, 2)
        XCTAssertFalse(session.hasInteractiveRemoteScreen, "Preparing a renderer is not frame readiness")
        visual.onFirstVideoFrame?()
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
        XCTAssertTrue(session.computerUseSession === prompt)
    }

    func test_visibilityObserversRetireWithTheirNativeOwnerOrExplicitRemoval() async throws {
        let (session, _, _) = try await makePrivacyFixture()
        defer { session.reset() }
        var retiredCalls = 0, removedCalls = 0
        autoreleasepool {
            let owner = NSObject()
            _ = session.observeRemoteScreenVisibility(owner: owner) { retiredCalls += 1 }
        }
        let owner = NSObject()
        let observation = session.observeRemoteScreenVisibility(owner: owner) { removedCalls += 1 }
        session.removeRemoteScreenVisibilityObserver(observation)
        session.setApplicationInputActive(false); session.setApplicationInputActive(true)
        XCTAssertEqual(retiredCalls, 1); XCTAssertEqual(removedCalls, 1)
    }

    func test_promptConnectionWithdrawalNotifiesPixelVisibilityWithoutPrivacyChange() async throws {
        let (session, _, prompt) = try await makePrivacyFixture()
        let owner = NSObject()
        var states: [Bool] = []
        let observation = session.observeRemoteScreenVisibility(owner: owner) { states.append(session.mayRevealRemoteScreenPixels) }
        defer { session.removeRemoteScreenVisibilityObserver(observation); withExtendedLifetime(owner) {}; session.reset() }
        XCTAssertEqual(states.last, true)
        XCTAssertFalse(session.isRemoteScreenObscured)
        prompt.stop()
        XCTAssertEqual(states.last, false, "An unchanged privacy bit cannot retain pixels for a stopped prompt connection")
        XCTAssertFalse(session.isRemoteScreenObscured)
        prompt.start()
        XCTAssertEqual(states.last, true)
    }

    func test_nativeVisibilityRegistrationPreservesReplacementDuringOldRendererDetach() async throws {
        let (old, oldVisual, _) = try await makePrivacyFixture()
        let (interrupted, interruptedVisual, interruptedPrompt) = try await makePrivacyFixture()
        let (current, currentVisual, currentPrompt) = try await makePrivacyFixture()
        let window = try RemoteKeyboardTestWindow()
        let screen = RemoteScreenUIView()
        screen.frame = window.window.bounds
        screen.bindSession(old)
        window.window.rootViewController?.view.addSubview(screen)
        defer {
            oldVisual.onDetachRenderer = nil
            screen.stopCapture(); screen.removeFromSuperview(); window.close()
            old.reset(); interrupted.reset(); current.reset()
        }
        var replaced = false
        oldVisual.onDetachRenderer = {
            guard !replaced else { return }
            replaced = true
            screen.bindSession(current)
        }
        screen.bindSession(interrupted)
        XCTAssertTrue(replaced)
        XCTAssertTrue(screen.session === current)
        XCTAssertEqual(oldVisual.detachedRenderers.count, 1)
        XCTAssertTrue(interruptedVisual.attachedRenderers.isEmpty)
        XCTAssertEqual(currentVisual.attachedRenderers.count, 1)
        XCTAssertTrue(interruptedPrompt.sendPrompt("Draft an email to Alex."))
        XCTAssertTrue(currentVisual.detachedRenderers.isEmpty)
        XCTAssertTrue(currentPrompt.sendPrompt("Draft an email to Alex."))
        XCTAssertEqual(currentVisual.detachedRenderers.count, 1, "The surviving registration must still observe its own privacy changes")
        currentPrompt.revealLiveScreen()
        XCTAssertEqual(currentVisual.attachedRenderers.count, 2)
    }

    func test_sidecarWaitingVisibilityCannotRetireAReentrantCurrentFrame() async throws {
        let (session, visual, _) = try await makePrivacyFixture()
        let owner = NSObject()
        var restored = false
        let observation = session.observeRemoteScreenVisibility(owner: owner) {
            if !restored && session.computerUseVisualSidecarState == .waitingForFreshFrame {
                restored = true
                visual.onFirstVideoFrame?()
            }
        }
        defer { session.removeRemoteScreenVisibilityObserver(observation); withExtendedLifetime(owner) {}; session.reset() }
        visual.onVideoFrameUnavailable?()
        XCTAssertTrue(restored)
        XCTAssertEqual(session.computerUseVisualSidecarState, .live)
        XCTAssertTrue(session.hasReceivedVideoFrame, "The previous waiting callback must not clear its replacement's frame")
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
        XCTAssertTrue(session.isComputerUsePromptTransportReady)
    }

    func test_privacyShieldReleasesAllSourcesAndBlocksInputUntilExplicitReveal() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture()
        defer { session.reset() }
        let generation = session.remoteInputGeneration
        let hardware = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        let keyboard = try XCTUnwrap(session.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: generation))
        let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: hardware)
        session.send(.key(usage: 5, down: true, modifiers: 0), from: keyboard)
        session.send(.pointer(x: 20, y: 30, buttons: 1), from: pointer)
        session.send(.scroll(x: 20, y: 30, dx: 1, dy: 2, phase: .begin), from: pointer)
        session.toggleSoftModifier(.shift)
        let beforeShield = visual.sentMessages.count

        XCTAssertTrue(prompt.sendPrompt("Draft an email to Alex."))
        XCTAssertTrue(prompt.isLiveScreenPrivacyShielded)
        XCTAssertTrue(session.isRemoteScreenObscured)
        XCTAssertTrue(session.isRemoteScreenSessionReady, "Keep the explicit reveal control reachable")
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        XCTAssertEqual(session.softModifierMask, 0)
        let releases = Array(visual.sentMessages.dropFirst(beforeShield).map(\.message))
        XCTAssertEqual(releases.count, 5)
        XCTAssertEqual(releases.compactMap { message -> Int? in
            if case let .key(usage, down, _) = message, !down { return usage }
            return nil
        }.sorted(), [4, 5, SoftModifier.shift.hidUsage].sorted())
        XCTAssertTrue(releases.contains { if case .pointer(x: 20, y: 30, buttons: 0) = $0 { return true }; return false })
        XCTAssertTrue(releases.contains { if case .scroll(x: 20, y: 30, dx: 0, dy: 0, phase: .end) = $0 { return true }; return false })
        let count = visual.sentMessages.count
        let hiddenGeneration = session.remoteInputGeneration
        for kind: RemoteInputSourceKind in [.hardwareKeyboard, .softKeyboard, .softModifiers, .pointer] {
            XCTAssertNil(session.beginRemoteInputSource(kind, expectedInputGeneration: hiddenGeneration))
        }
        session.send(.key(usage: 6, down: true, modifiers: 0))
        session.send(.text("hidden text"))
        session.send(.pointer(x: 20, y: 30, buttons: 1))
        session.send(.scroll(x: 20, y: 30, dx: 1, dy: 2, phase: .begin))
        session.toggleSoftModifier(.shift)
        XCTAssertEqual(visual.sentMessages.count, count)
        XCTAssertTrue(session.computerUseSession === prompt)
        XCTAssertTrue(prompt.isConnected); XCTAssertTrue(session.isComputerUsePromptTransportReady)
        XCTAssertEqual(session.computerUseVisualSidecarState, .live)
        XCTAssertTrue(visual.disconnectReasons.isEmpty)

        prompt.revealLiveScreen()
        XCTAssertFalse(session.isRemoteScreenObscured); XCTAssertTrue(session.hasInteractiveRemoteScreen)
        XCTAssertEqual(session.remoteInputGeneration, hiddenGeneration)
        session.send(.text("late callback"), from: keyboard)
        session.send(.key(usage: 4, down: true, modifiers: 0), from: hardware)
        session.send(.pointer(x: 20, y: 30, buttons: 1), from: pointer)
        session.send(.text("old generation"), expectedInputGeneration: generation)
        session.endRemoteInputSource(hardware); session.endRemoteInputSource(keyboard); session.endRemoteInputSource(pointer)
        XCTAssertEqual(visual.sentMessages.count, count)
        let replacement = try XCTUnwrap(session.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: hiddenGeneration))
        session.send(.text("visible input"), from: replacement)
        XCTAssertEqual(visual.sentMessages.count, count + 1)
    }

    func test_privacyCleanupRejectsReentrantInputAndHonorsAConcurrentReveal() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture()
        defer { visual.onSend = nil; session.reset() }
        let generation = session.remoteInputGeneration
        let source = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        let count = visual.sentMessages.count
        var cleanupCalls = 0
        visual.onSend = { message in
            guard case .key(usage: 4, down: false, modifiers: _) = message else { return }
            cleanupCalls += 1
            session.send(.text("inside cleanup"))
            XCTAssertNil(session.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: session.remoteInputGeneration))
            prompt.revealLiveScreen()
            session.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        }
        XCTAssertTrue(prompt.sendPrompt("Draft an email to Alex."))
        XCTAssertEqual(cleanupCalls, 1); XCTAssertEqual(visual.sentMessages.count, count + 1)
        XCTAssertFalse(prompt.isLiveScreenPrivacyShielded); XCTAssertFalse(session.isRemoteScreenObscured)
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        XCTAssertFalse(session.isRemoteInputSourceCurrent(source))
        XCTAssertTrue(prompt.isConnected); XCTAssertTrue(session.computerUseSession === prompt)
    }

    func test_privacyEdgeDuringSourceCleanupPreservesEveryOwnedRelease() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture()
        defer { visual.onSend = nil; session.reset() }
        let generation = session.remoteInputGeneration
        let source = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        session.send(.key(usage: 5, down: true, modifiers: 0), from: source)
        let count = visual.sentMessages.count
        visual.onSend = { message in
            guard case .key(usage: 4, down: false, modifiers: _) = message else { return }
            XCTAssertTrue(prompt.sendPrompt("Draft an email to Alex."))
            XCTAssertEqual(session.remoteInputGeneration, generation, "Remaining releases still own this scope")
            session.send(.text("hidden during deferred cleanup"))
            XCTAssertNil(session.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: generation))
        }
        session.endRemoteInputSource(source)
        let releases = Array(visual.sentMessages.dropFirst(count).map(\.message))
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases.compactMap { message -> Int? in
            if case let .key(usage, down, _) = message, !down { return usage }
            return nil
        }, [4, 5])
        XCTAssertTrue(session.isRemoteScreenObscured); XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        XCTAssertTrue(prompt.isConnected); XCTAssertTrue(session.computerUseSession === prompt)
    }

    func test_disconnectDuringPrivacyCleanupCannotSubmitTheInterruptedPrompt() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture()
        defer { visual.onSend = nil; session.reset() }
        let source = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        visual.onSend = { message in
            guard case .key(usage: 4, down: false, modifiers: _) = message else { return }
            session.reset()
        }
        XCTAssertFalse(prompt.sendPrompt("Draft an email to Alex."))
        XCTAssertFalse(prompt.hasActivePrompt); XCTAssertFalse(prompt.isConnected)
        XCTAssertTrue(prompt.messages.isEmpty)
        XCTAssertNil(session.computerUseSession)
        XCTAssertFalse(session.isRemoteScreenObscured)
        XCTAssertEqual(session.state, .idle)
    }

    func test_retiredPromptPrivacyCallbackCannotCoverAReplacementRemoteSession() async throws {
        let connected = expectation(description: "replacement remote transport")
        let ordinary = RecordingTargetTransport(connected: connected)
        let (session, _, prompt) = try await makePrivacyFixture(ordinaryTransport: ordinary)
        defer { session.reset() }
        let oldCallback = try XCTUnwrap(prompt.onRemoteScreenObscurationChange)
        XCTAssertTrue(prompt.sendPrompt("Draft an email to Alex."))
        XCTAssertTrue(session.isRemoteScreenObscured)
        session.reset()
        XCTAssertNil(prompt.onRemoteScreenObscurationChange)
        XCTAssertFalse(session.isRemoteScreenObscured)
        session.connect(code: "654321")
        await fulfillment(of: [connected], timeout: 1)
        ordinary.onHostHello?(compatibleComputerUseHello())
        ordinary.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); ordinary.onFirstVideoFrame?()
        let generation = session.remoteInputGeneration
        oldCallback()
        XCTAssertTrue(prompt.isLiveScreenPrivacyShielded)
        XCTAssertFalse(session.isRemoteScreenObscured); XCTAssertTrue(session.hasInteractiveRemoteScreen)
        XCTAssertEqual(session.remoteInputGeneration, generation)
        let count = ordinary.sentMessages.count
        session.send(.text("replacement input"))
        XCTAssertEqual(ordinary.sentMessages.count, count + 1)
    }

    func test_remoteKeyboardFocusRequestIsScopedOneUseAndPreservesPointerOwnership() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture(localPendingStore: KeyboardHandoffPendingStore())
        defer { session.reset() }
        XCTAssertFalse(session.allowsRemoteKeyboardInput, "AI chat owns typing before Take control")
        XCTAssertTrue(prompt.sendPrompt("Find movie tickets."))
        prompt.takeControl()
        XCTAssertTrue(session.allowsRemoteKeyboardInput)
        XCTAssertFalse(prompt.hasHostPauseAcknowledgement, "Direct takeover remains available before TLS confirmation")
        let generation = session.remoteInputGeneration, initial = session.remoteKeyboardCaptureIdentity
        let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.send(.pointer(x: 20, y: 30, buttons: 1), from: pointer)
        let count = visual.sentMessages.count
        session.requestRemoteKeyboardFocus(expectedInputGeneration: UUID())
        XCTAssertEqual(session.remoteKeyboardCaptureIdentity, initial)
        session.requestRemoteKeyboardFocus(expectedInputGeneration: generation)
        let requested = session.remoteKeyboardCaptureIdentity
        XCTAssertNotEqual(requested, initial)
        XCTAssertEqual(session.remoteInputGeneration, generation)
        XCTAssertFalse(session.consumeRemoteKeyboardFocusRequest(initial))
        XCTAssertTrue(session.consumeRemoteKeyboardFocusRequest(requested))
        XCTAssertFalse(session.consumeRemoteKeyboardFocusRequest(requested))
        XCTAssertTrue(session.isRemoteInputSourceCurrent(pointer))
        XCTAssertEqual(visual.sentMessages.count, count)

        session.requestRemoteKeyboardFocus(expectedInputGeneration: generation)
        let pending = session.remoteKeyboardCaptureIdentity
        prompt.resumeAI()
        XCTAssertFalse(session.allowsRemoteKeyboardInput)
        XCTAssertFalse(session.consumeRemoteKeyboardFocusRequest(pending))
        prompt.takeControl()
        XCTAssertFalse(session.consumeRemoteKeyboardFocusRequest(pending), "A later pause cannot inherit an old focus request")
        XCTAssertTrue(session.isRemoteInputSourceCurrent(pointer))
        XCTAssertEqual(visual.sentMessages.count, count)
    }

    func test_resumeRetiresKeyboardImmediatelyAcrossAnotherPauseAndKeepsTLSAndPointer() async throws {
        let (session, visual, prompt) = try await makePrivacyFixture(localPendingStore: KeyboardHandoffPendingStore())
        defer { session.reset() }
        XCTAssertTrue(prompt.sendPrompt("Find concert tickets.")); prompt.takeControl()
        let generation = session.remoteInputGeneration, capture = session.remoteKeyboardCaptureIdentity
        let hardware = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        let field = SoftKeyboardCapture.CaptureField()
        let keyboardWindow = try RemoteKeyboardTestWindow()
        defer { keyboardWindow.close() }
        try keyboardWindow.focus(field, in: session)
        XCTAssertTrue(field.canSendInput)
        let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: hardware)
        session.toggleSoftModifier(.shift)
        session.send(.pointer(x: 20, y: 30, buttons: 1), from: pointer)
        let count = visual.sentMessages.count

        prompt.resumeAI()
        XCTAssertFalse(session.allowsRemoteKeyboardInput)
        XCTAssertFalse(field.canSendInput)
        XCTAssertFalse(session.isRemoteInputSourceCurrent(hardware))
        XCTAssertNotEqual(session.remoteKeyboardCaptureIdentity, capture)
        XCTAssertEqual(session.remoteInputGeneration, generation)
        XCTAssertEqual(session.softModifierMask, 0)
        let released = visual.sentMessages.dropFirst(count).map(\.message)
        XCTAssertEqual(released.count, 2)
        XCTAssertEqual(released.compactMap { message -> Int? in
            if case let .key(usage, down, _) = message, !down { return usage }; return nil
        }.sorted(), [4, SoftModifier.shift.hidUsage].sorted())

        // No actor suspension or SwiftUI update between the two transitions.
        prompt.takeControl()
        XCTAssertTrue(session.allowsRemoteKeyboardInput)
        XCTAssertFalse(field.canSendInput)
        field.bindSession(session); field.insertText("late login text")
        session.send(.key(usage: 4, down: true, modifiers: 0), from: hardware)
        session.endRemoteInputSource(hardware)
        XCTAssertEqual(visual.sentMessages.count, count + 2)
        let replacement = SoftKeyboardCapture.CaptureField()
        try keyboardWindow.focus(replacement, in: session); replacement.insertText("new explicit input")
        XCTAssertTrue(replacement.canSendInput)
        XCTAssertEqual(visual.sentMessages.count, count + 3)
        XCTAssertTrue(session.isRemoteInputSourceCurrent(pointer))
        XCTAssertTrue(prompt.isConnected); XCTAssertTrue(session.computerUseSession === prompt)
        XCTAssertTrue(session.isComputerUsePromptTransportReady)
        XCTAssertEqual(session.computerUseVisualSidecarState, .live)
        XCTAssertTrue(visual.disconnectReasons.isEmpty)

        let current = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 5, down: true, modifiers: 0), from: current)
        let beforeStop = visual.sentMessages.count
        prompt.stop()
        XCTAssertFalse(session.allowsRemoteKeyboardInput)
        XCTAssertFalse(replacement.canSendInput)
        XCTAssertFalse(session.isRemoteInputSourceCurrent(current))
        XCTAssertEqual(visual.sentMessages.count, beforeStop + 1)
        XCTAssertTrue(session.isRemoteInputSourceCurrent(pointer))
        field.stopCapture(); replacement.stopCapture()
    }

    func test_keyboardCleanupCannotOverwriteAReentrantTakeControlWithResume() async throws {
        let store = KeyboardHandoffPendingStore()
        let (session, visual, prompt) = try await makePrivacyFixture(localPendingStore: store)
        defer { visual.onSend = nil; session.reset() }
        XCTAssertTrue(prompt.sendPrompt("Find travel tickets.")); prompt.takeControl()
        let source = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        let before = session.remoteKeyboardCaptureIdentity
        var releases = 0
        visual.onSend = { message in
            guard case .key(usage: 4, down: false, modifiers: _) = message else { return }
            releases += 1
            prompt.takeControl()
            XCTAssertNil(session.beginRemoteInputSource(.hardwareKeyboard,
                expectedInputGeneration: session.remoteInputGeneration))
        }
        prompt.resumeAI()
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(prompt.state, .paused)
        XCTAssertEqual(prompt.statusText, "Take Control requested — waiting for your Mac…")
        XCTAssertTrue(session.allowsRemoteKeyboardInput)
        XCTAssertNotEqual(session.remoteKeyboardCaptureIdentity, before)
        XCTAssertFalse(session.isRemoteInputSourceCurrent(source))
        XCTAssertTrue(prompt.isConnected)
    }

    private func makePrivacyFixture(ordinaryTransport: RecordingTargetTransport? = nil,
                                   localPendingStore: any ComputerUsePendingPromptStoring = EmptyComputerUsePendingPromptStore()) async throws
        -> (SessionModel, RecordingTargetTransport, ComputerUseSessionModel) {
        let connected = expectation(description: "privacy visual transport")
        let visual = RecordingTargetTransport(connected: connected), channel = IdleComputerUseSessionChannel()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
            transportFactory: { ordinaryTransport ?? visual }, computerUseVisualTransportFactory: { visual },
            localAccountBindingValidator: { _ in }, localComputerUseChannelConnector: { _, _, _, _, _, _, _ in channel },
            localPendingStore: localPendingStore, accountChangeNotificationCenter: NotificationCenter())
        session.connect(code: "123456", experience: .computerUse, computerUseHostID: "HOST-B", hostName: "Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
            localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
        await fulfillment(of: [connected], timeout: 1)
        let prompt = try XCTUnwrap(session.computerUseSession)
        visual.onHostHello?(compatibleComputerUseHello())
        visual.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); visual.onFirstVideoFrame?()
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
        return (session, visual, prompt)
    }

    func test_rendererLossReleasesRemoteControlsAndRestoresWithoutAnotherHello() async throws {
        let connected = expectation(description: "remote transport")
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
                                 transportFactory: { transport })
        let renderer = RecordingVideoSurface()
        model.attachVideoRenderer(renderer)
        XCTAssertFalse(model.shouldPrepareRemoteScreenRenderer)
        model.connect(code: "123456")
        defer { model.reset(); model.detachVideoRenderer(renderer) }
        XCTAssertTrue(model.shouldPrepareRemoteScreenRenderer)
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertTrue(transport.attachedRenderers.first === renderer)
        transport.onHostHello?(compatibleComputerUseHello())
        let display = DisplayInfo(w: 800, h: 600, scale: 1)
        transport.onDisplay?(display); transport.onFirstVideoFrame?()
        let oldGeneration = model.remoteInputGeneration
        let source = try XCTUnwrap(model.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: oldGeneration))
        model.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        transport.onVideoFrameUnavailable?()
        guard case let .key(usage, down, _) = transport.sentMessages.last?.message else { return XCTFail("Release held key") }
        XCTAssertEqual(usage, 4); XCTAssertFalse(down)
        XCTAssertFalse(model.hasInteractiveRemoteScreen); XCTAssertTrue(model.shouldPrepareRemoteScreenRenderer)
        XCTAssertEqual(model.display, display); XCTAssertEqual(model.state, .connected)
        XCTAssertNotEqual(model.remoteInputGeneration, oldGeneration)
        let count = transport.sentMessages.count, unavailableGeneration = model.remoteInputGeneration
        transport.onVideoFrameUnavailable?()
        XCTAssertEqual(model.remoteInputGeneration, unavailableGeneration)
        transport.onFirstVideoFrame?()
        XCTAssertTrue(model.hasInteractiveRemoteScreen)
        model.send(.text("stale"), expectedInputGeneration: oldGeneration)
        XCTAssertEqual(transport.sentMessages.count, count)
        XCTAssertTrue(transport.disconnectReasons.isEmpty)
    }

    func test_sidecarPreparesRendererAndTransfersItAcrossTransportReplacement() async {
        let firstConnected = expectation(description: "first"), nextConnected = expectation(description: "next")
        let first = RecordingTargetTransport(connected: firstConnected), next = RecordingTargetTransport(connected: nextConnected)
        var candidates = [first, next]
        let sidecar = ComputerUseVisualSidecar(transportFactory: { candidates.removeFirst() })
        let renderer = RecordingVideoSurface(), replacement = RecordingVideoSurface()
        sidecar.attachVideoRenderer(renderer)
        sidecar.start(pairingCode: "123456", expectedHostID: "HOST-B")
        await fulfillment(of: [firstConnected], timeout: 1)
        XCTAssertEqual(sidecar.state, .connecting)
        XCTAssertTrue(first.attachedRenderers.first === renderer)
        first.onHostHello?(compatibleComputerUseHello())
        first.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); first.onFirstVideoFrame?()
        XCTAssertEqual(sidecar.state, .live)
        sidecar.stop(preserveConfiguration: true); sidecar.resume()
        await fulfillment(of: [nextConnected], timeout: 1)
        XCTAssertTrue(first.detachedRenderers.first === renderer)
        XCTAssertTrue(next.attachedRenderers.first === renderer)
        first.onVideoFrameUnavailable?(); first.onFirstVideoFrame?()
        XCTAssertEqual(sidecar.state, .connecting)
        sidecar.attachVideoRenderer(replacement); sidecar.detachVideoRenderer(renderer)
        XCTAssertTrue(next.detachedRenderers.last === renderer)
        XCTAssertTrue(next.attachedRenderers.last === replacement)
        XCTAssertEqual(next.detachedRenderers.count, 1, "Old view cleanup must not detach its replacement")
        sidecar.stop(preserveConfiguration: false)
        XCTAssertTrue(next.detachedRenderers.last === replacement)
        sidecar.detachVideoRenderer(replacement)
    }

    func test_sidecarRendererCleanupCannotWithdrawAReplacementPresentation() async {
        let connected = expectation(description: "visual transport")
        let visual = RecordingTargetTransport(connected: connected)
        let sidecar = ComputerUseVisualSidecar(transportFactory: { visual })
        sidecar.start(pairingCode: "123456", expectedHostID: "HOST-B")
        await fulfillment(of: [connected], timeout: 1)
        visual.onHostHello?(compatibleComputerUseHello())
        visual.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); visual.onFirstVideoFrame?()
        sidecar.onVideoFrameUnavailable = {
            visual.onInputUnavailable?()
            visual.onHostHello?(self.compatibleComputerUseHello())
            visual.onDisplay?(DisplayInfo(w: 900, h: 700, scale: 1)); visual.onFirstVideoFrame?()
        }
        visual.onVideoFrameUnavailable?()
        XCTAssertEqual(sidecar.state, .live)
        XCTAssertTrue(sidecar.sendDirectInput(.text("replacement presentation")))
        sidecar.onVideoFrameUnavailable = nil
        sidecar.stop(preserveConfiguration: false)
    }

    func test_sidecarRendererLossPreservesTLSAndRepublishesLayoutBeforeReadiness() async throws {
        let connected = expectation(description: "visual transport")
        let visual = RecordingTargetTransport(connected: connected), channel = IdleComputerUseSessionChannel()
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
            computerUseVisualTransportFactory: { visual }, localAccountBindingValidator: { _ in },
            localComputerUseChannelConnector: { _, _, _, _, _, _, _ in channel },
            localPendingStore: EmptyComputerUsePendingPromptStore(), accountChangeNotificationCenter: NotificationCenter())
        model.connect(code: "123456", experience: .computerUse, computerUseHostID: "HOST-B", hostName: "Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
            localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
        defer { model.reset() }
        await fulfillment(of: [connected], timeout: 1)
        let promptSession = try XCTUnwrap(model.computerUseSession)
        XCTAssertTrue(model.shouldPrepareRemoteScreenRenderer); XCTAssertFalse(model.hasInteractiveRemoteScreen)
        let renderer = RecordingVideoSurface()
        model.attachVideoRenderer(renderer)
        visual.onHostHello?(compatibleComputerUseHello())
        let display = DisplayInfo(w: 800, h: 600, scale: 1)
        visual.onDisplay?(display); visual.onFirstVideoFrame?()
        model.toggleSoftModifier(.shift)
        let previous = model.remoteInputGeneration
        visual.onVideoFrameUnavailable?()
        guard case let .key(usage, down, _) = visual.sentMessages.last?.message else { return XCTFail("Release under the old input scope") }
        XCTAssertEqual(usage, SoftModifier.shift.hidUsage); XCTAssertFalse(down)
        XCTAssertEqual(model.computerUseVisualSidecarState, .waitingForFreshFrame)
        XCTAssertFalse(model.hasInteractiveRemoteScreen); XCTAssertTrue(model.shouldPrepareRemoteScreenRenderer)
        XCTAssertEqual(model.display, display); XCTAssertFalse(model.hasReceivedVideoFrame)
        XCTAssertTrue(model.mayRevealRemoteScreenPixels, "The authenticated display remains usable for the next renderer frame")
        XCTAssertEqual(model.softModifierMask, 0)
        XCTAssertTrue(model.computerUseSession === promptSession); XCTAssertTrue(promptSession.isConnected)
        XCTAssertTrue(model.isComputerUsePromptTransportReady)
        visual.onFirstVideoFrame?()
        XCTAssertEqual(model.display, display); XCTAssertTrue(model.hasInteractiveRemoteScreen)
        let count = visual.sentMessages.count
        model.send(.text("old callback"), expectedInputGeneration: previous)
        XCTAssertEqual(visual.sentMessages.count, count)
        XCTAssertTrue(model.computerUseSession === promptSession)
        XCTAssertTrue(visual.disconnectReasons.isEmpty)
        model.detachVideoRenderer(renderer)
    }

    func test_captureInvalidationNegotiatesOnlyWithScopedInputAndDecodesTheSelectedMode() throws {
        let hello = DirectInputHello(clientID: UUID(), revision: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControlMessage.hello(proto: 1).encoded(seq: 0, ts: 0, inputHello: hello)) as? [String: Any])
        XCTAssertEqual((object["caps"] as? [String: Any])?["inputInvalidation"] as? Int, 1)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: ControlMessage.hello(proto: 1).encoded(seq: 0, ts: 0)) as? [String: Any])
        XCTAssertNil(legacy["caps"])
        let ack = DirectInputAcknowledgement(hello: hello, hostID: UUID(), generation: 1)
        let bytes = try JSONSerialization.data(withJSONObject: ["t": "hello_ack", "proto": 1,
            "caps": ["inputSessions": 1, "inputInvalidation": 1], "inputSession": try XCTUnwrap(DirectInputWire.object(ack))])
        guard case .helloAck(let decoded) = HostMessage.decode(bytes) else { return XCTFail("Expected selected capability") }
        XCTAssertEqual(decoded.inputInvalidation, 1)
        var client = DirectInputClientState(clientID: hello.clientID)
        client.connectionChanged(connected: true); client.markHelloSent(hello)
        XCTAssertEqual(client.accept(version: decoded.inputSessions, acknowledgement: decoded.inputSession,
            inputInvalidation: decoded.inputInvalidation), .accepted)
        XCTAssertEqual(client.invalidate(ack), .accepted)
    }

    func test_captureInvalidationDecoderRejectsMalformedScopeAndCapability() throws {
        let ack = DirectInputAcknowledgement(hello: .init(clientID: UUID(), revision: 1), hostID: UUID(), generation: 1)
        let metadata = try XCTUnwrap(DirectInputWire.object(ack))
        let bytes = try JSONSerialization.data(withJSONObject: ["t": "input_unavailable", "inputSession": metadata])
        XCTAssertEqual(HostMessage.decode(bytes), .inputUnavailable(ack))
        var invalidGeneration = metadata; invalidGeneration["generation"] = true
        for value: Any in [NSNull(), "invalid", 1, ["version": 1], invalidGeneration] {
            let malformed = try JSONSerialization.data(withJSONObject: ["t": "input_unavailable", "inputSession": value])
            guard case .bye = HostMessage.decode(malformed) else { return XCTFail("Malformed revocation must close the transport") }
        }
        guard case .bye = HostMessage.decode(Data(#"{"t":"input_unavailable"}"#.utf8)) else { return XCTFail("Missing scope") }
        for value: Any in [true, "1", -1, 0.5, 2, NSNull()] {
            let malformed = try JSONSerialization.data(withJSONObject: ["t": "hello_ack", "proto": 1,
                "caps": ["inputSessions": 1, "inputInvalidation": value], "inputSession": metadata])
            guard case .bye = HostMessage.decode(malformed) else { return XCTFail("Malformed capability") }
        }
    }

    func test_captureInvalidationRetiresPresentationAndRequiresANewHelloRevision() throws {
        var client = DirectInputClientState(), presentation = RemoteInputPresentationState()
        client.connectionChanged(connected: true)
        let hello = try XCTUnwrap(client.helloToSend); client.markHelloSent(hello)
        let old = DirectInputAcknowledgement(hello: hello, hostID: UUID(), generation: 1)
        XCTAssertEqual(client.accept(version: 1, acknowledgement: old, inputInvalidation: 1), .accepted)
        presentation.begin(old)
        let oldFrame = try XCTUnwrap(presentation.armProbe())
        XCTAssertNotNil(client.authorizeNextInput())
        XCTAssertEqual(client.invalidate(.init(hello: hello, hostID: UUID(), generation: 1)), .ignored)
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(client.invalidate(old), .accepted)
        XCTAssertTrue(presentation.invalidate())
        XCTAssertFalse(client.isReady); XCTAssertNil(client.authorizeNextInput())
        XCTAssertFalse(presentation.acceptsFrame(oldFrame)); XCTAssertFalse(presentation.matches(old))
        let nextHello = try XCTUnwrap(client.helloToSend)
        XCTAssertEqual(nextHello.clientID, hello.clientID); XCTAssertEqual(nextHello.revision, 2)
        XCTAssertEqual(client.invalidate(old), .ignored)
        XCTAssertEqual(client.helloToSend, nextHello, "Duplicate events must not restart the handshake deadline")
        client.markHelloSent(nextHello)
        XCTAssertEqual(client.accept(version: 1, acknowledgement: old, inputInvalidation: 1), .ignored)
        let next = DirectInputAcknowledgement(hello: nextHello, hostID: UUID(), generation: 2)
        XCTAssertEqual(client.accept(version: 1, acknowledgement: next, inputInvalidation: 1), .accepted)
        presentation.begin(next)
        let newFrame = try XCTUnwrap(presentation.armProbe())
        XCTAssertFalse(presentation.matches(old)); XCTAssertFalse(presentation.acceptsFrame(oldFrame))
        XCTAssertTrue(presentation.acceptsFrame(newFrame))
        XCTAssertEqual(client.invalidate(old), .ignored)
        XCTAssertTrue(presentation.matches(next)); XCTAssertTrue(client.isReady)
        XCTAssertEqual(client.authorizeNextInput(), .scoped(.init(hostID: next.hostID, generation: next.generation, sequence: 1)))
    }

    func test_captureInvalidationRequiresTheNegotiatedModeAndCannotDowngradeIt() throws {
        for negotiated in [0, 1] {
            var client = DirectInputClientState()
            client.connectionChanged(connected: true)
            let hello = try XCTUnwrap(client.helloToSend); client.markHelloSent(hello)
            let ack = DirectInputAcknowledgement(hello: hello, hostID: UUID(), generation: 1)
            XCTAssertEqual(client.accept(version: 1, acknowledgement: ack, inputInvalidation: negotiated), .accepted)
            XCTAssertEqual(client.accept(version: 1, acknowledgement: ack, inputInvalidation: 1 - negotiated), .invalid)
            XCTAssertEqual(client.invalidate(ack), negotiated == 1 ? .accepted : .invalid)
            client.close()
            XCTAssertEqual(client.invalidate(ack), .ignored)
            XCTAssertFalse(client.connectionChanged(connected: true))
        }
    }

    func test_localRecoveryReadFailureStopsBeforeHandshakeOrVisualConnection() async throws {
        let unexpectedTransport = RecordingTargetTransport(connected: XCTestExpectation(description: "unexpected connection"))
        let expectedBinding = accountBinding
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
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
            let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
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
            let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), computerUseVisualTransportFactory: { visual }, localAccountBindingValidator: { _ in },
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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })

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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })

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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })

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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })

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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
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
        XCTAssertEqual(sidecar.state, .waitingForFreshFrame)
        transport.onFirstVideoFrame?()
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
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
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

    func test_remoteSessionRecoveryRequiresCurrentHelloDisplayAndFrameAndRetiresInputGeneration() async throws {
        let connected = expectation(description: "remote transport connected")
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { model.reset() }
        model.connect(code: "123456")
        await fulfillment(of: [connected], timeout: 1)
        transport.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); transport.onFirstVideoFrame?()
        XCTAssertFalse(model.hasInteractiveRemoteScreen); XCTAssertNil(model.display)
        model.send(.text("before hello")); model.toggleSoftModifier(.cmd)
        XCTAssertTrue(transport.sentMessages.isEmpty); XCTAssertEqual(model.softModifierMask, 0)
        transport.onHostHello?(compatibleComputerUseHello())
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        transport.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); transport.onFirstVideoFrame?()
        XCTAssertTrue(model.hasInteractiveRemoteScreen)
        let oldGeneration = model.remoteInputGeneration
        model.toggleSoftModifier(.cmd); XCTAssertNotEqual(model.softModifierMask, 0)
        let beforeLoss = transport.sentMessages.count
        transport.onInputUnavailable?()
        XCTAssertFalse(model.hasInteractiveRemoteScreen); XCTAssertFalse(model.hasReceivedVideoFrame)
        XCTAssertNil(model.display); XCTAssertEqual(model.softModifierMask, 0)
        XCTAssertNotEqual(model.remoteInputGeneration, oldGeneration)
        XCTAssertEqual(transport.sentMessages.count, beforeLoss, "Loss discards local holds without posting a release")
        transport.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); transport.onFirstVideoFrame?()
        XCTAssertNil(model.display); XCTAssertFalse(model.hasReceivedVideoFrame)
        model.send(.text("during recovery")); XCTAssertEqual(transport.sentMessages.count, beforeLoss)
        transport.onHostHello?(compatibleComputerUseHello())
        transport.onFirstVideoFrame?()
        XCTAssertFalse(model.hasInteractiveRemoteScreen, "The new frame still needs its current display")
        transport.onDisplay?(DisplayInfo(w: 1024, h: 768, scale: 2))
        XCTAssertTrue(model.hasInteractiveRemoteScreen)
        let afterHandshake = transport.sentMessages.count
        model.send(.key(usage: 4, down: false, modifiers: 0), expectedInputGeneration: oldGeneration)
        model.toggleSoftModifier(.cmd, expectedInputGeneration: oldGeneration)
        XCTAssertEqual(model.softModifierMask, 0)
        XCTAssertEqual(transport.sentMessages.count, afterHandshake)
        model.send(.text("current input"), expectedInputGeneration: model.remoteInputGeneration)
        XCTAssertEqual(transport.sentMessages.count, afterHandshake + 1)
        XCTAssertEqual(model.softModifierMask, 0)
    }

    func test_sidecarTransientRecoveryKeepsPromptTransportAndClearsLocalControls() async throws {
        let connected = expectation(description: "visual transport connected")
        let visual = RecordingTargetTransport(connected: connected), channel = IdleComputerUseSessionChannel()
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), computerUseVisualTransportFactory: { visual }, localAccountBindingValidator: { _ in },
            localComputerUseChannelConnector: { _, _, _, _, _, _, _ in channel },
            localPendingStore: EmptyComputerUsePendingPromptStore(), accountChangeNotificationCenter: NotificationCenter())
        defer { model.reset() }
        model.connect(code: "123456", experience: .computerUse, computerUseHostID: "HOST-B", hostName: "Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
            localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
        await fulfillment(of: [connected], timeout: 1)
        let promptSession = try XCTUnwrap(model.computerUseSession)
        visual.onHostHello?(compatibleComputerUseHello()); visual.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); visual.onFirstVideoFrame?()
        XCTAssertTrue(model.hasInteractiveRemoteScreen); XCTAssertTrue(model.isComputerUsePromptTransportReady)
        model.toggleSoftModifier(.shift)
        let oldGeneration = model.remoteInputGeneration, count = visual.sentMessages.count
        visual.onInputUnavailable?()
        XCTAssertEqual(model.computerUseVisualSidecarState, .connecting)
        XCTAssertFalse(model.hasInteractiveRemoteScreen); XCTAssertEqual(model.softModifierMask, 0); XCTAssertNil(model.display)
        XCTAssertTrue(model.computerUseSession === promptSession); XCTAssertTrue(promptSession.isConnected)
        XCTAssertTrue(model.isComputerUsePromptTransportReady); XCTAssertEqual(model.state, .connected)
        model.send(.text("no fallback through TLS")); XCTAssertEqual(visual.sentMessages.count, count)
        visual.onFirstVideoFrame?(); visual.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1))
        XCTAssertEqual(model.computerUseVisualSidecarState, .connecting)
        visual.onHostHello?(compatibleComputerUseHello()); visual.onDisplay?(DisplayInfo(w: 900, h: 700, scale: 1))
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        visual.onFirstVideoFrame?(); XCTAssertTrue(model.hasInteractiveRemoteScreen)
        let readyCount = visual.sentMessages.count
        model.send(.text("old keyboard callback"), expectedInputGeneration: oldGeneration)
        XCTAssertEqual(visual.sentMessages.count, readyCount)
        model.send(.text("current manual input"), expectedInputGeneration: model.remoteInputGeneration)
        XCTAssertEqual(visual.sentMessages.count, readyCount + 1)
        XCTAssertTrue(model.computerUseSession === promptSession); XCTAssertTrue(model.isComputerUsePromptTransportReady)
    }

    func test_applicationInactivityRetiresSidecarInputAndPreservesPromptSessionState() async throws {
        let connected = expectation(description: "visual transport connected")
        let visual = RecordingTargetTransport(connected: connected), channel = IdleComputerUseSessionChannel()
        let notifications = NotificationCenter()
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: notifications,
            computerUseVisualTransportFactory: { visual }, localAccountBindingValidator: { _ in },
            localComputerUseChannelConnector: { _, _, _, _, _, _, _ in channel },
            localPendingStore: EmptyComputerUsePendingPromptStore(), accountChangeNotificationCenter: NotificationCenter())
        defer { model.reset() }
        model.connect(code: "123456", experience: .computerUse, computerUseHostID: "HOST-B", hostName: "Mac",
            localComputerUseEndpoint: LocalComputerUseEndpoint(host: "127.0.0.1", port: 443),
            localCredentialID: String(repeating: "b", count: 64), localCloudAccountBinding: accountBinding)
        await fulfillment(of: [connected], timeout: 1)
        let promptSession = try XCTUnwrap(model.computerUseSession)
        visual.onHostHello?(compatibleComputerUseHello()); visual.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); visual.onFirstVideoFrame?()
        let state = promptSession.state
        let source = try XCTUnwrap(model.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: model.remoteInputGeneration))
        model.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        guard case let .key(usage, down, _) = visual.sentMessages.last?.message else { return XCTFail("Release belongs on the visual transport") }
        XCTAssertEqual(usage, 4); XCTAssertFalse(down)
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        XCTAssertTrue(model.computerUseSession === promptSession); XCTAssertTrue(promptSession.isConnected)
        XCTAssertEqual(promptSession.state, state); XCTAssertTrue(model.isComputerUsePromptTransportReady)
        XCTAssertEqual(model.state, .connected); XCTAssertTrue(visual.disconnectReasons.isEmpty)
        let count = visual.sentMessages.count
        model.send(.text("inactive input must not use TLS"))
        XCTAssertEqual(visual.sentMessages.count, count)
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        visual.onFirstVideoFrame?()
        model.send(.key(usage: 4, down: false, modifiers: 0), from: source)
        XCTAssertEqual(visual.sentMessages.count, count)
        XCTAssertTrue(model.computerUseSession === promptSession); XCTAssertEqual(promptSession.state, state)
    }

    func test_presentationLeaseRejectsRetiredFramesAndReplacementProbeCallbacks() throws {
        var presentation = RemoteInputPresentationState()
        XCTAssertFalse(presentation.matches(nil)); XCTAssertNil(presentation.armProbe())
        let hello = DirectInputHello(clientID: UUID(), revision: 1)
        let first = DirectInputAcknowledgement(hello: hello, hostID: UUID(), generation: 1)
        presentation.begin(first)
        let oldFrame = try XCTUnwrap(presentation.armProbe())
        XCTAssertTrue(presentation.matches(first)); XCTAssertTrue(presentation.acceptsFrame(oldFrame))
        XCTAssertTrue(presentation.invalidate())
        XCTAssertFalse(presentation.matches(first)); XCTAssertFalse(presentation.acceptsFrame(oldFrame))
        let current = DirectInputAcknowledgement(hello: hello, hostID: UUID(), generation: 2)
        presentation.begin(current)
        let currentFrame = try XCTUnwrap(presentation.armProbe())
        XCTAssertFalse(presentation.matches(first)); XCTAssertFalse(presentation.matches(nil))
        XCTAssertTrue(presentation.matches(current)); XCTAssertFalse(presentation.acceptsFrame(oldFrame))
        XCTAssertTrue(presentation.acceptsFrame(currentFrame))
        presentation.retireProbe()
        let replacementTrackFrame = try XCTUnwrap(presentation.armProbe())
        XCTAssertFalse(presentation.acceptsFrame(currentFrame)); XCTAssertTrue(presentation.acceptsFrame(replacementTrackFrame))
        XCTAssertTrue(presentation.matches(current), "Track probe ownership is distinct from wire handshake identity")
        presentation.invalidate(); presentation.begin(nil)
        XCTAssertTrue(presentation.matches(nil)); XCTAssertFalse(presentation.acceptsFrame(replacementTrackFrame))
    }

    func test_displayDecoderKeepsCurrentInputScopeAndRejectsMalformedMetadata() throws {
        let ack = DirectInputAcknowledgement(hello: .init(clientID: UUID(), revision: 2), hostID: UUID(), generation: 3)
        let bytes = try JSONSerialization.data(withJSONObject: ["t": "display", "w": 1920, "h": 1080, "scale": 2,
            "inputSession": try XCTUnwrap(DirectInputWire.object(ack))])
        guard case .display(let display) = HostMessage.decode(bytes) else { return XCTFail("Expected scoped display") }
        XCTAssertEqual(display, DisplayInfo(w: 1920, h: 1080, scale: 2, inputSession: ack))
        for metadata: Any in [NSNull(), "invalid", ["version": 1]] {
            XCTAssertNil(HostMessage.decode(try JSONSerialization.data(withJSONObject: ["t": "display", "w": 1, "h": 1,
                "inputSession": metadata])))
        }
        guard case .display(let legacy) = HostMessage.decode(Data(#"{"t":"display","w":800,"h":600,"scale":1}"#.utf8)) else { return XCTFail("Expected legacy display") }
        XCTAssertNil(legacy.inputSession)
    }

    func test_displayDecoderRequiresAKnownFullSurfaceMappingAndValidGeometry() throws {
        let base: [String: Any] = ["t": "display", "w": 1728, "h": 1117, "scale": 2, "fullDisplaySurface": 1]
        for invalid: Any in [true, false, NSNull(), "1", 0, 2, 1.5, [1]] {
            var object = base; object["fullDisplaySurface"] = invalid
            guard case .bye = HostMessage.decode(try JSONSerialization.data(withJSONObject: object)) else {
                XCTFail("Unknown mapping must not fall back to legacy presentation"); continue
            }
        }
        for key in ["w", "h"] {
            for invalid: Any in [true, NSNull(), "1728", 0, -1, 1.5, Int64(Int32.max) + 1, 1e100] {
                var object = base; object[key] = invalid
                guard case .bye = HostMessage.decode(try JSONSerialization.data(withJSONObject: object)) else {
                    XCTFail("Reject unrepresentable geometry before any integer conversion"); continue
                }
            }
        }
        for invalid: Any in [true, NSNull(), "2", 0, -1, 0.5, 5, 1e100] {
            var object = base; object["scale"] = invalid
            guard case .bye = HostMessage.decode(try JSONSerialization.data(withJSONObject: object)) else {
                XCTFail("Reject invalid display density"); continue
            }
        }
    }

    func test_displayDecoderRetainsSurfaceMappingUnderItsInputScope() throws {
        let ack = DirectInputAcknowledgement(hello: .init(clientID: UUID(), revision: 2), hostID: UUID(), generation: 3)
        let bytes = try JSONSerialization.data(withJSONObject: ["t": "display", "w": 1728, "h": 1117, "scale": 2,
            "fullDisplaySurface": 1, "inputSession": try XCTUnwrap(DirectInputWire.object(ack))])
        guard case .display(let display) = HostMessage.decode(bytes) else { return XCTFail("Expected mapped display") }
        XCTAssertEqual(display, DisplayInfo(w: 1728, h: 1117, scale: 2, inputSession: ack, fullDisplaySurface: true))
        let legacyBytes = Data(#"{"t":"display","w":800,"h":600}"#.utf8)
        guard case .display(let legacy) = HostMessage.decode(legacyBytes) else { return XCTFail("Expected earlier layout") }
        XCTAssertFalse(legacy.fullDisplaySurface); XCTAssertEqual(legacy.scale, 1)
        var presentation = RemoteInputPresentationState()
        presentation.begin(ack)
        XCTAssertTrue(presentation.matches(display.inputSession))
        presentation.invalidate()
        XCTAssertFalse(presentation.matches(display.inputSession), "A retired layout cannot carry its mapping into a new scope")
    }

    func test_replacedRemoteTransportCannotChangeTheNewScreenReadiness() async {
        let firstConnected = expectation(description: "first"), secondConnected = expectation(description: "second")
        let first = RecordingTargetTransport(connected: firstConnected), second = RecordingTargetTransport(connected: secondConnected)
        var candidates = [first, second]
        let model = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { candidates.removeFirst() })
        defer { model.reset() }
        model.connect(code: "123456"); await fulfillment(of: [firstConnected], timeout: 1)
        first.onHostHello?(compatibleComputerUseHello()); first.onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); first.onFirstVideoFrame?()
        model.reset(); model.connect(code: "654321"); await fulfillment(of: [secondConnected], timeout: 1)
        second.onHostHello?(compatibleComputerUseHello()); second.onDisplay?(DisplayInfo(w: 1024, h: 768, scale: 2)); second.onFirstVideoFrame?()
        let generation = model.remoteInputGeneration
        first.onInputUnavailable?(); first.onHostHello?(compatibleComputerUseHello())
        first.onDisplay?(DisplayInfo(w: 1, h: 1, scale: 1)); first.onFirstVideoFrame?(); first.onDisconnect?("old close")
        XCTAssertTrue(model.hasInteractiveRemoteScreen); XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(model.display, DisplayInfo(w: 1024, h: 768, scale: 2)); XCTAssertEqual(model.remoteInputGeneration, generation)
    }

    func test_wireInputSessionMetadataIsOnlyAttachedToItsMessageKind() throws {
        let hello = DirectInputHello(clientID: UUID(), revision: 3)
        let stamp = DirectInputStamp(hostID: UUID(), generation: 2, sequence: 7)
        let helloBytes = ControlMessage.hello(proto: 1).encoded(seq: 0, ts: 1, inputHello: hello, inputStamp: stamp)
        let helloObject = try XCTUnwrap(JSONSerialization.jsonObject(with: helloBytes) as? [String: Any])
        XCTAssertEqual(DirectInputWire.decode(try XCTUnwrap(helloObject["inputSession"]), as: DirectInputHello.self), hello)
        let input: [ControlMessage] = [.pointer(x: 12, y: 34, buttons: 1), .key(usage: 4, down: true, modifiers: 0),
            .scroll(x: 12, y: 34, dx: 0, dy: 4, phase: .changed), .text("  e\u{301} 😀\n")]
        for message in input {
            let data = message.encoded(seq: 99, ts: 1, inputHello: hello, inputStamp: stamp)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(DirectInputWire.decode(try XCTUnwrap(object["inputSession"]), as: DirectInputStamp.self), stamp)
            XCTAssertEqual(object["s"] as? Int, 99, "The session sequence is distinct from the legacy envelope counter")
            if case .text(let value) = message { XCTAssertEqual(object["s2"] as? String, value) }
        }
        for message: ControlMessage in [.bye(reason: "done"), .qos(targetFps: 30, maxBitrateKbps: 1000, prefer: "auto")] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message.encoded(seq: 1, ts: 1, inputHello: hello, inputStamp: stamp)) as? [String: Any])
            XCTAssertNil(object["inputSession"])
        }
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: ControlMessage.text("legacy").encoded(seq: 1, ts: 1)) as? [String: Any])
        XCTAssertNil(legacy["inputSession"])
    }

    func test_hostInputAcknowledgementDecodingKeepsScopeAndRejectsMalformedClaims() throws {
        let hello = DirectInputHello(clientID: UUID(), revision: 2)
        let acknowledgement = DirectInputAcknowledgement(hello: hello, hostID: UUID(), generation: 4)
        let metadata = try XCTUnwrap(DirectInputWire.object(acknowledgement))
        let bytes = try JSONSerialization.data(withJSONObject: ["t": "hello_ack", "proto": 1,
            "caps": ["inputSessions": 1], "inputSession": metadata])
        guard case .helloAck(let decoded) = HostMessage.decode(bytes) else { return XCTFail("Expected scoped acknowledgement") }
        XCTAssertEqual(decoded.inputSessions, 1); XCTAssertEqual(decoded.inputSession, acknowledgement)
        var client = DirectInputClientState(clientID: hello.clientID)
        client.connectionChanged(connected: true); client.connectionChanged(connected: false); client.connectionChanged(connected: true)
        XCTAssertTrue(client.markHelloSent(try XCTUnwrap(client.helloToSend)))
        XCTAssertEqual(client.accept(version: decoded.inputSessions, acknowledgement: decoded.inputSession), .accepted)
        guard case .scoped(let stamp) = client.authorizeNextInput() else { return XCTFail("A current acknowledgement must permit scoped input") }
        XCTAssertEqual(stamp.hostID, acknowledgement.hostID); XCTAssertEqual(stamp.generation, 4); XCTAssertEqual(stamp.sequence, 1)
        for capability: Any in [true, "1", 0.5, -1, NSNull()] {
            let invalid = try JSONSerialization.data(withJSONObject: ["t": "hello_ack", "proto": 1, "caps": ["inputSessions": capability]])
            guard case .bye = HostMessage.decode(invalid) else { XCTFail("Malformed capability cannot fall back to legacy input"); continue }
        }
        for caps: Any in [NSNull(), "invalid", [1, 2]] {
            let invalid = try JSONSerialization.data(withJSONObject: ["t": "hello_ack", "proto": 1, "caps": caps])
            guard case .bye = HostMessage.decode(invalid) else { XCTFail("Invalid capability containers cannot become legacy readiness"); continue }
        }
        for field: Any in [NSNull(), "invalid", ["version": 1], metadata.merging(["generation": 0]) { _, new in new }] {
            let invalid = try JSONSerialization.data(withJSONObject: ["t": "hello_ack", "proto": 1, "caps": ["inputSessions": 1], "inputSession": field])
            guard case .bye = HostMessage.decode(invalid) else { XCTFail("Malformed acknowledgement cannot authorize input"); continue }
        }
        guard case .helloAck(let legacy) = HostMessage.decode(Data(#"{"t":"hello_ack","proto":1}"#.utf8)) else { return XCTFail("Legacy acknowledgement remains decodable") }
        XCTAssertEqual(legacy.inputSessions, 0); XCTAssertNil(legacy.inputSession)
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
private final class RecordingTargetTransport: VideoRenderingTransport {
    struct SentMessage {
        let message: ControlMessage
        let seq: UInt32
        let ts: UInt64
    }

    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onInputUnavailable: (@MainActor () -> Void)?
    var onVideoFrameUnavailable: (@MainActor () -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private(set) var attachedRenderers: [any RemoteVideoSurface] = []
    private(set) var detachedRenderers: [any RemoteVideoSurface] = []
    func attachVideoRenderer(_ renderer: any RemoteVideoSurface) { attachedRenderers.append(renderer) }
    var onDetachRenderer: (() -> Void)?
    func detachVideoRenderer(_ renderer: any RemoteVideoSurface) { detachedRenderers.append(renderer); onDetachRenderer?() }

    private let connected: XCTestExpectation
    private let disconnected: XCTestExpectation?
    private(set) var pairingCode: String?
    private(set) var expectedHostID: String?
    private(set) var sentMessages: [SentMessage] = []
    private(set) var disconnectReasons: [String] = []
    var onSend: ((ControlMessage) -> Void)?

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
        onSend?(message)
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

/// A single retained record lets the actual client control-intent persistence
/// compare against the preceding prompt. No Keychain or network access.
private final class KeyboardHandoffPendingStore: ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ComputerUsePendingPrompt?
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        guard current?.hostID == hostID, current?.pairingCode == pairingCode else { return nil }
        return current
    }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        lock.lock(); defer { lock.unlock() }; current = pending; return true
    }
    func remove(hostID: String) {
        lock.lock(); defer { lock.unlock() }
        if current?.hostID == hostID { current = nil }
    }
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
