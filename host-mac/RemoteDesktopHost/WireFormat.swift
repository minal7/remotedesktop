import Foundation

/// Wire protocol shared between the iOS client and the Mac host,
/// as specified in `protocol/PROTOCOL.md` (v1 plus negotiated capabilities).
///
/// Semantic messages are separate from the negotiated input-session envelope.

struct ControlPacket {
    let message: ControlMessage
    let inputHello: DirectInputHello?
    let inputStamp: DirectInputStamp?

    static func decode(_ data: Data) -> ControlPacket? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = ControlMessage.decode(object) else { return nil }
        var hello: DirectInputHello?, stamp: DirectInputStamp?
        if let metadata = object["inputSession"] {
            switch message {
            case .hello:
                guard let value = DirectInputWire.decode(metadata, as: DirectInputHello.self), value.isValid else { return nil }
                hello = value
            case .pointer, .scroll, .key, .text:
                guard let value = DirectInputWire.decode(metadata, as: DirectInputStamp.self), value.isValid else { return nil }
                stamp = value
            case .qos, .bye: break
            }
        }
        return .init(message: message, inputHello: hello, inputStamp: stamp)
    }
}

enum InputScrollPhase: String, Codable {
    case begin, changed, end, momentum
}

enum ControlMessage: Equatable {
    case hello(proto: Int, orderedComputerUseControls: Int)
    case pointer(x: Int, y: Int, buttons: UInt8)
    case scroll(x: Int, y: Int, dx: Int, dy: Int, phase: InputScrollPhase)
    case key(usage: Int, down: Bool, modifiers: UInt16)
    case text(String)
    case qos(targetFps: Int, maxBitrateKbps: Int, prefer: String)
    case bye(reason: String)

    static func decode(_ data: Data) -> ControlMessage? {
        ControlPacket.decode(data)?.message
    }

    fileprivate static func decode(_ obj: [String: Any]) -> ControlMessage? {
        guard let t = obj["t"] as? String else { return nil }
        switch t {
        case "hello":
            let client = obj["client"] as? [String: Any]
            let caps = obj["caps"] as? [String: Any]
            return .hello(
                proto: int(obj["proto"], default: 1),
                orderedComputerUseControls: max(
                    0,
                    int(
                        client?["orderedComputerUseControls"]
                            ?? caps?["orderedComputerUseControls"],
                        default: 0)))
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
        if let b = v as? Bool { return b ? 1 : 0 }
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
        ts: UInt64,
        inputSession: DirectInputAcknowledgement? = nil
    ) -> Data {
        var obj: [String: Any] = [
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
                "maxFps": DesktopVideoQuality.targetFramesPerSecond,
                "orderedComputerUseControls":
                    HostConfig.orderedComputerUseControlsVersion,
                "inputSessions": DirectInputWire.version,
            ],
        ]
        if let inputSession { obj["inputSession"] = DirectInputWire.object(inputSession) }
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
