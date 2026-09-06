import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTaskExecutionTests: XCTestCase {
    func testTwoExecutorsWithTheSameFreshSnapshotCannotBothDispatchOrRewindProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try SearchTransactionFixture()
        let firstStore = try ComputerUseTaskJournalStore(directory: directory), staleStore = try ComputerUseTaskJournalStore(directory: directory)
        var firstExpected = try firstStore.load(taskID: fixture.contract.taskID)
        var staleExpected = try staleStore.load(taskID: fixture.contract.taskID)
        XCTAssertNil(firstExpected); XCTAssertNil(staleExpected)
        let first = try fixture.executor(recovered: firstExpected, persist: { journal in
            try firstStore.save(journal, replacing: firstExpected)
            firstExpected = journal; fixture.saved = journal
        })
        var staleEffects: [String] = []
        let stale = try ComputerUseTaskExecution(contract: fixture.contract, recovered: staleExpected,
            observe: { _ in true }, perform: { step, _ in staleEffects.append(step.id) },
            persist: { journal in
                try staleStore.save(journal, replacing: staleExpected)
                staleExpected = journal
            }, assertOwnership: { })
        try await first.run()
        let finished = try XCTUnwrap(firstStore.load(taskID: fixture.contract.taskID))
        for _ in 0..<2 {
            do { try await stale.run(); XCTFail("A stale executor cannot claim an already completed step") }
            catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .staleJournal) }
            XCTAssertEqual(try firstStore.load(taskID: fixture.contract.taskID), finished)
        }
        XCTAssertTrue(staleEffects.isEmpty)
        XCTAssertEqual(fixture.effects, ["type-1", "submit-1", "type-2", "submit-2"])
        XCTAssertTrue(stale.journal.statuses.allSatisfy { $0 == .planned })
    }

    func testUnconfirmedDiskCommitCannotDispatchOrReplayAnEffectAfterReconstruction() async throws {
        for failedWrite in [1, 2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try SearchTransactionFixture()
            var writeCount = 0
            let store = try ComputerUseTaskJournalStore(directory: directory, afterReplacement: {
                writeCount += 1
                if writeCount == failedWrite { throw TransactionFixtureError.writeFailed }
            })
            var expected = try store.load(taskID: fixture.contract.taskID)
            let execution = try fixture.executor(recovered: expected, persist: { journal in
                try store.save(journal, replacing: expected)
                expected = journal; fixture.saved = journal
            })
            do { try await execution.run(); XCTFail("An unconfirmed durable write cannot authorize progress") }
            catch { XCTAssertEqual(error as? TransactionFixtureError, .writeFailed) }
            XCTAssertEqual(fixture.effects.count, failedWrite == 1 ? 0 : 1)
            do { try await execution.run(); XCTFail("The writer remains unavailable after its failed commit") }
            catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
            let reopened = try ComputerUseTaskJournalStore(directory: directory)
            var recovered = try reopened.load(taskID: fixture.contract.taskID)
            XCTAssertEqual(recovered?.statuses.first, failedWrite == 1 ? .attempted : .verified)
            fixture.saved = recovered
            let resumed = try fixture.executor(recovered: recovered, persist: { journal in
                try reopened.save(journal, replacing: recovered)
                recovered = journal; fixture.saved = journal
            })
            if failedWrite == 1 {
                do { try await resumed.run(); XCTFail("A visible attempted journal does not prove that its effect happened") }
                catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .uncertainEffect("type-1")) }
                XCTAssertTrue(fixture.effects.isEmpty)
            } else {
                try await resumed.run()
                XCTAssertEqual(fixture.effects, ["type-1", "submit-1", "type-2", "submit-2"])
                XCTAssertEqual(fixture.submissions, ["Paris", "Paris"])
            }
        }
    }

    func testTwoIdenticalQueriesUseDistinctStepsAndEachSubmissionNeedsItsOwnEvidence() async throws {
        let fixture = try SearchTransactionFixture()
        let execution = try fixture.executor()
        try await execution.run()
        try await execution.run()
        XCTAssertEqual(fixture.effects, ["type-1", "submit-1", "type-2", "submit-2"])
        XCTAssertEqual(fixture.submissions, ["Paris", "Paris"])
        XCTAssertEqual(Set(fixture.effectIDs).count, 4)
        XCTAssertEqual(execution.journal.statuses, [.verified, .verified, .verified, .verified])
        XCTAssertNotEqual(fixture.contract.effectIdentity(for: fixture.contract.steps[1]),
                          fixture.contract.effectIdentity(for: fixture.contract.steps[3]))
    }

    func testRecoveryAfterEveryDeliveredStepReconcilesWithoutRepeatingTypingOrSubmission() async throws {
        for interruptedStep in 0..<4 {
            let fixture = try SearchTransactionFixture()
            fixture.interruptAfterEffect = interruptedStep
            let execution = try fixture.executor()
            do { try await execution.run(); XCTFail("Expected an interrupted effect") }
            catch is CancellationError { }
            let saved = try XCTUnwrap(fixture.saved)
            XCTAssertEqual(saved.statuses[interruptedStep], .attempted)
            let encoded = try JSONEncoder().encode(saved)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Paris"))
            let restored = try JSONDecoder().decode(ComputerUseTaskJournal.self, from: encoded)
            fixture.interruptAfterEffect = nil
            let resumed = try fixture.executor(recovered: restored)
            try await resumed.run()
            XCTAssertEqual(fixture.effects, ["type-1", "submit-1", "type-2", "submit-2"])
            XCTAssertEqual(fixture.submissions, ["Paris", "Paris"])
            XCTAssertTrue(resumed.journal.statuses.allSatisfy { $0 == .verified })
        }
    }

    func testReturnedButUnobservedSubmissionStaysUncertainWithoutReplay() async throws {
        let fixture = try SearchTransactionFixture()
        fixture.dropSubmission = true
        let execution = try fixture.executor()
        for _ in 0..<2 {
            do { try await execution.run(); XCTFail("Returning from dispatch cannot prove submission") }
            catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .uncertainEffect("submit-1")) }
        }
        XCTAssertEqual(fixture.effects, ["type-1", "submit-1"])
        XCTAssertEqual(execution.journal.statuses, [.verified, .uncertain, .planned, .planned])
        XCTAssertTrue(fixture.submissions.isEmpty)
    }

    func testCompletedJournalCannotHideAChangedFinalOutcomeOrConstraint() async throws {
        let fixture = try SearchTransactionFixture()
        let execution = try fixture.executor()
        try await execution.run()
        fixture.submissions.removeLast()
        do { try await execution.run(); XCTFail("A stale result is not complete") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .incompleteOutcome("submitted-2")) }
        fixture.submissions.append("Paris")
        fixture.documentGeneration = 1
        do { try await execution.run(); XCTFail("A replaced document cannot inherit completion") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .incompleteOutcome("same-document")) }
        XCTAssertEqual(fixture.effects.count, 4)
    }

    func testFailedDurableWriteOrOwnershipLossCannotReachEffectAdapter() async throws {
        for loseOwnership in [false, true] {
            let fixture = try SearchTransactionFixture()
            let execution = try fixture.executor(persist: { journal in
                if loseOwnership { fixture.saved = journal; fixture.ownsTask = false }
                else { throw TransactionFixtureError.writeFailed }
            })
            do { try await execution.run(); XCTFail("Ownership and durable attempt precede dispatch") }
            catch {
                XCTAssertEqual(error as? TransactionFixtureError, loseOwnership ? .ownershipLost : .writeFailed)
            }
            XCTAssertTrue(fixture.effects.isEmpty)
        }
    }

    func testConcurrentRunAndCancelledObservationCannotDispatchLateResult() async throws {
        let fixture = try SearchTransactionFixture()
        var continuation: CheckedContinuation<Bool, Never>?
        let execution = try fixture.executor(observe: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        let running = Task { try await execution.run() }
        for _ in 0..<100 {
            if continuation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let release = continuation else { running.cancel(); return XCTFail("Observation did not suspend") }
        do { try await execution.run(); XCTFail("Concurrent dispatch must be rejected") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .alreadyExecuting) }
        running.cancel()
        release.resume(returning: true)
        do { try await running.value; XCTFail("A late observation cannot revive a cancelled task") }
        catch is CancellationError { }
        XCTAssertTrue(fixture.effects.isEmpty)
        XCTAssertTrue(execution.journal.statuses.allSatisfy { $0 == .planned })
    }

    func testContractRejectsMissingBindingsPredicatesOutcomesAndImpossibleDependencies() throws {
        let original = try SearchTransactionFixture().contract
        func rebuilt(entities: [ComputerUseTaskContract.Entity]? = nil,
                     steps: [ComputerUseTaskContract.Step]? = nil,
                     outcomes: [String]? = nil, invariants: [String]? = nil) throws -> ComputerUseTaskContract {
            try ComputerUseTaskContract(taskID: original.taskID, promptDigest: original.promptDigest,
                entities: entities ?? original.entities, predicates: original.predicates, steps: steps ?? original.steps,
                invariants: invariants ?? original.invariants, outcomes: outcomes ?? original.outcomes)
        }
        XCTAssertThrowsError(try rebuilt(entities: Array(original.entities.prefix(1))))
        XCTAssertThrowsError(try rebuilt(steps: Array(original.steps.reversed())))
        XCTAssertThrowsError(try rebuilt(steps: [original.steps[0], original.steps[0]]))
        XCTAssertThrowsError(try rebuilt(outcomes: []))
        XCTAssertThrowsError(try rebuilt(outcomes: ["not-observed"]))
        XCTAssertThrowsError(try rebuilt(invariants: ["not-observed"]))
        var steps = original.steps
        let first = steps[0]
        steps[0] = .init(id: first.id, dependencies: [], operation: first.operation,
                         preconditions: first.preconditions, postconditions: [])
        XCTAssertThrowsError(try rebuilt(steps: steps))
    }

    func testRecoveryBindsTargetGenerationPayloadVersionDependenciesConstraintsAndOutcomes() throws {
        let fixture = try SearchTransactionFixture()
        let initial = try fixture.executor().journal
        let original = fixture.contract
        for change in 0..<6 {
            var entities = original.entities
            var steps = original.steps
            var invariants = original.invariants
            var outcomes = original.outcomes
            let last = steps[3]
            var operation = last.operation
            var dependencies = last.dependencies
            switch change {
            case 0: entities[0] = .init(id: entities[0].id, authorityDigest: ComputerUseTaskContract.digest(["new document"]))
            case 1: operation = .init(capabilityID: operation.capabilityID, entityID: "results",
                                     payloadDigest: operation.payloadDigest, payloadVersion: operation.payloadVersion)
            case 2: operation = .init(capabilityID: operation.capabilityID, entityID: operation.entityID,
                                     payloadDigest: operation.payloadDigest, payloadVersion: 2)
            case 3: dependencies = [steps[0].id]
            case 4: invariants = []
            default: outcomes = ["submitted-1"]
            }
            steps[3] = .init(id: last.id, dependencies: dependencies, operation: operation,
                             preconditions: last.preconditions, postconditions: last.postconditions)
            let changed = try ComputerUseTaskContract(taskID: original.taskID, promptDigest: original.promptDigest,
                entities: entities, predicates: original.predicates, steps: steps, invariants: invariants, outcomes: outcomes)
            XCTAssertNotEqual(changed.contractDigest, original.contractDigest)
            XCTAssertThrowsError(try ComputerUseTaskExecution(contract: changed, recovered: initial,
                observe: { _ in true }, perform: { _, _ in XCTFail("No effect during recovery") },
                persist: { _ in }, assertOwnership: { })) {
                    XCTAssertEqual($0 as? ComputerUseTaskExecutionError, .journalMismatch)
                }
        }
    }
}

