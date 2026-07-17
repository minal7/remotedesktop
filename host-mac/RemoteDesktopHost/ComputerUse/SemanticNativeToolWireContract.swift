import Foundation

/// Canonical model/evidence view of OCR text. Bounds are expressed in both
/// Unicode scalars and UTF-8 bytes so the line shown to the model is always
/// representable by the strict 512-code-point native-tool evidence schema.
/// Newline and control handling is scalar-defined rather than relying on
/// Swift grapheme-cluster behavior, which can change the effective bound for
/// combining sequences and emoji.
enum SemanticVisibleEvidence {
    static let maximumLines = 64
    static let maximumLineUnicodeScalars = 512
    static let maximumLineUTF8Bytes = maximumLineUnicodeScalars * 4
    static let maximumTotalUnicodeScalars = 6_000
    static let maximumTotalUTF8Bytes = maximumTotalUnicodeScalars * 4
    static let maximumScannedUnicodeScalars = 24_000

    static func canonicalText(from source: String) -> String {
        canonicalLines(from: source).joined(separator: "\n")
    }

    static func canonicalLines(from source: String) -> [String] {
        var result: [String] = []
        var lineScalars: [Unicode.Scalar] = []
        var lineBytes = 0
        var pendingSpace = false
        var scanned = 0
        var totalScalars = 0
        var totalBytes = 0

        func appendPendingSpaceIfPossible() {
            guard pendingSpace, !lineScalars.isEmpty,
                  lineScalars.count < maximumLineUnicodeScalars,
                  lineBytes < maximumLineUTF8Bytes else {
                pendingSpace = false
                return
            }
            lineScalars.append(" ")
            lineBytes += 1
            pendingSpace = false
        }

        func finishLine() -> Bool {
            pendingSpace = false
            guard !lineScalars.isEmpty else { return true }
            let separatorScalars = result.isEmpty ? 0 : 1
            let separatorBytes = separatorScalars
            let remainingScalars = maximumTotalUnicodeScalars
                - totalScalars - separatorScalars
            let remainingBytes = maximumTotalUTF8Bytes
                - totalBytes - separatorBytes
            guard remainingScalars > 0, remainingBytes > 0,
                  result.count < maximumLines else {
                return false
            }

            var accepted: [Unicode.Scalar] = []
            accepted.reserveCapacity(min(lineScalars.count, remainingScalars))
            var acceptedBytes = 0
            for scalar in lineScalars {
                let scalarBytes = String(scalar).utf8.count
                guard accepted.count < remainingScalars,
                      acceptedBytes + scalarBytes <= remainingBytes else {
                    break
                }
                accepted.append(scalar)
                acceptedBytes += scalarBytes
            }
            guard !accepted.isEmpty else { return false }
            result.append(String(String.UnicodeScalarView(accepted)))
            totalScalars += separatorScalars + accepted.count
            totalBytes += separatorBytes + acceptedBytes
            lineScalars.removeAll(keepingCapacity: true)
            lineBytes = 0
            return result.count < maximumLines
                && totalScalars < maximumTotalUnicodeScalars
                && totalBytes < maximumTotalUTF8Bytes
        }

        for scalar in source.unicodeScalars {
            scanned += 1
            guard scanned <= maximumScannedUnicodeScalars else { break }
            if CharacterSet.newlines.contains(scalar) {
                guard finishLine() else { break }
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar) {
                pendingSpace = !lineScalars.isEmpty
                continue
            }
            let scalarBytes = String(scalar).utf8.count
            guard lineScalars.count < maximumLineUnicodeScalars,
                  lineBytes + (pendingSpace ? 1 : 0) + scalarBytes
                    <= maximumLineUTF8Bytes else {
                // The remainder of this overlong source line is intentionally
                // ignored until its newline; it must not become a second line.
                pendingSpace = false
                continue
            }
            appendPendingSpaceIfPossible()
            lineScalars.append(scalar)
            lineBytes += scalarBytes
        }
        _ = finishLine()
        return result
    }
}

