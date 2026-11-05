import SwiftUI
import UIKit

/// Top-level in-session UI. Layers accessory-aware chrome over a
/// full-bleed `RemoteScreenView`.
///
/// The connection strip is shown while the session is being established,
/// then retracts on every device after a short confirmation period. A drag
/// from the top edge reveals it again when the user needs to disconnect.
///
/// A left → right swipe across the full screen triggers disconnect
/// with a visual progress indicator.
struct SessionView: View {
    @EnvironmentObject private var session: SessionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var accessories = AccessoryMonitor()
    @StateObject private var zoom = RemoteScreenZoomController()
    @State private var softKeyboardOpen = false
    @State private var restoreSoftKeyboardAfterHardwareDisconnect = false
    @State private var chromeRevealed = false
    @State private var hideTask: Task<Void, Never>?
    @State private var zoomRecentlyChanged = false
    @State private var zoomHideTask: Task<Void, Never>?
    @GestureState private var touchingZoomControls = false
    #if DEBUG
    @State private var showsVideoStatistics = false
    @State private var showsLatencyLabSettings = false
    @State private var videoStatistics = "Waiting for video stats…"
    #endif

    // Special-key idle translucency
    @State private var specialKeysIdle = false
    @State private var specialKeysIdleTask: Task<Void, Never>?

    // Swipe-to-disconnect state
    @State private var disconnectDragOffset: CGFloat = 0
    @State private var disconnectTriggered = false

    /// Whether the chrome overlay should be showing right now.
    private var shouldShowChrome: Bool {
        chromeRevealed || !session.hasInteractiveRemoteScreen
    }

    private var specialKeysAttentive: Bool {
        !specialKeysIdle || softKeyboardOpen || session.softModifierMask != 0
    }

    private var specialKeysIdleOpacity: Double {
        // Keep the composited controls above SwiftUI's low-opacity hit-test edge.
        0.56
    }

