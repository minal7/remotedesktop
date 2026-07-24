import Dispatch
import Foundation
import Network
import Security

/// Pinned ECDHE-PSK parameters for the local Computer Use RPC transport.
/// Certificate authentication is deliberately disabled because possession of
/// the 256-bit, device-local PSK is the sole peer-authentication mechanism.
public enum LocalComputerUseTLS {
    public static let applicationProtocol = "rd-computer-use/1"

    public static func clientParameters(
        credential: LocalComputerUseCredential
    ) -> NWParameters {
        parameters(credential: credential, isServer: false)
    }

    public static func serverParameters(
        credential: LocalComputerUseCredential
    ) -> NWParameters {
        parameters(credential: credential, isServer: true)
    }

    private static func parameters(
        credential: LocalComputerUseCredential,
        isServer: Bool
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        // Network.framework on macOS 26.5 fails listener-side external PSK at
        // TLS 1.3 with errSSLInternal, including when TLS_AES_128_GCM_SHA256 is
        // appended explicitly. Apple DTS's supported PSK configuration is TLS
        // 1.2. Pin one ECDHE-PSK AEAD suite: ephemeral ECDHE retains forward
        // secrecy, ChaCha20-Poly1305 provides authenticated encryption, and no
        // certificate or non-PSK fallback suite can be negotiated.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        applicationProtocol.withCString {
            sec_protocol_options_add_tls_application_protocol(options, $0)
        }

        let key = dispatchData(credential.rawKey)
        let identity = dispatchData(Data(credential.credentialID.utf8))
        sec_protocol_options_add_pre_shared_key(options, key, identity)
        sec_protocol_options_append_tls_ciphersuite(
            options,
            tls_ciphersuite_t(rawValue: UInt16(
                TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .responsiveData
        if isServer {
            parameters.allowLocalEndpointReuse = true
        }
        return parameters
    }

    private static func dispatchData(_ data: Data) -> dispatch_data_t {
        let value = data.withUnsafeBytes { DispatchData(bytes: $0) }
        return value as dispatch_data_t
    }
}

public enum LocalComputerUseRPCTransportError:
    Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case connectionFailed(String)
    case connectionClosed
    case invalidLengthPrefix
    case responseMismatch
    case remoteFailure(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The local Mac endpoint is invalid."
        case .connectionFailed(let message):
            return "The secure local connection failed: \(message)"
        case .connectionClosed:
            return "The secure local connection closed unexpectedly."
        case .invalidLengthPrefix:
            return "The secure local connection returned an invalid frame."
        case .responseMismatch:
            return "The secure local response did not match this request."
        case .remoteFailure(_, let message):
            return message
        }
    }
}

/// A single-request RPC exchange over an authenticated TLS-PSK connection.
/// The helpers use an explicit four-byte, network-order length prefix and
/// reject a payload before allocating beyond the shared frame limit.
public enum LocalComputerUseRPCTransport {
    public typealias Handler = @Sendable (
        LocalComputerUseRPCRequest
    ) async throws -> LocalComputerUseRPCResponse

