# RemoteDesktop iOS client

SwiftUI app for iPad and iPhone. Phase 2 keeps the input UX in place and
replaces the fake "connect" path with a real signaling-backed preflight
handshake, so 6-digit pairing codes are validated against a live host
before WebRTC/video land.

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

For local development against a dev signaling Worker:

- Simulator: defaults to `http://127.0.0.1:8787`
- Real iPhone: set the signaling URL in the app's debug connection
  settings to `http://<your-mac-lan-ip>:8787`, then run
  `npm run dev:lan`

## What works today

- Enter a 6-digit pairing code and complete a real signaling round-trip
  with the Mac host before the session transitions to connected.
- Indirect pointer on iPad (trackpad, Magic Mouse, Pencil hover):
  absolute-position pointer events + indirect scroll + right/middle
  click via `UIEvent.buttonMask`.
- Hardware keyboard via `GCKeyboard`: raw HID keycodes + modifier mask.
- Touch-cursor mode (no accessories): finger-delta cursor at 1.2×
  gain, tap = left click, long-press = right click, two-finger pan = scroll.
- Soft keyboard, floating button, on-screen modifier keys, and a hardware
  keyboard handoff that hides the soft layout while a keyboard is attached and
  restores it smoothly when the keyboard disconnects.
- Chrome collapses to a thin status strip when keyboard + pointer are
  both connected, per the project's UX contract.

## What's stubbed

- `SignalingPreflightTransport` validates the pairing code and gets a
  host acknowledgment, but it still drops control messages until the
  WebRTC data channel is wired up.
- `RemoteScreenView` renders a dark placeholder in place of video.
  Replace the placeholder `CALayer` with `AVSampleBufferDisplayLayer`
  fed from a WebRTC video track.
- `SignalingClient` still only handles the pre-WebRTC relay path.

## App Store compliance checklist (tracked in top-level README)

- ✅ Pairing code entered per session → user-initiated
- ✅ No private APIs
- ✅ `NSLocalNetworkUsageDescription` present
- ⬜ App Review notes explaining remote-control behavior (add before
  submission — reference Guideline 4.2.7)
