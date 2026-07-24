import CloudKit
import Darwin
import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Regression tests for the permission-detection bugs that made the
/// menu bar app unusable: Accessibility granted in System Settings
/// but not reflected in `HostSession.permissions`, "Start listening"
/// stuck disabled, and therefore no private host advertisement reaching iOS.
@MainActor
final class HostSessionTests: XCTestCase {

    // MARK: Issue 1 — Accessibility grant must be picked up on refresh

    /// The user's exact complaint: "despite granting accessibility it
    /// still doesn't recognize it." Simulate the provider reporting
    /// `false` initially (at launch) and then `true` after the user
    /// flips the toggle in System Settings. Calling `refreshPermissions()`
    /// must pick up the new value without requiring an app restart.
    func test_refreshPermissions_picksUpAccessibilityGrantAfterRefresh() {
        let provider = MockPermissionsProvider()
        provider.accessibility = false
        provider.screenRecording = true
        provider.microphone = true
        let session = makeSession(provider)

        session.refreshPermissions()
        XCTAssertFalse(session.permissions.accessibility, "precondition: accessibility starts denied")
        XCTAssertFalse(session.permissions.ok)

        // User grants Accessibility in System Settings and returns
        // to the app — the AppDelegate's `didBecomeActive` observer
        // (or the Check again button) will call `refreshPermissions`.
        provider.accessibility = true
        session.refreshPermissions()

        XCTAssertTrue(session.permissions.accessibility)
        XCTAssertTrue(session.permissions.ok)
    }

    func test_refreshPermissions_picksUpScreenRecordingGrantAfterRefresh() {
        let provider = MockPermissionsProvider()
        provider.accessibility = true
        provider.screenRecording = false
        provider.microphone = true
        let session = makeSession(provider)

        session.refreshPermissions()
        XCTAssertFalse(session.permissions.screenRecording)

        provider.screenRecording = true
        session.refreshPermissions()

        XCTAssertTrue(session.permissions.screenRecording)
        XCTAssertTrue(session.permissions.ok)
    }

    // MARK: Issue 2 — Start button must become enabled once perms flip

    /// `MenuContent` disables "Start listening" via
    /// `.disabled(!session.permissions.ok)`, so the button's state
    /// is a direct function of `permissions.ok`. This test locks in
    /// that contract: the published value flips to `true` the moment
    /// both checks come back positive.
    func test_corePermissionsBecomeReadyWithoutMicrophoneAccess() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.refreshPermissions()
        XCTAssertFalse(session.permissions.ok)

        provider.screenRecording = true
        session.refreshPermissions()
        XCTAssertFalse(session.permissions.ok, "one grant is not enough")

        provider.accessibility = true
        session.refreshPermissions()
        XCTAssertTrue(session.permissions.ok, "screen and control should not be blocked by optional audio")
        XCTAssertFalse(session.permissions.audioEnabled)

