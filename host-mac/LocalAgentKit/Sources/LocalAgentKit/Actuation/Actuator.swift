import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Physical input. The host app implements this over its gated InputInjector, so
/// Stop and takeover cut off the agent at the exact same boundary as everything
/// else. The CLI uses `DirectInputSink`.
public protocol InputSink: Sendable {
    func mayAct() -> Bool
    func move(to point: CGPoint) async throws
    func click(at point: CGPoint, right: Bool, count: Int) async throws
    func drag(from: CGPoint, to: CGPoint) async throws
    func scroll(at point: CGPoint, dx: Int, dy: Int) async throws
    func key(code: CGKeyCode, flags: CGEventFlags) async throws
    func type(_ text: String) async throws
    /// Runs an AX mutation or app launch under the same gate as synthesized input.
    func perform(_ effect: () throws -> Void) throws
    /// Modifier keys for the clicks that follow.
    func hold(flags: CGEventFlags)
}

public extension InputSink {
    func hold(flags: CGEventFlags) {}
}

public enum ActuationError: Error, CustomStringConvertible {
    case stopped
    case elementGone
    case disabled(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .stopped: return "stopped by the user"
        case .elementGone: return "that element no longer exists on screen"
        case .disabled(let name): return "\"\(name)\" is disabled"
        case .unavailable(let detail): return detail
        }
    }
}

/// Turns tool calls into effects. Prefers semantic accessibility actions, since
/// they work on covered windows and don't move the person's cursor, and falls back
/// to real input only if the semantic route didn't take.
public final class Actuator: @unchecked Sendable {
    public let input: any InputSink
    /// Where web addresses open. Unset means the person's default browser.
    public var urlOpener: (@Sendable (URL) async throws -> Void)?
    /// Decides an app opening first. Returns the app's name when handled, nil to open it normally.
    public var appOpener: (@Sendable (String) async throws -> String?)?

    public init(input: any InputSink) { self.input = input }

    // MARK: Click

    /// `viaPointer` is the fallback route, used when AXPress reported success but changed nothing.
    public func click(_ element: UIElement, in scene: Scene, right: Bool = false, count: Int = 1, viaPointer: Bool = false) async throws -> String {
        guard element.enabled else { throw ActuationError.disabled(element.label) }
        let handle = element.handle.flatMap { $0 < scene.handles.count ? scene.handles[$0] : nil }
        if let handle, element.offscreen {
            AXUIElementPerformAction(handle.element, "AXScrollToVisible" as CFString)
            try await Task.sleep(for: .milliseconds(250))
        }
        if !right, count == 1, !viaPointer, let handle, Self.prefersPress(element) {
            let actions = AX.actions(handle.element)
            if actions.contains(kAXPressAction as String) {
                var result = AXError.failure
                try input.perform { result = AXUIElementPerformAction(handle.element, kAXPressAction as CFString) }
                if result == .success { return "pressed" }
            }
        }
        let point = handle.flatMap { AX.frame($0.element) }.map { CGPoint(x: $0.midX, y: $0.midY) } ?? element.center
        try await activate(scene)
        try await input.click(at: point, right: right, count: count)
        return "clicked"
    }

    private static func prefersPress(_ element: UIElement) -> Bool {
        element.source == .accessibility && !element.editable && element.role != "text" && element.role != "image"
    }

    // MARK: Text

    public func type(_ text: String, into element: UIElement?, in scene: Scene, clear: Bool, submit: Bool) async throws -> String {
        if let element {
            guard element.enabled else { throw ActuationError.disabled(element.label) }
            if element.secure { throw ActuationError.unavailable("password fields are left to the person") }
            _ = try await focus(element, in: scene)
        } else {
            try await activate(scene)
        }
        if clear {
            try await input.key(code: KeyMap.code(for: "a")!, flags: .maskCommand)
            try await input.key(code: KeyMap.code(for: "delete")!, flags: [])
        }
        try await input.type(text)
        // Apps process typed events after we've posted them.
        try await Task.sleep(for: .milliseconds(min(800, 120 + text.count * 12)))
        if submit {
            try await Task.sleep(for: .milliseconds(120))
            try await input.key(code: KeyMap.code(for: "return")!, flags: [])
        }
        return "typed"
    }