    /// Opens one connection, sends one request, receives its matching
    /// response, and closes. Cancellation immediately cancels the connection.
    public static func call(
        endpoint: LocalComputerUseEndpoint,
        credential: LocalComputerUseCredential,
        request: LocalComputerUseRPCRequest,
        readinessTimeout: Duration = .seconds(10)
    ) async throws -> LocalComputerUseRPCResponse {
        guard endpoint.isValid,
              let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw LocalComputerUseRPCTransportError.invalidEndpoint
        }
        try request.validate()

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: LocalComputerUseTLS.clientParameters(
                credential: credential))
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try await startAndWaitUntilReady(
                connection,
                readinessTimeout: readinessTimeout)
            try await send(request: request, over: connection)
            let response = try await receiveResponse(over: connection)
            guard response.requestID == request.requestID,
                  response.senderID == request.targetID,
                  response.targetID == request.senderID else {
                throw LocalComputerUseRPCTransportError.responseMismatch
            }
            if let failure = response.failure {
                throw LocalComputerUseRPCTransportError.remoteFailure(
                    code: failure.code,
                    message: failure.message)
            }
            return response
        } onCancel: {
            connection.cancel()
        }
    }

    /// Starts an accepted `NWConnection`, receives one request, invokes the
    /// host handler, sends one response, and closes the connection. Handler
    /// failures become bounded generic failures and never expose internal
    /// diagnostics to the peer.
    @discardableResult
    public static func serveOne(
        on connection: NWConnection,
        handler: @escaping Handler
    ) async throws -> LocalComputerUseRPCResponse {
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await startAndWaitUntilReady(connection)
            let request = try await receiveRequest(over: connection)
            let response: LocalComputerUseRPCResponse
            do {
                response = try await handler(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                response = LocalComputerUseRPCResponse(
                    requestID: request.requestID,
                    senderID: request.targetID,
                    targetID: request.senderID,
                    failure: LocalComputerUseRPCFailure(
                        code: "host_processing_failed",
                        message: "The Mac could not process this local request."))
            }
            guard response.requestID == request.requestID,
                  response.senderID == request.targetID,
                  response.targetID == request.senderID else {
                throw LocalComputerUseRPCTransportError.responseMismatch
            }
            try await send(response: response, over: connection)
            return response
        } onCancel: {
            connection.cancel()
        }
    }

    public static func send(
        request: LocalComputerUseRPCRequest,
        over connection: NWConnection
    ) async throws {
        try await sendFrame(
            LocalComputerUseRPCCodec.encode(request),
            over: connection)
    }

    public static func receiveRequest(
        over connection: NWConnection
    ) async throws -> LocalComputerUseRPCRequest {
        try LocalComputerUseRPCCodec.decodeRequest(
            try await receiveFrame(over: connection))
    }

    public static func send(
        response: LocalComputerUseRPCResponse,
        over connection: NWConnection
    ) async throws {
        try await sendFrame(
            LocalComputerUseRPCCodec.encode(response),
            over: connection)
    }

    public static func receiveResponse(
        over connection: NWConnection
    ) async throws -> LocalComputerUseRPCResponse {
        try LocalComputerUseRPCCodec.decodeResponse(
            try await receiveFrame(over: connection))
    }

    private static let networkQueue = DispatchQueue(
        label: "com.threadmark.remotedesktop.local-computer-use",
        qos: .userInitiated,
        attributes: .concurrent)

    private static func startAndWaitUntilReady(
        _ connection: NWConnection,
        readinessTimeout: Duration = .seconds(10)
    ) async throws {
        guard readinessTimeout > .zero else {
            throw LocalComputerUseRPCTransportError.connectionFailed(
                "The secure local connection timed out.")
        }
        let box = LocalComputerUseContinuationBox<Void>()
        let deadline = Task {
            do {
                try await Task.sleep(for: readinessTimeout)
            } catch {
                return
            }
            box.resume(throwing:
                LocalComputerUseRPCTransportError.connectionFailed(
                    "The secure local connection timed out."))
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.stateUpdateHandler = nil
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(returning: ())
                    case .failed(let error):
                        box.resume(throwing:
                            LocalComputerUseRPCTransportError.connectionFailed(
                                error.localizedDescription))
                    case .cancelled:
                        box.resume(throwing: CancellationError())
                    case .setup, .preparing, .waiting:
                        // Valid loopback connections can briefly wait while
                        // the listener path settles. The explicit deadline
                        // above bounds this state without rejecting a healthy
                        // connection on a transient Network.framework event.
                        break
                    @unknown default:
                        box.resume(throwing:
                            LocalComputerUseRPCTransportError.connectionClosed)
                    }
                }
                connection.start(queue: networkQueue)
            }
        } onCancel: {
            // Resume directly as well as cancelling the connection. A cancel
            // that races before Network.framework installs its callback must
            // still release the awaiting continuation exactly once.
            box.resume(throwing: CancellationError())
            connection.cancel()
        }
    }

    private static func sendFrame(
        _ payload: Data,
        over connection: NWConnection
    ) async throws {
        guard !payload.isEmpty,
              payload.count <= LocalComputerUseRPCLimits.maximumFrameBytes,
              let length = UInt32(exactly: payload.count) else {
            throw LocalComputerUseRPCValidationError.frameTooLarge
        }
        var networkLength = length.bigEndian
        var frame = Data(
            bytes: &networkLength,
            count: LocalComputerUseRPCLimits.lengthPrefixBytes)
        frame.append(payload)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing:
                            LocalComputerUseRPCTransportError.connectionFailed(
                                error.localizedDescription))
                    } else {
                        continuation.resume(returning: ())
                    }
                })
        }
    }

    private static func receiveFrame(
        over connection: NWConnection
    ) async throws -> Data {
        let prefix = try await receiveExactly(
            LocalComputerUseRPCLimits.lengthPrefixBytes,
            over: connection)
        let length = prefix.withUnsafeBytes { rawBuffer -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: rawBuffer)
            }
            return UInt32(bigEndian: value)
        }
        guard length > 0,
              length <= LocalComputerUseRPCLimits.maximumFrameBytes else {
            throw LocalComputerUseRPCTransportError.invalidLengthPrefix
        }
        return try await receiveExactly(Int(length), over: connection)
    }

    private static func receiveExactly(
        _ count: Int,
        over connection: NWConnection
    ) async throws -> Data {
        var received = Data()
        received.reserveCapacity(count)
        while received.count < count {
            let remaining = count - received.count
            let chunk = try await receiveChunk(
                maximumLength: remaining,
                over: connection)
            guard !chunk.isEmpty else {
                throw LocalComputerUseRPCTransportError.connectionClosed
            }
            received.append(chunk)
        }
        return received
    }

    private static func receiveChunk(
        maximumLength: Int,
        over connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing:
                        LocalComputerUseRPCTransportError.connectionFailed(
                            error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing:
                        LocalComputerUseRPCTransportError.connectionClosed)
                } else {
                    continuation.resume(throwing:
                        LocalComputerUseRPCTransportError.connectionClosed)
                }
            }
        }
    }
}

private final class LocalComputerUseContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isCompleted = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let pending: Result<Value, Error>? = lock.withLock {
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            guard !isCompleted else { return nil }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func resume(returning value: Value) {
        complete(.success(value))
    }

    func resume(throwing error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Value, Error>) {
        let installed: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !isCompleted else { return nil }
            isCompleted = true
            guard let continuation else {
                pendingResult = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        installed?.resume(with: result)
    }
}
