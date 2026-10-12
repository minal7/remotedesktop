import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentMacEnvironmentTests: XCTestCase {
    func testMovedElementUsesFreshBoxWithoutChangingItsIdentity() async throws {
        let backend = Backend(snapshot: snapshot())
        let environment = MacEnvironment(taskID: "task", backend: backend)
        let original = try await environment.observe(context)
        backend.value = snapshot(x: 60)
        let resolved = try await environment.resolve(.click(target: .element(id: 1), button: nil, count: nil), in: original)
        XCTAssertEqual(resolved.targets.first?.bbox.x, 60)
        _ = try await environment.execute(resolved)
        XCTAssertEqual(backend.performedSnapshots.first?.elements.first?.bbox.x, 60)
    }

    func testWindowChangeRejectsBeforeInput() async throws {
        let backend = Backend(snapshot: snapshot())
        let environment = MacEnvironment(taskID: "task", backend: backend)
        let original = try await environment.observe(context)
        backend.value = snapshot(identity: "another-window")
        await rejects(.scopeChanged) { _ = try await environment.resolve(.key(chord: "tab"), in: original) }
        XCTAssertTrue(backend.performedSnapshots.isEmpty)
    }

    func testChangedNameDisabledAndCoveredTargetsRejectBeforeInput() async throws {
        for (name, states, expected) in [("Different", ["enabled"], AgentEnvironmentError.targetChanged),
                                         ("Field", ["disabled"], .disabledTarget), ("Field", ["covered"], .targetCovered)] {
            let backend = Backend(snapshot: snapshot())
            let environment = MacEnvironment(taskID: "task", backend: backend)
            let original = try await environment.observe(context)
            backend.value = snapshot(name: name, states: states)
            await rejects(expected) { _ = try await environment.resolve(.click(target: .element(id: 1), button: nil, count: nil), in: original) }
        }
    }

    func testChangedPayloadAfterGateRejectsBeforeInput() async throws {
        let backend = Backend(snapshot: snapshot(value: "original"))
        let environment = MacEnvironment(taskID: "task", backend: backend)
        let original = try await environment.observe(context)
        let resolved = try await environment.resolve(.click(target: .element(id: 1), button: nil, count: nil), in: original)
        backend.value = snapshot(value: "changed")
        await rejects(.targetChanged) { _ = try await environment.execute(resolved) }
        XCTAssertTrue(backend.performedSnapshots.isEmpty)
    }

    func testImplicitTypingCannotFollowChangedFocus() async throws {
        let backend = Backend(snapshot: snapshot())
        let environment = MacEnvironment(taskID: "task", backend: backend)
        let original = try await environment.observe(context)
        backend.value = snapshot(focusID: 2)
        await rejects(.targetChanged) { _ = try await environment.resolve(.type(target: nil, text: "hello", mode: .replace), in: original) }
    }

    func testChangedFullPayloadDigestRejectsEvenWhenModelObservationIsUnchanged() async throws {
        var originalSnapshot = snapshot(value: "same visible prefix")
        originalSnapshot.authorityDigest = String(repeating: "a", count: 64)
        let backend = Backend(snapshot: originalSnapshot)
        let environment = MacEnvironment(taskID: "task", backend: backend)
        let original = try await environment.observe(context)
        let resolved = try await environment.resolve(.click(target: .element(id: 1), button: nil, count: nil), in: original)
        backend.value.authorityDigest = String(repeating: "b", count: 64)
        await rejects(.targetChanged) { _ = try await environment.execute(resolved) }
        XCTAssertTrue(backend.performedSnapshots.isEmpty)
    }

    func testSuspendRetainsWindowForExplicitResume() async throws {
        let backend = Backend(snapshot: snapshot())
        let environment = MacEnvironment(taskID: "task", backend: backend)
        _ = try await environment.observe(context)
        await environment.suspend()
        do { _ = try await environment.observe(context); XCTFail("Suspended environment observed") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await environment.resume()
        let resumed = try await environment.observe(context)
        XCTAssertEqual(resumed.scope.identity, "window")
        XCTAssertEqual(backend.suspends, 1)
        XCTAssertEqual(backend.resumes, 1)
        await environment.stop()
        do { try await environment.resume(); XCTFail("Stopped environment resumed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPointTargetsRetainSecureSemanticsForTheGate() async throws {
        let backend = Backend(snapshot: snapshot(states: ["enabled", "secure"], value: nil))
        let environment = MacEnvironment(taskID: "task", backend: backend)
        let original = try await environment.observe(context)
        let resolved = try await environment.resolve(.type(target: .point(x: 15, y: 15), text: "secret", mode: .replace), in: original)
        XCTAssertEqual(resolved.targets.first?.state, ["enabled", "secure"])
    }

    func testKeyModifiersMatchTheInputInjectorWireMask() throws {
        XCTAssertEqual(try AgentKeyStroke.parse("cmd+shift+a"), .init(usage: 4, modifiers: 9))
        XCTAssertEqual(try AgentKeyStroke.parse("ctrl+alt+enter"), .init(usage: 0x28, modifiers: 6))
        XCTAssertThrowsError(try AgentKeyStroke.parse("shell+run"))
        XCTAssertThrowsError(try AgentKeyStroke.parse("cmd+"))
    }

    private var context: AgentObservationContext { .init(task: "Edit a field", history: [], budget: .init(step: 0, maxSteps: 40)) }

    private func snapshot(identity: String = "window", x: Double = 10, name: String = "Field",
                          states: [String] = ["enabled"], value: String? = "", focusID: Int = 1) -> AgentMacSnapshot {
        .init(identity: identity, bundleID: "test.app", title: "Document", screenshot: Data([1]),
              elements: [.init(id: 1, role: "textbox", name: name, value: value, state: states,
                               bbox: .init(x: x, y: 10, width: 30, height: 20), inView: true)],
              focus: .init(id: focusID, role: "textbox", name: name, valuePrefix: states.contains("secure") ? "" : value ?? "", selection: .init(start: 0, end: 0)))
    }

    private func rejects(_ expected: AgentEnvironmentError, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? AgentEnvironmentError, expected) }
    }

    private final class Backend: AgentMacBackend {
        var value: AgentMacSnapshot
        var performedSnapshots: [AgentMacSnapshot] = []
        var suspends = 0, resumes = 0
        init(snapshot: AgentMacSnapshot) { value = snapshot }
        func snapshot() async throws -> AgentMacSnapshot { value }
        func perform(_ action: AgentAction, snapshot: AgentMacSnapshot) async throws -> String {
            performedSnapshots.append(snapshot); return "ok"
        }
        func stop() {}
        func suspend() { suspends += 1 }
        func resume() { resumes += 1 }
    }
}
