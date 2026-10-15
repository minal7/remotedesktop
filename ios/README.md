# RemoteDesktop iOS client

SwiftUI app for iPad and iPhone with CloudKit-assisted automatic enrollment,
live WebRTC screen and audio playback, direct remote input, and the local AI
Computer Use chat experience.

Computer use (Beta) runs the Fara 1.5-4B vision-language model locally on an
Apple silicon Mac with at least 16 GB of memory. The iPhone provides the task
and shows progress, questions, approvals, Stop, and Take over controls. Final
smoke, safety, and
physical iPhone or iPad acceptance results are pending. See the top-level README and
`docs/support.html` for current setup guidance.

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

### Matched development and acceptance builds

CloudKit environments follow the build configuration on Simulator and physical
devices: **Debug talks to Development** and **Release talks to Production**.
The host and iOS client must use the same environment for pairing and setup.
For physical-device acceptance, use the latest signed host and iOS app with
matching CloudKit environments and connect both devices to the same Wi-Fi for
Computer use tasks. The iPhone or iPad acceptance checklist is in
`docs/computer-use-review/iphone-checklist.md`; its results are pending.

For local Simulator diagnostics, use matching Debug builds and sign the
Simulator into the same Apple Account as the host. The Codex Run entrypoint
defaults to Release; select the shared diagnostic configuration once rather
than setting separate sides:

```sh
REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug ./script/build_and_run.sh --verify

SIMULATOR_UDID='<booted simulator UDID>'
xcodebuild test \
  -project ios/RemoteDesktop.xcodeproj \
  -scheme RemoteDesktop \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}"
```

`script/build_and_run.sh` rejects differing
`REMOTE_DESKTOP_HOST_CONFIGURATION` and
`REMOTE_DESKTOP_IOS_CONFIGURATION` values. Do not install an unsigned simulator
binary produced with `CODE_SIGNING_ALLOWED=NO`; CloudKit rejects it.

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

The transport split is implemented and covered by component tests. End-to-end
acceptance of automatic enrollment followed by an ordinary prompt over LAN TLS
on a physical iPhone or iPad is still pending.

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
- Computer use (Beta) runs Fara 1.5-4B locally on the Mac. The iPhone or iPad starts a
  task over the authenticated LAN channel after enrollment; model setup may use
  the bounded CloudKit setup lifecycle.
- Progress narration, clarification questions, one-action approval cards,
  Deny, Stop, and Take over are available in the task view. Computer use can
  stop and ask for help when it cannot safely or reliably continue.
- Pause, resume, stop, direct intervention, and approvals are tied to the
  current host task and target.

## App Store compliance checklist (tracked in top-level README)

- ✅ Computer selected and session started by the user after private-account discovery
- ✅ No private APIs
- ✅ `NSLocalNetworkUsageDescription` present
- ⬜ App Review notes explaining remote-control behavior (add before
  submission — reference Guideline 4.2.7)