/// One model-neutral function definition for the local semantic router.
/// The model can only select a typed, no-effect route. It never receives an
/// executor, input injector, application opener, or MCP client.
struct SemanticNativeToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: MCPJSONValue

    /// OpenAI-compatible local runtimes use this JSON shape for native tools.
    /// Keeping it as `MCPJSONValue` avoids coupling the safety contract to a
    /// particular HTTP client or inference implementation.
    var nativeToolJSON: MCPJSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": inputSchema,
                "strict": .bool(true),
            ]),
        ])
    }
}

/// Raw model-authored arguments deliberately remain JSON text until the
/// strict parser has checked duplicate keys. Decoding directly into a Swift
/// dictionary would silently discard one of two conflicting values.
struct SemanticNativeToolCall: Equatable, Sendable {
    let name: String
    let argumentsJSON: String
}

/// The inference adapter supplies only the assistant message fields relevant
/// to the semantic contract. Reasoning metadata may stay outside this value;
/// ordinary assistant prose is forbidden whenever a tool route is selected.
struct SemanticNativeToolAssistantMessage: Equatable, Sendable {
    let content: String?
    let toolCalls: [SemanticNativeToolCall]

    init(content: String? = nil, toolCalls: [SemanticNativeToolCall]) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

/// Shared native-tool vocabulary and strict output boundary for an
/// open-source semantic router. The host's existing policy, approval,
/// evidence, and execution gates remain authoritative after this parser.
enum SemanticNativeToolWireContract {
    static let maximumArgumentsJSONBytes = 24 * 1_024
    /// Pinned llama.cpp b9992 rejects grammar repetitions as large as 4,096
    /// while initializing a native tool. Long, exact quoted payloads are
    /// handled by the existing deterministic host route; model-authored text
    /// stays within this grammar-safe bound and otherwise fails closed.
    static let maximumModelGeneratedTextCharacters = 512
    static let maximumModelGeneratedTextUTF8Bytes =
        maximumModelGeneratedTextCharacters * 4

    static func isValidModelGeneratedText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= maximumModelGeneratedTextCharacters
            && value.utf8.count <= maximumModelGeneratedTextUTF8Bytes
    }

    /// The reviewed production vocabulary. `abstain` is intentionally absent;
    /// it is an evaluator/runtime diagnostic route and is never offered by
    /// default. The legacy REPORT alias is likewise not a second model choice:
    /// ANSWER is the single canonical visible-facts operation.
    static let canonicalToolNames: [String] = [
        "normal_click",
        "double_click",
        "right_click",
        "drag_item",
        "type_text",
        "scroll_up",
        "scroll_down",
        "scroll_left",
        "scroll_right",
        "open_application",
        "press_enter",
        "keyboard_shortcut",
        "wait_for_screen",
        "complete_task",
        "ask_user",
        "answer_direct_question_only",
    ]

    static let evaluatorAbstainName = "abstain"

    /// Returns only tools authorized for this host-owned request. Every schema
    /// is a closed object (`additionalProperties: false`) with bounded fields.
    static func definitions(
        for request: OSAtlasSemanticRoutingRequest,
        includeEvaluatorAbstain: Bool = false
    ) -> [SemanticNativeToolDefinition] {
        definitions(
            for: request.availableDirectives,
            includeEvaluatorAbstain: includeEvaluatorAbstain)
    }

    static func definitions(
        for offeredDirectives: [OSAtlasExplicitActionDirective],
        includeEvaluatorAbstain: Bool = false
    ) -> [SemanticNativeToolDefinition] {
        let offeredNames = Set(offeredDirectives.flatMap(toolNames(for:)))
        var result = canonicalToolNames.compactMap { name in
            offeredNames.contains(name) ? definition(named: name) : nil
        }
        if includeEvaluatorAbstain,
           let abstain = definition(named: evaluatorAbstainName) {
            result.append(abstain)
        }
        return result
    }

