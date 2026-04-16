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
    @Published private(set) var hasHardwareKeyboard = false
    @Published private(set) var hasIndirectPointer = false

    private var observers: [NSObjectProtocol] = []

    init() {
        refreshKeyboard()
        let center = NotificationCenter.default
        // Observers on `.main` run on the main thread, which is already
        // the MainActor — no Task hop needed.
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard() } })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshKeyboard() } })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refreshKeyboard() {
        hasHardwareKeyboard = GCKeyboard.coalesced != nil
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
