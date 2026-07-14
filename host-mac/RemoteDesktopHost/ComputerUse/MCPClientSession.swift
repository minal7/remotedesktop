import Foundation
import MCP
import SystemPackage
#if canImport(Darwin)
import Darwin
#endif

protocol MCPClientSessioning: Sendable {
    func start() async throws -> MCPProcessIdentity
    func listAllowedTools() async throws -> [MCPAllowedTool]
    func execute(_ call: MCPToolCall) async throws -> MCPToolResult
    func stop() async
}

enum MCPToolPagination {
    static let maximumPages = 64
    static let maximumTools = 512

    static func collect<Element: Sendable>(
        page: (String?) async throws -> (items: [Element], nextCursor: String?)
    ) async throws -> [Element] {
        var cursor: String?
        var seenCursors = Set<String>()
        var result: [Element] = []

        for _ in 0 ..< maximumPages {
            let response = try await page(cursor)
            result.append(contentsOf: response.items)
            guard result.count <= maximumTools else {
                throw MCPClientError.serverMismatch(
                    "The server advertised more than \(maximumTools) tools.")
            }

            guard let nextCursor = response.nextCursor else { return result }
            guard !nextCursor.isEmpty,
                  nextCursor != cursor,
                  seenCursors.insert(nextCursor).inserted else {
                throw MCPClientError.paginationLoop
            }
            cursor = nextCursor
        }

        throw MCPClientError.paginationLoop
    }
}

