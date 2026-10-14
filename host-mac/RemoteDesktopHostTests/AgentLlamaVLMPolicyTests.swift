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

        XCTAssertEqual(policy.promptVersion, "v1-fara-native-coordinates-compact-history")
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
        XCTAssertTrue(input.messages[1].content.textValue?.contains(#""elements":[{"bbox":[250,250,500,500]"#) == true)
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
            (#"{"action":"visit_url","url":"https://example.test/"}"#, #"{"type":"open_url","url":"https://example.test/"}"#),
            (#"{"action":"wait","time":1}"#, #"{"type":"wait","seconds":1}"#),
            (#"{"action":"ask_user_question","question":"Choose one"}"#, #"{"type":"ask_user","question":"Choose one"}"#),
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

    func testUnsupportedFaraProposalsAreRecoverablePolicyRejections() async throws {
        let cases: [(String, String)] = [
            (#"{"action":"mouse_move","coordinate":[502,496]}"#, "Moving the pointer without a click is not available in this host action contract."),
            (#"{"action":"left_click_drag","coordinate":[8,9]}"#, "This host action contract requires both drag endpoints; Fara supplied only the destination."),
            (#"{"action":"visit_url","url":"file:///tmp/example.txt"}"#, "Only absolute HTTP and HTTPS URLs are supported."),
            (#"{"action":"web_search","query":"weather"}"#, "Search is unavailable in the current computer-use action contract."),
            (#"{"action":"read_page_answer_question","question":"What is shown?"}"#, "Page-reading actions are unavailable in the current computer-use action contract."),
            (#"{"action":"pause_and_memorize_fact","fact":"remember this"}"#, "Memory actions are unavailable in the current computer-use action contract."),
        ]
        for (arguments, reason) in cases {
            let raw = try completion(arguments: arguments)
            let transport = RecordingAgentVLMTransport(response: raw)
            let (policy, observation, _) = try fixture(transport: transport)

            let output = try await policy.propose(observation)

            XCTAssertEqual(output.rawOutput, raw)
            XCTAssertNil(output.action)
            XCTAssertEqual(output.rejectionReason, reason)
            XCTAssertEqual(transport.callCount, 1)
        }
    }

    func testUnsupportedGUIOwlProposalsAreRecoverablePolicyRejections() async throws {
        let model = AgentPolicyModel.guiOwl15_4b
        let cases: [(String, String)] = [
            (#"{"action":"mouse_move","coordinate":[502,496]}"#, "Moving the pointer without a click is unavailable in the host action contract."),
            (#"{"action":"left_click_drag","coordinate":[8,9]}"#, "The host action contract requires both drag endpoints; GUI-Owl supplied only a destination."),
            (#"{"action":"hscroll","pixels":4}"#, "Horizontal scrolling is unsupported by the pinned GUI-Owl PC runner."),
        ]
        for (arguments, reason) in cases {
            let raw = try completion(arguments: arguments, content: "Action: Try the requested operation.")
            let transport = RecordingAgentVLMTransport(response: raw)
            let (_, observation, _) = try fixture(transport: transport)
            let policy = try LlamaVLMPolicy(transport: transport, prompt: promptText(), model: model)

            let output = try await policy.propose(observation)

            XCTAssertEqual(output.rawOutput, raw)
            XCTAssertNil(output.action)
            XCTAssertEqual(output.rejectionReason, reason)
            XCTAssertEqual(transport.callCount, 1)
        }
    }

    func testExplicitNativeTerminalFailureRemainsAFailureAction() async throws {
        let model = AgentPolicyModel.guiOwl15_4b
        let raw = try completion(arguments: #"{"action":"terminate","status":"failure"}"#,
            content: "Action: Report failure.")
        let transport = RecordingAgentVLMTransport(response: raw)
        let (_, observation, _) = try fixture(transport: transport)
        let policy = try LlamaVLMPolicy(transport: transport, prompt: promptText(), model: model)

        let output = try await policy.propose(observation)

        XCTAssertEqual(output.rawOutput, raw)
        XCTAssertEqual(output.action, .fail(reason: "The model reported task failure."))
        XCTAssertNil(output.rejectionReason)
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

    func testModelFacingBoundingBoxesUseNativeFramesAndDecodeBack() async throws {
        let dimensions = [(width: 1_280, height: 827), (width: 2_048, height: 1_323)]
        for model in AgentPolicyModel.allCases {
            for size in dimensions {
                let png = try makePNG(width: size.width, height: size.height)
                let box = AgentBoundingBox(x: Double(size.width) * 0.271,
                    y: Double(size.height) * 0.237, width: Double(size.width) * 0.137,
                    height: Double(size.height) * 0.119)
                let observation = AgentObservation(task: "Click the marked control",
                    surface: .app(bundleID: "example.editor", title: nil),
                    screenshot: png.base64EncodedString(),
                    elements: [.init(id: 17, role: "button", name: "Target", value: nil,
                        state: ["enabled"], bbox: box, inView: true)],
                    focus: nil, history: [], budget: .init(step: 0, maxSteps: 5))
                let canonicalJSON = try LlamaVLMPolicy.observationJSON(observation)
                let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonicalJSON.utf8)) as? [String: Any])
                let canonicalElements = try XCTUnwrap(canonical["elements"] as? [[String: Any]])
                XCTAssertEqual(canonicalElements.first?["bbox"] as? [Double], [box.x, box.y, box.width, box.height])

                let expected: [Double]
                if model == .uiTars15_7b {
                    let resized = try UIActionTextParser.resizedSize(for: size)
                    expected = [box.x * Double(resized.width) / Double(size.width),
                        box.y * Double(resized.height) / Double(size.height),
                        box.width * Double(resized.width) / Double(size.width),
                        box.height * Double(resized.height) / Double(size.height)]
                } else {
                    expected = [box.x * 1_000 / Double(size.width), box.y * 1_000 / Double(size.height),
                        box.width * 1_000 / Double(size.width), box.height * 1_000 / Double(size.height)]
                }
                let centerX = expected[0] + expected[2] / 2
                let centerY = expected[1] + expected[3] / 2
                let response: String
                switch model {
                case .fara15_4b:
                    response = try completion(arguments: #"{"action":"left_click","coordinate":[\#(centerX),\#(centerY)]}"#)
                case .uiTars15_7b:
                    response = try uiTarsCompletion("Thought: click the marked control.\nAction: click(start_box='(\(centerX),\(centerY))')")
                case .guiOwl15_4b:
                    response = try completion(arguments: #"{"action":"click","coordinate":[\#(centerX),\#(centerY)]}"#,
                        content: "Action: click the marked control.")
                }
                let transport = RecordingAgentVLMTransport(response: response)
                let policy = try LlamaVLMPolicy(transport: transport, prompt: promptText(), model: model)
                let output = try await policy.propose(observation)
                guard case .click(.point(let x, let y), _, _)? = output.action else {
                    XCTFail("Expected a native center click from \(model)")
                    continue
                }
                XCTAssertGreaterThanOrEqual(x, box.x)
                XCTAssertLessThanOrEqual(x, box.x + box.width)
                XCTAssertGreaterThanOrEqual(y, box.y)
                XCTAssertLessThanOrEqual(y, box.y + box.height)

                let request = try XCTUnwrap(transport.inputs.first)
                XCTAssertEqual(request.imageCount, 1)
                let userText = try XCTUnwrap(request.messages.first(where: { $0.role == .user })?.content.textValue)
                let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(userText.utf8)) as? [String: Any])
                let requestElements = try XCTUnwrap(requestJSON["elements"] as? [[String: Any]])
                let actual = try XCTUnwrap(requestElements.first?["bbox"] as? [Double])
                XCTAssertEqual(actual.count, expected.count)
                for (actualValue, expectedValue) in zip(actual, expected) {
                    XCTAssertEqual(actualValue, expectedValue, accuracy: 1e-9)
                }
                XCTAssertTrue(request.messages.first?.content.textValue?.contains("bounding boxes") == true)
                if size.width == 2_048 {
                    let resized = try UIActionTextParser.resizedSize(for: size)
                    XCTAssertLessThanOrEqual(resized.width * resized.height, 1_536 * 28 * 28)
                    XCTAssertGreaterThan(size.width * size.height, 1_536 * 28 * 28)
                }
            }
        }
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

    func testGUIOwlUsesFullDisplayVersionedAliasAndPlainChatRequest() async throws {
        let model = try XCTUnwrap(AgentPolicyModel(rawValue: "gui-owl15-4b"))
        XCTAssertEqual(model.capturePreference, .fullDisplay)
        let nativePrompt = "GUI-Owl native prompt resource sentinel"
        let response = try completion(arguments: #"{"action":"wait","time":1}"#, content: "Action: Wait.")
        let transport = RecordingAgentVLMTransport(response: response)
        let ( _, observation, _) = try fixture(transport: transport)
        let policy = try LlamaVLMPolicy(transport: transport, prompt: nativePrompt, model: model)

        let output = try await policy.propose(observation)

        XCTAssertEqual(output.action, .wait(seconds: 1))
        let input = try XCTUnwrap(transport.inputs.last)
        XCTAssertEqual(input.modelAlias, "gui-owl15-4b-v1")
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "unit-test-token")
        let request = try OSAtlasLlamaHTTPClient.makeAgentActionRequest(endpoint: endpoint, input: input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gui-owl15-4b-v1")
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["grammar"])
        XCTAssertNil(body["response_format"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, LlamaVLMPolicy.nativePrompt(nativePrompt, model: model))
    }

    func testGUIOwlNativeMessageContentIsTheAssistantHistoryTurn() async throws {
        let model = try XCTUnwrap(AgentPolicyModel(rawValue: "gui-owl15-4b"))
        let promptURL = try XCTUnwrap(Bundle.main.url(forResource: LlamaVLMPolicy.promptResourceName(for: model), withExtension: "txt",
                                                      subdirectory: "policy/prompts"))
        XCTAssertEqual(promptURL.lastPathComponent, "gui-owl-1.5.txt")
        let nativePrompt = try String(contentsOf: promptURL, encoding: .utf8)
        XCTAssertTrue(LlamaVLMPolicy.nativePrompt(nativePrompt, model: model).contains(
            "[x, y, width, height] in GUI-Owl's normalized 0–1000 display coordinates"))

        let rawContent = try completion(arguments: #"{"action":"wait","time":1}"#, content: "Action: Wait.")
        let transport = RecordingAgentVLMTransport(responses: [rawContent, rawContent])
        let (_, observation, _) = try fixture(transport: transport)
        let policy = try LlamaVLMPolicy(transport: transport, prompt: nativePrompt, model: model)
        _ = try await policy.propose(observation)
        let next = AgentObservation(task: observation.task, surface: observation.surface,
            screenshot: observation.screenshot, elements: observation.elements, focus: observation.focus,
            history: [.init(action: .wait(seconds: 1), result: "ok: waited")],
            budget: .init(step: 1, maxSteps: 40))

        _ = try await policy.propose(next)

        let messages = try XCTUnwrap(transport.inputs.last?.messages)
        XCTAssertEqual(messages.first(where: { $0.role == .system })?.content,
            [.text(LlamaVLMPolicy.nativePrompt(nativePrompt, model: model))])
        XCTAssertEqual(messages.filter { $0.role == .assistant }.map(\.content), [[.text(rawContent)]])
        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user])
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
            XCTAssertEqual(sent.imageCount, min(index, 2) + 1)
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
                let userTurns = sent.messages.filter { $0.role == .user }
                for prior in userTurns.dropLast() {
                    let text = try XCTUnwrap(prior.content.textValue)
                    XCTAssertFalse(text.contains("\"elements\""))
                    XCTAssertFalse(text.contains("\"focus\""))
                }
                XCTAssertTrue(try XCTUnwrap(userTurns.last?.content.textValue).contains("\"elements\""))
                XCTAssertFalse(userTurns.first?.content.textValue?.contains("Continue") == true)
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
                             bbox: .init(x: 1, y: 1, width: 2, height: 2), inView: true)],
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

    private func makePNG(width: Int, height: Int) throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bitmap = try XCTUnwrap(image.bitmapData)
        bitmap.update(repeating: 0xff, count: image.bytesPerRow * height)
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
