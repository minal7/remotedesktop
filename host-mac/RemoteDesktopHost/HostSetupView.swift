import AppKit
import Combine
import SwiftUI

enum HostSetupStep: Equatable {
    case screenRecording
    case accessibility
    case ready

    static func current(
        permissions: HostSession.Permissions
    ) -> HostSetupStep {
        if !permissions.screenRecording {
            return .screenRecording
        }
        if !permissions.accessibility {
            return .accessibility
        }
        return .ready
    }

    var progress: Double {
        switch self {
        case .screenRecording: return 0
        case .accessibility: return 0.5
        case .ready: return 1.0
        }
    }

    var progressLabel: String {
        switch self {
        case .screenRecording: return "Step 1 of 2"
        case .accessibility: return "Step 2 of 2"
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        HostPermissionHistory.recordSuccessfulGrants(
            version: version,
            designatedRequirement: HostPermissionHistory.currentRequirement,
            defaults: defaults)
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

    @State private var permissionFlow = HostPermissionSetupState()
    @State private var now = ProcessInfo.processInfo.systemUptime
    @State private var repairingPermission: PermissionKind?
    @State private var failedRepair: PermissionKind?

    private var step: HostSetupStep {
        HostSetupStep.current(permissions: session.permissions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(step.progressLabel)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("Screen sharing and remote control")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: step.progress)
                    .accessibilityLabel(step.progressLabel)
            }

            Divider()

            HStack(spacing: 18) {
                setupSummaryRow("Screen Recording", enabled: session.permissions.screenRecording)
                setupSummaryRow("Accessibility", enabled: session.permissions.accessibility)
            }

            Group {
                switch step {
                case .screenRecording:
                    screenRecordingStep
                case .accessibility:
                    accessibilityStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(minWidth: 540, idealWidth: 560, minHeight: 470, idealHeight: 500)
        .onAppear {
            _ = permissionFlow.screenGrantRequiresRestart(session.permissions.screenRecording)
            refreshPermissionsAndAdvance()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard !permissionFlow.didRequestRestart, repairingPermission == nil else { return }
            refreshPermissionsAndAdvance()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshPermissionsAndAdvance()
            }
    }

    private func refreshPermissionsAndAdvance() {
        guard !permissionFlow.didRequestRestart, repairingPermission == nil else { return }
        now = ProcessInfo.processInfo.systemUptime
        session.refreshPermissions()
        if permissionFlow.screenGrantRequiresRestart(session.permissions.screenRecording) {
            HostSetupPreferences.markRestartRequested()
            onRestart()
        } else if session.permissions.coreReady {
            onCorePermissionsReady()
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
            explanation: "Screen Recording lets your iPhone or iPad see this Mac’s screen.")
    }

    private var accessibilityStep: some View {
        permissionStep(
            permission: .accessibility,
            icon: "cursorarrow.motionlines",
            title: "Allow Accessibility",
            explanation: "Accessibility lets your iPhone or iPad control the mouse and keyboard.")
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

            Text("Computer use (Beta) runs two local models on this Mac: Fara 1.5 9B and LFM3 1.7B. Start setup beside this Mac in the Remote Desktop app on your iPhone or iPad.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(computerUseSetupDetails)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Text("If a system overlay blocks a task, close it on the Mac and tap Resume.")
                    .foregroundStyle(.secondary)
                Link("see Support", destination: URL(string: "https://github.com/minal7/remotedesktop/blob/main/docs/support.html")!)
            }
            .font(.caption)

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

    private var computerUseSetupDetails: String {
        let manifest = ComputerUseArtifactManifest.current
        let downloadBytes = manifest.modelArtifacts.reduce(Int64.zero) { $0 + $1.byteCount }
        let requiredFreeBytes = downloadBytes + ComputerUseInstaller.installationHeadroomBytes
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloadSize = formatter.string(fromByteCount: downloadBytes)
        let requiredFreeSpace = formatter.string(fromByteCount: requiredFreeBytes)
        let requiredMemoryGB = (manifest.minimumMemoryBytes + 1_073_741_823) / 1_073_741_824
        return "Download: \(downloadSize). Keep \(requiredFreeSpace) free before setup. Requires at least \(requiredMemoryGB) GB of memory; setup reports the available memory if this Mac is below the minimum. Your iPhone or iPad shows progress; interrupted downloads resume, and SHA-256 is verified before activation."
    }

    private func permissionStep(
        permission: PermissionKind,
        icon: String,
        title: String,
        explanation: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            setupTitle(icon: icon, title: title, explanation: explanation)
            Text("In Settings, turn on Remote Desktop Host. We’ll check automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Allow") { allow(permission) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(repairingPermission != nil)

            if permissionFlow.offersFix(
                for: permission,
                granted: permissionGranted(permission),
                previouslyGranted: HostPermissionHistory.previouslyGranted(),
                now: now) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Already switched on? Click Fix to refresh it.")
                        .font(.callout)
                    Button(repairingPermission == permission ? "Fixing…" : "Fix") {
                        fix(permission)
                    }
                    .buttonStyle(.bordered)
                    .disabled(repairingPermission != nil)
                    if failedRepair == permission {
                        Label("Select Remote Desktop Host in Settings, click −, then click Allow again.", systemImage: "minus.circle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func permissionGranted(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .screenRecording: return session.permissions.screenRecording
        case .accessibility: return session.permissions.accessibility
        case .microphone: return session.permissions.microphone
        }
    }

    private func allow(_ permission: PermissionKind) {
        session.refreshPermissions()
        guard !permissionGranted(permission), permission != .microphone else {
            refreshPermissionsAndAdvance()
            return
        }
        session.requestCorePermission(permission)
        session.openSystemSettings(for: permission)
        permissionFlow.openedSettings(for: permission, now: ProcessInfo.processInfo.systemUptime)
        refreshPermissionsAndAdvance()
    }

    private func fix(_ permission: PermissionKind) {
        guard repairingPermission == nil else { return }
        repairingPermission = permission
        failedRepair = nil
        Task { @MainActor in
            session.refreshPermissions()
            do {
                try await HostPermissionRepair.fix(
                    permission,
                    isGranted: { permissionGranted(permission) },
                    reset: { try await HostPermissionRepair.resetOwnGrant(for: $0) },
                    request: { session.requestCorePermission($0) },
                    openSettings: { session.openSystemSettings(for: $0) })
            } catch {
                failedRepair = permission
            }
            repairingPermission = nil
            refreshPermissionsAndAdvance()
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
