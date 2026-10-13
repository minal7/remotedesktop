import Foundation

typealias MCPClientSessionFactory = @Sendable (
    _ validatedBinary: MCPValidatedBinary,
    _ processGeneration: UInt64
) -> any MCPClientSessioning

actor MCPClientPool {
    private let definition: MCPServerDefinition
    private let binaryValidator: any MCPServerBinaryValidating
    private let mutationLedger: (any MCPMutationCallLedger)?
    private let sessionFactory: MCPClientSessionFactory
    private var session: (any MCPClientSessioning)?
    private var identity: MCPProcessIdentity?
    private var processGeneration: UInt64 = 0
    private var lifecycleEpoch: UInt64 = 0
    private struct PendingApproval {
        let fingerprint: MCPApprovalFingerprint
        let date: Date
    }
    private var pendingApprovals: [String: PendingApproval] = [:]

    init(
        definition: MCPServerDefinition = MCPServerRegistry.macControl,
        binaryValidator: any MCPServerBinaryValidating = SystemMCPServerBinaryValidator(),
        mutationLedger: (any MCPMutationCallLedger)? = MCPFileMutationCallLedger(),
        sessionFactory: @escaping MCPClientSessionFactory = { binary, generation in
            MCPClientSession(
                validatedBinary: binary,
                processGeneration: generation)
        }
    ) {
        precondition(
            MCPServerRegistry.curatedServers.contains(definition),
            "MCPClientPool only accepts a compiled-in curated server.")
        self.definition = definition
        self.binaryValidator = binaryValidator
        self.mutationLedger = mutationLedger
        self.sessionFactory = sessionFactory
    }

    @discardableResult
    func start(binaryURL: URL) async throws -> MCPProcessIdentity {
        try Task.checkCancellation()
        // Claim this attempt before validation can suspend. A late validator
        // must not let an older request replace a newer start or undo Stop.
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        let validated = try await binaryValidator.validate(
            binaryURL: binaryURL,
            definition: definition)
        try requireCurrentStart(epoch)

        processGeneration &+= 1
        if processGeneration == 0 { processGeneration = 1 }
        let generation = processGeneration

        let previous = session
        session = nil
        identity = nil
        pendingApprovals.removeAll()
        await previous?.stop()
        // Retire the exact old session, but do not publish a candidate after
        // another attempt has acquired ownership.
        try requireCurrentStart(epoch)

        let candidate = sessionFactory(validated, generation)
        session = candidate
        do {
            let newIdentity = try await candidate.start()
            try requireCurrentStart(epoch)
            guard newIdentity.serverID == definition.serverID,
                  newIdentity.processGeneration == generation,
                  newIdentity.binaryPath == validated.executableURL.path else {
                throw MCPClientError.cancelled
            }
            identity = newIdentity
            return newIdentity
        } catch {
            // A newer validation attempt can supersede this request without
            // allocating a replacement session. Clear slots still owned by
            // this candidate; never clear a later allocated generation.
            if processGeneration == generation {
                session = nil
                identity = nil
            }
            await candidate.stop()
            throw error
        }
    }

    private func requireCurrentStart(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard lifecycleEpoch == epoch else { throw MCPClientError.cancelled }
    }

    func allowedTools() async throws -> [MCPAllowedTool] {
        guard let session, let identity else { throw MCPClientError.notRunning }
        let generation = identity.processGeneration
        let tools = try await session.listAllowedTools().filter {
            $0.serverID == identity.serverID && MCPToolSafetyPolicy.isAllowed($0.toolName)
        }
        guard self.identity?.processGeneration == generation else {
            throw MCPClientError.staleCall
        }
        guard Set(tools.map(\.toolName)).count == tools.count else {
            throw MCPClientError.serverMismatch(
                "The active MCP servers advertised duplicate tool names.")
        }
        return tools.sorted { $0.toolName < $1.toolName }
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        let (validatedCall, session) = try await validate(call)
        switch validatedCall.risk {
        case .readOnly:
            return try await performReadOnly(validatedCall, using: session)
        case .reversible:
            return try await performMutation(validatedCall, using: session)
        case .approvalRequired:
            throw MCPClientError.approvalRequired(validatedCall.approvalDisplay)
        case .blocked:
            throw MCPClientError.toolNotAllowed(validatedCall.toolName)
        }
    }

    func prepareApproval(_ call: MCPToolCall) async throws -> MCPPreparedApproval {
        let (validatedCall, _) = try await validate(call)
        guard validatedCall.risk == .approvalRequired else {
            throw MCPClientError.invalidArguments(
                "Only approval-required MCP actions can enter the approval flow.")
        }

        purgeExpiredApprovals()
        let fingerprint = MCPApprovalFingerprint(call: validatedCall)
        pendingApprovals[validatedCall.canonicalDigest] = PendingApproval(
            fingerprint: fingerprint, date: Date())
        return MCPPreparedApproval(
            call: validatedCall,
            fingerprint: fingerprint,
            display: validatedCall.approvalDisplay)
    }

    /// Performs only setup checks needed before claiming an approved effect.
    /// The approval remains pending, and no mutation ledger or tool runner is
    /// touched here. The later `performApproved` call repeats every check.
    func preflightApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws {
        try Task.checkCancellation()
        let (validatedCall, _) = try await validate(call)
        guard validatedCall.risk == .approvalRequired,
              fingerprint.matches(call: validatedCall) else {
            throw MCPClientError.approvalMismatch
        }
        _ = try approvedPending(for: validatedCall, fingerprint: fingerprint)
    }

    func performApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws -> MCPToolResult {
        let (validatedCall, session) = try await validate(call)
        guard validatedCall.risk == .approvalRequired,
              fingerprint.matches(call: validatedCall) else {
            throw MCPClientError.approvalMismatch
        }

        purgeExpiredApprovals()
        guard let pending = pendingApprovals[validatedCall.canonicalDigest],
              pending.fingerprint == fingerprint else {
            throw MCPClientError.approvalMismatch
        }
        pendingApprovals.removeValue(forKey: validatedCall.canonicalDigest)
        return try await performMutation(validatedCall, using: session)
    }

    func cancelAll() async {
        lifecycleEpoch &+= 1
        let active = session
        session = nil
        identity = nil
        pendingApprovals.removeAll()
        await active?.stop()
    }

    /// Stops only the sidecar generation owned by the caller. Cancellation
    /// cleanup often crosses an actor hop; by the time it arrives a Resume may
    /// already own a newer process, which must remain running.
    func cancel(processGeneration: UInt64) async {
        guard identity?.processGeneration == processGeneration else { return }
        await cancelAll()
    }

    private func validate(
        _ suppliedCall: MCPToolCall
    ) async throws -> (MCPToolCall, any MCPClientSessioning) {
        guard let rootIdentity = identity else { throw MCPClientError.notRunning }
        guard suppliedCall.serverID == rootIdentity.serverID,
              let session else {
            throw MCPClientError.staleCall
        }
        guard suppliedCall.processGeneration == rootIdentity.processGeneration else {
            throw MCPClientError.staleCall
        }

        let generation = rootIdentity.processGeneration
        let tools = try await session.listAllowedTools()
        guard self.identity?.processGeneration == generation else {
            throw MCPClientError.staleCall
        }
        guard let tool = tools.first(where: { $0.toolName == suppliedCall.toolName }) else {
            throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
        }
        guard tool.serverID == rootIdentity.serverID,
              tool.processGeneration == rootIdentity.processGeneration,
              tool.schemaDigest == suppliedCall.schemaDigest else {
            throw MCPClientError.staleCall
        }

        try MCPJSONSchemaValidator.validate(arguments: suppliedCall.arguments, against: tool.inputSchema)
        let reconstructed = try tool.makeCall(
            taskID: suppliedCall.taskID,
            arguments: suppliedCall.arguments,
            stepEffectID: suppliedCall.stepEffectID)
        guard reconstructed == suppliedCall else {
            throw MCPClientError.invalidArguments(
                "The MCP call metadata does not match its exact arguments and current policy.")
        }
        return (reconstructed, session)
    }

    private func performReadOnly(
        _ call: MCPToolCall,
        using session: any MCPClientSessioning
    ) async throws -> MCPToolResult {
        do {
            let result = try await session.execute(call)
            guard identity?.processGeneration == call.processGeneration else {
                throw MCPClientError.staleCall
            }
            if result.isError {
                throw MCPClientError.toolFailed(Self.boundedFailure(result.text))
            }
            return result
        } catch let error as MCPClientError {
            if case .transport = error {
                await cancel(processGeneration: call.processGeneration)
            }
            throw error
        } catch is CancellationError {
            await cancel(processGeneration: call.processGeneration)
            throw MCPClientError.cancelled
        } catch {
            await cancel(processGeneration: call.processGeneration)
            throw MCPClientError.transport(Self.boundedFailure(String(describing: error)))
        }
    }

    private func performMutation(
        _ call: MCPToolCall,
        using session: any MCPClientSessioning
    ) async throws -> MCPToolResult {
        guard let mutationLedger else {
            throw MCPClientError.mutationLedgerRequired
        }

        switch try await mutationLedger.claim(call) {
        case .completed(let result):
            return result
        case .ambiguous:
            throw MCPClientError.mutationAmbiguous
        case .new:
            break
        }

        do {
            let result = try await session.execute(call)
            guard identity?.processGeneration == call.processGeneration,
                  !result.isError else {
                await mutationLedger.markAmbiguous(call)
                await cancel(processGeneration: call.processGeneration)
                throw MCPClientError.mutationAmbiguous
            }
            do {
                try await mutationLedger.complete(call, result: result)
            } catch {
                await mutationLedger.markAmbiguous(call)
                await cancel(processGeneration: call.processGeneration)
                throw MCPClientError.mutationAmbiguous
            }
            return result
        } catch let error as MCPClientError {
            if error == .mutationAmbiguous { throw error }
            await mutationLedger.markAmbiguous(call)
            await cancel(processGeneration: call.processGeneration)
            throw MCPClientError.mutationAmbiguous
        } catch {
            await mutationLedger.markAmbiguous(call)
            await cancel(processGeneration: call.processGeneration)
            throw MCPClientError.mutationAmbiguous
        }
    }

    private func purgeExpiredApprovals(now: Date = Date()) {
        let maximumAge: TimeInterval = 5 * 60
        pendingApprovals = pendingApprovals.filter {
            now.timeIntervalSince($0.value.date) <= maximumAge
        }
    }

    private func approvedPending(
        for call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) throws -> PendingApproval {
        purgeExpiredApprovals()
        guard call.risk == .approvalRequired,
              fingerprint.matches(call: call),
              let pending = pendingApprovals[call.canonicalDigest],
              pending.fingerprint == fingerprint else {
            throw MCPClientError.approvalMismatch
        }
        return pending
    }

    private static func boundedFailure(_ value: String) -> String {
        String(value.prefix(400))
    }
}

