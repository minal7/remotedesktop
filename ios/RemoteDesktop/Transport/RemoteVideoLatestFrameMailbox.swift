import Foundation

/// One retained, unsubmitted frame and at most one queued wake per context.
/// Frame contents must remain immutable while retained. No UI or native
/// rendering runs while the lock is held.
final class RemoteVideoLatestFrameMailbox<Frame: AnyObject>: @unchecked Sendable {
    struct Wake: Equatable, Sendable { let context: UUID; let id: UUID }
    struct Entry: @unchecked Sendable { let context: UUID; let id: UUID; let frame: Frame }
    private let lock = NSLock()
    private var context: UUID?
    private var pending: Entry?
    private var wake: Wake?
    private var notify: (@Sendable (Wake) -> Void)?

    func setWakeHandler(_ notify: @escaping @Sendable (Wake) -> Void) {
        lock.lock()
        self.notify = notify
        let next: Wake?
        if let context, pending != nil, wake == nil {
            next = Wake(context: context, id: UUID()); wake = next
        } else { next = nil }
        lock.unlock()
        if let next { notify(next) }
    }

    func replaceContext(_ context: UUID?) {
        lock.lock()
        let old = pending
        self.context = context; pending = nil; wake = nil
        lock.unlock()
        withExtendedLifetime(old) {}
    }

    func offer(_ frame: Frame) {
        lock.lock()
        guard let context else { lock.unlock(); return }
        let old = pending
        pending = Entry(context: context, id: UUID(), frame: frame)
        let notification: (Wake, @Sendable (Wake) -> Void)?
        if wake == nil, let notify {
            let next = Wake(context: context, id: UUID()); wake = next
            notification = (next, notify)
        } else { notification = nil }
        lock.unlock()
        withExtendedLifetime(old) {}
        if let (wake, notify) = notification { notify(wake) }
    }

    func accepts(_ wake: Wake) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.context == wake.context && self.wake == wake && pending != nil
    }

    func hasPending(context: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.context == context && pending != nil
    }

    func takeLatest(context: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard self.context == context else { return nil }
        let entry = pending; pending = nil; wake = nil
        return entry
    }

    /// Only for an uncommitted admission failure. The caller owns its retry;
    /// restoring an older entry must never replace a newly received frame.
    func restoreUnlessNewer(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        guard context == entry.context, pending == nil else { return }
        pending = entry
        wake = Wake(context: entry.context, id: UUID())
    }
}
