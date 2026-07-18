import XCTest
@testable import RemoteDesktopHost

final class SemanticNativeToolWireContractTests: XCTestCase {
    func testCanonicalDefinitionsAreClosedBoundedAndExcludeRuntimeAbstention() {
        let definitions = SemanticNativeToolWireContract.definitions(
            for: allProductionDirectives)

        XCTAssertEqual(
            definitions.map(\.name),
            SemanticNativeToolWireContract.canonicalToolNames)
        XCTAssertEqual(definitions.count, 16)
        XCTAssertFalse(definitions.map(\.name).contains("abstain"))
        XCTAssertFalse(definitions.map(\.name).contains(
            "report_direct_facts_only"))

        for definition in definitions {
            XCTAssertFalse(definition.description.isEmpty, definition.name)
            guard case .object(let schema) = definition.inputSchema else {
                return XCTFail("\(definition.name) must use an object schema")
            }
            XCTAssertEqual(schema["type"], .string("object"), definition.name)
            XCTAssertEqual(
                schema["additionalProperties"],
                .bool(false),
                definition.name)
            guard case .object = schema["properties"],
                  case .array = schema["required"] else {
                return XCTFail("\(definition.name) must expose closed fields")
            }
            guard case .object(let nativeTool) = definition.nativeToolJSON,
                  nativeTool["type"] == .string("function"),
                  case .object(let function)? = nativeTool["function"] else {
                return XCTFail("\(definition.name) has invalid native JSON")
            }
            XCTAssertEqual(function["name"], .string(definition.name))
            XCTAssertEqual(function["parameters"], definition.inputSchema)
            XCTAssertLessThanOrEqual(
                maximumStringLength(in: definition.inputSchema),
                SemanticNativeToolWireContract
                    .maximumModelGeneratedTextCharacters,
                definition.name)
        }
    }

    func testTypeTextSchemaUsesPinnedB9992SafeMaximum() throws {
        XCTAssertEqual(
            SemanticNativeToolWireContract.maximumModelGeneratedTextCharacters,
            512)
        let definition = try XCTUnwrap(
            SemanticNativeToolWireContract.definition(named: "type_text"))
        guard case .object(let root) = definition.inputSchema,
              case .object(let properties)? = root["properties"],
              case .object(let text)? = properties["text"] else {
            return XCTFail("type_text schema is malformed")
        }
        XCTAssertEqual(
            text["maxLength"],
            .integer(SemanticNativeToolWireContract
                .maximumModelGeneratedTextCharacters))
    }

    func testTypeAndAskEnforceSharedCharacterAndUTF8Boundaries() throws {
        let request = productionRequest()
        let ascii512 = String(repeating: "x", count: 512)
        let ascii513 = String(repeating: "x", count: 513)
        let exact2048Bytes = String(repeating: "😀", count: 512)
        let over2048Bytes = String(repeating: "😀", count: 511)
            + "👨‍👩‍👧‍👦"
        XCTAssertEqual(exact2048Bytes.count, 512)
        XCTAssertEqual(exact2048Bytes.utf8.count, 2_048)
        XCTAssertEqual(over2048Bytes.count, 512)
        XCTAssertGreaterThan(over2048Bytes.utf8.count, 2_048)

        for text in [ascii512, exact2048Bytes] {
            XCTAssertEqual(
                try route(
                    name: "type_text",
                    argumentsJSON: jsonObject(key: "text", string: text),
                    request: request),
                .init(directive: .type, argument: .text(text)))
        }
        for text in [ascii513, over2048Bytes] {
            assertRejected(
                .init(content: nil, toolCalls: [.init(
                    name: "type_text",
                    argumentsJSON: jsonObject(key: "text", string: text))]),
                request: request)
        }

        for length in [500, 501, 512] {
            let question = String(repeating: "q", count: length)
            XCTAssertEqual(
                try route(
                    name: "ask_user",
                    argumentsJSON: jsonObject(
                        key: "question",
                        string: question),
                    request: request),
                .init(directive: .ask, argument: .question(question)))
        }
        XCTAssertEqual(
            try route(
                name: "ask_user",
                argumentsJSON: jsonObject(
                    key: "question",
                    string: exact2048Bytes),
                request: request),
            .init(
                directive: .ask,
                argument: .question(exact2048Bytes)))
        for question in [ascii513, over2048Bytes] {
            assertRejected(
                .init(content: nil, toolCalls: [.init(
                    name: "ask_user",
                    argumentsJSON: jsonObject(
                        key: "question",
                        string: question))]),
                request: request)
        }
    }

