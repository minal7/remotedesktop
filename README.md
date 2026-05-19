# RemoteDesktop

iPad / iPhone client that remotely controls a Mac or Windows computer over the
internet. No port forwarding, no self-hosted server.

## Architecture at a glance

```
┌────────────────┐          ┌──────────────────────┐          ┌─────────────────┐
│  iOS client    │ ──SDP──▶ │  Cloudflare Worker   │ ◀──SDP── │  Host agent     │
│  (iPad/iPhone) │ ◀─SDP──  │  (signaling room)    │  ──SDP─▶ │  (Mac / Windows)│
└───────┬────────┘          └──────────────────────┘          └────────┬────────┘
        │                                                              │
        │  ──────────────  WebRTC peer connection  ──────────────────▶ │
        │                (STUN + Cloudflare TURN fallback)             │
        │                                                              │
        │  ◀──  video (H.264)  ── audio (Opus)  ── input (DataChannel)─│
```

- **Transport:** WebRTC. Video track (H.264) for screen, audio track (Opus)
  for host audio, reliable-ordered data channel for input events + control
  messages.
- **Signaling:** Cloudflare Worker with one Durable Object per pairing code.
  The Worker is stateless glue — no user data persisted beyond a session's
  lifetime.
- **NAT traversal:** Google's public STUN + Cloudflare Realtime TURN (free
  tier). Works across symmetric NATs / CGNAT.
- **Pairing:** 6-digit numeric code displayed on the host; user types it into
  the iOS client. Codes expire on session teardown or after 5 minutes unused.

## Repository layout

| Path | What lives here |
| --- | --- |
| `ios/` | SwiftUI iPad + iPhone client |
| `host-mac/` | Menu-bar Swift agent using ScreenCaptureKit + CGEvent + CoreAudio |
| `host-windows/` | Rust Windows host process; CloudKit/Apple ID auth is wired, WebRTC/capture/input next |
| `signaling/` | Cloudflare Worker — pairing rooms, SDP + ICE relay |
| `protocol/` | Wire-format spec shared across all three clients |

## Build status (v1)

| Component | State |
| --- | --- |
| Protocol spec | draft |
| Signaling Worker | scaffolded |
| iOS client — input + accessory-aware UI | scaffolded (mock transport) |
| iOS client — WebRTC peer connection | **not yet** |
| Mac host agent — menu bar + capture + injection + signaling | scaffolded |
| Mac host agent — WebRTC peer connection | **not yet** |
| Windows host agent — Apple ID auth + CloudKit pairing | scaffolded |

End-to-end pairing (iOS ↔ Worker ↔ Mac host) is testable once `SIGNALING_URL`
points at a running Worker. Actual video/audio/input over WebRTC lands in
Phase 3 when the peer connection is wired into both clients.

## Getting started (developer)

### Signaling Worker

```sh
cd signaling
npm install
npx wrangler dev    # local dev (http://127.0.0.1:8787)
npx wrangler deploy # prod
```

### iOS client

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
xcodegen generate
open RemoteDesktop.xcodeproj
```

Set `SIGNALING_URL` in the scheme's Run environment to your dev Worker,
or edit `ios/RemoteDesktop/Config.swift` for the deployed URL.

### Mac host agent

```sh
cd host-mac
xcodegen generate
open RemoteDesktopHost.xcodeproj
```

First run will prompt for Screen Recording and Accessibility permissions.
Set `SIGNALING_URL` in the scheme if running against a local Worker.

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

## App Store compliance notes

- Remote-control apps are permitted (Apple App Review Guidelines 4.2.7) as
  long as the user initiates each session to a device they own. We meet this
  by requiring a pairing code typed into the client per session.
- No private screen-capture APIs used on iOS. Host-side capture uses public
  ScreenCaptureKit (macOS 12.3+) and DXGI Desktop Duplication (Windows 10+).
- Background execution: an active session holds `voip` is *not* used; sessions
  pause when backgrounded and prompt the user to resume. This is within
  Apple's BGTask rules.
- Privacy strings in `Info.plist`: `NSLocalNetworkUsageDescription`,
  `NSBonjourServices` (for optional LAN fast-path in a later phase).
- No mic / camera / location access required for v1.
