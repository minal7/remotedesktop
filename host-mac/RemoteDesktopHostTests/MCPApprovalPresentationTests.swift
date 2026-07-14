import XCTest
@testable import RemoteDesktopHost

final class MCPApprovalPresentationTests: XCTestCase {
    func testMailApprovalShowsExactHeldValuesAndSendButton() throws {
        let prepared = try makePrepared(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: [
                "to": .string("codex-acceptance@example.invalid"),
                "subject": .string("Remote Desktop acceptance test"),
                "body": .string("This is a safe local acceptance test."),
                "send_now": .bool(true),
            ])

        let presentation = prepared.computerUsePresentation

        XCTAssertEqual(presentation.message, "Send this email through Mail on your Mac?")
        XCTAssertEqual(presentation.confirmLabel, "Send email")
        XCTAssertEqual(presentation.details.map(\.label), [
            "From", "To", "Subject", "Message", "First use",
        ])
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "From" })?.value,
            "Your default account in Mail")
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "To" })?.value,
            "codex-acceptance@example.invalid")
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

    private func makePrepared(
        toolName: String,
        arguments: [String: MCPJSONValue]
    ) throws -> MCPPreparedApproval {
        let tool = try MCPAllowedTool(
            serverID: "mac-control",
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
