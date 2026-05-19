import SwiftUI

/// Top-level in-session UI. Layers accessory-aware chrome over a
/// full-bleed `RemoteScreenView`.
///
/// **Portrait** – chrome (status strip + keyboard controls) is always
/// visible; there's plenty of vertical space and hiding it would make
/// the disconnect action unreachable.
///
/// **Landscape** – chrome hides after 3 s and is revealed by dragging
/// down from the top edge, keeping the remote screen unobstructed.
///
/// A left → right swipe across the full screen triggers disconnect
/// with a visual progress indicator.
struct SessionView: View {
    @EnvironmentObject private var session: SessionModel
    @StateObject private var accessories = AccessoryMonitor()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var softKeyboardOpen = false
    @State private var restoreSoftKeyboardAfterHardwareDisconnect = false
    @State private var chromeRevealed = false
    @State private var hideTask: Task<Void, Never>?

    // Special-key idle translucency (landscape only)
    @State private var specialKeysIdle = false
    @State private var specialKeysIdleTask: Task<Void, Never>?

    // Swipe-to-disconnect state
    @State private var disconnectDragOffset: CGFloat = 0
    @State private var disconnectTriggered = false

    /// In portrait (`.regular` vertical size class) chrome is permanent.
    private var isPortrait: Bool { verticalSizeClass == .regular }

    /// Whether the chrome overlay should be showing right now.
    private var shouldShowChrome: Bool {
        isPortrait || chromeRevealed
    }

    private var specialKeysAttentive: Bool {
        !specialKeysIdle || softKeyboardOpen || session.softModifierMask != 0
    }

    private var inputModeTitle: String {
        switch (accessories.hasHardwareKeyboard, accessories.hasIndirectPointer) {
        case (true, true):
            return "Keyboard and pointer"
        case (true, false):
            return "Keyboard and touch cursor"
        case (false, true):
            return "Pointer and soft keys"
        case (false, false):
            return "Touch cursor and soft keys"
        }
    }

