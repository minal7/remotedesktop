import Foundation

/// How one computer-use-trained model expects to be spoken to. These models learned
/// a specific prompt, tool schema, coordinate grid and history shape, and they degrade
/// quickly outside it, so each dialect stays as close to its published form as possible.
public struct CUADialect: Sendable {
    public enum Frame: String, Sendable {
        /// The frontmost window. Closest to what a browser agent trained on.
        case window
        /// The display showing only the target app. A desktop agent sees the screen shape
        /// and scale it trained on without seeing other windows, or clicking them.
        case focus
        /// The whole display. Closest to what a desktop agent trained on, but it shows the
        /// model unrelated windows and lets it click them, so it is for isolated test machines.
        case display
    }

    public var name: String
    public var systemPrompt: String
    /// Screenshots kept in the conversation, the current one included.
    public var screenshotsKept: Int
    public var imageMaxSide: Int
    /// The model's coordinates run from 0 to this value on both axes.
    public var gridMax: Double
    public var frame: Frame
    public var maxTokens: Int
    public var temperature: Double
    public var serverArguments: [String]
    public var templateOptions: [String: Bool]
    /// Text carrying the instruction and older actions, placed in the first user turn.
    public var instructionText: @Sendable (_ instruction: String, _ previousActions: [String]) -> String

    public static func named(_ name: String) -> CUADialect? {
        switch name.lowercased() {
        case "fara", "fara15": return .fara
        case "evocua", "evocua-s2": return .evoCUA
        default: return nil
        }
    }

    /// Microsoft's published browser agent format. Trained at 1440x900, keeping the
    /// last 3 screenshots.
    public static let fara = CUADialect(
        name: "fara", systemPrompt: faraSystemPrompt, screenshotsKept: 3, imageMaxSide: 1_440, gridMax: 1_000, frame: .window,
        maxTokens: 800, temperature: 0, serverArguments: ["--reasoning-format", "none"], templateOptions: ["enable_thinking": true],
        instructionText: { instruction, previous in
            guard !previous.isEmpty else { return instruction }
            return instruction + "\n\nActions already taken:\n" + previous.joined(separator: "\n")
        })

    /// Meituan's EvoCUA "S2" format, trained on full desktop tasks. The published
    /// runner keeps 4 past turns and reads coordinates on a 0...999 grid.
    public static let evoCUA = CUADialect(
        name: "evocua", systemPrompt: evoSystemPrompt, screenshotsKept: 5, imageMaxSide: 1_440, gridMax: 999, frame: .focus,
        maxTokens: 500, temperature: 0.01, serverArguments: ["--reasoning-format", "none"], templateOptions: [:],
        instructionText: { instruction, previous in
            let actions = previous.isEmpty ? "None" : previous.joined(separator: "\n")
            return "\nPlease generate the next move according to the UI screenshot, instruction and previous actions.\n\nInstruction: \(instruction)\n\nPrevious actions:\n\(actions)"
        })

    // MARK: Reading replies

    public struct Reply: Sendable, Equatable {
        public var thought: String
        public var call: ToolCall?
        /// The model says it has finished, and whether it thinks that went well.
        public var terminated: (success: Bool, answer: String)?
        public var problem: String?
        /// Keys to hold down for the clicks that follow. Empty lets go of them.
        public var hold: [String]? = nil
        /// A sum the model asked for, worked out here because these models add badly.
        public var calculated: String? = nil

        public static func == (a: Reply, b: Reply) -> Bool {
            a.thought == b.thought && a.call == b.call && a.problem == b.problem && a.hold == b.hold && a.calculated == b.calculated
                && a.terminated?.success == b.terminated?.success && a.terminated?.answer == b.terminated?.answer
        }
    }

