#if DEBUG
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentEvalPreflightTests: XCTestCase {
    private let probeURL = "http://127.0.0.1:8765/forms.html?__eval_run=0123456789abcdef0123456789abcdef"

    func testRequestRequiresExactLoopbackProbeShape() throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        XCTAssertEqual(request.operation, "preflight")
        XCTAssertEqual(request.probeURL, probeURL)
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"https://example.test\"}".utf8)))
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1/\",\"task_id\":\"x\"}".utf8)))
    }

    func testPermissionFailureStopsBeforeHelperSafariOrModel() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var laterCheckCalled = false
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { false }, screenRecordingCheck: { true },
            helperCheck: { laterCheckCalled = true; return "enabled" },
            safariProbe: { _ in laterCheckCalled = true; return .init(extensionStatus: "enabled", sampleCount: 100, p95Milliseconds: 1) },
            modelCheck: { laterCheckCalled = true; return nil })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.blockedReason, "Accessibility or input control permission is unavailable.")
        XCTAssertTrue(response.ownerAction?.contains("Accessibility") == true)
        XCTAssertFalse(response.ownerAction?.contains("Input Monitoring") == true)
        XCTAssertEqual(response.checks.map(\.name), ["host_process", "accessibility"])
        XCTAssertFalse(laterCheckCalled)
    }

    func testHelperApprovalUsesExactOwnerActionAndStopsLaterChecks() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var laterCheckCalled = false
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            helperCheck: { throw SafariBridgeHelperServiceError.helperRequiresApproval },
            safariProbe: { _ in
                laterCheckCalled = true
                return .init(extensionStatus: "enabled", sampleCount: 100, p95Milliseconds: 1)
            },
            modelCheck: { laterCheckCalled = true; return nil })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.last?.name, "safari_helper")
        XCTAssertEqual(response.ownerAction, SafariBridgeHelperServiceError.helperRequiresApproval.localizedDescription)
        XCTAssertTrue(response.blockedReason?.contains("status:") == true)
        XCTAssertFalse(laterCheckCalled)
    }

    func testHelperFailureStopsBeforeSafariOrModel() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var laterCheckCalled = false
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            helperCheck: { throw SafariBridgeHelperServiceError.registrationFailed(domain: "Test", code: 7) },
            safariProbe: { _ in
                laterCheckCalled = true
                return .init(extensionStatus: "enabled", sampleCount: 100, p95Milliseconds: 1)
            },
            modelCheck: { laterCheckCalled = true; return nil })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.last?.name, "safari_helper")
        XCTAssertTrue(response.blockedReason?.contains("Test, code 7") == true)
        XCTAssertTrue(response.blockedReason?.contains("status:") == true)
        XCTAssertTrue(response.ownerAction?.contains("developer") == true)
        XCTAssertFalse(laterCheckCalled)
    }

    func testSuccessfulPreflightRequiresBoundTabPingsAndRuntimeHealth() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var probedURL: String?
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            helperCheck: { "enabled" },
            safariProbe: { url in
                probedURL = url
                return .init(extensionStatus: "enabled", sampleCount: 100, p95Milliseconds: 12.5)
            },
            modelCheck: { nil })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(probedURL, probeURL)
        XCTAssertEqual(response.outcome, "ready")
        XCTAssertEqual(response.checks.map(\.status), ["passed", "passed", "passed", "passed", "passed", "passed"])
        XCTAssertEqual(response.safariPingCount, 100)
        XCTAssertEqual(response.safariPingP95Milliseconds, 12.5)
        XCTAssertEqual(response.modelStatus, "loaded")
    }

    func testSafariProbeFailureStopsBeforeStartingModel() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var modelStarted = false
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            helperCheck: { "enabled" },
            safariProbe: { _ in throw TestFailure.probe },
            modelCheck: { modelStarted = true; return nil })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.last?.name, "safari_extension")
        XCTAssertFalse(modelStarted)
    }

    private func requestData() -> Data {
        Data("{\"operation\":\"preflight\",\"probe_url\":\"\(probeURL)\"}".utf8)
    }

    private enum TestFailure: Error { case probe }
}
#endif
