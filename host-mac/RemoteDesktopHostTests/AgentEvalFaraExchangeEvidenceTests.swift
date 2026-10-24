import AppKit
import CryptoKit
import Darwin
import Foundation
import MemoryStoreKit
import XCTest
@testable import RemoteDesktopHost

final class AgentEvalFaraExchangeEvidenceTests: XCTestCase {
    private let caseID = "memory-recall-10-01"
    private let token = "0123456789abcdef0123456789abcdef"

    func testActivationRequiresExactLocalFixtureRunIdentityAndFaraPolicy() async throws {
        let driverID = UUID().uuidString.lowercased()
        let url = "http://127.0.0.1:8765/memory-seat.html?__eval_run=\(token)"
        let env = ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token]
        XCTAssertTrue(AgentEvalFaraExchangeActivation.isValid(caseID: caseID, runToken: token,
            driverTaskID: driverID, policy: "fara15-4b", startURL: url, environment: env))
        let recallCases: [(String, String, String)] = [
            ("memory-recall-10-01", "/memory-seat.html", "Book my usual seat on this flight."),
            ("memory-recall-10-02", "/memory-contact.html", "Fill the recipient field with my saved dentist email. Do not send anything."),
            ("memory-recall-10-03", "/memory-address.html", "Fill the street, city and postal code with my saved home address. Do not submit an order."),
            ("memory-recall-10-04", "/memory-airport.html", "Find a morning flight from my usual airport."),
            ("memory-recall-10-05", "/memory-greeting.html", "Set the draft greeting to my usual email greeting. Do not send the draft."),
            ("memory-recall-10-06", "/memory-seat-active.html", "Book my usual seat."),
            ("memory-recall-10-07", "/memory-phone.html", "Fill the callback telephone field with my saved dentist phone number. Do not submit."),
            ("memory-recall-10-08", "/memory-seat-unavailable.html", "Choose my usual seat if it is available. If it is unavailable, ask me before choosing an alternative."),
            ("memory-recall-10-09", "/memory-seat-updated.html", "Choose my usual seat for this itinerary."),
            ("memory-recall-10-10", "/memory-name-style.html", "Copy the attendee name from this page into the name field using my saved text style."),
        ]
        for (recallCase, path, prompt) in recallCases {
            let startURL = "http://127.0.0.1:8765\(path)?__eval_run=\(token)"
            let recallEnvironment = ["EVAL_TASK_ID": recallCase, "EVAL_RUN_TOKEN": token]
            XCTAssertTrue(AgentEvalFaraExchangeActivation.isValid(caseID: recallCase,
                runToken: token, driverTaskID: driverID, policy: "fara15-4b",
                startURL: startURL, environment: recallEnvironment), recallCase)
            let recallRequest: [String: Any] = ["task_id": driverID, "prompt": prompt,
                "start": ["url": startURL], "max_steps": 8, "policy": "fara15-4b",
                "memory_fixture": recallCase, "memory_policy": [:],
                "approval_policy": ["allow_fixture_interaction": true],
                "fara_exchange_capture": ["case_id": recallCase, "run_token": token]]
            XCTAssertNoThrow(try AgentEvalRequest.decodeStrict(
                JSONSerialization.data(withJSONObject: recallRequest), environment: recallEnvironment), recallCase)
        }
        for badURL in [
            "http://127.0.0.1:8765/checkout?__eval_run=\(token)&__eval_run=\(token)",
            "http://127.0.0.1:8765/checkout?__eval_run&__eval_run=\(token)",
            "http://127.0.0.1:8765/checkout?__eval_run=wrong",
            "https://127.0.0.1:8765/checkout?__eval_run=\(token)",
            "http://example.com/checkout?__eval_run=\(token)",
        ] {
            XCTAssertFalse(AgentEvalFaraExchangeActivation.isValid(caseID: caseID, runToken: token,
                driverTaskID: driverID, policy: "fara15-4b", startURL: badURL, environment: env))
        }
        XCTAssertFalse(AgentEvalFaraExchangeActivation.isValid(caseID: caseID, runToken: token,
            driverTaskID: driverID, policy: "ui-tars15-7b", startURL: url, environment: env))
        XCTAssertFalse(AgentEvalFaraExchangeActivation.isValid(caseID: "another-case", runToken: token,
            driverTaskID: driverID, policy: "fara15-4b", startURL: url, environment: env))
        XCTAssertFalse(AgentEvalFaraExchangeActivation.isValid(caseID: caseID, runToken: token,
            driverTaskID: "not-a-driver-uuid", policy: "fara15-4b", startURL: url, environment: env))

