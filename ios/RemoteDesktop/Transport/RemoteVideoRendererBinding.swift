import Foundation
import LiveKitWebRTC

/// The view keeps its desired surface owner while a connection is being replaced.
/// Cleanup belongs to the exact target on which that sink was installed.
@MainActor
final class RemoteVideoRendererBinding {
    private var target: (any VideoRendererTarget)?
    private var renderer: (any RemoteVideoSurface)?
    private var installed: (target: any VideoRendererTarget, renderer: any RemoteVideoSurface)?
    private var isReconciling = false

    func bind(_ target: (any VideoRendererTarget)?) {
        self.target = target
        reconcile()
    }

    func attach(_ renderer: any RemoteVideoSurface) {
        self.renderer = renderer
        reconcile()
    }

    func detach(_ renderer: any RemoteVideoSurface) {
        guard self.renderer === renderer else { return }
        self.renderer = nil
        reconcile()
    }

    private func reconcile() {
        // External attach/detach callbacks may synchronously change either
        // desired endpoint. Finish the admitted operation, then read the
        // latest desired pair instead of installing a captured predecessor.
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        while true {
            if let installed {
                if installed.target === target, installed.renderer === renderer { return }
                self.installed = nil
                installed.target.detachVideoRenderer(installed.renderer)
            } else {
                guard let target, let renderer else { return }
                installed = (target, renderer)
                target.attachVideoRenderer(renderer)
            }
        }
    }
}

/// Each native track registration gets a new subscription. Retirement joins
/// an admitted synchronous sink call and prevents later callbacks from entering
/// that sink. The sink must not synchronously wait for MainActor while called.
/// Its own deferred rendering/GPU work is outside this gate.
final class RemoteVideoRenderSubscription: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let renderer: RTCVideoRenderer
    private let onFirstForwardedFrame: @Sendable () -> Void
    private var active = true
    private var didReport = false

    init(renderer: RTCVideoRenderer, onFirstForwardedFrame: @escaping @Sendable () -> Void) {
        self.renderer = renderer
        self.onFirstForwardedFrame = onFirstForwardedFrame
    }

    func retire() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func setSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        renderer.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0,
              [0, 90, 180, 270].contains(frame.rotation.rawValue) else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        renderer.renderFrame(frame)
        let shouldReport = active && !didReport
        if shouldReport { didReport = true }
        lock.unlock()
        // Submission is not a GPU presentation acknowledgement or evidence
        // that these pixels were captured after the current input handshake.
        if shouldReport { onFirstForwardedFrame() }
    }
}
