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

## Build status

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
tests. A signed release candidate is being prepared for the **Computer use (Beta)**
feature. Its smoke, safety, and physical-device acceptance results are pending;
this document does not claim that release validation has passed. Pairing and
remote desktop continue to use the CloudKit and WebRTC flows described above.

## Computer use (Beta)

Computer use lets you describe a task on your iPhone or iPad while a local
vision-language model on your Mac works through the browser or a basic Mac app.
The Mac observes the screen, takes one action, and checks the next screen. The
feature is in beta; its release-candidate smoke, safety, and physical-device
results are pending.

The shipped model is Fara 1.5-4B and inference runs on the Mac. An Apple silicon
Mac with at least 16 GB of memory is required. The iPhone and Mac must be on the
same local network for task traffic. Setup may use the account's private
CloudKit database for bounded enrollment and model setup; after enrollment, prompts, task status,
results, controls, and approvals use authenticated LAN TLS. Screen sharing and
direct remote input continue over WebRTC. Ordinary task content is not sent to
a developer-operated AI service.

Start model setup beside the Mac in the iPhone or iPad app. Setup shows download
progress, verifies the model files, and can resume after an interruption. Allow
about 4.3 GiB of free disk space for setup.

The iPhone shows brief progress narration, asks a question when information is
missing, and presents an approval card before consequential actions such as
sending, submitting, paying, purchasing, deleting, or sharing. You can deny an
action, stop the task, or take over the live Mac view. A task may stop and ask
for help rather than complete. Computer use is not available on the Windows
host in this beta.

Task screenshots and action records are stored locally on the Mac. They are
pruned when recording starts if they are more than seven days old, and can be
deleted from the host's Computer Use settings. See the [Privacy Policy](docs/privacy.html)
and [Support](docs/support.html) for details and setup help.

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
  Microphone is optional and used only to enable the system-audio bridge.
