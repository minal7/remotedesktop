import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Security

enum HostPermissionHistory {
    static let grantedVersionKey = "PermissionsGrantedVersion"
    static let grantedRequirementKey = "PermissionsGrantedRequirement"

    static let currentRequirement: String? = {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }()

    static func recordSuccessfulGrants(
        version: String,
        designatedRequirement: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let designatedRequirement, !designatedRequirement.isEmpty else { return }
        defaults.set(version, forKey: grantedVersionKey)
        defaults.set(designatedRequirement, forKey: grantedRequirementKey)
    }

    static func previouslyGranted(defaults: UserDefaults = .standard) -> Bool {
        // Older hosts recorded successful core grants with this setup flag.
        defaults.bool(forKey: "CompletedFirstRunSetup")
            || (defaults.string(forKey: grantedVersionKey) != nil
                && defaults.string(forKey: grantedRequirementKey) != nil)
    }
}

struct HostPermissionSetupState {
    private var settingsOpenedAt: [PermissionKind: TimeInterval] = [:]
    private var previousScreenGrant: Bool?
    private(set) var didRequestRestart = false

    mutating func openedSettings(for permission: PermissionKind, now: TimeInterval) {
        // Reopening Settings must not hide Fix once the five-second wait passed.
        if settingsOpenedAt[permission] == nil { settingsOpenedAt[permission] = now }
    }

    func offersFix(for permission: PermissionKind, granted: Bool, previouslyGranted: Bool, now: TimeInterval) -> Bool {
        guard permission != .microphone, !granted else { return false }
        return previouslyGranted || settingsOpenedAt[permission].map { now - $0 >= 5 } == true
    }

    mutating func screenGrantRequiresRestart(_ granted: Bool) -> Bool {
        defer { previousScreenGrant = granted }
        guard previousScreenGrant == false, granted, !didRequestRestart else { return false }
        didRequestRestart = true
        return true
    }
}

/// This operation is exposed only by the person's explicit Fix button.
/// Fixed arguments and an exact app-ID allowlist prevent resetting other apps.
enum HostPermissionRepair {
    static func resetArguments(for permission: PermissionKind, bundleIdentifier: String) throws -> [String] {
        guard bundleIdentifier == "com.threadmark.remotedesktop.host"
            || bundleIdentifier == "com.threadmark.remotedesktop.host.debug" else {
            throw RepairError.unavailable
        }
        let service: String
        switch permission {
        case .screenRecording: service = "ScreenCapture"
        case .accessibility: service = "Accessibility"
        case .microphone: throw RepairError.unavailable
        }
        return ["reset", service, bundleIdentifier]
    }

    @MainActor
    static func fix(
        _ permission: PermissionKind,
        isGranted: () -> Bool,
        reset: (PermissionKind) async throws -> Void,
        request: (PermissionKind) -> Void,
        openSettings: (PermissionKind) -> Void
    ) async throws {
        guard permission != .microphone, !isGranted() else { return }
        do {
            try await reset(permission)
            request(permission)
            openSettings(permission)
        } catch {
            openSettings(permission)
            throw error
        }
    }

    static func resetOwnGrant(for permission: PermissionKind) async throws {
        guard !HostRuntimeContext.isRunningUnitTests,
              let identifier = Bundle.main.bundleIdentifier else {
            throw RepairError.unavailable
        }
        let arguments = try resetArguments(for: permission, bundleIdentifier: identifier)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RepairError.unavailable)
                    }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
        }
    }

    enum RepairError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Select Remote Desktop Host in Settings, click −, then click Allow again."
        }
    }
}

enum PermissionKind: Hashable {
    case screenRecording
    case accessibility
    case microphone

    var systemSettingsURL: URL? {
        let fragment: String
        switch self {
        case .screenRecording:
            fragment = "Privacy_ScreenCapture"
        case .accessibility:
            fragment = "Privacy_Accessibility"
        case .microphone:
            fragment = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(fragment)")
    }
}

/// Abstracts the two TCC-backed calls `HostSession` cares about so
/// tests can drive the permission state deterministically without
/// depending on the live TCC database.
///
/// The system implementation re-queries on every access — which is
/// exactly what the bug reports needed: after the user grants
/// Accessibility in System Settings we want the next read to reflect
/// reality, not whatever the first call returned at launch.
protocol PermissionsProvider: Sendable {
    func screenRecordingGranted() -> Bool
    func accessibilityGranted() -> Bool
    func microphoneGranted() -> Bool
    func requestPrompt(for permission: PermissionKind)
    func requestMicrophoneAccess(completion: @escaping @Sendable (Bool) -> Void)
    func openSystemSettings(for permission: PermissionKind)

    /// Surface only the permissions required for screen viewing and control.
    /// Mac audio is optional and has its own explicit opt-in action so a user
    /// can finish setup without granting microphone access.
    func requestPrompts()
}

/// Production implementation that talks to the real APIs.
struct SystemPermissionsProvider: PermissionsProvider {
    private let accessibilityTrustCheck: @Sendable () -> Bool
    private let postEventAccessCheck: @Sendable () -> Bool
    private let accessibilityTrustRequest: @Sendable () -> Void
    private let postEventAccessRequest: @Sendable () -> Void

    init(
        accessibilityTrustCheck: @escaping @Sendable () -> Bool = {
            AXIsProcessTrusted()
        },
        postEventAccessCheck: @escaping @Sendable () -> Bool = {
            CGPreflightPostEventAccess()
        },
        accessibilityTrustRequest: @escaping @Sendable () -> Void = {
            let opts = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        },
        postEventAccessRequest: @escaping @Sendable () -> Void = {
            _ = CGRequestPostEventAccess()
        }
    ) {
        self.accessibilityTrustCheck = accessibilityTrustCheck
        self.postEventAccessCheck = postEventAccessCheck
        self.accessibilityTrustRequest = accessibilityTrustRequest
        self.postEventAccessRequest = postEventAccessRequest
    }

    func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func accessibilityGranted() -> Bool {
        // Remote control needs both Accessibility inspection and event
        // synthesis. In particular, preflight PostEvent here instead of
        // waiting for the first CGEvent: on a newly launched or upgraded app,
        // WindowServer can otherwise begin its TCC lookup only when that first
        // event arrives and silently discard a short burst of keystrokes while
        // the lookup is still in flight. Both checks re-read live TCC state,
        // so an older installation's existing grants are adopted immediately.
        accessibilityTrustCheck() && postEventAccessCheck()
    }

    func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPrompt(for permission: PermissionKind) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            accessibilityTrustRequest()
            postEventAccessRequest()
        case .microphone:
            requestMicrophoneAccess { _ in }
        }
    }

    func requestMicrophoneAccess(completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func openSystemSettings(for permission: PermissionKind) {
        guard let url = permission.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func requestPrompts() {
        requestPrompt(for: .screenRecording)
        requestPrompt(for: .accessibility)
    }
}
