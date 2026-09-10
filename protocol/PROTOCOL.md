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

## Negotiated direct-input sessions

The Mac/iOS implementation can opt into `inputSessions: 1` without changing
base protocol v1. This extension binds pointer, key, scroll and text input to
a particular authorized connection lifetime. It supplements authenticated peer
and channel ownership; the UUIDs are freshness identifiers, not credentials.

A supporting client includes an optional `inputSession` object in `hello`:

```json
{"version":1,"clientID":"6F291DC4-5B15-4B1E-AC62-82AA2F46E313","revision":1}
```

The client uses a new UUID for each control-channel lifetime and a positive
UInt32 revision. After an observed transient connection loss, it disables
outbound input, increments the revision without wrapping, and sends a new hello
when both the connection and channel are ready. It does not queue or replay
input while waiting. An exhausted counter requires a new connection.

A supporting host advertises `caps.inputSessions: 1`. The current Mac also
requires a running capture attempt with admitted complete video output before
it authorizes input. When capture, connected state and the current channel's
hello are established, its `hello_ack` includes:

```json
{"inputSession":{"version":1,"clientID":"6F291DC4-5B15-4B1E-AC62-82AA2F46E313","revision":1,"hostID":"75AA76B8-BA2B-4C96-9FBD-927557D7A988","generation":1}}
```

The host echoes the exact client ID/revision and issues a fresh host UUID and
increasing positive UInt32 generation whenever its input lifetime changes.
Its own disconnect/reconnect and a higher client hello revision both retire
the prior lifetime and its held direct input. A duplicate identical hello
preserves the lifetime and sequence state. An older revision, changed client
ID or mode downgrade cannot replace the current handshake on that channel.

The client accepts input readiness only after sending its current hello and
receiving an acknowledgement for that client ID/revision. It ignores older
host generations and rejects inconsistent acknowledgements for one generation.
Duplicate acknowledgements do not reset its packet counter. The Mac can send
a newer acknowledgement after host-only recovery even if the phone never
observed a disconnect. A phone hello requires acknowledgement within ten
seconds in the current implementation; send failure or deadline expiry closes
the transport instead of retrying possibly accepted input.

A `display` sent with a scoped acknowledgement also includes that complete
`inputSession` acknowledgement beside its dimensions. The phone accepts those
dimensions only for its presented input session, arms a new decoder-frame probe
after the current hello acknowledgement, and clears screen/input readiness on
loss. Already-queued callbacks from retired probes cannot restore readiness.
A post-handshake decoder callback does not prove post-handshake host capture;
that media freshness boundary still needs native qualification. These display
requirements are part of the unreleased `inputSessions: 1` extension and require
the matching host and phone implementation. See the
[presentation recovery review](../docs/audits/2026-09-04-mac-computer-use/INPUT_PRESENTATION_RECOVERY_REVIEW.md).

### Capture-loss invalidation

A client that supports scoped capture-loss recovery adds `caps.inputInvalidation: 1`
to its `hello`, alongside `inputSession`. The host returns the selected
`caps.inputInvalidation` value in `hello_ack`; absent or zero means unsupported.
The mode is fixed for that control channel. Values must be integers 0 or 1;
booleans, strings, fractional values and unsupported versions are rejected.
Selecting 1 requires input-session metadata.

On a current ScreenCaptureKit stream-stop callback, the Mac synchronously
revokes the input session and releases its held input before deferred recovery
work. Capture availability is separate from ICE/channel state: neither a
connected callback nor a repeated hello can authorize input while capture is
unavailable. A supporting peer receives the exact revoked acknowledgement:

```json
{"t":"input_unavailable","s":43,"ts":1235,"inputSession":{"version":1,"clientID":"6F291DC4-5B15-4B1E-AC62-82AA2F46E313","revision":1,"hostID":"75AA76B8-BA2B-4C96-9FBD-927557D7A988","generation":1}}
```

The phone acts only when this scope equals its current acknowledgement. It
revokes input and screen readiness, retires old input/probe generations,
increments the client hello revision and sends a new hello. Duplicate or
superseded invalidations do not restart that handshake or clear newer readiness.
A delayed old acknowledgement cannot reopen the revoked revision. Malformed
recognized invalidations and unnegotiated current-scope invalidations terminate
the transport.

The Mac waits for complete output from the current running capture attempt,
then creates a fresh input generation and sends its acknowledgement and scoped
dimensions. Both event/ack arrival orders are supported; input stamped before
the outage remains rejected. Failure to send invalidation, hello or dimensions
revokes input and closes the peer. A client without this negotiated capability,
including an earlier input-session client, must reconnect after capture loss
once it has had authorized input. A new phone using an older host cannot infer
this protection from `inputSessions` alone.

The capture-only re-handshake timeout is 35 seconds: the shared 30-second host
recovery budget plus a five-second delivery allowance. Initial/transport hello
waits remain 10 seconds and ICE recovery retains its separate timeout; concurrent
outages may therefore end sooner. These are configured limits, not measured
network guarantees.

