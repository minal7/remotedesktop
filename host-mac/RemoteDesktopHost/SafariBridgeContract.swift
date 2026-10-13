import Foundation

enum SafariBridgeOperation: String, Codable, CaseIterable {
    case ping, openTab, endTask, snapshot, click, type, key, scroll, select, drag
    case navigate, wait, captureVisibleTab, setFiles
}

enum SafariBridgeStatus: String, Codable { case ok, error }

enum SafariBridgeError: String, Codable, CaseIterable {
    case bridgeUnavailable, helperMissingFromBundle, helperNotRegistered, helperRequiresApproval, invalidPayload
    case unauthorizedTask, staleTask, wrongTab, missingPageAccess, tabNotFound
    case operationFailed, unsupported, targetGone, targetChanged, targetCovered
    case disabledTarget, credentialHandoff, inactiveTab, fileInjectionUnsupported
}

/// Host-authored typed operations. `payloadJSON` is generated from validated
/// Swift values; it is never JavaScript or model-supplied executable text.
struct SafariBridgeCommand: Codable, Equatable {
    let schemaVersion: Int
    let commandId: String
    let taskToken: String
    let operation: SafariBridgeOperation
    let tabId: Int?
    let windowId: Int?
    let nonce: String?
    let url: String?
    let payloadJSON: String?

    init(commandId: UUID = UUID(), taskToken: String, operation: SafariBridgeOperation,
         tabId: Int? = nil, windowId: Int? = nil, nonce: String? = nil,
         url: String? = nil, payload: [String: Any]? = nil) {
        schemaVersion = 1
        self.commandId = commandId.uuidString.lowercased()
        self.taskToken = taskToken
        self.operation = operation
        self.tabId = tabId
        self.windowId = windowId
        self.nonce = nonce
        self.url = url
        if let payload, JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           data.count <= Self.maximumPayloadBytes {
            payloadJSON = String(data: data, encoding: .utf8)
        } else { payloadJSON = nil }
    }