enum MCPJSONSchemaValidator {
    private static let maximumDepth = 16
    private static let maximumCollectionCount = 256
    private static let maximumStringBytes = 32 * 1_024

    static func validate(
        arguments: [String: MCPJSONValue],
        against schema: MCPJSONValue
    ) throws {
        try validateValue(.object(arguments), against: schema, path: "$", depth: 0)
    }

    private static func validateValue(
        _ value: MCPJSONValue,
        against schema: MCPJSONValue,
        path: String,
        depth: Int
    ) throws {
        guard depth <= maximumDepth else {
            throw MCPClientError.invalidArguments("\(path) exceeds the nesting limit.")
        }
        guard case .object(let rules) = schema else {
            throw MCPClientError.invalidArguments("\(path) has an invalid schema.")
        }
        for unsupported in ["$ref", "allOf", "anyOf", "not", "oneOf"]
            where rules[unsupported] != nil {
            throw MCPClientError.invalidArguments(
                "\(path) uses an unsupported schema feature (\(unsupported)).")
        }

        if let allowedTypes = try schemaTypes(rules["type"]),
           !allowedTypes.contains(typeName(of: value)),
           !(typeName(of: value) == "integer" && allowedTypes.contains("number")) {
            throw MCPClientError.invalidArguments(
                "\(path) must be \(allowedTypes.sorted().joined(separator: " or ")).")
        }

        if case .array(let enumValues) = rules["enum"],
           !enumValues.contains(value) {
            throw MCPClientError.invalidArguments("\(path) is not an allowed value.")
        }

        switch value {
        case .string(let string):
            guard string.utf8.count <= maximumStringBytes else {
                throw MCPClientError.invalidArguments("\(path) exceeds the string limit.")
            }
        case .array(let values):
            guard values.count <= maximumCollectionCount else {
                throw MCPClientError.invalidArguments("\(path) contains too many items.")
            }
            if let itemSchema = rules["items"] {
                for (index, child) in values.enumerated() {
                    try validateValue(
                        child,
                        against: itemSchema,
                        path: "\(path)[\(index)]",
                        depth: depth + 1)
                }
            }
        case .object(let object):
            guard object.count <= maximumCollectionCount else {
                throw MCPClientError.invalidArguments("\(path) contains too many fields.")
            }
            let properties: [String: MCPJSONValue]
            if let rawProperties = rules["properties"] {
                guard case .object(let decoded) = rawProperties else {
                    throw MCPClientError.invalidArguments("\(path) has invalid schema properties.")
                }
                properties = decoded
            } else {
                properties = [:]
            }
            let required = try stringSet(rules["required"], path: path)
            guard required.isSubset(of: Set(object.keys)) else {
                let missing = required.subtracting(object.keys).sorted().joined(separator: ", ")
                throw MCPClientError.invalidArguments("\(path) is missing: \(missing).")
            }
            let unknown = Set(object.keys).subtracting(properties.keys)
            guard unknown.isEmpty else {
                throw MCPClientError.invalidArguments(
                    "\(path) contains unknown fields: \(unknown.sorted().joined(separator: ", ")).")
            }
            for (key, child) in object {
                guard let childSchema = properties[key] else { continue }
                try validateValue(
                    child,
                    against: childSchema,
                    path: "\(path).\(key)",
                    depth: depth + 1)
            }
        default:
            break
        }
    }

