import Combine
import Foundation
import LiveKitWebRTC

/// Top-level state holder for the client. Owns the `Transport`, tracks
/// lifecycle, and fans input events out as `ControlMessage`s.
@MainActor
final class SessionModel: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case ended(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hostName: String?
    @Published private(set) var display: DisplayInfo?
    @Published private(set) var softModifierMask: UInt16 = 0
    @Published var error: String?

    private let transportFactory: @MainActor () -> Transport
    private var transport: Transport?
    private var seq: UInt32 = 0

    init(transportFactory: @escaping @MainActor () -> Transport = { WebRTCTransport() }) {
        self.transportFactory = transportFactory
    }

    func connect(code: String) {
        guard state == .idle || {
            if case .ended = state { return true } else { return false }
        }() else { return }
        state = .connecting
        error = nil

        let t = transportFactory()
        bind(t)
        transport = t

        Task { @MainActor in
            do {
                try await t.connect(pairingCode: code)
            } catch {
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
        transport?.disconnect(reason: "user")
        transport = nil
        state = .ended("Disconnected")
    }

    func reset() {
        releaseSoftModifiers()
        transport?.disconnect(reason: "user")
        transport = nil
        state = .idle
        error = nil
        hostName = nil
        display = nil
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
            self?.hostName = h.hostname
            self?.state = .connected
        }
        t.onDisplay = { [weak self] d in self?.display = d }
        t.onDisconnect = { [weak self] r in
            self?.transport = nil
            self?.state = .ended(r)
        }
    }

    private func releaseSoftModifiers() {
        guard softModifierMask != 0 else { return }
        let latched = SoftModifier.allCases.filter(isSoftModifierLatched)
        for modifier in latched.reversed() {
            softModifierMask &= ~modifier.mask
            send(.key(usage: modifier.hidUsage, down: false, modifiers: softModifierMask))
        }
        softModifierMask = 0
    }
}
