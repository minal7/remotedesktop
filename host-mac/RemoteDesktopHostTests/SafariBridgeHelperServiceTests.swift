import ServiceManagement
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class SafariBridgeHelperServiceTests: XCTestCase {
    func testEnabledStatusDoesNotRegisterOrOpenSettings() throws {
        var registrations = 0
        var settings = 0
        let result = try SafariBridgeHelperService.ensureRegistered(
            status: { .enabled },
            register: { registrations += 1 },
            openSettings: { settings += 1 })
        XCTAssertEqual(result, "enabled")
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settings, 0)
    }

    func testNotRegisteredCallsRegisterAndChecksResultingStatus() throws {
        var current = SafariBridgeHelperService.Status.notRegistered
        var registrations = 0
        let result = try SafariBridgeHelperService.ensureRegistered(
            status: { current },
            register: { registrations += 1; current = .enabled },
            openSettings: { XCTFail("Settings should not open for a successful registration") })
        XCTAssertEqual(result, "enabled")
        XCTAssertEqual(registrations, 1)
    }

    func testNotFoundIsDistinctFromNotRegistered() {
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .notFound },
            register: { XCTFail("Missing bundled helper must not register") },
            openSettings: { XCTFail("Missing helper must not open settings") })) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError, .helperMissingFromBundle)
            }
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .notRegistered },
            register: {},
            openSettings: { XCTFail("Unregistered helper must not open settings") })) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError, .helperNotRegistered)
            }
    }

    func testNotFoundRegistersWhenBundledHelperIsVerified() throws {
        var status = SafariBridgeHelperService.Status.notFound
        var registrations = 0
        var settings = 0
        let result = try SafariBridgeHelperService.ensureRegistered(
            status: { status },
            register: { registrations += 1; status = .enabled },
            openSettings: { settings += 1 },
            verifiedBundleContainsHelper: true)
        XCTAssertEqual(result, "enabled")
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settings, 0)
    }

    func testNotFoundAfterRegistrationIsMissingAndAbsentPackageNeverRegisters() {
        var registrations = 0
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .notFound },
            register: { registrations += 1 },
            openSettings: { XCTFail("Missing bundle must not open settings") },
            verifiedBundleContainsHelper: false)) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError, .helperMissingFromBundle)
            }
        XCTAssertEqual(registrations, 0)

        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .notFound },
            register: { registrations += 1 },
            openSettings: { XCTFail("Unsuccessful registration must not open settings") },
            verifiedBundleContainsHelper: true)) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError, .helperMissingFromBundle)
            }
        XCTAssertEqual(registrations, 1)
    }

    func testNotFoundRegistrationFailurePreservesNSErrorDomainAndCode() {
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .notFound },
            register: { throw NSError(domain: "SMAppServiceNotFound", code: 91) },
            openSettings: { XCTFail("A failed registration without approval must not open settings") },
            verifiedBundleContainsHelper: true)) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError,
                    .registrationFailed(domain: "SMAppServiceNotFound", code: 91))
            }
    }

    func testRequiresApprovalOpensLoginItemsExactlyOnceAndGivesSetupPath() {
        var settings = 0
        let settingsGate = SafariBridgeHelperService.SettingsGate()
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .requiresApproval },
            register: { XCTFail("Approval-required helper must not be registered again") },
            openSettings: { settings += 1 }, settingsGate: settingsGate)) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError, .helperRequiresApproval)
                XCTAssertEqual(error.localizedDescription,
                    "System Settings → General → Login Items & Extensions → allow Remote Desktop Host")
            }
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .requiresApproval },
            register: { XCTFail("Approval-required helper must not be registered again") },
            openSettings: { settings += 1 }, settingsGate: settingsGate))
        XCTAssertEqual(settings, 1)
    }

    func testRegistrationErrorThatChangesStatusToApprovalUsesLoginItemsHandoff() {
        var status = SafariBridgeHelperService.Status.notRegistered
        var settings = 0
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { status },
            register: {
                status = .requiresApproval
                throw NSError(domain: "SMAppServiceFixture", code: 73)
            },
            openSettings: { settings += 1 }, settingsGate: SafariBridgeHelperService.SettingsGate())) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError, .helperRequiresApproval)
            }
        XCTAssertEqual(settings, 1)
    }

    func testRegistrationFailurePreservesNSErrorDomainAndCode() {
        XCTAssertThrowsError(try SafariBridgeHelperService.ensureRegistered(
            status: { .notRegistered },
            register: { throw NSError(domain: "SMAppServiceFixture", code: 73) },
            openSettings: { XCTFail("A registration error is not an approval result") })) { error in
                XCTAssertEqual(error as? SafariBridgeHelperServiceError,
                    .registrationFailed(domain: "SMAppServiceFixture", code: 73))
                XCTAssertTrue(error.localizedDescription.contains("SMAppServiceFixture"))
                XCTAssertTrue(error.localizedDescription.contains("73"))
            }
    }

    func testStatusNamesMatchPublicSMAppServiceStates() {
        XCTAssertEqual(SafariBridgeHelperService.statusName(for: .enabled), "enabled")
        XCTAssertEqual(SafariBridgeHelperService.statusName(for: .notRegistered), "notRegistered")
        XCTAssertEqual(SafariBridgeHelperService.statusName(for: .requiresApproval), "requiresApproval")
        XCTAssertEqual(SafariBridgeHelperService.statusName(for: .notFound), "notFound")
    }
}
