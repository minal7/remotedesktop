import XCTest
@testable import RemoteDesktop

final class TrackpadGestureControllerTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)

    func testAccelerationCurve() {
        XCTAssertEqual(TrackpadGestureController.gain(speed: 0), 1)
        XCTAssertEqual(TrackpadGestureController.gain(speed: 200), 1)
        XCTAssertEqual(TrackpadGestureController.gain(speed: 700), 1.75, accuracy: 0.001)
        XCTAssertEqual(TrackpadGestureController.gain(speed: 1200), 2.5)
        XCTAssertEqual(TrackpadGestureController.gain(speed: 2000), 2.5)
    }

    func testTapAndDoubleTapUseCursor() {
        var state = TrackpadGestureController()
        let cursor = CGPoint(x: 200, y: 150)
        state.begin(at: 1, cursor: cursor, bounds: bounds)
        XCTAssertEqual(state.end(at: 1.1), [1, 0])
        state.begin(at: 1.2, cursor: cursor, bounds: bounds)
        XCTAssertEqual(state.end(at: 1.25), [1, 0])
        XCTAssertEqual(state.cursor, cursor)
    }

    func testHostWarpIsUsedForNextGesture() {
        var state = TrackpadGestureController()
        state.begin(at: 1, cursor: CGPoint(x: 10, y: 10), bounds: bounds)
        _ = state.move(delta: CGPoint(x: 20, y: 0), timestamp: 1.1, scale: 1, bounds: bounds)
        _ = state.end(at: 1.2)
        let hostPosition = CGPoint(x: 300, y: 200)
        state.begin(at: 2, cursor: hostPosition, bounds: bounds)
        XCTAssertEqual(state.cursor, hostPosition)
        _ = state.move(delta: CGPoint(x: 10, y: 0), timestamp: 2.1, scale: 1, bounds: bounds)
        XCTAssertEqual(state.cursor!.x, 310, accuracy: 0.001)
    }

    func testSecondFingerSuppressesSingleTapAndRoutesRightClick() {
        var state = TrackpadGestureController()
        state.begin(at: 1, cursor: CGPoint(x: 100, y: 100), bounds: bounds)
        XCTAssertEqual(state.secondFingerBegan(), [])
        XCTAssertEqual(state.end(at: 1.1), [])
        XCTAssertEqual(state.endTwoFingerTap(), [2, 0])
        XCTAssertEqual(state.endTwoFingerTap(), [])
    }

    func testSecondFingerReleasesDragAndScrollSuppressesRightClick() {
        var state = TrackpadGestureController()
        state.begin(at: 1, cursor: .zero, bounds: bounds)
        XCTAssertEqual(state.end(at: 1.1), [1, 0])
        state.begin(at: 1.2, cursor: .zero, bounds: bounds)
        XCTAssertEqual(state.move(delta: CGPoint(x: 10, y: 0), timestamp: 1.25, scale: 1, bounds: bounds), 1)
        XCTAssertEqual(state.secondFingerBegan(), [0])
        XCTAssertEqual(state.end(at: 1.3), [])
        state.twoFingerScrollBegan()
        XCTAssertEqual(state.endTwoFingerTap(), [])
    }

    func testTapDragHasPairedDownAndUpAndCancelReleases() {
        var state = TrackpadGestureController()
        state.begin(at: 1, cursor: .zero, bounds: bounds)
        XCTAssertEqual(state.end(at: 1.1), [1, 0])
        state.begin(at: 1.2, cursor: .zero, bounds: bounds)
        XCTAssertEqual(state.move(delta: CGPoint(x: 10, y: 0), timestamp: 1.25, scale: 1, bounds: bounds), 1)
        XCTAssertEqual(state.end(at: 1.4), [0])
        state.begin(at: 2, cursor: .zero, bounds: bounds)
        _ = state.end(at: 2.1)
        state.begin(at: 2.2, cursor: .zero, bounds: bounds)
        _ = state.move(delta: CGPoint(x: 10, y: 0), timestamp: 2.25, scale: 1, bounds: bounds)
        XCTAssertEqual(state.cancel(), [0])
        XCTAssertEqual(state.cancel(), [])
    }

    func testClampAndEdgePan() {
        var state = TrackpadGestureController()
        state.begin(at: 1, cursor: CGPoint(x: 490, y: 250), bounds: bounds)
        _ = state.move(delta: CGPoint(x: 100, y: 0), timestamp: 1.1, scale: 1, bounds: bounds)
        XCTAssertLessThan(state.cursor!.x, bounds.maxX)
        XCTAssertEqual(TrackpadGestureController.edgePan(cursor: CGPoint(x: 390, y: 100), viewport: CGRect(x: 0, y: 0, width: 400, height: 200)), CGPoint(x: -30, y: 0))
    }

    func testPreferencesDefaultDirectAndArePerHost() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TouchInputPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.mode(for: "a"), .direct)
        store.set(.trackpad, for: "a")
        XCTAssertEqual(store.mode(for: "a"), .trackpad)
        XCTAssertEqual(store.mode(for: "b"), .direct)
    }
}
