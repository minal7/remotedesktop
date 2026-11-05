import SwiftUI
import UIKit

/// The native responder owns hardware events; global device notifications
/// never forward keystrokes into the Mac.
struct KeyboardCapture: UIViewRepresentable {
    @EnvironmentObject private var session: SessionModel
    var onPhysicalKeyPress: () -> Void = {}

    func makeUIView(context: Context) -> RemoteHardwareKeyboardCapture {
        let view = RemoteHardwareKeyboardCapture()
        view.onPhysicalKeyPress = onPhysicalKeyPress
        view.install(session: session)
        return view
    }

    func updateUIView(_ uiView: RemoteHardwareKeyboardCapture, context: Context) {
        uiView.onPhysicalKeyPress = onPhysicalKeyPress
        uiView.update(session: session)
    }

    static func dismantleUIView(_ uiView: RemoteHardwareKeyboardCapture, coordinator: ()) {
        uiView.stop()
    }
}

/// Invisible text field that brings up the soft keyboard and funnels
/// typed characters as `text` messages (matching PROTOCOL.md) plus a
/// handful of special keys translated to HID usages.
struct SoftKeyboardCapture: UIViewRepresentable {
    @EnvironmentObject private var session: SessionModel
    @Binding var isOpen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isOpen: $isOpen)
    }

    func makeUIView(context: Context) -> UIView {
        let tf = CaptureField()
        tf.onKeyboardDismiss = context.coordinator.dismissKeyboard
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.keyboardType = .default
        tf.returnKeyType = .default
        tf.bindSession(session)
        return tf
    }

    func updateUIView(_ v: UIView, context: Context) {
        guard let tf = v as? CaptureField else { return }
        context.coordinator.isOpen = $isOpen
        tf.onKeyboardDismiss = context.coordinator.dismissKeyboard
        if !isOpen {
            tf.stopCapture()
            return
        }
        tf.bindSession(session)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? CaptureField)?.stopCapture()
    }

    final class Coordinator {
        var isOpen: Binding<Bool>

        init(isOpen: Binding<Bool>) {
            self.isOpen = isOpen
        }

        func dismissKeyboard() {
            isOpen.wrappedValue = false
        }
    }

    final class CaptureField: UITextField, UITextFieldDelegate {
        private static weak var active: CaptureField?
        private(set) weak var session: SessionModel?
        private weak var owningWindow: UIWindow?
        private var captureIdentity: RemoteKeyboardCaptureIdentity?
        private var inputSource: RemoteInputSourceLease?
        private var hasBoundSource = false
        private var stopped = false
        private var focusTask: Task<Void, Never>?
        private var focusRequestID: UUID?
        private var initialFocusRequested = false
        private var dismissalTask: Task<Void, Never>?
        private var dismissalID: UUID?
        private var windowObserver: NSObjectProtocol?
        private var keyboardHideObserver: NSObjectProtocol?
        private var nativeMutationDepth = 0
        private var mutationStartedWithMarkedText = false
        private var isDiscardingNativeText = false
        private var deferredCommit: Task<Void, Never>?
        private var deferredCommitID: UUID?
        var onKeyboardDismiss: (() -> Void)?

        private struct Destination {
            let session: SessionModel
            let source: RemoteInputSourceLease
            let modifiers: UInt16
        }

        // The Mac owns the document. An empty local composition buffer must
        // not disable Delete when there is remote text to remove.
        override var hasText: Bool { true }

        var canSendInput: Bool {
            guard nativeFocusIsCurrent, let session, let inputSource else { return false }
            return session.isRemoteInputSourceCurrent(inputSource)
        }

        private var bindingIsCurrent: Bool {
            !stopped && Self.active === self && session?.allowsRemoteKeyboardInput == true
                && captureIdentity == session?.remoteKeyboardCaptureIdentity
        }

        private var nativeFocusIsCurrent: Bool {
            bindingIsCurrent && isFirstResponder && window != nil && window === owningWindow
                && window?.isKeyWindow == true && window?.rootViewController?.presentedViewController == nil
        }

        func bindSession(_ session: SessionModel) {
            guard !stopped else { return }
            if captureIdentity != nil {
                guard self.session === session, captureIdentity == session.remoteKeyboardCaptureIdentity else {
                    stopCapture(); return
                }
            } else {
                let previous = Self.active
                Self.active = self
                previous?.stopCapture()
                guard Self.active === self, !stopped else { stopped = true; return }
                self.session = session
                captureIdentity = session.remoteKeyboardCaptureIdentity
            }
            if hasBoundSource, !canSendInput { retireBinding(notifyDismissal: true); return }
            requestInitialFocus()
        }

        private func retireBinding(notifyDismissal: Bool = false, resign: Bool = true) {
            guard !stopped else { return }
            stopped = true
            focusTask?.cancel(); focusTask = nil; focusRequestID = nil
            let source = inputSource
            inputSource = nil; owningWindow = nil
            discardNativeText()
            if let source { session?.endRemoteInputSource(source) }
            if Self.active === self, captureIdentity == session?.remoteKeyboardCaptureIdentity {
                session?.releaseSoftModifiers()
            }
            if resign, isFirstResponder { _ = super.resignFirstResponder() }
            if notifyDismissal { scheduleOwnedDismissal() }
        }

        func stopCapture() {
            retireBinding()
            dismissalTask?.cancel(); dismissalTask = nil; dismissalID = nil
            if Self.active === self { Self.active = nil }
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
            if let keyboardHideObserver { NotificationCenter.default.removeObserver(keyboardHideObserver) }
            keyboardHideObserver = nil
            session = nil
            captureIdentity = nil
            onKeyboardDismiss = nil
        }

        override var canBecomeFirstResponder: Bool {
            bindingIsCurrent && window?.isKeyWindow == true
                && window?.rootViewController?.presentedViewController == nil
                && super.canBecomeFirstResponder
        }

        override func becomeFirstResponder() -> Bool {
            guard canBecomeFirstResponder else { return false }
            focusTask?.cancel(); focusTask = nil; focusRequestID = nil
            initialFocusRequested = true
            if hasBoundSource {
                guard canSendInput else { retireBinding(notifyDismissal: true); return false }
                return true
            }
            guard let session, let identity = captureIdentity, let window else { return false }
            guard super.becomeFirstResponder() else { retireBinding(notifyDismissal: true); return false }
            guard bindingIsCurrent, isFirstResponder, self.window === window, window.isKeyWindow,
                  window.rootViewController?.presentedViewController == nil,
                  let source = session.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: identity.input) else {
                retireBinding(notifyDismissal: true); return false
            }
            guard self.session === session, captureIdentity == identity, bindingIsCurrent,
                  isFirstResponder, self.window === window, window.isKeyWindow,
                  session.isRemoteInputSourceCurrent(source) else {
                session.endRemoteInputSource(source)
                retireBinding(notifyDismissal: true); return false
            }
            hasBoundSource = true
            inputSource = source; owningWindow = window
            guard self.session === session, captureIdentity == identity, canSendInput else {
                retireBinding(notifyDismissal: true); return false
            }
            return true
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if hasBoundSource, newWindow !== owningWindow { retireBinding(notifyDismissal: true) }
            super.willMove(toWindow: newWindow)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil, captureIdentity != nil { retireBinding(notifyDismissal: true) }
            else { requestInitialFocus() }
        }

        private func requestInitialFocus() {
            guard !hasBoundSource, !initialFocusRequested, canBecomeFirstResponder, let window else { return }
            initialFocusRequested = true
            let id = UUID()
            focusRequestID = id
            let origin = Self.firstResponder(in: window)
            let hadOrigin = origin != nil
            focusTask = Task { @MainActor [weak self, weak window, weak origin] in
                guard !Task.isCancelled, let self, self.focusRequestID == id else { return }
                self.focusTask = nil; self.focusRequestID = nil
                guard let window, self.window === window, self.canBecomeFirstResponder,
                      !hadOrigin || origin != nil,
                      Self.firstResponder(in: window) === origin else {
                    self.retireBinding(notifyDismissal: true); return
                }
                _ = self.becomeFirstResponder()
            }
        }

        private static func firstResponder(in root: UIView) -> UIView? {
            var pending = [root]
            while let view = pending.popLast() {
                // The hardware listener gives way to the keyboard the person just asked for.
                if view.isFirstResponder { return view is RemoteHardwareKeyboardCapture ? nil : view }
                pending.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func scheduleOwnedDismissal() {
            guard Self.active === self, let session, let identity = captureIdentity,
                  session.remoteKeyboardCaptureIdentity == identity else { return }
            dismissalTask?.cancel()
            let id = UUID()
            dismissalID = id
            // Native retirement may happen during a SwiftUI update. Close the
            // exact still-owned keyboard on a later actor turn, never a successor.
            dismissalTask = Task { @MainActor [weak self, weak session] in
                guard !Task.isCancelled, let self, let session, self.dismissalID == id else { return }
                self.dismissalTask = nil; self.dismissalID = nil
                guard Self.active === self, self.session === session, self.captureIdentity == identity,
                      session.remoteKeyboardCaptureIdentity == identity else { return }
                self.onKeyboardDismiss?()
            }
        }

        private var destination: Destination? {
            guard canSendInput, let session, let inputSource else {
                if hasBoundSource, !stopped { retireBinding(notifyDismissal: true) }
                return nil
            }
            return .init(session: session, source: inputSource, modifiers: session.softModifierMask)
        }

        private func sendOwned(_ message: ControlMessage, to destination: Destination) {
            guard session === destination.session, inputSource == destination.source, canSendInput else {
                if hasBoundSource, !stopped { retireBinding(notifyDismissal: true) }
                return
            }
            destination.session.send(message, from: destination.source)
        }

        private func sendKey(_ usage: Int, to destination: Destination, modifiers: UInt16? = nil) {
            let mask = modifiers ?? destination.modifiers
            sendOwned(.key(usage: usage, down: true, modifiers: mask), to: destination)
            sendOwned(.key(usage: usage, down: false, modifiers: mask), to: destination)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            text = ""
            addTarget(self, action: #selector(nativeTextDidChange), for: .editingChanged)
            // The app's own controls show and hide the keyboard, so no extra bar sits on top of it.
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            windowObserver = NotificationCenter.default.addObserver(forName: UIWindow.didResignKeyNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? UIWindow,
                          window === self.window || window === self.owningWindow else { return }
                    self.retireBinding(notifyDismissal: true)
                }
            }
            // The system hide key removes the keyboard but leaves this field focused,
            // so nothing else reports that it closed and it could not be reopened.
            keyboardHideObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hasBoundSource, self.isFirstResponder else { return }
                    self.retireBinding(notifyDismissal: true)
                }
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            // This is a proposed local edit, including provisional IME text.
            // Never send it or reset UIKit's document before it is applied.
            guard textField === self, canSendInput, !isDiscardingNativeText else { return false }
            let length = (textField.text ?? "").utf16.count
            return range.location >= 0 && range.length >= 0 && range.location <= length
                && range.length <= length - range.location
        }

        private func beginNativeMutation() {
            if nativeMutationDepth == 0 { mutationStartedWithMarkedText = markedTextRange != nil }
            nativeMutationDepth += 1
        }

        private func endNativeMutation() {
            nativeMutationDepth -= 1
            if nativeMutationDepth == 0 {
                mutationStartedWithMarkedText = false
                flushCommittedText()
            }
        }

        override func insertText(_ text: String) {
            guard let destination, !isDiscardingNativeText else { return }
            if nativeMutationDepth == 0, markedTextRange == nil, (self.text ?? "").isEmpty {
                // UIKeyInput inserts committed text. With no local composition
                // to replace, preserve its exact bytes (including pasted line
                // breaks) instead of normalizing them through a single-line field.
                cancelDeferredCommit()
                sendCommittedText(text, to: destination)
                return
            }
            beginNativeMutation()
            defer { endNativeMutation() }
            super.insertText(text)
        }

        override func replace(_ range: UITextRange, withText text: String) {
            guard canSendInput, !isDiscardingNativeText else { return }
            beginNativeMutation()
            defer { endNativeMutation() }
            super.replace(range, withText: text)
        }

        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            guard canSendInput, !isDiscardingNativeText else { return }
            beginNativeMutation()
            defer { endNativeMutation() }
            super.setMarkedText(markedText, selectedRange: selectedRange)
        }

        override func unmarkText() {
            beginNativeMutation()
            defer { endNativeMutation() }
            super.unmarkText()
        }

        @objc private func nativeTextDidChange() {
            guard nativeMutationDepth == 0, !isDiscardingNativeText else { return }
            cancelDeferredCommit()
            guard let destination else { discardNativeText(); return }
            let id = UUID()
            deferredCommitID = id
            // UIKit may establish marked ranges after notifying observers.
            // Unwrapped native edits are inspected after that callback stack.
            deferredCommit = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, self.deferredCommitID == id else { return }
                self.deferredCommit = nil; self.deferredCommitID = nil
                guard self.session === destination.session, self.inputSource == destination.source else { return }
                self.flushCommittedText(to: destination)
            }
        }

        private func cancelDeferredCommit() {
            deferredCommit?.cancel(); deferredCommit = nil; deferredCommitID = nil
        }

        private func discardNativeText() {
            cancelDeferredCommit()
            guard !isDiscardingNativeText else { return }
            isDiscardingNativeText = true
            defer { isDiscardingNativeText = false }
            super.unmarkText()
            text = ""
        }

        private func flushCommittedText(to captured: Destination? = nil) {
            guard nativeMutationDepth == 0, !isDiscardingNativeText else { return }
            cancelDeferredCommit()
            guard let target = captured ?? destination,
                  session === target.session, inputSource == target.source, canSendInput else {
                discardNativeText()
                return
            }
            guard markedTextRange == nil, let value = text, !value.isEmpty else { return }
            // Clear before external input callbacks; a reentrant successor
            // cannot receive this commit or make a late notification repeat it.
            discardNativeText()
            sendCommittedText(value, to: target)
        }

        private func sendCommittedText(_ value: String, to target: Destination) {
            guard !value.isEmpty else { return }
            if value == "\n" {
                sendKey(0x28, to: target)
            } else if target.modifiers != 0,
                      let shortcut = SoftKeyboardShortcutMapper.map(value, baseModifiers: target.modifiers) {
                sendKey(shortcut.usage, to: target, modifiers: shortcut.modifiers)
            } else {
                sendOwned(.text(value), to: target)
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField === self, let destination else { return false }
            if markedTextRange != nil || (nativeMutationDepth > 0 && mutationStartedWithMarkedText) {
                unmarkText()
                return false // Confirm composition, without submitting a remote form.
            }
            flushCommittedText()
            sendKey(0x28, to: destination)
            return false
        }

        override func deleteBackward() {
            guard let destination, !isDiscardingNativeText else { return }
            if markedTextRange != nil || !(text ?? "").isEmpty {
                beginNativeMutation()
                defer { endNativeMutation() }
                super.deleteBackward()
            } else {
                sendKey(0x2A, to: destination)
            }
        }

        override func resignFirstResponder() -> Bool {
            // Retire authority before UIKit can confirm or deliver more text.
            retireBinding(notifyDismissal: true, resign: false)
            return super.resignFirstResponder()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            guard textField === self else { return }
            retireBinding(notifyDismissal: true)
        }

        deinit {
            focusTask?.cancel(); dismissalTask?.cancel(); deferredCommit?.cancel()
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            if let keyboardHideObserver { NotificationCenter.default.removeObserver(keyboardHideObserver) }
        }
    }
}
