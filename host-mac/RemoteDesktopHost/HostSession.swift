import AppKit
import Combine
import Foundation
import os

/// Top-level state holder for the host agent. Owns the pairing code,
/// signaling client, capture, live WebRTC peer session, and input
/// injector; exposes a small enum state that the menu bar UI renders.
@MainActor
final class HostSession: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case advertising(code: String)
        case paired(clientDescription: String)
        case error(String)
    }

    struct Permissions: Equatable {
        var screenRecording = false
        var accessibility = false
        var microphone = false

        /// Screen viewing and remote input are the two capabilities required
        /// to run the host. Audio is deliberately independent so declining the
        /// microphone prompt never disables video or control.
        var coreReady: Bool {
            screenRecording && accessibility
        }

        var ok: Bool {
            coreReady
        }

        var audioEnabled: Bool {
            HostConfig.enableSystemAudio && microphone
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var permissions = Permissions()
    @Published private(set) var optionalAudioError: String?
    let computerUse: HostComputerUseManager

    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "session")
    private var signalingTask: Task<Void, Never>?
    private var peerSession: HostPeerSession?
    private let advertiser = BonjourAdvertiser()
    private let injector: InputInjector
    private let capture = ScreenCapture()
    private let permissionsProvider: PermissionsProvider
    private let validateAudioInputEntitlements: @Sendable () throws -> Void
    private let deviceIdentityProvider: @Sendable () -> String
    private let signalingRunOverride: (@MainActor @Sendable (String) async -> Void)?
    private var pendingSignalingCleanupTasks: [Task<Void, Never>] = []
    private var pendingRemoteICEPayloads: [[String: String]] = []
    private var loggedPendingRemoteICE = false
    private var disconnecting = false
    private let iceConfigFetcher = ICEConfigFetcher(
        containerIdentifier: HostConfig.cloudKitContainerIdentifier)

    init(
        permissionsProvider: PermissionsProvider = SystemPermissionsProvider(),
        validateAudioInputEntitlements: @escaping @Sendable () throws -> Void = {
            try AudioInputEntitlements.validateIfNeeded()
        },
        deviceIdentityProvider: @escaping @Sendable () -> String = {
            DeviceIdentity.get()
        },
        computerUseExecutor: (any ComputerUseExecuting)? = nil,
        allowsExternalComputerUseServices: Bool =
            !HostRuntimeContext.isRunningUnitTests,
        signalingRunOverride: (@MainActor @Sendable (String) async -> Void)? = nil
    ) {
        let injector = InputInjector()
        self.injector = injector
        self.computerUse = HostComputerUseManager(
            injector: injector,
            executor: computerUseExecutor,
            allowsExternalServices: allowsExternalComputerUseServices)
        self.permissionsProvider = permissionsProvider
        self.validateAudioInputEntitlements = validateAudioInputEntitlements
        self.deviceIdentityProvider = deviceIdentityProvider
        self.signalingRunOverride = signalingRunOverride
    }

    /// Re-read permission state from the provider. Must be called
    /// whenever the user might have returned from System Settings —
    /// `AppDelegate` does this on `didBecomeActive` and on popover
    /// show, and users can also force it via the "Check again" button.
    func refreshPermissions() {
        permissions = Permissions(
            screenRecording: permissionsProvider.screenRecordingGranted(),
            accessibility: permissionsProvider.accessibilityGranted(),
            microphone: permissionsProvider.microphoneGranted())
        if permissions.audioEnabled {
            optionalAudioError = nil
        }
    }

    func requestPermissions() {
        permissionsProvider.requestPrompts()
        refreshPermissions()
    }

    func grantNextPermission() {
        refreshPermissions()
        guard let permission = nextMissingCorePermission else { return }
        requestCorePermission(permission)
    }

    func requestCorePermission(_ permission: PermissionKind) {
        guard permission != .microphone else { return }
        permissionsProvider.requestPrompt(for: permission)
        permissionsProvider.openSystemSettings(for: permission)
    }

    func requestOptionalAudioPermission() {
        refreshPermissions()
        guard HostConfig.enableSystemAudio, !permissions.microphone else { return }
        if let message = optionalAudioBuildIssueMessage {
            optionalAudioError = message
            return
        }

        optionalAudioError = nil

        permissionsProvider.requestMicrophoneAccess { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                guard !self.permissions.microphone else { return }
                self.permissionsProvider.openSystemSettings(for: .microphone)
            }
        }
    }

    func openSystemSettings(for permission: PermissionKind) {
        permissionsProvider.openSystemSettings(for: permission)
    }

    func openSystemSettingsForNextMissingPermission() {
        refreshPermissions()
        if let permission = nextMissingCorePermission {
            permissionsProvider.openSystemSettings(for: permission)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard case .idle = state else {
            if case .error = state {
                startListening()
            }
            return
        }
        startListening()
    }

    /// Internal entry point shared by `start()` and auto-restart.
    /// Validates permissions, generates a new pairing code, and kicks
    /// off the signaling run-loop.
    private func startListening() {
        refreshPermissions()
        computerUse.refreshModelState()
        guard permissions.ok else {
            state = .error(requiredPermissionsMessage)
            return
        }

        let code = Self.newPairingCode()
        // A stopped or disconnected run can still be deleting this Mac's
        // stable advertisement. Serialize the replacement behind every such
        // predecessor instead of relying on cancellation to finish promptly.
        var predecessorTasks = pendingSignalingCleanupTasks
        pendingSignalingCleanupTasks.removeAll()
        if let signalingTask {
            signalingTask.cancel()
            predecessorTasks.append(signalingTask)
        }
        signalingTask = nil
        advertiser.stop()
        resetPendingRemoteICE()
        state = .starting
        signalingTask = Task {
            for predecessorTask in predecessorTasks {
                await predecessorTask.value
            }
            guard !Task.isCancelled else { return }
            if let signalingRunOverride {
                await signalingRunOverride(code)
            } else {
                await run(code: code)
            }
        }
    }

    func stop() {
        if let canceledSignalingTask = stopConnections() {
            pendingSignalingCleanupTasks.append(canceledSignalingTask)
        }
        computerUse.stop()
        Task { await capture.stop() }
        state = .idle
    }

    /// AppKit uses this awaited path before process termination so the
    /// multi-gigabyte local model cannot outlive its owning host process.
    func shutdown() async {
        // Keep every task we cancelled alive until its final CloudKit cleanup
        // has completed. The host advertisement has a stable record
        // name per Mac, so launching a replacement before this returns lets
        // the old run delete the replacement run's freshly written record.
        var signalingTasks = pendingSignalingCleanupTasks
        pendingSignalingCleanupTasks.removeAll()
        if let canceledSignalingTask = stopConnections() {
            signalingTasks.append(canceledSignalingTask)
        }
        state = .idle
        for signalingTask in signalingTasks {
            await signalingTask.value
        }
        await computerUse.shutdown()
        await capture.stop()
    }

    @discardableResult
    private func stopConnections() -> Task<Void, Never>? {
        let canceledSignalingTask = signalingTask
        signalingTask = nil
        canceledSignalingTask?.cancel()
        advertiser.stop()
        peerSession?.close(reason: "user")
        peerSession = nil
        resetPendingRemoteICE()
        return canceledSignalingTask
    }

    // MARK: - Session lifecycle

    private func run(code: String) async {
        // `start()` deliberately launches this work asynchronously. If the
        // session was stopped before the task received its first turn, do not
        // touch the Keychain or create any external signaling state.
        guard !Task.isCancelled else { return }
        resetPendingRemoteICE()
        let senderID = deviceIdentityProvider()
        guard !Task.isCancelled else { return }
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let claimedComputerUseCapability = computerUse.capability
        let client = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: code,
            role: .host,
            hostName: hostName,
            computerUseCapability: claimedComputerUseCapability,
            senderID: senderID)

        do {
            try await client.claim()
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                return
            }
            log.error("claim failed: \(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't reach iCloud. Check your network."
            state = .error(message)
            return
        }

        state = .advertising(code: code)
        computerUse.start(pairingCode: code)
        let publishedComputerUseCapability = computerUse.capability
        advertiser.publish(
            hostname: hostName,
            code: code,
            senderID: senderID,
            computerUseCapability: publishedComputerUseCapability)
        log.info("advertising code=\(code, privacy: .public)")

        // Reset the cached ICE config so we get a fresh fetch,
        // important when the network topology changed (VPN, Wi-Fi handoff).
        await iceConfigFetcher.reset()
        let iceConfig = await iceConfigFetcher.get()

        let advertisementRefreshInterval = CloudKitSignalingClient
            .advertisementRefreshInterval()
        var nextAdvertisementRefresh = Date()
            .addingTimeInterval(advertisementRefreshInterval)
        var cloudKitComputerUseCapability = claimedComputerUseCapability
        var bonjourComputerUseCapability: ComputerUseCapability? =
            advertiser.publishedMetadata == nil ? nil : publishedComputerUseCapability

        while !Task.isCancelled {
            let currentComputerUseCapability = computerUse.capability
            if case .advertising = state,
               currentComputerUseCapability != bonjourComputerUseCapability {
                if advertiser.update(
                    senderID: senderID,
                    computerUseCapability: currentComputerUseCapability) {
                    bonjourComputerUseCapability = currentComputerUseCapability
                    log.debug("refreshed nearby AI capability code=\(code, privacy: .public)")
                } else {
                    log.error("nearby AI capability refresh failed code=\(code, privacy: .public)")
                }
            }

            let cloudKitCapabilityChanged = currentComputerUseCapability
                != cloudKitComputerUseCapability
            if case .advertising = state,
               Date() >= nextAdvertisementRefresh || cloudKitCapabilityChanged {
                do {
                    await client.setComputerUseCapability(currentComputerUseCapability)
                    try await client.refreshAdvertisement()
                    cloudKitComputerUseCapability = currentComputerUseCapability
                    nextAdvertisementRefresh = Date()
                        .addingTimeInterval(advertisementRefreshInterval)
                    log.debug("refreshed advertisement code=\(code, privacy: .public)")
                } catch {
                    log.error("advertisement refresh failed: \(String(describing: error), privacy: .public)")
                    nextAdvertisementRefresh = Date().addingTimeInterval(30)
                }
            }

            let envelopes: [SignalingEnvelope]
            do {
                envelopes = try await client.poll()
            } catch {
                if Task.isCancelled || Self.isCancellation(error) { break }
                log.error("poll failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            for env in envelopes {
                switch env.kind {
                case .offer:
                    guard let offerSenderID = env.senderID, !offerSenderID.isEmpty else {
                        continue
                    }
                    guard await client.acceptOfferSenderID(offerSenderID) else {
                        log.warning("ignored offer from a second signaling sender")
                        continue
                    }
                    let clientName = env.payload["client"] ?? "iOS client"
                    if let sdp = env.payload["sdp"] {
                        if peerSession == nil {
                            let computerUse = computerUse
                            peerSession = HostPeerSession(
                                signaling: client,
                                capture: capture,
                                injector: injector,
                                iceConfig: iceConfig,
                                audioEnabled: permissions.audioEnabled,
                                onUserInput: { [weak computerUse] in
                                    if computerUse?.blockActionsForUserIntervention() == true {
                                        Task { @MainActor [weak computerUse] in
                                            computerUse?.userIntervened()
                                        }
                                    }
                                },
                                onPeerAuthorizationChanged: { [weak computerUse] authorized in
                                    guard let computerUse else { return }
                                    let epoch = computerUse.nextPeerAuthorizationEpoch()
                                    if !authorized {
                                        // Close the injection gate before
                                        // crossing to MainActor; disconnect
                                        // callbacks and model actions can race.
                                        _ = computerUse.blockActionsForUserIntervention()
                                    }
                                    Task { @MainActor [weak computerUse] in
                                        computerUse?.applyPeerAuthorization(
                                            senderID: offerSenderID,
                                            authorized: authorized,
                                            epoch: epoch)
                                    }
                                },
                                onEnded: { [weak self] reason in
                                    Task { @MainActor in
                                        self?.handleDisconnect(reason: reason)
                                    }
                                })
                        }
                        do {
                            try await peerSession?.acceptOffer(sdp: sdp)
                            flushPendingRemoteICEIfPossible()
                            advertiser.stop()
                            await client.stopAdvertising()
                            state = .paired(clientDescription: clientName)
                        } catch {
                            log.error("failed to accept WebRTC offer: \(String(describing: error), privacy: .public)")
                            state = .error("Couldn't start the WebRTC session.")
                            advertiser.stop()
                            peerSession?.close(reason: "error")
                            peerSession = nil
                            resetPendingRemoteICE()
                            computerUse.stop()
                            await client.cleanup()
                            return
                        }
                    } else {
                        log.info("received client preflight offer from \(clientName, privacy: .public)")
                        state = .paired(clientDescription: clientName)
                        let ack = SignalingEnvelope(
                            role: .host,
                            kind: .answer,
                            payload: hostMetadata(),
                            ts: Date().timeIntervalSince1970)
                        do {
                            try await client.send(ack)
                            advertiser.stop()
                            await client.stopAdvertising()
                        } catch {
                            log.error("failed to send preflight answer: \(String(describing: error), privacy: .public)")
                            state = .error("Client reached the host, but the host couldn't reply over signaling.")
                            advertiser.stop()
                            resetPendingRemoteICE()
                            computerUse.stop()
                            await client.cleanup()
                            return
                        }
                    }
                case .ice:
                    if let peerSession {
                        peerSession.addRemoteIce(env.payload)
                    } else {
                        bufferRemoteICE(env.payload)
                    }
                case .answer:
                    // Host doesn't receive answers.
                    log.warning("unexpected answer from client")
                case .bye:
                    log.info("client said bye — will restart listening")
                    advertiser.stop()
                    peerSession?.close(reason: env.payload["reason"] ?? "user")
                    peerSession = nil
                    resetPendingRemoteICE()
                    computerUse.stop()
                    await client.cleanup()
                    handleDisconnect(reason: env.payload["reason"] ?? "user")
                    return
                }
            }
            // CloudKit is short-poll (2 s cadence), not long-poll.
            try? await Task.sleep(for: .seconds(2))
        }
        resetPendingRemoteICE()
        computerUse.stop()
        await client.cleanup()
    }

    /// Called when a peer session disconnects for any reason (WebRTC
    /// state change, client bye, etc.). Tears down the current peer
    /// session and immediately begins listening again with a fresh
    /// pairing code.
    private func handleDisconnect(reason: String) {
        // If the user already called stop(), state is .idle and we
        // should not auto-restart.
        guard state != .idle else { return }
        // Guard against re-entrancy: both screen-capture-stop and
        // peer-connection-failure can fire onEnded nearly simultaneously.
        guard !disconnecting else {
            log.info("handleDisconnect re-entered (reason=\(reason, privacy: .public)) — skipping")
            return
        }
        disconnecting = true
        log.info("connection ended (\(reason, privacy: .public)) — restarting listener")
        peerSession?.close(reason: reason)
        peerSession = nil
        resetPendingRemoteICE()
        advertiser.stop()
        disconnecting = false
        startListening()
    }

    // MARK: -

    static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    func hostMetadata() -> [String: String] {
        let mainScreen = NSScreen.main
        let frame = mainScreen?.frame ?? .zero
        let scale = mainScreen?.backingScaleFactor ?? 2.0
        return [
            "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "app": "RemoteDesktop-Host",
            "version": "0.1.0",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "audio": permissions.audioEnabled ? "true" : "false",
            "monitors": "\(NSScreen.screens.count)",
            "displayWidth": "\(Int(frame.width.rounded()))",
            "displayHeight": "\(Int(frame.height.rounded()))",
            "displayScale": String(format: "%.2f", scale),
        ]
    }

    private var requiredPermissionsMessage: String {
        return "Grant Screen Recording and Accessibility in System Settings, then press Check again."
    }

    private var optionalAudioBuildIssueMessage: String? {
        guard HostConfig.enableSystemAudio, !permissions.microphone else { return nil }
        do {
            try validateAudioInputEntitlements()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var nextMissingCorePermission: PermissionKind? {
        if !permissions.screenRecording {
            return .screenRecording
        }
        if !permissions.accessibility {
            return .accessibility
        }
        return nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func bufferRemoteICE(_ payload: [String: String]) {
        pendingRemoteICEPayloads.append(payload)
        if !loggedPendingRemoteICE {
            loggedPendingRemoteICE = true
            log.info("buffering remote ICE candidate until the WebRTC offer is accepted")
        }
    }

    private func flushPendingRemoteICEIfPossible() {
        guard let peerSession, !pendingRemoteICEPayloads.isEmpty else { return }
        let bufferedPayloads = pendingRemoteICEPayloads
        resetPendingRemoteICE()
        for payload in bufferedPayloads {
            peerSession.addRemoteIce(payload)
        }
    }

    private func resetPendingRemoteICE() {
        pendingRemoteICEPayloads.removeAll()
        loggedPendingRemoteICE = false
    }
}
