import Foundation

/// Adapts native Fara actions to the host contract; raw completion bytes stay in the episode.
enum FaraPolicyAdapter {
    static let maximumCompletionBytes = 1_048_576
    static let maximumActionBytes = 32_768

    static func canonicalActionJSON(fromCompletion raw: String, imageSize: (width: Int, height: Int)) throws -> String {
        guard raw.utf8.count <= maximumCompletionBytes,
              imageSize.width > 0, imageSize.height > 0 else { throw Failure.invalidCompletion }
        let action: AgentAction
        if let special = try decodeSpecialNativeAction(raw) { action = special }
        else {
            let proposal: ComputerUseFaraAction
            do { proposal = try ComputerUseFaraAction.decodeNativeMessage(raw) }
            catch { throw Failure.invalidCompletion }
            action = try canonicalAction(proposal, imageSize: imageSize)
        }
        let data = try JSONEncoder().encode(action)
        guard data.count <= maximumActionBytes else { throw Failure.invalidCompletion }
        return String(decoding: data, as: UTF8.self)
    }

    static func resultLineNote(fromCompletion raw: String) throws -> String? {
        guard raw.utf8.count <= maximumCompletionBytes else { throw Failure.invalidCompletion }
        let proposal: ComputerUseFaraAction
        do { proposal = try ComputerUseFaraAction.decodeNativeMessage(raw) }
        catch { throw Failure.invalidCompletion }
        guard case .key(let keys) = proposal else { return nil }
        return try keyChord(keys).note
    }

