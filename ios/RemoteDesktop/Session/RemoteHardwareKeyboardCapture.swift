import GameController
import UIKit

/// One native first-responder lifetime. A retired view cannot reclaim input;
/// an explicit screen press asks SwiftUI to install a new capture identity.
@MainActor
final class RemoteHardwareKeyboardCapture: UIView {
    private static weak var active: RemoteHardwareKeyboardCapture?
    private weak var session: SessionModel?
    private weak var keyboardDevice: GCKeyboard?
    private weak var keyboardInput: GCKeyboardInput?
    private var generation: UUID?
    private var captureIdentity: RemoteKeyboardCaptureIdentity?
    private var source: RemoteInputSourceLease?
    private var observers: [NSObjectProtocol] = []
    private var focusTask: Task<Void, Never>?
    private var focusRequestID: UUID?
    private var initialFocusRequested = false
    private var explicitFocus = false
    private var acquiredFocus = false
    private var retired = false
    private var stopped = false
    private var waitsForRelease = false
    private var presses = RemoteHardwarePressState()
    private var ownedPressObjects: [ObjectIdentifier: UIPress] = [:]

    func install(session: SessionModel) {
        Self.active?.stop()
        // Cleanup can synchronously install a successor. Do not overwrite it.
        guard Self.active == nil else { stopped = true; retired = true; return }
        Self.active = self
        captureIdentity = session.remoteKeyboardCaptureIdentity
        explicitFocus = session.consumeRemoteKeyboardFocusRequest(session.remoteKeyboardCaptureIdentity)
        update(session: session)
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect, UIWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.nativeStateChanged(notification) }
            })
        }
    }

    func update(session: SessionModel) {
        guard Self.active === self, !stopped, !retired else { return }
        let next = session.allowsRemoteKeyboardInput ? session.remoteInputGeneration : nil
        if acquiredFocus, self.session !== session || generation != next
            || captureIdentity != session.remoteKeyboardCaptureIdentity {
            retire()
            if isFirstResponder { _ = resignFirstResponder() }
            return
        }
        self.session = session
        generation = next
        requestInitialFocus()
    }

    private var permittedBySession: Bool {
        guard let session, let generation else { return false }
        return session.allowsRemoteKeyboardInput && session.remoteInputGeneration == generation
            && captureIdentity == session.remoteKeyboardCaptureIdentity
    }

    override var canBecomeFirstResponder: Bool {
        Self.active === self && !stopped && !retired && permittedBySession
            && window?.isKeyWindow == true
            && window?.rootViewController?.presentedViewController == nil
            && (explicitFocus || window.map({ !Self.containsOtherFirstResponder(in: $0, excluding: self) }) == true)
            && GCKeyboard.coalesced?.keyboardInput != nil
    }

    static func containsOtherFirstResponder(in root: UIView, excluding capture: UIView) -> Bool {
        var pending = [root]
        while let view = pending.popLast() {
            if view !== capture, view.isFirstResponder { return true }
            pending.append(contentsOf: view.subviews)
        }
        return false
    }

    override func becomeFirstResponder() -> Bool {
        guard canBecomeFirstResponder else { return false }
        if acquiredFocus {
            guard isFirstResponder, let source, session?.isRemoteInputSourceCurrent(source) == true else {
                retire()
                if isFirstResponder { _ = super.resignFirstResponder() }
                return false
            }
            return true
        }
        guard super.becomeFirstResponder() else { return false }
        guard canBecomeFirstResponder, let session, let generation,
              let keyboard = GCKeyboard.coalesced, let input = keyboard.keyboardInput,
              let source = session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation) else {
            retire()
            _ = super.resignFirstResponder()
            return false
        }
        guard canBecomeFirstResponder, isFirstResponder, self.session === session,
              self.generation == generation, session.isRemoteInputSourceCurrent(source) else {
            session.endRemoteInputSource(source)
            retire()
            if isFirstResponder { _ = super.resignFirstResponder() }
            return false
        }
        acquiredFocus = true
        explicitFocus = false
        self.source = source
        keyboardDevice = keyboard; keyboardInput = input
        waitsForRelease = input.isAnyKeyPressed
        if waitsForRelease {
            // This handler only observes the pre-existing physical hold. It
            // never sends input, even while another native control has focus.
            keyboard.handlerQueue = .main
            input.keyChangedHandler = { [weak self, weak input] keyboard, _, _, _ in
                MainActor.assumeIsolated {
                    guard let self, let input, Self.active === self,
                          self.keyboardInput === input, self.source == source, !self.retired else { return }
                    if !keyboard.isAnyKeyPressed {
                        self.waitsForRelease = false
                        input.keyChangedHandler = nil
                    }
                }
            }
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if acquiredFocus { retire() }
        return super.resignFirstResponder()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelFocusRequest()
            if acquiredFocus { retire() }
        } else {
            requestInitialFocus()
        }
    }

    private func requestInitialFocus() {
        guard !initialFocusRequested, canBecomeFirstResponder else { return }
        initialFocusRequested = true
        let id = UUID()
        focusRequestID = id
        focusTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.focusRequestID == id else { return }
            self.focusTask = nil; self.focusRequestID = nil
            guard self.canBecomeFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
    }

    private func cancelFocusRequest() {
        focusTask?.cancel(); focusTask = nil; focusRequestID = nil
    }

    private func nativeStateChanged(_ notification: Notification) {
        guard Self.active === self, !stopped else { return }
        if notification.name == UIWindow.didResignKeyNotification,
           let changedWindow = notification.object as? UIWindow, changedWindow === window {
            retire()
            if isFirstResponder { _ = resignFirstResponder() }
        } else if notification.name == .GCKeyboardDidDisconnect,
                  let device = notification.object as? GCKeyboard, device === keyboardDevice {
            retire()
            if isFirstResponder { _ = resignFirstResponder() }
        } else if notification.name == .GCKeyboardDidConnect {
            requestInitialFocus()
        }
    }

    private func retire() {
        retired = true
        explicitFocus = false
        cancelFocusRequest()
        if Self.active === self { keyboardInput?.keyChangedHandler = nil }
        keyboardDevice = nil; keyboardInput = nil; waitsForRelease = false
        presses.reset()
        ownedPressObjects.removeAll()
        let source = source
        self.source = nil
        if let source { session?.endRemoteInputSource(source) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        retire()
        if isFirstResponder { _ = super.resignFirstResponder() }
        if Self.active === self { Self.active = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        session = nil; generation = nil; captureIdentity = nil
    }

    /// Hover and local chrome cannot steal focus. The caller supplies an
    /// already-admitted new button press inside the remote content rectangle.
    static func requestFocus(in session: SessionModel, expectedInputGeneration: UUID) {
        guard let current = active, !current.stopped, current.session === session,
              current.generation == expectedInputGeneration, current.window?.isKeyWindow == true,
              session.allowsRemoteKeyboardInput else { return }
        if !current.retired, current.isFirstResponder,
           let source = current.source, session.isRemoteInputSourceCurrent(source) { return }
        session.requestRemoteKeyboardFocus(expectedInputGeneration: expectedInputGeneration)
    }

    private func route(_ nativePresses: Set<UIPress>, phase: RemoteHardwarePressState.Phase) -> Set<UIPress> {
        guard Self.active === self, !stopped, !retired, isFirstResponder,
              window?.isKeyWindow == true, permittedBySession,
              window?.rootViewController?.presentedViewController == nil,
              let session, let source, session.isRemoteInputSourceCurrent(source) else {
            if source != nil { retire() }
            return nativePresses
        }
        var unhandled = nativePresses
        // Simultaneous modifiers establish their side before ordinary keys.
        let ordered = nativePresses.sorted {
            let lhs = Int($0.key?.keyCode.rawValue ?? 0), rhs = Int($1.key?.keyCode.rawValue ?? 0)
            let lhsModifier = (0xE0...0xE7).contains(lhs), rhsModifier = (0xE0...0xE7).contains(rhs)
            if lhsModifier != rhsModifier { return phase == .began ? lhsModifier : !lhsModifier }
            return lhs < rhs
        }
        for press in ordered {
            guard !retired, Self.active === self, isFirstResponder, permittedBySession,
                  window?.isKeyWindow == true, window?.rootViewController?.presentedViewController == nil,
                  session.isRemoteInputSourceCurrent(source) else { break }
            guard press.responder === self, press.window === window, let key = press.key,
                  (4...255).contains(Int(key.keyCode.rawValue)) else { continue }
            unhandled.remove(press)
            guard !waitsForRelease else { continue }
            if let message = presses.handle(id: ObjectIdentifier(press), usage: Int(key.keyCode.rawValue),
                                            phase: phase, modifiers: key.modifierFlags) {
                // Keep each native object alive until its owned release, so
                // pointer-address reuse cannot impersonate a still-held press.
                if phase == .began { ownedPressObjects[ObjectIdentifier(press)] = press }
                else { ownedPressObjects[ObjectIdentifier(press)] = nil }
                session.send(message, from: source)
            }
        }
        return unhandled
    }

    var onPhysicalKeyPress: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key != nil }) { onPhysicalKeyPress?() }
        let remaining = route(presses, phase: .began)
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = route(presses, phase: .changed)
        if !remaining.isEmpty { super.pressesChanged(remaining, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = route(presses, phase: .ended)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = route(presses, phase: .cancelled)
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    deinit {
        focusTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Native press identity is local to one responder lifetime; a release cannot
/// release another press that happens to carry the same HID usage.
struct RemoteHardwarePressState {
    enum Phase: Equatable { case began, changed, ended, cancelled }
    private var active: [ObjectIdentifier: Int] = [:]
    mutating func reset() { active.removeAll() }
    mutating func handle(id: ObjectIdentifier, usage: Int, phase: Phase, modifiers: UIKeyModifierFlags) -> ControlMessage? {
        guard (4...255).contains(usage) else { return nil }
        let groups: [(UIKeyModifierFlags, Int, Int, UInt16, UInt16)] = [
            (.shift, 0xE1, 0xE5, 1, 16), (.control, 0xE0, 0xE4, 2, 32),
            (.alternate, 0xE2, 0xE6, 4, 64), (.command, 0xE3, 0xE7, 8, 128),
        ]
        switch phase {
        case .began:
            guard active[id] == nil || active[id] == usage,
                  !active.contains(where: { $0.key != id && $0.value == usage }) else { return nil }
            let proposed = Set(active.values).union([usage])
            // A sampled flag cannot identify its physical side or prove that
            // this responder owned its down. Do not turn an unowned shortcut
            // into a guessed left-side hold or an unmodified character.
            guard (0xE0...0xE7).contains(usage) || groups.allSatisfy({ flag, left, right, _, _ in
                !modifiers.contains(flag) || proposed.contains(left) || proposed.contains(right)
            }) else { return nil }
            active[id] = usage
        case .changed: return nil // Force changes are not invented key repeats.
        case .ended, .cancelled:
            guard active[id] == usage else { return nil }
            active[id] = nil
        }
        let held = Set(active.values)
        var mask: UInt16 = modifiers.contains(.alphaShift) ? 256 : 0
        for (_, left, right, leftBit, rightBit) in groups {
            if held.contains(left) { mask |= leftBit }
            if held.contains(right) { mask |= rightBit }
        }
        return .key(usage: usage, down: phase == .began, modifiers: mask)
    }
}
