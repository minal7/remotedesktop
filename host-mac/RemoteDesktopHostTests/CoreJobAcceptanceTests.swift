import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import RemoteDesktopClientCore

private enum GmailAcceptanceControlTrace {
    static func compactEvent(request: Data, response: Data) -> Data? {
        guard request.count <= 2 * 1_024 * 1_024, response.count <= 256 * 1_024,
              let requestRoot = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let messages = requestRoot["messages"] as? [[String: Any]],
              let user = messages.last(where: { $0["role"] as? String == "user" }),
              let content = user["content"] as? String,
              let context = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let responseRoot = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let choices = responseRoot["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let rawDecision = message["content"] as? String,
              let decision = try? JSONSerialization.jsonObject(with: Data(rawDecision.utf8)) as? [String: Any] else {
            return nil
        }
        let controls: [[String: Any]] = (context["native_controls"] as? [String: Any])?["items"] as? [[String: Any]]
            ?? context["observed_controls"] as? [[String: Any]] ?? []
        let safeControls = controls.prefix(48).map { item -> [String: Any] in
            var safe: [String: Any] = [:]
            for key in ["id", "role", "label", "enabled"] {
                if let value = item[key], value is String || value is NSNumber { safe[key] = value }
            }
            return safe
        }
        let safeDecision: [String: Any] = [
            "outcome": decision["outcome"] ?? NSNull(),
            "control_id": decision["control_id"] ?? NSNull(),
            "explanation": String((decision["explanation"] as? String ?? "").prefix(256)),
        ]
        return try? JSONSerialization.data(withJSONObject: [
            "observed_controls": safeControls,
            "control_count": controls.count,
            "decision": safeDecision,
            "request_bytes": request.count,
            "response_bytes": response.count,
            "focused_editor": context["focused_editor"] ?? NSNull(),
            "current_action_error": context["action_error"] ?? context["current_action_error"] ?? NSNull(),
        ], options: [.sortedKeys])
    }
}

@MainActor
private final class GmailAcceptanceVisualExecutorLoader: ComputerUseVisualExecutorLoading {
    private let base: OSAtlasVisualExecutorLoader
    private(set) var defaultBrowserExecutor: ComputerUseDefaultBrowserExecutor?

    init(base: OSAtlasVisualExecutorLoader) { self.base = base }

    private func retain(_ executor: any ComputerUseExecuting) -> any ComputerUseExecuting {
        if let browser = executor as? ComputerUseDefaultBrowserExecutor {
            defaultBrowserExecutor = browser
        }
        return executor
    }

    func prepareBrowser(receipt: ComputerUseInstallationReceipt?) throws -> ComputerUseFaraBrowserExecutor {
        try base.prepareBrowser(receipt: receipt)
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?) throws -> any ComputerUseExecuting {
        retain(try base.prepareDefaultBrowser(receipt: receipt))
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?) throws -> any ComputerUseExecuting {
        retain(try base.prepareDefaultBrowser(receipt: receipt, nativeFilePlanner: nativeFilePlanner))
    }

    func prepareDefaultBrowser(receipt: ComputerUseInstallationReceipt?,
        nativeFilePlanner: ComputerUseDefaultBrowserExecutor.NativeFilePlanner?,
        nativeControlInputs: ComputerUseDefaultBrowserExecutor.NativeControlInputs?) throws -> any ComputerUseExecuting {
        retain(try base.prepareDefaultBrowser(receipt: receipt, nativeFilePlanner: nativeFilePlanner,
            nativeControlInputs: nativeControlInputs))
    }

    func load(receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void) async throws -> any ComputerUseExecuting {
        retain(try await base.load(receipt: receipt, progress: progress))
    }

    func prepare(receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void) async throws -> ComputerUsePreparedVisualExecutor {
        let prepared = try await base.prepare(receipt: receipt, progress: progress)
        _ = retain(prepared.executor)
        return prepared
    }

    func deactivate() async { await base.deactivate() }
}

@MainActor
final class CoreJobAcceptanceTests: XCTestCase {

    private struct GmailAXFact {
        let role: String
        let title: String
        let description: String
        let value: String

        init(_ role: String, _ title: String = "", _ description: String = "", value: String = "") {
            self.role = role
            self.title = title
            self.description = description
            self.value = value
        }
    }

