import AppKit
import Combine
import SwiftUI

enum HostSetupStep: Equatable {
    case screenRecording
    case accessibility
    case optionalAudio
    case ready

    static func current(
        permissions: HostSession.Permissions,
        optionalAudioSkipped: Bool
    ) -> HostSetupStep {
        if !permissions.screenRecording {
            return .screenRecording
        }
        if !permissions.accessibility {
            return .accessibility
        }
        if HostConfig.enableSystemAudio,
           !permissions.audioEnabled,
           !optionalAudioSkipped {
            return .optionalAudio
        }
        return .ready
    }

    var progress: Double {
        switch self {
        case .screenRecording: return 1.0 / 3.0
        case .accessibility: return 2.0 / 3.0
        case .optionalAudio: return 1.0
        case .ready: return 1.0
        }
    }

    var progressLabel: String {
        switch self {
        case .screenRecording: return "Step 1 of 3"
        case .accessibility: return "Step 2 of 3"
        case .optionalAudio: return "Optional audio"
        case .ready: return "Setup complete"
        }
    }
}

enum HostSetupPreferences {
    static let completedKey = "CompletedFirstRunSetup"
    static let resumeAfterRestartKey = "ResumeSetupAfterRestart"

    static func shouldPresent(
        permissions: HostSession.Permissions,
        defaults: UserDefaults = .standard
    ) -> Bool {
        // TCC is authoritative. Completion preferences exist only to migrate
        // older builds and resume a still-incomplete permission flow; neither
        // may force onboarding after both required grants are already live.
        !permissions.coreReady
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
        defaults.removeObject(forKey: resumeAfterRestartKey)
    }

    static func markRestartRequested(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: resumeAfterRestartKey)
    }

    /// Treat live TCC state as the source of truth at launch. Builds that
    /// predate this setup guide have no completion preference, and a host can
    /// also retain the restart marker after macOS has already applied every
    /// required grant. In both cases reopening onboarding is redundant.
    static func reconcileExistingGrants(
        permissions: HostSession.Permissions,
        defaults: UserDefaults = .standard
    ) {
        guard permissions.coreReady else { return }
        markCompleted(defaults: defaults)
    }
}

/// A real window for the deeper first-run workflow. The menu-bar popover stays
/// concise while this view explains one macOS permission at a time.
struct HostSetupView: View {
    @ObservedObject var session: HostSession
    let onFinish: () -> Void
    let onRestart: () -> Void
    let onCorePermissionsReady: () -> Void

    @State private var optionalAudioSkipped = false
    @State private var restartHelpForStep: HostSetupStep?

