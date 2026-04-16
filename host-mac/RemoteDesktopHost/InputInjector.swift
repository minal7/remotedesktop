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
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "inject")

    // Track the most recent button state so transitions can be
    // synthesized as the right CGEventType.
    private var prevButtons: UInt8 = 0
    private var lastPointer = CGPoint.zero

    func apply(_ message: ControlMessage) {
        switch message {
        case .pointer(let x, let y, let buttons):
            injectPointer(x: x, y: y, buttons: buttons)
        case .scroll(_, _, let dx, let dy, _):
            injectScroll(dx: dx, dy: dy)
        case .key(let usage, let down, let modifiers):
            injectKey(usage: usage, down: down, modifiers: modifiers)
        case .text(let s):
            injectText(s)
        case .hello, .qos, .bye:
            break   // handled by HostSession, not injection
        }
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
        if down & 0b001 != 0 { post(mouse: .leftMouseDown,  at: pos, button: .left) }
        if up   & 0b001 != 0 { post(mouse: .leftMouseUp,    at: pos, button: .left) }
        if down & 0b010 != 0 { post(mouse: .rightMouseDown, at: pos, button: .right) }
        if up   & 0b010 != 0 { post(mouse: .rightMouseUp,   at: pos, button: .right) }
        if down & 0b100 != 0 { post(mouse: .otherMouseDown, at: pos, button: .center) }
        if up   & 0b100 != 0 { post(mouse: .otherMouseUp,   at: pos, button: .center) }

        prevButtons = buttons
    }

    private func post(mouse type: CGEventType, at pos: CGPoint, button: CGMouseButton) {
        guard let e = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: pos,
            mouseButton: button) else { return }
        e.post(tap: .cghidEventTap)
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
        e.post(tap: .cghidEventTap)
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
        e.post(tap: .cghidEventTap)
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

    private func injectText(_ s: String) {
        for scalar in s.unicodeScalars {
            var chars: [UniChar] = [UniChar(scalar.value & 0xFFFF)]
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            up?.post(tap: .cghidEventTap)
        }
    }
}