actor MCPClientSession: MCPClientSessioning {
    private let validatedBinary: MCPValidatedBinary
    private let processGeneration: UInt64
    private let stateDirectory: URL

    private var process: Process?
    private var serverInput: Pipe?
    private var serverOutput: Pipe?
    private var client: Client?
    private var transport: StdioTransport?
    private var identity: MCPProcessIdentity?
    private var isStopping = false

    init(
        validatedBinary: MCPValidatedBinary,
        processGeneration: UInt64,
        stateDirectory: URL = MCPClientSession.defaultStateDirectory
    ) {
        self.validatedBinary = validatedBinary
        self.processGeneration = processGeneration
        self.stateDirectory = stateDirectory
    }

    static var defaultStateDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Model", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("mac-control-mcp", isDirectory: true)
            .appendingPathComponent("State", isDirectory: true)
    }

    func start() async throws -> MCPProcessIdentity {
        if let identity, process?.isRunning == true { return identity }
        guard process == nil, client == nil else {
            throw MCPClientError.transport("The previous MCP session has not stopped cleanly.")
        }

        do {
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true)

            let process = Process()
            let serverInput = Pipe()
            let serverOutput = Pipe()
            let client = Client(
                name: "RemoteDesktopHost",
                version: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                capabilities: .init(),
                configuration: .strict)

            process.executableURL = validatedBinary.executableURL
            process.arguments = []
            let environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": FileManager.default.temporaryDirectory.path,
                "MAC_CONTROL_MCP_HOME": stateDirectory.standardizedFileURL.path,
                // The sidecar's optional tier system requires request_access
                // grants, but that broad grant-management surface is deliberately
                // not exposed. The host's narrower per-call allowlist, schema,
                // approval fingerprint, and mutation ledger are authoritative.
                "MAC_CONTROL_MCP_ENFORCE_TIERS": "0",
            ]
            process.environment = environment
            process.standardInput = serverInput
            process.standardOutput = serverOutput
            // Server stderr may contain app/window details. Do not retain it,
            // and avoid a pipe that can fill and deadlock the sidecar.
            process.standardError = FileHandle.nullDevice

            let transport = StdioTransport(
                input: .init(rawValue: serverOutput.fileHandleForReading.fileDescriptor),
                output: .init(rawValue: serverInput.fileHandleForWriting.fileDescriptor))

            self.process = process
            self.serverInput = serverInput
            self.serverOutput = serverOutput
            self.client = client
            self.transport = transport

            process.terminationHandler = { [weak self] _ in
                Task { await self?.sidecarDidExit() }
            }
            try process.run()

            let identity = MCPProcessIdentity(
                serverID: validatedBinary.definition.serverID,
                processGeneration: processGeneration,
                processIdentifier: process.processIdentifier,
                binaryPath: validatedBinary.executableURL.path,
                launchedAt: Date())
            self.identity = identity

            let initialization = try await client.connect(transport: transport)
            let definition = validatedBinary.definition
            guard initialization.serverInfo.name == definition.expectedServerName,
                  initialization.serverInfo.version == definition.expectedServerVersion,
                  initialization.protocolVersion == definition.expectedProtocolVersion else {
                await stop()
                throw MCPClientError.serverMismatch(
                    "Expected \(definition.expectedServerName) \(definition.expectedServerVersion) using protocol \(definition.expectedProtocolVersion).")
            }
            return identity
        } catch let error as MCPClientError {
            await stop()
            throw error
        } catch is CancellationError {
            await stop()
            throw MCPClientError.cancelled
        } catch {
            await stop()
            throw MCPClientError.transport(Self.safeErrorDescription(error))
        }
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] {
        guard let client, let identity, process?.isRunning == true else {
            throw MCPClientError.notRunning
        }

        do {
            let advertised = try await MCPToolPagination.collect { cursor in
                let response = try await client.listTools(cursor: cursor)
                return (response.tools, response.nextCursor)
            }

            var seenNames = Set<String>()
            var allowed: [MCPAllowedTool] = []
            for tool in advertised {
                guard seenNames.insert(tool.name).inserted else {
                    throw MCPClientError.serverMismatch(
                        "The server advertised the duplicate tool \(tool.name).")
                }
                guard MCPToolSafetyPolicy.isAllowed(tool.name) else { continue }

                let schema = try MCPJSONValue(mcpValue: tool.inputSchema)
                guard case .object = schema else {
                    throw MCPClientError.serverMismatch(
                        "The allowed tool \(tool.name) advertised a non-object schema.")
                }
                let assessment = MCPToolSafetyPolicy.assess(toolName: tool.name)
                allowed.append(try MCPAllowedTool(
                    serverID: identity.serverID,
                    processGeneration: identity.processGeneration,
                    toolName: tool.name,
                    description: Self.reviewedDescription(for: tool.name),
                    inputSchema: schema,
                    risk: assessment.risk,
                    approval: assessment.approval))
            }
            return allowed.sorted { $0.toolName < $1.toolName }
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            await stop()
            throw MCPClientError.cancelled
        } catch {
            throw MCPClientError.transport(Self.safeErrorDescription(error))
        }
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        guard let client, let identity, process?.isRunning == true else {
            throw MCPClientError.notRunning
        }
        guard call.serverID == identity.serverID,
              call.processGeneration == identity.processGeneration else {
            throw MCPClientError.staleCall
        }

        do {
            let request: RequestContext<CallTool.Result> = try await client.callTool(
                name: call.toolName,
                arguments: try call.arguments.mapValues { try $0.mcpValue })

            return try await withTaskCancellationHandler {
                let result = try await request.value
                return try MCPToolOutputSanitizer.sanitize(result: result, call: call)
            } onCancel: { [weak self] in
                Task {
                    try? await client.cancelRequest(
                        request.requestID,
                        reason: "The user canceled the remote computer action.")
                    await self?.stop()
                }
            }
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            await stop()
            throw MCPClientError.cancelled
        } catch {
            throw MCPClientError.transport(Self.safeErrorDescription(error))
        }
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true

        let client = self.client
        let process = self.process
        process?.terminationHandler = nil

        self.client = nil
        self.transport = nil
        self.identity = nil
        self.process = nil

        await client?.disconnect()
        try? serverInput?.fileHandleForWriting.close()
        try? serverOutput?.fileHandleForReading.close()
        serverInput = nil
        serverOutput = nil

        if let process, process.isRunning {
            process.terminate()
            // Escalate only the child sidecar if it ignored SIGTERM. Never
            // signal a PID that no longer belongs to our live Process object.
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        isStopping = false
    }

    private func sidecarDidExit() async {
        guard !isStopping else { return }
        await client?.disconnect()
        client = nil
        transport = nil
        identity = nil
        process = nil
        try? serverInput?.fileHandleForWriting.close()
        try? serverOutput?.fileHandleForReading.close()
        serverInput = nil
        serverOutput = nil
    }

    private static func reviewedDescription(for toolName: String) -> String {
        switch toolName {
        case "calendar_create_event":
            return "Create a Calendar event using a title plus ISO-8601 start and end values."
        case "calendar_list_events":
            return "List upcoming Calendar events for a bounded number of days."
        case "reminders_create":
            return "Create a reminder with an optional due date and list."
        case "reminders_list":
            return "List reminders with bounded completion and count options."
        case "contacts_search":
            return "Search Contacts by a name substring."
        case "list_shortcuts":
            return "List available Apple Shortcuts names."
        case "run_shortcut":
            return "Run one Apple Shortcut by exact name with optional private input."
        case "type_text":
            return "Enter text in the currently focused field."
        case "click":
            return "Click a typed accessibility target or explicit screen coordinate."
        case "press_key":
            return "Press one named keyboard key with optional modifiers."
        case let name where name.hasPrefix("browser_"):
            return "Use the reviewed typed browser operation \(name). Arbitrary JavaScript is unavailable."
        default:
            return "Use the reviewed typed macOS accessibility operation \(toolName)."
        }
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        String(String(describing: error).prefix(400))
    }
}

enum MCPToolOutputSanitizer {
    static let maximumTextBytes = 24 * 1_024
    static let maximumStructuredBytes = 8 * 1_024