    @discardableResult
    private func focus(_ element: UIElement, in scene: Scene) async throws -> Bool {
        try await activate(scene)
        if let index = element.handle, index < scene.handles.count {
            let handle = scene.handles[index]
            var result = AXError.failure
            try input.perform { result = AXUIElementSetAttributeValue(handle.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            if result == .success, AX.bool(handle.element, kAXFocusedAttribute) == true { return true }
        }
        try await input.click(at: Self.focusPoint(for: element, in: scene), right: false, count: 1)
        try await Task.sleep(for: .milliseconds(120))
        return true
    }

    /// Where to click to put the caret in this element. Text read from pixels is
    /// usually a label beside its field, not the field, so aim just past the label.
    static func focusPoint(for element: UIElement, in scene: Scene) -> CGPoint {
        guard element.source == .ocr, !element.editable else { return element.center }
        let label = element.label.trimmingCharacters(in: .whitespaces)
        guard label.hasSuffix(":") || label.count <= 24 else { return element.center }
        // Find the box itself if one is drawn, so a short gap or a narrow box still works.
        let start = CGPoint(x: element.frame.maxX + 3, y: element.frame.midY)
        let edge = scene.screenshot?.firstEdge(rightOf: start, within: 160)
        let target = CGPoint(x: edge.map { $0 + 14 } ?? element.frame.maxX + 40, y: element.frame.midY)
        // Other text there means it isn't an empty field to the right; take the label itself.
        let occupied = scene.elements.contains { other in
            other.id != element.id && other.frame.insetBy(dx: -6, dy: -4).contains(target)
        }
        let inWindow = scene.windowFrame.isEmpty || scene.windowFrame.contains(target)
        return inWindow && (!occupied || label.hasSuffix(":")) ? target : element.center
    }

    // MARK: Keys

    public func press(_ chord: String, in scene: Scene) async throws {
        let parsed = try KeyMap.parse(chord)
        try await activate(scene)
        try await input.key(code: parsed.code, flags: parsed.flags)
    }

    // MARK: Scroll

    public func scroll(direction: String, amount: Int, at element: UIElement?, in scene: Scene) async throws {
        let point = element?.center ?? CGPoint(x: scene.windowFrame.midX, y: scene.windowFrame.midY)
        try await activate(scene)
        try await input.move(to: point)
        let ticks = max(1, min(amount, 30))
        let distance = ticks * 5
        switch direction {
        case "up": try await input.scroll(at: point, dx: 0, dy: distance)
        case "down": try await input.scroll(at: point, dx: 0, dy: -distance)
        case "left": try await input.scroll(at: point, dx: distance, dy: 0)
        case "right": try await input.scroll(at: point, dx: -distance, dy: 0)
        default: throw ActuationError.unavailable("scroll direction must be up, down, left or right")
        }
    }

    public func drag(from: CGPoint, to: CGPoint, in scene: Scene) async throws {
        try await activate(scene)
        try await input.drag(from: from, to: to)
    }

    public func move(to point: CGPoint, in scene: Scene) async throws {
        try await activate(scene)
        try await input.move(to: point)
    }

    /// Scrolls by an amount the model chose, at a place it chose or the window's middle.
    /// Models count scroll in pixels of their own grid; positive means up.
    public func scroll(pixels: Double, horizontal: Bool, at point: CGPoint?, in scene: Scene) async throws {
        let target = point ?? CGPoint(x: scene.windowFrame.midX, y: scene.windowFrame.midY)
        try await activate(scene)
        try await input.move(to: target)
        let extent = horizontal ? scene.windowFrame.width : scene.windowFrame.height
        let lines = max(1, min(60, Int(abs(pixels) / 1_000 * extent / 12)))
        let signed = pixels > 0 ? lines : -lines
        try await input.scroll(at: target, dx: horizontal ? signed : 0, dy: horizontal ? 0 : signed)
    }

    /// Types at the current focus, with no field lookup and no Select All. A trailing
    /// newline becomes Return, the way these models were trained to submit.
    public func typeAtFocus(_ text: String, in scene: Scene) async throws {
        try await activate(scene)
        let submit = text.hasSuffix("\n")
        let body = submit ? String(text.dropLast()) : text
        if !body.isEmpty { try await input.type(body) }
        if submit { try await press("return", in: scene) }
        try await Task.sleep(for: .milliseconds(120))
    }

    /// Linux-trained models say ctrl where a Mac wants Command to pick several things.
    public func hold(modifiers: [String]) {
        var flags: CGEventFlags = []
        for key in modifiers.map({ $0.lowercased() }) {
            switch key {
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            default: flags.insert(.maskCommand)
            }
        }
        input.hold(flags: flags)
    }

    public func clickAt(_ point: CGPoint, in scene: Scene, right: Bool = false, count: Int = 1) async throws {
        try await activate(scene)
        try await input.click(at: point, right: right, count: count)
    }

    // MARK: Apps and URLs

    public func openApp(named name: String) async throws -> String {
        if let handled = try await appOpener?(name) { return handled }
        guard let url = AppCatalog.shared.resolve(name) else {
            throw ActuationError.unavailable("no installed app is called \"\(name)\". Installed apps with similar names: \(AppCatalog.shared.suggestions(for: name).joined(separator: ", "))")
        }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let appName = url.deletingPathExtension().lastPathComponent
        if input.mayAct() == false { throw ActuationError.stopped }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // Launching and coming forward aren't the same; wait for the second.
        for _ in 0..<40 {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID { return appName }
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID ?? "").first?.activate()
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ActuationError.unavailable("\(appName) opened but did not come to the front")
    }

    public func openURL(_ raw: String) async throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ActuationError.unavailable("only http and https addresses can be opened")
        }
        if input.mayAct() == false { throw ActuationError.stopped }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let urlOpener {
            try await urlOpener(url)
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
        return url.absoluteString
    }

    // MARK: Menus

    public enum MenuOutcome: Sendable, Equatable {
        case pressed(String)
        case listing(parent: String, items: [String])
    }

    /// Walks "File > Save As…". Stops short of a press and lists items if the path
    /// ends on a submenu, so the model can drill down without seeing every menu at once.
    public func menu(path: String, in scene: Scene) async throws -> MenuOutcome {
        let app = AXUIElementCreateApplication(scene.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else {
            throw ActuationError.unavailable("\(scene.appName) has no menu bar")
        }
        let wanted = path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var level = bar
        var trail: [String] = []
        for (index, name) in wanted.enumerated() {
            let items = Self.menuItems(of: level)
            guard let match = Self.bestMenuMatch(name, in: items) else {
                let available = items.compactMap { $0.title }.prefix(30).joined(separator: ", ")
                throw ActuationError.unavailable("no menu item \"\(name)\". Available: \(available)")
            }
            trail.append(match.title ?? name)
            let isLast = index == wanted.count - 1
            guard let submenu = AX.children(match.element).first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) else {
                guard isLast else { throw ActuationError.unavailable("\"\(match.title ?? name)\" has no submenu") }
                if AX.bool(match.element, kAXEnabledAttribute) == false { throw ActuationError.disabled(match.title ?? name) }
                let element = AXHandle(match.element)
                var result = AXError.failure
                try input.perform { result = AXUIElementPerformAction(element.element, kAXPressAction as CFString) }
                guard result == .success else { throw ActuationError.unavailable("the menu item did not respond") }
                return .pressed(trail.joined(separator: " > "))
            }
            level = submenu
            if isLast {
                let names = Self.menuItems(of: submenu).compactMap { item -> String? in
                    guard let title = item.title else { return nil }
                    return AX.bool(item.element, kAXEnabledAttribute) == false ? "\(title) (disabled)" : title
                }
                return .listing(parent: trail.joined(separator: " > "), items: names)
            }
        }
        // Empty path: top-level menu names.
        return .listing(parent: "menu bar", items: Self.menuItems(of: bar).compactMap(\.title))
    }

    /// One line per menu with what can be chosen right now. Leaves out the app's own menu and
    /// Help, which a task rarely needs and which would crowd out the rest.
    public func menuOutline(pid: pid_t, limit: Int = 1_500) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return nil }
        var lines: [String] = []
        var used = 0
        for menu in Self.menuItems(of: bar).dropFirst() where menu.title != "Help" {
            guard let title = menu.title,
                  let submenu = AX.children(menu.element).first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) else { continue }
            let items = Self.menuItems(of: submenu).filter { AX.bool($0.element, kAXEnabledAttribute) != false }.compactMap(\.title)
            guard !items.isEmpty else { continue }
            let line = "\(title): \(items.joined(separator: ", "))"
            guard used + line.count <= limit else { break }
            used += line.count
            lines.append(line)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private struct MenuItem { let element: AXUIElement; let title: String? }

