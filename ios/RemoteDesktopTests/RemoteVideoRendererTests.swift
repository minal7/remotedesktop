import XCTest
import CoreVideo
import LiveKitWebRTC
@testable import RemoteDesktop

@MainActor
final class RemoteVideoRendererTests: XCTestCase {
    func test_rendererBindingRetainsPreparationAndDetachesTheExactPreviousTarget() {
        let binding = RemoteVideoRendererBinding(), renderer = RecordingVideoSurface()
        let first = RecordingVideoTarget(), second = RecordingVideoTarget()
        binding.attach(renderer)
        XCTAssertTrue(first.attachments.isEmpty)
        binding.bind(first); binding.bind(first); binding.attach(renderer)
        XCTAssertEqual(first.attachments.count, 1)
        binding.bind(second)
        XCTAssertTrue(first.detachments.first === renderer)
        XCTAssertTrue(second.attachments.first === renderer)
        binding.bind(nil)
        XCTAssertTrue(second.detachments.first === renderer)
        binding.bind(first)
        XCTAssertEqual(first.attachments.count, 2, "The desired sink survives a transport gap")
        binding.detach(renderer)
        XCTAssertEqual(first.detachments.count, 2)
    }

    func test_rendererBindingIgnoresStaleSinkCleanupAndReplacesOnlyOnce() {
        let binding = RemoteVideoRendererBinding(), target = RecordingVideoTarget()
        let old = RecordingVideoSurface(), current = RecordingVideoSurface()
        binding.bind(target); binding.attach(old); binding.attach(current)
        binding.detach(old); binding.attach(current)
        XCTAssertEqual(target.attachments.count, 2)
        XCTAssertEqual(target.detachments.count, 1)
        XCTAssertTrue(target.detachments.first === old)
        binding.detach(current); binding.detach(current)
        XCTAssertEqual(target.detachments.count, 2)
        XCTAssertTrue(target.detachments.last === current)
    }

    func test_rendererBindingReconcilesChangesDuringExternalAttachAndDetach() {
        let binding = RemoteVideoRendererBinding()
        let first = RecordingVideoTarget(), skipped = RecordingVideoTarget(), latest = RecordingVideoTarget()
        let old = RecordingVideoSurface(), replacement = RecordingVideoSurface()
        defer { first.onDetach = nil; latest.onAttach = nil; binding.bind(nil) }
        binding.attach(old); binding.bind(first)
        first.onDetach = { binding.bind(latest); binding.attach(replacement) }
        binding.bind(skipped)
        XCTAssertTrue(skipped.attachments.isEmpty, "Cleanup replaced the desired target before installation")
        XCTAssertTrue(latest.attachments.first === replacement)
        latest.onDetach = nil
        latest.onAttach = { binding.detach(old) }
        binding.attach(old)
        XCTAssertEqual(latest.attachments.count, 2)
        XCTAssertTrue(latest.detachments.last === old, "An attachment revoked during its own callback is removed")
    }

    func test_rendererSubscriptionReportsOnlyAfterForwardingAValidFrame() throws {
        let renderer = RecordingVideoRenderer(), trace = RendererEventTrace()
        renderer.onRender = { trace.append("sink") }
        let subscription = RemoteVideoRenderSubscription(renderer: renderer) { trace.append("ready") }
        subscription.renderFrame(nil)
        for size in [CGSize.zero, CGSize(width: -1, height: 2), CGSize(width: CGFloat.nan, height: 2)] {
            subscription.setSize(size)
        }
        XCTAssertTrue(renderer.sizes.isEmpty); XCTAssertTrue(trace.events.isEmpty)
        subscription.setSize(CGSize(width: 2, height: 2))
        XCTAssertEqual(renderer.sizes, [CGSize(width: 2, height: 2)])
        XCTAssertTrue(trace.events.isEmpty, "A size callback is not a decoded frame")
        let frame = try makeFrame()
        subscription.renderFrame(frame); subscription.renderFrame(frame)
        XCTAssertEqual(trace.events, ["sink", "ready", "sink"])
        XCTAssertTrue(renderer.frames.first === frame)
    }

    func test_rendererSubscriptionRetirementRejectsOldFramesAndSizeCallbacks() throws {
        let renderer = RecordingVideoRenderer(), trace = RendererEventTrace(), frame = try makeFrame()
        let old = RemoteVideoRenderSubscription(renderer: renderer) { trace.append("old") }
        old.retire(); old.retire()
        let current = RemoteVideoRenderSubscription(renderer: renderer) { trace.append("current") }
        old.setSize(CGSize(width: 800, height: 600)); old.renderFrame(frame)
        XCTAssertTrue(renderer.sizes.isEmpty); XCTAssertTrue(renderer.frames.isEmpty)
        current.setSize(CGSize(width: 2, height: 2)); current.renderFrame(frame)
        old.setSize(CGSize(width: 900, height: 700)); old.renderFrame(frame)
        XCTAssertEqual(renderer.sizes, [CGSize(width: 2, height: 2)])
        XCTAssertEqual(renderer.frames.count, 1); XCTAssertEqual(trace.events, ["current"])
    }