        provider.microphone = true
        session.refreshPermissions()
        XCTAssertTrue(session.permissions.ok)
        XCTAssertTrue(session.permissions.audioEnabled)
    }

    /// Calling `start()` while permissions are denied must leave the
    /// session in an informative error state and *not* generate a
    /// private session binding.
    func test_start_whenPermissionsDenied_surfacesError() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.start()

        if case .error(let message) = session.state {
            XCTAssertTrue(message.contains("Accessibility") || message.contains("Screen Recording"),
                          "error should mention which permissions are needed")
        } else {
            XCTFail("expected .error, got \(session.state)")
        }
    }

    // MARK: Issue 3 — Listening must start once permissions are ok

    /// Once permissions are granted and the user clicks Start, the
    /// session must leave `.idle` and generate its internal routing binding so
    /// iOS can discover it automatically. We don't await the network
    /// round-trip — we only assert that `.starting` is entered and
    /// that the session is no longer idle.
    func test_start_whenPermissionsGranted_leavesIdle() {
        let provider = MockPermissionsProvider()
        provider.accessibility = true
        provider.screenRecording = true
        provider.microphone = true
        let session = makeSession(provider)

        session.start()

        XCTAssertNotEqual(session.state, .idle,
                          "session must leave .idle so an advertisement can be generated")
        if case .error(let msg) = session.state {
            XCTFail("expected non-error transition, got error: \(msg)")
        }

        session.stop()
    }

    func test_start_whenCorePermissionsGrantedAndMicrophoneDenied_stillLeavesIdle() {
        let provider = MockPermissionsProvider()
        provider.accessibility = true
        provider.screenRecording = true
        provider.microphone = false
        let session = makeSession(provider)

        session.start()

        XCTAssertNotEqual(session.state, .idle)
        if case .error(let message) = session.state {
            XCTFail("optional audio must not block listening: \(message)")
        }
        XCTAssertFalse(session.permissions.audioEnabled)

        session.stop()
    }

    func test_startWithEmptyDeviceIdentityFailsBeforeAdvertising() async throws {
        let provider = readyPermissionsProvider()
        let session = HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {},
            deviceIdentityProvider: { "" },
            allowsExternalComputerUseServices: false)

        session.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while session.state == .starting, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .error(let message) = session.state else {
            return XCTFail(
                "An empty host identity must fail before advertising; state=\(session.state)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("identity"))
        session.stop()
    }

    func test_hostMetadataAdvertisesOnlyActuallyEnabledAudio() {
        let provider = MockPermissionsProvider()
        provider.accessibility = true
        provider.screenRecording = true
        let session = makeSession(provider)

        session.refreshPermissions()
        XCTAssertEqual(session.hostMetadata()["audio"], "false")

        provider.microphone = true
        session.refreshPermissions()
        XCTAssertEqual(session.hostMetadata()["audio"], "true")
    }

    func test_start_retriesFromErrorAfterPermissionsAreGranted() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.start()
        if case .error = session.state {
            // Expected precondition.
        } else {
            XCTFail("expected missing permissions to enter .error, got \(session.state)")
        }

        provider.accessibility = true
        provider.screenRecording = true
        provider.microphone = true
        session.start()

        XCTAssertNotEqual(session.state, .idle)
        if case .error(let msg) = session.state {
            XCTFail("expected retry to leave error, got: \(msg)")
        }

        session.stop()
    }

    func test_shutdownWaitsForCanceledSignalingCleanup() async {
        let provider = readyPermissionsProvider()
        let started = AsyncLifecycleGate()
        let cleanupStarted = AsyncLifecycleGate()
        let releaseCleanup = AsyncLifecycleGate()
        let cleanupFinished = AsyncLifecycleGate()
        let session = makeSession(
            provider,
            signalingRunOverride: blockingSignalingRun(
                started: started,
                cleanupStarted: cleanupStarted,
                releaseCleanup: releaseCleanup,
                cleanupFinished: cleanupFinished))

        session.start()
        await started.wait()

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            await session.shutdown()
            shutdownReturned = true
        }

        await cleanupStarted.wait()
        XCTAssertFalse(
            shutdownReturned,
            "shutdown must retain and await the canceled task's CloudKit cleanup")

        await releaseCleanup.open()
        await shutdownTask.value

        XCTAssertTrue(shutdownReturned)
        let didFinishCleanup = await cleanupFinished.isOpen
        XCTAssertTrue(didFinishCleanup)
    }

    func test_shutdownKeepsSessionTransportOpenUntilComputerUseTeardownFinishes() async throws {
        let provider = readyPermissionsProvider()
        let signalingStarted = AsyncLifecycleGate()
        let signalingCleanupStarted = AsyncLifecycleGate()
        let releaseSignalingCleanup = AsyncLifecycleGate()
        let signalingCleanupFinished = AsyncLifecycleGate()
        let executionStarted = AsyncLifecycleGate()
        let channel = SessionTeardownOrderingComputerUseChannel()
        let executor = SessionSuspendingComputerUseExecutor(
            started: executionStarted)
        let ledgerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ledgerURL = ledgerDirectory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let session = HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {},
            deviceIdentityProvider: { "test-device-id" },
            computerUseManager: manager,
            signalingRunOverride: blockingSignalingRun(
                started: signalingStarted,
                cleanupStarted: signalingCleanupStarted,
                releaseCleanup: releaseSignalingCleanup,
                cleanupFinished: signalingCleanupFinished))
        let senderID = "F20EC3BA-677E-407A-BDFA-5E613DCA1784"
        let prompt = ComputerUseEnvelope(
            id: "session-shutdown-terminal",
            senderID: senderID,
            targetID: "EDBB4924-FBA9-4343-9B33-8A9A3D78D94D",
            pairingCode: "123456",
            sessionID: "SESSION-1",
            kind: .prompt,
            body: "Open Calculator")

        session.start()
        await signalingStarted.wait()
        manager.start(pairingCode: prompt.pairingCode)
        manager.authorizePeer(senderID: senderID)
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await executionStarted.wait()

        var shutdownReturned = false
        let shutdown = Task { @MainActor in
            await session.shutdown()
            shutdownReturned = true
        }

        await channel.waitForTerminalSend()
        var cleanupBegan = await signalingCleanupStarted.isOpen
        XCTAssertFalse(cleanupBegan)
        XCTAssertFalse(shutdownReturned)

        await channel.releaseTerminalSend()
        await channel.waitForReadySend()
        cleanupBegan = await signalingCleanupStarted.isOpen
        XCTAssertFalse(cleanupBegan)

        await channel.releaseReadySend()
        await channel.waitForStopPolling()
        cleanupBegan = await signalingCleanupStarted.isOpen
        XCTAssertFalse(
            cleanupBegan,
            "session signaling/LAN teardown must remain staged until polling stops")

        await channel.releaseStopPolling()
        await signalingCleanupStarted.wait()
        let didStopPolling = await channel.didStopPolling()
        XCTAssertTrue(didStopPolling)
        XCTAssertFalse(shutdownReturned)

        await releaseSignalingCleanup.open()
        await shutdown.value

        XCTAssertTrue(shutdownReturned)
        let didFinishCleanup = await signalingCleanupFinished.isOpen
        XCTAssertTrue(didFinishCleanup)
    }

    func test_terminationSequenceLaunchesReplacementOnlyAfterSignalingCleanup() async {
        let provider = readyPermissionsProvider()
        let started = AsyncLifecycleGate()
        let cleanupStarted = AsyncLifecycleGate()
        let releaseCleanup = AsyncLifecycleGate()
        let cleanupFinished = AsyncLifecycleGate()
        let session = makeSession(
            provider,
            signalingRunOverride: blockingSignalingRun(
                started: started,
                cleanupStarted: cleanupStarted,
                releaseCleanup: releaseCleanup,
                cleanupFinished: cleanupFinished))

        session.start()
        await started.wait()

        var replacementLaunchCount = 0
        let terminationTask = Task { @MainActor in
            await HostTerminationSequence.finish(
                session: session,
                relaunchAfterShutdown: true,
                launchReplacement: { replacementLaunchCount += 1 })
        }

        await cleanupStarted.wait()
        XCTAssertEqual(
            replacementLaunchCount,
            0,
            "the replacement must not overwrite the stable advertisement before old cleanup finishes")

        await releaseCleanup.open()
        await terminationTask.value

        XCTAssertEqual(replacementLaunchCount, 1)
        let didFinishCleanup = await cleanupFinished.isOpen
        XCTAssertTrue(didFinishCleanup)
    }

    func test_stopThenImmediateStartWaitsForOldSignalingCleanup() async {
        let provider = readyPermissionsProvider()
        let invocationCounter = AsyncInvocationCounter()
        let firstStarted = AsyncLifecycleGate()
        let firstCleanupStarted = AsyncLifecycleGate()
        let releaseFirstCleanup = AsyncLifecycleGate()
        let firstCleanupFinished = AsyncLifecycleGate()
        let secondStarted = AsyncLifecycleGate()
        let session = makeSession(
            provider,
            signalingRunOverride: { _ in
                let invocation = await invocationCounter.next()
                if invocation == 1 {
                    await firstStarted.open()
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        // Stop cancels the run and begins its bounded cleanup.
                    }
                    await firstCleanupStarted.open()
                    await releaseFirstCleanup.wait()
                    await firstCleanupFinished.open()
                } else {
                    await secondStarted.open()
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        // Test shutdown cancels the replacement run.
                    }
                }
            })

        session.start()
        await firstStarted.wait()

        session.stop()
        session.start()

        await firstCleanupStarted.wait()
        let replacementStartedBeforeCleanup = await secondStarted.isOpen
        XCTAssertFalse(
            replacementStartedBeforeCleanup,
            "an immediate restart must not publish before the old stable advertisement is cleaned up")

        await releaseFirstCleanup.open()
        await secondStarted.wait()

        let didFinishFirstCleanup = await firstCleanupFinished.isOpen
        XCTAssertTrue(didFinishFirstCleanup)
        let invocationCount = await invocationCounter.current
        XCTAssertEqual(invocationCount, 2)

        await session.shutdown()
    }

    func test_cloudAccountChangeClosesSignalingBeforeComputerUseDeliveryFinishes() async throws {
        let provider = readyPermissionsProvider()
        let signalingStarted = AsyncLifecycleGate()
        let signalingCleanupStarted = AsyncLifecycleGate()
        let releaseSignalingCleanup = AsyncLifecycleGate()
        let replacementStarted = AsyncLifecycleGate()
        let invocationCounter = AsyncInvocationCounter()
        let executionStarted = AsyncLifecycleGate()
        let channel = SessionTeardownOrderingComputerUseChannel()
        let executor = SessionSuspendingComputerUseExecutor(
            started: executionStarted)
        let ledgerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ledgerURL = ledgerDirectory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let session = HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {},
            deviceIdentityProvider: { "test-device-id" },
            computerUseManager: manager,
            signalingRunOverride: { _ in
                let invocation = await invocationCounter.next()
                if invocation == 1 {
                    await signalingStarted.open()
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        // Account changes cancel ingress immediately.
                    }
                    await signalingCleanupStarted.open()
                    await releaseSignalingCleanup.wait()
                } else {
                    await replacementStarted.open()
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        // Test shutdown cancels the replacement run.
                    }
                }
            })
        let senderID = "F20EC3BA-677E-407A-BDFA-5E613DCA1784"
        let prompt = ComputerUseEnvelope(
            id: "account-change-terminal",
            senderID: senderID,
            targetID: "EDBB4924-FBA9-4343-9B33-8A9A3D78D94D",
            pairingCode: "123456",
            sessionID: "SESSION-ACCOUNT-CHANGE",
            kind: .prompt,
            body: "Open Calculator")

        session.start()
        await signalingStarted.wait()
        manager.start(pairingCode: prompt.pairingCode)
        manager.authorizePeer(senderID: senderID)
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await executionStarted.wait()

        session.handleCloudAccountChanged()
        await channel.waitForTerminalSend()
        await signalingCleanupStarted.wait()
        let cleanupStartedBeforeDeliveryFinished =
            await signalingCleanupStarted.isOpen
        let replacementStartedBeforeCleanup =
            await replacementStarted.isOpen
        XCTAssertTrue(
            cleanupStartedBeforeDeliveryFinished,
            "an account change must cancel authenticated ingress before terminal delivery can finish")
        XCTAssertFalse(
            replacementStartedBeforeCleanup,
            "replacement advertising must still wait for bounded cleanup")

        await channel.releaseTerminalSend()
        await channel.waitForReadySend()
        await channel.releaseReadySend()
        await channel.waitForStopPolling()
        await channel.releaseStopPolling()
        await releaseSignalingCleanup.open()
        await replacementStarted.wait()

        await session.shutdown()
    }

    func test_cloudAccountChangeRequiresPositiveResolutionBeforeCachedFallback() {
        let session = makeSession(readyPermissionsProvider())
        let now = Date()

        session.handleCloudAccountChanged()

        XCTAssertTrue(session.requiresFreshCloudAccountResolution)
        for transient in [
            CloudKitAccountBindingResolutionError.temporarilyUnavailable,
            .couldNotDetermine,
        ] {
            XCTAssertFalse(
                HostSession.shouldReuseConfirmedAccountBinding(
                    after: transient,
                    requiresFreshResolution: true,
                    lastPositiveResolution: now,
                    now: now))
            XCTAssertTrue(
                HostSession.shouldReuseConfirmedAccountBinding(
                    after: transient,
                    requiresFreshResolution: false,
                    lastPositiveResolution: now,
                    now: now))
            XCTAssertFalse(
                HostSession.shouldReuseConfirmedAccountBinding(
                    after: transient,
                    requiresFreshResolution: false,
                    lastPositiveResolution: nil,
                    now: now),
                "a cold launch cannot trust a marker from an earlier process")
            XCTAssertFalse(
                HostSession.shouldReuseConfirmedAccountBinding(
                    after: transient,
                    requiresFreshResolution: false,
                    lastPositiveResolution:
                        now.addingTimeInterval(-(5 * 60 + 1)),
                    now: now),
                "the in-process transient grace period must be bounded")
        }
        for definitive in [
            CloudKitAccountBindingResolutionError.noAccount,
            .restricted,
        ] {
            XCTAssertFalse(
                HostSession.shouldReuseConfirmedAccountBinding(
                    after: definitive,
                    requiresFreshResolution: false,
                    lastPositiveResolution: now,
                    now: now))
            XCTAssertFalse(
                HostSession.shouldReuseConfirmedAccountBinding(
                    after: definitive,
                    requiresFreshResolution: true,
                    lastPositiveResolution: now,
                    now: now))
        }
    }

    func test_successfulClaimCannotResurrectExpiredCachedAccountBinding() {
        let now = Date()

        XCTAssertFalse(
            HostSession.canReusePositivelyResolvedCloudAccountBinding(
                requiresFreshResolution: false,
                lastPositiveResolution:
                    now.addingTimeInterval(-(5 * 60 + 1)),
                now: now),
            "a successful signaling claim must still force a fresh Apple Account lookup when the cached owner is expired")
        XCTAssertTrue(
            HostSession.canReusePositivelyResolvedCloudAccountBinding(
                requiresFreshResolution: false,
                lastPositiveResolution: now.addingTimeInterval(-(5 * 60)),
                now: now),
            "the existing bounded transient policy includes its five-minute boundary")
    }

    func test_successfulClaimCacheFenceHandlesAccountChangeAndMissedNotification() {
        let now = Date()

        XCTAssertFalse(
            HostSession.canReusePositivelyResolvedCloudAccountBinding(
                requiresFreshResolution: true,
                lastPositiveResolution: now,
                now: now),
            "an account-change notification must require a positive lookup even when the old binding is recent")
        XCTAssertTrue(
            HostSession.canReusePositivelyResolvedCloudAccountBinding(
                requiresFreshResolution: false,
                lastPositiveResolution: now,
                now: now),
            "a missed notification may use only the already-established bounded in-process grace period")
        XCTAssertFalse(
            HostSession.canReusePositivelyResolvedCloudAccountBinding(
                requiresFreshResolution: false,
                lastPositiveResolution:
                    now.addingTimeInterval(-(5 * 60 + 1)),
                now: now),
            "the missed-notification path must force re-resolution after the grace period")
    }

    func test_missingOrDifferentConfirmedBindingRotatesHostCredential() {
        let accountA = CloudKitAccountBinding(
            rawValue: String(repeating: "1", count: 64))!
        let accountB = CloudKitAccountBinding(
            rawValue: String(repeating: "2", count: 64))!

        XCTAssertFalse(
            HostSession.shouldRotateHostCredential(
                confirmedBinding: accountA,
                currentBinding: accountA))
        XCTAssertTrue(
            HostSession.shouldRotateHostCredential(
                confirmedBinding: accountA,
                currentBinding: accountB))
        XCTAssertTrue(
            HostSession.shouldRotateHostCredential(
                confirmedBinding: nil,
                currentBinding: accountA),
            "a lost or malformed owner marker cannot revive an old credential")
    }

    func test_grantNextPermission_requestsScreenRecordingWithoutForcingSettings() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.grantNextPermission()

        XCTAssertEqual(provider.requestedPermissions, [.screenRecording])
        XCTAssertEqual(provider.openedPermissions, [])
    }

    func test_grantNextPermission_requestsAccessibilityWithoutForcingSettings() {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        let session = makeSession(provider)

        session.grantNextPermission()

        XCTAssertEqual(provider.requestedPermissions, [.accessibility])
        XCTAssertEqual(provider.openedPermissions, [])
    }

    func test_systemAccessibilityRequiresInspectionAndPostEventAccess() {
        let existingGrant = SystemPermissionsProvider(
            accessibilityTrustCheck: { true },
            postEventAccessCheck: { true })
        let missingEventSynthesis = SystemPermissionsProvider(
            accessibilityTrustCheck: { true },
            postEventAccessCheck: { false })
        let missingInspection = SystemPermissionsProvider(
            accessibilityTrustCheck: { false },
            postEventAccessCheck: { true })

        XCTAssertTrue(
            existingGrant.accessibilityGranted(),
            "an older installation with both live TCC grants should be adopted immediately")
        XCTAssertFalse(
            missingEventSynthesis.accessibilityGranted(),
            "onboarding must not claim remote control is ready when CGEvent synthesis is unavailable")
        XCTAssertFalse(missingInspection.accessibilityGranted())
    }

    func test_systemAccessibilityPromptRequestsInspectionAndPostEventAccess() {
        let recorder = PermissionAccessRecorder()
        let provider = SystemPermissionsProvider(
            accessibilityTrustCheck: { true },
            postEventAccessCheck: { true },
            accessibilityTrustRequest: { recorder.recordInspectionRequest() },
            postEventAccessRequest: { recorder.recordPostEventRequest() })

        provider.requestPrompt(for: .accessibility)

        XCTAssertEqual(recorder.inspectionRequestCount, 1)
        XCTAssertEqual(recorder.postEventRequestCount, 1)
    }

    func test_optionalAudioPermission_targetsMicrophoneWithoutAffectingCoreReadiness() async {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        let session = makeSession(provider)

        session.requestOptionalAudioPermission()
        await Task.yield()

        XCTAssertEqual(provider.microphoneRequestCallCount, 1)
        XCTAssertEqual(provider.requestedPermissions, [])
        XCTAssertEqual(provider.openedPermissions, [])
        XCTAssertTrue(session.permissions.ok)
    }

    func test_openSystemSettings_isAnExplicitFallback() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.openSystemSettings(for: .screenRecording)
        session.openSystemSettings(for: .accessibility)
        session.openSystemSettings(for: .microphone)

        XCTAssertEqual(
            provider.openedPermissions,
            [.screenRecording, .accessibility, .microphone])
    }

    func test_optionalAudioPermission_refreshesAfterGrantWithoutReopeningSettings() async {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        provider.onRequestMicrophoneAccess = { completion in
            provider.microphone = true
            completion(true)
        }
        let session = makeSession(provider)

        session.requestOptionalAudioPermission()
        await Task.yield()

        XCTAssertEqual(provider.microphoneRequestCallCount, 1)
        XCTAssertTrue(session.permissions.microphone)
        XCTAssertEqual(provider.openedPermissions, [])
    }

    func test_optionalAudioPermission_surfacesBuildErrorWithoutBreakingHostState() {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        let session = HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {
                throw HostBuildValidationError.missingAudioInputEntitlement
            })

        session.requestOptionalAudioPermission()

        XCTAssertEqual(provider.microphoneRequestCallCount, 0)
        XCTAssertTrue(session.optionalAudioError?.contains("Audio Input") == true)
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.permissions.ok)
    }

    func test_requestPermissions_onlyRequestsCorePermissions() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.requestPermissions()

        XCTAssertEqual(provider.requestedPermissions, [.screenRecording, .accessibility])
        XCTAssertEqual(provider.microphoneRequestCallCount, 0)
    }

    func test_audioInputEntitlements_requireAudioInputEntitlementWhenSystemAudioEnabled() {
        XCTAssertThrowsError(
            try AudioInputEntitlements.validate { _ in nil }
        ) { error in
            XCTAssertTrue(
                ((error as? LocalizedError)?.errorDescription ?? "").contains("Audio Input"),
                "missing audio-input entitlement should explain the hardened runtime requirement")
        }
    }

    func test_audioInputEntitlements_acceptEnabledAudioInputEntitlement() {
        XCTAssertNoThrow(
            try AudioInputEntitlements.validate { key in
                guard key as String == "com.apple.security.device.audio-input" else { return nil }
                return true
            })
    }

    /// The deployed CloudKit schema still requires an internal six-ASCII-digit
    /// routing binding. This protects wire compatibility; the value is never
    /// presented for a person to enter.
    func test_newPairingCode_isSixDigits() {
        for _ in 0..<100 {
            let code = HostSession.newPairingCode()
            XCTAssertEqual(code.count, 6, "code must be 6 chars: \(code)")
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber },
                          "code must be all digits: \(code)")
        }
    }

    func test_headlessLaunchRemovesOnlyFixedLegacyPairingCodeFile() throws {
        try withLegacyPairingArtifactSandbox { defaults, root in
            let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
            let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: outsideDirectory,
                withIntermediateDirectories: true)
            let fixedLegacyFile = legacyDirectory
                .appendingPathComponent("pairing-code.txt")
            let outsideSentinel = outsideDirectory.appendingPathComponent("sentinel.txt")
            try Data("654321\n".utf8).write(to: fixedLegacyFile)
            try Data("untouched".utf8).write(to: outsideSentinel)
            defaults.set(
                legacyDirectory.path + "/../outside",
                forKey: "PairingCodeFile")

            HeadlessHostSettings.removeLegacyManualPairingArtifacts(
                defaults: defaults,
                legacyDirectoryURL: legacyDirectory)

            XCTAssertNil(defaults.object(forKey: "PairingCodeFile"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixedLegacyFile.path))
            XCTAssertEqual(
                try Data(contentsOf: outsideSentinel),
                Data("untouched".utf8),
                "the retired preference value must never become a deletion path")
        }
    }

    func test_headlessLaunchMissingLegacyFileIsIdempotent() throws {
        try withLegacyPairingArtifactSandbox { defaults, root in
            let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true)

            for _ in 0 ..< 2 {
                defaults.set(root.path, forKey: "PairingCodeFile")
                HeadlessHostSettings.removeLegacyManualPairingArtifacts(
                    defaults: defaults,
                    legacyDirectoryURL: legacyDirectory)
                XCTAssertNil(defaults.object(forKey: "PairingCodeFile"))
            }
        }
    }

    func test_headlessLaunchRejectsSymlinkedLegacyParent() throws {
        try withLegacyPairingArtifactSandbox { defaults, root in
            let realDirectory = root.appendingPathComponent("real", isDirectory: true)
            let symlinkedDirectory = root.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(
                at: realDirectory,
                withIntermediateDirectories: true)
            let fixedLegacyFile = realDirectory
                .appendingPathComponent("pairing-code.txt")
            try Data("654321\n".utf8).write(to: fixedLegacyFile)
            try FileManager.default.createSymbolicLink(
                at: symlinkedDirectory,
                withDestinationURL: realDirectory)
            defaults.set(root.path, forKey: "PairingCodeFile")

            HeadlessHostSettings.removeLegacyManualPairingArtifacts(
                defaults: defaults,
                legacyDirectoryURL: symlinkedDirectory)

            XCTAssertNil(defaults.object(forKey: "PairingCodeFile"))
            XCTAssertEqual(
                try Data(contentsOf: fixedLegacyFile),
                Data("654321\n".utf8))
        }
    }

    func test_headlessLaunchRejectsFinalComponentSymlink() throws {
        try withLegacyPairingArtifactSandbox { defaults, root in
            let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true)
            let outsideSentinel = root.appendingPathComponent("outside.txt")
            let fixedLegacyFile = legacyDirectory
                .appendingPathComponent("pairing-code.txt")
            try Data("untouched".utf8).write(to: outsideSentinel)
            try FileManager.default.createSymbolicLink(
                at: fixedLegacyFile,
                withDestinationURL: outsideSentinel)
            defaults.set(outsideSentinel.path, forKey: "PairingCodeFile")

            HeadlessHostSettings.removeLegacyManualPairingArtifacts(
                defaults: defaults,
                legacyDirectoryURL: legacyDirectory)

            XCTAssertNil(defaults.object(forKey: "PairingCodeFile"))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixedLegacyFile.path),
                outsideSentinel.path)
            XCTAssertEqual(
                try Data(contentsOf: outsideSentinel),
                Data("untouched".utf8))
        }
    }

    func test_headlessLaunchRejectsNonRegularLegacyEntry() throws {
        try withLegacyPairingArtifactSandbox { defaults, root in
            let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
            let fixedLegacyFile = legacyDirectory
                .appendingPathComponent("pairing-code.txt", isDirectory: true)
            try FileManager.default.createDirectory(
                at: fixedLegacyFile,
                withIntermediateDirectories: true)
            defaults.set(root.path, forKey: "PairingCodeFile")

            HeadlessHostSettings.removeLegacyManualPairingArtifacts(
                defaults: defaults,
                legacyDirectoryURL: legacyDirectory)

            var isDirectory = ObjCBool(false)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixedLegacyFile.path,
                isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertNil(defaults.object(forKey: "PairingCodeFile"))
        }
    }

    func test_headlessLaunchRejectsHardLinkedLegacyFile() throws {
        try withLegacyPairingArtifactSandbox { defaults, root in
            let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true)
            let fixedLegacyFile = legacyDirectory
                .appendingPathComponent("pairing-code.txt")
            let secondLink = root.appendingPathComponent("second-link.txt")
            try Data("654321\n".utf8).write(to: fixedLegacyFile)
            try FileManager.default.linkItem(at: fixedLegacyFile, to: secondLink)
            defaults.set(secondLink.path, forKey: "PairingCodeFile")

            HeadlessHostSettings.removeLegacyManualPairingArtifacts(
                defaults: defaults,
                legacyDirectoryURL: legacyDirectory)

            XCTAssertEqual(
                try Data(contentsOf: fixedLegacyFile),
                Data("654321\n".utf8))
            XCTAssertEqual(
                try Data(contentsOf: secondLink),
                Data("654321\n".utf8))
            XCTAssertNil(defaults.object(forKey: "PairingCodeFile"))
        }
    }

    func test_legacyPairingCodeValidationRejectsWrongOwner() {
        var fileStatus = stat()
        fileStatus.st_mode = S_IFREG | S_IRUSR | S_IWUSR
        fileStatus.st_uid = Darwin.geteuid()
        fileStatus.st_nlink = 1
        var directoryStatus = stat()
        directoryStatus.st_mode = S_IFDIR | S_IRWXU
        directoryStatus.st_uid = Darwin.geteuid()

        XCTAssertTrue(HeadlessHostSettings.legacyPairingCodeFileCanBeRemoved(fileStatus))
        XCTAssertFalse(HeadlessHostSettings.legacyPairingCodeFileCanBeRemoved(
            fileStatus,
            expectedOwnerID: Darwin.geteuid() &+ 1))
        XCTAssertTrue(HeadlessHostSettings.legacyPairingCodeDirectoryCanBeUsed(
            directoryStatus))
        XCTAssertFalse(HeadlessHostSettings.legacyPairingCodeDirectoryCanBeUsed(
            directoryStatus,
            expectedOwnerID: Darwin.geteuid() &+ 1))
    }

    func test_advertisementRefreshInterval_refreshesBeforeStaleCutoff() {
        XCTAssertEqual(
            CloudKitSignalingClient.advertisementRefreshInterval(),
            120)
        XCTAssertLessThan(
            CloudKitSignalingClient.advertisementRefreshInterval(),
            CloudKitSignalingClient.defaultStaleSeconds)
        XCTAssertEqual(
            CloudKitSignalingClient.advertisementRefreshInterval(staleSeconds: 20),
            10)
    }

    func test_advertisementRecordName_isStablePerSender() {
        XCTAssertEqual(
            CloudKitSignalingClient.advertisementRecordName(senderID: "HOST-ID"),
            "HostAdvertisement-HOST-ID")
        XCTAssertEqual(
            CloudKitSignalingClient.advertisementRecordName(senderID: "host id/1"),
            "HostAdvertisement-host_id_1")
    }

    func test_bonjourMetadata_roundTripsOnlyBoundedDiscoveryFields() throws {
        let senderID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: senderID,
            computerUseCapability: ComputerUseCapability(
                state: .installing,
                detail: "Downloading AI\n42%")))
        let data = metadata.txtRecordData()
        let values = NetService.dictionary(fromTXTRecord: data)
        let decoded = try XCTUnwrap(LocalHostBonjourMetadata.decode(
            txtRecordData: data))

        XCTAssertLessThanOrEqual(
            data.count,
            LocalHostBonjourMetadata.maximumTXTRecordBytes)
        XCTAssertEqual(Set(values.keys), ["v", "sid", "cu", "cud"])
        XCTAssertEqual(decoded.version, LocalHostBonjourMetadata.currentVersion)
        XCTAssertEqual(decoded.senderID, senderID)
        XCTAssertEqual(decoded.computerUseCapability.state, .installing)
        XCTAssertEqual(decoded.computerUseCapability.detail, "Downloading AI 42%")
    }

    func test_bonjourServiceNameDoesNotExposeInternalRoutingBinding() throws {
        let senderID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: senderID,
            computerUseCapability: .ready,
            routingBinding: "123456"))
        let values = NetService.dictionary(
            fromTXTRecord: metadata.txtRecordData())

        XCTAssertEqual(
            LocalHostAdvertisementName.serviceName(
                hostname: "Studio Mac",
                code: "123456"),
            "Studio Mac")
        XCTAssertEqual(String(data: try XCTUnwrap(values["rb"]), encoding: .utf8), "123456")
        XCTAssertFalse(
            LocalHostAdvertisementName.serviceName(
                hostname: "Studio Mac",
                code: "123456").contains("123456"))
    }

    func test_bonjourMetadata_rejectsInvalidIdentityAndOversizedRecords() {
        XCTAssertNil(LocalHostBonjourMetadata(
            senderID: "not-a-device-identity",
            computerUseCapability: .ready))
        let lowercaseSenderID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A".lowercased()
        XCTAssertEqual(
            LocalHostBonjourMetadata(
                senderID: lowercaseSenderID,
                computerUseCapability: .ready)?.senderID,
            lowercaseSenderID,
            "the exact CloudKit senderID spelling must survive validation")

        let values: [String: Data] = [
            "v": Data("1".utf8),
            "sid": Data("8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A".utf8),
            "cu": Data("ready".utf8),
            "cud": Data("AI Computer Use is ready".utf8),
            "padding-a": Data(repeating: 65, count: 240),
            "padding-b": Data(repeating: 66, count: 240),
        ]
        let oversized = NetService.data(fromTXTRecord: values)

        XCTAssertGreaterThan(
            oversized.count,
            LocalHostBonjourMetadata.maximumTXTRecordBytes)
        XCTAssertNil(LocalHostBonjourMetadata.decode(txtRecordData: oversized))
    }

    func test_bonjourAdvertiserPublishesAndRefreshesComputerUseCapability() throws {
        let senderID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
        let advertiser = BonjourAdvertiser()
        defer { advertiser.stop() }

        advertiser.publish(
            hostname: "Remote Desktop Host Tests",
            code: "654321",
            senderID: senderID,
            computerUseCapability: .setupRequired)
        XCTAssertEqual(
            advertiser.publishedMetadata?.computerUseCapability,
            .setupRequired)

        let installing = ComputerUseCapability(
            state: .installing,
            detail: "Downloading AI — 42%")
        XCTAssertTrue(advertiser.update(
            senderID: senderID,
            computerUseCapability: installing))
        XCTAssertEqual(
            advertiser.publishedMetadata?.computerUseCapability,
            installing)
    }

    func test_hostNameCapabilityFallback_roundTripsWithoutNewCloudKitFields() {
        let capability = ComputerUseCapability(
            state: .installing,
            detail: "Downloading AI — 42%")
        let encoded = CloudKitSignalingClient.encodedHostName(
            "Living Room Mac",
            capability: capability)
        let decoded = CloudKitSignalingClient.decodedHostName(encoded)

        XCTAssertEqual(decoded.name, "Living Room Mac")
        XCTAssertEqual(decoded.capability, capability)
        XCTAssertTrue(encoded.hasPrefix("Living Room Mac\n"))
    }

    func test_advertisementWrite_usesProductionSchemaAndFetchFallback() {
        let capability = ComputerUseCapability(
            state: .ready,
            detail: "AI Computer Use is ready")
        let updatedAt = Date(timeIntervalSince1970: 1_752_500_000)
        let record = CKRecord(
            recordType: "HostAdvertisement",
            recordID: CKRecord.ID(recordName: "HostAdvertisement-HOST-ID"))

        CloudKitSignalingClient.updateAdvertisementFields(
            on: record,
            senderID: "HOST-ID",
            pairingCode: "654321",
            hostName: "Living Room Mac",
            computerUseCapability: capability,
            createdAt: updatedAt)

        XCTAssertEqual(
            Set(record.changedKeys()),
            Set(["senderID", "pairingCode", "hostName", "createdAt"]))
        XCTAssertNil(record["computerUseState"])
        XCTAssertNil(record["computerUseDetail"])

        let advertisement = CloudKitSignalingClient.hostAdvertisement(from: record)
        XCTAssertEqual(advertisement?.senderID, "HOST-ID")
        XCTAssertEqual(advertisement?.hostName, "Living Room Mac")
        XCTAssertEqual(advertisement?.pairingCode, "654321")
        XCTAssertEqual(advertisement?.updatedAt, updatedAt)
        XCTAssertEqual(advertisement?.computerUseCapability, capability)
    }

    func test_hostNameCapabilityFallback_keepsLegacyPlainNamesReadable() {
        let decoded = CloudKitSignalingClient.decodedHostName("Office Mac")

        XCTAssertEqual(decoded.name, "Office Mac")
        XCTAssertNil(decoded.capability)
    }

    func test_startListeningOnLaunch_defaultsToTrue() {
        withTemporaryDefaults { defaults in
            XCTAssertTrue(HeadlessHostSettings.startListeningOnLaunch(
                defaults: defaults,
                arguments: ["RemoteDesktopHost"]))
        }
    }

    func test_startListeningOnLaunch_respectsExplicitFalse() {
        withTemporaryDefaults { defaults in
            defaults.set(false, forKey: HeadlessHostSettings.startListeningOnLaunchKey)

            XCTAssertFalse(HeadlessHostSettings.startListeningOnLaunch(
                defaults: defaults,
                arguments: ["RemoteDesktopHost"]))
        }
    }

    func test_startListeningArgumentOverridesExplicitFalse() {
        withTemporaryDefaults { defaults in
            defaults.set(false, forKey: HeadlessHostSettings.startListeningOnLaunchKey)

            XCTAssertTrue(HeadlessHostSettings.startListeningOnLaunch(
                defaults: defaults,
                arguments: ["RemoteDesktopHost", "--start-listening"]))
        }
    }

    func test_runtimeContextDetectsEachXCTestInjectionEnvironment() {
        for key in [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "XCInjectBundle",
            "XCInjectBundleInto",
        ] {
            XCTAssertTrue(
                HostRuntimeContext.detectsUnitTests(
                    environment: [key: "present"],
                    arguments: ["RemoteDesktopHost"],
                    loadedBundlePaths: [],
                    xctestRuntimeAvailable: false),
                "expected \(key) to identify an app-hosted test run")
        }
    }

    func test_runtimeContextDetectsFallbackXCTestMarkers() {
        XCTAssertTrue(HostRuntimeContext.detectsUnitTests(
            environment: ["DYLD_INSERT_LIBRARIES": "/tmp/XCTestBundleInject.dylib"],
            arguments: ["RemoteDesktopHost"],
            loadedBundlePaths: [],
            xctestRuntimeAvailable: false))
        XCTAssertTrue(HostRuntimeContext.detectsUnitTests(
            environment: [:],
            arguments: ["RemoteDesktopHost", "/tmp/RemoteDesktopHostTests.xctest"],
            loadedBundlePaths: [],
            xctestRuntimeAvailable: false))
        XCTAssertTrue(HostRuntimeContext.detectsUnitTests(
            environment: [:],
            arguments: ["RemoteDesktopHost"],
            loadedBundlePaths: ["/tmp/RemoteDesktopHostTests.xctest"],
            xctestRuntimeAvailable: false))
        XCTAssertTrue(HostRuntimeContext.detectsUnitTests(
            environment: [:],
            arguments: ["RemoteDesktopHost"],
            loadedBundlePaths: [],
            xctestRuntimeAvailable: true))
    }

    func test_runtimeContextDoesNotClassifyOrdinaryHostLaunchAsTests() {
        XCTAssertFalse(HostRuntimeContext.detectsUnitTests(
            environment: ["PATH": "/usr/bin:/bin"],
            arguments: ["/Applications/Remote Desktop Host.app/Contents/MacOS/RemoteDesktopHost"],
            loadedBundlePaths: ["/Applications/Remote Desktop Host.app"],
            xctestRuntimeAvailable: false))
    }

    func test_hostSessionDisablesExternalComputerUseServicesDuringXCTest() {
        XCTAssertTrue(HostRuntimeContext.isRunningUnitTests)
        XCTAssertFalse(
            HostRuntimeContext.shouldInstallVisibleChrome,
            "An app-hosted XCTest must not add a status item or any other visible host chrome")

        let session = makeSession(MockPermissionsProvider())

        XCTAssertFalse(session.computerUse.allowsExternalServices)
    }

    func test_appDelegateSkipsVisibleChromeAndServicesDuringXCTest() {
        XCTAssertTrue(HostRuntimeContext.isRunningUnitTests)
        let delegate = AppDelegate()

        delegate.applicationDidFinishLaunching(Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApp))

        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertFalse(
            delegate.didEnterProductionLaunchPath,
            "XCTest must return before termination handlers or host services are configured")
        XCTAssertFalse(
            delegate.didInstallStatusItem,
            "XCTest must not allocate the Control Center-hosted status item")
    }

    func test_startAtLogin_defaultsToTrue() {
        withTemporaryDefaults { defaults in
            XCTAssertTrue(HeadlessHostSettings.startAtLogin(defaults: defaults))
        }
    }

    func test_setupGuide_ordersRequiredPermissionsBeforeOptionalAudio() {
        XCTAssertEqual(
            HostSetupStep.current(
                permissions: .init(
                    screenRecording: false,
                    accessibility: false,
                    microphone: false),
                optionalAudioSkipped: false),
            .screenRecording)
        XCTAssertEqual(
            HostSetupStep.current(
                permissions: .init(
                    screenRecording: true,
                    accessibility: false,
                    microphone: false),
                optionalAudioSkipped: false),
            .accessibility)
        XCTAssertEqual(
            HostSetupStep.current(
                permissions: .init(
                    screenRecording: true,
                    accessibility: true,
                    microphone: false),
                optionalAudioSkipped: false),
            .optionalAudio)
    }

    func test_setupGuide_canFinishWhileOptionalAudioIsOff() {
        let permissions = HostSession.Permissions(
            screenRecording: true,
            accessibility: true,
            microphone: false)

        XCTAssertEqual(
            HostSetupStep.current(
                permissions: permissions,
                optionalAudioSkipped: true),
            .ready)
        XCTAssertTrue(permissions.coreReady)
        XCTAssertFalse(permissions.audioEnabled)
    }

    func test_setupPreferences_reopenForMissingCorePermission() {
        withTemporaryDefaults { defaults in
            let ready = HostSession.Permissions(
                screenRecording: true,
                accessibility: true,
                microphone: false)

            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults),
                "existing TCC grants must skip onboarding even without a completion preference")

            HostSetupPreferences.markCompleted(defaults: defaults)
            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults))

            XCTAssertTrue(HostSetupPreferences.shouldPresent(
                permissions: .init(
                    screenRecording: false,
                    accessibility: true,
                    microphone: true),
                defaults: defaults))
        }
    }

    func test_setupPreferences_adoptExistingGrantsFromOlderVersion() {
        withTemporaryDefaults { defaults in
            let ready = HostSession.Permissions(
                screenRecording: true,
                accessibility: true,
                microphone: false)

            HostSetupPreferences.markRestartRequested(defaults: defaults)
            XCTAssertNil(defaults.object(
                forKey: HostSetupPreferences.completedKey))
            XCTAssertTrue(defaults.bool(
                forKey: HostSetupPreferences.resumeAfterRestartKey))
            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults))

            HostSetupPreferences.reconcileExistingGrants(
                permissions: ready,
                defaults: defaults)

            XCTAssertTrue(defaults.bool(
                forKey: HostSetupPreferences.completedKey))
            XCTAssertNil(defaults.object(
                forKey: HostSetupPreferences.resumeAfterRestartKey))
            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults))
        }
    }

    func test_setupPreferences_restartMarkerClearsWhenRequiredGrantsAreReady() {
        withTemporaryDefaults { defaults in
            let ready = HostSession.Permissions(
                screenRecording: true,
                accessibility: true,
                microphone: false)
            HostSetupPreferences.markCompleted(defaults: defaults)
            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults))

            HostSetupPreferences.markRestartRequested(defaults: defaults)
            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults),
                "a stale restart marker must not override live TCC grants")

            HostSetupPreferences.reconcileExistingGrants(
                permissions: ready,
                defaults: defaults)
            XCTAssertFalse(HostSetupPreferences.shouldPresent(
                permissions: ready,
                defaults: defaults),
                "live TCC grants must clear a stale relaunch-resume marker")
            XCTAssertNil(defaults.object(
                forKey: HostSetupPreferences.resumeAfterRestartKey))
        }
    }

    func test_setupPreferences_restartMarkerStaysWhileCoreGrantIsMissing() {
        withTemporaryDefaults { defaults in
            let missingAccessibility = HostSession.Permissions(
                screenRecording: true,
                accessibility: false,
                microphone: true)
            HostSetupPreferences.markRestartRequested(defaults: defaults)

            HostSetupPreferences.reconcileExistingGrants(
                permissions: missingAccessibility,
                defaults: defaults)

            XCTAssertTrue(HostSetupPreferences.shouldPresent(
                permissions: missingAccessibility,
                defaults: defaults))
            XCTAssertTrue(defaults.bool(
                forKey: HostSetupPreferences.resumeAfterRestartKey))
        }
    }

    // MARK: Issue 4 — CloudKit signing must be validated before CKContainer

    func test_cloudKitEntitlements_requireCloudKitService() {
        XCTAssertThrowsError(
            try CloudKitEntitlements.validate(
                containerIdentifier: HostConfig.cloudKitContainerIdentifier,
                entitlementValue: entitlementValue(
                    containers: [HostConfig.cloudKitContainerIdentifier]))
        ) { error in
            XCTAssertTrue(
                ((error as? LocalizedError)?.errorDescription ?? "").contains("CloudKit"),
                "missing CloudKit service should surface a signing explanation")
        }
    }

    func test_cloudKitEntitlements_requireExpectedContainer() {
        XCTAssertThrowsError(
            try CloudKitEntitlements.validate(
                containerIdentifier: HostConfig.cloudKitContainerIdentifier,
                entitlementValue: entitlementValue(services: ["CloudKit"]))
        ) { error in
            XCTAssertTrue(
                ((error as? LocalizedError)?.errorDescription ?? "").contains(HostConfig.cloudKitContainerIdentifier),
                "missing container should name the required CloudKit container")
        }
    }

    func test_cloudKitEntitlements_acceptSignedCloudKitContainer() {
        XCTAssertNoThrow(
            try CloudKitEntitlements.validate(
                containerIdentifier: HostConfig.cloudKitContainerIdentifier,
                entitlementValue: entitlementValue(
                    services: ["CloudKit"],
                    containers: [HostConfig.cloudKitContainerIdentifier])))
    }

    func test_cloudKitRetryClassifier_onlyRetriesTransientErrors() {
        let networkFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue)
        let unknownItem = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.unknownItem.rawValue)
        let unrelated = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        XCTAssertTrue(CloudKitSignalingClient.isTransientCloudKitError(networkFailure))
        XCTAssertFalse(CloudKitSignalingClient.isTransientCloudKitError(unknownItem))
        XCTAssertFalse(CloudKitSignalingClient.isTransientCloudKitError(unrelated))
    }

    func test_cloudKitSignalingPollBoundsRejectIncompleteCursorPrefix() throws {
        var accumulator = BoundedCloudKitRecordAccumulator<Int>(
            maximumObservedRecords:
                CloudKitSignalingClient.maximumQueryRecords,
            maximumPages: CloudKitSignalingClient.maximumQueryPages)
        for page in 0..<(CloudKitSignalingClient.maximumQueryPages - 1) {
            try accumulator.append(
                Array((page * 50)..<((page + 1) * 50)),
                observedRecordCount: 50,
                hasMore: true)
        }
        XCTAssertThrowsError(try accumulator.append(
            Array(450..<500),
            observedRecordCount: 50,
            hasMore: true)) { error in
            XCTAssertEqual(
                error as? BoundedCloudKitRecordError,
                .queryLimitExceeded)
        }
        XCTAssertEqual(accumulator.observedRecordCount, 450)
    }

    func test_cloudKitHostDefersICEUntilOfferAndKeepsSameBatchSenderRecords() async throws {
        let client = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: "123456",
            role: .host,
            senderID: "HOST-ID")
        let base = Date()
        let earlyICE = try signalingRecord(
            name: "ice-a",
            senderID: "CLIENT-A",
            kind: .ice,
            payload: ["candidate": "candidate-a"],
            createdAt: base)

        let beforeOffer = try await client.consumePollRecords([earlyICE])
        XCTAssertTrue(beforeOffer.isEmpty)

        let offer = try signalingRecord(
            name: "offer-a",
            senderID: "CLIENT-A",
            kind: .offer,
            payload: ["sdp": "offer-sdp"],
            createdAt: base.addingTimeInterval(2))
        let otherSenderICE = try signalingRecord(
            name: "ice-b",
            senderID: "CLIENT-B",
            kind: .ice,
            payload: ["candidate": "candidate-b"],
            createdAt: base.addingTimeInterval(3))
        let otherSenderOffer = try signalingRecord(
            name: "offer-b",
            senderID: "CLIENT-B",
            kind: .offer,
            payload: ["sdp": "other-offer"],
            createdAt: base.addingTimeInterval(4))
        let earlyBye = try signalingRecord(
            name: "bye-a",
            senderID: "CLIENT-A",
            kind: .bye,
            payload: ["reason": "unbound"],
            createdAt: base.addingTimeInterval(1))

        let accepted = try await client.consumePollRecords([
            earlyICE,
            earlyBye,
            offer,
            otherSenderICE,
            otherSenderOffer,
        ])

        XCTAssertEqual(accepted.map(\.kind), [.ice, .offer])
        XCTAssertEqual(accepted.map(\.senderID), ["CLIENT-A", "CLIENT-A"])
        XCTAssertEqual(accepted.first?.payload["candidate"], "candidate-a")
        let replay = try await client.consumePollRecords([
            earlyICE,
            earlyBye,
            offer,
            otherSenderICE,
            otherSenderOffer,
        ])
        XCTAssertTrue(replay.isEmpty)
    }

    func test_cloudKitPollRejectsPerRecordFailureBeforeReplayMutation() async throws {
        let client = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: "123456",
            role: .host,
            senderID: "HOST-ID")
        let offer = try signalingRecord(
            name: "offer-a",
            senderID: "CLIENT-A",
            kind: .offer,
            payload: ["sdp": "offer-sdp"],
            createdAt: Date(timeIntervalSinceReferenceDate: 2_000))
        let failedID = CKRecord.ID(recordName: "unavailable-record")
        let partialBatch: [(CKRecord.ID, Result<CKRecord, Error>)] = [
            (offer.recordID, .success(offer)),
            (
                failedID,
                .failure(NSError(
                    domain: CKErrorDomain,
                    code: CKError.Code.networkFailure.rawValue))
            ),
        ]

        do {
            _ = try await client.consumePollQueryResults(partialBatch)
            XCTFail("one per-record failure must reject the complete query batch")
        } catch {
            // Expected. The successful prefix must remain unconsumed.
        }

        let retry = try await client.consumePollQueryResults([
            (offer.recordID, .success(offer)),
        ])
        XCTAssertEqual(retry.map(\.kind), [.offer])
        XCTAssertEqual(retry.map(\.senderID), ["CLIENT-A"])
    }

    func test_cloudKitEqualTimestampOffersUseRecordNameTotalOrder() async throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 3_000)
        let firstByName = try signalingRecord(
            name: "offer-a",
            senderID: "CLIENT-A",
            kind: .offer,
            payload: ["sdp": "offer-a"],
            createdAt: timestamp)
        let lastByName = try signalingRecord(
            name: "offer-z",
            senderID: "CLIENT-Z",
            kind: .offer,
            payload: ["sdp": "offer-z"],
            createdAt: timestamp)

        let reverseInputClient = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: "123456",
            role: .host,
            senderID: "HOST-ID")
        let forwardInputClient = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: "123456",
            role: .host,
            senderID: "HOST-ID")

        let fromReverse = try await reverseInputClient.consumePollRecords([
            lastByName,
            firstByName,
        ])
        let fromForward = try await forwardInputClient.consumePollRecords([
            firstByName,
            lastByName,
        ])

        XCTAssertEqual(fromReverse.map(\.senderID), ["CLIENT-A"])
        XCTAssertEqual(fromForward.map(\.senderID), ["CLIENT-A"])
        XCTAssertEqual(fromReverse.first?.payload["sdp"], "offer-a")
        XCTAssertEqual(fromForward.first?.payload["sdp"], "offer-a")
    }

    func test_cloudKitHostOfferBindingIsAtomicAndRejectsSecondSender() async {
        let client = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: "123456",
            role: .host,
            senderID: "HOST-ID")

        let acceptedFirst = await client.acceptOfferSenderID("CLIENT-A")
        let acceptedRepeat = await client.acceptOfferSenderID("CLIENT-A")
        let acceptedOther = await client.acceptOfferSenderID("CLIENT-B")
        let resolved = await client.resolvedPeerSenderID()

        XCTAssertTrue(acceptedFirst)
        XCTAssertTrue(acceptedRepeat)
        XCTAssertFalse(acceptedOther)
        XCTAssertEqual(resolved, "CLIENT-A")
    }

    func test_cloudKitClientPinsTheSelectedHostIdentity() {
        let first = CKRecord(
            recordType: "HostAdvertisement",
            recordID: CKRecord.ID(recordName: "host-a"))
        first["senderID"] = "HOST-A" as CKRecordValue
        let second = CKRecord(
            recordType: "HostAdvertisement",
            recordID: CKRecord.ID(recordName: "host-b"))
        second["senderID"] = "HOST-B" as CKRecordValue

        XCTAssertEqual(
            CloudKitSignalingClient.selectedHostSenderID(
                from: [first, second],
                expectedTargetID: "HOST-B"),
            "HOST-B")
        XCTAssertNil(
            CloudKitSignalingClient.selectedHostSenderID(
                from: [first, second],
                expectedTargetID: "HOST-C"))
        XCTAssertNil(
            CloudKitSignalingClient.selectedHostSenderID(
                from: [first, second],
                expectedTargetID: nil))
        XCTAssertEqual(
            CloudKitSignalingClient.selectedHostSenderID(
                from: [first],
                expectedTargetID: nil),
            "HOST-A")
    }

    private func makeSession(
        _ provider: MockPermissionsProvider,
        signalingRunOverride: (@MainActor @Sendable (String) async -> Void)? = nil
    ) -> HostSession {
        HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {},
            deviceIdentityProvider: { "test-device-id" },
            signalingRunOverride: signalingRunOverride)
    }

    private func readyPermissionsProvider() -> MockPermissionsProvider {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        provider.microphone = true
        return provider
    }

    private func blockingSignalingRun(
        started: AsyncLifecycleGate,
        cleanupStarted: AsyncLifecycleGate,
        releaseCleanup: AsyncLifecycleGate,
        cleanupFinished: AsyncLifecycleGate
    ) -> @MainActor @Sendable (String) async -> Void {
        { _ in
            await started.open()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                // Cancellation is the expected transition into cleanup.
            }
            await cleanupStarted.open()
            await releaseCleanup.wait()
            await cleanupFinished.open()
        }
    }

    private func signalingRecord(
        name: String,
        senderID: String,
        kind: SignalingEnvelope.Kind,
        payload: [String: String],
        createdAt: Date = Date()
    ) throws -> CKRecord {
        let record = CKRecord(
            recordType: "WebRTCSignal",
            recordID: CKRecord.ID(recordName: name))
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        record["senderID"] = senderID as CKRecordValue
        record["targetID"] = "HOST-ID" as CKRecordValue
        record["pairingCode"] = "123456" as CKRecordValue
        record["kind"] = kind.rawValue as CKRecordValue
        record["payload"] = try XCTUnwrap(
            String(data: payloadData, encoding: .utf8)) as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        return record
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "RemoteDesktopHostTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create temporary defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(defaults)
    }

    private func withLegacyPairingArtifactSandbox(
        _ body: (UserDefaults, URL) throws -> Void
    ) throws {
        let suiteName = "RemoteDesktopHostTests.LegacyPairing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try body(defaults, root)
    }
}