    /// Reads one native reply. `pointer` is the last pointer position on the 0...1000
    /// grid, because these models name only where a drag ends.
    public func parse(_ raw: String, pointer: (x: Double, y: Double)?) -> Reply {
        let thought = Self.thought(in: raw)
        guard let json = Self.toolCallJSON(in: raw),
              let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return Reply(thought: thought, call: nil, terminated: nil, problem: "Reply with one <tool_call> block.")
        }
        guard let arguments = (root["arguments"] as? [String: Any]) ?? (root["parameters"] as? [String: Any]),
              let action = arguments["action"] as? String else {
            return Reply(thought: thought, call: nil, terminated: nil, problem: "The tool call needs an action.")
        }
        func point() -> (x: Double, y: Double)? {
            guard let values = arguments["coordinate"] as? [Any], values.count >= 2,
                  let x = Self.number(values[0]), let y = Self.number(values[1]), x >= 0, y >= 0 else { return nil }
            return (min(1_000, x * 1_000 / gridMax), min(1_000, y * 1_000 / gridMax))
        }
        func problem(_ text: String) -> Reply { Reply(thought: thought, call: nil, terminated: nil, problem: text) }
        func pointerCall(right: Bool, count: Int) -> Reply {
            guard let at = point() else { return problem("\(action) needs a coordinate.") }
            return Reply(thought: thought, call: .pointAt(x: at.x, y: at.y, right: right, count: count), terminated: nil, problem: nil)
        }
        func call(_ call: ToolCall) -> Reply { Reply(thought: thought, call: call, terminated: nil, problem: nil) }

