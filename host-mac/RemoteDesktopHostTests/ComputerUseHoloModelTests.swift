import Foundation
import AppKit
import WebKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseHoloModelTests: XCTestCase {
    @MainActor
    func testOptInNativeHoloWireTypesExactlyPausesAndResumesWithoutReplay() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: scripted Holo native typing and login") }
        try await runLocalWorkflow(actualModel: false)
    }

    @MainActor
    func testOptInActualHoloCompletesLocalTypingAndLoginResume() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HOLO_NATIVE_TRIAL"] == "1" else { throw XCTSkip("Opt-in: bounded Holo local typing/login trial") }
        try await runLocalWorkflow(actualModel: true)
    }

    @MainActor
    func testOptInActualFaraQ6CompletesLocalTypingAndLoginResume() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_Q6_NATIVE_TRIAL"] == "1" else { throw XCTSkip("Opt-in: bounded Fara Q6 native typing/login trial") }
        try await runLocalWorkflow(actualModel: true, faraQ6: true)
    }

    @MainActor
    private func runLocalWorkflow(actualModel: Bool, faraQ6: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelName = faraQ6 ? "Fara Q6" : "Holo"
        let previous = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previous) }
        let directory = actualModel ? URL(fileURLWithPath: try XCTUnwrap(environment[faraQ6 ? "FARA_Q6_TRIAL_DIRECTORY" : "HOLO_TRIAL_DIRECTORY"]))
            : FileManager.default.temporaryDirectory.appendingPathComponent("HoloLocal-" + UUID().uuidString)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if !actualModel { try? FileManager.default.removeItem(at: directory) } }
        let server = try OwnedBrowserHTTPFixture(routes: ["/form": .init(body: """
            <!doctype html><meta charset=utf-8><title>Local travel form</title>
            <style>body{font:22px system-ui;background:white}label{position:fixed;left:20vw}input,textarea{position:fixed;left:20vw;width:60vw;font:22px system-ui;box-sizing:border-box}#origin{top:10vh;height:8vh}#destination{top:35vh;height:15vh}</style>
            <label for=origin style='top:5vh'>Origin</label><input id=origin value=Seattle>
            <label for=destination style='top:30vh'>Destination</label><textarea id=destination></textarea>
            <script>
            document.addEventListener('keydown',()=>fetch('/key'));
            document.addEventListener('click',event=>fetch('/clicked?target='+encodeURIComponent(event.target.id)));
            document.addEventListener('input',event=>{
              fetch('/edited?'+new URLSearchParams({target:event.target.id,trusted:String(event.isTrusted),value:event.target.value,origin:document.getElementById('origin').value,inputType:event.inputType,data:event.data}));
              if(!window.loginShown){window.loginShown=true;const p=document.createElement('input');p.id='login';p.type='password';p.value='private-fixture-password';p.style.top='70vh';document.body.append(p);fetch('/login-shown')}
            });</script>
            """)])
        let base = try await server.start(); defer { server.stop() }
        defer {
            let events = XCTAttachment(string: server.requestedPaths.joined(separator: "\n"))
            events.name = modelName + " native fixture events"; events.lifetime = .keepAlways; add(events)
            if let files = try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("actor"), includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file) {
                        let journal = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                        journal.name = modelName + " native action journal"; journal.lifetime = .keepAlways; add(journal)
                    }
                }
            }
        }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        try browser.claim(taskID: "holo-local")
        _ = try await browser.navigate(taskID: "holo-local", operationID: "fixture", to: base.appendingPathComponent("form"))
        let window = try XCTUnwrap(NSApp.keyWindow)
        func views(_ view: NSView) -> [WKWebView] { if let web = view as? WKWebView { return [web] }; return view.subviews.flatMap(views) }
        let web = try XCTUnwrap(views(try XCTUnwrap(window.contentView)).first)
        let exact = actualModel ? "Tokyo" : "  東京 e\u{301} 😀\n  "
        let goal = "In the Destination field, type \(exact). Leave Origin as Seattle."
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("actor"), propose: { input in
            guard calls < 8 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            defer { calls += 1 }
            XCTAssertEqual(input.goal, goal)
            if faraQ6 {
                return try await FaraQ6TestProposalRunner.propose(input: input, directory: directory, index: calls, environment: environment)
            }
            let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unused-diagnostic-request")
            _ = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
            let response: Data
            if actualModel {
                return try await HoloTestProposalRunner.propose(input: input, directory: directory, index: calls, environment: environment)
            } else if calls == 0 {
                response = try JSONSerialization.data(withJSONObject: ["model": ComputerUseHoloModel.modelAlias, "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "I will inspect the form."]]]])
            } else {
                let name = calls == 1 ? "click" : calls == 2 ? "type" : "answer"
                let arguments: [String: Any] = calls == 1 ? ["element":"Destination", "x":500, "y":425]
                    : calls == 2 ? ["text":exact] : ["content":"Destination filled; Origin remains Seattle."]
                response = try self.packet(name, arguments: String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self), id: "local-\(calls)")
            }
            return try ComputerUseHoloModel.decode(response)
        })
        func run() async throws -> ComputerUseExecutionResult {
            try await executor.execute(taskID: "holo-local", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        }
        let paused = try await run()
        guard case .userInterventionRequired = paused else { return XCTFail("Typing must pause before observing simulated login") }
        let pausedCalls = calls
        let early = try await run()
        XCTAssertEqual(early, paused); XCTAssertEqual(calls, pausedCalls)
        _ = try await web.evaluateJavaScript("document.getElementById('login').remove()")
        let completed = try await run()
        guard case .completed(let answer) = completed else { return XCTFail("\(modelName) did not complete after explicit Resume: \(completed)") }
        XCTAssertFalse(answer.isEmpty)
        let completedCalls = calls
        let replay = try await run()
        XCTAssertEqual(replay, completed); XCTAssertEqual(calls, completedCalls)
        let nativeState = try await web.evaluateJavaScript("({destination:document.getElementById('destination').value,origin:document.getElementById('origin').value})")
        let state = try XCTUnwrap(nativeState as? [String: String])
        XCTAssertEqual(state["destination"]?.utf8.map { $0 }, Array(exact.utf8)); XCTAssertEqual(state["origin"], "Seattle")
        let edits = server.requestedPaths.filter { $0.hasPrefix("/edited?") }
        XCTAssertFalse(edits.isEmpty)
        // WebKit emits insertText/insertParagraph/insertText for one native
        // multiline insertion. Check every observed value, not event count.
        for path in edits {
            let values = try XCTUnwrap(URLComponents(string: path.replacingOccurrences(of: "+", with: "%20"))?.queryItems)
            let event = Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(event["target"], "destination"); XCTAssertEqual(event["trusted"], "true")
            XCTAssertEqual(event["value"]?.utf8.map { $0 }, Array(exact.utf8)); XCTAssertEqual(event["origin"], "Seattle")
        }
        let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("actor"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        let dispatches = journals.filter { $0.stepIDs == ["native-dispatch-returned"] }
        if !actualModel { XCTAssertEqual(dispatches.count, 2, "One native click and one native text insertion") }
        XCTAssertTrue(journals.allSatisfy { $0.statuses == [.verified] })
        XCTAssertEqual(server.count("/key"), 0); XCTAssertEqual(server.count("/login-shown"), 1)
        XCTAssertTrue(NSApp.keyWindow === window)
        let report: [String: Any] = ["model":modelName, "actualModel":actualModel, "proposals":calls, "pausedProposals":pausedCalls, "answer":answer,
            "destination":state["destination"] ?? "", "origin":state["origin"] ?? "", "editEvents":edits.count,
            "sameWindow":NSApp.keyWindow === window, "wholeApp12GBQualified":false, "providerLoginQualified":false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("workflow.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = modelName + " native typing and login Resume"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testOptInNativeQuestionAndExactReplySurviveHistoryEviction() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: Holo question history through the native executor") }
        let previous = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previous) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HoloQuestion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        let goal = "Find tickets after asking for the destination.", reply = "  Kyoto e\u{301} 😀\n  "
        let session = try browser.prepareWorkflowSession(taskID: "history")
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: "history", prompt: goal, referenceDate: Date(), timeZoneIdentifier: "UTC"), allowedOrigins: [])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        var calls = 0
        let executor = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("actor"), propose: { input in
            guard calls <= 25 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            if calls == 21 {
                let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                let request = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let result = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "call-1" })
                let values = try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(result["content"] as? String).utf8))
                XCTAssertNil(values["error"], "Evicting the blocked URL proposal must not attach its error to the earlier wait")
                XCTAssertTrue(input.history.contains { $0.actionError != nil }, "The rejected action's later observation remains visible")
            }
            if calls == 25 {
                XCTAssertEqual(input.history.count, 20)
                let question = try XCTUnwrap(input.history.first { $0.response.contains("Which city?") }, "Holo's native question must survive ordinary history eviction")
                XCTAssertTrue(question.response.contains("call-0"))
                let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                let request = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let result = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "call-0" })
                let values = try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(result["content"] as? String).utf8))
                XCTAssertEqual(values["user_response"]?.utf8.map { $0 }, Array(reply.utf8))
            }
            let name = calls == 0 || calls == 25 ? "ask_user" : calls == 2 ? "visit_url" : "wait"
            let args = calls == 0 ? #"{"question":"Which city?"}"# : calls == 25 ? #"{"question":"Any other constraints?"}"# : calls == 2 ? #"{"url":"https://blocked.invalid/"}"# : #"{"time":0}"#
            defer { calls += 1 }
            return try ComputerUseHoloModel.decode(self.packet(name, arguments: args, id: "call-\(calls)"))
        })
        let first = try await executor.execute(taskID: "history", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(first, .clarificationRequired("Which city?"))
        let pending = try XCTUnwrap(executor.clarification(taskID: "history"))
        let clarified = try pending.goal.answering(pending.question, with: reply)
        let result = try await executor.continueClarification(taskID: "answer", originatingTaskID: "history", goal: clarified, progress: { _ in })
        XCTAssertEqual(result, .clarificationRequired("Any other constraints?")); XCTAssertEqual(calls, 26)
        let replay = try await executor.continueClarification(taskID: "answer", originatingTaskID: "history", goal: clarified, progress: { _ in })
        XCTAssertEqual(replay, result); XCTAssertEqual(calls, 26)
    }

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
                        environment: [String: String], memoryLimitGiB: Int = 5) async throws -> ComputerUseFaraModel.Proposal {
        guard [4, 5].contains(memoryLimitGiB) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unused-diagnostic-request")
        let request = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
        let requestFile = directory.appendingPathComponent("request-\(index).json")
        guard !FileManager.default.fileExists(atPath: requestFile.path) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        try XCTUnwrap(request.httpBody).write(to: requestFile)
        let output = directory.appendingPathComponent("proposal-\(index)")
        let probe = HoloProbeProcess()
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
    func finish() async throws -> Int32 {
        try await withTaskCancellationHandler {
            do {
                let deadline = ContinuousClock.now + .seconds(45)
                while process.isRunning {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                return process.terminationStatus
            } catch {
                cancel()
                await Task.detached { self.process.waitUntilExit() }.value
                throw error
            }
        } onCancel: { self.cancel() }
    }
}
