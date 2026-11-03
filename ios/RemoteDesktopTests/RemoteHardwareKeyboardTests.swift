import XCTest
import UIKit
@testable import RemoteDesktop

/// Source-authored cases only. These do not synthesize a physical keyboard or
/// establish UIKit's native press identity, repeat or responder chronology.
@MainActor
final class RemoteHardwareKeyboardTests: XCTestCase {
    func test_hardwarePressReleaseRequiresItsOwnNativeIdentity() {
        var state = RemoteHardwarePressState()
        let first = NSObject(), foreign = NSObject(), replacement = NSObject()
        assertKey(state.handle(id: ObjectIdentifier(first), usage: 4, phase: .began, modifiers: []), usage: 4, down: true)
        XCTAssertNil(state.handle(id: ObjectIdentifier(foreign), usage: 4, phase: .ended, modifiers: []))
        XCTAssertNil(state.handle(id: ObjectIdentifier(foreign), usage: 4, phase: .began, modifiers: []))
        XCTAssertNil(state.handle(id: ObjectIdentifier(first), usage: 5, phase: .cancelled, modifiers: []))
        assertKey(state.handle(id: ObjectIdentifier(first), usage: 4, phase: .cancelled, modifiers: []), usage: 4, down: false)
        assertKey(state.handle(id: ObjectIdentifier(replacement), usage: 4, phase: .began, modifiers: []), usage: 4, down: true)
        XCTAssertNil(state.handle(id: ObjectIdentifier(first), usage: 4, phase: .ended, modifiers: []))
        assertKey(state.handle(id: ObjectIdentifier(replacement), usage: 4, phase: .ended, modifiers: []), usage: 4, down: false)
        XCTAssertNil(state.handle(id: ObjectIdentifier(replacement), usage: 4, phase: .ended, modifiers: []))
    }

    func test_hardwarePressForceChangesDoNotInventRepeats() {
        var state = RemoteHardwarePressState()
        let press = NSObject()
        XCTAssertNil(state.handle(id: ObjectIdentifier(press), usage: 3, phase: .began, modifiers: []))
        XCTAssertNil(state.handle(id: ObjectIdentifier(press), usage: 256, phase: .began, modifiers: []))
        XCTAssertNil(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .changed, modifiers: []))
        XCTAssertNil(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .began, modifiers: .command))
        XCTAssertNil(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .ended, modifiers: .command))
        assertKey(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .began, modifiers: []), usage: 4, down: true)
        XCTAssertNil(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .changed, modifiers: []))
        assertKey(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .began, modifiers: []), usage: 4, down: true)
        assertKey(state.handle(id: ObjectIdentifier(press), usage: 4, phase: .ended, modifiers: []), usage: 4, down: false)
    }

    func test_hardwareModifierSidesAndReleaseFlagsPreserveOwnedState() {
        var state = RemoteHardwarePressState()
        let right = NSObject(), left = NSObject(), letter = NSObject()
        assertKey(state.handle(id: ObjectIdentifier(right), usage: 0xE5, phase: .began, modifiers: .shift), usage: 0xE5, down: true, modifiers: 16)
        assertKey(state.handle(id: ObjectIdentifier(left), usage: 0xE1, phase: .began, modifiers: .shift), usage: 0xE1, down: true, modifiers: 17)
        assertKey(state.handle(id: ObjectIdentifier(right), usage: 0xE5, phase: .ended, modifiers: .shift), usage: 0xE5, down: false, modifiers: 1)
        assertKey(state.handle(id: ObjectIdentifier(letter), usage: 4, phase: .began, modifiers: [.shift, .alphaShift]), usage: 4, down: true, modifiers: 257)
        assertKey(state.handle(id: ObjectIdentifier(left), usage: 0xE1, phase: .ended, modifiers: [.shift, .alphaShift]), usage: 0xE1, down: false, modifiers: 256)
        assertKey(state.handle(id: ObjectIdentifier(letter), usage: 4, phase: .ended, modifiers: .alphaShift), usage: 4, down: false, modifiers: 256)
        for (usage, flag, mask): (Int, UIKeyModifierFlags, UInt16) in [
            (0xE4, .control, 32), (0xE6, .alternate, 64), (0xE7, .command, 128),
        ] {
            let press = NSObject()
            assertKey(state.handle(id: ObjectIdentifier(press), usage: usage, phase: .began, modifiers: flag), usage: usage, down: true, modifiers: mask)
            assertKey(state.handle(id: ObjectIdentifier(press), usage: usage, phase: .cancelled, modifiers: flag), usage: usage, down: false)
        }
    }

    func test_hardwarePressResetCannotReleaseAReplacementPress() {
        var state = RemoteHardwarePressState()
        let old = NSObject(), current = NSObject()
        assertKey(state.handle(id: ObjectIdentifier(old), usage: 4, phase: .began, modifiers: []), usage: 4, down: true)
        state.reset()
        assertKey(state.handle(id: ObjectIdentifier(current), usage: 4, phase: .began, modifiers: []), usage: 4, down: true)
        XCTAssertNil(state.handle(id: ObjectIdentifier(old), usage: 4, phase: .ended, modifiers: []))
        assertKey(state.handle(id: ObjectIdentifier(current), usage: 4, phase: .cancelled, modifiers: []), usage: 4, down: false)
    }

    func test_hardwareFocusPolicyRecognizesLocalRespondersAndRejectsWindowlessCapture() {
        let root = UIView(), container = UIView(), capture = FocusFlagView(), local = FocusFlagView()
        root.addSubview(container); container.addSubview(capture); container.addSubview(local)
        capture.reportsFocus = true
        XCTAssertFalse(RemoteHardwareKeyboardCapture.containsOtherFirstResponder(in: root, excluding: capture))
        local.reportsFocus = true
        XCTAssertTrue(RemoteHardwareKeyboardCapture.containsOtherFirstResponder(in: root, excluding: capture))
        local.removeFromSuperview()
        XCTAssertFalse(RemoteHardwareKeyboardCapture.containsOtherFirstResponder(in: root, excluding: capture))
        let uninstalled = RemoteHardwareKeyboardCapture()
        XCTAssertFalse(uninstalled.canBecomeFirstResponder)
        XCTAssertFalse(uninstalled.becomeFirstResponder())
        uninstalled.stop()
        XCTAssertFalse(uninstalled.canBecomeFirstResponder)
    }

    private func assertKey(_ message: ControlMessage?, usage: Int, down: Bool, modifiers: UInt16 = 0,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard case let .key(actualUsage, actualDown, actualModifiers)? = message else {
            XCTFail("Expected an owned key event", file: file, line: line); return
        }
        XCTAssertEqual(actualUsage, usage, file: file, line: line)
        XCTAssertEqual(actualDown, down, file: file, line: line)
        XCTAssertEqual(actualModifiers, modifiers, file: file, line: line)
    }
}

@MainActor
private final class FocusFlagView: UIView {
    var reportsFocus = false
    override var isFirstResponder: Bool { reportsFocus }
}
