import Combine
import CloudKit
import Foundation
import LiveKitWebRTC

/// Status of the optional screen/input companion for an authenticated local
/// AI session. The TLS prompt/result channel is intentionally not represented
/// here: it is authoritative and can remain ready in every one of these
/// states.
enum ComputerUseVisualSidecarState: Equatable {
    case unavailable
    case connecting
    case waitingForFreshFrame
    case live
    case failed
}

/// Top-level state holder for the client. Owns the `Transport`, tracks
/// lifecycle, and fans input events out as `ControlMessage`s.
@MainActor
final class SessionModel: ObservableObject {
    typealias LocalAccountBindingValidator = @Sendable (
        _ expected: CloudKitAccountBinding
    ) async throws -> Void
    typealias LocalComputerUseChannelConnector = @Sendable (
        _ endpoint: LocalComputerUseEndpoint,
        _ credentialID: String,
        _ hostID: String,
        _ pairingCode: String,
        _ sessionID: String,
        _ senderID: String,
        _ accountBinding: CloudKitAccountBinding
    ) async throws -> any ComputerUseSessionChannel

    enum Experience: Equatable {
        case remoteControl
        case computerUse
    }

    enum ComputerUseConnectionMode: Equatable {
        /// Ordinary remote-control WebRTC session. Computer Use never sends
        /// prompts through this path.
        case liveScreen
        /// TLS-authenticated LAN prompt/result channel. The host still owns
        /// execution, approvals, and policy. A separately fenced WebRTC
        /// sidecar may add live pixels and direct input, but never carries AI
        /// prompts, progress, approvals, or results.
        case localPromptOnly
    }

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case ended(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hostName: String?
    @Published private(set) var display: DisplayInfo?
    @Published private(set) var hasReceivedVideoFrame = false
    @Published private(set) var softModifierMask: UInt16 = 0
    @Published var error: String?
    @Published private(set) var experience: Experience = .remoteControl
    @Published private(set) var computerUseSession: ComputerUseSessionModel?
    @Published private(set) var computerUseConnectionMode:
        ComputerUseConnectionMode = .liveScreen
    @Published private(set) var computerUseVisualSidecarState:
        ComputerUseVisualSidecarState = .unavailable
    @Published private(set) var isCloudAccountRevalidationPending = false

    var hasInteractiveRemoteScreen: Bool {
        guard !isCloudAccountRevalidationPending else { return false }
        guard experience == .computerUse,
              computerUseConnectionMode == .localPromptOnly else {
            return true
        }
        return computerUseVisualSidecarState == .live
    }

    var isComputerUsePromptTransportReady: Bool {
        guard state == .connected,
              !isCloudAccountRevalidationPending else { return false }
        switch computerUseConnectionMode {
        case .liveScreen:
            return hasReceivedVideoFrame
        case .localPromptOnly:
            return true
        }
    }

    private let transportFactory: @MainActor () -> Transport
    private let computerUseVisualTransportFactory:
        @MainActor () -> Transport
    private let localAccountBindingValidator: LocalAccountBindingValidator
    private let localComputerUseChannelConnector:
        LocalComputerUseChannelConnector
    private let localPendingStore: any ComputerUsePendingPromptStoring
    private let accountChangeNotificationCenter: NotificationCenter
    private var transport: Transport?
    private var computerUseVisualSidecar: ComputerUseVisualSidecar?
    private var localConnectionTask: Task<Void, Never>?
    private var accountChangeObserver: NSObjectProtocol?
    private var accountRevalidationTask: Task<Void, Never>?
    private var sessionAccountBinding: CloudKitAccountBinding?
    private var accountRevalidationGeneration: UInt64 = 0
    private var seq: UInt32 = 0

    init(
        transportFactory: @escaping @MainActor () -> Transport = {
            WebRTCTransport()
        },
        computerUseVisualTransportFactory:
            @escaping @MainActor () -> Transport = {
                WebRTCTransport(
                    mediaPolicy: .computerUseVisualSidecar)
            },
        localAccountBindingValidator: @escaping LocalAccountBindingValidator =
            { binding in
                try await LocalCloudAccountBindingPolicy.validate(binding)
            },
        localComputerUseChannelConnector:
            @escaping LocalComputerUseChannelConnector = {
                endpoint,
                credentialID,
                hostID,
                pairingCode,
                sessionID,
                senderID,
                accountBinding in
                guard let credential = LocalComputerUseCredentialStore()
                    .clientCredential(
                        hostID: hostID,
                        credentialID: credentialID,
                        accountBinding: accountBinding) else {
                    throw LocalComputerUseConnectionError
                        .automaticPairingIncomplete
                }
                let channel = LocalComputerUseBrokerClient(
                    endpoint: endpoint,
                    credential: credential,
                    pairingCode: pairingCode,
                    sessionID: sessionID,
                    senderID: senderID,
                    targetID: hostID)
                try await channel.handshake()
                return channel
            },
        localPendingStore: any ComputerUsePendingPromptStoring =
            ComputerUsePendingPromptStore.shared,
        accountChangeNotificationCenter: NotificationCenter = .default
    ) {
        self.transportFactory = transportFactory
        self.computerUseVisualTransportFactory =
            computerUseVisualTransportFactory
        self.localAccountBindingValidator = localAccountBindingValidator
        self.localComputerUseChannelConnector =
            localComputerUseChannelConnector
        self.localPendingStore = localPendingStore
        self.accountChangeNotificationCenter = accountChangeNotificationCenter
        accountChangeObserver = accountChangeNotificationCenter.addObserver(
            forName: NSNotification.Name.CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleCloudKitAccountChanged()
            }
        }
    }

