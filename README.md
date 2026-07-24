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
│  iOS client    │ ── bounded CloudKit lifecycle ────▶ │  Host agent     │
│  (iPad/iPhone) │ ◀── discovery / enrollment / SDP ─  │  (Mac / Windows)│
└───────┬────────┘                                    └────────┬────────┘
        │                                                      │
        │   ─── WebRTC peer connection (STUN-only) ──────────▶ │
        │                                                      │
        │  ◀──  video (H.264)  ── audio (Opus)  ── input (DataChannel)─│
        │                                                      │
        │   ═══ prompt / controls via authenticated LAN TLS ═▶ │
        │  ◀══ status / result / approval via same broker ═══  │
```

- **Transport:** WebRTC. Video track (H.264) for screen, audio track (Opus)
  for host audio, and a reliable-ordered data channel for direct input and
  remote-screen protocol messages.
- **CloudKit lifecycle:** the user's private database is limited to host
  discovery, same-account enrollment and encrypted credential exchange,
  remote-control SDP/ICE signaling, and Computer Use setup requests/progress.
  Each class has a bounded validity window, query budget, and cleanup state.
  The original Cloudflare Worker is deprecated; see
  `signaling/DEPRECATED.md`.
- **Computer Use task channel:** after enrollment, the natural-language
  prompt, bounded conversation context, task progress/status/result,
  pause/resume/cancel controls, and approval requests/responses travel only
  over the authenticated LAN TLS broker. That traffic does not fall back to
  CloudKit; if the broker cannot be authenticated or reached, the task fails
  closed without being submitted.
- **NAT traversal:** STUN-only (public STUN list delivered via a CloudKit
  `ICEConfig` record). No TURN — if ICE can't connect within a timeout, the
  client surfaces a "try the same Wi-Fi" error.
- **Pairing model:** automatic and same-Apple-Account only. The iPad/iPhone and
  host sign in to the same Apple Account; the client discovers the host in the
  account's private CloudKit database and pairs without a code field or copied
  secret. Ephemeral key agreement encrypts the LAN credential before it
  crosses CloudKit. A short-lived internal binding still routes deployed
  CloudKit records, but it is never shown or entered. Five minutes is the
  discovery/signaling stale-record window; a listening host refreshes its
  current advertisement.

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
| CloudKit lifecycle (private DB, same-Apple-Account, bounded polling) | implemented |
| iOS client — UI + WebRTC peer connection | implemented |
| Mac host agent — capture + injection + WebRTC | implemented |
| Windows host agent — WebRTC + capture + input + installer | implemented |

WebRTC media (H.264 video, Opus audio, input over DataChannel) is wired across
the iOS client and both hosts. Automatic same-account enrollment and the
post-enrollment LAN TLS task channel are implemented and covered by component
tests. A fresh signed Release macOS-host + iPhone Air Simulator run proving the
complete enrollment, task, approval, and result path is still pending; this
document is not that release-acceptance evidence. Remaining validation and
out-of-band CloudKit work are tracked in `PROGRESS.md`.

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
verification, and runtime loading. Setup request/progress is the only AI
lifecycle allowed to use private CloudKit before the LAN broker is ready;
already verified components are reused. Once enrolled, prompts, conversation,
task status/results, approvals, and controls use only authenticated LAN TLS.
The live screen and direct intervention continue over WebRTC, while planning,
visual grounding, and tool execution stay on the Mac. The host bundles the
third-party notices for all local components.
The phone-triggered model setup downloads only checksum-pinned OS-Atlas Pro 4B
GGUF data; executable inference code remains inside the signed host. The public
upstream checkpoint is Apache-2.0 licensed and needs no API key or paid service.

## Getting started (developer)

### Prerequisites (CloudKit)

There's no remote-control signaling server to run — discovery, enrollment,
setup lifecycle, and SDP/ICE signaling use bounded CloudKit records. One-time
configuration happens in the Apple Developer portal and CloudKit Dashboard
(App IDs with iCloud, the `iCloud.com.threadmark.remotedesktop` container,
queryable indexes, and the `ICEConfig` STUN record). The exact steps are in
`PROGRESS.md` under "Work you need to do out-of-band". Both devices must be
signed into the **same Apple Account** to enroll automatically.

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

For a screenless developer Mac mini, a local Apple Development build is a
matched Debug-only diagnostic install:

```sh
cd host-mac
REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug \
REMOTE_DESKTOP_HOST_CONFIGURATION=Debug \
REMOTE_DESKTOP_IOS_CONFIGURATION=Debug \
./scripts/install_host.sh --debug --headless --start-at-login --launch \
  --request-permissions --ssh-permission-report
```

A Release install must instead pass an absolute notarized Developer ID
`RemoteDesktopHost.app` plus its exact full source commit:

```sh
SOURCE_COMMIT="$(git rev-parse HEAD)"
host-mac/scripts/install_host.sh \
  --host-artifact "/absolute/path/RemoteDesktopHost.app" \
  --expected-source-commit "$SOURCE_COMMIT" \
  --headless --start-at-login --launch
```

The Release bundle must embed that revision in its code-signed
`RemoteDesktopSourceCommit` Info.plist key. The installer does not infer source
provenance from a mutable filename or CI build number. The signed-in iPhone or
iPad discovers and pairs with the host automatically; headless installs do not
write a pairing secret to disk.

The installed binary also supports `--check-permissions` and
`--check-permissions-json`. Plain SSH cannot grant every required macOS TCC
permission; `--ssh-permission-report` prints the exact breakdown. Use the
generated PPPC profile with user-approved MDM when you need the managed parts
of permission setup.

### Windows host

End users install from the latest [GitHub release](https://github.com/minal7/remotedesktop/releases)
(`RemoteDesktopHost-Setup-<version>.exe`) — a self-contained installer that
runs without any extra setup. On first launch it opens a browser for Apple ID
/ iCloud sign-in, then advertises privately to devices on that account.

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
  long as the user initiates each session to a device they own. The person
  explicitly selects a computer discovered through their private Apple
  Account and starts each session; automatic discovery does not auto-connect.
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