    func testEveryCanonicalCallMapsToExistingTypedRoute() throws {
        let request = productionRequest()
        let cases: [(String, String, OSAtlasSemanticActionRoute)] = [
            ("normal_click", #"{"target_hint":"Save"}"#,
             .init(directive: .click, argument: .targetHint("Save"))),
            ("double_click", #"{"target_hint":"Downloads"}"#,
             .init(directive: .doubleClick,
                   argument: .targetHint("Downloads"))),
            ("right_click", #"{"target_hint":"Packing list"}"#,
             .init(directive: .rightClick,
                   argument: .targetHint("Packing list"))),
            ("drag_item",
             #"{"item_to_move":"Buy groceries","drop_destination":"Weekend"}"#,
             .init(directive: .drag,
                   argument: .dragHints(
                       source: "Buy groceries", destination: "Weekend"))),
            ("type_text", #"{"text":"oat milk"}"#,
             .init(directive: .type, argument: .text("oat milk"))),
            ("scroll_up", "{}",
             .init(directive: .scroll, scrollDirection: .up)),
            ("scroll_down", "{}",
             .init(directive: .scroll, scrollDirection: .down)),
            ("scroll_left", "{}",
             .init(directive: .scroll, scrollDirection: .left)),
            ("scroll_right", "{}",
             .init(directive: .scroll, scrollDirection: .right)),
            ("open_application", #"{"application_name":"Notes"}"#,
             .init(directive: .openApplication,
                   argument: .applicationName("Notes"))),
            ("press_enter", "{}", .init(directive: .enter)),
            ("keyboard_shortcut", #"{"shortcut":"cmd+shift+c"}"#,
             .init(directive: .hotkey,
                   argument: .hotkey("COMMAND+SHIFT+C"))),
            ("wait_for_screen", "{}", .init(directive: .wait)),
            ("complete_task", "{}", .init(directive: .complete)),
            ("ask_user", #"{"question":"What date should I use?"}"#,
             .init(directive: .ask,
                   argument: .question("What date should I use?"))),
            ("answer_direct_question_only",
             #"{"summary":"The total is $42.","evidence":["Total: $42"]}"#,
             .init(directive: .answer,
                   argument: .visibleAnswer(
                       summary: "The total is $42.",
                       evidence: ["Total: $42"]))),
        ]

        XCTAssertEqual(cases.map(\.0),
                       SemanticNativeToolWireContract.canonicalToolNames)
        for testCase in cases {
            XCTAssertEqual(
                try route(
                    name: testCase.0,
                    argumentsJSON: testCase.1,
                    request: request),
                testCase.2,
                testCase.0)
        }
    }

