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
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXHelpTag"), .nonWindow)
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXTextField"), .unknown)
        XCTAssertEqual(SuiteCleanStartWindowRole.classify("AXUnrecognizedRole"), .unknown)
    }

    func testSystemVoiceOverlayResetAllowsOneEscapeThenRequiresOwnerIfItPersists() {
        var escapeCount = 0
        func inspect(_ present: Bool) -> SystemVoiceOverlayDecision {
            switch ElementMarks.overlayDecision(isPresent: present, escapeAlreadySent: escapeCount > 0) {
            case .proceed: return .proceed
            case .dismissOnce:
                escapeCount += 1
                return .dismissOnce
            case .handoff: return .handoff
            }
        }

        XCTAssertEqual(inspect(false), .proceed)
        XCTAssertEqual(inspect(true), .dismissOnce) // Overlay appeared after the first precheck.
        XCTAssertEqual(escapeCount, 1)
        XCTAssertEqual(inspect(true), .handoff) // A persistent overlay cannot cause another Escape.
        XCTAssertEqual(escapeCount, 1)
    }

    func testSystemVoiceOverlayFailuresDoNotMisreportBackgroundOrUnknownStateAsDismissal() {
        XCTAssertEqual(SystemVoiceOverlayFailure.notFrontmost.environmentError, .scopeChanged)
        XCTAssertEqual(SystemVoiceOverlayFailure.secureFocus.environmentError, .credentialHandoff)
        XCTAssertEqual(SystemVoiceOverlayFailure.inspectionUnavailable.environmentError,
            .unavailable("Accessibility could not verify the system overlay state."))
        XCTAssertEqual(SystemVoiceOverlayFailure.persists.environmentError,
            .systemHandoff("A system voice overlay is open on your Mac; close it and tap Resume"))
    }

    func testOnlyModalOrFocusedSystemOverlayBlocksInput() {
        XCTAssertEqual(ElementMarks.overlayInputState(modal: false, focused: false), .nonblocking)
        XCTAssertEqual(ElementMarks.overlayInputState(modal: false, focused: true), .blocking)
        XCTAssertEqual(ElementMarks.overlayInputState(modal: true, focused: false), .blocking)
        XCTAssertEqual(ElementMarks.overlayInputState(modal: true, focused: nil), .blocking)
        XCTAssertEqual(ElementMarks.overlayInputState(modal: false, focused: nil), .unknown)
        XCTAssertEqual(ElementMarks.overlayInputState(modal: nil, focused: false), .unknown)
        XCTAssertEqual(ElementMarks.overlayInputState(modal: nil, focused: nil), .unknown)
    }

    func testRequestRequiresExactLoopbackProbeAndSupportedPolicy() throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        XCTAssertEqual(request.operation, "preflight")
        XCTAssertEqual(request.probeURL, probeURL)
        XCTAssertEqual(request.policy, "fara15-4b")
        XCTAssertEqual(request.trustSeeds, [
            .init(kind: "app", identity: "Finder"), .init(kind: "app", identity: "Notes"),
            .init(kind: "app", identity: "Safari"), .init(kind: "app", identity: "TextEdit"),
            .init(kind: "web", identity: "https://www.google.com"),
            .init(kind: "web", identity: "http://127.0.0.1:8765"),
        ])
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"https://example.test\"}".utf8)))
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1/\",\"task_id\":\"x\"}".utf8)))
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(
            Data("{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1/\",\"policy\":\"unknown\"}".utf8)))
        for invalid in ["http://127.0.0.1:8765@evil.test", "http://127.0.0.1:9999", "https://127.0.0.1:8765",
                        "https://example.test/path", "https://user@example.test", "https://example.test#fragment",
                        "https://example.test:443", "https://example.test:8443", "https://EXAMPLE.test", "ftp://example.test",
                        "https://exa_mple.test", "https://example.test%2f.evil", "https://[2001:db8::1]"] {
            let body = "{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1:8765/\",\"trust_seeds\":[{\"kind\":\"app\",\"identity\":\"Safari\"},{\"kind\":\"web\",\"identity\":\"\(invalid)\"}]}"
            XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(Data(body.utf8)))
        }
        let duplicate = "{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1:8765/\",\"trust_seeds\":[{\"kind\":\"web\",\"identity\":\"https://example.test\"},{\"kind\":\"web\",\"identity\":\"https://example.test\"}]}"
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(Data(duplicate.utf8)))
        let unknownKind = "{\"operation\":\"preflight\",\"probe_url\":\"http://127.0.0.1:8765/\",\"trust_seeds\":[{\"kind\":\"other\",\"identity\":\"https://example.test\"}]}"
        XCTAssertThrowsError(try AgentEvalPreflightRequest.decodeStrict(Data(unknownKind.utf8)))
    }

    func testFocusProbeRequestAcceptsOnlyOnePositiveIntegerPID() throws {
        let valid = Data("{\"operation\":\"focus_probe\",\"expected_pid\":1234}".utf8)
        XCTAssertEqual(try AgentEvalFocusProbeRequest.decodeStrict(valid).expectedPID, 1234)
        for body in [
            "{\"operation\":\"focus_probe\",\"expected_pid\":true}",
            "{\"operation\":\"focus_probe\",\"expected_pid\":0}",
            "{\"operation\":\"focus_probe\",\"expected_pid\":-1}",
            "{\"operation\":\"focus_probe\",\"expected_pid\":1.5}",
            "{\"operation\":\"focus_probe\",\"expected_pid\":2147483648}",
            "{\"operation\":\"focus_probe\",\"expected_pid\":1234,\"url\":\"https://example.test\"}",
            "{\"operation\":\"preflight\",\"expected_pid\":1234}",
        ] {
            XCTAssertThrowsError(try AgentEvalFocusProbeRequest.decodeStrict(Data(body.utf8)), body)
        }
    }

    func testFocusProbeSkippedReadDoesNotInventAXError() {
        let skipped = AgentEvalFocusProbeAttribute.skipped("deadline elapsed")
        XCTAssertFalse(skipped.attempted)
        XCTAssertNil(skipped.timeoutSetErrorCode)
        XCTAssertNil(skipped.axErrorCode)
        XCTAssertNil(skipped.typeValid)
        XCTAssertEqual(skipped.reason, "deadline elapsed")
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
        XCTAssertEqual(response.trustedSurfaces.count, 6)
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

    func testPreflightRejectsTrustReceiptsThatDoNotExactlyMatchRequestedSeeds() async throws {
        let request = try AgentEvalPreflightRequest.decodeStrict(requestData())
        let dependencies = AgentEvalPreflightDependencies(
            signedHostCheck: { true }, accessibilityCheck: { true }, screenRecordingCheck: { true },
            pixelReadinessCheck: { .init(ready: true, detail: "Pixel ready") },
            modelCheck: { _ in nil }, trustSeeder: { seeds in
                let matching = try self.seedReceipts(seeds)
                var receipts = matching.trustedSurfaces
                receipts[0] = .init(kind: "app", identity: "org.example.Unrequested")
                return .init(trustedSurfaces: receipts, storePath: matching.storePath)
            })
        let response = await AgentEvalPreflight.run(request, dependencies: dependencies)
        XCTAssertEqual(response.outcome, "infra_blocked")
        XCTAssertEqual(response.checks.last?.name, "trust")
        XCTAssertEqual(response.trustedSurfaces, [])
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
        XCTAssertEqual(response.trustedSurfaces.count, 6)
        let taskStore = try AgentHostFactory.persistentTrustStore(directory: directory)
        for identity in ["com.apple.Safari", "com.apple.TextEdit", "com.apple.finder", "com.apple.Notes"] {
            XCTAssertTrue(try taskStore.isTrusted(kind: .app, identity: identity))
        }
        XCTAssertTrue(try taskStore.isTrusted(kind: .web, identity: "http://127.0.0.1:8765"))
        XCTAssertTrue(try taskStore.isTrusted(kind: .web, identity: "https://www.google.com"))
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
        let seeds = #"[{"kind":"app","identity":"Finder"},{"kind":"app","identity":"Notes"},{"kind":"app","identity":"Safari"},{"kind":"app","identity":"TextEdit"},{"kind":"web","identity":"https://www.google.com"},{"kind":"web","identity":"http://127.0.0.1:8765"}]"#
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
