import Foundation
import LiveKitWebRTC

/// A reusable surface owner, distinct from a native sink with cached frames.
/// Each call must create a new sink; a retired sink must never be reused.
@MainActor
protocol RemoteVideoSurface: AnyObject {
    func makeVideoAttachment(display: DisplayInfo) -> RemoteVideoSurfaceAttachment?
}

@MainActor
final class RemoteVideoSurfaceAttachment {
    let renderer: RTCVideoRenderer
    let presentation: RemoteVideoSurfacePresentation?
    private var cleanup: (@MainActor () -> Void)?

    init(renderer: RTCVideoRenderer, presentation: RemoteVideoSurfacePresentation? = nil, cleanup: @escaping @MainActor () -> Void) {
        self.renderer = renderer
        self.presentation = presentation
        self.cleanup = cleanup
    }

    /// Call after closing/joining the subscription's synchronous sink gate.
    /// Removes only this attachment's visible surface, at most once.
    func retire() {
        let cleanup = self.cleanup
        self.cleanup = nil
        presentation?.retire()
        cleanup?()
    }
}

/// Reserves one native surface before creation and owns its exact removal.
/// Factories return a new sink. Removal must be idempotent and affect only its
/// argument: UIKit callbacks may retire an installation before it returns.
@MainActor
final class RemoteVideoSurfaceLifetime<Renderer: RTCVideoRenderer> {
    private struct Reservation {
        let id: UUID
        let display: DisplayInfo
    }
    private let make: @MainActor () -> Renderer?
    private let install: @MainActor (Renderer, DisplayInfo) -> Void
    private let remove: @MainActor (Renderer) -> Void
    private let presentation: @MainActor (Renderer) -> RemoteVideoSurfacePresentation?
    private var reservation: Reservation?
    private(set) var renderer: Renderer?
    var display: DisplayInfo? { reservation?.display }

    init(make: @escaping @MainActor () -> Renderer?, install: @escaping @MainActor (Renderer, DisplayInfo) -> Void,
         remove: @escaping @MainActor (Renderer) -> Void,
         presentation: @escaping @MainActor (Renderer) -> RemoteVideoSurfacePresentation? = { _ in nil }) {
        self.make = make
        self.install = install
        self.remove = remove
        self.presentation = presentation
    }

    func prepare(display: DisplayInfo) -> RemoteVideoSurfaceAttachment? {
        guard reservation == nil else { return nil }
        let id = UUID()
        reservation = Reservation(id: id, display: display)
        guard let created = make() else {
            if reservation?.id == id { reservation = nil }
            return nil
        }
        guard reservation?.id == id else { remove(created); return nil }
        renderer = created
        install(created, display)
        guard reservation?.id == id, renderer === created else {
            // An installation may finish after reentrant retirement removed
            // it. Remove that exact old surface again; never the successor.
            remove(created)
            return nil
        }
        let channel = presentation(created)
        guard reservation?.id == id, renderer === created else { remove(created); return nil }
        return RemoteVideoSurfaceAttachment(renderer: created, presentation: channel) { [weak self, remove] in
            if let self { self.retire(id: id) }
            else { remove(created) }
        }
    }

    func retire() {
        if let id = reservation?.id { retire(id: id) }
    }

    private func retire(id: UUID) {
        guard reservation?.id == id else { return }
        reservation = nil
        let previous = renderer
        renderer = nil
        if let previous { remove(previous) }
    }
}
