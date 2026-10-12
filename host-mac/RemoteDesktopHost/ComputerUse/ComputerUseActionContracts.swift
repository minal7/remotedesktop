import CoreGraphics
import CryptoKit
import Foundation

enum ComputerUsePendingObservationPolicy {
    static let maximumConsecutivePendingObservations = 3
}

enum OSAtlasCustomAction: String, CaseIterable, Hashable, Sendable {
    case doubleClick
    case rightClick
    case drag
    case hotkey
    case ask
    case report
}

struct OSAtlasActionContract: Equatable, Sendable {
    let customActions: Set<OSAtlasCustomAction>

    static let macOS = OSAtlasActionContract(customActions: Set(OSAtlasCustomAction.allCases))
}

enum OSAtlasGUIAction: Equatable, Sendable {
    case click(x: Int, y: Int)
    case doubleClick(x: Int, y: Int)
    case rightClick(x: Int, y: Int)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
    case typeText(String)
    case scroll(OSAtlasScrollDirection)
    case openApplication(String)
    case enter
    case hotkey(usage: Int, modifiers: UInt16, displayName: String)
    case wait
    case complete
    case ask(String)
    case report(String)
}

enum OSAtlasScrollDirection: String, Equatable, Sendable {
    case up = "UP"
    case down = "DOWN"
    case left = "LEFT"
    case right = "RIGHT"
}

enum OSAtlasExplicitActionDirective: String, Equatable, Hashable, Sendable {
    case click = "CLICK"
    case doubleClick = "DOUBLE_CLICK"
    case rightClick = "RIGHT_CLICK"
    case drag = "DRAG"
    case type = "TYPE"
    case scroll = "SCROLL"
    case openApplication = "OPEN_APP"
    case enter = "ENTER"
    case hotkey = "HOTKEY"
    case wait = "WAIT"
    case complete = "COMPLETE"
    case ask = "ASK"
    case answer = "ANSWER"
    case report = "REPORT"

    var correctionFormat: String {
        switch self {
        case .click:
            return "CLICK <point>[[x-axis, y-axis]]</point>"
        case .doubleClick:
            return "DOUBLE_CLICK <point>[[x-axis, y-axis]]</point>"
        case .rightClick:
            return "RIGHT_CLICK <point>[[x-axis, y-axis]]</point>"
        case .drag:
            return "DRAG <point>[[x1, y1]]</point> TO <point>[[x2, y2]]</point>"
        case .type:
            return "TYPE [input text]"
        case .scroll:
            return "SCROLL [UP/DOWN/LEFT/RIGHT]"
        case .openApplication:
            return "OPEN_APP [app_name]"
        case .enter:
            return "ENTER"
        case .hotkey:
            return "HOTKEY [COMMAND+key], HOTKEY [OPTION+key], HOTKEY [CONTROL+key], or HOTKEY [SHIFT+key]"
        case .wait:
            return "WAIT"
        case .complete:
            return "COMPLETE"
        case .ask:
            return "ASK [question]"
        case .answer:
            return "ANSWER [observed result]"
        case .report:
            return "REPORT [observed result]"
        }
    }

    var correctionCategory: String {
        switch self {
        case .click, .type, .scroll:
            return "Basic"
        default:
            return "Custom"
        }
    }

    var correctionPurpose: String {
        switch self {
        case .click:
            return "Activate the specified visible position."
        case .doubleClick:
            return "Open or activate the specified visible desktop item."
        case .rightClick:
            return "Open the context menu at the specified visible position."
        case .drag:
            return "Move the specified visible item between two positions."
        case .type:
            return "Enter the specified text at the focused insertion point."
        case .scroll:
            return "Move the visible viewport in the specified direction."
        case .openApplication:
            return "Open the specified application."
        case .enter:
            return "Press the enter button."
        case .hotkey:
            return "Perform the specified keyboard shortcut on focused content."
        case .wait:
            return "Wait for the screen to load."
        case .complete:
            return "Indicate the task is finished."
        case .ask:
            return "Ask the user for required missing information."
        case .answer, .report:
            return "Return the requested facts visible in the screenshot."
        }
    }