@MainActor
private final class SessionSuspendingComputerUseExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Session teardown test runtime"
    private let started: AsyncLifecycleGate

    init(started: AsyncLifecycleGate) {
        self.started = started
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        await started.open()
        try await Task.sleep(for: .seconds(60))
        return .completed("Unexpected completion")
    }
}

private actor SessionTeardownOrderingComputerUseChannel:
    HostComputerUseChannel
{
    private let terminalSendStarted = AsyncLifecycleGate()
    private let releaseTerminal = AsyncLifecycleGate()
    private let readySendStarted = AsyncLifecycleGate()
    private let releaseReady = AsyncLifecycleGate()
    private let stopPollingStarted = AsyncLifecycleGate()
    private let releaseStop = AsyncLifecycleGate()
    private var pollingStopped = false

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        if kind == .assistant,
           let update = try? ComputerUseTaskUpdate.decodeBody(body),
           update.outcome == .unableToComplete {
            await terminalSendStarted.open()
            await releaseTerminal.wait()
        } else if kind == .status,
                  let update = try? ComputerUseTaskUpdate.decodeBody(body),
                  update.text == "ready" {
            await readySendStarted.open()
            await releaseReady.wait()
        }
        return ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: "EDBB4924-FBA9-4343-9B33-8A9A3D78D94D",
            targetID: explicitTargetID
                ?? "F20EC3BA-677E-407A-BDFA-5E613DCA1784",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "SESSION-1",
            kind: kind,
            body: body)
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func stopPolling() async {
        await stopPollingStarted.open()
        await releaseStop.wait()
        pollingStopped = true
    }

    func waitForTerminalSend() async {
        await terminalSendStarted.wait()
    }

    func releaseTerminalSend() async {
        await releaseTerminal.open()
    }

    func waitForReadySend() async {
        await readySendStarted.wait()
    }

    func releaseReadySend() async {
        await releaseReady.open()
    }

    func waitForStopPolling() async {
        await stopPollingStarted.wait()
    }

    func releaseStopPolling() async {
        await releaseStop.open()
    }

    func didStopPolling() -> Bool { pollingStopped }
}

