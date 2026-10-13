import Foundation
import AppKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseHoloModelTests: XCTestCase {
    func testRequestRetainsNativeHistoryAndPairsErrorsAndUserReplies() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = URL(string: "https://example.com/public")!
        let answer = "  Kyoto e\u{301} 😀\n  "
        var history: [ComputerUseFaraModel.Step] = []
        for i in 0..<4 {
            let name = i == 1 ? "ask_user" : "wait"
            let args = i == 1 ? #"{"question":"Which city?"}"# : #"{"time":0}"#
            let proposal = try ComputerUseHoloModel.decode(packet(name, arguments: args, content: "Note \(i)", id: "call-\(i)"))
            history.append(.init(screenshotPNG: png, response: proposal.response, currentURL: source,
                userResponse: i == 2 ? answer : nil, actionError: i == 1 ? "The previous action was not sent." : nil))
        }
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let input = ComputerUseFaraModel.Input(goal: "Find tickets; stop before selecting tickets.", screenshotPNG: png, history: history, currentURL: source)
        let request = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 14); XCTAssertEqual(messages.first?["content"] as? String, input.goal)
        let assistants = messages.filter { $0["role"] as? String == "assistant" }
        XCTAssertEqual(assistants.compactMap { $0["content"] as? String }, ["Note 0", "Note 1", "Note 2", "Note 3"])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("Private reasoning"))
        let results = messages.filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(results.compactMap { $0["tool_call_id"] as? String }, ["call-0", "call-1", "call-2", "call-3"])
        func result(_ index: Int) throws -> [String: String] {
            try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(results[index]["content"] as? String).utf8))
        }
        XCTAssertEqual(try result(0)["error"], "The previous action was not sent.")
        XCTAssertEqual(try result(1)["user_response"]?.utf8.map { $0 }, Array(answer.utf8))
        XCTAssertNil(try result(2)["error"]); XCTAssertNil(try result(2)["user_response"])
        let observations = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? [[String: Any]] }
        XCTAssertEqual(observations.flatMap { $0 }.filter { $0["type"] as? String == "image_url" }.count, 3)
        XCTAssertTrue(observations.allSatisfy { ($0.first?["text"] as? String)?.hasPrefix("<observation>") == true && ($0.last?["text"] as? String)?.hasSuffix("</observation>") == true })
        XCTAssertEqual(body["tool_choice"] as? String, "required"); XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        var invalid = input; invalid.history[0] = invalid.history[1]
        XCTAssertThrowsError(try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: invalid), "Repeated call IDs cannot create ambiguous result bindings")
        invalid = input; invalid.history[0] = .init(screenshotPNG: png, response: #"<tool_call>{"name":"computer_use","arguments":{"action":"wait","time":0}}</tool_call>"#)
        XCTAssertThrowsError(try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: invalid), "Do not silently translate Fara history")
        invalid = input; invalid.actionError = String(repeating: "x", count: 16_385)
        XCTAssertThrowsError(try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: invalid))
    }

    func testNoToolStopIsObservationOnlyAndNeverUsesProseAsAnAction() throws {
        let data = try JSONSerialization.data(withJSONObject: ["model": ComputerUseHoloModel.modelAlias, "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "answer: done; click(100, 100)", "reasoning_content": "private"]]]])
        let proposal = try ComputerUseHoloModel.decode(data)
        XCTAssertEqual(proposal.action, .wait(0))
        XCTAssertFalse(proposal.response.contains("tool_calls")); XCTAssertFalse(proposal.response.contains("private"))
        XCTAssertTrue(proposal.response.contains("answer: done; click(100, 100)"))
    }

    func packet(_ name: String, arguments: String, content: String = "Keep this public note.", id: String = "call-1") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": ComputerUseHoloModel.modelAlias, "choices": [[
            "finish_reason": "tool_calls", "message": ["role": "assistant", "content": content,
                "reasoning_content": "Private reasoning must not be replayed.",
                "tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]]]]]])
    }

    func testNativeToolCallsPreserveExactTextAndSeparateCompletionFromProse() throws {
        let text = "  東京 👨‍👩‍👧‍👦 e\u{301}\n</tool_call>\t"
        let args = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: ["text": text]), encoding: .utf8))
        let proposal = try ComputerUseHoloModel.decode(packet("type", arguments: args, content: "The task is complete."))
        XCTAssertEqual(proposal.action, .typeText(text))
        if case .typeText(let value) = proposal.action { XCTAssertEqual(Array(value.utf8), Array(text.utf8)) }
        XCTAssertTrue(proposal.response.contains("The task is complete."))
        XCTAssertFalse(proposal.response.contains("Private reasoning"))
        XCTAssertEqual(try ComputerUseHoloModel.decode(packet("answer", arguments: #"{"content":"Observed result"}"#, content: "Wrong result")).action, .reportCompletion("Observed result"))
        XCTAssertEqual(try ComputerUseHoloModel.decode(packet("click", arguments: #"{"element":"Destination","x":0,"y":1000}"#)).action, .pointer(.leftClick, .init(x: 0, y: 1000)))
        XCTAssertEqual(try ComputerUseHoloModel.decode(packet("key", arguments: #"{"keys":["Control","f"]}"#)).action, .key(["Control", "f"]))
        XCTAssertEqual(try ComputerUseHoloModel.decode(packet("scroll", arguments: #"{"direction":"down","distance":500.5}"#)).action, .scroll(horizontal: false, pixels: -500.5))
        XCTAssertEqual(try ComputerUseHoloModel.decode(packet("wait", arguments: #"{"time":0.2}"#)).action, .wait(0.2))
        XCTAssertEqual(try ComputerUseHoloModel.decode(packet("web_search", arguments: #"{"query":"Roxie showtimes"}"#)).action, .webSearch("Roxie showtimes"))
    }

    func testScrollDeclaresDirectionAndMapsUnsignedDistanceWithoutGuessing() throws {
        for (direction, horizontal, sign) in [("down", false, -1.0), ("up", false, 1.0), ("left", true, -1.0), ("right", true, 1.0)] {
            for distance in [0.0, 400.5, 10_000.0] {
                let args = "{\"direction\":\"\(direction)\",\"distance\":\(distance)}"
                let proposal = try ComputerUseHoloModel.decode(packet("scroll", arguments: args))
                XCTAssertEqual(proposal.action, .scroll(horizontal: horizontal, pixels: sign * distance))
                XCTAssertTrue(proposal.response.contains(direction))
            }
        }
        for args in [#"{"pixels":400}"#, #"{"direction":"down","distance":-400}"#,
                     #"{"direction":"down","distance":10001}"#, #"{"direction":"down","distance":true}"#,
                     #"{"direction":"down","distance":"400"}"#, #"{"direction":"Down","distance":400}"#,
                     #"{"direction":"down","distance":400,"pixels":-400}"#,
                     #"{"direction":"down","direction":"up","distance":400}"#] {
            XCTAssertThrowsError(try ComputerUseHoloModel.decode(packet("scroll", arguments: args)), args)
        }
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let request = try ComputerUseHoloModel.makeRequest(endpoint: endpoint,
            input: .init(goal: "Read the page.", screenshotPNG: png, history: []))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let functions = try XCTUnwrap(body["tools"] as? [[String: Any]]).compactMap { $0["function"] as? [String: Any] }
        let scroll = try XCTUnwrap(functions.first { $0["name"] as? String == "scroll" })
        let parameters = try XCTUnwrap(scroll["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["direction", "distance"])
    }

    func testMalformedOrAmbiguousCallsNeverBecomeActions() throws {
        let invalid: [(String, String)] = [
            ("type", #"{"text":"first","text":"second"}"#), ("type", #"{"text":"x","enter":true}"#),
            ("type", #"{"text":1}"#), ("answer", #"{"content":" "}"#), ("answer", #"{"content":"yes"} trailing"#),
            ("click", #"{"element":"field","x":12.5,"y":0}"#), ("click", #"{"element":"field","x":-1,"y":0}"#),
            ("click", #"{"element":"field","x":0,"y":1001}"#), ("click", #"{"x":0,"y":0}"#),
            ("click", #"{"element":"field","x":true,"y":0}"#), ("key", #"{"keys":["a","a"]}"#),
            ("key", #"{"keys":[]}"#), ("wait", #"{"time":31}"#), ("scroll", #"{"pixels":10001}"#),
            ("web_search", #"{"query":""}"#), ("execute_python", #"{"code":"print(1)"}"#)]
        for (name, args) in invalid { XCTAssertThrowsError(try ComputerUseHoloModel.decode(packet(name, arguments: args)), "\(name): \(args)") }
        let valid = try packet("answer", arguments: #"{"content":"Done"}"#)
        for mode in ["length", "model", "role", "missing-call", "multiple-calls", "multiple-choices", "arguments-object", "empty-id", "refusal"] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            var choices = try XCTUnwrap(root["choices"] as? [[String: Any]])
            var message = try XCTUnwrap(choices[0]["message"] as? [String: Any])
            var calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
            switch mode {
            case "length": choices[0]["finish_reason"] = "length"
            case "model": root["model"] = "fara-browser-v1"
            case "role": message["role"] = "user"
            case "missing-call": calls = []
            case "multiple-calls": calls.append(calls[0])
            case "arguments-object": var function = calls[0]["function"] as! [String: Any]; function["arguments"] = ["content":"Done"]; calls[0]["function"] = function
            case "empty-id": calls[0]["id"] = ""
            case "refusal": message["refusal"] = "Cannot comply"
            default: break
            }
            message["tool_calls"] = calls; choices[0]["message"] = message
            if mode == "multiple-choices" { choices.append(choices[0]) }
            root["choices"] = choices
            XCTAssertThrowsError(try ComputerUseHoloModel.decode(JSONSerialization.data(withJSONObject: root)), mode)
        }
        XCTAssertThrowsError(try ComputerUseHoloModel.decode(Data(#"{"model":"holo-browser-v1","model":"holo-browser-v1","choices":[]}"#.utf8)))
        XCTAssertThrowsError(try ComputerUseHoloModel.decode(Data(valid.dropLast())))
        XCTAssertThrowsError(try ComputerUseHoloModel.decode(Data(repeating: 32, count: 1_048_577)))
    }
}

@MainActor
enum HoloTestProposalRunner {
    static func propose(input: ComputerUseFaraModel.Input, directory: URL, index: Int,
                        environment: [String: String], memoryLimitGiB: Int = 5,
                        registerProbe: (HoloProbeProcess) -> Void = { _ in }) async throws -> ComputerUseFaraModel.Proposal {
        guard [4, 5].contains(memoryLimitGiB) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unused-diagnostic-request")
        let request = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
        let requestFile = directory.appendingPathComponent("request-\(index).json")
        guard !FileManager.default.fileExists(atPath: requestFile.path) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        try XCTUnwrap(request.httpBody).write(to: requestFile)
        let output = directory.appendingPathComponent("proposal-\(index)")
        let probe = HoloProbeProcess()
        registerProbe(probe)
        try probe.start(python: try XCTUnwrap(environment["HOLO_PYTHON"]), script: try XCTUnwrap(environment["HOLO_PROBE_SCRIPT"]),
            arguments: [requestFile.path, output.path, try XCTUnwrap(environment["HOLO_ASSETS"]), try XCTUnwrap(environment["HOLO_BINARY"]), String(memoryLimitGiB)])
        let status = try await probe.finish()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("report.json"))) as? [String: Any])
        XCTAssertEqual(report["ownedProcessExited"] as? Bool, true)
        guard status == 0 else { throw ComputerUseFaraAction.Failure.invalidResponse }
        return try ComputerUseHoloModel.decode(Data(contentsOf: output.appendingPathComponent("response.json")))
    }
}

/// Owns only the opt-in diagnostic Python process; that process joins its
/// single model worker before exiting, including on SIGTERM cancellation.
final class HoloProbeProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancellationSent = false
    func start(python: String, script: String, arguments: [String]) throws {
        try Task.checkCancellation()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    private func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancellationSent, process.isRunning else { return }
        cancellationSent = true; process.terminate()
    }
    /// The executor's finish hook owns this join even if its proposal deadline
    /// has already returned. A cancelled planner can otherwise outlive a task.
    func cancelAndWait() async {
        cancel()
        await Task.detached { if self.process.isRunning { self.process.waitUntilExit() } }.value
    }
    func finish() async throws -> Int32 {
        try await withTaskCancellationHandler {
            do {
                let deadline = ContinuousClock.now + .seconds(45)
                while process.isRunning {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                return process.terminationStatus
            } catch {
                await cancelAndWait()
                throw error
            }
        } onCancel: { self.cancel() }
    }
}
