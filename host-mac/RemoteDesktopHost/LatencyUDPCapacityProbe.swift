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

/// The caller feeds only packets that passed the session HMAC check.
struct LatencyUDPCapacityHandshake {
    private let startedAt: Double
    private(set) var authenticatedAt: Double?
    private var challengePair: Data?
    init(startedAt: Double) { self.startedAt = startedAt }

    mutating func challenge(client: Data, server: Data, now: Double) -> Data? {
        guard now.isFinite, now >= startedAt, now - startedAt < 10,
              authenticatedAt == nil, challengePair == nil,
              client.count == 16, server.count == 16 else { return nil }
        var pair = client; pair.append(server); challengePair = pair; return pair
    }
    mutating func confirm(_ pair: Data, now: Double) -> Bool {
        guard now.isFinite, now >= startedAt, now - startedAt < 10,
              authenticatedAt == nil, let challengePair, pair == challengePair else { return false }
        authenticatedAt = now
        return true
    }
    func permitsLoad(now: Double) -> Bool {
        guard let authenticatedAt, now.isFinite, now >= authenticatedAt else { return false }
        return now - authenticatedAt < LatencyUDPCapacityWire.maximumSessionSeconds
    }
}

/// Owns a single mapping token, including the race between close and adoption.
final class LatencyUDPCapacityMappingLease: @unchecked Sendable {
    private let lock = NSLock()
    private var token: (any HostPortMappingToken)?
    private var closed = false
    func adopt(_ token: any HostPortMappingToken) {
        lock.lock(); let reject = closed || self.token != nil
        if !reject { self.token = token }; lock.unlock()
        if reject { DispatchQueue.main.async { token.cancel() } }
    }
    func close() {
        lock.lock(); let token = self.token; self.token = nil; closed = true; lock.unlock()
        if let token { DispatchQueue.main.async { token.cancel() } }
    }
}

/// One diagnostic session. All endpoint and key material stays in memory and
/// is handed only to the already-authenticated control channel.
final class LatencyUDPCapacitySender: @unchecked Sendable {
    struct Offer {
        let host: String
        let port: UInt16
        let key: Data
    }
    struct ReceiverStep {
        let unique: Int
        let duplicate: Int
        let reordered: Int
        let late: Int
        let bytes: Int
    }
    private struct Step {
        var attempted = 0
        var sent = 0
        var sentBytes = 0
        var sendErrors = 0
        var activeSeconds: Double = 0
        var rttMs: [Double] = []
        var receiver: ReceiverStep?
    }
    typealias OfferHandler = @Sendable (Offer?) -> Void
    typealias Completion = @Sendable ([String: Any]) -> Void
    typealias SnapshotRequest = @Sendable () -> Void
    private let queue = DispatchQueue(label: "latency.capacity.sender")
    private let lanAddress: String
    private let mapper: any HostPortMapping
    private let offer: OfferHandler
    private let completion: Completion
    private let requestSnapshot: SnapshotRequest
    private let keyData: Data
    private let key: SymmetricKey
    private var listener: NWListener?
    private var connection: NWConnection?
    private let mappingLease = LatencyUDPCapacityMappingLease()
    private var timer: DispatchSourceTimer?
    private let handshakeStarted = ProcessInfo.processInfo.systemUptime
    private lazy var handshake = LatencyUDPCapacityHandshake(startedAt: handshakeStarted)
    private var authenticatedAt: Double?
    private var lastTick: Double?
    private var lastEcho: Double = 0
    private var tokens: Double = 0
    private var sequence: UInt64 = 0
    private var echoSequence: UInt64 = 0
    private var pendingEcho: [UInt64: (Double, Int)] = [:]
    private var baselineRTT: [Double] = []
    private var steps = Array(repeating: Step(), count: LatencyUDPCapacityWire.ratesMbps.count)
    private var totalAttemptedBytes = 0
    private var inFlight = 0
    private var stopped = false
    private var offered = false
    private var stopAfterStep: Int?
    private var dataCompleteAt: Double?
    private var receiverSnapshotAt: Double?
    private var receiverFinal = false
    private var heavySamples = 0
    private var sentHistory: [(Double, Int, Int)] = []

