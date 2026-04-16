import Foundation

/// Wire protocol shared between the iOS client and the Mac host,
/// as specified in `protocol/PROTOCOL.md` (v1).
///
/// The host primarily *decodes* client → host messages; encoding of
/// host → client messages (`hello_ack`, `display`) is a Phase 3 task
/// once the WebRTC data channel is wired up.

enum InputScrollPhase: String, Codable {
    case begin, changed, end, momentum
}

enum ControlMessage: Equatable {
    case hello(proto: Int)
    case pointer(x: Int, y: Int, buttons: UInt8)
    case scroll(x: Int, y: Int, dx: Int, dy: Int, phase: InputScrollPhase)
    case key(usage: Int, down: Bool, modifiers: UInt16)
    case text(String)
    case qos(targetFps: Int, maxBitrateKbps: Int, prefer: String)
    case bye(reason: String)

    static func decode(_ data: Data) -> ControlMessage? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any],
              let t = obj["t"] as? String else {
            return nil
        }
        switch t {
        case "hello":
            return .hello(proto: obj["proto"] as? Int ?? 1)
        case "pointer":
            return .pointer(
                x: int(obj["x"]), y: int(obj["y"]),
                buttons: UInt8(int(obj["buttons"]) & 0xFF))
        case "scroll":
            let phase = InputScrollPhase(rawValue: obj["phase"] as? String ?? "changed") ?? .changed
            return .scroll(
                x: int(obj["x"]), y: int(obj["y"]),
                dx: int(obj["dx"]), dy: int(obj["dy"]),
                phase: phase)
        case "key":
            return .key(
                usage: int(obj["usage"]),
                down: obj["down"] as? Bool ?? false,
                modifiers: UInt16(int(obj["modifiers"]) & 0xFFFF))
        case "text":
            return .text(obj["s2"] as? String ?? "")
        case "qos":
            return .qos(
                targetFps: int(obj["targetFps"], default: 60),
                maxBitrateKbps: int(obj["maxBitrateKbps"]),
                prefer: obj["prefer"] as? String ?? "auto")
        case "bye":
            return .bye(reason: obj["reason"] as? String ?? "user")
        default:
            return nil
        }
    }

    private static func int(_ v: Any?, default d: Int = 0) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return d
    }
}

enum HostMessageEncoder {
    static func helloAck(
        proto: Int,
        hostname: String,
        os: String,
        audio: Bool,
        monitors: Int,
        seq: UInt32,
        ts: UInt64
    ) -> Data {
        let obj: [String: Any] = [
            "t": "hello_ack",
            "s": seq,
            "ts": ts,
            "proto": proto,
            "host": [
                "app": "RemoteDesktop-Mac",
                "version": HostConfig.appVersion,
                "os": os,
                "hostname": hostname,
            ],
            "caps": [
                "audio": audio,
                "clipboard": false,
                "fileTransfer": false,
                "monitors": monitors,
                "maxFps": 60,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    static func display(
        width: Int,
        height: Int,
        scale: Double,
        seq: UInt32,
        ts: UInt64
    ) -> Data {
        let obj: [String: Any] = [
            "t": "display",
            "s": seq,
            "ts": ts,
            "w": width,
            "h": height,
            "scale": scale,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
