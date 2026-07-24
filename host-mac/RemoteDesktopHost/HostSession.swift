import AppKit
import Combine
import Foundation
import os

/// Top-level state holder for the host agent. Owns the private session binding,
/// signaling client, capture, live WebRTC peer session, and input
/// injector; exposes a small enum state that the menu bar UI renders.
@MainActor
final class HostSession: ObservableObject {
    private static let cloudAccountRevalidationInterval: TimeInterval = 60
    private static let confirmedAccountGraceInterval: TimeInterval = 5 * 60

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

    private struct ActiveWebRTCPeer {
        let senderID: String
        let generation: UInt64
        let classification:
            HostComputerUseManager.WebRTCPeerClassification
    }

    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "session")
    private var signalingTask: Task<Void, Never>?
    private var peerSession: HostPeerSession?
    private var activeWebRTCPeer: ActiveWebRTCPeer?
    private var nextWebRTCPeerGeneration: UInt64 = 0
    private var pendingPeerCaptureTeardown: Task<Void, Never>?
    private let advertiser = BonjourAdvertiser()
    private let injector: InputInjector
    private let capture = ScreenCapture()
    private let permissionsProvider: PermissionsProvider
    private let validateAudioInputEntitlements: @Sendable () throws -> Void
    private let deviceIdentityProvider: @Sendable () -> String
    private let cloudAccountBindingProvider:
        @Sendable () async throws -> CloudKitAccountBinding
    private let signalingRunOverride: (@MainActor @Sendable (String) async -> Void)?
    private var pendingSignalingCleanupTasks: [Task<Void, Never>] = []
    private var pendingRemoteICEPayloads: [[String: String]] = []
    private var loggedPendingRemoteICE = false
    private var disconnecting = false
    private let iceConfigFetcher = ICEConfigFetcher(
        containerIdentifier: HostConfig.cloudKitContainerIdentifier)
    private let localCredentialStore = LocalComputerUseCredentialStore()
    private var localComputerUseServer: LocalComputerUseBrokerServer?
    private var localComputerUseChannel: LocalHostComputerUseChannel?
    /// Set by every CloudKit account-change notification, including ones that
    /// arrive while idle or while another disconnect is unwinding. Until a
    /// positive current-user lookup succeeds, a cached binding must not bring
    /// the previous account's LAN credential back online.
    private(set) var requiresFreshCloudAccountResolution = true
    private var lastPositiveCloudAccountResolutionAt: Date?
    private var lastPositivelyResolvedCloudAccountBinding:
        CloudKitAccountBinding?

    init(
        permissionsProvider: PermissionsProvider = SystemPermissionsProvider(),
        validateAudioInputEntitlements: @escaping @Sendable () throws -> Void = {
            try AudioInputEntitlements.validateIfNeeded()
        },
        deviceIdentityProvider: @escaping @Sendable () -> String = {
            DeviceIdentity.get()
        },
        cloudAccountBindingProvider: @escaping @Sendable () async throws
            -> CloudKitAccountBinding = {
                try await CloudKitAccountBinding.current(
                    containerIdentifier: HostConfig.cloudKitContainerIdentifier)
            },
        computerUseExecutor: (any ComputerUseExecuting)? = nil,
        computerUseManager: HostComputerUseManager? = nil,
        allowsExternalComputerUseServices: Bool =
            !HostRuntimeContext.isRunningUnitTests,
        signalingRunOverride: (@MainActor @Sendable (String) async -> Void)? = nil
    ) {
        let injector = InputInjector()
        self.injector = injector
        self.computerUse = computerUseManager ?? HostComputerUseManager(
            injector: injector,
            executor: computerUseExecutor,
            allowsExternalServices: allowsExternalComputerUseServices)
        self.permissionsProvider = permissionsProvider
        self.validateAudioInputEntitlements = validateAudioInputEntitlements
        self.deviceIdentityProvider = deviceIdentityProvider
        self.cloudAccountBindingProvider = cloudAccountBindingProvider
        self.signalingRunOverride = signalingRunOverride
    }

    private var allowsLocalCredentialAccess: Bool {
        !HostRuntimeContext.isRunningUnitTests
    }

    /// Resolves the private CloudKit owner before exposing the LAN broker. A
    /// confirmed account switch rotates that account's credential so a device
    /// enrolled before the switch cannot retain access. Short network/account
    /// lookup outages may reuse only the last device-local confirmed binding;
    /// an explicit sign-out or restricted account always fails closed.
    private func resolveLocalComputerUseIdentity() async
        -> (binding: CloudKitAccountBinding,
            credential: LocalComputerUseCredential)? {
        guard allowsLocalCredentialAccess else { return nil }

        var positivelyResolvedThisAttempt = false
        do {
            let current = try await cloudAccountBindingProvider()
            guard !Task.isCancelled else { return nil }
            positivelyResolvedThisAttempt = true
            lastPositiveCloudAccountResolutionAt = Date()
            lastPositivelyResolvedCloudAccountBinding = current

            let confirmed: CloudKitAccountBinding?
            do {
                confirmed = try localCredentialStore
                    .confirmedAccountBinding()
            } catch LocalComputerUseCredentialError
                .malformedStoredAccountBinding {
                // A positive current-user lookup is authoritative. Repair a
                // corrupted marker and rotate so no credential whose owner is
                // now unknowable survives the repair.
                try? localCredentialStore.clearConfirmedAccountBinding()
                confirmed = nil
            }
            let credential: LocalComputerUseCredential
            if Self.shouldRotateHostCredential(
                confirmedBinding: confirmed,
                currentBinding: current
            ) {
                credential = try localCredentialStore.rotateHostCredential(
                    accountBinding: current)
            } else {
                credential = try localCredentialStore.hostCredential(
                    accountBinding: current)
            }
            try localCredentialStore.setConfirmedAccountBinding(current)
            requiresFreshCloudAccountResolution = false
            return (current, credential)
        } catch let resolution as CloudKitAccountBindingResolutionError {
            guard Self.shouldReuseConfirmedAccountBinding(
                after: resolution,
                requiresFreshResolution:
                    requiresFreshCloudAccountResolution,
                lastPositiveResolution:
                    lastPositiveCloudAccountResolutionAt
            ) else {
                if !resolution.preservesConfirmedBinding {
                    try? localCredentialStore.clearConfirmedAccountBinding()
                    lastPositiveCloudAccountResolutionAt = nil
                    lastPositivelyResolvedCloudAccountBinding = nil
                }
                log.info(
                    "local AI disabled because no usable Apple Account is confirmed")
                return nil
            }
            do {
                guard let confirmed = try localCredentialStore
                    .confirmedAccountBinding() else {
                    return nil
                }
                let credential = try localCredentialStore.hostCredential(
                    accountBinding: confirmed)
                lastPositivelyResolvedCloudAccountBinding = confirmed
                log.info(
                    "temporarily using the last confirmed Apple Account binding for local AI")
                return (confirmed, credential)
            } catch {
                log.error(
                    "last confirmed local AI identity could not be loaded: \(String(describing: error), privacy: .public)")
                return nil
            }
        } catch {
            if !positivelyResolvedThisAttempt {
                lastPositiveCloudAccountResolutionAt = nil
                lastPositivelyResolvedCloudAccountBinding = nil
            }
            log.error(
                "Apple Account identity could not be resolved for local AI: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Transient CloudKit failures may preserve an established session during
    /// ordinary network loss. They may not preserve it after CloudKit has told
    /// us the account context changed: only a new positive owner lookup can
    /// clear that fail-closed boundary.
    static func shouldReuseConfirmedAccountBinding(
        after resolution: CloudKitAccountBindingResolutionError,
        requiresFreshResolution: Bool,
        lastPositiveResolution: Date?,
        now: Date = Date()
    ) -> Bool {
        resolution.preservesConfirmedBinding
            && canReusePositivelyResolvedCloudAccountBinding(
                requiresFreshResolution: requiresFreshResolution,
                lastPositiveResolution: lastPositiveResolution,
                now: now)
    }

    /// Applies the same bounded, in-process trust rule to every cached account
    /// binding, including the fallback after a successful signaling claim.
    /// A claim authenticates the signaling record; it does not prove that the
    /// Apple Account which previously owned this process is still current.
    static func canReusePositivelyResolvedCloudAccountBinding(
        requiresFreshResolution: Bool,
        lastPositiveResolution: Date?,
        now: Date = Date()
    ) -> Bool {
        guard !requiresFreshResolution,
              let lastPositiveResolution else {
            return false
        }
        let age = now.timeIntervalSince(lastPositiveResolution)
        return age >= 0 && age <= confirmedAccountGraceInterval
    }

    static func shouldRotateHostCredential(
        confirmedBinding: CloudKitAccountBinding?,
        currentBinding: CloudKitAccountBinding
    ) -> Bool {
        confirmedBinding != currentBinding
    }

    /// Periodic defense for a missed or delayed CKAccountChanged notification.
    /// A short transient outage may continue only inside the bounded trust
    /// window established by a positive lookup in this process.
    private func activeCloudAccountStillMatches(
        _ expected: CloudKitAccountBinding
    ) async -> Bool {
        do {
            let current = try await cloudAccountBindingProvider()
            guard !Task.isCancelled else { return false }
            guard current == expected else {
                log.info("local AI account continuity check found a different owner")
                return false
            }
            lastPositiveCloudAccountResolutionAt = Date()
            lastPositivelyResolvedCloudAccountBinding = current
            return true
        } catch let resolution as CloudKitAccountBindingResolutionError {
            if Self.shouldReuseConfirmedAccountBinding(
                after: resolution,
                requiresFreshResolution:
                    requiresFreshCloudAccountResolution,
                lastPositiveResolution:
                    lastPositiveCloudAccountResolutionAt
            ) {
                log.debug("local AI account continuity check is temporarily unavailable")
                return true
            }
            if !resolution.preservesConfirmedBinding {
                try? localCredentialStore.clearConfirmedAccountBinding()
            }
            return false
        } catch {
            log.error(
                "local AI account continuity check failed closed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Tears down an authenticated generation immediately and serializes a
    /// fresh start behind its bounded CloudKit/task cleanup.
    private func restartAfterCloudAccountInvalidation(reason: String) {
        requiresFreshCloudAccountResolution = true
        lastPositiveCloudAccountResolutionAt = nil
        lastPositivelyResolvedCloudAccountBinding = nil
        guard state != .idle else { return }
        guard !disconnecting else { return }
        log.info("Apple Account trust changed — restarting authenticated listeners")
        let transportTeardown = computerUse.stop()
        pendingSignalingCleanupTasks.append(
            stageConnectionShutdown(
                after: transportTeardown,
                reason: reason,
                closeTransportsImmediately: true))
        startListening()
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
        // The native TCC prompt already offers the appropriate route into
        // System Settings. Forcing Settings open here stacks two permission
        // surfaces and even overrides a deliberate denial. Setup exposes a
        // separate explicit Settings button for the retry/fallback case.
        refreshPermissions()
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
    /// Validates permissions, generates a new private session binding, and kicks
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
        let transportTeardown = computerUse.stop()
        pendingSignalingCleanupTasks.append(
            stageConnectionShutdown(after: transportTeardown))
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
        let transportTeardown = computerUse.stop()
        signalingTasks.append(
            stageConnectionShutdown(after: transportTeardown))
        state = .idle
        for signalingTask in signalingTasks {
            await signalingTask.value
        }
        await computerUse.shutdown()
        await capture.stop()
    }

    /// Detaches the live connection generation synchronously so an immediate
    /// restart can serialize behind it, while retaining the actual listener
    /// and peer until Computer Use has delivered its terminal/ready sequence
    /// and stopped channel polling. The returned task also joins the canceled
    /// signaling run, preserving the stable CloudKit-record cleanup barrier.
    private func stageConnectionShutdown(
        after computerUseTeardown: Task<Void, Never>,
        reason: String = "user",
        closeTransportsImmediately: Bool = false
    ) -> Task<Void, Never> {
        let stoppedSignalingTask = signalingTask
        signalingTask = nil
        let stoppedLocalServer = localComputerUseServer
        localComputerUseServer = nil
        localComputerUseChannel = nil
        let stoppedPeerSession = peerSession
        peerSession = nil
        activeWebRTCPeer = nil
        disconnecting = true
        advertiser.stop()
        resetPendingRemoteICE()

        let immediatePeerCaptureTeardown: Task<Void, Never>?
        if closeTransportsImmediately {
            // Account identity is an authentication boundary. Close every
            // ingress path synchronously rather than keeping the old account's
            // listener alive while best-effort terminal delivery unwinds.
            stoppedSignalingTask?.cancel()
            stoppedLocalServer?.stop()
            immediatePeerCaptureTeardown = stoppedPeerSession?.close(
                reason: reason)
        } else {
            immediatePeerCaptureTeardown = nil
        }

        return Task { @MainActor [weak self] in
            await computerUseTeardown.value
            let peerCaptureTeardown: Task<Void, Never>?
            if !closeTransportsImmediately {
                stoppedSignalingTask?.cancel()
                stoppedLocalServer?.stop()
                peerCaptureTeardown = stoppedPeerSession?.close(
                    reason: reason)
            } else {
                peerCaptureTeardown = immediatePeerCaptureTeardown
            }
            await peerCaptureTeardown?.value
            await stoppedSignalingTask?.value
            self?.disconnecting = false
        }
    }

    // MARK: - Session lifecycle

    private func run(code: String) async {
        // `start()` deliberately launches this work asynchronously. If the
        // session was stopped before the task received its first turn, do not
        // touch the Keychain or create any external signaling state.
        guard !Task.isCancelled else { return }
        resetPendingRemoteICE()
        let senderID = deviceIdentityProvider()
        guard !senderID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            log.error("refusing to advertise without a stable device identity")
            state = .error(
                "This Mac could not create a secure device identity. Quit and reopen Remote Desktop Host, then try again.")
            return
        }
        guard !Task.isCancelled else { return }
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let claimedComputerUseCapability = computerUse.capability
        let localChannel = LocalHostComputerUseChannel(
            hostID: senderID,
            pairingCode: code)
        var activeLocalServer: LocalComputerUseBrokerServer?
        var localPort: Int32 = 9
        var localCredentialID: String?
        var localCredential: LocalComputerUseCredential?
        var localAccountBinding: CloudKitAccountBinding?

        if let localIdentity = await resolveLocalComputerUseIdentity() {
            let credential = localIdentity.credential
            localCredential = credential
            localAccountBinding = localIdentity.binding
            let server = LocalComputerUseBrokerServer(
                credential: credential,
                hostID: senderID,
                channel: localChannel,
                authorizePeer: { [weak computerUse] senderID in
                    computerUse?.authorizeLocalPeer(senderID: senderID) ?? false
                },
                revokePeer: { [weak computerUse] senderID in
                    computerUse?.revokeLocalPeerAuthorization(
                        senderID: senderID)
                })
            do {
                localPort = Int32(try await server.start())
                activeLocalServer = server
                localComputerUseServer = server
                localComputerUseChannel = localChannel
                localCredentialID = credential.credentialID
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    return
                }
                log.error(
                    "local AI listener failed: \(String(describing: error), privacy: .public)")
            }
        }
        defer {
            activeLocalServer?.stop()
            if let activeLocalServer,
               localComputerUseServer === activeLocalServer {
                localComputerUseServer = nil
                localComputerUseChannel = nil
            }
        }

        if activeLocalServer != nil {
            // Begin with LAN only. CloudKit signaling may be unavailable or
            // signed out; its computer-use poller is added nondestructively
            // only after the matching signaling advertisement is claimed.
            computerUse.start(
                pairingCode: code,
                additionalChannels: [localChannel],
                includeDefaultChannel: false,
                forceMultiplex: true)
        }
        let publishedComputerUseCapability = computerUse.capability
        state = .advertising(code: code)
        advertiser.publish(
            hostname: hostName,
            code: code,
            senderID: senderID,
            computerUseCapability: publishedComputerUseCapability,
            port: localPort,
            localCredentialID: localCredentialID)
        log.info(
            "advertising host localAI=\(activeLocalServer != nil, privacy: .public)")

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
            // Cloud signaling is an optional remote-control fallback. Keep
            // the authenticated local prompt broker and Bonjour capability
            // alive when the Mac is offline or signed out of iCloud.
            if activeLocalServer != nil {
                guard let localAccountBinding else {
                    advertiser.stop()
                    state = .error(
                        "The Apple Account could not be verified for automatic pairing.")
                    await stopComputerUseBeforeTransportClosure()
                    return
                }
                await maintainLocalOnlyAdvertisement(
                    senderID: senderID,
                    code: code,
                    initialCapability: publishedComputerUseCapability,
                    accountBinding: localAccountBinding)
                await stopComputerUseBeforeTransportClosure()
            } else {
                advertiser.stop()
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't start either local AI or iCloud signaling."
                state = .error(message)
            }
            return
        }

        // A CloudKit claim must never transition into a long-lived WebRTC or
        // LAN session without a positively resolved owner for this process.
        // Ordinarily the local credential resolution above already supplied
        // it; this fallback covers a local Keychain failure without weakening
        // the remote session's account-change fence.
        if localAccountBinding == nil {
            if let resolved = lastPositivelyResolvedCloudAccountBinding,
               Self.canReusePositivelyResolvedCloudAccountBinding(
                   requiresFreshResolution:
                       requiresFreshCloudAccountResolution,
                   lastPositiveResolution:
                       lastPositiveCloudAccountResolutionAt
               ) {
                localAccountBinding = resolved
            } else {
                do {
                    let resolved = try await cloudAccountBindingProvider()
                    guard !Task.isCancelled else { return }
                    localAccountBinding = resolved
                    lastPositivelyResolvedCloudAccountBinding = resolved
                    lastPositiveCloudAccountResolutionAt = Date()
                    requiresFreshCloudAccountResolution = false
                } catch {
                    advertiser.stop()
                    await client.cleanup()
                    state = .error(
                        "The Apple Account could not be verified for this session.")
                    return
                }
            }
        }

        if activeLocalServer != nil {
            computerUse.addDefaultChannel(pairingCode: code)
        } else {
            computerUse.start(pairingCode: code)
        }
        let automaticLocalPairing = localCredential.map { _ in
            CloudKitLocalComputerUsePairing(
                containerIdentifier: HostConfig.cloudKitContainerIdentifier,
                senderID: senderID)
        }

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
        var nextAccountRevalidation = Date().addingTimeInterval(
            Self.cloudAccountRevalidationInterval)

        while !Task.isCancelled {
            if Date() >= nextAccountRevalidation,
               let localAccountBinding {
                let accountStillMatches = await activeCloudAccountStillMatches(
                    localAccountBinding)
                guard accountStillMatches else {
                    restartAfterCloudAccountInvalidation(
                        reason: "cloud-account-revalidation-failed")
                    break
                }
                nextAccountRevalidation = Date().addingTimeInterval(
                    Self.cloudAccountRevalidationInterval)
            }

            let currentComputerUseCapability = computerUse.capability
            if case .advertising = state,
               currentComputerUseCapability != bonjourComputerUseCapability {
                if advertiser.update(
                    senderID: senderID,
                    computerUseCapability: currentComputerUseCapability) {
                    bonjourComputerUseCapability = currentComputerUseCapability
                    log.debug("refreshed nearby AI capability")
                } else {
                    log.error("nearby AI capability refresh failed")
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
                    log.debug("refreshed advertisement")
                } catch {
                    log.error("advertisement refresh failed: \(String(describing: error), privacy: .public)")
                    nextAdvertisementRefresh = Date().addingTimeInterval(30)
                }
            }

            if let automaticLocalPairing,
               let localCredential,
               let localAccountBinding {
                do {
                    let responses = try await automaticLocalPairing
                        .respondToRequests(
                            hostID: senderID,
                            pairingCode: code,
                            credential: localCredential,
                            accountBinding: localAccountBinding)
                    if responses > 0 {
                        log.info(
                            "automatically enrolled \(responses, privacy: .public) same-iCloud local AI device(s)")
                    }
                } catch {
                    if Task.isCancelled || Self.isCancellation(error) { break }
                    log.error(
                        "automatic local AI pairing poll failed: \(String(describing: error), privacy: .public)")
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
                    guard let offeredClassification = computerUse
                        .classifyWebRTCPeer(senderID: offerSenderID) else {
                        // If account-enrolled LAN Computer Use already has a
                        // correlated sender owner, no differently claimed
                        // signaling sender reaches screen capture, the data
                        // channel, or native input.
                        log.warning(
                            "ignored WebRTC offer that did not match the correlated control owner")
                        continue
                    }
                    guard await client.acceptOfferSenderID(offerSenderID) else {
                        log.warning("ignored offer from a second signaling sender")
                        continue
                    }
                    let clientName = env.payload["client"] ?? "iOS client"
                    if let sdp = env.payload["sdp"] {
                        if peerSession == nil {
                            // HostPeerSession shares one ScreenCapture. A
                            // replacement generation cannot install callbacks
                            // until the previous peer's stop has completed.
                            await pendingPeerCaptureTeardown?.value
                            guard computerUse.classifyWebRTCPeer(
                                senderID: offerSenderID)
                                    == offeredClassification else {
                                log.warning(
                                    "WebRTC ownership changed before capture could start")
                                continue
                            }
                            nextWebRTCPeerGeneration &+= 1
                            if nextWebRTCPeerGeneration == 0 {
                                nextWebRTCPeerGeneration = 1
                            }
                            let generation = nextWebRTCPeerGeneration
                            guard computerUse.activateWebRTCPeer(
                                senderID: offerSenderID,
                                generation: generation,
                                classification: offeredClassification) else {
                                log.warning(
                                    "WebRTC offer lost its authenticated owner before capture")
                                continue
                            }
                            activeWebRTCPeer = ActiveWebRTCPeer(
                                senderID: offerSenderID,
                                generation: generation,
                                classification: offeredClassification)
                            let computerUse = computerUse
                            peerSession = HostPeerSession(
                                signaling: client,
                                capture: capture,
                                injector: injector,
                                iceConfig: iceConfig,
                                audioEnabled: permissions.audioEnabled,
                                peerSenderID: offerSenderID,
                                onUserInput: { [weak computerUse] in
                                    if computerUse?.blockActionsForUserIntervention() == true {
                                        Task { @MainActor [weak computerUse] in
                                            computerUse?.userIntervened()
                                        }
                                    }
                                },
                                onPeerAuthorizationChanged: { [weak self, weak computerUse] update in
                                    guard let computerUse else { return }
                                    let epoch = computerUse.nextPeerAuthorizationEpoch()
                                    if !update.authorized {
                                        // Close the injection gate before
                                        // crossing to MainActor only when this
                                        // exact WebRTC peer owns that source.
                                        // A rejected second peer must not
                                        // interrupt the active LAN owner.
                                        _ = computerUse
                                            .blockActionsForWebRTCDeauthorization(
                                                senderID: update.senderID,
                                                generation: generation)
                                    }
                                    Task { @MainActor [weak self] in
                                        self?.applyPeerAuthorization(
                                            update,
                                            generation: generation,
                                            epoch: epoch)
                                    }
                                },
                                onEnded: { [weak self] reason in
                                    Task { @MainActor in
                                        self?.handlePeerEnded(
                                            reason: reason,
                                            senderID: offerSenderID,
                                            generation: generation,
                                            classification:
                                                offeredClassification)
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
                            if let activeWebRTCPeer,
                               activeWebRTCPeer.senderID == offerSenderID,
                               activeWebRTCPeer.classification
                                == .localComputerUseSidecar {
                                handlePeerEnded(
                                    reason: "error",
                                    senderID: offerSenderID,
                                    generation:
                                        activeWebRTCPeer.generation,
                                    classification:
                                        activeWebRTCPeer.classification)
                                continue
                            }
                            state = .error("Couldn't start the WebRTC session.")
                            advertiser.stop()
                            await stopComputerUseBeforeTransportClosure()
                            activeWebRTCPeer = nil
                            let captureTeardown = peerSession?.close(
                                reason: "error")
                            peerSession = nil
                            await captureTeardown?.value
                            resetPendingRemoteICE()
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
                            await stopComputerUseBeforeTransportClosure()
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
                    let reason = env.payload["reason"] ?? "user"
                    if let activeWebRTCPeer,
                       activeWebRTCPeer.classification
                        == .localComputerUseSidecar {
                        log.info(
                            "local Computer Use visual sidecar said bye; preserving the LAN task channel")
                        handlePeerEnded(
                            reason: reason,
                            senderID: activeWebRTCPeer.senderID,
                            generation: activeWebRTCPeer.generation,
                            classification:
                                activeWebRTCPeer.classification)
                        continue
                    }
                    log.info("client said bye — will restart listening")
                    advertiser.stop()
                    await stopComputerUseBeforeTransportClosure()
                    activeWebRTCPeer = nil
                    let captureTeardown = peerSession?.close(reason: reason)
                    peerSession = nil
                    await captureTeardown?.value
                    resetPendingRemoteICE()
                    await client.cleanup()
                    handleDisconnect(reason: reason)
                    return
                }
            }
            // CloudKit is short-poll (2 s cadence), not long-poll.
            try? await Task.sleep(for: .seconds(2))
        }
        resetPendingRemoteICE()
        await stopComputerUseBeforeTransportClosure()
        await client.cleanup()
    }

    /// `run` owns the local listener in a `defer`, so every terminal return
    /// must join Computer Use delivery before unwinding that listener. This is
    /// the async counterpart to `stageConnectionShutdown`, used when the
    /// signaling task itself is the code that discovered the terminal edge.
    private func stopComputerUseBeforeTransportClosure() async {
        let teardown = computerUse.stop()
        await teardown.value
    }

    /// Keeps the LAN product path healthy without making CloudKit account or
    /// internet availability a prerequisite. The model capability can change
    /// while installing or executing, so refresh the existing TXT record in
    /// place exactly as the CloudKit-backed loop does.
    private func maintainLocalOnlyAdvertisement(
        senderID: String,
        code: String,
        initialCapability: ComputerUseCapability,
        accountBinding: CloudKitAccountBinding
    ) async {
        var publishedCapability = initialCapability
        var nextAccountRevalidation = Date().addingTimeInterval(
            Self.cloudAccountRevalidationInterval)
        while !Task.isCancelled {
            if Date() >= nextAccountRevalidation {
                let accountStillMatches = await activeCloudAccountStillMatches(
                    accountBinding)
                guard accountStillMatches else {
                    restartAfterCloudAccountInvalidation(
                        reason: "local-account-revalidation-failed")
                    return
                }
                nextAccountRevalidation = Date().addingTimeInterval(
                    Self.cloudAccountRevalidationInterval)
            }
            let current = computerUse.capability
            if case .advertising = state,
               current != publishedCapability {
                if advertiser.update(
                    senderID: senderID,
                    computerUseCapability: current) {
                    publishedCapability = current
                } else {
                    log.error("nearby-only AI capability refresh failed")
                }
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    /// Separates loss of optional visual media from loss of the primary
    /// session. The sidecar owns neither the TLS broker nor its task channel,
    /// so it creates a resumable intervention boundary and leaves the private
    /// routing generation in place. Primary WebRTC retains the established
    /// full-disconnect behavior.
    private func handlePeerEnded(
        reason: String,
        senderID: String,
        generation: UInt64,
        classification:
            HostComputerUseManager.WebRTCPeerClassification
    ) {
        guard let activeWebRTCPeer,
              activeWebRTCPeer.senderID == senderID,
              activeWebRTCPeer.generation == generation,
              activeWebRTCPeer.classification == classification else {
            log.info(
                "ignored callback from an inactive WebRTC generation")
            return
        }

        guard classification == .localComputerUseSidecar else {
            handleDisconnect(reason: reason)
            return
        }

        let stoppedPeerSession = peerSession
        peerSession = nil
        self.activeWebRTCPeer = nil
        resetPendingRemoteICE()
        _ = computerUse.endWebRTCPeer(
            senderID: senderID,
            generation: generation,
            classification: classification)
        guard let captureTeardown = stoppedPeerSession?.close(
            reason: reason) else {
            return
        }
        let previousTeardown = pendingPeerCaptureTeardown
        pendingPeerCaptureTeardown = Task {
            await previousTeardown?.value
            await captureTeardown.value
        }
        log.info(
            "local Computer Use visual sidecar ended; LAN task transport remains active")
    }

    /// Called when a peer session disconnects for any reason (WebRTC
    /// state change, client bye, etc.). Tears down the current peer
    /// session and immediately begins listening again with a fresh private
    /// session binding.
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
        // A terminal peer failure is not a resumable pause. Persist and send
        // the terminal Computer Use result while the old task channel is still
        // available, before replacing the pairing/signaling transport.
        let transportTeardown = computerUse.stop()
        pendingSignalingCleanupTasks.append(
            stageConnectionShutdown(
                after: transportTeardown,
                reason: reason))
        startListening()
    }

    /// CloudKit posts this notification for sign-in, sign-out, and account
    /// replacement. Restarting forces a fresh account resolution before the
    /// LAN listener is exposed again; the notification itself is never trusted
    /// as proof of which account is active.
    func handleCloudAccountChanged() {
        // The helper latches invalidation before lifecycle guards, so a
        // notification delivered while idle or during another disconnect
        // still blocks cached fallback on the next run.
        restartAfterCloudAccountInvalidation(
            reason: "cloud-account-changed")
    }

    /// MainActor bridge from the authenticated WebRTC hello into the
    /// CloudKit-backed Computer Use control plane. Ordinary remote-control
    /// authorization remains independent from the ordered-controls feature.
    func applyPeerAuthorization(
        _ update: HostPeerSession.PeerAuthorization,
        generation: UInt64,
        epoch: UInt64
    ) {
        guard let activeWebRTCPeer,
              activeWebRTCPeer.senderID == update.senderID,
              activeWebRTCPeer.generation == generation else {
            return
        }
        computerUse.applyPeerAuthorization(
            senderID: update.senderID,
            authorized: update.authorized,
            supportsOrderedComputerUseControls:
                update.supportsOrderedComputerUseControls,
            peerGeneration: generation,
            epoch: epoch)
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
            "version": HostConfig.appVersion,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "audio": permissions.audioEnabled ? "true" : "false",
            "monitors": "\(NSScreen.screens.count)",
            "displayWidth": "\(Int(frame.width.rounded()))",
            "displayHeight": "\(Int(frame.height.rounded()))",
            "displayScale": String(format: "%.2f", scale),
            "orderedComputerUseControls":
                "\(HostConfig.orderedComputerUseControlsVersion)",
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
