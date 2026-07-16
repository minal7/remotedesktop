import SwiftUI

/// AI Computer Use keeps the live, interactive screen visible above a simple
/// conversation. The user can pause automation and take over without leaving
/// the screen, then hand control back with one tap.
struct ComputerUseView: View {
    @EnvironmentObject private var session: SessionModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: ComputerUseSessionModel
    @StateObject private var accessories = AccessoryMonitor()
    @StateObject private var zoom = RemoteScreenZoomController()
    @State private var draft = ""
    @State private var remoteKeyboardOpen = false
    @State private var didExplicitlyResumeAI = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        liveScreen(height: screenHeight(for: proxy.size))
                        controlStrip
                        if let guidance = model.interventionGuidance {
                            interventionCallout(guidance)
                        }
                        if isTakingControl {
                            takeoverInputStrip
                        }
                        conversation
                    }
                    .allowsHitTesting(!isAwaitingApproval)
                    .accessibilityHidden(isAwaitingApproval)

                    if case .approvalRequired(let request) = model.state {
                        approvalPrivacyBackdrop

                        approvalCard(request)
                            .frame(
                                maxHeight: ComputerUseApprovalCardLayout.maximumHeight(
                                    for: proxy.size))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .animation(.easeOut(duration: 0.2), value: isAwaitingApproval)
        }
        .persistentSystemOverlays(.visible)
        .overlay(alignment: .topLeading) {
            if didExplicitlyResumeAI {
                // Fixed, non-secret proof for the credential-safe UI test.
                // Keeping this separate from statusLabel prevents the proof
                // element from carrying dynamic task text.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Human resume recorded")
                    .accessibilityIdentifier("computer-use-human-resume-proof")
                    .allowsHitTesting(false)
            }
        }
        .background {
            if isTakingControl,
               remoteKeyboardOpen,
               model.isConnected {
                SoftKeyboardCapture(isOpen: $remoteKeyboardOpen)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
            if isTakingControl,
               model.isConnected,
               accessories.hasHardwareKeyboard,
               !remoteKeyboardOpen {
                KeyboardCapture()
                    .frame(width: 0, height: 0)
            }
        }
        .onChange(of: model.state) { _, state in
            if case .approvalRequired = state {
                composerFocused = false
            }
            if case .paused = state {
                // A new person-controlled interval needs a fresh, explicit
                // Resume tap before the UI exposes post-resume proof.
                didExplicitlyResumeAI = false
            }
            guard case .paused = state else {
                remoteKeyboardOpen = false
                session.releaseSoftModifiers()
                return
            }
            composerFocused = false
        }
        .onChange(of: accessories.hasHardwareKeyboard) { _, connected in
            if connected { remoteKeyboardOpen = false }
        }
        .onChange(of: model.isConnected) { _, connected in
            guard !connected else { return }
            remoteKeyboardOpen = false
            session.releaseSoftModifiers()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("AI Computer Use", systemImage: "sparkles")
                    .font(.headline)
                Text(session.hostName ?? model.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .connecting = session.state {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting to Mac")
            }
            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label("End", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Ends AI Computer Use and returns to Devices")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func liveScreen(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RemoteScreenView(accessories: accessories, zoom: zoom)
                .background(.black)
                .allowsHitTesting(
                    model.isConnected && !model.isLiveScreenPrivacyShielded)
                .accessibilityHidden(model.isLiveScreenPrivacyShielded)

            if !session.hasReceivedVideoFrame {
                VStack(spacing: 8) {
                    Label(
                        session.state == .connecting
                            ? "Connecting to live screen…"
                            : "Waiting for the Mac screen…",
                        systemImage: "display")
                        .font(.callout.weight(.semibold))
                    Text("If macOS asks, choose Allow on the Mac for RemoteDesktopHost Screen & System Audio Recording. This secure approval can only be completed on the Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("computer-use-live-screen-waiting")
            }

            if model.isLiveScreenPrivacyShielded {
                postMailPrivacyShield
            } else {
                RemoteScreenZoomControls(zoom: zoom)
                    .padding(10)
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.isLiveScreenPrivacyShielded
            ? "Mac screen hidden for this Mail task"
            : session.hasReceivedVideoFrame
                ? "Live interactive screen for \(session.hostName ?? model.hostName)"
                : "Waiting for live screen from \(session.hostName ?? model.hostName)")
        .accessibilityHint(model.isLiveScreenPrivacyShielded
            ? "Choose Show Mac when you are ready to reveal the live desktop."
            : "Turn on Zoom and move to pinch or drag the view without controlling the Mac. Turn it off to control the Mac.")
    }

    private var postMailPrivacyShield: some View {
        Color(uiColor: .systemGroupedBackground)
            .overlay {
                VStack(spacing: 12) {
                    Label(
                        "Mac screen hidden for this Mail task",
                        systemImage: "eye.slash.fill")
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("The request, approval, and result remain visible below. Reveal the Mac only when you’re ready to see the rest of the desktop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.revealLiveScreen()
                    } label: {
                        Label("Show Mac", systemImage: "eye.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("computer-use-show-mac")
                    .accessibilityHint("Explicitly reveals the live Mac screen")
                }
                .padding(20)
                .frame(maxWidth: 520)
            }
            .accessibilityIdentifier("computer-use-approval-privacy-shield")
    }

    private var approvalPrivacyBackdrop: some View {
        Color(uiColor: .systemGroupedBackground)
            .overlay(alignment: .top) {
                Label(
                    "Mac screen hidden while approval is pending",
                    systemImage: "eye.slash.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("computer-use-approval-privacy-shield")
            }
    }

    private var controlStrip: some View {
        HStack(spacing: 10) {
            statusLabel
            Spacer(minLength: 8)

            if case .working = model.state,
               !model.isCancellationPending {
                Button {
                    didExplicitlyResumeAI = false
                    model.takeControl()
                } label: {
                    Label("Take control", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("computer-use-take-control")
                .accessibilityHint("Pauses AI so you can use the live screen yourself")
                .disabled(!model.isConnected)
            } else if case .paused = model.state {
                Button(role: .destructive) {
                    didExplicitlyResumeAI = false
                    model.stopCurrentTask()
                } label: {
                    Label("Stop task", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("computer-use-stop-task")
                .disabled(!model.isConnected)

                Button {
                    // This marker is the UI-test's sole proof that the person,
                    // rather than a timeout or task-state race, returned
                    // control to AI. It contains no private screen data.
                    didExplicitlyResumeAI = true
                    model.resumeAI()
                } label: {
                    Label("Let AI continue", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("computer-use-resume-ai")
                .disabled(!model.isConnected)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var takeoverInputStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Label("You’re controlling the Mac", systemImage: "hand.point.up.left.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                if !accessories.hasHardwareKeyboard || remoteKeyboardOpen {
                    ModifierBar()

                    Button {
                        composerFocused = false
                        remoteKeyboardOpen.toggle()
                    } label: {
                        Label(
                            remoteKeyboardOpen ? "Hide keyboard" : "Keyboard",
                            systemImage: remoteKeyboardOpen
                                ? "keyboard.chevron.compact.down"
                                : "keyboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint("Types directly into the Mac, not into AI chat")
                }

                if accessories.hasHardwareKeyboard {
                    Label("Hardware keyboard active", systemImage: "keyboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !remoteKeyboardOpen {
                        Button {
                            composerFocused = false
                            remoteKeyboardOpen = true
                        } label: {
                            Label("Keyboard", systemImage: "keyboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint(
                            "Opens an on-screen keyboard that types directly into the Mac")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("computer-use-manual-control")
    }

    private func interventionCallout(_ guidance: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(guidance)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(guidance)
        .accessibilityIdentifier("computer-use-intervention-guidance")
    }

    private var isTakingControl: Bool {
        if model.isConnected, case .paused = model.state { return true }
        return false
    }

    private var isAwaitingApproval: Bool {
        if case .approvalRequired = model.state { return true }
        return false
    }

    private var statusLabel: some View {
        HStack(spacing: 7) {
            statusIcon
            Text(model.interventionGuidance == nil
                ? model.statusText
                : "Waiting for you")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("computer-use-status")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .working:
            ProgressView().controlSize(.mini)
        case .paused:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .approvalRequired:
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.messages.isEmpty {
                        welcome
                    } else {
                        ForEach(model.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .onChange(of: model.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func approvalCard(_ request: ComputerUseApprovalRequest) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Approve before AI continues", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(request.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let details = request.details, !details.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(details) { detail in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detail.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(detail.value.isEmpty ? "None" : detail.value)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing in this step will happen unless you approve it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                approvalActions(request)
            }
            .padding(14)
            .background(.regularMaterial)
        }
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .frame(maxWidth: 720)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) {
            if model.isConnected {
                model.respondToApproval(request, approved: false)
            }
        }
    }

    private func approvalActions(_ request: ComputerUseApprovalRequest) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            Button(role: .destructive) {
                model.respondToApproval(request, approved: false)
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Cancels this action without making the proposed change")
            .disabled(!model.isConnected)

            Button {
                model.respondToApproval(request, approved: true)
            } label: {
                Label(request.confirmLabel ?? "Approve once", systemImage: "checkmark")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Approves only the exact action shown above")
            .disabled(!model.isConnected)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What would you like your Mac to do?", systemImage: "message.fill")
                .font(.headline)
            Text("Describe the result in everyday language. You can watch every step above and take control at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                suggestion("Open Safari and find my next calendar event")
                suggestion("Organize the files on my desktop")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            draft = text
            composerFocused = true
        } label: {
            HStack {
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func messageBubble(_ message: ComputerUseSessionModel.ChatMessage) -> some View {
        HStack {
            if message.author == .user { Spacer(minLength: 44) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(message.author == .user ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.author == .user
                        ? Color.accentColor
                        : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel(message.author == .user ? "You: \(message.text)" : "AI: \(message.text)")
            if message.author != .user { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if model.retryPrompt != nil {
                Button {
                    model.retryLastPrompt()
                } label: {
                    Label("Retry sending the last request", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(!model.isConnected)
            }

            if case .working = model.state,
               !model.isCancellationPending {
                Button(role: .destructive) {
                    model.stopCurrentTask()
                } label: {
                    Label("Stop current task", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!model.isConnected)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    isTakingControl
                        ? "Resume AI to send another request"
                        : model.hasActivePrompt
                            ? "Waiting for the current request"
                        : "Tell your Mac what to do",
                    text: $draft,
                    axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .disabled(
                        isTakingControl
                            || isAwaitingApproval
                            || model.hasActivePrompt
                            || !model.isConnected
                            || !session.hasReceivedVideoFrame)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
                .accessibilityLabel("Send request")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        guard case .connected = session.state,
              model.isConnected,
              session.hasReceivedVideoFrame else { return false }
        switch model.state {
        case .ready, .error:
            break
        case .working, .paused, .approvalRequired:
            return false
        }
        guard !model.hasActivePrompt else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        let prompt = draft
        draft = ""
        composerFocused = false
        model.sendPrompt(prompt)
    }

    private func screenHeight(for size: CGSize) -> CGFloat {
        min(340, max(170, size.height * (size.width > size.height ? 0.36 : 0.3)))
    }
}

enum ComputerUseApprovalCardLayout {
    static func maximumHeight(for viewport: CGSize) -> CGFloat {
        let viewportFraction = viewport.width > viewport.height ? 0.72 : 0.55
        return min(460, max(260, viewport.height * viewportFraction))
    }
}
