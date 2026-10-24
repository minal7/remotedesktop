#if DEBUG
import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import MemoryStoreKit

@MainActor
final class PersonalMemoryTaskContextProviderTests: XCTestCase {
    func testDebugMemoryPhaseTraceWritesOnlyFixedCodes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("phases.jsonl")
        let trace = try DebugAgentEvalMemoryPhaseTrace(url: url)
        trace.record(.activateEmbedding, .begin)
        let data = try Data(contentsOf: url)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["t_ms", "phase", "marker"]))
        XCTAssertEqual(value["phase"] as? String, "activate_embedding")
        XCTAssertEqual(value["marker"] as? String, "begin")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("model"))
    }

    func testDebugEvaluationProviderUsesSharedRetrievalAndKeepsReceiptValueFree() async throws {
        let definition = try XCTUnwrap(DebugAgentEvalMemoryFixtureDefinition.forCase("memory-recall-10-01"))
        let records = definition.records + [.init(id: "fact-seat-context", kind: .fact,
            body: "Synthetic note: aisle seat is preferred for long flights.", observedAt: 110, active: true)]
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: records, ownerID: "synthetic-owner", sessionID: "synthetic-session",
            taskID: "memory-recall-10-01"))
        defer { try? fixture.close() }
        let counter = ProviderCounter()
        let provider = DebugAgentEvalMemoryContextProvider(fixture: fixture,
            caseID: "memory-recall-10-01", runID: "11111111-1111-1111-1111-111111111111",
            runToken: String(repeating: "b", count: 32), supersededIDs: definition.supersededIDs,
            runtime: counter.runtime(), embeddingInputs: { ProviderStoreFixture.embeddingInputs },
            faraRuntimeInputs: { ProviderStoreFixture.faraInputs })
        let lease = evaluationLease(fixture)
        let capturedBinding = try await provider.captureBinding(for: lease)
        let binding = try XCTUnwrap(capturedBinding)

        let preparedContext = try await provider.prepare(lease: lease, binding: binding,
            prompt: "Book my usual seat on this flight.")
        let context = try XCTUnwrap(preparedContext)
        XCTAssertTrue(context.contains("Prefers an aisle seat when available."))
        XCTAssertFalse(context.contains("Previously preferred a window seat."))
        let preparedReceipt = await provider.receipt()
        let receipt = try XCTUnwrap(preparedReceipt)
        XCTAssertEqual(receipt.selectedMemoryItemIDs, ["fact-seat-context", "profile-seat-aisle"])
        XCTAssertEqual(receipt.excludedSupersededMemoryItemIDs, ["profile-seat-window-old"])
        XCTAssertEqual(receipt.bindingReference, fixture.binding.reference)
        XCTAssertEqual(receipt.contextSHA256, SHA256.hash(data: Data(context.utf8))
            .map { String(format: "%02x", $0) }.joined())
        XCTAssertGreaterThan(counter.snapshot().embed, 0, "This focused test injects a fake runtime; live measurement uses the production runtime.")
        XCTAssertGreaterThan(counter.snapshot().countTokens, 0)
    }

    func testDebugEvaluationProviderReturnsEmptyContextWhenNoActiveRowsExist() async throws {
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [.init(id: "inactive-contact", kind: .fact,
                body: "Synthetic inactive contact fact.", observedAt: 10, active: false)],
            ownerID: "synthetic-owner", sessionID: "synthetic-session", taskID: "empty-memory-task"))
        defer { try? fixture.close() }
        let counter = ProviderCounter()
        let provider = DebugAgentEvalMemoryContextProvider(fixture: fixture,
            caseID: "memory-recall-10-01", runID: "22222222-2222-2222-2222-222222222222",
            runToken: String(repeating: "c", count: 32), supersededIDs: [],
            runtime: counter.runtime(), embeddingInputs: { ProviderStoreFixture.embeddingInputs },
            faraRuntimeInputs: { ProviderStoreFixture.faraInputs })
        let lease = evaluationLease(fixture)
        let capturedBinding = try await provider.captureBinding(for: lease)
        let binding = try XCTUnwrap(capturedBinding)

        let preparedContext = try await provider.prepare(lease: lease, binding: binding,
            prompt: "Use my ordinary contact fact.")
        let context = try XCTUnwrap(preparedContext)
        XCTAssertEqual(context, "[]")
        let preparedReceipt = await provider.receipt()
        XCTAssertEqual(preparedReceipt?.selectedMemoryItemIDs, [])
        XCTAssertEqual(counter.snapshot().embed, 0)
        XCTAssertGreaterThan(counter.snapshot().countTokens, 0)
    }

    func testDebugEvaluationProviderCancellationDoesNotCreateDeliveryReceipt() async throws {
        let definition = try XCTUnwrap(DebugAgentEvalMemoryFixtureDefinition.forCase("memory-recall-10-01"))
        let records = definition.records + [.init(id: "fact-seat-context", kind: .fact,
            body: "Synthetic note: aisle seat is preferred for long flights.", observedAt: 110, active: true)]
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: records, ownerID: "synthetic-owner", sessionID: "synthetic-session",
            taskID: "memory-recall-10-01"))
        defer { try? fixture.close() }
        let gate = ProviderGate()
        let counter = ProviderCounter()
        let provider = DebugAgentEvalMemoryContextProvider(fixture: fixture,
            caseID: "memory-recall-10-01", runID: "33333333-3333-3333-3333-333333333333",
            runToken: String(repeating: "d", count: 32), supersededIDs: definition.supersededIDs,
            runtime: counter.runtime(onEmbed: { await gate.pause() }),
            embeddingInputs: { ProviderStoreFixture.embeddingInputs },
            faraRuntimeInputs: { ProviderStoreFixture.faraInputs })
        let lease = evaluationLease(fixture)
        let capturedBinding = try await provider.captureBinding(for: lease)
        let binding = try XCTUnwrap(capturedBinding)
        let preparation = Task {
            try await provider.prepare(lease: lease, binding: binding,
                prompt: "Book my usual seat on this flight.")
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else {
            preparation.cancel()
            await gate.release()
            _ = try? await preparation.value
            return
        }
        preparation.cancel()
        await gate.release()
        do {
            _ = try await preparation.value
            XCTFail("Cancelled retrieval must not deliver a context")
        } catch is CancellationError {}
        let preparedReceipt = await provider.receipt()
        XCTAssertNil(preparedReceipt)
    }

    private func evaluationLease(_ fixture: MemoryEvaluationFixture) -> LocalMemoryHostLease {
        LocalMemoryHostLease(peerID: fixture.ownerID, sessionID: fixture.sessionID,
            taskID: fixture.taskID, authorizationGeneration: 1, taskAuthority: .active,
            memoryPolicy: .init())
    }

    func testDisabledAndRestrictedPoliciesTouchNoStorageOrRuntime() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        for (enabled, policy) in [
            (false, ComputerUseTaskMemoryPolicy()),
            (true, ComputerUseTaskMemoryPolicy(noMemory: true)),
            (true, ComputerUseTaskMemoryPolicy(incognito: true))
        ] {
            let counter = ProviderCounter()
            let provider = makeProvider(enabled: enabled, leaseIsCurrent: { _ in true },
                captureBinding: { counter.capture(); return nil },
                openService: { _, _, _ in counter.open(); return nil }, runtime: counter.runtime())
            let lease = activeLease(policy: policy)

            let captured = try await provider.captureBinding(for: lease)
            let prepared = try await provider.prepare(lease: lease,
                binding: fixture.binding, prompt: "Synthetic prompt")
            XCTAssertNil(captured)
            XCTAssertNil(prepared)
            let counts = counter.snapshot()
            XCTAssertEqual(counts.capture, 0)
            XCTAssertEqual(counts.open, 0)
            XCTAssertEqual(counts.activateEmbedding, 0)
            XCTAssertEqual(counts.embed, 0)
            XCTAssertEqual(counts.activateVision, 0)
            XCTAssertEqual(counts.countTokens, 0)
        }
    }

    func testAbsentStoreIsMemorylessButInvalidOwnerFailsClosed() async throws {
        let counter = ProviderCounter()
        let captureCount = ProviderValidityCounter()
        let absent = makeProvider(leaseIsCurrent: { _ in true },
            captureBinding: { captureCount.increment(); return nil },
            openService: { _, _, _ in counter.open(); return nil },
            runtime: counter.runtime())
        let absentBinding = try await absent.captureBinding(for: activeLease())
        XCTAssertNil(absentBinding)
        XCTAssertEqual(captureCount.value, 1)
        XCTAssertEqual(counter.snapshot().open, 0)
        XCTAssertEqual(counter.snapshot().activateEmbedding, 0)

        let invalidOwner = PersonalMemoryTaskContextProvider(enabled: true,
            ownerID: { nil }, isLeaseCurrent: { _ in true },
            isLeaseCurrentSynchronously: { _ in true },
            faraRuntimeInputs: { ProviderStoreFixture.faraInputs },
            captureBinding: { captureCount.increment(); return nil },
            openService: { _, _, _ in nil }, runtime: counter.runtime(),
            embeddingInputs: { ProviderStoreFixture.embeddingInputs })
        do {
            _ = try await invalidOwner.captureBinding(for: activeLease())
            XCTFail("An enabled task without an owner binding must fail closed")
        } catch is TaskMemoryContextFailure {}
        XCTAssertEqual(captureCount.value, 1, "Invalid owner must be rejected before storage access")
    }

    func testStorageAbsentAfterForgetReturnsEmptyContextWithoutRuntimeActivation() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        let counter = ProviderCounter()
        let leaseChecks = ProviderValidityCounter()
        let provider = makeProvider(
            leaseIsCurrent: { _ in leaseChecks.increment(); return true },
            syncLeaseIsCurrent: { _ in true },
            captureBinding: { fixture.binding },
            openService: { _, binding, _ in
                XCTAssertEqual(binding, fixture.binding)
                counter.open()
                throw MemoryFactoryError.storageAbsent
            }, runtime: counter.runtime())

        let context = try await provider.prepare(lease: activeLease(),
            binding: fixture.binding, prompt: "Using only saved memory, what is my home airport?")

        XCTAssertEqual(context, "[]")
        XCTAssertEqual(counter.snapshot().open, 1)
        XCTAssertEqual(counter.snapshot().activateEmbedding, 0)
        XCTAssertEqual(counter.snapshot().embed, 0)
        XCTAssertEqual(counter.snapshot().activateVision, 0)
        XCTAssertEqual(counter.snapshot().countTokens, 0)
        XCTAssertGreaterThan(leaseChecks.value, 1, "The lease must be revalidated after storage reports absent")
    }

    func testStorageUnavailableAndForgetRecoveryErrorsRemainFailClosed() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        for error in [MemoryFactoryError.storageUnavailable, .forgetRecoveryRequired] {
            let counter = ProviderCounter()
            let provider = makeProvider(leaseIsCurrent: { _ in true },
                captureBinding: { fixture.binding },
                openService: { _, _, _ in
                    counter.open()
                    throw error
                }, runtime: counter.runtime())

            do {
                _ = try await provider.prepare(lease: activeLease(), binding: fixture.binding,
                    prompt: "Using only saved memory, what is my home airport?")
                XCTFail("Only a verified absent store is empty context")
            } catch is TaskMemoryContextFailure {}
            XCTAssertEqual(counter.snapshot().open, 1)
            XCTAssertEqual(counter.snapshot().activateEmbedding, 0)
        }
    }

    func testStorageAbsentDoesNotBypassCancellationOrLeaseRevocation() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        let counter = ProviderCounter()
        let validity = ProviderValidity()
        let revokedProvider = makeProvider(leaseIsCurrent: { _ in validity.isValid() },
            syncLeaseIsCurrent: { _ in validity.isValid() },
            captureBinding: { fixture.binding },
            openService: { _, _, _ in
                counter.open()
                validity.revoke()
                throw MemoryFactoryError.storageAbsent
            }, runtime: counter.runtime())

        do {
            _ = try await revokedProvider.prepare(lease: activeLease(), binding: fixture.binding,
                prompt: "Using only saved memory, what is my home airport?")
            XCTFail("A revoked lease must not turn absent storage into delivered context")
        } catch is TaskMemoryContextFailure {}

        let cancelledProvider = makeProvider(leaseIsCurrent: { _ in true },
            captureBinding: { fixture.binding },
            openService: { _, _, _ in
                counter.open()
                withUnsafeCurrentTask { $0?.cancel() }
                throw MemoryFactoryError.storageAbsent
            }, runtime: counter.runtime())
        let preparation = Task {
            try await cancelledProvider.prepare(lease: activeLease(), binding: fixture.binding,
                prompt: "Using only saved memory, what is my home airport?")
        }
        do {
            _ = try await preparation.value
            XCTFail("A cancelled lease must not turn absent storage into delivered context")
        } catch is CancellationError {}

        XCTAssertEqual(counter.snapshot().activateEmbedding, 0)
        XCTAssertEqual(counter.snapshot().activateVision, 0)
    }

    func testPauseLearningStillAllowsOrdinaryReadRetrieval() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        try fixture.remember("Synthetic active preference")
        let counter = ProviderCounter()
        let lease = activeLease(policy: .init(pauseLearning: true))
        let provider = makeProvider(leaseIsCurrent: { _ in true },
            captureBinding: { fixture.binding },
            openService: { context, binding, _ in
                XCTAssertEqual(context, OwnerMemoryContext(ownerID: fixture.owner,
                    sessionID: lease.sessionID, taskID: lease.taskID))
                XCTAssertEqual(binding, fixture.binding)
                return fixture.service
            }, runtime: counter.runtime())

        let prepared = try await provider.prepare(lease: lease,
            binding: fixture.binding, prompt: "Use my saved preference")
        let context = try XCTUnwrap(prepared)
        XCTAssertTrue(context.contains("Synthetic active preference"))
        let counts = counter.snapshot()
        XCTAssertGreaterThan(counts.embed, 0)
        XCTAssertEqual(counts.activateEmbedding, 1)
        XCTAssertEqual(counts.activateVision, 1)
        XCTAssertGreaterThan(counts.countTokens, 0)
        XCTAssertEqual(counts.cancel, 0)
        XCTAssertEqual(counts.seenVisionInputs, ProviderStoreFixture.faraInputs)
        XCTAssertEqual(counts.countEndpoint, ProviderStoreFixture.faraEndpoint)
        let lastEmbedding = try XCTUnwrap(counts.events.lastIndex(of: "embed"))
        let faraActivation = try XCTUnwrap(counts.events.firstIndex(of: "activate-fara"))
        let firstCount = try XCTUnwrap(counts.events.firstIndex(of: "count"))
        XCTAssertLessThan(lastEmbedding, faraActivation)
        XCTAssertLessThan(faraActivation, firstCount)

    }

    func testLeaseRevokedDuringEmbeddingWithholdsContextAndSkipsFara() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        try fixture.remember("Synthetic active preference")
        let counter = ProviderCounter()
        let validity = ProviderValidity()
        let runtime = counter.runtime(onEmbed: { await validity.revoke() })
        let provider = makeProvider(leaseIsCurrent: { _ in validity.isValid() },
            syncLeaseIsCurrent: { _ in validity.isValid() },
            captureBinding: { fixture.binding },
            openService: { _, _, _ in fixture.service }, runtime: runtime)

        do {
            _ = try await provider.prepare(lease: activeLease(), binding: fixture.binding,
                prompt: "Use my saved preference")
            XCTFail("A result returned after task revocation must be withheld")
        } catch is TaskMemoryContextFailure {}

        let counts = counter.snapshot()
        XCTAssertEqual(counts.activateEmbedding, 1)
        XCTAssertGreaterThan(counts.embed, 0)
        XCTAssertEqual(counts.activateVision, 0)
        XCTAssertEqual(counts.countTokens, 0)
        XCTAssertEqual(counts.cancel, 1)
    }

    func testCancellationDuringEmbeddingCannotReturnLateContext() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        try fixture.remember("Synthetic active preference")
        let counter = ProviderCounter()
        let gate = ProviderGate()
        let provider = makeProvider(leaseIsCurrent: { _ in true },
            captureBinding: { fixture.binding },
            openService: { _, _, _ in fixture.service },
            runtime: counter.runtime(onEmbed: { await gate.pause() }))

        let preparation = Task {
            try await provider.prepare(lease: activeLease(), binding: fixture.binding,
                prompt: "Use my saved preference")
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else {
            preparation.cancel()
            await gate.release()
            _ = try? await preparation.value
            return
        }
        preparation.cancel()
        await gate.release()
        do {
            _ = try await preparation.value
            XCTFail("Cancellation must prevent a late context result")
        } catch is CancellationError {}
        let counts = counter.snapshot()
        XCTAssertEqual(counts.activateVision, 0)
        XCTAssertEqual(counts.cancel, 1)
    }


    func testRevocationDuringFaraTokenCountCancelsExactEndpointsAndWithholdsContext() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        try fixture.remember("Synthetic active preference")
        let counter = ProviderCounter()
        let validity = ProviderValidity()
        let gate = ProviderGate()
        let provider = makeProvider(leaseIsCurrent: { _ in validity.isValid() },
            syncLeaseIsCurrent: { _ in validity.isValid() },
            captureBinding: { fixture.binding },
            openService: { _, _, _ in fixture.service },
            runtime: counter.runtime(onCount: { await gate.pause() }))

        let preparation = Task {
            try await provider.prepare(lease: activeLease(), binding: fixture.binding,
                prompt: "Use my saved preference")
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else {
            preparation.cancel()
            await gate.release()
            _ = try? await preparation.value
            return
        }
        validity.revoke()
        await gate.release()
        do {
            _ = try await preparation.value
            XCTFail("A token-count result after revocation must not be handed to the task")
        } catch is TaskMemoryContextFailure {}

        let counts = counter.snapshot()
        XCTAssertGreaterThan(counts.countTokens, 0)
        XCTAssertEqual(counts.seenVisionInputs, ProviderStoreFixture.faraInputs)
        XCTAssertEqual(counts.countEndpoint, ProviderStoreFixture.faraEndpoint)
        XCTAssertEqual(counts.cancelledEndpoints, [ProviderStoreFixture.faraEndpoint,
            ProviderStoreFixture.embeddingEndpoint])
    }

    func testStaleBindingIsRejectedByBoundOpenerBeforeRuntimeStarts() async throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanup() }
        let counter = ProviderCounter()
        let currentBinding = ProviderBindingCell(fixture.binding)
        let provider = makeProvider(leaseIsCurrent: { _ in true },
            captureBinding: { currentBinding.value },
            openService: { _, binding, _ in
                counter.open()
                guard binding == currentBinding.value else { throw TaskMemoryContextFailure.staleBinding }
                return fixture.service
            }, runtime: counter.runtime())
        let lease = activeLease()
        let captured = try await provider.captureBinding(for: lease)
        let original = try XCTUnwrap(captured)
        currentBinding.value = nil

        do {
            _ = try await provider.prepare(lease: lease, binding: original, prompt: "Synthetic prompt")
            XCTFail("A binding that is no longer current must not open or read storage")
        } catch is TaskMemoryContextFailure {}
        let counts = counter.snapshot()
        XCTAssertEqual(counts.open, 1, "The bound opener must validate identity before returning a service")
        XCTAssertEqual(counts.activateEmbedding, 0)
        XCTAssertEqual(counts.embed, 0)
    }

    private func makeProvider(
        enabled: Bool = true,
        leaseIsCurrent: @escaping @MainActor @Sendable (LocalMemoryHostLease) -> Bool,
        syncLeaseIsCurrent: @escaping @Sendable (LocalMemoryHostLease) -> Bool = { _ in true },
        captureBinding: @escaping @Sendable () throws -> MemoryStoreBinding?,
        openService: @escaping @Sendable (OwnerMemoryContext, MemoryStoreBinding,
            @escaping @Sendable () -> Bool) throws -> PersonalMemoryService?,
        runtime: PersonalMemoryTaskRuntimeOperations
    ) -> PersonalMemoryTaskContextProvider {
        PersonalMemoryTaskContextProvider(enabled: enabled,
            ownerID: { "d" + String(repeating: "e", count: 63) },
            isLeaseCurrent: leaseIsCurrent,
            isLeaseCurrentSynchronously: syncLeaseIsCurrent,
            faraRuntimeInputs: { ProviderStoreFixture.faraInputs },
            captureBinding: captureBinding, openService: openService,
            runtime: runtime,
            embeddingInputs: { ProviderStoreFixture.embeddingInputs })
    }

    private func activeLease(policy: ComputerUseTaskMemoryPolicy = .init()) -> LocalMemoryHostLease {
        LocalMemoryHostLease(peerID: "synthetic-peer", sessionID: "synthetic-session",
            taskID: "synthetic-task", authorizationGeneration: 3, taskAuthority: .active,
            memoryPolicy: policy)
    }

}