    /// Strictly converts one native call into one existing typed semantic
    /// route. All malformed/integrity failures become `generationFailed`.
    /// A valid, explicitly enabled evaluator abstention becomes `noRoute`.
    static func route(
        from message: SemanticNativeToolAssistantMessage,
        request: OSAtlasSemanticRoutingRequest,
        includeEvaluatorAbstain: Bool = false
    ) throws -> OSAtlasSemanticActionRoute {
        do {
            try validate(request)
            let contentIsEmpty = message.content.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? true
            guard contentIsEmpty,
                  message.toolCalls.count == 1 else {
                throw ValidationError.invalidEnvelope
            }
            let call = message.toolCalls[0]
            let offeredNames = Set(definitions(
                for: request,
                includeEvaluatorAbstain: includeEvaluatorAbstain).map(\.name))
            guard offeredNames.contains(call.name),
                  call.argumentsJSON.utf8.count <= maximumArgumentsJSONBytes else {
                throw ValidationError.unofferedTool
            }
            var parser = StrictSemanticJSONParser(call.argumentsJSON)
            let value = try parser.parse()
            guard case .object(let arguments) = value else {
                throw ValidationError.invalidArguments
            }
            if call.name == evaluatorAbstainName {
                try validateAbstention(arguments)
                throw AppleFoundationVisualActionRouterError.noRoute
            }
            guard let template = routeTemplate(named: call.name) else {
                throw ValidationError.unofferedTool
            }
            return OSAtlasSemanticActionRoute(
                directive: template.directive,
                scrollDirection: template.scrollDirection,
                argument: try typedArgument(
                    for: call.name,
                    arguments: arguments,
                    visibleText: request.visibleText))
        } catch let error as AppleFoundationVisualActionRouterError {
            throw error
        } catch {
            throw AppleFoundationVisualActionRouterError.generationFailed
        }
    }

    /// Stable mapping helper shared by adapters without exposing the private
    /// Apple Foundation Models tool implementation.
    static func toolName(for route: OSAtlasSemanticActionRoute) -> String? {
        if let direction = route.scrollDirection {
            guard route.directive == .scroll else { return nil }
            return "scroll_\(direction.rawValue.lowercased())"
        }
        switch route.directive {
        case .click: return "normal_click"
        case .doubleClick: return "double_click"
        case .rightClick: return "right_click"
        case .drag: return "drag_item"
        case .type: return "type_text"
        case .openApplication: return "open_application"
        case .enter: return "press_enter"
        case .hotkey: return "keyboard_shortcut"
        case .wait: return "wait_for_screen"
        case .complete: return "complete_task"
        case .ask: return "ask_user"
        case .answer: return "answer_direct_question_only"
        case .scroll, .report: return nil
        }
    }

    static func definition(named name: String) -> SemanticNativeToolDefinition? {
        guard name == evaluatorAbstainName || routeTemplate(named: name) != nil,
              let schema = inputSchema(named: name),
              let description = description(named: name) else {
            return nil
        }
        return SemanticNativeToolDefinition(
            name: name,
            description: description,
            inputSchema: schema)
    }

