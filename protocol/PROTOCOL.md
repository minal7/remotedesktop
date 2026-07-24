# Wire protocol (v1)

Shared contract between iOS client and host agents. All peers speak this
over a single reliable-ordered WebRTC data channel named `control`. Video
and audio ride on standard WebRTC media tracks and don't appear here.

## Framing

Each data-channel message is one JSON object, UTF-8 encoded, terminated by
the channel boundary. No length prefix — WebRTC already gives us message
framing on reliable-ordered channels.

Every message has:
```jsonc
{
  "t": "<type>",    // message type (see below)
  "s": <uint32>,    // monotonically increasing sequence number, per sender
  "ts": <uint64>    // sender monotonic clock, microseconds
}
```

Receivers MUST ignore messages with unknown `t` rather than disconnecting —
this lets us add message types without a hard version bump.

## Session lifecycle

```
client                              host
  │  ── hello{proto:1, client:…} ──▶
  │  ◀── hello_ack{proto:1, host:…, caps:{…}} ──
  │  ◀── display{w, h, scale, monitors:[…]} ──
  │
  │  ── input events / control messages ──▶
  │  ◀── display updates / notices ──
  │
  │  ── bye ─▶ or ◀── bye ──
```

A `hello_ack` with `proto` different from the client's `proto` in `hello`
terminates the session; both sides send `bye`. AI Computer Use additionally
requires both peers to advertise `orderedComputerUseControls: 1` in their
respective hello capability dictionaries. This scoped negotiation keeps
ordinary protocol-v1 remote control compatible with Windows, Android, and
staggered iOS/macOS upgrades while preventing mixed-generation automation.

## Message types

### `hello` (client → host)

```jsonc
{ "t": "hello", "s": 0, "ts": …,
  "proto": 1,
  "client": { "app": "RemoteDesktop-iOS", "version": "0.1.0",
              "device": "iPad13,8", "osVersion": "18.0",
              "orderedComputerUseControls": 1 } }
```

### `hello_ack` (host → client)

```jsonc
{ "t": "hello_ack", "s": 0, "ts": …,
  "proto": 1,
  "host": { "app": "RemoteDesktop-Mac", "version": "0.1.0",
            "os": "macOS 15.1", "hostname": "studio.local" },
  "caps": { "audio": true, "clipboard": false, "fileTransfer": false,
            "monitors": 1, "maxFps": 60,
            "orderedComputerUseControls": 1 } }
```

### `display` (host → client)

Sent on connect and whenever the active display changes (resolution, HiDPI
scale, monitor switch).

```jsonc
{ "t": "display", "s": …, "ts": …,
  "w": 2560, "h": 1440,                 // logical pixel size of active monitor
  "scale": 2.0,                         // HiDPI backing scale
  "monitors": [
    { "id": 0, "w": 2560, "h": 1440, "x": 0, "y": 0, "primary": true }
  ],
  "active": 0 }
```

### `pointer` (client → host)

Absolute pointer position in the host's logical pixel space, plus button
state. Coalesce at the sender — don't send more than one per WebRTC frame.

```jsonc
{ "t": "pointer", "s": …, "ts": …,
  "x": 1230, "y": 456,
  "buttons": 0b001,    // bit 0 = left, 1 = right, 2 = middle
  "flags": 0 }         // reserved, must be 0 in v1
```

### `scroll` (client → host)

Wheel / trackpad scroll. Deltas are in host-logical pixels; positive `dy`
means "content moves up" (natural scrolling is handled by the host).

```jsonc
{ "t": "scroll", "s": …, "ts": …,
  "x": 1230, "y": 456,
  "dx": 0, "dy": -30,
  "phase": "changed" }   // "begin" | "changed" | "end" | "momentum"
```

### `key` (client → host)

Raw key events. Key codes are **USB HID usage codes** (page 0x07), not
platform keycodes — this avoids every-OS translation tables on the client.
The host maps HID usage → its local keycode.

```jsonc
{ "t": "key", "s": …, "ts": …,
  "usage": 0x04,              // HID usage for 'a'
  "down": true,
  "modifiers": 0b0001 }       // bit 0 = L⇧, 1 = L⌃, 2 = L⌥, 3 = L⌘,
                              // 4 = R⇧, 5 = R⌃, 6 = R⌥, 7 = R⌘, 8 = Caps
```

### `text` (client → host)

Fallback for IME / soft-keyboard composed text. Host injects as a series of
unicode key events (platform-specific: `CGEventKeyboardSetUnicodeString`
on macOS, `SendInput` with `KEYEVENTF_UNICODE` on Windows).