    var correctionExample: String {
        switch self {
        case .click:
            return "CLICK <point>[[101, 872]]</point>"
        case .doubleClick:
            return "DOUBLE_CLICK <point>[[214, 358]]</point>"
        case .rightClick:
            return "RIGHT_CLICK <point>[[752, 646]]</point>"
        case .drag:
            return "DRAG <point>[[125, 125]]</point> TO <point>[[875, 875]]</point>"
        case .type:
            return "TYPE [Book a table for Friday]"
        case .scroll:
            return "SCROLL [UP]"
        case .openApplication:
            return "OPEN_APP [Google Chrome]"
        case .enter:
            return "ENTER"
        case .hotkey:
            return "HOTKEY [COMMAND+V]"
        case .wait:
            return "WAIT"
        case .complete:
            return "COMPLETE"
        case .ask:
            return "ASK [Which date should I use?]"
        case .answer:
            return "ANSWER [observed result]"
        case .report:
            return "REPORT [The visible status is Ready.]"
        }
    }

    func isDeclared(in contract: OSAtlasActionContract) -> Bool {
        switch self {
        case .doubleClick:
            return contract.customActions.contains(.doubleClick)
        case .rightClick:
            return contract.customActions.contains(.rightClick)
        case .drag:
            return contract.customActions.contains(.drag)
        case .hotkey:
            return contract.customActions.contains(.hotkey)
        case .ask:
            return contract.customActions.contains(.ask)
        case .answer, .report:
            return contract.customActions.contains(.report)
        case .click, .type, .scroll, .openApplication, .enter, .wait, .complete:
            return true
        }
    }

    func matches(_ action: OSAtlasGUIAction) -> Bool {
        switch (self, action) {
        case (.click, .click),
             (.doubleClick, .doubleClick),
             (.rightClick, .rightClick),
             (.drag, .drag),
             (.type, .typeText),
             (.scroll, .scroll),
             (.openApplication, .openApplication),
             (.enter, .enter),
             (.hotkey, .hotkey),
             (.wait, .wait),
             (.complete, .complete),
             (.ask, .ask),
             (.answer, .report),
             (.report, .report):
            return true
        default:
            return false
        }
    }

    func matches(_ action: OSAtlasGUIAction, rawActionLine: String) -> Bool {
        guard matches(action),
              let rawVariant = rawActionLine
                .split(whereSeparator: { $0.isWhitespace })
                .first else {
            return false
        }
        return rawVariant.uppercased() == rawValue
    }
}

/// Typed, no-effect semantic context selected by the local language router.
/// OS-Atlas remains responsible for grounding pointer coordinates against the
/// current screenshot; these strings only tell it what visible target or exact
/// user-provided value the next action should use.
enum OSAtlasSemanticActionArgument: Equatable, Sendable {
    case none
    case targetHint(String)
    case dragHints(source: String, destination: String)
    case text(String)
    case literalTextReference(String)
    case applicationName(String)
    case hotkey(String)
    case question(String)
    case visibleAnswer(summary: String, evidence: [String])
    /// A deterministic host route proved that the visible, task-related state
    /// prevents the requested action. Foundation-model tool calls can never
    /// construct this provenance marker.
    case visibleObstacle(summary: String, evidence: [String])
}

/// A no-effect natural-language routing decision. Scroll direction is carried
/// separately because all four directions share the raw `SCROLL` token while
/// producing materially different native input.
struct OSAtlasSemanticActionRoute: Equatable, Sendable {
    let directive: OSAtlasExplicitActionDirective
    let scrollDirection: OSAtlasScrollDirection?
    let argument: OSAtlasSemanticActionArgument

    init(
        directive: OSAtlasExplicitActionDirective,
        scrollDirection: OSAtlasScrollDirection? = nil,
        argument: OSAtlasSemanticActionArgument = .none
    ) {
        precondition(directive == .scroll || scrollDirection == nil)
        self.directive = directive
        self.scrollDirection = scrollDirection
        self.argument = argument
    }

    func matches(
        _ action: OSAtlasGUIAction,
        rawActionLine: String
    ) -> Bool {
        guard directive.matches(action, rawActionLine: rawActionLine) else {
            return false
        }
        guard let scrollDirection else { return true }
        guard case .scroll(let emittedDirection) = action else { return false }
        return emittedDirection == scrollDirection
    }

