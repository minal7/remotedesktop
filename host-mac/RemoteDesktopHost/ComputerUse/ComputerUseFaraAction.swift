import Foundation

/// Fara's native tool proposal, before any app-owned action admission.
/// Parsing a proposal never dispatches input or verifies task completion.
enum ComputerUseFaraAction: Equatable, Sendable {
    enum ScrollUnits: Equatable, Sendable { case nativeLogicalPoints, normalizedScreenshot }
    enum PointerKind: String, Sendable { case mouseMove = "mouse_move", leftClick = "left_click", rightClick = "right_click", doubleClick = "double_click", tripleClick = "triple_click", drag = "left_click_drag" }
    struct Point: Equatable, Sendable {
        let x: Double
        let y: Double
        func pixel(width: Int, height: Int) throws -> (x: Int, y: Int) {
            guard x.isFinite, y.isFinite, (0...1000).contains(x), (0...1000).contains(y),
                  (1...1_000_000).contains(width), (1...1_000_000).contains(height) else { throw Failure.invalidResponse }
            // 1000 denotes the far edge; select the last cell, never an
            // out-of-image coordinate. Use the current image's actual extent.
            return (min(width - 1, Int(floor(x / 1000 * Double(width)))),
                    min(height - 1, Int(floor(y / 1000 * Double(height)))))
        }
    }
    case pointer(PointerKind, Point)
    case typeText(String)
    case key([String])
    case scroll(horizontal: Bool, pixels: Double)
    /// Located wheel input has an explicit screen point; its amount's units
    /// travel with the provider proposal. The unlocated variant retains browser semantics.
    case scrollAt(horizontal: Bool, pixels: Double, point: Point)
    case visitURL(URL)
    /// A well-formed proposal for a scheme this browser cannot open. It carries
    /// no executable URL; the browser may return bounded tool failure feedback.
    case unsupportedNavigation
    case historyBack
    case webSearch(String)
    case readPageQuestion(String)
    case remember(String)
    case askUser(String)
    /// A typed request against the host-retained, bounded local file catalog.
    /// Candidate IDs are proposals only; the host must revalidate them.
    case localFileOperation(ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation)
    case wait(Double)
    case reportCompletion(String)
    enum Failure: Error, Equatable { case invalidResponse }

    static func decodeNativeMessage(_ content: String) throws -> Self {
        try decodeMessage(content, allowsFractionalLocatedScroll: false)
    }

    /// Fara's screenshot-trained protocol uses normalized viewport units. Keep
    /// this decoder separate so native and other-provider histories stay strict.
    static func decodeFaraNativeMessage(_ content: String) throws -> Self {
        try decodeMessage(content, allowsFractionalLocatedScroll: true)
    }

    private static func decodeMessage(_ content: String, allowsFractionalLocatedScroll: Bool) throws -> Self {
        // The official Fara agent emits narrative followed by one tool call.
        // Use llama.cpp's reasoning_format=none to preserve that wire format;
        // never search the transport's separate reasoning field for actions.
        guard content.utf8.count <= 32_768,
              let start = content.range(of: "<tool_call>") else { throw Failure.invalidResponse }
        let narrative = content[..<start.lowerBound]
        guard !narrative.contains("<tool_call"), !narrative.contains("</tool_call") else { throw Failure.invalidResponse }
        // Decode the complete remainder: extra calls, trailing prose and a
        // truncated call fail the same strict JSON validator. Literal tags
        // inside a JSON text payload remain exact text, not extra actions.
        return try decode(String(content[start.lowerBound...]), allowsFractionalLocatedScroll: allowsFractionalLocatedScroll)
    }

    static func decode(_ content: String) throws -> Self {
        try decode(content, allowsFractionalLocatedScroll: false)
    }

