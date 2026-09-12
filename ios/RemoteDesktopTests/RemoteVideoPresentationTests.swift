import XCTest
import CoreGraphics
@testable import RemoteDesktop

@MainActor
final class RemoteVideoPresentationTests: XCTestCase {
    func test_simulatorReceiptRequiresSuccessfulCommittedGPUWorkAndNeverClaimsPresentation() throws {
        let drawable = NSObject()
        for succeeded in [true, false] {
            var ledger = RemoteVideoPresentationLedger()
            let ticket = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(),
                drawable: ObjectIdentifier(drawable), drawableID: 0, requiresPresentationCallback: false))
            XCTAssertTrue(ledger.completeGPU(ticket, succeeded: true, completionTime: 4).results.isEmpty)
            XCTAssertTrue(ledger.commit(ticket))
            XCTAssertTrue(ledger.presented(ticket, drawable: ObjectIdentifier(drawable), drawableID: 0, time: 5).results.isEmpty,
                "A Simulator ticket cannot acquire a hardware presentation receipt")
            let result = ledger.completeGPU(ticket, succeeded: succeeded, completionTime: 6)
            XCTAssertEqual(result.results.first?.1, succeeded ? .rendered(6) : .failed)
            XCTAssertEqual(result.released, [ticket]); XCTAssertEqual(ledger.count, 0)
            XCTAssertTrue(ledger.completeGPU(ticket, succeeded: true, completionTime: 7).results.isEmpty)
        }
    }

    func test_simulatorRetirementAndExpiryKeepGPUOwnershipAndRejectLateReadiness() throws {
        let drawable = NSObject(), context = UUID()
        for expires in [true, false] {
            var ledger = RemoteVideoPresentationLedger(capacity: 1)
            let ticket = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(),
                drawable: ObjectIdentifier(drawable), drawableID: 1, requiresPresentationCallback: false))
            XCTAssertTrue(ledger.commit(ticket))
            let retirement = expires ? ledger.expire(ticket) : ledger.retire(context: context)
            XCTAssertTrue(retirement.released.isEmpty); XCTAssertEqual(ledger.count, 1)
            XCTAssertNil(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 2))
            let late = ledger.completeGPU(ticket, succeeded: true, completionTime: 8)
            XCTAssertTrue(late.results.isEmpty); XCTAssertEqual(late.released, [ticket]); XCTAssertEqual(ledger.count, 0)
        }
    }

    func test_receiptRequiresGPUCompletionAndExactPresentationInEitherOrder() throws {
        let drawable = NSObject()
        for presentationFirst in [true, false] {
            var ledger = RemoteVideoPresentationLedger()
            let ticket = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 0))
            XCTAssertTrue(ledger.commit(ticket))
            let first = presentationFirst
                ? ledger.presented(ticket, drawable: ObjectIdentifier(drawable), drawableID: 0, time: 4)
                : ledger.completeGPU(ticket, succeeded: true)
            XCTAssertTrue(first.results.isEmpty); XCTAssertTrue(first.released.isEmpty)
            XCTAssertEqual(ledger.count, 1)
            let second = presentationFirst
                ? ledger.completeGPU(ticket, succeeded: true)
                : ledger.presented(ticket, drawable: ObjectIdentifier(drawable), drawableID: 0, time: 4)
            XCTAssertEqual(second.results.count, 1); XCTAssertEqual(second.results.first?.0, ticket)
            XCTAssertEqual(second.results.first?.1, .presented(4)); XCTAssertEqual(second.released, [ticket])
            XCTAssertEqual(ledger.count, 0)
        }
    }

    func test_skippedInvalidOrFailedPresentationCannotProduceAPresentedReceipt() throws {
        let drawable = NSObject()
        for time: TimeInterval in [0, -1, .nan, .infinity] {
            var ledger = RemoteVideoPresentationLedger()
            let ticket = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 1))
            XCTAssertTrue(ledger.commit(ticket))
            XCTAssertTrue(ledger.presented(ticket, drawable: ObjectIdentifier(drawable), drawableID: 1, time: time).results.isEmpty)
            XCTAssertEqual(ledger.completeGPU(ticket, succeeded: true).results.first?.1, .skipped)
            XCTAssertEqual(ledger.count, 0)
        }
        var ledger = RemoteVideoPresentationLedger()
        let ticket = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 2))
        XCTAssertTrue(ledger.commit(ticket))
        _ = ledger.presented(ticket, drawable: ObjectIdentifier(drawable), drawableID: 2, time: 4)
        XCTAssertEqual(ledger.completeGPU(ticket, succeeded: false).results.first?.1, .failed)
        XCTAssertTrue(ledger.completeGPU(ticket, succeeded: true).results.isEmpty)
    }

    func test_contextRetirementSuppressesReceiptAndKeepsNativeCapacityUntilCompletion() throws {
        let firstDrawable = NSObject(), secondDrawable = NSObject(), context = UUID()
        var ledger = RemoteVideoPresentationLedger(capacity: 1)
        let old = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(firstDrawable), drawableID: 1))
        XCTAssertTrue(ledger.commit(old))
        let retirement = ledger.retire(context: context)
        XCTAssertEqual(retirement.silenced, [old]); XCTAssertTrue(retirement.released.isEmpty)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertNil(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(secondDrawable), drawableID: 2))
        XCTAssertTrue(ledger.presented(old, drawable: ObjectIdentifier(firstDrawable), drawableID: 1, time: 5).results.isEmpty)
        let completion = ledger.completeGPU(old, succeeded: true)
        XCTAssertTrue(completion.results.isEmpty); XCTAssertEqual(completion.released, [old])
        XCTAssertNotNil(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(secondDrawable), drawableID: 2))
    }

    func test_observationExpiryReportsOnceWithoutReleasingUnfinishedGPUWork() throws {
        let drawable = NSObject()
        var ledger = RemoteVideoPresentationLedger(capacity: 1)
        let ticket = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 1))
        XCTAssertTrue(ledger.commit(ticket))
        let expiry = ledger.expire(ticket)
        XCTAssertEqual(expiry.results.first?.1, .expired); XCTAssertTrue(expiry.released.isEmpty)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertTrue(ledger.expire(ticket).results.isEmpty)
        XCTAssertTrue(ledger.presented(ticket, drawable: ObjectIdentifier(drawable), drawableID: 1, time: 6).results.isEmpty)
        XCTAssertEqual(ledger.completeGPU(ticket, succeeded: false).released, [ticket])
        XCTAssertEqual(ledger.count, 0)
    }

    func test_uncommittedRetirementAndAbandonmentDoNotStartOrLeakWork() throws {
        let drawable = NSObject(), context = UUID()
        var ledger = RemoteVideoPresentationLedger(capacity: 1)
        let first = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 1))
        XCTAssertTrue(ledger.completeGPU(first, succeeded: true).results.isEmpty)
        XCTAssertTrue(ledger.presented(first, drawable: ObjectIdentifier(drawable), drawableID: 1, time: 5).results.isEmpty)
        XCTAssertEqual(ledger.retire(context: context).released, [first]); XCTAssertFalse(ledger.commit(first))
        let next = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 2))
        XCTAssertEqual(ledger.abandonUncommitted(next).released, [next]); XCTAssertEqual(ledger.count, 0)
        XCTAssertFalse(ledger.commit(next))
    }

    func test_wrongDrawableForeignTicketAndDuplicateCallbacksCannotCompleteSuccessor() throws {
        let drawable = NSObject(), foreign = NSObject()
        var ledger = RemoteVideoPresentationLedger()
        let first = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 1))
        XCTAssertNil(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 2))
        XCTAssertTrue(ledger.commit(first)); XCTAssertFalse(ledger.commit(first))
        XCTAssertTrue(ledger.abandonUncommitted(first).released.isEmpty)
        _ = ledger.completeGPU(first, succeeded: true)
        XCTAssertTrue(ledger.presented(first, drawable: ObjectIdentifier(foreign), drawableID: 1, time: 4).results.isEmpty)
        XCTAssertTrue(ledger.presented(first, drawable: ObjectIdentifier(drawable), drawableID: 2, time: 4).results.isEmpty)
        XCTAssertEqual(ledger.presented(first, drawable: ObjectIdentifier(drawable), drawableID: 1, time: 4).results.first?.1, .presented(4))
        let next = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 2))
        XCTAssertTrue(ledger.commit(next))
        XCTAssertTrue(ledger.presented(first, drawable: ObjectIdentifier(drawable), drawableID: 1, time: 8).results.isEmpty)
        XCTAssertTrue(ledger.completeGPU(first, succeeded: false).results.isEmpty)
        XCTAssertEqual(ledger.count, 1)
        _ = ledger.presented(next, drawable: ObjectIdentifier(drawable), drawableID: 2, time: 9)
        XCTAssertEqual(ledger.completeGPU(next, succeeded: true).results.first?.0, next)
    }

    func test_gpuCompletedWorkStillWaitsForPresentationOrExplicitRetirement() throws {
        let drawable = NSObject(), context = UUID()
        var ledger = RemoteVideoPresentationLedger(capacity: 1)
        let ticket = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 1))
        XCTAssertTrue(ledger.commit(ticket))
        XCTAssertTrue(ledger.completeGPU(ticket, succeeded: true).released.isEmpty)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.retire(context: context).released, [ticket]); XCTAssertEqual(ledger.count, 0)
    }

    func test_pixelGeometryConvertsCropOriginBeforeAdaptationAndRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let geometry = try XCTUnwrap(RemoteVideoPixelGeometry(frameWidth: 200, frameHeight: 100,
                bufferWidth: 800, bufferHeight: 600, cropX: 20, cropY: 30, cropWidth: 400, cropHeight: 200, rotation: rotation))
            XCTAssertEqual(geometry.cropInImageCoordinates, CGRect(x: 20, y: 370, width: 400, height: 200))
            XCTAssertEqual(geometry.frameWidth, 200); XCTAssertEqual(geometry.frameHeight, 100)
            XCTAssertEqual(geometry.rotation, rotation)
        }
    }

    func test_pixelGeometryRejectsUnsupportedOrOutOfBoundsFramesBeforeCoreImage() {
        for (x, y, width, height, rotation) in [(-1, 0, 100, 100, 0), (Int.max, 0, 100, 100, 0),
            (0, -1, 100, 100, 0), (0, Int.max, 100, 100, 0), (700, 0, 200, 100, 0),
            (0, 500, 100, 200, 0), (0, 0, 0, 100, 0), (0, 0, 100, 0, 0), (0, 0, 100, 100, 45)] {
            XCTAssertNil(RemoteVideoPixelGeometry(frameWidth: 100, frameHeight: 100, bufferWidth: 800, bufferHeight: 600,
                cropX: x, cropY: y, cropWidth: width, cropHeight: height, rotation: rotation))
        }
        XCTAssertNil(RemoteVideoPixelGeometry(frameWidth: Int.max, frameHeight: 100, bufferWidth: 800, bufferHeight: 600,
            cropX: 0, cropY: 0, cropWidth: 100, cropHeight: 100, rotation: 0))
        XCTAssertFalse(RemoteVideoPresentationProducer.validDestination(width: Int.max, height: Int.max))
        XCTAssertFalse(RemoteVideoPresentationProducer.validDestination(width: 0, height: 1))
        XCTAssertFalse(RemoteVideoPresentationProducer.validDestination(width: 8_192, height: 8_192))
        XCTAssertTrue(RemoteVideoPresentationProducer.validDestination(width: 3_840, height: 2_160))
    }
}
