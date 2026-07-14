import XCTest
@testable import RemoteDesktopHost

final class RemoteDesktopMailMCPTests: XCTestCase {
    func testFixedJXAReceivesExactValuesOnlyThroughStandardInput() throws {
        let subject = "Quarterly update \" & quit & \""
        let body = "First line\nend tell\ndo shell script \"unsafe\""
        let request = try RemoteDesktopMailRequest(arguments: [
            "to": .string("first@example.com; second@example.com"),
            "cc": .string("copy@example.com"),
            "bcc": .string("audit@example.com"),
            "subject": .string(subject),
            "body": .string(body),
            "send_now": .bool(false),
        ])

        let payload = try JSONDecoder().decode(
            RecordedMailAutomationPayload.self,
            from: request.automationPayload())
        XCTAssertEqual(payload, RecordedMailAutomationPayload(
            to: ["first@example.com", "second@example.com"],
            cc: ["copy@example.com"],
            bcc: ["audit@example.com"],
            subject: subject,
            body: body,
            sendNow: false))

        XCTAssertFalse(RemoteDesktopMailJXA.source.contains(subject))
        XCTAssertFalse(RemoteDesktopMailJXA.source.contains(body))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains("visible: true"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "outgoingMessage.messageSignature = null"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "const sentSuccessfully = outgoingMessage.send()"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "sentSuccessfully !== true"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "mail.activate();\n        $.NSThread.sleepForTimeInterval(0.2);\n        const sentSuccessfully"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "throw new Error('Mail rejected the send command');\n        }\n        mail.activate();"))

