import Foundation

protocol ComputerUseSetupChannel: Sendable {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope

    func poll() async throws -> [ComputerUseEnvelope]
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws
}

extension CloudKitComputerUseChannel: ComputerUseSetupChannel {}

@MainActor
final class ComputerUseSetupCoordinator: ObservableObject {
    enum State: Equatable {
        case unavailable
        case setupRequired
        case requesting
        case installing(ComputerUseSetupProgress)
        case ready
        case failed(String)
    }

    typealias ChannelFactory = @MainActor (
        _ host: LocalHostAdvertisement,
        _ sessionID: String
    ) -> any ComputerUseSetupChannel

    @Published private var statesByHostID: [String: State] = [:]

    private struct SetupTaskContext {
        let pairingCode: String
        let requestID: String
        let task: Task<Void, Never>
    }

    private let channelFactory: ChannelFactory
    private var tasksByHostID: [String: SetupTaskContext] = [:]
    private static let setupTimeout: Duration = .seconds(6 * 60 * 60)
    private static let requestRefreshInterval: Duration = .seconds(30)

    init(channelFactory: @escaping ChannelFactory = { host, sessionID in
        CloudKitComputerUseChannel(
            containerIdentifier: Config.cloudKitContainerIdentifier,
            pairingCode: host.code,
            sessionID: sessionID,
            senderID: DeviceIdentity.get(),
            targetID: host.senderID)
    }) {
        self.channelFactory = channelFactory
    }

    func state(for host: LocalHostAdvertisement) -> State {
        guard let hostID = host.senderID, !hostID.isEmpty else {
            return .unavailable
        }
        if let state = statesByHostID[hostID] {
            return state
        }

        switch host.computerUseCapability.state {
        case .unavailable:
            return .unavailable
        case .setupRequired:
            return .setupRequired
        case .installing:
            return .installing(.waiting(detail: host.computerUseCapability.detail))
        case .ready, .busy, .paused:
            return .ready
        }
    }

    /// Reconciles coarse advertisement state with the direct setup-progress
    /// channel. If setup was already running when iOS reopened, the same
    /// idempotent request resumes monitoring instead of starting over.
    func reconcile(hosts: [LocalHostAdvertisement]) {
        for host in hosts {
            guard let hostID = host.senderID, !hostID.isEmpty else { continue }

            if let active = tasksByHostID[hostID],
               active.pairingCode != host.code {
                active.task.cancel()
                tasksByHostID.removeValue(forKey: hostID)
                statesByHostID.removeValue(forKey: hostID)
            }

            switch host.computerUseCapability.state {
            case .ready, .busy, .paused:
                tasksByHostID.removeValue(forKey: hostID)?.task.cancel()
                statesByHostID[hostID] = .ready

            case .installing:
                switch statesByHostID[hostID] {
                case nil, .unavailable, .setupRequired:
                    statesByHostID[hostID] = .installing(
                        .waiting(detail: host.computerUseCapability.detail))
                    startSetup(for: host)
                case .requesting, .installing, .ready, .failed:
                    break
                }

            case .setupRequired:
                // Keep direct progress while a same-pairing-code request is
                // active; the coarse advertisement can lag by one refresh.
                if tasksByHostID[hostID] == nil,
                   !isFailure(statesByHostID[hostID]) {
                    statesByHostID[hostID] = .setupRequired
                }

            case .unavailable:
                tasksByHostID.removeValue(forKey: hostID)?.task.cancel()
                statesByHostID[hostID] = .unavailable
            }
        }
    }

