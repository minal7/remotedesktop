import Foundation

/// Runs blocking native operations away from MainActor and Swift's cooperative
/// pool. A serial queue and one permit bound work even when a caller times out
/// while the underlying native operation remains blocked.
final class ComputerUseBlockingOperationWorker: @unchecked Sendable {
    enum Failure: Error, Equatable { case busy, timedOut }

    private let queue: DispatchQueue
    private let capacity = Capacity()

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func perform<Value: Sendable>(
        timeout: TimeInterval,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard capacity.acquire() else { throw Failure.busy }
        let delivery = Delivery<Value>()
        let deadline = DispatchWorkItem { delivery.finish(.failure(Failure.timedOut)) }
        defer { deadline.cancel() }
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delivery.install(continuation)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + max(0.001, timeout), execute: deadline)
                queue.async { [capacity = self.capacity] in
                    guard !delivery.isFinished else {
                        capacity.release()
                        return
                    }
                    let result = Result { try autoreleasepool(invoking: operation) }
                    capacity.release()
                    delivery.finish(result)
                }
            }
        } onCancel: {
            delivery.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return value
    }

    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var occupied = false
        func acquire() -> Bool {
            lock.withLock {
                guard !occupied else { return false }
                occupied = true
                return true
            }
        }
        func release() { lock.withLock { occupied = false } }
    }

    private final class Delivery<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        var isFinished: Bool { lock.withLock { result != nil } }
        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let finished = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let finished { continuation.resume(with: finished) }
        }
        func finish(_ result: Result<Value, Error>) {
            let waiter = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                defer { continuation = nil }
                return continuation
            }
            waiter?.resume(with: result)
        }
    }
}

/// Vision performs synchronous native work and can wait internally. Keep its
/// API and error semantics separate from other bounded blocking operations.
enum ComputerUseObservationWorker {
    private static let worker = ComputerUseBlockingOperationWorker(
        label: "com.threadmark.remotedesktop.computer-use.observation")

    enum Failure: Error, Equatable, LocalizedError {
        case busy, timedOut
        case recognitionFailed(domain: String, code: Int)
        var errorDescription: String? {
            switch self {
            case .busy: return "The previous screen analysis is still finishing. No new action was taken."
            case .timedOut: return "Local screen analysis took too long. No new action was taken."
            case .recognitionFailed(let domain, let code):
                return "Local text recognition failed (\(domain), \(code)). No result was inferred from the failed observation."
            }
        }
    }

    static func perform<Value: Sendable>(
        timeout: TimeInterval = 10,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        do { return try await worker.perform(timeout: timeout, operation) }
        catch ComputerUseBlockingOperationWorker.Failure.busy { throw Failure.busy }
        catch ComputerUseBlockingOperationWorker.Failure.timedOut { throw Failure.timedOut }
    }
}