    static func validate(_ request: OSAtlasSemanticRoutingRequest) throws {
        let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty,
              task.utf8.count <= OSAtlasSemanticRoutingRequest.maximumTaskBytes,
              request.conversation.count
                <= OSAtlasSemanticRoutingRequest.maximumConversationEntries,
              request.conversation.allSatisfy({ turn in
                  !turn.text.isEmpty
                    && turn.text.utf8.count
                        <= OSAtlasSemanticRoutingRequest
                            .maximumConversationEntryBytes
              }),
              request.conversation.reduce(0, {
                  $0 + $1.text.utf8.count
              }) <= OSAtlasSemanticRoutingRequest.maximumConversationBytes,
              request.visibleText.unicodeScalars.count
                <= OSAtlasSemanticRoutingRequest.maximumVisibleTextCharacters,
              request.visibleText.utf8.count
                <= OSAtlasSemanticRoutingRequest.maximumVisibleTextBytes,
              request.history.count
                <= OSAtlasSemanticRoutingRequest.maximumHistoryEntries,
              request.history.allSatisfy({
                  $0.utf8.count
                    <= OSAtlasSemanticRoutingRequest.maximumHistoryEntryBytes
                    && $0.rangeOfCharacter(from: .controlCharacters) == nil
                    && $0.rangeOfCharacter(from: .newlines) == nil
              }),
              request.frontmostApplication.map({
                  $0.utf8.count
                    <= OSAtlasSemanticRoutingRequest.maximumApplicationNameBytes
                    && $0.rangeOfCharacter(from: .controlCharacters) == nil
                    && $0.rangeOfCharacter(from: .newlines) == nil
              }) ?? true,
              request.openedApplications.count
                <= OSAtlasSemanticRoutingRequest.maximumOpenedApplicationEntries,
              request.openedApplications.allSatisfy({ value in
                  let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !name.isEmpty
                    && name.utf8.count
                        <= OSAtlasSemanticRoutingRequest
                            .maximumApplicationNameBytes
                    && name.rangeOfCharacter(from: .controlCharacters) == nil
                    && name.rangeOfCharacter(from: .newlines) == nil
              }),
              request.openedApplicationIdentities.count
                <= OSAtlasSemanticRoutingRequest.maximumOpenedApplicationEntries,
              Set(request.openedApplicationIdentities).count
                == request.openedApplicationIdentities.count,
              !request.availableDirectives.isEmpty,
              Set(request.availableDirectives).count
                == request.availableDirectives.count else {
            throw AppleFoundationVisualActionRouterError.invalidRequest
        }
    }

    private static func toolNames(
        for directive: OSAtlasExplicitActionDirective
    ) -> [String] {
        if directive == .scroll {
            return ["scroll_up", "scroll_down", "scroll_left", "scroll_right"]
        }
        let route = OSAtlasSemanticActionRoute(directive: directive)
        return toolName(for: route).map { [$0] } ?? []
    }

    private static func routeTemplate(
        named name: String
    ) -> OSAtlasSemanticActionRoute? {
        switch name {
        case "normal_click": return .init(directive: .click)
        case "double_click": return .init(directive: .doubleClick)
        case "right_click": return .init(directive: .rightClick)
        case "drag_item": return .init(directive: .drag)
        case "type_text": return .init(directive: .type)
        case "scroll_up":
            return .init(directive: .scroll, scrollDirection: .up)
        case "scroll_down":
            return .init(directive: .scroll, scrollDirection: .down)
        case "scroll_left":
            return .init(directive: .scroll, scrollDirection: .left)
        case "scroll_right":
            return .init(directive: .scroll, scrollDirection: .right)
        case "open_application": return .init(directive: .openApplication)
        case "press_enter": return .init(directive: .enter)
        case "keyboard_shortcut": return .init(directive: .hotkey)
        case "wait_for_screen": return .init(directive: .wait)
        case "complete_task": return .init(directive: .complete)
        case "ask_user": return .init(directive: .ask)
        case "answer_direct_question_only": return .init(directive: .answer)
        default: return nil
        }
    }

