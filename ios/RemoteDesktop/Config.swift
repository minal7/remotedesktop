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

    /// Host audio is temporarily disabled while we stabilize the
    /// LiveKit/WebRTC audio-session behavior on iOS.
    static let enableHostAudio = true
}
