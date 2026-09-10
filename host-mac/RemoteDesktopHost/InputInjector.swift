import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Translates wire-protocol `ControlMessage`s into synthetic macOS
/// events via `CGEvent`. Requires Accessibility permission; without
/// it, `CGEventPost` silently drops the events. The caller should
/// preflight via `AXIsProcessTrusted()` before handing messages here.
///
/// All injection is serialized through one lock and event source. Paced text
/// yields between key transitions while retaining explicit release ownership.
final class InputInjector: @unchecked Sendable {
    static let syntheticEventTag: Int64 = 0x52444D414349 // "RDMACI"
    static let physicalInterventionEventMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp, .rightMouseUp, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]

    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "inject")
    private let eventPoster: @Sendable (CGEvent) -> Void
    private let uptime: @Sendable () -> TimeInterval
    private let physicalInputState: @Sendable () -> PhysicalInputState

    // Track the most recent button state so transitions can be
    // synthesized as the right CGEventType.
    private var prevButtons: UInt8 = 0
    private var lastPointer = CGPoint.zero
    private var pressedKeys: [Int: UInt16] = [:]
    private var pendingUnicodeStroke: (id: UUID, release: CGEvent)?
    private var directInputTransactions = 0
    private var heldInputIsDirect = false
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
        },
        physicalInputState: (@Sendable () -> PhysicalInputState)? = nil
    ) {
        self.eventPoster = eventPoster
        self.uptime = uptime
        // Ordinary deterministic XCTest fixtures must not depend on whatever
        // the person is pressing on the test Mac. Native qualification must
        // explicitly inject readCurrentPhysicalInputState instead.
        if let physicalInputState { self.physicalInputState = physicalInputState }
        else if HostRuntimeContext.isRunningUnitTests { self.physicalInputState = { .released } }
        else { self.physicalInputState = { InputInjector.readCurrentPhysicalInputState() } }
    }

    func apply(_ message: ControlMessage) {
        _ = apply(message, ifAllowed: { true })
    }

    enum AutomationGateError: Error { case interrupted }

    enum AutomationAdmission: Equatable {
        case admitted, inputHeld, inputStateUnavailable, interrupted
    }

    enum PhysicalInputState: Equatable, Sendable {
        case released, held, unavailable
    }

    static func readCurrentPhysicalInputState() -> PhysicalInputState {
        samplePhysicalInputState(isTrusted: { AXIsProcessTrusted() },
            pressedMouseButtons: { UInt(truncatingIfNeeded: NSEvent.pressedMouseButtons) },
            modifierFlags: { NSEvent.modifierFlags },
            keyIsDown: { CGEventSource.keyState(.combinedSessionState, key: $0) })
    }

    /// One bounded admission sample, not a keyboard history. The macOS SDK's
    /// ev_keymap.h defines NX_NUMKEYCODES as 256. Include codes outside our
    /// wire HID mapping and all mouse buttons reported by AppKit.
    static func samplePhysicalInputState(isTrusted: () -> Bool,
        pressedMouseButtons: () -> UInt, modifierFlags: () -> NSEvent.ModifierFlags,
        keyIsDown: (CGKeyCode) -> Bool) -> PhysicalInputState {
        guard isTrusted() else { return .unavailable }
        let momentaryModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]
        guard pressedMouseButtons() == 0,
              modifierFlags().intersection(momentaryModifiers).isEmpty else { return .held }
        for key in UInt16(0)..<UInt16(256) {
            if keyIsDown(key) { return .held }
        }
        // Re-read the cheap aggregate state after the key scan. This remains
        // a sample; event callbacks still fence input arriving afterward.
        guard pressedMouseButtons() == 0,
              modifierFlags().intersection(momentaryModifiers).isEmpty else { return .held }
        return isTrusted() ? .released : .unavailable
    }

    /// A handback cannot activate automation between a direct-input callback
    /// and its last event, or while that input still owns a key/button. The
    /// admission closure must only change the action gate, never inject input.
    func admitAutomation(_ admission: () -> Bool) -> AutomationAdmission {
        lock.lock()
        defer { lock.unlock() }
        guard directInputTransactions == 0, prevButtons == 0,
              pressedKeys.isEmpty, pendingUnicodeStroke == nil else { return .inputHeld }
        switch physicalInputState() {
        case .held: return .inputHeld
        case .unavailable: return .inputStateUnavailable
        case .released: break
        }
        guard admission() else { return .interrupted }
        heldInputIsDirect = false
        return .admitted
    }

    /// Encloses occurrence recording and direct dispatch in one tracked
    /// transaction. Text retains its existing per-grapheme lock yields, but
    /// automation admission stays closed until the entire packet has finished.
    /// The interruption callback runs under this injector's lock and must not
    /// call back into the injector.
    func applyDirectInput(_ message: ControlMessage, interruptAutomation: () -> Bool) {
        switch message {
        case .pointer, .scroll, .key, .text: break
        case .hello, .qos, .bye: return
        }
        lock.lock()
        directInputTransactions += 1
        let interrupted = interruptAutomation()
        if interrupted || !heldInputIsDirect { releaseHeldAutomationInputLocked() }
        heldInputIsDirect = true
        lock.unlock()
        defer {
            lock.lock()
            directInputTransactions -= 1
            lock.unlock()
        }
        apply(message)
    }

    /// AX mutations use the same ownership boundary as synthesized input.
    /// Once interruptAutomation returns, a queued AX setter cannot pass an
    /// earlier gate check and overwrite the person's intervening input.
    func performHostEffectIfAllowed<Value>(
        ifAllowed: () -> Bool,
        _ effect: () throws -> Value
    ) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard ifAllowed() else {
            releaseHeldAutomationInputLocked()
            throw AutomationGateError.interrupted
        }
        return try effect()
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
            releaseHeldAutomationInputLocked()
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

    /// General paced input avoids a synchronous burst of Unicode events.
    /// Verified editing instead admits and reads back each applyTextStroke.
    @MainActor
    func applyTextPaced(_ text: String, ifAllowed: () -> Bool) async -> Bool {
        for character in text {
            guard await applyTextStroke(String(character), ifAllowed: ifAllowed) else { return false }
        }
        return true
    }

    /// Verified text editing calls this once per grapheme and reads back the
    /// resulting value/caret before authorizing another key. The exact-state
    /// predicate applies only before key-down; key-up always releases the key,
    /// even though the edit has already changed that pre-effect state.
    @MainActor
    func applyTextStroke(_ text: String, ifAllowed: () -> Bool,
                         beforePosting: () -> Bool = { true }) async -> Bool {
        guard text.count == 1, !Task.isCancelled,
              let stroke = beginUnicodeStroke(text, ifAllowed: { ifAllowed() && beforePosting() && !Task.isCancelled }) else { return false }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            finishUnicodeStroke(stroke)
            return false
        }
        finishUnicodeStroke(stroke)
        guard ifAllowed(), !Task.isCancelled else { return false }
        do { try await Task.sleep(for: .milliseconds(5)) }
        catch { return false }
        return true
    }

    private func beginUnicodeStroke(_ text: String, ifAllowed: () -> Bool) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard ifAllowed(), pendingUnicodeStroke == nil,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        var units = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.flags = []
        up.flags = []
        let id = UUID()
        pendingUnicodeStroke = (id, up)
        post(down)
        return id
    }

    private func finishUnicodeStroke(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let stroke = pendingUnicodeStroke, stroke.id == id else { return }
        pendingUnicodeStroke = nil
        post(stroke.release)
    }

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
                releaseHeldAutomationInputLocked()
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
    private func releaseHeldAutomationInputLocked() {
        // A late, rejected AI event must not release the person's new drag or
        // modifier. Direct input takes ownership after releasing old AI holds;
        // automation takes ownership only through neutral-input admission.
        guard !heldInputIsDirect else { return }
        releaseHeldInputLocked()
    }

    private func releaseHeldInputLocked() {
        if let stroke = pendingUnicodeStroke {
            pendingUnicodeStroke = nil
            post(stroke.release)
        }
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
        heldInputIsDirect = false

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

    static func isPhysicalIntervention(_ event: NSEvent) -> Bool {
        guard event.type.rawValue < 64 else { return false }
        return !isSynthetic(event) && physicalInterventionEventMask.contains(
            NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue))
    }
}
