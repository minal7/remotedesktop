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
        var ok: Bool {
            screenRecording && accessibility && (!HostConfig.enableSystemAudio || microphone)
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var permissions = Permissions()

    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "session")
    private var signalingTask: Task<Void, Never>?
    private var peerSession: HostPeerSession?
    private let advertiser = BonjourAdvertiser()
    private let injector = InputInjector()
    private let capture = ScreenCapture()
    private let permissionsProvider: PermissionsProvider
    private let validateAudioInputEntitlements: @Sendable () throws -> Void
    private var pendingRemoteICEPayloads: [[String: String]] = []
    private var loggedPendingRemoteICE = false

    init(
        permissionsProvider: PermissionsProvider = SystemPermissionsProvider(),
        validateAudioInputEntitlements: @escaping @Sendable () throws -> Void = {
            try AudioInputEntitlements.validateIfNeeded()
        }
    ) {
        self.permissionsProvider = permissionsProvider
        self.validateAudioInputEntitlements = validateAudioInputEntitlements
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
    }

    func requestPermissions() {
        permissionsProvider.requestPrompts()
        refreshPermissions()
    }

    func grantNextPermission() {
        refreshPermissions()
        guard let permission = nextMissingPermission else { return }
        guard permission == .microphone else {
            permissionsProvider.requestPrompt(for: permission)
            permissionsProvider.openSystemSettings(for: permission)
            return
        }
        if let message = microphoneBuildIssueMessage {
            state = .error(message)
            return
        }

        permissionsProvider.requestMicrophoneAccess { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                guard let nextPermission = self.nextMissingPermission else { return }
                self.permissionsProvider.openSystemSettings(for: nextPermission)
            }
        }
    }

    func openSystemSettingsForNextMissingPermission() {
        refreshPermissions()
        if let permission = nextMissingPermission {
            if permission == .microphone, let message = microphoneBuildIssueMessage {
                state = .error(message)
                return
            }
            permissionsProvider.openSystemSettings(for: permission)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard case .idle = state else { return }
        startListening()
    }

    /// Internal entry point shared by `start()` and auto-restart.
    /// Validates permissions, generates a new pairing code, and kicks
    /// off the signaling run-loop.
    private func startListening() {
        refreshPermissions()
        guard permissions.ok else {
            if let message = microphoneBuildIssueMessage {
                state = .error(message)
                return
            }
            state = .error(requiredPermissionsMessage)
            return
        }

        let code = Self.newPairingCode()
        state = .starting
        signalingTask = Task { await run(code: code) }
    }

    func stop() {
        signalingTask?.cancel()
        signalingTask = nil
        advertiser.stop()
        peerSession?.close(reason: "user")
        peerSession = nil
        resetPendingRemoteICE()
        Task { await capture.stop() }
        state = .idle
    }

    // MARK: - Session lifecycle

    private func run(code: String) async {
        resetPendingRemoteICE()
        let client = CloudKitSignalingClient(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier,
            code: code,
            role: .host,
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)

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

        let iceConfig = await ICEConfigFetcher(
            containerIdentifier: HostConfig.cloudKitContainerIdentifier).get()

        state = .advertising(code: code)
        advertiser.publish(
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            code: code)
        log.info("advertising code=\(code, privacy: .public)")

        while !Task.isCancelled {
            let envelopes: [SignalingEnvelope]
            do {
                envelopes = try await client.poll()
            } catch {
                if Task.isCancelled || Self.isCancellation(error) { return }
                log.error("poll failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            for env in envelopes {
                switch env.kind {
                case .offer:
                    let clientName = env.payload["client"] ?? "iOS client"
                    if let sdp = env.payload["sdp"] {
                        if peerSession == nil {
                            // `client` (CloudKitSignalingClient) auto-memoizes
                            // the client's senderID as targetID on first inbound
                            // envelope; outbound ICE will route there.
                            peerSession = HostPeerSession(
                                signaling: client,
                                capture: capture,
                                injector: injector,
                                iceConfig: iceConfig,
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
                            state = .paired(clientDescription: clientName)
                        } catch {
                            log.error("failed to accept WebRTC offer: \(String(describing: error), privacy: .public)")
                            state = .error("Couldn't start the WebRTC session.")
                            advertiser.stop()
                            peerSession?.close(reason: "error")
                            peerSession = nil
                            resetPendingRemoteICE()
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
                        } catch {
                            log.error("failed to send preflight answer: \(String(describing: error), privacy: .public)")
                            state = .error("Client reached the host, but the host couldn't reply over signaling.")
                            advertiser.stop()
                            resetPendingRemoteICE()
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
                    await client.cleanup()
                    handleDisconnect(reason: env.payload["reason"] ?? "user")
                    return
                }
            }
            // CloudKit is short-poll (2 s cadence), not long-poll.
            try? await Task.sleep(for: .seconds(2))
        }
        resetPendingRemoteICE()
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
        log.info("connection ended (\(reason, privacy: .public)) — restarting listener")
        peerSession?.close(reason: reason)
        peerSession = nil
        resetPendingRemoteICE()
        advertiser.stop()
        signalingTask?.cancel()
        signalingTask = nil
        startListening()
    }

    // MARK: -

    static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    private func hostMetadata() -> [String: String] {
        let mainScreen = NSScreen.main
        let frame = mainScreen?.frame ?? .zero
        let scale = mainScreen?.backingScaleFactor ?? 2.0
        return [
            "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "app": "RemoteDesktop-Host",
            "version": "0.1.0",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "audio": HostConfig.enableSystemAudio ? "true" : "false",
            "monitors": "\(NSScreen.screens.count)",
            "displayWidth": "\(Int(frame.width.rounded()))",
            "displayHeight": "\(Int(frame.height.rounded()))",
            "displayScale": String(format: "%.2f", scale),
        ]
    }

    private var requiredPermissionsMessage: String {
        if HostConfig.enableSystemAudio {
            return "Grant Screen & System Audio Recording, Microphone, and Accessibility in System Settings, then press Check again."
        }
        return "Grant Screen Recording and Accessibility in System Settings, then press Check again."
    }

    private var microphoneBuildIssueMessage: String? {
        guard HostConfig.enableSystemAudio, !permissions.microphone else { return nil }
        do {
            try validateAudioInputEntitlements()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var nextMissingPermission: PermissionKind? {
        if !permissions.screenRecording {
            return .screenRecording
        }
        if !permissions.accessibility {
            return .accessibility
        }
        if HostConfig.enableSystemAudio && !permissions.microphone {
            return .microphone
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
