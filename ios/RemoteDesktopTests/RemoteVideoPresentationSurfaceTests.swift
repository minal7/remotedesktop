import XCTest
import CoreGraphics
import CoreVideo
import LiveKitWebRTC
import QuartzCore
@testable import RemoteDesktop

@MainActor
final class RemoteVideoPresentationSurfaceTests: XCTestCase {
    /// One synthetic frame through the real mailbox, drawable acquirer and GPU.
    /// A rendering receipt is not a pixel comparison or hardware display proof.
    func test_optInSingleNativeSimulatorFrameReachesRenderedSurface() async throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["RUN_SINGLE_SIMULATOR_FRAME"] == "1" else {
            throw XCTSkip("Opt-in: one synthetic frame on an isolated Simulator")
        }
        let host = try RemoteKeyboardTestWindow()
        defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make())
        defer { surface.retire() }
        surface.view.frame = CGRect(x: 24, y: 96, width: 64, height: 64)
        let root = try XCTUnwrap(host.window.rootViewController?.view)
        root.addSubview(surface.view)
        root.layoutIfNeeded()
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        XCTAssertTrue(surface.view.window === host.window)

        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
            kCVPixelFormatType_32BGRA, attributes, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 { for x in 0..<64 {
                let offset = y * stride + x * 4
                base[offset] = 0; base[offset + 1] = 255
                base[offset + 2] = 0; base[offset + 3] = 255
            } }
        }
        let finished = expectation(description: "Single frame rendering finishes")
        var receipt: RemoteVideoSurfacePresentation.State?
        surface.presentation.observe { state in
            switch state {
            case .rendered, .presented, .failed:
                guard receipt == nil else { return }
                receipt = state; finished.fulfill()
            case .waiting, .retired: break
            }
        }
        let started = CACurrentMediaTime()
        surface.renderFrame(RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1))
        await fulfillment(of: [finished], timeout: 5)
        guard case .rendered(_, _, let time) = receipt else {
            return XCTFail("Expected actual Simulator GPU completion, received \(String(describing: receipt))")
        }
        XCTAssertGreaterThanOrEqual(time, started)
        XCTAssertLessThanOrEqual(time - started, 5)
        print("Single Simulator frame rendered in \(time - started)s; drawable=\(surface.view.metalLayer.drawableSize)")
        surface.retire()
        XCTAssertEqual(surface.presentation.state, .retired)
        #else
        throw XCTSkip("This experiment targets the Simulator rendering path")
        #endif
    }

    func test_renderedReadinessRetainsContextAndRejectsStaleOrRetiredGPUCompletion() {
        let old = UUID(), current = UUID(), frame = UUID()
        let channel = RemoteVideoSurfacePresentation(context: old)
        channel.begin(context: current)
        channel.render(context: old, frame: frame, time: 4)
        XCTAssertEqual(channel.state, .waiting(context: current))
        channel.render(context: current, frame: frame, time: 5)
        XCTAssertEqual(channel.state, .rendered(context: current, frame: frame, time: 5))
        channel.render(context: current, frame: UUID(), time: 4)
        XCTAssertEqual(channel.state, .rendered(context: current, frame: frame, time: 5))
        channel.retire()
        channel.render(context: current, frame: frame, time: 6)
        XCTAssertEqual(channel.state, .retired)
    }

    func test_frameMailboxKeepsOnlyTheLatestFrameAndOneWake() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), log = SurfaceWakeLog(), context = UUID()
        mailbox.setWakeHandler { log.append($0) }; mailbox.replaceContext(context)
        weak var first: SurfaceMailboxFrame?
        autoreleasepool {
            let frame = SurfaceMailboxFrame(1); first = frame; mailbox.offer(frame)
        }
        XCTAssertNotNil(first)
        mailbox.offer(SurfaceMailboxFrame(2)); mailbox.offer(SurfaceMailboxFrame(3))
        XCTAssertNil(first)
        XCTAssertEqual(log.values.count, 1)
        let wake = try XCTUnwrap(log.values.first)
        XCTAssertTrue(mailbox.accepts(wake))
        XCTAssertEqual(mailbox.takeLatest(context: context)?.frame.value, 3)
        XCTAssertFalse(mailbox.accepts(wake)); XCTAssertFalse(mailbox.hasPending(context: context))
        mailbox.offer(SurfaceMailboxFrame(4))
        XCTAssertEqual(log.values.count, 2)
        XCTAssertNotEqual(log.values.first, log.values.last)
    }

    func test_frameMailboxRetiresQueuedWakesAndOldRestoreAcrossContexts() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), log = SurfaceWakeLog(), old = UUID(), current = UUID()
        mailbox.replaceContext(old)
        mailbox.offer(SurfaceMailboxFrame(1))
        mailbox.setWakeHandler { log.append($0) }
        XCTAssertEqual(log.values.count, 1, "Installing the handler cannot lose an already waiting frame")
        let oldWake = try XCTUnwrap(log.values.first), oldEntry = try XCTUnwrap(mailbox.takeLatest(context: old))
        mailbox.replaceContext(current); mailbox.offer(SurfaceMailboxFrame(2)); mailbox.restoreUnlessNewer(oldEntry)
        XCTAssertFalse(mailbox.accepts(oldWake)); XCTAssertNil(mailbox.takeLatest(context: old))
        XCTAssertEqual(mailbox.takeLatest(context: current)?.frame.value, 2)
        mailbox.replaceContext(nil); mailbox.offer(SurfaceMailboxFrame(3)); mailbox.restoreUnlessNewer(oldEntry)
        XCTAssertFalse(mailbox.hasPending(context: current)); XCTAssertFalse(mailbox.hasPending(context: old))
    }

    func test_frameMailboxUncommittedRetryCannotOverwriteANewerFrame() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), log = SurfaceWakeLog(), context = UUID()
        mailbox.setWakeHandler { log.append($0) }; mailbox.replaceContext(context)
        mailbox.offer(SurfaceMailboxFrame(1))
        let old = try XCTUnwrap(mailbox.takeLatest(context: context))
        mailbox.restoreUnlessNewer(old)
        XCTAssertEqual(mailbox.takeLatest(context: context)?.id, old.id)
        mailbox.offer(SurfaceMailboxFrame(2)); mailbox.restoreUnlessNewer(old)
        XCTAssertEqual(mailbox.takeLatest(context: context)?.frame.value, 2)
    }

    func test_frameMailboxConcurrentOffersRemainBoundedAndRetainTheFinalOffer() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), log = SurfaceWakeLog(), context = UUID()
        mailbox.setWakeHandler { log.append($0) }; mailbox.replaceContext(context)
        DispatchQueue.concurrentPerform(iterations: 32) { mailbox.offer(SurfaceMailboxFrame($0)) }
        mailbox.offer(SurfaceMailboxFrame(100))
        XCTAssertEqual(log.values.count, 1)
        XCTAssertEqual(mailbox.takeLatest(context: context)?.frame.value, 100)
        XCTAssertFalse(mailbox.hasPending(context: context))
    }

    func test_frameMailboxRedrawRetainsDecodeIdentityWithoutRepeatingWork() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), context = UUID(), next = UUID()
        mailbox.replaceContext(context); mailbox.offer(SurfaceMailboxFrame(1))
        let decoded = try XCTUnwrap(mailbox.takeLatest(context: context))
        XCTAssertNil(mailbox.takeLatest(context: context), "A retained image is not a perpetual render request")
        mailbox.replaceContext(next, preservingLatestFrom: context)
        let redraw = try XCTUnwrap(mailbox.takeLatest(context: next))
        XCTAssertTrue(redraw.frame === decoded.frame)
        XCTAssertEqual(redraw.id, decoded.id, "Local layout cannot invent a new decode identity")
        XCTAssertEqual(redraw.context, next)
        XCTAssertFalse(mailbox.hasPending(context: next)); XCTAssertNil(mailbox.takeLatest(context: next))
        mailbox.offer(SurfaceMailboxFrame(2))
        let newer = try XCTUnwrap(mailbox.takeLatest(context: next))
        XCTAssertNotEqual(newer.id, redraw.id); XCTAssertEqual(newer.frame.value, 2)
    }

    func test_frameMailboxLayoutTransferKeepsPendingDecodeAndRetiresOldWake() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), log = SurfaceWakeLog(), old = UUID(), next = UUID()
        mailbox.setWakeHandler { log.append($0) }; mailbox.replaceContext(old)
        mailbox.offer(SurfaceMailboxFrame(1)); mailbox.offer(SurfaceMailboxFrame(2))
        let wake = try XCTUnwrap(log.values.first)
        mailbox.replaceContext(next, preservingLatestFrom: old)
        XCTAssertFalse(mailbox.accepts(wake)); XCTAssertNil(mailbox.takeLatest(context: old))
        XCTAssertTrue(mailbox.hasPending(context: next))
        // A decode arriving during layout/acquisition replaces the transferred
        // candidate. A queued wake from the old layout cannot consume it.
        mailbox.offer(SurfaceMailboxFrame(3))
        XCTAssertEqual(log.values.count, 2)
        XCTAssertTrue(mailbox.accepts(try XCTUnwrap(log.values.last)))
        XCTAssertEqual(mailbox.takeLatest(context: next)?.frame.value, 3)
        XCTAssertFalse(mailbox.hasPending(context: next))
    }

    func test_frameMailboxClearsRetainedImageAtVisibilityAndContextBoundaries() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), old = UUID(), next = UUID()
        mailbox.replaceContext(old)
        weak var retained: SurfaceMailboxFrame?
        autoreleasepool {
            let frame = SurfaceMailboxFrame(1); retained = frame; mailbox.offer(frame)
            _ = mailbox.takeLatest(context: old)
        }
        XCTAssertNotNil(retained, "The stationary image survives its first submission")
        mailbox.replaceContext(nil, preservingLatestFrom: old)
        XCTAssertNil(retained)
        mailbox.offer(SurfaceMailboxFrame(2))
        mailbox.replaceContext(next, preservingLatestFrom: old)
        XCTAssertNil(mailbox.takeLatest(context: next), "Hidden output cannot be retained for reveal")
        mailbox.offer(SurfaceMailboxFrame(3)); _ = mailbox.takeLatest(context: next)
        let boundary = UUID()
        mailbox.replaceContext(boundary)
        XCTAssertNil(mailbox.takeLatest(context: boundary))
        let replacement = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>()
        replacement.replaceContext(next, preservingLatestFrom: next)
        XCTAssertNil(replacement.takeLatest(context: next), "A new attachment has no predecessor image")
    }

    func test_frameMailboxRequiresExactPreviousContextForRedraw() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), first = UUID(), second = UUID(), third = UUID()
        mailbox.replaceContext(first); mailbox.offer(SurfaceMailboxFrame(1))
        let original = try XCTUnwrap(mailbox.takeLatest(context: first))
        mailbox.replaceContext(second, preservingLatestFrom: first)
        let redrawn = try XCTUnwrap(mailbox.takeLatest(context: second))
        XCTAssertEqual(redrawn.id, original.id)
        mailbox.replaceContext(third, preservingLatestFrom: first)
        XCTAssertNil(mailbox.takeLatest(context: third), "An obsolete layout cannot transfer the current image")
        mailbox.restoreUnlessNewer(original); mailbox.restoreUnlessNewer(redrawn)
        XCTAssertNil(mailbox.takeLatest(context: third))
        mailbox.offer(SurfaceMailboxFrame(2))
        XCTAssertEqual(mailbox.takeLatest(context: third)?.frame.value, 2)
    }

    func test_frameMailboxFailedImageCannotReappearThroughLayoutAndPreservesNewerDecode() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), first = UUID(), second = UUID(), third = UUID()
        mailbox.replaceContext(first); mailbox.offer(SurfaceMailboxFrame(1))
        let failed = try XCTUnwrap(mailbox.takeLatest(context: first))
        mailbox.discard(frame: failed.id, context: first)
        mailbox.restoreUnlessNewer(failed)
        mailbox.replaceContext(second, preservingLatestFrom: first)
        XCTAssertNil(mailbox.takeLatest(context: second))
        mailbox.offer(SurfaceMailboxFrame(2))
        let older = try XCTUnwrap(mailbox.takeLatest(context: second))
        mailbox.offer(SurfaceMailboxFrame(3))
        mailbox.discard(frame: older.id, context: second)
        let newer = try XCTUnwrap(mailbox.takeLatest(context: second))
        XCTAssertEqual(newer.frame.value, 3)
        mailbox.replaceContext(third, preservingLatestFrom: second)
        mailbox.discard(frame: newer.id, context: second)
        XCTAssertEqual(mailbox.takeLatest(context: third)?.id, newer.id,
                       "An obsolete callback cannot discard the current context")
        mailbox.discard(frame: newer.id, context: third)
        let fourth = UUID()
        mailbox.replaceContext(fourth, preservingLatestFrom: third)
        XCTAssertNil(mailbox.takeLatest(context: fourth))
    }

    func test_frameMailboxLateUncommittedRestoreCannotRegressAConsumedNewerDecode() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), context = UUID(), next = UUID()
        mailbox.replaceContext(context); mailbox.offer(SurfaceMailboxFrame(1))
        let older = try XCTUnwrap(mailbox.takeLatest(context: context))
        mailbox.offer(SurfaceMailboxFrame(2))
        let newer = try XCTUnwrap(mailbox.takeLatest(context: context))
        mailbox.restoreUnlessNewer(older)
        XCTAssertNil(mailbox.takeLatest(context: context))
        mailbox.replaceContext(next, preservingLatestFrom: context)
        XCTAssertEqual(mailbox.takeLatest(context: next)?.id, newer.id)
    }

    func test_frameMailboxReleasesReplacedImagesOutsideItsGate() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>(), first = UUID(), second = UUID()
        mailbox.replaceContext(first)
        autoreleasepool {
            mailbox.offer(SurfaceMailboxFrame(1, onRelease: { mailbox.offer(SurfaceMailboxFrame(2)) }))
            _ = mailbox.takeLatest(context: first)
        }
        mailbox.replaceContext(second)
        XCTAssertEqual(mailbox.takeLatest(context: second)?.frame.value, 2,
                       "Release-time native cleanup may reenter after the new context commits")
    }

    func test_surfacePresentationRejectsOldContextsAndRegressiveTimes() {
        let old = UUID(), current = UUID(), frame = UUID()
        let channel = RemoteVideoSurfacePresentation(context: old)
        channel.begin(context: current)
        channel.present(context: old, frame: frame, time: 1)
        channel.fail(context: old, message: "obsolete")
        XCTAssertEqual(channel.state, .waiting(context: current))
        for time: TimeInterval in [0, -1, .nan, .infinity] { channel.present(context: current, frame: frame, time: time) }
        XCTAssertEqual(channel.state, .waiting(context: current))
        channel.present(context: current, frame: frame, time: 10)
        XCTAssertEqual(channel.state, .presented(context: current, frame: frame, time: 10))
        channel.wait(context: current); channel.present(context: current, frame: UUID(), time: 9)
        XCTAssertEqual(channel.state, .waiting(context: current))
    }

    func test_surfacePresentationFailureCannotRecoverAndRetirementSilencesObservers() {
        let context = UUID(), channel = RemoteVideoSurfacePresentation(context: context)
        var values: [RemoteVideoSurfacePresentation.State] = []
        channel.observe { values.append($0) }
        channel.fail(context: context, message: "failed")
        channel.present(context: context, frame: UUID(), time: 5); channel.wait(context: context); channel.begin(context: UUID())
        XCTAssertEqual(channel.state, .failed(context: context, message: "failed"))
        XCTAssertEqual(values.count, 2)
        channel.retire(); channel.present(context: context, frame: UUID(), time: 6)
        channel.observe { values.append($0) }
        XCTAssertEqual(channel.state, .retired); XCTAssertEqual(values.count, 2)
    }

    func test_surfacePresentationPublicationKeepsAReentrantReplacementContext() {
        let old = UUID(), current = UUID(), channel = RemoteVideoSurfacePresentation(context: old)
        var replaced = false
        channel.observe { state in
            if state == .waiting(context: old), !replaced { replaced = true; channel.begin(context: current) }
        }
        XCTAssertTrue(replaced)
        channel.present(context: old, frame: UUID(), time: 5)
        XCTAssertEqual(channel.state, .waiting(context: current))
        let frame = UUID(); channel.present(context: current, frame: frame, time: 6)
        XCTAssertEqual(channel.state, .presented(context: current, frame: frame, time: 6))
    }

    func test_drawableSizingBoundsPhysicalPixelsAndRejectsInvalidRequests() {
        XCTAssertEqual(RemoteVideoDrawableSizing.size(bounds: CGSize(width: 900, height: 1600), scale: 3), CGSize(width: 2700, height: 4800))
        XCTAssertEqual(RemoteVideoDrawableSizing.size(bounds: CGSize(width: 10_000, height: 10_000), scale: 3), CGSize(width: 4096, height: 4096))
        XCTAssertEqual(RemoteVideoDrawableSizing.size(bounds: CGSize(width: 2, height: 16_384), scale: 1), CGSize(width: 1, height: 8192))
        for bounds in [CGSize.zero, CGSize(width: -1, height: 2), CGSize(width: CGFloat.nan, height: 2),
                       CGSize(width: CGFloat.infinity, height: 2), CGSize(width: CGFloat.greatestFiniteMagnitude, height: 2)] {
            XCTAssertNil(RemoteVideoDrawableSizing.size(bounds: bounds, scale: 3))
        }
        for scale: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertNil(RemoteVideoDrawableSizing.size(bounds: CGSize(width: 10, height: 10), scale: scale))
        }
    }

    func test_attachmentRetirementSilencesPresentationBeforeNativeCleanup() {
        let context = UUID(), channel = RemoteVideoSurfacePresentation(context: context)
        var states: [RemoteVideoSurfacePresentation.State] = [], removed = 0
        channel.observe { states.append($0) }
        let attachment = RemoteVideoSurfaceAttachment(renderer: SurfaceReceiptRenderer(), presentation: channel) {
            removed += 1
            XCTAssertEqual(channel.state, .retired)
            channel.present(context: context, frame: UUID(), time: 3)
        }
        attachment.retire(); attachment.retire()
        XCTAssertEqual(removed, 1); XCTAssertEqual(states, [.waiting(context: context)])
    }
}

private final class SurfaceMailboxFrame: NSObject, @unchecked Sendable {
    let value: Int
    private let onRelease: (@Sendable () -> Void)?
    init(_ value: Int, onRelease: (@Sendable () -> Void)? = nil) { self.value = value; self.onRelease = onRelease }
    deinit { onRelease?() }
}

private final class SurfaceWakeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>.Wake] = []
    var values: [RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>.Wake] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ wake: RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>.Wake) { lock.lock(); stored.append(wake); lock.unlock() }
}

private final class SurfaceReceiptRenderer: NSObject, RTCVideoRenderer {
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {}
}