    deinit {
        accountRevalidationTask?.cancel()
        if let accountChangeObserver {
            accountChangeNotificationCenter.removeObserver(
                accountChangeObserver)
        }
    }

    func connect(
        code: String,
        experience: Experience = .remoteControl,
        computerUseHostID: String? = nil,
        hostName: String = "Mac",
        localComputerUseEndpoint: LocalComputerUseEndpoint? = nil,
        localCredentialID: String? = nil,
        localCloudAccountBinding: CloudKitAccountBinding? = nil
    ) {
        guard state == .idle || {
            if case .ended = state { return true } else { return false }
        }() else { return }
        stopComputerUseVisualSidecar(preserveConfiguration: false)
        invalidateAccountRevalidation(clearBinding: true)
        state = .connecting
        error = nil
        hasReceivedVideoFrame = false
        self.experience = experience
        sessionAccountBinding = localCloudAccountBinding
        computerUseConnectionMode = .liveScreen

        if experience == .computerUse {
            guard let computerUseHostID, !computerUseHostID.isEmpty else {
                sessionAccountBinding = nil
                self.error = "AI Computer Use isn't available for this Mac yet. Wait a moment and try again."
                state = .idle
                return
            }
            guard let localComputerUseEndpoint,
                  localComputerUseEndpoint.isValid,
                  let localCredentialID,
                  LocalHostAdvertisement.isValidLocalCredentialID(
                    localCredentialID) else {
                sessionAccountBinding = nil
                self.error = "Secure local AI pairing is still finishing. Keep Remote Desktop Host open on the Mac and try again."
                state = .idle
                return
            }
            guard let localCloudAccountBinding else {
                sessionAccountBinding = nil
                self.error = "Sign into the same Apple Account on this device and the Mac so local AI can pair automatically."
                state = .idle
                return
            }
            connectLocalComputerUse(
                code: code,
                hostID: computerUseHostID,
                hostName: hostName,
                endpoint: localComputerUseEndpoint,
                credentialID: localCredentialID,
                accountBinding: localCloudAccountBinding)
            return
        } else {
            computerUseSession?.stop()
            computerUseSession = nil
        }

        let t = transportFactory()
        bind(t)
        transport = t

        Task { @MainActor in
            do {
                try await t.connect(
                    pairingCode: code,
                    expectedHostID: computerUseHostID)
            } catch {
                guard self.state == .connecting else { return }
                self.computerUseSession?.stop()
                self.computerUseSession = nil
                self.transport = nil
                self.sessionAccountBinding = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't connect: \(error.localizedDescription)"
                self.state = .idle
            }
        }
    }

    func send(_ message: ControlMessage) {
        guard !isCloudAccountRevalidationPending else { return }
        if experience == .computerUse,
           computerUseConnectionMode == .localPromptOnly {
            // Only fresh-frame-gated direct input belongs on the visual
            // sidecar. AI prompts and approval controls use the independent
            // ComputerUseSessionModel TLS channel and never pass through here.
            computerUseVisualSidecar?.sendDirectInput(message)
            return
        }
        seq &+= 1
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        transport?.send(message, seq: seq, ts: ts)
    }

