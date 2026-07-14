import Foundation
import MCP
#if canImport(Darwin)
import Darwin
#endif

/// The Mail capability is compiled into the signed host and connected through
/// the official Swift MCP SDK's in-memory transport. It does not inherit shell
/// state, open a listener, contact a remote service, or require an API key.
enum RemoteDesktopMailMCP {
    static let serverID = "com.threadmark.remotedesktop.host.mail-mcp"
    static let serverName = "remote-desktop-mail"
    static let serverVersion = "1.0.0"
    static let toolName = "remote_desktop_mail"

    static let reviewedDescription = """
    Create a visible email draft in Apple Mail, or send it after explicit user approval. \
    Recipients are comma, semicolon, or newline separated. Set send_now to false to open \
    a draft for review, or true only when the user explicitly asked to send now. Mail uses \
    the user's default sending account; this tool does not silently select another account.
    """

    static let inputSchema: MCPJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "to": .object([
                "type": .string("string"),
                "description": .string("Required To recipients, separated by commas, semicolons, or newlines."),
            ]),
            "cc": .object([
                "type": .string("string"),
                "description": .string("Optional CC recipients, separated by commas, semicolons, or newlines."),
            ]),
            "bcc": .object([
                "type": .string("string"),
                "description": .string("Optional BCC recipients, separated by commas, semicolons, or newlines."),
            ]),
            "subject": .object([
                "type": .string("string"),
                "description": .string("The exact email subject."),
            ]),
            "body": .object([
                "type": .string("string"),
                "description": .string("The exact plain-text email body."),
            ]),
            "send_now": .object([
                "type": .string("boolean"),
                "description": .string("False opens a visible draft; true sends only after explicit approval."),
            ]),
        ]),
        "required": .array([
            .string("to"),
            .string("subject"),
            .string("body"),
            .string("send_now"),
        ]),
        "additionalProperties": .bool(false),
    ])
}

struct RemoteDesktopMailRequest: Equatable, Sendable {
    static let maximumRecipientsPerField = 100
    static let maximumRecipientBytes = 512
    static let maximumApprovalValueBytes = 8_000
    static let maximumSubjectBytes = 4 * 1_024
    static let maximumBodyBytes = maximumApprovalValueBytes

    let to: String
    let cc: String
    let bcc: String
    let subject: String
    let body: String
    let sendNow: Bool

    init(arguments: [String: MCPJSONValue]) throws {
        let allowed = Set(["to", "cc", "bcc", "subject", "body", "send_now"])
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MCPClientError.invalidArguments(
                "The Mail request contains unknown fields: \(unknown.sorted().joined(separator: ", ")).")
        }
        guard case .string(let to)? = arguments["to"],
              case .string(let subject)? = arguments["subject"],
              case .string(let body)? = arguments["body"],
              case .bool(let sendNow)? = arguments["send_now"] else {
            throw MCPClientError.invalidArguments(
                "Mail requires string to, subject, and body fields plus an explicit send_now boolean.")
        }
        let cc = try Self.optionalString(arguments["cc"], name: "cc")
        let bcc = try Self.optionalString(arguments["bcc"], name: "bcc")

        _ = try Self.recipients(in: to, required: true, field: "to")
        _ = try Self.recipients(in: cc, required: false, field: "cc")
        _ = try Self.recipients(in: bcc, required: false, field: "bcc")
        guard subject.utf8.count <= Self.maximumSubjectBytes,
              !subject.contains("\0"),
              !subject.contains("\r"),
              !subject.contains("\n") else {
            throw MCPClientError.invalidArguments(
                "The Mail subject is too long or contains an unsupported control character.")
        }
        guard body.utf8.count <= Self.maximumBodyBytes,
              !body.contains("\0") else {
            throw MCPClientError.invalidArguments(
                "The Mail body is too long or contains an unsupported null character.")
        }

        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.sendNow = sendNow
    }

    /// The fixed JXA program receives one bounded JSON value over stdin.
    /// Message content therefore never appears in source, argv, environment,
    /// or a temporary file where another same-user process could inspect it.
    func automationPayload() throws -> Data {
        try JSONEncoder().encode(AutomationPayload(
            to: try Self.recipients(in: to, required: true, field: "to"),
            cc: try Self.recipients(in: cc, required: false, field: "cc"),
            bcc: try Self.recipients(in: bcc, required: false, field: "bcc"),
            subject: subject,
            body: body,
            sendNow: sendNow))
    }

    private struct AutomationPayload: Codable {
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

    private static func optionalString(
        _ value: MCPJSONValue?,
        name: String
    ) throws -> String {
        guard let value else { return "" }
        guard case .string(let string) = value else {
            throw MCPClientError.invalidArguments("Mail field \(name) must be a string.")
        }
        return string
    }

    private static func recipients(
        in value: String,
        required: Bool,
        field: String
    ) throws -> [String] {
        guard value.utf8.count <= maximumApprovalValueBytes else {
            throw MCPClientError.invalidArguments(
                "Mail field \(field) exceeds the exact mobile approval limit.")
        }
        let separators = CharacterSet(charactersIn: ",;\n")
        let recipients = value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !required || !recipients.isEmpty else {
            throw MCPClientError.invalidArguments(
                "Mail requires at least one To recipient.")
        }
        guard recipients.count <= maximumRecipientsPerField else {
            throw MCPClientError.invalidArguments(
                "Mail field \(field) contains too many recipients.")
        }
        for recipient in recipients {
            guard recipient.utf8.count <= maximumRecipientBytes,
                  !recipient.contains("\0"),
                  !recipient.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw MCPClientError.invalidArguments(
                    "Mail field \(field) contains an invalid recipient.")
            }
        }
        return recipients
    }
}