    private static func inputSchema(named name: String) -> MCPJSONValue? {
        switch name {
        case "normal_click", "double_click", "right_click":
            return closedObject(
                properties: [
                    "target_hint": boundedStringSchema(
                        maximumLength: 256),
                ],
                required: ["target_hint"])
        case "drag_item":
            return closedObject(
                properties: [
                    "item_to_move": boundedStringSchema(
                        maximumLength: 256),
                    "drop_destination": boundedStringSchema(
                        maximumLength: 256),
                ],
                required: ["item_to_move", "drop_destination"])
        case "type_text":
            return closedObject(
                properties: [
                    "text": boundedStringSchema(
                        maximumLength: maximumModelGeneratedTextCharacters),
                ],
                required: ["text"])
        case "open_application":
            return closedObject(
                properties: [
                    "application_name": boundedStringSchema(
                        maximumLength: 120),
                ],
                required: ["application_name"])
        case "keyboard_shortcut":
            return closedObject(
                properties: [
                    "shortcut": boundedStringSchema(
                        maximumLength: 64),
                ],
                required: ["shortcut"])
        case "ask_user":
            return closedObject(
                properties: [
                    "question": boundedStringSchema(
                        maximumLength: maximumModelGeneratedTextCharacters),
                ],
                required: ["question"])
        case "answer_direct_question_only":
            return closedObject(
                properties: [
                    "summary": boundedStringSchema(
                        maximumLength: maximumModelGeneratedTextCharacters),
                    "evidence": .object([
                        "type": .string("array"),
                        "minItems": .integer(1),
                        "maxItems": .integer(6),
                        "uniqueItems": .bool(true),
                        "items": boundedStringSchema(
                            maximumLength: 512),
                    ]),
                ],
                required: ["summary", "evidence"])
        case "scroll_up", "scroll_down", "scroll_left", "scroll_right",
             "press_enter", "wait_for_screen", "complete_task":
            return closedObject(properties: [:], required: [])
        case evaluatorAbstainName:
            return closedObject(
                properties: [
                    "reason_code": .object([
                        "type": .string("string"),
                        "enum": .array(abstainReasonCodes.map(
                            MCPJSONValue.string)),
                    ]),
                ],
                required: ["reason_code"])
        default:
            return nil
        }
    }