    var privacySafeToken: String {
        guard let scrollDirection else { return directive.rawValue }
        return "SCROLL_\(scrollDirection.rawValue)"
    }
}

/// Exact raw variants understood by the host parser. Scroll directions and
/// the two visible-facts spellings remain separate so a checkpoint profile can
/// describe precisely what an installed model has passed end to end.
enum OSAtlasRawActionVariant: String, CaseIterable, Hashable, Sendable {
    case click = "CLICK"
    case doubleClick = "DOUBLE_CLICK"
    case rightClick = "RIGHT_CLICK"
    case drag = "DRAG"
    case type = "TYPE"
    case scrollUp = "SCROLL_UP"
    case scrollDown = "SCROLL_DOWN"
    case scrollLeft = "SCROLL_LEFT"
    case scrollRight = "SCROLL_RIGHT"
    case openApplication = "OPEN_APP"
    case enter = "ENTER"
    case hotkey = "HOTKEY"
    case wait = "WAIT"
    case complete = "COMPLETE"
    case ask = "ASK"
    case answer = "ANSWER"
    case report = "REPORT"

    static func resolve(
        action: OSAtlasGUIAction,
        rawActionLine: String
    ) -> OSAtlasRawActionVariant? {
        guard let rawToken = rawActionLine
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .uppercased() else {
            return nil
        }
        switch action {
        case .click where rawToken == "CLICK": return .click
        case .doubleClick where rawToken == "DOUBLE_CLICK": return .doubleClick
        case .rightClick where rawToken == "RIGHT_CLICK": return .rightClick
        case .drag where rawToken == "DRAG": return .drag
        case .typeText where rawToken == "TYPE": return .type
        case .scroll(.up) where rawToken == "SCROLL": return .scrollUp
        case .scroll(.down) where rawToken == "SCROLL": return .scrollDown
        case .scroll(.left) where rawToken == "SCROLL": return .scrollLeft
        case .scroll(.right) where rawToken == "SCROLL": return .scrollRight
        case .openApplication where rawToken == "OPEN_APP": return .openApplication
        case .enter where rawToken == "ENTER": return .enter
        case .hotkey where rawToken == "HOTKEY": return .hotkey
        case .wait where rawToken == "WAIT": return .wait
        case .complete where rawToken == "COMPLETE": return .complete
        case .ask where rawToken == "ASK": return .ask
        case .report where rawToken == "ANSWER": return .answer
        case .report where rawToken == "REPORT": return .report
        default: return nil
        }
    }
}

struct OSAtlasCheckpointActionProfile: Equatable, Sendable {
    let allowedVariants: Set<OSAtlasRawActionVariant>

    static let parserComplete = OSAtlasCheckpointActionProfile(
        allowedVariants: Set(OSAtlasRawActionVariant.allCases))

    /// Parser-validated legacy compatibility allowlist. It keeps a constrained
    /// OS-Atlas path on macOS 14/15 and on macOS 26 Macs where the Apple
    /// on-device language model is unavailable. It is not evidence that raw
    /// checkpoint inference reliably selects every variant from ordinary
    /// language; the expanded surface below is host-composed for that reason.
    static let installedPro4BQ4KMLegacy = OSAtlasCheckpointActionProfile(
        allowedVariants: [
            .rightClick,
            .type,
            .scrollUp,
            .scrollDown,
            .scrollLeft,
            .scrollRight,
            .openApplication,
            .enter,
            .wait,
            .complete,
            .ask,
            .answer,
        ])

    /// Raw checkpoint variants that may execute without a typed semantic
    /// plan. The expanded user-facing surface is host-composed and therefore
    /// does not require this checkpoint to emit unreliable custom verbs.
    static let installedPro4BQ4KM = installedPro4BQ4KMLegacy

    func allows(
        action: OSAtlasGUIAction,
        rawActionLine: String
    ) -> Bool {
        guard let variant = OSAtlasRawActionVariant.resolve(
            action: action,
            rawActionLine: rawActionLine) else {
            return false
        }
        return allowedVariants.contains(variant)
    }

