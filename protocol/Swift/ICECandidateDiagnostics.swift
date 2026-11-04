import Foundation
import Darwin

/// Reduces ICE data to an allowlisted set of labels; never returns candidate text.
struct ICECandidateDiagnostics {
    private var counts: [String: Int] = [:]
    private(set) var globalIPv6Host = false

    static func family(_ address: String) -> String {
        var v4 = in_addr()
        var v6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return "v4" }
        if address.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return "v6" }
        return "unknown"
    }

    static func kind(_ value: String?) -> String {
        switch value?.lowercased() {
        case "host": return "host"
        case "srflx": return "srflx"
        case "prflx": return "prflx"
        default: return "unknown"
        }
    }

    static func transport(_ value: String?) -> String {
        switch value?.lowercased() {
        case "udp": return "udp"
        case "tcp": return "tcp"
        default: return "unknown"
        }
    }

    mutating func record(_ candidate: String) {
        let fields = candidate.prefix(2048).split(whereSeparator: \.isWhitespace)
        guard fields.count > 7, let typeIndex = fields.firstIndex(of: "typ"), typeIndex + 1 < fields.count else { return }
        let type = Self.kind(String(fields[typeIndex + 1]))
        let address = String(fields[4])
        let family = Self.family(address)
        let key = "\(type)_\(family)"
        counts[key] = min((counts[key] ?? 0) + 1, 10_000)
        if type == "host", family == "v6" {
            var address6 = in6_addr()
            if address.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1 {
                let bytes = withUnsafeBytes(of: address6) { Array($0) }
                // Exclude documentation space from the global-unicast range.
                let documentation = bytes.prefix(4).elementsEqual([0x20, 0x01, 0x0d, 0xb8])
                globalIPv6Host = globalIPv6Host || (bytes[0] & 0xe0 == 0x20 && !documentation)
            }
        }
    }

    var summary: String {
        ["host", "srflx", "prflx", "unknown"].flatMap { type in
            ["v4", "v6", "unknown"].map { family in
                let key = "\(type)_\(family)"
                return "\(key)=\(counts[key] ?? 0)"
            }
        }.joined(separator: " ")
    }
}
