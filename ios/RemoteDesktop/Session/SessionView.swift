import SwiftUI

/// Top-level in-session UI. Layers accessory-aware chrome over a
/// full-bleed `RemoteScreenView`. The chrome collapses to a status
/// strip only when both a hardware keyboard and an indirect pointer
/// are present.
struct SessionView: View {
    @EnvironmentObject private var session: SessionModel
    @StateObject private var accessories = AccessoryMonitor()
    @State private var softKeyboardOpen = false

    var body: some View {
        ZStack(alignment: .top) {
            RemoteScreenView(accessories: accessories)
                .ignoresSafeArea()

            chrome

            if softKeyboardOpen {
                SoftKeyboardCapture(isOpen: $softKeyboardOpen)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }

            // Hardware-keyboard capture is an invisible overlay that wires
            // GCKeyboard's raw key events into the transport. It's present
            // whenever a hardware keyboard is connected.
            if accessories.hasHardwareKeyboard {
                KeyboardCapture()
                    .frame(width: 0, height: 0)
            }
        }
        .statusBarHidden(accessories.chromeMode == .minimal)
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var chrome: some View {
        switch accessories.chromeMode {
        case .minimal:
            statusStrip.transition(.opacity)
        case .partial(let missing):
            statusStrip
            if missing == .keyboard {
                softKeyboardButton
            }
            // When only pointer is missing, the RemoteScreenView already
            // renders the floating touch cursor; no extra chrome needed.
        case .full:
            statusStrip
            softKeyboardButton
            VStack {
                Spacer()
                ModifierBar().padding(.bottom, 12)
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text(session.hostName ?? "Connecting…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { session.disconnect() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Disconnect")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var softKeyboardButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { softKeyboardOpen.toggle() } label: {
                    Image(systemName: softKeyboardOpen
                          ? "keyboard.chevron.compact.down"
                          : "keyboard")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(14)
                        .background(.thinMaterial, in: Circle())
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .accessibilityLabel(softKeyboardOpen ? "Hide keyboard" : "Show keyboard")
            }
        }
    }
}
