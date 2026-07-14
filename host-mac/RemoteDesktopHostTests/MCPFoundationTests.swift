import XCTest
@testable import RemoteDesktopHost

final class MCPFoundationTests: XCTestCase {
    func testCanonicalCallDigestIsStableAcrossDictionaryOrderAndProcessRestart() throws {
        let firstTool = try allowedTool(
            name: "set_element_attribute",
            generation: 10,
            schema: objectSchema(
                properties: [
                    "attribute": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")]),
                ],
                required: ["attribute", "value"]))
        let secondTool = try allowedTool(
            name: "set_element_attribute",
            generation: 11,
            schema: firstTool.inputSchema)

        let first = try firstTool.makeCall(
            taskID: "task-1",
            arguments: [
                "attribute": .string("AXValue"),
                "value": .string("fixture value"),
            ])
        let reordered = try secondTool.makeCall(
            taskID: "task-1",
            arguments: [
                "value": .string("fixture value"),
                "attribute": .string("AXValue"),
            ])

        XCTAssertEqual(first.canonicalArguments, reordered.canonicalArguments)
        XCTAssertEqual(first.argumentsDigest, reordered.argumentsDigest)
        XCTAssertEqual(first.canonicalDigest, reordered.canonicalDigest)
        XCTAssertNotEqual(first.processGeneration, reordered.processGeneration)

        let anotherTask = try firstTool.makeCall(
            taskID: "task-2",
            arguments: first.arguments)
        XCTAssertNotEqual(first.canonicalDigest, anotherTask.canonicalDigest)
    }

    func testSafetySetsAreDisjointAndUnknownOrDangerousToolsAreBlocked() {
        XCTAssertTrue(MCPToolSafetyPolicy.readOnlyTools
            .intersection(MCPToolSafetyPolicy.reversibleTools).isEmpty)
        XCTAssertTrue(MCPToolSafetyPolicy.readOnlyTools
            .intersection(MCPToolSafetyPolicy.approvalRequiredTools).isEmpty)
        XCTAssertTrue(MCPToolSafetyPolicy.reversibleTools
            .intersection(MCPToolSafetyPolicy.approvalRequiredTools).isEmpty)

        for name in [
            "browser_close_tab", "browser_eval_js", "browser_get_active_tab",
            "browser_list_tabs", "browser_navigate", "browser_new_tab",
            "clipboard_read", "foundation_models_generate", "imessage_send",
            "mail_send", "open_url_scheme", "system_shutdown", "trash_file",
        ] {
            XCTAssertTrue(MCPToolSafetyPolicy.explicitlyBlockedTools.contains(name))
            XCTAssertEqual(MCPToolSafetyPolicy.risk(for: name), .blocked)
            XCTAssertFalse(MCPToolSafetyPolicy.isAllowed(name))
        }
        XCTAssertEqual(MCPToolSafetyPolicy.risk(for: "future_unreviewed_tool"), .blocked)
    }

