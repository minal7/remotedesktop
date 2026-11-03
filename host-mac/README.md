# RemoteDesktop Mac host

Menu bar agent that automatically pairs with an iPad/iPhone on the same Apple
Account, then streams the main display (plus system audio) and
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

Because discovery, enrollment, setup lifecycle, and remote-control signaling
are CloudKit-backed, open the target's Signing & Capabilities pane once and
make sure Xcode is using your Apple Developer team with Automatically manage
signing enabled. The target's iCloud capability should include CloudKit for container
`iCloud.com.threadmark.remotedesktop`.

The generated target builds as a `LSUIElement` menu bar app. Debug builds use
the Development CloudKit database; Release builds use Production so they can
pair with TestFlight/App Store clients and the specially configured iOS
Simulator build. A Debug host and a Production client cannot discover each
other even when they use the same Apple Account.

## Native UI tests

The XCTest host suppresses production services, the menu bar item, setup
windows and automatic activation. By default it also prohibits test windows
from becoming active. For an explicitly selected batch that opens native
windows, prefix the `xcodebuild test` command with
`TEST_RUNNER_RUN_COMPUTER_USE_UI_TESTS=1`. Keep each test's own opt-in flags
as well, and run with `-jobs 1 -parallel-testing-enabled NO`.

This flag sets one accessory activation policy for the UI-test process.
Repeated prohibited/accessory transitions between methods can complete late
and prevent the next test's browser from becoming active. The flag only
applies inside XCTest and does not enable host services or automatic windows.
Tests still own and close any windows they create. Omit it for ordinary tests.

## GitHub release package

The GitHub `Release` workflow builds the macOS target as a signed,
notarized app archive and attaches `RemoteDesktopHost-macOS-<version>.zip`
beside the Windows installer. Configure the macOS signing and notarization
secrets listed at the top of `.github/workflows/release.yml` before pushing
a `v<version>` tag. A Release artifact used by the installer or live acceptance
must carry the exact 40-character revision in the code-signed
`RemoteDesktopSourceCommit` Info.plist key. `CFBundleVersion` is a CI build
number and is deliberately not treated as source provenance.

## CLI install and headless setup

For a developer Mac mini or other screenless host, a local Apple Development
build is explicitly a Debug-only diagnostic install:

```sh
cd host-mac
REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug \
REMOTE_DESKTOP_HOST_CONFIGURATION=Debug \
REMOTE_DESKTOP_IOS_CONFIGURATION=Debug \
./scripts/install_host.sh --debug --headless --start-at-login --launch \
  --request-permissions --ssh-permission-report
```

Release installation consumes a prebuilt, notarized Developer ID app from the
exact clean checkout instead of silently rebuilding an Apple Development app:

```sh
cd /path/to/remotedesktop
SOURCE_COMMIT="$(git rev-parse HEAD)"
host-mac/scripts/install_host.sh \
  --host-artifact "/absolute/path/RemoteDesktopHost.app" \
  --expected-source-commit "$SOURCE_COMMIT" \
  --headless --start-at-login --launch \
  --request-permissions --ssh-permission-report
```

The script installs `RemoteDesktopHost.app` into `/Applications`, enables a
per-user LaunchAgent when requested, and starts listening on launch in
headless mode. Release fails before changing the installed app unless the
artifact is signed by Developer ID team `V9AX39SPJD`, uses hardened runtime
and secure timestamps throughout, has only the reviewed Production CloudKit
container/service, omits task-debugging and APS entitlements, carries matching
signed source provenance, has a stapled notarization ticket, and passes
Gatekeeper. The installed executable is hash-compared with the verified
artifact and the installed bundle is verified again. Signed-in iPhone and iPad
clients discover and pair with it automatically; no pairing file is written.

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
request prompts, and verify status, but it cannot grant every protected
permission. The generated PPPC profile allows Accessibility/PostEvent and
delegates ScreenCapture approval to managed standard users; Screen Recording
cannot be silently granted by a local SSH script. Mac audio is optional; users
who enable it must approve Microphone themselves.

