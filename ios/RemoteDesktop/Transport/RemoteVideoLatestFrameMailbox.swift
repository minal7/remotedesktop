import Foundation

/// One retained latest frame and at most one queued wake per context. Taking
/// consumes pending work, not the image: continuous local layout changes may
/// redraw it into a different drawable without pretending it is a new decode
/// or host capture. Ordinary context replacement still discards the image.
/// Frame contents must remain immutable while retained. No UI or native
/// rendering runs while the lock is held.
final class RemoteVideoLatestFrameMailbox<Frame: AnyObject>: @unchecked Sendable {
    struct Wake: Equatable, Sendable { let context: UUID; let id: UUID }
    struct Entry: @unchecked Sendable { let context: UUID; let id: UUID; let frame: Frame }
    private let lock = NSLock()
    private var context: UUID?
    private var latest: Entry?
    private var pending = false
    private var wake: Wake?
    private var notify: (@Sendable (Wake) -> Void)?

    func setWakeHandler(_ notify: @escaping @Sendable (Wake) -> Void) {
        lock.lock()
        self.notify = notify
        let next: Wake?
        if let context, pending, wake == nil {
            next = Wake(context: context, id: UUID()); wake = next
        } else { next = nil }
        lock.unlock()
        if let next { notify(next) }
    }

    /// Preservation requires the exact previous context. The surface supplies
    /// it only for a continuous, eligible layout in the same native window.
    /// Nil/foreign contexts, hiding and retirement cannot transfer an image.
    func replaceContext(_ context: UUID?, preservingLatestFrom previous: UUID? = nil,
                        excludingFrameID: UUID? = nil) {
        lock.lock()
        let old = latest
        if let context, let previous, self.context == previous, let old, old.id != excludingFrameID {
            latest = Entry(context: context, id: old.id, frame: old.frame)
        } else { latest = nil }
        self.context = context; pending = latest != nil; wake = nil
        lock.unlock()
        withExtendedLifetime(old) {}
    }

    func offer(_ frame: Frame) {
        lock.lock()
        guard let context else { lock.unlock(); return }
        let old = latest
        latest = Entry(context: context, id: UUID(), frame: frame); pending = true
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
        return self.context == wake.context && self.wake == wake && pending
    }

    func hasPending(context: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.context == context && pending
    }

    func takeLatest(context: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard self.context == context, pending else { return nil }
        pending = false; wake = nil
        return latest
    }

    /// The caller owns its bounded retry; an older entry never replaces a
    /// newly received frame or crosses a context boundary.
    func restoreUnlessNewer(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        guard context == entry.context, latest?.id == entry.id, !pending else { return }
        pending = true
        wake = Wake(context: entry.context, id: UUID())
    }

    /// A failed/skipped committed presentation cannot be retried by rotating
    /// layout. Discard that image, while preserving any newer decode.
    func discard(frame: UUID, context: UUID) {
        lock.lock()
        guard self.context == context, latest?.id == frame else { lock.unlock(); return }
        let old = latest
        latest = nil; pending = false; wake = nil
        lock.unlock()
        withExtendedLifetime(old) {}
    }
}
