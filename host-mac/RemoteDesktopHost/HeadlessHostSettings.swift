import Foundation

enum HeadlessHostSettings {
    static let startListeningOnLaunchKey = "StartListeningOnLaunch"
    static let pairingCodeFileKey = "PairingCodeFile"

    static var startListeningOnLaunch: Bool {
        UserDefaults.standard.bool(forKey: startListeningOnLaunchKey)
            || CommandLine.arguments.contains("--start-listening")
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
}