## Computer Use transport boundary

The host uses private CloudKit only for bounded discovery, same-account
enrollment and encrypted credential exchange, remote-control SDP/ICE
signaling, and Computer Use setup requests/progress. After enrollment, the
account-bound LAN TLS broker is the only accepted transport for
natural-language prompts, conversation context, task status/results,
pause/resume/cancel controls, and approval requests/responses. There is no
CloudKit fallback for those messages: a missing, unreachable, or
unauthenticated broker fails closed before the host receives a task.

WebRTC remains a separate visual sidecar for live screen pixels, host audio,
and direct input. Computer use planning, policy validation, visual grounding,
and action execution remain on the Mac.

## What works today

- Menu bar icon + popover (SwiftUI inside `NSHostingController`)
- Generates a short-lived private routing binding on "Start listening"; it is
  retained only for deployed CloudKit/wire compatibility and is never shown
  or entered
- Publishes and refreshes its pairing advertisement in the user's private
  CloudKit database
- Long-polls CloudKit signaling envelopes and negotiates `offer` / `answer` / `ice` / `bye`
- TCC permission preflight (Screen Recording + Accessibility) with
  deep-links to System Settings
- CLI permission check/request commands plus a scriptable installer for
  `/Applications`, LaunchAgent startup, and headless auto-listen.
- Optional Microphone entitlement + permission preflight for the host audio
  bridge. LiveKitWebRTC's macOS audio engine still relies on the
  recording path to publish the ScreenCaptureKit system-audio feed,
  even though the host does not transmit microphone audio itself. Declining
  it leaves screen viewing and remote control fully available.
- `ScreenCapture` (ScreenCaptureKit) — captures the display and optional audio at
  30 fps, delivers `CMSampleBuffer`s on capture queues
- WebRTC media pipeline built on LiveKitWebRTC's public APIs:
  `RTCPeerConnectionFactory`, Unified Plan transceivers,
  `RTCVideoSource.videoSourceForScreenCast(_:)`, and the audio-engine
  `RTCAudioDeviceModuleDelegate` bridge for system audio
- `InputInjector` — consumes `ControlMessage.pointer|scroll|key|text`
  and posts `CGEvent`s with correct button transitions and drag types
- Full HID → macOS virtual-keycode translation table for common keys
## Computer use (Beta)

Computer use runs Fara 1.5-4B locally on an Apple silicon Mac with at least
16 GB of memory. It observes the active Mac window and acts through a visual
screen-and-input loop; browser interaction uses the screen and does not require
a browser extension. The model is installed from two pinned, checksummed
artifacts: the Fara model and its vision projector. Setup checks memory and
free disk space, reports download progress, resumes interrupted downloads, and
verifies SHA-256 before activating the installation.

After same-account enrollment, prompts, task status, results, questions,
approvals, and task controls travel over the authenticated LAN TLS channel.
CloudKit supports enrollment and Computer use setup; it does not carry task
prompts or results. Live pixels and direct remote input use the separate
WebRTC connection. The model may ask for missing information or help, and the
user can approve or deny consequential actions, stop a task, or take over the
live Mac view.

## Computer Use acceptance

The acceptance runners keep hidden component evidence separate from visible
product behavior:

The release end-to-end checklist uses the owner's physical iPhone or iPad on
the same Wi-Fi as the signed host; its timestamps, task IDs, episodes, and
fixture receipts are the release evidence. Simulator suites are diagnostics
and do not replace that physical-device check.

- `RemoteDesktopLiveE2E` exercises simulator-only transport and task UI cases;
  it is not evidence for the physical-device release checklist.