    private var step: HostSetupStep {
        HostSetupStep.current(
            permissions: session.permissions,
            optionalAudioSkipped: optionalAudioSkipped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(step.progressLabel)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("Screen and control are required. Audio is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: step.progress)
                    .accessibilityLabel(step.progressLabel)
            }

            Divider()

            Group {
                switch step {
                case .screenRecording:
                    screenRecordingStep
                case .accessibility:
                    accessibilityStep
                case .optionalAudio:
                    optionalAudioStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(minWidth: 540, idealWidth: 560, minHeight: 470, idealHeight: 500)
        .onAppear { session.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                session.refreshPermissions()
            }
        .onChange(of: session.permissions.coreReady) { _, coreReady in
            if coreReady {
                onCorePermissionsReady()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppLogo(size: 42)
                .padding(9)
                .logoGlassPlate(size: 60, cornerRadius: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Remote Desktop Host")
                    .font(.title2.weight(.semibold))
                Text("We’ll guide you through each setting. Nothing technical is required.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var screenRecordingStep: some View {
        permissionStep(
            permission: .screenRecording,
            icon: "rectangle.inset.filled",
            title: "Allow Screen Recording",
            explanation: "This lets your iPhone or iPad see the Mac screen. The host only shares it while you are connected.",
            instructions: [
                "Request screen recording access.",
                "Follow the macOS prompt to allow Remote Desktop Host.",
                "Return here. We’ll check automatically.",
            ],
            primaryTitle: "Request Screen Recording…",
            primaryAction: {
                restartHelpForStep = .screenRecording
                session.requestCorePermission(.screenRecording)
            })
    }

    private var accessibilityStep: some View {
        permissionStep(
            permission: .accessibility,
            icon: "cursorarrow.motionlines",
            title: "Allow Accessibility",
            explanation: "This lets the host perform the clicks and typing you send. It does not read passwords or keystrokes from other apps.",
            instructions: [
                "Request accessibility access.",
                "Follow the macOS prompt to allow Remote Desktop Host.",
                "Return here. We’ll check automatically.",
            ],
            primaryTitle: "Request Accessibility…",
            primaryAction: {
                restartHelpForStep = .accessibility
                session.requestCorePermission(.accessibility)
            })
    }

    private var optionalAudioStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupTitle(
                icon: "speaker.wave.2.fill",
                title: "Hear Mac Audio (Optional)",
                explanation: "Remote viewing and control are already ready, and AI setup can continue without audio. Enable this only if you also want sound from the Mac on your iPhone or iPad.")

            Label("The host never sends microphone audio. The WebRTC audio bridge uses macOS’s microphone permission to forward system sound.", systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = session.optionalAudioError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Enable Mac Audio…") {
                    session.requestOptionalAudioPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Not Now") {
                    optionalAudioSkipped = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                Button("Open Microphone Settings") {
                    session.openSystemSettings(for: .microphone)
                }
                .buttonStyle(.bordered)
                Button("Check Again") {
                    session.refreshPermissions()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupTitle(
                icon: "checkmark.circle.fill",
                title: "Remote Control Is Ready",
                explanation: readyExplanation)

            VStack(alignment: .leading, spacing: 10) {
                setupSummaryRow("Screen Recording", enabled: session.permissions.screenRecording)
                setupSummaryRow("Accessibility", enabled: session.permissions.accessibility)
                setupSummaryRow(
                    session.permissions.audioEnabled ? "Mac audio" : "Mac audio (optional, off)",
                    enabled: session.permissions.audioEnabled,
                    optional: !session.permissions.audioEnabled)
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("To use AI Computer Use, tap Set up AI beside this Mac on your iPhone or iPad. The Mac will install verified local tools and the visual fallback model, with live progress shown on your mobile device. No API key or paid AI service is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Finish Setup") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!session.permissions.coreReady)
                .accessibilityHint("Closes setup and starts listening for your iPhone or iPad")
        }
    }

    private var readyExplanation: String {
        if HeadlessHostSettings.startListeningOnLaunch {
            return "Remote Desktop Host can now show the screen and accept your controls. It will start listening automatically."
        }
        return "Remote Desktop Host can now show the screen and accept your controls. Choose Start listening from the menu bar when you’re ready."
    }

    private func permissionStep(
        permission: PermissionKind,
        icon: String,
        title: String,
        explanation: String,
        instructions: [String],
        primaryTitle: String,
        primaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            setupTitle(icon: icon, title: title, explanation: explanation)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor, in: Circle())
                        Text(instruction)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Open Settings") {
                    session.openSystemSettings(for: permission)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Check Again") {
                    session.refreshPermissions()
                }
                .buttonStyle(.link)
            }

            if restartHelpForStep == step {
                HStack(alignment: .center, spacing: 10) {
                    Label("Still shown as required after turning it on? Restart the host once so macOS can apply the change.", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Restart Host") {
                        HostSetupPreferences.markRestartRequested()
                        onRestart()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func setupTitle(icon: String, title: String, explanation: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupSummaryRow(
        _ title: String,
        enabled: Bool,
        optional: Bool = false
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: enabled ? "checkmark.circle.fill" : (optional ? "minus.circle" : "xmark.circle.fill"))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        }
    }
}
