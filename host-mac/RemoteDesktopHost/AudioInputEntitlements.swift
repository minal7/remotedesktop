import Foundation
import Security

enum HostBuildValidationError: LocalizedError {
    case entitlementInspectionUnavailable
    case missingAudioInputEntitlement

    var errorDescription: String? {
        switch self {
        case .entitlementInspectionUnavailable:
            return "This build couldn't inspect its signing entitlements. Rebuild the host with Apple Development signing and the hardened runtime Audio Input capability enabled."
        case .missingAudioInputEntitlement:
            return "This build is missing the hardened runtime Audio Input entitlement, so macOS won't show a microphone prompt or list Remote Desktop Host in System Settings. Enable Audio Input in Signing & Capabilities or add com.apple.security.device.audio-input to RemoteDesktopHost.entitlements, then rebuild."
        }
    }
}

enum AudioInputEntitlements {
    private static let entitlementKey = "com.apple.security.device.audio-input" as CFString

    static func validateIfNeeded(systemAudioEnabled: Bool = HostConfig.enableSystemAudio) throws {
        guard systemAudioEnabled else { return }
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw HostBuildValidationError.entitlementInspectionUnavailable
        }

        try validate(systemAudioEnabled: systemAudioEnabled) { entitlement in
            SecTaskCopyValueForEntitlement(task, entitlement, nil)
        }
    }

    static func validate(
        systemAudioEnabled: Bool = HostConfig.enableSystemAudio,
        entitlementValue: (CFString) -> Any?
    ) throws {
        guard systemAudioEnabled else { return }
        guard entitlementEnabled(for: entitlementKey, entitlementValue: entitlementValue) else {
            throw HostBuildValidationError.missingAudioInputEntitlement
        }
    }

    private static func entitlementEnabled(
        for key: CFString,
        entitlementValue: (CFString) -> Any?
    ) -> Bool {
        if let enabled = entitlementValue(key) as? Bool {
            return enabled
        }
        if let enabled = entitlementValue(key) as? NSNumber {
            return enabled.boolValue
        }
        return false
    }
}