    func testEnvelopeRejectsProseZeroCallsAndMultipleCalls() {
        let request = productionRequest()
        assertRejected(
            SemanticNativeToolAssistantMessage(
                content: "I will click Save.",
                toolCalls: [.init(
                    name: "normal_click",
                    argumentsJSON: #"{"target_hint":"Save"}"#)]),
            request: request)
        assertRejected(
            SemanticNativeToolAssistantMessage(content: nil, toolCalls: []),
            request: request)
        assertRejected(
            SemanticNativeToolAssistantMessage(
                content: nil,
                toolCalls: [
                    .init(name: "normal_click",
                          argumentsJSON: #"{"target_hint":"Save"}"#),
                    .init(name: "complete_task", argumentsJSON: "{}"),
                ]),
            request: request)
    }

    func testArgumentsRejectDuplicateUnknownMissingWrongAndOverlongFields() {
        let request = productionRequest()
        let rejected: [(String, String)] = [
            ("normal_click",
             #"{"target_hint":"Save","target_hint":"Delete"}"#),
            ("normal_click",
             #"{"target_hint":"Save","\u0074arget_hint":"Delete"}"#),
            ("normal_click",
             #"{"target_hint":"Save","coordinates":[1,2]}"#),
            ("normal_click", "{}"),
            ("normal_click", #"{"target_hint":42}"#),
            ("normal_click", #"{"target_hint":" Save "}"#),
            ("normal_click", #"{"target_hint":"Save"} trailing prose"#),
            ("press_enter", #"{"unexpected":true}"#),
            ("press_enter", "[]"),
            ("type_text", #"{"text":"   "}"#),
        ]
        for testCase in rejected {
            assertRejected(
                .init(content: nil, toolCalls: [
                    .init(name: testCase.0, argumentsJSON: testCase.1),
                ]),
                request: request,
                message: testCase.1)
        }

        assertRejected(
            .init(content: nil, toolCalls: [
                .init(
                    name: "normal_click",
                    argumentsJSON: jsonObject(
                        key: "target_hint",
                        string: String(repeating: "x", count: 257))),
            ]),
            request: request)
        assertRejected(
            .init(content: nil, toolCalls: [
                .init(
                    name: "type_text",
                    argumentsJSON: jsonObject(
                        key: "text",
                        string: String(repeating: "x", count: 513))),
            ]),
            request: request)
    }

    func testUnofferedToolAndLegacyReportAliasAreRejected() {
        let clickOnly = OSAtlasSemanticRoutingRequest(
            task: "Click Save.",
            frontmostApplication: "Notes",
            visibleText: "Save",
            history: [],
            availableDirectives: [.click])
        assertRejected(
            .init(content: nil, toolCalls: [
                .init(name: "type_text",
                      argumentsJSON: #"{"text":"hello"}"#),
            ]),
            request: clickOnly)
        assertRejected(
            .init(content: nil, toolCalls: [
                .init(name: "report_direct_facts_only",
                      argumentsJSON: #"{"summary":"Ready","evidence":["Status: Ready"]}"#),
            ]),
            request: productionRequest())
    }

    func testHotkeyRequiresUniqueModifierAndOneSupportedHIDKey() {
        let request = productionRequest()
        for value in [
            "C",
            "COMMAND",
            "COMMAND+C+V",
            "COMMAND+COMMAND+C",
            "COMMAND+?",
            "COMMAND+🔥",
            "COMMAND+",
        ] {
            assertRejected(
                .init(content: nil, toolCalls: [
                    .init(
                        name: "keyboard_shortcut",
                        argumentsJSON: jsonObject(
                            key: "shortcut", string: value)),
                ]),
                request: request,
                message: value)
        }
    }

    func testVisibleAnswerRequiresUniqueExactCompleteVisibleLines() {
        let request = productionRequest()
        for arguments in [
            #"{"summary":"Ready","evidence":["Ready"]}"#,
            #"{"summary":"Ready","evidence":[" Status: Ready"]}"#,
            #"{"summary":"Ready","evidence":["LINE 1: Status: Ready"]}"#,
            #"{"summary":"Ready","evidence":["Status: Ready","Status: Ready"]}"#,
            #"{"summary":"Ready","evidence":[42]}"#,
            #"{"summary":"Ready","evidence":[]}"#,
        ] {
            assertRejected(
                .init(content: nil, toolCalls: [
                    .init(
                        name: "answer_direct_question_only",
                        argumentsJSON: arguments),
                ]),
                request: request,
                message: arguments)
        }
    }

    func testVisibleEvidenceUsesScalarAndUTF8BoundedCanonicalLines() throws {
        let emojiLine = String(repeating: "😀", count: 513)
        let combiningLine = String(repeating: "e\u{0301}", count: 400)
        let source = "  Total:\t$42  \r\n"
            + emojiLine + "\n" + combiningLine
        let lines = SemanticVisibleEvidence.canonicalLines(from: source)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Total: $42")
        XCTAssertEqual(
            lines[1].unicodeScalars.count,
            SemanticVisibleEvidence.maximumLineUnicodeScalars)
        XCTAssertEqual(
            lines[1].utf8.count,
            SemanticVisibleEvidence.maximumLineUTF8Bytes)
        XCTAssertEqual(
            lines[2].unicodeScalars.count,
            SemanticVisibleEvidence.maximumLineUnicodeScalars)
        XCTAssertLessThanOrEqual(
            lines[2].utf8.count,
            SemanticVisibleEvidence.maximumLineUTF8Bytes)

        let request = OSAtlasSemanticRoutingRequest(
            task: "What exact line is visible?",
            frontmostApplication: "Notes",
            visibleText: source,
            history: [],
            availableDirectives: [.answer])
        XCTAssertEqual(request.visibleText, lines.joined(separator: "\n"))
        XCTAssertEqual(
            try route(
                name: "answer_direct_question_only",
                argumentsJSON: jsonObject(
                    summary: "The emoji line is visible.",
                    evidence: [lines[1]]),
                request: request),
            .init(
                directive: .answer,
                argument: .visibleAnswer(
                    summary: "The emoji line is visible.",
                    evidence: [lines[1]])))
    }

    func testVisibleEvidenceCapsWholeCanonicalLineInventory() {
        let source = (1 ... 80).map { "line-\($0)" }
            .joined(separator: "\n")
        let lines = SemanticVisibleEvidence.canonicalLines(from: source)
        XCTAssertEqual(lines.count, SemanticVisibleEvidence.maximumLines)
        XCTAssertEqual(lines.first, "line-1")
        XCTAssertEqual(lines.last, "line-64")
    }

    func testEvaluatorAbstentionIsOptInValidatedAndMapsToNoRoute() throws {
        let request = productionRequest()
        XCTAssertFalse(SemanticNativeToolWireContract.definitions(
            for: request).map(\.name).contains("abstain"))
        XCTAssertEqual(
            SemanticNativeToolWireContract.definitions(
                for: request,
                includeEvaluatorAbstain: true).last?.name,
            "abstain")

        let message = SemanticNativeToolAssistantMessage(
            content: nil,
            toolCalls: [.init(
                name: "abstain",
                argumentsJSON: #"{"reason_code":"ambiguous_request"}"#)])
        assertRejected(message, request: request)
        do {
            _ = try SemanticNativeToolWireContract.route(
                from: message,
                request: request,
                includeEvaluatorAbstain: true)
            XCTFail("A valid abstention must not become an executable route")
        } catch let error as AppleFoundationVisualActionRouterError {
            XCTAssertEqual(error, .noRoute)
        }

        for arguments in [
            #"{"reason_code":"something_else"}"#,
            #"{"reason_code":"ambiguous_request","extra":true}"#,
            #"{"reason_code":1}"#,
        ] {
            assertRejected(
                .init(content: nil, toolCalls: [
                    .init(name: "abstain", argumentsJSON: arguments),
                ]),
                request: request,
                includeEvaluatorAbstain: true)
        }
    }

    func testAppleFirstRouterFallsBackOnceAfterEveryRecoverableAppleFailure()
        async throws {
        let request = productionRequest()
        let recoverableErrors: [AppleFoundationVisualActionRouterError] = [
            .unavailable(.modelNotReady),
            .noRoute,
            .generationFailed,
        ]
        for expected in recoverableErrors {
            let fallbackCalls = SemanticRouterCallCounter()
            let apple = SemanticRouterStub(
                availability: expected == .unavailable(.modelNotReady)
                    ? .unavailable(.modelNotReady) : .available,
                handler: { _ in throw expected })
            let fallback = SemanticRouterStub(
                availability: .available,
                handler: { _ in
                    await fallbackCalls.record()
                    return .init(directive: .wait)
                })
            let router = AppleFirstSemanticActionRouter(
                fallbackRouter: fallback,
                appleRouter: apple)

            XCTAssertEqual(router.availability(), .available)
            let fallbackRoute = try await router.route(request)
            let fallbackCallCount = await fallbackCalls.value()
            XCTAssertEqual(fallbackRoute, .init(directive: .wait))
            XCTAssertEqual(
                fallbackCallCount,
                1,
                "\(expected) must receive exactly one fallback attempt")
        }

        let fallbackCalls = SemanticRouterCallCounter()
        let fallback = SemanticRouterStub(
            availability: .available,
            handler: { _ in
                await fallbackCalls.record()
                return .init(directive: .wait)
            })
        let deterministicApple = SemanticRouterStub(
            availability: .unavailable(.modelNotReady),
            handler: { _ in
                .init(
                    directive: .openApplication,
                    argument: .applicationName("Notes"))
            })
        let deterministicRouter = AppleFirstSemanticActionRouter(
            fallbackRouter: fallback,
            appleRouter: deterministicApple)
        let deterministicRoute = try await deterministicRouter.route(request)
        XCTAssertEqual(
            deterministicRoute,
            .init(
                directive: .openApplication,
                argument: .applicationName("Notes")))
        let deterministicFallbackCallCount = await fallbackCalls.value()
        XCTAssertEqual(deterministicFallbackCallCount, 0)
    }

    func testAppleFirstRouterPropagatesIntegrityAndCancellationErrors() async {
        let request = productionRequest()
        let fallbackCalls = SemanticRouterCallCounter()
        let fallback = SemanticRouterStub(
            availability: .available,
            handler: { _ in
                await fallbackCalls.record()
                return .init(directive: .wait)
            })
        let errors: [AppleFoundationVisualActionRouterError] = [
            .invalidRequest,
            .multipleRoutes,
            .cancelled,
        ]
        for expected in errors {
            let apple = SemanticRouterStub(
                availability: .available,
                handler: { _ in throw expected })
            let router = AppleFirstSemanticActionRouter(
                fallbackRouter: fallback,
                appleRouter: apple)
            do {
                _ = try await router.route(request)
                XCTFail("\(expected) must not activate fallback")
            } catch let error as AppleFoundationVisualActionRouterError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        let fallbackCallCount = await fallbackCalls.value()
        XCTAssertEqual(
            fallbackCallCount,
            0,
            "Integrity and cancellation failures must never activate fallback")
    }

    func testAppleFirstRouterDoesNotFallbackAfterGenerationFailureWhenCancelled()
        async {
        let request = productionRequest()
        let appleCalls = SemanticRouterCallCounter()
        let fallbackCalls = SemanticRouterCallCounter()
        let apple = SemanticRouterStub(
            availability: .available,
            handler: { _ in
                await appleCalls.record()
                throw AppleFoundationVisualActionRouterError.generationFailed
            })
        let fallback = SemanticRouterStub(
            availability: .available,
            handler: { _ in
                await fallbackCalls.record()
                return .init(directive: .wait)
            })
        let router = AppleFirstSemanticActionRouter(
            fallbackRouter: fallback,
            appleRouter: apple)
        let routeTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await router.route(request)
        }

        do {
            _ = try await routeTask.value
            XCTFail("A pre-cancelled route must not activate fallback")
        } catch let error as AppleFoundationVisualActionRouterError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let appleCallCount = await appleCalls.value()
        let fallbackCallCount = await fallbackCalls.value()
        XCTAssertEqual(appleCallCount, 1)
        XCTAssertEqual(fallbackCallCount, 0)
    }

    private var allProductionDirectives: [OSAtlasExplicitActionDirective] {
        [
            .click, .doubleClick, .rightClick, .drag, .type, .scroll,
            .openApplication, .enter, .hotkey, .wait, .complete, .ask,
            .answer,
        ]
    }

    private func productionRequest() -> OSAtlasSemanticRoutingRequest {
        OSAtlasSemanticRoutingRequest(
            task: "Complete the requested visible operation.",
            frontmostApplication: "Notes",
            visibleText: "Status: Ready\nTotal: $42",
            history: [],
            availableDirectives: allProductionDirectives)
    }

    private func route(
        name: String,
        argumentsJSON: String,
        request: OSAtlasSemanticRoutingRequest
    ) throws -> OSAtlasSemanticActionRoute {
        try SemanticNativeToolWireContract.route(
            from: .init(content: nil, toolCalls: [
                .init(name: name, argumentsJSON: argumentsJSON),
            ]),
            request: request)
    }

    private func assertRejected(
        _ message: SemanticNativeToolAssistantMessage,
        request: OSAtlasSemanticRoutingRequest,
        includeEvaluatorAbstain: Bool = false,
        message failureMessage: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try SemanticNativeToolWireContract.route(
                from: message,
                request: request,
                includeEvaluatorAbstain: includeEvaluatorAbstain)
            XCTFail(
                "Expected strict rejection. \(failureMessage)",
                file: file,
                line: line)
        } catch let error as AppleFoundationVisualActionRouterError {
            XCTAssertEqual(
                error,
                .generationFailed,
                failureMessage,
                file: file,
                line: line)
        } catch {
            XCTFail(
                "Unexpected error: \(error)",
                file: file,
                line: line)
        }
    }

    private func jsonObject(key: String, string: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: [key: string],
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(summary: String, evidence: [String]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["summary": summary, "evidence": evidence],
            options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func maximumStringLength(in value: MCPJSONValue) -> Int {
        switch value {
        case .object(let object):
            let ownMaximum: Int
            if case .integer(let maximum)? = object["maxLength"] {
                ownMaximum = maximum
            } else {
                ownMaximum = 0
            }
            return max(
                ownMaximum,
                object.values.map(maximumStringLength(in:)).max() ?? 0)
        case .array(let array):
            return array.map(maximumStringLength(in:)).max() ?? 0
        default:
            return 0
        }
    }
}

private struct SemanticRouterStub: OSAtlasSemanticActionRouting {
    let reportedAvailability: AppleFoundationMCPPlannerAvailability
    let handler: @Sendable (OSAtlasSemanticRoutingRequest) async throws
        -> OSAtlasSemanticActionRoute

    init(
        availability: AppleFoundationMCPPlannerAvailability,
        handler: @escaping @Sendable (OSAtlasSemanticRoutingRequest) async throws
            -> OSAtlasSemanticActionRoute
    ) {
        reportedAvailability = availability
        self.handler = handler
    }

    func availability() -> AppleFoundationMCPPlannerAvailability {
        reportedAvailability
    }

    func route(
        _ request: OSAtlasSemanticRoutingRequest
    ) async throws -> OSAtlasSemanticActionRoute {
        try await handler(request)
    }
}

private actor SemanticRouterCallCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