    func testRealStdioAcceptanceGateDefinesTheExactExposedAndPlannerSurfaces() {
        let expectedExposed: Set<String> = [
            "ax_snapshot_capture", "ax_snapshot_diff", "ax_tree_augmented",
            "click", "click_menu_path", "contacts_search", "find_element",
            "find_elements", "focus_window",
            "focused_app", "get_element_attributes", "get_ui_tree", "list_apps",
            "list_elements", "list_menu_titles", "list_shortcuts", "list_windows",
            "perform_element_action", "permissions_status", "press_key",
            "probe_ax_tree", "query_elements", "read_value", "reminders_list",
            RemoteDesktopMailMCP.toolName, "set_element_attribute", "type_text",
            "wait_for_ax_notification",
            "wait_for_element", "wait_for_window_state_change",
        ]
        XCTAssertEqual(MCPToolSafetyPolicy.allowedTools, expectedExposed)

        let acceptanceBlocked: Set<String> = [
            "browser_close_tab", "browser_dom_tree", "browser_get_active_tab",
            "browser_iframes", "browser_list_tabs", "browser_navigate",
            "browser_new_tab", "browser_visible_text", "calendar_create_event",
            "calendar_list_events", "reminders_create", "run_shortcut",
            "scroll_to_element",
        ]
        XCTAssertEqual(
            Set(MCPToolSafetyPolicy.acceptanceBlockedToolReasons.keys),
            acceptanceBlocked)
        XCTAssertTrue(acceptanceBlocked.isSubset(
            of: MCPToolSafetyPolicy.explicitlyBlockedTools))
        XCTAssertTrue(MCPToolSafetyPolicy.acceptanceBlockedToolReasons.values
            .allSatisfy { !$0.isEmpty })
        for tool in acceptanceBlocked {
            XCTAssertEqual(MCPToolSafetyPolicy.risk(for: tool), .blocked)
            XCTAssertFalse(MCPToolSafetyPolicy.isAllowed(tool))
        }

        let expectedPlannerTools: Set<String> = [
            "contacts_search", "focused_app", "list_apps", "list_shortcuts",
            "list_windows", "permissions_status", RemoteDesktopMailMCP.toolName,
            "reminders_list",
        ]
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.structuredToolNames,
            expectedPlannerTools)
        XCTAssertTrue(MCPFirstComputerUseExecutor.structuredToolNames
            .isSubset(of: expectedExposed))
    }

    func testDynamicApprovalCopyDoesNotRevealTypedTextOrEmailBody() throws {
        let typeTool = try allowedTool(
            name: "type_text",
            schema: objectSchema(
                properties: ["text": .object(["type": .string("string")])],
                required: ["text"]))
        let secret = "the user's private password"
        let typeCall = try typeTool.makeCall(
            taskID: "typing",
            arguments: ["text": .string(secret)])
        XCTAssertTrue(typeCall.approvalDetails.contains("\(secret.count) characters"))
        XCTAssertFalse(typeCall.approvalDetails.contains(secret))

        let mailTool = try allowedTool(
            name: RemoteDesktopMailMCP.toolName,
            schema: objectSchema(
                properties: [
                    "to": .object(["type": .string("string")]),
                    "subject": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string")]),
                    "send_now": .object(["type": .string("boolean")]),
                ],
                required: ["to", "subject", "body", "send_now"]))
        let body = "private medical details"
        let mailCall = try mailTool.makeCall(
            taskID: "mail",
            arguments: [
                "to": .string("person@example.com"),
                "subject": .string("Hello"),
                "body": .string(body),
                "send_now": .bool(true),
            ])
        XCTAssertEqual(mailCall.approvalConfirmLabel, "Send email")
        XCTAssertTrue(mailCall.approvalDetails.contains("person@example.com"))
        XCTAssertTrue(mailCall.approvalDetails.contains("Hello"))
        XCTAssertFalse(mailCall.approvalDetails.contains(body))
    }

    func testRegistryPinsOneExpectedServerAndRejectsWrongLayoutBeforeLaunch() throws {
        XCTAssertEqual(MCPServerRegistry.curatedServers, [MCPServerRegistry.macControl])
        let definition = MCPServerRegistry.macControl
        XCTAssertEqual(definition.expectedServerVersion, "0.8.2")
        XCTAssertEqual(
            definition.executableSHA256,
            "402729cbf8179783466f4ba2ca1d1a2bf8ffb19cd7dee330963392afae9f4302")
        XCTAssertEqual(definition.bundleIdentifier, "dev.macmcp.server")
        XCTAssertEqual(definition.teamIdentifier, "A3W973JZ49")
        XCTAssertEqual(definition.expectedProtocolVersion, "2024-11-05")

        let wrongURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-the-pinned-helper")
        XCTAssertThrowsError(try SystemMCPServerBinaryValidator.validateStructure(
            binaryURL: wrongURL,
            definition: definition)) { error in
            guard case MCPClientError.invalidBinary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPaginationCollectsEveryPageAndRejectsCursorLoops() async throws {
        let values = try await MCPToolPagination.collect { cursor in
            switch cursor {
            case nil: return ([1, 2], "next")
            case "next": return ([3], nil)
            default: return ([], nil)
            }
        }
        XCTAssertEqual(values, [1, 2, 3])

        do {
            _ = try await MCPToolPagination.collect { _ in ([1], "same") }
            XCTFail("Expected a pagination loop failure")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .paginationLoop)
        }
    }

    func testSchemaValidationRequiresKnownTypedFields() throws {
        let schema = objectSchema(
            properties: [
                "name": .object([
                    "type": .string("string"),
                    "enum": .array([.string("one"), .string("two")]),
                ]),
                "count": .object([
                    "type": .array([.string("integer"), .string("string")]),
                ]),
            ],
            required: ["name"])

        XCTAssertNoThrow(try MCPJSONSchemaValidator.validate(
            arguments: ["name": .string("one"), "count": .integer(2)],
            against: schema))
        XCTAssertThrowsError(try MCPJSONSchemaValidator.validate(
            arguments: ["count": .integer(2)],
            against: schema))
        XCTAssertThrowsError(try MCPJSONSchemaValidator.validate(
            arguments: ["name": .string("three")],
            against: schema))
        XCTAssertThrowsError(try MCPJSONSchemaValidator.validate(
            arguments: ["name": .string("one"), "surprise": .bool(true)],
            against: schema))
    }

    func testAmbientBrowserToolsCannotConstructCalls() throws {
        for name in [
            "browser_close_tab", "browser_get_active_tab", "browser_list_tabs",
            "browser_navigate", "browser_new_tab",
        ] {
            let tool = try allowedTool(name: name)
            XCTAssertThrowsError(try tool.makeCall(
                taskID: "blocked-browser",
                arguments: [:])) { error in
                    XCTAssertEqual(error as? MCPClientError, .toolNotAllowed(name))
                }
        }
    }

    func testOutputSanitizerRedactsPrivateInputsAndEnforcesByteCaps() throws {
        let tool = try allowedTool(
            name: "type_text",
            schema: objectSchema(
                properties: ["text": .object(["type": .string("string")])],
                required: ["text"]))
        let privateText = "correct horse battery staple"
        let call = try tool.makeCall(
            taskID: "private-output",
            arguments: ["text": .string(privateText)])

        let text = MCPToolOutputSanitizer.sanitizeText(
            "echoed \(privateText) " + String(
                repeating: "x",
                count: MCPToolOutputSanitizer.maximumTextBytes * 2),
            call: call)
        XCTAssertTrue(text.wasTruncated)
        XCTAssertFalse(text.text.contains(privateText))
        XCTAssertLessThanOrEqual(
            text.text.utf8.count,
            MCPToolOutputSanitizer.maximumTextBytes)

        let structured = try MCPToolOutputSanitizer.sanitizeStructured(
            .object([
                "text": .string(privateText),
                "access_token": .string("secret-token"),
            ]),
            call: call)
        XCTAssertEqual(structured.value, .object([
            "text": .string("[redacted]"),
            "access_token": .string("[redacted]"),
        ]))
    }

    func testPoolRequiresExactApprovalFingerprintAndConsumesItOnce() async throws {
        let temporary = temporaryURL("approval-ledger.json")
        let factory = FakeMCPSessionFactory(toolNames: ["press_key"])
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: temporary),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(
            taskID: "approved-key-press",
            arguments: [:])

        do {
            _ = try await pool.execute(call)
            XCTFail("Expected approval requirement")
        } catch let error as MCPClientError {
            guard case .approvalRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let prepared = try await pool.prepareApproval(call)
        var wrong = prepared.fingerprint
        wrong = MCPApprovalFingerprint(call: try tool.makeCall(
            taskID: "different-task",
            arguments: call.arguments))
        do {
            _ = try await pool.performApproved(call, fingerprint: wrong)
            XCTFail("Expected fingerprint mismatch")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }

        let result = try await pool.performApproved(
            call,
            fingerprint: prepared.fingerprint)
        XCTAssertEqual(result.text, "ok")
        let approvedExecutionCount = await factory.latestSession()?.executionCount()
        XCTAssertEqual(approvedExecutionCount, 1)

        do {
            _ = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
            XCTFail("Expected consumed approval")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }
    }

    func testCompletedMutationIsReturnedFromLedgerWithoutRetry() async throws {
        let factory = FakeMCPSessionFactory(toolNames: ["focus_window"])
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: temporaryURL("completed-ledger.json")),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(
            taskID: "focus-once",
            arguments: [:])

        let first = try await pool.execute(call)
        let second = try await pool.execute(call)
        XCTAssertEqual(first, second)
        let executionCount = await factory.latestSession()?.executionCount()
        XCTAssertEqual(executionCount, 1)
    }

    func testInterruptedMutationIsAmbiguousAfterLedgerRelaunch() async throws {
        let fileURL = temporaryURL("ambiguous-ledger.json")
        let call = try allowedTool(
            name: "focus_window")
            .makeCall(
                taskID: "interrupted",
                arguments: [:])

        let firstLedger = MCPFileMutationCallLedger(fileURL: fileURL)
        let firstClaim = try await firstLedger.claim(call)
        XCTAssertEqual(firstClaim, .new)

        let relaunchedLedger = MCPFileMutationCallLedger(fileURL: fileURL)
        let relaunchedClaim = try await relaunchedLedger.claim(call)
        XCTAssertEqual(relaunchedClaim, .ambiguous)
    }

    func testMutationLedgerFreshAtomicCreationIsOwnerOnly() async throws {
        let fileURL = temporaryURL("fresh-permissions-ledger.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let ledger = MCPFileMutationCallLedger(fileURL: fileURL)

        let claim = try await ledger.claim(mutationCall(taskID: "fresh"))
        XCTAssertEqual(claim, .new)

        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testMutationLedgerAtomicReplacementRepairsPermissiveFile() async throws {
        let fileURL = temporaryURL("replacement-permissions-ledger.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let ledger = MCPFileMutationCallLedger(fileURL: fileURL)
        let call = try mutationCall(taskID: "replacement")
        let claim = try await ledger.claim(call)
        XCTAssertEqual(claim, .new)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path)

        let result = try MCPToolResult(
            text: "completed",
            structuredContent: nil,
            isError: false,
            wasTruncated: false)
        try await ledger.complete(call, result: result)

        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testMutationLedgerInitializationRepairsExistingPermissiveFile() async throws {
        let fileURL = temporaryURL("existing-permissions-ledger.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let firstLedger = MCPFileMutationCallLedger(fileURL: fileURL)
        let claim = try await firstLedger.claim(mutationCall(taskID: "existing"))
        XCTAssertEqual(claim, .new)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path)
        XCTAssertEqual(try posixPermissions(at: fileURL), 0o644)

        _ = MCPFileMutationCallLedger(fileURL: fileURL)

        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testCancellingReadStopsTheOwnedSidecar() async throws {
        let factory = FakeMCPSessionFactory(
            toolNames: ["focused_app"],
            behavior: .suspend)
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: temporaryURL("cancel-ledger.json")),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(taskID: "cancel-read", arguments: [:])

        let operation = Task { try await pool.execute(call) }
        try await Task.sleep(for: .milliseconds(50))
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .cancelled)
        }
        let stopCount = await factory.latestSession()?.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testStaleCancelledReadCannotStopNewerSidecarGeneration() async throws {
        let factory = FakeMCPSessionFactory(
            toolNames: ["focused_app"],
            behavior: .suspend)
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: temporaryURL("stale-cancel-ledger.json")),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        let firstIdentity = try await pool.start(binaryURL: fakeBinaryURL)
        let firstTools = try await pool.allowedTools()
        let firstTool = try XCTUnwrap(firstTools.first)
        let firstCall = try firstTool.makeCall(taskID: "old-read", arguments: [:])
        let oldOperation = Task { try await pool.execute(firstCall) }
        try await Task.sleep(for: .milliseconds(50))

        let secondIdentity = try await pool.start(binaryURL: fakeBinaryURL)
        XCTAssertGreaterThan(
            secondIdentity.processGeneration,
            firstIdentity.processGeneration)
        oldOperation.cancel()
        do {
            _ = try await oldOperation.value
            XCTFail("Expected the old read to cancel")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .cancelled)
        }

        let currentTools = try await pool.allowedTools()
        XCTAssertFalse(currentTools.isEmpty)
        let newSessionStopCount = await factory.latestSession()?.stopCount()
        XCTAssertEqual(
            newSessionStopCount,
            0,
            "Cleanup from generation 1 must not stop generation 2")
        await pool.cancelAll()
    }

    private var fakeBinaryURL: URL {
        URL(fileURLWithPath: "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP")
    }

    private func allowedTool(
        name: String,
        generation: UInt64 = 1,
        schema: MCPJSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    ) throws -> MCPAllowedTool {
        let assessment = MCPToolSafetyPolicy.assess(toolName: name)
        return try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: generation,
            toolName: name,
            description: "Test tool",
            inputSchema: schema,
            risk: assessment.risk,
            approval: assessment.approval)
    }

    private func objectSchema(
        properties: [String: MCPJSONValue],
        required: [String] = []
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCPJSONValue.string))
        }
        return .object(schema)
    }

    private func mutationCall(taskID: String) throws -> MCPToolCall {
        try allowedTool(
            name: "focus_window")
            .makeCall(
                taskID: taskID,
                arguments: [:])
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPFoundationTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}

