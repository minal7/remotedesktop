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

A pairing code is 6 digits, uniform random (collisions handled by the
signaling worker — it refuses to allocate an in-use code). The code is
*also* the room ID on the signaling worker: `POST /rooms/{code}/offer`.

Codes are display-only on the host; they never leave the host except as
part of the signaling-room URL path. They expire after 5 minutes of
inactivity or on session teardown, whichever comes first.

## Security

- SDP is the only data that flows through signaling; no user content.
- The pairing code is entropy for the initial handshake only. Once a
  peer connection exists, the DTLS fingerprint in the SDP authenticates
  all subsequent traffic — WebRTC's standard E2E encryption.
- Hosts SHOULD show a "session active" indicator for the duration of the
  connection. Mac: menu-bar icon turns red. Windows: system-tray icon
  turns red.
