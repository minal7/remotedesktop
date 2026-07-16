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
        context.coordinator.session = session
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var session: SessionModel?
        private var connectObs: NSObjectProtocol?

        func start(session: SessionModel) {
            self.session = session
            attach()
            connectObs = NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidConnect, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach() }
            }
        }

        private func attach() {
            guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
            // `keyChangedHandler` isn't guaranteed to run on the main
            // queue, so hop to MainActor before touching session state.
            input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
                Task { @MainActor in
                    guard let self else { return }
                    self.session?.send(.key(
                        usage: Int(keyCode.rawValue),
                        down: pressed,
                        modifiers: self.modifierMask()
                    ))
                }
            }
        }

        private func modifierMask() -> UInt16 {
            guard let input = GCKeyboard.coalesced?.keyboardInput else { return 0 }
            var mask: UInt16 = 0
            func bit(_ n: Int, _ code: GCKeyCode) {
                if input.button(forKeyCode: code)?.isPressed == true {
                    mask |= UInt16(1 << n)
                }
            }
            bit(0, .leftShift)
            bit(1, .leftControl)
            bit(2, .leftAlt)
            bit(3, .leftGUI)
            bit(4, .rightShift)
            bit(5, .rightControl)
            bit(6, .rightAlt)
            bit(7, .rightGUI)
            if input.button(forKeyCode: .capsLock)?.isPressed == true {
                mask |= UInt16(1 << 8)
            }
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
        tf.session = session
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
        Task { @MainActor in _ = tf.becomeFirstResponder() }
        return tf
    }

    func updateUIView(_ v: UIView, context: Context) {
        guard let tf = v as? CaptureField else { return }
        tf.session = session
        context.coordinator.isOpen = $isOpen
        tf.onKeyboardDismiss = context.coordinator.dismissKeyboard
        if !isOpen, tf.isFirstResponder {
            tf.resignFirstResponder()
        } else if isOpen, !tf.isFirstResponder {
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
        weak var session: SessionModel?
        var onKeyboardDismiss: (() -> Void)?

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
                session?.send(.key(usage: 0x2A, down: true, modifiers: modifiers))
                session?.send(.key(usage: 0x2A, down: false, modifiers: modifiers))
            } else if string == "\n" {
                session?.send(.key(usage: 0x28, down: true, modifiers: modifiers))
                session?.send(.key(usage: 0x28, down: false, modifiers: modifiers))
            } else if let shortcut = SoftKeyboardShortcutMapper.map(string, baseModifiers: modifiers),
                      shortcut.modifiers != 0 {
                session?.send(.key(usage: shortcut.usage, down: true, modifiers: shortcut.modifiers))
                session?.send(.key(usage: shortcut.usage, down: false, modifiers: shortcut.modifiers))
            } else {
                session?.send(.text(string))
            }
            // Keep the buffer non-empty so backspace keeps firing.
            textField.text = " "
            return false
        }

        override func deleteBackward() {
            let modifiers = session?.softModifierMask ?? 0
            session?.send(.key(usage: 0x2A, down: true, modifiers: modifiers))
            session?.send(.key(usage: 0x2A, down: false, modifiers: modifiers))
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
