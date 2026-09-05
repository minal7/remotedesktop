import Foundation

/// Vision performs synchronous native work and can wait internally. Never
/// occupy MainActor or Swift's cooperative pool with that wait: takeover and
/// action-gate closure must remain runnable. A serial queue also bounds the
/// number of simultaneous OCR requests from this host.
enum ComputerUseObservationWorker {
    private static let queue = DispatchQueue(
        label: "com.threadmark.remotedesktop.computer-use.observation",
        qos: .userInitiated)
    private static let capacity = Capacity()

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
        try Task.checkCancellation()
        guard capacity.acquire() else { throw Failure.busy }
        let delivery = Delivery<Value>()
        let deadline = DispatchWorkItem {
            delivery.finish(.failure(Failure.timedOut))
        }
        defer { deadline.cancel() }
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delivery.install(continuation)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + max(0.001, timeout), execute: deadline)
                queue.async {
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

    /// Cancelling the caller cannot forcibly stop a blocked native API. Keep
    /// its single permit until that API returns; retries must not build up an
    /// unbounded queue of obsolete image requests.
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
