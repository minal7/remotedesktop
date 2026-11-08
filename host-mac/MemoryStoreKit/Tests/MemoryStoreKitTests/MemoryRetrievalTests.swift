import Foundation
import XCTest
@testable import MemoryStoreKit

private final class RetrievalKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    func loadKey() throws -> Data { Data(repeating: 0x67, count: 32) }
    func destroyKey() throws {}
}

private final class RetrievalState: @unchecked Sendable {
    private let lock = NSLock()
    private var current = OwnerMemoryPolicy(featureEnabled: true)
    func policy() -> OwnerMemoryPolicy { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ value: OwnerMemoryPolicy) { lock.lock(); defer { lock.unlock() }; current = value }
}

private final class FakeEmbeddingProvider: LocalMemoryEmbeddingProvider, @unchecked Sendable {
    let identity = "test-embed-v1"
    let dimensions = 2
    private let lock = NSLock()
    private var calls = 0
    private let vectors: [String: [Float]]
    private let onEmbed: (@Sendable (String) -> Void)?

    init(vectors: [String: [Float]] = [:], onEmbed: (@Sendable (String) -> Void)? = nil) {
        self.vectors = vectors
        self.onEmbed = onEmbed
    }

    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        incrementCalls()
        onEmbed?(text)
        return vectors[text] ?? [0, 1]
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    private func incrementCalls() {
        lock.lock(); defer { lock.unlock() }; calls += 1
    }
}

private final class DeletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var deleted = false
    func delete(_ store: MemoryStore) {
        lock.lock(); defer { lock.unlock() }
        if !deleted { try? store.forget(id: "fact"); deleted = true }
    }
}

private actor DelayedEmbeddingProvider: LocalMemoryEmbeddingProvider {
    nonisolated let identity = "delayed-test-v1"
    nonisolated let dimensions = 2
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<[Float], Never>?
    private var started = false

    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in startedContinuation = continuation }
    }

    func resume() { resultContinuation?.resume(returning: [1, 0]); resultContinuation = nil }
}

private struct WhitespaceTokenCounter: MemoryExactTokenCounter {
    func countTokens(in completeContext: String) async throws -> Int {
        completeContext.split(whereSeparator: \.isWhitespace).count
    }
}

private final class ByteBudgetTokenCounter: MemoryExactTokenCounter, @unchecked Sendable {
    private let lock = NSLock()
    private var largestInput = 0
    func countTokens(in completeContext: String) async throws -> Int {
        let bytes = completeContext.utf8.count
        record(bytes)
        return bytes
    }
    var maximumInputBytes: Int { lock.lock(); defer { lock.unlock() }; return largestInput }
    private func record(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        largestInput = max(largestInput, bytes)
    }
}

final class MemoryRetrievalTests: XCTestCase {
    private var fixtures: [(store: MemoryStore, directory: URL)] = []

