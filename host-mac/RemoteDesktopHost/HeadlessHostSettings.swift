import Foundation

enum HeadlessHostSettings {
    static let startAtLoginKey = "StartAtLogin"
    static let startListeningOnLaunchKey = "StartListeningOnLaunch"
    static let pairingCodeFileKey = "PairingCodeFile"

    static var startAtLogin: Bool {
        bool(forKey: startAtLoginKey, defaultValue: true)
    }

    static var startListeningOnLaunch: Bool {
        startListeningOnLaunch(
            defaults: .standard,
            arguments: CommandLine.arguments)
    }

    static func startAtLogin(defaults: UserDefaults) -> Bool {
        bool(forKey: startAtLoginKey, defaultValue: true, defaults: defaults)
    }

    static func startListeningOnLaunch(
        defaults: UserDefaults,
        arguments: [String]
    ) -> Bool {
        arguments.contains("--start-listening")
            || bool(
                forKey: startListeningOnLaunchKey,
                defaultValue: true,
                defaults: defaults)
    }

    static var pairingCodeFileURL: URL? {
        if let rawValue = UserDefaults.standard.string(forKey: pairingCodeFileKey),
           rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return URL(fileURLWithPath: (rawValue as NSString).expandingTildeInPath)
        }

        guard startListeningOnLaunch else { return nil }
        return defaultPairingCodeFileURL
    }

    private static var defaultPairingCodeFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemoteDesktopHost", isDirectory: true)
            .appendingPathComponent("pairing-code.txt")
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let value = defaults.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }
}
