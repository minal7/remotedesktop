import XCTest
import CoreGraphics
import LiveKitWebRTC
@testable import RemoteDesktop

@MainActor
final class RemoteVideoPresentationSurfaceTests: XCTestCase {
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
    init(_ value: Int) { self.value = value }
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
