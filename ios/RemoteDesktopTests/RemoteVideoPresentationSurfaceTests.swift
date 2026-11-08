import XCTest
import CoreGraphics
import CoreVideo
import LiveKitWebRTC
import Metal
import QuartzCore
import UIKit
@testable import RemoteDesktop

@MainActor
final class RemoteVideoPresentationSurfaceTests: XCTestCase {
    #if DEBUG
    func testSkipRetryRequiresLabAdmissionStockRendererAndExactOptIn() {
        let enabled = ["LATENCY_LAB": "1", "LATENCY_SKIP_RETRY": "1"]
        XCTAssertTrue(RemoteVideoPresentationSurface.labSkipRetryEnabled(labAdmitted: true, f4: false, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.labSkipRetryEnabled(labAdmitted: false, f4: false, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.labSkipRetryEnabled(labAdmitted: true, f4: true, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.labSkipRetryEnabled(labAdmitted: true, f4: false, environment: [:]))
        XCTAssertFalse(RemoteVideoPresentationSurface.labSkipRetryEnabled(labAdmitted: true, f4: false, environment: ["LATENCY_SKIP_RETRY": "1"]))
        XCTAssertFalse(RemoteVideoPresentationSurface.labSkipRetryEnabled(labAdmitted: true, f4: false, environment: ["LATENCY_LAB": "1", "LATENCY_SKIP_RETRY": "true"]))
    }

    func testSkipRecoveryUsesGenuineContextAndOneSecondBoundary() {
        let a = UUID(), b = UUID()
        var recovery = RemoteVideoPresentationSurface.LabSkipRecovery()
        recovery.begin(context: a, time: 10)
        XCTAssertFalse(recovery.shouldWait(context: a, time: 10.999))
        XCTAssertTrue(recovery.shouldWait(context: a, time: 11))
        XCTAssertFalse(recovery.presented(context: b, time: 12))
        XCTAssertTrue(recovery.presented(context: a, time: 12))
        XCTAssertFalse(recovery.shouldWait(context: a, time: 12.999))
        XCTAssertTrue(recovery.shouldWait(context: a, time: 13))
        recovery.begin(context: b, time: 14)
        XCTAssertFalse(recovery.shouldWait(context: a, time: 99))
        XCTAssertFalse(recovery.shouldWait(context: b, time: 14.999))
        recovery.reset(); XCTAssertNil(recovery.deadline(context: b))
    }

    func testNonserialSkipSettlesWithoutLosingTicketAccounting() {
        var gate = RemoteVideoPresentationSurface.LabNonserialGate()
        let older = UUID(), newer = UUID()
        XCTAssertTrue(gate.submit(older)); XCTAssertTrue(gate.completedGPU(older, succeeded: true))
        XCTAssertTrue(gate.submit(newer)); XCTAssertEqual(gate.count, 2)
        XCTAssertEqual(gate.settle(older, result: .skipped), .skipped)
        XCTAssertEqual(gate.count, 1); XCTAssertNil(gate.settle(older, result: .skipped))
        XCTAssertTrue(gate.completedGPU(newer, succeeded: true)); XCTAssertEqual(gate.settle(newer, result: .failed), .retry)
    }

    func testSkipReceiptPreservesReadinessAndNewPresentationCancelsNotice() async throws {
        let old = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(old) }
        var config = old; config.f4Renderer = false; LatencyLabConfiguration.setRuntime(config)
        let host = try RemoteKeyboardTestWindow(); defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: true)); defer { surface.retire() }
        surface.labEnableSkipRetryForTesting()
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1)
        surface.labReceiveForTesting(.presented(CACurrentMediaTime()), frame: frame)
        let ready = surface.presentation.state
        surface.labReceiveForTesting(.skipped, frame: frame)
        XCTAssertEqual(surface.presentation.state, ready)
        XCTAssertTrue(surface.labNoticeScheduledForTesting)
        XCTAssertFalse(surface.labRetryScheduledForTesting)
        XCTAssertEqual(surface.labFailedAttemptsForTesting, 0)
        surface.labReceiveForTesting(.rendered(CACurrentMediaTime()), frame: frame)
        guard case .rendered = surface.presentation.state else { return XCTFail("Simulator rendered receipt must retain its existing readiness") }
        XCTAssertFalse(surface.labNoticeScheduledForTesting)
        surface.labReceiveForTesting(.skipped, frame: frame)
        XCTAssertTrue(surface.labNoticeScheduledForTesting)
        surface.labReceiveForTesting(.presented(CACurrentMediaTime()), frame: frame)
        XCTAssertFalse(surface.labNoticeScheduledForTesting)
        try await Task.sleep(for: .milliseconds(1100))
        guard case .presented = surface.presentation.state else { return XCTFail("Late notice replaced a newer presentation") }
    }

    func testSkipWaitsOnlyAfterOneSecondAndHideCancelsNotice() async throws {
        let old = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(old) }
        var config = old; config.f4Renderer = false; LatencyLabConfiguration.setRuntime(config)
        let host = try RemoteKeyboardTestWindow(); defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: true)); defer { surface.retire() }
        surface.labEnableSkipRetryForTesting()
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1)
        surface.labReceiveForTesting(.presented(CACurrentMediaTime()), frame: frame)
        surface.labReceiveForTesting(.skipped, frame: frame)
        try await Task.sleep(for: .milliseconds(500))
        guard case .presented = surface.presentation.state else { return XCTFail("Wait notice appeared too early") }
        try await Task.sleep(for: .milliseconds(700))
        guard case .waiting = surface.presentation.state else { return XCTFail("Wait notice did not appear") }
        surface.labReceiveForTesting(.presented(CACurrentMediaTime()), frame: frame)
        surface.labReceiveForTesting(.skipped, frame: frame)
        surface.view.isHidden = true
        XCTAssertFalse(surface.labNoticeScheduledForTesting)
        surface.retire()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(surface.presentation.state, .retired)
    }

    func testSkipDiscardsRetainedFrameButSchedulesNewestPendingFrame() throws {
        let old = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(old) }
        var config = old; config.f4Renderer = false; LatencyLabConfiguration.setRuntime(config)
        let host = try RemoteKeyboardTestWindow(); defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: true)); defer { surface.retire() }
        surface.labEnableSkipRetryForTesting(); surface.labSuppressAcquisitionForTesting = true
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1)
        let newer = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 2)
        surface.labReceiveForTesting(.skipped, frame: frame)
        XCTAssertFalse(surface.labPendingForTesting)
        surface.configure(mode: .aspectFit, viewport: CGRect(x: 1, y: 0, width: 63, height: 64))
        XCTAssertFalse(surface.labPendingForTesting, "A skipped image must not be transferred by a later layout")
        let before = surface.labRequestCountForTesting
        surface.labReceiveForTesting(.skipped, frame: frame, newer: newer)
        XCTAssertTrue(surface.labPendingForTesting)
        XCTAssertGreaterThan(surface.labRequestCountForTesting, before, "A newer decode must be scheduled immediately")
        surface.configure(mode: .aspectFit, viewport: CGRect(x: 2, y: 0, width: 62, height: 64))
        XCTAssertTrue(surface.labPendingForTesting, "The newer decode survives a continuous layout")
    }

    func testSkipKeepsExistingDeadlineAndRealFailuresRetainLimits() async throws {
        let old = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(old) }
        var config = old; config.f4Renderer = false; LatencyLabConfiguration.setRuntime(config)
        let host = try RemoteKeyboardTestWindow(); defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: true)); defer { surface.retire() }
        surface.labEnableSkipRetryForTesting(); surface.labSuppressAcquisitionForTesting = true
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1)
        surface.labReceiveForTesting(.presented(CACurrentMediaTime()), frame: frame)
        surface.labReceiveForTesting(.skipped, frame: frame)
        let deadline = try XCTUnwrap(surface.labDeadlineIDForTesting)
        surface.labReceiveForTesting(.skipped, frame: frame)
        XCTAssertEqual(surface.labDeadlineIDForTesting, deadline, "Skip must not replenish the five-second deadline")
        surface.labReceiveForTesting(.failed, frame: frame)
        XCTAssertEqual(surface.labFailedAttemptsForTesting, 1)
        XCTAssertTrue(surface.labRetryScheduledForTesting)
        XCTAssertFalse(surface.labNoticeScheduledForTesting)
        guard case .waiting = surface.presentation.state else { return XCTFail("A real failure must publish waiting") }
        XCTAssertEqual(surface.labDeadlineIDForTesting, deadline)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(surface.labRetryScheduledForTesting, "A real failure retains the 100 ms retry delay")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(surface.labRetryScheduledForTesting)
        for _ in 2...31 { surface.labReceiveForTesting(.failed, frame: frame) }
        guard case .failed = surface.presentation.state else { return XCTFail("The 31st real failure must exhaust the existing limit") }
    }

    func testSkipEpisodeStillExpiresAtFiveSecondDeadline() async throws {
        let old = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(old) }
        var config = old; config.f4Renderer = false; LatencyLabConfiguration.setRuntime(config)
        let host = try RemoteKeyboardTestWindow(); defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: true)); defer { surface.retire() }
        surface.labEnableSkipRetryForTesting(); surface.labSuppressAcquisitionForTesting = true
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1)
        surface.labReceiveForTesting(.presented(CACurrentMediaTime()), frame: frame)
        surface.labReceiveForTesting(.skipped, frame: frame)
        try await Task.sleep(for: .milliseconds(5100))
        guard case .failed = surface.presentation.state else { return XCTFail("The existing recovery deadline must remain active") }
    }

    func testLabNonserialRequiresExplicitLabAdmissionAndStockRenderer() {
        let enabled = ["LATENCY_LAB": "1", "LATENCY_GPU_PIPELINE": "1"]
        XCTAssertTrue(RemoteVideoPresentationSurface.labNonserialEnabled(labAdmitted: true, f4: false, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.labNonserialEnabled(labAdmitted: false, f4: false, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.labNonserialEnabled(labAdmitted: true, f4: true, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.labNonserialEnabled(labAdmitted: true, f4: false, environment: [:]))
        XCTAssertFalse(RemoteVideoPresentationSurface.labNonserialEnabled(labAdmitted: true, f4: false,
            environment: ["LATENCY_GPU_PIPELINE": "1"]))
        XCTAssertFalse(RemoteVideoPresentationSurface.labNonserialEnabled(labAdmitted: true, f4: false,
            environment: ["LATENCY_LAB": "1", "LATENCY_GPU_PIPELINE": "true"]))
    }

    func testLabNonserialGateRequiresGPUCompletionAndNeverExceedsTwo() {
        var gate = RemoteVideoPresentationSurface.LabNonserialGate()
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertTrue(gate.canSubmit); XCTAssertTrue(gate.submit(first))
        XCTAssertFalse(gate.canSubmit); XCTAssertFalse(gate.submit(second))
        XCTAssertFalse(gate.completedGPU(first, succeeded: false)); XCTAssertFalse(gate.canSubmit)
        XCTAssertTrue(gate.completedGPU(first, succeeded: true)); XCTAssertTrue(gate.canSubmit)
        XCTAssertFalse(gate.completedGPU(first, succeeded: true))
        XCTAssertTrue(gate.submit(second)); XCTAssertEqual(gate.count, 2)
        XCTAssertFalse(gate.canSubmit); XCTAssertFalse(gate.submit(third))
        XCTAssertTrue(gate.completedGPU(second, succeeded: true)); XCTAssertFalse(gate.canSubmit)
        XCTAssertEqual(gate.settle(first, result: .presented(1)), .presented(1)); XCTAssertTrue(gate.canSubmit)
        XCTAssertNil(gate.settle(first, result: .presented(1))); XCTAssertTrue(gate.submit(third))
        gate.reset(); XCTAssertEqual(gate.count, 0)
        XCTAssertFalse(gate.completedGPU(second, succeeded: true)); XCTAssertNil(gate.settle(third, result: .failed))
    }

    func testLabNonserialCallbackRoutingKeepsReceiptsAuthoritative() {
        let older = UUID(), newer = UUID(), context = UUID()
        let presentation = RemoteVideoSurfacePresentation(context: context)
        var gate = RemoteVideoPresentationSurface.LabNonserialGate()
        XCTAssertTrue(gate.submit(older))
        XCTAssertTrue(gate.completedGPU(older, succeeded: true), "GPU completion permits scheduling only")
        XCTAssertEqual(presentation.state, .waiting(context: context), "GPU completion must not grant presentation readiness")
        XCTAssertTrue(gate.submit(newer))
        XCTAssertTrue(gate.completedGPU(newer, succeeded: true))
        XCTAssertEqual(gate.settle(newer, result: .presented(12)), .presented(12))
        presentation.present(context: context, frame: newer, time: 12)
        XCTAssertFalse(RemoteVideoPresentationProducer.isNewerReceipt(drawableID: 1, last: 2))
        XCTAssertTrue(gate.discard(older), "An older filtered skip settles without a readiness disposition")
        XCTAssertEqual(gate.count, 0)
        XCTAssertEqual(presentation.state, .presented(context: context, frame: newer, time: 12))
        XCTAssertFalse(gate.discard(older))

        XCTAssertTrue(gate.submit(older)); XCTAssertTrue(gate.completedGPU(older, succeeded: true))
        XCTAssertTrue(gate.submit(newer))
        XCTAssertEqual(gate.settle(older, result: .failed), .retry,
                       "A newer unproven frame does not establish readiness")
        XCTAssertFalse(gate.canSubmit)
        XCTAssertTrue(gate.completedGPU(newer, succeeded: true))
        XCTAssertEqual(gate.settle(newer, result: .presented(13)), .presented(13))

        XCTAssertTrue(gate.submit(older))
        // The ledger may settle before its queued GPU scheduling notification.
        XCTAssertEqual(gate.settle(older, result: .presented(14)), .presented(14))
        XCTAssertTrue(gate.submit(newer))
        XCTAssertFalse(gate.completedGPU(older, succeeded: true), "Late old notification cannot release newer work")
        XCTAssertFalse(gate.canSubmit)
        gate.reset() // hide, retirement or context replacement clears the surface generation
        XCTAssertFalse(gate.completedGPU(newer, succeeded: true))
        XCTAssertNil(gate.settle(newer, result: .skipped))
        XCTAssertFalse(gate.discard(newer))
    }

    func testRetryDiagnosticsRequireExplicitLabAdmissionAndOptIn() {
        let enabled = ["LATENCY_LAB": "1", "LATENCY_RENDER_DIAGNOSTICS": "1"]
        XCTAssertTrue(RemoteVideoPresentationSurface.retryDiagnosticsEnabled(labAdmitted: true, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.retryDiagnosticsEnabled(labAdmitted: false, environment: enabled))
        XCTAssertFalse(RemoteVideoPresentationSurface.retryDiagnosticsEnabled(labAdmitted: true, environment: [:]))
        XCTAssertFalse(RemoteVideoPresentationSurface.retryDiagnosticsEnabled(labAdmitted: true, environment: ["LATENCY_RENDER_DIAGNOSTICS": "1"]))
        XCTAssertFalse(RemoteVideoPresentationSurface.retryDiagnosticsEnabled(labAdmitted: true, environment: ["LATENCY_LAB": "1", "LATENCY_RENDER_DIAGNOSTICS": "true"]))
    }

    func testRetryDiagnosticsMapOnlyFailureReasonsAndBoundValues() throws {
        typealias Surface = RemoteVideoPresentationSurface
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationProducer.Admission.busy), .producerBusy)
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationProducer.Admission.unavailable), .producerUnavailable)
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationProducer.Admission.preparationFailed), .preparationFailed)
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationProducer.Admission.encodingFailed), .encodingFailed)
        XCTAssertNil(Surface.retryReason(for: RemoteVideoPresentationProducer.Admission.unsupportedFrame))
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationLedger.Result.skipped), .receiptSkipped)
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationLedger.Result.failed), .receiptFailed)
        XCTAssertEqual(Surface.retryReason(for: RemoteVideoPresentationLedger.Result.expired), .receiptExpired)
        XCTAssertNil(Surface.retryReason(for: RemoteVideoPresentationLedger.Result.presented(1)))
        XCTAssertNil(Surface.retryReason(for: RemoteVideoPresentationLedger.Result.rendered(1)))
        for reason in Surface.RetryDiagnosticReason.allCases {
            let record = try XCTUnwrap(Surface.retryDiagnosticRecord(reason: reason, time: 1, attempt: 2,
                contextGeneration: 3, acquisitionMs: 100))
            XCTAssertEqual(record["type"] as? String, "render_retry")
            XCTAssertEqual(record["reason"] as? String, reason.rawValue)
            XCTAssertEqual(record["acquisitionMs"] as? Double, reason == .drawableNil ? 100 : nil)
            XCTAssertTrue(Set(record.keys).isSubset(of: ["type", "reason", "time", "attempt", "contextGeneration", "acquisitionMs"]))
            XCTAssertTrue(JSONSerialization.isValidJSONObject(record))
        }
        XCTAssertNil(Surface.retryDiagnosticRecord(reason: .drawableNil, time: .nan, attempt: 0, contextGeneration: 0))
        XCTAssertNil(Surface.retryDiagnosticRecord(reason: .drawableNil, time: 1, attempt: 31, contextGeneration: 0))
        XCTAssertNil(Surface.retryDiagnosticRecord(reason: .drawableNil, time: 1, attempt: 0, contextGeneration: -1))
        let invalidDuration = try XCTUnwrap(Surface.retryDiagnosticRecord(reason: .drawableNil, time: 1,
            attempt: 0, contextGeneration: 0, acquisitionMs: .infinity))
        XCTAssertNil(invalidDuration["acquisitionMs"])
    }

    func testNormalLabRefreshHintRequiresOptInAndStopsWhenNotVisible() {
        let action = RemoteVideoPresentationSurface.labRefreshHintAction
        let enabled = ["LATENCY_LAB": "1", "LATENCY_RENDER_HINT_60": "1"]
        XCTAssertEqual(action(true, true, false, [:]), .stop)
        XCTAssertEqual(action(true, true, false, ["LATENCY_RENDER_HINT_60": "1"]), .stop)
        XCTAssertEqual(action(true, true, false, ["LATENCY_LAB": "1", "LATENCY_RENDER_HINT_60": "true"]), .stop)
        XCTAssertEqual(action(false, true, false, enabled), .stop)
        XCTAssertEqual(action(true, false, true, enabled), .stop)
        XCTAssertEqual(action(true, true, false, enabled), .start)
        XCTAssertEqual(action(true, true, true, enabled), .keep)
        XCTAssertEqual(action(true, false, false, enabled), .stop)
    }

    func testLabHintRecordContainsOnlyClosedEnumsAndValidRequestedRange() throws {
        let range = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        let started = try XCTUnwrap(RemoteVideoPresentationSurface.labHintRecord(
            state: .started, mode: .fixed60, time: 4, range: range, screenMaximumFps: 120))
        XCTAssertEqual(started["type"] as? String, "render_hint")
        XCTAssertEqual(started["state"] as? String, "started")
        XCTAssertEqual(started["mode"] as? String, "fixed60")
        XCTAssertEqual(started["minimumFps"] as? Double, 60)
        XCTAssertEqual(started["maximumFps"] as? Double, 60)
        XCTAssertEqual(started["preferredFps"] as? Double, 60)
        XCTAssertEqual(started["screenMaximumFps"] as? Int, 120)
        XCTAssertEqual(Set(started.keys), Set(["type", "state", "mode", "time", "minimumFps", "maximumFps", "preferredFps", "screenMaximumFps"]))
        let stopped = try XCTUnwrap(RemoteVideoPresentationSurface.labHintRecord(state: .stopped, mode: .f4, time: 5))
        XCTAssertEqual(stopped["mode"] as? String, "f4")
        XCTAssertEqual(Set(stopped.keys), Set(["type", "state", "mode", "time"]))
        XCTAssertNil(RemoteVideoPresentationSurface.labHintRecord(state: .started, mode: .fixed60, time: .nan, range: range, screenMaximumFps: 120))
        XCTAssertNil(RemoteVideoPresentationSurface.labHintRecord(state: .started, mode: .fixed60, time: 1, range: range, screenMaximumFps: 30))
        XCTAssertNil(RemoteVideoPresentationSurface.labHintRecord(state: .started, mode: .fixed60, time: 1))
    }

    func testHintTraceCannotBeEnabledForNonLabSurface() throws {
        let host = try RemoteKeyboardTestWindow()
        defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make())
        defer { surface.retire() }
        var events: [[String: Any]] = []
        surface.setLabHintTraceForTesting { events.append($0) }
        surface.setLabRefreshEnvironmentForTesting(["LATENCY_LAB": "1", "LATENCY_RENDER_HINT_60": "1"])
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        XCTAssertNil(surface.labRefreshLinkIdentityForTesting)
        XCTAssertTrue(events.isEmpty)
    }

    func testNormalLabRefreshLinkIsIdempotentAndRetires() throws {
        let old = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(old) }
        var config = old; config.f4Renderer = false
        LatencyLabConfiguration.setRuntime(config)
        let host = try RemoteKeyboardTestWindow()
        defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: true))
        surface.setLabRefreshEnvironmentForTesting(["LATENCY_LAB": "1", "LATENCY_RENDER_HINT_60": "1"])
        var hintEvents: [[String: Any]] = []
        surface.setLabHintTraceForTesting { hintEvents.append($0) }
        surface.view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        try XCTUnwrap(host.window.rootViewController?.view).addSubview(surface.view)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        let first = try XCTUnwrap(surface.labRefreshLinkIdentityForTesting)
        XCTAssertEqual(hintEvents.compactMap { $0["state"] as? String }, ["started"])
        XCTAssertEqual(hintEvents.first?["mode"] as? String, "fixed60")
        let range = try XCTUnwrap(surface.labRefreshRangeForTesting)
        let expected = Float(max(1, min(60, host.window.screen.maximumFramesPerSecond)))
        XCTAssertEqual(range.minimum, expected)
        XCTAssertEqual(range.maximum, expected)
        XCTAssertEqual(range.preferred, expected)
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        XCTAssertEqual(surface.labRefreshLinkIdentityForTesting, first)
        XCTAssertEqual(hintEvents.count, 1, "Repeated layout must not duplicate a start event")
        surface.view.isHidden = true
        XCTAssertNil(surface.labRefreshLinkIdentityForTesting)
        surface.view.isHidden = false
        XCTAssertNotNil(surface.labRefreshLinkIdentityForTesting)
        surface.retire()
        XCTAssertNil(surface.labRefreshLinkIdentityForTesting)
        XCTAssertEqual(hintEvents.compactMap { $0["state"] as? String }, ["started", "stopped", "started", "stopped"])
        XCTAssertTrue(hintEvents.allSatisfy { $0["mode"] as? String == "fixed60" })
    }

    /// The coordinator captures the actual Simulator screen during the ready
    /// interval; UIKit snapshots do not reliably include CAMetalLayer pixels.
    func test_optInNV12ColorScreenshot() async throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_SINGLE_SIMULATOR_FRAME"] == "1" else {
            throw XCTSkip("Opt-in: isolated Simulator surface test")
        }
        guard let phase = environment["F4_SCREENSHOT_PHASE"], phase == "A" || phase == "B" else {
            throw XCTSkip("Set F4_SCREENSHOT_PHASE to A or B")
        }
        let previous = LatencyLabConfiguration.current
        defer { LatencyLabConfiguration.setRuntime(previous) }
        var configuration = previous
        configuration.f4Renderer = phase == "B"
        LatencyLabConfiguration.setRuntime(configuration)

        let host = try RemoteKeyboardTestWindow()
        defer { host.close() }
        let surface = try XCTUnwrap(RemoteVideoPresentationSurface.make(allowF4: phase == "B"))
        defer { surface.retire() }
        surface.view.frame = CGRect(x: 24, y: 96, width: 256, height: 256)
        let root = try XCTUnwrap(host.window.rootViewController?.view)
        root.addSubview(surface.view)
        let marker = UILabel(frame: CGRect(x: 24, y: 48, width: 256, height: 32))
        marker.text = "NV12 COLOR PHASE \(phase)"
        marker.textColor = .white; marker.backgroundColor = .black
        root.addSubview(marker)
        root.layoutIfNeeded()
        surface.configure(mode: .aspectFit, viewport: surface.view.bounds)
        XCTAssertTrue(surface.view.window === host.window)

        var pixels: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 256, 256,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
            let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            // Eight vertical video-range patches, identical in both phases.
            let patches: [(UInt8, UInt8, UInt8)] = [
                (16, 128, 128), (235, 128, 128), (126, 128, 128), (63, 102, 240),
                (32, 240, 118), (173, 42, 26), (110, 155, 100), (70, 128, 128)
            ]
            for row in 0..<256 { for column in 0..<256 { y[row * ys + column] = patches[column / 32].0 } }
            for row in 0..<128 { for column in 0..<128 {
                let patch = patches[column / 16]
                uv[row * uvs + column * 2] = patch.1; uv[row * uvs + column * 2 + 1] = patch.2
            } }
        }
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1)
        if phase == "B" {
            // The exact prepared frame must be eligible for the direct NV12
            // path; otherwise a visually correct CI fallback is inconclusive.
            guard case .ready(let prepared) = RemoteVideoFrameImage.prepare(frame) else {
                return XCTFail("Unable to prepare NV12 fixture")
            }
            let device = try XCTUnwrap(surface.view.metalLayer.device)
            let renderer = try XCTUnwrap(RemoteVideoF4Metal(device: device))
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
            descriptor.usage = .renderTarget; descriptor.storageMode = .shared
            let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let resources = try XCTUnwrap(renderer.encode(prepared: prepared, destination: destination, command: command, mode: .aspectFit),
                                          "The F4 fixture must use the NV12 Metal path")
            command.commit(); command.waitUntilCompleted()
            withExtendedLifetime(resources) {}
            XCTAssertEqual(command.status, .completed)
            var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
            bytes.withUnsafeMutableBytes { storage in
                if let base = storage.baseAddress {
                    destination.getBytes(base, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
                }
            }
            func pixel(_ column: Int) -> (UInt8, UInt8, UInt8) {
                let offset = (128 * 256 + column) * 4
                return (bytes[offset + 2], bytes[offset + 1], bytes[offset])
            }
            let black = pixel(16), white = pixel(48), gray = pixel(80), red = pixel(112), blue = pixel(144)
            XCTAssertLessThan(black.0, 8); XCTAssertLessThan(black.1, 8); XCTAssertLessThan(black.2, 8)
            XCTAssertGreaterThan(white.0, 247); XCTAssertGreaterThan(white.1, 247); XCTAssertGreaterThan(white.2, 247)
            XCTAssertTrue((110...145).contains(Int(gray.0)) && (110...145).contains(Int(gray.1)) && (110...145).contains(Int(gray.2)))
            XCTAssertGreaterThan(red.0, 230); XCTAssertLessThan(red.1, 20); XCTAssertLessThan(red.2, 20)
            XCTAssertGreaterThan(blue.2, 230); XCTAssertLessThan(blue.0, 20); XCTAssertLessThan(blue.1, 20)
        }
        let finished = expectation(description: "NV12 surface ready")
        var receipt: RemoteVideoSurfacePresentation.State?
        surface.presentation.observe { state in
            switch state {
            case .rendered, .presented, .failed:
                guard receipt == nil else { return }
                receipt = state; finished.fulfill()
            case .waiting, .retired: break
            }
        }
        surface.renderFrame(frame)
        await fulfillment(of: [finished], timeout: 5)
        guard case .rendered = receipt else {
            return XCTFail("Expected Simulator GPU completion, received \(String(describing: receipt))")
        }
        NSLog("NV12_SCREENSHOT_READY phase=%@ rect=24,96,256,256 points", phase)
        try await Task.sleep(nanoseconds: 30_000_000_000)
        #else
        throw XCTSkip("This experiment targets the Simulator rendering path")
        #endif
    }
    #endif

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

    func test_failedPresentationRetriesLatestOnlyWithinItsContext() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<SurfaceMailboxFrame>()
        let first = UUID(), second = UUID(), third = UUID()
        mailbox.replaceContext(first)
        mailbox.offer(SurfaceMailboxFrame(1))
        let failed = try XCTUnwrap(mailbox.takeLatest(context: first))
        mailbox.restoreUnlessNewer(failed)
        XCTAssertEqual(mailbox.takeLatest(context: first)?.id, failed.id,
                       "A transient failure can retry the same decoded frame")
        mailbox.restoreUnlessNewer(failed)
        mailbox.replaceContext(second, preservingLatestFrom: first, excludingFrameID: failed.id)
        XCTAssertNil(mailbox.takeLatest(context: second), "A failed frame cannot cross layout contexts")
        mailbox.restoreUnlessNewer(failed)
        XCTAssertNil(mailbox.takeLatest(context: second), "An old retry cannot revive a replaced context")

        mailbox.offer(SurfaceMailboxFrame(2))
        let older = try XCTUnwrap(mailbox.takeLatest(context: second))
        mailbox.offer(SurfaceMailboxFrame(3))
        mailbox.restoreUnlessNewer(older)
        mailbox.replaceContext(third, preservingLatestFrom: second, excludingFrameID: older.id)
        let newer = try XCTUnwrap(mailbox.takeLatest(context: third))
        XCTAssertEqual(newer.frame.value, 3, "A newer decode must win and remain eligible for redraw")
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
