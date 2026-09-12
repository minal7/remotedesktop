import Foundation

/// One attachment's local presentation state, never a source-capture receipt.
@MainActor
final class RemoteVideoSurfacePresentation {
    enum State: Equatable {
        case waiting(context: UUID)
        case presented(context: UUID, frame: UUID, time: TimeInterval)
        case rendered(context: UUID, frame: UUID, time: TimeInterval)
        case failed(context: UUID, message: String)
        case retired
    }
    private(set) var state: State
    private var context: UUID?
    private var terminal = false
    private var lastPresentationTime: TimeInterval = 0
    private var observer: (@MainActor (State) -> Void)?

    init(context: UUID) { self.context = context; state = .waiting(context: context) }

    func observe(_ observer: @escaping @MainActor (State) -> Void) {
        guard context != nil else { return }
        self.observer = observer
        observer(state)
    }

    func begin(context: UUID) {
        guard self.context != nil, !terminal else { return }
        self.context = context
        lastPresentationTime = 0
        publish(.waiting(context: context))
    }

    func wait(context: UUID) {
        guard self.context == context, !terminal else { return }
        publish(.waiting(context: context))
    }

    func present(context: UUID, frame: UUID, time: TimeInterval) {
        guard self.context == context, !terminal, time.isFinite, time > 0, time >= lastPresentationTime else { return }
        lastPresentationTime = time
        publish(.presented(context: context, frame: frame, time: time))
    }

    /// GPU completion after scheduling presentation, without a hardware
    /// presentation timestamp. Used only by the Simulator producer.
    func render(context: UUID, frame: UUID, time: TimeInterval) {
        guard self.context == context, !terminal, time.isFinite, time > 0, time >= lastPresentationTime else { return }
        lastPresentationTime = time
        publish(.rendered(context: context, frame: frame, time: time))
    }

    func fail(context: UUID, message: String) {
        guard self.context == context, !terminal else { return }
        terminal = true
        publish(.failed(context: context, message: message))
    }

    func retire() { context = nil; terminal = true; observer = nil; state = .retired }

    private func publish(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        observer?(state)
    }
}
