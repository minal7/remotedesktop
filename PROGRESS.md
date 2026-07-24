# RemoteDesktop — Migration Tracker

Living document for the in-flight architecture migration. Keep this up to
date as decisions land and code moves. Anything not written here can be
forgotten between sessions — if it matters, capture it here.

---

## Target architecture (post-migration)

```
┌────────────────┐                                    ┌─────────────────┐
│  iOS client    │  ── bounded CloudKit lifecycle ──▶ │  Host agent     │
│  (iPad/iPhone) │                                    │  (Mac / Windows)│
│                │ ◀── discovery/enrollment/SDP/setup │                 │
└───────┬────────┘                                    └────────┬────────┘
        │                                                      │
        │   ─── WebRTC (STUN-only, TURN-less)   ─────────────▶ │
        │       video H.264 · audio Opus · DataChannel         │
        │                                                      │
        │   ═══ prompt / controls via authenticated LAN TLS ═▶ │
        │  ◀══ status / result / approval via same broker ═══  │
```

- **CloudKit lifecycle:** Private DB, same-Apple-Account only — **A** in the
  pairing-model decision. Its allowlist is host discovery, automatic
  enrollment and encrypted credential exchange, remote-control signaling, and
  Computer Use setup request/progress. Polling is bounded by validity, page,
  record, replay, and cleanup limits. No CKQuerySubscription / APNs for v1.
- **Computer Use task transport:** after enrollment, authenticated LAN TLS is
  authoritative for prompts, conversation, task status/results, controls, and
  approvals. There is no CloudKit fallback. Live pixels/audio/direct input
  remain WebRTC; planning, policy, and visual grounding stay on the Mac host.
- **STUN config:** single `ICEConfig` record in the **Public** DB, delivers
  the list of public STUN URLs. Clients fetch once per session.
- **NAT traversal:** STUN-only. If ICE doesn't reach `connected` inside a
  timeout, surface a friendly `"Can't reach your computer — try same Wi-Fi"`
  error. No TURN fallback.
- **Service profile:** CloudKit lifecycle traffic lives in each user's iCloud
  quota; no developer-operated signaling or AI relay receives task content.

### Decisions already locked

| # | Decision | Locked? |
| - | -- | -- |
| 1 | Team name / bundle prefix: `threadmark` → `com.threadmark.*` | ✅ |
| 2 | CloudKit container: `iCloud.com.threadmark.remotedesktop` | ✅ |
| 3 | Pairing model: **A** — same-Apple-Account only, no CKShare | ✅ |
| 4 | Skip `libzt` (ZeroTier). STUN only. Fail gracefully on TURN-need. | ✅ |
| 5 | Windows host: **Rust + Tauri** (`windows-rs`, `webrtc-rs`, `enigo`) | ✅ |
| 6 | Remote signaling/setup transport: bounded **polling**, not push | ✅ |

### Why bounded polling, not CKQuerySubscription
- No push entitlement needed → simpler signing, less App-ID config.
- Push prompts the user for notification permission on first send on iOS — bad UX for a remote-control tool.
- The remote-signaling poll cadence is about 30 req/min/user and is bounded to
  an active remote session.
- Remote signaling polls only while a session is active; setup polling stops
  at a terminal setup result. Idle clients poll neither channel.
- Can add CKQuerySubscription later as an optimization without breaking the wire protocol.

---

## CloudKit record schema

### `WebRTCSignal` — Private DB, `_defaultZone`

One deployed record type handles remote signaling plus the bounded enrollment
and setup lifecycle. Senders and receivers track the records they own or apply,
retry exact-record deletion, and reject records outside their validity window.

| Field | Type | Query? | Notes |
| -- | -- | -- | -- |
| `senderID` | String | sortable | Per-device UUID (Keychain-persisted). |
| `targetID` | String | **queryable**, sortable | Empty string means "advertise" (any host listening for this code). |
| `pairingCode` | String | **queryable**, sortable | Ephemeral internal session binding. Never shown or entered by a person. |
| `role` | String | sortable | `"host"` or `"client"`. |
| `kind` | String | sortable | Remote signaling (`"advertise"`, `"offer"`, `"answer"`, `"ice"`, `"bye"`), versioned local-credential enrollment, or `computerUse.setupRequest` / `computerUse.setupProgress`. Ordinary AI task kinds are forbidden on CloudKit. |
| `payload` | String | — | Bounded JSON for SDP/ICE, encrypted enrollment, or setup lifecycle data. Opaque to CloudKit. |
| `createdAt` | Date/Time | **queryable**, sortable | Used for stale filtering + since-cursor. |