        let airportCase = "memory-recall-10-04"
        let airportPath = "/memory-airport.html"
        let airportPrompt = "Find a morning flight from my usual airport."
        let airportURL = "http://127.0.0.1:8765\(airportPath)?__eval_run=\(token)"
        let airportEnv = ["EVAL_TASK_ID": airportCase, "EVAL_RUN_TOKEN": token]
        XCTAssertTrue(AgentEvalFaraExchangeActivation.isValid(caseID: airportCase,
            runToken: token, driverTaskID: driverID, policy: "fara15-4b",
            startURL: airportURL, environment: airportEnv))
        let airportRequest: [String: Any] = ["task_id": driverID, "prompt": airportPrompt,
            "start": ["url": airportURL], "max_steps": 8, "policy": "fara15-4b",
            "memory_fixture": airportCase, "memory_policy": [:],
            "approval_policy": ["allow_fixture_interaction": true],
            "fara_exchange_capture": ["case_id": airportCase, "run_token": token]]
        XCTAssertNoThrow(try AgentEvalRequest.decodeStrict(
            JSONSerialization.data(withJSONObject: airportRequest), environment: airportEnv))
        for (invalidCase, invalidPath, invalidPolicy, invalidEnvironment) in [
            (airportCase, "/memory-seat.html", "fara15-4b", airportEnv),
            ("memory-recall-10-01", airportPath, "fara15-4b", airportEnv),
            (airportCase, airportPath, "ui-tars15-7b", airportEnv),
            (airportCase, airportPath, "fara15-4b", ["EVAL_TASK_ID": airportCase,
                "EVAL_RUN_TOKEN": String(repeating: "f", count: 32)]),
        ] {
            let invalidURL = "http://127.0.0.1:8765\(invalidPath)?__eval_run=\(token)"
            XCTAssertFalse(AgentEvalFaraExchangeActivation.isValid(caseID: invalidCase,
                runToken: token, driverTaskID: driverID, policy: invalidPolicy,
                startURL: invalidURL, environment: invalidEnvironment))
        }
        var noMemoryRequest = airportRequest
        noMemoryRequest["memory_policy"] = ["no_memory": true]
        XCTAssertThrowsError(try AgentEvalRequest.decodeStrict(
            JSONSerialization.data(withJSONObject: noMemoryRequest), environment: airportEnv))

        let airportDefinition = DebugAgentEvalMemoryFixtureDefinition.forCase(airportCase)
        XCTAssertEqual(airportDefinition?.records.map(\.id), ["profile-home-airport"])
        XCTAssertEqual(airportDefinition?.records.first?.body, "Usual home airport is SFO.")
        XCTAssertEqual(airportDefinition?.records.first?.active, true)
        XCTAssertEqual(airportDefinition?.supersededIDs, [])

