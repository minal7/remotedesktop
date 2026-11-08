import Foundation

/// Character-to-token estimator that calibrates itself against the counts the
/// runtime reports, so budgets stay honest for any model and any language.
public final class TokenEstimator: @unchecked Sendable {
    private let lock = NSLock()
    private var charsPerToken: Double

    public init(charsPerToken: Double = 3.2) { self.charsPerToken = charsPerToken }

    public func estimate(_ text: String) -> Int { lock.withLock { Int((Double(text.utf8.count) / charsPerToken).rounded(.up)) } }

    /// Feed actual prompt sizes back in. Biased to the pessimistic side.
    public func observe(characters: Int, tokens: Int) {
        guard tokens > 50, characters > 100 else { return }
        lock.withLock {
            let measured = Double(characters) / Double(tokens)
            charsPerToken = max(1.5, min(5, charsPerToken * 0.8 + measured * 0.95 * 0.2))
        }
    }

    public var ratio: Double { lock.withLock { charsPerToken } }
}

/// Divides the model's small context between the parts of each prompt. Nothing
/// accumulates between steps: every prompt is rebuilt to fit, which is what lets
/// a 4–8 K context run tasks of any length.
public struct ContextBudget: Sendable, Equatable {
    public var contextTokens: Int
    public var outputTokens: Int
    public var imageTokens: Int
    /// Screen listing cap even when the context could hold more. Prompt size is
    /// the main cost per step on a base Apple chip.
    public var maximumScreenTokens: Int
    public var planTokens = 160
    public var notesTokens = 260
    public var historyTokens = 420

    public init(contextTokens: Int = 8_192, outputTokens: Int = 260, imageTokens: Int = 1_100, maximumScreenTokens: Int = 1_700) {
        self.contextTokens = contextTokens; self.outputTokens = outputTokens
        self.imageTokens = imageTokens; self.maximumScreenTokens = maximumScreenTokens
        // A model given a large context gets to use it for long pages and long histories.
        if contextTokens >= 32_768 {
            self.maximumScreenTokens = max(maximumScreenTokens, min(24_000, contextTokens / 4))
            planTokens = 640
            notesTokens = 2_000
            historyTokens = 4_000
        }
    }

    /// What's left for the screen after the fixed parts and a safety margin.
    public func screenTokens(systemTokens: Int, withImage: Bool) -> Int {
        let fixed = systemTokens + outputTokens + planTokens + notesTokens + historyTokens + (withImage ? imageTokens : 0) + 96
        return max(240, min(maximumScreenTokens, contextTokens - fixed))
    }

    /// After the runtime reports an overflow, shrink everything and try again.
    public func shrunk() -> ContextBudget {
        var copy = self
        copy.maximumScreenTokens = max(240, maximumScreenTokens * 2 / 3)
        copy.historyTokens = max(120, historyTokens * 2 / 3)
        copy.notesTokens = max(80, notesTokens * 2 / 3)
        return copy
    }
}

/// Fits the element list to its token share. Ranks by usefulness right now, then
/// prints the winners in their on-screen order so the listing still reads like the UI.
public enum SceneRenderer {
    public struct Output: Sendable {
        public var text: String
        public var shownIDs: Set<Int>
        public var omitted: Int
    }