    private var zoomControlsVisible: Bool {
        session.hasInteractiveRemoteScreen
            && SessionZoomControlsPolicy.showsControls(chromeVisible: shouldShowChrome,
                recentlyChanged: zoomRecentlyChanged, touching: touchingZoomControls,
                moveScreenEnabled: zoom.moveScreenEnabled)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // ── Remote screen ──────────────────────────────────
            #if DEBUG
            RemoteScreenView(accessories: accessories, zoom: zoom, allowF4Renderer: true, onLatencyGesture: { showsVideoStatistics.toggle() })
                .ignoresSafeArea()
            #else
            RemoteScreenView(accessories: accessories, zoom: zoom)
                .ignoresSafeArea()
            #endif

            if !session.hasInteractiveRemoteScreen {
                ZStack {
                    if !session.mayRevealRemoteScreenPixels { Color.black.ignoresSafeArea() }
                    VStack(spacing: 12) {
                        if session.inputActivity.allowsInput {
                            ConnectionWaitNotice(
                                title: session.isReconnecting ? "Reconnecting to your computer…"
                                    : (session.state == .connecting ? "Connecting to your computer…" : "Restoring the remote screen…"),
                                recovery: "Check that both devices are online and the host app is open.",
                                retry: { session.reset() })
                        } else {
                            Text("Return to this window to control your Mac.")
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 360)
                    .sessionGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .accessibilityIdentifier("remote-input-unavailable")
            }

            // ── Disconnect swipe indicator ─────────────────────
            if disconnectDragOffset > 0 {
                disconnectIndicator
            }

            // ── Left-edge swipe strip (disconnect) ─────────────
            leftEdgeSwipeStrip

            // ── Top-edge drag handle ───────────────────────────
            if !chromeRevealed {
                topEdgeDragHandle
            }

            // ── Chrome overlay ─────────────────────────────────
            if shouldShowChrome {
                chrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Input controls (orientation-aware) ─────────────
            inputDock
                .disabled(!session.hasInteractiveRemoteScreen)

            // Keep the controls in a safe-area-aware top-left location.
            VStack {
                HStack {
                    ZStack(alignment: .leading) {
                        RemoteScreenZoomControls(zoom: zoom)
                            .opacity(zoomControlsVisible ? 1 : 0)
                            .allowsHitTesting(zoomControlsVisible)
                            .accessibilityHidden(!zoomControlsVisible)
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($touchingZoomControls) { _, touching, _ in
                                        touching = true
                                    }
                            )
                        if !zoomControlsVisible && session.hasInteractiveRemoteScreen {
                            Button(action: showZoomControlsTemporarily) {
                                Text("\(Int((zoom.scale * 100).rounded()))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .padding(.horizontal, 4)
                                    .sessionGlass(in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .opacity(specialKeysIdleOpacity)
                            .accessibilityLabel("Show zoom controls")
                            .accessibilityValue("\(Int((zoom.scale * 100).rounded())) percent")
                            .accessibilityIdentifier("zoomPercentPill")
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                // Wide layouts have room beside the status pill; narrow ones sit below it.
                .padding(.top, shouldShowChrome && horizontalSizeClass != .regular ? 68 : 8)
                Spacer()
            }

            // ── Invisible soft-keyboard capture ────────────────
            if session.hasInteractiveRemoteScreen && softKeyboardOpen && !accessories.hasHardwareKeyboard {
                SoftKeyboardCapture(isOpen: $softKeyboardOpen)
                    .id(session.remoteKeyboardCaptureIdentity)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }

            // ── Hardware-keyboard capture ──────────────────────
            if session.hasInteractiveRemoteScreen && accessories.keyboardListed
                && !(softKeyboardOpen && !accessories.hasHardwareKeyboard) {
                KeyboardCapture(onPhysicalKeyPress: accessories.noteHardwareKeyPress)
                    .id(session.remoteKeyboardCaptureIdentity)
                    .frame(width: 0, height: 0)
            }

            if session.isCloudAccountRevalidationPending {
                accountRevalidationShield
            }
        }
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            if showsVideoStatistics {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(videoStatistics)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("latency-video-statistics")
                        .accessibilityValue("Zoom \(Int((zoom.scale * 100).rounded())) percent")
                    Button("Latency lab") { showsLatencyLabSettings = true }
                        .buttonStyle(.borderedProminent)
                }
                    .padding(8)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 64)
                    .padding(.horizontal, 10)
            }
        }
        .sheet(isPresented: $showsLatencyLabSettings) { LatencyLabSettingsView() }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("LatencyQuality"), LatencyStatsCollector.enabled {
                showsVideoStatistics = true
            }
            if LatencyStatsCollector.enabled, arguments.contains("LatencySoftKeyboardOpen") {
                while !session.hasInteractiveRemoteScreen {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
                softKeyboardOpen = true
            }
            // Lab check that zooming never interrupts the session.
            if LatencyStatsCollector.enabled, arguments.contains("LatencyZoomCycle") {
                while !Task.isCancelled {
                    if session.hasInteractiveRemoteScreen {
                        if zoom.scale >= RemoteZoomPolicy.maximumScale { zoom.reset() } else { zoom.zoomIn() }
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            guard LatencyStatsCollector.enabled,
                  let scenario = arguments.firstIndex(of: "LatencyProbeScenario"),
                  arguments.indices.contains(scenario + 1), arguments[scenario + 1] == "C" else { return }
            var step = 0
            while !Task.isCancelled {
                if RemoteVideoLatencyProbe.shared.hasRecentMarker(),
                   let display = session.display, display.fullDisplaySurface,
                   display.w > 100, display.h > 430, session.hasInteractiveRemoteScreen {
                    // Stay in the synthetic window's blank strip, above its counter cells.
                    let width = max(1, Int(floor(Double(display.w) * 0.42)) - 32)
                    let x = 36 + (step % (width * 2) < width ? step % width : width - 1 - step % width)
                    session.send(.pointer(x: x, y: 345, buttons: 0))
                    step += 8
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
        .task(id: showsVideoStatistics) {
            guard showsVideoStatistics else { return }
            while !Task.isCancelled {
                videoStatistics = await session.debugVideoStatistics()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        #endif
        .statusBarHidden(!shouldShowChrome)
        .onChange(of: session.remoteInputGeneration) { _, _ in
            softKeyboardOpen = false
            restoreSoftKeyboardAfterHardwareDisconnect = false
        }
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: shouldShowChrome)
        .animation(.easeInOut(duration: 0.25), value: zoom.isZoomed)
        .animation(.easeInOut(duration: 0.35), value: zoomControlsVisible)
        .animation(.smooth(duration: 0.32), value: accessories.hasHardwareKeyboard)
        .animation(.smooth(duration: 0.32), value: accessories.hasIndirectPointer)
        .onAppear {
            synchronizeChrome(with: session.state)
        }
        .onChange(of: session.state) { _, state in
            synchronizeChrome(with: state)
        }
        .onChange(of: accessories.hasHardwareKeyboard) { _, connected in
            handleHardwareKeyboardChange(connected)
        }
        .onChange(of: zoom.scale) { _, _ in showZoomControlsTemporarily() }
        .onChange(of: zoom.interactionRevision) { _, _ in showZoomControlsTemporarily() }
        .onChange(of: touchingZoomControls) { _, touching in
            if !touching { showZoomControlsTemporarily() }
        }
        .onDisappear {
            hideTask?.cancel()
            zoomHideTask?.cancel()
            specialKeysIdleTask?.cancel()
        }
    }

    private var accountRevalidationShield: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ConnectionWaitNotice(
                    title: "Verifying Apple Account…",
                    recovery: "Couldn't verify your Apple Account yet. Check your internet connection, then try again.",
                    retry: { session.reset() })
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .accessibilityIdentifier("account-revalidation-shield")
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

    // MARK: - Retractable top-edge drag handle

    private var topEdgeDragHandle: some View {
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

    // MARK: - Chrome reveal / auto-hide

    private func showZoomControlsTemporarily() {
        zoomRecentlyChanged = true
        zoomHideTask?.cancel()
        zoomHideTask = Task { @MainActor in
            try? await Task.sleep(for: SessionZoomControlsPolicy.hideDelay)
            guard !Task.isCancelled else { return }
            zoomRecentlyChanged = false
        }
    }

    private func revealChrome() {
        chromeRevealed = true
        if SessionChromePolicy.autoHides(after: session.state) {
            scheduleAutoHide()
        }
    }

    private func synchronizeChrome(with state: SessionModel.State) {
        hideTask?.cancel()
        chromeRevealed = true
        if SessionChromePolicy.autoHides(after: state) {
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: SessionChromePolicy.autoHideDelay)
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
            Circle()
                .fill(session.hasInteractiveRemoteScreen ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.leading, 8)
            Text(session.hostName ?? "Connecting…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Text(session.state == .connected ? "Disconnect" : "Cancel")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.state == .connected ? "Disconnect" : "Cancel")
        }
        .padding(6)
        .sessionGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityIdentifier("sessionStatusStrip")
    }

    // MARK: - Input dock (orientation-aware)

    /// Shown only while there is no hardware keyboard to do this job.
    @ViewBuilder
    private var inputDock: some View {
        if !accessories.hasHardwareKeyboard {
            VStack(spacing: 0) {
                Spacer()
                inputDockBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            .opacity(specialKeysAttentive ? 1.0 : specialKeysIdleOpacity)
            .animation(.easeInOut(duration: 0.35), value: specialKeysAttentive)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { scheduleSpecialKeysIdle() }
            .onDisappear {
                specialKeysIdleTask?.cancel()
                specialKeysIdle = false
            }
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

    private var inputDockBar: some View {
        HStack(spacing: 6) {
            ModifierKeys(onInteraction: wakeSpecialKeys)
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 24)
            softKeyboardButton
        }
        .padding(4)
        .sessionGlass(in: Capsule())
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

    private var softKeyboardButton: some View {
        Button {
            softKeyboardOpen.toggle()
            wakeSpecialKeys()
        } label: {
            Image(systemName: softKeyboardOpen
                  ? "keyboard.chevron.compact.down"
                  : "keyboard")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SessionKeyStyle())
        .accessibilityLabel(softKeyboardOpen ? "Hide keyboard" : "Show keyboard")
        .accessibilityIdentifier("sessionKeyboardButton")
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

enum SessionChromePolicy {
    static let autoHideDelay: Duration = .seconds(3)

    static func autoHides(after state: SessionModel.State) -> Bool {
        if case .connected = state {
            return true
        }
        return false
    }
}

enum SessionZoomControlsPolicy {
    static let hideDelay: Duration = .seconds(3)

    /// Zoom & move stops touches reaching the Mac, so its switch stays in reach while on.
    static func showsControls(chromeVisible: Bool, recentlyChanged: Bool, touching: Bool,
                              moveScreenEnabled: Bool) -> Bool {
        chromeVisible || recentlyChanged || touching || moveScreenEnabled
    }
}

/// A slow connection is normal, so it keeps looking like progress. Only a wait far
/// beyond the usual time asks the person to check anything, and it never hangs forever.
struct ConnectionWaitNotice: View {
    let title: String
    let recovery: String
    let retry: () -> Void
    @State private var isSlow = false
    @State private var needsHelp = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if needsHelp {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Back to Devices", action: retry)
                    .buttonStyle(.borderedProminent)
            } else if isSlow {
                Text("This can take a little longer on some networks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: title) {
            isSlow = false; needsHelp = false
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            isSlow = true
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            needsHelp = true
        }
    }
}