    private func fixture() throws -> (MemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRetrieval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.sqlite"),
            keyProvider: RetrievalKeyProvider()))
        fixtures.append((store, directory))
        return (store, directory)
    }

    override func tearDownWithError() throws {
        for fixture in fixtures {
            try? fixture.store.close()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll(keepingCapacity: false)
        try super.tearDownWithError()
    }

    private func writer(_ store: MemoryStore, state: RetrievalState) -> OwnerMemoryWriter {
        OwnerMemoryWriter(store: store, authorize: { $0.ownerID == "owner" && $0.sessionID == "session" },
            isTaskActive: { owner, task in owner == "owner" && task == "task" },
            policy: { state.policy() })
    }

    private func put(_ store: MemoryStore, id: String, kind: MemoryKind, body: String,
                     active: Bool = true, at: Int64 = 10, source: MemorySource = .ownerConfirmed,
                     provenance: MemoryProvenance = MemoryProvenance()) throws {
        try store.upsert(MemoryRecord(id: id, kind: kind, body: body, source: source,
            observedAt: at, active: active, provenance: provenance))
    }

    private func request(query: String = "aisle seat", budget: Int = 4096) -> MemoryContextRequest {
        MemoryContextRequest(context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"),
            query: query, tokenBudget: budget)
    }

    func testHybridRetrievalCombinesLiteralFTSAndParaphraseAndKeepsMetadataOnly() async throws {
        let (store, _) = try fixture()
        try put(store, id: "profile-1", kind: .profile, body: "Prefers direct flights", at: 30,
                source: .ownerMessage)
        try put(store, id: "exact", kind: .fact, body: "Owner prefers aisle seat", at: 20,
                provenance: MemoryProvenance(candidateOrigin: "page", sourceReference: "page:sample",
                    sourceSpan: "UNTRUSTED-PAGE-SPAN"))
        try put(store, id: "paraphrase", kind: .episode, body: "Chooses a side seat near the walkway", at: 19)
        try put(store, id: "inactive", kind: .fact, body: "aisle seat", active: false)
        try put(store, id: "deleted", kind: .fact, body: "aisle seat")
        try store.forget(id: "deleted")

        let provider = FakeEmbeddingProvider(vectors: [
            "aisle seat": [1, 0],
            "Owner prefers aisle seat": [0.7, 0.7],
            "Chooses a side seat near the walkway": [0.99, 0.01]
        ])
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: provider, tokenCounter: WhitespaceTokenCounter())
        let result = try await builder.build(request())
        XCTAssertEqual(result.entries.first?.id, "profile-1")
        XCTAssertTrue(result.entries.contains(where: { $0.id == "exact" }))
        XCTAssertTrue(result.entries.contains(where: { $0.id == "paraphrase" }))
        XCTAssertFalse(result.entries.contains(where: { $0.id == "inactive" || $0.id == "deleted" }))
        XCTAssertEqual(result.entries.first(where: { $0.id == "exact" })?.source, .ownerConfirmed)
        XCTAssertTrue(result.serializedContext.contains("exact"))
        XCTAssertTrue(result.serializedContext.contains("owner_confirmed"))
        XCTAssertFalse(result.serializedContext.contains("UNTRUSTED-PAGE-SPAN"))
        XCTAssertFalse(result.serializedContext.contains("page:sample"))
    }

    func testDeterministicSeatPreferenceRetrievalAcrossInsertionOrderAndReopen() async throws {
        let window = "When flying, I prefer a seat beside the window."
        let aisle = "When flying, I prefer an aisle seat."
        let hotel = "I prefer a quiet hotel room away from the elevator."
        let query = "window seat on a flight"
        let context = OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task")
        let vectors: [String: [Float]] = [
            query: [1, 0],
            "zzqv991": [1, 0],
            "qrzv772": [0.8, 0.6],
            window: [0.95, 0.3122499],
            aisle: [0.8, 0.6],
            hotel: [0, 1]
        ]
        let fixedRows: [(String, String, Int64)] = [
            ("seat-window", window, 100),
            ("seat-aisle", aisle, 200),
            ("hotel", hotel, 300)
        ]
        let state = RetrievalState()

        func open(_ directory: URL) throws -> MemoryStore {
            try XCTUnwrap(MemoryStore.open(enabled: true,
                databaseURL: directory.appendingPathComponent("memory.sqlite"),
                keyProvider: RetrievalKeyProvider()))
        }
        func seed(_ store: MemoryStore, rows: [(String, String, Int64)]) throws {
            for (id, body, observedAt) in rows {
                try store.upsert(MemoryRecord(id: id, kind: .fact, body: body,
                    source: .ownerConfirmed, observedAt: observedAt, confidence: 1))
            }
        }
        func assertRetrieval(_ store: MemoryStore, query retrievalQuery: String = query,
                             expectedLexical: [String], expectedOrder: [String] = [
                                "seat-window", "seat-aisle", "hotel"
                             ]) async throws {
            let memoryWriter = writer(store, state: state)
            let snapshot = try memoryWriter.retrievalSnapshot(query: retrievalQuery, context: context,
                candidateLimit: 10)
            XCTAssertEqual(snapshot.lexical.map(\.record.id), expectedLexical)

            let builder = MemoryContextBuilder(writer: memoryWriter,
                embedding: FakeEmbeddingProvider(vectors: vectors),
                tokenCounter: WhitespaceTokenCounter())
            let result = try await builder.build(MemoryContextRequest(context: context,
                query: retrievalQuery, tokenBudget: 512, candidateLimit: 10, topK: 3,
                profileTokenBudget: 32))
            XCTAssertEqual(result.entries.map(\.id), expectedOrder)
            XCTAssertEqual(result.entries.map(\.body), expectedOrder.map { id in
                switch id {
                case "seat-window": window
                case "seat-aisle": aisle
                default: hotel
                }
            })
        }

        let firstDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRetrievalDeterministic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        var firstStore: MemoryStore? = try open(firstDirectory)
        try seed(try XCTUnwrap(firstStore), rows: fixedRows)
        try await assertRetrieval(try XCTUnwrap(firstStore), expectedLexical: [
            "seat-window", "seat-aisle", "hotel"
        ])
        try await assertRetrieval(try XCTUnwrap(firstStore), query: "zzqv991",
            expectedLexical: [], expectedOrder: ["seat-window", "seat-aisle", "hotel"])
        try await assertRetrieval(try XCTUnwrap(firstStore), query: "qrzv772",
            expectedLexical: [], expectedOrder: ["seat-aisle", "seat-window", "hotel"])
        try XCTUnwrap(firstStore).close()
        firstStore = nil
        let reopenedStore = try open(firstDirectory)
        defer { try? reopenedStore.close() }
        try await assertRetrieval(reopenedStore, expectedLexical: [
            "seat-window", "seat-aisle", "hotel"
        ])

        let reversedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRetrievalReversed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reversedDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: reversedDirectory) }
        let reversedStore = try open(reversedDirectory)
        defer { try? reversedStore.close() }
        try seed(reversedStore, rows: fixedRows.reversed().map { $0 })
        try await assertRetrieval(reversedStore, expectedLexical: [
            "seat-window", "seat-aisle", "hotel"
        ])
    }

    func testWholeRecordsDropToFitIncludingSerializedMetadataAndFormatting() async throws {
        let (store, _) = try fixture()
        try put(store, id: "profile", kind: .profile, body: "small profile")
        try put(store, id: "large", kind: .fact, body: String(repeating: "large-body ", count: 80))
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: FakeEmbeddingProvider(vectors: ["query": [1, 0]]),
            tokenCounter: WhitespaceTokenCounter())
        let result = try await builder.build(request(query: "query", budget: 12))
        XCTAssertLessThanOrEqual(result.tokenCount, 12)
        XCTAssertEqual(result.tokenCount,
            result.serializedContext.split(whereSeparator: \.isWhitespace).count)
        XCTAssertFalse(result.entries.contains(where: { $0.id == "large" }))
        XCTAssertEqual(result.entries.map(\.id), ["profile"])
        XCTAssertTrue(result.serializedContext.hasPrefix("["), "serialization overhead is counted")
    }

    func testManyLargeProfilesAreBoundedBeforeTokenizerCallAndPackedAsWholeRecords() async throws {
        let (store, _) = try fixture()
        for index in 0..<400 {
            try put(store, id: "profile-\(index)", kind: .profile,
                body: String(repeating: "P", count: 3_500), at: Int64(index), source: .ownerMessage)
        }
        let counter = ByteBudgetTokenCounter()
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: FakeEmbeddingProvider(), tokenCounter: counter)
        let result = try await builder.build(MemoryContextRequest(
            context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"),
            query: "no matching memory", tokenBudget: 8_000,
            candidateLimit: 1, topK: 1, profileTokenBudget: 4_096))
        XCTAssertGreaterThan(counter.maximumInputBytes, 3_500)
        XCTAssertLessThanOrEqual(counter.maximumInputBytes, 1_048_576)
        XCTAssertLessThanOrEqual(result.tokenCount, 8_000)
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertTrue(result.entries.allSatisfy { $0.kind == .profile && $0.source == .ownerMessage })
        XCTAssertTrue(result.entries.allSatisfy { $0.body.utf8.count == 3_500 })
    }

    func testNaturalQueryFindsOlderPunctuatedIdentifierOutsideRecentCandidatePool() async throws {
        let (store, _) = try fixture()
        try put(store, id: "old-order", kind: .fact, body: "Order ZX-314 arrives on Friday", at: 1)
        for index in 0..<12 {
            try put(store, id: "recent-\(index)", kind: .fact,
                body: "Recent unrelated record \(index)", at: Int64(100 + index))
        }
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: FakeEmbeddingProvider(), tokenCounter: WhitespaceTokenCounter())
        let result = try await builder.build(MemoryContextRequest(
            context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"),
            query: "what is the status of order ZX-314?", tokenBudget: 4096,
            candidateLimit: 3, topK: 3))
        XCTAssertEqual(result.entries.first(where: { $0.kind != .profile })?.id, "old-order")
        XCTAssertTrue(result.serializedContext.contains("Order ZX-314 arrives on Friday"))
    }

    func testRareIdentifierSurvivesCommonEarlierLiteralTermOverflow() async throws {
        let (store, _) = try fixture()
        try put(store, id: "zzz-old-order", kind: .fact,
            body: "Order ZX-314 arrives on Friday", at: 1)
        for index in 0..<60 {
            try put(store, id: "common-order-\(index)", kind: .fact,
                body: "Order order order pending reference \(index)", at: Int64(2 + index))
        }
        for index in 0..<110 {
            try put(store, id: "recent-\(index)", kind: .fact,
                body: "Unrelated recent record \(index)", at: Int64(1_000 + index))
        }
        let memoryWriter = writer(store, state: RetrievalState())
        let snapshot = try memoryWriter.retrievalSnapshot(query: "what is the status of order ZX-314?",
            context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"),
            candidateLimit: 100)
        XCTAssertTrue(snapshot.lexical.contains(where: { $0.record.id == "zzz-old-order" }),
            "rare literal-token matches must survive lexical candidate fusion")
        XCTAssertEqual(snapshot.lexical.first?.record.id, "zzz-old-order",
            "multi-term rare match should outrank common one-term matches")
        let builder = MemoryContextBuilder(writer: memoryWriter,
            embedding: FakeEmbeddingProvider(), tokenCounter: WhitespaceTokenCounter())
        let result = try await builder.build(MemoryContextRequest(
            context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"),
            query: "what is the status of order ZX-314?", tokenBudget: 4096,
            candidateLimit: 100, topK: 10))
        XCTAssertEqual(result.entries.first(where: { $0.kind != .profile })?.id, "zzz-old-order")
        XCTAssertTrue(result.serializedContext.contains("Order ZX-314 arrives on Friday"))
    }

    func testIncognitoAndNoMemoryRejectBeforeEmbedding() async throws {
        let (store, _) = try fixture()
        try put(store, id: "fact", kind: .fact, body: "query")
        let state = RetrievalState()
        let provider = FakeEmbeddingProvider()
        let builder = MemoryContextBuilder(writer: writer(store, state: state),
            embedding: provider, tokenCounter: WhitespaceTokenCounter())
        for policy in [OwnerMemoryPolicy(featureEnabled: true, incognito: true),
                       OwnerMemoryPolicy(featureEnabled: true, noMemory: true)] {
            state.set(policy)
            do {
                _ = try await builder.build(request(query: "query"))
                XCTFail("expected policy denial")
            } catch { XCTAssertTrue(error is OwnerMemoryWriterError) }
        }
        XCTAssertEqual(provider.callCount, 0)
    }

    func testInvalidDimensionsAndNonFiniteVectorsFailClosed() async throws {
        let (store, _) = try fixture()
        try put(store, id: "fact", kind: .fact, body: "query")
        let writer = writer(store, state: RetrievalState())
        for vector in [[Float](repeating: 1, count: 3), [Float.nan, 0]] {
            let builder = MemoryContextBuilder(writer: writer,
                embedding: FakeEmbeddingProvider(vectors: ["query": vector]),
                tokenCounter: WhitespaceTokenCounter())
            do {
                _ = try await builder.build(request(query: "query"))
                XCTFail("expected invalid embedding")
            } catch { XCTAssertEqual(error as? MemoryRetrievalError, .invalidEmbedding) }
        }
    }

    func testPolicyRevocationAfterEmbeddingPreventsContextReturn() async throws {
        let (store, _) = try fixture()
        try put(store, id: "fact", kind: .fact, body: "query")
        let state = RetrievalState()
        let provider = FakeEmbeddingProvider(onEmbed: { _ in
            state.set(OwnerMemoryPolicy(featureEnabled: true, incognito: true))
        })
        let builder = MemoryContextBuilder(writer: writer(store, state: state),
            embedding: provider, tokenCounter: WhitespaceTokenCounter())
        do {
            _ = try await builder.build(request(query: "query"))
            XCTFail("revoked retrieval must not return")
        } catch { XCTAssertEqual(error as? OwnerMemoryWriterError, .incognito) }
    }

    func testDeleteDuringDelayedEmbeddingCannotReturnOrCacheStaleRecord() async throws {
        let (store, _) = try fixture()
        try put(store, id: "fact", kind: .fact, body: "query")
        let deleteOnce = DeletionOnce()
        let provider = FakeEmbeddingProvider(onEmbed: { text in
            guard text == "query" else { return }
            deleteOnce.delete(store)
        })
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: provider, tokenCounter: WhitespaceTokenCounter())
        do {
            _ = try await builder.build(request(query: "query"))
            XCTFail("deleted record must invalidate the in-flight snapshot")
        } catch { XCTAssertEqual(error as? MemoryRetrievalError, .staleSnapshot) }
        XCTAssertNil(try store.get(id: "fact"))
    }

    func testInvalidateWhileEmbeddingIsSuspendedRejectsStaleCompletion() async throws {
        let (store, _) = try fixture()
        try put(store, id: "fact", kind: .fact, body: "query")
        let provider = DelayedEmbeddingProvider()
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: provider, tokenCounter: WhitespaceTokenCounter())
        let build = Task { try await builder.build(request(query: "query")) }
        await provider.waitUntilStarted()
        await builder.invalidate()
        await provider.resume()
        do {
            _ = try await build.value
            XCTFail("invalidated in-flight embedding must not be used")
        } catch { XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized) }
    }

    func testCancellationAfterIgnoredEmbeddingNeverReturnsContext() async throws {
        let (store, _) = try fixture()
        try put(store, id: "fact", kind: .fact, body: "query")
        let provider = DelayedEmbeddingProvider()
        let builder = MemoryContextBuilder(writer: writer(store, state: RetrievalState()),
            embedding: provider, tokenCounter: WhitespaceTokenCounter())
        let build = Task { try await builder.build(request(query: "query")) }
        await provider.waitUntilStarted()
        build.cancel()
        await provider.resume()
        do {
            _ = try await build.value
            XCTFail("cancelled retrieval must not return a context")
        } catch is CancellationError { }
    }
}
