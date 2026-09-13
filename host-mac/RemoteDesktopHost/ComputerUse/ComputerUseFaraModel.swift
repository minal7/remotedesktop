import Foundation
import ImageIO

/// Verified model data and the signed bundled executable, resolved by setup.
/// The runtime never downloads models or executes code from a model package.
struct ComputerUseFaraRuntimeInputs: Equatable, Sendable {
    static let modelAlias = "fara-browser-v1"
    static let modelFileName = "Fara1.5-4B-Q4_K_M.gguf"
    static let projectorFileName = "mmproj-Fara1.5-4B-f16.gguf"
    let modelURL: URL
    let projectorURL: URL
    let llamaServerURL: URL
    init(modelURL: URL, projectorURL: URL, llamaServerURL: URL) {
        self.modelURL = modelURL.standardizedFileURL
        self.projectorURL = projectorURL.standardizedFileURL
        self.llamaServerURL = llamaServerURL.standardizedFileURL
    }
}

enum ComputerUseFaraModel {
    struct Step: Equatable, Sendable {
        let screenshotPNG: Data
        let response: String
        var currentURL: URL? = nil
    }
    struct Input: Equatable, Sendable {
        let goal: String
        let screenshotPNG: Data
        var history: [Step] = []
        var currentURL: URL? = nil
    }
    struct Proposal: Equatable, Sendable {
        let response: String
        let action: ComputerUseFaraAction
    }
    static func makeRequest(endpoint: OSAtlasLlamaEndpoint, input: Input) throws -> URLRequest {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(endpoint.baseURL)
        guard endpoint.variant == nil, !endpoint.bearerToken.isEmpty,
              !input.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.goal.utf8.count <= 8_192, input.history.count <= 20,
              input.history.reduce(input.goal.utf8.count + (input.currentURL?.absoluteString.utf8.count ?? 0),
                { $0 + $1.response.utf8.count + ($1.currentURL?.absoluteString.utf8.count ?? 0) }) <= 65_536 else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        var messages: [[String: Any]] = [["role": "system", "content": officialSystemPrompt]]
        let earliestImage = max(0, input.history.count - 2)
        for index in 0...input.history.count {
            var content: [[String: Any]] = []
            let png = index == input.history.count ? input.screenshotPNG : input.history[index].screenshotPNG
            if index >= earliestImage {
                try validatePNG(png)
                content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]])
            }
            let currentURL = index == input.history.count ? input.currentURL : input.history[index].currentURL
            if let currentURL {
                guard ComputerUseOwnedBrowser.validatedURL(currentURL) == currentURL else {
                    throw OSAtlasLlamaRuntimeError.invalidResponse
                }
                // Preserve the native browser observation alongside its image,
                // including when that image ages out of the three-image window.
                content.append(["type": "text", "text": "Current URL: " + currentURL.absoluteString])
            }
            if index == 0 { content.append(["type": "text", "text": input.goal]) }
            else if content.isEmpty { content.append(["type": "text", "text": "[Earlier screenshot omitted]"]) }
            messages.append(["role": "user", "content": content])
            if index < input.history.count {
                let response = input.history[index].response
                _ = try ComputerUseFaraAction.decodeNativeMessage(response)
                messages.append(["role": "assistant", "content": response])
            }
        }
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + endpoint.bearerToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ComputerUseFaraRuntimeInputs.modelAlias, "messages": messages,
            "temperature": 0, "max_tokens": 1024, "stream": false, "reasoning_format": "none",
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        guard request.httpBody!.count <= 9 * 1_024 * 1_024 else { throw OSAtlasLlamaRuntimeError.invalidResponse }
        return request
    }
    static func decode(_ data: Data) throws -> Proposal {
        do {
            guard data.count <= 1_024 * 1_024, let source = String(data: data, encoding: .utf8) else {
                throw OSAtlasLlamaRuntimeError.invalidResponse
            }
            var parser = StrictSemanticJSONParser(source)
            guard case .object(let root) = try parser.parse(),
                  root["model"] == .string(ComputerUseFaraRuntimeInputs.modelAlias),
                  case .array(let choices)? = root["choices"], choices.count == 1,
                  case .object(let choice) = choices[0], choice["finish_reason"] == .string("stop"),
                  case .object(let message)? = choice["message"], message["role"] == .string("assistant"),
                  Set(message.keys).isSubset(of: ["role", "content"]),
                  case .string(let response)? = message["content"] else { throw OSAtlasLlamaRuntimeError.invalidResponse }
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        } catch { throw OSAtlasLlamaRuntimeError.invalidResponse }
    }

    static func validatePNG(_ data: Data) throws {
        guard data.count <= 2 * 1_024 * 1_024,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304 else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
    }
}

// Official prompt: microsoft/fara a675d6d61c41c47ae87bacefeab22caad18e3e84.
// Reproduced from its literal identity, critical points and 1000×1000 tool schema.
// MIT License
// 
// Copyright (c) 2025 Microsoft
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
extension ComputerUseFaraModel {
    static let officialSystemPrompt = #"""
    You are Fara, a computer use agent (CUA) specialized for web browsers. You are developed by Microsoft AI Frontiers. You assist users with completing and automating tasks that require the use of a web browser.
    
    The model was trained in the timeframe of January - April 2026. You can effectively perform tasks even beyond this range by accessing the web browser and using the latest information on the live web. But your knowledge cutoff is limited to early 2026, so you may not be aware of events or developments that occurred after that time, without explicitly browsing and searching for latest information on the web.
    
    This edition of the model was trained using SFT on top of Qwen3.5-9B, using a synthetic data mixture generated and developed by Microsoft AI Frontiers.
    
    A critical point is a situation where we must pause and request information or confirmation from the user before proceeding. There are three types:
    
    Case 1: Missing User Information — The task requires personal information that the user has not provided (e.g., email, phone number, address, payment details). Never fabricate or assume personal information. Fill in only what the user has explicitly provided, then pause and ask for any missing required fields. (e.g., form requires phone number but user only gave name and email -> fill name and email, then ask for phone number.) If the user has provided all required information, proceed without stopping.
    
    Case 2: Underspecified Task — The task description is ambiguous or missing details needed to make a decision at the current step. Pause and ask for clarification. (e.g., user asks to book a flight but doesn't specify destination -> ask for destination.) If the user's instructions contain all information needed for the current decision, proceed without stopping.
    
    Case 3: Irreversible Action — We are about to perform an action that cannot be undone (e.g., submitting a form, completing a purchase, sending a message, deleting data). If the user explicitly authorized the action (e.g., "submit the form", "complete the purchase", "you have my permission to submit") -> proceed without stopping. If the user did NOT explicitly authorize the action -> stop and ask for confirmation. (e.g., "fill out a form" with no mention of submitting -> fill the form, then ask before submitting; "fill out and submit a form" -> fill and submit without stopping.)
    
    Only stop at a critical point if (1) required information is missing, (2) the task is ambiguous, OR (3) an irreversible action lacks explicit user authorization. If the user has provided all necessary information AND explicitly authorized the action, proceed without interruption.
    
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
