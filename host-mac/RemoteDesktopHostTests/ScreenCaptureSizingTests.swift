import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import RemoteDesktopHost

final class ScreenCaptureSizingTests: XCTestCase {
    func test_capturePlacementConvertsSurfacePointsWithoutApplyingContentScaleTwice() throws {
        let placement = try XCTUnwrap(CaptureVideoPlacement.read(placementAttachments(
            rect: CGRect(x: 0, y: 0, width: 960, height: 540), scale: 2, contentScale: 0.5)))
        XCTAssertEqual(placement.contentRect, CGRect(x: 0, y: 0, width: 960, height: 540))
        XCTAssertEqual(placement.contentScale, 0.5)
        XCTAssertTrue(placement.coversFullDisplaySurface(width: 1920, height: 1080, displayScale: 2))
        XCTAssertFalse(placement.coversFullDisplaySurface(width: 960, height: 540, displayScale: 2))
        let floating = try XCTUnwrap(CaptureVideoPlacement.read(placementAttachments(
            rect: CGRect(x: 0, y: 0, width: 960.0001, height: 539.9999), scale: 2)))
        XCTAssertTrue(floating.coversFullDisplaySurface(width: 1920, height: 1080, displayScale: 2))
    }

    func test_capturePlacementRejectsMissingMalformedAndNonfiniteMetadata() {
        let valid = placementAttachments()
        for key: SCStreamFrameInfo in [.contentRect, .scaleFactor, .contentScale] {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(CaptureVideoPlacement.read(missing))
            for raw: Any in [NSNull(), true, "1", [1, 2], NSNumber(value: Double.nan), NSNumber(value: Double.infinity)] {
                var malformed = valid; malformed[key] = raw
                XCTAssertNil(CaptureVideoPlacement.read(malformed))
            }
        }
        for scale in [0.0, 0.5, 4.1] {
            XCTAssertNil(CaptureVideoPlacement.read(placementAttachments(scale: scale)))
        }
        XCTAssertNil(CaptureVideoPlacement.read(placementAttachments(contentScale: 0)))
        XCTAssertNil(CaptureVideoPlacement.read(placementAttachments(contentScale: -1)))
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 2),
                     CGRect(x: .infinity, y: 0, width: 2, height: 2)] {
            XCTAssertNil(CaptureVideoPlacement.read(placementAttachments(rect: rect)))
        }
        var booleanRect = valid
        booleanRect[.contentRect] = ["X": false, "Y": 0, "Width": 1, "Height": 1] as [String: Any]
        XCTAssertNil(CaptureVideoPlacement.read(booleanRect))
    }

    func test_capturePlacementRejectsPaddingCroppingDensityAndPresenterOverlay() throws {
        for rect in [CGRect(x: 1, y: 0, width: 959, height: 540),
                     CGRect(x: 0, y: 0.5, width: 960, height: 539.5),
                     CGRect(x: 0, y: 0, width: 961, height: 540),
                     CGRect(x: -1, y: 0, width: 960, height: 540)] {
            let placement = try XCTUnwrap(CaptureVideoPlacement.read(placementAttachments(rect: rect, scale: 2)))
            XCTAssertFalse(placement.coversFullDisplaySurface(width: 1920, height: 1080, displayScale: 2))
        }
        let placement = try XCTUnwrap(CaptureVideoPlacement.read(placementAttachments(
            rect: CGRect(x: 0, y: 0, width: 960, height: 540), scale: 2)))
        XCTAssertFalse(placement.coversFullDisplaySurface(width: 1920, height: 1080, displayScale: 1))
        if #available(macOS 14.2, *) {
            var attachments = placementAttachments()
            attachments[.presenterOverlayContentRect] = CGRect.zero.dictionaryRepresentation
            XCTAssertTrue(try XCTUnwrap(CaptureVideoPlacement.read(attachments))
                .coversFullDisplaySurface(width: 2, height: 2, displayScale: 2))
            attachments[.presenterOverlayContentRect] = CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation
            XCTAssertFalse(try XCTUnwrap(CaptureVideoPlacement.read(attachments))
                .coversFullDisplaySurface(width: 2, height: 2, displayScale: 2))
            attachments[.presenterOverlayContentRect] = "unknown"
            XCTAssertNil(CaptureVideoPlacement.read(attachments))
        }
    }

    func test_capturedFrameRequiresAndRetainsItsOwnPlacementAttachments() throws {
        let sample = try captureSample()
        let frame = try XCTUnwrap(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        XCTAssertTrue(frame.placement.coversFullDisplaySurface(width: 2, height: 2, displayScale: 2))
        let rows = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSMutableDictionary])
        let row = try XCTUnwrap(rows.first)
        row.removeObject(forKey: SCStreamFrameInfo.contentRect.rawValue)
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        XCTAssertTrue(frame.placement.coversFullDisplaySurface(width: 2, height: 2, displayScale: 2),
                      "The already constructed frame retains its own immutable placement")
    }

    func test_fullDisplayConfigurationFillsCodecSurfaceWithoutAspectPadding() {
        let configuration = ScreenCapture.streamConfiguration(width: 1920, height: 1240, audioEnabled: false)
        XCTAssertFalse(configuration.preservesAspectRatio)
        XCTAssertEqual(configuration.destinationRect, CGRect(x: 0, y: 0, width: 1920, height: 1240))
        XCTAssertEqual(configuration.sourceRect, .zero, "The native default captures the entire selected display")
        XCTAssertEqual(configuration.width, 1920); XCTAssertEqual(configuration.height, 1240)
    }

    private func placementAttachments(rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                                      scale: Double = 2, contentScale: Double = 1) -> [SCStreamFrameInfo: Any] {
        [.contentRect: rect.dictionaryRepresentation, .scaleFactor: NSNumber(value: scale),
         .contentScale: NSNumber(value: contentScale)]
    }

    func test_captureDisplayFenceRequiresOneSuccessfulRegistration() throws {
        let fence = CaptureDisplayChangeFence()
        XCTAssertNil(fence.current)
        let unavailable: Int? = fence.sample { _ in XCTFail("No native reads before registration"); return 1 }
        XCTAssertNil(unavailable)
        // A callback may arrive inside registration, before it returns.
        fence.record(display: 17, flags: .beginConfigurationFlag)
        fence.completeRegistration(succeeded: true)
        XCTAssertNil(fence.current)
        fence.record(display: 17, flags: .setModeFlag)
        let current = try XCTUnwrap(fence.current)
        fence.completeRegistration(succeeded: true)
        XCTAssertEqual(fence.current, current, "Registration completion is one-shot")

        let failed = CaptureDisplayChangeFence()
        failed.completeRegistration(succeeded: false)
        failed.completeRegistration(succeeded: true)
        failed.record(display: 17, flags: .setModeFlag)
        XCTAssertNil(failed.current, "Later calls cannot disguise a failed native registration")
    }

    func test_captureDisplayFenceWaitsForEveryChangingDisplay() throws {
        let fence = CaptureDisplayChangeFence()
        fence.completeRegistration(succeeded: true)
        let before = try XCTUnwrap(fence.current)
        fence.record(display: 17, flags: .beginConfigurationFlag)
        fence.record(display: 22, flags: .beginConfigurationFlag)
        fence.record(display: 17, flags: .beginConfigurationFlag)
        XCTAssertFalse(fence.isCurrent(before))
        fence.record(display: 17, flags: .movedFlag)
        XCTAssertNil(fence.current, "The other display is still changing")
        fence.record(display: 22, flags: .removeFlag)
        let after = try XCTUnwrap(fence.current)
        XCTAssertNotEqual(before, after)
        fence.record(display: 30, flags: .addFlag)
        XCTAssertNotEqual(fence.current, after, "Post-change notifications without a seen begin also retire old tokens")
        XCTAssertNotNil(fence.current)
    }

    func test_captureDisplayFenceDiscardsSamplesCrossingAConfigurationBoundary() throws {
        let fence = CaptureDisplayChangeFence()
        fence.completeRegistration(succeeded: true)
        let before = try XCTUnwrap(fence.current)
        let crossed: String? = fence.sample { configuration in
            XCTAssertEqual(configuration, before)
            fence.record(display: 17, flags: .beginConfigurationFlag)
            fence.record(display: 17, flags: .setModeFlag)
            return "numerically unchanged bounds"
        }
        XCTAssertNil(crossed, "A completed change during native reads still invalidates the sample")
        let stable = fence.sample { Optional($0) }
        XCTAssertEqual(stable, fence.current)
        XCTAssertNotEqual(stable, before)
        fence.record(display: 17, flags: .beginConfigurationFlag)
        let pending: String? = fence.sample { _ in XCTFail("Do not sample a changing configuration"); return "stale" }
        XCTAssertNil(pending)
        fence.record(display: 17, flags: .setModeFlag)
        let absent: String? = fence.sample { _ in nil }
        XCTAssertNil(absent, "An unavailable native display remains unavailable in a stable configuration")
    }

    func test_captureDisplayFenceBoundsInvalidAndUnbalancedNotifications() throws {
        let invalid = CaptureDisplayChangeFence()
        invalid.completeRegistration(succeeded: true)
        invalid.record(display: 0, flags: .beginConfigurationFlag)
        invalid.record(display: 17, flags: .setModeFlag)
        XCTAssertNil(invalid.current, "An unidentifiable change cannot establish a stable configuration")

        let bounded = CaptureDisplayChangeFence()
        bounded.completeRegistration(succeeded: true)
        for display: UInt32 in 1...64 { bounded.record(display: display, flags: .beginConfigurationFlag) }
        for display: UInt32 in 1...64 { bounded.record(display: display, flags: .setModeFlag) }
        XCTAssertNotNil(bounded.current, "The bounded pending set can drain normally")
        for display: UInt32 in 1...65 { bounded.record(display: display, flags: .beginConfigurationFlag) }
        for display: UInt32 in 1...65 { bounded.record(display: display, flags: .setModeFlag) }
        XCTAssertNil(bounded.current, "Overflow cannot evict evidence and reopen admission")
    }

    func test_captureDisplayGeometryRejectsRestoredDimensionsFromAnOlderConfiguration() throws {
        let fence = CaptureDisplayChangeFence()
        fence.completeRegistration(succeeded: true)
        let bounds = CGRect(x: -1600, y: 120, width: 1600, height: 900)
        let sample = { fence.sample { configuration in
            CaptureDisplayState(displayID: 17, bounds: bounds, pixelWidth: 3200, pixelHeight: 1800,
                                rotation: 0, configuration: configuration)
        } }
        let old = try XCTUnwrap(sample())
        let geometry = try XCTUnwrap(CaptureDisplayGeometry(state: old, contentSizeInPoints: bounds.size, backingScale: 2))
        fence.record(display: 17, flags: .beginConfigurationFlag)
        XCTAssertFalse(geometry.matches(sample()))
        fence.record(display: 17, flags: .setModeFlag)
        let restored = try XCTUnwrap(sample())
        XCTAssertEqual(restored.originX, old.originX); XCTAssertEqual(restored.width, old.width)
        XCTAssertEqual(restored.pixelWidth, old.pixelWidth)
        XCTAssertNotEqual(restored.configuration, old.configuration)
        XCTAssertFalse(geometry.matches(restored), "Restoring dimensions does not restore the old capture lifetime")
    }

    func test_captureDisplayNotificationCanRetireAnInstalledStartingStream() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let owner = lifecycle.beginOwner(context: "starting")
        let stream = CaptureLifecycleTestStream()
        let entered = expectation(description: "native start entered")
        let release = CaptureLifecycleTestLatch()
        let start = try lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in
            entered.fulfill(); await release.wait()
        })
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(lifecycle.isRunning(for: owner))
        var stopped: CaptureStopReceipt?
        XCTAssertTrue(lifecycle.withCurrentStream { context, attempt, current in
            XCTAssertEqual(context, "starting"); XCTAssertTrue(current === stream)
            XCTAssertTrue(lifecycle.streamStopped(current) { _, receipt in
                XCTAssertEqual(receipt.attempt, attempt); stopped = receipt
            })
        })
        XCTAssertNotNil(stopped)
        XCTAssertFalse(lifecycle.withCurrentStream { _, _, _ in XCTFail("Retired startup has no current native resource") })
        await release.open()
        do { try await start.value; XCTFail("A delayed native success cannot restore the old configuration") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(lifecycle.consumeStop(try XCTUnwrap(stopped)))
        await lifecycle.endAll().value
    }

    func test_captureDelayedDisplayNotificationPreservesTheLatestReplacement() async throws {
        let fence = CaptureDisplayChangeFence()
        fence.completeRegistration(succeeded: true)
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, UUID> { _ in }
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: try XCTUnwrap(fence.current))
        try await lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }).value
        fence.record(display: 17, flags: .beginConfigurationFlag)
        fence.record(display: 17, flags: .setModeFlag)
        // Model queued observer delivery using the production current-resource
        // gate and latest fence. No native observer is registered by this fixture.
        XCTAssertTrue(lifecycle.withCurrentStream { configuration, _, current in
            XCTAssertFalse(fence.isCurrent(configuration)); XCTAssertTrue(current === old)
            XCTAssertTrue(lifecycle.streamStopped(current) { _, _ in })
        })
        let replacement = lifecycle.beginOwner(context: try XCTUnwrap(fence.current))
        try await lifecycle.start(for: replacement, prepare: { next }, startStream: { _ in }).value
        XCTAssertTrue(lifecycle.withCurrentStream { configuration, _, current in
            XCTAssertTrue(fence.isCurrent(configuration)); XCTAssertTrue(current === next)
        })
        XCTAssertTrue(lifecycle.isRunning(for: replacement))
        XCTAssertFalse(lifecycle.streamStopped(old) { _, _ in XCTFail("A delayed old stream callback cannot retire its replacement") })
        await lifecycle.endAll().value
        XCTAssertFalse(lifecycle.withCurrentStream { _, _, _ in XCTFail("Closed owners cannot receive queued notifications") })
    }

    func test_captureDisplayGeometryRejectsUnrepresentableOrInconsistentNativeDimensions() throws {
        let bounds = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let state = try XCTUnwrap(CaptureDisplayState(displayID: 17, bounds: bounds,
            pixelWidth: 3840, pixelHeight: 2160, rotation: 0))
        let geometry = try XCTUnwrap(CaptureDisplayGeometry(state: state, contentSizeInPoints: bounds.size, backingScale: 2))
        XCTAssertEqual(geometry.backingWidth, 3840); XCTAssertEqual(geometry.backingHeight, 2160)
        for invalid in [CGRect(x: .nan, y: 0, width: 10, height: 10),
                        CGRect(x: 0, y: .infinity, width: 10, height: 10),
                        CGRect(x: 0, y: 0, width: 0, height: 10),
                        CGRect(x: 0, y: 0, width: 10.5, height: 10),
                        CGRect(x: 0, y: 0, width: CGFloat(Int64.max), height: 10)] {
            XCTAssertNil(CaptureDisplayState(displayID: 17, bounds: invalid, pixelWidth: 20, pixelHeight: 20, rotation: 0))
        }
        XCTAssertNil(CaptureDisplayState(displayID: 0, bounds: bounds, pixelWidth: 3840, pixelHeight: 2160, rotation: 0))
        XCTAssertNil(CaptureDisplayState(displayID: 17, bounds: bounds, pixelWidth: 0, pixelHeight: 2160, rotation: 0))
        XCTAssertNil(CaptureDisplayState(displayID: 17, bounds: bounds, pixelWidth: 3840, pixelHeight: 2160, rotation: 45))
        for scale in [Double.nan, .infinity, 0, 0.5, 5] {
            XCTAssertNil(CaptureDisplayGeometry(state: state, contentSizeInPoints: bounds.size, backingScale: scale))
        }
        XCTAssertNil(CaptureDisplayGeometry(state: state, contentSizeInPoints: CGSize(width: 3840, height: 2160), backingScale: 2))
        let enormous = try XCTUnwrap(CaptureDisplayState(displayID: 17,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(Int32.max), height: 2),
            pixelWidth: Int(Int32.max), pixelHeight: 2, rotation: 0))
        XCTAssertNil(CaptureDisplayGeometry(state: enormous,
            contentSizeInPoints: CGSize(width: CGFloat(Int32.max), height: 2), backingScale: 4))
    }

    func test_captureDisplayGeometryMapsScreenLocalCornersAndScrollToGlobalCoordinates() throws {
        let bounds = CGRect(x: -1200, y: 1080, width: 1200, height: 1920)
        let state = try XCTUnwrap(CaptureDisplayState(displayID: 22, bounds: bounds,
            pixelWidth: 2400, pixelHeight: 3840, rotation: 90))
        let geometry = try XCTUnwrap(CaptureDisplayGeometry(state: state, contentSizeInPoints: bounds.size, backingScale: 2))
        XCTAssertEqual(geometry.map(.pointer(x: 0, y: 0, buttons: 1)), .pointer(x: -1200, y: 1080, buttons: 1))
        XCTAssertEqual(geometry.map(.pointer(x: 1199, y: 1919, buttons: 0)), .pointer(x: -1, y: 2999, buttons: 0))
        XCTAssertEqual(geometry.map(.scroll(x: 600, y: 960, dx: -8, dy: 90, phase: .changed)),
                       .scroll(x: -600, y: 2040, dx: -8, dy: 90, phase: .changed))
        XCTAssertEqual(geometry.map(.text("hello")), .text("hello"))
        XCTAssertEqual(geometry.map(.key(usage: 4, down: true, modifiers: 8)), .key(usage: 4, down: true, modifiers: 8))
        for point in [(-1, 0), (0, -1), (1200, 0), (0, 1920), (Int.max, Int.min)] {
            XCTAssertNil(geometry.map(.pointer(x: point.0, y: point.1, buttons: 0)))
            XCTAssertNil(geometry.map(.scroll(x: point.0, y: point.1, dx: 0, dy: 1, phase: .begin)))
        }
    }

    func test_captureDisplayGeometryRejectsIdentityBoundsModeRotationAndOfflineChanges() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let original = try XCTUnwrap(CaptureDisplayState(displayID: 17, bounds: bounds,
            pixelWidth: 3840, pixelHeight: 2160, rotation: 0))
        let geometry = try XCTUnwrap(CaptureDisplayGeometry(state: original, contentSizeInPoints: bounds.size, backingScale: 2))
        XCTAssertTrue(geometry.matches(original))
        let changed: [CaptureDisplayState?] = [
            nil,
            CaptureDisplayState(displayID: 18, bounds: bounds, pixelWidth: 3840, pixelHeight: 2160, rotation: 0),
            CaptureDisplayState(displayID: 17, bounds: bounds.offsetBy(dx: -1920, dy: 0), pixelWidth: 3840, pixelHeight: 2160, rotation: 0),
            CaptureDisplayState(displayID: 17, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), pixelWidth: 3840, pixelHeight: 2160, rotation: 0),
            CaptureDisplayState(displayID: 17, bounds: bounds, pixelWidth: 1920, pixelHeight: 1080, rotation: 0),
            CaptureDisplayState(displayID: 17, bounds: bounds, pixelWidth: 3840, pixelHeight: 2160, rotation: 180)
        ]
        for current in changed { XCTAssertFalse(geometry.matches(current)) }
        XCTAssertTrue(ScreenCapture.isRecoverableStop(ScreenCapture.CaptureError.displayChanged))
        XCTAssertFalse(ScreenCapture.isRecoverableStop(ScreenCapture.CaptureError.invalidDisplayGeometry))
    }

    func test_captureNativeResourceLookupCannotAdmitARetiredWrapperOrOwner() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: "old display")
        try await lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }).value
        let lookup = try XCTUnwrap(lifecycle.stream(matching: { $0 === old }))
        XCTAssertTrue(lifecycle.withRunningStream(owner) { _, resource in XCTAssertTrue(resource === lookup) })
        let successor = lifecycle.beginOwner(context: "new display")
        try await lifecycle.start(for: successor, prepare: { next }, startStream: { _ in }).value
        XCTAssertNil(lifecycle.stream(matching: { $0 === old }))
        XCTAssertFalse(lifecycle.withStream(lookup) { _, _ in XCTFail("Lookup is not retained admission") })
        XCTAssertFalse(lifecycle.streamStopped(lookup) { _, _ in XCTFail("Old callback cannot retire replacement") })
        XCTAssertFalse(lifecycle.withRunningStream(owner) { _, _ in XCTFail("Old owner cannot borrow replacement resources") })
        XCTAssertTrue(lifecycle.withRunningStream(successor) { _, resource in XCTAssertTrue(resource === next) })
        await lifecycle.endAll().value
    }

    func test_captureInitialDeadlineCanRetireDiscoveryBeforeNativeReturn() async throws {
        // Manually evaluate the production budget and retire the fake native
        // owner. This fixture does not execute the peer's scheduled watchdog.
        let trace = CaptureLifecycleTrace()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in trace.append("stop") }
        let owner = lifecycle.beginOwner(context: "initial peer")
        let stream = CaptureLifecycleTestStream()
        let entered = expectation(description: "discovery entered")
        let release = CaptureLifecycleTestLatch()
        let now = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: now)
        XCTAssertTrue(episode.reserveAttempt(at: now))
        let start = try lifecycle.start(for: owner, prepare: {
            entered.fulfill(); await release.wait(); return stream
        }, startStream: { _ in trace.append("start") })
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(episode.failure(at: episode.deadline), .timedOut)
        XCTAssertFalse(episode.reserveAttempt(at: episode.deadline))
        let teardown = lifecycle.endOwner(owner)
        XCTAssertFalse(lifecycle.withStream(stream) { _, _ in XCTFail("Discovery has not installed a stream") })
        XCTAssertFalse(lifecycle.withRunningOwner(owner) { _ in XCTFail("Expired owner is closed") })
        await release.open()
        do { try await start.value; XCTFail("Late discovery must not start capture") }
        catch { XCTAssertTrue(error is CancellationError) }
        await teardown.value
        XCTAssertEqual(trace.values, ["stop"], "The prepared object is cleaned without a native start")
        XCTAssertEqual(episode.attempts, 1)
    }

    func test_captureInitialEarlyFrameAndLateNativeSuccessCannotSatisfyExpiredReadiness() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let owner = lifecycle.beginOwner(context: "initial peer")
        let stream = CaptureLifecycleTestStream()
        let entered = expectation(description: "native start entered")
        let release = CaptureLifecycleTestLatch()
        let now = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: now)
        XCTAssertTrue(episode.reserveAttempt(at: now))
        let start = try lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in
            entered.fulfill(); await release.wait()
        })
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        await fulfillment(of: [entered], timeout: 2)
        var output: CaptureAttemptLease?
        var availability = CaptureVideoAvailability()
        XCTAssertTrue(lifecycle.withStream(stream) { _, attempt in
            output = attempt; availability.recordDeliveredFrame(from: attempt)
        })
        XCTAssertFalse(lifecycle.withRunningOwner(owner) { _ in XCTFail("Early output is not completed native startup") })
        await release.open(); try await start.value
        XCTAssertTrue(lifecycle.withRunningOwner(owner) { running in
            XCTAssertTrue(availability.isAvailable(for: running))
            XCTAssertTrue(episode.acceptsFrame(lastOutput: output, running: running,
                at: episode.deadline.advanced(by: .nanoseconds(-1))))
            XCTAssertFalse(episode.acceptsFrame(lastOutput: output, running: running, at: episode.deadline),
                           "Even a delayed watchdog must not permit late source readiness")
        })
        await lifecycle.endOwner(owner).value
    }

    func test_captureInitialFailedStartsShareTheOriginalAttemptAndCleanupBudget() async throws {
        let trace = CaptureLifecycleTrace()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in trace.append("stop") }
        let owner = lifecycle.beginOwner(context: "initial peer")
        let now = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: now)
        let id = episode.id, deadline = episode.deadline
        for index in 0..<CaptureRecoveryEpisode.maximumAttempts {
            XCTAssertTrue(episode.reserveAttempt(at: now.advanced(by: .seconds(index))))
            let stream = CaptureLifecycleTestStream()
            let start = try lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in
                trace.append("start"); throw CaptureLifecycleTestError.start
            })
            do { try await start.value; XCTFail("Expected native start failure") }
            catch { XCTAssertEqual(error as? CaptureLifecycleTestError, .start) }
            XCTAssertFalse(lifecycle.withRunningOwner(owner) { _ in XCTFail("A failed attempt has no readiness") })
            XCTAssertEqual(episode.id, id); XCTAssertEqual(episode.deadline, deadline)
        }
        XCTAssertFalse(episode.reserveAttempt(at: now.advanced(by: .seconds(6))))
        XCTAssertEqual(episode.failure(at: now.advanced(by: .seconds(6))), .attemptsExhausted)
        await lifecycle.endOwner(owner).value
        XCTAssertEqual(trace.values, Array(repeating: ["start", "stop"], count: CaptureRecoveryEpisode.maximumAttempts).flatMap { $0 },
                       "Each retry must join the previous native cleanup before the next start")
    }

    func test_captureStatusDistinguishesIdleFromLossAndRejectsMalformedValues() {
        let known: [(SCFrameStatus, CaptureVideoStatus)] = [
            (.complete, .complete), (.idle, .idle), (.started, .started),
            (.blank, .blank), (.suspended, .suspended), (.stopped, .stopped)
        ]
        for (native, expected) in known {
            XCTAssertEqual(CaptureVideoStatus.read(NSNumber(value: native.rawValue)), expected)
        }
        let invalid: [Any?] = [nil, true, false, "0", NSNumber(value: 0.5), NSNumber(value: -1), NSNumber(value: 999)]
        for value in invalid { XCTAssertEqual(CaptureVideoStatus.read(value), .invalid) }
    }

    func test_captureStatusOnlySamplesDoNotNeedReadyPixelsOrADisplayClock() throws {
        for status in [SCFrameStatus.blank, .suspended, .idle, .started, .stopped] {
            let sample = try captureSample(status: NSNumber(value: status.rawValue), displayTime: nil, dataReady: false)
            XCTAssertEqual(CaptureVideoStatus.read(sampleBuffer: sample), CaptureVideoStatus.read(NSNumber(value: status.rawValue)))
            XCTAssertNil(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        }
        XCTAssertEqual(CaptureVideoStatus.read(sampleBuffer: try captureSample(status: nil)), .invalid)
        let invalid = try captureSample()
        XCTAssertEqual(CMSampleBufferInvalidate(invalid), noErr)
        XCTAssertEqual(CaptureVideoStatus.read(sampleBuffer: invalid), .invalid)
    }

    func test_captureStartedDoesNotAuthorizeInitialOutputAndWithdrawsAnEstablishedImage() {
        var availability = CaptureVideoAvailability()
        let attempt = CaptureAttemptLease()
        XCTAssertFalse(availability.recordStarted(from: attempt, observedAtHostTime: displayTicks(seconds: 40)))
        XCTAssertFalse(availability.isAvailable(for: attempt))
        availability.recordDeliveredFrame(from: attempt)
        XCTAssertTrue(availability.isAvailable(for: attempt))
        XCTAssertTrue(availability.recordStarted(from: attempt, observedAtHostTime: displayTicks(seconds: 41)))
        XCTAssertFalse(availability.isAvailable(for: attempt))
        XCTAssertFalse(availability.recordStarted(from: attempt, observedAtHostTime: displayTicks(seconds: 42)))
    }

    func test_captureLossRejectsQueuedFramesAtOrBeforeItsObservationBoundary() throws {
        let attempt = CaptureAttemptLease()
        var availability = CaptureVideoAvailability()
        availability.recordDeliveredFrame(from: attempt)
        XCTAssertTrue(availability.recordUnavailable(from: attempt, observedAtHostTime: displayTicks(seconds: 42)))
        XCTAssertFalse(availability.isAvailable(for: attempt))
        for seconds in [Int64(41), 42] {
            let queued = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: seconds)))
            XCTAssertFalse(availability.permits(queued))
        }
        let fresh = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))
        XCTAssertTrue(availability.permits(fresh))
        XCTAssertFalse(availability.isAvailable(for: attempt), "Permission to admit a candidate is not delivery")
        availability.recordDeliveredFrame(from: attempt)
        XCTAssertTrue(availability.isAvailable(for: attempt))
    }

    func test_captureRepeatedLossDeduplicatesNotificationButAdvancesTheClockBoundary() throws {
        let attempt = CaptureAttemptLease()
        var availability = CaptureVideoAvailability()
        availability.recordDeliveredFrame(from: attempt)
        XCTAssertTrue(availability.recordUnavailable(from: attempt, observedAtHostTime: displayTicks(seconds: 41)))
        XCTAssertFalse(availability.recordUnavailable(from: attempt, observedAtHostTime: displayTicks(seconds: 42)))
        XCTAssertFalse(availability.recordUnavailable(from: attempt, observedAtHostTime: displayTicks(seconds: 40)))
        XCTAssertFalse(availability.permits(try XCTUnwrap(frameMetadata())))
        XCTAssertTrue(availability.permits(try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))))
        availability.recordDeliveredFrame(from: attempt)
        XCTAssertTrue(availability.recordUnavailable(from: attempt, observedAtHostTime: displayTicks(seconds: 43)),
                      "A later interruption must notify again after actual delivery")
    }

    func test_captureReplacementCannotReuseAvailabilityOrEraseTheLossClockBoundary() throws {
        let old = CaptureAttemptLease(), replacement = CaptureAttemptLease()
        var availability = CaptureVideoAvailability()
        availability.recordDeliveredFrame(from: old)
        XCTAssertFalse(availability.isAvailable(for: replacement))
        XCTAssertTrue(availability.recordUnavailable(from: old, observedAtHostTime: displayTicks(seconds: 42)))
        XCTAssertFalse(availability.recordStarted(from: replacement, observedAtHostTime: displayTicks(seconds: 43)))
        XCTAssertFalse(availability.isAvailable(for: old)); XCTAssertFalse(availability.isAvailable(for: replacement))
        XCTAssertFalse(availability.permits(try XCTUnwrap(frameMetadata())))
        XCTAssertTrue(availability.permits(try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))))
        availability.recordDeliveredFrame(from: replacement)
        XCTAssertFalse(availability.isAvailable(for: old)); XCTAssertTrue(availability.isAvailable(for: replacement))
    }

    func test_captureContinuingStreamRecoveryNeedsNoRestartAndKeepsItsOriginalDeadline() {
        let now = ContinuousClock.now
        let continuing = CaptureAttemptLease(), replacement = CaptureAttemptLease()
        var episode = CaptureRecoveryEpisode(now: now, waitingForOutputFrom: continuing)
        let id = episode.id, deadline = episode.deadline
        XCTAssertEqual(episode.attempts, 0)
        XCTAssertFalse(episode.acceptsFrame(lastOutput: nil, running: continuing, at: now))
        XCTAssertTrue(episode.acceptsFrame(lastOutput: continuing, running: continuing, at: now))
        XCTAssertFalse(episode.acceptsFrame(lastOutput: replacement, running: replacement, at: now))
        XCTAssertTrue(episode.reserveAttempt(at: now.advanced(by: .seconds(2))))
        XCTAssertTrue(episode.acceptsFrame(lastOutput: replacement, running: replacement, at: now.advanced(by: .seconds(3))))
        XCTAssertFalse(episode.acceptsFrame(lastOutput: continuing, running: continuing, at: deadline))
        XCTAssertFalse(episode.acceptsFrame(lastOutput: replacement, running: replacement, at: deadline))
        XCTAssertEqual(episode.id, id); XCTAssertEqual(episode.deadline, deadline)
    }

    func test_captureReportedOutputStopUsesBoundedRecoveryWithoutMisclassifyingOtherErrors() {
        XCTAssertTrue(ScreenCapture.isRecoverableStop(ScreenCapture.CaptureError.outputStopped))
        XCTAssertTrue(ScreenCapture.isRecoverableStop(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3821)))
        XCTAssertFalse(ScreenCapture.isRecoverableStop(ScreenCapture.CaptureError.noDisplay))
        XCTAssertFalse(ScreenCapture.isRecoverableStop(NSError(domain: "unrelated", code: -3821)))
        XCTAssertFalse(ScreenCapture.isRecoverableStop(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3808)))
    }

    func test_captureRunningStreamCannotRestoreFromItsRememberedFrameDuringOutputLoss() async throws {
        // Composition fixture: fake native lifecycle and source availability.
        // This does not execute HostPeerSession, SCStream or a remote renderer.
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let stream = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: "peer")
        try await lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in }).value
        defer { Task { await lifecycle.endAll().value } }
        var availability = CaptureVideoAvailability()
        var remembered: CaptureAttemptLease?
        lifecycle.withStream(stream) { _, attempt in
            remembered = attempt
            availability.recordDeliveredFrame(from: attempt)
        }
        let rememberedAttempt = try XCTUnwrap(remembered)
        let episode = CaptureRecoveryEpisode(now: ContinuousClock.now, waitingForOutputFrom: rememberedAttempt)
        lifecycle.withStream(stream) { _, attempt in
            XCTAssertTrue(availability.recordUnavailable(from: attempt, observedAtHostTime: displayTicks(seconds: 42)))
        }
        XCTAssertTrue(lifecycle.withRunningOwner(owner) { running in
            XCTAssertEqual(running, remembered, "The native stream and cached identity are unchanged")
            XCTAssertTrue(episode.acceptsFrame(lastOutput: remembered, running: running, at: ContinuousClock.now))
            XCTAssertFalse(availability.isAvailable(for: running), "Running identity alone must not reopen input")
        })
        let old = try XCTUnwrap(frameMetadata())
        let fresh = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))
        lifecycle.withStream(stream) { _, attempt in
            XCTAssertFalse(availability.permits(old))
            XCTAssertTrue(availability.permits(fresh))
            availability.recordDeliveredFrame(from: attempt)
        }
        XCTAssertTrue(lifecycle.withRunningOwner(owner) { running in XCTAssertTrue(availability.isAvailable(for: running)) })
        await lifecycle.endAll().value
    }

    func test_captureRecoveryCapsAttemptsWithoutResettingItsOriginalDeadline() {
        let start = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: start)
        let id = episode.id, deadline = episode.deadline
        let expectedDelays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5)]
        for index in 0..<5 {
            let now = start.advanced(by: .seconds(index))
            XCTAssertTrue(episode.reserveAttempt(at: now))
            XCTAssertEqual(episode.attempts, index + 1)
            XCTAssertEqual(episode.id, id)
            XCTAssertEqual(episode.deadline, deadline)
            XCTAssertEqual(episode.retryDelay(at: now), index < 4 ? expectedDelays[index] : nil)
        }
        XCTAssertFalse(episode.reserveAttempt(at: start.advanced(by: .seconds(6))))
        XCTAssertEqual(episode.attempts, 5)
        XCTAssertEqual(episode.failure(at: start.advanced(by: .seconds(6))), .attemptsExhausted)
    }

    func test_captureRecoveryDeadlineRejectsNewAttemptsAndLateSuccessAtItsExactBoundary() {
        let start = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: start)
        let stream = CaptureAttemptLease()
        XCTAssertTrue(episode.reserveAttempt(at: start))
        XCTAssertTrue(episode.acceptsFrame(lastOutput: stream, running: stream,
            at: episode.deadline.advanced(by: .nanoseconds(-1))))
        for now in [episode.deadline, episode.deadline.advanced(by: .seconds(1))] {
            XCTAssertFalse(episode.reserveAttempt(at: now))
            XCTAssertNil(episode.retryDelay(at: now))
            XCTAssertFalse(episode.acceptsFrame(lastOutput: stream, running: stream, at: now))
            XCTAssertEqual(episode.failure(at: now), .timedOut)
        }
        XCTAssertEqual(episode.attempts, 1, "Time exhaustion must not be reported as five failed starts")
    }

    func test_captureRecoveryRetryWaitCannotExtendTheDeadline() {
        let start = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: start)
        XCTAssertNil(episode.retryDelay(at: start), "No delay before the first attempt")
        XCTAssertTrue(episode.reserveAttempt(at: start))
        let nearDeadline = episode.deadline.advanced(by: .milliseconds(-20))
        XCTAssertEqual(episode.retryDelay(at: nearDeadline), .milliseconds(20))
        XCTAssertTrue(episode.reserveAttempt(at: nearDeadline))
        XCTAssertEqual(episode.retryDelay(at: nearDeadline), .milliseconds(20))
        XCTAssertEqual(episode.deadline, start.advanced(by: .seconds(30)))
    }

    func test_captureRecoveryNeedsOutputFromTheCurrentRunningAttempt() {
        let now = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: now)
        let old = CaptureAttemptLease(), current = CaptureAttemptLease()
        XCTAssertFalse(episode.acceptsFrame(lastOutput: current, running: current, at: now), "No recovery attempt has started")
        XCTAssertTrue(episode.reserveAttempt(at: now))
        XCTAssertFalse(episode.acceptsFrame(lastOutput: nil, running: current, at: now), "Native startup alone is insufficient")
        XCTAssertFalse(episode.acceptsFrame(lastOutput: old, running: current, at: now), "Old output cannot satisfy a replacement")
        XCTAssertTrue(episode.acceptsFrame(lastOutput: current, running: current, at: now))
        XCTAssertNil(episode.failure(at: now))
    }

    func test_captureRecoveryLastAttemptCanDeliverAFrameButCannotStartAnotherAttempt() {
        let now = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: now)
        for _ in 0..<5 { XCTAssertTrue(episode.reserveAttempt(at: now)) }
        let current = CaptureAttemptLease()
        XCTAssertTrue(episode.acceptsFrame(lastOutput: current, running: current, at: now),
                      "The fifth admitted start may still produce its first frame before the deadline")
        XCTAssertFalse(episode.reserveAttempt(at: now))
        XCTAssertNil(episode.retryDelay(at: now))
    }

    func test_captureRecoveryNewEpisodeDoesNotReuseAnEarlierDeadlineOrIdentity() {
        let start = ContinuousClock.now
        var old = CaptureRecoveryEpisode(now: start)
        for _ in 0..<5 { XCTAssertTrue(old.reserveAttempt(at: start)) }
        let next = CaptureRecoveryEpisode(now: start.advanced(by: .seconds(40)))
        XCTAssertNotEqual(next.id, old.id)
        XCTAssertGreaterThan(next.deadline, old.deadline)
        XCTAssertEqual(next.attempts, 0)
        XCTAssertEqual(old.attempts, 5)
    }

    func test_captureRecoveryRunningIdentityMatchesEarlyOutputAndChangesWithReplacement() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let early = expectation(description: "early output recorded")
        let release = CaptureLifecycleTestLatch()
        let owner = lifecycle.beginOwner(context: "peer")
        let start = try lifecycle.start(for: owner, prepare: { old }, startStream: { _ in
            early.fulfill(); await release.wait()
        })
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        await fulfillment(of: [early], timeout: 2)
        var output: CaptureAttemptLease?
        lifecycle.withStream(old) { _, attempt in output = attempt }
        XCTAssertFalse(lifecycle.withRunningOwner(owner) { _ in XCTFail("Still starting") })
        await release.open(); try await start.value
        let now = ContinuousClock.now
        var episode = CaptureRecoveryEpisode(now: now)
        XCTAssertTrue(episode.reserveAttempt(at: now))
        XCTAssertTrue(lifecycle.withRunningOwner(owner) { running in
            XCTAssertTrue(episode.acceptsFrame(lastOutput: output, running: running, at: now))
        })
        let successor = lifecycle.beginOwner(context: "replacement")
        try await lifecycle.start(for: successor, prepare: { next }, startStream: { _ in }).value
        XCTAssertTrue(lifecycle.withRunningOwner(successor) { running in
            XCTAssertFalse(episode.acceptsFrame(lastOutput: output, running: running, at: now))
        })
        await lifecycle.endAll().value
    }

    func test_captureLifecycleJoinsPreparationAndAdmitsEarlyNativeFrames() async throws {
        let trace = CaptureLifecycleTrace()
        let stream = CaptureLifecycleTestStream()
        let startEntered = expectation(description: "native start entered")
        let releaseStart = CaptureLifecycleTestLatch()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in trace.append("stop") }
        let owner = lifecycle.beginOwner(context: "peer")
        defer { Task { await releaseStart.open(); await lifecycle.endAll().value } }
        let first = try lifecycle.start(for: owner, prepare: {
            trace.append("prepare"); return stream
        }, startStream: { _ in
            startEntered.fulfill()
            await releaseStart.wait()
        })
        let second = try lifecycle.start(for: owner, prepare: {
            trace.append("unexpected preparation"); return stream
        }, startStream: { _ in trace.append("unexpected start") })
        await fulfillment(of: [startEntered], timeout: 2)
        XCTAssertFalse(lifecycle.isRunning(for: owner))
        XCTAssertTrue(lifecycle.withStream(stream) { context, _ in trace.append("early frame for " + context) })
        await releaseStart.open()
        try await first.value
        try await second.value
        XCTAssertTrue(lifecycle.isRunning(for: owner))
        XCTAssertEqual(trace.values, ["prepare", "early frame for peer"])
        await lifecycle.endOwner(owner).value
        XCTAssertEqual(trace.values.last, "stop")
    }

    func test_captureLifecycleStopDuringPreparationJoinsAndCleansItsPreparedStream() async throws {
        try await exerciseCaptureRetirement(duringPreparation: true)
    }

    func test_captureLifecycleStopDuringNativeStartJoinsBeforeStoppingOrReplacing() async throws {
        try await exerciseCaptureRetirement(duringPreparation: false)
    }

    private func exerciseCaptureRetirement(duringPreparation: Bool) async throws {
        let trace = CaptureLifecycleTrace()
        let old = CaptureLifecycleTestStream()
        let next = CaptureLifecycleTestStream()
        let nativeEntered = expectation(description: "suspended native operation")
        let stopEntered = expectation(description: "old native stop")
        let releaseNative = CaptureLifecycleTestLatch()
        let releaseStop = CaptureLifecycleTestLatch()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { stream in
            if stream === old {
                trace.append("old stop entered")
                stopEntered.fulfill()
                await releaseStop.wait()
                trace.append("old stop finished")
            }
        }
        defer { Task { await releaseNative.open(); await releaseStop.open(); await lifecycle.endAll().value } }
        let owner = lifecycle.beginOwner(context: "old")
        let oldStart = try lifecycle.start(for: owner, prepare: {
            if duringPreparation { nativeEntered.fulfill(); await releaseNative.wait() }
            return old
        }, startStream: { _ in
            trace.append("old start entered")
            if !duringPreparation { nativeEntered.fulfill(); await releaseNative.wait() }
        })
        await fulfillment(of: [nativeEntered], timeout: 2)
        let teardown = lifecycle.endOwner(owner)
        XCTAssertFalse(lifecycle.withStream(old) { _, _ in XCTFail("Retired media was delivered") })
        XCTAssertThrowsError(try lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }))
        let successor = lifecycle.beginOwner(context: "next")
        let nextStart = try lifecycle.start(for: successor, prepare: {
            trace.append("next preparation"); return next
        }, startStream: { _ in trace.append("next start") })
        await releaseNative.open()
        await fulfillment(of: [stopEntered], timeout: 2)
        XCTAssertFalse(trace.values.contains("next preparation"), "Native teardown is still pending")
        XCTAssertEqual(trace.values.contains("old start entered"), !duringPreparation)
        await releaseStop.open()
        await teardown.value
        do { try await oldStart.value; XCTFail("Retired startup reported success") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await nextStart.value
        XCTAssertEqual(Array(trace.values.suffix(3)), ["old stop finished", "next preparation", "next start"])
        // An old close arriving after replacement must leave it running.
        await lifecycle.endOwner(owner).value
        XCTAssertTrue(lifecycle.isRunning(for: successor))
        await lifecycle.endOwner(successor).value
    }

    func test_captureLifecycleOldOwnerCloseDoesNotWaitForSuccessorTeardown() async throws {
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let nextStopping = expectation(description: "successor stop entered")
        let oldClosed = expectation(description: "old owner close returned")
        let release = CaptureLifecycleTestLatch()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { stream in
            if stream === next { nextStopping.fulfill(); await release.wait() }
        }
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        let owner = lifecycle.beginOwner(context: "old")
        try await lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }).value
        let successor = lifecycle.beginOwner(context: "next")
        try await lifecycle.start(for: successor, prepare: { next }, startStream: { _ in }).value
        let nextTeardown = lifecycle.endOwner(successor)
        await fulfillment(of: [nextStopping], timeout: 2)
        let lateClose = Task {
            await lifecycle.endOwner(owner).value
            oldClosed.fulfill()
        }
        await fulfillment(of: [oldClosed], timeout: 2)
        await release.open()
        await nextTeardown.value
        await lateClose.value
    }

    func test_captureLifecycleForeignFramesCannotAdvanceTheCurrentFrameBoundary() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: "old")
        try await lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }).value
        let successor = lifecycle.beginOwner(context: "next")
        try await lifecycle.start(for: successor, prepare: { next }, startStream: { _ in }).value
        var order = CaptureVideoFrameOrder()
        let oldQueued = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))
        let current = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 42)))
        XCTAssertFalse(lifecycle.withStream(old) { _, _ in _ = order.admit(oldQueued) })
        XCTAssertTrue(lifecycle.withStream(next) { context, _ in
            XCTAssertEqual(context, "next")
            XCTAssertTrue(order.admit(current), "Retired output cannot poison the accepted boundary")
        })
        XCTAssertFalse(lifecycle.streamStopped(old) { _, _ in XCTFail("Old failure reached successor") })
        XCTAssertTrue(lifecycle.isRunning(for: successor))
        await lifecycle.endAll().value
    }

    func test_captureLifecycleUnexpectedStopRetiresBeforeNotifyingAndIssuesOneReceipt() async throws {
        let trace = CaptureLifecycleTrace()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in trace.append("native stop") }
        let stream = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: "peer")
        try await lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in }).value
        var receipt: CaptureStopReceipt?
        XCTAssertTrue(lifecycle.streamStopped(stream) { context, event in
            XCTAssertEqual(context, "peer")
            XCTAssertFalse(lifecycle.isRunning(for: owner))
            XCTAssertFalse(lifecycle.withStream(stream) { _, _ in XCTFail("Admission must retire first") })
            receipt = event
        })
        let event = try XCTUnwrap(receipt)
        XCTAssertTrue(lifecycle.consumeStop(event) { trace.append("consumed") })
        XCTAssertFalse(lifecycle.consumeStop(event) { trace.append("duplicate consumption") })
        XCTAssertFalse(lifecycle.streamStopped(stream) { _, _ in XCTFail("Duplicate stop was delivered") })
        await lifecycle.endAll().value
        XCTAssertEqual(trace.values.filter { $0 == "native stop" }.count, 1)
        XCTAssertEqual(trace.values.filter { $0 == "consumed" }.count, 1)
        XCTAssertFalse(trace.values.contains("duplicate consumption"))
    }

    func test_captureLifecycleNewAttemptAndOwnerInvalidateDeferredStopReceipts() async throws {
        for replaceOwner in [false, true] {
            let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
            let stream = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
            let owner = lifecycle.beginOwner(context: "old")
            try await lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in }).value
            var receipt: CaptureStopReceipt?
            lifecycle.streamStopped(stream) { _, value in receipt = value }
            let successor = replaceOwner ? lifecycle.beginOwner(context: "next") : owner
            let nextStart = try lifecycle.start(for: successor, prepare: { next }, startStream: { _ in })
            XCTAssertFalse(lifecycle.consumeStop(try XCTUnwrap(receipt)) { XCTFail("Deferred failure was still authoritative") })
            try await nextStart.value
            XCTAssertTrue(lifecycle.isRunning(for: successor))
            await lifecycle.endAll().value
        }
    }

    func test_captureLifecycleLateStartupFailureCannotRetireItsSuccessor() async throws {
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let entered = expectation(description: "old start entered")
        let release = CaptureLifecycleTestLatch()
        let trace = CaptureLifecycleTrace()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { stream in
            trace.append(stream === old ? "old stop" : "next stop")
        }
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        let owner = lifecycle.beginOwner(context: "old")
        let oldStart = try lifecycle.start(for: owner, prepare: { old }, startStream: { _ in
            entered.fulfill(); await release.wait(); throw CaptureLifecycleTestError.start
        })
        await fulfillment(of: [entered], timeout: 2)
        let successor = lifecycle.beginOwner(context: "next")
        let nextStart = try lifecycle.start(for: successor, prepare: { next }, startStream: { _ in })
        await release.open()
        do { try await oldStart.value; XCTFail("Expected startup failure") }
        catch { XCTAssertEqual(error as? CaptureLifecycleTestError, .start) }
        try await nextStart.value
        XCTAssertTrue(lifecycle.isRunning(for: successor))
        XCTAssertFalse(lifecycle.streamStopped(old) { _, _ in XCTFail("Retired error was delivered") })
        XCTAssertEqual(trace.values, ["old stop"])
        await lifecycle.endAll().value
    }

    func test_captureLifecycleReentrantConsumerCanRetireWithoutReclaimingReplacement() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: "old")
        try await lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }).value
        var successor: CaptureOwnerLease?
        XCTAssertTrue(lifecycle.withStream(old) { _, _ in
            _ = lifecycle.endOwner(owner)
            successor = lifecycle.beginOwner(context: "next")
            XCTAssertFalse(lifecycle.withStream(old) { _, _ in XCTFail("Recursive retired admission") })
        })
        let replacement = try XCTUnwrap(successor)
        try await lifecycle.start(for: replacement, prepare: { next }, startStream: { _ in }).value
        await lifecycle.endOwner(owner).value
        XCTAssertTrue(lifecycle.isRunning(for: replacement))
        await lifecycle.endAll().value
    }

    func test_captureLifecycleRetirementWaitsForTheSynchronousMediaConsumer() async throws {
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in }
        let stream = CaptureLifecycleTestStream()
        let owner = lifecycle.beginOwner(context: "peer")
        try await lifecycle.start(for: owner, prepare: { stream }, startStream: { _ in }).value
        let trace = CaptureLifecycleTrace()
        let entered = expectation(description: "consumer entered")
        let retiring = expectation(description: "retirement requested")
        let retired = expectation(description: "retirement returned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); Task { await lifecycle.endAll().value } }
        DispatchQueue.global().async {
            lifecycle.withStream(stream) { _, _ in
                trace.append("consumer entered")
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                trace.append("consumer finished")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        DispatchQueue.global().async {
            retiring.fulfill()
            _ = lifecycle.endOwner(owner)
            trace.append("retirement returned")
            retired.fulfill()
        }
        await fulfillment(of: [retiring], timeout: 2)
        release.signal()
        await fulfillment(of: [retired], timeout: 2)
        XCTAssertEqual(trace.values, ["consumer entered", "consumer finished", "retirement returned"])
        XCTAssertFalse(lifecycle.withStream(stream) { _, _ in XCTFail("Media escaped retirement") })
        await lifecycle.endAll().value
    }

    func test_captureLifecycleFailedStartCleansBeforeRetryingTheSameOwner() async throws {
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let entered = expectation(description: "failed startup cleanup")
        let release = CaptureLifecycleTestLatch()
        let trace = CaptureLifecycleTrace()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { stream in
            if stream === old {
                entered.fulfill(); await release.wait(); trace.append("old cleanup finished")
            }
        }
        defer { Task { await release.open(); await lifecycle.endAll().value } }
        let owner = lifecycle.beginOwner(context: "peer")
        let failed = try lifecycle.start(for: owner, prepare: { old }, startStream: { _ in throw CaptureLifecycleTestError.start })
        do { try await failed.value; XCTFail("Expected startup failure") }
        catch { XCTAssertEqual(error as? CaptureLifecycleTestError, .start) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(lifecycle.withStream(old) { _, _ in XCTFail("Failed start still admitted media") })
        let retry = try lifecycle.start(for: owner, prepare: {
            trace.append("next preparation"); return next
        }, startStream: { _ in })
        XCTAssertEqual(trace.values, [])
        await release.open()
        try await retry.value
        XCTAssertEqual(trace.values, ["old cleanup finished", "next preparation"])
        XCTAssertTrue(lifecycle.isRunning(for: owner))
        await lifecycle.endAll().value
    }

    func test_captureLifecycleFailedNativeStopBlocksReplacementPreparation() async throws {
        let trace = CaptureLifecycleTrace()
        let old = CaptureLifecycleTestStream(), next = CaptureLifecycleTestStream()
        let lifecycle = CaptureStreamLifecycle<CaptureLifecycleTestStream, String> { _ in
            trace.append("failed stop"); throw CaptureLifecycleTestError.stop
        }
        let owner = lifecycle.beginOwner(context: "old")
        try await lifecycle.start(for: owner, prepare: { old }, startStream: { _ in }).value
        await lifecycle.endOwner(owner).value
        let successor = lifecycle.beginOwner(context: "next")
        let nextStart = try lifecycle.start(for: successor, prepare: {
            trace.append("unexpected preparation"); return next
        }, startStream: { _ in trace.append("unexpected start") })
        do { try await nextStart.value; XCTFail("A failed stop is not a resource barrier") }
        catch {
            let failure = try XCTUnwrap(error as? CaptureStreamTeardownFailure)
            XCTAssertEqual(failure.underlying as? CaptureLifecycleTestError, .stop)
        }
        XCTAssertFalse(lifecycle.isRunning(for: successor))
        XCTAssertFalse(lifecycle.withStream(old) { _, _ in XCTFail("Failed cleanup reopened retired input") })
        await lifecycle.endAll().value
        XCTAssertEqual(trace.values, ["failed stop"])
    }

    func test_captureFrameMetadataRequiresCompleteStatus() {
        for status: Int? in [nil, -1, SCFrameStatus.idle.rawValue, SCFrameStatus.blank.rawValue,
                            SCFrameStatus.started.rawValue, SCFrameStatus.suspended.rawValue, SCFrameStatus.stopped.rawValue] {
            XCTAssertNil(frameMetadata(status: status))
        }
        XCTAssertNotNil(frameMetadata())
    }

    func test_captureFrameMetadataUsesDisplayClockAndPreservesIntegerMediaTime() throws {
        let exact: Int64 = 9_000_000_000_000_001
        let metadata = try XCTUnwrap(frameMetadata(presentationTime: CMTime(value: exact, timescale: 1_000_000_000)))
        XCTAssertEqual(metadata.captureTimeNanoseconds, 42_000_000_000)
        XCTAssertEqual(metadata.presentationTimeNanoseconds, exact, "Do not round through Double seconds")
        XCTAssertEqual(metadata.displayTimeHostTicks, displayTicks(seconds: 42))
        XCTAssertEqual(metadata.width, 800); XCTAssertEqual(metadata.height, 600)
        let third = try XCTUnwrap(frameMetadata(presentationTime: CMTime(value: 1, timescale: 3)))
        XCTAssertEqual(third.presentationTimeNanoseconds, 333_333_333)
        XCTAssertEqual(third.captureTimeNanoseconds, metadata.captureTimeNanoseconds, "Media PTS is not WindowServer display time")
    }

    func test_captureFrameMetadataDoesNotUseInvalidOrForeignEpochMediaTimeAsCaptureEvidence() throws {
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                     CMTime(value: -1, timescale: 1), CMTime(value: 1, timescale: 0),
                     CMTime(value: Int64.max, timescale: 1),
                     CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1)] {
            let metadata = try XCTUnwrap(frameMetadata(presentationTime: time))
            XCTAssertNil(metadata.presentationTimeNanoseconds)
            XCTAssertEqual(metadata.captureTimeNanoseconds, 42_000_000_000,
                           "Valid WindowServer timing does not depend on optional media timing")
        }
    }

    func test_captureFrameMetadataRejectsMissingZeroFutureDisplayTimeAndEmptyDimensions() {
        XCTAssertNil(frameMetadata(displayTime: nil))
        XCTAssertNil(frameMetadata(displayTime: 0))
        XCTAssertNil(frameMetadata(displayTime: displayTicks(seconds: 44)))
        XCTAssertNil(frameMetadata(width: 0))
        XCTAssertNil(frameMetadata(height: -1))
        XCTAssertNotNil(frameMetadata(displayTime: displayTicks(seconds: 43)), "The observation boundary itself is permitted")
    }

    func test_captureFrameOrderRejectsDuplicatesAndRegressionsWithoutAdvancingItsBoundary() throws {
        var order = CaptureVideoFrameOrder()
        let first = try XCTUnwrap(frameMetadata())
        let older = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 41)))
        let next = try XCTUnwrap(frameMetadata(displayTime: displayTicks(seconds: 43)))
        XCTAssertTrue(order.admit(first))
        XCTAssertFalse(order.admit(first))
        XCTAssertFalse(order.admit(older))
        let sameNanosecond = CaptureVideoFrameMetadata(displayTimeHostTicks: first.displayTimeHostTicks + 1,
            captureTimeNanoseconds: first.captureTimeNanoseconds, presentationTimeNanoseconds: 0, width: 800, height: 600)
        XCTAssertFalse(order.admit(sameNanosecond))
        XCTAssertTrue(order.admit(next))
        XCTAssertFalse(order.admit(first))
    }

    func test_capturedVideoFrameRetainsTheCompleteSampleBufferAndItsClockEvidence() throws {
        let sample = try captureSample()
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let frame = try XCTUnwrap(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        XCTAssertTrue(frame.imageBuffer === image)
        XCTAssertEqual(frame.metadata.width, 2); XCTAssertEqual(frame.metadata.height, 2)
        XCTAssertEqual(frame.metadata.captureTimeNanoseconds, 42_000_000_000)
        XCTAssertEqual(frame.metadata.presentationTimeNanoseconds, 3_500_000_000)
    }

    func test_capturedVideoFrameRejectsAbsentMalformedAndIncompleteAttachments() throws {
        let malformed: [(Any?, Any?)] = [
            (nil, NSNumber(value: displayTicks(seconds: 42))),
            (NSNumber(value: SCFrameStatus.complete.rawValue), nil),
            (NSNumber(value: false), NSNumber(value: displayTicks(seconds: 42))),
            (NSNumber(value: SCFrameStatus.complete.rawValue), NSNumber(value: true)),
            (NSNumber(value: 0.5), NSNumber(value: displayTicks(seconds: 42))),
            (NSNumber(value: SCFrameStatus.complete.rawValue), NSNumber(value: 5.5)),
            (NSNumber(value: SCFrameStatus.idle.rawValue), NSNumber(value: displayTicks(seconds: 42))),
        ]
        for (status, time) in malformed {
            let sample = try captureSample(status: status, displayTime: time)
            XCTAssertNil(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 43)))
        }
        let sample = try captureSample()
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: sample, observedAtHostTime: displayTicks(seconds: 41)))
    }

    func test_capturedVideoFrameRejectsInvalidAndNotReadyBuffers() throws {
        let pending = try captureSample(dataReady: false)
        XCTAssertTrue(pending.isValid); XCTAssertFalse(CMSampleBufferDataIsReady(pending))
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: pending, observedAtHostTime: displayTicks(seconds: 43)))
        let invalid = try captureSample()
        XCTAssertEqual(CMSampleBufferInvalidate(invalid), noErr)
        XCTAssertNil(CapturedVideoFrame(sampleBuffer: invalid, observedAtHostTime: displayTicks(seconds: 43)))
    }

    private func displayTicks(seconds: Int64) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(value: seconds, timescale: 1))
    }

    private func frameMetadata(status: Int? = SCFrameStatus.complete.rawValue,
                               displayTime: UInt64? = CMClockConvertHostTimeToSystemUnits(CMTime(value: 42, timescale: 1)),
                               presentationTime: CMTime = CMTime(value: 7, timescale: 2),
                               width: Int = 800, height: Int = 600) -> CaptureVideoFrameMetadata? {
        CaptureVideoFrameMetadata.read(status: status,
            displayTimeHostTicks: displayTime,
            presentationTime: presentationTime, width: width, height: height,
            observedAtHostTime: displayTicks(seconds: 43))
    }

    private func captureSample(status: Any? = NSNumber(value: SCFrameStatus.complete.rawValue),
                               displayTime: Any? = NSNumber(value: CMClockConvertHostTimeToSystemUnits(CMTime(value: 42, timescale: 1))),
                               dataReady: Bool = true) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(image)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 7, timescale: 2), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer, dataReady: dataReady, makeDataReadyCallback: nil, makeDataReadyRefcon: nil,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        let rows = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) as? [NSMutableDictionary])
        let row = try XCTUnwrap(rows.first)
        if let status { row[SCStreamFrameInfo.status.rawValue] = status }
        if let displayTime {
            row[SCStreamFrameInfo.displayTime.rawValue] = displayTime
        }
        for (key, value) in placementAttachments() { row[key.rawValue] = value }
        return result
    }

    func test_normalizedCaptureDimensions_leaveEvenSizesUntouched() {
        let normalized = CaptureSizing.normalized(width: 1728, height: 1116)

        XCTAssertEqual(normalized.width, 1728)
        XCTAssertEqual(normalized.height, 1116)
    }

    func test_normalizedCaptureDimensions_roundDownOddSizesForVideoToolbox() {
        let normalized = CaptureSizing.normalized(width: 1728, height: 1117)

        XCTAssertEqual(normalized.width, 1728)
        XCTAssertEqual(normalized.height, 1116,
                       "H.264/420f frames must use even dimensions or VideoToolbox will reject them")
    }

    func test_normalizedCaptureDimensions_neverDropsBelowTwoPixels() {
        let normalized = CaptureSizing.normalized(width: 1, height: 1)

        XCTAssertEqual(normalized.width, 2)
        XCTAssertEqual(normalized.height, 2)
    }

    func test_backingPixelSize_usesScreenCaptureKitPointScale() {
        let size = CaptureSizing.backingPixelSize(
            widthInPoints: 1728,
            heightInPoints: 1117,
            pointPixelScale: 2)

        XCTAssertEqual(size.width, 3456)
        XCTAssertEqual(size.height, 2234)
    }

    func test_encoderSafeCaptureDimensions_keepRetinaLaptopNativeAtPreferredQuality() {
        let sourceMacroblocks = CaptureSizing.macroblockCount(width: 3456, height: 2234)
        let safe = CaptureSizing.encoderSafe(
            width: 3456,
            height: 2234,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(sourceMacroblocks, 30_240)
        XCTAssertEqual(safe.width, 3456)
        XCTAssertEqual(safe.height, 2234)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height)
                * 16 * 16 * Int(CaptureSizing.targetFramesPerSecond),
            251_658_240,
            "H.264 level 5.1 permits 983,040 macroblocks per second")
    }

    func test_encoderSafeCaptureDimensions_fallBackForLevel31Peer() {
        let safe = CaptureSizing.encoderSafe(
            width: 3456,
            height: 2234,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 1188)
        XCTAssertEqual(safe.height, 768)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame)
    }

    func test_encoderSafeCaptureDimensions_leaveCompliantFramesUntouched() {
        let safe = CaptureSizing.encoderSafe(
            width: 1280,
            height: 720,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 1280)
        XCTAssertEqual(safe.height, 720)
        XCTAssertEqual(CaptureSizing.macroblockCount(width: 1280, height: 720), 3_600)
    }

    func test_encoderSafeCaptureDimensions_preservePortraitOrientation() {
        let safe = CaptureSizing.encoderSafe(
            width: 2160,
            height: 3840,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 2160)
        XCTAssertEqual(safe.height, 3840)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)
    }

    func test_encoderSafeCaptureDimensions_capOversizedDisplayAt4K() {
        let safe = CaptureSizing.encoderSafe(
            width: 5120,
            height: 2880,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.preferredH264MaximumMacroblocksPerFrame)

        XCTAssertEqual(safe.width, 3840)
        XCTAssertEqual(safe.height, 2160)
    }

    func test_encoderSafeCaptureDimensions_limitSoftwareCodecFallback() {
        let safe = CaptureSizing.encoderSafe(
            width: 3456,
            height: 2234,
            maximumMacroblocksPerFrame:
                DesktopVideoQuality.softwareCodecMaximumMacroblocksPerFrame)

        XCTAssertLessThan(safe.width, 3456)
        XCTAssertLessThan(safe.height, 2234)
        XCTAssertLessThanOrEqual(
            CaptureSizing.macroblockCount(width: safe.width, height: safe.height),
            DesktopVideoQuality.softwareCodecMaximumMacroblocksPerFrame)
    }

    func test_streamConfiguration_disablesAudioWhenMicrophoneIsNotGranted() {
        let configuration = ScreenCapture.streamConfiguration(
            width: 3456,
            height: 2234,
            audioEnabled: false)

        XCTAssertFalse(configuration.capturesAudio)
        XCTAssertEqual(configuration.width, 3456)
        XCTAssertEqual(configuration.height, 2234)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(configuration.queueDepth, DesktopVideoQuality.captureQueueDepth)
    }

    func test_streamConfiguration_enablesAudioOnlyForOptedInSession() {
        let configuration = ScreenCapture.streamConfiguration(
            width: 3456,
            height: 2234,
            audioEnabled: true)

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
    }

    func test_systemStoppedStreamError_isRecognizedAsRecoverableInterruption() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3821)

        XCTAssertTrue(ScreenCapture.isSystemStopped(error))
        XCTAssertFalse(ScreenCapture.isAlreadyStopped(error))
    }

    func test_alreadyStoppedStreamError_isNotSystemStopped() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3808)

        XCTAssertTrue(ScreenCapture.isAlreadyStopped(error))
        XCTAssertFalse(ScreenCapture.isSystemStopped(error))
    }

    func test_desktopVideoFactoriesAdvertiseHigherH264Level() throws {
        let encoderFactory = DesktopVideoEncoderFactory()
        let decoderFactory = DesktopVideoDecoderFactory()
        let encoderCodecs = encoderFactory.supportedCodecs()
        let decoderCodecs = decoderFactory.supportedCodecs()
        let encoderProfiles = encoderCodecs
            .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
            .compactMap { $0.parameters["profile-level-id"] }
        let decoderProfiles = decoderCodecs
            .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
            .compactMap { $0.parameters["profile-level-id"] }

        XCTAssertFalse(encoderProfiles.isEmpty)
        XCTAssertTrue(encoderProfiles.contains("640c33"))
        XCTAssertTrue(encoderProfiles.contains("42e01f"))
        XCTAssertEqual(decoderProfiles, encoderProfiles)

        let encoderCodec = try XCTUnwrap(encoderCodecs.first {
            $0.parameters["profile-level-id"] == "640c33"
        })
        let decoderCodec = try XCTUnwrap(decoderCodecs.first {
            $0.parameters["profile-level-id"] == "640c33"
        })
        XCTAssertNotNil(encoderFactory.createEncoder(encoderCodec))
        XCTAssertNotNil(decoderFactory.createDecoder(decoderCodec))
    }

    func test_h264LevelMappingRetainsLegacyAndRetinaLimits() {
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "1e"),
            1_620)
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "1f"),
            3_600)
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "2a"),
            8_704)
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(levelIDC: "33"),
            32_768)
    }

    func test_h264Level1bUsesTheFullRFC6184ProfileLevelID() {
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "42b00b"),
            99,
            "Baseline level 1b uses constraint_set3_flag with level_idc 11")
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "42a00b"),
            396,
            "Baseline level 1.1 has level_idc 11 without constraint_set3_flag")
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "640009"),
            99,
            "Other profiles signal level 1b with level_idc 9")
        XCTAssertEqual(
            DesktopVideoQuality.h264MaximumMacroblocksPerFrame(
                profileLevelID: "not-hex"),
            DesktopVideoQuality.fallbackH264MaximumMacroblocksPerFrame)
    }

    func test_senderPolicyPreservesResolutionAndClampsUnsafeRequests() {
        let policy = DesktopVideoQuality.senderPolicy(
            targetFramesPerSecond: 120,
            maximumBitrateKbps: 100_000,
            preference: "sharpness")

        XCTAssertEqual(policy.maximumFramesPerSecond, 30)
        XCTAssertEqual(policy.maximumBitrateBps, 30_000_000)
        XCTAssertEqual(policy.degradationPreference, .maintainResolution)
    }
}

private final class CaptureLifecycleTestStream: @unchecked Sendable {}
private enum CaptureLifecycleTestError: Error, Equatable { case start, stop }

private actor CaptureLifecycleTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class CaptureLifecycleTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(value)
    }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
