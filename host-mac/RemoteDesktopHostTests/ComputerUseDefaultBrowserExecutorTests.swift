import Foundation
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

}