    func test_rendererSubscriptionRetiredInsideSinkDoesNotReportReadiness() throws {
        let renderer = RecordingVideoRenderer(), trace = RendererEventTrace()
        let subscription = RemoteVideoRenderSubscription(renderer: renderer) { trace.append("ready") }
        renderer.onRender = { [weak subscription] in subscription?.retire() }
        let frame = try makeFrame()
        subscription.renderFrame(frame); subscription.renderFrame(frame)
        XCTAssertEqual(renderer.frames.count, 1, "Retirement cannot retract an already admitted sink call")
        XCTAssertTrue(trace.events.isEmpty)
        renderer.onRender = nil
    }

    func test_surfaceRetirementIsolatesDeferredOldFramesAndSizesFromReplacement() throws {
        let queue = DeferredVideoQueue()
        var created: [DeferredVideoRenderer] = []
        let lifetime = RemoteVideoSurfaceLifetime<DeferredVideoRenderer>(make: {
            let renderer = DeferredVideoRenderer(queue: queue); created.append(renderer); return renderer
        }, install: { renderer, _ in renderer.visible = true }, remove: { $0.visible = false })
        let oldDisplay = DisplayInfo(w: 800, h: 600, scale: 1)
        let first = try XCTUnwrap(lifetime.prepare(display: oldDisplay))
        let oldFrame = try makeFrame(), newFrame = try makeFrame()
        first.renderer.setSize(CGSize(width: 800, height: 600)); first.renderer.renderFrame(oldFrame)
        first.retire()
        let currentDisplay = DisplayInfo(w: 900, h: 700, scale: 2, fullDisplaySurface: true)
        let next = try XCTUnwrap(lifetime.prepare(display: currentDisplay))
        next.renderer.setSize(CGSize(width: 900, height: 700)); next.renderer.renderFrame(newFrame)
        queue.finishNewestFirst()
        XCTAssertFalse(created[0].visible); XCTAssertTrue(created[1].visible)
        XCTAssertEqual(created[0].size, CGSize(width: 800, height: 600), "Admitted native work can still finish on the removed object")
        XCTAssertTrue(created[0].frame === oldFrame)
        XCTAssertEqual(created[1].size, CGSize(width: 900, height: 700)); XCTAssertTrue(created[1].frame === newFrame)
        XCTAssertTrue(lifetime.renderer === created[1]); XCTAssertEqual(lifetime.display, currentDisplay)
        first.retire()
        XCTAssertTrue(created[1].visible, "A stale handle must not remove the successor")
        next.retire(); XCTAssertFalse(created[1].visible); XCTAssertNil(lifetime.display)
    }

    func test_surfaceLifetimeCreatesANewSinkEvenForIdenticalDisplayMetadata() throws {
        let display = DisplayInfo(w: 800, h: 600, scale: 1)
        var creations = 0, removals = 0
        let lifetime = RemoteVideoSurfaceLifetime<RecordingVideoRenderer>(make: {
            creations += 1; return RecordingVideoRenderer()
        }, install: { _, _ in }, remove: { _ in removals += 1 })
        let first = try XCTUnwrap(lifetime.prepare(display: display))
        XCTAssertNil(lifetime.prepare(display: display), "An active attachment must be retired explicitly")
        XCTAssertEqual(creations, 1)
        first.retire(); first.retire(); XCTAssertEqual(removals, 1)
        let second = try XCTUnwrap(lifetime.prepare(display: display))
        XCTAssertFalse(first.renderer === second.renderer)
        XCTAssertEqual(creations, 2)
        first.retire(); XCTAssertEqual(removals, 1)
        second.retire(); XCTAssertEqual(removals, 2)
    }

    func test_surfaceCreationFailureReleasesOnlyItsReservation() throws {
        var shouldFail = true, installs = 0, removals = 0
        let lifetime = RemoteVideoSurfaceLifetime<RecordingVideoRenderer>(make: {
            shouldFail ? nil : RecordingVideoRenderer()
        }, install: { _, _ in installs += 1 }, remove: { _ in removals += 1 })
        let display = DisplayInfo(w: 800, h: 600, scale: 1)
        XCTAssertNil(lifetime.prepare(display: display)); XCTAssertNil(lifetime.renderer); XCTAssertNil(lifetime.display)
        XCTAssertEqual(installs, 0); XCTAssertEqual(removals, 0)
        shouldFail = false
        let next = try XCTUnwrap(lifetime.prepare(display: display))
        XCTAssertEqual(installs, 1)
        next.retire(); XCTAssertEqual(removals, 1)
    }

