import Foundation
import XCTest
@testable import RemoteDesktopHost

final class PeerCloseCoordinatorTests: XCTestCase {
    func testReentrantNativeCloseCallbackDoesNotHoldCoordinatorLock() async {
        let coordinator = PeerCloseCoordinator()
        let state = CloseState()

        let completion = coordinator.close(revokeInput: { state.revoke() }) {
            state.recordNativeClose()
            _ = coordinator.close(revokeInput: { state.revoke() }) {
                state.recordUnexpectedSecondTeardown()
                return Task {}
            }
            state.recordReentrantReturn()
            return Task { await state.captureCleanup.wait() }
        }
        let completionObserver = Task {
            await completion.value
            state.recordCompletion()
        }

        XCTAssertEqual(state.snapshot.nativeCloseCount, 1)
        XCTAssertEqual(state.snapshot.revokeCount, 2)
        XCTAssertTrue(state.snapshot.reentrantReturned)
        XCTAssertFalse(state.snapshot.secondTeardownRan)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(state.snapshot.completionFinished)

        state.captureCleanup.finish()
        await completionObserver.value
        XCTAssertTrue(state.snapshot.completionFinished)
    }

    func testConcurrentCloseRevokesInputBeforeReturningAndSharesBarrier() async {
        let coordinator = PeerCloseCoordinator()
        let state = CloseState()
        let nativeCloseEntered = DispatchSemaphore(value: 0)
        let allowNativeCloseToReturn = DispatchSemaphore(value: 0)
        let firstReturn = CloseTaskBox()

        DispatchQueue.global().async {
            firstReturn.task = coordinator.close(revokeInput: { state.revoke() }) {
                state.recordNativeClose()
                nativeCloseEntered.signal()
                allowNativeCloseToReturn.wait()
                return Task { await state.captureCleanup.wait() }
            }
        }

        XCTAssertEqual(nativeCloseEntered.wait(timeout: .now() + 2), .success)
        let second = coordinator.close(revokeInput: { state.revoke() }) {
            state.recordUnexpectedSecondTeardown()
            return Task {}
        }
        let secondCompletionObserver = Task {
            await second.value
            state.recordCompletion()
        }

        XCTAssertEqual(state.snapshot.revokeCount, 2,
                       "each close call must revoke input synchronously")
        XCTAssertFalse(state.snapshot.secondTeardownRan)
        XCTAssertFalse(state.snapshot.completionFinished)

        // Capture cleanup can finish while the first caller is still inside
        // native close. The shared barrier must remain pending until native
        // teardown returns and the first caller hands back that cleanup task.
        state.captureCleanup.finish()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(state.snapshot.completionFinished,
                       "the second caller must not pass the barrier during native close")

        allowNativeCloseToReturn.signal()
        let first = await firstReturn.wait()
        await first.value
        await secondCompletionObserver.value
        await second.value
        XCTAssertTrue(state.snapshot.completionFinished)
    }
}

private final class CloseState: @unchecked Sendable {
    struct Snapshot {
        var revokeCount = 0
        var nativeCloseCount = 0
        var reentrantReturned = false
        var secondTeardownRan = false
        var completionFinished = false
    }

    private let lock = NSLock()
    private var value = Snapshot()
    let captureCleanup = AsyncCloseGate()

    var snapshot: Snapshot { lock.withLock { value } }
    func revoke() { lock.withLock { value.revokeCount += 1 } }
    func recordNativeClose() { lock.withLock { value.nativeCloseCount += 1 } }
    func recordReentrantReturn() { lock.withLock { value.reentrantReturned = true } }
    func recordUnexpectedSecondTeardown() { lock.withLock { value.secondTeardownRan = true } }
    func recordCompletion() { lock.withLock { value.completionFinished = true } }
}

private final class AsyncCloseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class CloseTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Task<Void, Never>?
    private var waiter: CheckedContinuation<Task<Void, Never>, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { value } }
        set {
            let continuation = lock.withLock { () -> CheckedContinuation<Task<Void, Never>, Never>? in
                value = newValue
                defer { waiter = nil }
                return waiter
            }
            if let newValue, let continuation { continuation.resume(returning: newValue) }
        }
    }

    func wait() async -> Task<Void, Never> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
