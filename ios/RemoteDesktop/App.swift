import SwiftUI
import UIKit

@main
struct RemoteDesktopApp: App {
    @StateObject private var session = SessionModel(
        enablePersonalMemory: MemoryFeatureConfiguration.memoryV1CandidateEnabled)
    @StateObject private var computerUseSetup = ComputerUseSetupCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(computerUseSetup)
                .background {
                    RemoteInputActivityCapture(session: session)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

/// Observe the actual containing scene. A SwiftUI phase update may arrive
/// after native input callbacks, and another scene must not reopen this one.
private struct RemoteInputActivityCapture: UIViewRepresentable {
    let session: SessionModel

    func makeUIView(context: Context) -> RemoteInputActivityView {
        let view = RemoteInputActivityView()
        view.bindSession(session)
        return view
    }

    func updateUIView(_ uiView: RemoteInputActivityView, context: Context) {
        uiView.bindSession(session)
    }

    static func dismantleUIView(_ uiView: RemoteInputActivityView, coordinator: ()) {
        uiView.stopObserving()
    }
}

private final class RemoteInputActivityView: UIView {
    private weak var session: SessionModel?
    private weak var observedScene: UIWindowScene?
    private var sceneLease: RemoteInputSceneLease?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    func bindSession(_ session: SessionModel) {
        guard !stopped else { return }
        if self.session !== session {
            retireScene()
            self.session = session
        }
        bindWindowScene()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        bindWindowScene()
    }

    private func bindWindowScene() {
        guard !stopped else { return }
        guard let scene = window?.windowScene, let session else {
            retireScene()
            return
        }
        guard observedScene !== scene else { return }
        retireScene()
        observedScene = scene
        let lease = session.bindRemoteInputScene(isActive: false)
        sceneLease = lease
        let center = NotificationCenter.default
        for name in [UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification,
                     UIScene.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: scene, queue: .main) {
                [weak session] _ in
                MainActor.assumeIsolated { session?.setRemoteInputSceneActive(false, lease: lease) }
            })
        }
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) {
            [weak session, weak scene] _ in
            MainActor.assumeIsolated {
                guard let scene else { return }
                session?.setRemoteInputSceneActive(scene.activationState == .foregroundActive, lease: lease)
            }
        })
        // Sample only a new binding. Repeated view updates cannot undo a
        // will-deactivate edge while UIKit still reports the preceding state.
        session.setApplicationInputActive(UIApplication.shared.applicationState == .active)
        session.setRemoteInputSceneActive(scene.activationState == .foregroundActive, lease: lease)
    }

    private func retireScene() {
        let lease = sceneLease
        sceneLease = nil
        observedScene = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let lease { session?.endRemoteInputScene(lease) }
    }

    func stopObserving() {
        stopped = true
        retireScene()
        session = nil
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
