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

The generated target builds as a `LSUIElement` menu bar app. Debug builds use
the Development CloudKit database; Release builds use Production so they can
pair with TestFlight/App Store clients and the specially configured iOS
Simulator build. A Debug host and a Production client cannot discover each
other even when they use the same Apple Account.

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
request prompts, and verify status, but it cannot grant every protected
permission. The generated PPPC profile allows Accessibility/PostEvent and
delegates ScreenCapture approval to managed standard users; Screen Recording
cannot be silently granted by a local SSH script. Mac audio is optional; users
who enable it must approve Microphone themselves.

## What works today

- Menu bar icon + popover (SwiftUI inside `NSHostingController`)
- Generates a random 6-digit pairing code on "Start listening"
- Publishes and refreshes its pairing advertisement in the user's private
  CloudKit database
- Long-polls CloudKit signaling envelopes and negotiates `offer` / `answer` / `ice` / `bye`
- TCC permission preflight (Screen Recording + Accessibility) with
  deep-links to System Settings
- CLI permission check/request commands plus a scriptable installer for
  `/Applications`, LaunchAgent startup, headless auto-listen, and pairing-code
  file export.
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
- MCP-first Computer Use using Apple's on-device Foundation Models planner and
  a pinned, notarized universal `mac-control-mcp` helper. It runs locally over
  stdio with a scrubbed environment: no API key, paid service, Python,
  Homebrew, or Conda is required. The host owns the tool allowlist, schema
  validation, mutation ledger, and exact one-use approvals.
- Reliable Apple Mail draft/send support through `remote_desktop_mail`, a
  reviewed MCP server embedded in the signed host and connected in memory. It
  uses the default Mail sending account, creates a visible draft, suppresses
  automatic signatures so the approved body stays exact, and sends only after
  iOS shows the complete recipients, subject, and body for one-action approval.
  The downloaded helper's generic `mail_send` tool remains blocked.
- GUI-only apps use a local hybrid when no suitable structured tool exists.
  Its always-installed semantic router opens an explicitly named common app
  once before interacting and handles bounded literal text and unambiguous
  current-app navigation deterministically. Remaining ordinary-language steps
  use Apple's on-device model to select one typed semantic action and bounded
  arguments. OS-Atlas-Pro-4B grounds pointer targets, and the host composes,
  validates, approves, and executes the native action.
  iOS sends one idempotent setup request over the existing private CloudKit
  signaling record; the host streams the helper download, model download,
  verification, and runtime-loading progress back to the device row.
- Versioned model installation in Application Support with Apple-silicon,
  8 GiB memory, free-space, byte-size, and streaming SHA-256 checks before an
  atomic receipt is activated. An 8–15 GiB Mac uses a 4,096-token compact
  llama.cpp profile, smaller logical/physical batches, 3 GiB launch headroom,
  1 GiB post-load headroom, and a 4 GiB process ceiling. Macs with at least
  16 GiB retain the 8,192-token profile and larger safety margins. Resumable
  progress is calculated from durable bytes across every artifact, and chat is
  exposed only after the complete model package loads successfully.
- The host-composed surface covers 16 semantic operations. `ANSWER` and
  `REPORT` are aliases for the same evidence-checked visible-facts behavior.
  Click, double-click, secondary-click, and drag use harmless OS-Atlas primary
  click carriers only for visual points; the typed plan owns the final verb.
  Text, four-direction scroll, app opening, Return, hotkeys, wait, completion,
  clarification, and visible answers are composed directly from validated
  arguments without visual-model verb selection. The router remains installed
  regardless of Apple's startup availability and re-checks availability for
  every non-deterministic step. Its deterministic, host-authored routes remain
  usable during an Apple-model outage. If no such route matches, the task
  returns `unable to complete` before any further OS-Atlas inference or host
  effects; the raw checkpoint path is not revived. Authentication-boundary app
  switching likewise accepts only a typed `OPEN_APP` route. Direct user input
  immediately pauses automation, and malformed or out-of-range actions are
  rejected before any effect.

## Computer Use local component distribution

`mac-control-mcp` 0.8.2 is fetched only after setup is requested on iOS. The
host pins its release URL, byte count, SHA-256, bundle identifier, Developer ID
team, hardened-runtime signature, universal architectures, Gatekeeper result,
and notarization ticket before activating a versioned receipt. The helper is
not launched by the installer. Its MIT license and notice ship in the host.

The v1 visual model is OS-Atlas-Pro-4B, pinned to the public, ungated
`OS-Copilot/OS-Atlas-Pro-4B` revision
`06b790b907d82f29bb317ba889e6888805953036`. It runs locally and requires no
API key or paid service. Pro is selected because the upstream project trains it
for agentic next-action generation. The Base 4B variant is represented for a
possible future grounding-only package, but v1 neither downloads nor loads it
alongside Pro.

The phone-triggered setup downloads only immutable, verified OS-Atlas Pro 4B
GGUF model data. Each manifest entry contains its complete HTTPS URL, byte
count, and SHA-256. Downloaded model files are explicitly non-executable; the
signed host contains all inference code. Conversion provenance is pinned to
llama.cpp tag `b9992`, revision
`6eddde06a4f25d55d538b5d15628dcc2b6882147`.

