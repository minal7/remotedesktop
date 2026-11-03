import AppKit
import Darwin
import Foundation

enum HostRelaunch {
    static let command = "--relaunch-after-pid"
    private static let maximumWait: TimeInterval = 60

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        timeout: TimeInterval = maximumWait,
        isProcessRunning: (pid_t) -> Bool = processIsRunning,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        launch: (URL) throws -> Void = launchApplication
    ) -> Int32? {
        guard arguments.dropFirst().first == command else { return nil }
        let args = Array(arguments.dropFirst(2))
        guard args.count == 2, let pid = pid_t(args[0]), pid > 1,
              let bundleIdentifier, !bundleIdentifier.isEmpty else {
            writeError("invalid relaunch request")
            return 2
        }

        let canonicalBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let requestedBundleURL = URL(fileURLWithPath: args[1])
            .resolvingSymlinksInPath().standardizedFileURL
        guard canonicalBundleURL == requestedBundleURL,
              Bundle(url: canonicalBundleURL)?.bundleIdentifier == bundleIdentifier else {
            writeError("relaunch target does not match this app bundle")
            return 2
        }

        guard waitForExit(pid, timeout: timeout, isProcessRunning: isProcessRunning, sleep: sleep) else {
            writeError("old host did not exit before relaunch deadline")
            return 3
        }
        do {
            try launch(canonicalBundleURL)
            return 0
        } catch {
            writeError("could not open replacement host: \(error.localizedDescription)")
            return 4
        }
    }

    static func waitForExit(
        _ pid: pid_t,
        timeout: TimeInterval,
        isProcessRunning: (pid_t) -> Bool,
        sleep: (TimeInterval) -> Void
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while isProcessRunning(pid) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            sleep(0.05)
        }
        return true
    }

    static func startAfterExit(bundleURL: URL) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw RelaunchError.executableUnavailable
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [command, String(Darwin.getpid()), bundleURL.path]
        try process.run()
    }

    static func processIsRunning(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func launchApplication(_ bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundleURL.path]
        try process.run()
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("RemoteDesktopHost: \(message)\n".utf8))
    }

    enum RelaunchError: Error {
        case executableUnavailable
    }
}
