import Darwin
import Foundation

/// Produces an additional ICE candidate only when the current path is IPv6-only.
struct NAT64CandidateSynthesizer {
    typealias Resolver = (String) -> String?
    var resolve: Resolver = Self.resolveIPv6

    func candidate(from sdp: String, hasIPv4: Bool, hasIPv6: Bool) -> String? {
        guard !hasIPv4, hasIPv6 else { return nil }
        var fields = sdp.split(separator: " ").map(String.init)
        guard fields.count >= 8, fields[0].hasPrefix("candidate:"),
              fields[6].lowercased() == "typ",
              ["host", "srflx"].contains(fields[7].lowercased()),
              let priority = UInt32(fields[3]), priority > 0 else { return nil }
        var ipv4 = in_addr()
        guard fields[4].withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1,
              let ipv6 = resolve(fields[4]) else { return nil }
        var address = in6_addr()
        guard ipv6.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        fields[3] = String(priority - 1)
        fields[4] = ipv6
        return fields.joined(separator: " ")
    }

    private static func resolveIPv6(_ literal: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_DEFAULT
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(literal, nil, &hints, &result) == 0 else { return nil }
        defer { if let result { freeaddrinfo(result) } }
        var current = result
        while let entry = current {
            if entry.pointee.ai_family == AF_INET6, let address = entry.pointee.ai_addr {
                let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                var copy = ipv6
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &copy, &buffer, socklen_t(buffer.count)) != nil {
                    return String(cString: buffer)
                }
            }
            current = entry.pointee.ai_next
        }
        return nil
    }
}
