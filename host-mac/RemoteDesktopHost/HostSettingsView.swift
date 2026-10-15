import AppKit
import SwiftUI

/// Secondary details for setup, local AI components, and legal notices. The
/// menu-bar popover intentionally keeps these operational details out of the
/// everyday readiness surface.
struct HostSettingsView: View {
    @ObservedObject var session: HostSession
    let openSetup: () -> Void
    @State private var historyMessage: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            computerUseTab
                .tabItem { Label("Computer use (Beta)", systemImage: "sparkles") }

            licensesTab
                .tabItem { Label("Licenses", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 410)
    }

    private var generalTab: some View {
        settingsScroll {
            settingsHeader(
                title: "Remote Desktop Host",
                subtitle: "Connection and permission settings for this Mac.")

            GroupBox("Host Status") {
                VStack(spacing: 12) {
                    settingsRow(
                        title: "Remote access",
                        detail: session.permissions.coreReady ? "Ready" : "Setup required",
                        enabled: session.permissions.coreReady)
                    Divider()
                    settingsRow(
                        title: "Screen Recording",
                        detail: session.permissions.screenRecording ? "Allowed" : "Required",
                        enabled: session.permissions.screenRecording)
                    settingsRow(
                        title: "Accessibility",
                        detail: session.permissions.accessibility ? "Allowed" : "Required",
                        enabled: session.permissions.accessibility)
                    if HostConfig.enableSystemAudio {
                        settingsRow(
                            title: "Mac audio",
                            detail: session.permissions.audioEnabled ? "On" : "Optional",
                            enabled: session.permissions.audioEnabled,
                            optional: !session.permissions.audioEnabled)
                    }
                }
                .padding(6)
            }

            HStack {
                Text("macOS manages these permissions in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.permissions.coreReady {
                    Button("Setup & Permissions…") { openSetup() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Finish Setup…") { openSetup() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var computerUseTab: some View {
        settingsScroll {
            settingsHeader(
                title: "Computer use (Beta)",
                subtitle: computerUseStatusDetail)

            GroupBox("Local Computer Use") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Fara 1.5 4B", systemImage: "globe")
                            .font(.headline)
                        Spacer()
                        Text(modelStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(modelStatusColor)
                    }
                    Text("Uses the task window or browser tab to work locally. Requires a Mac with at least 16 GB of memory.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Runs on this Mac with no third-party AI account or API key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Model Folder…") {
                            session.computerUse.revealModelFolder()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }

            GroupBox("Task History") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Task screenshots and actions stay on this Mac. Episodes older than seven days are removed when a new task recording starts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Delete task history", role: .destructive) {
                        do { try TrajectoryRecorder.deleteHistory(); historyMessage = "Local task history deleted." }
                        catch { historyMessage = "Could not delete local task history: \(error.localizedDescription)" }
                    }
                    .disabled(session.computerUse.activity != .idle || session.computerUse.hasRetainedAgentTask)
                    if let historyMessage { Text(historyMessage).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(6)
            }

            Text("Open-source license documents are collected in the Licenses tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var licensesTab: some View {
        settingsScroll {
            settingsHeader(
                title: "Open-Source Licenses",
                subtitle: "License documents and attribution for bundled Computer Use components.")

            GroupBox {
                VStack(spacing: 0) {
                    licenseRow(
                        name: "Fara 1.5 4B",
                        license: "MIT License",
                        destination: ComputerUseArtifactManifest.displayedFaraLicenseURL)
                    Divider().padding(.vertical, 10)
                    licenseRow(
                        name: "Qwen 3.5 base model license",
                        license: "Apache License 2.0",
                        destination: ComputerUseArtifactManifest.bundledLegalDocumentURL(
                            ComputerUseArtifactManifest.qwen35License)
                            ?? ComputerUseArtifactManifest.qwen35LicenseURL)
                    Divider().padding(.vertical, 10)
                    licenseRow(
                        name: "llama.cpp",
                        license: "MIT License",
                        destination: ComputerUseArtifactManifest.bundledLegalDocumentURL(
                            ComputerUseArtifactManifest.llamaCPPLicense)
                            ?? ComputerUseArtifactManifest.llamaCPPLicenseURL)
                }
                .padding(6)
            }

            if let noticeURL = Bundle.main.url(forResource: "NOTICE", withExtension: "txt") {
                Link(destination: noticeURL) {
                    Label("View attribution notice", systemImage: "doc.plaintext")
                }
            }
        }
    }

    private func settingsScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsRow(
        title: String,
        detail: String,
        enabled: Bool,
        optional: Bool = false
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: enabled ? "checkmark.circle.fill" : (optional ? "minus.circle" : "exclamationmark.circle.fill"))
                    .foregroundStyle(enabled ? Color.green : (optional ? Color.secondary : Color.orange))
            }
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func licenseRow(name: String, license: String, destination: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                Text(license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link("View License", destination: destination)
        }
    }

    private func bundledDocument(named name: String, fallback: URL) -> URL {
        Bundle.main.url(forResource: name, withExtension: "txt") ?? fallback
    }

    private var computerUseStatusDetail: String {
        switch session.computerUse.capability.state {
        case .ready: return session.computerUse.capability.detail
        case .busy: return "Computer use (Beta) is working on a task."
        case .paused: return session.computerUse.capability.detail
        case .installing: return session.computerUse.capability.detail
        case .setupRequired: return "Finish setup from your iPhone or iPad."
        case .unavailable: return session.computerUse.capability.detail
        }
    }

    private var modelStatus: String {
        switch session.computerUse.modelState {
        case .downloadRequired: return "Not installed"
        case .packageFound: return "Loading"
        case .installing: return "Installing"
        case .ready: return "Ready"
        case .error: return "Needs attention"
        }
    }

    private var modelStatusColor: Color {
        switch session.computerUse.modelState {
        case .ready: return .green
        case .installing, .packageFound: return .indigo
        case .error: return .red
        case .downloadRequired: return .secondary
        }
    }
}
