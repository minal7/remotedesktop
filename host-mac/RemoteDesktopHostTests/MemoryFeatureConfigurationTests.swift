import XCTest
@testable import RemoteDesktopHost

final class MemoryFeatureConfigurationTests: XCTestCase {
    func testMemoryFeatureBuildGateMatchesCompilationMode() {
#if MEMORY_V1_SHIPPING_BETA && !DEBUG
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [:]))
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "0"
        ]))
#elseif DEBUG
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [:]))
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "0"
        ]))
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "1"
        ]))
#else
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [:]))
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "1"
        ]))
#endif
    }

    @MainActor
    func testMissingMemorySlotPreservesBasePolicyIdentity() {
        let base = MemorylessPolicy()
        let selected = TaskMemoryContextPolicy.applying(taskID: "memory-off-test", slot: nil, base: base)
        XCTAssertTrue(selected === base)
    }
}

@MainActor
private final class MemorylessPolicy: AgentPolicy {
    let promptVersion = "memoryless-test-policy"

    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        AgentPolicyOutput(rawOutput: "", action: nil, rejectionReason: nil)
    }

    func stop() async {}
}
