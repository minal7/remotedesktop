import CloudKit
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

private actor UnavailableComputerUseSetupChannel:
    ComputerUseSetupChannel {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        throw SignalingError.transport(message)
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        throw SignalingError.transport(message)
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        throw SignalingError.transport(message)
    }
}

private actor AccountBoundComputerUseSetupChannel:
    ComputerUseSetupChannel {
    private let base: any ComputerUseSetupChannel
    private let accountBinding: CloudKitAccountBinding
    private var hasValidatedBinding = false

    init(
        base: any ComputerUseSetupChannel,
        accountBinding: CloudKitAccountBinding
    ) {
        self.base = base
        self.accountBinding = accountBinding
    }

    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        try await validateBindingIfNeeded()
        return try await base.send(
            kind: kind,
            body: body,
            to: explicitTargetID,
            sessionID: explicitSessionID,
            messageID: explicitMessageID)
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        try await validateBindingIfNeeded()
        return try await base.poll()
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        try await validateBindingIfNeeded()
        try await base.acknowledge(envelopes)
    }

    private func validateBindingIfNeeded() async throws {
        guard !hasValidatedBinding else { return }
        try await LocalCloudAccountBindingPolicy.validate(accountBinding)
        hasValidatedBinding = true
    }
}

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

    private struct HostAccountKey: Hashable {
        let hostID: String
        let accountBindingRawValue: String?

        init?(host: LocalHostAdvertisement) {
            guard let hostID = host.senderID, !hostID.isEmpty else {
                return nil
            }
            self.hostID = hostID
            self.accountBindingRawValue = host.accountBinding?.rawValue
        }
    }

    @Published private var statesByHostKey: [HostAccountKey: State] = [:]

    private struct SetupTaskContext {
        let pairingCode: String
        let routeIdentity: String
        let requestID: String
        let task: Task<Void, Never>
    }

    private let channelFactory: ChannelFactory
    private let hasAuthenticatedRoute: (LocalHostAdvertisement) -> Bool
    private let accountChangeNotificationCenter: NotificationCenter
    private var accountChangeObserver: NSObjectProtocol?
    private var tasksByHostKey: [HostAccountKey: SetupTaskContext] = [:]
    private static let setupTimeout: Duration = .seconds(6 * 60 * 60)
    private static let requestRefreshInterval: Duration = .seconds(30)

    init(
        hasAuthenticatedRoute: @escaping (LocalHostAdvertisement) -> Bool =
            ComputerUseSetupCoordinator.defaultHasAuthenticatedRoute,
        accountChangeNotificationCenter: NotificationCenter = .default,
        channelFactory: @escaping ChannelFactory = { host, sessionID in
            let senderID = DeviceIdentity.get()
            guard !senderID.isEmpty else {
                return UnavailableComputerUseSetupChannel(
                    message: "Secure device identity is unavailable. Unlock this device and try again.")
            }
            if let endpoint = host.localEndpoint,
               endpoint.isValid,
               let hostID = host.senderID,
               let credentialID = host.localCredentialID,
               let accountBinding = host.accountBinding,
               let credential = LocalComputerUseCredentialStore()
                .clientCredential(
                    hostID: hostID,
                    credentialID: credentialID,
                    accountBinding: accountBinding) {
                let local = LocalComputerUseBrokerClient(
                    endpoint: endpoint,
                    credential: credential,
                    pairingCode: host.code,
                    sessionID: sessionID,
                    senderID: senderID,
                    targetID: hostID)
                return AccountBoundComputerUseSetupChannel(
                    base: local,
                    accountBinding: accountBinding)
            }
            return CloudKitComputerUseChannel(
                containerIdentifier: Config.cloudKitContainerIdentifier,
                pairingCode: host.code,
                sessionID: sessionID,
                senderID: senderID,
                targetID: host.senderID)
        }
    ) {
        self.channelFactory = channelFactory
        self.hasAuthenticatedRoute = hasAuthenticatedRoute
        self.accountChangeNotificationCenter = accountChangeNotificationCenter
        accountChangeObserver = accountChangeNotificationCenter.addObserver(
            forName: NSNotification.Name.CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                LocalCloudAccountBindingPolicy.invalidateForAccountChange()
                self?.cancelAllSetups()
            }
        }
    }

    deinit {
        if let accountChangeObserver {
            accountChangeNotificationCenter.removeObserver(accountChangeObserver)
        }
    }

    /// Keeps the original single trailing-closure construction source
    /// compatible while the designated initializer also accepts a route
    /// authentication policy for focused tests.
    convenience init(channelFactory: @escaping ChannelFactory) {
        self.init(
            hasAuthenticatedRoute: Self.defaultHasAuthenticatedRoute,
            accountChangeNotificationCenter: .default,
            channelFactory: channelFactory)
    }

    private nonisolated static func defaultHasAuthenticatedRoute(
        _ host: LocalHostAdvertisement
    ) -> Bool {
        if host.hasAuthenticatedCloudMatch { return true }
        guard let endpoint = host.localEndpoint,
              endpoint.isValid,
              let hostID = host.senderID,
              let credentialID = host.localCredentialID,
              let accountBinding = host.accountBinding else {
            return false
        }
        return LocalComputerUseCredentialStore().clientCredential(
            hostID: hostID,
            credentialID: credentialID,
            accountBinding: accountBinding) != nil
    }

    func state(for host: LocalHostAdvertisement) -> State {
        guard let key = HostAccountKey(host: host) else {
            return .unavailable
        }
        if let state = statesByHostKey[key] {
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
        let keyedHosts = hosts.compactMap { host -> (HostAccountKey, LocalHostAdvertisement)? in
            guard let key = HostAccountKey(host: host) else { return nil }
            return (key, host)
        }
        let liveKeys = Set(keyedHosts.map(\.0))

        // An empty list is the account-invalidated state published by
        // discovery. Stop every suspended poll before it can mutate or send
        // for the previous Apple Account.
        for key in tasksByHostKey.keys.filter({ !liveKeys.contains($0) }) {
            tasksByHostKey.removeValue(forKey: key)?.task.cancel()
        }
        statesByHostKey = statesByHostKey.filter { liveKeys.contains($0.key) }

        for (key, host) in keyedHosts {

            var shouldRecreateTask = false
            if let active = tasksByHostKey[key],
               (active.pairingCode != host.code
                || active.routeIdentity != routeIdentity(for: host)) {
                active.task.cancel()
                tasksByHostKey.removeValue(forKey: key)
                statesByHostKey.removeValue(forKey: key)
                shouldRecreateTask = true
            }

            switch host.computerUseCapability.state {
            case .ready, .busy, .paused:
                tasksByHostKey.removeValue(forKey: key)?.task.cancel()
                statesByHostKey[key] = .ready

            case .installing:
                if !isFailure(statesByHostKey[key]),
                   tasksByHostKey[key] == nil {
                    statesByHostKey[key] = .installing(
                        .waiting(detail: host.computerUseCapability.detail))
                    if hasAuthenticatedRoute(host) {
                        startSetup(for: host)
                    }
                }

            case .setupRequired:
                // Keep direct progress while a same-pairing-code request is
                // active; the coarse advertisement can lag by one refresh.
                if tasksByHostKey[key] == nil,
                   !isFailure(statesByHostKey[key]) {
                    statesByHostKey[key] = .setupRequired
                    if shouldRecreateTask, hasAuthenticatedRoute(host) {
                        startSetup(for: host)
                    }
                }

            case .unavailable:
                tasksByHostKey.removeValue(forKey: key)?.task.cancel()
                statesByHostKey[key] = .unavailable
            }
        }
    }

    func startSetup(for host: LocalHostAdvertisement) {
        guard let key = HostAccountKey(host: host),
              hasAuthenticatedRoute(host),
              tasksByHostKey[key] == nil else {
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
        statesByHostKey[key] = .requesting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSetup(
                key: key,
                request: request,
                channel: channel)
        }
        tasksByHostKey[key] = SetupTaskContext(
            pairingCode: host.code,
            routeIdentity: routeIdentity(for: host),
            requestID: request.requestID,
            task: task)
    }

    private func routeIdentity(
        for host: LocalHostAdvertisement
    ) -> String {
        if let endpoint = host.localEndpoint,
           endpoint.isValid,
           let hostID = host.senderID,
           let credentialID = host.localCredentialID,
           let accountBinding = host.accountBinding,
           LocalComputerUseCredentialStore().clientCredential(
                hostID: hostID,
                credentialID: credentialID,
                accountBinding: accountBinding) != nil {
            return "local|\(hostID)|\(credentialID)|\(accountBinding.rawValue)|\(endpoint.host):\(endpoint.port)|\(host.code)"
        }
        if host.hasAuthenticatedCloudMatch {
            return "cloud|\(host.senderID ?? "none")|\(host.accountBinding?.rawValue ?? "none")|\(host.code)"
        }
        let endpoint = host.localEndpoint.map {
            "\($0.host):\($0.port)"
        } ?? "none"
        return "unavailable|\(host.senderID ?? "none")|\(host.localCredentialID ?? "none")|\(endpoint)|\(host.code)"
    }

    private func performSetup(
        key: HostAccountKey,
        request: ComputerUseSetupRequest,
        channel: any ComputerUseSetupChannel
    ) async {
        defer {
            if tasksByHostKey[key]?.requestID == request.requestID {
                tasksByHostKey[key] = nil
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
            guard isCurrentSetup(key: key, requestID: request.requestID) else {
                return
            }

            statesByHostKey[key] = .installing(ComputerUseSetupProgress(
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
                    guard isCurrentSetup(
                        key: key,
                        requestID: request.requestID) else {
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrentSetup(
                        key: key,
                        requestID: request.requestID) else {
                        return
                    }
                    // Installation continues on the Mac. A brief iCloud or
                    // network outage must not turn a multi-gigabyte download
                    // into a false terminal failure on iOS.
                    nextRequestRefresh = await refreshSetupRequestIfNeeded(
                        request,
                        body: body,
                        channel: channel,
                        nextRefresh: nextRequestRefresh)
                    guard isCurrentSetup(
                        key: key,
                        requestID: request.requestID) else {
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                    guard isCurrentSetup(
                        key: key,
                        requestID: request.requestID) else {
                        return
                    }
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
                        statesByHostKey[key] = .ready
                        try? await channel.acknowledge(envelopes)
                        return
                    case .failed:
                        statesByHostKey[key] = .failed(
                            progress.errorMessage ?? progress.detail)
                        try? await channel.acknowledge(envelopes)
                        return
                    case .queued, .downloadingModel, .installingPackages, .verifying:
                        let current: ComputerUseSetupProgress?
                        if case .installing(let value) = statesByHostKey[key] {
                            current = value
                        } else {
                            current = nil
                        }
                        statesByHostKey[key] = .installing(
                            ComputerUseSetupProgressPolicy.merge(
                                current: current,
                                incoming: progress))
                    }
                }

                try? await channel.acknowledge(envelopes)
                guard isCurrentSetup(
                    key: key,
                    requestID: request.requestID) else {
                    return
                }

                // The stable record is periodically recreated after the host
                // acknowledges it. If the Mac app restarts mid-download, the
                // resumable installer receives the same idempotent request and
                // the user does not have to wait hours or tap through setup.
                nextRequestRefresh = await refreshSetupRequestIfNeeded(
                    request,
                    body: body,
                    channel: channel,
                    nextRefresh: nextRequestRefresh)
                guard isCurrentSetup(
                    key: key,
                    requestID: request.requestID) else {
                    return
                }

                try await Task.sleep(for: .seconds(1))
            }
            if isCurrentSetup(key: key, requestID: request.requestID) {
                statesByHostKey[key] = .failed(
                    "Setup is taking longer than expected. Check the Mac host, then tap Retry.")
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSetup(key: key, requestID: request.requestID) else {
                return
            }
            statesByHostKey[key] = .failed(
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

    private func isCurrentSetup(
        key: HostAccountKey,
        requestID: String
    ) -> Bool {
        !Task.isCancelled
            && tasksByHostKey[key]?.requestID == requestID
    }

    private func cancelAllSetups() {
        tasksByHostKey.values.forEach { $0.task.cancel() }
        tasksByHostKey.removeAll()
        statesByHostKey.removeAll()
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
    case pairingLocal
    case retryLocalPairing(String)
    case setup
    case progress(ComputerUseSetupProgress)
    case useAI
    case retry(String)

    static func resolve(
        host: LocalHostAdvertisement,
        state: ComputerUseSetupCoordinator.State,
        localPromptReady: Bool
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
            guard localPromptReady else {
                return .unavailable(
                    "Secure local AI pairing is still finishing. Keep Remote Desktop Host open on the Mac and try again.")
            }
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