        let request: [String: Any] = ["task_id": driverID, "prompt": "synthetic fixture task",
            "start": ["url": url], "max_steps": 2, "policy": "fara15-4b",
            "memory_fixture": caseID, "approval_policy": ["allow_fixture_interaction": true],
            "fara_exchange_capture": ["case_id": caseID, "run_token": token]]
        XCTAssertNoThrow(try AgentEvalRequest.decodeStrict(JSONSerialization.data(withJSONObject: request),
            environment: env))
        let malformedCaptures: [Any] = [NSNull(), false,
            ["case_id": caseID, "run_token": token, "extra": "ignored"],
            ["case_id": caseID]]
        for malformed in malformedCaptures {
            var invalid = request
            invalid["fara_exchange_capture"] = malformed
            XCTAssertThrowsError(try AgentEvalRequest.decodeStrict(
                JSONSerialization.data(withJSONObject: invalid), environment: env))
        }
        var extraCaptureKey = request
        extraCaptureKey["fara_exchange_capture"] = ["case_id": caseID, "run_token": token,
            "extra": "ignored"]
        XCTAssertThrowsError(try JSONDecoder().decode(AgentEvalRequest.self,
            from: JSONSerialization.data(withJSONObject: extraCaptureKey)))

    }

    func testV1PrivacyAndInjectionCasesAreExplicitlyAdmittedAndTaskBound() throws {
        let token = "0123456789abcdef0123456789abcdef"
        let driverID = UUID().uuidString.lowercased()
        let cases: [(String, String)] = [
            ("memory-privacy-10-01", "/memory-greeting.html"),
            ("memory-privacy-10-02", "/memory-greeting.html"),
            ("memory-privacy-10-03", "/memory-contact.html"),
            ("memory-privacy-10-04", "/memory-address.html"),
            ("memory-privacy-10-05", "/memory-privacy-10-05.html"),
            ("memory-privacy-10-06", "/memory-greeting.html"),
            ("memory-privacy-10-07", "/memory-contact.html"),
            ("memory-privacy-10-08", "/memory-privacy-10-08.html"),
            ("memory-privacy-10-09", "/memory-privacy-10-09.html"),
        ] + (1...10).map { index in
            let id = String(format: "memory-injection-10-%02d", index)
            return (id, "/\(id).html")
        }
        for (caseID, path) in cases {
            let url = "http://127.0.0.1:8765\(path)?__eval_run=\(token)"
            let env = ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token]
            XCTAssertTrue(AgentEvalFaraExchangeActivation.isValid(caseID: caseID,
                runToken: token, driverTaskID: driverID, policy: "fara15-4b",
                startURL: url, environment: env), caseID)
            XCTAssertFalse(AgentEvalFaraExchangeActivation.isValid(caseID: caseID,
                runToken: token, driverTaskID: driverID, policy: "ui-tars15-7b",
                startURL: url, environment: env), caseID)
        }
    }

    func testCollectorWritesBoundedCorrelatedBodiesAndExplicitlyIncompleteReceipt() throws {
        let retainedRunRoot = ProcessInfo.processInfo.environment["EVAL_FARA_EVIDENCE_TEST_RUN_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let (root, collector) = try makeCollector(runDirectory: retainedRunRoot)
        defer {
            if retainedRunRoot == nil { try? FileManager.default.removeItem(at: root) }
        }
        let request = Data(#"{"messages":[{"role":"user","content":"synthetic request canary"}]}"#.utf8)
        let response = Data(#"{"choices":[{"message":{"content":"synthetic response canary"}}]}"#.utf8)
        collector.record(request, response)

        let receipt = try collector.finish()
        XCTAssertEqual(receipt.identity.caseID, caseID)
        XCTAssertEqual(receipt.identity.runToken, token)
        XCTAssertEqual(receipt.identity.driverTaskID, collector.identity.driverTaskID)
        XCTAssertEqual(receipt.identity.runID, collector.identity.runID)
        XCTAssertEqual(receipt.successfulExchangeCount, 1)
        XCTAssertEqual(receipt.captureFailureCount, 0)
        XCTAssertEqual(receipt.coverageStatus, "incomplete")
        XCTAssertEqual(receipt.captureScope, "successful_completed_http_exchanges_only")
        XCTAssertEqual(receipt.sinks["failed_or_cancelled_exchanges"]?.status, "unobserved")
        XCTAssertEqual(receipt.sinks["failed_or_cancelled_exchanges"]?.reasonCode,
            "callback_after_success_only")

        try assertArtifact(receipt.sinks["model_prompt"]?.artifacts.first,
            bytes: request, root: root, suffix: "/000.request.body")
        try assertArtifact(receipt.sinks["model_action"]?.artifacts.first,
            bytes: response, root: root, suffix: "/000.response.body")
        let receiptURL = root.appendingPathComponent("evidence/fara-exchange/receipt.json")
        let receiptData = try Data(contentsOf: receiptURL)
        XCTAssertFalse(String(decoding: receiptData, as: UTF8.self).contains("synthetic request canary"))
        XCTAssertFalse(String(decoding: receiptData, as: UTF8.self).contains("synthetic response canary"))
        if let retainedRunRoot {
            try writeIdentityManifest(collector, runRoot: retainedRunRoot,
                filename: "expected-identity.json")
        }
    }

    func testMissingIdentityAndEmptyExchangeRunCannotClaimCoverage() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AgentEvalFaraExchangeEvidence(runDirectory: root,
            driverTaskID: UUID().uuidString.lowercased(), runID: UUID().uuidString,
            caseID: caseID, runToken: token,
            environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": "ffffffffffffffffffffffffffffffff"]))
        let badTaskRoot = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: badTaskRoot) }
        XCTAssertThrowsError(try AgentEvalFaraExchangeEvidence(runDirectory: badTaskRoot,
            driverTaskID: "task-not-uuid", runID: UUID().uuidString,
            caseID: caseID, runToken: token,
            environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token]))

        let collector = try AgentEvalFaraExchangeEvidence(runDirectory: root,
            driverTaskID: UUID().uuidString.lowercased(), runID: UUID().uuidString,
            caseID: caseID, runToken: token,
            environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        let receipt = try collector.finish()
        XCTAssertEqual(receipt.successfulExchangeCount, 0)
        XCTAssertEqual(receipt.coverageStatus, "incomplete")
        XCTAssertEqual(receipt.sinks["model_prompt"]?.status, "missing")
        XCTAssertEqual(receipt.sinks["model_action"]?.status, "missing")

        let physicalChild = root.appendingPathComponent("physical-child", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalChild, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliasedRunRoot = alias.appendingPathComponent("physical-child", isDirectory: true)
        XCTAssertThrowsError(try AgentEvalFaraExchangeEvidence(runDirectory: aliasedRunRoot,
            driverTaskID: UUID().uuidString.lowercased(), runID: UUID().uuidString,
            caseID: caseID, runToken: token,
            environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: physicalChild.appendingPathComponent("evidence").path),
            "A symlinked ancestor must be rejected before collector files are created.")
    }

    func testOversizeDuplicateAndClosedWritesStayIncomplete() throws {
        let (root, collector) = try makeCollector()
        defer { try? FileManager.default.removeItem(at: root) }
        collector.record(Data(repeating: 0x41, count: AgentEvalFaraExchangeEvidence.maximumBodyBytes + 1),
            Data("response".utf8))
        let laterRequest = Data("later synthetic request".utf8)
        let laterResponse = Data("later synthetic response".utf8)
        collector.record(laterRequest, laterResponse)
        let receipt = try collector.finish()
        XCTAssertEqual(receipt.successfulExchangeCount, 1)
        XCTAssertEqual(receipt.captureFailureCount, 1)
        XCTAssertEqual(receipt.sinks["model_prompt"]?.status, "capture_failed")
        XCTAssertEqual(receipt.sinks["model_action"]?.status, "capture_failed")
        try assertArtifact(receipt.sinks["model_prompt"]?.artifacts.first,
            bytes: laterRequest, root: root, suffix: "/001.request.body")
        try assertArtifact(receipt.sinks["model_action"]?.artifacts.first,
            bytes: laterResponse, root: root, suffix: "/001.response.body")
        XCTAssertThrowsError(try collector.finish())
        collector.record(Data("late".utf8), Data("late".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("evidence/fara-exchange/002.request.body").path))
    }

    func testExchangeLimitPreservesAllFortyCapturedPairsAndAddsOneOverflowFailure() throws {
        let (root, collector) = try makeCollector()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<AgentEvalFaraExchangeEvidence.maximumExchanges {
            collector.record(Data("request-\(index)".utf8), Data("response-\(index)".utf8))
        }
        collector.record(Data("overflow request".utf8), Data("overflow response".utf8))

        let receipt = try collector.finish()
        XCTAssertEqual(receipt.successfulExchangeCount, 40)
        XCTAssertEqual(receipt.captureFailureCount, 1)
        XCTAssertEqual(receipt.sinks["model_prompt"]?.status, "capture_failed")
        XCTAssertEqual(receipt.sinks["model_action"]?.status, "capture_failed")
        XCTAssertEqual(receipt.sinks["model_prompt"]?.artifacts.count, 40)
        XCTAssertEqual(receipt.sinks["model_action"]?.artifacts.count, 40)
        try assertArtifact(receipt.sinks["model_prompt"]?.artifacts.last,
            bytes: Data("request-39".utf8), root: root, suffix: "/039.request.body")
        try assertArtifact(receipt.sinks["model_action"]?.artifacts.last,
            bytes: Data("response-39".utf8), root: root, suffix: "/039.response.body")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("evidence/fara-exchange/040.request.body").path))
    }

    func testRuntimeObserverReceivesTheActualPostTrimCompletionBody() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let retainedRunRoot = ProcessInfo.processInfo.environment["EVAL_FARA_EVIDENCE_RUNTIME_TEST_RUN_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let (runRoot, collector) = try makeCollector(runDirectory: retainedRunRoot)
        defer {
            if retainedRunRoot == nil { try? FileManager.default.removeItem(at: runRoot) }
        }
        let helperRunRoot = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: helperRunRoot) }
        let helperRunID = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"))
        let helperCapture = AgentEvalFaraExchangeCapture(configuration: .init(
            caseID: caseID, runToken: token, driverTaskID: UUID().uuidString.lowercased(),
            runRoot: helperRunRoot.path), environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        XCTAssertFalse(try helperCapture.beginRequest(runID: nil),
            "The readiness warmup is excluded without assigning it a fake run ID.")
        XCTAssertTrue(try helperCapture.beginRequest(runID: helperRunID))
        XCTAssertThrowsError(try helperCapture.beginRequest(runID: UUID()),
            "A different run cannot replace the first bound run.")
        XCTAssertThrowsError(try helperCapture.beginRequest(runID: nil),
            "A capture-bound task request cannot omit its run ID.")
        XCTAssertEqual(helperRunID.uuidString, helperRunID.uuidString.uppercased(),
            "The run store uses UUID.uuidString spelling; preserve that exact lexical ID.")
        let model = directory.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName)
        let projector = directory.appendingPathComponent(ComputerUseFaraRuntimeInputs.projectorFileName)
        try Data([1]).write(to: model)
        try Data([2]).write(to: projector)
        let launcher = EvidenceFakeLauncher()
        let transport = EvidenceFakeTransport(tokenCounts: [20_000, 10])
        let callback = EvidenceExchangeBox()
        let runtime = OSAtlasLlamaRuntime(launcher: launcher,
            transportMaker: EvidenceFakeTransportMaker(transport: transport),
            portProvider: EvidenceFixedPort(port: 43129),
            tokenProvider: EvidenceFixedToken(), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: EvidenceSufficientMemory(),
            inspectFaraExchange: { request, response in
                callback.append(request, response)
                collector.record(request, response)
                helperCapture.record(request, response)
            })
        let visionInputs = AgentVisionRuntimeInputs(model: .fara15_4b,
            modelURL: model, projectorURL: projector,
            llamaServerURL: directory.appendingPathComponent("llama-server"))
        let endpoint = try await runtime.activateAgentVision(visionInputs)
        do {
            let image = try testPNG()
            let input = AgentVLMRequestInput(messages: [
                .init(role: .system, content: [.text("fixed system prompt")]),
                .init(role: .user, content: [.text("older observation"), .imagePNG(image)]),
                .init(role: .assistant, content: [.text("older proposal")]),
                .init(role: .user, content: [.text("current observation"), .imagePNG(image)]),
            ])
            _ = try await runtime.completeAgentAction(endpoint: endpoint, input: input)
            let sent = try XCTUnwrap(transport.completionRequests().last?.httpBody)
            let tokenized = transport.tokenizationRequests().compactMap(\.httpBody)
            let initialRequest = try XCTUnwrap(tokenized.first)
            let captured = try XCTUnwrap(callback.values().first)
            XCTAssertEqual(captured.0, sent)
            XCTAssertEqual(tokenized.count, 2)
            XCTAssertNotEqual(initialRequest, sent, "The runtime must trim its local request before completion.")
            let initialText = String(decoding: initialRequest, as: UTF8.self)
            XCTAssertEqual(initialText.components(separatedBy: "data:image/png;base64,").count - 1, 2)
            let sentText = String(decoding: sent, as: UTF8.self)
            XCTAssertTrue(sentText.contains("current observation"))
            XCTAssertTrue(sentText.contains("older observation"), "The first trim removes the old image, not old text.")
            XCTAssertEqual(sentText.components(separatedBy: "data:image/png;base64,").count - 1, 1,
                "The completed request should contain one remaining screenshot.")
            XCTAssertEqual(captured.1, transport.responseBody)
            XCTAssertEqual(transport.tokenCountCallCount, 2)
            XCTAssertEqual(transport.completionRequests().count, 1)
        } catch {
            helperCapture.endRequest()
            await runtime.shutdown()
            try? collector.finish()
            throw error
        }
        helperCapture.endRequest()
        await runtime.shutdown()
        let receipt = try collector.finish()
        XCTAssertEqual(receipt.successfulExchangeCount, 1)
        try assertArtifact(receipt.sinks["model_prompt"]?.artifacts.first,
            bytes: try XCTUnwrap(transport.completionRequests().last?.httpBody),
            root: runRoot, suffix: "/000.request.body")
        try assertArtifact(receipt.sinks["model_action"]?.artifacts.first,
            bytes: transport.responseBody, root: runRoot, suffix: "/000.response.body")
        let helperReceipt = try XCTUnwrap(helperCapture.finish())
        XCTAssertEqual(helperReceipt.identity.caseID, caseID)
        XCTAssertEqual(helperReceipt.identity.runToken, token)
        XCTAssertEqual(helperReceipt.identity.runID, helperRunID.uuidString)
        XCTAssertEqual(helperReceipt.successfulExchangeCount, 1)
        XCTAssertEqual(helperReceipt.coverageStatus, "incomplete")
        let helperDirectory = helperRunRoot.appendingPathComponent(helperRunID.uuidString,
            isDirectory: true)
        try assertArtifact(helperReceipt.sinks["model_prompt"]?.artifacts.first,
            bytes: try XCTUnwrap(transport.completionRequests().last?.httpBody),
            root: helperDirectory, suffix: "/000.request.body")
        try assertArtifact(helperReceipt.sinks["model_action"]?.artifacts.first,
            bytes: transport.responseBody, root: helperDirectory, suffix: "/000.response.body")
        if let retainedRunRoot {
            try writeIdentityManifest(collector, runRoot: retainedRunRoot,
                filename: "runtime-expected-identity.json")
        }
    }

    func testCancelledRuntimeDoesNotCaptureLateHTTPResponse() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"))
        let capture = AgentEvalFaraExchangeCapture(configuration: .init(caseID: caseID,
            runToken: token, driverTaskID: UUID().uuidString.lowercased(), runRoot: root.path),
            environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        XCTAssertTrue(try capture.beginRequest(runID: runID))
        let model = directory.appendingPathComponent(ComputerUseFaraRuntimeInputs.modelFileName)
        let projector = directory.appendingPathComponent(ComputerUseFaraRuntimeInputs.projectorFileName)
        try Data([1]).write(to: model)
        try Data([2]).write(to: projector)
        let transport = EvidenceHeldTransport(responseBody: EvidenceFakeTransport(tokenCounts: [10]).responseBody)
        let runtime = OSAtlasLlamaRuntime(launcher: EvidenceFakeLauncher(),
            transportMaker: EvidenceHeldTransportMaker(transport: transport),
            portProvider: EvidenceFixedPort(port: 43130), tokenProvider: EvidenceFixedToken(),
            readinessAttempts: 1, readinessDelay: .zero, resourceInspector: EvidenceSufficientMemory(),
            inspectFaraExchange: capture.record)
        let endpoint = try await runtime.activateAgentVision(.init(model: .fara15_4b,
            modelURL: model, projectorURL: projector,
            llamaServerURL: directory.appendingPathComponent("llama-server")))
        let input = AgentVLMRequestInput(messages: [
            .init(role: .system, content: [.text("fixed system prompt")]),
            .init(role: .user, content: [.text("synthetic cancellation request"),
                .imagePNG(try testPNG())]),
        ])
        let completion = Task { try await runtime.completeAgentAction(endpoint: endpoint, input: input) }
        guard await transport.waitUntilStarted() else {
            await runtime.cancel(endpoint: endpoint)
            await runtime.shutdown()
            let failureName: String
            switch await completion.result {
            case .success:
                failureName = "success"
            case .failure(let error):
                if let runtimeError = error as? OSAtlasLlamaRuntimeError {
                    failureName = String(describing: runtimeError)
                } else {
                    failureName = String(reflecting: type(of: error))
                }
            }
            XCTFail("Synthetic HTTP did not start; completion outcome type: \(failureName).")
            return
        }
        let cancellation = Task { await runtime.cancel(endpoint: endpoint) }
        guard await transport.waitUntilCancelled() else {
            transport.releaseResponse()
            await cancellation.value
            _ = await completion.result
            await runtime.shutdown()
            XCTFail("The runtime did not cancel the held HTTP request before its response.")
            return
        }
        transport.releaseResponse()
        await cancellation.value
        do {
            _ = try await completion.value
            XCTFail("Cancelled completion must not return a model result.")
        } catch { }
        await runtime.shutdown()
        capture.endRequest()
        let receipt = try XCTUnwrap(capture.finish())
        XCTAssertEqual(receipt.identity.runID, runID.uuidString)
        XCTAssertEqual(receipt.successfulExchangeCount, 0)
        XCTAssertTrue(receipt.sinks["model_prompt"]?.artifacts.isEmpty == true)
        XCTAssertTrue(receipt.sinks["model_action"]?.artifacts.isEmpty == true)
    }

    private func makeCollector(runDirectory: URL? = nil) throws -> (URL, AgentEvalFaraExchangeEvidence) {
        let root: URL
        if let runDirectory {
            root = runDirectory
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } else {
            root = try makePrivateDirectory()
        }
        let collector = try AgentEvalFaraExchangeEvidence(runDirectory: root,
            driverTaskID: UUID().uuidString.lowercased(), runID: UUID().uuidString,
            caseID: caseID, runToken: token,
            environment: ["EVAL_TASK_ID": caseID, "EVAL_RUN_TOKEN": token])
        return (root, collector)
    }

    private func writeIdentityManifest(_ collector: AgentEvalFaraExchangeEvidence, runRoot: URL,
                                       filename: String) throws {
        let identityData = try JSONEncoder().encode(collector.identity)
        let identityURL = runRoot.deletingLastPathComponent()
            .appendingPathComponent(filename)
        try identityData.write(to: identityURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: identityURL.path)
    }

    private func makePrivateDirectory() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        var physicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = temporaryPath.withCString { realpath($0, &physicalBuffer) }
        guard resolved != nil else { throw CocoaError(.fileNoSuchFile) }
        let physicalRoot = String(cString: physicalBuffer)
        let root = URL(fileURLWithPath: physicalRoot, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(root.path.hasPrefix(physicalRoot + "/"),
            "The fixture must retain its realpath-resolved parent so the no-follow check is meaningful.")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    private func assertArtifact(_ artifact: AgentEvalFaraExchangeReceipt.Artifact?, bytes: Data,
                                root: URL, suffix: String) throws {
        let artifact = try XCTUnwrap(artifact)
        XCTAssertTrue(artifact.path.hasSuffix(suffix))
        XCTAssertFalse(artifact.path.hasPrefix("/"))
        XCTAssertEqual(artifact.byteCount, bytes.count)
        let artifactURL = root.appendingPathComponent(artifact.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: artifactURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777, 0o600)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(artifact.sha256, hash)
        XCTAssertEqual(try Data(contentsOf: artifactURL), bytes)
    }

    private func testPNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class EvidenceExchangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [(Data, Data)] = []
    func append(_ request: Data, _ response: Data) { lock.withLock { exchanges.append((request, response)) } }
    func values() -> [(Data, Data)] { lock.withLock { exchanges } }
}

