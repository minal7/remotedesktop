import AppKit
import ApplicationServices
import Foundation

protocol RemoteDesktopMailAutomationPreflighting: Sendable {
    func ensureAuthorized() async throws
}

/// Requests the narrowly scoped Mail Automation grant after mobile approval
/// but before the durable mutation claim. A first-use denial is therefore a
/// clear, retryable setup error rather than an ambiguous email mutation.
struct SystemRemoteDesktopMailAutomationPreflight:
    RemoteDesktopMailAutomationPreflighting
{
    private static let mailBundleID = "com.apple.mail"
    private static let applicationNotFoundStatus = OSStatus(-600)
    private static let maximumReadinessChecks = 100
    private static let readinessCheckInterval: TimeInterval = 0.1
    private static let maximumPermissionAttempts = 5

    static let denialMessage = """
    Allow Remote Desktop Host in System Settings > Privacy & Security > Automation, then send a new request.
    """

    func ensureAuthorized() async throws {
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try Self.ensureMailIsRunning()
            try Self.requestAutomationPermission()
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func ensureMailIsRunning() throws {
        var didRequestLaunch = false
        for _ in 0 ..< maximumReadinessChecks {
            try Task.checkCancellation()
            let runningApplications = NSRunningApplication.runningApplications(
                withBundleIdentifier: mailBundleID)
            if runningApplications.contains(where: {
                !$0.isTerminated && $0.isFinishedLaunching
            }) {
                return
            }

            if runningApplications.isEmpty && !didRequestLaunch {
                try launchMail()
                didRequestLaunch = true
            }
            Thread.sleep(forTimeInterval: readinessCheckInterval)
        }
        throw MCPClientError.toolFailed(
            "Open Mail on this Mac, then send a new request.")
    }

    private static func launchMail() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-b", mailBundleID]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MCPClientError.toolFailed(
                "Open Mail on this Mac, then send a new request.")
        }
        guard process.terminationStatus == 0 else {
            throw MCPClientError.toolFailed(
                "Open Mail on this Mac, then send a new request.")
        }
    }

    private static func requestAutomationPermission() throws {
        let bundleID = Data("com.apple.mail".utf8)
        var target = AEAddressDesc()
        let createStatus = bundleID.withUnsafeBytes { bytes in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bytes.baseAddress,
                bytes.count,
                &target)
        }
        guard createStatus == noErr else {
            throw MCPClientError.toolFailed(
                "macOS could not check Mail Automation permission. Send a new request after reopening the host app.")
        }
        defer { AEDisposeDesc(&target) }

        try authorizeWithRetry {
            AEDeterminePermissionToAutomateTarget(
                &target,
                typeWildCard,
                typeWildCard,
                true)
        } waitUntilMailReady: {
            try ensureMailIsRunning()
        } pause: {
            Thread.sleep(forTimeInterval: readinessCheckInterval)
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` can briefly return -600 after
    /// LaunchServices has created Mail's process but before its Apple Event
    /// endpoint is ready. Retry only that transient result; an explicit denial
    /// or any other status remains terminal and never reaches the mutation
    /// ledger.
    static func authorizeWithRetry(
        maximumAttempts: Int = maximumPermissionAttempts,
        request: () -> OSStatus,
        waitUntilMailReady: () throws -> Void,
        pause: () -> Void
    ) throws {
        precondition(maximumAttempts > 0)
        var lastStatus = applicationNotFoundStatus
        for attempt in 0 ..< maximumAttempts {
            try Task.checkCancellation()
            let permissionStatus = request()
            if permissionStatus == noErr { return }
            if permissionStatus == OSStatus(errAEEventNotPermitted) {
                throw MCPClientError.toolFailed(denialMessage)
            }
            lastStatus = permissionStatus
            guard permissionStatus == applicationNotFoundStatus,
                  attempt + 1 < maximumAttempts else {
                break
            }
            try waitUntilMailReady()
            pause()
        }
        throw MCPClientError.toolFailed(
            "macOS could not authorize Mail Automation (status \(lastStatus)). Send a new request after checking System Settings > Privacy & Security > Automation.")
    }
}
