import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentLlamaVLMPolicyTests: XCTestCase {
    func testPolicyIncludesNativePromptAndOneAttachedPNG() async throws {
        let raw = try completion(arguments: #"{"action":"left_click","coordinate":[250,500]}"#,
                                 content: "I will continue with the visible control.")
        let transport = RecordingAgentVLMTransport(response: raw)
        let (policy, observation, png) = try fixture(transport: transport)

        let output = try await policy.propose(observation)

        XCTAssertEqual(policy.promptVersion, "v1-fara-native-content")
        XCTAssertEqual(output.rawOutput, raw)
        XCTAssertEqual(output.action, .click(target: .point(x: 1, y: 2), button: nil, count: nil))
        let input = try XCTUnwrap(transport.inputs.first)
        let nativePrompt = try XCTUnwrap(input.messages.first?.content.textValue)
        XCTAssertTrue(nativePrompt.contains("Qwen3.5-4B"))
        XCTAssertTrue(nativePrompt.contains("A critical point is a situation"))
        XCTAssertTrue(nativePrompt.contains("<tools>"))
        XCTAssertTrue(nativePrompt.contains("<tool_call>"))
        XCTAssertEqual(input.messages.map(\.role), [.system, .user])
        XCTAssertTrue(input.messages[0].content.textValue?.contains("<tools>") == true)
        XCTAssertTrue(input.messages[1].content.textValue?.contains(#""elements":[{"bbox":[1,2,30,12]"#) == true)
        XCTAssertEqual(input.messages[1].content.imageValues, [png])
        XCTAssertFalse(input.messages[1].content.textValue?.contains(png.base64EncodedString()) == true)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testMalformedJSONAndExtraActionFieldsAreRejectedWithoutRetry() async throws {
        let validArguments = #"{"action":"terminate","answer":"ok"}"#
        for raw in ["Here is the action: {\"type\":\"done\",\"answer\":\"ok\"}",
                    try completionWithoutToolCall(content: #"<tool_call>{"name":"computer_use","arguments":{"type":"done","answer":"ok"}}</tool_call>"#),
                    try completion(arguments: #"{"action":"terminate","answer":"ok","tool":"extra"}"#),
                    try completion(arguments: validArguments, extraCalls: true),
                    try completion(arguments: validArguments, toolName: "other")] {
            let transport = RecordingAgentVLMTransport(response: raw)
            let (policy, observation, _) = try fixture(transport: transport)
            let output = try await policy.propose(observation)
            XCTAssertNil(output.action)
            XCTAssertEqual(output.rawOutput, raw)
            XCTAssertNotNil(output.rejectionReason)
            XCTAssertEqual(transport.callCount, 1)
        }
    }

    func testFaraXMLProposalMapsSupportedActionsWithoutInventingInput() throws {
        let cases: [(String, String)] = [
            (#"{"action":"left_click","coordinate":[120,45]}"#, #"{"type":"click","target":{"x":120,"y":45}}"#),
            (#"{"action":"right_click","coordinate":[120,45]}"#, #"{"type":"click","target":{"x":120,"y":45},"button":"right"}"#),
            (#"{"action":"type","text":"sample","coordinate":[700,800]}"#, #"{"type":"type","text":"sample","mode":"append"}"#),
            (#"{"action":"key","keys":["CTRL","L"]}"#, #"{"type":"key","chord":"CTRL+L"}"#),
            (#"{"action":"scroll","pixels":40}"#, #"{"type":"scroll","direction":"up","amount":40}"#),
            (#"{"action":"hscroll","pixels":-40}"#, #"{"type":"scroll","direction":"left","amount":40}"#),
            (#"{"action":"left_click_drag","coordinate":[8,9]}"#, #"{"type":"fail","reason":"This host action contract requires both drag endpoints; Fara supplied only the destination."}"#),
            (#"{"action":"visit_url","url":"https://example.test/"}"#, #"{"type":"open_url","url":"https://example.test/"}"#),
            (#"{"action":"wait","time":1}"#, #"{"type":"wait","seconds":1}"#),
            (#"{"action":"ask_user_question","question":"Choose one"}"#, #"{"type":"ask_user","question":"Choose one"}"#),
            (#"{"action":"web_search","query":"weather"}"#, #"{"type":"fail","reason":"Search is unavailable in the current computer-use action contract."}"#),
            (#"{"action":"read_page_answer_question","question":"What is shown?"}"#, #"{"type":"fail","reason":"Page-reading actions are unavailable in the current computer-use action contract."}"#),
            (#"{"action":"pause_and_memorize_fact","fact":"remember this"}"#, #"{"type":"fail","reason":"Memory actions are unavailable in the current computer-use action contract."}"#),
            (#"{"action":"terminate","answer":"Complete"}"#, #"{"type":"done","answer":"Complete"}"#),
        ]
        for (native, expected) in cases {
            let raw = try completion(arguments: native)
            let decoded = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: raw, imageSize: (1_000, 1_000))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
            XCTAssertNoThrow(try JSONDecoder().decode(AgentAction.self, from: Data(decoded.utf8)))
        }
    }

    func testUiTarsNativeTextAndResizedCoordinatesAreStrictlyAdapted() throws {
        XCTAssertEqual(try UIActionTextParser.resizedSize(for: (1280, 800)).width, 1288)
        XCTAssertEqual(try UIActionTextParser.resizedSize(for: (1280, 800)).height, 812)
        let large = try UIActionTextParser.resizedSize(for: (2048, 1323))
        XCTAssertEqual(large.width % 28, 0)
        XCTAssertEqual(large.height % 28, 0)
        XCTAssertGreaterThanOrEqual(large.width * large.height, 8 * 28 * 28)
        XCTAssertLessThanOrEqual(large.width * large.height, 1_536 * 28 * 28)
        XCTAssertThrowsError(try UIActionTextParser.resizedSize(for: (10_000, 10)))
        let center = try uiTarsCompletion("Thought: click the visible control.\nAction: click(start_box='(644,406)')")
        let mapped = try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: center, imageSize: (1280, 800))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(mapped.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":640,"y":400}}"#.utf8)) as? NSDictionary)
        for invalid in [
            "Thought: choose.\nAction: click(start_box='(1288,406)')",
            "Thought: choose.\nAction: click(start_box='(1,2)')\nAction: wait()",
            "Thought: choose.\nAction: python('arbitrary')",
            "Thought: choose.\nAction: click(start_box='(NaN,2)')",
        ] {
            XCTAssertThrowsError(try UIActionTextParser.canonicalJSON(invalid, imageSize: (1280, 800)))
        }
    }

    func testUiTarsNativeActionBranchesMapToCanonicalActions() throws {
        let cases: [(String, String)] = [
            ("click(start_box='(644,406)')", #"{"type":"click","target":{"x":640,"y":400}}"#),
            ("left_double(start_box='(644,406)')", #"{"type":"click","target":{"x":640,"y":400},"count":2}"#),
            ("right_single(start_box='(644,406)')", #"{"type":"click","target":{"x":640,"y":400},"button":"right"}"#),
            ("drag(start_box='(644,406)', end_box='(1287,811)')", #"{"type":"drag","from":{"x":640,"y":400},"to":{"x":1279.0062111801242,"y":799.0147783251232}}"#),
            ("hotkey(key='CTRL+L')", #"{"type":"key","chord":"CTRL+L"}"#),
            ("type(content='hello\\nworld')", #"{"type":"type","text":"hello\nworld","mode":"append"}"#),
            ("scroll(start_box='(644,406)', direction='down')", #"{"type":"scroll","target":{"x":640,"y":400},"direction":"down","amount":400}"#),
            ("wait()", #"{"type":"wait","seconds":5}"#),
            ("finished(content='complete')", #"{"type":"done","answer":"complete"}"#),
            ("call_user(content='clarify')", #"{"type":"ask_user","question":"clarify"}"#),
            ("open_url(url='https://example.test/')", #"{"type":"open_url","url":"https://example.test/"}"#),
            ("open_app(name='Example Editor')", #"{"type":"open_app","name":"Example Editor"}"#),
            ("find_files(query='sample', kind='text')", #"{"type":"find_files","query":"sample","kind":"text"}"#),
            ("select_option(start_box='(644,406)', option='First choice')", #"{"type":"select","target":{"x":640,"y":400},"option":"First choice"}"#),
            ("set_files(start_box='(644,406)', file_ids='[\\\"file-1\\\"]')", #"{"type":"set_files","target":{"x":640,"y":400},"file_ids":["file-1"]}"#),
            ("fail(reason='Unavailable')", #"{"type":"fail","reason":"Unavailable"}"#),
        ]
        for (line, expected) in cases {
            let actual = try UIActionTextParser.canonicalJSON("Thought: act.\nAction: " + line, imageSize: (1280, 800))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(actual.utf8)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary, line)
            XCTAssertNoThrow(try JSONDecoder().decode(AgentAction.self, from: Data(actual.utf8)), line)
        }
    }

    func testFaraNormalizedCoordinatesAndScrollScaleToScreenshot() throws {
        let center = try completion(arguments: #"{"action":"left_click","coordinate":[500,500]}"#)
        let centerAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: center, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(centerAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":1000,"y":500}}"#.utf8)) as? NSDictionary)
        let edge = try completion(arguments: #"{"action":"left_click","coordinate":[999,999]}"#)
        let edgeAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: edge, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(edgeAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":1998,"y":999}}"#.utf8)) as? NSDictionary)
        let vertical = try completion(arguments: #"{"action":"scroll","pixels":500}"#)
        let verticalAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: vertical, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(verticalAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"scroll","direction":"up","amount":500}"#.utf8)) as? NSDictionary)
        let horizontal = try completion(arguments: #"{"action":"hscroll","pixels":500}"#)
        let horizontalAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: horizontal, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(horizontalAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"scroll","direction":"right","amount":1000}"#.utf8)) as? NSDictionary)
        let edgeBoundary = try completion(arguments: #"{"action":"left_click","coordinate":[1000,1000]}"#)
        let edgeBoundaryAction = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: edgeBoundary, imageSize: (2_000, 1_000))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(edgeBoundaryAction.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(#"{"type":"click","target":{"x":1999,"y":999}}"#.utf8)) as? NSDictionary)
        let invalid = try completion(arguments: #"{"action":"left_click","coordinate":[1001,10]}"#)
        XCTAssertThrowsError(try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: invalid, imageSize: (2_000, 1_000)))
    }

    func testUiTarsCompletionRejectsWrongModelAndMultipleChoices() throws {
        let valid = try uiTarsCompletion("Thought: wait.\nAction: wait()")
        XCTAssertNoThrow(try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: valid, imageSize: (1920, 1080)))
        let wrong = valid.replacingOccurrences(of: "ui-tars15-7b-v1", with: "another-model")
        XCTAssertThrowsError(try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: wrong, imageSize: (1920, 1080)))
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        var choices = try XCTUnwrap(body["choices"] as? [[String: Any]])
        choices.append(choices[0]); body["choices"] = choices
        let multiple = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertThrowsError(try UiTarsPolicyAdapter.canonicalActionJSON(fromCompletion: multiple, imageSize: (1920, 1080)))
    }

    func testPolicyCancellationStopsInjectedTransport() async throws {
        let transport = RecordingAgentVLMTransport(response: "", blocks: true)
        let (policy, observation, _) = try fixture(transport: transport)
        let proposal = Task { try await policy.propose(observation) }
        while transport.callCount == 0 { await Task.yield() }
        proposal.cancel()
        do {
            _ = try await proposal.value
            XCTFail("A cancelled proposal returned")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.stopCount, 1)
    }

    func testRequestBoundsImagesAndPreservesNativeMessageOrder() async throws {
        let raw = try completion(arguments: #"{"action":"wait","time":1}"#)
        let transport = RecordingAgentVLMTransport(response: raw)
        let (_, _, png) = try fixture(transport: transport)
        let request = AgentVLMRequestInput(messages: [
            .init(role: .system, content: [.text("Prompt")]),
            .init(role: .user, content: [.text("first"), .imagePNG(png)]),
            .init(role: .assistant, content: [.text("<tool_call>raw</tool_call>")]),
            .init(role: .user, content: [.text("feedback"), .imagePNG(png), .imagePNG(png)]),
        ])
        XCTAssertEqual(request.imageCount, 3)
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unit-test-token")
        let urlRequest = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        let content = try XCTUnwrap(messages[3]["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image_url", "image_url"])
        let tooManyImages = AgentVLMRequestInput(messages: [
            .init(role: .system, content: [.text("Prompt")]),
            .init(role: .user, content: [.text("feedback"), .imagePNG(png), .imagePNG(png), .imagePNG(png), .imagePNG(png)]),
        ])
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: tooManyImages))
    }

    func testApprovalOutcomesKeepOneNativeAssistantProposal() async throws {
        let proposal = try completion(arguments: #"{"action":"left_click","coordinate":[250,500]}"#)
        let click = AgentAction.click(target: .point(x: 1, y: 2), button: nil, count: nil)
        for result in ["approved and executed", "rejected: user declined", "rejected: approval target changed"] {
            let transport = RecordingAgentVLMTransport(responses: [proposal, try completion(arguments: #"{"action":"wait","time":1}"#)])
            let (policy, observation, _) = try fixture(transport: transport)
            _ = try await policy.propose(observation)
            let resumed = AgentObservation(task: observation.task, surface: observation.surface,
                screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
                history: [.init(action: click, result: result)], budget: .init(step: 1, maxSteps: 40))
            _ = try await policy.propose(resumed)
            let messages = try XCTUnwrap(transport.inputs.last?.messages)
            XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user])
            XCTAssertEqual(messages.filter { $0.role == .assistant }.flatMap(\.content), [.text(proposal)])
            XCTAssertTrue(messages[3].content.textValue?.contains(result) == true)
            XCTAssertEqual(messages.flatMap(\.content).imageValues.count, 2)
        }
    }

    func testClarificationFollowsNativeAskUserTurn() async throws {
        let proposal = try completion(arguments: #"{"action":"ask_user_question","question":"Which item?"}"#)
        let transport = RecordingAgentVLMTransport(responses: [proposal, try completion(arguments: #"{"action":"wait","time":1}"#)])
        let (policy, observation, _) = try fixture(transport: transport)
        _ = try await policy.propose(observation)
        let answered = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
            history: [.init(action: .askUser(question: "Which item?", choices: nil),
                            result: "User clarification: the second item")], budget: .init(step: 1, maxSteps: 40))
        _ = try await policy.propose(answered)
        let messages = try XCTUnwrap(transport.inputs.last?.messages)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.flatMap(\.content), [.text(proposal)])
        XCTAssertTrue(messages[3].content.textValue?.contains("User clarification: the second item") == true)
    }

    func testUiTarsHistoryKeepsAssistantNativeActionRatherThanHTTPEnvelope() async throws {
        let nativeAction = "Thought: wait.\nAction: wait()"
        let transport = RecordingAgentVLMTransport(responses: [try uiTarsCompletion(nativeAction), try uiTarsCompletion(nativeAction)])
        let png = try XCTUnwrap(NSBitmapImageRep(data: makeJPEG())?.representation(using: .png, properties: [:]))
        let observation = AgentObservation(task: "Wait for the page", surface: .app(bundleID: "example.editor", title: nil),
            screenshot: png.base64EncodedString(), elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 10))
        let policy = try LlamaVLMPolicy(transport: transport, prompt: "Native UI-TARS policy", model: .uiTars15_7b)
        _ = try await policy.propose(observation)
        let next = AgentObservation(task: observation.task, surface: observation.surface, screenshot: observation.screenshot,
            elements: [], focus: nil, history: [.init(action: .wait(seconds: 5), result: "ok: waited")],
            budget: .init(step: 1, maxSteps: 10))
        _ = try await policy.propose(next)

        let assistant = try XCTUnwrap(transport.inputs.last?.messages.first { $0.role == .assistant })
        XCTAssertEqual(assistant.content, [.text(nativeAction)])
    }

    func testEachPriorScreenshotStaysInItsActionUserTurn() async throws {
        let raw = try completion(arguments: #"{"action":"wait","time":1}"#)
        let transport = RecordingAgentVLMTransport(response: raw)
        let (policy, fixtureObservation, _) = try fixture(transport: transport)
        let screenshots = try [
            NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1),
            NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1),
            NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1),
        ].map { try makePNG(color: $0) }
        XCTAssertEqual(Set(screenshots).count, 3)
        let initial = AgentObservation(task: fixtureObservation.task, surface: fixtureObservation.surface,
            screenshot: screenshots[0].base64EncodedString(), elements: fixtureObservation.elements,
            focus: fixtureObservation.focus, history: [], budget: .init(step: 0, maxSteps: 40))
        _ = try await policy.propose(initial)
        let oneResult = AgentObservation(task: initial.task, surface: initial.surface,
            screenshot: screenshots[1].base64EncodedString(), elements: initial.elements, focus: initial.focus,
            history: [.init(action: .wait(seconds: 1), result: "result-0")], budget: .init(step: 1, maxSteps: 40))
        _ = try await policy.propose(oneResult)
        let twoResults = AgentObservation(task: initial.task, surface: initial.surface,
            screenshot: screenshots[2].base64EncodedString(), elements: initial.elements, focus: initial.focus,
            history: [
                .init(action: .wait(seconds: 1), result: "result-0"),
                .init(action: .wait(seconds: 1), result: "result-1"),
            ], budget: .init(step: 2, maxSteps: 40))

        _ = try await policy.propose(twoResults)

        let messages = try XCTUnwrap(transport.inputs.last?.messages)
        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(messages[1].content.imageValues, [screenshots[0]])
        XCTAssertEqual(messages[3].content.imageValues, [screenshots[1]])
        XCTAssertEqual(messages[5].content.imageValues, [screenshots[2]])
        XCTAssertEqual(transport.inputs.last?.imageCount, 3)
    }

    func testMalformedNativeOutputIsRetainedOnceBeforeRejectionFeedback() async throws {
        let malformed = "<tool_call>{unfinished"
        let transport = RecordingAgentVLMTransport(responses: [malformed, try completion(arguments: #"{"action":"wait","time":1}"#)])
        let (policy, observation, _) = try fixture(transport: transport)
        let first = try await policy.propose(observation)
        XCTAssertNil(first.action)
        let rejected = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
            history: [.init(action: nil, result: "rejected: invalid completion")],
            budget: .init(step: 1, maxSteps: 40))

        _ = try await policy.propose(rejected)

        let messages = try XCTUnwrap(transport.inputs.last?.messages)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(messages.first { $0.role == .assistant }?.content, [.text(malformed)])
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.textValue?.contains("rejected: invalid completion") == true })
    }

    func testEmptyNativeOutputDoesNotCreateAnEmptyAssistantTurn() async throws {
        let transport = RecordingAgentVLMTransport(responses: ["", try completion(arguments: #"{"action":"wait","time":1}"#)])
        let (policy, observation, _) = try fixture(transport: transport)
        _ = try await policy.propose(observation)
        let rejected = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
            history: [.init(action: nil, result: "rejected: empty native response")], budget: .init(step: 1, maxSteps: 40))
        _ = try await policy.propose(rejected)

        let messages = try XCTUnwrap(transport.inputs.last?.messages)
        XCTAssertFalse(messages.contains { $0.role == .assistant })
        XCTAssertTrue(messages.last?.content.textValue?.contains("rejected: empty native response") == true)
    }

    func testHistoryIsBoundedAndSuspendRetainsItWhileStopClearsIt() async throws {
        let raw = try completion(arguments: #"{"action":"wait","time":1}"#)
        let transport = RecordingAgentVLMTransport(response: raw)
        let (policy, observation, _) = try fixture(transport: transport)
        var history: [AgentHistoryItem] = []
        for index in 0..<12 {
            let input = AgentObservation(task: observation.task, surface: observation.surface,
                screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
                history: history, budget: .init(step: index, maxSteps: 40))
            _ = try await policy.propose(input)
            let sent = try XCTUnwrap(transport.inputs.last)
            XCTAssertLessThanOrEqual(sent.imageCount, 3)
            XCTAssertLessThanOrEqual(sent.messages.filter { $0.role == .assistant }.count, 8)
            XCTAssertFalse(sent.messages.flatMap(\.content).textValues.contains { $0.contains("result-0") } && index >= 9)
            if index == 6 {
                let approvalFeedback = try XCTUnwrap(sent.messages.first {
                    $0.role == .user && $0.content.textValue?.contains("needs approval") == true
                }?.content.textValue)
                XCTAssertTrue(approvalFeedback.contains("needs approval"))
                XCTAssertTrue(approvalFeedback.contains("approved and executed"))
                XCTAssertEqual(sent.messages.filter { $0.role == .assistant }.count, 6)
            }
            if index == 11 {
                let earliestPriorUser = try XCTUnwrap(sent.messages.first { $0.role == .user })
                XCTAssertTrue(earliestPriorUser.content.imageValues.isEmpty)
                XCTAssertFalse(earliestPriorUser.content.textValue?.contains("Continue") == true)
            }
            if index == 5 { await policy.suspend() }
            if index == 5 {
                history.append(.init(action: .wait(seconds: 1), result: "needs approval: confirm"))
                history.append(.init(action: .wait(seconds: 1), result: "approved and executed"))
            } else {
                history.append(.init(action: .wait(seconds: 1), result: "result-\(index)"))
            }
        }
        XCTAssertTrue(transport.inputs[6].messages.contains { $0.role == .assistant }, "Suspend should retain completed transcript")
        await policy.stop()
        let afterStop = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
            history: history, budget: .init(step: 13, maxSteps: 40))
        _ = try await policy.propose(afterStop)
        XCTAssertFalse(transport.inputs.last?.messages.contains { $0.role == .assistant } ?? true)
    }

    func testDuplicateObservationKeepsLastAlignedTurnWithoutPairingPendingOutput() async throws {
        let raw = try completion(arguments: #"{"action":"wait","time":1}"#)
        let transport = RecordingAgentVLMTransport(responses: [raw, raw, raw])
        let (policy, observation, _) = try fixture(transport: transport)
        _ = try await policy.propose(observation)
        let result = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
            history: [.init(action: .wait(seconds: 1), result: "result-0")], budget: .init(step: 1, maxSteps: 40))
        _ = try await policy.propose(result)
        _ = try await policy.propose(result)
        XCTAssertEqual(transport.inputs.last?.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(transport.inputs.last?.messages.first { $0.role == .assistant }?.content, [.text(raw)])
    }

    func testObservationCarriesOnlyLastEightActionResults() throws {
        let items = (0..<10).map { index in
            AgentHistoryItem(action: .wait(seconds: 1), result: "result-\(index)")
        }
        let observation = AgentObservation(task: "A generic task",
            surface: .app(bundleID: "example.editor", title: nil), screenshot: "AA==",
            elements: [], focus: nil, history: items, budget: .init(step: 10, maxSteps: 20))
        let json = try LlamaVLMPolicy.observationJSON(observation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let history = try XCTUnwrap(object["history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 8)
        XCTAssertEqual(history.first?["result"] as? String, "result-2")
        XCTAssertEqual(history.last?["result"] as? String, "result-9")
    }

    func testPolicyCapturePreferencesAndUIResourceLimitsAreExplicit() {
        XCTAssertEqual(AgentPolicyModel.fara15_4b.capturePreference, .frontmostWindow)
        XCTAssertEqual(AgentPolicyModel.uiTars15_7b.capturePreference, .fullDisplay)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.agentVision.contextSize, 16_384)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.agentVision.maximumResidentMemoryBytes, 12 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.agentVision.maximumResidentModelWorkers, 1)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.fara.contextSize, 8_192)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.fara.maximumResidentMemoryBytes, 4 * 1_024 * 1_024 * 1_024)
    }

    func testFaraUsesPlainCompletionContentAndAuthenticatedLoopbackOnly() throws {
        let (_, observation, png) = try fixture(transport: RecordingAgentVLMTransport(response: ""))
        let input = AgentVLMRequestInput(messages: [
            .init(role: .system, content: [.text(LlamaVLMPolicy.nativePrompt(try promptText(), model: .fara15_4b))]),
            .init(role: .user, content: [.text(try LlamaVLMPolicy.observationJSON(observation)), .imagePNG(png)]),
        ])
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unit-test-token")
        let request = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: input)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:43123/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, ComputerUseFaraRuntimeInputs.modelAlias)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertNil(body["response_format"])
        XCTAssertEqual(body["reasoning_format"] as? String, "none")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.contains("Qwen3.5-4B"))
        XCTAssertTrue(system.contains("<tools>"))
        XCTAssertTrue(system.contains("\"name\": \"computer_use\""))
        XCTAssertTrue(system.contains("<tool_call>"))
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertFalse((content[0]["text"] as? String ?? "").contains(png.base64EncodedString()))
        XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"],
                       "data:image/png;base64," + png.base64EncodedString())
        let templateRequest = try OSAtlasLlamaHTTPClient.makeSemanticTemplateRequest(from: request)
        XCTAssertEqual(templateRequest.url?.absoluteString, "http://127.0.0.1:43123/apply-template")
        XCTAssertEqual(templateRequest.httpBody, request.httpBody)
        let uiInput = AgentVLMRequestInput(messages: [
            .init(role: .system, content: [.text("UI prompt")]),
            .init(role: .user, content: [.text("{}"), .imagePNG(png)]),
        ], modelAlias: "ui-tars15-7b-v1", model: .uiTars15_7b)
        let uiRequest = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: uiInput)
        let uiBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(uiRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(uiBody["model"] as? String, "ui-tars15-7b-v1")
        XCTAssertNil(uiBody["tools"])
        XCTAssertNil(uiBody["tool_choice"])
        XCTAssertNil(uiBody["response_format"])
        for url in ["https://example.test/", "http://user:secret@127.0.0.1:43123"] {
            let rejected = OSAtlasLlamaEndpoint(generation: 2, variant: nil,
                baseURL: URL(string: url)!, bearerToken: "token")
            XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: rejected, input: input))
        }
    }

    func testFaraResponseUsesMessageContentAndNeverReasoningContent() throws {
        let action = #"<tool_call>{"name":"computer_use","arguments":{"action":"wait","time":1}}</tool_call>"#
        let envelope: [String: Any] = ["choices": [["message": [
            "role": "assistant", "content": action,
            "reasoning_content": #"<tool_call>{"name":"computer_use","arguments":{"action":"terminate","answer":"wrong"}}</tool_call>"#,
        ]]]]
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertEqual(try OSAtlasLlamaHTTPClient.responseText(from: bytes), action)

        let reasoningOnly: [String: Any] = ["choices": [["message": [
            "role": "assistant", "content": "", "reasoning_content": action,
        ]]]]
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.responseText(from:
            JSONSerialization.data(withJSONObject: reasoningOnly)))
    }

    func testInvalidPNGAndObservationAreRejectedBeforeTransport() async throws {
        let transport = RecordingAgentVLMTransport(response: #"{"type":"done","answer":"ok"}"#)
        let (policy, observation, _) = try fixture(transport: transport)
        let invalidPNG = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: "bm90LXBuZw==", elements: observation.elements, focus: observation.focus,
            history: observation.history, budget: observation.budget)
        do { _ = try await policy.propose(invalidPNG); XCTFail("Invalid PNG passed through") }
        catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidVisionInput) }
        XCTAssertEqual(transport.callCount, 0)
    }

    private func fixture(transport: RecordingAgentVLMTransport) throws
        -> (LlamaVLMPolicy, AgentObservation, Data) {
        let png = try XCTUnwrap(NSBitmapImageRep(data: makeJPEG())?.representation(using: .png, properties: [:]))
        let observation = AgentObservation(task: "Complete a generic task",
            surface: .web(url: "https://example.test/", title: nil), screenshot: png.base64EncodedString(),
            elements: [.init(id: 1, role: "button", name: "Continue", value: nil, state: ["enabled"],
                             bbox: .init(x: 1, y: 2, width: 30, height: 12), inView: true)],
            focus: nil, history: [], budget: .init(step: 0, maxSteps: 40))
        let promptURL = try XCTUnwrap(Bundle.main.url(forResource: "v1", withExtension: "txt",
                                                      subdirectory: "policy/prompts"))
        let prompt = try String(contentsOf: promptURL, encoding: .utf8)
        return (try LlamaVLMPolicy(transport: transport, prompt: prompt), observation, png)
    }

    private func promptText() throws -> String {
        let promptURL = try XCTUnwrap(Bundle.main.url(forResource: "v1", withExtension: "txt",
                                                      subdirectory: "policy/prompts"))
        return try String(contentsOf: promptURL, encoding: .utf8)
    }

    private func completion(arguments: String, toolName: String = "computer_use", extraCalls: Bool = false,
                            content: String = "") throws -> String {
        let call = "<tool_call>{\"name\":\"\(toolName)\",\"arguments\":\(arguments)}</tool_call>"
        return [content, call, extraCalls ? call : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func completionWithoutToolCall(content: String) throws -> String {
        content
    }

    private func uiTarsCompletion(_ content: String) throws -> String {
        let body: [String: Any] = ["model": "ui-tars15-7b-v1",
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }

    private func makeJPEG() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return image.representation(using: .jpeg, properties: [:])!
    }

    private func makePNG(color: NSColor) throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<4 {
            for x in 0..<4 { image.setColor(color, atX: x, y: y) }
        }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class RecordingAgentVLMTransport: AgentVLMTransport {
    private let responses: [String]
    private let blocks: Bool
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var inputs: [AgentVLMRequestInput] = []
    private(set) var stopCount = 0
    var callCount: Int { inputs.count }

    init(response: String, blocks: Bool = false) {
        self.responses = [response]
        self.blocks = blocks
    }

    init(responses: [String], blocks: Bool = false) {
        self.responses = responses
        self.blocks = blocks
    }

    func complete(_ input: AgentVLMRequestInput) async throws -> String {
        inputs.append(input)
        if blocks {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return responses[min(inputs.count - 1, responses.count - 1)]
    }

    func stop() async {
        stopCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private extension Array where Element == AgentVLMContentPart {
    var textValue: String? {
        guard case .text(let text)? = first else { return nil }
        return text
    }

    var imageValues: [Data] {
        compactMap { part in
            guard case .imagePNG(let data) = part else { return nil }
            return data
        }
    }

    var textValues: [String] {
        compactMap { part in
            guard case .text(let text) = part else { return nil }
            return text
        }
    }
}
