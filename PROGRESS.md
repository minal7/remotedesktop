# RemoteDesktop — Migration Tracker

Living document for the in-flight architecture migration. Keep this up to
date as decisions land and code moves. Anything not written here can be
forgotten between sessions — if it matters, capture it here.

---

## Target architecture (post-migration)

```
┌────────────────┐                                    ┌─────────────────┐
│  iOS client    │  ── SDP / ICE via CloudKit ──────▶ │  Host agent     │
│  (iPad/iPhone) │                                    │  (Mac / Windows)│
│                │ ◀── SDP / ICE via CloudKit ──────  │                 │
└───────┬────────┘                                    └────────┬────────┘
        │                                                      │
        │   ─── WebRTC (STUN-only, TURN-less)   ─────────────▶ │
        │       video H.264 · audio Opus · DataChannel         │
```

- **Signaling:** CloudKit (Private DB, same-iCloud only) — **A** in the
  pairing-model decision. Polling-based during active sessions. No
  CKQuerySubscription / APNs for v1; add later as an optimization.
- **STUN config:** single `ICEConfig` record in the **Public** DB, delivers
  the list of public STUN URLs. Clients fetch once per session.
- **NAT traversal:** STUN-only. If ICE doesn't reach `connected` inside a
  timeout, surface a friendly `"Can't reach your computer — try same Wi-Fi"`
  error. No TURN fallback.
- **Cost profile:** $0 forever, any scale. Each user's signaling traffic
  lives in their own iCloud quota; we don't operate infrastructure.

### Decisions already locked

| # | Decision | Locked? |
| - | -- | -- |
| 1 | Team name / bundle prefix: `threadmark` → `com.threadmark.*` | ✅ |
| 2 | CloudKit container: `iCloud.com.threadmark.remotedesktop` | ✅ |
| 3 | Pairing model: **A** — same-iCloud only, no CKShare | ✅ |
| 4 | Skip `libzt` (ZeroTier). STUN only. Fail gracefully on TURN-need. | ✅ |
| 5 | Windows host: **Rust + Tauri** (`windows-rs`, `webrtc-rs`, `enigo`) | ✅ |
| 6 | Signaling transport during session: **polling** (2s cadence), not push | ✅ |

### Why polling, not CKQuerySubscription
- No push entitlement needed → simpler signing, less App-ID config.
- Push prompts the user for notification permission on first send on iOS — bad UX for a remote-control tool.
- Polling cost during an active session ≈ 30 req/min/user, well under CloudKit's 40 req/s rate limit.
- We only poll while a session is active. Idle clients poll zero.
- Can add CKQuerySubscription later as an optimization without breaking the wire protocol.

---

## CloudKit record schema

### `WebRTCSignal` — Private DB, `_defaultZone`

One record type handles the entire handshake. Records are deleted by the
sender on session teardown; stale records filtered by `createdAt`.

| Field | Type | Query? | Notes |
| -- | -- | -- | -- |
| `senderID` | String | sortable | Per-device UUID (Keychain-persisted). |
| `targetID` | String | **queryable**, sortable | Empty string means "advertise" (any host listening for this code). |
| `pairingCode` | String | **queryable**, sortable | 6-digit. |
| `role` | String | sortable | `"host"` or `"client"`. |
| `kind` | String | sortable | `"advertise" \| "offer" \| "answer" \| "ice" \| "bye"`. |
| `payload` | String | — | JSON blob. SDP / ICE candidate dict. Opaque to CloudKit. |
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

## Pairing flow (same-iCloud model A)

```
HOST                              CLIENT
  │                                 │
  │ 1. generate CODE                │
  │ 2. CK.save(WebRTCSignal{        │
  │      kind:"advertise",          │
  │      pairingCode:CODE,          │
  │      targetID:"",               │
  │      senderID: H })             │
  │ 3. show CODE                    │
  │                                 │ user types CODE
  │                                 │
  │                                 │ 4. CK.query Private DB for
  │                                 │    kind="advertise"
  │                                 │    pairingCode=CODE
  │                                 │    createdAt > now-5min
  │                                 │    → gets host senderID H
  │                                 │
  │                                 │ 5. CK.save(WebRTCSignal{
  │                                 │      kind:"offer",
  │                                 │      targetID: H,
  │                                 │      senderID: C,
  │                                 │      pairingCode: CODE,
  │                                 │      payload: <SDP> })
  │ 6. poll: targetID==H            │
  │    → gets offer from C          │
  │ 7. CK.save(answer)              │
  │                                 │ 8. poll: targetID==C → gets answer
  │ ... ICE candidates both ways ...│
  │                                 │
  │ 9. WebRTC "connected"           │
  │    → delete all own records     │
  │       for pairingCode=CODE      │
  │                                 │ 10. delete client-side records
```

**Stale-record hygiene:** after `connected`, both sides delete their own
`WebRTCSignal` records matching this `pairingCode`. On session close (bye),
same cleanup. Records with `createdAt > 5min` are ignored on read.

**Dedup on read:** each side tracks `Set<CKRecord.ID>` of already-consumed
records; keeps re-queries idempotent during the 2s poll loop.

---

## Remaining work (status mirrors TodoWrite)

- [x] **Mic permission / crash fix** (iOS + Mac).
- [x] **`PROGRESS.md`** — this file.
- [x] **Bundle ID rename** `com.example.*` → `com.threadmark.*`.
- [x] **Entitlements & project.yml** — CloudKit container on iOS and Mac.
- [x] **DeviceIdentity** — Keychain-backed per-device UUID (iOS + Mac).
- [x] **CloudKitSignalingClient** — conforms to `SignalingChannel`; drop-in.
- [x] **ICEConfigFetcher** — reads the Public `ICEConfig` record.
- [x] **Graceful ICE-timeout error** — 25 s deadline in `WebRTCTransport`
  surfaces `"Can't reach your computer — try putting both devices on the
  same Wi-Fi."` on timeout or early `RTCPeerConnectionState.failed`.
- [x] **Archive `signaling/`** — `signaling/DEPRECATED.md` written; code
  left in tree for now.
- [x] **Windows host scaffold** — `host-windows/` (Rust crate stub with
  module layout + README pinning the stack). Real work begins next.

## Next up (ordered)

1. **Windows CloudKit REST client** — `host-windows/src/signaling.rs`
   Web Services implementation, Web Auth Token bootstrap via `wry`.
2. **Windows WebRTC + capture + input** — `webrtc-rs`, Windows.Graphics.Capture,
   `enigo`.
3. **End-to-end iCloud pairing test** on real devices (out-of-band Apple
   Developer portal work required first; see below).
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
   - Create the single `ICEConfig` record in the Public DB with
     `recordName = "default"` and the STUN list.

## Notes & gotchas

- **Schema-promotion gotcha:** CloudKit Development DB auto-creates
  record types when you save a novel type. Production does *not*. First
  TestFlight build will fail queries until schema is promoted in the
  Dashboard. This is documented pain, not a bug.
- **Same-iCloud model:** a user's iPad and Mac must be signed into the
  same iCloud account. Error state surfaces as "no hosts found for code"
  when accounts diverge. Not a silent failure.
- **iOS Simulator CloudKit quirk:** simulators signed into "Simulator
  Apple ID" sometimes fail to create subscriptions. Run on a real device
  when in doubt.
- **Windows + CloudKit:** CloudKit JS via a small `wry` webview for the
  one-time iCloud sign-in. All subsequent records are fetched via the
  CloudKit Web Services REST API (token from the webview), polled 2s.
  There is no push channel on Windows — same polling model.
