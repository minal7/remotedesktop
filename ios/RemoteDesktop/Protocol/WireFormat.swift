import Foundation
import UIKit

/// Scroll phase as carried on the wire. Named `InputScrollPhase` to
/// avoid collision with SwiftUI's `ScrollPhase` (iOS 18+).
enum InputScrollPhase: String, Codable {
    case begin, changed, end, momentum
}

/// Messages sent from the client to the host, per `protocol/PROTOCOL.md`.
enum ControlMessage {
    case hello(proto: Int)
    case pointer(x: Int, y: Int, buttons: UInt8)
    case scroll(x: Int, y: Int, dx: Int, dy: Int, phase: InputScrollPhase)
    case key(usage: Int, down: Bool, modifiers: UInt16)
    case text(String)
    case qos(targetFps: Int, maxBitrateKbps: Int, prefer: String)
    case bye(reason: String)

    func encoded(seq: UInt32, ts: UInt64) -> Data {
        var obj: [String: Any] = ["s": seq, "ts": ts]
        switch self {
        case .hello(let p):
            obj["t"] = "hello"
            obj["proto"] = p
            obj["client"] = [
                "app": "RemoteDesktop-iOS",
                "version": Config.appVersion,
                "device": UIDevice.current.model,
                "osVersion": UIDevice.current.systemVersion,
                "orderedComputerUseControls": Config.orderedComputerUseControlsVersion,
            ]
        case let .pointer(x, y, b):
            obj["t"] = "pointer"
            obj["x"] = x; obj["y"] = y; obj["buttons"] = b
        case let .scroll(x, y, dx, dy, phase):
            obj["t"] = "scroll"
            obj["x"] = x; obj["y"] = y
            obj["dx"] = dx; obj["dy"] = dy
            obj["phase"] = phase.rawValue
        case let .key(usage, down, mods):
            obj["t"] = "key"
            obj["usage"] = usage; obj["down"] = down; obj["modifiers"] = mods
        case .text(let s):
            obj["t"] = "text"; obj["s2"] = s
        case let .qos(fps, kbps, pref):
            obj["t"] = "qos"
            obj["targetFps"] = fps; obj["maxBitrateKbps"] = kbps; obj["prefer"] = pref
        case .bye(let r):
            obj["t"] = "bye"; obj["reason"] = r
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}

/// Decoded subset of the host → client messages the client cares about.
/// The full envelope is parsed by the transport; the model layer only
/// sees these semantic events.
struct HostHello: Equatable {
    let app: String
    let version: String
    let hostname: String
    let os: String
    let audio: Bool
    let monitors: Int
    let orderedComputerUseControls: Int

    init(
        app: String,
        version: String,
        hostname: String,
        os: String,
        audio: Bool,
        monitors: Int,
        orderedComputerUseControls: Int = 0
    ) {
        self.app = app
        self.version = version
        self.hostname = hostname
        self.os = os
        self.audio = audio
        self.monitors = monitors
        self.orderedComputerUseControls = orderedComputerUseControls
    }
}

struct DisplayInfo: Equatable {
    let w: Int
    let h: Int
    let scale: Double
}

enum HostMessage: Equatable {
    case helloAck(HostHello)
    case display(DisplayInfo)
    case bye(String)

    static func decode(_ data: Data) -> HostMessage? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any],
              let t = obj["t"] as? String else {
            return nil
        }

        switch t {
        case "hello_ack":
            guard int(obj["proto"], default: 1) == Config.protocolVersion else {
                return .bye("protocol")
            }
            let host = obj["host"] as? [String: Any]
            let caps = obj["caps"] as? [String: Any]
            return .helloAck(HostHello(
                app: host?["app"] as? String ?? "RemoteDesktop-Host",
                version: host?["version"] as? String ?? "0.1.0",
                hostname: host?["hostname"] as? String ?? "Mac",
                os: host?["os"] as? String ?? "macOS",
                audio: caps?["audio"] as? Bool ?? false,
                monitors: int(caps?["monitors"]),
                orderedComputerUseControls: int(
                    caps?["orderedComputerUseControls"])))
        case "display":
            return .display(DisplayInfo(
                w: int(obj["w"]),
                h: int(obj["h"]),
                scale: double(obj["scale"], default: 1.0)))
        case "bye":
            return .bye(obj["reason"] as? String ?? "user")
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

    private static func double(_ v: Any?, default d: Double = 0) -> Double {
        if let v = v as? Double { return v }
        if let v = v as? Int { return Double(v) }
        if let s = v as? String, let v = Double(s) { return v }
        return d
    }
}