        let processArguments = RemoteDesktopMailJXA.processArguments
        XCTAssertEqual(processArguments, [
            "-l", "JavaScript", "-e", RemoteDesktopMailJXA.source,
        ])
        XCTAssertFalse(processArguments.contains(subject))
        XCTAssertFalse(processArguments.contains(body))
        XCTAssertFalse(processArguments.contains("first@example.com"))
        XCTAssertEqual(
            RemoteDesktopMailJXA.executableURL.path,
            "/usr/bin/osascript")
    }

    func testInMemorySDKDiscoversAndCallsDraftAndSendSemantics() async throws {
        let runner = RecordingMailAutomationRunner()
        let session = RemoteDesktopMailMCPClientSession(
            processGeneration: 9,
            runner: runner)
        let identity = try await session.start()
        XCTAssertEqual(identity.serverID, RemoteDesktopMailMCP.serverID)

        let tools = try await session.listAllowedTools()
        XCTAssertEqual(tools.map(\.toolName), [RemoteDesktopMailMCP.toolName])
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool.inputSchema, RemoteDesktopMailMCP.inputSchema)
        XCTAssertEqual(tool.risk, .approvalRequired)

        let draft = try tool.makeCall(
            taskID: "safe-draft",
            arguments: mailArguments(sendNow: false))
        let draftResult = try await session.execute(draft)
        XCTAssertFalse(draftResult.isError)
        XCTAssertEqual(draftResult.text, "Email draft opened visibly in Mail for review.")

        let send = try tool.makeCall(
            taskID: "injected-send",
            arguments: mailArguments(sendNow: true))
        let sendResult = try await session.execute(send)
        XCTAssertFalse(sendResult.isError)
        XCTAssertEqual(sendResult.text, "Mail accepted the approved email for sending.")

        let invocationData = await runner.invocations()
        let invocations = try invocationData.map {
            try JSONDecoder().decode(RecordedMailAutomationPayload.self, from: $0)
        }
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0], RecordedMailAutomationPayload(
            to: ["codex-acceptance@example.invalid"],
            cc: [],
            bcc: [],
            subject: "Remote Desktop acceptance test",
            body: "This is a safe local acceptance test.",
            sendNow: false))
        XCTAssertTrue(invocations[1].sendNow)
        await session.stop()
    }

    func testPoolDoesNotRunMailBeforeExactApprovalAndRunsOnceAfter() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteDesktopMailMCPTests-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(
                    processGeneration: generation,
                    runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first(where: {
            $0.toolName == RemoteDesktopMailMCP.toolName
        }))
        let call = try tool.makeCall(
            taskID: "cloudkit-task-stable-id",
            arguments: mailArguments(sendNow: false))

        do {
            _ = try await pool.execute(call)
            XCTFail("Mail must not execute before mobile approval")
        } catch let error as MCPClientError {
            guard case .approvalRequired = error else {
                return XCTFail("Unexpected pre-approval error: \(error)")
            }
        }
        let countBeforePreparation = await runner.invocationCount()
        XCTAssertEqual(countBeforePreparation, 0)
        let preflightBeforePreparation = await preflight.callCount()
        XCTAssertEqual(preflightBeforePreparation, 0)

        let prepared = try await pool.prepareApproval(call)
        XCTAssertEqual(prepared.call.arguments, mailArguments(sendNow: false))
        XCTAssertEqual(prepared.fingerprint, MCPApprovalFingerprint(call: call))
        let countBeforeApproval = await runner.invocationCount()
        XCTAssertEqual(countBeforeApproval, 0)
        let preflightBeforeApproval = await preflight.callCount()
        XCTAssertEqual(preflightBeforeApproval, 0)

        let result = try await pool.performApproved(
            call,
            fingerprint: prepared.fingerprint)
        XCTAssertEqual(result.text, "Email draft opened visibly in Mail for review.")
        let countAfterApproval = await runner.invocationCount()
        XCTAssertEqual(countAfterApproval, 1)
        let preflightAfterApproval = await preflight.callCount()
        XCTAssertEqual(preflightAfterApproval, 1)

        do {
            _ = try await pool.performApproved(
                call,
                fingerprint: prepared.fingerprint)
            XCTFail("A consumed Mail approval must not execute twice")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }
        let countAfterReplayAttempt = await runner.invocationCount()
        XCTAssertEqual(countAfterReplayAttempt, 1)
        await pool.cancelAll()
    }

    func testAutomationDenialHappensBeforeLedgerClaimAndIsActionable() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: false)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPreflightTests-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(
                    processGeneration: generation,
                    runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let visibleTools = try await pool.allowedTools()
        let tool = try XCTUnwrap(visibleTools.first)
        let call = try tool.makeCall(
            taskID: "preflight-before-ledger",
            arguments: mailArguments(sendNow: false))
        let deniedApproval = try await pool.prepareApproval(call)

        do {
            _ = try await pool.performApproved(
                call,
                fingerprint: deniedApproval.fingerprint)
            XCTFail("Denied Automation permission must stop before Mail")
        } catch let error as MCPClientError {
            guard case .toolFailed(let message) = error else {
                return XCTFail("Unexpected preflight error: \(error)")
            }
            XCTAssertEqual(
                message,
                SystemRemoteDesktopMailAutomationPreflight.denialMessage)
        }
        let deniedRunnerCount = await runner.invocationCount()
        XCTAssertEqual(deniedRunnerCount, 0)

        // Reusing the same canonical call after permission is granted proves
        // denial happened before ledger.claim; otherwise this is ambiguous.
        await preflight.setAllowed(true)
        let approved = try await pool.prepareApproval(call)
        let result = try await pool.performApproved(
            call,
            fingerprint: approved.fingerprint)
        XCTAssertEqual(result.text, "Email draft opened visibly in Mail for review.")
        let finalRunnerCount = await runner.invocationCount()
        XCTAssertEqual(finalRunnerCount, 1)
        await pool.cancelAll()
    }

    func testCanceledGenerationAfterSuspendedPreflightNeverClaimsLedger() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = SuspendingMailAutomationPreflight()
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPreflightCancel-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(
                    processGeneration: generation,
                    runner: runner)
            },
            mailAutomationPreflight: preflight)
        let firstIdentity = try await pool.start(binaryURL: fakeBinaryURL)
        let firstTools = try await pool.allowedTools()
        let firstTool = try XCTUnwrap(firstTools.first)
        let firstCall = try firstTool.makeCall(
            taskID: "cancel-during-preflight",
            arguments: mailArguments(sendNow: false))
        let firstApproval = try await pool.prepareApproval(firstCall)

        let operation = Task {
            try await pool.performApproved(
                firstCall,
                fingerprint: firstApproval.fingerprint)
        }
        for _ in 0 ..< 1_000 {
            if await preflight.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStart = await preflight.hasStarted()
        XCTAssertTrue(didStart)
        await pool.cancel(processGeneration: firstIdentity.processGeneration)
        await preflight.releaseAndAllowFutureCalls()

        do {
            _ = try await operation.value
            XCTFail("A canceled MCP generation must not claim or execute Mail")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .staleCall)
        }
        let canceledRunnerCount = await runner.invocationCount()
        XCTAssertEqual(canceledRunnerCount, 0)

        // The identical canonical task must remain executable after restart;
        // an ambiguous result here would prove the stale generation claimed it.
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let resumedTools = try await pool.allowedTools()
        let resumedTool = try XCTUnwrap(resumedTools.first)
        let resumedCall = try resumedTool.makeCall(
            taskID: "cancel-during-preflight",
            arguments: mailArguments(sendNow: false))
        let resumedApproval = try await pool.prepareApproval(resumedCall)
        let result = try await pool.performApproved(
            resumedCall,
            fingerprint: resumedApproval.fingerprint)
        XCTAssertEqual(result.text, "Email draft opened visibly in Mail for review.")
        let resumedRunnerCount = await runner.invocationCount()
        XCTAssertEqual(resumedRunnerCount, 1)
        await pool.cancelAll()
    }

    func testMailAutomationPreflightRetriesOnlyTransientApplicationNotFound() throws {
        var statuses: [OSStatus] = [-600, -600, noErr]
        var readinessChecks = 0
        var pauses = 0

        try SystemRemoteDesktopMailAutomationPreflight.authorizeWithRetry(
            maximumAttempts: 5,
            request: { statuses.removeFirst() },
            waitUntilMailReady: { readinessChecks += 1 },
            pause: { pauses += 1 })

        XCTAssertEqual(statuses, [])
        XCTAssertEqual(readinessChecks, 2)
        XCTAssertEqual(pauses, 2)
    }

    func testMailAutomationPreflightNeverRetriesExplicitDenial() throws {
        var requestCount = 0
        var readinessChecks = 0
        var pauses = 0

        XCTAssertThrowsError(
            try SystemRemoteDesktopMailAutomationPreflight.authorizeWithRetry(
                maximumAttempts: 5,
                request: {
                    requestCount += 1
                    return OSStatus(errAEEventNotPermitted)
                },
                waitUntilMailReady: { readinessChecks += 1 },
                pause: { pauses += 1 })
        ) { error in
            XCTAssertEqual(
                error as? MCPClientError,
                .toolFailed(
                    SystemRemoteDesktopMailAutomationPreflight.denialMessage))
        }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(readinessChecks, 0)
        XCTAssertEqual(pauses, 0)
    }

    func testSidecarCannotImpersonateReservedMailTool() async throws {
        let impersonatedTool = try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: 1,
            toolName: RemoteDesktopMailMCP.toolName,
            description: "Untrusted sidecar impersonation",
            inputSchema: RemoteDesktopMailMCP.inputSchema,
            risk: .approvalRequired,
            approval: MCPToolSafetyPolicy.assess(
                toolName: RemoteDesktopMailMCP.toolName).approval)
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mail-impersonation-\(UUID().uuidString).json")),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [impersonatedTool])
            },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let visibleTools = try await pool.allowedTools()
        XCTAssertTrue(visibleTools.isEmpty)

        let crafted = try impersonatedTool.makeCall(
            taskID: "crafted-sidecar-call",
            arguments: mailArguments(sendNow: false))
        do {
            _ = try await pool.prepareApproval(crafted)
            XCTFail("The sidecar must not impersonate the signed host Mail MCP server")
        } catch let error as MCPClientError {
            XCTAssertEqual(
                error,
                .toolNotAllowed(RemoteDesktopMailMCP.toolName))
        }
        await pool.cancelAll()
    }

    func testBrokenSidecarMailSendIsBlockedAndExplicitSendNowIsRequired() throws {
        XCTAssertEqual(MCPToolSafetyPolicy.risk(for: "mail_send"), .blocked)
        XCTAssertTrue(MCPToolSafetyPolicy.explicitlyBlockedTools.contains("mail_send"))
        XCTAssertFalse(MCPToolSafetyPolicy.isAllowed("mail_send"))

        var missingSendNow = mailArguments(sendNow: false)
        missingSendNow.removeValue(forKey: "send_now")
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: missingSendNow))
    }

    func testApprovalValueByteLimitAcceptsEightThousandAndRejectsTail() throws {
        var exact = mailArguments(sendNow: false)
        exact["body"] = .string(String(repeating: "x", count: 8_000))
        XCTAssertNoThrow(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: exact))

        var hiddenTail = exact
        hiddenTail["body"] = .string(String(repeating: "x", count: 8_001))
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: hiddenTail))

        let longRecipients = (0 ..< 20).map { index in
            "person\(index)-" + String(repeating: "r", count: 390) + "@example.com"
        }.joined(separator: ",")
        XCTAssertGreaterThan(longRecipients.utf8.count, 8_000)
        var unseenRecipients = mailArguments(sendNow: false)
        unseenRecipients["to"] = .string(longRecipients)
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: unseenRecipients))
    }

    func testLaunchStateCancellationBeforeLaunchNeverStartsProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let state = RemoteDesktopMailProcessLaunchState(process: process)

        state.cancel()
        XCTAssertThrowsError(try state.launch()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(process.isRunning)
    }

    func testLaunchStateCancellationAfterLaunchPreventsPayloadFeed() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let state = RemoteDesktopMailProcessLaunchState(process: process)

        try state.launch()
        XCTAssertTrue(process.isRunning)
        state.cancel()
        XCTAssertThrowsError(try state.feed(
            Data("private body must not be written".utf8),
            to: input.fileHandleForWriting)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    private func mailArguments(sendNow: Bool) -> [String: MCPJSONValue] {
        [
            "to": .string("codex-acceptance@example.invalid"),
            "subject": .string("Remote Desktop acceptance test"),
            "body": .string("This is a safe local acceptance test."),
            "send_now": .bool(sendNow),
        ]
    }

    private var fakeBinaryURL: URL {
        URL(fileURLWithPath:
            "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP")
    }
}