    private static func decode(_ content: String, allowsFractionalLocatedScroll: Bool) throws -> Self {
        do {
            guard content.utf8.count <= 32_768 else { throw Failure.invalidResponse }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "<tool_call>", suffix = "</tool_call>"
            guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { throw Failure.invalidResponse }
            let body = String(text.dropFirst(prefix.count).dropLast(suffix.count))
            var parser = StrictSemanticJSONParser(body)
            guard case .object(let call) = try parser.parse(), Set(call.keys) == ["name", "arguments"],
                  call["name"] == .string("computer_use"), case .object(let args)? = call["arguments"],
                  case .string(let action)? = args["action"] else { throw Failure.invalidResponse }
            func keys(_ fields: String...) throws {
                guard Set(args.keys) == Set(["action"] + fields) else { throw Failure.invalidResponse }
            }
            func string(_ key: String, permitsEmpty: Bool = false) throws -> String {
                guard case .string(let value)? = args[key], permitsEmpty || !value.isEmpty else { throw Failure.invalidResponse }
                return value
            }
            func number(_ value: MCPJSONValue?) throws -> Double {
                let result: Double
                switch value {
                case .integer(let value): result = Double(value)
                case .double(let value): result = value
                default: throw Failure.invalidResponse
                }
                guard result.isFinite else { throw Failure.invalidResponse }
                return result
            }
            if let kind = PointerKind(rawValue: action) {
                try keys("coordinate")
                guard case .array(let coordinate)? = args["coordinate"], coordinate.count == 2 else { throw Failure.invalidResponse }
                let point = try Point(x: number(coordinate[0]), y: number(coordinate[1]))
                guard (0...1000).contains(point.x), (0...1000).contains(point.y) else { throw Failure.invalidResponse }
                return .pointer(kind, point)
            }
            switch action {
            case "type":
                // Fara 1.5 types at the current focus even when it supplies
                // coordinates. Validate that metadata without inventing a click.
                if args["coordinate"] != nil {
                    try keys("text", "coordinate")
                    guard case .array(let coordinate)? = args["coordinate"], coordinate.count == 2 else { throw Failure.invalidResponse }
                    let point = try Point(x: number(coordinate[0]), y: number(coordinate[1]))
                    guard (0...1000).contains(point.x), (0...1000).contains(point.y) else { throw Failure.invalidResponse }
                } else { try keys("text") }
                return try .typeText(string("text", permitsEmpty: true))
            case "key":
                try keys("keys")
                guard case .array(let values)? = args["keys"], (1...8).contains(values.count) else { throw Failure.invalidResponse }
                let names = try values.map { value -> String in
                    guard case .string(let name) = value, !name.isEmpty, name.utf8.count <= 32,
                          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalidResponse }
                    return name
                }
                guard Set(names).count == names.count else { throw Failure.invalidResponse }
                return .key(names)
            case "scroll", "hscroll":
                let pixels = try number(args["pixels"])
                guard abs(pixels) <= 10_000 else { throw Failure.invalidResponse }
                if args["coordinate"] != nil {
                    try keys("pixels", "coordinate")
                    let amount = allowsFractionalLocatedScroll ? pixels.rounded(.towardZero) : pixels
                    guard abs(amount) >= 1, (allowsFractionalLocatedScroll || pixels.rounded() == pixels),
                          case .array(let coordinate)? = args["coordinate"], coordinate.count == 2 else { throw Failure.invalidResponse }
                    let point = try Point(x: number(coordinate[0]), y: number(coordinate[1]))
                    guard (0...1000).contains(point.x), (0...1000).contains(point.y) else { throw Failure.invalidResponse }
                    return .scrollAt(horizontal: action == "hscroll", pixels: amount, point: point)
                }
                try keys("pixels")
                return .scroll(horizontal: action == "hscroll", pixels: pixels)
            case "visit_url":
                try keys("url")
                let source = try string("url")
                guard source.utf8.count <= 8_192,
                      source == source.trimmingCharacters(in: .whitespacesAndNewlines),
                      !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      let parts = URLComponents(string: source), let scheme = parts.scheme,
                      parts.user == nil, parts.password == nil, let url = parts.url else { throw Failure.invalidResponse }
                guard ["http", "https"].contains(scheme.lowercased()) else { return .unsupportedNavigation }
                guard parts.host?.isEmpty == false else { throw Failure.invalidResponse }
                return .visitURL(url)
            case "history_back": try keys(); return .historyBack
            case "web_search": try keys("query"); return try .webSearch(string("query"))
            case "read_page_answer_question": try keys("question"); return try .readPageQuestion(string("question"))
            case "pause_and_memorize_fact": try keys("fact"); return try .remember(string("fact"))
            case "ask_user_question": try keys("question"); return try .askUser(string("question"))
            case "wait":
                try keys("time")
                let seconds = try number(args["time"])
                guard (0...30).contains(seconds) else { throw Failure.invalidResponse }
                return .wait(seconds)
            case "terminate": try keys("answer"); return try .reportCompletion(string("answer"))
            default: throw Failure.invalidResponse
            }
        } catch { throw Failure.invalidResponse }
    }
}
