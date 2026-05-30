import CloudKit
import XCTest
@testable import RemoteDesktopHost

/// Regression tests for the permission-detection bugs that made the
/// menu bar app unusable: Accessibility granted in System Settings
/// but not reflected in `HostSession.permissions`, "Start listening"
/// stuck disabled, and therefore no pairing code surfacing to iOS.
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
    func test_permissionsOk_flipsWhenBothGranted() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.refreshPermissions()
        XCTAssertFalse(session.permissions.ok)

        provider.screenRecording = true
        session.refreshPermissions()
        XCTAssertFalse(session.permissions.ok, "one grant is not enough")

        provider.accessibility = true
        session.refreshPermissions()
        XCTAssertFalse(session.permissions.ok, "system audio also requires microphone access")

        provider.microphone = true
        session.refreshPermissions()
        XCTAssertTrue(session.permissions.ok, "all required permissions enable the Start button")
    }

    /// Calling `start()` while permissions are denied must leave the
    /// session in an informative error state and *not* generate a
    /// pairing code.
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

    // MARK: Issue 3 — Pairing code must surface once permissions are ok

    /// Once permissions are granted and the user clicks Start, the
    /// session must leave `.idle` and generate a 6-digit code so the
    /// iOS client has something to enter. We don't await the network
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
                          "session must leave .idle so a pairing code can be generated")
        if case .error(let msg) = session.state {
            XCTFail("expected non-error transition, got error: \(msg)")
        }

        session.stop()
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

    func test_grantNextPermission_targetsScreenRecordingFirst() {
        let provider = MockPermissionsProvider()
        let session = makeSession(provider)

        session.grantNextPermission()

        XCTAssertEqual(provider.requestedPermissions, [.screenRecording])
        XCTAssertEqual(provider.openedPermissions, [.screenRecording])
    }

    func test_grantNextPermission_targetsAccessibilityAfterScreenRecording() {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        let session = makeSession(provider)

        session.grantNextPermission()

        XCTAssertEqual(provider.requestedPermissions, [.accessibility])
        XCTAssertEqual(provider.openedPermissions, [.accessibility])
    }

    func test_grantNextPermission_targetsMicrophoneWhenOnlyAudioBridgePermissionMissing() async {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        let session = makeSession(provider)

        session.grantNextPermission()
        await Task.yield()

        XCTAssertEqual(provider.microphoneRequestCallCount, 1)
        XCTAssertEqual(provider.requestedPermissions, [])
        XCTAssertEqual(provider.openedPermissions, [.microphone])
    }

    func test_grantNextPermission_refreshesAfterMicrophoneGrantWithoutReopeningSettings() async {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        provider.onRequestMicrophoneAccess = { completion in
            provider.microphone = true
            completion(true)
        }
        let session = makeSession(provider)

        session.grantNextPermission()
        await Task.yield()

        XCTAssertEqual(provider.microphoneRequestCallCount, 1)
        XCTAssertTrue(session.permissions.microphone)
        XCTAssertEqual(provider.openedPermissions, [])
    }

    func test_grantNextPermission_surfacesBuildErrorWhenAudioInputEntitlementMissing() {
        let provider = MockPermissionsProvider()
        provider.screenRecording = true
        provider.accessibility = true
        let session = HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {
                throw HostBuildValidationError.missingAudioInputEntitlement
            })

        session.grantNextPermission()

        XCTAssertEqual(provider.microphoneRequestCallCount, 0)
        if case .error(let message) = session.state {
            XCTAssertTrue(message.contains("Audio Input"))
        } else {
            XCTFail("expected .error, got \(session.state)")
        }
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

    /// The pairing code format is the iOS client's contract: exactly
    /// six ASCII digits. This test protects the format generator from
    /// drifting (e.g., a refactor that returns a UUID instead).
    func test_newPairingCode_isSixDigits() {
        for _ in 0..<100 {
            let code = HostSession.newPairingCode()
            XCTAssertEqual(code.count, 6, "code must be 6 chars: \(code)")
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber },
                          "code must be all digits: \(code)")
        }
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

    func test_startAtLogin_defaultsToTrue() {
        withTemporaryDefaults { defaults in
            XCTAssertTrue(HeadlessHostSettings.startAtLogin(defaults: defaults))
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

    private func makeSession(_ provider: MockPermissionsProvider) -> HostSession {
        HostSession(
            permissionsProvider: provider,
            validateAudioInputEntitlements: {})
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
    func requestPrompts() { requestPromptsCallCount += 1 }
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
