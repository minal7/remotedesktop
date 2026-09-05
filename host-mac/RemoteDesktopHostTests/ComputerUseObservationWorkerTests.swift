import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseObservationWorkerTests: XCTestCase {
    func testBlockingObservationLeavesMainActorResponsiveAndTimesOut() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "native work started")
        let exited = expectation(description: "native work exited")
        let read = Task {
            try await ComputerUseObservationWorker.perform(timeout: 0.1) {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                release.wait()
                exited.fulfill()
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 1)
        // This actor can still process takeover while the native call waits.
        var takeoverHandled = false
        await Task { @MainActor in takeoverHandled = true }.value
        XCTAssertTrue(takeoverHandled)
        do {
            _ = try await read.value
            XCTFail("The native operation did not finish before its deadline")
        } catch {
            XCTAssertEqual(error as? ComputerUseObservationWorker.Failure, .timedOut)
        }
        do {
            _ = try await ComputerUseObservationWorker.perform { 0 }
            XCTFail("An obsolete blocked request must retain the one worker permit")
        } catch {
            XCTAssertEqual(error as? ComputerUseObservationWorker.Failure, .busy)
        }
        release.signal()
        await fulfillment(of: [exited], timeout: 1)
        try await waitForReleasedWorker()
    }

    func testCancellationReturnsWithoutWaitingForBlockedNativeCall() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "native work started")
        let exited = expectation(description: "native work exited")
        let read = Task {
            try await ComputerUseObservationWorker.perform(timeout: 5) {
                started.fulfill()
                release.wait()
                exited.fulfill()
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let start = ContinuousClock.now
        read.cancel()
        do {
            _ = try await read.value
            XCTFail("Cancelled observations must not deliver a value")
        } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        release.signal()
        await fulfillment(of: [exited], timeout: 1)
        try await waitForReleasedWorker()
    }

    private func waitForReleasedWorker() async throws {
        for _ in 0 ..< 100 {
            do {
                let result = try await ComputerUseObservationWorker.perform { 7 }
                XCTAssertEqual(result, 7)
                return
            } catch ComputerUseObservationWorker.Failure.busy {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        XCTFail("The finished native operation did not release capacity")
    }
}
