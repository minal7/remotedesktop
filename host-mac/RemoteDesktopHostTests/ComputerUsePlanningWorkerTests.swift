import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUsePlanningWorkerTests: XCTestCase {
    func testDeadlineReturnsBeforeUncooperativePlannerAndRetainsItsPermit() async throws {
        let worker = ComputerUsePlanningWorker()
        let gate = ComputerUsePlanningTestGate<Int>(
            started: expectation(description: "planner started"),
            returned: expectation(description: "planner returned"))
        defer { gate.finish(42) }
        let delivered = expectation(description: "caller received deadline")
        let call = Task { () -> Result<Int, Error> in
            defer { delivered.fulfill() }
            do { return .success(try await worker.perform(timeout: 0.1) { await gate.wait() }) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [gate.started, delivered], timeout: 2, enforceOrder: true)
        XCTAssertThrowsError(try worker.requireAvailable()) {
            XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .busy)
        }
        gate.finish(42)
        switch await call.value {
        case .failure(let error): XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut)
        case .success: XCTFail("A late proposal cannot replace the delivered timeout")
        }
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        let fresh = try await worker.perform { 7 }
        XCTAssertEqual(fresh, 7)
    }

    func testCancellationReturnsBeforeUncooperativePlannerAndDiscardsLateProposal() async throws {
        let worker = ComputerUsePlanningWorker()
        let gate = ComputerUsePlanningTestGate<Int>(
            started: expectation(description: "planner started"),
            returned: expectation(description: "planner returned"))
        defer { gate.finish(42) }
        let delivered = expectation(description: "caller received cancellation")
        let call = Task { () -> Result<Int, Error> in
            defer { delivered.fulfill() }
            do { return .success(try await worker.perform(timeout: 5) { await gate.wait() }) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [gate.started], timeout: 1)
        call.cancel()
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertThrowsError(try worker.requireAvailable()) {
            XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .busy)
        }
        gate.finish(42)
        switch await call.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("An obsolete proposal cannot become the cancelled caller's result")
        }
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
    }

    func testOverdueProposalIsRejectedEvenBeforeTheTimerCallbackRuns() async throws {
        let clock = PlanningWorkerFixtureClock()
        let worker = ComputerUsePlanningWorker(now: { clock.now() })
        do {
            _ = try await worker.perform(timeout: 60) {
                clock.advance(by: 61)
                return 42
            }
            XCTFail("An overdue response cannot become timely because the timer callback has not run")
        } catch {
            XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut)
        }
        try worker.requireAvailable()
    }

    func testPlanningPreservesTaskLocalContextAndReleasesAfterSuccessOrFailure() async throws {
        let worker = ComputerUsePlanningWorker()
        let context = try await PlanningWorkerFixtureContext.$value.withValue("original-task") {
            try await worker.perform { PlanningWorkerFixtureContext.value }
        }
        XCTAssertEqual(context, "original-task", "Foundation provenance must follow the proposal child task")
        try worker.requireAvailable()
        do {
            let _: Int = try await worker.perform { throw PlanningWorkerFixtureError.failed }
            XCTFail("The original planner error must be delivered")
        } catch {
            XCTAssertEqual(error as? PlanningWorkerFixtureError, .failed)
        }
        try worker.requireAvailable()
        let next = try await worker.perform { 9 }
        XCTAssertEqual(next, 9)
    }

    func testAlreadyCancelledPlanningDoesNotInvokeOperationOrOccupyPermit() async throws {
        let worker = ComputerUsePlanningWorker()
        let call = Task {
            try await worker.perform {
                XCTFail("A cancelled caller cannot start planning")
                return 1
            }
        }
        call.cancel()
        do { _ = try await call.value; XCTFail("Cancellation must be returned") }
        catch is CancellationError { }
        try worker.requireAvailable()
    }

    func testConcurrentPlanningRejectsNewCallerWithoutCancellingHealthyOwner() async throws {
        let worker = ComputerUsePlanningWorker()
        let gate = ComputerUsePlanningTestGate<Int>(
            started: expectation(description: "owner started"),
            returned: expectation(description: "owner returned"))
        defer { gate.finish(42) }
        let owner = Task { try await worker.perform(timeout: 5) { await gate.wait() } }
        await fulfillment(of: [gate.started], timeout: 1)
        do {
            _ = try await worker.perform { XCTFail("Concurrent caller must not enter its planner"); return 7 }
            XCTFail("Planning capacity cannot be queued or shared")
        } catch {
            XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy)
        }
        gate.finish(42)
        let value = try await owner.value
        XCTAssertEqual(value, 42)
        await fulfillment(of: [gate.returned], timeout: 1)
        try worker.requireAvailable()
    }
}

private enum PlanningWorkerFixtureContext {
    @TaskLocal static var value: String?
}

private enum PlanningWorkerFixtureError: Error, Equatable { case failed }

private final class PlanningWorkerFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = DispatchTime.now()
    func now() -> DispatchTime { lock.withLock { instant } }
    func advance(by seconds: TimeInterval) { lock.withLock { instant = instant + seconds } }
}

/// Deliberately ignores Task cancellation, as a stalled model API can do.
/// Shared by the worker and production-executor fixtures; it never uses a model.
final class ComputerUsePlanningTestGate<Value: Sendable>: @unchecked Sendable {
    let started: XCTestExpectation
    let returned: XCTestExpectation
    private let lock = NSLock()
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    init(started: XCTestExpectation, returned: XCTestExpectation) {
        self.started = started
        self.returned = returned
    }

    func wait() async -> Value {
        let received: Value = await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Value? in
                if let value = self.value { return value }
                self.continuation = continuation
                return nil
            }
            started.fulfill()
            if let ready { continuation.resume(returning: ready) }
        }
        returned.fulfill()
        return received
    }

    func finish(_ value: Value) {
        let waiter = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard self.value == nil else { return nil }
            self.value = value
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(returning: value)
    }
}

func waitForAvailablePlanningWorker(_ worker: ComputerUsePlanningWorker) async throws {
    for _ in 0..<100 {
        do { try worker.requireAvailable(); return }
        catch ComputerUsePlanningWorker.Failure.busy { try await Task.sleep(for: .milliseconds(1)) }
    }
    XCTFail("The actual planner return must release its retained permit")
    try worker.requireAvailable()
}
