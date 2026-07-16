import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

enum PermissionKind: Equatable {
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
