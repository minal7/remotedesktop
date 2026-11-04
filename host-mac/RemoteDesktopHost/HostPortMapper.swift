import Darwin
import dnssd
import Foundation
import OSLog

/// A mapping is kept alive by its token and must be cancelled with its peer.
protocol HostPortMappingToken: AnyObject {
    func cancel()
}

protocol HostPortMapping {
    func mapUDP(port: UInt16, lanAddress: String, completion: @escaping (HostPortMappingResult) -> Void) -> any HostPortMappingToken
}

enum HostPortMappingResult {
    case mapped(address: UInt32, port: UInt16) // address is in network byte order
    case doubleNAT
    case unavailable
}

struct SystemHostPortMapper: HostPortMapping {
    func mapUDP(port: UInt16, lanAddress: String, completion: @escaping (HostPortMappingResult) -> Void) -> any HostPortMappingToken {
        SystemPortMapping(port: port, lanAddress: lanAddress, completion: completion)
    }
}

/// All operations, including DNS-SD callbacks, run on the main queue.
private final class SystemPortMapping: HostPortMappingToken {
    private var ref: DNSServiceRef?
    private var completion: ((HostPortMappingResult) -> Void)?

    init(port: UInt16, lanAddress: String, completion: @escaping (HostPortMappingResult) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.completion = completion
        guard let interface = Self.interfaceIndex(for: lanAddress) else {
            DispatchQueue.main.async { [weak self] in self?.completion?(.unavailable) }
            return
        }
        let status = DNSServiceNATPortMappingCreate(&ref, 0, interface,
            DNSServiceProtocol(kDNSServiceProtocol_UDP), port.bigEndian, 0, 0,
            { _, _, _, error, address, _, _, externalPort, _, context in
                guard let context else { return }
                let mapping = Unmanaged<SystemPortMapping>.fromOpaque(context).takeUnretainedValue()
                if error == kDNSServiceErr_DoubleNAT {
                    mapping.completion?(.doubleNAT)
                } else if error != kDNSServiceErr_NoError || address == 0 || externalPort == 0 {
                    mapping.completion?(.unavailable)
                } else {
                    mapping.completion?(.mapped(address: address, port: UInt16(bigEndian: externalPort)))
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else {
            DispatchQueue.main.async { [weak self] in self?.completion?(.unavailable) }
            return
        }
        if DNSServiceSetDispatchQueue(ref, DispatchQueue.main) != kDNSServiceErr_NoError {
            DispatchQueue.main.async { [weak self] in self?.completion?(.unavailable) }
        }
    }

    private static func interfaceIndex(for address: String) -> UInt32? {
        var wanted = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &wanted) }) == 1 else { return nil }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let item = cursor {
            let entry = item.pointee
            if let addr = entry.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET {
                let ipv4 = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                if ipv4.s_addr == wanted.s_addr { return if_nametoindex(entry.ifa_name) }
            }
            cursor = entry.ifa_next
        }
        return nil
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        completion = nil
        if let ref { DNSServiceRefDeallocate(ref); self.ref = nil }
    }

    deinit { if let ref { DNSServiceRefDeallocate(ref) } }
}

struct HostMappingCandidate {
    let foundation: String
    let lanAddress: String
    let mappedPriority: UInt32
    let internalPort: UInt16
    let mid: String?
    let lineIndex: Int32

    init?(sdp: String, mid: String?, lineIndex: Int32) {
        let fields = sdp.split(separator: " ").map(String.init)
        guard fields.count >= 8, fields[0].hasPrefix("candidate:"),
              fields[1] == "1", fields[2].lowercased() == "udp",
              fields[6] == "typ", fields[7] == "host",
              let priority = UInt32(fields[3]),
              let port = UInt16(fields[5]), port != 0,
              Self.isLAN(fields[4]) else { return nil }
        foundation = String(fields[0].dropFirst("candidate:".count))
        lanAddress = fields[4]
        mappedPriority = (100 << 24) + (priority & 0x00ff_ffff) - 1
        internalPort = port
        self.mid = mid
        self.lineIndex = lineIndex
    }

    private static func octets(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { UInt8($0) }
        return values.count == 4 ? values : nil
    }

