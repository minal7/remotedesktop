import AppKit
import ApplicationServices
import Foundation

@MainActor
final class AgentNativeBackend: AgentMacBackend {
    typealias Picker = @MainActor ([String]) async throws -> String
    private let reader = AgentMacAccessibility()
    private let injector: InputInjector
    private let allowed: () -> Bool
    private let registry: AgentAppRegistry
    private let finder: AgentWebFileFinder?
    private let picker: Picker?
    private var stopped = false
    private var suspended = false

    init(injector: InputInjector, registry: AgentAppRegistry, allowed: @escaping () -> Bool,
         finder: AgentWebFileFinder? = nil, picker: Picker? = nil) {
        self.injector = injector; self.registry = registry; self.allowed = allowed
        self.finder = finder; self.picker = picker
    }

    func snapshot() async throws -> AgentMacSnapshot {
        try checkActive()
        let window = try reader.window()
        let before = try reader.tree(window, size: window.bounds.size)
        let image = try await reader.capture(window)
        try checkWindow(window.identity)
        let tree = try reader.tree(window, size: .init(width: image.width, height: image.height))
        try checkWindow(window.identity)
        guard before.consistencyDigest == tree.consistencyDigest,
              before.authorityDigest == tree.authorityDigest else { throw AgentEnvironmentError.targetChanged }
        return .init(identity: window.identity, bundleID: window.application.bundleIdentifier!, title: window.title,
                     screenshot: try reader.png(image, masking: tree.secureRects), elements: tree.elements, focus: tree.focus,
                     authorityDigest: tree.authorityDigest)
    }

    func perform(_ action: AgentAction, snapshot: AgentMacSnapshot) async throws -> String {
        try checkWindow(snapshot.identity)
        switch action {
        case let .click(target, button, count):
            try click(target, button: button ?? .left, count: count ?? 1, snapshot: snapshot)
        case let .type(target, text, mode):
            try type(target, text: text, mode: mode, snapshot: snapshot)
        case let .key(chord):
            try key(chord, snapshot: snapshot)
        case let .scroll(target, direction, amount):
            let point = try point(target, snapshot: snapshot)
            let distance = Int(min(amount, 10_000).rounded())
            let dx = direction == .right ? distance : direction == .left ? -distance : 0
            let dy = direction == .down ? -distance : direction == .up ? distance : 0
            try post(.scroll(x: Int(point.x), y: Int(point.y), dx: dx, dy: dy, phase: .changed), snapshot: snapshot)
        case let .drag(from, to):
            let start = try point(from, snapshot: snapshot), end = try point(to, snapshot: snapshot)
            try post(.pointer(x: Int(start.x), y: Int(start.y), buttons: 1), snapshot: snapshot)
            do {
                for step in 1...12 {
                    let fraction = Double(step) / 12
                    try post(.pointer(x: Int(start.x + (end.x - start.x) * fraction),
                                      y: Int(start.y + (end.y - start.y) * fraction), buttons: 1), snapshot: snapshot)
                }
                try post(.pointer(x: Int(end.x), y: Int(end.y), buttons: 0), snapshot: snapshot)
            } catch { injector.releaseHeldInput(); throw error }
        case let .select(target, option):
            try setValue(target, text: option, snapshot: snapshot)
        case let .openApp(name):
            let app = try registry.resolve(name)
            try checkWindow(snapshot.identity)
            try await registry.open(app)
        case let .findFiles(query, kind, modifiedAfter):
            guard let finder else { throw AgentEnvironmentError.unavailable("Local file search is unavailable.") }
            let candidates = try await finder(query, kind, modifiedAfter)
            return try AgentFileResults.render(candidates)
        case let .setFiles(_, ids):
            guard let picker else { throw AgentEnvironmentError.unavailable("The native file picker is unavailable.") }
            return try await picker(ids)
        case let .wait(seconds):
            try await Task.sleep(for: .seconds(seconds))
        case .openURL, .askUser, .done, .fail: throw AgentEnvironmentError.unsupportedAction
        }
        return "Action delivered to the bound task window."
    }

