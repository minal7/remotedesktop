import Foundation

/// Converts the model-native computer_use arguments into the single host
/// AgentAction contract. Raw completion bytes remain owned by the episode.
enum FaraPolicyAdapter {
    static let maximumCompletionBytes = 1_048_576
    static let maximumActionBytes = 32_768

    static func canonicalActionJSON(fromCompletion raw: String, imageSize: (width: Int, height: Int)) throws -> String {
        guard raw.utf8.count <= maximumCompletionBytes,
              imageSize.width > 0, imageSize.height > 0 else { throw Failure.invalidCompletion }
        let proposal: ComputerUseFaraAction
        do { proposal = try ComputerUseFaraAction.decodeNativeMessage(raw) }
        catch { throw Failure.invalidCompletion }
        let action = try canonicalAction(proposal, imageSize: imageSize)
        let data = try JSONEncoder().encode(action)
        guard data.count <= maximumActionBytes else { throw Failure.invalidCompletion }
        return String(decoding: data, as: UTF8.self)
    }

    static func actionJSON(fromCompletion raw: String) throws -> String {
        // Kept as a strict compatibility entry point for tests without coordinates.
        try canonicalActionJSON(fromCompletion: raw, imageSize: (16_384, 16_384))
    }

    enum Failure: Error { case invalidCompletion, unsupportedProposal(String) }

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
        case .key(let keys): return .key(chord: keys.joined(separator: "+"))
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
}
