#if DEBUG
import Foundation
import XCTest
@testable import RemoteDesktopHost

final class AgentEvalWireTests: XCTestCase {
    func testCoordinateCalibrationIdentityRequiresNearestActionableMarkWithinFiveAncestors() {
        let passive = (false, false)
        let expected = (true, true)
        let actionableSibling = (false, true)
        func classify(_ ancestors: [(Bool, Bool)], exact: Bool = false, hitActionable: Bool = false,
                      geometry: Bool = true, window: Bool = true) -> CoordinateCalibrationIdentityResult {
            CoordinateCalibrationIdentityMatcher.classify(geometryValid: geometry,
                selectedWindowHit: window, exact: exact, hitIsActionable: hitActionable,
                ancestors: ancestors)
        }

        XCTAssertEqual(classify([], exact: true, hitActionable: true), .exact)
        for depth in 1...5 {
            XCTAssertEqual(classify(Array(repeating: passive, count: depth - 1) + [expected]),
                .descendant(depth: depth))
        }
        XCTAssertEqual(classify(Array(repeating: passive, count: 5) + [expected]), .rejected)
        XCTAssertEqual(classify([passive, actionableSibling, expected]), .rejected)
        XCTAssertEqual(classify([actionableSibling, expected]), .rejected)
        XCTAssertEqual(classify([], exact: true, hitActionable: true, window: false), .rejected)
        XCTAssertEqual(classify([], exact: true, hitActionable: true, geometry: false), .rejected)
        XCTAssertEqual(classify([], exact: true, hitActionable: false), .exact)
        XCTAssertEqual(classify([(true, false)]), .rejected)
    }

