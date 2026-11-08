import Foundation

struct ComputerUseSignInPageStatus: Equatable {
    enum Activity: Equatable {
        case ready, opening, opened, interrupted, failed
        var detail: String? {
            switch self {
            case .ready: return nil
            case .opening: return "Opening sign-in page…"
            case .opened: return "Sign-in page opened"
            case .interrupted: return "Sign-in page request interrupted"
            case .failed: return "Sign-in page request failed"
            }
        }
    }
    enum Warning: Equatable {
        case unsupportedDestination, unsupportedDocument, loadFailed, pageUnavailable, providerError(Int)
        var message: String {
            switch self {
            case .unsupportedDestination: return "This sign-in destination is not supported in the AI browser. Close this window to return."
            case .unsupportedDocument: return "The sign-in page cannot be displayed. Close this window to return."
            case .loadFailed: return "The sign-in page did not finish loading. Check this window or close it to return."
            case .pageUnavailable: return "The sign-in page could not be verified. Check this window or close it to return."
            case .providerError(let code): return "The website returned an error (HTTP \(code)). Check its message or close this window to return."
            }
        }
    }
    static let controlDetail = "You control this window. AI is paused."
    var activity: Activity = .ready
    var warning: Warning?
    var detail: String { warning?.message ?? activity.detail ?? Self.controlDetail }
}

/// One child window's display-only navigation state. A native finish is not
/// authentication, a parent document receipt, or permission to resume AI.
/// Generic identity permits isolated state fixtures without constructing WebKit.
@MainActor
final class ComputerUseSignInNavigation<Navigation: AnyObject> {
    private struct Active {
        let navigation: Navigation
        let warningRevision: UUID
    }
    // Preserve retired identity while native code or a callback retains it,
    // without retaining an unbounded sequence of completed navigation objects.
    private let known = NSHashTable<Navigation>(options: [.weakMemory, .objectPointerPersonality], capacity: 0)
    private var active: Active?
    private var warningRevision = UUID()
    private(set) var revision = UUID()
    private(set) var status = ComputerUseSignInPageStatus()

    func isRetired(_ navigation: Navigation?) -> Bool {
        guard let navigation, known.contains(navigation) else { return false }
        return active?.navigation !== navigation
    }

    @discardableResult
    func start(_ navigation: Navigation?) -> Bool {
        guard let navigation, !known.contains(navigation) else { return false }
        known.add(navigation)
        active = Active(navigation: navigation, warningRevision: warningRevision)
        status.activity = .opening
        revision = UUID()
        return true
    }

    /// Policy warnings have no exact WKNavigation. Keep them independently:
    /// an already-started navigation cannot clear a newer warning on finish.
    func warn(_ warning: ComputerUseSignInPageStatus.Warning) {
        status.warning = warning
        warningRevision = UUID()
        revision = UUID()
    }

    @discardableResult
    func finish(_ navigation: Navigation?, hasSupportedPage: Bool, canClearWarning: Bool) -> Bool {
        guard let navigation else { return false }
        known.add(navigation)
        guard let active, active.navigation === navigation else { return false }
        self.active = nil
        if !hasSupportedPage {
            status.activity = .failed
            if active.warningRevision == warningRevision { warn(.pageUnavailable) }
        } else {
            status.activity = .opened
            if canClearWarning && active.warningRevision == warningRevision { status.warning = nil }
        }
        revision = UUID()
        return true
    }

    @discardableResult
    func fail(_ navigation: Navigation?, cancelled: Bool) -> Bool {
        guard let navigation else { return false }
        known.add(navigation)
        guard let active, active.navigation === navigation else { return false }
        self.active = nil
        status.activity = cancelled ? .interrupted : .failed
        // A cancellation often belongs to replacement or manual navigation.
        // It cannot erase a warning or invent a fresh network failure.
        if !cancelled && active.warningRevision == warningRevision { warn(.loadFailed) }
        revision = UUID()
        return true
    }
}