    func attachVideoRenderer(_ renderer: RTCVideoRenderer) {
        if experience == .computerUse,
           computerUseConnectionMode == .localPromptOnly {
            computerUseVisualSidecar?.attachVideoRenderer(renderer)
        } else {
            (transport as? VideoRenderingTransport)?
                .attachVideoRenderer(renderer)
        }
    }

    func detachVideoRenderer(_ renderer: RTCVideoRenderer) {
        if experience == .computerUse,
           computerUseConnectionMode == .localPromptOnly {
            computerUseVisualSidecar?.detachVideoRenderer(renderer)
        } else {
            (transport as? VideoRenderingTransport)?
                .detachVideoRenderer(renderer)
        }
    }

    func disconnect() {
        invalidateAccountRevalidation(clearBinding: true)
        releaseSoftModifiers()
        stopComputerUseVisualSidecar(preserveConfiguration: false)
        localConnectionTask?.cancel()
        localConnectionTask = nil
        computerUseSession?.stop()
        transport?.disconnect(reason: "user")
        transport = nil
        state = .ended("Disconnected")
        hasReceivedVideoFrame = false
    }

    func reset() {
        invalidateAccountRevalidation(clearBinding: true)
        releaseSoftModifiers()
        stopComputerUseVisualSidecar(preserveConfiguration: false)
        localConnectionTask?.cancel()
        localConnectionTask = nil
        computerUseSession?.stop()
        computerUseSession = nil
        transport?.disconnect(reason: "user")
        transport = nil
        state = .idle
        error = nil
        hostName = nil
        display = nil
        hasReceivedVideoFrame = false
        experience = .remoteControl
        computerUseConnectionMode = .liveScreen
        computerUseVisualSidecarState = .unavailable
    }

