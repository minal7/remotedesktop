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

The generated target builds as a `LSUIElement` menu bar app. For local
dev against the signaling Worker, set `SIGNALING_URL=http://127.0.0.1:8787`
in the scheme's Run environment.

## GitHub release package

The GitHub `Release` workflow builds the macOS target as a signed,
notarized app archive and attaches `RemoteDesktopHost-macOS-<version>.zip`
beside the Windows installer. Configure the macOS signing and notarization
secrets listed at the top of `.github/workflows/release.yml` before pushing
a `v<version>` tag.

## CLI install and headless setup

For a developer Mac mini or other screenless host, build and install from SSH:

```sh
cd host-mac
./scripts/install_host.sh --headless --start-at-login --launch --request-permissions --ssh-permission-report
```

The script installs `RemoteDesktopHost.app` into `/Applications`, enables a
per-user LaunchAgent when requested, starts listening on launch in headless
mode, and writes the current pairing code to:

```sh
~/Library/Application Support/RemoteDesktopHost/pairing-code.txt
```

You can check host readiness from the installed app binary:

```sh
/Applications/RemoteDesktopHost.app/Contents/MacOS/RemoteDesktopHost --check-permissions
/Applications/RemoteDesktopHost.app/Contents/MacOS/RemoteDesktopHost --check-permissions-json
/Applications/RemoteDesktopHost.app/Contents/MacOS/RemoteDesktopHost --ssh-permission-report
```

To generate an MDM Privacy Preferences Policy Control profile for managed Macs:

```sh
./scripts/install_host.sh --generate-pppc-profile ./RemoteDesktopHost.pppc.mobileconfig
```

Apple's TCC rules are intentionally strict: plain SSH can install, launch,
request prompts, and verify status, but it cannot grant every required
permission. The generated PPPC profile allows Accessibility/PostEvent and
delegates ScreenCapture approval to managed standard users; Screen Recording
and Microphone still cannot be silently granted by a local SSH script.

## What works today

- Menu bar icon + popover (SwiftUI inside `NSHostingController`)
- Generates a random 6-digit pairing code on "Start listening"
- Claims the room on the signaling Worker as `host`
- Long-polls CloudKit signaling envelopes and negotiates `offer` / `answer` / `ice` / `bye`
- TCC permission preflight (Screen Recording + Accessibility) with
  deep-links to System Settings
- CLI permission check/request commands plus a scriptable installer for
  `/Applications`, LaunchAgent startup, headless auto-listen, and pairing-code
  file export.
- Microphone entitlement + permission preflight for the host audio
  bridge. LiveKitWebRTC's macOS audio engine still relies on the
  recording path to publish the ScreenCaptureKit system-audio feed,
  even though the host does not transmit microphone audio itself.
- `ScreenCapture` (ScreenCaptureKit) — captures display + audio at
  60 fps, delivers `CMSampleBuffer`s on capture queues
- WebRTC media pipeline built on LiveKitWebRTC's public APIs:
  `RTCPeerConnectionFactory`, Unified Plan transceivers,
  `RTCVideoSource.videoSourceForScreenCast(_:)`, and the audio-engine
  `RTCAudioDeviceModuleDelegate` bridge for system audio
- `InputInjector` — consumes `ControlMessage.pointer|scroll|key|text`
  and posts `CGEvent`s with correct button transitions and drag types
- Full HID → macOS virtual-keycode translation table for common keys

## Current limitations

- `WireFormat.swift` and `SignalingClient.swift` are duplicated
  between `ios/` and `host-mac/`. Extract to a shared SPM package
  under `protocol/Swift/` before further divergence.

## First-run permissions

Screen Recording and Accessibility surface as TCC prompts the first
time the host tries to use them. When system audio is enabled, the
host also needs the hardened runtime Audio Input entitlement plus
Microphone permission so LiveKitWebRTC can start its recording graph
for the outbound audio track. The app forwards ScreenCaptureKit system
audio, not microphone audio, but macOS still requires the recording
path to be available.