This source implementation handles reported stream stops. Silent video stalls
and blank/suspended output require further availability handling. Source output
and a later decoded-frame callback do not prove that current pixels reached the
phone's renderer. End-to-end media identity and native compatibility remain
unqualified; see the [capture/input review](../docs/audits/2026-09-04-mac-computer-use/CAPTURE_INPUT_INVALIDATION_REVIEW.md).

Each scoped input message carries a separate envelope, for example:

```json
{"t":"text","s":42,"ts":1234,"s2":"Exact text 😀","inputSession":{"hostID":"75AA76B8-BA2B-4C96-9FBD-927557D7A988","generation":1,"sequence":1}}
```

The input sequence is a positive UInt32, separate from the legacy `s` counter.
The host requires an exact current host ID/generation and a sequence greater
than the last admitted input sequence. Missing, malformed, duplicate and older
claims are dropped before the input-interruption callback or native dispatch.
The admitted packet retains a local session identity which is rechecked under
the posting lock, including between complete text graphemes. A buffered packet
from a retired host lifetime cannot acquire authority merely by arriving late.
These counters are bounded integers; booleans, strings, negative/fractional
values and overflow are invalid. Unknown extension versions do not silently
become legacy readiness.

Legacy clients may still use an initial ordinary v1 remote-control connection.
On an observed loss, the updated Mac terminates a legacy channel rather than
reusing it after recovery. An updated iOS client likewise closes after a loss
when paired with an older host that did not negotiate input sessions. A new
connection is required. Older hosts do not validate this extension; their
host-only outage behavior is not qualified by the updated Mac implementation.

This extension does not prove that an action reached its intended UI target,
expire delayed input on an otherwise continuously live channel, or qualify
native RTC callback order and the channel's reliable-ordered delivery. It also
does not scope the separate `bye` or video-quality messages. Physical input,
AI task controls, account handoff and result verification retain their own
contracts. The source changes and pending qualification are tracked in the
[wire-input session review](../docs/audits/2026-09-04-mac-computer-use/WIRE_INPUT_SESSION_REVIEW.md).

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
  "w": 2560, "h": 1440,                 // logical size of the captured display
  "scale": 2.0,                         // HiDPI backing scale
  "fullDisplaySurface": 1,              // optional: the full video surface represents this display
  "monitors": [
    { "id": 0, "w": 2560, "h": 1440, "x": 0, "y": 0, "primary": true }
  ],
  "active": 0 }
```

`w` and `h` are positive JSON integers representable as signed 32-bit values;
`scale` is a finite JSON number in `[1, 4]` (an omitted legacy scale defaults
to `1`). Strings, booleans, fractional dimensions and out-of-range numbers
are invalid geometry.

`fullDisplaySurface: 1` means the host captures the entire selected logical
display into the entire video surface, without letterboxing or a content
crop. The host validates native per-frame placement before forwarding video
or declaring capture available. The client aspect-fits the logical `w:h`
rectangle inside its viewport and fills that exact rectangle with the whole
decoded surface. Input uses the same rectangle. This restores the logical
aspect ratio after even codec sizing or drawable rounding; the client must
not introduce another aspect-fit based on encoded pixel dimensions inside
that rectangle. Absent metadata retains legacy presentation. A present
value other than numeric `1` is unsupported and closes the session.

This field belongs to the same input scope as its `display` message. It is
a placement contract, not proof of frame freshness, delivery or actual
renderer presentation. Older clients that ignore it retain their earlier
mapping behavior and require separate compatibility qualification.

### `pointer` (client → host)

Absolute position within the captured display's logical coordinate space,
plus button state. The top-left corner is `(0, 0)` and valid positions are
`0 <= x < w`, `0 <= y < h` from the scoped `display` message. The Mac host
maps these coordinates through the captured display's global origin before
posting input. The phone must not add an origin from another display or infer
one from the host's focused window. Coalesce at the sender — don't send more
than one per WebRTC frame.

The host binds this layout to its native capture attempt and local input
session. A detected display identity, bounds, mode or rotation change retires
the old input scope through the negotiated capture-loss invalidation path;
older clients reconnect. A new hello alone cannot remap an existing capture
descriptor. Actual encoded content padding, presentation evidence and native
multi-display behavior remain qualification requirements; this coordinate
contract does not establish that every rendered frame has that geometry.

```jsonc
{ "t": "pointer", "s": …, "ts": …,
  "x": 1230, "y": 456,
  "buttons": 0b001,    // bit 0 = left, 1 = right, 2 = middle
  "flags": 0 }         // reserved, must be 0 in v1
```

### `scroll` (client → host)

Wheel / trackpad scroll. Deltas are in host-logical pixels; positive `dy`
means "content moves up" (natural scrolling is handled by the host).
The `x` and `y` fields use the same captured-display coordinates as `pointer`.
The host maps the event location to global coordinates while preserving the
deltas; the Mac implementation sets that location on the scroll event.

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
