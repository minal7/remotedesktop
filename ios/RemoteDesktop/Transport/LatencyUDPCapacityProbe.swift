#if DEBUG
import CryptoKit
import Foundation

/// Private, bounded binary datagrams for the opt-in lab capacity experiment.
/// The key is generated per session and exchanged only on the authenticated
/// control channel. This codec never formats endpoint or secret material.
enum LatencyUDPCapacityWire {
    static let maximumDatagramBytes = 1_200
    static let maximumPackets = 100_000
    static let maximumPayloadBytes = 90_000_000
    static let ratesMbps = [2, 5, 8, 10, 12, 16]
    static let stepSeconds: Double = 4
    static let cooldownSeconds: Double = 1
    static let maximumSessionSeconds: Double = 60
    private static let magic: [UInt8] = [0x55, 0x43, 0x50, 0x31]
    private static let headerBytes = 14
    private static let tagBytes = 32

    enum Kind: UInt8 {
        case hello = 1, challenge = 2, confirm = 3, confirmed = 4
        case data = 5, echo = 6, echoReply = 7
    }
    struct Packet: Equatable {
        let kind: Kind
        let step: UInt8
        let sequence: UInt64
        let body: Data
    }

    static func encode(_ packet: Packet, key: SymmetricKey) -> Data? {
        guard packet.step < UInt8(ratesMbps.count),
              packet.body.count <= maximumDatagramBytes - headerBytes - tagBytes else { return nil }
        var data = Data(magic)
        data.append(packet.kind.rawValue)
        data.append(packet.step)
        var sequence = packet.sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        data.append(packet.body)
        data.append(contentsOf: HMAC<SHA256>.authenticationCode(for: data, using: key))
        return data
    }

    static func decode(_ data: Data, key: SymmetricKey) -> Packet? {
        guard data.count >= headerBytes + tagBytes, data.count <= maximumDatagramBytes else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes.prefix(4)) == magic, let kind = Kind(rawValue: bytes[4]),
              bytes[5] < UInt8(ratesMbps.count) else { return nil }
        let signed = Data(bytes.dropLast(tagBytes))
        let tag = Data(bytes.suffix(tagBytes))
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: signed, using: key) else { return nil }
        let sequence = bytes[6..<headerBytes].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Packet(kind: kind, step: bytes[5], sequence: sequence,
                      body: Data(bytes[headerBytes..<(bytes.count - tagBytes)]))
    }
}

/// The receiver uses bounded unique sequence storage. Counters describe what
/// the receiver observed; actual send counts must come from the sender.
struct LatencyUDPCapacityReceiveCounters {
    struct Step: Equatable, Sendable {
        var unique = 0
        var duplicate = 0
        var reordered = 0
        var late = 0
        var bytes = 0
    }
    private(set) var steps = Array(repeating: Step(), count: LatencyUDPCapacityWire.ratesMbps.count)
    private var seen = Set<UInt64>()
    private var greatest: UInt64?
    private(set) var overflowed = false

    mutating func record(step: UInt8, sequence: UInt64, byteCount: Int, activeStep: UInt8?) {
        guard Int(step) < steps.count, byteCount >= 0, byteCount <= LatencyUDPCapacityWire.maximumDatagramBytes else { return }
        if seen.contains(sequence) { steps[Int(step)].duplicate += 1; return }
        guard seen.count < LatencyUDPCapacityWire.maximumPackets else { overflowed = true; return }
        seen.insert(sequence)
        if let greatest, sequence < greatest { steps[Int(step)].reordered += 1 }
        greatest = max(greatest ?? sequence, sequence)
        if let activeStep, step < activeStep { steps[Int(step)].late += 1 }
        steps[Int(step)].unique += 1
        steps[Int(step)].bytes += byteCount
    }
}

import Network
import Security

enum LatencyUDPCapacityForegroundPolicy {
    static func permitsStart(isActive: Bool) -> Bool { isActive }
}