private struct AcceptingMCPBinaryValidator: MCPServerBinaryValidating {
    func validate(
        binaryURL: URL,
        definition: MCPServerDefinition
    ) async throws -> MCPValidatedBinary {
        MCPValidatedBinary(
            definition: definition,
            appBundleURL: binaryURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            executableURL: binaryURL)
    }
}

private final class FakeMCPSessionFactory: @unchecked Sendable {
    enum Behavior: Sendable {
        case succeed
        case suspend
    }

    private let lock = NSLock()
    private let toolNames: [String]
    private let behavior: Behavior
    private var sessions: [FakeMCPSession] = []

    init(toolNames: [String], behavior: Behavior = .succeed) {
        self.toolNames = toolNames
        self.behavior = behavior
    }

    func make(
        binary: MCPValidatedBinary,
        generation: UInt64
    ) -> any MCPClientSessioning {
        let session = FakeMCPSession(
            binary: binary,
            generation: generation,
            toolNames: toolNames,
            behavior: behavior)
        lock.lock()
        sessions.append(session)
        lock.unlock()
        return session
    }

    func latestSession() -> FakeMCPSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.last
    }
}

private actor FakeMCPSession: MCPClientSessioning {
    private let binary: MCPValidatedBinary
    private let generation: UInt64
    private let toolNames: [String]
    private let behavior: FakeMCPSessionFactory.Behavior
    private var executions = 0
    private var stops = 0

    init(
        binary: MCPValidatedBinary,
        generation: UInt64,
        toolNames: [String],
        behavior: FakeMCPSessionFactory.Behavior
    ) {
        self.binary = binary
        self.generation = generation
        self.toolNames = toolNames
        self.behavior = behavior
    }

    func start() async throws -> MCPProcessIdentity {
        MCPProcessIdentity(
            serverID: binary.definition.serverID,
            processGeneration: generation,
            processIdentifier: 42,
            binaryPath: binary.executableURL.path,
            launchedAt: Date())
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] {
        try toolNames.map { name in
            let assessment = MCPToolSafetyPolicy.assess(toolName: name)
            return try MCPAllowedTool(
                serverID: binary.definition.serverID,
                processGeneration: generation,
                toolName: name,
                description: "Fake \(name)",
                inputSchema: Self.schema(for: name),
                risk: assessment.risk,
                approval: assessment.approval)
        }
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        executions += 1
        switch behavior {
        case .succeed:
            return try MCPToolResult(
                text: "ok",
                structuredContent: nil,
                isError: false,
                wasTruncated: false)
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            return try MCPToolResult(
                text: "unexpected",
                structuredContent: nil,
                isError: false,
                wasTruncated: false)
        }
    }

    func stop() async {
        stops += 1
    }

    func executionCount() -> Int { executions }
    func stopCount() -> Int { stops }

    private static func schema(for name: String) -> MCPJSONValue {
        let fields: [String: MCPJSONValue]
        let required: [String]
        switch name {
        case RemoteDesktopMailMCP.toolName:
            fields = [
                "to": .object(["type": .string("string")]),
                "subject": .object(["type": .string("string")]),
                "body": .object(["type": .string("string")]),
                "cc": .object(["type": .string("string")]),
                "bcc": .object(["type": .string("string")]),
                "send_now": .object(["type": .string("boolean")]),
            ]
            required = ["to", "subject", "body", "send_now"]
        default:
            fields = [:]
            required = []
        }

        var schema: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(fields),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCPJSONValue.string))
        }
        return .object(schema)
    }
}