```jsonc
{ "t": "text", "s": …, "ts": …, "s2": "hello" }
```

### `qos` (client → host)

Lets the client hint at desired video quality when it knows better than the
receiver's bandwidth estimation (e.g. user chose "prioritize fluency" or
"prioritize sharpness").

```jsonc
{ "t": "qos", "s": …, "ts": …,
  "targetFps": 60,
  "maxBitrateKbps": 12000,
  "prefer": "fluency" }    // "fluency" | "sharpness" | "auto"
```

### `bye` (either → either)

```jsonc
{ "t": "bye", "s": …, "ts": …,
  "reason": "user" }   // "user" | "error" | "timeout" | "protocol"
```

## Automatic Apple-Account pairing → signaling room

The host and client use the same private CloudKit database, so the client can
discover the user's computers automatically. The person chooses a computer;
there is no code field or copied secret. A six-digit value remains in the
deployed `pairingCode` schema field as a short-lived internal routing binding.
The host publishes and refreshes a `HostAdvertisement` containing that binding
and its opaque sender ID. The client binds to the exact host sender ID and
exchanges SDP/ICE in targeted `WebRTCSignal` records. Records older than 5
minutes are ignored, and each side removes its own records after connection or
teardown.

For nearby local AI, the client requests the exact credential fingerprint
advertised by the authenticated CloudKit-plus-Bonjour host. Ephemeral X25519
keys derive an HKDF-SHA256 key, and AES-GCM seals the device-local TLS
credential. Request, client, host, account, routing, and credential identities
are authenticated as associated data. Only the encrypted credential crosses
CloudKit; the receiving device stores it as a non-synchronizing,
ThisDeviceOnly Keychain item.

## Security

- Private CloudKit has a strict allowlist: host discovery, same-account local
  enrollment and encrypted credential exchange, remote-control
  offer/answer/ICE/bye signaling, and Computer Use `setupRequest` /
  `setupProgress`. It MUST reject ordinary AI task messages. Discovery,
  signaling, and enrollment use five-minute validity windows; setup lifecycle
  records use a one-hour validity window. Reads, pages, pending deletions,
  replay state, and owned-record cleanup are bounded, and an exhausted bound
  fails closed rather than widening the query or retaining unbounded process
  state.
- After local enrollment, the authenticated LAN TLS broker is the sole
  Computer Use task transport. Natural-language prompts, conversation
  context, task progress/status/results, pause/resume/cancel controls, and
  approval requests/responses MUST NOT fall back to CloudKit. Loss or failure
  of that broker ends or blocks the task without resubmitting it over another
  channel.
- Live screen pixels, host audio, and direct input stay on the encrypted
  WebRTC peer connection. The private database, exact host identity, internal
  binding, and SDP fingerprint scope that remote-control handshake.
- Hosts SHOULD show a "session active" indicator for the duration of the
   connection. Mac: menu-bar icon turns red. Windows: system-tray icon
   turns red.

# AI Computer Use control plane

This AI control plane is currently implemented only by the macOS host. The
Windows host remains an ordinary remote-desktop host and does not advertise or
execute AI Computer Use.

AI Computer Use deliberately separates the high-bandwidth live screen from
the low-bandwidth command lifecycle:

- WebRTC continues to carry live video, audio, and direct user input.
- Private CloudKit carries only discovery, enrollment, remote-control
  signaling, and setup request/progress records. Setup may complete before the
  LAN broker is ready; it does not authorize CloudKit as an ordinary task
  channel.
- Once enrolled, authenticated LAN TLS carries prompts and bounded
  conversation context, assistant responses, task progress/status/results,
  pause/resume/cancel controls, and approval exchanges. The client exposes no
  CloudKit fallback for this traffic.
- The macOS host plans and executes locally. Its always-installed semantic GUI
  router handles bounded app-first, literal-entry, and unambiguous navigation
  routes before checking Apple's on-device Foundation Model for the remaining
  typed GUI actions. The Foundation Model also proposes typed calls to reviewed
  MCP tools. For GUI-only work, a pinned, quantized OS-Atlas Pro 4B model grounds
  visual pointer targets; the host owns the final verb, validation, approval,
  and execution. The Base and Pro models are never resident together. A host
  only advertises AI availability when the
  notarized helper, signed inference runtime, and exact-hash visual-model
  artifacts are all verified and ready.
- Pausing cancels the current execution task and gates host-side input tools;
  the user can immediately operate the same live screen from iOS.

`HostAdvertisement` adds two optional fields so older builds remain readable:

- `computerUseState`: `unavailable`, `setupRequired`, `installing`, `ready`,
  `busy`, or `paused`.
