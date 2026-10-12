import Foundation

enum SafariBridgeXPCNames {
    static let appGroup = "group.com.threadmark.remotedesktop"
    static let hostService = "group.com.threadmark.remotedesktop.safari-bridge-host"
    static let extensionService = "group.com.threadmark.remotedesktop.safari-bridge-extension"
    static var hostBundleIdentifier: String {
        configuredInfo["SafariBridgeHostIdentifier"] as? String
            ?? "com.threadmark.remotedesktop.host"
    }
    static var extensionBundleIdentifier: String {
        configuredInfo["SafariBridgeExtensionIdentifier"] as? String
            ?? "com.threadmark.remotedesktop.host.safari"
    }
    static var helperBundleIdentifier: String {
        configuredInfo["SafariBridgeHelperIdentifier"] as? String
            ?? "com.threadmark.remotedesktop.host.bridge-broker"
    }
    static var safariExtensionIdentifier: String { extensionBundleIdentifier }
    static let teamIdentifier = "V9AX39SPJD"

    private static var configuredInfo: [String: Any] {
        if let info = Bundle.main.infoDictionary,
           info["SafariBridgeHostIdentifier"] != nil { return info }
        var candidate = URL(fileURLWithPath: CommandLine.arguments.first ?? "").standardizedFileURL
        for _ in 0..<6 {
            candidate.deleteLastPathComponent()
            if candidate.pathExtension == "app", let info = Bundle(url: candidate)?.infoDictionary,
               info["SafariBridgeHostIdentifier"] != nil { return info }
        }
        return Bundle.main.infoDictionary ?? [:]
    }
}

@objc protocol SafariBridgeBrokerXPC {
    func registerTask(_ taskToken: String, reply: @escaping (Bool) -> Void)
    func registerCommand(_ json: String, reply: @escaping (Bool) -> Void)
    func submitResult(_ json: String, reply: @escaping (Bool) -> Void)
    func awaitResult(_ commandId: String, reply: @escaping (String?) -> Void)
    func finishTask(_ taskToken: String, reply: @escaping (Bool) -> Void)
}

enum SafariBridgeCodeSigning {
    static func requirement(for identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(SafariBridgeXPCNames.teamIdentifier)\" and identifier = \"\(identifier)\""
    }
}