private final class ProviderCounter: @unchecked Sendable {
    struct Counts: Sendable {
        var capture = 0
        var open = 0
        var activateEmbedding = 0
        var embed = 0
        var activateVision = 0
        var countTokens = 0
        var cancel = 0
        var events: [String] = []
        var seenVisionInputs: AgentVisionRuntimeInputs?
        var countEndpoint: OSAtlasLlamaEndpoint?
        var cancelledEndpoints: [OSAtlasLlamaEndpoint] = []
    }
    private let lock = NSLock()
    private var counts = Counts()
    private let onEmbed: (@Sendable () async -> Void)?
    private let onCount: (@Sendable () async -> Void)?

    init(onEmbed: (@Sendable () async -> Void)? = nil,
         onCount: (@Sendable () async -> Void)? = nil) {
        self.onEmbed = onEmbed
        self.onCount = onCount
    }
    func capture() { lock.lock(); counts.capture += 1; lock.unlock() }
    func open() { lock.lock(); counts.open += 1; lock.unlock() }
    func snapshot() -> Counts { lock.lock(); defer { lock.unlock() }; return counts }

    func runtime(onEmbed: (@Sendable () async -> Void)? = nil,
                 onCount: (@Sendable () async -> Void)? = nil) -> PersonalMemoryTaskRuntimeOperations {
        let owner = self
        return PersonalMemoryTaskRuntimeOperations(
            activateEmbedding: { _ in owner.bumpEmbedding(); return ProviderStoreFixture.embeddingEndpoint },
            embed: { _, _, _ in
                owner.bumpEmbed()
                await (onEmbed ?? owner.onEmbed)?()
                return Array(repeating: 1, count: PersonalMemoryRuntimeInputs.embeddingDimensions)
            },
            activateAgentVision: { inputs in owner.bumpVision(inputs); return ProviderStoreFixture.faraEndpoint },
            countMemoryTokens: { endpoint, context in
                owner.bumpCount(endpoint)
                await (onCount ?? owner.onCount)?()
                return max(1, context.split(whereSeparator: \.isWhitespace).count)
            },
            cancel: { endpoint in owner.bumpCancel(endpoint) })
    }