- `computerUseDetail`: a short user-facing readiness explanation.

The same capability is mirrored after a newline in the existing `hostName`
field. New clients strip and decode that suffix; older clients keep showing the
first line. This is the Production-schema fallback when the optional AI fields
have not been deployed yet.

Nearby Bonjour discovery uses the computer name as its visible service name;
it does not append or display the internal six-digit routing value. A bounded
version-1 DNS-SD TXT record uses `v`, `sid`, `cu`, `cud`, plus optional `lci`
and `rb` keys. These carry the schema version, opaque per-install `senderID`,
capability state/detail, non-secret TLS credential fingerprint, and internal
routing binding. Legacy `Computer Name [123456]` advertisements remain readable
during upgrades. TXT metadata is only a discovery hint: iOS hides unmatched
Bonjour rows, and an exact same-account private-CloudKit host identity must
match before setup, connection, or Computer Use becomes available. Invalid,
oversized, conflicting, or future-version metadata can never replace the
CloudKit identity.

The CloudKit enrollment exchange and Computer Use setup lifecycle reuse the
already-deployed `WebRTCSignal` record type and its existing `senderID`,
`targetID`, `pairingCode`, `kind`, `payload`, and `createdAt` fields. Enrollment
uses its versioned credential request/response kinds. Setup allows only
`computerUse.setupRequest` and `computerUse.setupProgress`; the JSON `payload`
contains the message ID, session ID, and bounded body. This avoids a second
Production schema deployment and lets older signaling clients safely ignore
the records.

Setup records are filtered by internal routing binding and session ID, ignored
after their one-hour validity window, and acknowledged only after application.
Clients cap query pages/records and pending cleanup bookkeeping, persist a
bounded set of owned record identities across restarts, and retry deletion.
If deletion is unavailable, expired setup content remains in the user's
private database but is no longer accepted by the protocol.

The shared `ComputerUseEnvelope` also defines `prompt`, `assistant`, `status`,
`pause`, `resume`, `cancel`, `approvalRequest`, and `approvalResponse`, but
those kinds are valid only on the authenticated LAN TLS broker after
enrollment. A stable message/task ID preserves at-most-once execution and lets
the iOS device-only Keychain recover one in-flight task without recreating a
CloudKit prompt record. A TLS failure never changes the envelope's authorized
transport.

Setup requests carry an idempotency key; setup progress carries a user-facing
phase and optional normalized fraction covering the signed helper bytes,
visual-model bytes, verification, and runtime loading. Reopening iOS observes
the existing host installation instead of starting a duplicate download;
capability/status reads never start installation by themselves.

Privileged prompts and lifecycle controls are accepted only from the
account-enrolled sender authenticated by the LAN TLS credential. Before
consequential external actions (such as sending, purchasing, deleting,
changing security settings, or entering secrets), the local executor must stop
and return an `approvalRequest` over that broker. iOS replies over the same
broker with a one-time scoped `approvalResponse`; direct iOS input or physical
Mac input closes the action gate immediately. The host constructs approval
copy from the concrete action and Accessibility target rather than trusting
model text, fingerprints that target/focus and nearby screen pixels, and
revalidates immediately before executing exactly one approved action.

Structured MCP calls follow the same rule. The planner can only propose a call;
it cannot execute one. The host reconstructs arguments against the discovered
schema, applies its own allowlist/risk class, and records mutating calls before
dispatch. Approval-required calls carry exact held values (for example email
recipient, subject, and body), an expiring process/schema/argument fingerprint,
and a single-use approval. Pause, cancel, direct iOS input, or physical Mac
input invalidates the pending operation and terminates the local sidecar.

Apple Mail is a special reviewed route. The `remote_desktop_mail` MCP server is
embedded in the signed host and connected through an in-memory transport; the
downloaded helper's generic `mail_send` tool is blocked. The embedded tool
accepts exact To/CC/BCC, subject, body, and draft/send values, uses Mail's
default sending account, creates a visible message, and disables automatic
signatures so the approved body is unchanged. iOS displays every one of those
values before issuing its single-use approval.

After that mobile approval, the first Mail action may trigger macOS's
Automation prompt on the host. The permission preflight runs before the durable
mutation claim or any email-creation/send Apple event, so denial cannot create
an ambiguous send and no email is created or sent. The user can enable **Remote
Desktop Host → Mail** under **System Settings → Privacy & Security →
Automation** and submit a new request. Message values are delivered to a fixed
local automation program over standard input, not source text, command-line
arguments, environment variables, temporary files, or host logs.