    static func isLAN(_ address: String) -> Bool {
        guard let a = octets(address) else { return false }
        return a[0] == 10 || (a[0] == 172 && (16...31).contains(a[1])) ||
            (a[0] == 192 && a[1] == 168) || (a[0] == 100 && (64...127).contains(a[1]))
    }

    func mappedSDP(address: String, port: UInt16) -> String {
        // Preserve the host candidate's local preference and component while
        // placing the mapped candidate just below the corresponding srflx.
        "candidate:\(foundation) 1 udp \(mappedPriority) \(address) \(port) typ srflx raddr \(lanAddress) rport \(internalPort)"
    }
}

/// Own one instance per accepted ordinary peer. Methods may be called from any queue.
final class HostPortMappingSession {
    private let mapper: any HostPortMapping
    private let enabled: () -> Bool
    private let acceptedOrdinaryPeer: Bool
    private let send: (HostMappingCandidate, String) -> Void
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "port-mapping")
    private var tokens: [UUID: any HostPortMappingToken] = [:] // main queue
    private var pending: Set<UUID> = []
    private var closed = false
    private var requestedCandidates: Set<String> = []
    private let started = DispatchTime.now()
    private var settingsObserver: NSObjectProtocol?

    init(mapper: any HostPortMapping = SystemHostPortMapper(), acceptedOrdinaryPeer: Bool = false, enabled: @escaping () -> Bool,
         send: @escaping (HostMappingCandidate, String) -> Void) {
        self.mapper = mapper
        self.acceptedOrdinaryPeer = acceptedOrdinaryPeer
        self.enabled = enabled
        self.send = send
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.enabled() else { return }
                self.close()
            }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func gather(sdp: String, mid: String?, lineIndex: Int32) {
        guard let candidate = HostMappingCandidate(sdp: sdp, mid: mid, lineIndex: lineIndex) else { return }
        DispatchQueue.main.async { [self] in
            guard !closed, acceptedOrdinaryPeer, enabled(), requestedCandidates.count < 2,
                  requestedCandidates.insert("\(candidate.lanAddress):\(candidate.internalPort)").inserted else { return }
            let id = UUID()
            pending.insert(id)
            event("requested")
            tokens[id] = mapper.mapUDP(port: candidate.internalPort, lanAddress: candidate.lanAddress) { [weak self] result in
                // Mocks may call synchronously or on another queue.
                DispatchQueue.main.async { self?.completed(id, candidate: candidate, result: result) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.pending.remove(id) != nil else { return }
                self.event("unavailable")
                if let token = self.tokens.removeValue(forKey: id) { token.cancel(); self.event("released") }
            }
        }
    }

    func closeAsync() { DispatchQueue.main.async { [self] in close() } }

    func close() {
        let release = { [self] in
            guard !closed else { return }
            closed = true
            pending.removeAll()
            for token in tokens.values { token.cancel(); event("released") }
            tokens.removeAll()
        }
        if Thread.isMainThread { release() } else { DispatchQueue.main.sync(execute: release) }
    }

    private func completed(_ id: UUID, candidate: HostMappingCandidate, result: HostPortMappingResult) {
        guard !closed, pending.remove(id) != nil else { return }
        guard enabled() else { tokens.removeValue(forKey: id)?.cancel(); event("released"); return }
        switch result {
        case .doubleNAT:
            event("double_nat")
            if let token = tokens.removeValue(forKey: id) { token.cancel(); event("released") }
        case .unavailable:
            event("unavailable")
            if let token = tokens.removeValue(forKey: id) { token.cancel(); event("released") }
        case let .mapped(address, port):
            var raw = in_addr(s_addr: address)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard port != 0, inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else {
                event("unavailable"); if let token = tokens.removeValue(forKey: id) { token.cancel(); event("released") }; return
            }
            let ip = String(cString: buffer)
            guard !HostMappingCandidate.isLAN(ip) else {
                event("double_nat"); if let token = tokens.removeValue(forKey: id) { token.cancel(); event("released") }; return
            }
            event("mapped")
            send(candidate, candidate.mappedSDP(address: ip, port: port))
        }
    }

    private func event(_ name: String) {
        let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        log.notice("port_mapping=\(name, privacy: .public) ms=\(ms, privacy: .public)")
    }
}
