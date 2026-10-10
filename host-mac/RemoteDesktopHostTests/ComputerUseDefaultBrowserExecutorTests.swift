import Foundation
import AppKit
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseDefaultBrowserExecutorTests: XCTestCase {
    func testOnlyRetainedWindowCoordinatesAndSafeNavigationKeysAreAllowed() {
        let bounds = CGRect(x: 100, y: 50, width: 900, height: 700)
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.click(x: 150, y: 100, button: 1, count: 1), within: bounds))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permits(.click(x: 20, y: 100, button: 1, count: 1), within: bounds))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.drag(fromX: 150, fromY: 100, toX: 200, toY: 150), within: bounds))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permits(.drag(fromX: 150, fromY: 100, toX: 1_100, toY: 150), within: bounds))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.scroll(x: 200, y: 200, dx: 0, dy: 80), within: bounds))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x0F, modifiers: 8), within: bounds)) // Cmd-L
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x28, modifiers: 0), within: bounds)) // Return
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x04, modifiers: 8), within: bounds)) // Cmd-A
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x0F, modifiers: 0), within: bounds)) // plain L
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x2B, modifiers: 0), within: bounds)) // Tab within page
        for chord in [(0x16, 8), (0x17, 8), (0x1A, 8), (0x14, 8), (0x35, 8),
                      (0x1E, 8), (0x2B, 2), (0x4E, 2), (0x0F, 2)] { // Cmd-N/T/W/Q/grave/1, Ctrl-Tab/PgDn/L
            XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permits(.key(usage: chord.0, modifiers: UInt16(chord.1)), within: bounds))
        }
    }

    func testObservedGmailControlApprovalBindingMatchesDesktopDispatchCoordinates() throws {
        let display = CGRect(x: -640, y: -200, width: 1280, height: 800)
        let center = CGPoint(x: 100.6, y: 87.6)
        let binding = try ComputerUseDefaultBrowserExecutor.observedControlActionPair(
            center: center, display: display)
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 800)),
            displayBounds: display))
        let dispatched = try XCTUnwrap(ComputerUseDesktopExecutor.nativeAction(binding.proposalAction, image: image))
        XCTAssertEqual(binding.predictedAction, dispatched,
            "The observed Send proposal's approval binding must match DesktopExecutor's exact display conversion")
    }

    func testSharedDisplayPointRejectsInvalidDisplayGeometry() {
        let invalidBounds = [
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0.5, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 100.5, height: 100),
            CGRect(x: 0, y: 0, width: 1_000_001, height: 100),
        ]

        for bounds in invalidBounds {
            XCTAssertThrowsError(try ComputerUseDesktopImage.displayPoint(
                normalizedX: 500, normalizedY: 500, displayBounds: bounds))
        }
    }

}
