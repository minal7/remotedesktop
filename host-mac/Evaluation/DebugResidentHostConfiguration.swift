import Foundation

#if DEBUG
/// Opt-in configuration for a second, headless real HostSession used only by
/// an explicitly launched Debug candidate. Release builds reject the selector.
struct DebugResidentHostConfiguration: Equatable, Sendable {
    static let argument = "--debug-r0-resident-host"
    static let identityEnvironmentKey = "REMOTE_DESKTOP_R0_HOST_ID"
    static let credentialService =
        "com.threadmark.remotedesktop.local-computer-use.r0-test.v1"

    let hostID: String
    let lockIdentity: String
    let hostDisplayName = "Remote Desktop R0 Test"

    static func isSelected(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.dropFirst().contains(argument)
            || environment[identityEnvironmentKey] != nil
    }

    static func parse(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        guard isSelected(arguments: arguments, environment: environment),
              Array(arguments.dropFirst()) == [argument],
              let rawID = environment[identityEnvironmentKey],
              rawID.utf8.count == 36,
              let uuid = UUID(uuidString: rawID) else {
            return nil
        }
        let canonicalID = uuid.uuidString
        return Self(
            hostID: canonicalID,
            lockIdentity: "com.threadmark.remotedesktop.host.r0-test")
    }

    var taskLedgerURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host R0 Test", isDirectory: true)
            .appendingPathComponent("Computer Use Tasks", isDirectory: true)
            .appendingPathComponent("processed-prompts.json")
    }
}
#endif
