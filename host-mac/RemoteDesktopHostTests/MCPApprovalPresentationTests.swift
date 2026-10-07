import XCTest
@testable import RemoteDesktopHost

final class MCPApprovalPresentationTests: XCTestCase {
    func testMailApprovalShowsExactHeldValuesAndSendButton() throws {
        let prepared = try makePrepared(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: [
                "to": .string("codex-acceptance@example.invalid"),
                "cc": .string("copy@example.invalid"),
                "bcc": .string("audit@example.invalid"),
                "subject": .string("Remote Desktop acceptance test"),
                "body": .string("This is a safe local acceptance test."),
                "send_now": .bool(true),
            ])

        let presentation = prepared.computerUsePresentation

        XCTAssertEqual(presentation.message, "Send this email through Mail on your Mac?")
        XCTAssertEqual(presentation.confirmLabel, "Send email")
        XCTAssertEqual(presentation.details.map(\.label), [
            "From", "To", "CC", "BCC", "Subject", "Message", "First use",
        ])
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "From" })?.value,
            "Your default account in Mail")
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "To" })?.value,
            "codex-acceptance@example.invalid")
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "CC" })?.value,
            "copy@example.invalid")
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "BCC" })?.value,
            "audit@example.invalid")
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "Message" })?.value,
            "This is a safe local acceptance test.")
        XCTAssertTrue(
            presentation.details.first(where: { $0.label == "First use" })?
                .value.contains("Choose Allow") == true)
    }

    func testMailDraftNeverUsesSendApprovalCopy() throws {
        let prepared = try makePrepared(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: [
                "to": .string("codex-acceptance@example.invalid"),
                "subject": .string("Draft"),
                "body": .string("Review me"),
                "send_now": .bool(false),
            ])

        let presentation = prepared.computerUsePresentation

        XCTAssertEqual(presentation.confirmLabel, "Create draft")
        XCTAssertTrue(presentation.message.contains("draft"))
    }

    func testMailAttachmentApprovalListsEveryExactPathWithoutTruncation() throws {
        let paths = [
            "/Users/test/Downloads/Quarterly \"update\".txt",
            "/Users/test/Downloads/second;attachment.txt",
        ]
        let prepared = try makePrepared(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: [
                "to": .string("codex-acceptance@example.invalid"),
                "subject": .string("Draft with files"),
                "body": .string("Review both files"),
                "send_now": .bool(false),
                "attachment_paths": .array(paths.map(MCPJSONValue.string)),
            ])

        let presentation = prepared.computerUsePresentation
        XCTAssertEqual(presentation.details.filter { $0.label.hasPrefix("Attachment ") }
            .map(\.value), paths)
        XCTAssertEqual(presentation.details.last?.label, "First use")
    }

    func testMailAttachmentReceiptCannotProveWholeTaskCompletion() throws {
        let path = "/Users/test/Downloads/approved.txt"
        let prompt = "Draft an email to codex-acceptance@example.invalid with subject \"Review\" and body \"Please see attached\"."
        let prepared = try makePrepared(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: [
                "to": .string("codex-acceptance@example.invalid"),
                "subject": .string("Review"),
                "body": .string("Please see attached"),
                "send_now": .bool(false),
                "attachment_paths": .array([.string(path)]),
            ])
        let result = try MCPToolResult(
            text: "Email draft opened visibly in Mail with 1 confirmed attachment.",
            structuredContent: .object([
                "status": .string("draft_opened"),
                "attachment_count": .integer(1),
                "attachment_names": .array([.string("approved.txt")]),
                "attachment_digest": .string(String(repeating: "a", count: 64)),
            ]),
            isError: false,
            wasTruncated: false)

        let verified = try MCPApprovedActionResult.verified(
            call: prepared.call,
            result: result,
            trustedUserPrompt: prompt)
        XCTAssertNil(verified.completionPromptDigest)
        XCTAssertThrowsError(try MCPApprovedActionResult.verified(
            call: prepared.call,
            result: try MCPToolResult(
                text: "Email draft opened visibly in Mail with 1 confirmed attachment.",
                structuredContent: .object([
                    "status": .string("draft_opened"),
                    "attachment_count": .integer(1),
                    "attachment_names": .array([.string("wrong.txt")]),
                    "attachment_digest": .string(String(repeating: "a", count: 64)),
                ]),
                isError: false,
                wasTruncated: false),
            trustedUserPrompt: prompt))
        XCTAssertThrowsError(try MCPApprovedActionResult.verified(
            call: prepared.call,
            result: try MCPToolResult(
                text: "Email draft opened visibly in Mail with 1 confirmed attachment.",
                structuredContent: .object([
                    "status": .string("draft_opened"),
                    "attachment_count": .integer(1),
                    "attachment_names": .array([.string("approved.txt")]),
                ]),
                isError: false,
                wasTruncated: false),
            trustedUserPrompt: prompt))
        XCTAssertThrowsError(try MCPApprovedActionResult.verified(
            call: prepared.call,
            result: try MCPToolResult(
                text: "Email draft opened visibly in Mail with 1 confirmed attachment.",
                structuredContent: .object([
                    "status": .string("draft_opened"),
                    "attachment_count": .integer(1),
                    "attachment_names": .array([.string("approved.txt")]),
                    "attachment_digest": .string("invalid"),
                ]),
                isError: false,
                wasTruncated: false),
            trustedUserPrompt: prompt))
    }

    private func makePrepared(
        toolName: String,
        arguments: [String: MCPJSONValue]
    ) throws -> MCPPreparedApproval {
        let tool = try MCPAllowedTool(
            serverID: toolName == RemoteDesktopMailMCP.toolName ? RemoteDesktopMailMCP.serverID : "mac-control",
            processGeneration: 7,
            toolName: toolName,
            description: "Pinned local tool",
            inputSchema: .object(["type": .string("object")]),
            risk: .approvalRequired,
            approval: MCPApprovalDisplay(
                summary: "Approve this action?",
                details: "Exact values are shown.",
                confirmLabel: "Approve once"))
        let call = try tool.makeCall(taskID: "task-1", arguments: arguments)
        return MCPPreparedApproval(
            call: call,
            fingerprint: MCPApprovalFingerprint(call: call),
            display: call.approvalDisplay)
    }
}