    func declares(_ directive: OSAtlasExplicitActionDirective) -> Bool {
        switch directive {
        case .click: return allowedVariants.contains(.click)
        case .doubleClick: return allowedVariants.contains(.doubleClick)
        case .rightClick: return allowedVariants.contains(.rightClick)
        case .drag: return allowedVariants.contains(.drag)
        case .type: return allowedVariants.contains(.type)
        case .scroll:
            return !allowedVariants.isDisjoint(with: [
                .scrollUp, .scrollDown, .scrollLeft, .scrollRight,
            ])
        case .openApplication: return allowedVariants.contains(.openApplication)
        case .enter: return allowedVariants.contains(.enter)
        case .hotkey: return allowedVariants.contains(.hotkey)
        case .wait: return allowedVariants.contains(.wait)
        case .complete: return allowedVariants.contains(.complete)
        case .ask: return allowedVariants.contains(.ask)
        case .answer: return allowedVariants.contains(.answer)
        case .report: return allowedVariants.contains(.report)
        }
    }
}

/// Minimal, privacy-preserving geometry used to correct a visual point only
/// when macOS Accessibility exposes one unambiguous nearby control. Labels and
/// values never leave the host and are intentionally absent from this type.
struct OSAtlasAccessibilityClickCandidate: Equatable, Sendable {
    let identity: String
    let frame: CGRect
    let isEnabled: Bool
    let isActionable: Bool
}

enum OSAtlasAccessibilityClickCorrection {
    static let maximumRadius: CGFloat = 48

