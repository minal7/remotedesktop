import Foundation
import Darwin
import XCTest
@testable import RemoteDesktopHost

final class AgentEvalFaraHTTPLifecycleTests: XCTestCase {
    private let caseID = "memory-recall-10-01"
    private let token = "0123456789abcdef0123456789abcdef"
    private let runID = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB")!

    func testURLSessionDispatchLifecycleWritesActualBoundedAttempts() async throws {
        let temporaryRoot = try privateDirectory()
        let retainedRoot = ProcessInfo.processInfo.environment["EVAL_FARA_LIFECYCLE_TEST_RUN_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root: URL
        if let retainedRoot {
            try FileManager.default.createDirectory(at: retainedRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.removeItem(at: temporaryRoot)
            root = retainedRoot
        } else {
            root = temporaryRoot
        }
        defer { if retainedRoot == nil { try? FileManager.default.removeItem(at: root) } }
        let taskID = UUID().uuidString.lowercased()
        let env = ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token]
        let capture = AgentEvalFaraExchangeCapture(configuration: .init(caseID: caseID,
            runToken: token, driverTaskID: taskID, runRoot: root.path),
            lifecycleEnabled: true, environment: env)
        XCTAssertFalse(try capture.beginRequest(runID: nil), "Warmup has no fabricated run identity.")
        XCTAssertTrue(try capture.beginRequest(runID: runID))

        LifecycleURLProtocol.reset([
            "/apply-template": [.reply(200, Data(#"{"prompt":"rendered prompt"}"#.utf8))],
            "/tokenize": [.reply(200, Data(#"{"tokens":[1,2,3]}"#.utf8))],
            "/v1/chat/completions": [
                .reply(200, Data(#"{"choices":[{"message":{"content":"synthetic result"}}]}"#.utf8)),
                .reply(503, Data("DO_NOT_CAPTURE_HTTP_ERROR_BODY".utf8)),
                .hold(200, Data("partial lifecycle response".utf8)),
                .fail(200, Data("transport failure prefix".utf8)),
                .oversized,
            ],
        ])
        var configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        let progress = LifecycleProgressObserver(capture)
        let transport = URLSessionOSAtlasTransport(configuration: configuration, observer: progress)
        let completion = try completionRequest(path: "/v1/chat/completions",
            prompt: "EVAL_ONLY_CANARY_2a6d83c49ef14f93 completed request")
        let tokenCount = try await transport.exactInputTokenCount(completionRequest: completion)
        XCTAssertEqual(tokenCount, 3)
        let completionResponse = try await transport.complete(request: completion)
        XCTAssertFalse(completionResponse.isEmpty)

        let rejected = try completionRequest(path: "/v1/chat/completions", prompt: "synthetic http error")
        do { _ = try await transport.complete(request: rejected); XCTFail("HTTP error must reject") }
        catch { }

        let cancelled = try completionRequest(path: "/v1/chat/completions",
            prompt: "EVAL_ONLY_CANARY_2a6d83c49ef14f93 cancelled request")
        progress.reset()
        let task = Task { try await transport.complete(request: cancelled) }
        let requestStarted = await LifecycleURLProtocol.waitForStart()
        XCTAssertTrue(requestStarted)
        let readPrefix = await progress.waitForFirstByte()
        XCTAssertTrue(readPrefix)
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request must not return") }
        catch { }
        let stopped = await LifecycleURLProtocol.waitForStop()
        XCTAssertTrue(stopped)
        let transportFailure = try completionRequest(path: "/v1/chat/completions", prompt: "transport failure")
        do { _ = try await transport.complete(request: transportFailure); XCTFail("transport failure must reject") }
        catch { }
        let oversized = try completionRequest(path: "/v1/chat/completions", prompt: "oversized response")
        do { _ = try await transport.complete(request: oversized); XCTFail("oversized response must reject") }
        catch { }
        await transport.cancelAll()
        capture.endRequest()
        _ = try capture.finish()

        let runRoot = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        let evidence = runRoot.appendingPathComponent("evidence/fara-exchange", isDirectory: true)
        let receiptData = try Data(contentsOf: evidence.appendingPathComponent("receipt.json"))
        let receipt = try JSONDecoder().decode(AgentEvalFaraLifecycleReceipt.self, from: receiptData)
        XCTAssertEqual(receipt.schemaVersion, 2)
        XCTAssertEqual(receipt.producerID, "fara_http_lifecycle")
        XCTAssertEqual(receipt.coverageStatus, "incomplete")
        XCTAssertEqual(receipt.identity.caseID, caseID)
        XCTAssertEqual(receipt.identity.runToken, token)
        XCTAssertEqual(receipt.identity.driverTaskID, taskID)
        XCTAssertEqual(receipt.identity.runID, runID.uuidString)
        XCTAssertEqual(receipt.attemptCount, 7)
        XCTAssertEqual(receipt.attempts.map(\.kind), ["apply_template", "tokenize",
            "chat_completion", "chat_completion", "chat_completion", "chat_completion", "chat_completion"])
        XCTAssertEqual(receipt.attempts.map(\.outcome), ["completed", "completed", "completed",
            "http_error", "cancelled", "transport_error", "oversized"])
        XCTAssertEqual(receipt.attempts.map(\.index), Array(0..<7))
        XCTAssertTrue(receipt.attempts[0].responseComplete)
        XCTAssertNil(receipt.attempts[3].response, "HTTP error bodies are never consumed or saved")
        XCTAssertFalse(receipt.attempts[3].responseComplete)
        XCTAssertNotNil(receipt.attempts[4].response, "Bytes received before cancellation are retained")
        XCTAssertFalse(receipt.attempts[4].responseComplete)
        let cancelledPrefix = try XCTUnwrap(receipt.attempts[4].response)
        XCTAssertEqual(try Data(contentsOf: runRoot.appendingPathComponent(cancelledPrefix.path)),
            Data("partial lifecycle response".utf8))
        XCTAssertNotNil(receipt.attempts[5].response, "A failed stream retains only bytes already yielded")
        XCTAssertFalse(receipt.attempts[5].responseComplete)
        let failedPrefix = try XCTUnwrap(receipt.attempts[5].response)
        let failedBytes = try Data(contentsOf: runRoot.appendingPathComponent(failedPrefix.path))
        XCTAssertTrue(Data("transport failure prefix".utf8).starts(with: failedBytes),
            "A transport error may arrive before URLSession yields any buffered prefix")
        XCTAssertNil(receipt.attempts[6].response)
        XCTAssertFalse(receipt.attempts[6].responseComplete)
        let allBodyText = try (0..<7).flatMap { index -> [String] in
            let request = try XCTUnwrap(receipt.attempts[index].request)
            let requestBytes = try Data(contentsOf: runRoot.appendingPathComponent(request.path))
            var bodies = [String(decoding: requestBytes, as: UTF8.self)]
            if let response = receipt.attempts[index].response {
                bodies.append(String(decoding: try Data(contentsOf: runRoot.appendingPathComponent(response.path)),
                    as: UTF8.self))
            }
            return bodies
        }
        XCTAssertTrue(allBodyText.contains { $0.contains("EVAL_ONLY_CANARY_2a6d83c49ef14f93") })
        XCTAssertFalse(allBodyText.contains { $0.contains("DO_NOT_CAPTURE_HTTP_ERROR_BODY") })

        let identity = try JSONEncoder().encode(receipt.identity)
        try identity.write(to: root.appendingPathComponent("expected-identity.json"), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath:
            root.appendingPathComponent("expected-identity.json").path)
    }

    func testPreboundCaptureRequiresExactRunDirectoryAndKeepsReceiptAtRunPath() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runDirectory = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let taskID = UUID().uuidString.lowercased()
        let env = ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token]
        let configuration = EvalFaraHostExchangeCaptureConfiguration(caseID: caseID,
            runToken: token, driverTaskID: taskID, runRoot: root.path)

        XCTAssertThrowsError(try AgentEvalFaraExchangeCapture(
            runDirectory: root, configuration: configuration, runID: runID, environment: env))
        let capture = try AgentEvalFaraExchangeCapture(runDirectory: runDirectory,
            configuration: configuration, runID: runID, environment: env)
        XCTAssertThrowsError(try capture.beginRequest(runID: nil),
            "A prebound task cannot accept a missing run identity.")
        XCTAssertTrue(try capture.beginRequest(runID: runID))
        let attempt = UUID()
        capture.willDispatch(id: attempt, kind: .chatCompletion, body: Data("synthetic request".utf8))
        capture.didFinish(id: attempt, outcome: .completed,
            responseBody: Data("synthetic response".utf8), responseComplete: true)
        capture.endRequest()
        XCTAssertNil(try capture.finish())

        let receiptURL = runDirectory.appendingPathComponent("evidence/fara-exchange/receipt.json")
        let receipt = try JSONDecoder().decode(AgentEvalFaraLifecycleReceipt.self,
            from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.identity.caseID, caseID)
        XCTAssertEqual(receipt.identity.runToken, token)
        XCTAssertEqual(receipt.identity.driverTaskID, taskID)
        XCTAssertEqual(receipt.identity.runID, runID.uuidString)
        XCTAssertEqual(receipt.attemptCount, 1)
        XCTAssertEqual(receipt.attempts.first?.outcome, "completed")
    }

    func testCancelledBeforeDispatchDoesNotCreateAnAttemptAndNilObserverIsUnchanged() async throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = AgentEvalFaraExchangeCapture(configuration: .init(caseID: caseID,
            runToken: token, driverTaskID: UUID().uuidString.lowercased(), runRoot: root.path),
            lifecycleEnabled: true, environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        XCTAssertTrue(try capture.beginRequest(runID: runID))
        var configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        let request = try completionRequest(path: "/v1/chat/completions", prompt: "must not dispatch")
        let gate = LifecycleDispatchGate()
        let cancelledBeforeDispatch = Task {
            await gate.wait()
            try Task.checkCancellation()
            return try await URLSessionOSAtlasTransport(configuration: configuration, observer: capture)
                .complete(request: request)
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        cancelledBeforeDispatch.cancel()
        await gate.release()
        do { _ = try await cancelledBeforeDispatch.value; XCTFail("pre-cancelled task must stop") }
        catch { }
        XCTAssertEqual(LifecycleURLProtocol.dispatchCount, 0)
        let noObserver = URLSessionOSAtlasTransport(configuration: configuration)
        LifecycleURLProtocol.reset(["/v1/chat/completions": [.reply(200, Data("ok".utf8))]])
        let unobservedResponse = try await noObserver.complete(request: request)
        XCTAssertEqual(unobservedResponse, Data("ok".utf8))
        capture.endRequest()
        _ = try capture.finish()
        let url = root.appendingPathComponent(runID.uuidString)
            .appendingPathComponent("evidence/fara-exchange/receipt.json")
        let receipt = try JSONDecoder().decode(AgentEvalFaraLifecycleReceipt.self, from: Data(contentsOf: url))
        XCTAssertEqual(receipt.attemptCount, 0)
        XCTAssertEqual(LifecycleURLProtocol.dispatchCount, 1, "Only the observer-free request reached URLProtocol")
    }

    func testLifecycleCollectorBoundsAttemptsAndCountsDuplicateCallbacks() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = AgentEvalFaraExchangeCapture(configuration: .init(caseID: caseID,
            runToken: token, driverTaskID: UUID().uuidString.lowercased(), runRoot: root.path),
            lifecycleEnabled: true, environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        XCTAssertTrue(try capture.beginRequest(runID: runID))
        let duplicate = UUID()
        capture.willDispatch(id: duplicate, kind: .chatCompletion, body: Data("duplicate".utf8))
        capture.willDispatch(id: duplicate, kind: .chatCompletion, body: Data("must-not-replace".utf8))
        capture.didFinish(id: duplicate, outcome: .completed,
            responseBody: Data("response".utf8), responseComplete: true)
        capture.didFinish(id: duplicate, outcome: .completed,
            responseBody: Data("late".utf8), responseComplete: true)
        for _ in 1..<AgentEvalFaraExchangeEvidence.maximumLifecycleAttempts {
            let id = UUID()
            capture.willDispatch(id: id, kind: .tokenize, body: Data("request".utf8))
            capture.didFinish(id: id, outcome: .completed,
                responseBody: Data("response".utf8), responseComplete: true)
        }
        let overflowID = UUID()
        capture.willDispatch(id: overflowID, kind: .chatCompletion, body: Data("overflow".utf8))
        capture.didFinish(id: overflowID, outcome: .completed,
            responseBody: Data("overflow".utf8), responseComplete: true)
        capture.endRequest()
        _ = try capture.finish()
        let url = root.appendingPathComponent(runID.uuidString)
            .appendingPathComponent("evidence/fara-exchange/receipt.json")
        let receipt = try JSONDecoder().decode(AgentEvalFaraLifecycleReceipt.self, from: Data(contentsOf: url))
        XCTAssertEqual(receipt.attemptCount, AgentEvalFaraExchangeEvidence.maximumLifecycleAttempts)
        XCTAssertTrue(receipt.overflowed)
        XCTAssertEqual(receipt.attempts.map(\.index), Array(0..<AgentEvalFaraExchangeEvidence.maximumLifecycleAttempts))
        XCTAssertGreaterThanOrEqual(receipt.captureFailureCount, 3)
        XCTAssertEqual(Set(receipt.attempts.map(\.requestID)).count, receipt.attemptCount)
    }

    func testLifecycleCollectorPerBodyLimitAcceptsExactAndRejectsOneByteOver() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = AgentEvalFaraExchangeCapture(configuration: .init(caseID: caseID,
            runToken: token, driverTaskID: UUID().uuidString.lowercased(), runRoot: root.path),
            lifecycleEnabled: true, environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        XCTAssertTrue(try capture.beginRequest(runID: runID))

        let limit = AgentEvalFaraExchangeEvidence.maximumBodyBytes
        let exact = Data(repeating: 0x41, count: limit)
        let exactID = UUID()
        capture.willDispatch(id: exactID, kind: .chatCompletion, body: exact)
        capture.didFinish(id: exactID, outcome: .completed,
            responseBody: Data(), responseComplete: true)

        let tooLargeID = UUID()
        capture.willDispatch(id: tooLargeID, kind: .chatCompletion,
            body: Data(repeating: 0x42, count: limit + 1))
        capture.didFinish(id: tooLargeID, outcome: .transportError,
            responseBody: nil, responseComplete: false)
        capture.endRequest()
        _ = try capture.finish()

        let runRoot = root.appendingPathComponent(runID.uuidString)
        let receiptURL = runRoot.appendingPathComponent("evidence/fara-exchange/receipt.json")
        let receipt = try JSONDecoder().decode(AgentEvalFaraLifecycleReceipt.self,
            from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.attemptCount, 2)
        XCTAssertGreaterThanOrEqual(receipt.captureFailureCount, 1)
        let accepted = try XCTUnwrap(receipt.attempts.first)
        let requestArtifact = try XCTUnwrap(accepted.request)
        XCTAssertEqual(requestArtifact.byteCount, limit)
        XCTAssertEqual(try Data(contentsOf: runRoot.appendingPathComponent(requestArtifact.path)), exact)
        XCTAssertEqual(try XCTUnwrap(accepted.response).byteCount, 0)
        let rejected = try XCTUnwrap(receipt.attempts.last)
        XCTAssertNil(rejected.request, "Oversized request evidence is omitted rather than truncated")
        XCTAssertEqual(rejected.outcome, "transport_error")
    }

    func testLifecycleCollectorAggregateLimitAcceptsExactAndRejectsOneByteOver() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = AgentEvalFaraExchangeCapture(configuration: .init(caseID: caseID,
            runToken: token, driverTaskID: UUID().uuidString.lowercased(), runRoot: root.path),
            lifecycleEnabled: true, environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        XCTAssertTrue(try capture.beginRequest(runID: runID))

        let halfBody = Data(repeating: 0x53, count: 4 * 1_024 * 1_024)
        for _ in 0..<16 {
            let id = UUID()
            capture.willDispatch(id: id, kind: .chatCompletion, body: halfBody)
            capture.didFinish(id: id, outcome: .completed,
                responseBody: halfBody, responseComplete: true)
        }
        let overLimitID = UUID()
        capture.willDispatch(id: overLimitID, kind: .chatCompletion, body: Data())
        capture.didFinish(id: overLimitID, outcome: .completed,
            responseBody: Data([0x54]), responseComplete: true)
        capture.endRequest()
        _ = try capture.finish()

        let runRoot = root.appendingPathComponent(runID.uuidString)
        let receiptURL = runRoot.appendingPathComponent("evidence/fara-exchange/receipt.json")
        let receipt = try JSONDecoder().decode(AgentEvalFaraLifecycleReceipt.self,
            from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.attemptCount, 17)
        XCTAssertGreaterThanOrEqual(receipt.captureFailureCount, 1)
        XCTAssertTrue(receipt.attempts.prefix(16).allSatisfy {
            $0.request != nil && $0.response != nil && $0.responseComplete
        })
        let retained = try XCTUnwrap(receipt.attempts.first?.request)
        XCTAssertEqual(retained.byteCount, halfBody.count)
        XCTAssertEqual(try Data(contentsOf: runRoot.appendingPathComponent(retained.path)), halfBody)
        let overLimit = try XCTUnwrap(receipt.attempts.last)
        XCTAssertNotNil(overLimit.request)
        XCTAssertNil(overLimit.response, "The byte beyond the aggregate bound is not persisted")
        XCTAssertEqual(overLimit.outcome, "completed")
        XCTAssertTrue(overLimit.responseComplete, "Transport success remains distinct from evidence capture failure")
    }

    private func completionRequest(path: String, prompt: String) throws -> URLRequest {
        let url = URL(string: "http://127.0.0.1:43129\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer synthetic-only", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "synthetic",
            "messages": [["role": "system", "content": "system"], ["role": "user", "content": prompt]]])
        return request
    }

    private func privateDirectory() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard temporary.withCString({ realpath($0, &buffer) }) != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }
}

private final class LifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    enum Route { case reply(Int, Data), hold(Int, Data), fail(Int, Data), oversized }
    private static let lock = NSLock()
    private static var routes: [String: [Route]] = [:]
    private static var starts = 0
    private static var stops = 0
    private static var dispatches = 0
    private var held = false
    static var dispatchCount: Int { lock.withLock { dispatches } }
    static func reset(_ values: [String: [Route]]) {
        lock.withLock { routes = values; starts = 0; stops = 0; dispatches = 0 }
    }
    private static func next(_ path: String) -> Route? {
        lock.withLock {
            dispatches += 1
            guard var queue = routes[path], !queue.isEmpty else { return nil }
            let value = queue.removeFirst(); routes[path] = queue; return value
        }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.scheme == "http"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let path = request.url?.path, let route = Self.next(path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let status: Int, body: Data, hold: Bool, oversized: Bool, fail: Bool
        switch route {
        case .reply(let code, let data): (status, body, hold, oversized, fail) = (code, data, false, false, false)
        case .hold(let code, let data): (status, body, hold, oversized, fail) = (code, data, true, false, false)
        case .fail(let code, let data): (status, body, hold, oversized, fail) = (code, data, false, false, true)
        case .oversized: (status, body, hold, oversized, fail) = (200, Data(), true, true, false)
        }
        guard let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: oversized
                ? ["Content-Type": "application/json", "Content-Length": "1048577"]
                : ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if hold { held = true; Self.lock.withLock { Self.starts += 1 } }
        else if fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { if held { held = false; Self.lock.withLock { Self.stops += 1 } } }
    static func waitForStart() async -> Bool {
        for _ in 0..<100 {
            if lock.withLock({ starts > 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    static func waitForStop() async -> Bool {
        for _ in 0..<100 {
            if lock.withLock({ stops > 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class LifecycleProgressObserver: OSAtlasLlamaHTTPRequestObserver, @unchecked Sendable {
    private let capture: AgentEvalFaraExchangeCapture
    private let lock = NSLock()
    private var observed = false
    init(_ capture: AgentEvalFaraExchangeCapture) { self.capture = capture }
    func reset() { lock.withLock { observed = false } }
    func willDispatch(id: UUID, kind: OSAtlasLlamaHTTPRequestKind, body: Data) {
        capture.willDispatch(id: id, kind: kind, body: body)
    }
    func didReadResponsePrefix(id: UUID, byteCount: Int) {
        capture.didReadResponsePrefix(id: id, byteCount: byteCount)
        lock.withLock { observed = byteCount > 0 }
    }
    func didFinish(id: UUID, outcome: OSAtlasLlamaHTTPOutcome,
                   responseBody: Data?, responseComplete: Bool) {
        capture.didFinish(id: id, outcome: outcome, responseBody: responseBody,
            responseComplete: responseComplete)
    }
    func waitForFirstByte() async -> Bool {
        for _ in 0..<100 {
            if lock.withLock({ observed }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor LifecycleDispatchGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            entered = true
            if released { continuation.resume() }
            else { self.continuation = continuation }
        }
    }
    func waitUntilEntered() async -> Bool {
        for _ in 0..<100 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