    private static func menuItems(of element: AXUIElement) -> [MenuItem] {
        AX.children(element).compactMap { child in
            let title = AX.string(child, kAXTitleAttribute)?.nilIfBlank
            if title == nil, AX.string(child, kAXRoleAttribute) == kAXMenuItemRole { return nil }
            return MenuItem(element: child, title: title)
        }.filter { $0.title != "Apple" }
    }

    private static func bestMenuMatch(_ name: String, in items: [MenuItem]) -> MenuItem? {
        func normalize(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        let target = normalize(name)
        return items.first { normalize($0.title ?? "") == target }
            ?? items.first { normalize($0.title ?? "").hasPrefix(target) }
            ?? items.first { normalize($0.title ?? "").contains(target) }
    }

    // MARK: Focus

    /// Real input lands on whatever is in front, so make sure that's our app and window.
    public func activate(_ scene: Scene) async throws {
        guard input.mayAct() else { throw ActuationError.stopped }
        guard scene.pid != 0 else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != scene.bundleID {
            let running = NSRunningApplication(processIdentifier: scene.pid)
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: scene.bundleID).first
            running?.activate()
            try await Task.sleep(for: .milliseconds(180))
        }
        if let window = scene.windowHandle {
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
    }
}

/// Every installed app, so `open_app` can launch anything, not a fixed list.
public final class AppCatalog: @unchecked Sendable {
    public static let shared = AppCatalog()