    private func update(_ mutation: (inout Counts) -> Void) { lock.lock(); defer { lock.unlock() }; mutation(&counts) }
    private func bumpEmbedding() { update { $0.activateEmbedding += 1; $0.events.append("activate-nomic") } }
    private func bumpEmbed() { update { $0.embed += 1; $0.events.append("embed") } }
    private func bumpVision(_ inputs: AgentVisionRuntimeInputs) {
        update { $0.activateVision += 1; $0.events.append("activate-fara"); $0.seenVisionInputs = inputs }
    }
    private func bumpCount(_ endpoint: OSAtlasLlamaEndpoint) {
        update { $0.countTokens += 1; $0.events.append("count"); $0.countEndpoint = endpoint }
    }
    private func bumpCancel(_ endpoint: OSAtlasLlamaEndpoint) {
        update { $0.cancel += 1; $0.cancelledEndpoints.append(endpoint) }
    }
}

private final class ProviderValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func revoke() { lock.lock(); valid = false; lock.unlock() }
    func isValid() -> Bool { lock.lock(); defer { lock.unlock() }; return valid }
}

private final class ProviderValidityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}

private actor ProviderGate {
    private var entered = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class ProviderBindingCell: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MemoryStoreBinding?
    init(_ binding: MemoryStoreBinding?) { stored = binding }
    var value: MemoryStoreBinding? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class ProviderStoreFixture {
    static let embeddingInputs = PersonalMemoryRuntimeInputs(modelURL: URL(fileURLWithPath: "/synthetic/model"),
        llamaServerURL: URL(fileURLWithPath: "/synthetic/llama-server"))
    static let faraInputs = AgentVisionRuntimeInputs(model: .fara15_4b,
        modelURL: URL(fileURLWithPath: "/synthetic/fara"),
        projectorURL: URL(fileURLWithPath: "/synthetic/projector"),
        llamaServerURL: URL(fileURLWithPath: "/synthetic/llama-server"))
    static let embeddingEndpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
        baseURL: URL(string: "http://127.0.0.1:12345")!, bearerToken: "synthetic")
    static let faraEndpoint = OSAtlasLlamaEndpoint(generation: 2, variant: nil,
        baseURL: URL(string: "http://127.0.0.1:12346")!, bearerToken: "synthetic-fara")

    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("TaskMemoryProvider-\(UUID())", isDirectory: true)
    let root: URL
    let service: PersonalMemoryService
    let binding: MemoryStoreBinding
    let owner = "d" + String(repeating: "e", count: 63)

    init() throws {
        root = parent.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try MemoryStoreFactory.preparePrivateRoot(root)
        let namespace = KeychainNamespace.testing(UUID().uuidString)
        let keys = ProviderKeychain()
        let ownerID = owner
        service = try XCTUnwrap(try MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: keys, random: ProviderRandom(), namespace: namespace,
            authorize: { $0.ownerID == ownerID }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace))
    }
    func remember(_ text: String) throws {
        try service.writer.remember(kind: .fact, text: text, commandID: UUID().uuidString.lowercased(),
            context: OwnerMemoryContext(ownerID: owner, sessionID: "synthetic-session", taskID: "synthetic-task"))
    }
    func cleanup() {
        try? service.close()
        try? FileManager.default.removeItem(at: parent)
    }
}

private struct ProviderRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x39, count: count) }
}

private final class ProviderKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    func add(_ item: ExactKeychainItem, data: Data) throws { lock.lock(); defer { lock.unlock() }; values[item] = data }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }
    func delete(_ item: ExactKeychainItem) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: item) }
    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] != nil else { throw KeychainBoundaryError.missingItem }
        values[item] = data
    }
}
#endif
