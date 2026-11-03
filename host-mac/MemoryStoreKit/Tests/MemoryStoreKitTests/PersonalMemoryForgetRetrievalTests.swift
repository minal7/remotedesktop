import Foundation
import XCTest
@testable import MemoryStoreKit

private final class RetrievalForgetKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExactKeychainItem: Data] = [:]

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        items[item] = data
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard items.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
}

private struct RetrievalForgetRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x39, count: count) }
}

private actor SuspendedEmbedding: LocalMemoryEmbeddingProvider {
    nonisolated let identity = "forget-retrieval-test"
    nonisolated let dimensions = 2
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<[Float], Error>?
    private var started = false

    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
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

    func resume() {
        resultContinuation?.resume(returning: [1, 0])
        resultContinuation = nil
    }
}

private actor SuspendedTokenCounter: MemoryExactTokenCounter {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<Int, Error>?
    private var started = false

    func countTokens(in completeContext: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
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

    func resume() {
        resultContinuation?.resume(returning: 1)
        resultContinuation = nil
    }
}

private struct ImmediateEmbedding: LocalMemoryEmbeddingProvider {
    let identity = "forget-token-test"
    let dimensions = 2
    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] { [1, 0] }
}

private struct ImmediateTokenCounter: MemoryExactTokenCounter {
    func countTokens(in completeContext: String) async throws -> Int {
        completeContext.split(whereSeparator: \.isWhitespace).count
    }
}

final class PersonalMemoryForgetRetrievalTests: XCTestCase {
    private let owner = OwnerMemoryContext(ownerID: "forget-owner", sessionID: "forget-session")

    private func service() throws -> PersonalMemoryService {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalMemoryForgetRetrieval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        return try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: RetrievalForgetKeychain(), random: RetrievalForgetRandom(),
            namespace: .testing("forget-retrieval-\(UUID().uuidString)"),
            authorize: { $0.ownerID == "forget-owner" && $0.sessionID == "forget-session" },
            isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
    }

    private func addRecord(to service: PersonalMemoryService) throws {
        _ = try service.writer.remember(kind: .fact, text: "synthetic saved fact",
            commandID: "fixture-write", context: owner)
    }

    private func request() -> MemoryContextRequest {
        MemoryContextRequest(context: owner, query: "synthetic query", tokenBudget: 128)
    }

    private func assertNoContext<T>(_ task: Task<T, Error>, file: StaticString = #filePath,
                                   line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("retrieval completed after Forget", file: file, line: line)
        } catch {
            XCTAssertTrue(String(reflecting: error).contains("forgotten"),
                          "expected the writer's fixed Forget fence error, got \(error)",
                          file: file, line: line)
        }
    }

    func testForgetWhileEmbeddingSuspendedPreventsContextReturn() async throws {
        let service = try service()
        try addRecord(to: service)
        let embedding = SuspendedEmbedding()
        let builder = MemoryContextBuilder(writer: service.writer, embedding: embedding,
                                           tokenCounter: ImmediateTokenCounter())
        let build = Task { try await builder.build(request()) }

        await embedding.waitUntilStarted()
        try service.forgetAll()
        await embedding.resume()

        await assertNoContext(build)
    }

    func testForgetWhileTokenCountingSuspendedPreventsContextReturn() async throws {
        let service = try service()
        try addRecord(to: service)
        let counter = SuspendedTokenCounter()
        let builder = MemoryContextBuilder(writer: service.writer, embedding: ImmediateEmbedding(),
                                           tokenCounter: counter)
        let build = Task { try await builder.build(request()) }

        await counter.waitUntilStarted()
        try service.forgetAll()
        await counter.resume()

        await assertNoContext(build)
    }
}
