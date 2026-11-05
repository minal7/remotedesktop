import Combine
import GameController
import UIKit

/// Observes presence of a hardware keyboard and indirect pointer
/// (trackpad / Magic Mouse / Pencil hover). The session chrome reads
/// `chromeMode` and hides on-screen controls that an attached accessory
/// already covers.
///
/// Pointer presence isn't exposed via a system notification, so callers
/// from `RemoteScreenView`'s hover recognizer call
/// `noteIndirectPointer(active:)` when a hover begins/ends.
@MainActor
final class AccessoryMonitor: ObservableObject {
    /// A keyboard is believed to be physically attached, so on-screen keys can go.
    @Published private(set) var hasHardwareKeyboard = false
    /// The system lists a keyboard. It also lists a "Generic Keyboard" with nothing
    /// attached, so this only says that key presses should be listened for.
    @Published private(set) var keyboardListed = false
    @Published private(set) var hasIndirectPointer = false

    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter
    private let keyboardName: @MainActor () -> String?
    private let memory: HardwareKeyboardMemory

    /// Remembered for the life of the app, so a new session starts with the right controls.
    final class HardwareKeyboardMemory {
        static let shared = HardwareKeyboardMemory()
        var keyPressSeen = false
    }

    init(center: NotificationCenter = .default,
         memory: HardwareKeyboardMemory = .shared,
         keyboardName: @escaping @MainActor () -> String? = {
             GCKeyboard.coalesced.map { $0.vendorName ?? "Generic Keyboard" }
         }) {
        self.center = center
        self.memory = memory
        self.keyboardName = keyboardName
        refreshKeyboard()
        // Observers on `.main` run on the main thread, which is already
        // the MainActor — no Task hop needed.
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard() } })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            // The keyboard can still be listed while this notification is delivered.
            MainActor.assumeIsolated {
                self?.refreshKeyboard()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.refreshKeyboard()
                }
            }
        })
        // A keyboard attached or removed while the app was away sends nothing on return.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard() } })
    }

    deinit {
        observers.forEach { center.removeObserver($0) }
    }

    func refreshKeyboard() {
        let name = keyboardName()
        if name == nil { memory.keyPressSeen = false }
        let named = name.map { !$0.lowercased().hasPrefix("generic") } ?? false
        let present = name != nil && (named || memory.keyPressSeen)
        #if DEBUG
        if present != hasHardwareKeyboard || (name != nil) != keyboardListed {
            SessionEventLog.record("hardware_keyboard present=\(present) listed=\(name ?? "nil") keyPressSeen=\(memory.keyPressSeen)")
        }
        #endif
        keyboardListed = name != nil
        hasHardwareKeyboard = present
    }

    /// A real key press proves a keyboard is attached, whatever it is called.
    func noteHardwareKeyPress() {
        guard !memory.keyPressSeen else { return }
        memory.keyPressSeen = true
        refreshKeyboard()
    }

    func noteIndirectPointer(active: Bool) {
        if hasIndirectPointer != active {
            hasIndirectPointer = active
        }
    }

    /// How much chrome to paint over the remote screen.
    ///
    /// - `minimal`: hardware keyboard AND indirect pointer are connected.
    ///   Show only a thin status strip. Everything else is the remote screen.
    /// - `partial`: one of the two is connected; surface controls for the
    ///   missing channel only.
    /// - `full`: neither is connected; show touch-cursor affordances,
    ///   soft-keyboard toggle, and on-screen modifier keys.
    var chromeMode: ChromeMode {
        switch (hasHardwareKeyboard, hasIndirectPointer) {
        case (true, true):  return .minimal
        case (true, false): return .partial(missing: .pointer)
        case (false, true): return .partial(missing: .keyboard)
        case (false, false): return .full
        }
    }

    enum ChromeMode: Equatable {
        case minimal
        case partial(missing: MissingChannel)
        case full
    }

    enum MissingChannel: Equatable { case keyboard, pointer }
}
