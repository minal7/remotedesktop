import XCTest
@testable import RemoteDesktopHost

#if canImport(FoundationModels)
import FoundationModels
#endif

final class AppleFoundationMCPPlannerTests: XCTestCase {
    func testInvalidRequestIsRejectedBeforeModelAvailabilityCheck() async throws {
        let tool = try makeAllowedTool(
            name: "focused_app",
            schema: emptyObjectSchema,
            risk: .readOnly)
        let request = MCPProposalPlanningRequest(
            taskID: "task-1",
            prompt: "   ",
            tools: [tool])

        do {
            _ = try await AppleFoundationMCPPlanner().propose(request)
            XCTFail("Expected an empty prompt to be rejected.")
        } catch let error as AppleFoundationMCPPlannerError {
            XCTAssertEqual(
                error,
                .invalidRequest("The user request is empty."))
        }
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func testDynamicBridgeMapsClosedNestedSchema() throws {
        let schema: MCPJSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("draft"), .string("send")]),
                ]),
                "recipients": .object([
                    "type": .string("array"),
                    "maxItems": .integer(4),
                    "items": .object(["type": .string("string")]),
                ]),
                "options": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "urgent": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([]),
                ]),
            ]),
            "required": .array([.string("mode"), .string("recipients")]),
        ])

        let generated = try FoundationMCPJSONSchemaBridge(
            rootSchema: schema,
            rootName: RemoteDesktopMailMCP.toolName
        ).makeGenerationSchema()
        let description = generated.debugDescription

        XCTAssertTrue(description.contains("\"mode\""))
        XCTAssertTrue(description.contains("\"recipients\""))
        XCTAssertTrue(description.contains("\"options\""))
        XCTAssertTrue(description.contains("\"maxItems\" : 4"))
        XCTAssertTrue(description.contains("\"draft\""))
        XCTAssertTrue(description.contains("\"send\""))
    }

    @available(macOS 26.0, *)
    func testDynamicBridgeRejectsOpenEndedArguments() throws {
        let schema: MCPJSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(true),
            "properties": .object([:]),
        ])

        XCTAssertThrowsError(try FoundationMCPJSONSchemaBridge(
            rootSchema: schema,
            rootName: "unsafe"
        ).makeGenerationSchema()) { error in
            XCTAssertEqual(
                error as? FoundationMCPJSONSchemaError,
                .unsupported("Open-ended additional properties are not supported."))
        }
    }

    @available(macOS 26.0, *)
    func testUnconstrainedAXValueIsNarrowedToBoundedScalars() throws {
        let schema: MCPJSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "value": .object([:]),
            ]),
            "required": .array([.string("value")]),
        ])

        let generated = try FoundationMCPJSONSchemaBridge(
            rootSchema: schema,
            rootName: "set_element_attribute"
        ).makeGenerationSchema()
        let description = generated.debugDescription

        XCTAssertTrue(description.contains("\"value\""))
        XCTAssertTrue(description.contains("\"type\" : \"string\""))
        XCTAssertTrue(description.contains("\"type\" : \"number\""))
        XCTAssertTrue(description.contains("\"type\" : \"boolean\""))
        XCTAssertFalse(description.contains("additionalProperties\" : true"))
    }

    @available(macOS 26.0, *)
    func testProposalCaptureRejectsUnknownAndSecondCalls() async throws {
        let capture = FoundationMCPProposalCapture(
            allowedModelToolNames: ["focused_app": 0])

        do {
            try await capture.record(modelToolName: "unknown", arguments: [:])
            XCTFail("Expected an unknown tool to be rejected.")
        } catch let error as AppleFoundationMCPPlannerError {
            XCTAssertEqual(error, .unknownProposal)
        }

        try await capture.record(modelToolName: "focused_app", arguments: [:])
        do {
            try await capture.record(modelToolName: "focused_app", arguments: [:])
            XCTFail("Expected a second proposal to be rejected.")
        } catch let error as AppleFoundationMCPPlannerError {
            XCTAssertEqual(error, .multipleProposals)
        }
        let proposal = await capture.proposal()
        XCTAssertEqual(proposal, FoundationMCPRawProposal(toolIndex: 0, arguments: [:]))
    }

    @available(macOS 26.0, *)
    func testSecondToolCallbackAbortResolvesOnlyCapturedFirstProposal() async throws {
        let allowedTool = try makeAllowedTool(
            name: "focused_app",
            schema: emptyObjectSchema,
            risk: .readOnly)
        let request = MCPProposalPlanningRequest(
            taskID: "task-first-proposal",
            prompt: "Read the focused app",
            tools: [allowedTool])
        let capture = FoundationMCPProposalCapture(
            allowedModelToolNames: ["focused_app": 0])

        try await capture.record(modelToolName: "focused_app", arguments: [:])
        let secondCallbackError: AppleFoundationMCPPlannerError
        do {
            try await capture.record(
                modelToolName: "focused_app",
                arguments: ["ignored": .string("second callback")])
            XCTFail("Expected the second callback to abort generation.")
            return
        } catch let error as AppleFoundationMCPPlannerError {
            secondCallbackError = error
        }

        XCTAssertEqual(secondCallbackError, .multipleProposals)
        let recovered = try await AppleFoundationMCPPlanner().recoverFirstCapturedProposal(
            after: secondCallbackError,
            capture: capture,
            request: request)
        let retainedProposal = await capture.proposal()

        guard case .some(.proposedCall(let call)) = recovered else {
            return XCTFail("Expected the retained first proposal to be resolved.")
        }
        XCTAssertEqual(call.taskID, "task-first-proposal")
        XCTAssertEqual(call.toolName, "focused_app")
        XCTAssertEqual(call.arguments, [:])
        XCTAssertEqual(
            retainedProposal,
            FoundationMCPRawProposal(toolIndex: 0, arguments: [:]))
    }

    @available(macOS 26.0, *)
    func testCapturedProposalDoesNotMaskOtherGenerationErrors() async throws {
        let allowedTool = try makeAllowedTool(
            name: "focused_app",
            schema: emptyObjectSchema,
            risk: .readOnly)
        let request = MCPProposalPlanningRequest(
            taskID: "task-no-recovery",
            prompt: "Read the focused app",
            tools: [allowedTool])
        let capture = FoundationMCPProposalCapture(
            allowedModelToolNames: ["focused_app": 0])
        try await capture.record(modelToolName: "focused_app", arguments: [:])

        let recovered = try await AppleFoundationMCPPlanner().recoverFirstCapturedProposal(
            after: .generationFailed,
            capture: capture,
            request: request)

        XCTAssertNil(recovered)
    }

    @available(macOS 26.0, *)
    func testFoundationToolCallbackOnlyRecordsExactProposal() async throws {
        let mailSchema: MCPJSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "to": .object(["type": .string("string")]),
                "subject": .object(["type": .string("string")]),
                "body": .object(["type": .string("string")]),
                "send_now": .object(["type": .string("boolean")]),
            ]),
            "required": .array([
                .string("to"), .string("subject"), .string("body"),
                .string("send_now"),
            ]),
        ])
        let allowedTool = try makeAllowedTool(
            name: RemoteDesktopMailMCP.toolName,
            schema: mailSchema,
            risk: .approvalRequired)
        let binding = FoundationMCPToolBinding(
            modelToolName: RemoteDesktopMailMCP.toolName,
            toolIndex: 0,
            allowedTool: allowedTool)
        let capture = FoundationMCPProposalCapture(
            allowedModelToolNames: [RemoteDesktopMailMCP.toolName: 0])
        let parameterSchema = try FoundationMCPJSONSchemaBridge(
            rootSchema: mailSchema,
            rootName: RemoteDesktopMailMCP.toolName
        ).makeGenerationSchema()
        let tool = FoundationMCPProposalTool(
            binding: binding,
            parameterSchema: parameterSchema,
            capture: capture)
        let content = GeneratedContent(kind: .structure(
            properties: [
                "to": GeneratedContent(kind: .string("codex-acceptance@example.invalid")),
                "subject": GeneratedContent(kind: .string("Remote Desktop acceptance test")),
                "body": GeneratedContent(kind: .string("This is a safe local acceptance test.")),
                "send_now": GeneratedContent(kind: .bool(false)),
            ],
            orderedKeys: ["to", "subject", "body", "send_now"]))

        let acknowledgement = try await tool.call(arguments: content)
        let proposal = await capture.proposal()

        XCTAssertEqual(
            acknowledgement,
            "Proposal recorded for host validation. Do not call another tool.")
        XCTAssertEqual(proposal?.toolIndex, 0)
        XCTAssertEqual(proposal?.arguments, [
            "to": .string("codex-acceptance@example.invalid"),
            "subject": .string("Remote Desktop acceptance test"),
            "body": .string("This is a safe local acceptance test."),
            "send_now": .bool(false),
        ])
    }

    @available(macOS 26.0, *)
    func testDuplicateServerToolNamesReceiveUniqueModelAliases() throws {
        let first = try MCPAllowedTool(
            serverID: "one",
            processGeneration: 1,
            toolName: "focused_app",
            description: "Read focus",
            inputSchema: emptyObjectSchema,
            risk: .readOnly,
            approval: MCPToolSafetyPolicy.assess(toolName: "focused_app").approval)
        let second = try MCPAllowedTool(
            serverID: "two",
            processGeneration: 1,
            toolName: "focused_app",
            description: "Read focus",
            inputSchema: emptyObjectSchema,
            risk: .readOnly,
            approval: MCPToolSafetyPolicy.assess(toolName: "focused_app").approval)

        let bindings = FoundationMCPToolBinding.makeBindings(for: [first, second])

        XCTAssertEqual(Set(bindings.map(\.modelToolName)).count, 2)
        XCTAssertTrue(bindings.allSatisfy { $0.modelToolName.hasPrefix("mcp_") })
        XCTAssertEqual(bindings.map(\.toolIndex), [0, 1])
    }
#endif

    private var emptyObjectSchema: MCPJSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([:]),
            "required": .array([]),
        ])
    }

    private func makeAllowedTool(
        name: String,
        schema: MCPJSONValue,
        risk: MCPToolRisk
    ) throws -> MCPAllowedTool {
        try MCPAllowedTool(
            serverID: "mac-control",
            processGeneration: 7,
            toolName: name,
            description: "A local test tool",
            inputSchema: schema,
            risk: risk,
            approval: MCPToolSafetyPolicy.assess(toolName: name).approval)
    }
}