    @MainActor
    func testCleanStartIsEnabledOnlyByEvaluationConfiguration() throws {
        XCTAssertFalse(AgentHostFactory.Configuration().requireCleanStart)
        let request = try decode(#"{"task_id":"eval_clean_start","prompt":"Read this page","start":{"url":"http://127.0.0.1:8765/read.html"},"max_steps":2,"policy":"fara15-4b"}"#)
        XCTAssertTrue(request.hostConfiguration(storageDirectory: URL(fileURLWithPath: "/tmp/eval-clean-start"))
            .requireCleanStart)
        XCTAssertTrue(AgentEvalFirstObservation.requiresStartValidation(configured: true, isInitialObservation: true))
        XCTAssertFalse(AgentEvalFirstObservation.requiresStartValidation(configured: true, isInitialObservation: false))
    }

    @MainActor
    func testStartReceiptPrefersRawAccessibilityURLWhileRuntimeURLStaysSanitized() {
        let raw = "https://example.test/form?run=alpha#section"
        let runtime = "https://example.test/form"
        XCTAssertEqual(AgentEvalFirstObservation.startURLCandidate(axURL: raw as CFString,
            documentURL: "https://example.test/other" as CFString, sanitizedURL: runtime), raw)
        XCTAssertEqual(AgentEvalFirstObservation.startURLCandidate(axURL: nil,
            documentURL: URL(string: raw)! as CFURL, sanitizedURL: runtime), raw)
        XCTAssertEqual(AgentEvalFirstObservation.startURLCandidate(axURL: nil,
            documentURL: nil, sanitizedURL: runtime), runtime)
        XCTAssertEqual(ElementMarks.safeURL(raw as CFString), runtime)
        XCTAssertTrue(AgentEvalFirstObservation.matchesStart(expectedBundleID: "org.example.browser",
            observedBundleID: "org.example.browser", expectedURL: raw,
            observedURL: AgentEvalFirstObservation.startURLCandidate(axURL: raw as CFString,
                documentURL: nil, sanitizedURL: runtime)))
        XCTAssertFalse(AgentEvalFirstObservation.matchesStart(expectedBundleID: "org.example.browser",
            observedBundleID: "org.example.browser", expectedURL: raw,
            observedURL: AgentEvalFirstObservation.startURLCandidate(axURL: "https://example.test/form?run=beta" as CFString,
                documentURL: raw as CFString, sanitizedURL: runtime)))
    }

    @MainActor
    func testCleanStartDiscardsOnlyAnOwnedFixtureLossPrompt() {
        XCTAssertTrue(SuiteCleanStart.ownsLoopbackFixtureWindow(
            url: "http://127.0.0.1:8765/forms.html?__eval_run=0123456789abcdef0123456789abcdef"))
        for url in [nil, "http://127.0.0.1:8765/forms.html", "http://localhost:8765/forms.html?__eval_run=x",
                    "http://127.0.0.1:8766/forms.html?__eval_run=x", "http://127.0.0.1:8765/forms.html?__eval_run="] {
            XCTAssertFalse(SuiteCleanStart.ownsLoopbackFixtureWindow(url: url))
        }

        let message = "You have entered text. If you close the window, your changes will be lost. Do you want to close the window anyway?"
        XCTAssertEqual(SuiteCleanStart.discardButton(prompt: message, buttonTitles: ["Cancel", "Close"]), "Close")
        XCTAssertEqual(SuiteCleanStart.discardButton(prompt: message, buttonTitles: ["Cancel", "Don't Save"]), "Don't Save")
        XCTAssertNil(SuiteCleanStart.discardButton(prompt: "Allow this app to control your computer?",
            buttonTitles: ["Don't Allow", "Allow"]))
        XCTAssertNil(SuiteCleanStart.discardButton(prompt: "Save changes before closing?",
            buttonTitles: ["Cancel", "Save"] ))
        XCTAssertNil(SuiteCleanStart.discardButton(prompt: message, buttonTitles: ["Close"]))
        XCTAssertNil(SuiteCleanStart.discardButton(prompt: message, buttonTitles: ["Cancel", "Close", "Save As"]))
    }

    @MainActor
    func testCleanStartRecognizesOnlyExistingPrivateNativeRunFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let root = home.appendingPathComponent("AgentEval", isDirectory: true)
        let run = root.appendingPathComponent("task-0123456789abcdef0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let document = run.appendingPathComponent("notes.txt")
        try Data("fixture".utf8).write(to: document)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(SuiteCleanStart.ownsNativeScratchDocument(url: document.absoluteString, homeDirectory: home))
        XCTAssertFalse(SuiteCleanStart.ownsNativeScratchDocument(url: home.appendingPathComponent("notes.txt").absoluteString,
            homeDirectory: home))
        let malformedRun = root.appendingPathComponent("task-short", isDirectory: true).appendingPathComponent("notes.txt")
        XCTAssertFalse(SuiteCleanStart.ownsNativeScratchDocument(url: malformedRun.absoluteString, homeDirectory: home))
    }

    func testAcceptsOnlyKnownPolicyAndBoundedTaskConfiguration() throws {
        let request = try decode(#"{"task_id":"eval_1","prompt":"Read this page","start":{"url":"http://127.0.0.1:8765/read.html"},"max_steps":40,"policy":"fara15-4b"}"#)
        XCTAssertEqual(request.taskID, "eval_1")
        XCTAssertEqual(request.maxSteps, 40)
        XCTAssertEqual(request.policy, "fara15-4b")
        XCTAssertFalse(request.allowsFixtureCommit)
        XCTAssertFalse(request.allowsFixtureInteraction)
        let publicRead = try decode(requestJSON(start: #"{"url":"https://example.org/docs"}"#,
            approval: #"{"allow_start_interaction":true}"#))
        XCTAssertTrue(publicRead.allowsStartInteraction)
    }

    func testRejectsUnknownPolicyAndInvalidBounds() {
        let invalid = [
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/"},"max_steps":41,"policy":"fara15-4b"}"#,
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/"},"max_steps":1,"policy":"other"}"#,
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/"},"max_steps":0,"policy":"fara15-4b"}"#
        ]
        for payload in invalid { XCTAssertThrowsError(try decode(payload)) }
    }

    func testRejectsNonLoopbackOrCredentialedStartURL() {
        let invalid = [
            "http://example.com/",
            "http://user:secret@localhost/",
            "http://localhost.evil/",
            "http://127.0.0.1:70000/",
            "https://example.org/a b",
            "https://[broken/"
        ]
        for url in invalid {
            let payload = requestJSON(start: #"{"url":"\#(url)"}"#)
            XCTAssertThrowsError(try decode(payload), url)
        }
    }

    func testRejectsUnknownKeysAndMalformedStartAlternatives() {
        let invalid = [
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/","app":"Safari"},"max_steps":1,"policy":"fara15-4b"}"#,
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/","extra":true},"max_steps":1,"policy":"fara15-4b"}"#,
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/"},"max_steps":1,"policy":"fara15-4b","extra":true}"#,
            #"{"task_id":"t","prompt":"x","start":{"url":"http://localhost/"},"max_steps":1,"policy":"fara15-4b","approval_policy":{"allow_fixture_commit":true,"extra":true}}"#
        ]
        for payload in invalid { XCTAssertThrowsError(try decode(payload)) }
    }

    func testFixtureApprovalFlagsAreExplicitAndIndependent() throws {
        let commit = try decode(requestJSON(approval: #"{"allow_fixture_commit":true}"#))
        XCTAssertTrue(commit.allowsFixtureCommit)
        XCTAssertFalse(commit.allowsFixtureInteraction)
        let interaction = try decode(requestJSON(approval: #"{"allow_fixture_interaction":true}"#))
        XCTAssertFalse(interaction.allowsFixtureCommit)
        XCTAssertTrue(interaction.allowsFixtureInteraction)
        let start = try decode(requestJSON(start: #"{"url":"https://example.org/"}"#,
            approval: #"{"allow_start_interaction":true}"#))
        XCTAssertTrue(start.allowsStartInteraction)
        XCTAssertFalse(start.allowsFixtureInteraction)
    }

    func testResponseProvesRealHostAndKeepsRunnerWireNames() throws {
        let response = AgentEvalResponse(taskID: "t", outcome: "completed", answer: "Done",
            episodePath: "/tmp/episode.jsonl", wallSeconds: 1.25,
            policy: "fara15-4b", cropMode: "unknown", requestedCropMode: "frontmost-window")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertEqual(value["task_id"] as? String, "t")
        XCTAssertEqual(value["real_host_app"] as? Bool, true)
        XCTAssertEqual(value["episode_path"] as? String, "/tmp/episode.jsonl")
        XCTAssertEqual(value["wall_seconds"] as? Double, 1.25)
        XCTAssertEqual(value["environment"] as? String, "pixel")
        XCTAssertEqual(value["policy"] as? String, "fara15-4b")
        XCTAssertEqual(value["crop_mode"] as? String, "unknown")
        XCTAssertEqual(value["requested_crop_mode"] as? String, "frontmost-window")
    }

    func testPixelCropMetadataAcceptsOnlyKnownBackendAndModes() {
        XCTAssertEqual(AgentEvalPixelMetadata.actualCropMode(from: Data(
            #"{"active_backend":"pixel","crop_mode":"frontmost-window"}"#.utf8)), "frontmost-window")
        XCTAssertEqual(AgentEvalPixelMetadata.actualCropMode(from: Data(
            #"{"active_backend":"pixel","crop_mode":"full-display"}"#.utf8)), "full-display")
        for invalid in [
            #"{"active_backend":"safari","crop_mode":"frontmost-window"}"#,
            #"{"active_backend":"pixel","crop_mode":"window"}"#,
            #"{"active_backend":"pixel","crop_mode":"full-display","extra":true}"#,
            "not json"
        ] {
            XCTAssertEqual(AgentEvalPixelMetadata.actualCropMode(from: Data(invalid.utf8)), "unknown")
        }
        XCTAssertEqual(AgentEvalPixelMetadata.actualCropMode(from: nil), "unknown")
    }

    func testPrivatePixelMetadataRecordsTheActualSingleFrontmostStartWindow() throws {
        let valid = #"{"active_backend":"pixel","crop_mode":"frontmost-window","first_observation":{"frontmost_bundle_id":"com.apple.Safari","frontmost_app_name":"Safari","frontmost_process_id":123,"expected_start_bundle_id":"com.apple.Safari","expected_start_url":"https://example.test/transit","observed_start_url":"https://example.test/transit","start_surface_matches":true,"visible_window_count":1,"selected_window_title":"Transit","selected_window_number":42,"selected_window_owner_process_id":123,"selected_window_bounds":[10,20,800,600],"valid":true}}"#
        let data = Data(valid.utf8)
        XCTAssertEqual(AgentEvalPixelMetadata.actualCropMode(from: data), "frontmost-window")
        XCTAssertTrue(AgentEvalPixelMetadata.hasValidFirstObservation(from: data))

        let twoWindows = valid.replacingOccurrences(of: #""visible_window_count":1"#, with: #""visible_window_count":2"#)
        XCTAssertFalse(AgentEvalPixelMetadata.hasValidFirstObservation(from: Data(twoWindows.utf8)))
        let missingSelection = valid.replacingOccurrences(of: #""selected_window_number":42"#, with: #""selected_window_number":null"#)
        XCTAssertFalse(AgentEvalPixelMetadata.hasValidFirstObservation(from: Data(missingSelection.utf8)))
        let otherProcess = valid.replacingOccurrences(of: #""selected_window_owner_process_id":123"#, with: #""selected_window_owner_process_id":456"#)
        XCTAssertFalse(AgentEvalPixelMetadata.hasValidFirstObservation(from: Data(otherProcess.utf8)))
        let wrongStart = valid.replacingOccurrences(of: #""observed_start_url":"https://example.test/transit""#, with: #""observed_start_url":"https://example.test/other""#)
        XCTAssertFalse(AgentEvalPixelMetadata.hasValidFirstObservation(from: Data(wrongStart.utf8)))
        let wrongApplication = valid.replacingOccurrences(of: #""expected_start_bundle_id":"com.apple.Safari""#,
            with: #""expected_start_bundle_id":"org.example.other""#)
        XCTAssertFalse(AgentEvalPixelMetadata.hasValidFirstObservation(from: Data(wrongApplication.utf8)))
    }

    private func decode(_ json: String) throws -> AgentEvalRequest {
        try AgentEvalRequest.decodeStrict(Data(json.utf8))
    }

    private func requestJSON(start: String = #"{"url":"http://localhost/"}"#,
                             approval: String? = nil) -> String {
        let approvalField = approval.map { ",\"approval_policy\":\($0)" } ?? ""
        return #"{"task_id":"t","prompt":"x","start":\#(start),"max_steps":1,"policy":"fara15-4b"\#(approvalField)}"#
    }
}
#endif