    private let lock = NSLock()
    private var apps: [(name: String, url: URL)] = []
    private var loadedAt = Date.distantPast

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(loadedAt) > 60 else { return }
        var found: [(String, URL)] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for root in ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", "\(home)/Applications", "/System/Library/CoreServices/Applications"] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                found.append(((entry as NSString).deletingPathExtension, URL(fileURLWithPath: root).appendingPathComponent(entry)))
            }
            // One level of grouping folders, such as Microsoft Office or Adobe suites.
            for entry in entries where !entry.hasSuffix(".app") && root == "/Applications" {
                let folder = (root as NSString).appendingPathComponent(entry)
                for nested in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where nested.hasSuffix(".app") {
                    found.append(((nested as NSString).deletingPathExtension, URL(fileURLWithPath: folder).appendingPathComponent(nested)))
                }
            }
        }
        apps = found.map { (name: $0.0, url: $0.1) }
        loadedAt = Date()
    }

    public func resolve(_ name: String) -> URL? {
        load()
        let wanted = Self.normalize(name)
        guard !wanted.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let exact = apps.first(where: { Self.normalize($0.name) == wanted }) { return exact.url }
        let prefix = apps.filter { Self.normalize($0.name).hasPrefix(wanted) }
        if prefix.count == 1 { return prefix[0].url }
        let contains = apps.filter { Self.normalize($0.name).contains(wanted) }
        if contains.count == 1 { return contains[0].url }
        if let installed = (prefix + contains).min(by: { $0.name.count < $1.name.count })?.url { return installed }
        // An app can be open without living in a standard folder, as old and in-house software often does.
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && Self.normalize($0.localizedName ?? "").contains(wanted)
        }?.bundleURL
    }

    public func suggestions(for name: String) -> [String] {
        load()
        let wanted = Set(Self.normalize(name))
        lock.lock(); defer { lock.unlock() }
        return apps.map(\.name).sorted {
            Set(Self.normalize($0)).intersection(wanted).count > Set(Self.normalize($1)).intersection(wanted).count
        }.prefix(5).map { $0 }
    }

    private static func normalize(_ name: String) -> String {
        var text = name.lowercased()
        if text.hasSuffix(".app") { text.removeLast(4) }
        return text.filter { $0.isLetter || $0.isNumber }
    }
}

/// Key names and chords as a small model tends to write them.
public enum KeyMap {
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    public static func code(for key: String) -> CGKeyCode? { codes[key.lowercased()] }

