import Foundation

/// GUI-Owl's native desktop protocol, separate from effect admission.
enum ComputerUseGUIOwlModel {
    static let modelAlias = "gui-owl-desktop-v1"
    enum Decision: Equatable, Sendable {
        case browser(ComputerUseFaraAction)
        case wheel(horizontal: Bool, amount: Double)
        case middleClick(ComputerUseFaraAction.Point)
        case handoff(String)
        case terminalStatus(success: Bool)
    }
    struct Proposal: Equatable, Sendable {
        let response: String
        let decision: Decision
        func compatibleDesktopProposal() -> ComputerUseDesktopProposal {
            switch decision {
            case .browser(let action): return .init(response: response, action: action)
            case .terminalStatus(let success): return .init(response: response, decision: .completionStatus(success: success))
            case .handoff(let message): return .init(response: response, decision: .handoff(message))
            case .wheel, .middleClick: return .init(response: response, decision: .unsupported)
            }
        }
    }
    static func decode(_ data: Data) throws -> Proposal {
        do {
            guard data.count <= 1_048_576, let text = String(data:data,encoding:.utf8) else { throw invalid }
            var parser = StrictSemanticJSONParser(text)
            guard case .object(let root) = try parser.parse(), root["model"] == .string(modelAlias),
                  case .array(let choices)? = root["choices"], choices.count == 1,
                  case .object(let choice) = choices[0], choice["finish_reason"] == .string("stop"),
                  case .object(let message)? = choice["message"], message["role"] == .string("assistant"),
                  Set(message.keys) == ["role","content"], case .string(let response)? = message["content"] else { throw invalid }
            return try .init(response:response,decision:decodeMessage(response))
        } catch { throw invalid }
    }