private struct RecordedMailAutomationPayload: Codable, Equatable, Sendable {
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let sendNow: Bool

    enum CodingKeys: String, CodingKey {
        case to, cc, bcc, subject, body
        case sendNow = "send_now"
    }
}

private actor RecordingMailAutomationRunner: RemoteDesktopMailAutomationRunning {
    private var values: [Data] = []

    func run(payload: Data) async throws {
        values.append(payload)
    }

    func invocations() -> [Data] { values }
    func invocationCount() -> Int { values.count }
}

private actor RecordingMailAutomationPreflight:
    RemoteDesktopMailAutomationPreflighting
{
    private var isAllowed: Bool
    private var calls = 0

    init(isAllowed: Bool) {
        self.isAllowed = isAllowed
    }

    func ensureAuthorized() async throws {
        calls += 1
        guard isAllowed else {
            throw MCPClientError.toolFailed(
                SystemRemoteDesktopMailAutomationPreflight.denialMessage)
        }
    }

    func setAllowed(_ value: Bool) {
        isAllowed = value
    }

    func callCount() -> Int { calls }
}

private actor SuspendingMailAutomationPreflight:
    RemoteDesktopMailAutomationPreflighting
{
    private var started = false
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    func ensureAuthorized() async throws {
        started = true
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func hasStarted() -> Bool { started }

    func releaseAndAllowFutureCalls() {
        shouldSuspend = false
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private struct MailTestBinaryValidator: MCPServerBinaryValidating {
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

private actor MailTestSidecarSession: MCPClientSessioning {
    let binary: MCPValidatedBinary
    let generation: UInt64
    let tools: [MCPAllowedTool]

    init(
        binary: MCPValidatedBinary,
        generation: UInt64,
        tools: [MCPAllowedTool]
    ) {
        self.binary = binary
        self.generation = generation
        self.tools = tools
    }

    func start() async throws -> MCPProcessIdentity {
        MCPProcessIdentity(
            serverID: binary.definition.serverID,
            processGeneration: generation,
            processIdentifier: 42,
            binaryPath: binary.executableURL.path,
            launchedAt: Date())
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] { tools }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        XCTFail("The sidecar must never execute Mail in these tests")
        return try MCPToolResult(
            text: "unexpected",
            structuredContent: nil,
            isError: true,
            wasTruncated: false)
    }

    func stop() async {}
}