The signed host bundles and verifies the complete
[OS-Atlas Apache 2.0 License](https://github.com/OS-Copilot/OS-Atlas/blob/bad08407ab54b5bf6c17a69fe1ced476b9494926/LICENSE),
the pinned llama.cpp MIT license, and a conversion notice before activating a
receipt. Missing or tampered installed copies are repaired from the signed app;
no legal document or executable is fetched during model setup.

## Computer Use acceptance

The acceptance runners keep hidden component evidence separate from visible
product behavior:

- `host-mac/scripts/run_mcp_acceptance.py` validates the pinned helper identity,
  inventory, host policy, and schemas, then issues real stdio JSON-RPC
  `tools/call` requests for all 29 exposed sidecar operations. A no-Dock
  accessory AppKit fixture stays outside every display. A 20 ms native
  watchdog starts before helper launch/initialization and aborts on any new
  visible window or prompt. The one explicit native-feedback allowance is the
  bounded macOS screen-capture privacy status indicator during
  `ax_tree_augmented`; it is reported and must fade before the next call. Exact
  frontmost state is restored after cleanup. Private read results are never
  printed. Five Safari tab tools are explicitly blocked because the live gate
  proved v0.8.2 activates and mutates Safari's ambient front window; browser
  pricing tasks therefore use the OS-Atlas visual fallback and its login
  handoff instead. This 29-operation gate is low-level component and host-policy
  coverage; it does not claim that all 29 operations are available to the
  natural-language product planner. The production structured planner exposes
  seven read-only sidecar operations (Contacts search, Reminders list,
  Shortcuts list, focused app, running apps, windows, and permission status)
  plus the host's embedded Mail operation. Host executor tests cover an
  ordinary-person prompt, typed proposal, execution, and consumed result for
  every read-only operation. A separate Contacts-to-Mail test proves that a
  detailed send request consumes the contact result, stops at the exact Mail
  approval, and invokes Mail only after approval.
- Visible login takeover, exact email-send confirmation, approvals, progress,
  and results run through `RemoteDesktopLiveE2E` on an iOS Simulator, so the
  shipped app and only the task-relevant Mac surface are what the user sees.
- `host-mac/scripts/run_doordash_takeover_resume_simulator_live_e2e.py`
  runs only the continuous Release-Simulator DoorDash acceptance through
  direct `xcodebuild`, preserving the person-handled macOS consent, private
  login, quote preparation, and resume windows without an MCP transport
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
  Reminders/Calendar/Contacts, or MCP UI. It deliberately performs no OCR
  during the person's private sign-in window.
- `host-mac/scripts/run_osatlas_acceptance.sh` runs a hidden deterministic
  parser/executor/safety/native-input matrix by default. That matrix covers the
  full host grammar: 16 semantic operations across 17 raw variants.
- `host-mac/scripts/run_osatlas_acceptance.sh --actual-model` additionally
  loads the installed Apple language model and OS-Atlas Pro checkpoint against
  hidden, in-memory screens. Its semantic matrix covers all 16 host actions:
  direct actions use the typed plan, while pointer actions require one or two
  real OS-Atlas point-grounding inferences. Separate stateful delivery
  component tests retain the legacy raw parser in a test-only configuration;
  they are not production-equivalent fallback tests. Production loading always
  installs the semantic router and disables explicit raw-action compatibility.
  A separate 15-scenario regular-user matrix forces the Apple planner
  unavailable and classifies each terminal state as `task completed`, `user
  intervention required`, or `unable to complete`. It includes authentication,
  purchase approval, persistent-error, platform-incompatibility, and an
  unrecognized-operation fail-closed boundary. Every raw checkpoint response
  in that matrix must be a `CLICK` point carrier for a typed pointer route;
  direct and terminal routes require zero checkpoint calls.
  These tests do not capture the desktop, post system input, or advance
  checkout.
- Live DoorDash quote reading requires `--live-doordash`,
  `--allow-visible-ui`, and exact `DOORDASH_EXPECTED_ITEM`,
  `DOORDASH_EXPECTED_TOTAL`, and `DOORDASH_EXPECTED_ETA` values. It reads a
  review page prepared by the user and uses local Vision OCR for the itemized
  quote. It intercepts all input, so it cannot advance checkout or place an
  order. A login wall always pauses for user takeover.

See [AcceptanceFixtures/README.md](AcceptanceFixtures/README.md) for exact
commands, mode boundaries, privacy guidance, and the MCP operation matrix.

## Current limitations

- `WireFormat.swift` and `SignalingClient.swift` are duplicated
  between `ios/` and `host-mac/`. Extract to a shared SPM package
  under `protocol/Swift/` before further divergence.
- Apple's language-model planner requires the Foundation Models framework and
  an available on-device model. Older or ineligible Macs keep the reviewed
  deterministic route subset and fail closed for other ordinary-language
  steps; an open-source typed semantic planner is not yet shipped.
- The 8–15 GiB compact runtime profile has been exercised on a 32 GiB Apple
  silicon Mac with its exact 4,096-token limits and measured at about 2.27 GiB
  peak process footprint. It has not yet been validated on physical 8 GiB Mac
  hardware, so that hardware tier is supported by bounded-resource tests, not
  a completed low-memory field qualification.
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
