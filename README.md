# RemoteDesktop

iPad / iPhone client that remotely controls a Mac or Windows computer over the
internet. No port forwarding, no self-hosted server.

## Downloads

<!-- The release workflow updates the block below after each published host release. -->
<!-- download-links:start -->
Latest host release: [v0.2.0](https://github.com/minal7/remotedesktop/releases/tag/v0.2.0)

- iPhone and iPad beta: [Join TestFlight](https://testflight.apple.com/join/tyHPrUny)
- macOS host: [RemoteDesktopHost-macOS-0.2.0.zip](https://github.com/minal7/remotedesktop/releases/download/v0.2.0/RemoteDesktopHost-macOS-0.2.0.zip)
- Windows host: [RemoteDesktopHost-Setup-0.2.0.exe](https://github.com/minal7/remotedesktop/releases/download/v0.2.0/RemoteDesktopHost-Setup-0.2.0.exe)
<!-- download-links:end -->

## Architecture at a glance

```
┌────────────────┐                                    ┌─────────────────┐
│  iOS client    │ ── SDP / ICE via CloudKit ───────▶ │  Host agent     │
│  (iPad/iPhone) │ ◀── SDP / ICE via CloudKit ──────  │  (Mac / Windows)│
└───────┬────────┘                                    └────────┬────────┘
        │                                                      │
        │   ─── WebRTC peer connection (STUN-only) ──────────▶ │
        │                                                      │
        │  ◀──  video (H.264)  ── audio (Opus)  ── input (DataChannel)─│
```

- **Transport:** WebRTC. Video track (H.264) for screen, audio track (Opus)
  for host audio, reliable-ordered data channel for input events + control
  messages.
- **Signaling:** CloudKit. SDP/ICE exchange goes through each user's own
  iCloud private database, polled on a ~2 s cadence during an active session.
  No server to operate and $0 cost at any scale — each user's signaling
  traffic lives in their own iCloud quota. (The original Cloudflare Worker is
  deprecated; see `signaling/DEPRECATED.md`.)
- **NAT traversal:** STUN-only (public STUN list delivered via a CloudKit
  `ICEConfig` record). No TURN — if ICE can't connect within a timeout, the
  client surfaces a "try the same Wi-Fi" error.
- **Pairing model:** same-iCloud only. The iPad/iPhone and the host must be
  signed into the same iCloud account. A 6-digit numeric code shown on the
  host is typed into the client. A new code is generated whenever the host
  listener starts, including after a disconnect. Five minutes is the stale
  CloudKit-record window; a listening host refreshes its current advertisement.

## Repository layout

| Path | What lives here |
| --- | --- |
| `ios/` | SwiftUI iPad + iPhone client |
| `host-mac/` | Menu-bar Swift agent using ScreenCaptureKit + CGEvent + CoreAudio |
| `host-windows/` | Rust Windows host — WebRTC + Windows.Graphics.Capture + WASAPI + `enigo`, with a distributable installer |
| `protocol/` | Shared wire-format spec + Swift CloudKit signaling client |
| `signaling/` | **Deprecated** Cloudflare Worker (kept for reference; see `signaling/DEPRECATED.md`) |

`PROGRESS.md` is the living migration tracker — CloudKit schema, pairing flow,
and remaining out-of-band Apple Developer portal work.

## Build status (v1)

| Component | State |
| --- | --- |
| Protocol spec + shared CloudKit signaling client | implemented |
| CloudKit signaling (private-DB, same-iCloud, polling) | implemented |
| iOS client — UI + WebRTC peer connection | implemented |
| Mac host agent — capture + injection + WebRTC | implemented |
| Windows host agent — WebRTC + capture + input + installer | implemented |

WebRTC media (H.264 video, Opus audio, input over DataChannel) is wired
end-to-end across the iOS client and both hosts. Remaining v1 work is mostly
out-of-band Apple Developer / CloudKit Dashboard setup and on-device pairing
validation — tracked in `PROGRESS.md`.

## AI Computer Use

AI Computer Use is MCP-first and stays local to the macOS host. On supported
Macs, Apple's on-device Foundation Models framework turns eligible chat requests
into typed calls within the reviewed planner surface: seven read-only helper
operations plus the host's embedded Mail operation for contact-resolution
flows. Fully specified Mail sends are deterministically pre-routed to that
embedded operation before any planner/model call. The host—not the model—applies
the allowlist, validates arguments, pauses for exact one-action approval, and
records mutation attempts before execution. No API key or paid AI service is
used. Windows AI Computer Use is not implemented; the Windows host remains a
remote-desktop host only. GUI-only applications use a local hybrid. An AI-ready
macOS host always installs the semantic router: it opens an explicitly named
common app once before interacting, and can route bounded literal text and
unambiguous current-app navigation without model inference. Remaining
ordinary-language steps use Apple's on-device model to select one typed
semantic action with bounded arguments. OS-Atlas-Pro-4B grounds visual pointer
targets, and the host composes and validates the native Mac action. Non-pointer
actions do not ask OS-Atlas to echo a verb, and a raw OS-Atlas verb can never
override the typed plan. Deterministic host routes remain available when
Apple's model is unavailable; an unrecognized step returns `unable to
complete` without asking OS-Atlas for an executable action.
For delivery quotes, the production typed semantic route performs direct app,
text, and scroll steps; OS-Atlas is used only when a visual pointer must be
grounded. Legacy raw delivery parsing remains in component-test configuration
only and is not a production or ordinary-language fallback. Local Vision OCR
extracts and validates itemized facts only inside the focused window. V1 loads
Pro only and never Base and Pro at the same time. Macs with 8–15 GiB memory use
a bounded
4,096-token compact profile with smaller batches and a 4 GiB process ceiling;
Macs with at least 16 GiB retain the 8,192-token standard profile. Both profiles
recheck reclaimable memory before launch and every inference.

Mail requests use a separately reviewed MCP tool embedded in the signed host,
not the downloaded helper's generic Mail tool. It can create a visible draft or
send through Apple Mail's default account only after iOS states that the
default account will be used and shows the exact To/CC/BCC, subject, and
message for one-action approval. On the first approved Mail action, macOS may
ask on the Mac whether Remote Desktop Host can automate Mail. Denying that
prompt stops before an email is created or sent; enable
**Remote Desktop Host → Mail** under **System Settings → Privacy & Security →
Automation**, then make a new request.

Setup is initiated from the iPhone or iPad; passive status checks never start a
download. One progress bar reflects the real helper and visual-model bytes,
verification, and runtime loading returned over the existing private CloudKit
channel. Already verified components are reused. The live screen and direct
intervention continue over WebRTC, while planning and tool execution stay on
the Mac. The host bundles the third-party notices for all local components.
The phone-triggered model setup downloads only checksum-pinned OS-Atlas Pro 4B
GGUF data; executable inference code remains inside the signed host. The public
upstream checkpoint is Apache-2.0 licensed and needs no API key or paid service.

## Getting started (developer)

### Prerequisites (CloudKit)

There's no signaling server to run — signaling is CloudKit. One-time setup
happens in the Apple Developer portal and CloudKit Dashboard (App IDs with
iCloud, the `iCloud.com.threadmark.remotedesktop` container, queryable
indexes, and the `ICEConfig` STUN record). The exact steps are in
`PROGRESS.md` under "Work you need to do out-of-band". All clients must be
signed into the **same iCloud account** to pair.

### iOS client

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
xcodegen generate
open RemoteDesktop.xcodeproj
```

Sign the target with a team whose provisioning includes the CloudKit
container, and run on a device signed into the same iCloud account as the
host. (There is no `SIGNALING_URL` to set anymore — that was the old Worker.)

### Mac host agent

```sh
cd host-mac
xcodegen generate
open RemoteDesktopHost.xcodeproj
```

First run will prompt for Screen Recording and Accessibility permissions,
and for Apple ID / iCloud sign-in (same account as the client).

For a screenless developer Mac mini, the host can be installed and launched
from SSH:

```sh
cd host-mac
./scripts/install_host.sh --headless --start-at-login --launch --request-permissions --ssh-permission-report
cat ~/Library/Application\ Support/RemoteDesktopHost/pairing-code.txt
```

The installed binary also supports `--check-permissions` and
`--check-permissions-json`. Plain SSH cannot grant every required macOS TCC
permission; `--ssh-permission-report` prints the exact breakdown. Use the
generated PPPC profile with user-approved MDM when you need the managed parts
of permission setup.

### Windows host

End users install from the latest [GitHub release](https://github.com/minal7/remotedesktop/releases)
(`RemoteDesktopHost-Setup-<version>.exe`) — a self-contained installer that
runs without any extra setup. On first launch it opens a browser for Apple ID
/ iCloud sign-in, then advertises a pairing code.

To build from source you need the MSVC build tools, CMake, and a CloudKit API
token. Full instructions (token handling, the tag-driven release workflow, and
the Microsoft Store path) are in [`host-windows/README.md`](host-windows/README.md):

```powershell
cd host-windows
$env:REMOTE_DESKTOP_CLOUDKIT_API_TOKEN = "<token>"
$env:REMOTE_DESKTOP_CLOUDKIT_ENV = "development"
cargo run --release
```

## App Store compliance notes

- Remote-control apps are permitted (Apple App Review Guidelines 4.2.7) as
  long as the user initiates each session to a device they own. We meet this
  by requiring a pairing code typed into the client per session.
- No private screen-capture APIs used on iOS. Host-side capture uses public
  ScreenCaptureKit (macOS 12.3+) and Windows.Graphics.Capture (Windows 10+).
- Background execution: no `voip` background mode is used; sessions pause when
  backgrounded and prompt the user to resume. This is within Apple's BGTask
  rules.
- Privacy strings in `Info.plist`: `NSLocalNetworkUsageDescription`,
  `NSBonjourServices`, and defensive `NSMicrophoneUsageDescription` and
  `NSCameraUsageDescription` keys because the bundled WebRTC component is
  microphone- and camera-capable. The declarations do not request access. The
  iOS client creates receive-only media and a playback audio session; it does
  not request, record, store, or transmit iPhone/iPad microphone or camera data.
- The iOS client does not declare Location access. On the Mac,
  Screen Recording and Accessibility are required for remote control;
  Microphone is optional and used only to enable the system-audio bridge. A
  separately declared Apple Events permission is requested only after the user
  approves an Apple Mail action on iOS.