    static func sanitize(
        result: CallTool.Result,
        call: MCPToolCall
    ) throws -> MCPToolResult {
        var fragments: [String] = []
        for content in result.content {
            switch content {
            case .text(let text, _, _):
                fragments.append(text)
            case .image(_, let mimeType, _, _):
                fragments.append("[Binary image output omitted: \(mimeType)]")
            case .audio(_, let mimeType, _, _):
                fragments.append("[Binary audio output omitted: \(mimeType)]")
            case .resource:
                fragments.append("[Embedded resource output omitted]")
            case .resourceLink:
                fragments.append("[Resource link output omitted]")
            }
        }

        let sanitizedText = sanitizeText(
            fragments.joined(separator: "\n"),
            call: call)
        let text = sanitizedText.text

        let decodedStructured = try result.structuredContent.map(
            MCPJSONValue.init(mcpValue:))
        let sanitizedStructured = try sanitizeStructured(
            decodedStructured,
            call: call)

        return try MCPToolResult(
            text: text,
            structuredContent: sanitizedStructured.value,
            isError: result.isError ?? false,
            wasTruncated: sanitizedText.wasTruncated
                || sanitizedStructured.wasTruncated)
    }

    static func sanitizeText(
        _ rawText: String,
        call: MCPToolCall
    ) -> (text: String, wasTruncated: Bool) {
        var text = rawText
        for secret in sensitiveInputStrings(call) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
        }

        if text.utf8.count > maximumTextBytes {
            let suffix = "\n[Output truncated by host]"
            text = truncate(
                text,
                maximumBytes: maximumTextBytes - suffix.utf8.count) + suffix
            return (text, true)
        }
        return (text, false)
    }

    static func sanitizeStructured(
        _ rawValue: MCPJSONValue?,
        call: MCPToolCall
    ) throws -> (value: MCPJSONValue?, wasTruncated: Bool) {
        var structured = rawValue
        if let value = structured {
            structured = redact(value, for: call)
            if try MCPDigest.canonicalData(for: structured ?? .null).count
                > maximumStructuredBytes {
                structured = .object([
                    "notice": .string("Structured MCP output exceeded the host limit and was omitted."),
                ])
                return (structured, true)
            }
        }
        return (structured, false)
    }

    private static func sensitiveInputStrings(_ call: MCPToolCall) -> [String] {
        let sensitiveKeys: Set<String>
        switch call.toolName {
        case "type_text": sensitiveKeys = ["text"]
        case RemoteDesktopMailMCP.toolName: sensitiveKeys = ["body"]
        case "run_shortcut": sensitiveKeys = ["input"]
        case "set_element_attribute": sensitiveKeys = ["value"]
        default: sensitiveKeys = []
        }
        return sensitiveKeys.compactMap { key in
            guard case .string(let value) = call.arguments[key] else { return nil }
            return value
        }
    }

    private static func redact(
        _ value: MCPJSONValue,
        for call: MCPToolCall,
        key: String? = nil
    ) -> MCPJSONValue {
        let normalizedKey = key?.lowercased() ?? ""
        let alwaysSensitive = [
            "authorization", "cookie", "password", "secret", "token",
        ].contains { normalizedKey.contains($0) }
        let callSensitive = (call.toolName == "type_text" && normalizedKey == "text")
            || (call.toolName == RemoteDesktopMailMCP.toolName && normalizedKey == "body")
            || (call.toolName == "run_shortcut" && normalizedKey == "input")
        if alwaysSensitive || callSensitive { return .string("[redacted]") }

        switch value {
        case .array(let values):
            return .array(values.map { redact($0, for: call) })
        case .object(let values):
            var redacted: [String: MCPJSONValue] = [:]
            for (childKey, child) in values {
                redacted[childKey] = redact(child, for: call, key: childKey)
            }
            return .object(redacted)
        default:
            return value
        }
    }

    private static func truncate(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var used = 0
        for character in value {
            let count = String(character).utf8.count
            guard used + count <= maximumBytes else { break }
            result.append(character)
            used += count
        }
        return result
    }
}

private extension MCPJSONValue {
    init(mcpValue: Value) throws {
        switch mcpValue {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .integer(value)
        case .double(let value):
            guard value.isFinite else {
                throw MCPClientError.serverMismatch("The server returned a non-finite number.")
            }
            self = .double(value)
        case .string(let value): self = .string(value)
        case .data(let mimeType, let data):
            self = .string("[Binary data omitted: \(mimeType ?? "unknown type"), \(data.count) bytes]")
        case .array(let values):
            self = .array(try values.map { try Self(mcpValue: $0) })
        case .object(let values):
            self = .object(try values.mapValues { try Self(mcpValue: $0) })
        }
    }

    var mcpValue: Value {
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
            case .array(let values): return .array(try values.map { try $0.mcpValue })
            case .object(let values): return .object(try values.mapValues { try $0.mcpValue })
            }
        }
    }
}