private actor AsyncLifecycleGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private actor AsyncInvocationCounter {
    private(set) var current = 0

    func next() -> Int {
        current += 1
        return current
    }
}

private final class PermissionAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inspectionRequests = 0
    private var postEventRequests = 0

    var inspectionRequestCount: Int {
        lock.withLock { inspectionRequests }
    }

    var postEventRequestCount: Int {
        lock.withLock { postEventRequests }
    }

    func recordInspectionRequest() {
        lock.withLock { inspectionRequests += 1 }
    }

    func recordPostEventRequest() {
        lock.withLock { postEventRequests += 1 }
    }
}

// MARK: - Test doubles

/// Deterministic stand-in for `SystemPermissionsProvider`. The real
/// provider calls into TCC, which we can't drive from a unit test —
/// and whose caching behavior was at the heart of the bug. Keeping
/// the fake trivially mutable ensures each test is isolated.
final class MockPermissionsProvider: PermissionsProvider, @unchecked Sendable {
    var screenRecording = false
    var accessibility = false
    var microphone = false
    var onRequestMicrophoneAccess: (@Sendable (@escaping @Sendable (Bool) -> Void) -> Void)?
    private(set) var requestPromptsCallCount = 0
    private(set) var microphoneRequestCallCount = 0
    private(set) var requestedPermissions: [PermissionKind] = []
    private(set) var openedPermissions: [PermissionKind] = []

    func screenRecordingGranted() -> Bool { screenRecording }
    func accessibilityGranted() -> Bool { accessibility }
    func microphoneGranted() -> Bool { microphone }
    func requestPrompt(for permission: PermissionKind) { requestedPermissions.append(permission) }
    func requestMicrophoneAccess(completion: @escaping @Sendable (Bool) -> Void) {
        microphoneRequestCallCount += 1
        if let onRequestMicrophoneAccess {
            onRequestMicrophoneAccess(completion)
        } else {
            completion(microphone)
        }
    }
    func openSystemSettings(for permission: PermissionKind) { openedPermissions.append(permission) }
    func requestPrompts() {
        requestPromptsCallCount += 1
        requestedPermissions.append(contentsOf: [.screenRecording, .accessibility])
    }
}

private func entitlementValue(
    services: [String] = [],
    containers: [String] = []
) -> (CFString) -> Any? {
    { key in
        switch key as String {
        case "com.apple.developer.icloud-services":
            return services.isEmpty ? nil : services
        case "com.apple.developer.icloud-container-identifiers":
            return containers.isEmpty ? nil : containers
        default:
            return nil
        }
    }
}
