import AppKit
import Foundation
import Dispatch
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentTargetOCRTests: XCTestCase {
    func testTargetLabelSelectsNearbyTextInsteadOfConcatenatingAdjacentHighRiskText() throws {
        let image = try syntheticScreenshot { canvas in
            canvas.button("Continue", center: CGPoint(x: 220, y: 120), fontSize: 18)
            canvas.text("Submit", center: CGPoint(x: 315, y: 120), fontSize: 18, color: .black)
        }

        let label = SystemBarriers.targetLabel(screenshot: image, x: 220, y: 120)

        XCTAssertEqual(normalized(label), "continue")
    }

    func testTargetLabelRecognizesSmallWhiteOnBlueControlText() throws {
        let image = try syntheticScreenshot { canvas in
            canvas.button("Submit", center: CGPoint(x: 320, y: 120), fontSize: 10)
        }

        let label = SystemBarriers.targetLabel(screenshot: image, x: 320, y: 120)

        XCTAssertEqual(normalized(label), "submit")
    }

    func testTargetLabelKeepsWordsFromOneControlTogether() throws {
        let image = try syntheticScreenshot { canvas in
            canvas.button("Save changes", center: CGPoint(x: 320, y: 120), fontSize: 18)
        }

        let label = SystemBarriers.targetLabel(screenshot: image, x: 320, y: 120)

        XCTAssertEqual(normalized(label), "save changes")
    }

    func testTargetLabelMapsTextNearTopImageEdgeToClickCoordinates() throws {
        let image = try syntheticScreenshot { canvas in
            canvas.text("Continue", center: CGPoint(x: 320, y: 10), fontSize: 14, color: .black)
            canvas.text("Delete", center: CGPoint(x: 320, y: 43), fontSize: 14, color: .black)
        }

        let label = SystemBarriers.targetLabel(screenshot: image, x: 320, y: 25)

        XCTAssertEqual(normalized(label), "continue")
    }

    func testEquidistantTargetLabelsDoNotChooseAnArbitraryCandidate() throws {
        let label = SystemBarriers.selectTargetLabel(candidates: [
            ("Delete", CGRect(x: 260, y: 112, width: 20, height: 16)),
            ("Continue", CGRect(x: 360, y: 112, width: 20, height: 16)),
        ], at: CGPoint(x: 320, y: 120))
        XCTAssertNil(label)
    }

    func testTargetLabelRejectsMalformedImagesAndNonfiniteCoordinates() throws {
        let image = try syntheticScreenshot { $0.button("Submit", center: CGPoint(x: 320, y: 120), fontSize: 18) }

        XCTAssertNil(SystemBarriers.targetLabel(screenshot: "not-base64", x: 320, y: 120))
        XCTAssertNil(SystemBarriers.targetLabel(screenshot: Data("invalid image".utf8).base64EncodedString(), x: 320, y: 120))
        XCTAssertNil(SystemBarriers.targetLabel(screenshot: image, x: .infinity, y: 120))
        XCTAssertNil(SystemBarriers.targetLabel(screenshot: image, x: 320, y: .nan))
    }

    func testSmallPointTargetLabelFlowsThroughPixelContextIntoApprovalGate() throws {
        let point = CGPoint(x: 1016.65, y: 143.74)
        let action = AgentAction.click(target: .point(x: Double(point.x), y: Double(point.y)), button: nil, count: nil)
        let submitImage = try syntheticScreenshot(width: 1280, height: 827) { canvas in
            canvas.button("Submit", center: point, fontSize: 10, size: CGSize(width: 65, height: 12))
        }
        let submitLabel = try XCTUnwrap(PixelTargetContextLabel.resolve(action, targets: []) { x, y in
            SystemBarriers.targetLabel(screenshot: submitImage, x: x, y: y)
        })
        let scope = AgentScope(taskID: "fixture", kind: .web, identity: "https://fixture.test")
        let gate = AgentActionGate(trustStore: TrustedStore(), allowPolicy: AllowPolicy())

        func evaluate(_ screenshot: String, label: String) throws -> AgentGateEvaluation {
            let observation = AgentObservation(task: "Complete a generic form",
                surface: .web(url: "https://fixture.test", title: nil), screenshot: screenshot,
                elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 20))
            let frame = AgentFrame(observation: observation, scope: scope)
            let resolved = AgentResolvedAction(action: action, frame: frame, targets: [], targetContextLabel: label)
            return try gate.evaluate(resolved, expectedScope: scope)
        }

        XCTAssertEqual(normalized(submitLabel), "submit")
        let submit = try evaluate(submitImage, label: submitLabel)
        XCTAssertEqual(submit.result.decision, .needsApproval)
        XCTAssertEqual(submit.result.riskTier, AgentRiskTier.high.rawValue)

        let continueImage = try syntheticScreenshot(width: 1280, height: 827) { canvas in
            canvas.button("Continue", center: point, fontSize: 10, size: CGSize(width: 65, height: 12))
        }
        let continueLabel = try XCTUnwrap(PixelTargetContextLabel.resolve(action, targets: []) { x, y in
            SystemBarriers.targetLabel(screenshot: continueImage, x: x, y: y)
        })
        XCTAssertEqual(normalized(continueLabel), "continue")
        let continueResult = try evaluate(continueImage, label: continueLabel)
        XCTAssertEqual(continueResult.result.decision, .allowed)
        XCTAssertEqual(continueResult.result.riskTier, AgentRiskTier.low.rawValue)
    }

    func testRecognizedSubmitLabelRequiresApprovalAtActionGate() throws {
        let image = try syntheticScreenshot { $0.button("Submit", center: CGPoint(x: 320, y: 120), fontSize: 18) }
        let label = try XCTUnwrap(SystemBarriers.targetLabel(screenshot: image, x: 320, y: 120))
        let scope = AgentScope(taskID: "fixture", kind: .web, identity: "https://fixture.test")
        let observation = AgentObservation(task: "Complete a generic form", surface: .web(url: "https://fixture.test", title: nil),
            screenshot: image, elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 20))
        let frame = AgentFrame(observation: observation, scope: scope)
        let resolved = AgentResolvedAction(action: .click(target: .point(x: 320, y: 120), button: nil, count: nil),
            frame: frame, targets: [], targetContextLabel: label)
        let gate = AgentActionGate(trustStore: TrustedStore(), allowPolicy: AllowPolicy())

        let result = try gate.evaluate(resolved, expectedScope: scope)

        XCTAssertEqual(result.result.decision, .needsApproval)
        XCTAssertEqual(result.result.riskTier, AgentRiskTier.high.rawValue)
    }

    func testSystemBarrierConsentOCRLeavesMainActorResponsiveAndCancellationDiscardsResult() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: syntheticScreenshot { _ in }))
        let started = expectation(description: "consent OCR started")
        let heartbeat = expectation(description: "main actor heartbeat")
        let exited = expectation(description: "blocked consent OCR exited")
        let startedSignal = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let observation: Task<String?, Error> = Task { @MainActor in
            try await SystemBarriers.handoffReason(
                screenshot: imageData, elements: [], focus: nil,
                consentRecognition: { _ in
                    XCTAssertFalse(Thread.isMainThread)
                    started.fulfill()
                    startedSignal.signal()
                    defer { exited.fulfill() }
                    _ = release.wait(timeout: .now() + .seconds(2))
                    return true
                })
        }
        let cancelAndMeasure = Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<(cancelledAt: ContinuousClock.Instant, heartbeatAt: ContinuousClock.Instant), Never>) in
                DispatchQueue.global().async {
                    _ = startedSignal.wait(timeout: .now() + .seconds(1))
                    observation.cancel()
                    let cancelledAt = ContinuousClock.now
                    Task { @MainActor in
                        heartbeat.fulfill()
                        continuation.resume(returning: (cancelledAt: cancelledAt, heartbeatAt: ContinuousClock.now))
                    }
                }
            }
        }

        await fulfillment(of: [started, heartbeat], timeout: 1)
        let timing = await cancelAndMeasure.value
        let heartbeatDelay = timing.cancelledAt.duration(to: timing.heartbeatAt)
        XCTAssertLessThan(heartbeatDelay, .seconds(1), "The main actor must remain responsive during OCR")
        do {
            let result = try await observation.value
            XCTFail("A cancelled OCR wait must not return a handoff result: \(result ?? "nil")")
        } catch is CancellationError { }
        XCTAssertLessThan(timing.cancelledAt.duration(to: .now), .seconds(1),
            "Cancellation should return while the worker operation is still blocked")

        release.signal()
        await fulfillment(of: [exited], timeout: 1)
        try await waitForConsentWorkerCapacity()
    }

    func testSystemBarrierReportsBusyConsentWorkerInsteadOfPublishingUncheckedFrame() async throws {
        let imageData = try XCTUnwrap(Data(base64Encoded: syntheticScreenshot { _ in }))
        let started = expectation(description: "first consent OCR started")
        let exited = expectation(description: "first consent OCR exited")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let first: Task<String?, Error> = Task { @MainActor in
            try await SystemBarriers.handoffReason(
                screenshot: imageData, elements: [], focus: nil,
                consentRecognition: { _ in
                    started.fulfill()
                    defer { exited.fulfill() }
                    _ = release.wait(timeout: .now() + .seconds(2))
                    return false
                })
        }
        await fulfillment(of: [started], timeout: 1)

        do {
            _ = try await SystemBarriers.handoffReason(
                screenshot: imageData, elements: [], focus: nil,
                consentRecognition: { _ in XCTFail("A busy worker must not start overlapping OCR"); return false })
            XCTFail("A busy consent worker must not publish an unchecked frame")
        } catch let failure as ComputerUseObservationWorker.Failure {
            XCTAssertEqual(failure, .busy)
        }

        first.cancel()
        do { _ = try await first.value } catch is CancellationError { }
        release.signal()
        await fulfillment(of: [exited], timeout: 1)
        try await waitForConsentWorkerCapacity()
    }

    func testSystemBarrierPreservesFastAuthenticationAndConsentOutcomes() async throws {
        let secureFocus = AgentFocus(id: 1, role: "AXSecureTextField", name: "Password",
            valuePrefix: "", selection: .init(start: 0, end: 0))
        let fastHandoff = try await SystemBarriers.handoffReason(
            screenshot: Data("synthetic frame".utf8), elements: [], focus: secureFocus,
            consentRecognition: { _ in XCTFail("Fast AX authentication must skip OCR"); return false })
        XCTAssertEqual(fastHandoff, "A sign-in or verification screen needs your attention.")

        let permissionHandoff = try await SystemBarriers.handoffReason(
            screenshot: Data("synthetic frame".utf8), elements: [], focus: nil,
            consentRecognition: { _ in true })
        XCTAssertEqual(permissionHandoff, "Approve the screen-capture request in macOS to continue.")

        let ordinaryFrame = try await SystemBarriers.handoffReason(
            screenshot: Data("synthetic frame".utf8), elements: [], focus: nil,
            consentRecognition: { _ in false })
        XCTAssertNil(ordinaryFrame)
    }

    private func waitForConsentWorkerCapacity() async throws {
        for _ in 0..<100 {
            do {
                _ = try await ComputerUseObservationWorker.perform(timeout: 0.5) { true }
                return
            } catch ComputerUseObservationWorker.Failure.busy {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTFail("Consent recognition worker did not release its serial permit")
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func syntheticScreenshot(width: Int = 640, height: Int = 240,
                                     _ draw: (Canvas) -> Void) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        draw(Canvas(imageHeight: CGFloat(height)))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:])).base64EncodedString()
    }

    private struct Canvas {
        private let imageHeight: CGFloat

        init(imageHeight: CGFloat = 240) { self.imageHeight = imageHeight }

        func button(_ title: String, center: CGPoint, fontSize: CGFloat,
                    size: CGSize = CGSize(width: 108, height: 36)) {
            NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.72, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: center.x - size.width / 2,
                y: imageHeight - center.y - size.height / 2, width: size.width, height: size.height),
                xRadius: 5, yRadius: 5).fill()
            text(title, center: center, fontSize: fontSize, color: .white, weight: .semibold)
        }

        func text(_ title: String, center: CGPoint, fontSize: CGFloat, color: NSColor,
                  weight: NSFont.Weight = .regular) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: center.x - size.width / 2,
                y: imageHeight - center.y - size.height / 2), withAttributes: attributes)
        }
    }

    @MainActor
    private final class TrustedStore: AgentTrustStore {
        func isTrusted(kind: AgentScope.Kind, identity: String) throws -> Bool { true }
        func markTrusted(kind: AgentScope.Kind, identity: String) throws {}
    }

    @MainActor
    private final class AllowPolicy: AgentAllowPolicy {
        func decision(for action: AgentAction, in scope: AgentScope) -> AgentAccessDecision { .allowed }
        func resolvedTrustIdentity(for action: AgentAction, in scope: AgentScope) -> AgentTrustIdentity? { nil }
    }
}
