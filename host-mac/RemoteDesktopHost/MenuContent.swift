import AppKit
import SwiftUI

/// Popover content for the menu bar status item.
struct MenuContent: View {
    @EnvironmentObject private var session: HostSession
    private let openSetup: () -> Void
    private let openSettings: () -> Void

    init(
        openSetup: @escaping () -> Void = {},
        openSettings: @escaping () -> Void = {}
    ) {
        self.openSetup = openSetup
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            ComputerUseHostSection(manager: session.computerUse)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { session.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 34)
                .padding(7)
                .logoGlassPlate(size: 48, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Desktop Host").font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Settings…", systemImage: "gearshape") {
                    openSettings()
                }
                Button("Setup & Permissions…", systemImage: "checklist") {
                    openSetup()
                }
                Divider()
                Button("Quit Remote Desktop Host", systemImage: "power") {
                    session.stop()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("More options")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            idleView
        case .starting:
            HStack { ProgressView(); Text("Starting…") }
                .frame(maxWidth: .infinity)
        case .advertising:
            advertisingView
        case .paired(let client):
            pairedView(client)
        case .error(let message):
            errorView(message)
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.permissions.coreReady {
                Text("Ready to accept a connection.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Button {
                    session.start()
                } label: {
                    Text("Start Listening").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Label("Finish setup to start the host", systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Button("Finish Setup…") { openSetup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var advertisingView: some View {
        VStack(spacing: 10) {
            Label("Ready for your devices", systemImage: "checkmark.icloud.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Open Remote Desktop on an iPhone or iPad signed into the same Apple Account. Pairing happens automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Stop") { session.stop() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }

    private func pairedView(_ client: String) -> some View {
        VStack(spacing: 10) {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(client)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { session.stop() } label: {
                Text("End session").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            HStack {
                Button("Retry") { session.start() }
                    .buttonStyle(.borderedProminent)
                Button("Open Setup Guide") { openSetup() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var statusLine: String {
        switch session.state {
        case .idle:        return "Ready"
        case .starting:    return "Starting…"
        case .advertising: return "Ready for your devices"
        case .paired:      return "Connected"
        case .error:       return "Error"
        }
    }
}

private struct ComputerUseHostSection: View {
    @ObservedObject var manager: HostComputerUseManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .foregroundStyle(statusColor)
                    .frame(width: 22)
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                statusIcon
            }

            if case .installing(let detail, let fraction) = manager.modelState {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction {
                        ProgressView(value: fraction)
                            .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let supportingText {
                Text(supportingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch manager.capability.state {
        case .ready: return "AI Computer Use Ready"
        case .busy: return "AI Computer Use Working"
        case .paused:
            if case .awaitingApproval = manager.activity {
                return "AI Approval Required"
            }
            return "AI Computer Use Paused"
        case .installing: return "Setting Up AI Computer Use"
        case .setupRequired: return "AI Computer Use Setup Needed"
        case .unavailable: return "AI Computer Use Unavailable"
        }
    }

    private var supportingText: String? {
        switch manager.capability.state {
        case .ready:
            return nil
        case .busy, .paused:
            return manager.capability.detail
        case .installing:
            return nil
        case .setupRequired:
            if case .error(let message) = manager.modelState {
                return message
            }
            return "Finish setup from your iPhone or iPad."
        case .unavailable:
            return manager.capability.detail
        }
    }

    private var statusColor: Color {
        switch manager.capability.state {
        case .ready: return .green
        case .busy, .installing: return .indigo
        case .paused: return .orange
        case .setupRequired:
            if case .error = manager.modelState { return .red }
            return .secondary
        case .unavailable: return .secondary
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch manager.capability.state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .busy:
            ProgressView().controlSize(.small)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .installing:
            ProgressView().controlSize(.small)
        case .setupRequired:
            if case .error = manager.modelState {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
        case .unavailable:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }

}