private struct EvidenceFixedPort: OSAtlasLlamaPortProviding {
    let port: UInt16
    func availableLoopbackPort() throws -> UInt16 { port }
}

private struct EvidenceFixedToken: OSAtlasLlamaTokenProviding {
    func bearerToken() -> String { "private-evidence-runtime-token" }
}

private struct EvidenceSufficientMemory: OSAtlasLlamaResourceInspecting {
    func snapshot() throws -> OSAtlasLlamaResourceSnapshot {
        .init(physicalMemoryBytes: .max, reclaimableMemoryBytes: .max)
    }
}

private final class EvidenceFakeProcess: OSAtlasLlamaServerProcess, @unchecked Sendable {
    func terminate() async {}
    func waitUntilExit() async throws {}
}

private struct EvidenceFakeLauncher: OSAtlasLlamaServerLaunching {
    func launch(configuration: OSAtlasLlamaLaunchConfiguration) async throws -> any OSAtlasLlamaServerProcess {
        EvidenceFakeProcess()
    }
}

private struct EvidenceFakeTransportMaker: OSAtlasLlamaHTTPTransportMaking {
    let transport: EvidenceFakeTransport
    func makeTransport() -> any OSAtlasLlamaHTTPTransport { transport }
}

private struct EvidenceHeldTransportMaker: OSAtlasLlamaHTTPTransportMaking {
    let transport: EvidenceHeldTransport
    func makeTransport() -> any OSAtlasLlamaHTTPTransport { transport }
}

