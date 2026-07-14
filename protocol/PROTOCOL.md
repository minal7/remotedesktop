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
terminates the session; both sides send `bye`.

## Message types

### `hello` (client → host)

```jsonc
{ "t": "hello", "s": 0, "ts": …,
  "proto": 1,
  "client": { "app": "RemoteDesktop-iOS", "version": "0.1.0",
              "device": "iPad13,8", "osVersion": "18.0" } }
```

### `hello_ack` (host → client)

```jsonc
{ "t": "hello_ack", "s": 0, "ts": …,
  "proto": 1,
  "host": { "app": "RemoteDesktop-Mac", "version": "0.1.0",
            "os": "macOS 15.1", "hostname": "studio.local" },
  "caps": { "audio": true, "clipboard": false, "fileTransfer": false,
            "monitors": 1, "maxFps": 60 } }
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

## Pairing code → signaling room

A pairing code is 6 digits and uniformly random. The host publishes and
refreshes a `HostAdvertisement` containing that code and its opaque sender ID
in the user's private CloudKit database. The client queries recent matching
advertisements, binds to the newest host sender ID, and exchanges SDP/ICE in
targeted `WebRTCSignal` records. Records older than 5 minutes are ignored, and
each side removes its own records after connection or teardown.

## Security

- CloudKit carries SDP/ICE plus the low-bandwidth AI command lifecycle in the
  user's private database. It never carries live screen, host audio, or direct
  input; those stay on the encrypted WebRTC peer connection. AI prompts and
  approval values do pass through private CloudKit so the host can plan and the
  iOS client can show the exact proposed action.
- The pairing code is entropy for the initial handshake only. Once a
  peer connection exists, the DTLS fingerprint in the SDP authenticates
  all subsequent traffic — WebRTC's standard E2E encryption.
- Hosts SHOULD show a "session active" indicator for the duration of the
   connection. Mac: menu-bar icon turns red. Windows: system-tray icon
   turns red.

# AI Computer Use control plane

AI Computer Use deliberately separates the high-bandwidth live screen from
the low-bandwidth command lifecycle:

- WebRTC continues to carry live video, audio, and direct user input.
- The user's private CloudKit database carries prompts, assistant responses,
  progress, pause, resume, and cancel messages.
- The host plans and executes locally. On supported systems, Apple's on-device
  Foundation Model proposes typed calls to a pinned local MCP helper. A pinned,
  quantized OS-Atlas Pro 4B model is loaded only for GUI-only visual fallback;
  the Base and Pro models are never resident together. A host only advertises
  AI availability when the notarized helper, signed inference runtime, and
  exact-hash visual-model artifacts are all verified and ready.
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

Nearby Bonjour discovery keeps the legacy service name
`Computer Name [123456]` and adds a version-1 DNS-SD TXT record with only four
bounded keys: `v`, `sid`, `cu`, and `cud`. They carry the schema version, the
host's opaque per-install `senderID`, capability state, and a short sanitized
detail. iOS resolves and monitors that record so a nearby row can offer setup
before CloudKit discovery refreshes. Invalid, oversized, or future-version TXT
records fall back to the legacy row. TXT metadata is only a discovery hint:
CloudKit still resolves pairing and carries every setup/control message, and a
conflicting Bonjour identity never replaces a CloudKit identity.

Computer Use messages reuse the already-deployed `WebRTCSignal` record type
and its existing `senderID`, `targetID`, `pairingCode`, `kind`, `payload`, and
`createdAt` fields. `kind` is prefixed with `computerUse.`; the JSON `payload`
contains the message ID, session ID, and body. This avoids a second Production
schema deployment and lets older signaling clients safely ignore these
records. All records stay in the private database and are filtered again by
pairing code and session ID on read, then deleted only after the receiver
explicitly acknowledges application.
Receivers acknowledge only after applying a message. A prompt that arrives
just before WebRTC peer authorization is left in CloudKit for a later poll,
while the host's durable task ledger makes repeated stable prompt IDs
at-most-once across process restarts.

Computer Use kinds are `setupRequest`, `setupProgress`, `prompt`, `assistant`,
`status`, `pause`, `resume`, `cancel`, `approvalRequest`, and
`approvalResponse`. Setup requests carry an idempotency
key; setup progress carries a user-facing phase and optional normalized
fraction covering the signed helper bytes, visual model bytes, verification,
and runtime loading. Reopening iOS observes the existing host installation
instead of starting a duplicate download; capability/status reads never start
installation by themselves. Assistant and status bodies carry their stable task
ID, preventing a delayed replay from an older task from completing a newer chat
request. iOS keeps one in-flight prompt/session ID in the device Keychain and
periodically recreates the same CloudKit record until a terminal response.

Privileged prompts and lifecycle controls are accepted only from the sender ID
bound to the active WebRTC peer; pre-pairing setup requests remain available so
the device-row setup flow can download the model before opening a screen
session. Before consequential external actions (such as sending, purchasing,
deleting, changing security settings, or entering secrets), the local executor
must stop and send an `approvalRequest`. iOS replies with a one-time scoped
`approvalResponse`; direct iOS input or physical Mac input closes the action
gate immediately. The host constructs approval copy from the concrete action
and Accessibility target rather than trusting model text, fingerprints that
target/focus and nearby screen pixels, and revalidates immediately before
executing exactly one approved action.

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