    private static func closedObject(
        properties: [String: MCPJSONValue],
        required: [String]
    ) -> MCPJSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array(required.map(MCPJSONValue.string)),
        ])
    }

    private static func boundedStringSchema(
        maximumLength: Int
    ) -> MCPJSONValue {
        .object([
            "type": .string("string"),
            "minLength": .integer(1),
            "maxLength": .integer(maximumLength),
        ])
    }

    private static func typedArgument(
        for name: String,
        arguments: [String: MCPJSONValue],
        visibleText: String
    ) throws -> OSAtlasSemanticActionArgument {
        switch name {
        case "normal_click", "double_click", "right_click":
            try requireExactKeys(["target_hint"], in: arguments)
            return .targetHint(try boundedString(
                named: "target_hint", in: arguments,
                maximumCharacters: 256, maximumBytes: 1_024))
        case "drag_item":
            try requireExactKeys(["item_to_move", "drop_destination"], in: arguments)
            return .dragHints(
                source: try boundedString(
                    named: "item_to_move", in: arguments,
                    maximumCharacters: 256, maximumBytes: 1_024),
                destination: try boundedString(
                    named: "drop_destination", in: arguments,
                    maximumCharacters: 256, maximumBytes: 1_024))
        case "type_text":
            try requireExactKeys(["text"], in: arguments)
            return .text(try boundedString(
                named: "text", in: arguments,
                maximumCharacters: maximumModelGeneratedTextCharacters,
                maximumBytes: maximumModelGeneratedTextUTF8Bytes,
                preserveWhitespace: true))
        case "open_application":
            try requireExactKeys(["application_name"], in: arguments)
            return .applicationName(try boundedString(
                named: "application_name", in: arguments,
                maximumCharacters: 120, maximumBytes: 480))
        case "keyboard_shortcut":
            try requireExactKeys(["shortcut"], in: arguments)
            let value = try boundedString(
                named: "shortcut", in: arguments,
                maximumCharacters: 64, maximumBytes: 256)
            return .hotkey(try normalizedHotkey(value))
        case "ask_user":
            try requireExactKeys(["question"], in: arguments)
            return .question(try boundedString(
                named: "question", in: arguments,
                maximumCharacters: maximumModelGeneratedTextCharacters,
                maximumBytes: maximumModelGeneratedTextUTF8Bytes))
        case "answer_direct_question_only":
            try requireExactKeys(["summary", "evidence"], in: arguments)
            let summary = try boundedString(
                named: "summary", in: arguments,
                maximumCharacters: maximumModelGeneratedTextCharacters,
                maximumBytes: maximumModelGeneratedTextUTF8Bytes)
            guard case .array(let rawEvidence)? = arguments["evidence"],
                  (1 ... 6).contains(rawEvidence.count) else {
                throw ValidationError.invalidArguments
            }
            let exactVisibleLines = Set(
                SemanticVisibleEvidence.canonicalLines(from: visibleText))
            var seen: Set<String> = []
            let evidence = try rawEvidence.map { value -> String in
                guard case .string(let rawValue) = value else {
                    throw ValidationError.invalidArguments
                }
                let item = try boundedString(
                    rawValue,
                    maximumCharacters: 512,
                    maximumBytes: 2_048)
                guard rawValue == item,
                      exactVisibleLines.contains(item),
                      seen.insert(item).inserted else {
                    throw ValidationError.unfaithfulEvidence
                }
                return item
            }
            return .visibleAnswer(summary: summary, evidence: evidence)
        case "scroll_up", "scroll_down", "scroll_left", "scroll_right",
             "press_enter", "wait_for_screen", "complete_task":
            try requireExactKeys([], in: arguments)
            return .none
        default:
            throw ValidationError.invalidArguments
        }
    }

    private static func requireExactKeys(
        _ expected: Set<String>,
        in arguments: [String: MCPJSONValue]
    ) throws {
        guard Set(arguments.keys) == expected else {
            throw ValidationError.invalidArguments
        }
    }

    private static func boundedString(
        named name: String,
        in arguments: [String: MCPJSONValue],
        maximumCharacters: Int,
        maximumBytes: Int,
        preserveWhitespace: Bool = false
    ) throws -> String {
        guard case .string(let value)? = arguments[name] else {
            throw ValidationError.invalidArguments
        }
        return try boundedString(
            value,
            maximumCharacters: maximumCharacters,
            maximumBytes: maximumBytes,
            preserveWhitespace: preserveWhitespace)
    }

    private static func boundedString(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int,
        preserveWhitespace: Bool = false
    ) throws -> String {
        let candidate = preserveWhitespace
            ? value
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.count <= maximumCharacters,
              candidate.utf8.count <= maximumBytes,
              preserveWhitespace || candidate == value else {
            throw ValidationError.invalidArguments
        }
        return candidate
    }

    private static func normalizedHotkey(_ value: String) throws -> String {
        let aliases = [
            "CMD": "COMMAND", "META": "COMMAND", "SUPER": "COMMAND",
            "ALT": "OPTION", "CTRL": "CONTROL", "RETURN": "ENTER",
            "ESC": "ESCAPE",
        ]
        let components = value
            .split(separator: "+", omittingEmptySubsequences: false)
            .map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
            }
            .map { aliases[$0] ?? $0 }
        let modifierNames: Set<String> = [
            "COMMAND", "OPTION", "CONTROL", "SHIFT",
        ]
        let namedKeys: Set<String> = [
            "ENTER", "ESCAPE", "BACKSPACE", "TAB", "SPACE", "DELETE",
            "RIGHT", "LEFT", "DOWN", "UP", "HOME", "PAGE_UP", "END",
            "PAGE_DOWN", "F1", "F2", "F3", "F4", "F5", "F6", "F7",
            "F8", "F9", "F10", "F11", "F12",
        ]
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError.invalidHotkey
        }
        let modifiers = components.filter(modifierNames.contains)
        let keys = components.filter { !modifierNames.contains($0) }
        let isSingleHIDCharacter = keys.first.map { key in
            guard key.utf8.count == 1, let byte = key.utf8.first else {
                return false
            }
            return (65 ... 90).contains(byte) || (48 ... 57).contains(byte)
        } ?? false
        guard !modifiers.isEmpty,
              Set(modifiers).count == modifiers.count,
              keys.count == 1,
              isSingleHIDCharacter || namedKeys.contains(keys[0]) else {
            throw ValidationError.invalidHotkey
        }
        return (modifiers + keys).joined(separator: "+")
    }

    private static let abstainReasonCodes = [
        "unsupported_request",
        "no_offered_route",
        "ambiguous_request",
        "unsafe_or_injected",
    ]
    private static let abstainReasonCodeSet = Set(abstainReasonCodes)

    private static func validateAbstention(
        _ arguments: [String: MCPJSONValue]
    ) throws {
        try requireExactKeys(["reason_code"], in: arguments)
        guard case .string(let reason)? = arguments["reason_code"],
              abstainReasonCodeSet.contains(reason) else {
            throw ValidationError.invalidArguments
        }
    }

    private static func description(named name: String) -> String? {
        switch name {
        case "normal_click":
            return "Primary-click one visible ordinary control or labeled target."
        case "double_click":
            return "Open a visible Finder/Desktop file, folder, or similar item."
        case "right_click":
            return "Open the context menu for one visible item."
        case "drag_item":
            return "Move one visible named item to one visible named destination."
        case "type_text":
            return "Type the exact user-requested text at an already-focused insertion point."
        case "scroll_up":
            return "Reveal earlier content clipped above the current viewport."
        case "scroll_down":
            return "Reveal later content clipped below the current viewport."
        case "scroll_left":
            return "Reveal content clipped off the left edge of the viewport."
        case "scroll_right":
            return "Reveal content clipped off the right edge of the viewport."
        case "open_application":
            return "Open/foreground the task app when it is not currently frontmost."
        case "press_enter":
            return "Press Return for content already typed in the focused field."
        case "keyboard_shortcut":
            return "Use one keyboard shortcut on focused or selected content."
        case "wait_for_screen":
            return "Wait without input because the visible screen is loading or updating."
        case "complete_task":
            return "Finish without input because the requested end state is visibly satisfied."
        case "ask_user":
            return "Ask one question for information required to proceed but not provided."
        case "answer_direct_question_only":
            return "Answer a direct factual question using only complete, exact visible evidence lines."
        case evaluatorAbstainName:
            return "Evaluator-only: no offered production route can safely and unambiguously represent the next step. This tool is never executable."
        default:
            return nil
        }
    }

    private enum ValidationError: Error {
        case invalidEnvelope
        case unofferedTool
        case invalidArguments
        case invalidHotkey
        case unfaithfulEvidence
    }
}