    private func handleCloudKitAccountChanged() {
        LocalCloudAccountBindingPolicy.invalidateForAccountChange()
        guard state == .connecting || state == .connected else { return }

        // A connection still being established cannot be resumed safely: its
        // signaling or TLS handshake may already belong to the old owner.
        guard state == .connected,
              let expectedBinding = sessionAccountBinding else {
            endForCloudAccountChange()
            return
        }

        if !isCloudAccountRevalidationPending {
            // Release any latched remote keys before freezing outbound input.
            releaseSoftModifiers()
        }
        isCloudAccountRevalidationPending = true
        computerUseSession?.stop()
        // Stop decoding and invalidate every sidecar callback while the
        // Apple Account owner is unknown. Keep only the non-secret route
        // configuration so a successful same-account check can reconnect it.
        stopComputerUseVisualSidecar(preserveConfiguration: true)

        accountRevalidationGeneration &+= 1
        let generation = accountRevalidationGeneration
        accountRevalidationTask?.cancel()
        accountRevalidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.localAccountBindingValidator(expectedBinding)
                guard !Task.isCancelled,
                      self.accountRevalidationGeneration == generation,
                      self.state == .connected,
                      self.sessionAccountBinding == expectedBinding else {
                    return
                }
                self.accountRevalidationTask = nil
                self.isCloudAccountRevalidationPending = false
                self.computerUseSession?.start()
                self.computerUseVisualSidecar?.resume()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.accountRevalidationGeneration == generation else {
                    return
                }
                self.endForCloudAccountChange()
            }
        }
    }

    private func endForCloudAccountChange() {
        let reason = "The Apple Account changed or is no longer available. Sign into the same Apple Account and pair again."
        invalidateAccountRevalidation(clearBinding: true)
        localConnectionTask?.cancel()
        localConnectionTask = nil
        computerUseSession?.stop()
        stopComputerUseVisualSidecar(preserveConfiguration: false)
        transport?.disconnect(reason: reason)
        transport = nil
        hasReceivedVideoFrame = false
        error = reason
        state = .ended(reason)
    }

    private func invalidateAccountRevalidation(clearBinding: Bool) {
        accountRevalidationGeneration &+= 1
        accountRevalidationTask?.cancel()
        accountRevalidationTask = nil
        isCloudAccountRevalidationPending = false
        if clearBinding {
            sessionAccountBinding = nil
        }
    }

    private func connectLocalComputerUse(
        code: String,
        hostID: String,
        hostName: String,
        endpoint: LocalComputerUseEndpoint,
        credentialID: String,
        accountBinding: CloudKitAccountBinding
    ) {
        computerUseConnectionMode = .localPromptOnly

        localConnectionTask?.cancel()
        localConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.localAccountBindingValidator(accountBinding)
                guard !Task.isCancelled,
                      self.state == .connecting else { return }
                let pendingStore = self.localPendingStore
                // Read recovery state only after the current Apple Account is
                // validated, and only from that account's Keychain namespace.
                let recoveryCandidate = pendingStore.loadForLocalRecovery(
                    hostID: hostID,
                    localAccountBinding: accountBinding)
                let sessionID = recoveryCandidate?.sessionID
                    ?? UUID().uuidString
                let senderID = DeviceIdentity.get()
                guard !senderID.isEmpty else {
                    throw SignalingError.transport(
                        "Secure device identity is unavailable. Unlock this device and try again.")
                }
                let channel = try await self.localComputerUseChannelConnector(
                    endpoint,
                    credentialID,
                    hostID,
                    code,
                    sessionID,
                    senderID,
                    accountBinding)
                guard !Task.isCancelled,
                      self.state == .connecting else { return }
                // Close the validate→handshake race before reading, rebinding,
                // or replaying any durable task state on this channel.
                try await self.localAccountBindingValidator(accountBinding)
                guard !Task.isCancelled,
                      self.state == .connecting,
                      self.sessionAccountBinding == accountBinding else {
                    return
                }
                if let recoveryCandidate,
                   recoveryCandidate.pairingCode != code {
                    let rebound = recoveryCandidate.rebindingPairingCode(code)
                    guard pendingStore.save(rebound) else {
                        throw SignalingError.transport(
                            "The recovered AI task could not be saved safely. No task was resent.")
                    }
                }
                let model = ComputerUseSessionModel(
                    hostName: hostName,
                    pairingCode: code,
                    hostID: hostID,
                    sessionID: sessionID,
                    localAccountBinding: accountBinding,
                    pendingStore: pendingStore,
                    channel: channel)
                self.hostName = hostName
                self.computerUseSession = model
                self.state = .connected
                self.localConnectionTask = nil
                model.start()
                // The authenticated TLS channel is ready before this optional
                // connection begins. Sidecar delay or failure must not delay,
                // stop, or replace the durable AI task channel.
                self.display = nil
                self.startComputerUseVisualSidecar(
                    pairingCode: code,
                    expectedHostID: hostID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.localConnectionTask = nil
                self.computerUseSession = nil
                self.stopComputerUseVisualSidecar(
                    preserveConfiguration: false)
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't open the secure local AI connection."
                self.state = .idle
            }
        }
    }

    private func startComputerUseVisualSidecar(
        pairingCode: String,
        expectedHostID: String
    ) {
        let sidecar: ComputerUseVisualSidecar
        if let existing = computerUseVisualSidecar {
            sidecar = existing
        } else {
            let created = ComputerUseVisualSidecar(
                transportFactory: computerUseVisualTransportFactory)
            created.onStateChange = { [weak self] newState in
                guard let self,
                      self.experience == .computerUse,
                      self.computerUseConnectionMode == .localPromptOnly else {
                    return
                }
                let wasLive = self.computerUseVisualSidecarState == .live
                self.computerUseVisualSidecarState = newState
                self.hasReceivedVideoFrame = newState == .live
                if wasLive, newState != .live {
                    // A closed WebRTC control channel releases host-side input.
                    // Clear local latch state without attempting to write to a
                    // failed or replacement generation.
                    self.softModifierMask = 0
                }
            }
            created.onDisplay = { [weak self] display in
                guard let self,
                      self.state == .connected,
                      !self.isCloudAccountRevalidationPending else { return }
                self.display = display
            }
            computerUseVisualSidecar = created
            sidecar = created
        }
        sidecar.start(
            pairingCode: pairingCode,
            expectedHostID: expectedHostID)
    }

    private func stopComputerUseVisualSidecar(
        preserveConfiguration: Bool
    ) {
        computerUseVisualSidecar?.stop(
            preserveConfiguration: preserveConfiguration)
        computerUseVisualSidecarState = .unavailable
        if computerUseConnectionMode == .localPromptOnly {
            hasReceivedVideoFrame = false
            display = nil
        }
    }

    func toggleSoftModifier(_ modifier: SoftModifier) {
        guard !isCloudAccountRevalidationPending else { return }
        if experience == .computerUse,
           computerUseConnectionMode == .localPromptOnly,
           !hasInteractiveRemoteScreen {
            return
        }
        let wasLatched = isSoftModifierLatched(modifier)
        if wasLatched {
            softModifierMask &= ~modifier.mask
            send(.key(usage: modifier.hidUsage, down: false, modifiers: softModifierMask))
        } else {
            softModifierMask |= modifier.mask
            send(.key(usage: modifier.hidUsage, down: true, modifiers: softModifierMask))
        }
    }

    func isSoftModifierLatched(_ modifier: SoftModifier) -> Bool {
        (softModifierMask & modifier.mask) != 0
    }

    private func bind(_ t: Transport) {
        t.onHostHello = { [weak self] h in
            guard let self else { return }
            guard self.state == .connecting,
                  !self.isCloudAccountRevalidationPending else { return }
            self.hostName = h.hostname
            if self.experience == .computerUse,
               h.orderedComputerUseControls
                    < Config.orderedComputerUseControlsVersion {
                self.computerUseSession?.stop()
                self.computerUseSession = nil
                t.disconnect(reason: "protocol")
                self.transport = nil
                self.error = "Update Remote Desktop Host on this Mac before using AI Computer Use. Ordinary remote control is still available."
                self.state = .idle
                return
            }
            self.state = .connected
            self.computerUseSession?.start()
            self.send(.qos(
                targetFps: DesktopVideoQuality.targetFramesPerSecond,
                maxBitrateKbps: DesktopVideoQuality.maximumBitrateKbps,
                prefer: "sharpness"))
        }
        t.onDisplay = { [weak self] d in self?.display = d }
        t.onFirstVideoFrame = { [weak self] in
            guard let self,
                  self.state == .connected else { return }
            // Record decoded-frame readiness even while the account shield is
            // up. WebRTC reports this edge only once, while the pending flag
            // still keeps pixels hidden and outbound prompt/control disabled.
            self.hasReceivedVideoFrame = true
        }
        t.onDisconnect = { [weak self] r in
            self?.invalidateAccountRevalidation(clearBinding: true)
            self?.computerUseSession?.stop()
            self?.transport = nil
            self?.hasReceivedVideoFrame = false
            self?.state = .ended(r)
        }
    }

    func releaseSoftModifiers() {
        guard softModifierMask != 0 else { return }
        let latched = SoftModifier.allCases.filter(isSoftModifierLatched)
        for modifier in latched.reversed() {
            softModifierMask &= ~modifier.mask
            send(.key(usage: modifier.hidUsage, down: false, modifiers: softModifierMask))
        }
        softModifierMask = 0
    }
}

