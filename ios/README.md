# RemoteDesktop iOS client

SwiftUI app for iPad and iPhone with CloudKit pairing, live WebRTC screen and
audio playback, direct remote input, and the AI Computer Use chat experience.

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
Pair a Debug iOS build with a Debug Mac host. To connect Simulator to the
officially distributed Mac host, edit the iOS scheme's Run action to use the
Release configuration, then run it again.

Choose the configured development team and use Xcode's normal **Run** action;
do not install a build produced with `CODE_SIGNING_ALLOWED=NO`, because CloudKit
rejects that unsigned simulator binary. The Simulator must also be signed into
the same Apple Account as the host under Settings.

The iOS app has no camera capture path and does not declare Camera or Location
permission. It does declare a defensive microphone usage description because
the bundled WebRTC component is microphone-capable. The app does not request
that permission: its media transceivers are receive-only, audio uses the
playback session category, and it never records, stores, or transmits the
iPhone/iPad microphone.

## What works today

- Enter a 6-digit pairing code and complete a real signaling round-trip
  with the Mac host before the session transitions to connected.
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
  resumable and idempotent over CloudKit and reuses verified components.
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

- ✅ Pairing code entered per session → user-initiated
- ✅ No private APIs
- ✅ `NSLocalNetworkUsageDescription` present
- ⬜ App Review notes explaining remote-control behavior (add before
  submission — reference Guideline 4.2.7)