    private static var invalid: OSAtlasLlamaRuntimeError { .invalidResponse }
    private static func decodeMessage(_ response: String) throws -> Decision {
        guard response.utf8.count <= 32_768, let start = response.range(of:"<tool_call>") else { throw invalid }
        let narrative = response[..<start.lowerBound].trimmingCharacters(in:.whitespacesAndNewlines)
        guard narrative.hasPrefix("Action: "), !narrative.dropFirst(8).trimmingCharacters(in:.whitespaces).isEmpty,
              !narrative.contains("\n"), !narrative.contains("\r"), !narrative.contains("</tool_call") else { throw invalid }
        let call = response[start.lowerBound...].trimmingCharacters(in:.whitespacesAndNewlines)
        guard call.hasSuffix("</tool_call>") else { throw invalid }
        let body = String(call.dropFirst("<tool_call>".count).dropLast("</tool_call>".count))
        var parser = StrictSemanticJSONParser(body)
        guard case .object(let object) = try parser.parse(), Set(object.keys) == ["name","arguments"],
              object["name"] == .string("computer_use"), case .object(let args)? = object["arguments"],
              case .string(let name)? = args["action"] else { throw invalid }
        func keys(_ fields: String...) throws { guard Set(args.keys) == Set(["action"] + fields) else { throw invalid } }
        func text(_ field: String) throws -> String {
            guard case .string(let value)? = args[field], !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw invalid }
            return value
        }
        func number(_ value: JSONValue?) throws -> Double {
            let number: Double
            switch value { case .integer(let n): number=Double(n); case .double(let n):number=n;default:throw invalid }
            guard number.isFinite else { throw invalid };return number
        }
        // Only these GUI-Owl actions share Fara's exact argument semantics.
        // The raw GUI-Owl message is retained; no Fara conversation is fabricated.
        if ComputerUseFaraAction.PointerKind(rawValue:name) != nil || ["type","key","wait"].contains(name) {
            return try .browser(ComputerUseFaraAction.decode(call))
        }
        switch name {
        case "answer": try keys("text");return try .browser(.reportCompletion(text("text")))
        case "terminate":
            try keys("status");let status=try text("status")
            guard status == "success" || status == "failure" else { throw invalid }
            return .terminalStatus(success:status == "success")
        case "interact":try keys("text");return try .handoff(text("text"))
        case "scroll","hscroll":
            if args["coordinate"] != nil { return try .browser(ComputerUseFaraAction.decode(call)) }
            try keys("pixels");let amount=try number(args["pixels"])
            guard abs(amount)<=10_000 else { throw invalid }
            return .wheel(horizontal:name == "hscroll",amount:amount)
        case "middle_click":
            try keys("coordinate")
            guard case .array(let point)? = args["coordinate"], point.count == 2 else { throw invalid }
            let x=try number(point[0]),y=try number(point[1])
            guard (0...1000).contains(x),(0...1000).contains(y) else { throw invalid }
            return .middleClick(.init(x:x,y:y))
        default:throw invalid
        }
    }

    /// Native alternating screenshot/action history. Two recent image pairs
    /// remain visible; older actions retain their original outcomes as summaries.
    static func makeRequest(endpoint: OSAtlasLlamaEndpoint, input: ComputerUseFaraModel.Input) throws -> URLRequest {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(endpoint.baseURL)
        try input.validateSurfaceContext()
        guard endpoint.variant == nil, !endpoint.bearerToken.isEmpty,
              !input.goal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              input.goal.utf8.count <= 8192, input.history.count <= 20,
              input.pageReading == nil, input.history.allSatisfy({$0.pageReading == nil}) else { throw invalid }
        try ComputerUseFaraModel.validatePNG(input.screenshotPNG)
        var bytes = input.goal.utf8.count
        func observation(url:URL?,error:String?,reply:String?,editor:String?,state:ComputerUseNativeTextState?) throws -> String {
            var fields:[String:Any]=[:]
            if input.surface == .desktop { fields = ComputerUseFaraModel.nativeFocusObject(editor, state: state) }
            if let url {
                guard ComputerUseValidatedWebURL.validatedURL(url)==url,url.absoluteString.utf8.count<=8192 else { throw invalid }
                fields["observed_url"]=url.absoluteString
            }
            for (key,value,maximum) in [("error",error,16384),("user_response",reply,8192)] {
                if let value {
                    guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.utf8.count<=maximum else { throw invalid }
                    fields[key]=value
                }
            }
            let data=try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes])
            bytes+=data.count
            return String(decoding:data,as:UTF8.self)
        }
        var observations:[String]=[]
        for step in input.history { observations.append(try observation(url:step.currentURL,error:step.actionError,reply:step.userResponse,editor:step.focusedEditor,state:step.focusedTextState)) }
        observations.append(try observation(url:input.currentURL,error:input.actionError,reply:input.userResponse,editor:input.focusedEditor,state:input.focusedTextState))
        var outcomes:[String]=[]
        for (i,step) in input.history.enumerated() {
            _ = try decodeMessage(step.response)
            try ComputerUseFaraModel.validatePNG(step.screenshotPNG)
            bytes+=step.response.utf8.count
            var result=observations[i+1]
            if let original=step.resultObservation {
                result=try observation(url:original.currentURL,error:original.actionError,reply:original.userResponse,editor:original.focusedEditor,state:original.focusedTextState)
            }
            outcomes.append(result)
        }
        let controls = try input.surface == .desktop ? ComputerUseFaraModel.nativeControlsJSON(input.nativeControls) : nil
        bytes += controls?.utf8.count ?? 0
        guard bytes<=65_536 else { throw invalid }
        let firstImage = max(0,input.history.count-2)
        let previous: [String] = (0..<firstImage).map { i in
            let action: String = "Step\(i+1): " + input.history[i].response
            let before: String = action + "\nObserved before action: " + observations[i]
            return before + "\nObserved outcome: " + outcomes[i]
        }
        var messages:[[String:Any]]=[
            ["role":"system","content":[["type":"text","text":try input.surface == .desktop ? desktopSystemPrompt() : officialSystemPrompt]]]]
        for i in firstImage...input.history.count {
            var text = ""
            if i == firstImage {
                text = "Please generate the next move according to the UI screenshot, instruction and previous actions.\n\nInstruction: " + input.goal + "\n\nPrevious actions:\n" + (previous.isEmpty ? "No previous action." : previous.joined(separator:"\n")) + "\n\n"
            } else {
                // A retained action's result may precede a later recapture or
                // pruned history. Never relabel that result as this image's state.
                text = "Previous action outcome: " + outcomes[i-1] + "\n\n"
            }
            text += "Current observation: " + observations[i]
            if i == input.history.count, let controls { text += "\n" + controls }
            let screenshot = i < input.history.count ? input.history[i].screenshotPNG : input.screenshotPNG
            messages.append(["role":"user","content":[["type":"text","text":text],["type":"image_url","image_url":["url":"data:image/png;base64,"+screenshot.base64EncodedString()]]]])
            if i < input.history.count {
                messages.append(["role":"assistant","content":[["type":"text","text":input.history[i].response]]])
            }
        }
        var request=URLRequest(url:endpoint.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod="POST";request.timeoutInterval=40
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer "+endpoint.bearerToken,forHTTPHeaderField:"Authorization")
        request.httpBody=try JSONSerialization.data(withJSONObject:["model":modelAlias,"messages":messages,"temperature":0,"seed":20260913,"max_tokens":1024,"stream":false],options:[.sortedKeys,.withoutEscapingSlashes])
        guard request.httpBody!.count<=9*1024*1024 else { throw invalid }
        return request
    }

    private static func desktopSystemPrompt() throws -> String {
        var tool = ComputerUseFaraModel.desktopToolSchema()
        guard var function = tool["function"] as? [String: Any],
              var parameters = function["parameters"] as? [String: Any],
              var properties = parameters["properties"] as? [String: Any] else { throw invalid }
        properties["action"] = ["type": "string",
            "enum": ["key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "answer", "terminate", "interact"],
            "description": "Choose one native Mac action. Clicking uses coordinate; type inserts exact text at the current selection without implicit keys; key sends the literal chord. wait takes seconds. answer uses text for the final answer. terminate uses status success or failure and supplies no answer text. interact uses text to request manual user control, then resumes with a fresh screenshot after the user chooses Resume."]
        properties.removeValue(forKey: "answer"); properties.removeValue(forKey: "fact")
        properties["status"] = ["type": "string", "enum": ["success", "failure"], "description": "Required by terminate: whether the task succeeded or could not be completed."]
        properties["text"] = ["type": "string", "description": "Exact text to insert for type, final answer for answer, or manual handoff message for interact."]
        parameters["properties"] = properties; function["parameters"] = parameters; tool["function"] = function
        return try ComputerUseFaraModel.replacingDesktopToolSchema(in: officialSystemPrompt, with: tool)
    }

    // Verbatim SYSTEM_PROMPT, X-PLUG/MobileAgent commit 11cea575561fb7800b5fb6b6cafa56f7a91de11f,
    // Mobile-Agent-v3.5/cookbook/end2end_usage_computer.ipynb (MIT).
    // Copyright (c) 2022 mPLUG. See ThirdPartyNotices/GUI-OWL-DESKTOP-MIT-LICENSE.txt.
    static let officialSystemPrompt = #"""
    # Tools

    You may call one or more functions to assist with the user query.

    You are provided with function signatures within <tools></tools> XML tags:
    <tools>
    {"type": "function", "function": {"name": "computer_use", "description": "Use a mouse and keyboard to interact with a computer, and take screenshots.
    * This is an interface to a desktop GUI. You do not have access to a terminal or applications menu. You must click on desktop icons to start applications.
    * Some applications may take time to start or process actions, so you may need to wait and take successive screenshots to see the results of your actions. E.g. if you click on Firefox and a window doesn't open, try wait and taking another screenshot.
    * The screen's resolution is 1000x1000.
    * Whenever you intend to move the cursor to click on an element like an icon, you should consult a screenshot to determine the coordinates of the element before moving the cursor.
    * If you tried clicking on a program or link but it failed to load, even after waiting, try adjusting your cursor position so that the tip of the cursor visually falls on the element that you want to click.
    * Make sure to click any buttons, links, icons, etc with the cursor tip in the center of the element. Don't click boxes on their edges unless asked.", "parameters": {"properties": {"action": {"description": "The action to perform. The available actions are:
    * `key`: Performs key down presses on the arguments passed in order, then performs key releases in reverse order.
    * `type`: Type a string of text on the keyboard.
    * `mouse_move`: Move the cursor to a specified (x, y) pixel coordinate on the screen.
    * `left_click`: Click the left mouse button at a specified (x, y) pixel coordinate on the screen.
    * `left_click_drag`: Click and drag the cursor to a specified (x, y) pixel coordinate on the screen.
    * `right_click`: Click the right mouse button at a specified (x, y) pixel coordinate on the screen.
    * `middle_click`: Click the middle mouse button at a specified (x, y) pixel coordinate on the screen.
    * `double_click`: Double-click the left mouse button at a specified (x, y) pixel coordinate on the screen.
    * `triple_click`: Triple-click the left mouse button at a specified (x, y) pixel coordinate on the screen (simulated as double-click since it's the closest action).
    * `scroll`: Performs a scroll of the mouse scroll wheel.
    * `hscroll`: Performs a horizontal scroll (mapped to regular scroll).
    * `wait`: Wait specified seconds for the change to happen.
    * `interact`: Resolve the blocking window by interacting with the user.
    * `terminate`: Terminate the current task and report its completion status.
    * `answer`: Answer a question.", "enum": ["key", "type", "mouse_move", "left_click", "left_click_drag", "right_click", "middle_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "interact", "terminate", "answer"], "type": "string"}, "keys": {"description": "Required only by `action=key`.", "type": "array"}, "text": {"description": "Required only by `action=type`, `action=interact`, and `action=answer`.", "type": "string"}, "coordinate": {"description": "(x, y): The x (pixels from the left edge) and y (pixels from the top edge) coordinates to move the mouse to. Required only by `action=mouse_move` and `action=left_click_drag`.", "type": "array"}, "pixels": {"description": "The amount of scrolling to perform. Positive values scroll up, negative values scroll down. Required only by `action=scroll` and `action=hscroll`.", "type": "number"}, "time": {"description": "The seconds to wait. Required only by `action=wait`.", "type": "number"}, "status": {"description": "The status of the task. Required only by `action=terminate`.", "type": "string", "enum": ["success", "failure"]}}, "required": ["action"], "type": "object"}}}
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
    - Be brief: one for Action.
    - Do not output anything else outside those two parts.
    - If finishing, use action=terminate in the tool call.
    """# + "\n"
}
