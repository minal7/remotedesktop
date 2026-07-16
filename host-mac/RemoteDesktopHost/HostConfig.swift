import Foundation

enum HostConfig {
    /// CloudKit container used for signaling. The container must be
    /// attached to the host's App ID in the Apple Developer portal and
    /// listed in `RemoteDesktopHost.entitlements`.
    static let cloudKitContainerIdentifier = "iCloud.com.threadmark.remotedesktop"

    // Base remote-control compatibility remains v1. Optional features such as
    // causally ordered Computer Use controls negotiate their own capability
    // inside the authenticated hello instead of disconnecting legacy peers.
    static let protocolVersion = 1
    static let orderedComputerUseControlsVersion = 1
    static var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }
    /// The build contains the optional system-audio bridge. A session only
    /// enables it after the user separately grants microphone access.
    static let enableSystemAudio = true
    /// Local fallback STUN list. The live list comes from the CloudKit
    /// `ICEConfig` record; this one is only used when that fetch fails.
    static let stunServers = [
        "stun:stun.cloudflare.com:3478",
        "stun:stun.l.google.com:19302",
    ]
}
