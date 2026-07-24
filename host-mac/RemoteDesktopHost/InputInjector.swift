import AppKit
import CoreGraphics
import Foundation
import os

/// Translates wire-protocol `ControlMessage`s into synthetic macOS
/// events via `CGEvent`. Requires Accessibility permission; without
/// it, `CGEventPost` silently drops the events. The caller should
/// preflight via `AXIsProcessTrusted()` before handing messages here.
///
/// This is a single-threaded actor — all injection goes through the
/// same event source so the host OS sees a coherent stream.
final class InputInjector: @unchecked Sendable {
    static let syntheticEventTag: Int64 = 0x52444D414349 // "RDMACI"

    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "inject")
    private let eventPoster: @Sendable (CGEvent) -> Void
    private let uptime: @Sendable () -> TimeInterval

    // Track the most recent button state so transitions can be
    // synthesized as the right CGEventType.
    private var prevButtons: UInt8 = 0
    private var lastPointer = CGPoint.zero
    private var pressedKeys: [Int: UInt16] = [:]
    private var lastClickButton: CGMouseButton?
    private var lastClickPosition = CGPoint.zero
    private var lastClickUptime: TimeInterval = -.infinity
    private var lastClickCount = 0
    private var activeClickCounts: [UInt32: Int64] = [:]

    init(
        eventPoster: @escaping @Sendable (CGEvent) -> Void = {
            $0.post(tap: .cghidEventTap)
        },
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.eventPoster = eventPoster
        self.uptime = uptime
    }

    func apply(_ message: ControlMessage) {
        _ = apply(message, ifAllowed: { true })
    }

    /// Checks the automation gate while holding the same lock used for event
    /// injection. If a person's WebRTC input closes the gate while an AI
    /// action is queued, that queued action is dropped before it reaches
    /// CGEvent.
    @discardableResult
    func apply(
        _ message: ControlMessage,
        ifAllowed: () -> Bool
    ) -> Bool {
        if case .text(let text) = message {
            return injectText(text, ifAllowed: ifAllowed)
        }
        lock.lock()
        defer { lock.unlock() }
        guard ifAllowed() else {
            releaseHeldInputLocked()
            return false
        }
        switch message {
        case .pointer(let x, let y, let buttons):
            injectPointer(x: x, y: y, buttons: buttons)
        case .scroll(_, _, let dx, let dy, _):
            injectScroll(dx: dx, dy: dy)
        case .key(let usage, let down, let modifiers):
            injectKey(usage: usage, down: down, modifiers: modifiers)
        case .text:
            assertionFailure("Text input is handled one grapheme at a time")
        case .hello, .qos, .bye:
            break   // handled by HostSession, not injection
        }
        return true
    }

    /// Serializes a person's intervention against the same event-posting lock
    /// used by automation. Once this returns, no checked AI event can slip
    /// through after the gate was closed, and any held input is released.
    @discardableResult
    func interruptAutomation(_ closeGate: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let interrupted = closeGate()
        if interrupted { releaseHeldInputLocked() }
        return interrupted
    }

    /// Releases every pointer button and key owned by the current remote-input
    /// stream even when no AI action is presently inside the automation gate.
    /// A visual-sidecar transport can disappear while the person is dragging
    /// or holding a key; relying only on AI cancellation would leave that
    /// native input latched on the Mac.
    func releaseHeldInput() {
        lock.lock()
        defer { lock.unlock() }
        releaseHeldInputLocked()
    }

    // MARK: - Pointer

    private func injectPointer(x: Int, y: Int, buttons: UInt8) {
        let pos = CGPoint(x: x, y: y)
        lastPointer = pos

        // Compute which buttons changed so we emit the right transitions.
        let down = buttons & ~prevButtons
        let up   = prevButtons & ~buttons
        let held = buttons & prevButtons

        // Move first. When buttons are held, the right event type is
        // *Dragged — otherwise `mouseMoved`. macOS needs this to keep
        // hit-testing consistent in apps that watch for drags.
        let moveType: CGEventType = {
            if held & 0b001 != 0 { return .leftMouseDragged }
            if held & 0b010 != 0 { return .rightMouseDragged }
            if held & 0b100 != 0 { return .otherMouseDragged }
            return .mouseMoved
        }()
        post(mouse: moveType, at: pos, button: .left)

        // Button transitions
        if down & 0b001 != 0 { postClickDown(.leftMouseDown, at: pos, button: .left) }
        if up   & 0b001 != 0 { postClickUp(.leftMouseUp, at: pos, button: .left) }
        if down & 0b010 != 0 { postClickDown(.rightMouseDown, at: pos, button: .right) }
        if up   & 0b010 != 0 { postClickUp(.rightMouseUp, at: pos, button: .right) }
        if down & 0b100 != 0 { postClickDown(.otherMouseDown, at: pos, button: .center) }
        if up   & 0b100 != 0 { postClickUp(.otherMouseUp, at: pos, button: .center) }

        prevButtons = buttons
    }

    private func post(
        mouse type: CGEventType,
        at pos: CGPoint,
        button: CGMouseButton,
        clickCount: Int64? = nil
    ) {
        guard let e = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: pos,
            mouseButton: button) else { return }
        if let clickCount {
            e.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        post(e)
    }

    /// macOS does not infer a double-click merely from two synthetic down/up
    /// pairs. The click-state field is what AppKit uses to surface
    /// `NSEvent.clickCount`, so track the same bounded time/position sequence a
    /// physical mouse would produce and stamp both halves of each click.
    private func postClickDown(
        _ type: CGEventType,
        at position: CGPoint,
        button: CGMouseButton
    ) {
        let now = uptime()
        let continuesSequence = lastClickButton == button
            && now - lastClickUptime <= NSEvent.doubleClickInterval
            && hypot(
                position.x - lastClickPosition.x,
                position.y - lastClickPosition.y) <= 4
        let count = continuesSequence ? min(lastClickCount + 1, 3) : 1
        lastClickButton = button
        lastClickPosition = position
        lastClickUptime = now
        lastClickCount = count
        activeClickCounts[button.rawValue] = Int64(count)
        post(mouse: type, at: position, button: button, clickCount: Int64(count))
    }

    private func postClickUp(
        _ type: CGEventType,
        at position: CGPoint,
        button: CGMouseButton
    ) {
        let count = activeClickCounts.removeValue(forKey: button.rawValue) ?? 1
        post(mouse: type, at: position, button: button, clickCount: count)
    }

    // MARK: - Scroll

    private func injectScroll(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        // wheel1 is vertical (pixel-delta), wheel2 is horizontal.
        guard let e = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: dy),
            wheel2: Int32(clamping: dx),
            wheel3: 0) else { return }
        post(e)
    }

    // MARK: - Keys

    private func injectKey(usage: Int, down: Bool, modifiers: UInt16) {
        guard let keyCode = HIDUsage.toMacKeyCode(usage) else {
            log.debug("drop unknown HID usage 0x\(String(usage, radix: 16), privacy: .public)")
            return
        }
        guard let e = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: down) else { return }
        e.flags = flags(from: modifiers)
        post(e)
        if down {
            pressedKeys[usage] = modifiers
        } else {
            pressedKeys.removeValue(forKey: usage)
        }
    }

    private func flags(from mask: UInt16) -> CGEventFlags {
        var f: CGEventFlags = []
        if mask & (1 << 0) != 0 || mask & (1 << 4) != 0 { f.insert(.maskShift) }
        if mask & (1 << 1) != 0 || mask & (1 << 5) != 0 { f.insert(.maskControl) }
        if mask & (1 << 2) != 0 || mask & (1 << 6) != 0 { f.insert(.maskAlternate) }
        if mask & (1 << 3) != 0 || mask & (1 << 7) != 0 { f.insert(.maskCommand) }
        if mask & (1 << 8) != 0 { f.insert(.maskAlphaShift) }
        return f
    }

    // MARK: - Text (IME / soft keyboard fallback)

    private func injectText(
        _ s: String,
        ifAllowed: () -> Bool
    ) -> Bool {
        // Send one complete extended grapheme at a time. A Unicode scalar is
        // not necessarily one UTF-16 code unit: truncating it to `UniChar`
        // corrupts emoji and other supplementary-plane text.
        for character in s {
            lock.lock()
            guard ifAllowed() else {
                releaseHeldInputLocked()
                lock.unlock()
                return false
            }
            var chars = Array(String(character).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(
                stringLength: chars.count,
                unicodeString: &chars)
            if let down { post(down) }
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(
                stringLength: chars.count,
                unicodeString: &chars)
            if let up { post(up) }
            lock.unlock()
        }
        return true
    }

    /// Caller must hold `lock` so releases cannot interleave with another
    /// direct or automated injection.
    private func releaseHeldInputLocked() {
        if prevButtons & 0b001 != 0 {
            post(mouse: .leftMouseUp, at: lastPointer, button: .left)
        }
        if prevButtons & 0b010 != 0 {
            post(mouse: .rightMouseUp, at: lastPointer, button: .right)
        }
        if prevButtons & 0b100 != 0 {
            post(mouse: .otherMouseUp, at: lastPointer, button: .center)
        }
        prevButtons = 0

        let keys = pressedKeys
        pressedKeys.removeAll()
        for (usage, modifiers) in keys {
            guard let keyCode = HIDUsage.toMacKeyCode(usage),
                  let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: keyCode,
                    keyDown: false) else { continue }
            event.flags = flags(from: modifiers)
            post(event)
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Self.syntheticEventTag)
        eventPoster(event)
    }

    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            == syntheticEventTag
    }
}
