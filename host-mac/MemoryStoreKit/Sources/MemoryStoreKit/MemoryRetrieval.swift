import Foundation

private let maximumSerializedTokenInputBytes = 1_048_576

public enum MemoryEmbeddingPurpose: Sendable {
    case query
    case document
}

/// Adapter contract for a future pinned, local embedding model. Implementations must remain
/// local-only; this package intentionally ships no model runtime or model downloader.
public protocol LocalMemoryEmbeddingProvider: Sendable {
    var identity: String { get }
    var dimensions: Int { get }
    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float]
}

/// Counts tokens in the complete serialized context, including metadata and formatting.
public protocol MemoryExactTokenCounter: Sendable {
    func countTokens(in completeContext: String) async throws -> Int
}

public struct MemoryContextRequest: Sendable {
    public let context: OwnerMemoryContext
    public let query: String
    public let tokenBudget: Int
    public let candidateLimit: Int
    public let topK: Int
    public let profileTokenBudget: Int

    public init(context: OwnerMemoryContext, query: String, tokenBudget: Int,
                candidateLimit: Int = 100, topK: Int = 10, profileTokenBudget: Int = 1_024) {
        self.context = context
        self.query = query
        self.tokenBudget = tokenBudget
        self.candidateLimit = candidateLimit
        self.topK = topK
        self.profileTokenBudget = profileTokenBudget
    }
}

/// Model-facing entry. It carries stable record metadata and the saved body, never source spans,
/// page/tool excerpts, vault handles, or raw vault values.
public struct MemoryContextEntry: Codable, Sendable, Equatable {
    public let id: String
    public let kind: MemoryKind
    public let body: String
    public let source: MemorySource
    public let observedAt: Int64
    public let active: Bool
}

public struct MemoryContextResult: Sendable, Equatable {
    public let serializedContext: String
    public let entries: [MemoryContextEntry]
    public let tokenCount: Int
}

public enum MemoryRetrievalError: Error, Equatable {
    case invalidRequest
    case invalidEmbedding
    case dependencyFailure
    case contextTooLarge
    case staleSnapshot
}