    func stop() { stopped = true; injector.releaseHeldInput() }
    func suspend() { suspended = true; injector.releaseHeldInput() }
    func resume() { suspended = false }

    private func type(_ target: AgentTarget?, text: String, mode: AgentTextMode, snapshot: AgentMacSnapshot) throws {
        let element: AgentElement?
        if case let .element(id)? = target { element = snapshot.elements.first { $0.id == id } }
        else if let target, case let .point(x, y) = target { element = AgentTargetBinding.hit(x: x, y: y, elements: snapshot.elements) }
        else { element = snapshot.elements.first { $0.id == snapshot.focus?.id } }
        guard let element, !AgentCredentialRule.isSensitive(role: element.role, name: element.name, state: element.state) else {
            throw AgentEnvironmentError.credentialHandoff
        }
        guard text.utf8.count <= 1_048_576 else { throw AgentEnvironmentError.unsupportedAction }
        let ax = try reader.element(element.id)
        guard !reader.isSensitive(ax) else { throw AgentEnvironmentError.credentialHandoff }
        if reader.editableValueIsSettable(ax) {
            let oldValue = mode == .append ? try reader.fullEditableString(ax) : nil
            let value = mode == .append ? (oldValue ?? "") + text : text
            guard value.utf8.count <= 1_048_576 else { throw AgentEnvironmentError.unsupportedAction }
            try mutate(snapshot) {
                guard !self.reader.isSensitive(ax), self.reader.editableValueIsSettable(ax) else {
                    throw AgentEnvironmentError.credentialHandoff
                }
                if let oldValue, try self.reader.fullEditableString(ax) != oldValue {
                    throw AgentEnvironmentError.targetChanged
                }
                guard AXUIElementSetAttributeValue(ax, kAXValueAttribute as CFString, value as CFString) == .success else {
                    throw AgentEnvironmentError.unavailable("The field refused its new value.")
                }
            }
            return
        }
        if let target { try click(target, button: .left, count: 1, snapshot: snapshot) }
        try requireTextFocus(element.id, snapshot: snapshot)
        if mode == .append { try moveCaretToEnd(ax, id: element.id, snapshot: snapshot) }
        if mode == .replace { try key("cmd+a", snapshot: snapshot, expectedFocusID: element.id) }
        try post(.text(text), snapshot: snapshot, expectedFocusID: element.id)
    }

    private func moveCaretToEnd(_ element: AXUIElement, id: Int, snapshot: AgentMacSnapshot) throws {
        let value = try reader.fullEditableString(element)
        let end = value.utf16.count
        let expected = AgentSelection(start: end, end: end)
        if reader.selectedTextRangeIsSettable(element) {
            try mutate(snapshot) {
                guard !self.reader.isSensitive(element), self.reader.isTextEditable(element),
                      let window = self.reader.currentWindow, window.identity == snapshot.identity,
                      self.reader.focusedTextElementIs(id, in: window),
                      try self.reader.fullEditableString(element) == value,
                      self.reader.selectedTextRangeIsSettable(element) else {
                    throw AgentEnvironmentError.targetChanged
                }
                try self.reader.setSelection(expected, on: element)
            }
        } else {
            try key("cmd+down", snapshot: snapshot, expectedFocusID: id)
        }
        guard try reader.fullEditableString(element) == value,
              AgentNativeTextFocusBinding.caretIsAtEnd(try reader.selection(element, valueLength: end), valueLength: end),
              let window = reader.currentWindow, window.identity == snapshot.identity,
              reader.focusedTextElementIs(id, in: window) else {
            throw AgentEnvironmentError.targetChanged
        }
    }

