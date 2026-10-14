#if DEBUG
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentEvalPreflightTests: XCTestCase {
    private let probeURL = "http://127.0.0.1:8765/forms.html?__eval_run=0123456789abcdef0123456789abcdef"

    func testSuiteCleanStartRoleFilterOnlyCountsWindowRoles() {
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXWindow"), .window)
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXDialog"), .window)
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXSheet"), .window)
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXScrollArea"), .nonWindow)
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXUnrecognizedRole"), .unknown)
    }

    func testRequestRequiresExactLoopbackProbeAndSupportedPolicy() throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        XCTAssertEqual(request.operation, "preflight")
        XCTAssertEqual(request.probeURL, probeURL)
        XCTAssertEqual(request.policy, "fara15-4b")
        XCTAssertEqual(request.trustSeeds, [
            .init(kind: "app", identity: "Finder"), .init(kind: "app", identity: "Notes"),
            .init(kind: "app", identity: "Safari"), .init(kind: "app", identity: "TextEdit"),
            .init(kind: "web", identity: "http://127.0.0.1:8765"),
        ])
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"https://example.test\"}".utf8)))
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1/\",\"task_id\":\"x\"}".utf8)))
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1/\",\"policy\":\"unknown\"}".utf8)))
        for invalid in ["http://127.0.0.1:8765@evil.test", "http://127.0.0.1:9999", "https://127.0.0.1:8765"] {
            let body = "{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1:8765/\",\"trust_seeds\":[{\"kind\":\"app\",\"identity\":\"Safari\"},{\"kind\":\"web\",\"identity\":\"\(invalid)\"}]}"
            XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(Data(body.utf8)))
        }
    }

    func testPermissionFailureStopsBeforePixelOrModel() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var laterCheckCalled = false
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { false }, screenRecordingCheck: { true },
            pixelReadinessCheck: { laterCheckCalled = true; return .init(ready: true, detail: "ok") },
            modelCheck: { _ in laterCheckCalled = true; return nil }, trustSeeder: { _ in XCTFail("must not seed"); return .init(trustedSurfaces: [], storePath: "") })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.map(\.name), ["host_process", "accessibility"])
        XCTAssertEqual(response.checks.last?.status, "blocked")
        XCTAssertTrue(response.ownerAction?.contains("Accessibility") == true)
        XCTAssertFalse(response.ownerAction?.contains("Input Monitoring") == true)
        XCTAssertEqual(response.activeEnvironment, "pixel")
        XCTAssertFalse(laterCheckCalled)
    }

    func testPixelReadinessFailureStopsBeforeModel() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        var modelStarted = false
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            pixelReadinessCheck: { .init(ready: false, detail: "capture unavailable") },
            modelCheck: { _ in modelStarted = true; return nil }, trustSeeder: { _ in XCTFail("must not seed"); return .init(trustedSurfaces: [], storePath: "") })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.last?.name, "pixel_environment")
        XCTAssertEqual(response.checks.last?.status, "blocked")
        XCTAssertFalse(modelStarted)
    }

    func testSuccessfulPreflightChecksSelectedModelRuntimeHealth() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData(policy: "ui-tars15-7b"))
        var checkedModel: AgentPolicyModel?
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            pixelReadinessCheck: { .init(ready: true, detail: "Pixel ready") },
            modelCheck: { model in checkedModel = model; return nil }, trustSeeder: seedReceipts)
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(checkedModel, .uiTars15_7b)
        XCTAssertEqual(response.outcome, "ready")
        XCTAssertEqual(response.activeEnvironment, "pixel")
        XCTAssertEqual(response.policy, "ui-tars15-7b")
        XCTAssertEqual(response.modelStatus, "loaded")
        XCTAssertEqual(response.checks.map(\.name),
            ["host_process", "accessibility", "screen_recording", "pixel_environment", "model", "trust"])
        XCTAssertTrue(response.checks.allSatisfy { $0.status == "passed" })
        XCTAssertEqual(response.trustedSurfaces.count, 5)
        XCTAssertTrue(response.trustStorePath.hasSuffix("RemoteDesktopHost/AgentTrust"))
    }

    func testModelFailureIsReportedWithoutClaimingReadiness() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            pixelReadinessCheck: { .init(ready: true, detail: "Pixel ready") },
            modelCheck: { _ in "server health check failed" }, trustSeeder: { _ in XCTFail("must not seed"); return .init(trustedSurfaces: [], storePath: "") })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.last?.name, "model")
        XCTAssertEqual(response.modelStatus, "failed")
        XCTAssertTrue(response.blockedReason?.contains("server health check failed") == true)
    }

    func testPreflightSeedIsVisibleToAnotherTaskUsingSamePersistentStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("AgentTrust", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            pixelReadinessCheck: { .init(ready: true, detail: "Pixel ready") },
            modelCheck: { _ in nil },
            trustSeeder: { seeds in
                let store = try AgentHostFactory.persistentTrustStore(directory: directory)
                let bundles = ["Safari": "com.apple.Safari", "TextEdit": "com.apple.TextEdit",
                               "Finder": "com.apple.finder", "Notes": "com.apple.Notes"]
                let receipts = try seeds.map { seed -> AgentEvalTrustReceipt in
                    let identity = seed.kind == "app" ? bundles[seed.identity]! : seed.identity
                    let kind = AgentScope.Kind(rawValue: seed.kind)!
                    try store.markTrusted(kind: kind, identity: identity)
                    XCTAssertTrue(try store.isTrusted(kind: kind, identity: identity))
                    return .init(kind: seed.kind, identity: identity)
                }
                return .init(trustedSurfaces: receipts, storePath: directory.path)
            })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "ready")
        XCTAssertEqual(response.trustedSurfaces.count, 5)
        let taskStore = try AgentHostFactory.persistentTrustStore(directory: directory)
        for identity in ["com.apple.Safari", "com.apple.TextEdit", "com.apple.finder", "com.apple.Notes"] {
            XCTAssertTrue(try taskStore.isTrusted(kind: .app, identity: identity))
        }
        XCTAssertTrue(try taskStore.isTrusted(kind: .web, identity: "http://127.0.0.1:8765"))
        let scope = AgentScope(taskID: "different-run", kind: .app, identity: "com.apple.Safari")
        let target = AgentElement(id: 1, role: "button", name: "Open", value: nil, state: ["enabled"],
                                  bbox: .init(x: 1, y: 1, width: 10, height: 10), inView: true)
        let observation = AgentObservation(task: "Open the app", surface: .app(bundleID: "com.apple.Safari", title: nil),
            screenshot: "", elements: [target], focus: nil, history: [], budget: .init(step: 0, maxSteps: 30))
        let gate = AgentActionGate(trustStore: taskStore, allowPolicy: PreflightTestAllowPolicy())
        let result = try gate.evaluate(.init(action: .click(target: .element(id: 1), button: nil, count: nil),
            frame: .init(observation: observation, scope: scope), targets: [target]), expectedScope: scope)
        XCTAssertEqual(result.result.decision, .allowed)
        XCTAssertTrue(response.trustStorePath.hasSuffix("AgentTrust"))
    }

    private func requestData(policy: String = "fara15-4b") -> Data {
        let seeds = #"[{"kind":"app","identity":"Finder"},{"kind":"app","identity":"Notes"},{"kind":"app","identity":"Safari"},{"kind":"app","identity":"TextEdit"},{"kind":"web","identity":"http://127.0.0.1:8765"}]"#
        return Data("{\"operation\":\"preflight\",\"probe_url\":\"\(probeURL)\",\"policy\":\"\(policy)\",\"trust_seeds\":\(seeds)}".utf8)
    }

    private func seedReceipts(_ seeds: [AgentEvalTrustSeed]) throws -> AgentEvalTrustSeedResult {
        let bundles = ["Safari": "com.apple.Safari", "TextEdit": "com.apple.TextEdit", "Finder": "com.apple.finder", "Notes": "com.apple.Notes"]
        let receipts = seeds.map { AgentEvalTrustReceipt(kind: $0.kind, identity: $0.kind == "app" ? bundles[$0.identity]! : $0.identity) }
        return .init(trustedSurfaces: receipts,
                     storePath: "/Users/test/Library/Application Support/RemoteDesktopHost/AgentTrust")
    }
}

@MainActor
private final class PreflightTestAllowPolicy: AgentAllowPolicy {
    func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
    func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? { nil }
}
#endif