    static let maximumPayloadBytes = 400 * 1024
    var payload: [String: Any]? {
        guard let payloadJSON, let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    var isStructurallyValid: Bool {
        guard schemaVersion == 1,
              UUID(uuidString: commandId)?.uuidString.lowercased() == commandId,
              Self.isValidTaskToken(taskToken) else { return false }
        switch operation {
        case .openTab, .navigate:
            guard let url, Self.isAllowedURL(url) else { return false }
        default: guard url == nil else { return false }
        }
        if operation == .openTab || operation == .endTask {
            guard tabId == nil, windowId == nil, nonce == nil else { return false }
        } else if operation == .ping {
            guard validBinding, let nonce, (1...128).contains(nonce.utf8.count) else { return false }
        } else if operation == .captureVisibleTab {
            guard validBinding, nonce == nil, payloadJSON == nil else { return false }
        } else {
            guard validBinding, nonce == nil, let payloadJSON,
                  payloadJSON.utf8.count <= Self.maximumPayloadBytes,
                  payload != nil else { return false }
        }
        if operation == .openTab || operation == .endTask { return payloadJSON == nil }
        return true
    }

    private var validBinding: Bool { tabId.map { $0 >= 0 } == true && windowId.map { $0 >= 0 } == true }

    static func isValidTaskToken(_ token: String) -> Bool {
        token.utf8.count == 32 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isAllowedURL(_ value: String) -> Bool {
        guard value.utf8.count <= 4096, let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.fragment == nil || scheme == "https",
              !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    func encodedJSON() throws -> String {
        guard isStructurallyValid else { throw SafariBridgeContractError.invalidCommand }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> SafariBridgeCommand {
        let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        guard value.isStructurallyValid else { throw SafariBridgeContractError.invalidCommand }
        return value
    }
}

struct SafariBridgeResult: Codable, Equatable {
    let schemaVersion: Int
    let commandId: String
    let taskToken: String
    let operation: SafariBridgeOperation
    let status: SafariBridgeStatus
    let tabId: Int?
    let windowId: Int?
    let nonce: String?
    let documentId: String?
    let resultJSON: String?
    let error: SafariBridgeError?

    init(command: SafariBridgeCommand, status: SafariBridgeStatus, tabId: Int? = nil,
         windowId: Int? = nil, nonce: String? = nil, documentId: String? = nil,
         resultJSON: String? = nil, error: SafariBridgeError? = nil) {
        schemaVersion = 1; commandId = command.commandId; taskToken = command.taskToken
        operation = command.operation; self.status = status; self.tabId = tabId
        self.windowId = windowId; self.nonce = nonce; self.documentId = documentId
        self.resultJSON = resultJSON; self.error = error
    }

    func matches(_ command: SafariBridgeCommand) -> Bool {
        guard schemaVersion == 1, commandId == command.commandId,
              taskToken == command.taskToken, operation == command.operation else { return false }
        if status == .error { return error != nil && resultJSON == nil }
        guard error == nil else { return false }
        switch operation {
        case .openTab: return (tabId ?? -1) >= 0 && (windowId ?? -1) >= 0
        case .ping: return tabId == command.tabId && windowId == command.windowId && nonce == command.nonce && !(documentId ?? "").isEmpty
        case .endTask: return (tabId == nil) == (windowId == nil) && nonce == nil && documentId == nil
        default:
            return tabId == command.tabId && windowId == command.windowId && nonce == nil
                && (resultJSON?.utf8.count ?? 0) <= Self.maximumResultBytes
        }
    }
    static let maximumResultBytes = 2 * 1024 * 1024
}

enum SafariBridgeContractError: Error { case invalidCommand, mismatchedReply, taskNotAuthorized, wrongTab }

struct SafariBridgeTaskBindings {
    private(set) var tabsByTask: [String: SafariBridgeTabBinding] = [:]
    private var activeTasks = Set<String>()
    static func isValidTaskToken(_ token: String) -> Bool { SafariBridgeCommand.isValidTaskToken(token) }
    mutating func register(taskToken: String) throws {
        guard SafariBridgeCommand.isValidTaskToken(taskToken), activeTasks.insert(taskToken).inserted else {
            throw SafariBridgeContractError.taskNotAuthorized
        }
    }
    mutating func validate(_ command: SafariBridgeCommand) throws {
        guard command.isStructurallyValid, activeTasks.contains(command.taskToken) else { throw SafariBridgeContractError.taskNotAuthorized }
        if command.operation != .openTab && command.operation != .endTask {
            guard let tabId = command.tabId, let windowId = command.windowId,
                  tabsByTask[command.taskToken] == SafariBridgeTabBinding(tabId: tabId, windowId: windowId) else {
                throw SafariBridgeContractError.wrongTab
            }
        }
    }
    mutating func accept(_ result: SafariBridgeResult, for command: SafariBridgeCommand) throws {
        guard result.matches(command), activeTasks.contains(command.taskToken) else { throw SafariBridgeContractError.mismatchedReply }
        if command.operation == .openTab && result.status == .ok {
            guard let tabId = result.tabId, let windowId = result.windowId else { throw SafariBridgeContractError.wrongTab }
            tabsByTask[command.taskToken] = SafariBridgeTabBinding(tabId: tabId, windowId: windowId)
        } else if command.operation == .endTask && result.status == .ok {
            if let tabId = result.tabId, let windowId = result.windowId,
               tabsByTask[command.taskToken] != SafariBridgeTabBinding(tabId: tabId, windowId: windowId) {
                throw SafariBridgeContractError.wrongTab
            }
            activeTasks.remove(command.taskToken); tabsByTask.removeValue(forKey: command.taskToken)
        }
    }
    mutating func finish(taskToken: String) -> Bool {
        guard activeTasks.remove(taskToken) != nil else { return false }
        tabsByTask.removeValue(forKey: taskToken); return true
    }
}

struct SafariBridgeTabBinding: Equatable { let tabId: Int; let windowId: Int }