/// Owns the optional WebRTC pixels/control channel used alongside a local TLS
/// AI session. It deliberately has no reference to `ComputerUseSessionModel`,
/// so a video failure cannot stop, recreate, or reroute a durable AI task.
@MainActor
final class ComputerUseVisualSidecar {
    var onStateChange: ((ComputerUseVisualSidecarState) -> Void)?
    var onDisplay: ((DisplayInfo) -> Void)?

    private(set) var state: ComputerUseVisualSidecarState = .unavailable

    private struct Configuration {
        let pairingCode: String
        let expectedHostID: String
    }

    private let transportFactory: @MainActor () -> Transport

    private var configuration: Configuration?
    private var transport: Transport?
    private var connectionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var didReceiveCompatibleHostHello = false
    private var didReceiveCurrentDisplay = false
    private var didReceiveFreshFrame = false
    private var seq: UInt32 = 0

    init(
        transportFactory: @escaping @MainActor () -> Transport = {
            WebRTCTransport(
                mediaPolicy: .computerUseVisualSidecar)
        }
    ) {
        self.transportFactory = transportFactory
    }

    func start(pairingCode: String, expectedHostID: String) {
        configuration = Configuration(
            pairingCode: pairingCode,
            expectedHostID: expectedHostID)
        beginAttempt()
    }

    func resume() {
        guard configuration != nil else { return }
        beginAttempt()
    }

    func stop(preserveConfiguration: Bool) {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        let oldTransport = transport
        transport = nil
        didReceiveCompatibleHostHello = false
        didReceiveCurrentDisplay = false
        didReceiveFreshFrame = false
        if !preserveConfiguration {
            configuration = nil
        }
        transition(to: .unavailable)
        oldTransport?.disconnect(reason: "visual-sidecar-stopped")
    }

    /// Sends only person-generated screen input. Protocol/lifecycle messages
    /// and every AI task envelope are intentionally rejected here.
    @discardableResult
    func sendDirectInput(_ message: ControlMessage) -> Bool {
        guard state == .live,
              didReceiveCompatibleHostHello,
              didReceiveFreshFrame,
              let transport,
              Self.isDirectInput(message) else { return false }
        seq &+= 1
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        transport.send(message, seq: seq, ts: ts)
        return true
    }