    func startSetup(for host: LocalHostAdvertisement) {
        guard let hostID = host.senderID,
              !hostID.isEmpty,
              tasksByHostID[hostID] == nil else {
            return
        }

        switch host.computerUseCapability.state {
        case .setupRequired, .installing:
            break
        case .unavailable, .ready, .busy, .paused:
            return
        }

        let request = ComputerUseSetupRequest()
        let sessionID = "setup-\(request.requestID)"
        let channel = channelFactory(host, sessionID)
        statesByHostID[hostID] = .requesting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSetup(
                hostID: hostID,
                request: request,
                channel: channel)
        }
        tasksByHostID[hostID] = SetupTaskContext(
            pairingCode: host.code,
            requestID: request.requestID,
            task: task)
    }

    private func performSetup(
        hostID: String,
        request: ComputerUseSetupRequest,
        channel: any ComputerUseSetupChannel
    ) async {
        defer {
            if tasksByHostID[hostID]?.requestID == request.requestID {
                tasksByHostID[hostID] = nil
            }
        }

        do {
            let body = try request.encodedBody()
            try await channel.send(
                kind: .setupRequest,
                body: body,
                to: nil,
                sessionID: nil,
                messageID: request.requestID)
            guard !Task.isCancelled else { return }

            statesByHostID[hostID] = .installing(ComputerUseSetupProgress(
                requestID: request.requestID,
                idempotencyKey: request.idempotencyKey,
                phase: .queued,
                detail: "Starting setup on your Mac…"))

            let deadline = ContinuousClock.now.advanced(by: Self.setupTimeout)
            var nextRequestRefresh = ContinuousClock.now.advanced(
                by: Self.requestRefreshInterval)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let envelopes: [ComputerUseEnvelope]
                do {
                    envelopes = try await channel.poll()
                } catch is CancellationError {
                    return
                } catch {
                    // Installation continues on the Mac. A brief iCloud or
                    // network outage must not turn a multi-gigabyte download
                    // into a false terminal failure on iOS.
                    nextRequestRefresh = await refreshSetupRequestIfNeeded(
                        request,
                        body: body,
                        channel: channel,
                        nextRefresh: nextRequestRefresh)
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                for envelope in envelopes where envelope.kind == .setupProgress {
                    // One stale or malformed private-CloudKit record must not
                    // strand a multi-gigabyte install in a permanent Retry
                    // loop. Ignore it, acknowledge the batch below, and keep
                    // listening for the host's next idempotent status update.
                    guard let progress = try? ComputerUseSetupProgress.decodeBody(
                        envelope.body),
                          progress.idempotencyKey == request.idempotencyKey else {
                        continue
                    }

                    switch progress.phase {
                    case .ready:
                        statesByHostID[hostID] = .ready
                        try? await channel.acknowledge(envelopes)
                        return
                    case .failed:
                        statesByHostID[hostID] = .failed(
                            progress.errorMessage ?? progress.detail)
                        try? await channel.acknowledge(envelopes)
                        return
                    case .queued, .downloadingModel, .installingPackages, .verifying:
                        let current: ComputerUseSetupProgress?
                        if case .installing(let value) = statesByHostID[hostID] {
                            current = value
                        } else {
                            current = nil
                        }
                        statesByHostID[hostID] = .installing(
                            ComputerUseSetupProgressPolicy.merge(
                                current: current,
                                incoming: progress))
                    }
                }

                try? await channel.acknowledge(envelopes)

                // The stable record is periodically recreated after the host
                // acknowledges it. If the Mac app restarts mid-download, the
                // resumable installer receives the same idempotent request and
                // the user does not have to wait hours or tap through setup.
                nextRequestRefresh = await refreshSetupRequestIfNeeded(
                    request,
                    body: body,
                    channel: channel,
                    nextRefresh: nextRequestRefresh)

                try await Task.sleep(for: .seconds(1))
            }
            if !Task.isCancelled {
                statesByHostID[hostID] = .failed(
                    "Setup is taking longer than expected. Check the Mac host, then tap Retry.")
            }
        } catch is CancellationError {
            return
        } catch {
            statesByHostID[hostID] = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't set up AI: \(error.localizedDescription)")
        }
    }

    private func refreshSetupRequestIfNeeded(
        _ request: ComputerUseSetupRequest,
        body: String,
        channel: any ComputerUseSetupChannel,
        nextRefresh: ContinuousClock.Instant
    ) async -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        guard now >= nextRefresh else { return nextRefresh }
        _ = try? await channel.send(
            kind: .setupRequest,
            body: body,
            to: nil,
            sessionID: nil,
            messageID: request.requestID)
        return now.advanced(by: Self.requestRefreshInterval)
    }

    private func isFailure(_ state: State?) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// CloudKit progress records can complete out of order because each host
/// update is saved independently. Keep the last completed fraction as a lower
/// bound so the device-row bar never moves backwards or becomes an indeterminate
/// spinner after real byte progress has already arrived.
enum ComputerUseSetupProgressPolicy {
    static func merge(
        current: ComputerUseSetupProgress?,
        incoming: ComputerUseSetupProgress
    ) -> ComputerUseSetupProgress {
        guard let current,
              let currentFraction = current.fractionCompleted else {
            return incoming
        }

        if let incomingFraction = incoming.fractionCompleted {
            return incomingFraction < currentFraction ? current : incoming
        }

        return ComputerUseSetupProgress(
            requestID: incoming.requestID,
            idempotencyKey: incoming.idempotencyKey,
            phase: incoming.phase,
            fractionCompleted: currentFraction,
            detail: incoming.detail,
            errorMessage: incoming.errorMessage)
    }
}

enum ComputerUseRowAction: Equatable {
    case hidden
    case unavailable(String)
    case setup
    case progress(ComputerUseSetupProgress)
    case useAI
    case retry(String)

    static func resolve(
        host: LocalHostAdvertisement,
        state: ComputerUseSetupCoordinator.State
    ) -> ComputerUseRowAction {
        guard host.senderID?.isEmpty == false else {
            return .unavailable(
                "Remote control is available nearby. For AI setup, update and open Remote Desktop Host on your Mac, then make sure this device and the Mac use the same Apple Account for iCloud.")
        }

        switch state {
        case .unavailable:
            return .unavailable(
                "Update Remote Desktop Host on this Mac to a version that supports AI Computer Use, then try again.")
        case .setupRequired:
            return .setup
        case .requesting:
            return .progress(.waiting(detail: "Starting setup…"))
        case .installing(let progress):
            return .progress(progress)
        case .ready:
            return .useAI
        case .failed(let message):
            return .retry(message)
        }
    }
}

private extension ComputerUseSetupProgress {
    static func waiting(detail: String) -> ComputerUseSetupProgress {
        ComputerUseSetupProgress(
            requestID: "pending",
            phase: .queued,
            detail: detail.isEmpty ? "Setting up AI…" : detail)
    }
}