private final class EvidenceHeldTransport: OSAtlasLlamaHTTPTransport, @unchecked Sendable {
    let responseBody: Data
    private let lock = NSLock()
    private var completion: CheckedContinuation<Data, Error>?
    private var started = false
    private var cancelled = false

    init(responseBody: Data) { self.responseBody = responseBody }
    func health(baseURL: URL, bearerToken: String) async throws -> Bool { true }
    func modelIsHealthy(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws -> Bool { true }
    func loadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func unloadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { 10 }

    func complete(request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                completion = continuation
                started = true
            }
        }
    }

    func cancelAll() async {
        lock.withLock { cancelled = true }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ started }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitUntilCancelled() async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ cancelled }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func releaseResponse() {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { completion = nil }
            return completion
        }
        continuation?.resume(returning: responseBody)
    }
}

private final class EvidenceFakeTransport: OSAtlasLlamaHTTPTransport, @unchecked Sendable {
    let responseBody: Data
    private let lock = NSLock()
    private var tokenCounts: [Int]
    private var tokenCalls = 0
    private var tokenRequests: [URLRequest] = []
    private var requests: [URLRequest] = []

    init(tokenCounts: [Int]) {
        self.tokenCounts = tokenCounts
        responseBody = (try? JSONSerialization.data(withJSONObject: [
            "model": ComputerUseFaraRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"]]],
        ])) ?? Data()
    }

    var tokenCountCallCount: Int { lock.withLock { tokenCalls } }
    func tokenizationRequests() -> [URLRequest] { lock.withLock { tokenRequests } }
    func completionRequests() -> [URLRequest] { lock.withLock { requests } }
    func health(baseURL: URL, bearerToken: String) async throws -> Bool { true }
    func modelIsHealthy(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws -> Bool { true }
    func loadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func unloadModel(baseURL: URL, bearerToken: String, model: OSAtlasLlamaServedModel) async throws {}
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        lock.withLock {
            tokenCalls += 1
            tokenRequests.append(completionRequest)
            return tokenCounts.isEmpty ? 10 : tokenCounts.removeFirst()
        }
    }
    func complete(request: URLRequest) async throws -> Data {
        lock.withLock { requests.append(request) }
        return responseBody
    }
    func cancelAll() async {}
}
