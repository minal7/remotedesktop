import Combine
import Foundation
import LiveKitWebRTC

/// Top-level state holder for the client. Owns the `Transport`, tracks
/// lifecycle, and fans input events out as `ControlMessage`s.
@MainActor
final class SessionModel: ObservableObject {
    enum Experience: Equatable {
        case remoteControl
        case computerUse
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

    private let transportFactory: @MainActor () -> Transport
    private var transport: Transport?
    private var seq: UInt32 = 0

    init(transportFactory: @escaping @MainActor () -> Transport = { WebRTCTransport() }) {
        self.transportFactory = transportFactory
    }

    func connect(
        code: String,
        experience: Experience = .remoteControl,
        computerUseHostID: String? = nil,
        hostName: String = "Mac"
    ) {
        guard state == .idle || {
            if case .ended = state { return true } else { return false }
        }() else { return }
        state = .connecting
        error = nil
        hasReceivedVideoFrame = false
        self.experience = experience

        if experience == .computerUse {
            guard let computerUseHostID, !computerUseHostID.isEmpty else {
                self.error = "AI Computer Use isn't available for this Mac yet. Wait a moment and try again."
                state = .idle
                return
            }
            let computerUse = ComputerUseSessionModel(
                hostName: hostName,
                pairingCode: code,
                hostID: computerUseHostID)
            computerUseSession = computerUse
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
                self.computerUseSession?.stop()
                self.computerUseSession = nil
                self.transport = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't connect: \(error.localizedDescription)"
                self.state = .idle
            }
        }
    }

    func send(_ message: ControlMessage) {
        seq &+= 1
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
        transport?.send(message, seq: seq, ts: ts)
    }

    func attachVideoRenderer(_ renderer: RTCVideoRenderer) {
        (transport as? VideoRenderingTransport)?.attachVideoRenderer(renderer)
    }

    func detachVideoRenderer(_ renderer: RTCVideoRenderer) {
        (transport as? VideoRenderingTransport)?.detachVideoRenderer(renderer)
    }

    func disconnect() {
        releaseSoftModifiers()
        computerUseSession?.stop()
        transport?.disconnect(reason: "user")
        transport = nil
        state = .ended("Disconnected")
        hasReceivedVideoFrame = false
    }

    func reset() {
        releaseSoftModifiers()
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
    }

    func toggleSoftModifier(_ modifier: SoftModifier) {
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
            self?.hasReceivedVideoFrame = true
        }
        t.onDisconnect = { [weak self] r in
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