    public static func render(_ scene: Scene, tokens: Int, estimator: TokenEstimator, keywords: Set<String> = [],
                              freshIDs: Set<Int> = [], pinned: Set<Int> = [], includeMarksHint: Bool = false) -> Output {
        var header = "App: \(scene.appName.isEmpty ? "(none)" : scene.appName)"
        if !scene.windowTitle.isEmpty { header += " | window: \"\(scene.windowTitle.prefix(70))\"" }
        if let url = scene.url { header += "\nAddress: \(url.prefix(120))" }
        if !scene.otherWindows.isEmpty {
            header += "\nOther windows: " + scene.otherWindows.prefix(4).map { "\"\($0.prefix(30))\"" }.joined(separator: ", ")
        }
        if scene.hasModal { header += "\nA DIALOG IS OPEN. Deal with it first." }
        if !scene.menuBar.isEmpty { header += "\nMenus: " + scene.menuBar.prefix(12).joined(separator: " ") }
        if scene.windowFrame.isEmpty && scene.elements.isEmpty { header += "\nThis app has no open window." }

        var remaining = tokens - estimator.estimate(header) - 24
        struct Candidate { let index: Int; let id: Int; let score: Int; let line: String }
        var ranked: [Candidate] = []
        ranked.reserveCapacity(scene.elements.count)
        for (index, element) in scene.elements.enumerated() {
            ranked.append(Candidate(index: index, id: element.id,
                                    score: score(element, keywords: keywords, fresh: freshIDs, pinned: pinned),
                                    line: line(for: element)))
        }
        ranked.sort { (a: Candidate, b: Candidate) -> Bool in
            a.score == b.score ? a.index < b.index : a.score > b.score
        }

        var chosen: [(Int, String)] = []
        var shown = Set<Int>()
        for candidate in ranked {
            let cost = estimator.estimate(candidate.line) + 1
            if cost > remaining { continue }
            remaining -= cost
            chosen.append((candidate.index, candidate.line))
            shown.insert(candidate.id)
        }
        chosen.sort { $0.0 < $1.0 }

        var text = header + "\nOn screen:\n" + chosen.map(\.1).joined(separator: "\n")
        if chosen.isEmpty { text = header + "\nOn screen: nothing readable. Use look to see a screenshot." }
        var footnotes: [String] = []
        let omitted = scene.elements.count - chosen.count
        if omitted > 0 { footnotes.append("\(omitted) less relevant items not listed; find can search them") }
        if scene.hiddenBelow > 0 { footnotes.append("more below; scroll down") }
        if scene.hiddenAbove > 0 { footnotes.append("more above; scroll up") }
        if scene.usedOCR { footnotes.append("items read from pixels") }
        if !footnotes.isEmpty { text += "\n(" + footnotes.joined(separator: "; ") + ")" }
        return Output(text: text, shownIDs: shown, omitted: omitted)
    }

    static func line(for element: UIElement) -> String {
        var parts = "[\(element.id)]"
        if element.role != "text" { parts += " \(element.role)" }
        let labelLimit = element.role == "text" ? 180 : 70
        if !element.label.isEmpty { parts += " \"\(truncate(element.label, labelLimit))\"" }
        if let value = element.value, !element.secure { parts += " = \"\(truncateMiddle(AccessibilityReader.collapse(value), 110))\"" }
        var flags: [String] = []
        if element.focused { flags.append("focused") }
        if !element.enabled { flags.append("disabled") }
        if element.selected { flags.append("selected") }
        if element.secure { flags.append("password") }
        if element.offscreen { flags.append("off-screen") }
        if !flags.isEmpty { parts += " (\(flags.joined(separator: ", ")))" }
        return parts
    }

    private static func score(_ element: UIElement, keywords: Set<String>, fresh: Set<Int>, pinned: Set<Int>) -> Int {
        var score = 0
        if pinned.contains(element.id) { score += 400 }
        if element.focused { score += 200 }
        if element.inModal { score += 120 }
        if fresh.contains(element.id) { score += 40 }
        if element.isInteractive { score += 30 }
        if element.editable { score += 25 }
        if element.role == "text" { score += element.label.count < 60 ? 12 : 8 }
        if !element.enabled { score -= 15 }
        if element.offscreen { score -= 20 }
        if element.label.isEmpty && !element.editable { score -= 25 }
        if !keywords.isEmpty {
            let label = element.label.lowercased()
            let matches = keywords.reduce(0) { $0 + (label.contains($1) ? 1 : 0) }
            score += min(matches, 3) * 35
        }
        return score
    }

    /// Words worth matching elements against. Common filler is dropped.
    public static func keywords(from text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "open", "then", "your", "you", "please",
                                 "new", "make", "use", "using", "called", "named", "them", "are", "was", "will", "should", "must",
                                 "have", "has", "can", "file", "folder", "app", "its", "out", "all", "any", "not"]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !stop.contains($0) })
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Keeps both ends, since in a field the end of the text shows where the caret work is.
    static func truncateMiddle(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return String(text.prefix(half)) + "…" + String(text.suffix(half))
    }
}
