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

Ships with a small `eframe`/`egui` window that mirrors the macOS
status popover — same five states (idle → starting → advertising →
paired → error) and the same Start / Stop / Quit affordances. The
window registers a procedurally-drawn monitor icon, so the host shows
up in the Windows taskbar with a recognizable icon and is brought to
focus on click. Release builds use `windows_subsystem = "windows"` so
no console window flashes on launch; logs go to
`%LOCALAPPDATA%\RemoteDesktopHost\host.log` instead of stdout.

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

For local development, build with `cargo build --release` and run
`target/release/remote-desktop-host.exe`. For shipping a distributable
build, see [Packaging & distribution](#packaging--distribution) below.

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

## Packaging & distribution

The release build is a single, self-contained `.exe`:

- **No CloudKit token prompt.** The token is baked into the binary at
  compile time. `config.rs` reads it from the process environment first
  (so `.env` / shell vars still win for local dev) and otherwise falls
  back to a value embedded via `option_env!`. A build with the env var
  set ships a binary that runs with zero per-machine setup. CloudKit Web
  Services API tokens are designed to be client-embedded — the real
  per-user secret is the web-auth token obtained at Apple ID sign-in.
- **No VC++ Redistributable needed.** `.cargo/config.toml` statically
  links the MSVC C runtime (`+crt-static`); the bundled C encoders are
  compiled with the matching `/MT` runtime.
- **Real icon + version metadata.** `build.rs` embeds
  `assets/icon.ico` and file-properties via `winresource`. Regenerate
  the icon with `pwsh packaging/generate-icon.ps1` only if the design in
  `src/ui.rs` changes.

### Automated GitHub release (recommended)

`.github/workflows/release.yml` builds, packages, and publishes on a tag.

One-time setup in the GitHub repo (Settings → Secrets and variables →
Actions):

- **Secret** `CLOUDKIT_API_TOKEN` — the CloudKit Web Services API token.
- **Variable** `CLOUDKIT_ENV` *(optional)* — `production` (default) or
  `development`.

Cut a release:

```powershell
# 1. Bump the version (source of truth for the embedded build).
#    Edit `version` in host-windows/Cargo.toml, then refresh the lock:
cargo update -p remote-desktop-host
# 2. Commit Cargo.toml + Cargo.lock.
# 3. Tag with a matching v-prefixed version and push:
git tag v0.1.0
git push origin v0.1.0
```

The workflow verifies the tag matches `Cargo.toml`, builds with the
token baked in, and attaches two artifacts to a GitHub Release:

- `RemoteDesktopHost-Setup-<version>.exe` — Inno Setup installer.
- `RemoteDesktopHost-<version>-portable-x64.zip` — the bare `.exe`.

### Building the installer locally

To produce/test the installer without CI, install
[Inno Setup 6](https://jrsoftware.org/isdl.php), then:

```powershell
$env:REMOTE_DESKTOP_CLOUDKIT_API_TOKEN = "<token>"
$env:REMOTE_DESKTOP_CLOUDKIT_ENV = "production"
cargo build --release
iscc /DMyAppVersion=0.1.0 packaging/installer.iss
# → dist/RemoteDesktopHost-Setup-0.1.0.exe
```

The installer defaults to a per-user install (no UAC prompt), adds a
Start Menu shortcut, cleans up the launch-at-login registry value and
log directory on uninstall, and closes/relaunches a running instance on
upgrade.

### Code signing & SmartScreen

The released exe/installer is **unsigned**. On first download users see
a Microsoft Defender SmartScreen "unknown publisher" warning and must
click *More info → Run anyway*. To remove it, sign the artifacts with an
Authenticode certificate (an EV cert clears SmartScreen reputation
immediately). Wire `signtool sign /fd sha256 /tr <timestamp-url> ...`
into the workflow after the build and installer steps once a cert is
available. The Microsoft Store path (below) signs the package for you.

## Microsoft Store (MSIX) — future

The Store accepts the same win32 executable wrapped in an **MSIX**
package, and signs it on ingestion (no cert purchase needed for the
Store channel). High-level path:

1. Reserve the app name and create an app in
   [Partner Center](https://partner.microsoft.com/dashboard); note the
   assigned **Package/Identity/Name** and **Publisher** values.
2. Author an `AppxManifest.xml` (template below), providing PNG assets
   (Square44x44Logo, Square150x150Logo, etc.) generated from the same
   icon design.
3. Build the MSIX from the release `.exe`:
   ```powershell
   makeappx pack /d <staging-dir> /p RemoteDesktopHost.msix
   ```
   or drive it with the **MSIX Packaging Tool** (GUI).
4. Upload the `.msix` to Partner Center; the Store re-signs and
   distributes it.

Caveats to validate before committing to the Store path:

- **Per-user autostart**: the HKCU `Run` key write in `autostart.rs`
  works for sideloaded MSIX but Store packages should prefer the
  `windows.startupTask` extension declared in the manifest.
- **Input injection** (`SendInput`) and **screen capture**
  (Windows.Graphics.Capture) run fine in a packaged context, but
  Store certification scrutinizes apps that inject input — be ready to
  document the remote-control use case.

Minimal manifest template to adapt (replace the `Identity` values with
the ones Partner Center assigns):

```xml
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
  <Identity Name="Threadmark.RemoteDesktopHost"
            Publisher="CN=<from Partner Center>"
            Version="0.1.0.0"
            ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>Remote Desktop Host</DisplayName>
    <PublisherDisplayName>Threadmark</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0"
                        MaxVersionTested="10.0.22621.0" />
  </Dependencies>
  <Resources><Resource Language="en-us" /></Resources>
  <Applications>
    <Application Id="RemoteDesktopHost" Executable="remote-desktop-host.exe"
                 EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="Remote Desktop Host"
                          Description="Remote Desktop Host"
                          BackgroundColor="transparent"
                          Square150x150Logo="Assets\Square150x150Logo.png"
                          Square44x44Logo="Assets\Square44x44Logo.png" />
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
```
