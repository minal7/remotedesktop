import AppKit
import Foundation
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

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func syntheticScreenshot(_ draw: (Canvas) -> Void) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 640, height: 240)).fill()
        draw(Canvas())
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:])).base64EncodedString()
    }

    private struct Canvas {
        private let imageHeight: CGFloat = 240

        func button(_ title: String, center: CGPoint, fontSize: CGFloat) {
            NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.72, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: center.x - 54, y: imageHeight - center.y - 18,
                width: 108, height: 36), xRadius: 5, yRadius: 5).fill()
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