    private var specialKeysIdleOpacity: Double {
        // Keep the composited controls above SwiftUI's low-opacity hit-test edge.
        isPortrait ? 0.62 : 0.56
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ── Remote screen ──────────────────────────────────
            RemoteScreenView(accessories: accessories)
                .ignoresSafeArea()

            // ── Disconnect swipe indicator ─────────────────────
            if disconnectDragOffset > 0 {
                disconnectIndicator
            }

            // ── Left-edge swipe strip (disconnect) ─────────────
            leftEdgeSwipeStrip

            // ── Top-edge drag handle (landscape only) ──────────
            if !isPortrait && !chromeRevealed {
                landscapeDragHandle
            }

            // ── Chrome overlay ─────────────────────────────────
            if shouldShowChrome {
                chrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Input controls (orientation-aware) ─────────────
            inputDock

            // ── Invisible soft-keyboard capture ────────────────
            if softKeyboardOpen && !accessories.hasHardwareKeyboard {
                SoftKeyboardCapture(isOpen: $softKeyboardOpen)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }

            // ── Hardware-keyboard capture ──────────────────────
            if accessories.hasHardwareKeyboard {
                KeyboardCapture()
                    .frame(width: 0, height: 0)
            }
        }
        .statusBarHidden(!shouldShowChrome)
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: shouldShowChrome)
        .animation(.smooth(duration: 0.32), value: accessories.hasHardwareKeyboard)
        .animation(.smooth(duration: 0.32), value: accessories.hasIndirectPointer)
        .onChange(of: isPortrait) { _, _ in
            // Reset landscape chrome state when rotating back to portrait.
            if isPortrait {
                hideTask?.cancel()
                chromeRevealed = false
            }
        }
        .onChange(of: accessories.hasHardwareKeyboard) { _, connected in
            handleHardwareKeyboardChange(connected)
        }
    }

    // MARK: - Left-edge swipe strip

    /// A narrow invisible strip along the left edge that captures the
    /// swipe-to-disconnect gesture. Only edge swipes trigger it so the
    /// rest of the screen is free for touch-cursor mouse input.
    private var leftEdgeSwipeStrip: some View {
        HStack {
            Color.clear
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(disconnectSwipeGesture)
            Spacer()
        }
        .ignoresSafeArea()
    }

    // MARK: - Landscape top-edge drag handle

    private var landscapeDragHandle: some View {
        VStack(spacing: 0) {
            // The handle itself
            Color.clear
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            if value.translation.height > 12 {
                                revealChrome()
                            }
                        }
                )
                .overlay(alignment: .bottom) {
                    // Subtle pill hint so users know they can drag
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 36, height: 4)
                        .padding(.bottom, 6)
                }
            Spacer()
        }
    }

    // MARK: - Chrome reveal / auto-hide (landscape only)

    private func revealChrome() {
        chromeRevealed = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            chromeRevealed = false
        }
    }

    // MARK: - Chrome (status strip)

    @ViewBuilder
    private var chrome: some View {
        statusStrip
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            // Connection indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.6), radius: 4, y: 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.hostName ?? "Connecting...")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(inputModeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Disconnect button
            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red.opacity(0.86))
                    .frame(width: 32, height: 32)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("Disconnect")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 0)
        )
        .overlay(alignment: .bottom) {
            // Hairline separator
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    // MARK: - Input dock (orientation-aware)

    @ViewBuilder
    private var inputDock: some View {
        let needsKeyboard = !accessories.hasHardwareKeyboard
        let needsModifiers = !accessories.hasHardwareKeyboard

        if needsKeyboard || needsModifiers {
            VStack(spacing: 0) {
                Spacer()
                inputDockContent(needsKeyboard: needsKeyboard,
                                 needsModifiers: needsModifiers)
            }
            .opacity(specialKeysAttentive ? 1.0 : specialKeysIdleOpacity)
            .animation(.easeInOut(duration: 0.35), value: specialKeysAttentive)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { scheduleSpecialKeysIdle() }
            .onDisappear {
                specialKeysIdleTask?.cancel()
                specialKeysIdle = false
            }
            .onChange(of: isPortrait) { _, _ in wakeSpecialKeys() }
            .onChange(of: softKeyboardOpen) { _, open in
                if open {
                    wakeSpecialKeys()
                } else {
                    scheduleSpecialKeysIdle()
                }
            }
            .onChange(of: session.softModifierMask) { _, mask in
                if mask == 0 {
                    scheduleSpecialKeysIdle()
                } else {
                    wakeSpecialKeys()
                }
            }
        }
    }

    /// Builds the actual row of controls. In portrait they sit as a compact
    /// bar just above the keyboard (bottom safe-area edge); in landscape they
    /// anchor flush at the very bottom of the screen.
    @ViewBuilder
    private func inputDockContent(needsKeyboard: Bool,
                                  needsModifiers: Bool) -> some View {
        if isPortrait {
            // ── Portrait: bottom-aligned, compact row ──────────
            inputDockRow(needsKeyboard: needsKeyboard,
                         needsModifiers: needsModifiers)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else {
            // ── Landscape: free-floating buttons at screen bottom ──
            inputDockRow(needsKeyboard: needsKeyboard,
                         needsModifiers: needsModifiers)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private func inputDockRow(needsKeyboard: Bool,
                              needsModifiers: Bool) -> some View {
        HStack(spacing: 12) {
            if needsModifiers {
                ModifierBar(attentive: specialKeysAttentive,
                            onInteraction: wakeSpecialKeys)
            }
            Spacer(minLength: 8)
            if needsKeyboard {
                softKeyboardButton
            }
        }
    }

    private func handleHardwareKeyboardChange(_ connected: Bool) {
        withAnimation(.smooth(duration: 0.32)) {
            if connected {
                restoreSoftKeyboardAfterHardwareDisconnect = softKeyboardOpen
                softKeyboardOpen = false
                session.releaseSoftModifiers()
                specialKeysIdle = true
            } else {
                specialKeysIdle = false
                if restoreSoftKeyboardAfterHardwareDisconnect {
                    softKeyboardOpen = true
                    restoreSoftKeyboardAfterHardwareDisconnect = false
                }
                wakeSpecialKeys()
            }
        }
    }

    // MARK: - Idle translucency helpers

    private func wakeSpecialKeys() {
        specialKeysIdle = false
        scheduleSpecialKeysIdle()
    }

    private func scheduleSpecialKeysIdle() {
        specialKeysIdleTask?.cancel()
        specialKeysIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard !softKeyboardOpen, session.softModifierMask == 0 else { return }
            specialKeysIdle = true
        }
    }

    @ViewBuilder
    private var softKeyboardButton: some View {
        let attentive = specialKeysAttentive

        Button {
            softKeyboardOpen.toggle()
            wakeSpecialKeys()
        } label: {
            Image(systemName: softKeyboardOpen
                  ? "keyboard.chevron.compact.down"
                  : "keyboard")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(softKeyboardOpen ? 1 : (attentive ? 0.88 : 0.64)))
                .frame(width: 52, height: 52)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .fill(
                            softKeyboardOpen
                                ? Color.accentColor.opacity(0.86)
                                : Color.black.opacity(attentive ? 0.16 : 0.04)
                        )
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(softKeyboardOpen ? 0.26 : (attentive ? 0.16 : 0.08)),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(attentive ? 0.3 : 0.12),
                        radius: attentive ? 12 : 4,
                        y: attentive ? 4 : 1)
                .scaleEffect(softKeyboardOpen ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(softKeyboardOpen ? "Hide keyboard" : "Show keyboard")
        .animation(.easeInOut(duration: 0.25), value: softKeyboardOpen)
        .animation(.easeInOut(duration: 0.3), value: attentive)
    }

    // MARK: - Swipe-right to disconnect

    private let disconnectThreshold: CGFloat = 160

    private var disconnectSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Only track mostly-horizontal rightward swipes.
                guard dx > 0, abs(dy) < dx * 0.6 else {
                    disconnectDragOffset = 0
                    return
                }
                withAnimation(.interactiveSpring()) {
                    disconnectDragOffset = dx
                }
                if dx >= disconnectThreshold && !disconnectTriggered {
                    disconnectTriggered = true
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                }
            }
            .onEnded { value in
                if disconnectTriggered {
                    session.disconnect()
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    disconnectDragOffset = 0
                }
                disconnectTriggered = false
            }
    }

    private var disconnectIndicator: some View {
        let progress = min(disconnectDragOffset / disconnectThreshold, 1.0)
        let triggered = progress >= 1.0

        return GeometryReader { geo in
            ZStack {
                // Left-edge red glow
                HStack {
                    LinearGradient(
                        colors: [
                            Color.red.opacity(triggered ? 0.45 : 0.2 * progress),
                            Color.red.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(disconnectDragOffset * 0.7, 0))
                    .allowsHitTesting(false)
                    Spacer()
                }

                // Arrow + label
                HStack(spacing: 8) {
                    Image(systemName: triggered
                          ? "xmark.circle.fill"
                          : "chevron.right.2")
                        .font(.system(size: triggered ? 28 : 22, weight: .bold))
                        .foregroundStyle(triggered ? Color.red : .white.opacity(0.7))

                    if triggered {
                        Text("Release to disconnect")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .offset(x: min(disconnectDragOffset * 0.4 - 60, geo.size.width * 0.3))
                .opacity(Double(progress))
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