        switch action {
        case "left_click": return pointerCall(right: false, count: 1)
        case "double_click": return pointerCall(right: false, count: 2)
        case "triple_click": return pointerCall(right: false, count: 3)
        case "right_click": return pointerCall(right: true, count: 1)
        case "middle_click": return pointerCall(right: false, count: 1)
        case "mouse_move":
            guard let at = point() else { return problem("mouse_move needs a coordinate.") }
            return call(.moveTo(x: at.x, y: at.y))
        case "left_click_drag":
            guard let to = point() else { return problem("left_click_drag needs a coordinate.") }
            guard let from = pointer else { return problem("Move the pointer to the start of the drag first.") }
            return call(.dragAt(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y))
        case "type":
            guard let text = arguments["text"] as? String, !text.isEmpty else { return problem("type needs text.") }
            return call(.typeAtFocus(text))
        case "key":
            let keys = (arguments["keys"] as? [Any])?.compactMap { $0 as? String }
                ?? (arguments["keys"] as? String).map { [$0] } ?? []
            if !keys.isEmpty, keys.allSatisfy(Self.isModifier) { return Reply(thought: thought, call: nil, terminated: nil, problem: nil, hold: keys) }
            guard let chord = Self.macChord(keys) else { return problem(Self.keyProblem(keys)) }
            return call(.key(chord))
        case "scroll", "hscroll":
            guard let pixels = Self.number(arguments["pixels"] ?? 0), pixels != 0 else { return problem("scroll needs pixels.") }
            let at = point()
            return call(.scrollBy(pixels: pixels, horizontal: action == "hscroll", x: at?.x, y: at?.y))
        case "wait":
            return call(.wait(min(10, max(0.5, Self.number(arguments["time"] ?? 1) ?? 1))))
        case "visit_url":
            guard let url = arguments["url"] as? String else { return problem("visit_url needs a url.") }
            return call(.openURL(url))
        case "history_back":
            return call(.key("cmd+["))
        case "web_search":
            guard let query = arguments["query"] as? String,
                  let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return problem("web_search needs a query.") }
            return call(.openURL("https://duckduckgo.com/?q=\(encoded)"))
        case "read_page_answer_question":
            guard let question = arguments["question"] as? String else { return problem("Ask a question.") }
            return call(.read(question))
        case "pause_and_memorize_fact":
            guard let fact = arguments["fact"] as? String else { return problem("Give the fact to remember.") }
            return call(.note(fact))
        case "calculate":
            guard let sum = arguments["text"] as? String, let value = Arithmetic.evaluate(sum) else { return problem("Write the sum like 12.50+3.20.") }
            return Reply(thought: thought, call: nil, terminated: nil, problem: nil, calculated: "\(sum) = \(value)")
        case "ask_user_question":
            guard let question = arguments["question"] as? String else { return problem("Ask a question.") }
            return call(.askUser(question: question, choices: []))
        case "terminate":
            let status = (arguments["status"] as? String)?.lowercased()
            let answer = (arguments["answer"] as? String) ?? (arguments["text"] as? String) ?? ""
            return Reply(thought: thought, call: nil, terminated: (status != "failure", Self.cleanAnswer(answer)), problem: nil)
        case "answer":
            return Reply(thought: thought, call: nil, terminated: (true, Self.cleanAnswer((arguments["text"] as? String) ?? "")), problem: nil)
        case "key_down":
            // A modifier is held for the clicks that follow. Anything else is meant as a plain press.
            let keys = (arguments["keys"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !keys.isEmpty, keys.allSatisfy(Self.isModifier) { return Reply(thought: thought, call: nil, terminated: nil, problem: nil, hold: keys) }
            guard let chord = Self.macChord(keys) else { return problem(Self.keyProblem(keys)) }
            return call(.key(chord))
        case "key_up":
            return Reply(thought: thought, call: nil, terminated: nil, problem: nil, hold: [])
        case "menu":
            guard let path = ((arguments["text"] ?? arguments["path"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return problem("menu needs text with the menu and item, like File > Save.")
            }
            return call(.menu(path))
        case "open_app":
            guard let name = ((arguments["text"] ?? arguments["app"] ?? arguments["name"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return problem("open_app needs text with the app's name.")
            }
            return call(.openApp(name))
        default:
            return problem("\(action) isn't an available action.")
        }
    }

    static func isModifier(_ key: String) -> Bool {
        ["ctrl", "control", "alt", "option", "opt", "cmd", "command", "meta", "super", "win", "shift", "fn"].contains(key.lowercased())
    }

    static let howToChangeApp = "To change app, call the computer tool with action \"open_app\" and text set to the app's name."

    private static func keyProblem(_ keys: [String]) -> String {
        if keys.count > 1, keys.last?.lowercased() == "tab" { return howToChangeApp }
        if let last = keys.last, isModifier(last) { return "\(last) alone does nothing. Press a whole shortcut, or click what you want." }
        return "That key isn't available on this computer."
    }

    /// Some models wrap a final answer in math markup.
    static func cleanAnswer(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\boxed{"), trimmed.hasSuffix("}") else { return trimmed }
        return String(trimmed.dropFirst(7).dropLast()).trimmingCharacters(in: .whitespaces)
    }

    static func number(_ value: Any) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// The text before the tool call, minus any markup. Shown to the person watching.
    static func thought(in raw: String) -> String {
        var text = raw
        if let call = text.range(of: "<tool_call>") { text = String(text[..<call.lowerBound]) }
        // A dialect's one-line "Action:" says plainly what's happening; prefer it.
        if let line = text.components(separatedBy: .newlines).last(where: { $0.lowercased().hasPrefix("action:") }) {
            return String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        for tag in ["<think>", "</think>"] { text = text.replacingOccurrences(of: tag, with: "") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(400))
    }

    /// Forgiving about a missing closing tag, since replies can run out of tokens there.
    static func toolCallJSON(in raw: String) -> String? {
        var body: Substring
        if let open = raw.range(of: "<tool_call>") {
            body = raw[open.upperBound...]
            if let close = body.range(of: "</tool_call>") { body = body[..<close.lowerBound] }
        } else if let brace = raw.range(of: "{\"name\"") {
            body = raw[brace.lowerBound...]
        } else {
            return nil
        }
        guard let first = body.firstIndex(of: "{"), let last = body.lastIndex(of: "}") else { return nil }
        return String(body[first...last])
    }

    /// These models learned Windows and Linux keyboards. The same shortcuts on a Mac
    /// use Command, and a few have no one-to-one key.
    static func macChord(_ keys: [String]) -> String? {
        var parts = keys.flatMap { $0.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        let names = ["arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down", "esc": "escape",
                     "enter": "return", "backspace": "delete", "del": "forwarddelete", "page_down": "pagedown", "page_up": "pageup"]
        let key = names[last] ?? last
        let modifiers = Set(parts)
        let control = modifiers.contains("ctrl") || modifiers.contains("control")
        let option = modifiers.contains("alt") || modifiers.contains("option") || modifiers.contains("opt")
        let command = modifiers.contains("cmd") || modifiers.contains("command") || modifiers.contains("meta") || modifiers.contains("super") || modifiers.contains("win")
        let shift = modifiers.contains("shift")
        // Switching apps belongs to whoever decides what to work on, not the worker.
        if (option || command), key == "tab" { return nil }
        if option, modifiers.count == 1, key == "left" { return "cmd+[" }
        if option, modifiers.count == 1, key == "right" { return "cmd+]" }
        if modifiers.isEmpty, key == "home" { return "cmd+left" }
        if modifiers.isEmpty, key == "end" { return "cmd+right" }
        if control, modifiers.count == 1, key == "home" { return "cmd+up" }
        if control, modifiers.count == 1, key == "end" { return "cmd+down" }
        var chord: [String] = []
        if control || command { chord.append("cmd") }
        if option { chord.append("opt") }
        if shift { chord.append("shift") }
        chord.append(key)
        let text = chord.joined(separator: "+")
        return (try? KeyMap.parse(text)) == nil ? nil : text
    }

    // MARK: Published prompts

    private static let evoDescription = """
    Use a mouse and keyboard to interact with a computer, and take screenshots.
    * This is an interface to a desktop GUI. You must click on desktop icons to start applications.
    * Some applications may take time to start or process actions, so you may need to wait and take successive screenshots to see the results of your actions. E.g. if you click on Firefox and a window doesn't open, try wait and taking another screenshot.
    * The screen's resolution is 1000x1000.
    * Whenever you intend to move the cursor to click on an element like an icon, you should consult a screenshot to determine the coordinates of the element before moving the cursor.
    * If you tried clicking on a program or link but it failed to load even after waiting, try adjusting your cursor position so that the tip of the cursor visually falls on the element that you want to click.
    * Make sure to click any buttons, links, icons, etc with the cursor tip in the center of the element. Don't click boxes on their edges unless asked.
    """

    private static let evoActions = """
    * `key`: Performs key down presses on the arguments passed in order, then performs key releases in reverse order.
    * `key_down`: Press and HOLD the specified key(s) down in order (no release). Use this for stateful holds like holding Shift while clicking.
    * `key_up`: Release the specified key(s) in reverse order.
    * `type`: Type a string of text on the keyboard.
    * `mouse_move`: Move the cursor to a specified (x, y) pixel coordinate on the screen.
    * `left_click`: Click the left mouse button at a specified (x, y) pixel coordinate on the screen.
    * `left_click_drag`: Click and drag the cursor to a specified (x, y) pixel coordinate on the screen.
    * `right_click`: Click the right mouse button at a specified (x, y) pixel coordinate on the screen.
    * `middle_click`: Click the middle mouse button at a specified (x, y) pixel coordinate on the screen.
    * `double_click`: Double-click the left mouse button at a specified (x, y) pixel coordinate on the screen.
    * `triple_click`: Triple-click the left mouse button at a specified (x, y) pixel coordinate on the screen.
    * `scroll`: Performs a scroll of the mouse scroll wheel.
    * `hscroll`: Performs a horizontal scroll (mapped to regular scroll).
    * `wait`: Wait specified seconds for the change to happen.
    * `terminate`: Terminate the current task and report its completion status.
    * `answer`: Answer a question.
    """

    private static var evoToolJSON: String {
        let tool: [String: Any] = ["type": "function", "function": [
            "name_for_human": "computer_use", "name": "computer_use", "description": evoDescription,
            "parameters": ["properties": [
                "action": ["description": evoActions, "type": "string",
                           "enum": ["key", "type", "mouse_move", "left_click", "left_click_drag", "right_click", "middle_click", "double_click", "triple_click", "scroll", "wait", "terminate", "key_down", "key_up"]],
                "keys": ["description": "Required only by `action=key`.", "type": "array"],
                "text": ["description": "Required only by `action=type`.", "type": "string"],
                "coordinate": ["description": "The x,y coordinates for mouse actions.", "type": "array"],
                "pixels": ["description": "The amount of scrolling.", "type": "number"],
                "time": ["description": "The seconds to wait.", "type": "number"],
                "status": ["description": "The status of the task.", "type": "string", "enum": ["success", "failure"]],
            ] as [String: Any], "required": ["action"], "type": "object"] as [String: Any],
            "args_format": "Format the arguments as a JSON object.",
        ] as [String: Any]]
        let data = (try? JSONSerialization.data(withJSONObject: tool, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static var evoSystemPrompt: String {
        """
        # Tools

        You may call one or more functions to assist with the user query.

        You are provided with function signatures within <tools></tools> XML tags:
        <tools>
        \(evoToolJSON)
        </tools>

        For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
        <tool_call>
        {"name": <function-name>, "arguments": <args-json-object>}
        </tool_call>

        # Response format

        Response format for every step:
        1) Action: a short imperative describing what to do in the UI.
        2) A single <tool_call>...</tool_call> block containing only the JSON: {"name": <function-name>, "arguments": <args-json-object>}.

        Rules:
        - Output exactly in the order: Action, <tool_call>.
        - Be brief: one sentence for Action.
        - Do not output anything else outside those parts.
        - If finishing, use action=terminate in the tool call.
        """
    }

    static let faraSystemPrompt = #"""
    You are Fara, a computer use agent (CUA) specialized for web browsers. You are developed by Microsoft AI Frontiers. You assist users with completing and automating tasks that require the use of a web browser.

    The model was trained in the timeframe of January - April 2026. You can effectively perform tasks even beyond this range by accessing the web browser and using the latest information on the live web. But your knowledge cutoff is limited to early 2026, so you may not be aware of events or developments that occurred after that time, without explicitly browsing and searching for latest information on the web.

    A critical point is a situation where we must pause and request information or confirmation from the user before proceeding. There are three types:

    Case 1: Missing User Information — The task requires personal information that the user has not provided (e.g., email, phone number, address, payment details). Never fabricate or assume personal information. Fill in only what the user has explicitly provided, then pause and ask for any missing required fields. (e.g., form requires phone number but user only gave name and email -> fill name and email, then ask for phone number.) If the user has provided all required information, proceed without stopping.

    Case 2: Underspecified Task — The task description is ambiguous or missing details needed to make a decision at the current step. Pause and ask for clarification. (e.g., user asks to book a flight but doesn't specify destination -> ask for destination.) If the user's instructions contain all information needed for the current decision, proceed without stopping.

    Case 3: Irreversible Action — We are about to perform an action that cannot be undone (e.g., submitting a form, completing a purchase, sending a message, deleting data). If the user explicitly authorized the action (e.g., "submit the form", "complete the purchase", "you have my permission to submit") -> proceed without stopping. If the user did NOT explicitly authorize the action -> stop and ask for confirmation. (e.g., "fill out a form" with no mention of submitting -> fill the form, then ask before submitting; "fill out and submit a form" -> fill and submit without stopping.)

    Case 4: Human Check — A page, in any language, asks you to prove you are human or a website has blocked automated visitors (a CAPTCHA, an "I am not a robot" box, a verification page). Never solve it, and never try to get around it through other addresses of that site. Ask the user to complete it on the live view, using ask_user_question, then carry on when they say so.

    Only stop at a critical point if (1) required information is missing, (2) the task is ambiguous, (3) an irreversible action lacks explicit user authorization, OR (4) a human check is in the way. If the user has provided all necessary information AND explicitly authorized the action, proceed without interruption.

    You are provided with function signatures within <tools></tools> XML tags:
    <tools>
    {"type": "function", "function": {"name": "computer_use", "description": "Use a mouse and keyboard to interact with a computer, and take screenshots.\n* This is an interface to a desktop GUI. You do not have access to a terminal or applications menu. You must click on desktop icons to start applications.\n* Some applications may take time to start or process actions, so you may need to wait and take successive screenshots to see the results of your actions. E.g. if you click on Firefox and a window doesn't open, try wait and taking another screenshot.\n* The screen's resolution is 1000x1000.\n* Whenever you intend to move the cursor to click on an element like an icon, you should consult a screenshot to determine the coordinates of the element before moving the cursor.\n* If you tried clicking on a program or link but it failed to load, even after waiting, try adjusting your cursor position so that the tip of the cursor visually falls on the element that you want to click.\n* Make sure to click any buttons, links, icons, etc with the cursor tip in the center of the element. Don't click boxes on their edges.", "parameters": {"properties": {"action": {"description": "The action to perform. The available actions are:\n* `key`: Performs key down presses on the arguments passed in order, then performs key releases in reverse order. Includes \"Enter\", \"Alt\", \"Shift\", \"Tab\", \"Control\", \"Backspace\", \"Delete\", \"Escape\", \"ArrowUp\", \"ArrowDown\", \"ArrowLeft\", \"ArrowRight\", \"PageDown\", \"PageUp\", \"Shift\", etc.\n* `type`: Type a string of text on the keyboard.\n* `mouse_move`: Move the cursor to a specified (x, y) pixel coordinate on the screen.\n* `left_click`: Click the left mouse button.\n* `double_click`: Double-click the left mouse button.\n* `right_click`: Click the right mouse button.\n* `triple_click`: Triple-click the left mouse button (e.g. to select a line of text).\n* `left_click_drag`: Click and drag the cursor to a specified (x, y) pixel coordinate on the screen.\n* `scroll`: Performs a scroll of the mouse scroll wheel.\n* `hscroll`: Performs a horizontal scroll (mapped to regular scroll).\n* `visit_url`: Visit a specified URL.\n* `history_back`: Go back to the previous page in the browser history.\n* `web_search`: Perform a web search with a specified query.\n* `read_page_answer_question`: Read the current page content and answer a question about it.\n* `pause_and_memorize_fact`: Pause and memorize a fact for future reference.\n* `ask_user_question`: Ask the user a clarifying question and wait for a response.\n* `wait`: Wait specified seconds for the change to happen.\n* `terminate`: Terminate the current task and provide the final answer.", "enum": ["key", "type", "mouse_move", "left_click", "left_click_drag", "right_click", "double_click", "triple_click", "scroll", "hscroll", "visit_url", "history_back", "web_search", "read_page_answer_question", "pause_and_memorize_fact", "ask_user_question", "wait", "terminate"], "type": "string"}, "keys": {"description": "Required only by `action=key`.", "type": "array"}, "text": {"description": "Required only by `action=type`.", "type": "string"}, "coordinate": {"description": "(x, y): The x (pixels from the left edge) and y (pixels from the top edge) coordinates to move the mouse to. Required by `action=left_click`, `action=double_click`, `action=right_click`, `action=triple_click`, `action=left_click_drag`, and `action=mouse_move`.", "type": "array"}, "pixels": {"description": "The amount of scrolling to perform. Positive values scroll up, negative values scroll down. Required only by `action=scroll` and `action=hscroll`.", "type": "number"}, "url": {"description": "The URL to visit. Required only by `action=visit_url`.", "type": "string"}, "query": {"description": "The query to search for. Required only by `action=web_search`.", "type": "string"}, "fact": {"description": "The fact to remember for the future. Required only by `action=pause_and_memorize_fact`.", "type": "string"}, "question": {"description": "The question to ask. Required by `action=read_page_answer_question` and `action=ask_user_question`.", "type": "string"}, "time": {"description": "The seconds to wait. Required only by `action=wait`.", "type": "number"}, "answer": {"description": "The final answer for the task. Required only by `action=terminate`.", "type": "string"}}, "required": ["action"], "type": "object"}}}
    </tools>

    For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
    <tool_call>
    {"name": <function-name>, "arguments": <args-json-object>}
    </tool_call>
    """#
}

/// Sums with + - * / and brackets, for a model to check its adding up. Text that isn't a sum gives nil.
public enum Arithmetic {
    public static func evaluate(_ text: String) -> String? {
        let cleaned = text.filter { !" $€£,\n".contains($0) }
        guard !cleaned.isEmpty, cleaned.count <= 200 else { return nil }
        var parser = Parser(characters: Array(cleaned))
        guard let value = parser.sum(depth: 0), parser.position == parser.characters.count else { return nil }
        let number = NSDecimalNumber(decimal: value)
        if cleaned.contains("."), value.exponent >= -2 { return String(format: "%.2f", number.doubleValue) }
        return number.stringValue
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        mutating func sum(depth: Int) -> Decimal? {
            guard var total = product(depth: depth) else { return nil }
            while position < characters.count, "+-".contains(characters[position]) {
                let plus = characters[position] == "+"
                position += 1
                guard let next = product(depth: depth) else { return nil }
                total = plus ? total + next : total - next
            }
            return total
        }

        mutating func product(depth: Int) -> Decimal? {
            guard var total = term(depth: depth) else { return nil }
            while position < characters.count, "*/x×".contains(characters[position]) {
                let divide = characters[position] == "/"
                position += 1
                guard let next = term(depth: depth) else { return nil }
                if divide, next == 0 { return nil }
                total = divide ? total / next : total * next
            }
            return total
        }

        mutating func term(depth: Int) -> Decimal? {
            guard position < characters.count, depth < 20 else { return nil }
            if characters[position] == "-" {
                position += 1
                return term(depth: depth + 1).map { -$0 }
            }
            if characters[position] == "(" {
                position += 1
                guard let inside = sum(depth: depth + 1), position < characters.count, characters[position] == ")" else { return nil }
                position += 1
                return inside
            }
            let start = position
            while position < characters.count, characters[position].isNumber || characters[position] == "." { position += 1 }
            return start == position ? nil : Decimal(string: String(characters[start..<position]))
        }
    }
}
