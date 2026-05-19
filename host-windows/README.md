# RemoteDesktopHost (Windows)

Windows counterpart of `host-mac/`. Same protocol, same WebRTC, same
CloudKit-backed signaling — just different system APIs under the hood.

## Stack

- **`webrtc-rs`** — peer connection, H.264 + Opus sample tracks, the
  `control` data channel, ICE trickle.
- **`windows-capture`** — Windows.Graphics.Capture (BGRA frames).
- **`wasapi`** — WASAPI render-endpoint loopback (system audio).
- **`openh264`** — software H.264 encoder (BGRA → I420 → Annex-B).
- **`audiopus`** — Opus encoder (48 kHz stereo, 20 ms frames).
- **`enigo`** — synthetic keyboard / mouse / text injection.
- **CloudKit Web Services** (REST) via `reqwest`, gated by Apple
  ID/iCloud sign-in. The host will not advertise until a CloudKit Web
  Auth Token is obtained and validated.
- **Windows Credential Manager** via `keyring` for the web-auth token
  and the persistent device sender ID.

Console app — it prints the pairing code to stdout. There is no
Tauri/tray shell: the protocol only *recommends* a session indicator,
and a system-webview shell is a large dependency the "it just works"
path doesn't need. Deliberate v1 scope trim from the original plan.

## Why Rust (and not C#/WinUI)

- Rust gives us first-class `webrtc-rs` — the C# WebRTC ecosystem is
  stuck on ancient Microsoft-maintained forks.
- `windows-capture`, `wasapi` and `enigo` all have clean Rust bindings.
- A single language across host + signaling + input + media keeps the
  scope manageable for v1.

## CloudKit on Windows

There is no first-party CloudKit client for Windows. We use CloudKit's
public **Web Services** REST API (`https://api.apple-cloudkit.com`)
with **Web Auth Token** authentication:

1. The host probes CloudKit. If no valid token is stored, startup is
   blocked.
2. The host opens Apple's sign-in page in the default browser.
3. Apple redirects back to the local loopback callback with
   `ckWebAuthToken`.
4. The token goes into Windows Credential Manager for reuse across
   launches.
5. All subsequent private-database record ops include the token.

Apple documents these web-auth tokens as short-lived and single-use;
CloudKit may rotate the token in responses, and the host stores a
replacement token whenever one is returned.

## Configure Apple ID Sign-In

Create a CloudKit API token for `iCloud.com.threadmark.remotedesktop`.
Set the token's **Sign in Callback** / URL Redirect to:

```text
http://127.0.0.1:48172/icloud-auth-callback
```

## Build prerequisites (Windows)

The media encoders compile native code, so a release build needs:

- The MSVC build tools (`cl.exe`) — OpenH264 (`openh264-sys2`) compiles
  from source via `cc`.
- **CMake** on `PATH` — `audiopus_sys` builds libopus from source.

No prebuilt binary is shipped yet; build with `cargo build --release`
and run `target/release/remote-desktop-host.exe`.

Then launch the host with:

```powershell
$env:REMOTE_DESKTOP_CLOUDKIT_API_TOKEN = "<CloudKit API token>"
$env:REMOTE_DESKTOP_CLOUDKIT_ENV = "development"
cargo run --release
```

Optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `REMOTE_DESKTOP_CLOUDKIT_CONTAINER` | `iCloud.com.threadmark.remotedesktop` | CloudKit container ID |
| `REMOTE_DESKTOP_CLOUDKIT_ENV` | `development` | `development` or `production` |
| `REMOTE_DESKTOP_AUTH_CALLBACK_BIND` | `127.0.0.1:48172` | Local listener for Apple ID redirect |
| `REMOTE_DESKTOP_AUTH_CALLBACK_PATH` | `/icloud-auth-callback` | Callback path configured on the API token |
| `REMOTE_DESKTOP_POLL_SECONDS` | `2` | CloudKit short-poll cadence |
| `REMOTE_DESKTOP_STALE_SECONDS` | `300` | Stale signaling cutoff |

## Status

Implemented end-to-end:

- Mandatory Apple ID/iCloud auth gate before the host can run.
- CloudKit Web Services client; `HostAdvertisement` publish +
  `WebRTCSignal` poll; preflight-offer response.
- `ICEConfig` (public DB) STUN fetch with baked-in fallback.
- WebRTC: accept the client SDP offer, add a send-only H.264 screen
  track and send-only Opus system-audio track, answer, trickle ICE
  both ways, auto-restart the listener when a session ends.
- `control` data channel: `hello` → `hello_ack` + `display`; routes
  `pointer` / `scroll` / `key` / `text` into the input injector; `bye`
  ends the session.
- Screen capture (Windows.Graphics.Capture), system-audio loopback
  (WASAPI), H.264/Opus encode, `SendInput` injection.

### What is verified

The portable surface — protocol codec, HID→key mapping, BGRA→I420 +
H.264 + Opus encoders, signaling, ICE config — compiles and unit-tests
on any host (`cargo test`, 26 tests).

**Windows-only, unverified here:** the capture seam in `src/capture.rs`
(`windows-capture` + `wasapi`) is `#[cfg(windows)]` and can only be
exercised by building and running on Windows. It mirrors the macOS host
behavior but has not been run on a Windows machine in this workspace —
validate screen capture, loopback audio, and `SendInput` there.
