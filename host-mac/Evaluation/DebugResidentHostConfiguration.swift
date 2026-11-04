import Foundation

#if DEBUG
/// Opt-in configuration for a second, headless real HostSession used only by
/// an explicitly launched Debug candidate. Release builds reject the selector.
struct DebugResidentHostConfiguration: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case r0, latency }
    static let argument = "--debug-r0-resident-host"
    static let identityEnvironmentKey = "REMOTE_DESKTOP_R0_HOST_ID"
    static let latencyArgument = "--debug-latency-host"
    static let latencyIdentityEnvironmentKey = "REMOTE_DESKTOP_LATENCY_HOST_ID"
    static let credentialService =
        "com.threadmark.remotedesktop.local-computer-use.r0-test.v1"
    static let latencyCredentialService =
        "com.threadmark.remotedesktop.local-computer-use.latency-test.v1"

    let mode: Mode
    let hostID: String
    let lockIdentity: String
    var hostDisplayName: String { mode == .r0 ? "Remote Desktop R0 Test" : (Host.current().localizedName ?? ProcessInfo.processInfo.hostName) }
    var credentialServiceName: String { mode == .r0 ? Self.credentialService : Self.latencyCredentialService }
    var allowsExternalComputerUseServices: Bool { mode == .r0 }
    var allowsPersonalMemory: Bool { mode == .r0 }

    static func isSelected(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.dropFirst().contains(argument)
            || environment[identityEnvironmentKey] != nil
            || arguments.dropFirst().contains(latencyArgument)
            || environment[latencyIdentityEnvironmentKey] != nil
    }

    static func parse(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        let mode: Mode
        let rawID: String?
        if Array(arguments.dropFirst()) == [argument], environment[latencyIdentityEnvironmentKey] == nil {
            mode = .r0; rawID = environment[identityEnvironmentKey]
        } else if Array(arguments.dropFirst()) == [latencyArgument], environment[identityEnvironmentKey] == nil {
            mode = .latency; rawID = environment[latencyIdentityEnvironmentKey]
        } else { return nil }
        guard let rawID,
              rawID.utf8.count == 36,
              let uuid = UUID(uuidString: rawID) else {
            return nil
        }
        let canonicalID = uuid.uuidString
        return Self(
            mode: mode,
            hostID: canonicalID,
            lockIdentity: mode == .r0 ? "com.threadmark.remotedesktop.host.r0-test" : "com.threadmark.remotedesktop.host.latency-test")
    }

    var taskLedgerURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(mode == .r0 ? "Remote Desktop Host R0 Test" : "Remote Desktop Host Latency Test", isDirectory: true)
            .appendingPathComponent("Computer Use Tasks", isDirectory: true)
            .appendingPathComponent("processed-prompts.json")
    }
}
#endif
