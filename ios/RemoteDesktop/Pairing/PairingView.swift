import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var computerUseSetup: ComputerUseSetupCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var discovery = LocalHostDiscovery()
    @State private var code: String = ""
    @State private var showCodeEntry = false
    @State private var aiHelpMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let err = session.error {
                    errorBanner(err)
                }

                availableDevices
                manualPairing
                privacyPolicyLink
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGroupedBackground),
                    Color(uiColor: .secondarySystemGroupedBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
                .ignoresSafeArea()
        }
        .onAppear { discovery.start() }
        .onChange(of: discovery.hosts) { _, hosts in
            computerUseSetup.reconcile(hosts: hosts)
        }
        .onDisappear { discovery.stop() }
        .alert(
            "AI Computer Use isn’t available yet",
            isPresented: Binding(
                get: { aiHelpMessage != nil },
                set: { if !$0 { aiHelpMessage = nil } })
        ) {
            Button("OK", role: .cancel) { aiHelpMessage = nil }
        } message: {
            Text(aiHelpMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AppLogo(size: 54)
                .padding(10)
                .logoGlassPlate(size: 74, cornerRadius: 22)

            VStack(alignment: .leading, spacing: 10) {
                Text("Connect to your computer")
                    .font(horizontalSizeClass == .compact
                        ? .title2.weight(.bold)
                        : .largeTitle.weight(.bold))
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
                    .minimumScaleFactor(0.8)

                Text("Choose your Mac below. If it isn’t listed, enter the pairing code shown by Remote Desktop Host on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.red.opacity(0.16), lineWidth: 1)
            }
    }

    private var availableDevices: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Available devices",
                count: discovery.hosts.isEmpty ? nil : discovery.hosts.count,
                isLoading: discovery.hosts.isEmpty
            )

            if discovery.hosts.isEmpty {
                emptyDevicesState
            } else {
                VStack(spacing: 10) {
                    ForEach(discovery.hosts) { host in
                        hostButton(host)
                    }
                }
            }

            #if targetEnvironment(simulator)
            simulatorCloudKitHint
            #endif
        }
        .padding(18)
        .sectionSurface()
    }

    #if targetEnvironment(simulator)
    private var simulatorCloudKitHint: some View {
        Label {
            #if DEBUG
            Text("This Debug Simulator app finds Debug Mac hosts. To connect to the official Mac host, run the iOS app in Release.")
            #else
            Text("This Release Simulator app can find the official Mac host through iCloud.")
            #endif
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Simulator iCloud environment")
    }
    #endif

    private var emptyDevicesState: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Searching for hosts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Open Remote Desktop Host on your Mac, or use a pairing code below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var manualPairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "Pair with code")

            Button {
                toggleCodeEntry()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "number.square")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: Circle())

                    Text("Enter code")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(showCodeEntry ? .degrees(180) : .zero)
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(session.state == .connecting)

            if showCodeEntry {
                codeEntryForm
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }
        }
        .padding(18)
        .sectionSurface()
        .animation(.smooth(duration: 0.28), value: showCodeEntry)
    }

    private var privacyPolicyLink: some View {
        Link(destination: Config.privacyPolicyURL) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                Text("Privacy Policy")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Privacy Policy")
        .accessibilityHint("Opens the privacy policy in your browser")
        .accessibilityIdentifier("privacy-policy-link")
    }

    private var codeEntryForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 42, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .tracking(8)
                .focused($focused)
                .onChange(of: code) { _, value in
                    code = String(value.filter(\.isNumber).prefix(6))
                    if code.count == 6 { submit() }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.62) : Color.primary.opacity(0.08), lineWidth: 1)
                }
                .accessibilityLabel("Pairing code")

            Button(action: submit) {
                HStack {
                    Spacer()
                    if case .connecting = session.state {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Connect")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count != 6 || session.state == .connecting)
        }
        .padding(16)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func sectionHeader(title: String, count: Int? = nil, isLoading: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func hostButton(_ host: LocalHostAdvertisement) -> some View {
        let computerUseAction: ComputerUseRowAction = if host.canOfferComputerUse {
            ComputerUseRowAction.resolve(
                host: host,
                state: computerUseSetup.state(for: host))
        } else {
            .unavailable(
                "Remote control is available nearby. AI Computer Use will become available after iCloud confirms this Mac for the current app version. Keep Remote Desktop Host open and make sure both devices use the same Apple Account.")
        }

        Group {
            if horizontalSizeClass == .compact {
                VStack(spacing: 10) {
                    remoteControlButton(
                        host,
                        computerUseAction: computerUseAction)

                    computerUseActionView(
                        computerUseAction,
                        host: host,
                        fillsWidth: true)
                }
            } else {
                HStack(spacing: 10) {
                    remoteControlButton(
                        host,
                        computerUseAction: computerUseAction)

                    computerUseActionView(
                        computerUseAction,
                        host: host,
                        fillsWidth: false)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func remoteControlButton(
        _ host: LocalHostAdvertisement,
        computerUseAction: ComputerUseRowAction
    ) -> some View {
        Button {
            connect(to: host, experience: .remoteControl)
        } label: {
            hostSummary(host, computerUseAction: computerUseAction)
        }
        .buttonStyle(.plain)
        .disabled(session.state == .connecting)
    }

    private func hostSummary(
        _ host: LocalHostAdvertisement,
        computerUseAction: ComputerUseRowAction
    ) -> some View {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(host.hostname)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(host.source == .cloudKit ? "Ready through iCloud" : "Ready nearby")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    computerUseStatus(computerUseAction, host: host)
                }
                .layoutPriority(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(6)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func computerUseActionView(
        _ action: ComputerUseRowAction,
        host: LocalHostAdvertisement,
        fillsWidth: Bool
    ) -> some View {
        switch action {
        case .hidden:
            EmptyView()

        case .unavailable(let message):
            Button {
                aiHelpMessage = message
            } label: {
                computerUseButtonLabel(
                    host.canOfferComputerUse ? "AI info" : "Checking",
                    systemImage: host.canOfferComputerUse ? "info.circle" : "icloud",
                    fillsWidth: fillsWidth)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(.secondary)
            .accessibilityLabel("AI Computer Use availability for \(host.hostname)")
            .accessibilityHint(message)

        case .setup:
            Button {
                computerUseSetup.startSetup(for: host)
            } label: {
                computerUseButtonLabel(
                    "Set up AI",
                    systemImage: "sparkles",
                    fillsWidth: fillsWidth)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(.indigo)
            .disabled(session.state == .connecting)
            .accessibilityLabel("Set up AI Computer Use on \(host.hostname)")
            .accessibilityHint("Downloads and prepares AI on your Mac")

        case .progress(let progress):
            setupProgress(progress, host: host, fillsWidth: fillsWidth)

        case .useAI:
            Button {
                connect(to: host, experience: .computerUse)
            } label: {
                computerUseButtonLabel(
                    "Use AI",
                    systemImage: "sparkles",
                    fillsWidth: fillsWidth)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(.indigo)
            .disabled(session.state == .connecting)
            .accessibilityLabel("Use AI Computer Use on \(host.hostname)")
            .accessibilityHint("Opens a chat with the live computer screen")

        case .retry(let message):
            Button {
                computerUseSetup.startSetup(for: host)
            } label: {
                computerUseButtonLabel(
                    "Retry",
                    systemImage: "arrow.clockwise",
                    fillsWidth: fillsWidth)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(.orange)
            .disabled(session.state == .connecting)
            .accessibilityLabel("Retry AI setup on \(host.hostname)")
            .accessibilityHint(message)
        }
    }

    @ViewBuilder
    private func computerUseButtonLabel(
        _ title: String,
        systemImage: String,
        fillsWidth: Bool
    ) -> some View {
        if fillsWidth {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 68)
            .frame(minHeight: 52)
        }
    }

    @ViewBuilder
    private func setupProgress(
        _ progress: ComputerUseSetupProgress,
        host: LocalHostAdvertisement,
        fillsWidth: Bool
    ) -> some View {
        Group {
            if fillsWidth {
                HStack(spacing: 10) {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Setting up AI on your Mac")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                VStack(spacing: 7) {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Setting up")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .frame(width: 78)
                .frame(minHeight: 52)
            }
        }
        .foregroundStyle(.indigo)
        .padding(.horizontal, 8)
        .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setting up AI Computer Use on \(host.hostname)")
        .accessibilityValue(progressAccessibilityValue(progress))
    }

    private func progressAccessibilityValue(_ progress: ComputerUseSetupProgress) -> String {
        if let fraction = progress.fractionCompleted {
            return "\(Int((fraction * 100).rounded())) percent, \(progress.detail)"
        }
        return progress.detail
    }

    @ViewBuilder
    private func computerUseStatus(
        _ action: ComputerUseRowAction,
        host: LocalHostAdvertisement
    ) -> some View {
        Group {
            switch action {
            case .hidden:
                EmptyView()
            case .unavailable:
                if host.canOfferComputerUse {
                    Label("AI setup unavailable", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } else {
                    Label("Checking AI availability", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            case .setup:
                Label("AI setup available", systemImage: "sparkles")
                    .foregroundStyle(.indigo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            case .progress(let progress):
                Label(progress.detail, systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.indigo)
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
            case .useAI:
                Label("AI Computer Use available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
            case .retry(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
            }
        }
        .font(.footnote.weight(.medium))
    }

    private func connect(to host: LocalHostAdvertisement, experience: SessionModel.Experience) {
        focused = false
        code = host.code
        session.connect(
            code: host.code,
            experience: experience,
            computerUseHostID: host.senderID,
            hostName: host.hostname)
    }

    private func toggleCodeEntry() {
        withAnimation(.smooth(duration: 0.28)) {
            showCodeEntry.toggle()
        }

        if showCodeEntry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                focused = true
            }
        } else {
            focused = false
        }
    }

    private func submit() {
        guard code.count == 6 else { return }
        focused = false
        session.connect(code: code)
    }
}

private extension View {
    func sectionSurface() -> some View {
        adaptiveGlassSurface(cornerRadius: 22)
            .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}
