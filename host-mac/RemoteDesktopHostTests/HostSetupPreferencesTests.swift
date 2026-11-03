import XCTest
@testable import RemoteDesktopHost

@MainActor
final class HostSetupPreferencesTests: XCTestCase {
    func testSuccessfulGrantHistorySurvivesAnUpgrade() {
        withDefaults { defaults in
            HostPermissionHistory.recordSuccessfulGrants(
                version: "2", designatedRequirement: "old signing requirement", defaults: defaults)
            XCTAssertTrue(HostPermissionHistory.previouslyGranted(defaults: defaults))
            XCTAssertEqual(defaults.string(forKey: HostPermissionHistory.grantedVersionKey), "2")
            HostPermissionHistory.recordSuccessfulGrants(
                version: "3", designatedRequirement: "new signing requirement", defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: HostPermissionHistory.grantedVersionKey), "3")
            XCTAssertEqual(defaults.string(forKey: HostPermissionHistory.grantedRequirementKey), "new signing requirement")
        }
    }

    func testLegacyCompletedSetupOffersFixWithoutNewHistory() {
        withDefaults { defaults in
            XCTAssertFalse(HostPermissionHistory.previouslyGranted(defaults: defaults))
            defaults.set(true, forKey: HostSetupPreferences.completedKey)
            XCTAssertTrue(HostPermissionHistory.previouslyGranted(defaults: defaults))
        }
    }

    func testFirstInstallOffersFixAfterFiveSecondsForEachMissingPermission() {
        var flow = HostPermissionSetupState()
        for permission in [PermissionKind.screenRecording, .accessibility] {
            XCTAssertFalse(flow.offersFix(for: permission, granted: false, previouslyGranted: false, now: 100))
            flow.openedSettings(for: permission, now: 100)
            XCTAssertFalse(flow.offersFix(for: permission, granted: false, previouslyGranted: false, now: 104.9))
            XCTAssertTrue(flow.offersFix(for: permission, granted: false, previouslyGranted: false, now: 105))
            XCTAssertFalse(flow.offersFix(for: permission, granted: true, previouslyGranted: false, now: 105))
            flow.openedSettings(for: permission, now: 110)
            XCTAssertTrue(flow.offersFix(for: permission, granted: false, previouslyGranted: false, now: 110))
        }
    }

    func testPriorGrantOffersFixImmediatelyButNeverForMicrophoneOrGrantedPermission() {
        let flow = HostPermissionSetupState()
        for permission in [PermissionKind.screenRecording, .accessibility] {
            XCTAssertTrue(flow.offersFix(for: permission, granted: false, previouslyGranted: true, now: 0))
            XCTAssertFalse(flow.offersFix(for: permission, granted: true, previouslyGranted: true, now: 0))
        }
        XCTAssertFalse(flow.offersFix(for: .microphone, granted: false, previouslyGranted: true, now: 100))
    }

    func testScreenGrantRestartsExactlyOnceAndExistingGrantNeverRestarts() {
        var flow = HostPermissionSetupState()
        XCTAssertFalse(flow.screenGrantRequiresRestart(false))
        XCTAssertFalse(flow.screenGrantRequiresRestart(false))
        XCTAssertTrue(flow.screenGrantRequiresRestart(true))
        XCTAssertFalse(flow.screenGrantRequiresRestart(true))
        XCTAssertFalse(flow.screenGrantRequiresRestart(false))
        XCTAssertFalse(flow.screenGrantRequiresRestart(true))
        var relaunched = HostPermissionSetupState()
        XCTAssertFalse(relaunched.screenGrantRequiresRestart(true))
        XCTAssertFalse(relaunched.didRequestRestart)
    }

    func testResetArgumentsTargetOnlyRequestedServiceAndOwnBundle() throws {
        for identifier in ["com.threadmark.remotedesktop.host", "com.threadmark.remotedesktop.host.debug"] {
            XCTAssertEqual(try HostPermissionRepair.resetArguments(for: .screenRecording, bundleIdentifier: identifier),
                           ["reset", "ScreenCapture", identifier])
            XCTAssertEqual(try HostPermissionRepair.resetArguments(for: .accessibility, bundleIdentifier: identifier),
                           ["reset", "Accessibility", identifier])
            XCTAssertThrowsError(try HostPermissionRepair.resetArguments(for: .microphone, bundleIdentifier: identifier))
        }
        XCTAssertThrowsError(try HostPermissionRepair.resetArguments(for: .screenRecording, bundleIdentifier: "com.example.other"))
    }

    func testFixResetsOnlyMissingPermissionThenRequestsAndOpensItsPane() async throws {
        for permission in [PermissionKind.screenRecording, .accessibility] {
            var actions: [String] = []
            try await HostPermissionRepair.fix(permission, isGranted: { false }, reset: {
                XCTAssertEqual($0, permission)
                actions.append("reset")
            }, request: {
                XCTAssertEqual($0, permission)
                actions.append("request")
            }, openSettings: {
                XCTAssertEqual($0, permission)
                actions.append("settings")
            })
            XCTAssertEqual(actions, ["reset", "request", "settings"])
        }
    }

    func testFixDoesNothingIfGrantArrivedBeforeClick() async throws {
        try await HostPermissionRepair.fix(.accessibility, isGranted: { true }, reset: { _ in
            XCTFail("An existing grant must not be reset")
        }, request: { _ in XCTFail("An existing grant must not be requested") },
           openSettings: { _ in XCTFail("Ready must not open Settings") })
    }

    func testFailedFixReopensPaneWithoutClaimingFreshEntry() async {
        var actions: [String] = []
        do {
            try await HostPermissionRepair.fix(.accessibility, isGranted: { false }, reset: { _ in
                actions.append("reset")
                throw HostPermissionRepair.RepairError.unavailable
            }, request: { _ in actions.append("request") }, openSettings: { _ in actions.append("settings") })
            XCTFail("A failed reset must reach the illustrated fallback")
        } catch {
            XCTAssertEqual(actions, ["reset", "settings"])
        }
    }

    func testUnitTestsCannotResetAnyRealPermission() async {
        do {
            try await HostPermissionRepair.resetOwnGrant(for: .screenRecording)
            XCTFail("Permission reset must never run in the test host")
        } catch HostPermissionRepair.RepairError.unavailable {
            // The production entry point fails before launching tccutil.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "HostSetupPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}
