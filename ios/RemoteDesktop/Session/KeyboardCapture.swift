import GameController
import SwiftUI
import UIKit

/// Invisible SwiftUI overlay that wires hardware keyboard events from
/// `GCKeyboard` into the session transport. Raw `GCKeyCode` values are
/// USB HID usage codes on page 0x07, which is exactly our wire format.
struct KeyboardCapture: UIViewRepresentable {
    @EnvironmentObject private var session: SessionModel

    func makeUIView(context: Context) -> UIView {
        context.coordinator.start(session: session)
        return UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(session: session)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        private static weak var activeCoordinator: Coordinator?
        private weak var session: SessionModel?
        private weak var keyboardInput: GCKeyboardInput?
        private var connectObs: NSObjectProtocol?
        private var inputGeneration: UUID?
        private var captureID = UUID()
        private var waitsForRelease = false

        func start(session: SessionModel) {
            update(session: session)
            connectObs = NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidConnect, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach() }
            }
        }

        func update(session: SessionModel) {
            let next = session.hasInteractiveRemoteScreen ? session.remoteInputGeneration : nil
            let changed = self.session !== session || inputGeneration != next
            self.session = session
            inputGeneration = next
            if changed { attach() }
        }

        func stop() {
            if Self.activeCoordinator === self {
                keyboardInput?.keyChangedHandler = nil
                Self.activeCoordinator = nil
            }
            if let connectObs { NotificationCenter.default.removeObserver(connectObs) }
            connectObs = nil; keyboardInput = nil; session = nil; inputGeneration = nil
            captureID = UUID()
        }

        private func attach() {
            guard let keyboard = GCKeyboard.coalesced, let input = keyboard.keyboardInput else { return }
            // GCDevice.h defines this as the queue for value-change handlers.
            // Keep native ordering on main instead of introducing a Task per key.
            keyboard.handlerQueue = .main
            Self.activeCoordinator = self
            keyboardInput = input
            waitsForRelease = input.isAnyKeyPressed
            let generation = inputGeneration
            let captureID = UUID()
            self.captureID = captureID
            input.keyChangedHandler = { [weak self] keyboard, _, keyCode, pressed in
                MainActor.assumeIsolated {
                    guard let self, Self.activeCoordinator === self, let generation,
                          self.captureID == captureID, self.inputGeneration == generation,
                          let session = self.session, session.hasInteractiveRemoteScreen,
                          session.remoteInputGeneration == generation else { return }
                    if self.waitsForRelease {
                        self.waitsForRelease = keyboard.isAnyKeyPressed
                        return // The old hold and its final release stay local.
                    }
                    session.send(.key(usage: Int(keyCode.rawValue), down: pressed,
                        modifiers: Self.modifierMask(input: keyboard)),
                        expectedInputGeneration: generation)
                }
            }
        }

        nonisolated private static func modifierMask(input: GCKeyboardInput) -> UInt16 {
            var mask: UInt16 = 0
            func bit(_ n: Int, _ code: GCKeyCode) {
                if input.button(forKeyCode: code)?.isPressed == true { mask |= UInt16(1 << n) }
            }
            bit(0, .leftShift); bit(1, .leftControl); bit(2, .leftAlt); bit(3, .leftGUI)
            bit(4, .rightShift); bit(5, .rightControl); bit(6, .rightAlt); bit(7, .rightGUI)
            if input.button(forKeyCode: .capsLock)?.isPressed == true { mask |= UInt16(1 << 8) }
            return mask
        }

        deinit {
            if let o = connectObs { NotificationCenter.default.removeObserver(o) }
        }
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
        tf.keyboardType = .asciiCapable
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
        if (!isOpen || !tf.canSendInput), tf.isFirstResponder {
            tf.resignFirstResponder()
        } else if isOpen, tf.canSendInput, !tf.isFirstResponder {
            tf.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? CaptureField)?.resignFirstResponder()
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
            didSet { if oldValue !== session { synchronizeBinding() } }
        }
        private var inputGeneration: UUID?
        var onKeyboardDismiss: (() -> Void)?

        var canSendInput: Bool {
            guard let session, let inputGeneration else { return false }
            return session.hasInteractiveRemoteScreen && session.remoteInputGeneration == inputGeneration
        }

        func bindSession(_ session: SessionModel) {
            self.session = session
            synchronizeBinding()
        }

        private func synchronizeBinding() {
            let next = session?.hasInteractiveRemoteScreen == true ? session?.remoteInputGeneration : nil
            guard next != inputGeneration else { return }
            inputGeneration = nil
            resignFirstResponder()
            unmarkText()
            text = " "
            inputGeneration = next
        }

        private func send(_ message: ControlMessage) {
            guard canSendInput else { return }
            session?.send(message, expectedInputGeneration: inputGeneration)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            // Non-zero empty text so backspace fires `shouldChangeCharactersIn`.
            text = " "
            inputAccessoryView = makeKeyboardAccessory()
        }
        required init?(coder: NSCoder) { fatalError() }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let modifiers = session?.softModifierMask ?? 0
            if string.isEmpty {
                // Backspace: HID usage 0x2A.
                send(.key(usage: 0x2A, down: true, modifiers: modifiers))
                send(.key(usage: 0x2A, down: false, modifiers: modifiers))
            } else if string == "\n" {
                send(.key(usage: 0x28, down: true, modifiers: modifiers))
                send(.key(usage: 0x28, down: false, modifiers: modifiers))
            } else if let shortcut = SoftKeyboardShortcutMapper.map(string, baseModifiers: modifiers),
                      shortcut.modifiers != 0 {
                send(.key(usage: shortcut.usage, down: true, modifiers: shortcut.modifiers))
                send(.key(usage: shortcut.usage, down: false, modifiers: shortcut.modifiers))
            } else {
                send(.text(string))
            }
            // Keep the buffer non-empty so backspace keeps firing.
            textField.text = " "
            return false
        }

        override func deleteBackward() {
            let modifiers = session?.softModifierMask ?? 0
            send(.key(usage: 0x2A, down: true, modifiers: modifiers))
            send(.key(usage: 0x2A, down: false, modifiers: modifiers))
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
            resignFirstResponder()
            onKeyboardDismiss?()
        }
    }
}