/// Runs the Apple router first so its deterministic host routes remain usable
/// even when Apple Intelligence reports unavailable. The fallback is invoked
/// only when Apple routing itself throws `.unavailable`; malformed output,
/// multiple/no routes, generation failures, and cancellation are propagated.
struct AppleFirstSemanticActionRouter: OSAtlasSemanticActionRouting {
    private let appleRouter: any OSAtlasSemanticActionRouting
    private let fallbackRouter: any OSAtlasSemanticActionRouting

    init(
        fallbackRouter: any OSAtlasSemanticActionRouting,
        appleRouter: any OSAtlasSemanticActionRouting =
            AppleFoundationVisualActionRouter()
    ) {
        self.appleRouter = appleRouter
        self.fallbackRouter = fallbackRouter
    }

    func availability() -> AppleFoundationMCPPlannerAvailability {
        switch appleRouter.availability() {
        case .available:
            return .available
        case .unavailable:
            return fallbackRouter.availability()
        }
    }

    func route(
        _ request: OSAtlasSemanticRoutingRequest
    ) async throws -> OSAtlasSemanticActionRoute {
        do {
            return try await appleRouter.route(request)
        } catch let error as AppleFoundationVisualActionRouterError {
            guard case .unavailable = error else {
                throw error
            }
        }
        guard !Task.isCancelled else {
            throw AppleFoundationVisualActionRouterError.cancelled
        }
        return try await fallbackRouter.route(request)
    }
}

/// Small strict JSON parser used solely for model-authored native-tool
/// arguments. It rejects duplicate keys at every object depth before any
/// dictionary exists, enforces one complete JSON value, and bounds nesting.
struct StrictSemanticJSONParser {
    static let maximumNestingDepth = 12
    static let defaultMaximumValueCount = 256

    private let bytes: [UInt8]
    private let maximumValueCount: Int
    private var index = 0
    private var valueCount = 0