/// A single connected UDP receiver; callers admit it only after the existing
/// authenticated ordinary control session accepts the lab-only rendezvous.
final class LatencyUDPCapacityReceiver: @unchecked Sendable {
    typealias Progress = @Sendable ([LatencyUDPCapacityReceiveCounters.Step], Bool, Bool) -> Void
    private let queue = DispatchQueue(label: "latency.capacity.receiver")
    private let connection: NWConnection
    private let key: SymmetricKey
    private let progress: Progress
    private var clientChallenge = Data(count: 16)
    private var challengePair: Data?
    private var authenticatedAt: TimeInterval?
    private var highestStep: UInt8?
    private var counters = LatencyUDPCapacityReceiveCounters()
    private var bytes = 0
    private var stopped = false
    private var timer: DispatchSourceTimer?

    init?(host: String, port: UInt16, keyData: Data, progress: @escaping Progress) {
        guard !host.isEmpty, host.utf8.count <= 255, port > 0, keyData.count == 32,
              let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        self.key = SymmetricKey(data: keyData)
        self.progress = progress
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        let random = clientChallenge.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard random == errSecSuccess else { return nil }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.timer == nil else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let authenticatedAt = self.authenticatedAt {
                    self.progress(self.counters.steps, self.counters.overflowed, false)
                    if now - authenticatedAt >= LatencyUDPCapacityWire.maximumSessionSeconds { self.closeOnQueue() }
                } else if now - started >= 10 { self.closeOnQueue() }
            }
            self.timer = timer
            timer.resume()
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(kind: .hello, step: 0, sequence: 0, body: self.clientChallenge)
                    self.receive()
                case .failed, .cancelled: self.closeOnQueue()
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    func stop() { queue.async { [self] in closeOnQueue() } }

    func requestFinalSnapshot() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.authenticatedAt != nil else { return }
            self.progress(self.counters.steps, self.counters.overflowed, true)
        }
    }

    private func receive() {
        guard !stopped else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.closeOnQueue(); return }
            if let data, let packet = LatencyUDPCapacityWire.decode(data, key: self.key) {
                self.accept(packet, datagramBytes: data.count)
            }
            self.receive()
        }
    }

    private func accept(_ packet: LatencyUDPCapacityWire.Packet, datagramBytes: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if let authenticatedAt, now - authenticatedAt >= LatencyUDPCapacityWire.maximumSessionSeconds {
            closeOnQueue(); return
        }
        switch packet.kind {
        case .challenge:
            guard authenticatedAt == nil, challengePair == nil, packet.sequence == 0,
                  packet.body.count == 32, packet.body.prefix(16) == clientChallenge else { return }
            challengePair = packet.body
            send(kind: .confirm, step: 0, sequence: 0, body: packet.body)
        case .confirmed:
            guard authenticatedAt == nil, packet.sequence == 0,
                  let challengePair, packet.body == challengePair else { return }
            authenticatedAt = now
        case .data:
            guard authenticatedAt != nil, packet.sequence < UInt64(LatencyUDPCapacityWire.maximumPackets),
                  bytes + datagramBytes <= LatencyUDPCapacityWire.maximumPayloadBytes else { closeOnQueue(); return }
            highestStep = max(highestStep ?? packet.step, packet.step)
            counters.record(step: packet.step, sequence: packet.sequence,
                            byteCount: datagramBytes, activeStep: highestStep)
            bytes += datagramBytes
        case .echo:
            guard authenticatedAt != nil, packet.body.count <= 32 else { return }
            send(kind: .echoReply, step: packet.step, sequence: packet.sequence, body: packet.body)
        default: break
        }
    }

    private func send(kind: LatencyUDPCapacityWire.Kind, step: UInt8, sequence: UInt64, body: Data) {
        guard !stopped, let data = LatencyUDPCapacityWire.encode(.init(kind: kind, step: step, sequence: sequence, body: body), key: key) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func closeOnQueue() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        progress(counters.steps, counters.overflowed, false)
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
#endif
