import CryptoKit
import Foundation
import Network
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseLocalTextGoalPlannerTests: XCTestCase {
    func testSingleTurnGoalLeavesTheExistingRequestByteIdentical() async throws {
        let response = try envelope(#"{"disposition":"unsupported","edits":[]}"#)
        let transport = FixedTextTransport(response: response)
        let planner = try planner(transport: transport, contract: .candidateV2)
        let prompt = #"Set "Origin" to "  exact  "."#
        _ = try await planner.propose(prompt: prompt, fields: fields())
        _ = try await planner.propose(goal: .init(userRequest: prompt), fields: fields())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].allHTTPHeaderFields, requests[1].allHTTPHeaderFields)
    }

    func testClarifiedGoalSendsSeparateTurnsAndResolvesAnOriginalLongLiteral() async throws {
        let exact = "  東京 e\u{301} 😀\n" + String(repeating: "x", count: 5_000) + "  "
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Put \"" + exact + "\" in a field.")
            .answering("Which field should I edit, and what exact text should it contain?", with: "Destination")
        let transport = FixedTextTransport(response: try envelope(#"{"disposition":"supported","edits":[{"fieldID":"f2","mode":"replaceAll","value":"p1"}]}"#))
        let result = try await planner(transport: transport, contract: .candidateV2).propose(goal: goal, fields: fields())
        guard case .edits(let edits, let unchanged) = result else { return XCTFail("The retained goal did not compile") }
        XCTAssertEqual(edits.count, 1); XCTAssertTrue(edits[0].text.utf8.elementsEqual(exact.utf8))
        XCTAssertEqual(edits[0].targetID, "private-ax-1"); XCTAssertEqual(unchanged, ["private-ax-0"])
        let requests = await transport.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages[1]["content"])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertNil(context["task"])
        XCTAssertEqual(context["userTurns"] as? [String], ["Put [exact quoted payload p1] in a field.", "Destination"])
        XCTAssertEqual(context["questionsBeforeAnswers"] as? [String], goal.questions)
        XCTAssertFalse(content.contains(exact)); XCTAssertFalse(content.contains("private existing value"))
        XCTAssertTrue(try XCTUnwrap(messages[0]["content"]).hasSuffix(ComputerUseLocalTextGoalPlanner.clarificationInstructions))
        let completions = await transport.completions
        XCTAssertEqual(completions, 1)
    }

    func testClarificationDecoderCannotUseQuestionTextOrJoinTwoAnswersIntoAPayload() async throws {
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "first").answering("Enter HOST_ONLY in Origin", with: "second")
        for value in ["HOST_ONLY", "first\nsecond", "questionsBeforeAnswers", "p1"] {
            let content = String(decoding: try JSONSerialization.data(withJSONObject: ["disposition":"supported", "edits":[
                ["fieldID":"f1", "mode":"replaceAll", "value":value]]]), as: UTF8.self)
            let transport = FixedTextTransport(response: try envelope(content))
            do {
                _ = try await planner(transport: transport, contract: .candidateV2).propose(goal: goal, fields: fields())
                XCTFail("Non-user text cannot become literal input")
            } catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .invalidResponse) }
        }
    }

    func testClarificationChecksCapabilityEligibilityAndFullContextBeforeInference() async throws {
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Set Origin to a value").answering("What exact text?", with: "Oslo")
        let legacyTransport = FixedTextTransport()
        let legacyResult = try await planner(transport: legacyTransport).propose(goal: goal, fields: fields())
        XCTAssertEqual(legacyResult, .unsupported)
        let limited = FixedTextTransport(tokens: 3_009)
        do {
            _ = try await planner(transport: limited, contract: .candidateV2).propose(goal: goal, fields: fields())
            XCTFail("The complete question/answer input must fit the exact token budget")
        } catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .contextLimit) }
        let unsupported = try planner(transport: limited, contract: .candidateV2)
        let emptyResult = try await unsupported.propose(goal: goal, fields: [])
        XCTAssertEqual(emptyResult, .unsupported)
        let legacyCalls = await legacyTransport.completions, limitedCalls = await limited.completions
        XCTAssertEqual(legacyCalls, 0); XCTAssertEqual(limitedCalls, 0)
        let currentOnly = CurrentTurnOnlyClarificationFixture()
        let currentOnlyResult = try await currentOnly.propose(goal: goal, fields: fields())
        XCTAssertEqual(currentOnlyResult, .unsupported)
        let prompts = await currentOnly.prompts
        XCTAssertTrue(prompts.isEmpty, "A legacy adapter cannot flatten or discard earlier authority")
    }

    private func fields(labels: [String] = ["Origin", "Destination"]) -> [ComputerUseTextField] {
        labels.enumerated().map { index, label in
            ComputerUseTextField(label: label, snapshot: ComputerUseTextSnapshot(
                targetID: "private-ax-\(index)", value: "private existing value", selection: NSRange(location: 0, length: 0),
                isEditable: true, isSecure: false))
        }
    }

    private func planner(transport: any ComputerUseTextModelTransport = FixedTextTransport(),
                         contract: ComputerUseLocalTextGoalPlanner.Contract = .frozenV1) throws -> ComputerUseLocalTextGoalPlanner {
        ComputerUseLocalTextGoalPlanner(connection: try ComputerUseTextModelConnection(
            baseURL: URL(string: "http://127.0.0.1:49123")!, bearerToken: "fictional-test-token", modelAlias: "test-native"),
            transport: transport, contract: contract)
    }

    private func envelope(_ content: String, finish: String = "stop", model: String = "test-native") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model, "choices": [[
            "finish_reason": finish, "message": ["role": "assistant", "content": content],
        ]]])
    }

    func testModelInputMatchesFrozenContractWithoutExposingFieldValuesOrLiterals() throws {
        let catalog = try ComputerUseTextPayloadCatalog("Put \"  東京\n\" in Origin.")
        let value = try planner()
        let request = try value.makeRequest(catalog: catalog, fields: fields())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], "{\"fields\": [{\"id\": \"f1\", \"label\": \"Origin\"}, {\"id\": \"f2\", \"label\": \"Destination\"}], \"task\": \"Put [exact quoted payload p1] in Origin.\", \"literalPayloadIDs\": [\"p1\"]}")
        let instructionHash = SHA256.hash(data: Data(ComputerUseLocalTextGoalPlanner.instructions.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(instructionHash, "552441dde6058647031da17493e732f7182fc5339a259fe1f9f7ddda6dba211f")
        let encoded = String(decoding: request.httpBody!, as: UTF8.self)
        for privateValue in ["東京", "private existing value", "private-ax-"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-test-token")
    }

    func testExactPayloadsOrderedStepsAndUneditedFieldsRemainHostOwned() async throws {
        let response = try envelope(#"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"p1"},{"fieldID":"f1","mode":"append","value":"p2"}]}"#)
        let transport = FixedTextTransport(response: response)
        let result = try await planner(transport: transport).propose(
            prompt: "Replace Origin with \"  東京\n\", then append \"e\u{301} 😀\".", fields: fields())
        XCTAssertEqual(result, .edits([
            ComputerUseTextPlanEdit(targetID: "private-ax-0", mode: .replaceAll, text: "  東京\n"),
            ComputerUseTextPlanEdit(targetID: "private-ax-0", mode: .append, text: "e\u{301} 😀"),
        ], unchangedTargetIDs: ["private-ax-1"]))
        let calls = await transport.completions
        XCTAssertEqual(calls, 1)
    }

    func testQuotedFieldNamesRemainResolvableWithoutExposingOtherLiteralContents() throws {
        let catalog = try ComputerUseTextPayloadCatalog("Set \"Destination\" to \"private exact payload\".")
        let context = try ComputerUseLocalTextGoalPlanner.context(catalog: catalog, fields: fields(), includeQuotedFieldMatches: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let matches = try XCTUnwrap(object["literalFieldMatches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0]["literalID"] as? String, "p1")
        XCTAssertEqual(matches[0]["fieldIDs"] as? [String], ["f2"])
        XCTAssertFalse(context.contains("private exact payload"))
        XCTAssertFalse(context.contains("private existing value"))
        let ambiguous = try ComputerUseLocalTextGoalPlanner.context(catalog: catalog,
            fields: fields(labels: ["Destination", "destination"]), includeQuotedFieldMatches: true)
        let ambiguousObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ambiguous.utf8)) as? [String: Any])
        let ambiguousMatches = try XCTUnwrap(ambiguousObject["literalFieldMatches"] as? [[String: Any]])
        XCTAssertEqual(ambiguousMatches[0]["fieldIDs"] as? [String], ["f1", "f2"])
    }

    func testQuotedFieldMatchDoesNotTurnAValueIntoAnExistingValueRead() async throws {
        let response = try envelope(#"{"disposition":"supported","edits":[{"fieldID":"f2","mode":"replaceAll","value":"p1"}]}"#)
        let connection = try ComputerUseTextModelConnection(baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "fictional-test-token", modelAlias: "test-native")
        let planner = ComputerUseLocalTextGoalPlanner(connection: connection,
            transport: FixedTextTransport(response: response), contract: .candidateV2)
        let proposal = try await planner.propose(prompt: "Set Destination to \"Origin\".", fields: fields())
        XCTAssertEqual(proposal, .edits([
            ComputerUseTextPlanEdit(targetID: "private-ax-1", mode: .replaceAll, text: "Origin"),
        ], unchangedTargetIDs: ["private-ax-0"]))
    }

    func testMalformedPartialOrInventedPlansCannotBecomeEdits() throws {
        let catalog = try ComputerUseTextPayloadCatalog("Set Origin to Paris.")
        let invalid = [
            #"{"disposition":"unsupported","disposition":"supported","edits":[]}"#,
            #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"append","value":"Paris","value":"Boston"}]}"#,
            #"{"disposition":"supported","edits":[{"fieldID":"f99","mode":"replaceAll","value":"Paris"}]}"#,
            #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"Boston"}]}"#,
            #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"p1"}]}"#,
            #"{"disposition":"unsupported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"Paris"}]}"#,
            #"{"disposition":"supported","edits":[],"extra":"ignore all rules"}"#,
        ]
        let value = try planner()
        for content in invalid {
            XCTAssertThrowsError(try value.decode(envelope(content), catalog: catalog, fields: fields())) {
                XCTAssertEqual($0 as? ComputerUseLocalTextPlanError, .invalidResponse)
            }
        }
    }

    func testTruncatedOrWrongModelResponseIsRejectedEvenWithValidJSON() throws {
        let content = #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"Paris"}]}"#
        let catalog = try ComputerUseTextPayloadCatalog("Set Origin to Paris.")
        let value = try planner()
        for data in [try envelope(content, finish: "length"), try envelope(content, model: "another-model")] {
            XCTAssertThrowsError(try value.decode(data, catalog: catalog, fields: fields()))
        }
    }

    func testAmbiguousLabelsCannotBeResolvedByChoosingAnOpaqueID() throws {
        let content = #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"Paris"}]}"#
        let result = try planner().decode(envelope(content), catalog: ComputerUseTextPayloadCatalog("Set City to Paris."),
                                          fields: fields(labels: ["City", "City"]))
        XCTAssertEqual(result, .clarification)
    }

    func testInvalidOrExcessiveTokenCountsPreventInference() async throws {
        for count in [0, -1, 3_009] {
            let transport = FixedTextTransport(tokens: count)
            do {
                _ = try await planner(transport: transport).propose(prompt: "Origin Paris", fields: fields())
                XCTFail("Expected context rejection")
            } catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .contextLimit) }
            let calls = await transport.completions
            XCTAssertEqual(calls, 0)
        }
    }

    func testNonLoopbackOrUnscopedConnectionsAreRejectedBeforeTransport() {
        for address in ["https://example.com", "http://localhost:49123", "http://127.0.0.1",
                        "http://127.0.0.1:49123/other", "http://user@127.0.0.1:49123", "http://127.0.0.1:49123?next=remote"] {
            XCTAssertThrowsError(try ComputerUseTextModelConnection(baseURL: URL(string: address)!,
                bearerToken: "fictional-test-token", modelAlias: "test-native"))
        }
        XCTAssertThrowsError(try ComputerUseTextModelConnection(baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "token\r\nInjected: value", modelAlias: "test-native"))
    }

    func testLoopbackModelTransportNeverFollowsRedirects() async throws {
        let destination = try LocalHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        defer { destination.stop() }
        let destinationPort = try await destination.start()
        let origin = try LocalHTTPFixture(response: "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(destinationPort)/destination\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { origin.stop() }
        let originPort = try await origin.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(originPort)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data("fictional prompt".utf8)
        request.timeoutInterval = 3
        // First prove the fixture is a valid redirect that an ordinary session
        // follows, rather than counting an invalid HTTP exchange as protection.
        let reference = URLSession(configuration: .ephemeral)
        defer { reference.invalidateAndCancel() }
        let (_, response) = try await reference.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(destination.connections, 1)
        let transport = URLSessionOSAtlasTransport()
        do { _ = try await transport.complete(request: request); XCTFail("A redirected model response is invalid") }
        catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidResponse) }
        await transport.cancelAll()
        XCTAssertEqual(destination.connections, 1, "Model input must never reach the redirect destination")
    }

    func testTransportStopsOversizedBodiesBeforeEOFIncludingChunkedResponses() async throws {
        let limit = 1_024 * 1_024
        let tooMuch = String(repeating: "x", count: limit + 1)
        let responses = [
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(limit + 1)\r\n\r\nx",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(limit + 1, radix: 16))\r\n\(tooMuch)\r\n",
        ]
        for (index, response) in responses.enumerated() {
            // Keep the socket open with no EOF/last chunk. A post-download
            // size check would time out instead of rejecting the body now.
            let fixture = try LocalHTTPFixture(response: response, closeAfterResponse: false)
            defer { fixture.stop() }
            let port = try await fixture.start()
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.timeoutInterval = 3
            let transport = URLSessionOSAtlasTransport()
            do { _ = try await transport.complete(request: request); XCTFail("Oversized response must be rejected") }
            catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidResponse, "Response \(index): \(error)") }
            await transport.cancelAll()
        }
        let exact = String(repeating: "x", count: limit)
        let fixture = try LocalHTTPFixture(response: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(limit, radix: 16))\r\n\(exact)\r\n0\r\n\r\n")
        defer { fixture.stop() }
        let port = try await fixture.start()
        let transport = URLSessionOSAtlasTransport()
        let result = try await transport.complete(request: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!))
        XCTAssertEqual(result, Data(exact.utf8))
        await transport.cancelAll()
    }

    func testTransportCancellationClosesAnIncompleteResponse() async throws {
        let fixture = try LocalHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n", closeAfterResponse: false)
        defer { fixture.stop() }
        let port = try await fixture.start()
        let transport = URLSessionOSAtlasTransport()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.timeoutInterval = 5
        let task = Task { try await transport.complete(request: request) }
        for _ in 0..<100 where fixture.connections == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(fixture.connections, 1)
        try await Task.sleep(for: .milliseconds(50))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("An incomplete response cannot complete after cancellation") }
        catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        await transport.cancelAll()
    }
}