    func testGmailAcceptanceRecognizesStandaloneComposerBeforeAttachment() {
        let subject = "Remote Desktop acceptance [token]"
        let account = "sender@example.com"
        let recipient = "recipient@example.com"
        let facts = Self.standaloneGmailFacts(subject: subject, recipient: recipient,
            body: "Please review the attachment.")
        let title = "Compose Mail - sender@example.com - Gmail"
        let url = "https://mail.google.com/mail/u/0/?fs=1&to=recipient%40example.com&su=Remote%20Desktop%20acceptance%20%5Btoken%5D&body=Please%20review&tf=cm"
        XCTAssertTrue(Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
            webAreaDescription: title, url: url, expectedAccount: account, subject: subject,
            composeRegions: [facts]),
            "A standalone compose can be recognized for safe reuse before it has an attachment")
        XCTAssertFalse(Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
            webAreaDescription: title, url: url, expectedAccount: account, subject: subject,
            composeRegions: [facts, facts]), "Duplicate compose regions must not be treated as owned")
        XCTAssertFalse(Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
            webAreaDescription: title, url: "https://example.com/?fs=1&tf=cm", expectedAccount: account,
            subject: subject, composeRegions: [facts]))
        XCTAssertFalse(Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
            webAreaDescription: title, url: "https://mail.google.com/mail/u/0/?fs=1&fs=1&tf=cm",
            expectedAccount: account, subject: subject, composeRegions: [facts]))
        XCTAssertFalse(Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
            webAreaDescription: title, url: "https://mail.google.com/mail/u/0/?fs=1&tf=cm&tf=cm",
            expectedAccount: account, subject: subject, composeRegions: [facts]))
        XCTAssertFalse(Self.gmailStandaloneComposerIdentityMatches(windowTitle: "Compose Mail - recipient@example.com - Gmail",
            webAreaDescription: "Compose Mail - recipient@example.com - Gmail", url: url,
            expectedAccount: account, subject: subject, composeRegions: [facts]),
            "The To recipient cannot stand in for the signed-in sender account")
        XCTAssertFalse(Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
            webAreaDescription: "Another page", url: url, expectedAccount: account,
            subject: subject, composeRegions: [facts]))
    }

    func testGmailFileApprovalDetailsRequireExactSingleFileRequest() {
        let expected = Expected(job: "gmail", run_id: "run", prompt: "",
            source_path: "/fixture/Board Review.pptx", source_sha256: String(repeating: "a", count: 64),
            attachment_name: "Board Review.pptx", source_bytes: 2_793,
            to: "sender@example.com", subject: "Remote Desktop acceptance [token]", body: "Body",
            cloud_root: nil, destination_path: nil, gmail_existing_draft_url: nil,
            send_approval_check: false, trip: nil)
        func request(_ details: [(String, String)], label: String = "Attach file")
            -> RemoteDesktopClientCore.ComputerUseApprovalRequest {
            .init(taskID: "task", message: "Attach selected file",
                details: details.map { .init(label: $0.0, value: $0.1) }, confirmLabel: label)
        }
        let exact = request([
            ("File", "Board Review.pptx"), ("Size", "2793 bytes"),
            ("Destination", "Gmail (sender@example.com)"), ("To", "sender@example.com"),
            ("Subject", "Remote Desktop acceptance [token]"),
        ])
        XCTAssertTrue(Self.gmailAttachmentApprovalDetailsMatch(exact, expected: expected))
        XCTAssertFalse(Self.gmailAttachmentApprovalDetailsMatch(request([
            ("File", "Board Review.pptx"), ("Size", "2793 bytes"),
            ("Destination", "Gmail (sender@example.com)"), ("To", "sender@example.com"),
            ("Subject", "Remote Desktop acceptance [token]"), ("CC", "other@example.com"),
        ]), expected: expected))
        XCTAssertFalse(Self.gmailAttachmentApprovalDetailsMatch(request([
            ("File", "Board Review.pptx"), ("Size", "2793 bytes"),
            ("Destination", "Gmail (sender@example.com)"), ("To", "sender@example.com"),
            ("Subject", "Remote Desktop acceptance [token]"),
        ], label: "Send email"), expected: expected))
    }

    func testGmailAcceptanceAttachmentOracleRequiresOneExactNameAndRoundedVisibleSize() {
        let exact = Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx (3K)"], removeButtonLabels: ["Remove attachment"],
            expectedName: "Board Review.pptx", expectedBytes: 2_793)
        XCTAssertTrue(exact.nameMatches)
        XCTAssertTrue(exact.sizeVisible)
        XCTAssertTrue(exact.singleAttachment)
        XCTAssertFalse(Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx (3K)", "Board Review.pptx (3K)"],
            removeButtonLabels: ["Remove attachment"], expectedName: "Board Review.pptx",
            expectedBytes: 2_793).singleAttachment)
        XCTAssertFalse(Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx final (3K)"], removeButtonLabels: ["Remove attachment"],
            expectedName: "Board Review.pptx", expectedBytes: 2_793).nameMatches)
        let wrongSize = Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx (4K)"], removeButtonLabels: ["Remove attachment"],
            expectedName: "Board Review.pptx", expectedBytes: 2_793)
        XCTAssertTrue(wrongSize.nameMatches)
        XCTAssertFalse(wrongSize.sizeVisible)
        let missingRemoval = Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx (3K)"], removeButtonLabels: [],
            expectedName: "Board Review.pptx", expectedBytes: 2_793)
        XCTAssertFalse(missingRemoval.singleAttachment)
        XCTAssertFalse(missingRemoval.sizeVisible)
        let duplicateRemoval = Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx (3K)"],
            removeButtonLabels: ["Remove attachment", "Remove attachment"],
            expectedName: "Board Review.pptx", expectedBytes: 2_793)
        XCTAssertFalse(duplicateRemoval.singleAttachment)
        XCTAssertFalse(duplicateRemoval.sizeVisible)
        XCTAssertFalse(Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx final (3K)",
            linkLabels: ["Board Review.pptx (3K)"], removeButtonLabels: ["Remove attachment"],
            expectedName: "Board Review.pptx", expectedBytes: 2_793).nameMatches)
        XCTAssertFalse(Self.gmailAttachmentFactsMatch(groupText: "Attachment: Board Review.pptx (3K)",
            linkLabels: ["Board Review.pptx (3K)"], removeButtonLabels: ["Remove attachment"], groupCount: 2,
            expectedName: "Board Review.pptx", expectedBytes: 2_793).singleAttachment)
        XCTAssertFalse(Self.gmailAttachmentFactsMatch(groupText: "Attachment: board review.pptx (3K)",
            linkLabels: ["Board Review.pptx (3K)"], removeButtonLabels: ["Remove attachment"],
            expectedName: "Board Review.pptx", expectedBytes: 2_793).nameMatches)
    }

    func testGmailAcceptanceSanitizesSessionValidationPhase() {
        for phase in ["capture", "target", "sheet", "focus", "complete"] {
            XCTAssertEqual(Self.sanitizedSessionValidationPhase(phase), phase)
        }
        for rejected in ["targetLost", "capture extra", "phase=focus", ""] {
            XCTAssertNil(Self.sanitizedSessionValidationPhase(rejected))
        }
        XCTAssertNil(Self.sanitizedSessionValidationPhase(nil))
    }

    func testGmailAcceptanceSanitizesSessionCaptureReasonAndAXErrorCode() {
        for reason in ["frontmost_unavailable", "frontmost_process_mismatch", "frontmost_identity_mismatch",
            "windows_read", "windows_malformed", "windows_unconvertible", "focused_window_read",
            "focused_window_malformed", "focused_window_unconvertible", "capture_deadline",
            "capture_cancelled", "final_frontmost_unavailable", "final_frontmost_changed",
            "bounds_read", "bounds_deadline", "bounds_type", "bounds_malformed"] {
            XCTAssertEqual(Self.sanitizedSessionCaptureReason(reason), reason)
        }
        for rejected in ["https://mail.google.com/", "recipient@example.com", "phase=capture_failure", "unknown"] {
            XCTAssertNil(Self.sanitizedSessionCaptureReason(rejected))
        }
        XCTAssertNil(Self.sanitizedSessionCaptureReason(nil))
        XCTAssertEqual(Self.sanitizedSessionCaptureAXErrorCode("-25202"), -25_202)
        XCTAssertNil(Self.sanitizedSessionCaptureAXErrorCode("-999999"))
        XCTAssertNil(Self.sanitizedSessionCaptureAXErrorCode("private text"))
    }

    func testGmailAcceptanceSanitizesDesktopRevalidationEvidence() {
        let diagnostic = Self.sanitizedDesktopRevalidationDiagnostic([
            "blockedAt": "editor-settle-timeout", "sampleCount": "13", "tokenChangeCount": "2",
            "nilSampleCount": "1", "elapsedMs": "3250", "quietMs": "10",
            "pointerTargetFrame": "recipient@example.com", "sampleCountExtra": "500000",
            "approvedVisualContinuationFailure": "desktopFailure",
            "approvedVisualContinuationDesktopFailure": "scopedSurfaceChanged",
            "rejectedFailure": "changedScreen", "rejectedCount": "3", "decisionKind": "reportCompletion",
            "completionVerificationPhase": "final-surface", "completionOutcomeAccepted": "true",
            "gmailFlowStage": "normalizeDrafts", "gmailNavigationStage": "waitForTarget",
            "gmailPendingFlowStage": "waitingForAttachment",
        ])
        XCTAssertEqual(diagnostic["blockedAt"] as? String, "editor-settle-timeout")
        XCTAssertEqual(diagnostic["sampleCount"] as? Int, 13)
        XCTAssertEqual(diagnostic["tokenChangeCount"] as? Int, 2)
        XCTAssertEqual(diagnostic["nilSampleCount"] as? Int, 1)
        XCTAssertEqual(diagnostic["elapsedMs"] as? Int, 3_250)
        XCTAssertEqual(diagnostic["quietMs"] as? Int, 10)
        XCTAssertNil(diagnostic["pointerTargetFrame"])
        XCTAssertNil(diagnostic["sampleCountExtra"])
        XCTAssertEqual(diagnostic["approvedVisualContinuationFailure"] as? String, "desktopFailure")
        XCTAssertEqual(diagnostic["approvedVisualContinuationDesktopFailure"] as? String, "scopedSurfaceChanged")
        XCTAssertEqual(diagnostic["rejectedFailure"] as? String, "changedScreen")
        XCTAssertEqual(diagnostic["rejectedCount"] as? Int, 3)
        XCTAssertEqual(diagnostic["decisionKind"] as? String, "reportCompletion")
        XCTAssertEqual(diagnostic["completionVerificationPhase"] as? String, "final-surface")
        XCTAssertEqual(diagnostic["completionOutcomeAccepted"] as? Bool, true)
        XCTAssertEqual(diagnostic["gmailFlowStage"] as? String, "normalizeDrafts")
        XCTAssertEqual(diagnostic["gmailNavigationStage"] as? String, "waitForTarget")
        XCTAssertEqual(diagnostic["gmailPendingFlowStage"] as? String, "waitingForAttachment")
        XCTAssertTrue(Self.sanitizedDesktopRevalidationDiagnostic([
            "blockedAt": "recipient@example.com", "sampleCount": "999999",
            "rejectedFailure": "private text", "rejectedCount": "4", "decisionKind": "https://private.invalid/",
            "completionVerificationPhase": "private text", "completionOutcomeAccepted": "yes",
            "gmailFlowStage": "recipient@example.com", "gmailNavigationStage": "private text",
            "gmailPendingFlowStage": "private text",
        ]).isEmpty)
        let rejected = Self.sanitizedDesktopRevalidationDiagnostic([
            "approvedVisualContinuationFailure": "recipient@example.com",
            "approvedVisualContinuationDesktopFailure": "private text",
        ])
        XCTAssertNil(rejected["approvedVisualContinuationFailure"])
        XCTAssertNil(rejected["approvedVisualContinuationDesktopFailure"])
    }

    func testGmailSavedRecipientRetryRequiresPreMenuMissingState() {
        for phase in ["subject_ancestor_chip_missing", "chip_reacquisition_compose_unavailable",
            "chip_reacquisition_chip_missing", "chip_reacquisition_metadata_changed"] {
            XCTAssertTrue(Self.gmailSavedRecipientProofRetryEligible(["recipient_proof_diagnostic": [
                "phase": phase, "opened_menu_count": 0, "menu_scan_nodes_visited": 0,
                "preexisting_menu_count": 0,
            ]]))
        }
        let rejectedDiagnostics: [[String: Any]] = [
            ["phase": "subject_ancestor_chip_ambiguous", "opened_menu_count": 0, "menu_scan_nodes_visited": 0],
            ["phase": "subject_ancestor_chip_missing", "opened_menu_count": 1, "menu_scan_nodes_visited": 0],
            ["phase": "subject_ancestor_chip_missing", "opened_menu_count": 0, "menu_scan_nodes_visited": 1],
        ]
        for diagnostic in rejectedDiagnostics {
            XCTAssertFalse(Self.gmailSavedRecipientProofRetryEligible(["recipient_proof_diagnostic": diagnostic]))
        }
    }

    func testGmailAcceptanceDoesNotTreatComposeURLParametersAsFieldEvidence() {
        let subject = "Remote Desktop acceptance [token]"
        let body = "Please review the attachment."
        let url = "https://mail.google.com/mail/u/0/?fs=1&to=recipient%40example.com&su=Remote%20Desktop%20acceptance%20%5Btoken%5D&body=Please%20review&tf=cm"
        let facts = [GmailAXFact("AXTextField", "Subject", value: "different subject"),
            GmailAXFact("AXTextArea", "Message Body", value: "different body")]
        let proof = Self.gmailTextFieldProof(facts, subject: subject, body: body)
        XCTAssertFalse(proof.subjectMatches)
        XCTAssertFalse(proof.bodyMatches)
        XCTAssertTrue(URLComponents(string: url)?.queryItems?.contains(where: { $0.name == "su" && $0.value == subject }) == true)
        XCTAssertTrue(URLComponents(string: url)?.queryItems?.contains(where: { $0.name == "body" }) == true,
            "URL query values are navigation evidence, never field evidence")
    }

    func testGmailAcceptanceTextFieldProofRequiresOneExactSubjectAndBodyValue() {
        let subject = "Remote Desktop acceptance [token]"
        let body = "Please review the attachment."
        let exact = Self.gmailTextFieldProof([
            GmailAXFact("AXTextField", "Subject", value: subject),
            GmailAXFact("AXTextArea", "Message Body", value: body)], subject: subject, body: body)
        XCTAssertTrue(exact.subjectMatches)
        XCTAssertTrue(exact.bodyMatches)
        let duplicate = Self.gmailTextFieldProof([
            GmailAXFact("AXTextField", "Subject", value: subject),
            GmailAXFact("AXTextField", "Subject", value: subject),
            GmailAXFact("AXTextArea", "Message Body", value: body)], subject: subject, body: body)
        XCTAssertFalse(duplicate.subjectMatches)
        XCTAssertTrue(duplicate.bodyMatches)
        let duplicateBody = Self.gmailTextFieldProof([
            GmailAXFact("AXTextField", "Subject", value: subject),
            GmailAXFact("AXTextArea", "Message Body", value: body),
            GmailAXFact("AXTextArea", "Message Body", value: body)], subject: subject, body: body)
        XCTAssertTrue(duplicateBody.subjectMatches)
        XCTAssertFalse(duplicateBody.bodyMatches)
    }

    func testGmailAcceptanceDraftRecoveryRequiresOneExactSubjectRowAndCompleteScan() {
        let subject = "Remote Desktop acceptance [token]"
        XCTAssertEqual(Self.gmailPrimaryDraftCellText(value: "", descendantStaticTexts: ["", subject, "body"]),
            subject)
        XCTAssertEqual(Self.gmailPrimaryDraftCellText(value: "Sender", descendantStaticTexts: [subject]), "Sender")
        XCTAssertEqual(Self.gmailPrimaryDraftCellText(value: nil, descendantStaticTexts: ["Sender", subject]), "Sender")
        XCTAssertEqual(Self.gmailUniqueDraftSubjectRowIndex(
            cellValuesByRow: [["Other draft"], [subject]], scanComplete: true, subject: subject), 1)
        XCTAssertNil(Self.gmailUniqueDraftSubjectRowIndex(
            cellValuesByRow: [[Self.gmailPrimaryDraftCellText(value: "", descendantStaticTexts: [subject])],
                [Self.gmailPrimaryDraftCellText(value: "", descendantStaticTexts: [subject])]],
            scanComplete: true, subject: subject))
        XCTAssertNil(Self.gmailUniqueDraftSubjectRowIndex(
            cellValuesByRow: [[subject], [subject]], scanComplete: true, subject: subject))
        XCTAssertNil(Self.gmailUniqueDraftSubjectRowIndex(
            cellValuesByRow: [[subject]], scanComplete: false, subject: subject))
        XCTAssertNil(Self.gmailUniqueDraftSubjectRowIndex(
            cellValuesByRow: [["Remote Desktop acceptance [other-token]"], ["body contains \(subject)"]],
            scanComplete: true, subject: subject))
    }

    func testGmailDraftsListingPolicyRequiresTheObservedSelectedAccountWithoutComposeID() {
        XCTAssertTrue(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/0/#drafts", expectedAccountIndex: 0))
        XCTAssertTrue(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/0/#drafts?view=all", expectedAccountIndex: 0))
        XCTAssertTrue(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/0/#drafts?view=all%20drafts", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/0/#inbox", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_ownedDraft123", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/0/#drafts?view=%ZZ", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com/mail/u/1/#drafts", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedDraftsListingURL(
            "https://mail.google.com.evil.invalid/mail/u/0/#drafts", expectedAccountIndex: 0))
        XCTAssertTrue(Self.gmailIsOwnedOpaqueDraftComposeURL(
            "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_ownedDraft1234567890", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedOpaqueDraftComposeURL(
            "https://mail.google.com/mail/u/0/?fs=1&to=someone@example.com#drafts", expectedAccountIndex: 0))
        XCTAssertFalse(Self.gmailIsOwnedOpaqueDraftComposeURL(
            "https://mail.google.com/mail/u/1/#drafts?compose=FMfcgzQX_ownedDraft1234567890", expectedAccountIndex: 0))
    }

    func testGmailRecipientContextClickPointRequiresFinitePositiveBoundsInsideRetainedWindow() {
        let window = CGRect(x: 10, y: 20, width: 900, height: 700)
        let chip = CGRect(x: 100, y: 120, width: 140, height: 24)
        XCTAssertEqual(Self.gmailContextClickPoint(chipBounds: chip, windowBounds: window),
            CGPoint(x: 170, y: 132))
        for invalid in [CGRect.zero, CGRect(x: 100, y: 120, width: -1, height: 24),
                        CGRect(x: CGFloat.nan, y: 120, width: 140, height: 24),
                        CGRect(x: 890, y: 120, width: 40, height: 24)] {
            XCTAssertNil(Self.gmailContextClickPoint(chipBounds: invalid, windowBounds: window))
        }
        XCTAssertNil(Self.gmailContextClickPoint(chipBounds: chip, windowBounds: .zero))
    }

    func testOptInGmailDraftRowCaptureProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_GMAIL_DRAFT_ROW_CAPTURE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in: set RUN_GMAIL_DRAFT_ROW_CAPTURE_PROBE=1")
        }
        guard let expectedPath = environment["GMAIL_DRAFT_ROW_CAPTURE_PROBE_EXPECTED_PATH"],
              let resultPath = environment["GMAIL_DRAFT_ROW_CAPTURE_PROBE_RESULT_PATH"],
              let probeSubject = environment["GMAIL_DRAFT_ROW_CAPTURE_PROBE_SUBJECT"] else {
            throw HarnessError.prerequisite("The opt-in Gmail row probe requires expected, result, and subject paths")
        }
        let expected = try JSONDecoder().decode(Expected.self,
            from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
        guard expected.job == "gmail", expected.subject == probeSubject else {
            throw HarnessError.prerequisite("The opt-in Gmail row probe subject does not match expected.json")
        }
        var evidence: [String: Any] = [:]
        await Self.captureGmailDraft(expected: expected, evidence: &evidence, verifySavedDraft: true)
        let output: [String: Any] = [
            "capture_status": evidence["capture_status"] ?? NSNull(),
            "saved_oracle_status": evidence["saved_oracle_status"] ?? NSNull(),
            "saved_draft_count": evidence["saved_draft_count"] ?? NSNull(),
            "account_identity_verified": evidence["account_identity_verified"] ?? false,
            "draft_row_capture_probe": evidence["draft_row_capture_probe"] ?? NSNull(),
            "product_draft_row_probe_diagnostic": evidence["product_draft_row_probe_diagnostic"] ?? NSNull(),
            "product_draft_row_probe_cell_found": evidence["product_draft_row_probe_cell_found"] ?? false,
            "product_draft_row_probe_ambiguous": evidence["product_draft_row_probe_ambiguous"] ?? false,
        ]
        try Self.write(output, to: URL(fileURLWithPath: resultPath))
        XCTAssertEqual(evidence["saved_oracle_status"] as? String, "probe-unique-exact-subject-row-found",
            "The read-only Gmail row probe did not find one exact subject row: \(output)")
        XCTAssertEqual(evidence["saved_draft_count"] as? Int, 1,
            "The read-only Gmail row probe did not identify exactly one subject row: \(output)")
        XCTAssertTrue(evidence["product_draft_row_probe_cell_found"] as? Bool == true,
            "The product Gmail row helper did not identify the exact subject cell: \(output)")
        XCTAssertFalse(evidence["product_draft_row_probe_ambiguous"] as? Bool == true,
            "The product Gmail row helper treated one native cell alias as duplicate subject rows: \(output)")
    }

    func testOptInGmailExistingDraftRecipientCaptureProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE"] == "1" else {
            throw XCTSkip("Opt-in: set RUN_GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE=1")
        }
        guard let expectedPath = environment["GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE_EXPECTED_PATH"],
              let resultPath = environment["GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE_RESULT_PATH"],
              let probeSubject = environment["GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE_SUBJECT"] else {
            throw HarnessError.prerequisite("The existing-draft recipient probe requires expected, result, and subject paths")
        }
        let expected = try JSONDecoder().decode(Expected.self,
            from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
        guard expected.job == "gmail", expected.subject == probeSubject else {
            throw HarnessError.prerequisite("The recipient probe subject does not match expected.json")
        }
        var evidence: [String: Any] = [:]
        await Self.captureGmailDraft(expected: expected, evidence: &evidence)
        let output: [String: Any] = [
            "capture_status": evidence["capture_status"] ?? NSNull(),
            "existing_draft_url_verified": evidence["existing_draft_recipient_probe_url_verified"] ?? false,
            "account_identity_verified": evidence["account_identity_verified"] ?? false,
            "compose_count": evidence["compose_count"] ?? 0,
            "compose_identity_verified": evidence["compose_identity_verified"] ?? false,
            "subject_matches": evidence["subject_matches"] ?? false,
            "body_matches": evidence["body_matches"] ?? false,
            "recipient_matches": evidence["recipient_matches"] ?? false,
            "recipient_proof_diagnostic": evidence["recipient_proof_diagnostic"] ?? NSNull(),
        ]
        try Self.write(output, to: URL(fileURLWithPath: resultPath))
        XCTAssertTrue(evidence["existing_draft_recipient_probe_url_verified"] as? Bool == true,
            "The read-only recipient probe requires the existing opaque compose URL: \(output)")
        XCTAssertTrue(evidence["account_identity_verified"] as? Bool == true,
            "The recipient probe could not verify the selected account: \(output)")
        XCTAssertEqual(evidence["compose_count"] as? Int, 1,
            "The recipient probe requires one current compose: \(output)")
        XCTAssertTrue(evidence["recipient_matches"] as? Bool == true,
            "The exact Copy-address proof did not verify the recipient: \(output)")
    }

    private static func standaloneGmailFacts(subject: String, recipient: String, body: String) -> [GmailAXFact] {
        [GmailAXFact("AXGroup", subject),
         GmailAXFact("AXStaticText", "Contact Name (\(recipient))"),
         GmailAXFact("AXTextField", "Subject", value: subject),
         GmailAXFact("AXTextArea", "Message Body", value: body),
         GmailAXFact("AXButton", "Send"),
         GmailAXFact("AXPopUpButton", "Attach files"),
         GmailAXFact("AXButton", "Discard draft")]
    }

    private static func gmailStandaloneComposerIdentityMatches(windowTitle: String, webAreaDescription: String,
        url: String, expectedAccount: String, subject: String, composeRegions: [[GmailAXFact]]) -> Bool {
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        let fsItems = queryItems.filter { $0.name == "fs" }
        let tfItems = queryItems.filter { $0.name == "tf" }
        guard let urlParts = URLComponents(string: url), urlParts.scheme?.lowercased() == "https",
              urlParts.host?.lowercased() == "mail.google.com", urlParts.user == nil,
              urlParts.password == nil, urlParts.port == nil,
              urlParts.path.range(of: #"^/mail/u/[0-9]+/?$"#, options: .regularExpression) != nil,
              fsItems.count == 1, fsItems.first?.value == "1",
              tfItems.count == 1, tfItems.first?.value == "cm",
              ComputerUseGmailAccountDirectory.email(in: expectedAccount) == expectedAccount.lowercased(),
              windowTitle == "Compose Mail - \(expectedAccount) - Gmail",
              webAreaDescription == windowTitle,
              composeRegions.count == 1, let facts = composeRegions.first else { return false }
        let exactSubjectGroups = facts.filter {
            $0.role == "AXGroup" && [$0.title, $0.description, $0.value].contains(subject)
        }
        guard exactSubjectGroups.count == 1,
              facts.filter({ $0.role == "AXTextField" && $0.title == "Subject" }).count == 1,
              facts.filter({ $0.role == "AXTextArea" && $0.title == "Message Body" }).count == 1,
              facts.contains(where: {
                  guard $0.role == "AXButton" else { return false }
                  return [$0.title, $0.description].contains { label in
                      let normalized = label.replacingOccurrences(of: "\u{202A}", with: "")
                          .replacingOccurrences(of: "\u{202B}", with: "")
                          .replacingOccurrences(of: "\u{202C}", with: "")
                          .replacingOccurrences(of: "\u{2066}", with: "")
                          .replacingOccurrences(of: "\u{2067}", with: "")
                          .replacingOccurrences(of: "\u{2068}", with: "")
                          .replacingOccurrences(of: "\u{2069}", with: "")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
                      return normalized == "Send" || normalized.hasPrefix("Send (")
                  }
              }),
              facts.contains(where: { $0.role == "AXPopUpButton" && $0.title == "Attach files" }),
              facts.contains(where: { $0.role == "AXButton" && $0.title == "Discard draft" }) else { return false }
        return true
    }

    private static func gmailTextFieldProof(_ facts: [GmailAXFact], subject: String, body: String)
        -> (subjectMatches: Bool, bodyMatches: Bool) {
        let subjectFields = facts.filter { $0.role == "AXTextField" && $0.title == "Subject" }
        let bodyFields = facts.filter {
            ($0.role == "AXTextArea" || $0.role == "AXTextEntryArea") && $0.title == "Message Body"
        }
        return (subjectFields.count == 1 && subjectFields.first?.value == subject,
            bodyFields.count == 1 && bodyFields.first?.value == body)
    }

    private static func gmailAttachmentFactsMatch(groupText: String, linkLabels: [String],
        removeButtonLabels: [String], groupCount: Int = 1, expectedName: String, expectedBytes: Int)
        -> (nameMatches: Bool, sizeVisible: Bool, singleAttachment: Bool) {
        let groupMatches = gmailAttachmentGroupNamesMatch(groupText: groupText, expectedName: expectedName)
        let acceptedSizes = gmailVisibleAttachmentSizeLabels(expectedBytes)
        let nameLabels = linkLabels.filter {
            guard $0.hasPrefix("\(expectedName) ("), $0.hasSuffix(")") else { return false }
            let size = String($0.dropFirst(expectedName.count + 2).dropLast())
            return size.range(of: #"^[0-9]+(?:\.[0-9]+)? ?(?:K|KB|KiB|M|MB|MiB|G|GB|GiB)$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        }
        let exactSizeLabels = nameLabels.filter { label in
            acceptedSizes.contains { label == "\(expectedName) (\($0))" }
        }
        let exactRemoveLabels = removeButtonLabels.filter {
            ["Remove attachment", "Remove \(expectedName)"].contains($0)
        }
        let nameMatches = groupMatches && linkLabels.count == 1 && nameLabels.count == 1
        let uniqueAttachment = groupCount == 1 && nameMatches
            && removeButtonLabels.count == 1 && exactRemoveLabels.count == 1
        return (nameMatches, uniqueAttachment && exactSizeLabels.count == 1, uniqueAttachment)
    }

    private static func gmailAttachmentGroupNamesMatch(groupText: String, expectedName: String) -> Bool {
        let pattern = #"(?:^|\s)(?i:Attachment): "# + NSRegularExpression.escapedPattern(for: expectedName)
            + #"(?: \([0-9]+(?:\.[0-9]+)? ?(?:K|KB|KiB|M|MB|MiB|G|GB|GiB)\))?(?:\.|\s*$)"#
        return groupText.range(of: pattern, options: [.regularExpression]) != nil
    }

    private static func gmailVisibleAttachmentSizeLabels(_ byteCount: Int) -> Set<String> {
        guard byteCount >= 0 else { return [] }
        let binaryRounded = Int((Double(byteCount) / 1_024).rounded())
        let decimalRounded = Int((Double(byteCount) / 1_000).rounded())
        let binaryTenth = (Double(byteCount) / 1_024 * 10).rounded() / 10
        let decimalTenth = (Double(byteCount) / 1_000 * 10).rounded() / 10
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var labels: Set<String> = [formatter.string(fromByteCount: Int64(byteCount))]
        for amount in Set([binaryRounded, decimalRounded]) {
            for unit in ["K", "KB", "KiB"] {
                labels.insert("\(amount)\(unit)")
                labels.insert("\(amount) \(unit)")
            }
        }
        for amount in Set([binaryTenth, decimalTenth]) {
            let number = String(format: "%.1f", amount)
            for unit in ["K", "KB", "KiB"] {
                labels.insert("\(number)\(unit)")
                labels.insert("\(number) \(unit)")
            }
        }
        return labels
    }

    private static func gmailUniqueDraftSubjectRowIndex(cellValuesByRow: [[String]], scanComplete: Bool,
        subject: String) -> Int? {
        guard scanComplete else { return nil }
        let exactRows = cellValuesByRow.enumerated().filter { _, cells in cells.contains(subject) }
        guard exactRows.count == 1 else { return nil }
        return exactRows[0].offset
    }

    private static func gmailPrimaryDraftCellText(value: String?, descendantStaticTexts: [String]) -> String {
        if let value, !value.isEmpty { return value }
        return descendantStaticTexts.first(where: { !$0.isEmpty }) ?? ""
    }

    private static func gmailContextClickPoint(chipBounds: CGRect, windowBounds: CGRect) -> CGPoint? {
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && !rect.isEmpty
                && rect.size.width > 0 && rect.size.height > 0
                && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
        }
        guard valid(chipBounds), valid(windowBounds), windowBounds.contains(chipBounds) else { return nil }
        let point = CGPoint(x: chipBounds.midX, y: chipBounds.midY)
        return windowBounds.contains(point) ? point : nil
    }

    private static func gmailIsOwnedDraftsListingURL(_ rawURL: String, expectedAccountIndex: Int) -> Bool {
        guard rawURL.range(of: #"%(?![0-9A-Fa-f]{2})"#, options: .regularExpression) == nil,
              let components = URLComponents(string: rawURL), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "mail.google.com", components.user == nil,
              components.password == nil, components.port == nil,
              ComputerUseGmailAccountDirectory.accountIndex(from: rawURL) == expectedAccountIndex,
              components.path == "/mail/u/\(expectedAccountIndex)/",
              !(components.queryItems ?? []).contains(where: { $0.name == "compose" }),
              let fragment = components.fragment else { return false }
        let parts = fragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let route = parts.first, route == "drafts" || route == "drafts/" else { return false }
        if parts.count > 1 {
            guard let fragmentComponents = URLComponents(string: "https://mail.google.com/?\(parts[1])"),
                  let fragmentQuery = fragmentComponents.queryItems else { return false }
            if fragmentQuery.contains(where: { $0.name == "compose" }) { return false }
        }
        return true
    }

    private static func gmailIsOwnedOpaqueDraftComposeURL(_ rawURL: String, expectedAccountIndex: Int) -> Bool {
        guard rawURL.range(of: #"%(?![0-9A-Fa-f]{2})"#, options: .regularExpression) == nil,
              let components = URLComponents(string: rawURL), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "mail.google.com", components.user == nil,
              components.password == nil, components.port == nil,
              ComputerUseGmailAccountDirectory.accountIndex(from: rawURL) == expectedAccountIndex,
              components.path == "/mail/u/\(expectedAccountIndex)/",
              !(components.queryItems ?? []).contains(where: { $0.name == "compose" }),
              let fragment = components.fragment else { return false }
        let parts = fragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "drafts",
              let query = URLComponents(string: "https://mail.google.com/?\(parts[1])")?.queryItems else { return false }
        let composeItems = query.filter { $0.name == "compose" }
        guard composeItems.count == 1, let token = composeItems[0].value else { return false }
        return token.range(of: #"^[A-Za-z0-9_-]{16,}$"#, options: .regularExpression) != nil
    }

    // A product-observed bookmark can recover navigation after a native panel
    // interrupts the independent reader. It must never supply acceptance proof.
    private static func gmailRecoveryMetadata(verifiedURL: URL?) -> [String: Any] {
        guard let url = verifiedURL,
              let accountIndex = ComputerUseGmailAccountDirectory.accountIndex(from: url.absoluteString),
              gmailIsOwnedOpaqueDraftComposeURL(url.absoluteString, expectedAccountIndex: accountIndex) else {
            return [:]
        }
        return ["recovery_compose_url": url.absoluteString,
            "recovery_subject_verified": true, "gmail_account_index": accountIndex]
    }

    func testGmailRecoveryBookmarkDoesNotSupplyIndependentDraftProof() {
        let url = URL(string: "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_ownedDraft1234567890")!
        let evidence = Self.gmailRecoveryMetadata(verifiedURL: url)
        XCTAssertEqual(evidence["recovery_compose_url"] as? String, url.absoluteString)
        XCTAssertEqual(evidence["gmail_account_index"] as? Int, 0)
        XCTAssertEqual(evidence["recovery_subject_verified"] as? Bool, true)
        for key in ["subject_matches", "saved_subject_matches", "saved_draft_count", "compose_count",
                    "saved_draft_url", "compose_url", "attachment_matches"] {
            XCTAssertNil(evidence[key])
        }
        for invalid in [nil, URL(string: "https://mail.google.com/mail/u/0/#drafts"),
                        URL(string: "https://mail.google.com.evil.invalid/mail/u/0/#drafts?compose=FMfcgzQX_ownedDraft1234567890"),
                        URL(string: "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_ownedDraft1234567890&compose=otherDraft1234567890")] {
            XCTAssertTrue(Self.gmailRecoveryMetadata(verifiedURL: invalid).isEmpty)
        }
    }

    private enum GmailPreferencePreflight: Equatable {
        case allowed
        case missingExpectedAddress
        case malformedPreference
        case conflictingPreference
    }

    func testGmailAcceptancePreferencePreflightFailsClosedOnConflict() {
        XCTAssertEqual(Self.gmailPreferencePreflight(preferredEmail: nil,
            expectedAddress: "self@example.com"), .allowed)
        XCTAssertEqual(Self.gmailPreferencePreflight(preferredEmail: "self@example.com",
            expectedAddress: "self@example.com"), .allowed)
        XCTAssertEqual(Self.gmailPreferencePreflight(preferredEmail: "other@example.com",
            expectedAddress: "self@example.com"), .conflictingPreference)
        XCTAssertEqual(Self.gmailPreferencePreflight(preferredEmail: "not-an-address",
            expectedAddress: "self@example.com"), .malformedPreference)
        XCTAssertEqual(Self.gmailPreferencePreflight(preferredEmail: nil,
            expectedAddress: "not-an-address"), .missingExpectedAddress)
        XCTAssertEqual(Self.gmailPreferencePreflight(preferredEmail: nil,
            expectedAddress: nil), .missingExpectedAddress)
    }

    func testGmailAcceptanceAccountChoiceRequiresOneExactHostOfferedMatch() throws {
        let wanted = try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-wanted",
            label: "Test Account", detail: "self@example.com")
        let other = try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-other",
            label: "Other Account", detail: "other@example.com")
        XCTAssertEqual(Self.gmailAccountChoice(in: [other, wanted], expectedAddress: "self@example.com"), wanted)
        XCTAssertNil(Self.gmailAccountChoice(in: [wanted], expectedAddress: "self@example.com"),
            "A single option is not an observed account-choice list")
        let tooMany = try (0..<9).map { index in
            try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-\(index)",
                label: "Account \(index)", detail: "account\(index)@example.com")
        }
        XCTAssertNil(Self.gmailAccountChoice(in: tooMany, expectedAddress: "self@example.com"),
            "An overfull account list must not be auto-answered")
        let third = try RemoteDesktopClientCore.ComputerUseClarificationChoice(id: "gmail-account-third",
            label: "Third Account", detail: "third@example.com")
        XCTAssertNil(Self.gmailAccountChoice(in: [other, third], expectedAddress: "self@example.com"),
            "A valid account list without the expected address must not be answered")
        XCTAssertNil(Self.gmailAccountChoice(in: [other, wanted, try RemoteDesktopClientCore.ComputerUseClarificationChoice(
            id: "gmail-account-duplicate", label: "Duplicate", detail: "self@example.com")],
            expectedAddress: "self@example.com"), "Ambiguous exact matches must not be answered automatically")
        XCTAssertNil(Self.gmailAccountChoice(in: [other, try RemoteDesktopClientCore.ComputerUseClarificationChoice(
            id: "foreign-choice", label: "Self", detail: "self@example.com")],
            expectedAddress: "self@example.com"), "Matching display details do not authorize a foreign choice ID")
    }

    private struct Expected: Decodable {
        let job, run_id, prompt: String
        let source_path, source_sha256, attachment_name: String?
        let source_bytes: Int?
        let to, subject, body, cloud_root, destination_path: String?
        let gmail_existing_draft_url: String?
        let send_approval_check: Bool?
        let trip: Trip?
    }

    private struct Trip: Decodable {
        let origin, destination, date: String

        var json: [String: String] {
            ["origin": origin, "destination": destination, "date": date]
        }
    }

    func testRunJob() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let job = env["CORE_JOB_ACCEPTANCE_JOB"],
              let tracePath = env["CORE_JOB_ACCEPTANCE_TRACE"],
              let fixtureRoot = env["CORE_JOB_ACCEPTANCE_FIXTURE_ROOT"],
              let runID = env["CORE_JOB_ACCEPTANCE_RUN_ID"] else {
            throw XCTSkip("Opt-in: run_job.sh supplies the M0 job, trace, fixture root, and run ID")
        }
        let trace = URL(fileURLWithPath: tracePath, isDirectory: true)
        try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var record: [String: Any] = ["job": job, "run_id": runID, "task_id": NSNull(),
            "raw_outcome": "not-started", "text": "", "elapsed_ms": 0,
            "failure_class": NSNull(), "evidence": [String: Any]()]
        defer { try? Self.write(record, to: trace.appendingPathComponent("outcome.json")) }
        let started = Date()
        let expected: Expected
        do {
            expected = try JSONDecoder().decode(Expected.self,
                from: Data(contentsOf: trace.appendingPathComponent("expected.json")))
        } catch {
            record["failure_class"] = "other"
            record["text"] = "Could not read expected.json: \(error.localizedDescription.prefix(500))"
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
            throw error
        }
        guard expected.job == job, expected.run_id == runID,
              !expected.prompt.isEmpty, FileManager.default.fileExists(atPath: fixtureRoot) else {
            record["failure_class"] = "other"
            record["text"] = "The runner's expected.json or fixture root does not match this invocation"
            throw HarnessError.prerequisite("The runner's expected.json or fixture root does not match this invocation")
        }

        if job == "gmail" {
            let preferredEmail = ComputerUseGmailAccountPreferences().preferredEmail
            let preflightMessage: String?
            switch Self.gmailPreferencePreflight(preferredEmail: preferredEmail, expectedAddress: expected.to) {
            case .allowed:
                preflightMessage = nil
            case .conflictingPreference:
                preflightMessage = "The saved Gmail account preference conflicts with the requested acceptance account; no task was started."
            case .missingExpectedAddress, .malformedPreference:
                preflightMessage = "The Gmail acceptance account could not be verified exactly; no task was started."
            }
            if let preflightMessage {
                record["failure_class"] = "other"
                record["text"] = preflightMessage
                record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
                throw HarnessError.prerequisite(preflightMessage)
            }
        }

        var manager: HostComputerUseManager?
        var client: RemoteDesktopClientCore.ComputerUseSessionModel?
        var gmailVisualLoader: GmailAcceptanceVisualExecutorLoader?
        defer { client?.stop(); _ = manager?.stop() }

        do {
            if job == "email" || job == "cloud" || job == "gmail" {
                guard let sourcePath = expected.source_path, let sourceHash = expected.source_sha256,
                      try Self.sha256(URL(fileURLWithPath: sourcePath)) == sourceHash.lowercased() else {
                    throw HarnessError.prerequisite("The staged source does not match expected.json")
                }
            }
            let nativeInstaller = ComputerUseInstaller.nativeText()
            let nativeReceipt = await nativeInstaller.currentInstallation()
            let nativeInstallInterrupted = await nativeInstaller.interruptedInstallationExists()
            guard nativeReceipt != nil, !nativeInstallInterrupted else {
                throw HarnessError.prerequisite("Verified native text runtime is not ready; setup was not started")
            }
            let helperInstaller = MacControlMCPInstaller()
            guard case .ready = await helperInstaller.durableStatus() else {
                throw HarnessError.prerequisite("Verified MacControl helper is not ready; setup was not started")
            }

            let hostID = UUID().uuidString, clientID = UUID().uuidString
            let sessionID = UUID().uuidString, pairingCode = String(Int.random(in: 100_000...999_999))
            let mailbox = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
            let bridge = SerializedClarificationClientChannel(mailbox: mailbox, hostID: hostID,
                clientID: clientID, sessionID: sessionID, pairingCode: pairingCode)
            let pendingStore = CompositionPendingStore()
            let diagnosticLock = NSLock()
            if job == "gmail" {
                let base = OSAtlasVisualExecutorLoader(nativeControlInspectExchange: { request, response in
                    guard let event = GmailAcceptanceControlTrace.compactEvent(request: request, response: response) else { return }
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("gmail-control-decisions.jsonl")
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(event); data.append(0x0A)
                        try? Data(data.suffix(65_536)).write(to: path, options: .atomic)
                    }
                }, browserRevalidationFailureObserver: { expected, fresh, action, diagnostic in
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("gmail-revalidation.jsonl")
                        let facts: [String: Any] = ["action": String(describing: action),
                            "diagnostic": diagnostic,
                            "expected_display_bounds": String(describing: expected.displayBounds),
                            "fresh_display_bounds": String(describing: fresh.displayBounds)]
                        guard let event = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) else { return }
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(event); data.append(0x0A)
                        try? Data(data.suffix(16_384)).write(to: path, options: .atomic)
                    }
                }, gmailExistingDraftURL: expected.gmail_existing_draft_url.flatMap { URL(string: $0) })
                gmailVisualLoader = GmailAcceptanceVisualExecutorLoader(base: base)
            } else {
                gmailVisualLoader = nil
            }
            let visualLoader: (any ComputerUseVisualExecutorLoading)? = gmailVisualLoader
            let host = HostComputerUseManager(injector: InputInjector(),
                nativeTextInstaller: nativeInstaller, macControlInstaller: helperInstaller,
                visualExecutorLoader: visualLoader,
                mcpPlanner: AppleFoundationMCPPlanner(inspectFailure: { message in
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("planner-failure.txt")
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(contentsOf: (message + "\n").utf8)
                        try? Data(data.suffix(65_536)).write(to: path, options: .atomic)
                    }
                }),
                taskLedger: ComputerUseTaskLedger(fileURL: trace.appendingPathComponent("ledger.json")),
                allowsExternalServices: true,
                nativeTextTargetDiagnosticObserver: { event in
                    guard job == "gmail", let eventData = try? JSONEncoder().encode(event) else { return }
                    diagnosticLock.withLock {
                        let path = trace.appendingPathComponent("gmail-text-bindings.jsonl")
                        var data = (try? Data(contentsOf: path)) ?? Data()
                        data.append(eventData); data.append(0x0A)
                        try? Data(data.suffix(65_536)).write(to: path, options: .atomic)
                    }
                }, channelFactory: { _ in mailbox })
            manager = host
            let phone = RemoteDesktopClientCore.ComputerUseSessionModel(hostName: "M0 local host",
                pairingCode: pairingCode, hostID: hostID, sessionID: sessionID,
                pendingStore: pendingStore, channel: bridge, promptRefreshInterval: .seconds(600))
            client = phone

            host.start(pairingCode: pairingCode, additionalChannels: [mailbox], includeDefaultChannel: false)
            host.authorizePeer(senderID: clientID)
            phone.start()
            let ready = await Self.waitForReady(host, deadline: .now + .seconds(60))
            guard phone.sendPrompt(expected.prompt) else {
                throw HarnessError.transport("The shipped client refused the job prompt")
            }
            let taskID = try await Self.waitForSentPrompt(bridge, deadline: .now + .seconds(5))
            record["task_id"] = taskID
            record["raw_outcome"] = "running"
            let terminal = try await Self.waitForTerminal(phone, expected: expected, taskID: taskID,
                deadline: .now + .seconds(job == "gmail" ? 420 : 180), trace: trace)
            record["task_id"] = taskID
            record["raw_outcome"] = terminal.outcome
            record["text"] = String((phone.interventionGuidance
                ?? phone.messages.last(where: { $0.author == .assistant })?.text ?? phone.statusText).prefix(12_000))
            record["progress"] = phone.taskProgressHistory
            var evidence: [String: Any] = ["transport": "local-in-process", "manager_ready_before_prompt": ready,
                "dispatch_counts": ["client_prompt": 1, "native_inputs": NSNull()]]
        evidence["draft_create_approved_count"] = terminal.approvedDrafts
        evidence["other_approval_denied_count"] = terminal.deniedApprovals
            record["evidence"] = evidence
            switch job {
            case "email":
                var email: [String: Any] = ["send_effects": NSNull(),
                    "send_approval_observed": terminal.sendApprovalObserved]
                evidence["email"] = email
                do {
                    try await Self.exportDraft(expected: expected, trace: trace, evidence: &email)
                } catch {
                    evidence["email"] = email
                    record["evidence"] = evidence
                    throw error
                }
                evidence["email"] = email
            case "cloud":
                var cloud: [String: Any] = [:]
                evidence["cloud"] = cloud
                do {
                    try await Self.checkCloudCopy(expected: expected, evidence: &cloud)
                } catch {
                    evidence["cloud"] = cloud
                    record["evidence"] = evidence
                    throw error
                }
                evidence["cloud"] = cloud
            case "flights":
                var flights: [String: Any] = [:]
                if let trip = expected.trip {
                    flights["requested_trip"] = trip.json
                    flights["requested_trip_source"] = "runner expected.json"
                }
                evidence["flights"] = flights
                do {
                    try Self.captureFlightPage(text: record["text"] as? String ?? "",
                        trace: trace, evidence: &flights)
                } catch {
                    evidence["flights"] = flights
                    record["evidence"] = evidence
                    throw error
                }
                evidence["flights"] = flights
            case "away":
                evidence["away"] = ["transport": "local-in-process", "cellular_route_verified": false,
                    "display_asleep_verified": false, "locked_state_detected": NSNull(),
                    "unlock_resume_prompt_shown": false, "pre_unlock_effect_count": NSNull(),
                    "start_seconds": NSNull(), "approval_push_seconds": NSNull()]
            case "gmail":
                var gmail: [String: Any] = ["approval_events": terminal.approvalEvents,
                    "approval_events_omitted": terminal.approvalEventsOmitted,
                    "approval_responses_denied": terminal.deniedApprovals,
                    "harness_granted_approvals": terminal.attachmentApprovalResponsesGranted,
                    "approval_responses_granted": terminal.attachmentApprovalResponsesGranted,
                    "attachment_approval_count": terminal.attachmentApprovalCount,
                    "attachment_approval_verified": terminal.attachmentApprovalVerified,
                    "attachment_approval_responses_granted": terminal.attachmentApprovalResponsesGranted,
                    "send_approval_observed": terminal.sendApprovalObserved,
                    "send_approval_fields_exact": terminal.sendApprovalFieldsExact,
                    "send_approval_count": terminal.sendApprovalObserved ? 1 : 0,
                    "send_approval_responses_granted": terminal.sendApprovalResponsesGranted,
                    "send_approval_responses_denied": terminal.sendApprovalResponsesDenied,
                    "attachment_bytes_verified": false]
                if expected.send_approval_check != true {
                    await Self.captureGmailDraft(expected: expected, evidence: &gmail, verifySavedDraft: true)
                }
                gmail.merge(Self.gmailRecoveryMetadata(
                    verifiedURL: gmailVisualLoader?.defaultBrowserExecutor?.gmailVerifiedComposeURLForRecovery),
                    uniquingKeysWith: { independent, _ in independent })
                let productFieldDiagnostic = Self.sanitizedGmailFieldDiagnostic(from: gmailVisualLoader)
                if !productFieldDiagnostic.isEmpty {
                    gmail["product_field_diagnostic"] = productFieldDiagnostic
                }
                evidence["gmail"] = gmail
            default:
                throw HarnessError.prerequisite("Unknown M0 job: \(job)")
            }
            record["evidence"] = evidence
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
            if let failure = Self.failureClass(outcome: record["raw_outcome"] as? String,
                                               text: record["text"] as? String) {
                record["failure_class"] = failure
            } else {
                record["failure_class"] = NSNull()
            }
            record["evidence"] = evidence
        } catch {
            if job == "gmail" {
                var gmail: [String: Any] = ["attachment_bytes_verified": false]
                if expected.send_approval_check != true {
                    await Self.captureGmailDraft(expected: expected, evidence: &gmail)
                }
                gmail.merge(Self.gmailRecoveryMetadata(
                    verifiedURL: gmailVisualLoader?.defaultBrowserExecutor?.gmailVerifiedComposeURLForRecovery),
                    uniquingKeysWith: { independent, _ in independent })
                let productFieldDiagnostic = Self.sanitizedGmailFieldDiagnostic(from: gmailVisualLoader)
                if !productFieldDiagnostic.isEmpty {
                    gmail["product_field_diagnostic"] = productFieldDiagnostic
                }
                var evidence = record["evidence"] as? [String: Any] ?? [:]
                evidence["gmail"] = gmail
                record["evidence"] = evidence
            }
            if let client {
                record["progress"] = client.taskProgressHistory
                if let outcome = client.latestTerminalOutcome { record["raw_outcome"] = outcome.rawValue }
                if let guidance = client.interventionGuidance, !guidance.isEmpty { record["text"] = guidance }
            }
            let terminalFailure = Self.failureClass(outcome: record["raw_outcome"] as? String,
                                                     text: record["text"] as? String)
            if let terminalFailure,
               (terminalFailure == "guard-rejected" || terminalFailure == "approval-needed"
                    || terminalFailure == "model-malformed" || terminalFailure == "text-entry") {
                record["failure_class"] = terminalFailure
            } else {
                record["failure_class"] = Self.failureClass(error: error)
            }
            if (record["text"] as? String)?.isEmpty != false {
                record["text"] = String(describing: error).prefix(1_000).description
            }
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1_000)
        }
        if let manager {
            await manager.shutdown()
            await OSAtlasLlamaRuntime.shared.shutdown()
        }
    }

    private enum HarnessError: LocalizedError {
        case prerequisite(String), transport(String), missingEvidence(String)
        var errorDescription: String? {
            switch self {
            case .prerequisite(let text), .transport(let text), .missingEvidence(let text): text
            }
        }
    }

    private static func sanitizedGmailFieldDiagnostic(from loader: GmailAcceptanceVisualExecutorLoader?)
        -> [String: Any] {
        var result: [String: Any] = ["executorCaptured": loader?.defaultBrowserExecutor != nil]
        guard let raw = loader?.defaultBrowserExecutor?.lastActionDiagnosticForTests else { return result }
        for key in ["gmailSubjectFieldCount", "gmailMessageBodyFieldCount"] {
            if let value = raw[key], let count = Int(value), (0...1_024).contains(count) {
                result[key] = count
            }
        }
        for key in ["gmailSubjectValueMatches", "gmailMessageBodyValueMatches"] {
            if raw[key] == "true" { result[key] = true }
            if raw[key] == "false" { result[key] = false }
        }
        if let phase = raw["gmailNavigationPhase"],
           phase.range(of: #"^phase=[a-z_]+$"#, options: .regularExpression) != nil {
            result["gmailNavigationPhase"] = phase
        }
        if let phase = Self.sanitizedSessionValidationPhase(raw["sessionValidationPhase"]) {
            result["sessionValidationPhase"] = phase
        }
        if let reason = Self.sanitizedSessionCaptureReason(raw["sessionCaptureReason"]) {
            result["sessionCaptureReason"] = reason
        }
        if let code = Self.sanitizedSessionCaptureAXErrorCode(raw["sessionCaptureAXErrorCode"]) {
            result["sessionCaptureAXErrorCode"] = code
        }
        for (key, value) in Self.sanitizedDesktopRevalidationDiagnostic(raw) {
            result[key] = value
        }
        let sessionFailures: Set<String> = ["changedTaskOrGoal", "targetLost", "ambiguousWindows",
            "noNewFocusedWindow", "existingWindowsChanged", "interrupted", "journalUncertain",
            "authenticationHandoff", "browserAutomationPermissionRequired"]
        if raw["lastSessionFailureForDiagnostics"] == "nil" {
            result["lastSessionFailureForDiagnostics"] = "nil"
        } else if let failure = raw["lastSessionFailureForDiagnostics"],
                  failure.hasPrefix("Optional("), failure.hasSuffix(")") {
            let inner = String(failure.dropFirst("Optional(".count).dropLast())
            guard inner.range(of: #"^(?:[A-Za-z0-9_]+\.)*[A-Za-z0-9_]+$"#,
                options: .regularExpression) != nil else { return result }
            let caseName = String(inner.split(separator: ".").last ?? "")
            if sessionFailures.contains(caseName) {
                result["lastSessionFailureForDiagnostics"] = "Optional(\(caseName))"
            }
        } else if let failure = raw["lastSessionFailureForDiagnostics"], sessionFailures.contains(failure) {
            result["lastSessionFailureForDiagnostics"] = failure
        }
        return result
    }

    private static func sanitizedDesktopRevalidationDiagnostic(_ raw: [String: String]) -> [String: Any] {
        let blockedStages: Set<String> = [
            "scope-wait-active-app-before-check", "scope-wait-deadline", "scope-wait-active-app-after-check",
            "initial-editor-sample-active-app-before-check", "initial-editor-sample-active-app-after-check",
            "initial-editor-sample-scope-invalid", "settle-active-app-before-editor-sample",
            "settle-active-app-after-pre-sample-scope", "settle-scope-invalid-before-editor-sample",
            "settle-active-app-before-post-sample-check", "settle-active-app-after-post-sample-scope",
            "settle-scope-invalid-after-editor-sample", "editor-settle-timeout", "editor-settle-deadline-reobserve", "screen-consent-recognition",
            "typing-target-unavailable", "approval-fingerprint-preparation", "approval-fingerprint-dispatch",
        ]
        var result: [String: Any] = [:]
        if let stage = raw["blockedAt"], blockedStages.contains(stage) {
            result["blockedAt"] = stage
        }
        for key in ["sampleCount", "tokenChangeCount", "nilSampleCount"] {
            if let value = raw[key], let count = Int(value), (0...4_096).contains(count) {
                result[key] = count
            }
        }
        for key in ["elapsedMs", "quietMs"] {
            if let value = raw[key], let milliseconds = Int(value), (0...120_000).contains(milliseconds) {
                result[key] = milliseconds
            }
        }
        let continuationFailures: Set<String> = ["sessionAuthenticationHandoff", "desktopFailure", "sessionFailure",
            "browserFailure", "hostFailure", "other"]
        if let failure = raw["approvedVisualContinuationFailure"], continuationFailures.contains(failure) {
            result["approvedVisualContinuationFailure"] = failure
        }
        let desktopFailures: Set<String> = ["changedTask", "recoveredTask", "changedScreen", "scopedSurfaceChanged",
            "completionUnverified", "unsupportedAction", "invalidApproval", "stepLimit", "authentication"]
        if let failure = raw["approvedVisualContinuationDesktopFailure"], desktopFailures.contains(failure) {
            result["approvedVisualContinuationDesktopFailure"] = failure
        }
        let finiteLabels: [String: Set<String>] = [
            "rejectedFailure": ["changedScreen", "completionUnverified", "unsupportedAction"],
            "decisionKind": ["completionStatus", "handoff", "refreshObservation", "unsupported", "pointer",
                "typeText", "key", "scroll", "visitURL", "unsupportedNavigation", "historyBack", "webSearch",
                "readPageQuestion", "remember", "askUser", "localFileOperation", "wait", "reportCompletion"],
            "completionVerificationPhase": ["outcome-check", "complete-check", "final-surface", "verified", "check-rejected"],
            "gmailFlowStage": ["compose", "normalizeDrafts", "waitingForDraftReopen", "attach", "waitingForPicker",
                "waitingForAttachment", "send", "saveDraft", "verifySend", "verifyDraft", "complete"],
            "gmailPendingFlowStage": ["compose", "normalizeDrafts", "waitingForDraftReopen", "attach", "waitingForPicker",
                "waitingForAttachment", "send", "saveDraft", "verifySend", "verifyDraft", "complete"],
            "gmailNavigationStage": ["navigateTarget", "waitForTarget", "ready"],
        ]
        for (key, allowed) in finiteLabels {
            if let value = raw[key], allowed.contains(value) { result[key] = value }
        }
        if let count = raw["rejectedCount"].flatMap(Int.init), (1...3).contains(count) {
            result["rejectedCount"] = count
        }
        if let value = raw["completionOutcomeAccepted"], ["true", "false"].contains(value) {
            result["completionOutcomeAccepted"] = value == "true"
        }
        return result
    }

    private static func gmailSavedRecipientProofRetryEligible(_ evidence: [String: Any]) -> Bool {
        guard let diagnostic = evidence["recipient_proof_diagnostic"] as? [String: Any],
              let phase = diagnostic["phase"] as? String,
              ["subject_ancestor_chip_missing", "chip_reacquisition_compose_unavailable",
               "chip_reacquisition_chip_missing", "chip_reacquisition_metadata_changed"].contains(phase),
              diagnostic["opened_menu_count"] as? Int == 0,
              diagnostic["menu_scan_nodes_visited"] as? Int == 0,
              diagnostic["preexisting_menu_count"] as? Int == 0 else { return false }
        if let counts = diagnostic["subject_ancestor_candidate_counts"] as? [Int], counts.contains(where: { $0 > 1 }) {
            return false
        }
        if let counts = diagnostic["recipient_reacquisition_candidate_counts"] as? [Int], counts.contains(where: { $0 > 1 }) {
            return false
        }
        return true
    }

    private static func sanitizedSessionValidationPhase(_ raw: String?) -> String? {
        guard let raw, ["capture", "target", "sheet", "focus", "complete"].contains(raw) else { return nil }
        return raw
    }

    private static func sanitizedSessionCaptureReason(_ raw: String?) -> String? {
        let allowed: Set<String> = ["capture_cancelled", "frontmost_unavailable", "frontmost_process_mismatch",
            "frontmost_identity_mismatch", "windows_read", "windows_malformed", "windows_unconvertible",
            "focused_window_read", "focused_window_malformed", "focused_window_unconvertible",
            "capture_deadline", "final_frontmost_unavailable", "final_frontmost_changed",
            "retained_target_missing_or_ambiguous", "retained_target_pid", "pid", "bounds_read",
            "bounds_deadline", "bounds_type", "bounds_malformed", "focused_duplicate", "duplicate_id",
            "duplicate_element", "bounds_ax_read_failure"]
        guard let raw, allowed.contains(raw) else { return nil }
        return raw
    }

    private static func sanitizedSessionCaptureAXErrorCode(_ raw: String?) -> Int? {
        guard let raw, let code = Int(raw), (-65_535...65_535).contains(code) else { return nil }
        return code
    }

    private struct Terminal {
        let outcome: String
        let approvedDrafts: Int
        let deniedApprovals: Int
        let attachmentApprovalCount: Int
        let attachmentApprovalVerified: Bool
        let attachmentApprovalResponsesGranted: Int
        let sendApprovalObserved: Bool
        let sendApprovalFieldsExact: Bool
        let sendApprovalResponsesGranted: Int
        let sendApprovalResponsesDenied: Int
        let approvalEvents: [[String: Any]]
        let approvalEventsOmitted: Int
    }

    func testFailureClassSeparatesGeneratedToolSchemaFailuresFromHostGuardRejection() {
        let unable = RemoteDesktopClientCore.ComputerUseTerminalOutcome.unableToComplete.rawValue
        XCTAssertEqual(Self.failureClass(outcome: unable,
            text: "The local planning request is invalid: Generated arguments for example_tool did not satisfy the tool schema: A generated string is shorter than its minimum length."),
            "model-malformed")
        XCTAssertEqual(Self.failureClass(outcome: unable,
            text: "The local planning request is invalid: The selected file changed during validation."),
            "guard-rejected")
        XCTAssertEqual(Self.failureClass(outcome: RemoteDesktopClientCore.ComputerUseTerminalOutcome.userInterventionRequired.rawValue,
            text: "The selected Gmail account could not be confirmed for this draft. Review the account before continuing."),
            "guard-rejected", "A failed account proof is a host guard rejection, not an approval request")
        XCTAssertEqual(Self.failureClass(outcome: unable,
            text: "I couldn't complete that task: The app did not confirm the exact text edit. Check the field before continuing; the edit was not retried."),
            "text-entry")
    }

    func testFailureClassSeparatesScreenPermissionAndWindowHandoffs() {
        let intervention = RemoteDesktopClientCore.ComputerUseTerminalOutcome.userInterventionRequired.rawValue
        XCTAssertEqual(Self.failureClass(outcome: intervention,
            text: "Close the covering window or handle the system dialog, then bring the intended window to the front and choose Resume."),
            "guard-rejected")
        XCTAssertEqual(Self.failureClass(outcome: intervention,
            text: "Complete sign-in or the system permission step, then choose Resume."), "permission")
        XCTAssertEqual(Self.failureClass(outcome: intervention,
            text: "The intended browser window changed or is unavailable. Restore it, then choose Resume."), "window-lost")
        XCTAssertEqual(Self.failureClass(outcome: intervention,
            text: "The app did not confirm the exact text edit. Check the field before continuing; the edit was not retried."),
            "text-entry")
        XCTAssertEqual(Self.failureClass(outcome: intervention, text: "Review this step, then choose Resume."),
            "approval-needed")
    }

    private static func waitForReady(_ host: HostComputerUseManager,
        deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if host.capability.state == .ready { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return host.capability.state == .ready
    }

    private static func waitForSentPrompt(_ bridge: SerializedClarificationClientChannel,
        deadline: ContinuousClock.Instant) async throws -> String {
        while ContinuousClock.now < deadline {
            if let id = await bridge.prompts().last?.id { return id }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.transport("The serialized client did not publish the job prompt")
    }

    private static func gmailAttachmentApprovalDetailsMatch(
        _ request: RemoteDesktopClientCore.ComputerUseApprovalRequest, expected: Expected
    ) -> Bool {
        guard request.confirmLabel == "Attach file",
              let name = expected.attachment_name, let byteCount = expected.source_bytes,
              let recipient = expected.to, let subject = expected.subject,
              let details = request.details, details.count == 5 else { return false }
        let labels = details.map(\.label)
        guard Set(labels).count == labels.count else { return false }
        let fields = Dictionary(uniqueKeysWithValues: details.map { ($0.label, $0.value) })
        return fields.count == 5
            && fields["File"] == name
            && fields["Size"] == "\(byteCount) bytes"
            && fields["Destination"] == "Gmail (\(recipient))"
            && fields["To"] == recipient
            && fields["Subject"] == subject
            && fields["CC"] == nil && fields["BCC"] == nil
    }

    @MainActor
    private static func gmailAttachmentApprovalHasIndependentPickerProof(
        expected: Expected, diagnostic: (String) -> Void = { _ in }
    ) -> Bool {
        func fail(_ reason: String) -> Bool {
            diagnostic(reason)
            return false
        }
        guard let sourcePath = expected.source_path, let expectedBytes = expected.source_bytes,
              let expectedDigest = expected.source_sha256?.lowercased(), expectedBytes >= 0,
              expectedDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return fail("source")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        var sourceInfo = stat()
        guard sourceURL.isFileURL, lstat(sourceURL.path, &sourceInfo) == 0,
              (sourceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              sourceInfo.st_size == off_t(expectedBytes),
              sourceURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL == sourceURL,
              (try? Self.sha256(sourceURL)) == expectedDigest else { return fail("source") }

        let selectedURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        var panelFailureReason = "panel"
        func exactPanel() -> (ComputerUseApplicationIdentity,
            ComputerUseDefaultBrowserSession.Window, ComputerUseDefaultBrowserSession.FileOpenPanel)? {
            guard let handler = ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler(),
                  let running = NSWorkspace.shared.frontmostApplication, !running.isTerminated,
                  handler.bundleIdentifier == "com.apple.Safari",
                  running.bundleIdentifier == handler.bundleIdentifier,
                  let proof = ComputerUseReviewedApplicationCodeVerifier.proofForRunningApplication(
                    runningApplication: running),
                  proof.canonicalBundlePath == handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
                  let application = ComputerUseApplicationIdentity(runningApplication: running,
                    codeIdentity: proof), application.matchesReviewedApplication(named: "Safari") else {
                panelFailureReason = "application"
                return nil
            }
            guard let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
                  snapshot.application == application, !snapshot.hasUnrecognizedSheets,
                  let panel = snapshot.fileOpenPanel, panel.isFocused, panel.primaryActionEnabled == true,
                  panel.selectedFileURLs.count == 1,
                  panel.selectedFileURLs[0].standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL == selectedURL else {
                panelFailureReason = "panel"
                return nil
            }
            let parents = snapshot.windows.filter { $0.id == panel.parentWindowID }
            guard parents.count == 1, let parent = parents.first,
                  parent.application == application,
                  CFEqual(parent.accessibilityElement, panel.parentWindowElement) else { return nil }
            return (application, parent, panel)
        }
        guard let (application, parent, initialPanel) = exactPanel() else { return fail(panelFailureReason) }
        let reader = ComputerUseDefaultBrowserPageReader()
        guard let pageURL = try? reader.readRetainedPageURL(window: parent.accessibilityElement,
                application: application, mayAct: { !Task.isCancelled }),
              URLComponents(string: pageURL)?.host?.lowercased() == "mail.google.com" else { return fail("url") }
        guard let accountIndex = ComputerUseGmailAccountDirectory.accountIndex(from: pageURL) else {
            return fail("account")
        }
        let account = ComputerUseGmailAccountDirectory.Account(email: expected.to ?? "", displayName: "",
            index: accountIndex)
        guard !account.email.isEmpty else { return fail("account") }

        var revalidationFailed = false
        let revalidate: @MainActor () throws -> Void = {
            guard !Task.isCancelled, let (freshApplication, freshParent, freshPanel) = exactPanel(),
                  freshApplication == application, freshParent.id == parent.id,
                  CFEqual(freshParent.accessibilityElement, parent.accessibilityElement),
                  CFEqual(freshPanel.accessibilityElement, initialPanel.accessibilityElement) else {
                revalidationFailed = true
                throw HarnessError.missingEvidence("The Gmail picker or retained parent changed during approval proof")
            }
        }
        let accountLabel: String?
        do {
            accountLabel = try ComputerUseGmailRecipientVerifier.accountControlLabel(
                window: parent.accessibilityElement, application: application, revalidate: revalidate)
        } catch { return fail(revalidationFailed ? "stability" : "account") }
        let title: String?
        do {
            title = try ComputerUseGmailAccountDirectory.observedWindowTitle(
                window: parent.accessibilityElement, application: application, revalidate: revalidate)
        } catch { return fail(revalidationFailed ? "stability" : "account") }
        guard ComputerUseGmailAccountDirectory.confirmsActiveAccount(currentURL: pageURL, windowTitle: title,
                accountControlLabel: accountLabel, expected: account) else { return fail("account") }
        guard let afterPageURL = try? reader.readRetainedPageURL(window: parent.accessibilityElement,
                application: application, mayAct: { !Task.isCancelled }) else { return fail("url") }
        guard afterPageURL == pageURL,
              let (afterApplication, afterParent, afterPanel) = exactPanel(),
              afterApplication == application, afterParent.id == parent.id,
              CFEqual(afterParent.accessibilityElement, parent.accessibilityElement),
              CFEqual(afterPanel.accessibilityElement, initialPanel.accessibilityElement) else {
            return fail("stability")
        }
        return true
    }

    private static func waitForTerminal(_ client: RemoteDesktopClientCore.ComputerUseSessionModel,
        expected: Expected, taskID: String, deadline: ContinuousClock.Instant, trace: URL) async throws -> Terminal {
        var deniedApprovals = 0
        var attachmentApprovalCount = 0
        var attachmentApprovalVerified = false
        var attachmentApprovalResponsesGranted = 0
        let sendApprovalResponsesGranted = 0
        let sendApprovalResponsesDenied = 0
        var approvalEvents: [[String: Any]] = []
        var approvalEventsOmitted = 0
        var respondedRequestIDs = Set<String>()
        var lastObservation = ""
        var answeredGmailAccountClarifications = Set<String>()
        while ContinuousClock.now < deadline {
            let observation = String(describing: client.state) + client.statusText
                + client.taskProgressHistory.joined(separator: "\n")
            if observation != lastObservation {
                try Self.write(["state": String(describing: client.state), "status": client.statusText,
                    "terminal": client.latestTerminalOutcome?.rawValue ?? "",
                    "intervention": client.interventionGuidance ?? "",
                    "assistant": String(client.messages.last(where: { $0.author == .assistant })?.text.prefix(12_000) ?? ""),
                    "progress": client.taskProgressHistory],
                    to: trace.appendingPathComponent("client-state.json"))
                lastObservation = observation
            }
            if expected.job == "gmail", let expectedAddress = expected.to,
               case .answer(let reference, let validUntil) = client.composerMode,
               validUntil > Date(),
               let choices = client.clarificationChoices,
               let choice = Self.gmailAccountChoice(in: choices, expectedAddress: expectedAddress) {
                let clarificationKey = "\(reference.taskID):\(choice.id)"
                if !answeredGmailAccountClarifications.contains(clarificationKey),
                   client.sendClarificationChoice(choice.id) {
                    answeredGmailAccountClarifications.insert(clarificationKey)
                    try Self.write(["task_id": reference.taskID, "choice_id": choice.id,
                        "account_detail": choice.detail ?? "", "choice_count": choices.count,
                        "answer_sent": true], to: trace.appendingPathComponent("gmail-account-choice.json"))
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
            }
            if case .approvalRequired(let request) = client.state {
                if expected.job == "gmail", request.confirmLabel == "Attach file" {
                    attachmentApprovalCount += 1
                    let freshRequest: Bool
                    if case .approvalRequired(let current) = client.state {
                        freshRequest = current == request && current.taskID == taskID
                            && !current.requestID.isEmpty && !respondedRequestIDs.contains(current.requestID)
                    } else {
                        freshRequest = false
                    }
                    if attachmentApprovalCount == 1, attachmentApprovalResponsesGranted == 0,
                       freshRequest, Self.gmailAttachmentApprovalDetailsMatch(request, expected: expected),
                       Self.gmailAttachmentApprovalHasIndependentPickerProof(expected: expected, diagnostic: { reason in
                           try? Self.write(["reason": reason],
                               to: trace.appendingPathComponent("gmail-attachment-proof.json"))
                       }),
                       case .approvalRequired(let current) = client.state, current == request,
                       current.taskID == taskID, !respondedRequestIDs.contains(current.requestID) {
                        attachmentApprovalVerified = true
                        respondedRequestIDs.insert(request.requestID)
                        attachmentApprovalResponsesGranted += 1
                        if approvalEvents.count < 24 {
                            approvalEvents.append([
                                "request_id": request.requestID,
                                "task_id": request.taskID,
                                "confirm_label": request.confirmLabel ?? "",
                                "verified_file_approval": true,
                                "details": (request.details ?? []).map { ["label": $0.label, "value": $0.value] },
                            ])
                        } else {
                            approvalEventsOmitted += 1
                        }
                        try? Self.write(["events": approvalEvents, "omitted": approvalEventsOmitted],
                            to: trace.appendingPathComponent("gmail-approval-events.json"))
                        client.respondToApproval(request, approved: true)
                        continue
                    }
                }
                let details = request.details ?? []
                let labels = details.map(\.label)
                let fields = Set(labels).count == labels.count
                    ? Dictionary(uniqueKeysWithValues: details.map { ($0.label, $0.value) }) : [:]
                let exactFields = fields["To"] == expected.to && fields["Subject"] == expected.subject
                    && fields["Message"] == expected.body && fields["Attachment 1"] == expected.source_path
                    && fields["CC"] == nil && fields["BCC"] == nil
                    && fields["Attachment 2"] == nil && fields["Attachment 3"] == nil
                    && fields["Attachment 4"] == nil && fields["Attachment 5"] == nil
                if expected.send_approval_check == true, expected.job == "email",
                   request.taskID == taskID, !respondedRequestIDs.contains(request.requestID),
                   request.confirmLabel == "Send email", exactFields {
                    // Observe the exact approval and leave it pending. No
                    // approval response can grant permission to send.
                    return Terminal(outcome: "approvalRequired", approvedDrafts: 0,
                        deniedApprovals: deniedApprovals, attachmentApprovalCount: attachmentApprovalCount,
                        attachmentApprovalVerified: attachmentApprovalVerified,
                        attachmentApprovalResponsesGranted: attachmentApprovalResponsesGranted,
                        sendApprovalObserved: true, sendApprovalFieldsExact: true,
                        sendApprovalResponsesGranted: sendApprovalResponsesGranted,
                        sendApprovalResponsesDenied: sendApprovalResponsesDenied,
                        approvalEvents: approvalEvents, approvalEventsOmitted: approvalEventsOmitted)
                }
                let gmailSendMessage = fields["Message"] as? String ?? ""
                let gmailAttachmentPresentation = expected.attachment_name.map { name in
                    "\(name) (\(expected.source_bytes ?? -1) bytes)"
                }
                let gmailSendFieldsExact = request.confirmLabel == "Send email"
                    && fields["To"] == expected.to && fields["Subject"] == expected.subject
                    && gmailSendMessage.hasPrefix(expected.body ?? "")
                    && fields["Attachment"] == gmailAttachmentPresentation
                    && fields["CC"] == nil && fields["BCC"] == nil
                    && fields["Attachment 2"] == nil && fields["Attachment 3"] == nil
                    && fields["Attachment 4"] == nil && fields["Attachment 5"] == nil
                if expected.job == "gmail", request.confirmLabel == "Send email" {
                    let taskBoundSendApproval = request.taskID == taskID
                        && !request.requestID.isEmpty && !respondedRequestIDs.contains(request.requestID)
                    let event: [String: Any] = [
                        "request_id": request.requestID,
                        "task_id": request.taskID,
                        "confirm_label": request.confirmLabel ?? "",
                        "send_fields_exact": taskBoundSendApproval && gmailSendFieldsExact,
                        "message": request.message,
                        "details": (request.details ?? []).map { ["label": $0.label, "value": $0.value] },
                    ]
                    return Terminal(outcome: "approvalRequired", approvedDrafts: 0,
                        deniedApprovals: deniedApprovals, attachmentApprovalCount: attachmentApprovalCount,
                        attachmentApprovalVerified: attachmentApprovalVerified,
                        attachmentApprovalResponsesGranted: attachmentApprovalResponsesGranted,
                        sendApprovalObserved: true,
                        sendApprovalFieldsExact: expected.send_approval_check == true
                            && taskBoundSendApproval && gmailSendFieldsExact,
                        sendApprovalResponsesGranted: sendApprovalResponsesGranted,
                        sendApprovalResponsesDenied: sendApprovalResponsesDenied,
                        approvalEvents: approvalEvents + [event], approvalEventsOmitted: approvalEventsOmitted)
                }
                if expected.job == "gmail" {
                    if approvalEvents.count < 24 {
                        approvalEvents.append([
                            "request_id": request.requestID,
                            "task_id": request.taskID,
                            "confirm_label": request.confirmLabel ?? "",
                            "message": request.message,
                            "details": (request.details ?? []).map { ["label": $0.label, "value": $0.value] },
                        ])
                    } else {
                        approvalEventsOmitted += 1
                    }
                    try? Self.write(["events": approvalEvents, "omitted": approvalEventsOmitted],
                        to: trace.appendingPathComponent("gmail-approval-events.json"))
                }
                deniedApprovals += 1
                client.respondToApproval(request, approved: false)
            }
            if let outcome = client.latestTerminalOutcome,
               !client.hasActivePrompt || outcome == .userInterventionRequired {
                return Terminal(outcome: outcome.rawValue, approvedDrafts: 0,
                    deniedApprovals: deniedApprovals, attachmentApprovalCount: attachmentApprovalCount,
                    attachmentApprovalVerified: attachmentApprovalVerified,
                    attachmentApprovalResponsesGranted: attachmentApprovalResponsesGranted,
                    sendApprovalObserved: false, sendApprovalFieldsExact: false,
                    sendApprovalResponsesGranted: sendApprovalResponsesGranted,
                    sendApprovalResponsesDenied: sendApprovalResponsesDenied,
                    approvalEvents: approvalEvents, approvalEventsOmitted: approvalEventsOmitted)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.transport("Timed out waiting for the shipped client terminal outcome")
    }

    private static func gmailAccountChoice(in choices: [RemoteDesktopClientCore.ComputerUseClarificationChoice],
                                           expectedAddress: String) -> RemoteDesktopClientCore.ComputerUseClarificationChoice? {
        guard (2...RemoteDesktopClientCore.ComputerUseClarificationChoice.maximumChoices).contains(choices.count),
              !expectedAddress.isEmpty,
              choices.allSatisfy({ $0.id.hasPrefix("gmail-account-") }) else { return nil }
        let matches = choices.filter { $0.detail?.utf8.elementsEqual(expectedAddress.utf8) == true }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func gmailPreferencePreflight(preferredEmail: String?,
                                                 expectedAddress: String?) -> GmailPreferencePreflight {
        guard let expectedAddress,
              ComputerUseGmailAccountDirectory.email(in: expectedAddress) == expectedAddress.lowercased() else {
            return .missingExpectedAddress
        }
        guard let preferredEmail else { return .allowed }
        guard ComputerUseGmailAccountDirectory.email(in: preferredEmail) == preferredEmail.lowercased() else {
            return .malformedPreference
        }
        return preferredEmail.utf8.elementsEqual(expectedAddress.utf8) ? .allowed : .conflictingPreference
    }

    private static func captureGmailDraft(expected: Expected, evidence: inout [String: Any],
                                          verifySavedDraft: Bool = false,
                                          requiredComposeURL: String? = nil,
                                          requiredApplication: ComputerUseApplicationIdentity? = nil,
                                          requiredWindowID: String? = nil,
                                          readinessDeadline: ContinuousClock.Instant? = nil) async {
        var recipientMenuEffectAttempted = false
        func boundedDeadline(after duration: Duration) -> ContinuousClock.Instant {
            let requested = ContinuousClock.now.advanced(by: duration)
            // After opening a menu, finish its independently bounded proof and
            // dismissal even if the pre-action readiness deadline has expired.
            return recipientMenuEffectAttempted ? requested : min(requested, readinessDeadline ?? requested)
        }
        guard let name = expected.attachment_name, let recipient = expected.to,
              let subject = expected.subject, let body = expected.body else {
            evidence["capture_status"] = "missing-expected-gmail-fields"
            return
        }
        let probeEnvironment = ProcessInfo.processInfo.environment
        let draftRowProbeEnabled = verifySavedDraft
            && probeEnvironment["RUN_GMAIL_DRAFT_ROW_CAPTURE_PROBE"] == "1"
            && probeEnvironment["GMAIL_DRAFT_ROW_CAPTURE_PROBE_SUBJECT"] == subject
        let existingDraftRecipientProbeEnabled = !verifySavedDraft
            && probeEnvironment["RUN_GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE"] == "1"
            && probeEnvironment["GMAIL_EXISTING_DRAFT_RECIPIENT_PROBE_SUBJECT"] == subject
        var captured: (ComputerUseApplicationIdentity, ComputerUseDefaultBrowserSession.Window,
                       ComputerUseDefaultBrowserPageReader.Observation)?
        let loadDeadline = boundedDeadline(after: .seconds(5))
        while ContinuousClock.now < loadDeadline, !Task.isCancelled {
            if let (_, application, _) = ComputerUseDefaultBrowserTarget.currentDefaultHandlerForegroundWindow(),
               let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
               let focusedID = snapshot.focusedWindowID,
               let window = snapshot.windows.first(where: { $0.id == focusedID }),
               let page = try? ComputerUseDefaultBrowserPageReader().read(window: window.accessibilityElement,
                    application: application, mayAct: { true }),
               page.application == application,
               URLComponents(string: page.url)?.host?.lowercased() == "mail.google.com" {
                captured = (application, window, page)
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let (application, window, page) = captured else {
            evidence["capture_status"] = "no-focused-default-browser-page"
            return
        }
        if let requiredApplication, application != requiredApplication
            || requiredWindowID.map({ window.id != $0 }) == true {
            evidence["capture_status"] = "recipient-retry-window-changed"
            evidence["account_identity_verified"] = false
            return
        }
        let host = URLComponents(string: page.url)?.host?.lowercased() ?? ""
        evidence["browser_bundle_id"] = application.bundleIdentifier
        evidence["url_host"] = host
        evidence["compose_url"] = page.url
        evidence["url_is_gmail"] = host == "mail.google.com"
        guard host == "mail.google.com" else {
            evidence["capture_status"] = "focused-page-is-not-gmail"
            return
        }
        guard let expectedAccount = expected.to,
              let accountIndex = ComputerUseGmailAccountDirectory.accountIndex(from: page.url) else {
            evidence["account_identity_verified"] = false
            evidence["capture_status"] = "gmail-account-unverified"
            return
        }
        if let requiredComposeURL,
           (page.url != requiredComposeURL
            || !Self.gmailIsOwnedOpaqueDraftComposeURL(page.url, expectedAccountIndex: accountIndex)) {
            evidence["capture_status"] = "recipient-retry-compose-url-changed"
            evidence["account_identity_verified"] = false
            return
        }
        let account = ComputerUseGmailAccountDirectory.Account(email: expectedAccount, displayName: "",
            index: accountIndex)
        let reader = ComputerUseDefaultBrowserPageReader()
        var accountRevalidationFailed = false
        var revalidatedWindowBounds = window.identity.bounds
        var retainedPageURL = page.url
        let revalidateAccountPage: @MainActor () throws -> Void = {
            guard !Task.isCancelled,
                  let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
                  snapshot.application == application,
                  snapshot.focusedWindowID == window.id,
                  !snapshot.hasSheets, !snapshot.hasUnrecognizedSheets, snapshot.fileOpenPanel == nil,
                  snapshot.windows.filter({ $0.id == window.id }).count == 1,
                  let currentWindow = snapshot.windows.first(where: { $0.id == window.id }),
                  CFEqual(currentWindow.accessibilityElement, window.accessibilityElement),
                  let currentURL = try? reader.readRetainedPageURL(window: currentWindow.accessibilityElement,
                    application: application, mayAct: { !Task.isCancelled }),
                  currentURL == retainedPageURL else {
                accountRevalidationFailed = true
                throw HarnessError.missingEvidence("The owned Gmail page changed during the independent account proof")
            }
            revalidatedWindowBounds = currentWindow.identity.bounds
        }
        let accountLabel: String?
        do {
            accountLabel = try ComputerUseGmailRecipientVerifier.accountControlLabel(
                window: window.accessibilityElement, application: application, revalidate: revalidateAccountPage)
        } catch {
            evidence["account_identity_verified"] = false
            evidence["capture_status"] = accountRevalidationFailed ? "gmail-account-page-changed" : "gmail-account-unverified"
            return
        }
        let windowTitle: String?
        do {
            windowTitle = try ComputerUseGmailAccountDirectory.observedWindowTitle(
                window: window.accessibilityElement, application: application, revalidate: revalidateAccountPage)
        } catch {
            evidence["account_identity_verified"] = false
            evidence["capture_status"] = accountRevalidationFailed ? "gmail-account-page-changed" : "gmail-account-unverified"
            return
        }
        guard ComputerUseGmailAccountDirectory.confirmsActiveAccount(currentURL: page.url,
                windowTitle: windowTitle, accountControlLabel: accountLabel, expected: account),
              let finalURL = try? reader.readRetainedPageURL(window: window.accessibilityElement,
                application: application, mayAct: { !Task.isCancelled }), finalURL == page.url else {
            evidence["account_identity_verified"] = false
            evidence["capture_status"] = "gmail-account-unverified"
            return
        }
        evidence["account_identity_verified"] = true
        evidence["gmail_account_index"] = accountIndex
        func value(_ attribute: String, _ element: AXUIElement, timeout: Float = 0.1) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, timeout)
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func axBounds(_ element: AXUIElement) -> CGRect? {
            guard let rawPosition = value(kAXPositionAttribute as String, element, timeout: 0.5),
                  let rawSize = value(kAXSizeAttribute as String, element, timeout: 0.5),
                  CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
        struct Node {
            let element: AXUIElement
            let role, title, description, text: String
        }
        func readTree(_ root: AXUIElement, limit: Int) -> [Node]? {
            var queue = [root]
            var visited: [AXUIElement] = []
            var result: [Node] = []
            let deadline = boundedDeadline(after: .seconds(2))
            while !queue.isEmpty, visited.count < limit, ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                if pruneDiscoverySubtree(element, role: role) { continue }
                let title = value(kAXTitleAttribute as String, element) as? String ?? ""
                let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
                let text = value(kAXValueAttribute as String, element) as? String ?? ""
                result.append(Node(element: element, role: role, title: title, description: description, text: text))
                if role == "AXSheet" || role == "AXDialog" || role == "AXWebArea" { continue }
                if let children = value(kAXChildrenAttribute as String, element) as? [AXUIElement] {
                    let room = max(0, limit - visited.count - queue.count)
                    guard children.count <= room else { return nil }
                    queue.append(contentsOf: children)
                }
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            return result
        }
        func pruneDiscoverySubtree(_ element: AXUIElement, role: String) -> Bool {
            if ["AXSheet", "AXToolbar", "AXSecureTextField"].contains(role) { return true }
            if value(kAXHiddenAttribute as String, element) as? Bool == true
                || value("AXProtectedContent", element) as? Bool == true { return true }
            if role == "AXTextField" || role == "AXTextArea" {
                return value(kAXSubroleAttribute as String, element) as? String == "AXSecureTextField"
            }
            return false
        }
        let composerScanNodeLimit = 512
        let composerScanDuration = Duration.seconds(3)
        func discoverComposers(_ root: AXUIElement, visitedCount: inout Int,
            incompleteReason: inout String) -> [Node]? {
            var queue = [root]
            var visited: [AXUIElement] = []
            var composers: [Node] = []
            let deadline = boundedDeadline(after: composerScanDuration)
            while !queue.isEmpty, visited.count < composerScanNodeLimit,
                  ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                visitedCount = visited.count
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                if pruneDiscoverySubtree(element, role: role) { continue }
                if role == "AXWebArea" && !CFEqual(element, root) { continue }
                let title = role == "AXGroup" ? (value(kAXTitleAttribute as String, element) as? String ?? "") : ""
                let description = role == "AXGroup" ? (value(kAXDescriptionAttribute as String, element) as? String ?? "") : ""
                if role == "AXGroup" && (title.hasPrefix("Compose:") || description.hasPrefix("Compose:")) {
                    composers.append(Node(element: element, role: role, title: title, description: description, text: ""))
                    continue
                }
                // Gmail's inbox is an AXTable; its thousands of rows are unrelated to this owned compose.
                if role == "AXTable" || role == "AXOutline" || role == "AXList" { continue }
                if let children = value(kAXChildrenAttribute as String, element) as? [AXUIElement] {
                    let room = max(0, composerScanNodeLimit - visited.count - queue.count)
                    guard children.count <= room else { incompleteReason = "node_limit"; return nil }
                    queue.append(contentsOf: children)
                }
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else {
                incompleteReason = Task.isCancelled ? "cancelled"
                    : (ContinuousClock.now >= deadline ? "deadline" : "node_limit")
                return nil
            }
            return composers
        }
        func discoverStandaloneSubjectGroups(_ root: AXUIElement, visitedCount: inout Int,
            incompleteReason: inout String) -> [Node]? {
            var queue = [root]
            var visited: [AXUIElement] = []
            var groups: [Node] = []
            let deadline = boundedDeadline(after: composerScanDuration)
            while !queue.isEmpty, visited.count < composerScanNodeLimit,
                  ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                visitedCount = visited.count
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                if pruneDiscoverySubtree(element, role: role) { continue }
                if role == "AXWebArea" && !CFEqual(element, root) { continue }
                let title = role == "AXGroup" ? (value(kAXTitleAttribute as String, element) as? String ?? "") : ""
                let description = role == "AXGroup" ? (value(kAXDescriptionAttribute as String, element) as? String ?? "") : ""
                let text = role == "AXGroup" ? (value(kAXValueAttribute as String, element) as? String ?? "") : ""
                if role == "AXGroup" && [title, description, text].contains(subject) {
                    groups.append(Node(element: element, role: role, title: title,
                        description: description, text: text))
                    continue
                }
                if role == "AXTable" || role == "AXOutline" || role == "AXList" { continue }
                if let children = value(kAXChildrenAttribute as String, element) as? [AXUIElement] {
                    let room = max(0, composerScanNodeLimit - visited.count - queue.count)
                    guard children.count <= room else { incompleteReason = "node_limit"; return nil }
                    queue.append(contentsOf: children)
                }
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else {
                incompleteReason = Task.isCancelled ? "cancelled"
                    : (ContinuousClock.now >= deadline ? "deadline" : "node_limit")
                return nil
            }
            return groups
        }
        func selectedOuterWebArea() -> AXUIElement? {
            do { try revalidateAccountPage() } catch { return nil }
            var queue = [window.accessibilityElement]
            var visited: [AXUIElement] = []
            var areas: [AXUIElement] = []
            let deadline = boundedDeadline(after: .seconds(3))
            let limit = 512
            while !queue.isEmpty, visited.count < limit, ContinuousClock.now < deadline, !Task.isCancelled {
                let element = queue.removeFirst()
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                if pruneDiscoverySubtree(element, role: role) { continue }
                if role == "AXWebArea" {
                    areas.append(element)
                    continue
                }
                if role == "AXTable" || role == "AXOutline" || role == "AXList" { continue }
                var childrenValue: CFTypeRef?
                let childrenStatus = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                    &childrenValue)
                let children = childrenStatus == .success ? childrenValue as? [AXUIElement] : nil
                let containerRoles: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXTabGroup", "AXTab",
                    "AXSplitGroup", "AXUnknown"]
                if children == nil, containerRoles.contains(role) { return nil }
                let room = max(0, limit - visited.count - queue.count)
                let next = children ?? []
                guard next.count <= room else { return nil }
                queue.append(contentsOf: next)
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled,
                  !areas.isEmpty, areas.count <= 8 else { return nil }
            if areas.count == 1 { return areas[0] }

            let windowBounds = revalidatedWindowBounds
            guard windowBounds.origin.x.isFinite, windowBounds.origin.y.isFinite,
                  windowBounds.width.isFinite, windowBounds.height.isFinite,
                  windowBounds.width > 0, windowBounds.height > 0 else { return nil }
            let candidateFrames = areas.compactMap(axBounds)
            guard candidateFrames.count == areas.count,
                  let firstFrame = candidateFrames.first,
                  candidateFrames.allSatisfy({ frame in
                      frame.origin.x.isFinite && frame.origin.y.isFinite
                          && frame.width.isFinite && frame.height.isFinite
                          && frame.width > 0 && frame.height > 0
                          && windowBounds.contains(frame)
                          && abs(frame.minX - firstFrame.minX) <= 2
                          && abs(frame.minY - firstFrame.minY) <= 2
                          && abs(frame.width - firstFrame.width) <= 2
                          && abs(frame.height - firstFrame.height) <= 2
                  }) else { return nil }
            let points = [
                CGPoint(x: windowBounds.midX, y: windowBounds.midY),
                CGPoint(x: windowBounds.midX, y: windowBounds.minY + windowBounds.height * 0.33),
                CGPoint(x: windowBounds.midX, y: windowBounds.minY + windowBounds.height * 0.67),
            ]
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.2)
            var hits: [AXUIElement] = []
            for point in points {
                guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
                      var current = hit else { return nil }
                var chain: [AXUIElement] = []
                var area: AXUIElement?
                var reachedWindow = false
                for _ in 0..<16 {
                    guard !chain.contains(where: { CFEqual($0, current) }) else { return nil }
                    chain.append(current)
                    let role = value(kAXRoleAttribute as String, current) as? String ?? ""
                    guard role.hasPrefix("AX"), role != "AXUnknown",
                          !pruneDiscoverySubtree(current, role: role) else { return nil }
                    if role == "AXWebArea" {
                        guard area == nil, areas.contains(where: { CFEqual($0, current) }) else { return nil }
                        area = current
                    }
                    if role == "AXWindow" {
                        guard CFEqual(current, window.accessibilityElement) else { return nil }
                        reachedWindow = true
                        break
                    }
                    var parentValue: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString,
                            &parentValue) == .success,
                          let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
                    current = unsafeBitCast(parentValue, to: AXUIElement.self)
                }
                guard reachedWindow, let area else { return nil }
                hits.append(area)
            }
            guard hits.count == 3, hits.allSatisfy({ CFEqual($0, hits[0]) }),
                  areas.filter({ CFEqual($0, hits[0]) }).count == 1 else { return nil }
            do { try revalidateAccountPage() } catch { return nil }
            return hits[0]
        }
        var embeddedScanVisited = 0
        var embeddedScanFailure = ""
        guard let outerWebArea = selectedOuterWebArea() else {
            evidence["capture_status"] = "outer-page-selection-unverified"
            return
        }
        guard let composers = discoverComposers(outerWebArea, visitedCount: &embeddedScanVisited,
                incompleteReason: &embeddedScanFailure) else {
            evidence["capture_status"] = "compose-discovery-incomplete"
            evidence["compose_scan_pass"] = "embedded"
            evidence["compose_scan_visited"] = embeddedScanVisited
            evidence["compose_scan_failure"] = embeddedScanFailure
            return
        }
        var standalone = false
        var standaloneCandidates: [Node] = []
        if composers.isEmpty {
            var standaloneScanVisited = 0
            var standaloneScanFailure = ""
            guard let found = discoverStandaloneSubjectGroups(outerWebArea,
                    visitedCount: &standaloneScanVisited, incompleteReason: &standaloneScanFailure) else {
                evidence["capture_status"] = "compose-discovery-incomplete"
                evidence["compose_scan_pass"] = "standalone"
                evidence["compose_scan_visited"] = standaloneScanVisited
                evidence["compose_scan_failure"] = standaloneScanFailure
                return
            }
            standaloneCandidates = found
            if !found.isEmpty {
                let title = value(kAXTitleAttribute as String, window.accessibilityElement) as? String ?? ""
                let description = value(kAXDescriptionAttribute as String, outerWebArea) as? String ?? ""
                let expectedAccount = ComputerUseGmailAccountPreferences().preferredEmail ?? ""
                let facts = found.count == 1 ? ((readTree(found[0].element, limit: 256) ?? []).map {
                    GmailAXFact($0.role, $0.title, $0.description, value: $0.text)
                }) : []
                standalone = Self.gmailStandaloneComposerIdentityMatches(windowTitle: title,
                    webAreaDescription: description, url: page.url, expectedAccount: expectedAccount,
                    subject: subject, composeRegions: facts.isEmpty ? [] : [facts])
                guard standalone else {
                    evidence["compose_count"] = found.count
                    evidence["capture_status"] = "standalone-compose-identity-unverified"
                    return
                }
            }
        }
        evidence["compose_count"] = composers.count + (standalone ? 1 : 0)
        evidence["compose_layout"] = standalone ? "standalone" : (composers.isEmpty ? "none" : "embedded")
        evidence["compose_identity_verified"] = standalone || composers.count == 1
        var nodes: [Node] = []
        if composers.count == 1, let composer = composers.first,
           let composeNodes = readTree(composer.element, limit: 256) {
            nodes = composeNodes
        } else if standalone, let candidate = standaloneCandidates.first,
                  let composeNodes = readTree(candidate.element, limit: 256) {
            nodes = composeNodes
        } else if !(verifySavedDraft && composers.isEmpty && standaloneCandidates.isEmpty) {
            evidence["capture_status"] = "compose-window-not-unique-or-readable"
            return
        }
        if existingDraftRecipientProbeEnabled {
            let urlVerified = !standalone && composers.count == 1
                && Self.gmailIsOwnedOpaqueDraftComposeURL(page.url, expectedAccountIndex: accountIndex)
            evidence["existing_draft_recipient_probe_url_verified"] = urlVerified
            guard urlVerified else {
                evidence["capture_status"] = "recipient-probe-requires-existing-opaque-compose"
                return
            }
        }
        let recipientContainers = nodes.filter {
            ($0.role == "AXGroup" || $0.role == "AXTextField") && ($0.title == "To" || $0.description == "To")
        }
        let recipientContainer = recipientContainers.count == 1 ? recipientContainers.first : nil
        let recipientNodes = recipientContainer.flatMap { readTree($0.element, limit: 64) } ?? []
        var recipientMatches = recipientNodes.contains {
            $0.role == "AXStaticText" && [$0.title, $0.description, $0.text].contains(recipient)
        }
        var recipientProofDiagnostic: [String: Any]?
        if !recipientMatches, !composers.isEmpty, !draftRowProbeEnabled {
            var failurePhase = "compose_unavailable"
            var candidateCountsByDepth: [Int] = []
            var chipCandidateAncestorDiagnostics: [[String: Any]] = []
            var reacquisitionCandidateCounts: [Int] = []
            var reacquisitionScopeAvailable: Bool?
            var reacquisitionScanComplete: Bool?
            var reacquisitionCandidateRoleMatches: Bool?
            var reacquisitionCandidateVisible: Bool?
            var reacquisitionCandidateUnprotected: Bool?
            var reacquisitionCandidateSupportsMenu: Bool?
            var preexistingMenuCount = 0
            var openedMenuCount = 0
            var exactCopyItemCount = 0
            var cancelSucceeded = false
            var escapeDispatched = false
            var menuClosed = false
            var contextClickAttempted = false
            var contextClickDownSent = false
            var contextClickReleaseSent = false
            var menuScanVisited = 0
            func supportsShowMenu(_ element: AXUIElement) -> Bool {
                AXUIElementSetMessagingTimeout(element, 0.1)
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      let actions = actions as? [String] else { return false }
                return actions.contains("AXShowMenu")
            }
            func supportsCancel(_ element: AXUIElement) -> Bool {
                AXUIElementSetMessagingTimeout(element, 0.1)
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      let actions = actions as? [String] else { return false }
                return actions.contains("AXCancel")
            }

            func parent(of element: AXUIElement) -> AXUIElement? {
                AXUIElementSetMessagingTimeout(element, 0.1)
                var parentValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                      let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
                return unsafeBitCast(parentValue, to: AXUIElement.self)
            }
            func freshComposeAndSubject() -> (Node, [Node], Node)? {
                var scanVisited = 0
                var scanFailure = ""
                guard let freshOuterWebArea = selectedOuterWebArea(), CFEqual(freshOuterWebArea, outerWebArea),
                      let freshComposers = discoverComposers(freshOuterWebArea,
                        visitedCount: &scanVisited, incompleteReason: &scanFailure),
                      freshComposers.count == 1, composers.count == 1,
                      CFEqual(freshComposers[0].element, composers[0].element),
                      let freshNodes = readTree(freshComposers[0].element, limit: 256) else { return nil }
                let subjectFields = freshNodes.filter { $0.role == "AXTextField" && $0.title == "Subject" }
                guard subjectFields.count == 1 else { return nil }
                let fields = freshNodes.map { GmailAXFact($0.role, $0.title, $0.description, value: $0.text) }
                let proof = Self.gmailTextFieldProof(fields, subject: subject, body: body)
                guard proof.subjectMatches, proof.bodyMatches else { return nil }
                return (freshComposers[0], freshNodes, subjectFields[0])
            }

            func locateRecipientChip(compose: Node, nodes: [Node], subjectField: Node)
                -> (candidate: Node?, counts: [Int], complete: Bool, scopeAvailable: Bool, diagnostics: [[String: Any]]) {
                let explicitToContainers = nodes.filter {
                    ($0.role == "AXGroup" || $0.role == "AXTextField") && ($0.title == "To" || $0.description == "To")
                }
                var scopes: [AXUIElement] = []
                if explicitToContainers.count == 1 {
                    scopes = [explicitToContainers[0].element]
                } else if explicitToContainers.isEmpty {
                    var cursor = subjectField.element
                    for _ in 0..<6 {
                        guard let next = parent(of: cursor) else { break }
                        if CFEqual(next, compose.element) { break }
                        scopes.append(next)
                        cursor = next
                    }
                }
                guard !scopes.isEmpty else { return (nil, [], true, false, []) }
                var candidatesByDepth = Array(repeating: [Node](), count: scopes.count)
                var diagnostics: [[String: Any]] = []
                let excludedRoles: Set<String> = ["AXTextArea", "AXMenu", "AXMenuItem", "AXWebArea",
                    "AXSecureTextField", "AXHeading", "AXButton", "AXLink"]
                let diagnosticRoles: Set<String> = ["AXApplication", "AXWindow", "AXWebArea", "AXGroup",
                    "AXTextField", "AXTextArea", "AXTextEntryArea", "AXStaticText", "AXHeading",
                    "AXButton", "AXLink", "AXMenu", "AXMenuItem", "AXToolbar", "AXSheet", "AXDialog",
                    "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXCell", "AXRow"]
                let deadline = boundedDeadline(after: .seconds(3))
                var actionChecks = 0
                var complete = true
                for node in nodes where node.role == "AXStaticText" {
                    if actionChecks >= 32 || ContinuousClock.now >= deadline {
                        complete = false
                        break
                    }
                    actionChecks += 1
                    guard !pruneDiscoverySubtree(node.element, role: node.role), supportsShowMenu(node.element) else {
                        continue
                    }
                    var descendant = node.element
                    var ancestorRoles: [String] = []
                    var firstBlockedRole: String?
                    for _ in 0..<8 {
                        guard let nodeParent = parent(of: descendant) else { break }
                        let role = value(kAXRoleAttribute as String, nodeParent) as? String ?? ""
                        ancestorRoles.append(diagnosticRoles.contains(role) ? role : "other")
                        if firstBlockedRole == nil && (excludedRoles.contains(role)
                            || pruneDiscoverySubtree(nodeParent, role: role)) {
                            firstBlockedRole = diagnosticRoles.contains(role) ? role : "hidden_or_protected"
                        }
                        if excludedRoles.contains(role) || pruneDiscoverySubtree(nodeParent, role: role) { break }
                        if CFEqual(nodeParent, compose.element) { break }
                        if let depth = scopes.firstIndex(where: { CFEqual($0, nodeParent) }) {
                            if !candidatesByDepth[depth].contains(where: { CFEqual($0.element, node.element) }) {
                                candidatesByDepth[depth].append(node)
                            }
                            break
                        }
                        descendant = nodeParent
                    }
                    diagnostics.append(["ancestor_roles": ancestorRoles,
                        "first_blocked_role": firstBlockedRole ?? "none"])
                }
                let counts = candidatesByDepth.map(\.count)
                let firstMatchDepth = candidatesByDepth.firstIndex(where: { !$0.isEmpty })
                let candidate = firstMatchDepth.flatMap { candidatesByDepth[$0].count == 1 ? candidatesByDepth[$0][0] : nil }
                return (complete ? candidate : nil, counts, complete, true, diagnostics)
            }

            var candidate: Node?
            var pageMenuRoot: AXUIElement?
            do {
                try revalidateAccountPage()
                guard let (compose, freshNodes, subjectField) = freshComposeAndSubject() else {
                    failurePhase = "unique_compose_or_subject_unavailable"
                    throw HarnessError.missingEvidence("Unique compose or Subject field unavailable")
                }
                let locatedChip = locateRecipientChip(compose: compose, nodes: freshNodes, subjectField: subjectField)
                candidateCountsByDepth = locatedChip.counts
                chipCandidateAncestorDiagnostics = locatedChip.diagnostics
                guard locatedChip.scopeAvailable else {
                    failurePhase = "recipient_scope_unavailable"
                    throw HarnessError.missingEvidence("Unique recipient or Subject scope unavailable")
                }
                guard locatedChip.complete else {
                    failurePhase = "chip_candidate_scan_incomplete"
                    throw HarnessError.missingEvidence("Collapsed recipient chip scan incomplete")
                }
                guard let locatedCandidate = locatedChip.candidate else {
                    failurePhase = locatedChip.counts.contains(where: { $0 > 1 })
                        ? "subject_ancestor_chip_ambiguous" : "subject_ancestor_chip_missing"
                    throw HarnessError.missingEvidence("Collapsed recipient chip is not unique")
                }
                candidate = locatedCandidate
                var rootCursor = compose.element
                for _ in 0..<8 {
                    if value(kAXRoleAttribute as String, rootCursor) as? String == "AXWebArea" {
                        pageMenuRoot = rootCursor
                        break
                    }
                    guard let next = parent(of: rootCursor) else { break }
                    rootCursor = next
                }
                guard pageMenuRoot != nil else {
                    failurePhase = "compose_page_scope_unavailable"
                    throw HarnessError.missingEvidence("Compose page scope unavailable")
                }
            } catch {
                if failurePhase == "compose_unavailable" { failurePhase = "page_revalidation_failed" }
            }

            func scanMenus() -> (complete: Bool, menus: [AXUIElement], exactCopyCount: Int, visited: Int) {
                guard let pageMenuRoot else { return (false, [], 0, 0) }
                var queue = [pageMenuRoot]
                var seen: [AXUIElement] = []
                var menus: [AXUIElement] = []
                var copyCount = 0
                let deadline = boundedDeadline(after: .seconds(3))
                let nodeLimit = 512
                let containerRoles: Set<String> = ["AXWebArea", "AXGroup", "AXScrollArea", "AXMenu", "AXMenuBar"]
                let skipRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXCell", "AXRow", "AXTextArea",
                    "AXButton", "AXLink", "AXHeading"]
                while !queue.isEmpty, seen.count < nodeLimit, ContinuousClock.now < deadline, !Task.isCancelled {
                    let element = queue.removeFirst()
                    guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                    seen.append(element)
                    let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                    if pruneDiscoverySubtree(element, role: role) || role == "AXDialog" { continue }
                    if role == "AXWebArea" && !CFEqual(element, pageMenuRoot) { continue }
                    if role == "AXMenu" { menus.append(element) }
                    if role == "AXMenuItem" {
                        let copyLabel = "Copy \"\(recipient)\""
                        let labels = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                            kAXValueAttribute as String].compactMap { value($0, element) as? String }
                        if labels.contains(where: { $0 == copyLabel || $0 == "\(copyLabel) Option+C" }) {
                            copyCount += 1
                        }
                    }
                    if skipRoles.contains(role) { continue }
                    AXUIElementSetMessagingTimeout(element, 0.1)
                    var childrenValue: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
                    let children = status == .success ? childrenValue as? [AXUIElement] : nil
                    if children == nil, containerRoles.contains(role) { return (false, menus, copyCount, seen.count) }
                    let next = children ?? []
                    let remaining = max(0, nodeLimit - seen.count - queue.count)
                    guard next.count <= remaining else { return (false, menus, copyCount, seen.count) }
                    queue.append(contentsOf: next)
                }
                let complete = queue.isEmpty && ContinuousClock.now < deadline && !Task.isCancelled
                return (complete, menus, copyCount, seen.count)
            }

            if candidate != nil, let pageMenuRoot {
                do {
                    try revalidateAccountPage()
                    let beforeMenu = scanMenus()
                    menuScanVisited += beforeMenu.visited
                    preexistingMenuCount = beforeMenu.menus.count
                    guard beforeMenu.complete, beforeMenu.menus.isEmpty else {
                        failurePhase = beforeMenu.complete ? "preexisting_page_menu" : "page_menu_scan_incomplete"
                        throw HarnessError.missingEvidence("Page menu state is not clear")
                    }
                    try revalidateAccountPage()
                    guard readinessDeadline.map({ ContinuousClock.now < $0 }) ?? true else {
                        failurePhase = "recipient_readiness_deadline"
                        throw HarnessError.missingEvidence("Recipient readiness deadline expired before menu action")
                    }
                    guard let (freshCompose, freshNodes, freshSubject) = freshComposeAndSubject() else {
                        failurePhase = "chip_reacquisition_compose_unavailable"
                        throw HarnessError.missingEvidence("Compose fields changed before recipient click")
                    }
                    let freshChip = locateRecipientChip(compose: freshCompose, nodes: freshNodes,
                        subjectField: freshSubject)
                    reacquisitionCandidateCounts = freshChip.counts
                    reacquisitionScopeAvailable = freshChip.scopeAvailable
                    reacquisitionScanComplete = freshChip.complete
                    guard freshChip.complete, freshChip.scopeAvailable, let selectedCandidate = freshChip.candidate else {
                        failurePhase = !freshChip.complete ? "chip_reacquisition_scan_incomplete"
                            : (!freshChip.scopeAvailable ? "chip_reacquisition_scope_unavailable"
                            : (freshChip.counts.contains(where: { $0 > 1 })
                                ? "chip_reacquisition_ambiguous" : "chip_reacquisition_chip_missing"))
                        throw HarnessError.missingEvidence("Unique recipient chip changed before context click")
                    }
                    let roleMatches = value(kAXRoleAttribute as String, selectedCandidate.element) as? String == "AXStaticText"
                    let isVisible = value(kAXHiddenAttribute as String, selectedCandidate.element) as? Bool != true
                    let isUnprotected = value("AXProtectedContent", selectedCandidate.element) as? Bool != true
                    let canShowMenu = supportsShowMenu(selectedCandidate.element)
                    reacquisitionCandidateRoleMatches = roleMatches
                    reacquisitionCandidateVisible = isVisible
                    reacquisitionCandidateUnprotected = isUnprotected
                    reacquisitionCandidateSupportsMenu = canShowMenu
                    guard roleMatches, isVisible, isUnprotected, canShowMenu,
                          let chipBounds = axBounds(selectedCandidate.element),
                          let clickPoint = Self.gmailContextClickPoint(chipBounds: chipBounds,
                            windowBounds: revalidatedWindowBounds) else {
                        failurePhase = "chip_reacquisition_metadata_or_bounds_invalid"
                        throw HarnessError.missingEvidence("Unique recipient chip bounds are not safe for context click")
                    }
                    candidate = selectedCandidate
                    func contextClickStillVerified() -> Bool {
                        guard !Task.isCancelled,
                              readinessDeadline.map({ ContinuousClock.now < $0 }) ?? true else { return false }
                        do {
                            try revalidateAccountPage()
                            guard let (currentCompose, currentNodes, currentSubject) = freshComposeAndSubject() else {
                                return false
                            }
                            let currentChip = locateRecipientChip(compose: currentCompose, nodes: currentNodes,
                                subjectField: currentSubject)
                            guard currentChip.complete, currentChip.scopeAvailable,
                                  let currentCandidate = currentChip.candidate,
                                  CFEqual(currentCandidate.element, selectedCandidate.element),
                                  value(kAXRoleAttribute as String, currentCandidate.element) as? String == "AXStaticText",
                                  value(kAXHiddenAttribute as String, currentCandidate.element) as? Bool != true,
                                  value("AXProtectedContent", currentCandidate.element) as? Bool != true,
                                  supportsShowMenu(currentCandidate.element),
                                  let currentBounds = axBounds(currentCandidate.element),
                                  Self.gmailContextClickPoint(chipBounds: currentBounds,
                                    windowBounds: revalidatedWindowBounds) == clickPoint else { return false }
                            return true
                        } catch { return false }
                    }
                    recipientMenuEffectAttempted = true
                    contextClickAttempted = true
                    let injector = InputInjector()
                    let clickX = Int(clickPoint.x.rounded())
                    let clickY = Int(clickPoint.y.rounded())
                    contextClickDownSent = injector.apply(.pointer(x: clickX, y: clickY, buttons: 0b010),
                        ifAllowed: contextClickStillVerified)
                    guard contextClickDownSent else {
                        failurePhase = "chip_context_click_denied"
                        throw HarnessError.missingEvidence("Recipient context click was not authorized by fresh bounds")
                    }
                    // A successful context click may replace the chip node with the open menu.
                    // Bind release to the retained account/window/page only; the exact chip guard
                    // is required immediately before down, while menu proof verifies the effect.
                    contextClickReleaseSent = injector.apply(.pointer(x: clickX, y: clickY, buttons: 0),
                        ifAllowed: {
                            guard !Task.isCancelled else { return false }
                            do { try revalidateAccountPage(); return true }
                            catch { return false }
                        })
                    guard contextClickReleaseSent else {
                        failurePhase = "chip_context_click_release_denied"
                        throw HarnessError.missingEvidence("Recipient context click release was not authorized")
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                    try revalidateAccountPage()
                    let openedMenu = scanMenus()
                    menuScanVisited += openedMenu.visited
                    openedMenuCount = openedMenu.menus.count
                    exactCopyItemCount = openedMenu.exactCopyCount
                    if openedMenu.menus.count == 1, supportsCancel(openedMenu.menus[0]) {
                        try revalidateAccountPage()
                        cancelSucceeded = AXUIElementPerformAction(openedMenu.menus[0], "AXCancel" as CFString) == .success
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                    try revalidateAccountPage()
                    let closedMenu = scanMenus()
                    menuScanVisited += closedMenu.visited
                    menuClosed = closedMenu.complete && closedMenu.menus.isEmpty
                    recipientMatches = beforeMenu.complete && openedMenu.complete && openedMenu.menus.count == 1
                        && openedMenu.exactCopyCount == 1 && cancelSucceeded && menuClosed
                    if !recipientMatches {
                        failurePhase = !openedMenu.complete ? "opened_menu_scan_incomplete"
                            : (openedMenu.menus.count != 1 ? "opened_menu_not_unique"
                            : (openedMenu.exactCopyCount != 1 ? "copy_address_item_not_unique"
                            : (!cancelSucceeded ? "menu_cancel_failed" : "menu_close_unverified")))
                    }
                    if !menuClosed, cancelSucceeded, closedMenu.complete, closedMenu.menus.count == 1,
                       closedMenu.exactCopyCount == 1, let confirmedMenu = closedMenu.menus.first,
                       let openedMenuElement = openedMenu.menus.first,
                       CFEqual(confirmedMenu, openedMenuElement) {
                        try revalidateAccountPage()
                        let injector = InputInjector()
                        let keyDown = injector.apply(.key(usage: 0x29, down: true, modifiers: 0),
                            ifAllowed: {
                                do { try revalidateAccountPage(); return true }
                                catch { return false }
                            })
                        let keyUp = injector.apply(.key(usage: 0x29, down: false, modifiers: 0),
                            ifAllowed: {
                                do { try revalidateAccountPage(); return true }
                                catch { return false }
                            })
                        escapeDispatched = keyDown && keyUp
                        try? await Task.sleep(for: .milliseconds(120))
                        try revalidateAccountPage()
                        let escapedMenu = scanMenus()
                        menuScanVisited += escapedMenu.visited
                        menuClosed = escapedMenu.complete && escapedMenu.menus.isEmpty
                        recipientMatches = beforeMenu.complete && openedMenu.complete
                            && openedMenu.menus.count == 1 && openedMenu.exactCopyCount == 1
                            && cancelSucceeded && escapeDispatched && menuClosed
                    }
                } catch {
                    if failurePhase == "compose_unavailable" { failurePhase = "page_revalidation_failed" }
                }
            }
            if !recipientMatches {
                recipientProofDiagnostic = [
                    "phase": failurePhase,
                    "subject_ancestor_candidate_counts": candidateCountsByDepth,
                    "recipient_reacquisition_candidate_counts": reacquisitionCandidateCounts,
                    "recipient_reacquisition_scope_available": reacquisitionScopeAvailable as Any? ?? NSNull(),
                    "recipient_reacquisition_scan_complete": reacquisitionScanComplete as Any? ?? NSNull(),
                    "recipient_reacquisition_role_matches": reacquisitionCandidateRoleMatches as Any? ?? NSNull(),
                    "recipient_reacquisition_visible": reacquisitionCandidateVisible as Any? ?? NSNull(),
                    "recipient_reacquisition_unprotected": reacquisitionCandidateUnprotected as Any? ?? NSNull(),
                    "recipient_reacquisition_supports_menu": reacquisitionCandidateSupportsMenu as Any? ?? NSNull(),
                    "recipient_container_count": recipientContainers.count,
                    "recipient_container_roles": recipientContainers.map(\.role),
                    "chip_candidate_ancestor_diagnostics": chipCandidateAncestorDiagnostics,
                    "preexisting_menu_count": preexistingMenuCount,
                    "opened_menu_count": openedMenuCount,
                    "context_click_attempted": contextClickAttempted,
                    "context_click_down_sent": contextClickDownSent,
                    "context_click_release_sent": contextClickReleaseSent,
                    "exact_copy_address_item_count": exactCopyItemCount,
                    "cancel_succeeded": cancelSucceeded,
                    "escape_dispatched": escapeDispatched,
                    "menu_closed_verified": menuClosed,
                    "menu_scan_nodes_visited": menuScanVisited,
                ]
            }
        }
        let axFacts = nodes.map { GmailAXFact($0.role, $0.title, $0.description, value: $0.text) }
        let fieldProof = Self.gmailTextFieldProof(axFacts, subject: subject, body: body)
        let subjectMatches = fieldProof.subjectMatches
        let bodyMatches = fieldProof.bodyMatches
        let ccValues = nodes.filter {
            ($0.role == "AXTextField" || $0.role == "AXTextArea" || $0.role == "AXTextEntryArea")
                && ["Cc", "CC"].contains($0.title)
        }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bccValues = nodes.filter {
            ($0.role == "AXTextField" || $0.role == "AXTextArea" || $0.role == "AXTextEntryArea")
                && ["Bcc", "BCC"].contains($0.title)
        }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let ccMatches = ccValues.allSatisfy(\.isEmpty)
        let bccMatches = bccValues.allSatisfy(\.isEmpty)
        let attachmentGroups = nodes.filter {
            $0.role == "AXGroup" && ($0.title + " " + $0.description + " " + $0.text)
                .range(of: #"(?:^|\s)Attachment: "#, options: [.regularExpression]) != nil
        }
        let expectedGroup = attachmentGroups.first {
            Self.gmailAttachmentGroupNamesMatch(groupText: $0.title + " " + $0.description + " " + $0.text,
                expectedName: name)
        }
        let attachmentGroup = attachmentGroups.count == 1 ? expectedGroup : nil
        let attachmentNodes = attachmentGroup.flatMap { readTree($0.element, limit: 64) } ?? []
        func label(_ node: Node) -> String { [node.title, node.description, node.text].first { !$0.isEmpty } ?? "" }
        let attachmentLinks = attachmentNodes.filter { $0.role == "AXLink" }.map(label)
        let removalButtons = attachmentNodes.filter { $0.role == "AXButton" && label($0).localizedCaseInsensitiveContains("remove") }
            .map(label)
        let groupLabel = attachmentGroup.map { $0.title + " " + $0.description + " " + $0.text } ?? ""
        let attachmentFacts = Self.gmailAttachmentFactsMatch(groupText: groupLabel,
            linkLabels: attachmentLinks, removeButtonLabels: removalButtons,
            groupCount: attachmentGroups.count, expectedName: name, expectedBytes: expected.source_bytes ?? -1)
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        let sizeLabel = formatter.string(fromByteCount: Int64(expected.source_bytes ?? 0))
        evidence["recipient_matches"] = recipientMatches
        if let recipientProofDiagnostic { evidence["recipient_proof_diagnostic"] = recipientProofDiagnostic }
        evidence["subject_matches"] = subjectMatches
        evidence["body_matches"] = bodyMatches
        evidence["cc_matches"] = ccMatches
        evidence["bcc_matches"] = bccMatches
        evidence["attachment_name_visible"] = attachmentFacts.nameMatches
        evidence["attachment_count"] = attachmentGroups.count
        evidence["attachment_size_label"] = sizeLabel
        evidence["attachment_size_visible"] = attachmentFacts.sizeVisible
        evidence["attachment_bytes_verified"] = false
        evidence["saved_marker_observed"] = nodes.contains {
            ($0.title + $0.description + $0.text).localizedCaseInsensitiveContains("Draft saved")
        }
        evidence["capture_status"] = standalone ? "standalone-compose-captured"
            : (composers.isEmpty ? "compose-already-closed" : "captured")
        guard verifySavedDraft else { return }
        func press(_ element: AXUIElement) -> Bool {
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            value(kAXChildrenAttribute as String, element) as? [AXUIElement] ?? []
        }
        var draftRowProbe: [String: Any]?
        func findOwnedDraftSubject(_ root: AXUIElement, subject: String) -> [Node]? {
            struct PendingNode {
                let element: AXUIElement
                let cellIndex: Int?
            }
            struct DraftCell {
                let element: AXUIElement
                let title: String
                let description: String
                var primaryText: String
            }
            var queue = [PendingNode(element: root, cellIndex: nil)]
            var visited: [AXUIElement] = []
            var cells: [DraftCell] = []
            var cellCount = 0
            func saveProbe(complete: Bool, failure: String?) {
                guard draftRowProbeEnabled else { return }
                var summary: [String: Any] = [
                    "visited": visited.count,
                    "cell_count": cellCount,
                    "resolved_primary_subject_cell_count": cells.filter { $0.primaryText == subject }.count,
                    "scan_complete": complete,
                ]
                if let failure { summary["scan_failure"] = failure }
                draftRowProbe = summary
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !queue.isEmpty, visited.count < 1_800, ContinuousClock.now < deadline, !Task.isCancelled {
                let pending = queue.removeLast()
                let element = pending.element
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                if pruneDiscoverySubtree(element, role: role) || role == "AXDialog" { continue }
                if role == "AXWebArea" && !CFEqual(element, root) { continue }
                let title = value(kAXTitleAttribute as String, element) as? String ?? ""
                let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
                let rawValue = (role == "AXCell" || (role == "AXStaticText" && pending.cellIndex != nil))
                    ? value(kAXValueAttribute as String, element) : nil
                let text = rawValue as? String ?? (rawValue as? NSAttributedString)?.string ?? ""
                var cellIndex = pending.cellIndex
                if role == "AXCell" {
                    cells.append(DraftCell(element: element, title: title, description: description,
                        primaryText: text))
                    cellIndex = cells.count - 1
                } else if role == "AXStaticText", let index = cellIndex,
                          cells.indices.contains(index), cells[index].primaryText.isEmpty,
                          !text.isEmpty {
                    cells[index].primaryText = text
                }
                if role == "AXCell" {
                    cellCount += 1
                }
                AXUIElementSetMessagingTimeout(element, 0.1)
                var childrenResult: CFTypeRef?
                let childrenStatus = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                    &childrenResult)
                let childElements = childrenStatus == .success ? childrenResult as? [AXUIElement] : nil
                let containerRoles: Set<String> = ["AXWindow", "AXWebArea", "AXTable", "AXOutline", "AXRow",
                    "AXList", "AXGroup", "AXScrollArea", "AXCell"]
                if childElements == nil, containerRoles.contains(role) {
                    saveProbe(complete: false, failure: "container_children_unavailable")
                    return nil
                }
                let next = childElements ?? []
                let room = max(0, 1_800 - visited.count - queue.count)
                guard next.count <= room else {
                    saveProbe(complete: false, failure: "node_limit")
                    return nil
                }
                queue.append(contentsOf: next.reversed().map { PendingNode(element: $0, cellIndex: cellIndex) })
            }
            guard queue.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled else {
                saveProbe(complete: false, failure: Task.isCancelled ? "cancelled"
                    : (ContinuousClock.now >= deadline ? "deadline" : "node_limit"))
                return nil
            }
            saveProbe(complete: true, failure: nil)

            let matches = cells.filter { $0.primaryText == subject }.map {
                Node(element: $0.element, role: "AXCell", title: $0.title,
                    description: $0.description, text: $0.primaryText)
            }
            let exactCellIndex = Self.gmailUniqueDraftSubjectRowIndex(
                cellValuesByRow: matches.map { [$0.text] }, scanComplete: true, subject: subject)
            guard let exactCellIndex, matches.indices.contains(exactCellIndex) else { return [] }
            let exactCell = matches[exactCellIndex]
            // Resolve the exact subject cell to its actionable ancestor row.
            var rows: [Node] = []
            for match in [exactCell] {
                var current: AXUIElement? = match.element
                var row: AXUIElement?
                for _ in 0..<8 {
                    guard let element = current else { break }
                    let currentRole = value(kAXRoleAttribute as String, element) as? String ?? ""
                    if currentRole == "AXRow" { row = element; break }
                    var parent: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                          let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    current = (parent as! AXUIElement)
                }
                let actionable = row ?? match.element
                guard !rows.contains(where: { CFEqual($0.element, actionable) }) else { continue }
                let role = value(kAXRoleAttribute as String, actionable) as? String ?? match.role
                let title = value(kAXTitleAttribute as String, actionable) as? String ?? match.title
                let description = value(kAXDescriptionAttribute as String, actionable) as? String ?? match.description
                let text = value(kAXValueAttribute as String, actionable) as? String ?? match.text
                rows.append(Node(element: actionable, role: role, title: title,
                    description: description, text: text))
            }
            return rows
        }
        if draftRowProbeEnabled && (!composers.isEmpty || standalone) {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "probe-composer-open-no-action"
            return
        }
        if composers.count == 1 {
            guard let saveClose = nodes.first(where: {
                $0.role == "AXButton" && [$0.title, $0.description].contains("Save & close")
            }), press(saveClose.element) else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = "save-close-control-unavailable"
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
        }

        func verifiedCurrentGmailURL() -> String? {
            guard let currentURL = try? reader.readRetainedPageURL(window: window.accessibilityElement,
                    application: application, mayAct: { !Task.isCancelled }),
                  ComputerUseGmailAccountDirectory.accountIndex(from: currentURL) == accountIndex else { return nil }
            let revalidate: @MainActor () throws -> Void = {
                guard !Task.isCancelled,
                      let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
                      snapshot.application == application,
                      snapshot.windows.filter({ $0.id == window.id }).count == 1,
                      let currentWindow = snapshot.windows.first(where: { $0.id == window.id }),
                      CFEqual(currentWindow.accessibilityElement, window.accessibilityElement),
                      let rereadURL = try? reader.readRetainedPageURL(window: currentWindow.accessibilityElement,
                        application: application, mayAct: { !Task.isCancelled }),
                      rereadURL == currentURL else {
                    throw HarnessError.missingEvidence("The retained Gmail page changed during the Drafts oracle")
                }
            }
            guard let currentLabel = try? ComputerUseGmailRecipientVerifier.accountControlLabel(
                    window: window.accessibilityElement, application: application, revalidate: revalidate),
                  let title = try? ComputerUseGmailAccountDirectory.observedWindowTitle(
                    window: window.accessibilityElement, application: application, revalidate: revalidate),
                  ComputerUseGmailAccountDirectory.confirmsActiveAccount(currentURL: currentURL,
                    windowTitle: title, accountControlLabel: currentLabel, expected: account),
                  let finalURL = try? reader.readRetainedPageURL(window: window.accessibilityElement,
                    application: application, mayAct: { !Task.isCancelled }), finalURL == currentURL else { return nil }
            return currentURL
        }
        guard let currentURL = verifiedCurrentGmailURL() else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "drafts-page-account-unverified"
            return
        }
        retainedPageURL = currentURL
        let alreadyOnDrafts = Self.gmailIsOwnedDraftsListingURL(currentURL, expectedAccountIndex: accountIndex)
        if draftRowProbeEnabled && !alreadyOnDrafts {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "probe-current-page-is-not-owned-drafts-listing"
            return
        }
        if draftRowProbeEnabled {
            var productDiagnostic = "phase=not_reported reason=not_reported visited=0 max_depth=0 max_children=0 exact_matches=0"
            var productAmbiguous = false
            let productRevalidate: @MainActor () throws -> Void = {
                guard !Task.isCancelled, verifiedCurrentGmailURL() == currentURL else {
                    throw HarnessError.missingEvidence("The retained Gmail page changed during product row diagnostics")
                }
            }
            var productCellFound = false
            do {
                let result = try ComputerUseGmailRecipientVerifier.exactDraftSubjectCellEvidence(
                    window: window.accessibilityElement, application: application, subject: subject,
                    ambiguous: &productAmbiguous,
                    diagnostic: { productDiagnostic = $0 }, revalidate: productRevalidate)
                productCellFound = result != nil
            } catch {
                productCellFound = false
            }
            let diagnosticPattern = #"^phase=[a-z_]+ reason=[a-z_]+ visited=[0-9]+ max_depth=[0-9]+ max_children=[0-9]+ exact_matches=[0-9]+$"#
            evidence["product_draft_row_probe_diagnostic"] = productDiagnostic.range(
                of: diagnosticPattern, options: .regularExpression) != nil ? productDiagnostic : "phase=invalid"
            evidence["product_draft_row_probe_cell_found"] = productCellFound
            evidence["product_draft_row_probe_ambiguous"] = productAmbiguous
        }
        if !alreadyOnDrafts {
            // Search the complete bounded navigation tree for one exact Drafts link;
            // never use a truncated scan or an arbitrary text ancestor as a target.
            func isDraftsLinkLabel(_ label: String) -> Bool {
                label == "Drafts" || label.range(of: #"^Drafts [0-9]+ unread$"#,
                    options: [.regularExpression]) != nil
            }
            var chromeQueue = [window.accessibilityElement]
            var chromeSeen: [AXUIElement] = []
            var draftsLinks: [AXUIElement] = []
            var chromeFailure = ""
            let chromeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !chromeQueue.isEmpty, chromeSeen.count < 512, ContinuousClock.now < chromeDeadline,
                  !Task.isCancelled {
                let element = chromeQueue.removeFirst()
                guard !chromeSeen.contains(where: { CFEqual($0, element) }) else { continue }
                chromeSeen.append(element)
                let role = value(kAXRoleAttribute as String, element) as? String ?? ""
                if pruneDiscoverySubtree(element, role: role) { continue }
                if role == "AXLink" {
                    let title = value(kAXTitleAttribute as String, element) as? String ?? ""
                    let description = value(kAXDescriptionAttribute as String, element) as? String ?? ""
                    let text = value(kAXValueAttribute as String, element) as? String ?? ""
                    if [title, description, text].contains(where: isDraftsLinkLabel) {
                        draftsLinks.append(element)
                    }
                }
                if role == "AXTable" || role == "AXOutline" || role == "AXList" { continue }
                let next = children(element)
                let room = max(0, 512 - chromeSeen.count - chromeQueue.count)
                guard next.count <= room else { chromeFailure = "node_limit"; break }
                chromeQueue.append(contentsOf: next)
            }
            if chromeFailure.isEmpty && !chromeQueue.isEmpty {
                chromeFailure = Task.isCancelled ? "cancelled"
                    : (ContinuousClock.now >= chromeDeadline ? "deadline" : "node_limit")
            }
            guard chromeQueue.isEmpty, chromeFailure.isEmpty,
                  ContinuousClock.now < chromeDeadline, !Task.isCancelled else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = "drafts-navigation-scan-incomplete"
                evidence["drafts_navigation_scan_visited"] = chromeSeen.count
                evidence["drafts_navigation_scan_failure"] = chromeFailure.isEmpty
                    ? (Task.isCancelled ? "cancelled" : "deadline") : chromeFailure
                return
            }
            guard draftsLinks.count == 1, let draftsNavigation = draftsLinks.first else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = draftsLinks.isEmpty
                    ? "drafts-navigation-unavailable" : "drafts-navigation-ambiguous"
                return
            }
            guard verifiedCurrentGmailURL() == currentURL else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = "drafts-navigation-page-changed-before-press"
                return
            }
            guard value(kAXEnabledAttribute as String, draftsNavigation) as? Bool == true,
                  press(draftsNavigation) else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = "drafts-navigation-link-disabled"
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard let navigatedURL = verifiedCurrentGmailURL(),
                  Self.gmailIsOwnedDraftsListingURL(navigatedURL, expectedAccountIndex: accountIndex) else {
                evidence["draft_saved_verified"] = false
                evidence["saved_oracle_status"] = "drafts-navigation-unverified"
                return
            }
            retainedPageURL = navigatedURL
        }
        guard let draftsPageRoot = selectedOuterWebArea(), verifiedCurrentGmailURL() == retainedPageURL else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "drafts-outer-page-selection-unverified"
            return
        }
        let subjectNodes = findOwnedDraftSubject(draftsPageRoot, subject: subject)
        if let draftRowProbe { evidence["draft_row_capture_probe"] = draftRowProbe }
        guard let subjectNodes else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "drafts-list-incomplete"
            return
        }
        evidence["saved_draft_count"] = subjectNodes.count
        if draftRowProbeEnabled {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = subjectNodes.count == 1
                ? "probe-unique-exact-subject-row-found" : "probe-exact-subject-row-not-unique"
            return
        }
        guard subjectNodes.count == 1, let subjectNode = subjectNodes.first else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "owned-subject-not-unique-in-drafts"
            return
        }
        var draftRow: AXUIElement?
        var ancestor: AXUIElement? = subjectNode.element
        for _ in 0..<8 {
            guard let current = ancestor else { break }
            let role = value(kAXRoleAttribute as String, current) as? String ?? ""
            if role == "AXRow" || role == "AXLink" || role == "AXButton" {
                draftRow = current
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success else { break }
            guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            ancestor = (parent as! AXUIElement)
        }
        guard let draftRow,
              verifiedCurrentGmailURL() == retainedPageURL,
              value(kAXEnabledAttribute as String, draftRow) as? Bool == true,
              press(draftRow) else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "owned-draft-row-not-actionable"
            return
        }
        var reopened = false
        let reopenDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < reopenDeadline, !Task.isCancelled {
            guard let reopenedURL = verifiedCurrentGmailURL(),
                  Self.gmailIsOwnedOpaqueDraftComposeURL(reopenedURL, expectedAccountIndex: accountIndex) else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            retainedPageURL = reopenedURL
            guard let reopenedPageRoot = selectedOuterWebArea() else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            var reopenScanVisited = 0
            var reopenScanFailure = ""
            if let found = discoverComposers(reopenedPageRoot, visitedCount: &reopenScanVisited,
                    incompleteReason: &reopenScanFailure), found.count == 1 {
                reopened = true
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard reopened else {
            evidence["draft_saved_verified"] = false
            evidence["saved_oracle_status"] = "owned-draft-did-not-reopen"
            return
        }
        var savedFields: [String: Any] = [:]
        await Self.captureGmailDraft(expected: expected, evidence: &savedFields)
        let reopenedComposeURL = savedFields["compose_url"] as? String
        let retryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var readinessRetryCount = 0
        if Self.gmailSavedRecipientProofRetryEligible(savedFields),
           savedFields["account_identity_verified"] as? Bool == true,
           savedFields["compose_identity_verified"] as? Bool == true,
           savedFields["compose_count"] as? Int == 1,
           let reopenedComposeURL,
           Self.gmailIsOwnedOpaqueDraftComposeURL(reopenedComposeURL, expectedAccountIndex: accountIndex) {
            while readinessRetryCount < 2, ContinuousClock.now < retryDeadline,
                  !Task.isCancelled, Self.gmailSavedRecipientProofRetryEligible(savedFields) {
                try? await Task.sleep(for: .milliseconds(250))
                guard ContinuousClock.now < retryDeadline, !Task.isCancelled else { break }
                var retryFields: [String: Any] = [:]
                await Self.captureGmailDraft(expected: expected, evidence: &retryFields,
                    requiredComposeURL: reopenedComposeURL, requiredApplication: application,
                    requiredWindowID: window.id, readinessDeadline: retryDeadline)
                readinessRetryCount += 1
                let sameOwnedCompose = retryFields["compose_url"] as? String == reopenedComposeURL
                    && retryFields["account_identity_verified"] as? Bool == true
                    && retryFields["compose_identity_verified"] as? Bool == true
                    && retryFields["compose_count"] as? Int == 1
                    && retryFields["subject_matches"] as? Bool == true
                    && retryFields["body_matches"] as? Bool == true
                    && retryFields["url_is_gmail"] as? Bool == true
                guard sameOwnedCompose else {
                    savedFields["recipient_retry_status"] = "owned_compose_changed"
                    break
                }
                savedFields = retryFields
                if retryFields["recipient_matches"] as? Bool == true
                    || !Self.gmailSavedRecipientProofRetryEligible(retryFields) { break }
            }
        }
        evidence["saved_recipient_readiness_retry_count"] = readinessRetryCount
        evidence["saved_draft_url"] = savedFields["compose_url"] ?? NSNull()
        evidence["saved_to_matches"] = savedFields["recipient_matches"] ?? false
        if let diagnostic = savedFields["recipient_proof_diagnostic"] {
            evidence["saved_recipient_proof_diagnostic"] = diagnostic
        }
        evidence["saved_subject_matches"] = savedFields["subject_matches"] ?? false
        evidence["saved_body_matches"] = savedFields["body_matches"] ?? false
        evidence["saved_attachment_name_visible"] = savedFields["attachment_name_visible"] ?? false
        evidence["saved_attachment_size_visible"] = savedFields["attachment_size_visible"] ?? false
        evidence["saved_attachment_count"] = savedFields["attachment_count"] ?? 0
        evidence["draft_saved_verified"] = subjectNodes.count == 1
            && (savedFields["account_identity_verified"] as? Bool == true)
            && (savedFields["compose_identity_verified"] as? Bool == true)
            && (savedFields["compose_count"] as? Int == 1)
            && (savedFields["attachment_count"] as? Int == 1)
            && (savedFields["url_is_gmail"] as? Bool == true)
            && (savedFields["recipient_matches"] as? Bool == true)
            && (savedFields["subject_matches"] as? Bool == true)
            && (savedFields["body_matches"] as? Bool == true)
            && (savedFields["cc_matches"] as? Bool == true)
            && (savedFields["bcc_matches"] as? Bool == true)
            && (savedFields["attachment_name_visible"] as? Bool == true)
            && (savedFields["attachment_size_visible"] as? Bool == true)
        evidence["saved_oracle_status"] = evidence["draft_saved_verified"] as? Bool == true
            ? "reopened-from-drafts" : "reopened-draft-fields-mismatch"
    }

    private static func exportDraft(expected: Expected, trace: URL,
        evidence: inout [String: Any]) async throws {
        guard let subject = expected.subject else { throw HarnessError.missingEvidence("Missing expected draft subject") }
        let script = #"""
        const Mail = Application("/System/Applications/Mail.app");
        function run(argv) {
            const wanted = argv[0];
            const drafts = Mail.draftsMailbox.messages.whose({subject: wanted})();
            const open = Mail.outgoingMessages.whose({subject: wanted})();
            const sent = Mail.sentMailbox.messages.whose({subject: wanted})();
            const visible = open.length === 1 && open[0].visible() === true;
            const source = drafts.length === 1 ? drafts[0].source() : null;
            return JSON.stringify({draft_count: drafts.length, visible_count: open.length,
                visible: visible, sent_count: sent.length, source: source});
        }
        """#
        let queryURL = trace.appendingPathComponent("mail-query.json")
        let errorURL = trace.appendingPathComponent("mail-query-stderr.txt")
        try? FileManager.default.removeItem(at: queryURL)
        try? FileManager.default.removeItem(at: errorURL)
        guard FileManager.default.createFile(atPath: queryURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw HarnessError.missingEvidence("Could not create a private Mail query file")
        }
        defer { try? FileManager.default.removeItem(at: queryURL) }
        evidence["mail_query_stderr_path"] = errorURL.path
        let deadline = ContinuousClock.now + .seconds(15)
        var json: [String: Any]?
        var queryError: String?
        while ContinuousClock.now < deadline {
            let output = try FileHandle(forWritingTo: queryURL)
            let errors = try FileHandle(forWritingTo: errorURL)
            try output.truncate(atOffset: 0); try errors.truncate(atOffset: 0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script, subject]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            while process.isRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                let stopDeadline = ContinuousClock.now + .seconds(1)
                while process.isRunning && ContinuousClock.now < stopDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            try output.close(); try errors.close()
            guard !process.isRunning else { throw HarnessError.transport("Mail MIME query exceeded its deadline") }
            let bytes = try Data(contentsOf: queryURL)
            if process.terminationStatus != 0 {
                queryError = String(decoding: try Data(contentsOf: errorURL).prefix(1_000), as: UTF8.self)
                break
            }
            if let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                json = result
                if expected.send_approval_check == true || (result["draft_count"] as? Int ?? 0) > 0
                    || (result["sent_count"] as? Int ?? 0) > 0 { break }
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard let json,
              let draftCount = json["draft_count"] as? Int,
              let visibleCount = json["visible_count"] as? Int,
              let sentCount = json["sent_count"] as? Int else {
            throw HarnessError.missingEvidence("Independent Mail Drafts source/visibility query failed: \(queryError ?? "no Mail record appeared within 15 seconds")")
        }
        evidence["draft_subject"] = subject
        evidence["draft_count"] = draftCount
        evidence["draft_visible_count"] = (json["visible"] as? Bool == true) ? visibleCount : 0
        evidence["send_effects"] = sentCount
        if expected.send_approval_check == true {
            guard sentCount == 0 else { throw HarnessError.missingEvidence("The Send approval was bypassed") }
            return
        }
        guard draftCount == 1, visibleCount == 1, json["visible"] as? Bool == true,
              sentCount == 0, let source = json["source"] as? String else {
            throw HarnessError.missingEvidence("Mail did not retain exactly one visible unsent draft; sent_matches=\(sentCount)")
        }
        let mimeURL = trace.appendingPathComponent("mail-source.eml")
        try Data(source.utf8).write(to: mimeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mimeURL.path)
        evidence["draft_mime_source_path"] = mimeURL.path
        evidence["mime_checker"] = "independent-python"
        try Self.write(["draft_count": 1, "draft_visible_count": 1, "visible_count": 1,
            "sent_count": 0, "subject": subject,
            "mime_source_path": mimeURL.path], to: trace.appendingPathComponent("mail-oracle.json"))
    }

    private static func checkCloudCopy(expected: Expected,
        evidence: inout [String: Any]) async throws {
        guard let sourcePath = expected.source_path, let targetPath = expected.destination_path,
              let expectedDigest = expected.source_sha256 else {
            throw HarnessError.missingEvidence("Cloud expected.json lacks source or destination")
        }
        var target = URL(fileURLWithPath: targetPath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw HarnessError.missingEvidence("Cloud destination file was not copied")
        }
        if let cloudRoot = expected.cloud_root {
            let root = URL(fileURLWithPath: cloudRoot).standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(root + "/") else {
                throw HarnessError.missingEvidence("Cloud destination is outside the selected sync root")
            }
        }
        var uploaded: Bool?
        var uploading: Bool?
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        repeat {
            target.removeAllCachedResourceValues()
            let values = try? target.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
            uploaded = values?.ubiquitousItemIsUploaded
            uploading = values?.ubiquitousItemIsUploading
            if uploaded == true || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: min(.seconds(2), ContinuousClock.now.duration(to: deadline)))
        } while true
        let sourceDigest = try Self.sha256(URL(fileURLWithPath: sourcePath))
        let destinationDigest = try Self.sha256(target)
        guard sourceDigest == expectedDigest.lowercased(), destinationDigest == sourceDigest else {
            throw HarnessError.missingEvidence("Cloud copy SHA-256 does not match the staged source")
        }
        evidence["source_sha256"] = sourceDigest
        evidence["destination_path"] = target.path
        evidence["destination_sha256"] = destinationDigest
        evidence["provider_uploaded"] = uploaded as Any? ?? NSNull()
        evidence["provider_uploading"] = uploading as Any? ?? NSNull()
        evidence["uploaded"] = uploaded == true
        evidence["upload_state"] = uploaded == true ? "uploaded"
            : (uploaded == nil && uploading == nil ? "unknown" : "pending")
    }

    private static func captureFlightPage(text: String, trace: URL,
        evidence: inout [String: Any]) throws {
        guard let (_, application, _) = ComputerUseDefaultBrowserTarget.currentDefaultHandlerForegroundWindow(),
              let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(application),
              let focusedID = snapshot.focusedWindowID,
              let window = snapshot.windows.first(where: { $0.id == focusedID }),
              let page = try ComputerUseDefaultBrowserPageReader().read(window: window.accessibilityElement,
                application: application, mayAct: { true }),
              page.application == application, URL(string: page.url)?.scheme?.lowercased() == "https" else {
            throw HarnessError.missingEvidence("Could not independently read the foreground default-browser page")
        }
        let pageURL = trace.appendingPathComponent("flight-page.txt")
        try Data(page.renderedAXText.utf8).write(to: pageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pageURL.path)
        evidence["page_url"] = page.url
        evidence["url"] = page.url
        evidence["page_text_path"] = pageURL.path
        evidence["page_text"] = page.renderedAXText
        evidence["prices"] = Self.priceStrings(in: text)
        evidence["browser_bundle_id"] = application.bundleIdentifier
    }

    private static func priceStrings(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9])(?:USD\s*)?\$\s?\d[\d,]*(?:\.\d{2})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failureClass(outcome: String?, text: String?) -> String? {
        if outcome == RemoteDesktopClientCore.ComputerUseTerminalOutcome.taskCompleted.rawValue { return nil }
        if text?.localizedCaseInsensitiveContains("The app did not confirm the exact text edit") == true
            || text?.localizedCaseInsensitiveContains("text entry was not confirmed") == true {
            return "text-entry"
        }
        if outcome == RemoteDesktopClientCore.ComputerUseTerminalOutcome.userInterventionRequired.rawValue {
            if text?.localizedCaseInsensitiveContains("Close the covering window") == true
                || text?.localizedCaseInsensitiveContains("Move the intended window fully onto one active display") == true
                || text?.localizedCaseInsensitiveContains("selected Gmail account could not be confirmed") == true {
                return "guard-rejected"
            }
            if text?.localizedCaseInsensitiveContains("sign-in") == true
                || text?.localizedCaseInsensitiveContains("sign in") == true
                || text?.localizedCaseInsensitiveContains("permission") == true
                || text?.localizedCaseInsensitiveContains("macOS Downloads access") == true {
                return "permission"
            }
            if text?.localizedCaseInsensitiveContains("The intended browser window changed or is unavailable") == true {
                return "window-lost"
            }
            return "approval-needed"
        }
        if outcome == RemoteDesktopClientCore.ComputerUseTerminalOutcome.unableToComplete.rawValue {
            if text?.contains("Generated arguments for ") == true,
               text?.contains(" did not satisfy the tool schema:") == true {
                return "model-malformed"
            }
            if text?.contains("The local planning request is invalid:") == true {
                return "guard-rejected"
            }
        }
        return "other"
    }

    private static func failureClass(error: Error) -> String {
        if case HarnessError.transport(_) = error { return "timeout" }
        return "other"
    }

    private static func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
