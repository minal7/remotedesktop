import Foundation
import XCTest
@testable import MemoryStoreKit

private final class FakeLlamaTransport: LlamaCppHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [LlamaCppHTTPRequest] = []
    private var storedResponse: LlamaCppHTTPResponse
    private var shouldCancel = false

    init(status: Int = 200, body: Data) { storedResponse = LlamaCppHTTPResponse(statusCode: status, body: body) }
    func setResponse(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        storedResponse = LlamaCppHTTPResponse(statusCode: status, body: body)
    }
    func cancelRequests() { lock.lock(); defer { lock.unlock() }; shouldCancel = true }
    var requests: [LlamaCppHTTPRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    func send(_ request: LlamaCppHTTPRequest) async throws -> LlamaCppHTTPResponse {
        try Task.checkCancellation()
        let (response, cancel) = recordAndRead(request)
        if cancel { throw CancellationError() }
        return response
    }
    private func recordAndRead(_ request: LlamaCppHTTPRequest) -> (LlamaCppHTTPResponse, Bool) {
        lock.lock()
        defer { lock.unlock() }
        storedRequests.append(request)
        return (storedResponse, shouldCancel)
    }
}

private final class SequencedLlamaTransport: LlamaCppHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<LlamaCppHTTPResponse, Error>]
    private var storedRequests: [LlamaCppHTTPRequest] = []

    init(_ responses: [Result<LlamaCppHTTPResponse, Error>]) { self.responses = responses }

    var requests: [LlamaCppHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    func send(_ request: LlamaCppHTTPRequest) async throws -> LlamaCppHTTPResponse {
        try Task.checkCancellation()
        lock.lock()
        storedRequests.append(request)
        let next = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()
        guard let next else { throw LlamaCppAdapterError.transportFailure }
        return try next.get()
    }
}