    init(
        _ source: String,
        maximumValueCount: Int = Self.defaultMaximumValueCount
    ) {
        bytes = Array(source.utf8)
        self.maximumValueCount = max(1, maximumValueCount)
    }

    mutating func parse() throws -> MCPJSONValue {
        skipWhitespace()
        let result = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw ParserError.invalidJSON }
        return result
    }

    private mutating func parseValue(depth: Int) throws -> MCPJSONValue {
        guard depth <= Self.maximumNestingDepth, index < bytes.count else {
            throw ParserError.invalidJSON
        }
        valueCount += 1
        guard valueCount <= maximumValueCount else {
            throw ParserError.invalidJSON
        }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth + 1) // {
        case 0x5B: return try parseArray(depth: depth + 1)  // [
        case 0x22: return .string(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .bool(true)
        case 0x66:
            try consumeLiteral("false")
            return .bool(false)
        case 0x6E:
            try consumeLiteral("null")
            return .null
        case 0x2D, 0x30 ... 0x39:
            return try parseNumber()
        default:
            throw ParserError.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int) throws -> MCPJSONValue {
        index += 1
        skipWhitespace()
        var result: [String: MCPJSONValue] = [:]
        var keys: Set<String> = []
        if consume(0x7D) { return .object(result) }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ParserError.invalidJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw ParserError.duplicateKey
            }
            skipWhitespace()
            guard consume(0x3A) else { throw ParserError.invalidJSON } // :
            skipWhitespace()
            result[key] = try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return .object(result) }
            guard consume(0x2C) else { throw ParserError.invalidJSON } // ,
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> MCPJSONValue {
        index += 1
        skipWhitespace()
        var result: [MCPJSONValue] = []
        if consume(0x5D) { return .array(result) }
        while true {
            result.append(try parseValue(depth: depth))
            skipWhitespace()
            if consume(0x5D) { return .array(result) }
            guard consume(0x2C) else { throw ParserError.invalidJSON }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw ParserError.invalidJSON }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if byte == 0x5C { // backslash
                escaped = true
                index += 1
                continue
            }
            guard byte >= 0x20 else { throw ParserError.invalidJSON }
            index += 1
            if byte == 0x22 {
                let data = Data(bytes[start ..< index])
                guard let value = try? JSONDecoder().decode(
                    String.self, from: data) else {
                    throw ParserError.invalidJSON
                }
                return value
            }
        }
        throw ParserError.invalidJSON
    }

    private mutating func parseNumber() throws -> MCPJSONValue {
        let start = index
        _ = consume(0x2D)
        guard index < bytes.count else { throw ParserError.invalidJSON }
        if consume(0x30) {
            if index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                throw ParserError.invalidJSON
            }
        } else {
            guard consumeDigit(range: 0x31 ... 0x39) else {
                throw ParserError.invalidJSON
            }
            while consumeDigit(range: 0x30 ... 0x39) {}
        }
        var isInteger = true
        if consume(0x2E) {
            isInteger = false
            guard consumeDigit(range: 0x30 ... 0x39) else {
                throw ParserError.invalidJSON
            }
            while consumeDigit(range: 0x30 ... 0x39) {}
        }
        if consume(0x65) || consume(0x45) {
            isInteger = false
            _ = consume(0x2B) || consume(0x2D)
            guard consumeDigit(range: 0x30 ... 0x39) else {
                throw ParserError.invalidJSON
            }
            while consumeDigit(range: 0x30 ... 0x39) {}
        }
        guard let raw = String(bytes: bytes[start ..< index], encoding: .utf8) else {
            throw ParserError.invalidJSON
        }
        if isInteger, let value = Int(raw) { return .integer(value) }
        guard let value = Double(raw), value.isFinite else {
            throw ParserError.invalidJSON
        }
        return .double(value)
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes[index...].starts(with: expected) else {
            throw ParserError.invalidJSON
        }
        index += expected.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(
        range: ClosedRange<UInt8>
    ) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private enum ParserError: Error {
        case invalidJSON
        case duplicateKey
    }
}
