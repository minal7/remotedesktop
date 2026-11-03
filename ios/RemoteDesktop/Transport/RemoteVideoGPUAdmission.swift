#if DEBUG
import Foundation

/// Shared across legacy and F4 surfaces. Observation expiry and surface
/// retirement cannot make committed GPU work stop using its resources.
final class RemoteVideoGPUAdmission: @unchecked Sendable {
    static let shared = RemoteVideoGPUAdmission(capacity: 2)
    private let lock = NSLock()
    private let capacity: Int
    private var inUse = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }
    func acquire() -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard inUse < capacity else { return nil }
        inUse += 1
        return Lease(pool: self)
    }
    private func release() {
        lock.lock(); defer { lock.unlock() }
        precondition(inUse > 0)
        inUse -= 1
    }

    /// Explicitly release an abandoned submission or call from the native
    /// GPU completion. Multiple native callbacks cannot free another permit.
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var pool: RemoteVideoGPUAdmission?
        fileprivate init(pool: RemoteVideoGPUAdmission) { self.pool = pool }
        func release() {
            lock.lock(); let pool = self.pool; self.pool = nil; lock.unlock()
            pool?.release()
        }
    }
}
#endif