private actor CancellationIgnoringLlamaTransport: LlamaCppHTTPTransport {
    private let response: LlamaCppHTTPResponse
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<LlamaCppHTTPResponse, Never>?
    private var started = false
    init(response: LlamaCppHTTPResponse) { self.response = response }
    func send(_ request: LlamaCppHTTPRequest) async throws -> LlamaCppHTTPResponse {
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func release() { responseContinuation?.resume(returning: response); responseContinuation = nil }
}

final class LlamaCppLocalAdaptersTests: XCTestCase {
    private func endpoint(_ token: String = "ram-only-test-token") throws -> LlamaCppLocalEndpoint {
        try LlamaCppLocalEndpoint(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:8089")), bearerToken: token)
    }

    private func embeddingJSON(_ vector: [Float], index: Int = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": [["index": index, "embedding": vector]]])
    }

    func testEmbeddingUsesRolePrefixesAndPinnedIdentity() async throws {
        let transport = FakeLlamaTransport(body: try embeddingJSON(Array(repeating: 0.25, count: 768)))
        let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(), transport: transport)
        XCTAssertEqual(provider.identity, LlamaCppMemoryEmbeddingProvider.pinnedModelIdentity)
        XCTAssertEqual(provider.dimensions, 768)
        _ = try await provider.embed("find a preference", purpose: .query)
        _ = try await provider.embed("saved statement", purpose: .document)
        let requests = transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url.path, "/v1/embeddings")
        XCTAssertEqual(requests[0].authorization, "Bearer ram-only-test-token")
        let inputs = try requests.map { request -> String in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            return try XCTUnwrap(json["input"] as? String)
        }
        XCTAssertEqual(inputs, ["search_query: find a preference", "search_document: saved statement"])
        XCTAssertTrue((try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any]))
            .keys.contains("encoding_format"))
    }

    func testOptionalTokenLimitCountsPrefixedQueryAndDocumentExactly() async throws {
        let vector = Array(repeating: 0.25 as Float, count: 768)
        for (purpose, expectedInput) in [
            (MemoryEmbeddingPurpose.query, "search_query: sample text"),
            (.document, "search_document: sample text"),
        ] {
            let transport = SequencedLlamaTransport([
                .success(.init(statusCode: 200, body: Data("{\"tokens\":[1,2,3]}".utf8))),
                .success(.init(statusCode: 200, body: try embeddingJSON(vector))),
            ])
            let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(),
                transport: transport, maximumInputTokens: 3)
            _ = try await provider.embed("sample text", purpose: purpose)
            let requests = transport.requests
            XCTAssertEqual(requests.map(\.url.path), ["/tokenize", "/v1/embeddings"])
            let tokenRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
            XCTAssertEqual(tokenRequest["content"] as? String, expectedInput)
            XCTAssertEqual(tokenRequest["add_special"] as? Bool, true)
            XCTAssertEqual(tokenRequest["parse_special"] as? Bool, true)
            let embeddingRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
            XCTAssertEqual(embeddingRequest["input"] as? String, expectedInput)
        }
    }

    func testOptionalTokenLimitAllowsEqualBoundaryAndRefusesOneOverBeforeEmbedding() async throws {
        let vector = Array(repeating: 0.5 as Float, count: 768)
        let equal = SequencedLlamaTransport([
            .success(.init(statusCode: 200, body: Data("{\"tokens\":[1,2,3]}".utf8))),
            .success(.init(statusCode: 200, body: try embeddingJSON(vector))),
        ])
        let equalProvider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(),
            transport: equal, maximumInputTokens: 3)
        _ = try await equalProvider.embed("at limit", purpose: .query)
        XCTAssertEqual(equal.requests.map(\.url.path), ["/tokenize", "/v1/embeddings"])

        let over = SequencedLlamaTransport([
            .success(.init(statusCode: 200, body: Data("{\"tokens\":[1,2,3,4]}".utf8))),
        ])
        let overProvider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(),
            transport: over, maximumInputTokens: 3)
        do { _ = try await overProvider.embed("over limit", purpose: .query); XCTFail("over-limit input embedded") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .inputTooLarge) }
        XCTAssertEqual(over.requests.map(\.url.path), ["/tokenize"])
    }

    func testOptionalTokenLimitFailureOrCancellationNeverSendsEmbedding() async throws {
        let rejected = SequencedLlamaTransport([
            .success(.init(statusCode: 500, body: Data("private error".utf8))),
        ])
        let rejectedProvider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(),
            transport: rejected, maximumInputTokens: 512)
        do { _ = try await rejectedProvider.embed("safe", purpose: .document); XCTFail("tokenizer error ignored") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .rejectedResponse) }
        XCTAssertEqual(rejected.requests.map(\.url.path), ["/tokenize"])

        let cancelled = SequencedLlamaTransport([.failure(CancellationError())])
        let cancelledProvider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(),
            transport: cancelled, maximumInputTokens: 512)
        do { _ = try await cancelledProvider.embed("safe", purpose: .query); XCTFail("tokenizer cancellation ignored") }
        catch is CancellationError { }
        XCTAssertEqual(cancelled.requests.map(\.url.path), ["/tokenize"])
    }

    func testConfiguredTokenLimitMustBeWithinPinnedNomicContext() async throws {
        let transport = SequencedLlamaTransport([])
        for limit in [0, 8_193] {
            let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(),
                transport: transport, maximumInputTokens: limit)
            do { _ = try await provider.embed("safe", purpose: .query); XCTFail("invalid token bound accepted") }
            catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidConfiguration) }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testEmbeddingRejectsWrongIndexDimensionsNonfiniteAndZeroVectors() async throws {
        let good = Array(repeating: 1.0 as Float, count: 768)
        let transport = FakeLlamaTransport(body: try embeddingJSON(good, index: 1))
        let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(), transport: transport)
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("wrong index accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidResponse) }
        transport.setResponse(status: 200, body: try embeddingJSON([1, 2]))
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("wrong dimensions accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidResponse) }
        transport.setResponse(status: 200, body: try embeddingJSON(Array(repeating: 0, count: 768)))
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("zero vector accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidEmbedding) }
        var overflowing = Array(repeating: 1.0, count: 768)
        overflowing[0] = 1e308
        let overflowBody = try JSONSerialization.data(withJSONObject: ["data": [["index": 0,
            "embedding": overflowing]]])
        transport.setResponse(status: 200, body: overflowBody)
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("Float overflow accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidEmbedding) }
        let nanBody = Data("{\"data\":[{\"index\":0,\"embedding\":[NaN]}]}".utf8)
        transport.setResponse(status: 200, body: nanBody)
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("NaN accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidResponse) }
        let falseIndexBody = try JSONSerialization.data(withJSONObject: ["data": [["index": false,
            "embedding": good]]])
        transport.setResponse(status: 200, body: falseIndexBody)
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("boolean index accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidResponse) }
        let floatIndexBody = Data("{\"data\":[{\"index\":0.0,\"embedding\":[]}]}".utf8)
        transport.setResponse(status: 200, body: floatIndexBody)
        do { _ = try await provider.embed("x", purpose: .query); XCTFail("floating index accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidResponse) }
    }

    func testTokenizerCountsCompleteTextAndSendsExplicitSpecialTokenOptions() async throws {
        let transport = FakeLlamaTransport(body: Data("{\"tokens\":[4,5,6,7]}".utf8))
        let identity = try LlamaCppTokenizerIdentity(value: "planner-tokenizer-r7", addSpecialTokens: true,
                                                    parseSpecialTokens: false)
        let counter = LlamaCppMemoryTokenCounter(endpoint: try endpoint(), tokenizer: identity, transport: transport)
        let context = "{\"body\":\"all serialized content\",\"metadata\":true}"
        let tokenCount = try await counter.countTokens(in: context)
        XCTAssertEqual(tokenCount, 4)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.path, "/tokenize")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["content"] as? String, context)
        XCTAssertEqual(json["add_special"] as? Bool, true)
        XCTAssertEqual(json["parse_special"] as? Bool, false)
        XCTAssertEqual(json["with_pieces"] as? Bool, false)
        XCTAssertEqual(identity.value, "planner-tokenizer-r7")
        XCTAssertFalse(String(describing: identity).contains("planner-tokenizer-r7"))
        let requestDescription = String(reflecting: request)
        XCTAssertFalse(requestDescription.contains("ram-only-test-token"))
        XCTAssertFalse(requestDescription.contains(context))
        XCTAssertFalse(String(describing: request).contains(context))
        for tokenJSON in ["{\"tokens\":[true]}", "{\"tokens\":[-1]}",
                          "{\"tokens\":[1.5]}", "{\"tokens\":[1.0]}"] {
            transport.setResponse(status: 200, body: Data(tokenJSON.utf8))
            do { _ = try await counter.countTokens(in: context); XCTFail("malformed token id accepted: \(tokenJSON)") }
            catch { XCTAssertEqual(error as? LlamaCppAdapterError, .invalidResponse) }
        }
    }

    func testEndpointRejectsNonLoopbackOrAmbiguousConfiguration() throws {
        for raw in ["https://127.0.0.1:8089", "http://localhost:8089", "http://127.0.0.1",
                    "http://127.0.0.1:0", "http://127.0.0.1:8089/path",
                    "http://user@127.0.0.1:8089", "http://127.0.0.1:8089/?x=1",
                    "http://127.0.0.1:8089/#frag"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try LlamaCppLocalEndpoint(baseURL: url, bearerToken: "secret"), raw)
        }
        XCTAssertThrowsError(try LlamaCppLocalEndpoint(baseURL: URL(string: "http://127.0.0.1:8089")!,
                                                       bearerToken: "bad\nheader"))
    }

    func testInputAndResponseLimitsAndSanitizedStatusFailure() async throws {
        let transport = FakeLlamaTransport(status: 500, body: Data("SECRET-SERVER-ERROR".utf8))
        let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint("TOP-SECRET"), transport: transport)
        do { _ = try await provider.embed("safe", purpose: .query); XCTFail("server error accepted") }
        catch {
            XCTAssertEqual(error as? LlamaCppAdapterError, .rejectedResponse)
            XCTAssertFalse(String(describing: error).contains("SECRET"))
        }
        do { _ = try await provider.embed(String(repeating: "x", count: 32_769), purpose: .query); XCTFail("large input accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .inputTooLarge) }
        XCTAssertFalse(String(describing: try endpoint("TOP-SECRET")).contains("TOP-SECRET"))
        XCTAssertFalse(String(reflecting: try endpoint("TOP-SECRET")).contains("TOP-SECRET"))

        let huge = Data(repeating: 0x20, count: 65_537)
        let responseTransport = FakeLlamaTransport(body: huge)
        let boundedProvider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(), transport: responseTransport)
        do { _ = try await boundedProvider.embed("safe", purpose: .query); XCTFail("oversized response accepted") }
        catch { XCTAssertEqual(error as? LlamaCppAdapterError, .responseTooLarge) }
    }

    func testCancellationIsPreserved() async throws {
        let transport = FakeLlamaTransport(body: try embeddingJSON(Array(repeating: 1, count: 768)))
        transport.cancelRequests()
        let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(), transport: transport)
        do { _ = try await provider.embed("query", purpose: .query); XCTFail("cancel ignored") }
        catch is CancellationError { }
    }

    func testExternalCancellationWinsEvenIfTransportIgnoresIt() async throws {
        let response = LlamaCppHTTPResponse(statusCode: 200,
            body: try embeddingJSON(Array(repeating: 1, count: 768)))
        let transport = CancellationIgnoringLlamaTransport(response: response)
        let provider = LlamaCppMemoryEmbeddingProvider(endpoint: try endpoint(), transport: transport)
        let task = Task { try await provider.embed("query", purpose: .query) }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.release()
        do { _ = try await task.value; XCTFail("external cancellation was lost") }
        catch is CancellationError { }
    }

    func testProductionSessionIsEphemeralProxyDisabledAndRedirectIsRefused() throws {
        let configuration = URLSessionLlamaCppTransport.makeConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let proxy = try XCTUnwrap(configuration.connectionProxyDictionary)
        XCTAssertEqual(proxy["HTTPEnable"] as? Int, 0)
        XCTAssertEqual(proxy["HTTPSEnable"] as? Int, 0)
        XCTAssertEqual(proxy["SOCKSEnable"] as? Int, 0)
        XCTAssertEqual(proxy["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertEqual(proxy["ProxyAutoDiscoveryEnable"] as? Int, 0)

        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1")!)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://127.0.0.1:1")!,
            statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://example.com"]))
        var redirectedRequest: URLRequest? = URLRequest(url: URL(string: "http://example.com")!)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: redirectedRequest!) { redirectedRequest = $0 }
        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }
}
