# RemoteDesktop Mac host

Menu bar agent that waits for an iPad/iPhone client to pair with a
6-digit code, then streams the main display (plus system audio) and
injects input events received over the wire.

## Why this isn't an App Store app

CGEvent-based input injection requires **Accessibility** permission,
which is incompatible with the macOS App Sandbox. The agent ships as
a user-installed, signed, notarized menu bar app — same deployment
model as TeamViewer, AnyDesk, Jump Desktop Connect, and friends.
The iOS client on the other side *is* App Store compliant.

## Build

Requires:

- Xcode 15.4+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- macOS 14+ to run (ScreenCaptureKit + newer TCC APIs)

```sh
cd host-mac
xcodegen generate
open RemoteDesktopHost.xcodeproj
```

Because signaling is CloudKit-backed, open the target's Signing &
Capabilities pane once and make sure Xcode is using your Apple
Developer team with Automatically manage signing enabled. The target's
iCloud capability should include CloudKit for container
`iCloud.com.threadmark.remotedesktop`.

If you keep Hardened Runtime enabled, also make sure the host carries
the `Audio Input` entitlement. Without it, macOS will not surface the
microphone permission prompt and the app will not appear under
System Settings > Privacy & Security > Microphone.

The generated target builds as a `LSUIElement` menu bar app. For local
dev against the signaling Worker, set `SIGNALING_URL=http://127.0.0.1:8787`
in the scheme's Run environment.

## What works today (Phase 2)

- Menu bar icon + popover (SwiftUI inside `NSHostingController`)
- Generates a random 6-digit pairing code on "Start listening"
- Claims the room on the signaling Worker as `host`
- Long-polls for client envelopes; advances state on `offer` / `bye`
- TCC permission preflight (Screen Recording + Accessibility) with
  deep-links to System Settings
- `ScreenCapture` (ScreenCaptureKit) — captures display + audio at
  60 fps, delivers `CMSampleBuffer`s on capture queues
- `InputInjector` — consumes `ControlMessage.pointer|scroll|key|text`
  and posts `CGEvent`s with correct button transitions and drag types
- Full HID → macOS virtual-keycode translation table for common keys

## What's stubbed (Phase 3)

- No `RTCPeerConnection` — when an SDP offer arrives in `HostSession`,
  we log it and advance state but don't create an answer. Next pass
  wires Google's `WebRTC.framework` into both iOS and Mac, feeds
  `SCStream` samples into an `RTCVideoSource`, and negotiates the
  peer connection end-to-end.
- `WireFormat.swift` and `SignalingClient.swift` are duplicated
  between `ios/` and `host-mac/`. Extract to a shared SPM package
  under `protocol/Swift/` before further divergence.

## First-run permissions

Screen Recording, Accessibility, and (when system audio is enabled)
Microphone all surface as TCC prompts the first time the app tries to
use them. The popover's footer shows live status and links to System
Settings if any are missing. Granting these once per install is a
platform requirement — we can't avoid it.
