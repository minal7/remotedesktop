import SwiftUI
import UIKit

/// The native responder owns hardware events; global device notifications
/// never forward keystrokes into the Mac.
struct KeyboardCapture: UIViewRepresentable {
    @EnvironmentObject private var session: SessionModel

    func makeUIView(context: Context) -> RemoteHardwareKeyboardCapture {
        let view = RemoteHardwareKeyboardCapture()
        view.install(session: session)
        return view
    }

    func updateUIView(_ uiView: RemoteHardwareKeyboardCapture, context: Context) {
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
        tf.bindSession(session)
        tf.onKeyboardDismiss = context.coordinator.dismissKeyboard
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.keyboardType = .default
        tf.returnKeyType = .default
        // Defer to next runloop tick — UITextField can't become first
        // responder until it's been added to the window hierarchy.
        Task { @MainActor in if tf.canSendInput { _ = tf.becomeFirstResponder() } }
        return tf
    }

    func updateUIView(_ v: UIView, context: Context) {
        guard let tf = v as? CaptureField else { return }
        tf.bindSession(session)
        context.coordinator.isOpen = $isOpen
        tf.onKeyboardDismiss = context.coordinator.dismissKeyboard
        if !isOpen {
            tf.stopCapture()
            return
        }
        if !tf.canSendInput, tf.isFirstResponder {
            tf.resignFirstResponder()
        } else if isOpen, tf.canSendInput, !tf.isFirstResponder {
            tf.becomeFirstResponder()
        }
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
        weak var session: SessionModel? {
            didSet {
                if oldValue !== session {
                    if hasBoundSource { stopped = true }
                    let source = inputSource
                    inputSource = nil; inputGeneration = nil
                    if let source { oldValue?.endRemoteInputSource(source) }
                    retireBinding()
                    synchronizeBinding()
                }
            }
        }
        private var inputGeneration: UUID?
        private var inputSource: RemoteInputSourceLease?
        private var hasBoundSource = false
        private var stopped = false
        private var detached = false
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
            guard !stopped, !detached, let session, session.allowsRemoteKeyboardInput, let inputSource else { return false }
            return session.isRemoteInputSourceCurrent(inputSource)
        }

        func bindSession(_ session: SessionModel) {
            guard !stopped else { return }
            self.session = session
            synchronizeBinding()
        }

        private func retireBinding() {
            // UIKit's later input callbacks do not carry our source token.
            // Once a native field has owned a source it cannot be recycled
            // into another generation; SwiftUI installs a new field instead.
            if hasBoundSource { stopped = true }
            let source = inputSource
            inputSource = nil; inputGeneration = nil
            if let source { session?.endRemoteInputSource(source) }
            resignFirstResponder()
            discardNativeText()
        }

        func stopCapture() {
            stopped = true
            retireBinding()
            session = nil
            onKeyboardDismiss = nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detached = window == nil
            if detached { retireBinding() }
            else { synchronizeBinding() }
        }

        private func synchronizeBinding() {
            guard !stopped, !detached else { return }
            let next = session?.allowsRemoteKeyboardInput == true ? session?.remoteInputGeneration : nil
            guard next != inputGeneration else { return }
            retireBinding()
            guard !stopped else { return }
            if let next, let source = session?.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: next) {
                inputGeneration = next
                inputSource = source
                hasBoundSource = true
            }
        }

        private var destination: Destination? {
            guard canSendInput, let session, let inputSource else { return nil }
            return .init(session: session, source: inputSource, modifiers: session.softModifierMask)
        }

        private func sendKey(_ usage: Int, to destination: Destination, modifiers: UInt16? = nil) {
            let mask = modifiers ?? destination.modifiers
            destination.session.send(.key(usage: usage, down: true, modifiers: mask), from: destination.source)
            destination.session.send(.key(usage: usage, down: false, modifiers: mask), from: destination.source)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            text = ""
            addTarget(self, action: #selector(nativeTextDidChange), for: .editingChanged)
            inputAccessoryView = makeKeyboardAccessory()
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
                target.session.send(.text(value), from: target.source)
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
            // Resignation can unmark text. Discard it before UIKit can turn a
            // hidden/dismissed composition into a committed remote value.
            discardNativeText()
            return super.resignFirstResponder()
        }

        private func makeKeyboardAccessory() -> UIView {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()

            var configuration = UIButton.Configuration.plain()
            configuration.title = "Hide keyboard"
            configuration.image = UIImage(
                systemName: "keyboard.chevron.compact.down")
            configuration.imagePadding = 6

            let dismissButton = UIButton(configuration: configuration)
            dismissButton.accessibilityIdentifier =
                "computer-use-hide-remote-keyboard"
            dismissButton.accessibilityLabel = "Hide remote keyboard"
            dismissButton.addTarget(
                self,
                action: #selector(dismissKeyboardFromAccessory),
                for: .touchUpInside)

            toolbar.items = [
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(customView: dismissButton),
            ]
            return toolbar
        }

        @objc private func dismissKeyboardFromAccessory() {
            // A retiring field may still receive its old accessory action.
            let ownsDismissal = !stopped && (session == nil || canSendInput)
            retireBinding()
            if ownsDismissal { onKeyboardDismiss?() }
        }
    }
}