protocol RemoteDesktopMailAutomationRunning: Sendable {
    func run(payload: Data) async throws
}

/// Only this fixed JXA source is executable. User/model values arrive as a
/// bounded JSON object on stdin and are never concatenated into source/argv.
enum RemoteDesktopMailJXA {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

    static let source = #"""
    ObjC.import('Foundation');

    function readRequest() {
        const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
        const text = ObjC.unwrap(
            $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)
        );
        return JSON.parse(text);
    }

    function run() {
        const request = readRequest();
        const mail = Application('Mail');
        mail.activate();

        const outgoingMessage = mail.OutgoingMessage({
            subject: request.subject,
            content: request.body,
            visible: true
        });
        mail.outgoingMessages.push(outgoingMessage);

        // The approved body is exact: never append a configured Mail signature.
        outgoingMessage.messageSignature = null;
        request.to.forEach(address =>
            outgoingMessage.toRecipients.push(mail.ToRecipient({address: address}))
        );
        request.cc.forEach(address =>
            outgoingMessage.ccRecipients.push(mail.CcRecipient({address: address}))
        );
        request.bcc.forEach(address =>
            outgoingMessage.bccRecipients.push(mail.BccRecipient({address: address}))
        );
        outgoingMessage.visible = true;

        if (request.send_now) {
            // Keep the app whose approved action is executing in front. Mail's
            // activation is asynchronous; without a short yield, a fast send
            // can create and close the compose window before macOS switches
            // away from an unrelated previously focused app.
            mail.activate();
            $.NSThread.sleepForTimeInterval(0.2);
            const sentSuccessfully = outgoingMessage.send();
            if (sentSuccessfully !== true) {
                throw new Error('Mail rejected the send command');
            }
            mail.activate();
        } else {
            mail.activate();
        }
    }
    """#

    static let processArguments = ["-l", "JavaScript", "-e", source]
}

actor SystemRemoteDesktopMailAutomationRunner: RemoteDesktopMailAutomationRunning {
    private var activeProcess: Process?

    func run(payload: Data) async throws {
        guard activeProcess == nil else {
            throw MCPClientError.toolFailed("Another local Mail action is already running.")
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = RemoteDesktopMailJXA.executableURL
        process.arguments = RemoteDesktopMailJXA.processArguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        let standardInput = Pipe()
        process.standardInput = standardInput
        // The fixed script emits no useful content. Avoid retaining addresses,
        // subject text, body text, or Mail diagnostics in host logs.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        activeProcess = process
        let termination = RemoteDesktopMailProcessTermination()
        let launchState = RemoteDesktopMailProcessLaunchState(process: process)
        process.terminationHandler = { completed in
            termination.finish(completed.terminationStatus)
        }
        defer {
            if activeProcess === process { activeProcess = nil }
            process.terminationHandler = nil
            try? standardInput.fileHandleForWriting.close()
        }

        // The cancellation callback operates on a lock-backed launch state
        // directly, without waiting for another actor hop. Launch and stdin
        // feed are separate linearized phases: cancellation before feed keeps
        // the child blocked without private data and prevents the Mail action.
        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try launchState.launch()
                try Task.checkCancellation()
                try launchState.feed(
                    payload,
                    to: standardInput.fileHandleForWriting)
                return await termination.value()
            } onCancel: {
                launchState.cancel()
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw MCPClientError.toolFailed(
                "Mail did not accept the local automation action (status \(status)).")
        }
    }

}

/// Synchronizes cancellation with the two consequential process phases.
/// Holding the lock across `Process.run()` prevents the classic check/launch
/// race; holding it across the small bounded stdin write defines feed as the
/// mutation's commit point.
final class RemoteDesktopMailProcessLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var isCancelled = false
    private var didLaunch = false
    private var didFeed = false

    init(process: Process) {
        self.process = process
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        try process.run()
        didLaunch = true
    }

    func feed(_ payload: Data, to input: FileHandle) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, didLaunch, !didFeed else {
            throw CancellationError()
        }
        try input.write(contentsOf: payload)
        try input.close()
        didFeed = true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let shouldTerminate = didLaunch && process.isRunning
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }
}

private final class RemoteDesktopMailProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            self.status = status
            lock.unlock()
        }
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private actor RemoteDesktopMailMCPHandler {
    let runner: any RemoteDesktopMailAutomationRunning

    init(runner: any RemoteDesktopMailAutomationRunning) {
        self.runner = runner
    }

    func call(_ request: CallTool.Parameters) async -> CallTool.Result {
        guard request.name == RemoteDesktopMailMCP.toolName else {
            return Self.failure("The requested local Mail tool is unavailable.")
        }

        do {
            let arguments = try (request.arguments ?? [:]).mapValues {
                try MCPJSONValue(remoteDesktopMailValue: $0)
            }
            let mail = try RemoteDesktopMailRequest(arguments: arguments)
            try await runner.run(payload: try mail.automationPayload())
            let message = mail.sendNow
                ? "Mail accepted the approved email for sending."
                : "Email draft opened visibly in Mail for review."
            return CallTool.Result(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "status": .string(
                        mail.sendNow ? "accepted_for_sending" : "draft_opened"),
                ]),
                isError: false)
        } catch is CancellationError {
            return Self.failure("The local Mail action was canceled.")
        } catch {
            // Never return arguments or AppleScript diagnostics because they
            // may contain private message content.
            return Self.failure("Mail could not complete the approved local action.")
        }
    }

    private static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true)
    }
}

/// A normal MCP client session backed by a normal MCP server, joined with an
/// `InMemoryTransport` pair. Keeping the full protocol roundtrip makes local
/// tools obey the same discovery/call boundary as the signed sidecar tools.
actor RemoteDesktopMailMCPClientSession: MCPClientSessioning {
    private let processGeneration: UInt64
    private let runner: any RemoteDesktopMailAutomationRunning

    private var server: Server?
    private var client: Client?
    private var clientTransport: InMemoryTransport?
    private var serverTransport: InMemoryTransport?
    private var identity: MCPProcessIdentity?

    init(
        processGeneration: UInt64,
        runner: any RemoteDesktopMailAutomationRunning =
            SystemRemoteDesktopMailAutomationRunner()
    ) {
        self.processGeneration = processGeneration
        self.runner = runner
    }

    func start() async throws -> MCPProcessIdentity {
        if let identity, client != nil, server != nil { return identity }
        guard client == nil, server == nil else {
            throw MCPClientError.transport(
                "The previous embedded Mail MCP session did not stop cleanly.")
        }

        let transports = await InMemoryTransport.createConnectedPair()
        let handler = RemoteDesktopMailMCPHandler(runner: runner)
        let server = Server(
            name: RemoteDesktopMailMCP.serverName,
            version: RemoteDesktopMailMCP.serverVersion,
            capabilities: .init(tools: .init()),
            configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [Tool(
                name: RemoteDesktopMailMCP.toolName,
                description: RemoteDesktopMailMCP.reviewedDescription,
                inputSchema: try RemoteDesktopMailMCP.inputSchema.remoteDesktopMailMCPValue,
                annotations: .init(
                    title: "Mail on this Mac",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: true),
            )])
        }
        await server.withMethodHandler(CallTool.self) { request in
            await handler.call(request)
        }
        let client = Client(
            name: "RemoteDesktopHost",
            version: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            capabilities: .init(),
            configuration: .strict)

        self.server = server
        self.client = client
        clientTransport = transports.client
        serverTransport = transports.server

        do {
            try await server.start(transport: transports.server)
            let initialization = try await client.connect(transport: transports.client)
            guard initialization.serverInfo.name == RemoteDesktopMailMCP.serverName,
                  initialization.serverInfo.version == RemoteDesktopMailMCP.serverVersion,
                  initialization.capabilities.tools != nil else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server identity did not match the signed host.")
            }
            let identity = MCPProcessIdentity(
                serverID: RemoteDesktopMailMCP.serverID,
                processGeneration: processGeneration,
                processIdentifier: getpid(),
                binaryPath: Bundle.main.executableURL?.path
                    ?? ProcessInfo.processInfo.arguments.first ?? "",
                launchedAt: Date())
            self.identity = identity
            return identity
        } catch let error as MCPClientError {
            await stop()
            throw error
        } catch is CancellationError {
            await stop()
            throw MCPClientError.cancelled
        } catch {
            await stop()
            throw MCPClientError.transport(
                String(String(describing: error).prefix(400)))
        }
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] {
        guard let client, let identity else { throw MCPClientError.notRunning }
        do {
            let response = try await client.listTools()
            guard response.tools.count == 1,
                  response.nextCursor == nil,
                  let tool = response.tools.first,
                  tool.name == RemoteDesktopMailMCP.toolName else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server advertised an unexpected tool set.")
            }
            let schema = try MCPJSONValue(remoteDesktopMailValue: tool.inputSchema)
            guard schema == RemoteDesktopMailMCP.inputSchema else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP schema did not match the signed host contract.")
            }
            let assessment = MCPToolSafetyPolicy.assess(toolName: tool.name)
            guard assessment.risk == .approvalRequired else {
                throw MCPClientError.toolNotAllowed(tool.name)
            }
            return [try MCPAllowedTool(
                serverID: identity.serverID,
                processGeneration: identity.processGeneration,
                toolName: tool.name,
                description: RemoteDesktopMailMCP.reviewedDescription,
                inputSchema: schema,
                risk: assessment.risk,
                approval: assessment.approval)]
        } catch let error as MCPClientError {
            throw error
        } catch {
            throw MCPClientError.transport(
                String(String(describing: error).prefix(400)))
        }
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        guard let client, let identity else { throw MCPClientError.notRunning }
        guard call.serverID == identity.serverID,
              call.processGeneration == identity.processGeneration,
              call.toolName == RemoteDesktopMailMCP.toolName else {
            throw MCPClientError.staleCall
        }
        do {
            let request: RequestContext<CallTool.Result> = try await client.callTool(
                name: call.toolName,
                arguments: try call.arguments.mapValues {
                    try $0.remoteDesktopMailMCPValue
                })
            return try await withTaskCancellationHandler {
                let result = try await request.value
                return try MCPToolOutputSanitizer.sanitize(
                    result: result,
                    call: call)
            } onCancel: { [weak self] in
                Task {
                    try? await client.cancelRequest(
                        request.requestID,
                        reason: "The user canceled the local Mail action.")
                    await self?.stop()
                }
            }
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            throw MCPClientError.cancelled
        } catch {
            throw MCPClientError.transport(
                String(String(describing: error).prefix(400)))
        }
    }

    func stop() async {
        let client = self.client
        let server = self.server
        self.client = nil
        self.server = nil
        identity = nil
        clientTransport = nil
        serverTransport = nil
        await client?.disconnect()
        await server?.stop()
    }
}

private extension MCPJSONValue {
    init(remoteDesktopMailValue: Value) throws {
        switch remoteDesktopMailValue {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .integer(value)
        case .double(let value):
            guard value.isFinite else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server returned a non-finite number.")
            }
            self = .double(value)
        case .string(let value): self = .string(value)
        case .data(let mimeType, let data):
            self = .string("[Binary data omitted: \(mimeType ?? "unknown type"), \(data.count) bytes]")
        case .array(let values):
            self = .array(try values.map(Self.init(remoteDesktopMailValue:)))
        case .object(let values):
            self = .object(try values.mapValues(Self.init(remoteDesktopMailValue:)))
        }
    }

    var remoteDesktopMailMCPValue: Value {
        get throws {
            switch self {
            case .null: return .null
            case .bool(let value): return .bool(value)
            case .integer(let value): return .int(value)
            case .double(let value):
                guard value.isFinite else {
                    throw MCPClientError.invalidArguments("Numbers must be finite.")
                }
                return .double(value)
            case .string(let value): return .string(value)
            case .array(let values):
                return .array(try values.map { try $0.remoteDesktopMailMCPValue })
            case .object(let values):
                return .object(try values.mapValues { try $0.remoteDesktopMailMCPValue })
            }
        }
    }
}