/// Request-scoped retrieval and deterministic context packer. This is an unconnected candidate;
/// the host must supply a pinned local model and exact tokenizer before enabling it.
public actor MemoryContextBuilder {
    private let writer: OwnerMemoryWriter
    private let embedding: any LocalMemoryEmbeddingProvider
    private let tokenCounter: any MemoryExactTokenCounter
    private var generation: UInt64 = 0

    public init(writer: OwnerMemoryWriter, embedding: any LocalMemoryEmbeddingProvider,
                tokenCounter: any MemoryExactTokenCounter) {
        self.writer = writer
        self.embedding = embedding
        self.tokenCounter = tokenCounter
    }

    /// Invalidates the results of embeddings already in flight.
    public func invalidate() {
        generation &+= 1
    }

    public func build(_ request: MemoryContextRequest) async throws -> MemoryContextResult {
        guard !request.query.isEmpty, request.query.utf8.count <= 2_048,
              !request.query.utf8.contains(0), (1...8_192).contains(request.tokenBudget),
              (1...100).contains(request.candidateLimit), (1...20).contains(request.topK),
              (1...4_096).contains(request.profileTokenBudget),
              !embedding.identity.isEmpty, embedding.identity.utf8.count <= 256,
              (1...4_096).contains(embedding.dimensions) else {
            throw MemoryRetrievalError.invalidRequest
        }
        let initialGeneration = generation
        let snapshot: (profiles: [MemoryRecord], candidates: [MemoryRecord], lexical: [MemoryMatch])
        do {
            snapshot = try writer.retrievalSnapshot(query: request.query,
                context: request.context, candidateLimit: request.candidateLimit)
        } catch {
            throw error
        }

        var candidatesByID: [String: MemoryRecord] = [:]
        for record in snapshot.candidates { candidatesByID[record.id] = record }
        var lexicalRanks: [String: Int] = [:]
        for (index, match) in snapshot.lexical.enumerated() {
            lexicalRanks[match.record.id] = index + 1
            candidatesByID[match.record.id] = match.record
        }

        var semanticRanks: [String: Int] = [:]
        if !candidatesByID.isEmpty {
            let queryVector = try await embedChecked(request.query, purpose: .query,
                context: request.context, expectedGeneration: initialGeneration, record: nil)
            let ordered = candidatesByID.values.sorted { $0.id < $1.id }
            var similarities: [(String, Double)] = []
            for record in ordered {
                let vector = try await embedChecked(record.body, purpose: .document,
                    context: request.context, expectedGeneration: initialGeneration, record: record)
                similarities.append((record.id, cosine(queryVector, vector)))
            }
            let orderedSimilarities = similarities.sorted(by: {
                $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
            })
            var denseRank = 0
            var previousSimilarity: Double?
            for item in orderedSimilarities {
                if previousSimilarity != item.1 {
                    denseRank += 1
                    previousSimilarity = item.1
                }
                semanticRanks[item.0] = denseRank
            }
        }
        try revalidate(request.context, generation: initialGeneration)

        // Reciprocal-rank fusion combines BM25 and cosine ranks without comparing their scales.
        var fused: [(record: MemoryRecord, score: Double)] = []
        for record in candidatesByID.values {
            let lexicalRank = lexicalRanks[record.id] ?? 0
            let semanticRank = semanticRanks[record.id] ?? 0
            let lexicalScore = lexicalRank == 0 ? 0.0 : 1.0 / (60.0 + Double(lexicalRank))
            let semanticScore = semanticRank == 0 ? 0.0 : 1.0 / (60.0 + Double(semanticRank))
            fused.append((record: record, score: lexicalScore + semanticScore))
        }
        fused.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.record.observedAt != right.record.observedAt {
                return left.record.observedAt > right.record.observedAt
            }
            return left.record.id < right.record.id
        }

        let orderedProfiles = snapshot.profiles.sorted {
            $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt
        }
        var profileEntries: [MemoryContextEntry] = []
        for record in orderedProfiles {
            let candidate = profileEntries + [MemoryContextEntry(record: record)]
            let candidateText = try serialize(candidate)
            guard candidateText.utf8.count <= maximumSerializedTokenInputBytes else { break }
            profileEntries = candidate
        }
        var profileText = try serialize(profileEntries)
        var profileCount = try await countChecked(profileText, context: request.context,
            generation: initialGeneration)
        while profileCount > request.profileTokenBudget, !profileEntries.isEmpty {
            profileEntries.removeLast()
            profileText = try serialize(profileEntries)
            profileCount = try await countChecked(profileText, context: request.context,
                generation: initialGeneration)
        }
        var entries = profileEntries
        entries += fused.prefix(request.topK).map { MemoryContextEntry(record: $0.record) }
        var serialized = try serialize(entries)
        while serialized.utf8.count > maximumSerializedTokenInputBytes, !entries.isEmpty {
            entries.removeLast()
            serialized = try serialize(entries)
        }
        var count = try await countChecked(serialized, context: request.context,
                                           generation: initialGeneration)
        // Drop complete records from lowest priority upward; never truncate a saved statement.
        while count > request.tokenBudget, !entries.isEmpty {
            entries.removeLast()
            serialized = try serialize(entries)
            guard serialized.utf8.count <= maximumSerializedTokenInputBytes else {
                throw MemoryRetrievalError.contextTooLarge
            }
            count = try await countChecked(serialized, context: request.context,
                                           generation: initialGeneration)
        }
        guard count <= request.tokenBudget else { throw MemoryRetrievalError.contextTooLarge }
        try revalidate(request.context, generation: initialGeneration)
        for entry in entries {
            guard let source = (snapshot.profiles + Array(candidatesByID.values)).first(where: { $0.id == entry.id }) else {
                throw MemoryRetrievalError.staleSnapshot
            }
            try writer.validateRetrievalRecord(source, context: request.context)
        }
        return MemoryContextResult(serializedContext: serialized, entries: entries, tokenCount: count)
    }

    private func embedChecked(_ text: String, purpose: MemoryEmbeddingPurpose,
                              context: OwnerMemoryContext, expectedGeneration: UInt64,
                              record: MemoryRecord?) async throws -> [Float] {
        try revalidate(context, generation: expectedGeneration)
        let result: [Float]
        do { result = try await embedding.embed(text, purpose: purpose) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MemoryRetrievalError.dependencyFailure }
        try revalidate(context, generation: expectedGeneration)
        if let record { try writer.validateRetrievalRecord(record, context: context) }
        guard result.count == embedding.dimensions,
              result.allSatisfy({ $0.isFinite }),
              result.contains(where: { $0 != 0 }) else { throw MemoryRetrievalError.invalidEmbedding }
        return result
    }

    private func countChecked(_ text: String, context: OwnerMemoryContext,
                              generation expectedGeneration: UInt64) async throws -> Int {
        try revalidate(context, generation: expectedGeneration)
        let count: Int
        do { count = try await tokenCounter.countTokens(in: text) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MemoryRetrievalError.dependencyFailure }
        try revalidate(context, generation: expectedGeneration)
        guard count >= 0 else { throw MemoryRetrievalError.dependencyFailure }
        return count
    }

    private func revalidate(_ context: OwnerMemoryContext, generation expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw OwnerMemoryWriterError.unauthorized }
        try writer.validateRetrieval(context)
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var dot = 0.0, leftNorm = 0.0, rightNorm = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]), right = Double(rhs[index])
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        return dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }

    private func serialize(_ entries: [MemoryContextEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(entries), as: UTF8.self) }
        catch { throw MemoryRetrievalError.dependencyFailure }
    }
}

private extension MemoryContextEntry {
    init(record: MemoryRecord) {
        id = record.id
        kind = record.kind
        body = record.body
        source = record.source
        observedAt = record.observedAt
        active = record.active
    }
}
