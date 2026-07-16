//! Wire protocol shared with the iOS client, as specified in
//! `protocol/PROTOCOL.md` (v1). One JSON object per data-channel
//! message. The host decodes client → host messages and encodes the
//! `hello_ack` / `display` / `bye` it sends back.
//!
//! Unknown `t` values decode to `None` and the caller ignores them —
//! that's the spec's forward-compatibility rule, not an error.

use serde_json::{json, Value};

pub const PROTOCOL_VERSION: i64 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScrollPhase {
    Begin,
    Changed,
    End,
    Momentum,
}

impl ScrollPhase {
    fn from_str(value: &str) -> Self {
        match value {
            "begin" => Self::Begin,
            "end" => Self::End,
            "momentum" => Self::Momentum,
            _ => Self::Changed,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ClientMessage {
    Hello {
        proto: i64,
    },
    Pointer {
        x: i32,
        y: i32,
        buttons: u8,
    },
    Scroll {
        dx: i32,
        dy: i32,
        phase: ScrollPhase,
    },
    Key {
        usage: u32,
        down: bool,
        modifiers: u16,
    },
    Text(String),
    Qos {
        target_fps: i64,
        max_bitrate_kbps: i64,
        prefer: String,
    },
    Bye {
        reason: String,
    },
}

impl ClientMessage {
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(bytes).ok()?;
        let obj = value.as_object()?;
        match obj.get("t")?.as_str()? {
            "hello" => Some(Self::Hello {
                proto: int(obj.get("proto")).unwrap_or(1),
            }),
            "pointer" => Some(Self::Pointer {
                x: int(obj.get("x")).unwrap_or(0) as i32,
                y: int(obj.get("y")).unwrap_or(0) as i32,
                buttons: (int(obj.get("buttons")).unwrap_or(0) & 0xFF) as u8,
            }),
            "scroll" => Some(Self::Scroll {
                dx: int(obj.get("dx")).unwrap_or(0) as i32,
                dy: int(obj.get("dy")).unwrap_or(0) as i32,
                phase: ScrollPhase::from_str(
                    obj.get("phase")
                        .and_then(Value::as_str)
                        .unwrap_or("changed"),
                ),
            }),
            "key" => Some(Self::Key {
                usage: int(obj.get("usage")).unwrap_or(0) as u32,
                down: obj.get("down").and_then(Value::as_bool).unwrap_or(false),
                modifiers: (int(obj.get("modifiers")).unwrap_or(0) & 0xFFFF) as u16,
            }),
            "text" => Some(Self::Text(
                obj.get("s2")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
            )),
            "qos" => Some(Self::Qos {
                target_fps: int(obj.get("targetFps")).unwrap_or(60),
                max_bitrate_kbps: int(obj.get("maxBitrateKbps")).unwrap_or(0),
                prefer: obj
                    .get("prefer")
                    .and_then(Value::as_str)
                    .unwrap_or("auto")
                    .to_string(),
            }),
            "bye" => Some(Self::Bye {
                reason: obj
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("user")
                    .to_string(),
            }),
            _ => None,
        }
    }
}

/// Host metadata advertised in `hello_ack.host` and the preflight answer.
#[derive(Clone, Debug)]
pub struct HostInfo {
    pub app: String,
    pub version: String,
    pub os: String,
    pub hostname: String,
}

#[derive(Clone, Copy, Debug)]
pub struct DisplayInfo {
    pub width: i32,
    pub height: i32,
    pub scale: f64,
}

pub fn encode_hello_ack(
    seq: u32,
    ts: u64,
    host: &HostInfo,
    audio: bool,
    monitors: i64,
    max_fps: i64,
) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "t": "hello_ack",
        "s": seq,
        "ts": ts,
        "proto": PROTOCOL_VERSION,
        "host": {
            "app": host.app,
            "version": host.version,
            "os": host.os,
            "hostname": host.hostname,
        },
        "caps": {
            "audio": audio,
            "clipboard": false,
            "fileTransfer": false,
            "monitors": monitors,
            "maxFps": max_fps,
        },
    }))
    .unwrap_or_default()
}

pub fn encode_display(seq: u32, ts: u64, display: DisplayInfo) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "t": "display",
        "s": seq,
        "ts": ts,
        "w": display.width,
        "h": display.height,
        "scale": display.scale,
    }))
    .unwrap_or_default()
}

pub fn encode_bye(seq: u32, ts: u64, reason: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "t": "bye",
        "s": seq,
        "ts": ts,
        "reason": reason,
    }))
    .unwrap_or_default()
}

/// Mirrors the Swift `int()` helper: tolerate JSON number or string.
fn int(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|f| f as i64))
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_hello_with_proto() {
        let msg = ClientMessage::decode(br#"{"t":"hello","s":0,"ts":1,"proto":1}"#).unwrap();
        assert_eq!(msg, ClientMessage::Hello { proto: 1 });
    }

    #[test]
    fn decodes_pointer_and_masks_buttons() {
        let msg = ClientMessage::decode(br#"{"t":"pointer","x":10,"y":20,"buttons":511}"#).unwrap();
        assert_eq!(
            msg,
            ClientMessage::Pointer {
                x: 10,
                y: 20,
                buttons: 0xFF
            }
        );
    }

    #[test]
    fn decodes_numeric_strings_like_swift_client() {
        let msg = ClientMessage::decode(br#"{"t":"key","usage":"4","down":true}"#).unwrap();
        assert_eq!(
            msg,
            ClientMessage::Key {
                usage: 4,
                down: true,
                modifiers: 0
            }
        );
    }

    #[test]
    fn unknown_type_is_ignored() {
        assert_eq!(ClientMessage::decode(br#"{"t":"future","s":1}"#), None);
    }

    #[test]
    fn scroll_phase_defaults_to_changed() {
        let msg = ClientMessage::decode(br#"{"t":"scroll","dx":1,"dy":-2}"#).unwrap();
        assert_eq!(
            msg,
            ClientMessage::Scroll {
                dx: 1,
                dy: -2,
                phase: ScrollPhase::Changed
            }
        );
    }

    #[test]
    fn hello_ack_round_trips() {
        let bytes = encode_hello_ack(
            1,
            2,
            &HostInfo {
                app: "RemoteDesktop-Windows".into(),
                version: "0.1.0".into(),
                os: "Windows".into(),
                hostname: "PC".into(),
            },
            true,
            1,
            60,
        );
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["t"], "hello_ack");
        assert_eq!(value["proto"], PROTOCOL_VERSION);
        assert_eq!(value["caps"]["audio"], true);
        assert_eq!(value["host"]["app"], "RemoteDesktop-Windows");
    }
}