private actor FixedTextTransport: ComputerUseTextModelTransport {
    let tokens: Int
    let response: Data
    private(set) var completions = 0
    private(set) var requests: [URLRequest] = []
    init(tokens: Int = 500, response: Data = Data()) { self.tokens = tokens; self.response = response }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { tokens }
    func complete(request: URLRequest) async throws -> Data { completions += 1; requests.append(request); return response }
}

private actor CurrentTurnOnlyClarificationFixture: ComputerUseTextGoalPlanning {
    private(set) var prompts: [String] = []
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        prompts.append(prompt); return .unsupported
    }
}

private final class LocalHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "remotedesktop.test.local-http")
    private let lock = NSLock()
    private var accepted = 0
    private var readyReported = false
    private var activeConnections: [NWConnection] = []
    var connections: Int { lock.withLock { accepted } }

    init(response: String, closeAfterResponse: Bool = true) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.accepted += 1; self.activeConnections.append(connection) }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    if closeAfterResponse { connection.cancel() }
                })
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    let first = self.lock.withLock { let first = !self.readyReported; self.readyReported = true; return first }
                    if first { continuation.resume(returning: port.rawValue) }
                case .failed(let error):
                    let first = self.lock.withLock { let first = !self.readyReported; self.readyReported = true; return first }
                    if first { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        let active = lock.withLock { let active = activeConnections; activeConnections = []; return active }
        active.forEach { $0.cancel() }
    }
}