    func attachVideoRenderer(_ renderer: RTCVideoRenderer) {
        guard state == .live else { return }
        (transport as? VideoRenderingTransport)?
            .attachVideoRenderer(renderer)
    }

    func detachVideoRenderer(_ renderer: RTCVideoRenderer) {
        (transport as? VideoRenderingTransport)?
            .detachVideoRenderer(renderer)
    }

    private func beginAttempt() {
        guard let configuration else {
            transition(to: .unavailable)
            return
        }

        generation &+= 1
        let attemptGeneration = generation
        connectionTask?.cancel()
        connectionTask = nil
        let oldTransport = transport
        transport = nil
        oldTransport?.disconnect(reason: "visual-sidecar-replaced")

        didReceiveCompatibleHostHello = false
        didReceiveCurrentDisplay = false
        didReceiveFreshFrame = false
        seq = 0
        let candidate = transportFactory()
        transport = candidate
        bind(candidate, generation: attemptGeneration)
        transition(to: .connecting)

        connectionTask = Task { @MainActor [weak self] in
            do {
                try await candidate.connect(
                    pairingCode: configuration.pairingCode,
                    expectedHostID: configuration.expectedHostID)
                guard let self,
                      self.generation == attemptGeneration else { return }
                self.connectionTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.failCurrentGeneration(
                    attemptGeneration,
                    disconnectTransport: true)
            }
        }
    }

    private func bind(_ candidate: Transport, generation: UInt64) {
        candidate.onHostHello = { [weak self] hello in
            guard let self,
                  self.generation == generation else { return }
            guard hello.orderedComputerUseControls
                    >= Config.orderedComputerUseControlsVersion else {
                self.failCurrentGeneration(
                    generation,
                    disconnectTransport: true)
                return
            }
            self.didReceiveCompatibleHostHello = true
            self.sendQualityPolicy(on: candidate)
            if self.didReceiveFreshFrame,
               self.didReceiveCurrentDisplay {
                self.becomeLive(generation: generation)
            } else {
                self.transition(to: .waitingForFreshFrame)
            }
        }
        candidate.onDisplay = { [weak self] display in
            guard let self,
                  self.generation == generation else { return }
            self.didReceiveCurrentDisplay = true
            self.onDisplay?(display)
            if self.didReceiveCompatibleHostHello,
               self.didReceiveFreshFrame {
                self.becomeLive(generation: generation)
            }
        }
        candidate.onFirstVideoFrame = { [weak self] in
            guard let self,
                  self.generation == generation else { return }
            self.didReceiveFreshFrame = true
            guard self.didReceiveCompatibleHostHello else { return }
            self.becomeLive(generation: generation)
        }
        candidate.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.failCurrentGeneration(
                generation,
                disconnectTransport: false)
        }
    }

    private func becomeLive(generation: UInt64) {
        guard self.generation == generation,
              didReceiveCompatibleHostHello,
              didReceiveCurrentDisplay,
              didReceiveFreshFrame else { return }
        transition(to: .live)
    }

    private func failCurrentGeneration(
        _ failedGeneration: UInt64,
        disconnectTransport: Bool
    ) {
        guard generation == failedGeneration else { return }
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        let failedTransport = transport
        transport = nil
        didReceiveCompatibleHostHello = false
        didReceiveCurrentDisplay = false
        didReceiveFreshFrame = false
        if disconnectTransport {
            failedTransport?.disconnect(reason: "visual-sidecar-failed")
        }
        transition(to: .failed)
    }

    private func sendQualityPolicy(on transport: Transport) {
        seq &+= 1
        transport.send(
            .qos(
                targetFps: DesktopVideoQuality.targetFramesPerSecond,
                maxBitrateKbps: DesktopVideoQuality.maximumBitrateKbps,
                prefer: "sharpness"),
            seq: seq,
            ts: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000))
    }

    private func transition(to newState: ComputerUseVisualSidecarState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private static func isDirectInput(_ message: ControlMessage) -> Bool {
        switch message {
        case .pointer, .scroll, .key, .text:
            return true
        case .hello, .qos, .bye:
            return false
        }
    }
}

private enum LocalComputerUseConnectionError: Error, LocalizedError {
    case automaticPairingIncomplete

    var errorDescription: String? {
        "Automatic local AI pairing is still finishing through iCloud. Keep Remote Desktop Host open on the Mac, then try again."
    }
}
