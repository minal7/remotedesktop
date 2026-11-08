import CoreGraphics
import Foundation

/// One thing on screen the model can refer to by number. IDs stay stable while
/// the same element persists, so "[12]" keeps meaning the same control between steps.
public struct UIElement: Sendable, Equatable {
    public enum Source: String, Sendable { case accessibility, ocr }

    public var id: Int
    public var role: String
    public var label: String
    public var value: String?
    public var frame: CGRect
    public var enabled = true
    public var focused = false
    public var selected = false
    public var secure = false
    public var editable = false
    public var inModal = false
    public var offscreen = false
    public var source: Source = .accessibility
    /// Index into `Scene.handles`; absent for OCR elements, which are clicked by position.
    public var handle: Int?

    public init(id: Int = 0, role: String, label: String, value: String? = nil, frame: CGRect,
                enabled: Bool = true, focused: Bool = false, selected: Bool = false, secure: Bool = false,
                editable: Bool = false, inModal: Bool = false, offscreen: Bool = false,
                source: Source = .accessibility, handle: Int? = nil) {
        self.id = id; self.role = role; self.label = label; self.value = value; self.frame = frame
        self.enabled = enabled; self.focused = focused; self.selected = selected; self.secure = secure
        self.editable = editable; self.inModal = inModal; self.offscreen = offscreen
        self.source = source; self.handle = handle
    }

    public static let interactiveRoles: Set<String> = [
        "button", "link", "field", "check", "radio", "popup", "menuitem", "tab", "row", "slider",
        "stepper", "toggle", "combo", "search", "cell", "menubutton", "disclosure",
    ]

    public var isInteractive: Bool { Self.interactiveRoles.contains(role) }

    /// Identity across observations: role and label, plus a coarse position so two
    /// identically named controls (say, two "Delete" rows) keep distinct IDs.
    public var identityKey: String {
        let x = Int(frame.midX / 40), y = Int(frame.midY / 40)
        return "\(role)|\(label.prefix(60))|\(x),\(y)"
    }

    /// Same control, position ignored: survives scrolling and window moves.
    public var looseKey: String { "\(role)|\(label.prefix(60))" }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// A complete, host-side snapshot of what the agent can currently see.
public struct Scene: @unchecked Sendable {
    public var appName = ""
    public var bundleID = ""
    public var pid: Int32 = 0
    public var windowTitle = ""
    public var windowFrame: CGRect = .zero
    /// The window's close, minimize and full screen buttons, as the system reports them.
    public var windowButtons: [CGRect] = []
    /// Every frame of the page in front, and how many things the page itself shows.
    public var frameURLs: [String] = []
    public var pageElementCount = 0
    public var otherWindows: [String] = []
    public var menuBar: [String] = []
    public var url: String?
    public var hasModal = false
    public var elements: [UIElement] = []
    public var hiddenAbove = 0
    public var hiddenBelow = 0
    /// OCR ran because accessibility gave too little to work with.
    public var usedOCR = false
    /// AX coverage was poor: the model should be shown pixels.
    public var isVisuallyOpaque = false
    public var fingerprint = ""
    public var screenshot: ScreenFrame?
    /// AXUIElement references kept host-side. Elements index into this by `handle`.
    var handles: [AXHandle] = []
    var windowHandle: AXHandle?

    public init() {}

    public func element(id: Int) -> UIElement? { elements.first { $0.id == id } }
    public var focused: UIElement? { elements.first { $0.focused } }

    /// All visible text, in reading order: the raw material for `read`.
    public var fullText: String {
        elements.compactMap { element -> String? in
            let text = element.value.map { "\(element.label) \($0)" } ?? element.label
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }.joined(separator: "\n")
    }
}

/// Keeps IDs stable between scenes. Exact match first, then a loose match so a
/// control that merely moved (scroll, window drag) keeps its number.
public final class ElementIDAllocator: @unchecked Sendable {
    private var next = 1
    private var exact: [String: Int] = [:]
    private var loose: [String: [Int]] = [:]

    public init() {}

