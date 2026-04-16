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

    /// Surface the OS-level prompts. Idempotent: after first-run the
    /// system shows these silently or not at all.
    func requestPrompts()
}

/// Production implementation that talks to the real APIs.
struct SystemPermissionsProvider: PermissionsProvider {
    func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func accessibilityGranted() -> Bool {
        // `AXIsProcessTrusted()` reads the current TCC state each
        // call — it is *not* cached. What users hit instead is TCC
        // failing to propagate the grant to an already-running
        // process in some cases; the reliable fix is to re-read on
        // `NSApplication.didBecomeActiveNotification`, which
        // AppDelegate wires up.
        AXIsProcessTrusted()
    }

    func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPrompt(for permission: PermissionKind) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
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
        requestPrompt(for: .microphone)
    }
}