    private func setValue(_ target: AgentTarget, text: String, snapshot: AgentMacSnapshot) throws {
        guard case let .element(id) = target else { throw AgentEnvironmentError.unsupportedAction }
        let element = try reader.element(id)
        guard !reader.isSensitive(element) else { throw AgentEnvironmentError.credentialHandoff }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { throw AgentEnvironmentError.unsupportedAction }
        try mutate(snapshot) {
            guard !self.reader.isSensitive(element) else { throw AgentEnvironmentError.credentialHandoff }
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
                throw AgentEnvironmentError.unavailable("The control refused the selected value.")
            }
        }
    }

    private func click(_ target: AgentTarget, button: AgentMouseButton, count: Int, snapshot: AgentMacSnapshot) throws {
        guard (1...3).contains(count) else { throw AgentEnvironmentError.unsupportedAction }
        if case let .element(id) = target, button == .left, count == 1 {
            let element = try reader.element(id)
            var names: CFArray?
            if AXUIElementCopyActionNames(element, &names) == .success,
               (names as? [String])?.contains(kAXPressAction) == true {
                try mutate(snapshot) {
                    guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                        throw AgentEnvironmentError.unavailable("The control refused the press action.")
                    }
                }
                return
            }
        }
        let point = try point(target, snapshot: snapshot)
        let buttons: UInt8 = button == .right ? 2 : button == .middle ? 4 : 1
        do {
            for _ in 0..<count {
                try post(.pointer(x: Int(point.x), y: Int(point.y), buttons: buttons), snapshot: snapshot)
                try post(.pointer(x: Int(point.x), y: Int(point.y), buttons: 0), snapshot: snapshot)
            }
        } catch { injector.releaseHeldInput(); throw error }
    }

    private func point(_ target: AgentTarget?, snapshot: AgentMacSnapshot) throws -> CGPoint {
        guard let window = reader.currentWindow, window.identity == snapshot.identity else { throw AgentEnvironmentError.scopeChanged }
        let x: Double, y: Double
        switch target {
        case let .element(id):
            guard let element = snapshot.elements.first(where: { $0.id == id }) else { throw AgentEnvironmentError.targetGone }
            x = element.bbox.x + element.bbox.width / 2; y = element.bbox.y + element.bbox.height / 2
        case let .point(px, py): x = px; y = py
        case nil: x = reader.captureSize.width / 2; y = reader.captureSize.height / 2
        }
        guard x >= 0, y >= 0, x < reader.captureSize.width, y < reader.captureSize.height else { throw AgentEnvironmentError.targetGone }
        return CGPoint(x: window.bounds.minX + x * window.bounds.width / reader.captureSize.width,
                       y: window.bounds.minY + y * window.bounds.height / reader.captureSize.height)
    }

    private func key(_ chord: String, snapshot: AgentMacSnapshot, expectedFocusID: Int? = nil) throws {
        if let expectedFocusID { try requireTextFocus(expectedFocusID, snapshot: snapshot) }
        else { try requireSecureFocusAbsent(snapshot) }
        let stroke = try AgentKeyStroke.parse(chord)
        try injector.applyHostKeyStroke(usage: stroke.usage, modifiers: stroke.modifiers,
                                       ifAllowed: {
                                           guard self.inputAllowed(snapshot) else { return false }
                                           guard let expectedFocusID else { return true }
                                           return self.textFocusIsBound(expectedFocusID, snapshot: snapshot)
                                       }, beforePosting: {})
    }

    private func requireTextFocus(_ expectedID: Int, snapshot: AgentMacSnapshot) throws {
        guard let window = reader.currentWindow, window.identity == snapshot.identity else { throw AgentEnvironmentError.scopeChanged }
        let element = try reader.element(expectedID)
        guard !reader.isSensitive(element) else { throw AgentEnvironmentError.credentialHandoff }
        guard reader.isTextEditable(element) else { throw AgentEnvironmentError.unsupportedAction }
        guard reader.focusedTextElementIs(expectedID, in: window) else { throw AgentEnvironmentError.targetChanged }
    }

    private func textFocusIsBound(_ expectedID: Int, snapshot: AgentMacSnapshot) -> Bool {
        guard let window = reader.currentWindow, window.identity == snapshot.identity,
              let element = try? reader.element(expectedID) else { return false }
        return AgentNativeTextFocusBinding.matches(expectedID: expectedID,
            focusedID: reader.focusedElementID(in: window), isEditable: reader.isTextEditable(element),
            isSecure: reader.isSensitive(element))
    }

    private func requireSecureFocusAbsent(_ snapshot: AgentMacSnapshot) throws {
        guard let window = reader.currentWindow else { throw AgentEnvironmentError.scopeChanged }
        let tree = try reader.tree(window, size: reader.captureSize)
        if let focus = tree.focus, let element = tree.elements.first(where: { $0.id == focus.id }),
           AgentCredentialRule.isSensitive(role: element.role, name: element.name, state: element.state) {
            throw AgentEnvironmentError.credentialHandoff
        }
    }

    private func mutate(_ snapshot: AgentMacSnapshot, _ effect: () throws -> Void) throws {
        try injector.performHostEffectIfAllowed(ifAllowed: { self.inputAllowed(snapshot) }, effect)
    }

    private func post(_ message: ControlMessage, snapshot: AgentMacSnapshot, expectedFocusID: Int? = nil) throws {
        guard injector.apply(message, ifAllowed: {
            guard self.inputAllowed(snapshot) else { return false }
            guard let expectedFocusID else { return true }
            return self.textFocusIsBound(expectedFocusID, snapshot: snapshot)
        }) else { throw CancellationError() }
    }

    private func inputAllowed(_ snapshot: AgentMacSnapshot) -> Bool {
        !stopped && !suspended && !Task.isCancelled && allowed() && (try? reader.window().identity) == snapshot.identity
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped, !suspended, allowed() else { throw CancellationError() }
    }

    private func checkWindow(_ identity: String) throws {
        try checkActive()
        guard try reader.window().identity == identity else { throw AgentEnvironmentError.scopeChanged }
    }
}