    public func assign(_ elements: inout [UIElement]) {
        var nextExact: [String: Int] = [:]
        var nextLoose: [String: [Int]] = [:]
        var used = Set<Int>()
        // First pass: exact identities keep their numbers.
        for index in elements.indices {
            let key = elements[index].identityKey
            if let id = exact[key], !used.contains(id) {
                elements[index].id = id
                used.insert(id)
            } else {
                elements[index].id = 0
            }
        }
        // Second pass: moved controls.
        for index in elements.indices where elements[index].id == 0 {
            if let id = loose[elements[index].looseKey]?.first(where: { !used.contains($0) }) {
                elements[index].id = id
                used.insert(id)
            }
        }
        for index in elements.indices {
            if elements[index].id == 0 {
                elements[index].id = next
                used.insert(next)
                next += 1
            }
            nextExact[elements[index].identityKey] = elements[index].id
            nextLoose[elements[index].looseKey, default: []].append(elements[index].id)
        }
        exact = nextExact
        loose = nextLoose
    }
}

/// What changed between two scenes, in words a small model can act on.
public struct SceneDiff: Sendable, Equatable {
    public var appChanged: String?
    public var windowChanged: String?
    public var urlChanged: String?
    public var modalOpened = false
    public var modalClosed = false
    public var added: [UIElement] = []
    public var removedCount = 0
    public var valueChanges: [(label: String, value: String)] = []
    public var focusChanged: String?
    public var pixelsChanged = false

    public static func == (lhs: SceneDiff, rhs: SceneDiff) -> Bool { lhs.summary == rhs.summary }

    public init() {}

    public init(from old: Scene, to new: Scene) {
        if old.bundleID != new.bundleID { appChanged = new.appName }
        if old.windowTitle != new.windowTitle { windowChanged = new.windowTitle }
        if old.url != new.url, let url = new.url { urlChanged = url }
        modalOpened = !old.hasModal && new.hasModal
        modalClosed = old.hasModal && !new.hasModal
        let oldIDs = Dictionary(old.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.elements.map(\.id))
        added = new.elements.filter { oldIDs[$0.id] == nil }
        removedCount = oldIDs.keys.filter { !newIDs.contains($0) }.count
        for element in new.elements {
            guard let previous = oldIDs[element.id], !element.secure,
                  previous.value != element.value, let value = element.value else { continue }
            valueChanges.append((element.label, value))
        }
        if old.focused?.id != new.focused?.id, let focus = new.focused {
            focusChanged = focus.label.isEmpty ? focus.role : "\(focus.role) \"\(focus.label.prefix(40))\""
        }
        if let a = old.screenshot?.signature, let b = new.screenshot?.signature {
            pixelsChanged = ScreenFrame.distance(a, b) > 0.0006
        }
    }

    /// Any effect at all. Pixel change counts: canvas apps change nothing else.
    public var isEmpty: Bool {
        appChanged == nil && windowChanged == nil && urlChanged == nil && !modalOpened && !modalClosed
            && added.isEmpty && removedCount == 0 && valueChanges.isEmpty && focusChanged == nil && !pixelsChanged
    }

    /// Bounded text fed back to the model as the result of its last action.
    public var summary: String {
        var parts: [String] = []
        if let appChanged { parts.append("now in app \(appChanged)") }
        if let windowChanged { parts.append("window is now \"\(windowChanged.prefix(60))\"") }
        if let urlChanged { parts.append("page is now \(urlChanged.prefix(100))") }
        if modalOpened { parts.append("a dialog opened") }
        if modalClosed { parts.append("the dialog closed") }
        if let focusChanged { parts.append("focus moved to \(focusChanged)") }
        for change in valueChanges.prefix(2) {
            parts.append("\"\(change.label.prefix(30))\" now reads \"\(change.value.prefix(60))\"")
        }
        if !added.isEmpty || removedCount > 0 {
            // A few small changes are usually the point (a display, a status line): quote
            // them in full. A big change gets a count, since the screen is listed anyway.
            let named = added.filter { !$0.label.isEmpty }
            if added.count <= 3, !named.isEmpty {
                let quoted = named.map { "\"\($0.label.prefix(50))\"" }.joined(separator: ", ")
                parts.append("now shows \(quoted)")
            } else {
                let names = named.prefix(3).map { "\"\($0.label.prefix(24))\"" }.joined(separator: ", ")
                parts.append("\(added.count) items appeared\(names.isEmpty ? "" : " such as \(names)"), \(removedCount) went away")
            }
        }
        if parts.isEmpty { return pixelsChanged ? "the screen changed" : "nothing changed on screen" }
        return parts.joined(separator: "; ")
    }
}
