import AppKit
import SwiftUI

/// Popover content for the menu bar status item.
struct MenuContent: View {
    @EnvironmentObject private var session: HostSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            Divider()
            permissionsFooter
            Divider()
            quitRow
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { session.refreshPermissions() }
    }

    private var quitRow: some View {
        HStack {
            Spacer()
            Button("Quit Remote Desktop Host") {
                session.stop()
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Desktop Host").font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        case .advertising(let code):
            advertisingView(code)
        case .paired(let client):
            pairedView(client)
        case .error(let message):
            errorView(message)
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to accept a pairing.")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button {
                session.start()
            } label: {
                Text("Start listening").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!session.permissions.ok)
        }
    }

    private func advertisingView(_ code: String) -> some View {
        VStack(spacing: 10) {
            Text("Enter this code on your iPad or iPhone:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(6)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
                Button("Open System Settings") { session.openSystemSettingsForNextMissingPermission() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var permissionsFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                HostConfig.enableSystemAudio ? "Screen & System Audio Recording" : "Screen Recording",
                granted: session.permissions.screenRecording)
            permissionRow("Accessibility",    granted: session.permissions.accessibility)
            if HostConfig.enableSystemAudio {
                permissionRow("Microphone (WebRTC audio bridge)", granted: session.permissions.microphone)
            }
            if !session.permissions.ok {
                HStack(spacing: 8) {
                    Button("Grant…") { session.grantNextPermission() }
                        .buttonStyle(.link)
                    Button("Open System Settings") { session.openSystemSettingsForNextMissingPermission() }
                        .buttonStyle(.link)
                    Button("Check again") { session.refreshPermissions() }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption)
    }

    private func permissionRow(_ label: String, granted: Bool) -> some View {
        Label {
            Text("\(label): \(granted ? "granted" : "required")")
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
        }
    }

    private var statusLine: String {
        switch session.state {
        case .idle:        return "Ready"
        case .starting:    return "Starting…"
        case .advertising: return "Waiting for pairing"
        case .paired:      return "Connected"
        case .error:       return "Error"
        }
    }
}