- `host-mac/scripts/run_doordash_takeover_resume_simulator_live_e2e.py`
  runs only the continuous Release-Simulator DoorDash acceptance through
  direct `xcodebuild`, preserving the person-handled macOS consent, private
  login, quote preparation, and resume windows without a request transport
  timeout. It requires `--allow-visible-ui`, validates the installed Release
  host and one booted iPhone Air, and stops after 40 minutes. It first uses
  `build-for-testing`, copies the generated old-style xctestrun beside the
  private `Build/Products` output so Xcode placeholders still resolve, removes
  every stale live or expected-value environment variable, and enables exactly
  the two intended live gates. That private copy selects screenshot-mode UI
  capture, discards every automatic system attachment even on failure, disables
  diagnostic collection, and retains only explicit user evidence for a second
  audit. `test-without-building` writes into a mode-0700 quarantine; the runner
  publishes the unique result bundle only after `xcresulttool` proves that every
  retained attachment is one of four allowlisted JSON evidence records. Any
  screenshot, screen recording, UI snapshot, synthesized event, unknown file,
  malformed manifest, or failed audit deletes the quarantine and private build
  products instead of retaining them. The runner never clicks system permission prompts, enters
  credentials, changes the cart, checks out, or places an order. The live test
  requires two consecutive streamed-pixel samples of Safari at `doordash.com`
  with the real signed-out form before it focuses the composer or submits a
  request. Its bounded 10-second preflight sends nothing on failure. The runner
  disables Xcode's continuous screen recording and verbose failure diagnostics, and
  the test retains no custom screenshot or OCR sample during person-controlled
  login. A Safari History entry, tab preview, or Codex/ChatGPT page that
  merely mentions DoorDash is rejected; if History is used, the operator must
  click the entry, wait for navigation, close the menu, and visibly confirm the
  `doordash.com` sign-in form. The test OCR-audits only the streamed Mac
  viewport before credentials and after the prepared quote, failing on visible
  Safari History, Everyday Planner,
  Reminders/Calendar/Contacts. It deliberately performs no OCR
  during the person's private sign-in window.
- `host-mac/scripts/run_osatlas_acceptance.sh` runs the hidden deterministic
  OS-Atlas compatibility tests selected by the checked-in inventory. It
  defaults to Debug and accepts `--configuration Release`; the inventory is
  verified before and after the test run, with automatic package resolution
  disabled and the resolved package versions enforced.

See [AcceptanceFixtures/README.md](AcceptanceFixtures/README.md) for local fixture
commands, mode boundaries, and privacy guidance.

## Current limitations

- `WireFormat.swift` and `SignalingClient.swift` are duplicated
  between `ios/` and `host-mac/`. Extract to a shared SPM package
  under `protocol/Swift/` before further divergence.
- Computer use requires Apple silicon and at least 16 GB of Mac memory. It is
  limited to basic visual browser and Mac-app tasks and may stop to ask for
  help.
- The downloadable v0.2.0 host release predates the current main-branch
  Computer Use hardening. A new signed/notarized release is still required
  before end users receive these changes.

## First-run permissions

Screen Recording and Accessibility are required and are presented one at a
time by the first-run setup guide. Mac audio is optional. The host declares its
ScreenCaptureKit system-audio purpose separately. If a user enables audio, the
host also needs the hardened runtime Audio Input entitlement plus Microphone
permission so LiveKitWebRTC can start its recording graph for the outbound
audio track. The app forwards ScreenCaptureKit system audio, not microphone
audio. Declining this optional prompt never blocks video or control.

Apple Mail has a separate, narrowly scoped Automation permission. It is not
requested during general setup. After the user approves an exact Mail draft or
send action on iOS for the first time, macOS asks on the Mac whether Remote
Desktop Host may control Mail. If permission is denied, the host stops before
creating or sending the email. Enable **Remote Desktop Host → Mail** in **System
Settings → Privacy & Security → Automation**, then submit a new request. Mail
content is passed to a fixed local automation program over standard input; it
is not placed in command-line arguments, environment variables, temporary
files, or host logs.
