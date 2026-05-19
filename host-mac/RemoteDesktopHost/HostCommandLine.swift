import Foundation

enum HostCommandLine {
    static func runIfNeeded(arguments: [String] = CommandLine.arguments) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { return nil }

        switch command {
        case "--help", "-h":
            printHelp()
            return 0
        case "--check-permissions":
            let snapshot = PermissionSnapshot.read()
            print(snapshot.humanReadable)
            return snapshot.ok ? 0 : 2
        case "--check-permissions-json":
            let snapshot = PermissionSnapshot.read()
            print(snapshot.json)
            return snapshot.ok ? 0 : 2
        case "--request-permissions":
            requestPermissions()
            let snapshot = PermissionSnapshot.read()
            print(snapshot.humanReadable)
            return snapshot.ok ? 0 : 2
        case "--ssh-permission-report":
            printSSHPermissionReport()
            return 0
        case "--start-listening":
            return nil
        default:
            return nil
        }
    }

    private static func printHelp() {
        print("""
        RemoteDesktopHost command line

        Usage:
          RemoteDesktopHost --check-permissions
          RemoteDesktopHost --check-permissions-json
          RemoteDesktopHost --request-permissions
          RemoteDesktopHost --ssh-permission-report
          RemoteDesktopHost --start-listening

        --request-permissions asks macOS to surface available TCC prompts. macOS
        still requires user or MDM approval for protected services such as Screen
        Recording and Microphone.
        """)
    }

    private static func requestPermissions() {
        let provider = SystemPermissionsProvider()
        provider.requestPrompt(for: .screenRecording)
        provider.requestPrompt(for: .accessibility)

        guard HostConfig.enableSystemAudio else { return }
        let semaphore = DispatchSemaphore(value: 0)
        provider.requestMicrophoneAccess { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
    }

    private static func printSSHPermissionReport() {
        print("""
        Plain SSH cannot grant every permission required by Remote Desktop Host.

        SSH can install the app, set defaults, install a LaunchAgent, launch the
        host, request prompts, and check permission status.

        macOS still requires user or management approval for protected TCC
        services. User-approved MDM can configure Accessibility/PostEvent and can
        delegate Screen Recording approval to standard users. Screen Recording
        and Microphone cannot be silently granted by a local SSH script.
        """)
    }
}

private struct PermissionSnapshot {
    let screenRecording: Bool
    let accessibility: Bool
    let microphone: Bool
    let audioRequired: Bool
    let entitlementError: String?

    var ok: Bool {
        screenRecording
            && accessibility
            && (!audioRequired || microphone)
            && entitlementError == nil
    }

    static func read() -> PermissionSnapshot {
        let provider = SystemPermissionsProvider()
        let entitlementError: String?
        do {
            try AudioInputEntitlements.validateIfNeeded()
            entitlementError = nil
        } catch {
            entitlementError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        return PermissionSnapshot(
            screenRecording: provider.screenRecordingGranted(),
            accessibility: provider.accessibilityGranted(),
            microphone: provider.microphoneGranted(),
            audioRequired: HostConfig.enableSystemAudio,
            entitlementError: entitlementError)
    }

    var humanReadable: String {
        var lines = [
            "Screen Recording: \(screenRecording ? "granted" : "missing")",
            "Accessibility: \(accessibility ? "granted" : "missing")",
        ]

        if audioRequired {
            lines.append("Microphone: \(microphone ? "granted" : "missing")")
        } else {
            lines.append("Microphone: not required")
        }

        if let entitlementError {
            lines.append("Build: \(entitlementError)")
        }

        lines.append(ok ? "All required permissions are ready." : "One or more permissions still need approval.")
        return lines.joined(separator: "\n")
    }

    var json: String {
        let fields: [(String, String)] = [
            ("screenRecording", screenRecording ? "true" : "false"),
            ("accessibility", accessibility ? "true" : "false"),
            ("microphone", microphone ? "true" : "false"),
            ("audioRequired", audioRequired ? "true" : "false"),
            ("ok", ok ? "true" : "false"),
            ("entitlementError", entitlementError.map { "\"\(Self.escape($0))\"" } ?? "null"),
        ]
        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