    private static func schemaTypes(_ value: MCPJSONValue?) throws -> Set<String>? {
        guard let value else { return nil }
        switch value {
        case .string(let type): return [type]
        case .array(let values):
            let types = try values.map { value -> String in
                guard case .string(let type) = value else {
                    throw MCPClientError.invalidArguments("A schema type list is invalid.")
                }
                return type
            }
            return Set(types)
        default:
            throw MCPClientError.invalidArguments("A schema type is invalid.")
        }
    }

    private static func stringSet(
        _ value: MCPJSONValue?,
        path: String
    ) throws -> Set<String> {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw MCPClientError.invalidArguments("\(path) has an invalid required list.")
        }
        return try Set(values.map { value in
            guard case .string(let key) = value else {
                throw MCPClientError.invalidArguments("\(path) has an invalid required field.")
            }
            return key
        })
    }

    private static func typeName(of value: MCPJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .integer: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

actor MCPFileMutationCallLedger: MCPMutationCallLedger {
    private static let ownerOnlyPermissions = 0o600

    private struct Snapshot: Codable {
        var entries: [String: Entry]
    }

    private struct Entry: Codable {
        enum Status: String, Codable {
            case inFlight
            case completed
            case ambiguous
        }

        var status: Status
        var result: MCPToolResult?
        let taskID: String
        let serverID: String
        let toolName: String
        let updatedAt: Date
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Model", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("mutation-ledger.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var entries: [String: Entry] = [:]
    private var isLoaded = false

    init(
        fileURL: URL = MCPFileMutationCallLedger.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        // Migrate an older host's permissive ledger as soon as the default
        // pool constructs it, before the first mutation needs to read it.
        // loadIfNeeded retries this operation and fails closed if it cannot
        // be enforced.
        try? Self.enforceOwnerOnlyPermissionsIfPresent(
            at: fileURL,
            fileManager: fileManager)
    }

    func claim(_ call: MCPToolCall) async throws -> MCPMutationClaim {
        guard call.risk.isMutation else {
            throw MCPClientError.invalidArguments(
                "Read-only calls must not enter the mutation ledger.")
        }
        try loadIfNeeded()
        if let entry = entries[call.canonicalDigest] {
            switch entry.status {
            case .completed:
                guard let result = entry.result else {
                    throw MCPClientError.mutationAmbiguous
                }
                return .completed(result)
            case .inFlight, .ambiguous:
                if entry.status == .inFlight {
                    entries[call.canonicalDigest] = makeEntry(
                        call: call,
                        status: .ambiguous,
                        result: nil)
                    try persist()
                }
                return .ambiguous
            }
        }

        entries[call.canonicalDigest] = makeEntry(
            call: call,
            status: .inFlight,
            result: nil)
        try persist()
        return .new
    }

    func complete(_ call: MCPToolCall, result: MCPToolResult) async throws {
        try loadIfNeeded()
        guard entries[call.canonicalDigest]?.status == .inFlight else {
            entries[call.canonicalDigest] = makeEntry(
                call: call,
                status: .ambiguous,
                result: nil)
            try persist()
            throw MCPClientError.mutationAmbiguous
        }
        entries[call.canonicalDigest] = makeEntry(
            call: call,
            status: .completed,
            result: result)
        do {
            try persist()
        } catch {
            entries[call.canonicalDigest] = makeEntry(
                call: call,
                status: .ambiguous,
                result: nil)
            try? persist()
            throw error
        }
    }

    func markAmbiguous(_ call: MCPToolCall) async {
        guard (try? loadIfNeeded()) != nil else { return }
        if entries[call.canonicalDigest]?.status != .completed {
            entries[call.canonicalDigest] = makeEntry(
                call: call,
                status: .ambiguous,
                result: nil)
            try? persist()
        }
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try Self.enforceOwnerOnlyPermissionsIfPresent(
                    at: fileURL,
                    fileManager: fileManager)
                let data = try Data(contentsOf: fileURL)
                entries = try JSONDecoder().decode(Snapshot.self, from: data).entries
            } catch {
                throw MCPClientError.transport(
                    "The persistent MCP mutation safety record is unreadable.")
            }
        }
        isLoaded = true

        var changed = false
        for (digest, entry) in entries where entry.status == .inFlight {
            entries[digest] = Entry(
                status: .ambiguous,
                result: nil,
                taskID: entry.taskID,
                serverID: entry.serverID,
                toolName: entry.toolName,
                updatedAt: Date())
            changed = true
        }
        if changed { try persist() }
    }

    private func persist() throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Snapshot(entries: entries)).write(
                to: fileURL,
                options: [.atomic])
            // Atomic writes replace the inode and can restore umask-derived
            // 0644 permissions, so secure every newly created replacement.
            try Self.enforceOwnerOnlyPermissionsIfPresent(
                at: fileURL,
                fileManager: fileManager)
        } catch {
            throw MCPClientError.transport(
                "The persistent MCP mutation safety record could not be saved.")
        }
    }

    private static func enforceOwnerOnlyPermissionsIfPresent(
        at fileURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.setAttributes(
            [.posixPermissions: ownerOnlyPermissions],
            ofItemAtPath: fileURL.path)
    }

    private func makeEntry(
        call: MCPToolCall,
        status: Entry.Status,
        result: MCPToolResult?
    ) -> Entry {
        Entry(
            status: status,
            result: result,
            taskID: call.taskID,
            serverID: call.serverID,
            toolName: call.toolName,
            updatedAt: Date())
    }
}
