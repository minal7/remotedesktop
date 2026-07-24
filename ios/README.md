# RemoteDesktop iOS client

SwiftUI app for iPad and iPhone with CloudKit-assisted automatic enrollment,
live WebRTC screen and audio playback, direct remote input, and the local AI
Computer Use chat experience.

Computer Use is MCP-first on the Mac host. Apple's local Foundation Model plans
within a reviewed surface of seven read-only helper operations plus the host's
embedded Mail operation; the public OS-Atlas-Pro-4B model is used only for
GUI-only visual fallback. Both run locally, with no API key or paid AI service.
V1 loads Pro only. Macs with 8–15 GiB memory use a smaller bounded context and
batch profile; Macs with at least 16 GiB use the standard profile. The host
ships the required third-party licenses and notices.

## Build

Requires:

- Xcode 15.3+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

```sh
cd ios
xcodegen generate
open RemoteDesktop.xcodeproj
```

Because pairing uses CloudKit, confirm the app target is signed with
your Apple Developer team and that the iCloud capability's CloudKit
service includes container `iCloud.com.threadmark.remotedesktop`.

### Simulator and the official host

CloudKit environments follow the build configuration on Simulator and physical
devices: **Debug talks to Development** and **Release talks to Production**.
Never mix those configurations: a Debug client cannot discover a Release host
because they use different CloudKit databases.

The final acceptance pair is always a **Release macOS host + Release iPhone Air
Simulator + Production CloudKit**. Install the Release host (the default), then
build and install the ordinary iOS app scheme explicitly in Release with the
exact booted iPhone Air UDID:

```sh
host-mac/scripts/install_host.sh --headless --launch

SIMULATOR_UDID='<booted iPhone Air UDID>'
xcodebuild build \
  -project ios/RemoteDesktop.xcodeproj \
  -scheme RemoteDesktop \
  -configuration Release \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -derivedDataPath ios/build/paired-release
xcrun simctl install "$SIMULATOR_UDID" \
  ios/build/paired-release/Build/Products/Release-iphonesimulator/RemoteDesktop.app
xcrun simctl launch "$SIMULATOR_UDID" com.threadmark.remotedesktop.client
```

Use Debug/Debug only for local diagnostics. The Codex Run entrypoint defaults
to Release; select the shared diagnostic configuration once rather than setting
separate sides:

```sh
REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug ./script/build_and_run.sh --verify
xcodebuild test \
  -project ios/RemoteDesktop.xcodeproj \
  -scheme RemoteDesktop \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}"
```

`script/build_and_run.sh` rejects differing
`REMOTE_DESKTOP_HOST_CONFIGURATION` and
`REMOTE_DESKTOP_IOS_CONFIGURATION` values. The interactive Release live runner
also reads the macOS bundle's signed entitlements and the iOS build's exact
generated `RemoteDesktop.app-Simulated.xcent`; it refuses to start UI when
either side is not Production or contains Debug/XCTest payloads.
After verifying its replacement bundle, the Run entrypoint stops the exact
installed `/Applications` host before launching the workspace host, so only one
same-bundle host advertises at a time.

Choose the configured development team and use Xcode's normal **Run** action;
do not install a build produced with `CODE_SIGNING_ALLOWED=NO`, because CloudKit
rejects that unsigned simulator binary. The Simulator must also be signed into
the same Apple Account as the host under Settings.

The iOS app declares defensive Camera and Microphone usage descriptions because
the bundled WebRTC component is capable of both features; these declarations do
not request permission. The app has no camera or microphone capture path and
does not declare Location access. Its media transceivers are receive-only,
audio uses the playback session category, and it never records, stores, or
transmits the iPhone/iPad camera or microphone.

## Computer Use transport boundary

CloudKit is the bounded bootstrap and setup plane: it may carry discovery,
same-account enrollment and encrypted credential exchange, remote-control
SDP/ICE signaling, and Computer Use setup requests/progress. Once enrollment
has installed the account-bound credential, the app opens an authenticated LAN
TLS broker for every natural-language prompt, bounded conversation context,
task status/result, pause/resume/cancel control, and approval exchange. Those
messages never fall back to CloudKit. If the TLS broker cannot be authenticated
or reached, the app must stop and report that the local AI channel is
unavailable without submitting the task elsewhere.

Live pixels, host audio, and direct input remain on the separate WebRTC
connection. Planning, policy enforcement, visual grounding, and execution
remain on the Mac host; the iOS app is the prompt, approval, status, and visible
intervention surface.

The transport split is implemented and covered by component tests. Fresh
signed end-to-end acceptance of automatic enrollment followed by an ordinary
prompt over LAN TLS is still pending for both matched Debug/Debug and
Release/Release configurations.

## What works today

- Discover Macs through the signed-in Apple Account and complete automatic,
  encrypted local pairing with no code or copied-secret entry.
- Indirect pointer on iPad (trackpad, Magic Mouse, Pencil hover):
  absolute-position pointer events + indirect scroll + right/middle
  click via `UIEvent.buttonMask`.
- Hardware keyboard via `GCKeyboard`: raw HID keycodes + modifier mask.
- Touch-cursor mode (no accessories): finger-delta cursor at 1.2×
  gain, tap = left click, long-press = right click, two-finger pan = scroll.
- A separate **Zoom & move** toggle. On means touches only pan/pinch the local
  viewport; off means dragging controls the computer and two fingers scroll it.
- Soft keyboard, floating button, on-screen modifier keys, and a hardware
  keyboard handoff that hides the soft layout while a keyboard is attached and
  restores it smoothly when the keyboard disconnects.
- Chrome collapses to a thin status strip when keyboard + pointer are
  both connected, per the project's UX contract.
- AI setup initiated beside each compatible Mac. One progress bar covers real
  helper/model download bytes, verification, and runtime loading; setup is
  resumable and idempotent. Its bounded setup lifecycle may use CloudKit and
  reuses verified components; ordinary task traffic may not use that channel.
- A live-screen-plus-chat view, with Apple Foundation Models planning typed MCP
  calls first and OS-Atlas-Pro-4B reserved for typed visual-point grounding and
  the production delivery workflow's pointer targets. If no typed route is
  available, the Mac reports that it cannot complete the step instead of
  executing a raw model verb. Phone-triggered setup downloads only verified
  GGUF model data; executable inference code stays in the signed Mac host.
- Pause, resume, stop, direct intervention, and one-action consequential-action
  approvals tied to the exact host target.
- Apple Mail approval cards state that the default Mail account will be used
  and show the exact recipients, subject, and message. The first approved Mail
  action may show a macOS Automation prompt on the Mac; denying it creates no
  draft and sends no message.

## App Store compliance checklist (tracked in top-level README)

- ✅ Computer selected and session started by the user after private-account discovery
- ✅ No private APIs
- ✅ `NSLocalNetworkUsageDescription` present
- ⬜ App Review notes explaining remote-control behavior (add before
  submission — reference Guideline 4.2.7)
