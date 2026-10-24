import Foundation
import Network

@MainActor
final class LocalComputerUseBrokerServer {
    typealias MemoryCommandHandler = @MainActor @Sendable (
        LocalMemoryRPCCommand, LocalMemoryRPCContext
    ) async -> LocalMemoryRPCReply

    enum ServerError: LocalizedError {
        case listenerFailed(String)
        case unavailablePort
        case wrongHost
        case busy
        case nonLocalPeer

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let message):
                return "The secure local AI listener failed: \(message)"
            case .unavailablePort:
                return "The secure local AI listener did not receive a port."
            case .wrongHost:
                return "The local AI request targeted a different Mac."
            case .busy:
                return "Another local AI device is already connected to this Mac."
            case .nonLocalPeer:
                return "The secure local AI listener accepts only private local-network peers."
            }
        }
    }

    private static let authorizationLease: Duration = .seconds(12)
    private static let requestDeadline: Duration = .seconds(15)
    private static let maximumConcurrentConnections = 8
    private static let listenerQueue = DispatchQueue(
        label: "com.threadmark.remotedesktop.local-computer-use.listener",
        qos: .userInitiated)

    private let credential: LocalComputerUseCredential
    private let hostID: String
    private let channel: LocalHostComputerUseChannel
    private let authorizePeer: (String) -> Bool
    private let revokePeer: (String) -> Void
    private let loopbackOnly: Bool
    private let memoryFeatureEnabled: Bool
    private let memoryHandler: MemoryCommandHandler?
    private var listener: NWListener?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var authorizedPeerID: String?
    private var authorizationLeaseTask: Task<Void, Never>?
    private var didFinishStarting = false

    init(
        credential: LocalComputerUseCredential,
        hostID: String,
        channel: LocalHostComputerUseChannel,
        loopbackOnly: Bool = false,
        memoryFeatureEnabled: Bool = false,
        memoryHandler: MemoryCommandHandler? = nil,
        authorizePeer: @escaping (String) -> Bool,
        revokePeer: @escaping (String) -> Void
    ) {
        self.credential = credential
        self.hostID = hostID
        self.channel = channel
        self.loopbackOnly = loopbackOnly
        self.memoryFeatureEnabled = memoryFeatureEnabled
        self.memoryHandler = memoryHandler
        self.authorizePeer = authorizePeer
        self.revokePeer = revokePeer
    }

    func start() async throws -> UInt16 {
        stop()
        didFinishStarting = false
        let listener: NWListener
        do {
            let parameters = LocalComputerUseTLS.serverParameters(credential: credential)
            if loopbackOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            }
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw ServerError.listenerFailed(error.localizedDescription)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt16, Error>) in
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor [weak self, weak listener] in
                        guard let self, let listener,
                              self.listener === listener,
                              !self.didFinishStarting else { return }
                        switch state {
                        case .ready:
                            self.didFinishStarting = true
                            guard let port = listener.port?.rawValue else {
                                continuation.resume(
                                    throwing: ServerError.unavailablePort)
                                return
                            }
                            continuation.resume(returning: port)
                        case .failed(let error):
                            self.didFinishStarting = true
                            continuation.resume(throwing:
                                ServerError.listenerFailed(
                                    error.localizedDescription))
                        case .cancelled:
                            self.didFinishStarting = true
                            continuation.resume(throwing: CancellationError())
                        case .setup, .waiting:
                            break
                        @unknown default:
                            self.didFinishStarting = true
                            continuation.resume(throwing:
                                ServerError.listenerFailed(
                                    "Unexpected listener state."))
                        }
                    }
                }
                listener.start(queue: Self.listenerQueue)
            }
        } onCancel: {
            listener.cancel()
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        authorizationLeaseTask?.cancel()
        authorizationLeaseTask = nil
        if let authorizedPeerID {
            self.authorizedPeerID = nil
            revokePeer(authorizedPeerID)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        guard loopbackOnly
            ? Self.isLoopbackEndpoint(connection.endpoint)
            : Self.isPrivateLocalEndpoint(connection.endpoint) else {
            // Reject before the TLS handshake and do not reveal whether the
            // local credential, host identity, or local AI service exists.
            connection.cancel()
            return
        }
        guard connectionTasks.count < Self.maximumConcurrentConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connectionTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionTasks[id] = nil }
            let deadline = Task {
                do {
                    try await Task.sleep(for: Self.requestDeadline)
                } catch {
                    return
                }
                connection.cancel()
            }
            defer { deadline.cancel() }
            do {
                _ = try await LocalComputerUseRPCTransport.serveOne(
                    on: connection
                ) { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handle(request)
                }
            } catch {
                // TLS failures and malformed frames are intentionally silent;
                // no unauthenticated peer receives host diagnostics.
            }
        }
    }

    func handle(
        _ request: LocalComputerUseRPCRequest
    ) async throws -> LocalComputerUseRPCResponse {
        try request.validate()
        guard request.targetID == hostID else {
            throw ServerError.wrongHost
        }
        guard Self.isValidPeerID(request.senderID),
              Self.isValidPeerID(request.targetID) else {
            throw LocalComputerUseRPCValidationError.invalidField("senderID")
        }
        guard Self.isValidSessionID(request.sessionID) else {
            throw LocalComputerUseRPCValidationError.invalidField("sessionID")
        }
        if let authorizedPeerID,
           authorizedPeerID != request.senderID {
            throw ServerError.busy
        }
        // Reserve the first authenticated peer before crossing the actor await.
        // Otherwise two simultaneous first requests can both observe nil and
        // authorize different devices. Roll the reservation back if the frame
        // itself fails bounded routing validation.
        let reservedPeer = authorizedPeerID == nil
        if reservedPeer {
            authorizedPeerID = request.senderID
        }
        guard authorizePeer(request.senderID) else {
            if reservedPeer, authorizedPeerID == request.senderID {
                authorizedPeerID = nil
            }
            throw ServerError.busy
        }
        if let command = request.memoryCommand {
            touchAuthorization(for: request.senderID)
            let context = LocalMemoryRPCContext(
                peerID: request.senderID,
                sessionID: request.sessionID)
            let reply: LocalMemoryRPCReply
            if memoryFeatureEnabled, let memoryHandler {
                reply = await memoryHandler(command, context)
            } else {
                reply = Self.disabledMemoryReply(for: command)
            }
            let response = LocalComputerUseRPCResponse(
                requestID: request.requestID,
                senderID: hostID,
                targetID: request.senderID,
                memoryReply: reply)
            do {
                _ = try response.memoryResult(for: request)
                try response.validate()
                return response
            } catch {
                return LocalComputerUseRPCResponse(
                    requestID: request.requestID,
                    senderID: hostID,
                    targetID: request.senderID,
                    memoryReply: Self.unavailableMemoryReply(for: command))
            }
        }
        let accepted: [String]
        do {
            accepted = try await channel.applyClientFrame(
                envelopes: request.envelopes,
                acknowledgedEnvelopeIDs: request.acknowledgedEnvelopeIDs,
                authenticatedSenderID: request.senderID,
                sessionID: request.sessionID)
        } catch {
            if reservedPeer, authorizedPeerID == request.senderID {
                authorizedPeerID = nil
                revokePeer(request.senderID)
            }
            throw error
        }
        touchAuthorization(for: request.senderID)
        let envelopes = try await channel.pollForClient(
            authenticatedSenderID: request.senderID,
            sessionID: request.sessionID)
        return try Self.boundedResponse(to: request, envelopes: envelopes, acceptedEnvelopeIDs: accepted)
    }

    static func disabledMemoryReply(
        for command: LocalMemoryRPCCommand
    ) -> LocalMemoryRPCReply {
        .init(operation: command.operation,
              commandID: command.commandID,
              rememberKind: command.rememberKind,
              status: .disabled,
              generationReference: Self.requiresGenerationReference(command)
                ? command.generationReference : nil)
    }

    static func unavailableMemoryReply(
        for command: LocalMemoryRPCCommand
    ) -> LocalMemoryRPCReply {
        .init(operation: command.operation,
              commandID: command.commandID,
              rememberKind: command.rememberKind,
              status: .unavailable,
              generationReference: Self.requiresGenerationReference(command)
                ? command.generationReference : nil)
    }

    private static func requiresGenerationReference(
        _ command: LocalMemoryRPCCommand
    ) -> Bool {
        command.operation == .forgetEverything
            || command.operation == .initializeMemoryGeneration
    }

    /// Count alone cannot bound JSON frames containing complete questions.
    /// Select an ordered prefix by its actual encoded size; polling does not
    /// remove any messages. Only a later authenticated acknowledgement does.
    static func boundedResponse(to request: LocalComputerUseRPCRequest, envelopes: [ComputerUseEnvelope],
                                acceptedEnvelopeIDs: [String]) throws -> LocalComputerUseRPCResponse {
        func response(_ messages: [ComputerUseEnvelope]) -> LocalComputerUseRPCResponse {
            .init(requestID: request.requestID, senderID: request.targetID, targetID: request.senderID,
                envelopes: messages, acceptedEnvelopeIDs: acceptedEnvelopeIDs)
        }
        var selected = response([])
        _ = try LocalComputerUseRPCCodec.encode(selected)
        for envelope in envelopes.prefix(LocalComputerUseRPCLimits.maximumEnvelopesPerFrame) {
            let candidate = response(selected.envelopes + [envelope])
            do {
                _ = try LocalComputerUseRPCCodec.encode(candidate)
                selected = candidate
            } catch LocalComputerUseRPCValidationError.frameTooLarge {
                // A message that cannot fit by itself is an error, not a
                // successful empty poll that would conceal a stuck queue.
                guard !selected.envelopes.isEmpty else { throw LocalComputerUseRPCValidationError.frameTooLarge }
                break
            }
        }
        return selected
    }

    private static func isValidPeerID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= LocalHostComputerUseChannel.maximumSessionIDBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    /// `NWListener(on: .any)` is needed for both Wi-Fi and wired Macs, but the
    /// broker itself is LAN-only. Restrict accepted source addresses to
    /// loopback, IPv4 private/link-local space, and IPv6 link-/unique-local
    /// space before any authenticated application bytes are processed.
    static func isPrivateLocalEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 10
                || bytes[0] == 127
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)

        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
            let isLinkLocal = bytes[0] == 0xFE
                && (bytes[1] & 0xC0) == 0x80
            let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
            return isLoopback || isLinkLocal || isUniqueLocal

        case .name(let name, _):
            let normalized = name.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return normalized == "localhost" || normalized.hasSuffix(".local")

        @unknown default:
            return false
        }
    }

    static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return [UInt8](address.rawValue).first == 127
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        case .name(let name, _):
            return name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "localhost"
        @unknown default:
            return false
        }
    }

    private func touchAuthorization(for senderID: String) {
        if authorizedPeerID == nil {
            authorizedPeerID = senderID
        }
        authorizationLeaseTask?.cancel()
        authorizationLeaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.authorizationLease)
            } catch {
                return
            }
            guard let self,
                  self.authorizedPeerID == senderID else { return }
            self.authorizedPeerID = nil
            self.authorizationLeaseTask = nil
            self.revokePeer(senderID)
        }
    }
}
