import Foundation

enum Config {
    /// CloudKit container used for signaling. Must match the host's
    /// container and be attached to the iOS App ID.
    static let cloudKitContainerIdentifier = "iCloud.com.threadmark.remotedesktop"

    /// Local fallback STUN list. The live list is fetched from the
    /// CloudKit `ICEConfig` record; this one is only used when that
    /// fetch fails.
    static let stunServers = [
        "stun:stun.cloudflare.com:3478",
        "stun:stun.l.google.com:19302",
    ]

    /// Protocol version advertised in `hello`.
    static let protocolVersion = 1

    /// Negotiated independently from the base remote-control protocol so
    /// Windows, Android, and staggered upgrades retain ordinary remote access.
    /// AI Computer Use starts only when both iOS and the Mac advertise v1.
    static let orderedComputerUseControlsVersion = 1

    /// Release version advertised to the paired host. The release workflow
    /// supplies MARKETING_VERSION, so wire metadata always matches the binary.
    static var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    /// Whether the client should negotiate and render the host's
    /// system-audio track.
    static let enableHostAudio = true
}