**Indexes:** CloudKit auto-creates indexes for fields marked queryable in
the Dashboard. In Development, records are schema-auto-created on first
save, but indexes are not — they must be added manually in the Dashboard
after the first record lands, or queries by `pairingCode` / `targetID`
will fail.

### `ICEConfig` — Public DB, single well-known record

| Field | Type | Notes |
| -- | -- | -- |
| `recordName` | — | Fixed: `"default"`. Makes fetch-by-ID deterministic. |
| `stunURLs` | [String] | e.g. `["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]`. |
| `updatedAt` | Date/Time | For local cache freshness decisions. |

Editing this one record in the CloudKit Dashboard rotates STUN providers
for every client with no code change. No TURN fields — that's the whole
point.

---

## Automatic pairing flow (same-Apple-Account model A)

```text
HOST                                      CLIENT
  │                                         │
  │ Both resolve the current owner of the same private CloudKit container.
  │ The opaque owner digest is used only to separate device-local credentials.
  │                                         │
  │ Publish private CloudKit advertisement  │ Discover account-owned Macs
  │ plus nearby Bonjour route/fingerprint ─▶│ and match host + internal session
  │                                         │
  │◀── private-DB enrollment request ───────│ Generate ephemeral key agreement
  │    (public key + expected fingerprint)  │
  │                                         │
  │ Verify current account again; encrypt   │
  │ account-bound LAN credential ──────────▶│ Verify binding/fingerprint and
  │                                         │ store only in device Keychain
  │                                         │
  │◀════════ authenticated local TLS ═══════│ Send one natural-language task
  │       prompt / progress / typed result  │
```

There is no pairing field, displayed code, copied access key, or approval step.
The six-digit value retained in the wire format is only an ephemeral internal
session-routing value for compatibility with the deployed CloudKit schema. It
is not an authentication factor and is carried in bounded Bonjour TXT metadata
rather than the visible service name. The LAN credential is encrypted in the
private database, bound to the exact CloudKit account/container, stored as a
non-synchronizable Keychain item, and revalidated when the Apple Account
changes. A confirmed sign-out or restriction disables the local broker.

Remote screen sessions use the same automatically discovered internal session
binding for their existing offer/answer/ICE exchange; the app never asks the
person to type it.

**Bounded record hygiene:** discovery, enrollment, and remote signaling records
expire after five minutes; setup lifecycle records expire after one hour.
Applied records are deleted by exact ID, with bounded persisted cleanup
identity so an interrupted deletion can be retried after restart. Query pages,
observed records, pending acknowledgements, owned records, and replay entries
all have hard ceilings. Expired records are ignored, and hitting a ceiling
fails closed rather than growing memory or widening a query.

---

## Remaining work (status mirrors TodoWrite)

- [x] **Audio permission / crash fix** — iOS is receive-only and playback-only;
  the Mac requests Microphone only when optional host system audio is enabled.
- [x] **`PROGRESS.md`** — this file.
- [x] **Bundle ID rename** `com.example.*` → `com.threadmark.*`.
- [x] **Entitlements & project.yml** — CloudKit container on iOS and Mac.
- [x] **DeviceIdentity** — Keychain-backed per-device UUID (iOS + Mac).
- [x] **CloudKitSignalingClient** — conforms to `SignalingChannel`; drop-in.
- [x] **Automatic local enrollment** — same-account CloudKit identity plus
  Bonjour discovery, ephemeral key agreement, encrypted credential exchange,
  and device-only Keychain storage; no manual pairing code.
- [x] **Local Computer Use task broker** — authenticated LAN TLS carries the
  post-enrollment prompt, conversation, task result, controls, and approvals;
  CloudKit remains setup-only for AI.
- [ ] **Signed Release end-to-end acceptance** — prove automatic enrollment,
  LAN TLS prompt/result, visual WebRTC sidecar, approval routing, and
  host-local planning/grounding on the signed-in iPhone Air Simulator.
