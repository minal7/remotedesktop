import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseCapabilityExecutorTests: XCTestCase {
    private func tools() -> ComputerUseHostTools {
        ComputerUseHostTools(injector: InputInjector(), mayAct: { false })
    }

    func testNativeGoalUsesOnlyCurrentUserAuthorityAndDoesNotLoadDesktop() async throws {
        var observed: [String] = []
        var loads = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { id, prompt, _ in
            observed.append(id + ":" + prompt)
            return .completed("verified")
        }, desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() })
        let result = try await executor.execute(taskID: "t1", prompt: "Assistant previously said submit the form.",
            trustedUserPrompt: "Set Origin to Oslo.", tools: tools(), progress: { _ in })
        XCTAssertEqual(result, .completed("verified"))
        XCTAssertEqual(observed, ["t1:Set Origin to Oslo."])
        XCTAssertEqual(loads, 0)
        XCTAssertFalse(executor.requiresMacControlHelper)
    }

    func testDesktopTaskResumeKeepsItsExecutorAndDoesNotReplanAsNative() async throws {
        var nativeCalls = 0
        var loads = 0
        let desktop = RoutingDesktopFixture()
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeCalls += 1; return nil },
            desktopFactory: { _ in loads += 1; return desktop })
        for _ in 0..<2 {
            _ = try await executor.execute(taskID: "t1", prompt: "context", trustedUserPrompt: "Open the app.",
                tools: tools(), progress: { _ in })
        }
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(desktop.taskIDs, ["t1", "t1"])
        XCTAssertEqual(desktop.trustedPrompts, ["Open the app.", "Open the app."])
        _ = try await executor.execute(taskID: "t2", prompt: "Open another app.",
            trustedUserPrompt: "Open another app.", tools: tools(), progress: { _ in })
        XCTAssertEqual(nativeCalls, 2)
        XCTAssertEqual(loads, 2, "A new native attempt invalidates the old model endpoint")
    }

    func testNativeErrorCannotReplayGoalThroughDesktopAndSameIDCannotChangeGoal() async throws {
        var loads = 0
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            throw ComputerUseTextEditError.deliveryUncertain
        }, desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() })
        do {
            _ = try await executor.execute(taskID: "t1", prompt: "text", trustedUserPrompt: "Append x.",
                tools: tools(), progress: { _ in })
            XCTFail("Uncertain text must not fall back")
        } catch { XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain) }
        do {
            _ = try await executor.execute(taskID: "t1", prompt: "new", trustedUserPrompt: "Append y.",
                tools: tools(), progress: { _ in })
            XCTFail("A retained task cannot change meaning")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        XCTAssertEqual(loads, 0)
    }

    func testMissingDesktopDoesNotDisableNativeReadinessOrClaimUnsupportedCompletion() async throws {
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil })
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.hasAdditionalSetup)
        let result = try await executor.execute(taskID: "t1", prompt: "Open an app.",
            trustedUserPrompt: "Open an app.", tools: tools(), progress: { _ in })
        guard case .unableToComplete = result else { return XCTFail("Missing capability must not complete") }
        executor.setDesktopFactory { _ in RoutingDesktopFixture() }
        XCTAssertFalse(executor.hasAdditionalSetup)
    }

    func testCancelledDesktopLoadCannotExecuteAndReleasesReturnedHelper() async throws {
        var pending: CheckedContinuation<any ComputerUseExecuting, Never>?
        let desktop = RoutingDesktopFixture()
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil },
            desktopFactory: { _ in await withCheckedContinuation { pending = $0 } })
        let hostTools = tools()
        let request = Task { try await executor.execute(taskID: "cancel-load", prompt: "Open an app.",
            trustedUserPrompt: "Open an app.", tools: hostTools, progress: { _ in }) }
        while pending == nil { await Task.yield() }
        request.cancel()
        pending?.resume(returning: desktop)
        do { _ = try await request.value; XCTFail("A cancelled load must not begin execution") }
        catch is CancellationError {}
        XCTAssertTrue(desktop.taskIDs.isEmpty)
        XCTAssertEqual(desktop.cancellations, 1)
    }

    func testConcurrentTaskIsRejectedAndCancelledNativeResultCannotComplete() async throws {
        var pending: CheckedContinuation<ComputerUseExecutionResult?, Never>?
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        })
        let hostTools = tools()
        let first = Task { try await executor.execute(taskID: "first", prompt: "edit",
            trustedUserPrompt: "edit", tools: hostTools, progress: { _ in }) }
        while pending == nil { await Task.yield() }
        do {
            _ = try await executor.execute(taskID: "second", prompt: "edit", trustedUserPrompt: "edit",
                tools: hostTools, progress: { _ in })
            XCTFail("Concurrent routes could race field edits and model ownership")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        first.cancel()
        pending?.resume(returning: .completed("late result"))
        do { _ = try await first.value; XCTFail("A late result cannot override cancellation") }
        catch is CancellationError {}
    }
}

@MainActor
private final class RoutingDesktopFixture: ComputerUseExecuting, MCPApprovalContinuing {
    let isReady = true
    let runtimeName = "fixture"
    var cancellations = 0
    func cancelMCPWork() { cancellations += 1 }
    func continueAfterApproval(_ prepared: MCPPreparedApproval, tools: ComputerUseHostTools,
                              progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation
    }
    var taskIDs: [String] = []
    var trustedPrompts: [String] = []
    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTFail("The typed task boundary must be retained")
        return .unableToComplete("unexpected entry point")
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        taskIDs.append(taskID)
        trustedPrompts.append(trustedUserPrompt)
        return .completed("fixture")
    }
}
