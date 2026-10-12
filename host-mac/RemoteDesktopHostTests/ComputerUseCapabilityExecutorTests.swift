import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseCapabilityExecutorTests: XCTestCase {
    func testMacToolsReadinessDoesNotPretendVisualControlIsInstalled() async throws {
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil })
        executor.setDesktopFactory(includesVisualControl: false) { _ in RoutingDesktopFixture() }
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.hasAdditionalSetup)
        XCTAssertTrue(executor.readyDetail.contains("Mac tools are ready"))
        XCTAssertTrue(executor.readyDetail.contains("visual control needs setup"))
        let result = try await executor.execute(taskID: "structured", prompt: "Use a Mac tool",
            trustedUserPrompt: "Use a Mac tool", tools: tools(), progress: { _ in })
        XCTAssertEqual(result, .completed("fixture"))
        executor.setDesktopFactory { _ in RoutingDesktopFixture() }
        XCTAssertFalse(executor.hasAdditionalSetup)
    }

    func testDeferredVisualRetainsTypedTaskAndContinuationWithoutReloading() async throws {
        var loads = 0
        let actual = RoutingDesktopFixture()
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in loads += 1; return actual })
        XCTAssertTrue(deferred.isReady)
        XCTAssertEqual(loads, 0)
        let conversation = [ComputerUseConversationTurn(role: .assistant, text: "Earlier model context")]
        for _ in 0..<2 {
            _ = try await deferred.execute(taskID: "visual", modelPrompt: "Full model context", currentUserPrompt: "Current goal",
                conversation: conversation, tools: tools(), progress: { _ in })
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(actual.taskIDs, ["visual", "visual"])
        XCTAssertEqual(actual.trustedPrompts, ["Current goal", "Current goal"])
        XCTAssertEqual(actual.conversations, [conversation, conversation])
        let continuation = ComputerUseVisualApprovalContinuation(taskID: "visual", nonce: UUID())
        let result = try await deferred.continueAfterApprovedVisualAction(continuation,
            action: .typeText("value"), tools: tools(), progress: { _ in })
        XCTAssertEqual(result, .completed("continued"))
        XCTAssertEqual(actual.visualContinuations, [continuation])
        XCTAssertEqual(loads, 1)
        do {
            _ = try await deferred.continueAfterApprovedVisualAction(.init(taskID: "other", nonce: UUID()),
                action: .typeText("value"), tools: tools(), progress: { _ in })
            XCTFail("A continuation from another task cannot acquire the loaded executor")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        XCTAssertEqual(actual.visualContinuations, [continuation])
    }

    func testMissingOrCancelledDeferredVisualCannotExecuteOrCreateContinuation() async throws {
        let unavailable = ComputerUseDeferredVisualExecutor()
        XCTAssertFalse(unavailable.isReady)
        let result = try await unavailable.execute(taskID: "missing", prompt: "A visual task",
            trustedUserPrompt: "A visual task", tools: tools(), progress: { _ in })
        guard case .unableToComplete = result else { return XCTFail("Missing visual control cannot complete a task") }
        do {
            _ = try await unavailable.continueAfterApprovedVisualAction(.init(taskID: "missing", nonce: UUID()),
                action: .typeText("value"), tools: tools(), progress: { _ in })
            XCTFail("An approval cannot load a nonexistent continuation")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }

        var pending: CheckedContinuation<any ComputerUseExecuting, Never>?
        var abandoned = 0
        let actual = RoutingDesktopFixture()
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in
            await withCheckedContinuation { pending = $0 }
        }, abandon: { candidate in
            XCTAssertTrue(candidate === actual)
            abandoned += 1
        })
        let hostTools = tools()
        let task = Task { try await deferred.execute(taskID: "cancelled", prompt: "goal",
            trustedUserPrompt: "goal", tools: hostTools, progress: { _ in }) }
        while pending == nil { await Task.yield() }
        do {
            _ = try await deferred.execute(taskID: "competing", prompt: "other",
                trustedUserPrompt: "other", tools: tools(), progress: { _ in })
            XCTFail("A second load cannot race the first")
        } catch { XCTAssertTrue(error is ComputerUseCapabilityExecutor.RoutingError) }
        task.cancel()
        pending?.resume(returning: actual)
        do { _ = try await task.value; XCTFail("Late cancelled load cannot execute") }
        catch is CancellationError {}
        XCTAssertEqual(abandoned, 1)
        XCTAssertTrue(actual.taskIDs.isEmpty)
    }

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
        var nativeFailure: any Error = ComputerUseTextEditError.deliveryUncertain
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            throw nativeFailure
        }, desktopFactory: { _ in loads += 1; return RoutingDesktopFixture() })
        // An error with this name can also originate in response decoding,
        // snapshot validation or preflight. It is not a no-effect decline.
        let failures: [any Error] = [ComputerUseTextEditError.deliveryUncertain,
            ComputerUseBrowserError.unsupportedDocument, ComputerUseBrowserError.pageChanged]
        for failure in failures {
            nativeFailure = failure
            do {
                _ = try await executor.execute(taskID: "t1", prompt: "text", trustedUserPrompt: "Append x.",
                    tools: tools(), progress: { _ in })
                XCTFail("A native error must not fall back")
            } catch {
                if let expected = failure as? ComputerUseTextEditError { XCTAssertEqual(error as? ComputerUseTextEditError, expected) }
                else { XCTAssertEqual(error as? ComputerUseBrowserError, failure as? ComputerUseBrowserError) }
            }
        }
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

    func testPauseAndStopMCPCallsForwardSeparatelyToDesktop() async throws {
        let desktop = RoutingDesktopFixture()
        let executor = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil },
            desktopFactory: { _ in desktop })
        _ = try await executor.execute(taskID: "pause-forward", prompt: "Open an app.",
            trustedUserPrompt: "Open an app.", tools: tools(), progress: { _ in })
        executor.pauseMCPWork()
        XCTAssertEqual(desktop.pauses, 1)
        XCTAssertEqual(desktop.cancellations, 0)
        executor.cancelMCPWork()
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
private final class RoutingDesktopFixture: ComputerUseExecuting, MCPApprovalContinuing, ComputerUseVisualApprovalContinuing {
    let isReady = true
    let runtimeName = "fixture"
    var cancellations = 0
    var pauses = 0
    var result: ComputerUseExecutionResult = .completed("fixture")
    func cancelMCPWork() { cancellations += 1 }
    func pauseMCPWork() { pauses += 1 }
    func continueAfterApproval(_ prepared: MCPPreparedApproval, tools: ComputerUseHostTools,
                              progress: @escaping (String) -> Void) async throws -> MCPApprovedActionResult {
        throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation
    }
    var taskIDs: [String] = []
    var trustedPrompts: [String] = []
    var conversations: [[ComputerUseConversationTurn]] = []
    var visualContinuations: [ComputerUseVisualApprovalContinuation] = []
    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        conversations.append(conversation)
        return try await execute(taskID: taskID, prompt: modelPrompt, trustedUserPrompt: currentUserPrompt,
                                 tools: tools, progress: progress)
    }
    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        visualContinuations.append(continuation)
        return .completed("continued")
    }
    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {}
    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        XCTFail("The typed task boundary must be retained")
        return .unableToComplete("unexpected entry point")
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        taskIDs.append(taskID)
        trustedPrompts.append(trustedUserPrompt)
        return result
    }
}
