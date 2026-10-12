import Foundation

@objc private protocol SafariBridgeBrokerExport: SafariBridgeBrokerXPC {}

@main
enum SafariBridgeBrokerMain {
    static func main() {
        let broker = SafariBridgeBroker()
        let hostListener = NSXPCListener(machServiceName: SafariBridgeXPCNames.hostService)
        hostListener.setConnectionCodeSigningRequirement(
            SafariBridgeCodeSigning.requirement(for: SafariBridgeXPCNames.hostBundleIdentifier))
        let extensionListener = NSXPCListener(machServiceName: SafariBridgeXPCNames.extensionService)
        extensionListener.setConnectionCodeSigningRequirement(
            SafariBridgeCodeSigning.requirement(for: SafariBridgeXPCNames.extensionBundleIdentifier))
        let hostDelegate = SafariBridgeListenerDelegate(broker: broker, role: .host)
        let extensionDelegate = SafariBridgeListenerDelegate(broker: broker, role: .extension)
        hostListener.delegate = hostDelegate
        extensionListener.delegate = extensionDelegate
        hostListener.resume()
        extensionListener.resume()
        withExtendedLifetime((hostDelegate, extensionDelegate)) { dispatchMain() }
    }
}

private enum SafariBridgePeerRole: Equatable {
    case host
    case `extension`
}

private final class SafariBridgeListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let broker: SafariBridgeBroker
    private let role: SafariBridgePeerRole

    init(broker: SafariBridgeBroker, role: SafariBridgePeerRole) {
        self.broker = broker
        self.role = role
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SafariBridgeBrokerExport.self)
        connection.exportedObject = SafariBridgeBrokerConnection(broker: broker, role: role)
        connection.resume()
        return true
    }
}

private final class SafariBridgeBrokerConnection: NSObject, SafariBridgeBrokerExport {
    private let broker: SafariBridgeBroker
    private let role: SafariBridgePeerRole

    init(broker: SafariBridgeBroker, role: SafariBridgePeerRole) {
        self.broker = broker
        self.role = role
    }

    func registerTask(_ taskToken: String, reply: @escaping (Bool) -> Void) {
        guard role == .host else { reply(false); return }
        reply(broker.registerTask(taskToken))
    }

    func registerCommand(_ json: String, reply: @escaping (Bool) -> Void) {
        guard role == .host else { reply(false); return }
        reply(broker.registerCommand(json))
    }

    func submitResult(_ json: String, reply: @escaping (Bool) -> Void) {
        guard role == .extension else { reply(false); return }
        reply(broker.submitResult(json))
    }

    func awaitResult(_ commandId: String, reply: @escaping (String?) -> Void) {
        guard role == .host else { reply(nil); return }
        broker.awaitResult(commandId, reply: reply)
    }

    func finishTask(_ taskToken: String, reply: @escaping (Bool) -> Void) {
        guard role == .host else { reply(false); return }
        reply(broker.finishTask(taskToken))
    }
}

/// A small authenticated rendezvous. Host registrations are short lived, and
/// only the matching signed appex can resolve a command submitted by Safari.
private final class SafariBridgeBroker {
    private struct PendingCommand {
        let command: SafariBridgeCommand
        var result: SafariBridgeResult?
        var waiter: ((String?) -> Void)?
    }

    private let lock = NSLock()
    private var bindings = SafariBridgeTaskBindings()
    private var pending: [String: PendingCommand] = [:]

    func registerTask(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { try bindings.register(taskToken: token); return true }
        catch { return false }
    }

    func registerCommand(_ json: String) -> Bool {
        guard let command = try? SafariBridgeCommand.decode(json) else { return false }
        lock.lock(); defer { lock.unlock() }
        do {
            try bindings.validate(command)
            guard pending[command.commandId] == nil else { return false }
            pending[command.commandId] = PendingCommand(command: command)
            return true
        } catch { return false }
    }

    func submitResult(_ json: String) -> Bool {
        guard let result = try? JSONDecoder().decode(SafariBridgeResult.self, from: Data(json.utf8)) else { return false }
        lock.lock()
        guard var entry = pending[result.commandId] else {
            lock.unlock(); return false
        }
        guard entry.result == nil else { lock.unlock(); return false }
        let command = entry.command
        guard result.matches(command) else { lock.unlock(); return false }
        do {
            try bindings.validate(command)
            try bindings.accept(result, for: command)
        } catch {
            lock.unlock(); return false
        }
        // Safari's result reaches here only after the extension checked the
        // sender tab/frame and matched its content-script nonce.
        entry.result = result
        let waiter = entry.waiter
        entry.waiter = nil
        let encoded = try? Self.encode(result)
        if waiter == nil { pending[command.commandId] = entry }
        else { pending.removeValue(forKey: command.commandId) }
        lock.unlock()
        waiter?(encoded)
        return true
    }

    func awaitResult(_ commandId: String, reply: @escaping (String?) -> Void) {
        lock.lock()
        guard var entry = pending[commandId] else { lock.unlock(); reply(nil); return }
        if let result = entry.result, let json = try? Self.encode(result) {
            pending.removeValue(forKey: commandId)
            lock.unlock()
            reply(json)
        } else {
            entry.waiter = reply
            pending[commandId] = entry
            lock.unlock()
        }
    }

    func finishTask(_ token: String) -> Bool {
        lock.lock()
        guard SafariBridgeTaskBindings.isValidTaskToken(token) else { lock.unlock(); return false }
        let wasActive = bindings.finish(taskToken: token)
        let abandoned = pending.values
            .filter { $0.command.taskToken == token }
            .compactMap(\.waiter)
        pending = pending.filter { $0.value.command.taskToken != token }
        lock.unlock()
        abandoned.forEach { $0(nil) }
        return wasActive
    }

    private static func encode(_ result: SafariBridgeResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }
}

