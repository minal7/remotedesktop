import Foundation

typealias MCPClientSessionFactory = @Sendable (
    _ validatedBinary: MCPValidatedBinary,
    _ processGeneration: UInt64
) -> any MCPClientSessioning

typealias MCPEmbeddedSessionFactory = @Sendable (
    _ processGeneration: UInt64
) -> (any MCPClientSessioning)?

actor MCPClientPool {
    private let definition: MCPServerDefinition
    private let binaryValidator: any MCPServerBinaryValidating
    private let mutationLedger: (any MCPMutationCallLedger)?
    private let sessionFactory: MCPClientSessionFactory
    private let embeddedSessionFactory: MCPEmbeddedSessionFactory
    private let cloudEmbeddedSessionFactory: MCPEmbeddedSessionFactory
    private let cloudStorage: RemoteDesktopCloudStorage
    private let mailAutomationPreflight: any RemoteDesktopMailAutomationPreflighting

    private var session: (any MCPClientSessioning)?
    private var identity: MCPProcessIdentity?
    private var embeddedSession: (any MCPClientSessioning)?
    private var embeddedIdentity: MCPProcessIdentity?
    private var cloudEmbeddedSession: (any MCPClientSessioning)?
    private var cloudEmbeddedIdentity: MCPProcessIdentity?
    private var processGeneration: UInt64 = 0
    private var lifecycleEpoch: UInt64 = 0
    private struct PendingApproval {
        let fingerprint: MCPApprovalFingerprint
        let date: Date
        let mailAttachments: [RemoteDesktopMailAttachmentSnapshot]?
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
        },
        embeddedSessionFactory: @escaping MCPEmbeddedSessionFactory = { generation in
            RemoteDesktopMailMCPClientSession(processGeneration: generation)
        },
        cloudStorage: RemoteDesktopCloudStorage = .init(),
        cloudEmbeddedSessionFactory: MCPEmbeddedSessionFactory? = nil,
        mailAutomationPreflight: any RemoteDesktopMailAutomationPreflighting =
            SystemRemoteDesktopMailAutomationPreflight()
    ) {
        precondition(
            MCPServerRegistry.curatedServers.contains(definition),
            "MCPClientPool only accepts a compiled-in curated server.")
        self.definition = definition
        self.binaryValidator = binaryValidator
        self.mutationLedger = mutationLedger
        self.sessionFactory = sessionFactory
        self.embeddedSessionFactory = embeddedSessionFactory
        self.cloudStorage = cloudStorage
        self.cloudEmbeddedSessionFactory = cloudEmbeddedSessionFactory ?? { generation in
            // A6 pauses sync-folder copying. Keep the implementation behind
            // the experimental flag; it is never advertised for routing.
            guard ComputerUseFeatureFlags.computerUseV2 else { return nil }
            return RemoteDesktopCloudStorageMCPClientSession(
                processGeneration: generation,
                storage: cloudStorage)
        }
        self.mailAutomationPreflight = mailAutomationPreflight
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
        let previousEmbedded = embeddedSession
        let previousCloudEmbedded = cloudEmbeddedSession
        session = nil
        identity = nil
        embeddedSession = nil
        embeddedIdentity = nil
        cloudEmbeddedSession = nil
        cloudEmbeddedIdentity = nil
        pendingApprovals.removeAll()
        await previous?.stop()
        await previousEmbedded?.stop()
        await previousCloudEmbedded?.stop()
        // These are exact old sessions. Finish retiring both, but do not
        // publish a candidate after another attempt has acquired ownership.
        try requireCurrentStart(epoch)

        let candidate = sessionFactory(validated, generation)
        let embeddedCandidate = embeddedSessionFactory(generation)
        let cloudEmbeddedCandidate = cloudEmbeddedSessionFactory(generation)
        session = candidate
        embeddedSession = embeddedCandidate
        cloudEmbeddedSession = cloudEmbeddedCandidate
        do {
            let newIdentity = try await candidate.start()
            try requireCurrentStart(epoch)
            guard newIdentity.serverID == definition.serverID,
                  newIdentity.processGeneration == generation,
                  newIdentity.binaryPath == validated.executableURL.path else {
                throw MCPClientError.cancelled
            }
            let newEmbeddedIdentity = try await embeddedCandidate?.start()
            try requireCurrentStart(epoch)
            if let newEmbeddedIdentity {
                guard newEmbeddedIdentity.serverID == RemoteDesktopMailMCP.serverID,
                      newEmbeddedIdentity.processGeneration == generation else {
                    throw MCPClientError.serverMismatch(
                        "The embedded Mail MCP identity did not match the signed host.")
                }
            }
            let newCloudEmbeddedIdentity = try await cloudEmbeddedCandidate?.start()
            try requireCurrentStart(epoch)
            if let newCloudEmbeddedIdentity {
                guard newCloudEmbeddedIdentity.serverID == RemoteDesktopCloudStorageMCP.serverID,
                      newCloudEmbeddedIdentity.processGeneration == generation else {
                    throw MCPClientError.serverMismatch(
                        "The embedded cloud-storage MCP identity did not match the signed host.")
                }
            }
            identity = newIdentity
            embeddedIdentity = newEmbeddedIdentity
            cloudEmbeddedIdentity = newCloudEmbeddedIdentity
            return newIdentity
        } catch {
            // A newer validation attempt can supersede this request without
            // allocating a replacement session. Clear slots still owned by
            // this candidate; never clear a later allocated generation.
            if processGeneration == generation {
                session = nil
                identity = nil
                embeddedSession = nil
                embeddedIdentity = nil
                cloudEmbeddedSession = nil
                cloudEmbeddedIdentity = nil
            }
            await candidate.stop()
            await embeddedCandidate?.stop()
            await cloudEmbeddedCandidate?.stop()
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
        let sidecarTools = try await session.listAllowedTools().filter {
            // The embedded tool name is reserved to the signed host. A future
            // sidecar cannot impersonate it, and v0.8.2's broken mail_send is
            // excluded by policy even if a session implementation returns it.
            $0.serverID == identity.serverID
                && $0.toolName != RemoteDesktopMailMCP.toolName
                && $0.toolName != RemoteDesktopCloudStorageMCP.toolName
                && $0.serverID != RemoteDesktopMailMCP.serverID
                && $0.serverID != RemoteDesktopCloudStorageMCP.serverID
                && MCPToolSafetyPolicy.isAllowed($0.toolName)
        }
        var tools = sidecarTools
        if let embeddedSession, let embeddedIdentity {
            let embeddedTools = try await embeddedSession.listAllowedTools()
            guard embeddedTools.allSatisfy({
                $0.serverID == embeddedIdentity.serverID
                    && $0.toolName == RemoteDesktopMailMCP.toolName
            }) else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server advertised an unexpected tool.")
            }
            tools.append(contentsOf: embeddedTools)
        }
        if let cloudEmbeddedSession, let cloudEmbeddedIdentity {
            let cloudTools = try await cloudEmbeddedSession.listAllowedTools()
            guard cloudTools.allSatisfy({
                $0.serverID == cloudEmbeddedIdentity.serverID
                    && $0.toolName == RemoteDesktopCloudStorageMCP.toolName
            }) else {
                throw MCPClientError.serverMismatch(
                    "The embedded cloud-storage MCP server advertised an unexpected tool.")
            }
            // A6: retained for future OS-level work, deliberately unrouted.
            _ = cloudTools
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
        let mailAttachments: [RemoteDesktopMailAttachmentSnapshot]?
        if validatedCall.toolName == RemoteDesktopMailMCP.toolName {
            let mail = try RemoteDesktopMailRequest(arguments: validatedCall.arguments)
            if !mail.attachmentPaths.isEmpty,
               pendingApprovals.contains(where: {
                   $0.key != validatedCall.canonicalDigest && $0.value.mailAttachments != nil
               }) {
                throw MCPClientError.toolFailed("Only one attachment approval can be pending at a time.")
            }
            mailAttachments = mail.attachmentPaths.isEmpty
                ? nil
                : try RemoteDesktopMailAttachmentFileReader.snapshot(paths: mail.attachmentPaths)
        } else {
            mailAttachments = nil
        }
        let fingerprint = MCPApprovalFingerprint(
            call: validatedCall,
            mailAttachmentDigest: try mailAttachments.map(RemoteDesktopMailAttachmentFileReader.approvalDigest))
        if validatedCall.toolName == RemoteDesktopCloudStorageMCP.toolName {
            let prepared = try await cloudStorage.prepare(arguments: validatedCall.arguments)
            guard prepared.arguments == validatedCall.arguments else {
                throw MCPClientError.invalidArguments(
                    "The cloud-storage action was not bound to the current source and destination.")
            }
            try Task.checkCancellation()
            guard identity?.processGeneration == validatedCall.processGeneration,
                  cloudEmbeddedIdentity?.processGeneration == validatedCall.processGeneration else {
                throw MCPClientError.staleCall
            }
        }
        pendingApprovals[validatedCall.canonicalDigest] = PendingApproval(
            fingerprint: fingerprint, date: Date(), mailAttachments: mailAttachments)
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
        let pending = try approvedPending(for: validatedCall, fingerprint: fingerprint)
        let isCloudStorage = validatedCall.toolName == RemoteDesktopCloudStorageMCP.toolName
        let isMail = validatedCall.toolName == RemoteDesktopMailMCP.toolName
        if isCloudStorage {
            let refreshed = try await cloudStorage.prepare(arguments: validatedCall.arguments)
            guard refreshed.arguments == validatedCall.arguments else {
                throw MCPClientError.approvalMismatch
            }
            try Task.checkCancellation()
            guard identity?.processGeneration == validatedCall.processGeneration,
                  cloudEmbeddedIdentity?.processGeneration == validatedCall.processGeneration else {
                throw MCPClientError.staleCall
            }
        } else if !isMail {
            return
        }

        let epoch = lifecycleEpoch
        let generation = validatedCall.processGeneration
        if isMail {
            try await mailAutomationPreflight.ensureAuthorized()
        }
        try Task.checkCancellation()
        guard lifecycleEpoch == epoch,
              identity?.processGeneration == generation,
              (isCloudStorage
                ? cloudEmbeddedIdentity?.processGeneration == generation
                : embeddedIdentity?.processGeneration == generation) else {
            throw MCPClientError.staleCall
        }

        let (revalidatedCall, _) = try await validate(call)
        try Task.checkCancellation()
        guard revalidatedCall == validatedCall,
              lifecycleEpoch == epoch,
              identity?.processGeneration == generation,
              (isCloudStorage
                ? cloudEmbeddedIdentity?.processGeneration == generation
                : embeddedIdentity?.processGeneration == generation) else {
            throw MCPClientError.staleCall
        }
        let stillPending = try approvedPending(for: revalidatedCall, fingerprint: fingerprint)
        guard stillPending.date == pending.date,
              stillPending.mailAttachments == pending.mailAttachments else {
            throw MCPClientError.approvalMismatch
        }
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
        if let mailAttachments = pending.mailAttachments {
            try RemoteDesktopMailAttachmentFileReader.verifyUnchanged(mailAttachments)
            guard fingerprint.mailAttachmentDigest
                    == (try RemoteDesktopMailAttachmentFileReader.approvalDigest(mailAttachments)) else {
                throw MCPClientError.approvalMismatch
            }
            let result = try await performMutation(validatedCall, using: session,
                approvedMailAttachments: mailAttachments)
            guard case .object(let receipt)? = result.structuredContent,
                  receipt["attachment_digest"] == .string(fingerprint.mailAttachmentDigest ?? "") else {
                throw MCPClientError.approvalMismatch
            }
            return result
        }
        guard fingerprint.mailAttachmentDigest == nil else {
            throw MCPClientError.approvalMismatch
        }
        return try await performMutation(validatedCall, using: session)
    }

    func cancelAll() async {
        lifecycleEpoch &+= 1
        let active = session
        let activeEmbedded = embeddedSession
        let activeCloudEmbedded = cloudEmbeddedSession
        session = nil
        identity = nil
        embeddedSession = nil
        embeddedIdentity = nil
        cloudEmbeddedSession = nil
        cloudEmbeddedIdentity = nil
        pendingApprovals.removeAll()
        await active?.stop()
        await activeEmbedded?.stop()
        await activeCloudEmbedded?.stop()
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
        // Tool names are not identities. Bind the signed host's reserved Mail
        // tool to its embedded server again at execution time so a sidecar
        // cannot bypass discovery filtering with a crafted call.
        if suppliedCall.toolName == RemoteDesktopMailMCP.toolName {
            guard suppliedCall.serverID == RemoteDesktopMailMCP.serverID,
                  embeddedIdentity?.serverID == RemoteDesktopMailMCP.serverID else {
                throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
            }
        } else if suppliedCall.serverID == RemoteDesktopMailMCP.serverID {
            throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
        }
        if suppliedCall.toolName == RemoteDesktopCloudStorageMCP.toolName {
            guard suppliedCall.serverID == RemoteDesktopCloudStorageMCP.serverID,
                  cloudEmbeddedIdentity?.serverID == RemoteDesktopCloudStorageMCP.serverID else {
                throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
            }
        } else if suppliedCall.serverID == RemoteDesktopCloudStorageMCP.serverID {
            throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
        }
        if suppliedCall.serverID == rootIdentity.serverID,
           suppliedCall.toolName == "mail_send" {
            throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
        }
        let selected: (any MCPClientSessioning, MCPProcessIdentity)
        if suppliedCall.serverID == rootIdentity.serverID,
           let session {
            selected = (session, rootIdentity)
        } else if let embeddedSession, let embeddedIdentity,
                  suppliedCall.serverID == embeddedIdentity.serverID {
            selected = (embeddedSession, embeddedIdentity)
        } else if let cloudEmbeddedSession, let cloudEmbeddedIdentity,
                  suppliedCall.serverID == cloudEmbeddedIdentity.serverID {
            selected = (cloudEmbeddedSession, cloudEmbeddedIdentity)
        } else {
            throw MCPClientError.staleCall
        }
        let (session, selectedIdentity) = selected
        guard suppliedCall.processGeneration == selectedIdentity.processGeneration else {
            throw MCPClientError.staleCall
        }

        let generation = selectedIdentity.processGeneration
        let tools = try await session.listAllowedTools()
        guard self.identity?.processGeneration == generation else {
            throw MCPClientError.staleCall
        }
        guard let tool = tools.first(where: { $0.toolName == suppliedCall.toolName }) else {
            throw MCPClientError.toolNotAllowed(suppliedCall.toolName)
        }
        guard tool.serverID == selectedIdentity.serverID,
              tool.processGeneration == selectedIdentity.processGeneration,
              tool.schemaDigest == suppliedCall.schemaDigest else {
            throw MCPClientError.staleCall
        }

        try MCPJSONSchemaValidator.validate(arguments: suppliedCall.arguments, against: tool.inputSchema)
        if suppliedCall.serverID == RemoteDesktopCloudStorageMCP.serverID {
            try RemoteDesktopCloudStorage.validateArguments(suppliedCall.arguments)
        }
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
        using session: any MCPClientSessioning,
        approvedMailAttachments: [RemoteDesktopMailAttachmentSnapshot]? = nil
    ) async throws -> MCPToolResult {
        guard let mutationLedger else {
            throw MCPClientError.mutationLedgerRequired
        }

        if let approvedMailAttachments, !approvedMailAttachments.isEmpty {
            guard call.toolName == RemoteDesktopMailMCP.toolName,
                  session is RemoteDesktopMailMCPClientSession else {
                throw MCPClientError.approvalMismatch
            }
        }
        if call.toolName == RemoteDesktopCloudStorageMCP.toolName {
            guard call.serverID == RemoteDesktopCloudStorageMCP.serverID,
                  session is RemoteDesktopCloudStorageMCPClientSession else {
                throw MCPClientError.approvalMismatch
            }
        }

        // This boundary is reached only after the exact fingerprinted mobile
        // approval has been consumed. Ask for Automation now, before claiming
        // the at-most-once mutation, so denial cannot make an unsent email
        // look ambiguous or poison a later corrected request.
        if call.toolName == RemoteDesktopMailMCP.toolName {
            do {
                try await mailAutomationPreflight.ensureAuthorized()
            } catch is CancellationError {
                throw MCPClientError.cancelled
            } catch let error as MCPClientError {
                throw error
            } catch {
                throw MCPClientError.toolFailed(
                    SystemRemoteDesktopMailAutomationPreflight.denialMessage)
            }
            try Task.checkCancellation()
            guard identity?.processGeneration == call.processGeneration,
                  embeddedIdentity?.processGeneration == call.processGeneration else {
                throw MCPClientError.staleCall
            }
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
            let result: MCPToolResult
            if let approvedMailAttachments, !approvedMailAttachments.isEmpty,
               let mailSession = session as? RemoteDesktopMailMCPClientSession {
                result = try await mailSession.executeApprovedMail(call, attachments: approvedMailAttachments)
            } else {
                result = try await session.execute(call)
            }
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
        if call.toolName == RemoteDesktopMailMCP.toolName {
            let request = try RemoteDesktopMailRequest(arguments: call.arguments)
            if request.attachmentPaths.isEmpty {
                guard pending.mailAttachments == nil,
                      fingerprint.mailAttachmentDigest == nil else {
                    throw MCPClientError.approvalMismatch
                }
            } else {
                guard let snapshots = pending.mailAttachments,
                      snapshots.map(\.path) == request.attachmentPaths,
                      fingerprint.mailAttachmentDigest
                        == (try RemoteDesktopMailAttachmentFileReader.approvalDigest(snapshots)) else {
                    throw MCPClientError.approvalMismatch
                }
                try RemoteDesktopMailAttachmentFileReader.verifyUnchanged(snapshots)
            }
        } else {
            guard pending.mailAttachments == nil,
                  fingerprint.mailAttachmentDigest == nil else {
                throw MCPClientError.approvalMismatch
            }
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