    func test_surfaceRetirementDuringCreationRemovesTheUninstalledObject() throws {
        let display = DisplayInfo(w: 800, h: 600, scale: 1)
        var lifetime: RemoteVideoSurfaceLifetime<RecordingVideoRenderer>!
        var retireDuringCreation = true, installs = 0, removals = 0
        lifetime = RemoteVideoSurfaceLifetime(make: {
            let renderer = RecordingVideoRenderer()
            if retireDuringCreation { lifetime.retire() }
            return renderer
        }, install: { _, _ in installs += 1 }, remove: { _ in removals += 1 })
        defer { lifetime.retire(); lifetime = nil }
        XCTAssertNil(lifetime.prepare(display: display)); XCTAssertNil(lifetime.renderer)
        XCTAssertEqual(installs, 0); XCTAssertEqual(removals, 1)
        retireDuringCreation = false
        let next = try XCTUnwrap(lifetime.prepare(display: display))
        XCTAssertEqual(installs, 1)
        next.retire(); XCTAssertEqual(removals, 2)
    }

    func test_surfaceRetirementDuringInstallationCannotRemoveItsSuccessor() throws {
        let queue = DeferredVideoQueue(), display = DisplayInfo(w: 800, h: 600, scale: 1)
        var lifetime: RemoteVideoSurfaceLifetime<DeferredVideoRenderer>!
        var successor: RemoteVideoSurfaceAttachment?
        var created: [DeferredVideoRenderer] = []
        lifetime = RemoteVideoSurfaceLifetime(make: {
            let renderer = DeferredVideoRenderer(queue: queue); created.append(renderer); return renderer
        }, install: { renderer, display in
            if renderer === created.first {
                lifetime.retire()
                successor = lifetime.prepare(display: display)
            }
            // Model UIKit finishing an already admitted installation after
            // a reentrant retirement/replacement callback.
            renderer.visible = true
        }, remove: { $0.visible = false })
        defer { successor?.retire(); successor = nil; lifetime = nil }
        XCTAssertNil(lifetime.prepare(display: display))
        XCTAssertNotNil(successor); XCTAssertEqual(created.count, 2)
        XCTAssertFalse(created[0].visible); XCTAssertTrue(created[1].visible)
        XCTAssertTrue(lifetime.renderer === created[1])
    }

    func test_surfaceAttachmentCanRemoveItsExactSinkAfterContainerOwnerDeallocation() throws {
        var removed: [RTCVideoRenderer] = []
        var lifetime: RemoteVideoSurfaceLifetime<RecordingVideoRenderer>? = .init(
            make: { RecordingVideoRenderer() }, install: { _, _ in }, remove: { removed.append($0) })
        weak var weakLifetime = lifetime
        let attachment = try XCTUnwrap(lifetime?.prepare(display: DisplayInfo(w: 800, h: 600, scale: 1)))
        lifetime = nil
        XCTAssertNil(weakLifetime, "The attachment must not keep its container owner alive")
        attachment.retire(); attachment.retire()
        XCTAssertEqual(removed.count, 1); XCTAssertTrue(removed.first === attachment.renderer)
    }

    private func makeFrame() throws -> RTCVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixelBuffer)),
                             rotation: ._0, timeStampNs: 1)
    }
}

@MainActor
private final class RecordingVideoTarget: VideoRendererTarget {
    var attachments: [any RemoteVideoSurface] = []
    var detachments: [any RemoteVideoSurface] = []
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?
    func attachVideoRenderer(_ renderer: any RemoteVideoSurface) { attachments.append(renderer); onAttach?() }
    func detachVideoRenderer(_ renderer: any RemoteVideoSurface) { detachments.append(renderer); onDetach?() }
}

@MainActor
final class RecordingVideoSurface: RemoteVideoSurface {
    func makeVideoAttachment(display: DisplayInfo) -> RemoteVideoSurfaceAttachment? {
        RemoteVideoSurfaceAttachment(renderer: RecordingVideoRenderer(), cleanup: {})
    }
}

/// Serial fixture sink: no native track, Metal view or asynchronous decoder.
final class RecordingVideoRenderer: NSObject, RTCVideoRenderer {
    var sizes: [CGSize] = []
    var frames: [RTCVideoFrame] = []
    var onRender: (() -> Void)?
    func setSize(_ size: CGSize) { sizes.append(size) }
    func renderFrame(_ frame: RTCVideoFrame?) {
        if let frame { frames.append(frame); onRender?() }
    }
}

private final class RendererEventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(_ event: String) { lock.lock(); defer { lock.unlock() }; recorded.append(event) }
}

/// Controlled deferred operations; no native display or decoder queue runs.
private final class DeferredVideoQueue {
    var pending: [() -> Void] = []
    func finishNewestFirst() {
        let work = pending
        pending.removeAll()
        for item in work.reversed() { item() }
    }
}

private final class DeferredVideoRenderer: NSObject, RTCVideoRenderer {
    let queue: DeferredVideoQueue
    var visible = false
    var size: CGSize?
    var frame: RTCVideoFrame?
    init(queue: DeferredVideoQueue) { self.queue = queue }
    func setSize(_ size: CGSize) { queue.pending.append { [weak self] in self?.size = size } }
    func renderFrame(_ frame: RTCVideoFrame?) { queue.pending.append { [weak self] in self?.frame = frame } }
}