    init?(lanAddress: String, mapper: any HostPortMapping = SystemHostPortMapper(),
          offer: @escaping OfferHandler, requestSnapshot: @escaping SnapshotRequest,
          completion: @escaping Completion) {
        guard !lanAddress.isEmpty else { return nil }
        var bytes = Data(count: 32)
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { return nil }
        self.lanAddress = lanAddress
        self.mapper = mapper
        self.offer = offer
        self.completion = completion
        self.requestSnapshot = requestSnapshot
        self.keyData = bytes
        self.key = SymmetricKey(data: bytes)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            do {
                let listener = try NWListener(using: .udp, on: .any)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] incoming in self?.accept(incoming) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener?.port?.rawValue, port > 0 else { self.finish(reason: 1); return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            let token = self.mapper.mapUDP(port: port, lanAddress: self.lanAddress) { [weak self] result in
                                self?.queue.async { [weak self] in self?.mapped(result) }
                            }
                            self.mappingLease.adopt(token)
                        }
                    case .failed, .cancelled: self.finish(reason: 1)
                    default: break
                    }
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                listener.start(queue: self.queue)
            } catch { self.finish(reason: 1) }
        }
    }

    func stop() { queue.async { [self] in finish(reason: 2) } }

    /// Input is accepted only from the same authenticated control channel.
    func updateReceiver(_ values: [ReceiverStep], overflowed: Bool, final: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.authenticatedAt != nil,
                  values.count == self.steps.count else { return }
            guard !overflowed else { self.finish(reason: 3); return }
            if final && self.dataCompleteAt == nil { return }
            for (index, value) in values.enumerated() {
                let prior = self.steps[index].receiver
                guard value.unique >= 0, value.duplicate >= 0, value.reordered >= 0,
                      value.late >= 0, value.bytes >= 0,
                      value.unique <= LatencyUDPCapacityWire.maximumPackets,
                      value.bytes <= LatencyUDPCapacityWire.maximumPayloadBytes,
                      prior == nil || (value.unique >= prior!.unique && value.duplicate >= prior!.duplicate &&
                        value.reordered >= prior!.reordered && value.late >= prior!.late && value.bytes >= prior!.bytes)
                else { self.finish(reason: 3); return }
            }
            for (index, value) in values.enumerated() { self.steps[index].receiver = value }
            self.receiverSnapshotAt = ProcessInfo.processInfo.systemUptime
            if final { self.receiverFinal = true }
            guard let started = self.authenticatedAt else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - started - 1
            let step = Int(elapsed / 5)
            guard elapsed >= 2, step >= 0, step < self.steps.count else { return }
            let history = self.sentHistory.last { $0.1 == step && $0.0 <= now - 1 }
            guard let sent = history?.2, sent >= 100 else { return }
            let missing = max(0, sent - values[step].unique)
            let recentRTT = self.steps[step].rttMs.suffix(10)
            let baseline = self.baselineRTT.sorted()
            let reference = baseline.isEmpty ? 0 : baseline[baseline.count / 2]
            let highRTT = recentRTT.count >= 3 && recentRTT.sorted()[recentRTT.count / 2] > max(250, reference * 2)
            self.heavySamples = (Double(missing) / Double(sent) > 0.10 || highRTT) ? self.heavySamples + 1 : 0
            if self.heavySamples >= 2 { self.stopAfterStep = step }
        }
    }

    private func mapped(_ result: HostPortMappingResult) {
        guard !stopped, !offered else { return }
        switch result {
        case let .mapped(address, port):
            var ip = in_addr(s_addr: address)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard port > 0, inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil,
                  !HostMappingCandidate.isLAN(String(cString: buffer)) else { finish(reason: 1); return }
            offered = true
            offer(Offer(host: String(cString: buffer), port: port, key: keyData))
        case .unavailable, .doubleNAT: finish(reason: 1)
        }
    }

    private func accept(_ incoming: NWConnection) {
        guard !stopped, connection == nil else { incoming.cancel(); return }
        connection = incoming
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.finish(reason: 1)
            default: break
            }
        }
        incoming.start(queue: queue)
    }

    private func receive() {
        guard !stopped, let connection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.finish(reason: 1); return }
            if let data, let packet = LatencyUDPCapacityWire.decode(data, key: self.key) { self.accept(packet) }
            self.receive()
        }
    }

    private func accept(_ packet: LatencyUDPCapacityWire.Packet) {
        switch packet.kind {
        case .hello:
            guard packet.sequence == 0 else { return }
            var challenge = Data(count: 16)
            guard challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { finish(reason: 1); return }
            guard let pair = handshake.challenge(client: packet.body, server: challenge,
                                                 now: ProcessInfo.processInfo.systemUptime) else { return }
            send(.challenge, step: 0, sequence: 0, body: pair)
        case .confirm:
            let now = ProcessInfo.processInfo.systemUptime
            guard packet.sequence == 0, handshake.confirm(packet.body, now: now) else { return }
            send(.confirmed, step: 0, sequence: 0, body: packet.body)
            authenticatedAt = now
            lastTick = now
        case .echoReply:
            guard authenticatedAt != nil, let pending = pendingEcho.removeValue(forKey: packet.sequence) else { return }
            let ms = (ProcessInfo.processInfo.systemUptime - pending.0) * 1000
            guard ms.isFinite, ms >= 0, ms <= 10_000 else { return }
            if pending.1 < 0 { baselineRTT.append(ms) } else { steps[pending.1].rttMs.append(ms) }
        default: break
        }
    }

    private func send(_ kind: LatencyUDPCapacityWire.Kind, step: UInt8, sequence: UInt64, body: Data) {
        guard let connection, let data = LatencyUDPCapacityWire.encode(.init(kind: kind, step: step, sequence: sequence, body: body), key: key) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let started = authenticatedAt else { if now - handshakeStarted >= 10 { finish(reason: 1) }; return }
        let elapsed = now - started
        guard handshake.permitsLoad(now: now), elapsed < LatencyUDPCapacityWire.maximumSessionSeconds else { finish(reason: 4); return }
        let phase = elapsed - 1
        let index = phase < 0 ? -1 : Int(phase / 5)
        if index >= steps.count || (stopAfterStep != nil && index > stopAfterStep!) {
            if dataCompleteAt == nil { dataCompleteAt = now; requestSnapshot() }
            if (receiverFinal && inFlight == 0) || now - (dataCompleteAt ?? now) >= 2 {
                finish(reason: stopAfterStep == nil ? 0 : 5)
            }
            return
        }
        if now - lastEcho >= 0.1 {
            lastEcho = now; echoSequence &+= 1
            pendingEcho[echoSequence] = (now, index)
            pendingEcho = pendingEcho.filter { now - $0.value.0 <= 3 }
            send(.echo, step: UInt8(max(0, index)), sequence: echoSequence, body: Data())
        }
        guard index >= 0, phase.truncatingRemainder(dividingBy: 5) < 4 else { lastTick = now; tokens = 0; return }
        let dt = max(0, min(0.05, now - (lastTick ?? now))); lastTick = now
        let rate = Double(LatencyUDPCapacityWire.ratesMbps[index]) * 1_000_000 / 8
        tokens = min(12_000, tokens + dt * rate)
        sentHistory.append((now, index, steps[index].sent))
        sentHistory.removeAll { now - $0.0 > 3 }
        let body = Data(repeating: 0, count: LatencyUDPCapacityWire.maximumDatagramBytes - 46)
        while tokens >= 1_200 && inFlight < 64 && sequence < UInt64(LatencyUDPCapacityWire.maximumPackets) {
            guard totalAttemptedBytes + 1_200 <= LatencyUDPCapacityWire.maximumPayloadBytes,
                  let connection,
                  let packet = LatencyUDPCapacityWire.encode(.init(kind: .data, step: UInt8(index), sequence: sequence, body: body), key: key) else { finish(reason: 4); return }
            tokens -= 1_200; sequence += 1; inFlight += 1; totalAttemptedBytes += packet.count; steps[index].attempted += 1
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.inFlight = max(0, self.inFlight - 1)
                    if error == nil { self.steps[index].sent += 1; self.steps[index].sentBytes += packet.count }
                    else { self.steps[index].sendErrors += 1 }
                }
            })
        }
    }

    static func lossThroughFinalSnapshot(sent: Int, received: Int, finalSnapshot: Bool, inFlight: Int) -> Int? {
        guard finalSnapshot, inFlight == 0, sent >= 0, received >= 0, received <= sent else { return nil }
        return sent - received
    }

    static func wallActiveSeconds(authenticatedAt: Double, step: Int, now: Double) -> Double {
        guard authenticatedAt.isFinite, now.isFinite, step >= 0,
              step < LatencyUDPCapacityWire.ratesMbps.count else { return 0 }
        return min(4, max(0, now - (authenticatedAt + 1 + Double(step) * 5)))
    }

    private func finish(reason: Int) {
        guard !stopped else { return }; stopped = true
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        mappingLease.close()
        func summary(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted(); guard !sorted.isEmpty else { return [:] }
            return ["p50": sorted[(sorted.count - 1) / 2], "p95": sorted[Int(Double(sorted.count - 1) * 0.95)], "max": sorted[sorted.count - 1]]
        }
        let now = ProcessInfo.processInfo.systemUptime
        let finalValid = receiverFinal && inFlight == 0
        let values: [[String: Any]] = steps.enumerated().map { index, step in
            let activeSeconds = authenticatedAt.map { Self.wallActiveSeconds(authenticatedAt: $0, step: index, now: now) } ?? 0
            var row: [String: Any] = ["rateMbps": LatencyUDPCapacityWire.ratesMbps[index], "attempted": step.attempted,
                "sent": step.sent, "sentBytes": step.sentBytes, "sendErrors": step.sendErrors,
                "activeSeconds": activeSeconds, "rttMs": summary(step.rttMs)]
            if activeSeconds > 0 {
                row["offeredBps"] = Double(step.attempted * 1_200 * 8) / activeSeconds
                row["sentBps"] = Double(step.sentBytes * 8) / activeSeconds
            }
            if let r = step.receiver {
                row["received"] = r.unique; row["duplicate"] = r.duplicate; row["reordered"] = r.reordered
                row["late"] = r.late; row["receivedBytes"] = r.bytes
                row["receiverExceedsSent"] = r.unique > step.sent
                if let lost = Self.lossThroughFinalSnapshot(sent: step.sent, received: r.unique,
                                                              finalSnapshot: receiverFinal, inFlight: inFlight) {
                    row["lostThroughSnapshot"] = lost
                    if step.sent > 0 { row["lossFractionThroughSnapshot"] = Double(lost) / Double(step.sent) }
                }
                if activeSeconds > 0 { row["receivedBps"] = Double(r.bytes * 8) / activeSeconds }
            }
            return row
        }
        var result: [String: Any] = ["reason": reason, "baselineRTTMs": summary(baselineRTT),
                                     "finalSnapshotValid": finalValid, "steps": values]
        if let receiverSnapshotAt { result["receiverSnapshotAgeSeconds"] = max(0, now - receiverSnapshotAt) }
        completion(result)
    }
}
#endif
