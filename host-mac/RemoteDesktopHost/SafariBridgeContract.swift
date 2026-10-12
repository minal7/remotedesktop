import Foundation

enum SafariBridgeOperation: String, Codable, CaseIterable {
    case ping
    case openTab
    case endTask
}

enum SafariBridgeStatus: String, Codable {
    case ok
    case error
}

enum SafariBridgeError: String, Codable, CaseIterable {
    case bridgeUnavailable
    case helperNotRegistered
    case helperRequiresApproval
    case invalidPayload
    case unauthorizedTask
    case staleTask
    case wrongTab
    case missingPageAccess
    case tabNotFound
    case operationFailed
    case unsupported
}

struct SafariBridgeCommand: Codable, Equatable {
    let schemaVersion: Int
    let commandId: String
    let taskToken: String
    let operation: SafariBridgeOperation
    let tabId: Int?
    let windowId: Int?
    let nonce: String?
    let url: String?

    init(
        commandId: UUID = UUID(),
        taskToken: String,
        operation: SafariBridgeOperation,
        tabId: Int? = nil,
        windowId: Int? = nil,
        nonce: String? = nil,
        url: String? = nil
    ) {
        schemaVersion = 1
        self.commandId = commandId.uuidString.lowercased()
        self.taskToken = taskToken
        self.operation = operation
        self.tabId = tabId
        self.windowId = windowId
        self.nonce = nonce
        self.url = url
    }

    var isStructurallyValid: Bool {
        guard schemaVersion == 1,
              UUID(uuidString: commandId)?.uuidString.lowercased() == commandId,
              taskToken.count == 32,
              taskToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return false }

        switch operation {
        case .openTab:
            guard tabId == nil, windowId == nil, nonce == nil,
                  let url, let parsed = URL(string: url),
                  parsed.scheme?.lowercased() == "https",
                  parsed.user == nil, parsed.password == nil,
                  parsed.port == nil || parsed.port == 443,
                  let host = parsed.host?.lowercased(), Self.isAllowed(host: host, path: parsed.path) else { return false }
        case .ping:
            guard let tabId, tabId >= 0, let windowId, windowId >= 0,
                  let nonce, (1...128).contains(nonce.utf8.count), url == nil else { return false }
        case .endTask:
            guard tabId == nil, windowId == nil, nonce == nil, url == nil else { return false }
        }
        return true
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> SafariBridgeCommand {
        let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        guard value.isStructurallyValid else { throw SafariBridgeContractError.invalidCommand }
        return value
    }

    private static func isAllowed(host: String, path: String) -> Bool {
        switch host {
        case "mail.google.com", "drive.google.com", "www.dropbox.com": return true
        case "www.google.com": return path == "/travel" || path.hasPrefix("/travel/")
        default: return false
        }
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
    let error: SafariBridgeError?

    init(
        command: SafariBridgeCommand,
        status: SafariBridgeStatus,
        tabId: Int? = nil,
        windowId: Int? = nil,
        nonce: String? = nil,
        documentId: String? = nil,
        error: SafariBridgeError? = nil
    ) {
        schemaVersion = 1
        commandId = command.commandId
        taskToken = command.taskToken
        operation = command.operation
        self.status = status
        self.tabId = tabId
        self.windowId = windowId
        self.nonce = nonce
        self.documentId = documentId
        self.error = error
    }

    func matches(_ command: SafariBridgeCommand) -> Bool {
        guard schemaVersion == 1, commandId == command.commandId,
              taskToken == command.taskToken, operation == command.operation else { return false }
        if status == .error {
            return error != nil
        } else if error != nil {
            return false
        }
        switch command.operation {
        case .openTab:
            return status == .error || ((tabId ?? -1) >= 0 && (windowId ?? -1) >= 0)
        case .ping:
            return tabId == command.tabId && windowId == command.windowId && nonce == command.nonce
                && (status == .error || !(documentId ?? "").isEmpty)
        case .endTask:
            let tabPairIsComplete = (tabId == nil) == (windowId == nil)
            return tabPairIsComplete && (status == .error || (nonce == nil && documentId == nil))
        }
    }
}

enum SafariBridgeContractError: Error {
    case invalidCommand
    case mismatchedReply
    case taskNotAuthorized
    case wrongTab
}

/// Tracks the single tab a task may access. The host registers the token before
/// dispatching `openTab`; subsequent pings must name the exact returned tab.
struct SafariBridgeTaskBindings {
    private(set) var tabsByTask: [String: SafariBridgeTabBinding] = [:]
    private var activeTasks = Set<String>()

    mutating func register(taskToken: String) throws {
        guard Self.isValidTaskToken(taskToken), activeTasks.insert(taskToken).inserted else {
            throw SafariBridgeContractError.taskNotAuthorized
        }
    }

    mutating func validate(_ command: SafariBridgeCommand) throws {
        guard command.isStructurallyValid, activeTasks.contains(command.taskToken) else {
            throw SafariBridgeContractError.taskNotAuthorized
        }
        if command.operation == .ping {
            guard let tabId = command.tabId, let windowId = command.windowId,
                  tabsByTask[command.taskToken] == SafariBridgeTabBinding(tabId: tabId, windowId: windowId) else {
                throw SafariBridgeContractError.wrongTab
            }
        }
    }

    mutating func accept(_ result: SafariBridgeResult, for command: SafariBridgeCommand) throws {
        guard result.matches(command) else { throw SafariBridgeContractError.mismatchedReply }
        guard activeTasks.contains(command.taskToken) else { throw SafariBridgeContractError.taskNotAuthorized }
        if command.operation == .openTab, result.status == .ok {
            guard let tabId = result.tabId, tabId >= 0,
                  let windowId = result.windowId, windowId >= 0 else { throw SafariBridgeContractError.wrongTab }
            tabsByTask[command.taskToken] = SafariBridgeTabBinding(tabId: tabId, windowId: windowId)
        } else if command.operation == .endTask, result.status == .ok {
            if let tabId = result.tabId, let windowId = result.windowId {
                guard tabsByTask[command.taskToken] == SafariBridgeTabBinding(tabId: tabId, windowId: windowId) else {
                    throw SafariBridgeContractError.wrongTab
                }
            } else {
                guard result.tabId == nil, result.windowId == nil else { throw SafariBridgeContractError.wrongTab }
            }
            activeTasks.remove(command.taskToken)
            tabsByTask.removeValue(forKey: command.taskToken)
        }
    }

    static func isValidTaskToken(_ token: String) -> Bool {
        token.utf8.count == 32 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    mutating func finish(taskToken: String) -> Bool {
        guard activeTasks.remove(taskToken) != nil else { return false }
        tabsByTask.removeValue(forKey: taskToken)
        return true
    }
}

struct SafariBridgeTabBinding: Equatable {
    let tabId: Int
    let windowId: Int
}
