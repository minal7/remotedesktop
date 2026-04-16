# RemoteDesktopHost (Windows)

Windows counterpart of `host-mac/`. Same protocol, same WebRTC, same
CloudKit-backed signaling — just different system APIs under the hood.

## Stack

- **Rust + Tauri 2** for the tray/UI shell (small system webview, no
  Electron bloat).
- **`webrtc-rs`** — peer connection, media tracks, data channel.
- **`windows-rs`** for Windows.Graphics.Capture (fast path) and WASAPI
  loopback (system audio).
- **`enigo`** for synthetic keyboard/mouse input injection.
- **CloudKit Web Services** (REST) via `reqwest`. First launch pops a
  tiny `wry` webview to sign the user into iCloud and obtain a web-auth
  token; the token is persisted via the Windows Credential Manager. All
  subsequent signaling traffic is polled over HTTPS at 2 s cadence —
  same polling model as the native Apple clients, since there's no
  CloudKit native client on Windows.

## Why Rust + Tauri (and not C#/WinUI)

- Rust gives us first-class `webrtc-rs` — the C# WebRTC ecosystem is
  stuck on ancient Microsoft-maintained forks.
- Tauri is ~10 MB installed; WinUI + WebView2 is ~60 MB and drags
  more deployment pain.
- Windows.Graphics.Capture and enigo both have clean Rust bindings, so
  there is nothing we'd gain by dropping into C#.
- A single language across host + signaling + input keeps the scope
  manageable for v1.

## CloudKit on Windows — the catch

There is no first-party CloudKit client for Windows. We use CloudKit's
public **Web Services** REST API (`https://api.apple-cloudkit.com`)
with **Web Auth Token** authentication:

1. First launch opens `wry` webview to `https://icloud.com` for login.
2. The app captures the Web Auth Token (`ckWebAuthToken`) from the
   authenticated session.
3. Token goes into Windows Credential Manager for reuse across launches.
4. All subsequent CloudKit record ops hit the REST API with that token.

## Status

Not yet implemented. This folder is a skeleton — see `PROGRESS.md` at
the repo root for the ordered task list. First milestone: reach pairing
parity with the Mac host (advertise a `HostAdvertisement`, accept an
offer over CloudKit, round-trip ICE, produce a black-video answer).