    /// Keeps the model point unless it currently resolves only to a
    /// non-actionable container and exactly one enabled actionable candidate
    /// is nearby. Ambiguity always preserves the original point.
    static func correctedPoint(
        predicted: CGPoint,
        directHit: OSAtlasAccessibilityClickCandidate?,
        nearbyCandidates: [OSAtlasAccessibilityClickCandidate],
        maximumRadius: CGFloat = maximumRadius
    ) -> CGPoint {
        guard maximumRadius > 0,
              predicted.x.isFinite,
              predicted.y.isFinite,
              let directHit else {
            return predicted
        }
        if directHit.isEnabled,
           directHit.isActionable,
           directHit.frame.contains(predicted) {
            return predicted
        }
        guard !directHit.isActionable else { return predicted }

        var unique: [String: OSAtlasAccessibilityClickCandidate] = [:]
        for candidate in nearbyCandidates where
            candidate.isEnabled && candidate.isActionable &&
            candidate.frame.width > 0 && candidate.frame.height > 0 &&
            distance(from: predicted, to: candidate.frame) <= maximumRadius {
            unique[candidate.identity] = candidate
        }
        guard unique.count == 1, let candidate = unique.values.first else {
            return predicted
        }
        return CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

/// Host-only semantic evidence for a visible Accessibility control. Unlike the
/// privacy-preserving geometry candidate above, the label is retained only for
/// the duration of one local correction and is never logged or persisted.
struct OSAtlasSemanticAccessibilityClickCandidate: Equatable, Sendable {
    let identity: String
    let frame: CGRect
    let isEnabled: Bool
    let isActionable: Bool
    let label: String
}

struct OSAtlasSemanticAccessibilityClickScope: Equatable, Sendable {
    let frame: CGRect
    let candidates: [OSAtlasSemanticAccessibilityClickCandidate]
}

enum OSAtlasSemanticAccessibilityClickCorrection {
    /// Returns a center point only when one distinct, enabled actionable
    /// control strongly matches the typed planner's target purpose. Candidate
    /// collection is separately restricted to the focused window/web area.
    static func correctedPoint(
        predicted: CGPoint,
        targetHint: String,
        scope: OSAtlasSemanticAccessibilityClickScope
    ) -> CGPoint? {
        guard predicted.x.isFinite, predicted.y.isFinite,
              scope.frame.origin.x.isFinite,
              scope.frame.origin.y.isFinite,
              scope.frame.width.isFinite,
              scope.frame.height.isFinite,
              scope.frame.width > 0,
              scope.frame.height > 0,
              scope.frame.contains(predicted),
              !meaningfulTokens(targetHint).isEmpty else {
            return nil
        }

        var unique: [String: OSAtlasSemanticAccessibilityClickCandidate] = [:]
        for candidate in scope.candidates where
            candidate.isEnabled && candidate.isActionable &&
            candidate.frame.origin.x.isFinite &&
            candidate.frame.origin.y.isFinite &&
            candidate.frame.width.isFinite &&
            candidate.frame.height.isFinite &&
            candidate.frame.width > 0 && candidate.frame.height > 0 &&
            scope.frame.contains(CGPoint(
                x: candidate.frame.midX,
                y: candidate.frame.midY)) &&
            stronglyMatches(
                targetHint: targetHint,
                candidateLabel: candidate.label) {
            unique[candidate.identity] = candidate
        }
        guard unique.count == 1, let candidate = unique.values.first else {
            return nil
        }
        return CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
    }

    /// Derives a second, AX-only hint from one ordered pointer clause in the
    /// authoritative user request. Foundation's generated hint remains the
    /// visual-grounding input and is always tried first. This fallback exists
    /// for icon descriptions such as “diagonal navigation glyph” and positional
    /// descriptions such as “the tab on the right”, where the generated words
    /// describe appearance or layout but omit the accessible purpose.
    ///
    /// The generated hint must uniquely anchor one affirmative pointer clause,
    /// that clause must be the next unperformed pointer clause, and it must add
    /// substantive purpose words. A one-word purpose is accepted only for a
    /// layout-qualified hint that also carries that exact task anchor. Quoted
    /// payloads, negated commands, the rest of the task, and visible page text
    /// cannot contribute.
    static func trustedTaskFallbackHint(
        trustedTask: String,
        proposedTargetHint: String,
        history: [String],
        frontmostApplication: String? = nil,
        frontmostApplicationIdentityIsAuthoritative: Bool = false
    ) -> String? {
        guard case .bound = AppleFoundationVisualActionRouter
            .taskBoundOrderedPointerResolution(
                for: trustedTask,
                history: history,
                availableDirectives: [.click, .doubleClick, .rightClick],
                historyIsComplete: true,
                frontmostApplication: frontmostApplication,
                frontmostApplicationIdentityIsAuthoritative:
                    frontmostApplicationIdentityIsAuthoritative) else {
            return nil
        }
        let task = AppleFoundationVisualActionRouter
            .taskTextMaskingQuotedContent(trustedTask)
        let words = canonicalTokens(task)
        let proposedAnchors = Set(anchorTokens(proposedTargetHint))
        guard !words.isEmpty, !proposedAnchors.isEmpty else { return nil }

        let pointerVerbs: Set<String> = [
            "activate", "choose", "click", "press", "select", "tap",
        ]
        let orderedActionVerbs = pointerVerbs.union([
            "answer", "copy", "drag", "enter", "report", "scroll",
            "tell", "type", "wait", "write",
        ])
        let pointerStarts = words.indices.filter { index in
            pointerVerbs.contains(words[index])
                && !isLocallyNegated(index: index, words: words)
        }
        guard !pointerStarts.isEmpty else { return nil }

        var clauses: [[String]] = []
        clauses.reserveCapacity(pointerStarts.count)
        for start in pointerStarts {
            let searchStart = words.index(after: start)
            let end = words[searchStart...].indices.first(where: { index in
                orderedActionVerbs.contains(words[index])
                    && !isLocallyNegated(index: index, words: words)
            }) ?? words.endIndex
            clauses.append(Array(words[start ..< end]))
        }

        let genericAnchors: Set<String> = [
            "button", "control", "field", "icon", "item", "link", "row",
            "tab",
        ]
        let positionalAnchors: Set<String> = [
            "above", "adjacent", "below", "beside", "bottom", "center",
            "central", "first", "hand", "inactive", "last", "left",
            "lower", "middle", "near", "nearby", "next", "other",
            "previous", "right", "second", "side", "top", "upper",
            "unselected",
        ]
        let completedPointerActions = history.filter { entry in
            ["CLICK", "DOUBLE_CLICK", "RIGHT_CLICK"].contains { prefix in
                entry == prefix || entry.hasPrefix("\(prefix) [[")
            }
        }.count
        let anchored = clauses.indices.filter { index in
            let shared = proposedAnchors.intersection(Set(anchorTokens(
                clauses[index].joined(separator: " "))))
            return !shared.subtracting(genericAnchors).isEmpty
        }
        let clauseIndex: Int
        let isPositionalFallback: Bool
        let carriesOnlyCompletedClauseContext: Bool
        if anchored.count == 1, let anchoredClause = anchored.first {
            clauseIndex = anchoredClause
            isPositionalFallback = false
            carriesOnlyCompletedClauseContext = false
        } else if anchored.count > 1,
                  clauses.indices.contains(completedPointerActions),
                  anchored.contains(completedPointerActions),
                  anchored.allSatisfy({ $0 <= completedPointerActions }) {
            // Foundation sometimes retains the purpose of the just-completed
            // click while naming the next target (for example “route details
            // Rates tab”). The raw host history can disambiguate that overlap:
            // accept the next clause only when every other matched clause is
            // already complete. A hint mixing the next action with any future
            // clause still fails closed.
            clauseIndex = completedPointerActions
            isPositionalFallback = false
            carriesOnlyCompletedClauseContext = true
        } else {
            // A layout-only hint has no semantic authority of its own. It may
            // borrow only the next affirmative pointer clause from the user's
            // ordered task. Any substantive generated word (for example
            // "Overview", "Continue", or "Place Order") keeps this path
            // closed instead of being rewritten into a different action.
            let specific = proposedAnchors.subtracting(genericAnchors)
            guard anchored.isEmpty,
                  !specific.isEmpty,
                  specific.isSubset(of: positionalAnchors),
                  clauses.indices.contains(completedPointerActions) else {
                return nil
            }
            clauseIndex = completedPointerActions
            isPositionalFallback = true
            carriesOnlyCompletedClauseContext = false
        }
        guard clauseIndex == completedPointerActions else { return nil }

        let selectedClauseWords = Set(clauses[clauseIndex])
        let unsafeFallbackWords: Set<String> = [
            "buy", "cannot", "delete", "dont", "download", "erase",
            "except", "excluding", "how", "instead", "learn", "never",
            "no", "not", "order", "purchase", "rather", "remove", "save",
            "send", "share", "submit", "trash", "upload", "without",
        ]
        guard selectedClauseWords.isDisjoint(with: unsafeFallbackWords),
              isPositionalFallback || selectedClauseWords.contains("icon")
        else {
            return nil
        }

        let substantive = Set(meaningfulTokens(
            clauses[clauseIndex].joined(separator: " "))).subtracting(
                pointerVerbs)
        // A positional-only hint can safely resolve the next ordinary one-word
        // task target. An anchored hint may do the same only when it contains
        // that task word plus at least one tightly bounded layout qualifier.
        // The exact one-word hint stays on the primary matcher and does not
        // silently acquire broader authority from the task.
        let proposedMeaningful = Set(
            meaningfulTokens(proposedTargetHint)).subtracting(pointerVerbs)
        let anchoredOneWordWithLayout = !isPositionalFallback
            && !carriesOnlyCompletedClauseContext
            && substantive.count == 1
            && substantive.isSubset(of: proposedMeaningful)
            && !proposedMeaningful.subtracting(substantive).isEmpty
            && proposedMeaningful.subtracting(substantive)
                .isSubset(of: positionalAnchors)
        let completedClauseWords = Set(
            clauses.prefix(completedPointerActions).flatMap {
                meaningfulTokens($0.joined(separator: " "))
            }).subtracting(pointerVerbs)
        let anchoredOneWordWithCompletedContext =
            carriesOnlyCompletedClauseContext
            && substantive.count == 1
            && substantive.isSubset(of: proposedMeaningful)
            && !proposedMeaningful.subtracting(substantive).isEmpty
            && proposedMeaningful.subtracting(substantive)
                .isSubset(of: completedClauseWords)
        guard substantive.count >= 2
                || (isPositionalFallback && substantive.count == 1)
                || anchoredOneWordWithLayout
                || anchoredOneWordWithCompletedContext else {
            return nil
        }
        // The Accessibility matcher needs the task-authored target phrase,
        // not the operation that will be performed on it. Keeping the leading
        // pointer verb would turn a safe one-word purpose such as `Rates` into
        // `{select, rate}` and prevent its exact-label match. Remove only that
        // already-validated clause verb rather than weakening the global
        // semantic matcher.
        return String(
            clauses[clauseIndex].dropFirst().joined(separator: " ")
                .prefix(192))
    }

    static func stronglyMatches(
        targetHint: String,
        candidateLabel: String
    ) -> Bool {
        let target = Set(meaningfulTokens(targetHint))
        let candidate = Set(meaningfulTokens(candidateLabel))
        guard !target.isEmpty, !candidate.isEmpty else { return false }
        if target == candidate { return true }

        // A one-word label such as “Rates” must match exactly. Longer labels
        // may include benign operation/context words, but two substantive
        // shared tokens are required before either side may be a subset.
        let shared = target.intersection(candidate)
        guard shared.count >= 2 else { return false }
        return shared == target || shared == candidate
    }

    private static func meaningfulTokens(_ value: String) -> [String] {
        let ignored: Set<String> = [
            "a", "an", "and", "at", "by", "called", "center", "column",
            "control", "field", "file", "folder", "for", "from", "in",
            "item", "label", "link", "named", "new", "of", "on", "only",
            "or", "page", "row", "tab", "target", "that", "the", "then",
            "there", "this", "to", "visible", "which", "with", "without",
            // Appearance alone is not semantic authority. These words are
            // useful to OS-Atlas visually, while the AX match must retain the
            // task purpose/destination that an accessible label describes.
            "arrow", "button", "card", "icon", "shape", "square", "symbol",
        ]
        return canonicalTokens(value)
            .filter { !ignored.contains($0) }
    }

    private static func anchorTokens(_ value: String) -> [String] {
        let ignored: Set<String> = [
            "a", "an", "and", "at", "by", "called", "for", "from",
            "in", "into", "named", "new", "of", "on", "only", "or",
            "page", "screen", "that", "the", "this", "to", "visible",
            "which", "with",
        ]
        let operationWords: Set<String> = [
            "activate", "choose", "click", "press", "select", "tap",
        ]
        return canonicalTokens(value).filter {
            !ignored.contains($0) && !operationWords.contains($0)
        }
    }

    private static func canonicalTokens(_ value: String) -> [String] {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .split(whereSeparator: {
                !CharacterSet.alphanumerics.contains($0)
            })
            .map(String.init)
            .map(Self.canonicalToken)
    }

    private static func isLocallyNegated(
        index: Int,
        words: [String]
    ) -> Bool {
        let lowerBound = max(words.startIndex, index - 4)
        let preceding = Array(words[lowerBound ..< index])
        guard !preceding.isEmpty else { return false }
        if preceding.last == "not" || preceding.contains("never") {
            return true
        }
        if preceding.suffix(2) == ["do", "not"]
            || preceding.suffix(2) == ["don", "t"] {
            return true
        }
        return false
    }

    private static func canonicalToken(_ token: String) -> String {
        if token.count > 5, token.hasSuffix("ing") {
            return String(token.dropLast(3))
        }
        if token.count > 4, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        if token.count > 3,
           token.hasSuffix("s"),
           !["as", "is", "ss", "us", "ws"].contains(where: {
               token.hasSuffix($0)
           }) {
            return String(token.dropLast())
        }
        return token
    }
}

extension OSAtlasGUIAction {
    var historyEntry: String {
        switch self {
        case .click(let x, let y):
            return "CLICK [[\(x),\(y)]]"
        case .doubleClick(let x, let y):
            return "DOUBLE_CLICK [[\(x),\(y)]]"
        case .rightClick(let x, let y):
            return "RIGHT_CLICK [[\(x),\(y)]]"
        case .drag(let fromX, let fromY, let toX, let toY):
            return "DRAG [[\(fromX),\(fromY)]] TO [[\(toX),\(toY)]]"
        case .typeText(let text):
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
            let bounded = escaped.count > 1_000
                ? String(escaped.prefix(1_000))
                : escaped
            if escaped.count > 1_000 {
                // A display prefix is not effect identity. Retain a digest of
                // the exact payload bytes when the history display is clipped.
                let digest = SHA256.hash(data: Data(text.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                return "TYPE [\(bounded)] SHA256 [\(digest)]"
            }
            return "TYPE [\(bounded)]"
        case .scroll(let direction):
            return "SCROLL [\(direction.rawValue)]"
        case .openApplication(let name):
            return "OPEN_APP [\(name)]"
        case .enter:
            return "ENTER"
        case .hotkey(_, _, let displayName):
            return "HOTKEY [\(displayName)]"
        case .wait:
            return "WAIT"
        case .complete:
            return "COMPLETE"
        case .ask:
            return "ASK"
        case .report:
            return "REPORT"
        }
    }
}