    public static func parse(_ chord: String) throws -> (code: CGKeyCode, flags: CGEventFlags) {
        let parts = chord.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let last = parts.last else { throw ActuationError.unavailable("empty key") }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "meta", "super", "win": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw ActuationError.unavailable("unknown modifier \"\(part)\"")
            }
        }
        let aliases = ["arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down", "del": "delete"]
        guard let code = codes[aliases[last] ?? last] else { throw ActuationError.unavailable("unknown key \"\(last)\"") }
        return (code, flags)
    }
}

/// Direct CGEvent input for the CLI and tests. The host app uses its own sink.
public final class DirectInputSink: InputSink, @unchecked Sendable {
    /// Marks our events so a watcher can tell them from a real person's.
    public static let eventTag: Int64 = 0x4C41_4355_41

    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = DirectInputSink.eventTag
        return source
    }()
    private let gate: @Sendable () -> Bool

    private let fence: (@Sendable () -> String?)?
    private let pointFence: (@Sendable (CGPoint) -> String?)?

    /// `fence` names why input may not land on what is in front right now, if so. It also stops
    /// the shortcuts that switch apps. `pointFence` does the same for a place on the screen,
    /// because a click lands on the window under it, whichever app is in front. Test runs use
    /// these to keep off the person's own apps.
    public init(mayAct: @escaping @Sendable () -> Bool = { true }, fence: (@Sendable () -> String?)? = nil,
                pointFence: (@Sendable (CGPoint) -> String?)? = nil) {
        gate = mayAct
        self.fence = fence
        self.pointFence = pointFence
    }

    private let heldLock = NSLock()
    private var heldFlags: CGEventFlags = []

    public func hold(flags: CGEventFlags) {
        heldLock.lock()
        heldFlags = flags
        heldLock.unlock()
    }

    private func currentlyHeld() -> CGEventFlags {
        heldLock.lock()
        defer { heldLock.unlock() }
        return heldFlags
    }

    private func guardAct(at point: CGPoint) throws {
        try guardAct()
        if let reason = pointFence?(point) { throw ActuationError.unavailable(reason) }
    }

    public func mayAct() -> Bool { gate() }

    private func guardAct() throws {
        guard gate() else { throw ActuationError.stopped }
        if let reason = fence?() { throw ActuationError.unavailable(reason) }
    }

    /// Tab or Space with a modifier: Command-Tab, Spotlight, input-source and app switchers.
    static func switchesApps(code: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard code == 48 || code == 49 else { return false }
        return !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }

    /// Every event says its own modifiers rather than inheriting whatever is current.
    private func post(_ event: CGEvent?, flags: CGEventFlags = []) {
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    public func perform(_ effect: () throws -> Void) throws {
        try guardAct()
        try effect()
    }

    public func move(to point: CGPoint) async throws {
        try guardAct(at: point)
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }

    public func click(at point: CGPoint, right: Bool, count: Int) async throws {
        try guardAct(at: point)
        try await move(to: point)
        try await Task.sleep(for: .milliseconds(40))
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for clickIndex in 1...max(1, count) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
                post(event, flags: currentlyHeld())
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    public func drag(from: CGPoint, to: CGPoint) async throws {
        try guardAct(at: from)
        try guardAct(at: to)
        try await move(to: from)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
        try await Task.sleep(for: .milliseconds(80))
        for step in 1...12 {
            let t = Double(step) / 12
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
            try await Task.sleep(for: .milliseconds(16))
        }
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
    }

    public func scroll(at point: CGPoint, dx: Int, dy: Int) async throws {
        try guardAct(at: point)
        post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0))
    }

    public func key(code: CGKeyCode, flags: CGEventFlags) async throws {
        try guardAct()
        if fence != nil, Self.switchesApps(code: code, flags: flags) {
            throw ActuationError.unavailable("this run keeps to its own apps, so that shortcut isn't available")
        }
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
            // Modifiers on the key-up would stay in the system state and get inherited
            // by the next event: a later "." becomes Cmd+. and a click becomes Cmd-click.
            post(event, flags: isDown ? flags : [])
        }
    }

    public func type(_ text: String) async throws {
        for character in text {
            try guardAct()
            if character == "\n" { try await key(code: 36, flags: []); continue }
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}
