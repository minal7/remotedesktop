import Foundation
import SafariServices
import ServiceManagement

enum SafariBridgeTransportFailure: Error {
    case unavailable(SafariBridgeError)
    case malformedReply
    case taskRejected
}

@MainActor
final class SafariBridgeTransport {
    private let timeout: TimeInterval
    private var registeredTasks = Set<String>()
    private var hostConnection: NSXPCConnection?

    init(timeout: TimeInterval = 1.0) {
        self.timeout = timeout
    }

    func startTask(taskToken: String, registerHelperIfNeeded: Bool = false) async throws {
        guard SafariBridgeTaskBindings.isValidTaskToken(taskToken) else {
            throw SafariBridgeTransportFailure.taskRejected
        }
        let helperService = SMAppService.agent(plistName: "LaunchAgent.plist")
        if registerHelperIfNeeded, helperService.status == .notRegistered {
            do { try helperService.register() }
            catch { /* Report the resulting public service status below. */ }
        }
        switch helperService.status {
        case .enabled:
            break
        case .requiresApproval:
            throw SafariBridgeTransportFailure.unavailable(.helperRequiresApproval)
        case .notRegistered:
            throw SafariBridgeTransportFailure.unavailable(.helperNotRegistered)
        case .notFound:
            throw SafariBridgeTransportFailure.unavailable(.helperNotRegistered)
        @unknown default:
            throw SafariBridgeTransportFailure.unavailable(.bridgeUnavailable)
        }
        let connection = SafariBridgeHostXPC.connection()
        let remote = try proxy(connection)
        let accepted: Bool? = await boolReply(timeout: timeout) { reply in
            remote.registerTask(taskToken, reply: reply)
        }
        guard accepted == true else {
            connection.invalidate()
            throw SafariBridgeTransportFailure.unavailable(.bridgeUnavailable)
        }
        hostConnection?.invalidate()
        hostConnection = connection
        registeredTasks.insert(taskToken)
    }

    func perform(_ command: SafariBridgeCommand) async throws -> SafariBridgeResult {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        guard registeredTasks.contains(command.taskToken), command.isStructurallyValid,
              let connection = hostConnection else { throw SafariBridgeTransportFailure.taskRejected }
        let remote = try proxy(connection)
        let json = try command.encodedJSON()
        let accepted: Bool? = await boolReply(timeout: Self.remaining(until: deadline)) { reply in
            remote.registerCommand(json, reply: reply)
        }
        guard accepted == true else { throw SafariBridgeTransportFailure.unavailable(.bridgeUnavailable) }

        let dispatched: Bool = await withCheckedContinuation { continuation in
            let once = SafariBridgeOneShot<Bool>(continuation)
            SFSafariApplication.dispatchMessage(
                withName: "remoteDesktop.command.v1",
                toExtensionWithIdentifier: SafariBridgeXPCNames.safariExtensionIdentifier,
                userInfo: Self.dictionary(from: command)) { error in
                    once.resume(error == nil)
                }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.remaining(until: deadline)) {
                once.resume(false)
            }
        }
        guard dispatched else { throw SafariBridgeTransportFailure.unavailable(.bridgeUnavailable) }

        let resultJSON = await Self.resultFromBroker(
            remote: remote,
            commandId: command.commandId,
            timeout: Self.remaining(until: deadline))
        guard let resultJSON,
              let result = try? JSONDecoder().decode(SafariBridgeResult.self, from: Data(resultJSON.utf8)),
              result.matches(command) else {
            throw SafariBridgeTransportFailure.unavailable(.bridgeUnavailable)
        }
        guard result.status == .ok else {
            throw SafariBridgeTransportFailure.unavailable(result.error ?? .operationFailed)
        }
        return result
    }

    func endTask(taskToken: String) async {
        guard registeredTasks.contains(taskToken), let connection = hostConnection else { return }
        if let remote = try? proxy(connection) {
            // Send the detach through Safari while the helper still recognizes
            // the task, so the extension clears its task and tab authority.
            _ = try? await perform(SafariBridgeCommand(taskToken: taskToken, operation: .endTask))
            _ = await boolReply(timeout: timeout) { reply in
                remote.finishTask(taskToken, reply: reply)
            }
        }
        registeredTasks.remove(taskToken)
        connection.invalidate()
        hostConnection = nil
    }

    private func proxy(_ connection: NSXPCConnection) throws -> SafariBridgeBrokerXPC {
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? SafariBridgeBrokerXPC else {
            throw SafariBridgeTransportFailure.unavailable(.bridgeUnavailable)
        }
        return remote
    }

    private func boolReply(
        timeout: TimeInterval,
        invoke: (@escaping (Bool) -> Void) -> Void
    ) async -> Bool? {
        await withCheckedContinuation { continuation in
            let once = SafariBridgeOneShot<Bool?>(continuation)
            invoke { once.resume($0) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    private static func remaining(until deadline: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        return Double(deadline - now) / 1_000_000_000
    }

    private static func resultFromBroker(
        remote: SafariBridgeBrokerXPC,
        commandId: String,
        timeout: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let once = SafariBridgeOneShot<String?>(continuation)
            remote.awaitResult(commandId) { once.resume($0) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    private static func dictionary(from command: SafariBridgeCommand) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(command),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}

/// `continuation` is accessed only while holding `lock`, so timeout and API
/// callbacks can safely race to complete the same async operation.
private final class SafariBridgeOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private enum SafariBridgeHostXPC {
    static func connection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: SafariBridgeXPCNames.hostService, options: [])
        connection.setCodeSigningRequirement(
            SafariBridgeCodeSigning.requirement(for: SafariBridgeXPCNames.helperBundleIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: SafariBridgeBrokerXPC.self)
        connection.resume()
        return connection
    }
}
