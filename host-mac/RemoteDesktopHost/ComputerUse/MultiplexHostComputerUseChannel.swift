import Foundation

/// Lets the host accept the existing private-CloudKit control plane and the
/// authenticated LAN broker at the same time. A reply is routed only to the
/// transport that authenticated the corresponding sender/session pair.
actor MultiplexHostComputerUseChannel: HostComputerUseChannel {
    static let maximumTrackedPeerRoutes = 64
    static let maximumTrackedEnvelopeRoutes = 256
    static let routeIdleLifetime: TimeInterval = 15 * 60

    /// Setup stays on the bootstrap transport while all task lifecycle traffic
    /// stays on the authenticated task transport. Keeping these route purposes
    /// distinct prevents a CloudKit setup request from claiming the LAN task
    /// route when a client legitimately reuses its sender/session identity.
    private enum RoutePurpose: Hashable {
        case setup
        case task

        init(kind: ComputerUseEnvelope.Kind) {
            switch kind {
            case .setupRequest, .setupProgress:
                self = .setup
            default:
                self = .task
            }
        }
    }

    private struct PeerRoute: Hashable {
        let senderID: String
        let sessionID: String
        let purpose: RoutePurpose
    }

    private struct EnvelopeRoute: Hashable {
        let id: String
        let senderID: String
        let sessionID: String
        let purpose: RoutePurpose
    }

    private struct PeerRouteEntry {
        let channelIndex: Int
        let touchedAt: Date
        let sequence: UInt64
    }

    private struct EnvelopeRouteEntry {
        let channelIndex: Int
        let touchedAt: Date
        let sequence: UInt64
    }

    private var channels: [any HostComputerUseChannel]
    private let now: @Sendable () -> Date
    private var channelByPeer: [PeerRoute: PeerRouteEntry] = [:]
    private var channelByEnvelope: [EnvelopeRoute: EnvelopeRouteEntry] = [:]
    private var receivedByChannel:
        [Int: [EnvelopeRoute: ComputerUseEnvelope]] = [:]
    private var pollTasks: [Int: Task<Void, Never>] = [:]
    private var isPollingStopped = false
    private var pinnedPeerRoute: PeerRoute?
    private var routeSequence: UInt64 = 0

    init(
        channels: [any HostComputerUseChannel],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(!channels.isEmpty)
        self.channels = channels
        self.now = now
    }

    func add(_ channel: any HostComputerUseChannel) {
        guard !isPollingStopped else { return }
        let index = channels.count
        channels.append(channel)
        if !pollTasks.isEmpty {
            startPoller(channel, at: index)
        }
    }

    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        guard let targetID = explicitTargetID,
              let sessionID = explicitSessionID else {
            throw SignalingError.transport(
                "The authenticated AI session route is no longer available.")
        }
        let peer = PeerRoute(
            senderID: targetID,
            sessionID: sessionID,
            purpose: RoutePurpose(kind: kind))
        let timestamp = now()
        pruneRouteState(at: timestamp, protecting: peer)
        guard let entry = channelByPeer[peer] else {
            throw SignalingError.transport(
                "The authenticated AI session route is no longer available.")
        }
        touchPeerRoute(peer, channelIndex: entry.channelIndex, at: timestamp)
        let envelope = try await channels[entry.channelIndex].send(
            kind: kind,
            body: body,
            to: explicitTargetID,
            sessionID: explicitSessionID,
            messageID: explicitMessageID)
        if kind == .assistant, pinnedPeerRoute == peer {
            pinnedPeerRoute = nil
        }
        pruneRouteState(at: now(), protecting: peer)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        guard !isPollingStopped else { throw CancellationError() }
        startPollersIfNeeded()
        let timestamp = now()
        pruneRouteState(at: timestamp, protecting: pinnedPeerRoute)
        let batches = receivedByChannel.map { index, values in
            (index, Array(values.values))
        }

        var merged: [ComputerUseEnvelope] = []
        for (channelIndex, envelopes) in batches.sorted(by: { $0.0 < $1.0 }) {
            for envelope in envelopes {
                let peer = PeerRoute(
                    senderID: envelope.senderID,
                    sessionID: envelope.sessionID,
                    purpose: RoutePurpose(kind: envelope.kind))
                guard let existing = channelByPeer[peer],
                      existing.channelIndex == channelIndex else {
                    // The same authenticated peer/session cannot migrate
                    // between transports mid-task. Ignore the conflicting
                    // route rather than allowing a response-channel swap.
                    continue
                }
                let envelopeRoute = EnvelopeRoute(
                    id: envelope.id,
                    senderID: envelope.senderID,
                    sessionID: envelope.sessionID,
                    purpose: RoutePurpose(kind: envelope.kind))
                guard channelByEnvelope[envelopeRoute]?.channelIndex
                        == channelIndex else { continue }
                touchPeerRoute(
                    peer,
                    channelIndex: channelIndex,
                    at: timestamp)
                touchEnvelopeRoute(
                    envelopeRoute,
                    channelIndex: channelIndex,
                    at: timestamp)
                merged.append(envelope)
            }
        }
        return merged.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Each backing transport owns an independent long-lived poll. A stalled
    /// CloudKit request can therefore never hold the LAN actor's already-ready
    /// batch behind structured-concurrency scope teardown.
    private func startPollersIfNeeded() {
        guard !isPollingStopped, pollTasks.isEmpty else { return }
        for (index, channel) in channels.enumerated() {
            startPoller(channel, at: index)
        }
    }

    private func startPoller(
        _ channel: any HostComputerUseChannel,
        at index: Int
    ) {
        guard !isPollingStopped, pollTasks[index] == nil else { return }
        pollTasks[index] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let envelopes = try await channel.poll()
                    guard !Task.isCancelled else { return }
                    await self?.record(
                        envelopes,
                        fromChannelAt: index)
                } catch is CancellationError {
                    return
                } catch {
                    // This transport retries independently. Other healthy
                    // transports continue to feed the host immediately.
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func record(
        _ envelopes: [ComputerUseEnvelope],
        fromChannelAt index: Int
    ) {
        guard !isPollingStopped else { return }
        let timestamp = now()
        pruneRouteState(at: timestamp, protecting: pinnedPeerRoute)
        for envelope in envelopes {
            let peer = PeerRoute(
                senderID: envelope.senderID,
                sessionID: envelope.sessionID,
                purpose: RoutePurpose(kind: envelope.kind))
            if envelope.kind == .prompt, pinnedPeerRoute == nil {
                // The host accepts at most one active task. Retain the first
                // prompt's authenticated route until its terminal assistant
                // response is handed to that transport, even if abandoned
                // sessions subsequently churn every ordinary route slot.
                pinnedPeerRoute = peer
            }
            guard ensurePeerRoute(
                peer,
                channelIndex: index,
                at: timestamp) else { continue }
            let key = EnvelopeRoute(
                id: envelope.id,
                senderID: envelope.senderID,
                sessionID: envelope.sessionID,
                purpose: RoutePurpose(kind: envelope.kind))
            if let existing = receivedByChannel[index]?[key] {
                // Retain the first authenticated contents for a stable ID.
                if existing == envelope {
                    touchEnvelopeRoute(
                        key,
                        channelIndex: index,
                        at: timestamp)
                }
                continue
            }
            guard makeEnvelopeRouteCapacity(protecting: pinnedPeerRoute) else {
                continue
            }
            var received = receivedByChannel[index] ?? [:]
            received[key] = envelope
            receivedByChannel[index] = received
            touchEnvelopeRoute(key, channelIndex: index, at: timestamp)
        }
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        guard !isPollingStopped else { throw CancellationError() }
        let timestamp = now()
        pruneRouteState(at: timestamp, protecting: pinnedPeerRoute)
        var grouped: [Int: [ComputerUseEnvelope]] = [:]
        for envelope in envelopes {
            let key = EnvelopeRoute(
                id: envelope.id,
                senderID: envelope.senderID,
                sessionID: envelope.sessionID,
                purpose: RoutePurpose(kind: envelope.kind))
            guard let entry = channelByEnvelope[key] else { continue }
            grouped[entry.channelIndex, default: []].append(envelope)
        }
        for (index, values) in grouped {
            try await channels[index].acknowledge(values)
            for envelope in values {
                let key = EnvelopeRoute(
                    id: envelope.id,
                    senderID: envelope.senderID,
                    sessionID: envelope.sessionID,
                    purpose: RoutePurpose(kind: envelope.kind))
                removeEnvelopeRoute(key)
                let peer = PeerRoute(
                    senderID: envelope.senderID,
                    sessionID: envelope.sessionID,
                    purpose: RoutePurpose(kind: envelope.kind))
                if let route = channelByPeer[peer] {
                    touchPeerRoute(
                        peer,
                        channelIndex: route.channelIndex,
                        at: timestamp)
                }
            }
            if receivedByChannel[index]?.isEmpty == true {
                receivedByChannel[index] = nil
            }
        }
    }

    func stopPolling() async {
        guard !isPollingStopped else { return }
        isPollingStopped = true
        let tasks = Array(pollTasks.values)
        pollTasks.removeAll()
        for task in tasks { task.cancel() }
        for channel in channels {
            await channel.stopPolling()
        }
        receivedByChannel.removeAll()
        channelByEnvelope.removeAll()
    }

    func routeStateCounts() -> (peers: Int, envelopes: Int) {
        (channelByPeer.count, channelByEnvelope.count)
    }

    func hasPeerRoute(senderID: String, sessionID: String) -> Bool {
        [.setup, .task].contains { purpose in
            channelByPeer[PeerRoute(
                senderID: senderID,
                sessionID: sessionID,
                purpose: purpose)] != nil
        }
    }

    private func ensurePeerRoute(
        _ peer: PeerRoute,
        channelIndex: Int,
        at timestamp: Date
    ) -> Bool {
        if let existing = channelByPeer[peer] {
            guard existing.channelIndex == channelIndex else { return false }
            touchPeerRoute(peer, channelIndex: channelIndex, at: timestamp)
            return true
        }
        while channelByPeer.count >= Self.maximumTrackedPeerRoutes {
            guard evictLeastRecentPeerRoute(
                excluding: pinnedPeerRoute) else { return false }
        }
        touchPeerRoute(peer, channelIndex: channelIndex, at: timestamp)
        return true
    }

    private func touchPeerRoute(
        _ peer: PeerRoute,
        channelIndex: Int,
        at timestamp: Date
    ) {
        routeSequence &+= 1
        channelByPeer[peer] = PeerRouteEntry(
            channelIndex: channelIndex,
            touchedAt: timestamp,
            sequence: routeSequence)
    }

    private func touchEnvelopeRoute(
        _ route: EnvelopeRoute,
        channelIndex: Int,
        at timestamp: Date
    ) {
        routeSequence &+= 1
        channelByEnvelope[route] = EnvelopeRouteEntry(
            channelIndex: channelIndex,
            touchedAt: timestamp,
            sequence: routeSequence)
    }

    private func pruneRouteState(
        at timestamp: Date,
        protecting protectedPeer: PeerRoute?
    ) {
        let expiredEnvelopes: [EnvelopeRoute] = channelByEnvelope.compactMap {
            element -> EnvelopeRoute? in
            let route = element.key
            let entry = element.value
            let peer = PeerRoute(
                senderID: route.senderID,
                sessionID: route.sessionID,
                purpose: route.purpose)
            guard peer != pinnedPeerRoute,
                  peer != protectedPeer,
                  timestamp.timeIntervalSince(entry.touchedAt)
                    >= Self.routeIdleLifetime else { return nil }
            return route
        }
        for route in expiredEnvelopes { removeEnvelopeRoute(route) }

        let expiredPeers: [PeerRoute] = channelByPeer.compactMap {
            element -> PeerRoute? in
            let peer = element.key
            let entry = element.value
            guard peer != pinnedPeerRoute,
                  peer != protectedPeer,
                  timestamp.timeIntervalSince(entry.touchedAt)
                    >= Self.routeIdleLifetime else { return nil }
            return peer
        }
        for peer in expiredPeers { removePeerRoute(peer) }

        while channelByEnvelope.count > Self.maximumTrackedEnvelopeRoutes {
            guard evictLeastRecentEnvelopeRoute(
                excluding: pinnedPeerRoute ?? protectedPeer) else { break }
        }
        while channelByPeer.count > Self.maximumTrackedPeerRoutes {
            guard evictLeastRecentPeerRoute(
                excluding: pinnedPeerRoute ?? protectedPeer) else { break }
        }
    }

    private func makeEnvelopeRouteCapacity(
        protecting protectedPeer: PeerRoute?
    ) -> Bool {
        while channelByEnvelope.count >= Self.maximumTrackedEnvelopeRoutes {
            guard evictLeastRecentEnvelopeRoute(
                excluding: protectedPeer) else { return false }
        }
        return true
    }

    @discardableResult
    private func evictLeastRecentPeerRoute(
        excluding protectedPeer: PeerRoute?
    ) -> Bool {
        guard let victim = channelByPeer
            .filter({ $0.key != protectedPeer })
            .min(by: { lhs, rhs in
                if lhs.value.sequence == rhs.value.sequence {
                    if lhs.key.senderID == rhs.key.senderID {
                        return lhs.key.sessionID < rhs.key.sessionID
                    }
                    return lhs.key.senderID < rhs.key.senderID
                }
                return lhs.value.sequence < rhs.value.sequence
            })?.key else { return false }
        removePeerRoute(victim)
        return true
    }

    @discardableResult
    private func evictLeastRecentEnvelopeRoute(
        excluding protectedPeer: PeerRoute?
    ) -> Bool {
        guard let victim = channelByEnvelope
            .filter({ entry in
                let route = entry.key
                return PeerRoute(
                    senderID: route.senderID,
                    sessionID: route.sessionID,
                    purpose: route.purpose) != protectedPeer
            })
            .min(by: { lhs, rhs in
                if lhs.value.sequence == rhs.value.sequence {
                    return lhs.key.id < rhs.key.id
                }
                return lhs.value.sequence < rhs.value.sequence
            })?.key else { return false }
        removeEnvelopeRoute(victim)
        return true
    }

    private func removePeerRoute(_ peer: PeerRoute) {
        channelByPeer[peer] = nil
        let envelopeRoutes = channelByEnvelope.keys.filter {
            $0.senderID == peer.senderID
                && $0.sessionID == peer.sessionID
                && $0.purpose == peer.purpose
        }
        for route in envelopeRoutes { removeEnvelopeRoute(route) }
    }

    private func removeEnvelopeRoute(_ route: EnvelopeRoute) {
        channelByEnvelope[route] = nil
        for index in Array(receivedByChannel.keys) {
            receivedByChannel[index]?[route] = nil
            if receivedByChannel[index]?.isEmpty == true {
                receivedByChannel[index] = nil
            }
        }
    }
}
