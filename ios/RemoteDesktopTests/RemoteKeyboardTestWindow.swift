import XCTest
import UIKit
@testable import RemoteDesktop

/// Future hosted-iOS fixture. Creating this window requires explicit native
/// test execution; source inventory/parse checks never instantiate it.
@MainActor
final class RemoteKeyboardTestWindow {
    private enum Failure: Error { case nativeFocusRejected }
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    private var fields: [SoftKeyboardCapture.CaptureField] = []

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive },
            "Keyboard ownership cases require a foreground hosted iOS scene", file: file, line: line)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    func focus(_ field: SoftKeyboardCapture.CaptureField, in session: SessionModel,
               file: StaticString = #filePath, line: UInt = #line) throws {
        fields.append(field)
        field.frame = CGRect(x: 20, y: 80, width: 280, height: 44)
        window.rootViewController?.view.addSubview(field)
        field.bindSession(session)
        let focused = field.becomeFirstResponder()
        XCTAssertTrue(focused, "Native focus must succeed before input is exercised", file: file, line: line)
        XCTAssertTrue(field.isFirstResponder, file: file, line: line)
        XCTAssertTrue(field.canSendInput, file: file, line: line)
        guard focused, field.isFirstResponder, field.canSendInput else {
            close()
            throw Failure.nativeFocusRejected
        }
    }

    func close() {
        for field in fields { field.stopCapture(); field.removeFromSuperview() }
        fields.removeAll()
        let wasKey = window.isKeyWindow
        window.isHidden = true
        window.rootViewController = nil
        if wasKey, window.windowScene?.windows.contains(where: { $0.isKeyWindow }) == false,
           previousKeyWindow?.isHidden == false {
            previousKeyWindow?.makeKey()
        }
    }
}
