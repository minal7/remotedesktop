import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import MemoryStoreKit

@MainActor
final class PersonalMemoryEmptyContextTests: XCTestCase {
    func testValidEmptyJSONArrayContextIsIdenticalToNoMemoryObservation() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let observation = AgentObservation(task: "Describe the visible page", surface: .web(url: "https://example.test", title: "Fixture"),
            screenshot: "synthetic screenshot", elements: [], focus: nil, history: [], budget: .init(step: 2, maxSteps: 5))
        let noMemoryBase = ContextRecordingPolicy()
        let noMemoryPolicy = TaskMemoryContextPolicy.applying(taskID: "no-memory-baseline", slot: nil,
            base: noMemoryBase)
        _ = try await noMemoryPolicy.propose(observation)
        let noMemoryObservation = try XCTUnwrap(noMemoryBase.seen)

        for (index, context) in ["[]", " \n [ ] \t"].enumerated() {
            let taskID = "empty-context-\(index)"
            let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(), sessionID: "empty-context-session-\(index)",
                taskID: taskID, authorizationGeneration: 12, taskAuthority: .active)
            let slot = TaskMemoryContextSlot()
            slot.stage(context, taskID: taskID, lease: lease, binding: store.binding, isCurrent: { true })
            let authority = AgentMemoryDisclosureAuthority(taskID: taskID, slot: slot)
            let base = ContextRecordingPolicy()
            let policy = TaskMemoryContextPolicy.applying(taskID: taskID, slot: slot, base: base,
                memoryDisclosureAuthority: authority)

            _ = try await policy.propose(observation)

            XCTAssertEqual(base.seen, noMemoryObservation, "A semantically empty array must match the no-memory path exactly.")
            XCTAssertTrue(slot.hasLease(taskID: taskID), "Empty context still retains the accepted lease checks.")
            guard case .none = authority.state(for: taskID) else {
                return XCTFail("An empty memory result must not create disclosure authority.")
            }
        }
    }

    func testMalformedContextIsNotTreatedAsEmpty() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let taskID = "malformed-context-task", slot = TaskMemoryContextSlot()
        let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(), sessionID: "malformed-context-session",
            taskID: taskID, authorizationGeneration: 12, taskAuthority: .active)
        let malformed = "{"
        slot.stage(malformed, taskID: taskID, lease: lease, binding: store.binding, isCurrent: { true })
        let authority = AgentMemoryDisclosureAuthority(taskID: taskID, slot: slot)
        let observation = AgentObservation(task: "Describe the visible page", surface: .web(url: "https://example.test", title: nil),
            screenshot: "synthetic screenshot", elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 2))
        let base = ContextRecordingPolicy()
        let policy = TaskMemoryContextPolicy.applying(taskID: taskID, slot: slot, base: base,
            memoryDisclosureAuthority: authority)

        _ = try await policy.propose(observation)

        XCTAssertEqual(base.seen?.task, observation.task + "\n\n<saved-memory-reference-data>\n{\n</saved-memory-reference-data>")
        guard case .current = authority.state(for: taskID) else {
            return XCTFail("Malformed context must remain fail-closed as attached memory, not be downgraded to empty.")
        }
    }

    func testEmptyJSONArrayContextStillTerminatesWhenLeaseIsRevokedInFlight() async throws {
        let store = try ContextStoreFixture()
        defer { store.cleanup() }
        let taskID = "empty-context-revoked-task", slot = TaskMemoryContextSlot()
        let lease = LocalMemoryHostLease(peerID: UUID().uuidString.lowercased(), sessionID: "empty-context-revoked-session",
            taskID: taskID, authorizationGeneration: 12, taskAuthority: .active)
        slot.stage("[]", taskID: taskID, lease: lease, binding: store.binding, isCurrent: { true })
        let base = BlockingContextPolicy()
        let policy = TaskMemoryContextPolicy.applying(taskID: taskID, slot: slot, base: base)
        let observation = AgentObservation(task: "Describe the visible page", surface: .web(url: "https://example.test", title: nil),
            screenshot: "synthetic screenshot", elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 2))
        let proposal = Task { try await policy.propose(observation) }
        let entered = await base.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { slot.revokeAuthorization(); return }

        slot.revokeAuthorization()
        await base.release()
        do {
            _ = try await proposal.value
            XCTFail("An empty result must not bypass in-flight lease revocation.")
        } catch AgentPolicyTermination.authorizationRevoked {}
        XCTAssertEqual(base.seen, observation)
    }
}