private enum TransactionFixtureError: Error, Equatable { case writeFailed, ownershipLost }

/// A controlled effect oracle, not a browser or model integration test. It
/// distinguishes submitted-result receipts from the current input value, so
/// a repeated query cannot pass its second submission by reusing the first.
@MainActor
private final class SearchTransactionFixture {
    let contract: ComputerUseTaskContract
    var input = ""
    var submissions: [String] = []
    var documentGeneration = 0
    var effects: [String] = []
    var effectIDs: [String] = []
    var saved: ComputerUseTaskJournal?
    var ownsTask = true
    var interruptAfterEffect: Int?
    var dropSubmission = false

    init() throws {
        func digest(_ value: String) -> String { ComputerUseTaskContract.digest([value]) }
        let entities = ["input", "results"].map { ComputerUseTaskContract.Entity(id: $0, authorityDigest: digest("document 0:" + $0)) }
        let predicates = [
            ComputerUseTaskContract.Predicate(id: "empty", entityID: "input", kind: "value", expectedDigest: digest("")),
            .init(id: "query", entityID: "input", kind: "value", expectedDigest: digest("Paris")),
            .init(id: "submitted-0", entityID: "results", kind: "receipt-count", expectedDigest: digest("0")),
            .init(id: "submitted-1", entityID: "results", kind: "receipt-count", expectedDigest: digest("1")),
            .init(id: "submitted-2", entityID: "results", kind: "receipt-count", expectedDigest: digest("2")),
            .init(id: "same-document", entityID: "input", kind: "document-generation", expectedDigest: digest("0")),
        ]
        let type = ComputerUseTaskContract.Operation(capabilityID: "text.replace", entityID: "input",
            payloadDigest: digest("Paris"), payloadVersion: 1)
        let submit = ComputerUseTaskContract.Operation(capabilityID: "search.submit", entityID: "input",
            payloadDigest: digest("Paris"), payloadVersion: 1)
        let steps = [
            ComputerUseTaskContract.Step(id: "type-1", dependencies: [], operation: type,
                preconditions: ["empty", "submitted-0"], postconditions: ["query"]),
            .init(id: "submit-1", dependencies: ["type-1"], operation: submit,
                preconditions: ["query", "submitted-0"], postconditions: ["submitted-1"]),
            .init(id: "type-2", dependencies: ["submit-1"], operation: type,
                preconditions: ["query", "submitted-1"], postconditions: ["query"]),
            .init(id: "submit-2", dependencies: ["type-2"], operation: submit,
                preconditions: ["query", "submitted-1"], postconditions: ["submitted-2"]),
        ]
        contract = try ComputerUseTaskContract(taskID: "two-searches", promptDigest: digest("Search twice for Paris"),
            entities: entities, predicates: predicates, steps: steps, invariants: ["same-document"], outcomes: ["submitted-2", "query"])
    }

    func executor(recovered: ComputerUseTaskJournal? = nil,
                  observe: ((ComputerUseTaskContract.Predicate) async throws -> Bool)? = nil,
                  persist: ((ComputerUseTaskJournal) throws -> Void)? = nil) throws -> ComputerUseTaskExecution {
        try ComputerUseTaskExecution(contract: contract, recovered: recovered,
            observe: observe ?? { [self] predicate in
                let value: String
                switch predicate.kind {
                case "value": value = input
                case "receipt-count": value = String(submissions.count)
                case "document-generation": value = String(documentGeneration)
                default: return false
                }
                return ComputerUseTaskContract.digest([value]) == predicate.expectedDigest
            }, perform: { [self] step, identity in
                let index = effects.count
                XCTAssertEqual(saved?.statuses[index], .attempted, "Persist must precede every effect")
                effects.append(step.id)
                effectIDs.append(identity)
                if step.operation.capabilityID == "text.replace" { input = "Paris" }
                else if !dropSubmission { submissions.append(input) }
                if interruptAfterEffect == index { throw CancellationError() }
            }, persist: persist ?? { [self] in saved = $0 },
            assertOwnership: { [self] in guard ownsTask else { throw TransactionFixtureError.ownershipLost } })
    }
}
