import Foundation

/// A deadline for proposal-only asynchronous planning. Cancelling a Swift
/// task cannot force a model API to return. Deliver failure promptly, discard
/// late proposals, and retain the one permit until that exact call finishes.
/// Never put an effectful tool call inside this worker.
final class ComputerUsePlanningWorker: @unchecked Sendable {
    static let shared = ComputerUsePlanningWorker()
    static let maximumWait: TimeInterval = 120

    enum Failure: Error, Equatable, LocalizedError {
        case busy, timedOut, invalidDeadline

        var errorDescription: String? {
            switch self {
            case .busy:
                return "The previous local planning call is still finishing. No new action was started."
            case .timedOut:
                return "The local planner took too long to choose the next step. No further action was taken; earlier completed steps remain on the Mac."
            case .invalidDeadline:
                return "Local planning could not start because its time limit was invalid."
            }
        }
    }

    private let lock = NSLock()
    private let now: @Sendable () -> DispatchTime
    private var occupied = false

    init(now: @escaping @Sendable () -> DispatchTime = { .now() }) {
        self.now = now
    }

    /// An advisory check before activating a runtime. `perform` still acquires
    /// the permit atomically, including when multiple executors share it.
    func requireAvailable() throws {
        guard lock.withLock({ !occupied }) else { throw Failure.busy }
    }

    func perform<Value: Sendable>(
        timeout: TimeInterval = ComputerUsePlanningWorker.maximumWait,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= Self.maximumWait else {
            throw Failure.invalidDeadline
        }
        let acquired = lock.withLock { () -> Bool in
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard acquired else { throw Failure.busy }
        let expiresAt = now() + timeout
        let delivery = Delivery<Value>()
        let deadline = DispatchWorkItem {
            delivery.finish(.failure(Failure.timedOut), cancellingOperation: true)
        }
        defer { deadline.cancel() }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delivery.install(continuation)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: expiresAt, execute: deadline)
                // Inherit task-local provenance. The operation is proposal-
                // only; no late result may resume an executor's effect path.
                let task = Task {
                    let result: Result<Value, Error>
                    do {
                        guard !delivery.isFinished else { throw CancellationError() }
                        try Task.checkCancellation()
                        guard self.now().uptimeNanoseconds < expiresAt.uptimeNanoseconds else {
                            throw Failure.timedOut
                        }
                        let proposed = try await operation()
                        try Task.checkCancellation()
                        result = .success(proposed)
                    } catch {
                        result = .failure(error)
                    }
                    // A busy timer queue must not allow an overdue response
                    // to win merely because its deadline callback ran late.
                    let expired = self.now().uptimeNanoseconds
                        >= expiresAt.uptimeNanoseconds
                    // Release only after the underlying call really returns,
                    // before waking a successful caller that may plan again.
                    self.lock.withLock { self.occupied = false }
                    delivery.finish(
                        expired ? .failure(Failure.timedOut) : result,
                        cancellingOperation: false)
                }
                delivery.install(task)
            }
        } onCancel: {
            delivery.finish(.failure(CancellationError()), cancellingOperation: true)
        }
        try Task.checkCancellation()
        return value
    }

    private final class Delivery<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        private var operationTask: Task<Void, Never>?

        var isFinished: Bool { lock.withLock { result != nil } }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let finished = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let finished { continuation.resume(with: finished) }
        }

        func install(_ task: Task<Void, Never>) {
            let finished = lock.withLock { () -> Bool in
                guard result == nil else { return true }
                operationTask = task
                return false
            }
            if finished { task.cancel() }
        }

        func finish(_ result: Result<Value, Error>, cancellingOperation: Bool) {
            let pending = lock.withLock { () -> (
                CheckedContinuation<Value, Error>?, Task<Void, Never>?
            ) in
                guard self.result == nil else { return (nil, nil) }
                self.result = result
                defer { continuation = nil; operationTask = nil }
                return (continuation, cancellingOperation ? operationTask : nil)
            }
            pending.1?.cancel()
            pending.0?.resume(with: result)
        }
    }
}