enum AgentNativeTextFocusBinding {
    static func matches(expectedID: Int, focusedID: Int?, isEditable: Bool, isSecure: Bool) -> Bool {
        guard expectedID >= 0, focusedID == expectedID, isEditable else { return false }
        return !isSecure
    }

    static func caretIsAtEnd(_ selection: AgentSelection?, valueLength: Int) -> Bool {
        guard valueLength >= 0, let selection else { return false }
        return selection.start == valueLength && selection.end == valueLength
    }
}

enum AgentFileResults {
    static func render(_ candidates: [AgentFileCandidate]) throws -> String {
        let object: [[String: Any]] = candidates.map {
            ["id": $0.id, "name": $0.name, "kind": $0.kind as Any? ?? NSNull(),
             "modified_at": $0.modifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": object], options: [.sortedKeys]), as: UTF8.self)
    }
}

struct AgentKeyStroke: Equatable {
    let usage: Int
    let modifiers: UInt16

    static func parse(_ chord: String) throws -> Self {
        let parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { throw AgentEnvironmentError.unsupportedAction }
        let modifierNames: [String: UInt16] = ["cmd": 8, "command": 8, "super": 8, "ctrl": 2, "control": 2, "shift": 1, "alt": 4, "option": 4]
        var modifiers: UInt16 = 0
        for part in parts.dropLast() {
            guard let mask = modifierNames[part] else { throw AgentEnvironmentError.unsupportedAction }
            modifiers |= mask
        }
        let named: [String: Int] = ["enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29, "backspace": 0x2a,
            "tab": 0x2b, "space": 0x2c, "delete": 0x4c, "home": 0x4a, "end": 0x4d, "pageup": 0x4b,
            "pagedown": 0x4e, "arrowright": 0x4f, "right": 0x4f, "arrowleft": 0x50, "left": 0x50,
            "arrowdown": 0x51, "down": 0x51, "arrowup": 0x52, "up": 0x52]
        let scalar = key.unicodeScalars.count == 1 ? key.unicodeScalars.first?.value : nil
        let usage: Int?
        if let value = scalar, (97...122).contains(value) { usage = Int(value - 97) + 4 }
        else if let value = scalar, (49...57).contains(value) { usage = Int(value - 49) + 0x1e }
        else if key == "0" { usage = 0x27 }
        else if key.first == "f", let number = Int(key.dropFirst()), (1...12).contains(number) { usage = 0x39 + number }
        else { usage = named[key] }
        guard let usage, HIDUsage.toMacKeyCode(usage) != nil else { throw AgentEnvironmentError.unsupportedAction }
        return .init(usage: usage, modifiers: modifiers)
    }
}
