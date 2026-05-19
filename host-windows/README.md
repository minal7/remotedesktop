# RemoteDesktopHost (Windows)

Windows counterpart of `host-mac/`. Same protocol, same WebRTC, same
CloudKit-backed signaling — just different system APIs under the hood.

## Stack

- **Rust** host process for the first Windows milestone.
- **CloudKit Web Services** (REST) via `reqwest`. Launch is gated by
  Apple ID/iCloud sign-in; the host will not advertise a pairing code
  until a CloudKit Web Auth Token is obtained and validated.
- **Windows Credential Manager** via `keyring` for the CloudKit web-auth
  token and persistent device sender ID.
- **Next:** `webrtc-rs`, `windows-rs`, `enigo`, then the Tauri tray/UI
  shell once the transport is alive.

## Why Rust + Tauri (and not C#/WinUI)

- Rust gives us first-class `webrtc-rs` — the C# WebRTC ecosystem is
  stuck on ancient Microsoft-maintained forks.
- Tauri is ~10 MB installed; WinUI + WebView2 is ~60 MB and drags
  more deployment pain.
- Windows.Graphics.Capture and enigo both have clean Rust bindings, so
  there is nothing we'd gain by dropping into C#.
- A single language across host + signaling + input keeps the scope
  manageable for v1.

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

Then launch the host with:

```powershell
$env:REMOTE_DESKTOP_CLOUDKIT_API_TOKEN = "<CloudKit API token>"
$env:REMOTE_DESKTOP_CLOUDKIT_ENV = "development"
cargo run
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

Implemented:

- Mandatory Apple ID/iCloud auth gate before the host can run.
- CloudKit Web Services client for authenticated private-database
  requests.
- Persistent Windows host device identity.
- `HostAdvertisement` publishing and `WebRTCSignal` polling.
- Preflight offer response for the transitional signaling transport.

Not implemented yet:

- WebRTC answer generation, ICE handling, screen capture, system audio,
  and input injection.
- Tauri tray/UI shell. Current milestone is a Rust host process.
