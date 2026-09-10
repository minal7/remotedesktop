import XCTest
import CoreVideo
import LiveKitWebRTC
@testable import RemoteDesktop

@MainActor
final class RemoteVideoRendererTests: XCTestCase {
    func test_rendererBindingRetainsPreparationAndDetachesTheExactPreviousTarget() {
        let binding = RemoteVideoRendererBinding(), renderer = RecordingVideoRenderer()
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
        let old = RecordingVideoRenderer(), current = RecordingVideoRenderer()
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
        let old = RecordingVideoRenderer(), replacement = RecordingVideoRenderer()
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
    var attachments: [RTCVideoRenderer] = []
    var detachments: [RTCVideoRenderer] = []
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?
    func attachVideoRenderer(_ renderer: RTCVideoRenderer) { attachments.append(renderer); onAttach?() }
    func detachVideoRenderer(_ renderer: RTCVideoRenderer) { detachments.append(renderer); onDetach?() }
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
