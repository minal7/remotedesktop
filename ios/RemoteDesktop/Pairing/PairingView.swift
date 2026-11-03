import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var computerUseSetup: ComputerUseSetupCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var discovery = LocalHostDiscovery()
    @State private var aiHelpMessage: String?
    @State private var discoveryAttempt = UUID()
    #if DEBUG
    @State private var latencyProbeConnected = false
    #endif
    private let localCredentialStore = LocalComputerUseCredentialStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let err = session.error {
                    errorBanner(err)
                }

                availableDevices
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
        .onAppear {
            discovery.start()
            #if DEBUG
            connectLatencyProbeHost(in: discovery.hosts)
            #endif
        }
        .onChange(of: discovery.hosts) { _, hosts in
            computerUseSetup.reconcile(hosts: hosts)
            #if DEBUG
            connectLatencyProbeHost(in: hosts)
            #endif
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

                Text("Choose your Mac below. Devices signed into the same Apple Account pair automatically—there are no codes to copy or enter.")
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
                isLoading: false
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
            Text("This Debug Simulator app pairs with Debug Mac hosts. Run both apps in Release to use the installed host and its matching local database.")
            #else
            Text("This Release app pairs automatically with the installed Release Mac host through your private iCloud account.")
            #endif
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Simulator local environment")
    }
    #endif

    @ViewBuilder
    private var emptyDevicesState: some View {
        if let status = discovery.accountPairingStatus {
            cloudAccountActionState(status)
        } else {
            searchingDevicesState
        }
    }

    private var searchingDevicesState: some View {
        ConnectionWaitNotice(
            title: "Searching for hosts…",
            recovery: "Can’t find your computer. Open the host app, use the same Apple Account, and check that both devices are online.",
            retry: {
                discovery.stop()
                discovery.start()
                discoveryAttempt = UUID()
            })
            .id(discoveryAttempt)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cloudAccountActionState(
        _ status: LocalCloudAccountPairingStatus
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: status.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(status.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cloud-account-action-required")
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
        let localPromptReady = host.canOfferLocalComputerUse
            && hasLocalCredential(for: host)
        let computerUseAction: ComputerUseRowAction = if host.canOfferLocalComputerUse,
           !localPromptReady {
            if host.hasAuthenticatedCloudMatch {
                switch discovery.automaticPairingState(for: host) {
                case .failed(let message):
                    .retryLocalPairing(message)
                case .pairing, .none:
                    .pairingLocal
                }
            } else {
                .unavailable(
                    "Sign into the same Apple Account on this device and the Mac so local AI can pair automatically.")
            }
        } else if host.canOfferComputerUse {
            ComputerUseRowAction.resolve(
                host: host,
                state: computerUseSetup.state(for: host),
                localPromptReady: localPromptReady)
        } else {
            .unavailable(
                "Remote control is available nearby. Update and reopen Remote Desktop Host to enable its secure local AI connection.")
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
        .accessibilityLabel(
            "Remote control \(host.accessibilityDisplayName)")
        .accessibilityHint("Connects to this exact Mac")
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
                    Text(hostAvailabilityLabel(host))
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
            .accessibilityLabel(
                "AI Computer Use availability for \(host.accessibilityDisplayName)")
            .accessibilityHint(message)

        case .pairingLocal:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Securing AI")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .padding(.horizontal, fillsWidth ? 10 : 8)
            .foregroundStyle(.indigo)
            .background(
                Color.indigo.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Pairing local AI automatically on \(host.accessibilityDisplayName)")

        case .retryLocalPairing(let message):
            Button {
                discovery.retryAutomaticPairing(for: host)
            } label: {
                computerUseButtonLabel(
                    "Retry AI",
                    systemImage: "arrow.clockwise.icloud",
                    fillsWidth: fillsWidth)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(.orange)
            .disabled(session.state == .connecting)
            .accessibilityLabel(
                "Retry automatic local AI pairing on \(host.accessibilityDisplayName)")
            .accessibilityHint(message)

        case .setup:
            Button {
                computerUseSetup.startSetup(for: host)
            } label: {
                computerUseButtonLabel(
                    "Set up Computer use (Beta)",
                    systemImage: "sparkles",
                    fillsWidth: fillsWidth)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(.indigo)
            .disabled(session.state == .connecting)
            .accessibilityLabel(
                "Set up AI Computer Use on \(host.accessibilityDisplayName)")
            .accessibilityHint("Downloads and prepares AI on your Mac")

        case .progress(let progress):
            setupProgress(progress, host: host, fillsWidth: fillsWidth)

        case .useAI:
            VStack(spacing: 8) {
                useAIButton(host: host, fillsWidth: fillsWidth)
                if host.computerUseCapability.state == .ready {
                    Button("Check AI setup", systemImage: "arrow.down.circle") {
                        computerUseSetup.checkSetup(for: host)
                    }
                    .font(.caption)
                    .disabled(session.state == .connecting)
                    .accessibilityLabel("Check and finish AI setup on \(host.accessibilityDisplayName)")
                }
            }

        case .useAIWithSetupFailure(let message):
            VStack(spacing: 8) {
                useAIButton(host: host, fillsWidth: fillsWidth)
                Button("Retry additional setup", systemImage: "arrow.clockwise") {
                    computerUseSetup.checkSetup(for: host)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(session.state == .connecting || host.computerUseCapability.state != .ready)
                .accessibilityLabel("Retry additional AI setup on \(host.accessibilityDisplayName)")
                .accessibilityHint(message)
            }

        case .retry(let message):
            Button {
                computerUseSetup.checkSetup(for: host)
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
            .accessibilityLabel(
                "Retry AI setup on \(host.accessibilityDisplayName)")
            .accessibilityHint(message)
        }
    }

    private func useAIButton(host: LocalHostAdvertisement, fillsWidth: Bool) -> some View {
        Button {
            connect(to: host, experience: .computerUse)
        } label: {
            computerUseButtonLabel("Computer use (Beta)", systemImage: "sparkles", fillsWidth: fillsWidth)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(.indigo)
        .disabled(session.state == .connecting)
        .accessibilityLabel("Use AI Computer Use on \(host.accessibilityDisplayName)")
        .accessibilityHint("Opens a secure local AI conversation")
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
        .accessibilityLabel(
            "Setting up AI Computer Use on \(host.accessibilityDisplayName)")
        .accessibilityValue(progressAccessibilityValue(progress))
    }

    private func hostAvailabilityLabel(
        _ host: LocalHostAdvertisement
    ) -> String {
        let readiness = host.source == .cloudKit
            ? "Ready through iCloud" : "Ready nearby"
        guard let discriminator = host.presentationDiscriminator else {
            return readiness
        }
        return "\(readiness) • \(discriminator)"
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
            case .pairingLocal:
                Label("Pairing local AI automatically", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.indigo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            case .retryLocalPairing(let message):
                Label(message, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
            case .setup:
                Label("Computer use (Beta) setup available", systemImage: "sparkles")
                    .foregroundStyle(.indigo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            case .progress(let progress):
                Label(progress.detail, systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.indigo)
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
            case .useAI:
                Label(host.computerUseCapability.detail.isEmpty ? "Computer use (Beta) available" : host.computerUseCapability.detail,
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
            case .retry(let message), .useAIWithSetupFailure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
            }
        }
        .font(.footnote.weight(.medium))
    }

    #if DEBUG
    private func connectLatencyProbeHost(in hosts: [LocalHostAdvertisement]) {
        let args = ProcessInfo.processInfo.arguments
        guard LatencyStatsCollector.enabled, !latencyProbeConnected,
              let index = args.firstIndex(of: "LatencyProbeHostID"),
              args.indices.contains(index + 1), let requested = UUID(uuidString: args[index + 1]) else { return }
        let matches = hosts.filter { host in
            guard host.hasAuthenticatedCloudMatch, host.accountBinding != nil,
                  let sender = host.senderID, let id = UUID(uuidString: sender) else { return false }
            return id == requested
        }
        guard matches.count == 1 else { return }
        latencyProbeConnected = true
        connect(to: matches[0], experience: .remoteControl)
    }
    #endif

    private func connect(to host: LocalHostAdvertisement, experience: SessionModel.Experience) {
        session.connect(
            code: host.code,
            experience: experience,
            computerUseHostID: host.senderID,
            hostName: host.hostname,
            localComputerUseEndpoint: host.localEndpoint,
            localCredentialID: host.localCredentialID,
            localCloudAccountBinding: host.accountBinding)
    }

    private func hasLocalCredential(
        for host: LocalHostAdvertisement
    ) -> Bool {
        guard let hostID = host.senderID,
              let credentialID = host.localCredentialID,
              let accountBinding = host.accountBinding else {
            return false
        }
        return localCredentialStore.clientCredential(
            hostID: hostID,
            credentialID: credentialID,
            accountBinding: accountBinding) != nil
    }

}

private extension View {
    func sectionSurface() -> some View {
        adaptiveGlassSurface(cornerRadius: 22)
            .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}