- [x] **ICEConfigFetcher** — reads the Public `ICEConfig` record.
- [x] **Graceful ICE-timeout error** — 25 s deadline in `WebRTCTransport`
  surfaces `"Can't reach your computer — try putting both devices on the
  same Wi-Fi."` on timeout or early `RTCPeerConnectionState.failed`.
- [x] **Archive `signaling/`** — `signaling/DEPRECATED.md` written; code
  left in tree for now.
- [x] **Windows host scaffold** — `host-windows/` (Rust crate stub with
  module layout + README pinning the stack). Real work begins next.
- [x] **Windows Apple ID auth gate + CloudKit signaling** —
  `host-windows/` now requires CloudKit Web Auth Token sign-in before it
  advertises, stores credentials in Windows Credential Manager, publishes
  `HostAdvertisement`, polls `WebRTCSignal`, and answers preflight offers.

## Next up (ordered)

1. ~~**Windows WebRTC + capture + input**~~ — DONE. `webrtc-rs` peer
   session, `windows-capture` screen grab, `wasapi` loopback audio,
   `openh264`/`audiopus` encode, `enigo` injection. Portable surface
   unit-tested on macOS; the `#[cfg(windows)]` capture seam in
   `host-windows/src/capture.rs` still needs a real Windows run.
2. **Tauri tray/UI shell** — dropped for v1. The legacy Windows host remains a
   console app; Apple clients now discover account-owned hosts automatically
   and never expose a pairing-code entry surface. Revisit a Windows tray after
   the account-discovery UX is validated there.
3. **End-to-end signed pairing/task validation** — first match a Release Mac
   host with the signed-in Release iPhone Air Simulator and prove automatic
   enrollment plus the no-fallback LAN task path. Follow with physical-device
   and Windows validation; build Windows with MSVC + CMake,
   `cargo run --release`.
4. **Production CloudKit schema promotion** once dev-DB records land.

## Work you (the user) need to do out-of-band

These can't be scripted — they happen in the Apple Developer portal and
CloudKit Dashboard:

1. **Apple Developer portal:**
   - Create two App IDs: `com.threadmark.remotedesktop.client`,
     `com.threadmark.remotedesktop.host`.
   - Enable **iCloud** capability on both App IDs.
   - Add CloudKit container `iCloud.com.threadmark.remotedesktop` and
     attach it to both App IDs.
2. **CloudKit Dashboard** (after first build writes records):
   - Promote `WebRTCSignal` schema from Development to Production when
     ready to ship. Dev auto-creates record types, prod requires promotion.
   - Add **queryable** indexes on `WebRTCSignal`:
     - `pairingCode` (queryable)
     - `targetID` (queryable)
     - `createdAt` (queryable)
   - Add **queryable** indexes on `HostAdvertisement`:
     - `pairingCode` (queryable)
     - `createdAt` (queryable)
   - Create the single `ICEConfig` record in the Public DB with
     `recordName = "default"` and the STUN list.

## Notes & gotchas

- **Schema-promotion gotcha:** CloudKit Development DB auto-creates
  record types when you save a novel type. Production does *not*. First
  TestFlight build will fail queries until schema is promoted in the
  Dashboard. This is documented pain, not a bug.
- **Same-Apple-Account model:** the iPhone/iPad and Mac must be signed into the
  same Apple Account for the app's CloudKit container. Hosts are discovered and
  paired automatically. A different account, confirmed sign-out, or account
  restriction fails closed without exposing a manual code fallback.
- **iOS Simulator CloudKit quirk:** simulators signed into "Simulator
  Apple ID" sometimes fail to create subscriptions. Run on a real device
  when in doubt.
- **Windows + CloudKit:** the Windows host uses a browser-based Apple ID
  web-auth prompt with a local loopback callback, then stores the
  CloudKit Web Auth Token in Windows Credential Manager. All subsequent
  remote-control discovery/signaling records are fetched via the CloudKit Web
  Services REST API. Windows AI Computer Use is not implemented, so Windows
  does not accept AI prompts or approvals through CloudKit. There is no push
  channel on Windows — the remote-signaling path uses the same polling model.
