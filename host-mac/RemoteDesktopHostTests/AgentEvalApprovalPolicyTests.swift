#if DEBUG
import Foundation
import XCTest
@testable import RemoteDesktopHost

final class AgentEvalApprovalPolicyTests: XCTestCase {
    func testFixtureCommitApprovalBindsTaskScopeFingerprintAndOrigin() throws {
        let request = try makeRequest(start: "http://127.0.0.1:8765/page", flags: [
            "allow_fixture_interaction": true, "allow_fixture_commit": true,
        ])
        let valid = candidate(request: request, action: .click(target: .element(id: 1), button: nil, count: nil),
            currentURL: "http://127.0.0.1:8765/other")
        XCTAssertTrue(AgentEvalApprovalPolicy.permits(valid, request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, approvalScope: "stale"), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, fingerprint: "bad"), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, currentURL: "http://127.0.0.1:8766/page"), request: request))
    }

    func testSecureTargetsAndUnknownHighRiskActionsNeverAutoApprove() throws {
        let request = try makeRequest(start: "http://127.0.0.1:8765/page", flags: [
            "allow_fixture_interaction": true, "allow_fixture_commit": true,
        ])
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, hasSensitiveTarget: true), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request,
            action: .done(answer: "finished")), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, riskTier: "unknown"), request: request))
    }

    func testSyntheticSetFilesNeedsExplicitFixtureCommitAndFixtureRoot() throws {
        let fixtureRequest = try makeRequest(start: "http://127.0.0.1:8765/upload", flags: [
            "allow_fixture_interaction": true, "allow_fixture_commit": true,
        ])
        let action = AgentAction.setFiles(target: .element(id: 2), fileIDs: ["opaque-file-id"])
        XCTAssertTrue(AgentEvalApprovalPolicy.permits(candidate(request: fixtureRequest,
            action: action, hasSyntheticFileRoot: true), request: fixtureRequest))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: fixtureRequest,
            action: action, hasSyntheticFileRoot: false), request: fixtureRequest))
        let publicRequest = try makeRequest(start: "https://example.org/upload", flags: ["allow_start_interaction": true])
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: publicRequest,
            action: action, hasSyntheticFileRoot: true), request: publicRequest))
    }

    func testPublicStartFlagNeverAutoApprovesActions() throws {
        let request = try makeRequest(start: "https://example.org/docs", flags: ["allow_start_interaction": true])
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request,
            action: .scroll(target: nil, direction: .down, amount: 1), riskTier: "medium"), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request,
            action: .click(target: .element(id: 1), button: nil, count: nil), riskTier: "medium",
            targetRoles: ["link"]), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request,
            action: .click(target: .element(id: 1), button: nil, count: nil), riskTier: "medium",
            targetRoles: ["button"]), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request,
            action: .type(target: nil, text: "value", mode: .append), riskTier: "medium"), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request,
            action: .openURL(url: "https://other.example/"), riskTier: "low"), request: request))
    }

    func testFixtureApprovalRequiresExplicitInteractionFlagAtEveryRisk() throws {
        let missing = try makeRequest(start: "http://127.0.0.1:8765/page", flags: ["allow_fixture_commit": true])
        for risk in ["low", "medium", "high"] {
            XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: missing, riskTier: risk), request: missing), risk)
        }
        let interactionOnly = try makeRequest(start: "http://127.0.0.1:8765/page", flags: ["allow_fixture_interaction": true])
        XCTAssertTrue(AgentEvalApprovalPolicy.permits(candidate(request: interactionOnly, riskTier: "medium"), request: interactionOnly))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: interactionOnly, riskTier: "high"), request: interactionOnly))
    }

    func testOnlyExactIPv4LoopbackFixtureOriginCanBeAutoApproved() throws {
        XCTAssertThrowsError(try makeRequest(start: "http://[::1]:8765/page", flags: [
            "allow_fixture_interaction": true, "allow_fixture_commit": true,
        ]))
        for url in ["http://localhost:8765/page", "https://127.0.0.1:8765/page", "https://example.org/page"] {
            let request = try makeRequest(start: url, flags: ["allow_fixture_interaction": true, "allow_fixture_commit": true])
            for risk in ["low", "medium", "high"] {
                XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, riskTier: risk), request: request), "\(url) \(risk)")
            }
        }
    }

    func testNativeStartApprovalIsBoundToResolvedStartAppAndLowOrMediumRisk() throws {
        let request = try appRequest(start: "TextEdit")
        let allowed = candidate(request: request,
            action: .type(target: nil, text: "Draft", mode: .replace), riskTier: "medium", currentURL: nil,
            currentApp: "com.apple.TextEdit", expectedApp: "com.apple.TextEdit")
        XCTAssertTrue(AgentEvalApprovalPolicy.permits(allowed, request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, riskTier: "high",
            currentURL: nil, currentApp: "com.apple.TextEdit", expectedApp: "com.apple.TextEdit"), request: request))
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: request, riskTier: "low",
            currentURL: nil, currentApp: "com.apple.finder", expectedApp: "com.apple.TextEdit"), request: request))
        let unapproved = try appRequest(start: "TextEdit", flags: [:])
        XCTAssertFalse(AgentEvalApprovalPolicy.permits(candidate(request: unapproved, riskTier: "medium",
            currentURL: nil, currentApp: "com.apple.TextEdit", expectedApp: "com.apple.TextEdit"), request: unapproved))
    }

    private func makeRequest(start: String, flags: [String: Bool]) throws -> AgentEvalRequest {
        var value: [String: Any] = ["task_id": "eval-task", "prompt": "Read the current page",
            "start": ["url": start], "max_steps": 10, "policy": "fara15-4b"]
        value["approval_policy"] = flags
        return try AgentEvalRequest.decodeStrict(JSONSerialization.data(withJSONObject: value))
    }

    private func appRequest(start: String, flags: [String: Bool] = ["allow_start_interaction": true]) throws -> AgentEvalRequest {
        var value: [String: Any] = ["task_id": "eval-task", "prompt": "Read the current page",
            "start": ["app": start], "max_steps": 10, "policy": "fara15-4b"]
        if !flags.isEmpty { value["approval_policy"] = flags }
        return try AgentEvalRequest.decodeStrict(JSONSerialization.data(withJSONObject: value))
    }

    private func candidate(request: AgentEvalRequest, action: AgentAction = .key(chord: "Enter"),
                           riskTier: String = "high", currentURL: String? = nil,
                           approvalScope: String = "tab-id", resolvedScope: String = "tab-id",
                           fingerprint: String = String(repeating: "a", count: 64),
                           currentApp: String? = nil, expectedApp: String? = nil,
                           targetRoles: [String] = [], hasSensitiveTarget: Bool = false,
                           hasSyntheticFileRoot: Bool = false) -> AgentEvalApprovalCandidate {
        AgentEvalApprovalCandidate(taskID: request.taskID, requestID: UUID().uuidString,
            fingerprint: fingerprint, approvalScope: approvalScope, resolvedScope: resolvedScope,
            riskTier: riskTier, action: action, currentURL: currentURL ?? request.start.url,
            expectedURL: request.start.url, currentApp: currentApp, expectedApp: expectedApp,
            targetRoles: targetRoles,
            hasSensitiveTarget: hasSensitiveTarget, hasSyntheticFileRoot: hasSyntheticFileRoot)
    }
}
#endif