    static func progressText(fromCompletion raw: String) -> String? {
        guard raw.utf8.count <= maximumCompletionBytes,
              let start = raw.range(of: "<tool_call>") else { return nil }
        let prefix = raw[..<start.lowerBound]
        guard !prefix.contains("<tool_call"), !prefix.contains("</tool_call") else { return nil }
        var text = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>") {
            text.removeFirst("<think>".count)
            if let closing = text.range(of: "</think>") {
                guard text[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                text = String(text[..<closing.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty || text.utf8.count > 4_096 ? nil : text
    }

    static func actionJSON(fromCompletion raw: String) throws -> String {
        // Kept as a strict compatibility entry point for tests without coordinates.
        try canonicalActionJSON(fromCompletion: raw, imageSize: (16_384, 16_384))
    }

    enum Failure: Error { case invalidCompletion, unsupportedProposal(String) }

    private static func keyChord(_ keys: [String]) throws -> (chord: String, note: String?) {
        guard let nativeKey = keys.last?.lowercased(), !nativeKey.isEmpty else { throw Failure.invalidCompletion }
        let key = ["arrowleft": "left", "arrowright": "right"][nativeKey] ?? nativeKey
        let modifiers = Set(keys.dropLast().map { $0.lowercased() })
        let hasControl = modifiers.contains("ctrl") || modifiers.contains("control"), hasOption = modifiers.contains("alt") || modifiers.contains("option") || modifiers.contains("opt")
        if hasOption && key == "tab" {
            throw Failure.unsupportedProposal("Use open_app to switch apps.")
        }
        let mapped: String?
        if hasControl && modifiers.count == 2 && modifiers.contains("shift") && key == "z" { mapped = "cmd+shift+z" }
        else if hasControl && modifiers.count == 1 && ["a", "c", "v", "x", "z", "y", "s", "o", "n", "w", "t", "f", "l", "p", "q"].contains(key) {
            mapped = "cmd+\(key)"
        } else if hasControl && modifiers.count == 1 && key == "home" { mapped = "cmd+up" }
        else if hasControl && modifiers.count == 1 && key == "end" { mapped = "cmd+down" }
        else if hasOption && modifiers.count == 1 && key == "left" { mapped = "cmd+[" }
        else if hasOption && modifiers.count == 1 && key == "right" { mapped = "cmd+]" }
        else if modifiers.isEmpty && key == "home" { mapped = "cmd+left" }
        else if modifiers.isEmpty && key == "end" { mapped = "cmd+right" }
        else { mapped = nil }
        let chord = mapped ?? keys.joined(separator: "+")
        guard (try? AgentKeyStroke.parse(chord)) != nil else {
            throw Failure.unsupportedProposal("Use one supported key plus supported modifiers per key action.")
        }
        return (chord, mapped.map { "mapped \(keys.map { $0.lowercased() }.joined(separator: "+")) → \($0)" })
    }

    private static func canonicalAction(_ proposal: ComputerUseFaraAction,
                                        imageSize: (width: Int, height: Int)) throws -> AgentAction {
        func point(_ point: ComputerUseFaraAction.Point) throws -> AgentTarget {
            let pixel = try point.pixel(width: imageSize.width, height: imageSize.height)
            return .point(x: Double(pixel.x), y: Double(pixel.y))
        }
        func scroll(_ horizontal: Bool, _ pixels: Double, _ target: AgentTarget? = nil) throws -> AgentAction {
            guard pixels.isFinite, pixels != 0, abs(pixels) <= 1_000 else { throw Failure.invalidCompletion }
            let scale = Double(horizontal ? imageSize.width : imageSize.height) / 1_000
            let amount = abs(pixels) * scale
            guard amount.isFinite, amount > 0 else { throw Failure.invalidCompletion }
            let direction: AgentScrollDirection = horizontal
                ? (pixels > 0 ? .right : .left) : (pixels > 0 ? .up : .down)
            return .scroll(target: target, direction: direction, amount: amount)
        }
        switch proposal {
        case let .pointer(kind, position):
            let target = try point(position)
            switch kind {
            case .leftClick: return .click(target: target, button: nil, count: nil)
            case .rightClick: return .click(target: target, button: .right, count: nil)
            case .doubleClick: return .click(target: target, button: nil, count: 2)
            case .tripleClick: return .click(target: target, button: nil, count: 3)
            case .drag:
                throw Failure.unsupportedProposal("This host action contract requires both drag endpoints; Fara supplied only the destination.")
            case .mouseMove:
                throw Failure.unsupportedProposal("Moving the pointer without a click is not available in this host action contract.")
            }
        case .typeText(let text): return .type(target: nil, text: text, mode: .append)
        case .key(let keys): return .key(chord: try keyChord(keys).chord)
        case let .scroll(horizontal, pixels): return try scroll(horizontal, pixels)
        case let .scrollAt(horizontal, pixels, position):
            return try scroll(horizontal, pixels, point(position))
        case .visitURL(let url): return .openURL(url: url.absoluteString)
        case .unsupportedNavigation:
            throw Failure.unsupportedProposal("Only absolute HTTP and HTTPS URLs are supported.")
        case .historyBack: return .key(chord: "cmd+[")
        case .webSearch:
            throw Failure.unsupportedProposal("Search is unavailable in the current computer-use action contract.")
        case .readPageQuestion:
            throw Failure.unsupportedProposal("Page-reading actions are unavailable in the current computer-use action contract.")
        case .remember:
            throw Failure.unsupportedProposal("Memory actions are unavailable in the current computer-use action contract.")
        case .askUser(let question): return .askUser(question: question, choices: nil)
        case .localFileOperation(let operation):
            switch operation {
            case let .listFiles(query, _):
                return .findFiles(query: query.nameContains, kind: query.fileKind.rawValue, modifiedAfter: nil)
            case let .askFile(question, candidates):
                return .askUser(question: question, choices: candidates)
            case .selectFile, .selectLocalFile:
                throw Failure.unsupportedProposal("Select the file through the visible host-provided file control.")
            }
        case .wait(let seconds):
            guard seconds > 0, seconds <= 10 else { throw Failure.invalidCompletion }
            return .wait(seconds: seconds)
        case .reportCompletion(let answer): return .done(answer: answer)
        }
    }

    private static func decodeSpecialNativeAction(_ raw: String) throws -> AgentAction? {
        guard let start = raw.range(of: "<tool_call>") else { return nil }
        let callText = String(raw[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard callText.hasPrefix("<tool_call>"), callText.hasSuffix("</tool_call>") else { return nil }
        let body = String(callText.dropFirst("<tool_call>".count).dropLast("</tool_call>".count))
        var parser = StrictSemanticJSONParser(body)
        guard case .object(let call) = try parser.parse(), Set(call.keys) == ["name", "arguments"],
              call["name"] == .string("computer_use"), case .object(let args)? = call["arguments"],
              case .string(let action)? = args["action"] else { return nil }
        if action == "open_app" {
            guard Set(args.keys) == ["action", "name"], case .string(let name)? = args["name"],
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 1_024, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw Failure.invalidCompletion
            }
            return .openApp(name: name)
        }
        let click: (AgentMouseButton?, Int?)
        switch action {
        case "left_click": click = (nil, nil)
        case "right_click": click = (.right, nil)
        case "double_click": click = (nil, 2)
        case "triple_click": click = (nil, 3)
        default: return nil
        }
        guard args["element_id"] != nil else { return nil }
        guard Set(args.keys) == ["action", "element_id"], case .integer(let id)? = args["element_id"], id >= 1 else {
            throw Failure.invalidCompletion
        }
        return .click(target: .element(id: id), button: click.0, count: click.1)
    }
}
