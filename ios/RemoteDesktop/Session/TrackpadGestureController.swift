import UIKit

/// Gesture state for touch trackpad input. Positions are in content coordinates.
struct TrackpadGestureController {
    private(set) var cursor: CGPoint?
    private var beganAt: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0
    private var lastTapAt: TimeInterval?
    private var dragCandidate = false
    private var dragging = false
    private var moved = false
    private var travel: CGFloat = 0
    private var singleFingerActive = false
    private var twoFingerActive = false
    private var twoFingerScrolled = false

    static func gain(speed: CGFloat) -> CGFloat {
        let t = min(1, max(0, (speed - 200) / 1000))
        return 1 + 1.5 * t * t * (3 - 2 * t)
    }

    mutating func begin(at timestamp: TimeInterval, cursor initial: CGPoint, bounds: CGRect) {
        cursor = Self.clamp(initial, to: bounds)
        singleFingerActive = true
        twoFingerActive = false
        twoFingerScrolled = false
        beganAt = timestamp
        lastTimestamp = timestamp
        dragCandidate = lastTapAt.map { timestamp - $0 >= 0 && timestamp - $0 <= 0.3 } ?? false
        dragging = false
        moved = false
        travel = 0
    }

    /// Returns button state to send, including the first down for a tap-drag.
    mutating func move(delta: CGPoint, timestamp: TimeInterval, scale: CGFloat, bounds: CGRect) -> UInt8 {
        guard singleFingerActive, let cursor, bounds.width > 0, bounds.height > 0 else { return 0 }
        let elapsed = max(timestamp - lastTimestamp, 0.001)
        let speed = hypot(delta.x, delta.y) / CGFloat(elapsed)
        let gain = Self.gain(speed: speed) / max(scale, 0.001)
        self.cursor = Self.clamp(CGPoint(x: cursor.x + delta.x * gain, y: cursor.y + delta.y * gain), to: bounds)
        lastTimestamp = timestamp
        travel += hypot(delta.x, delta.y)
        if travel > 4 { moved = true }
        if dragCandidate && moved { dragging = true; lastTapAt = nil }
        return dragging ? 1 : 0
    }

    mutating func end(at timestamp: TimeInterval) -> [UInt8] {
        guard singleFingerActive else { return [] }
        defer { singleFingerActive = false; dragging = false; dragCandidate = false }
        if dragging { lastTapAt = nil; return [0] }
        guard !moved, timestamp - beganAt < 0.3 else { lastTapAt = nil; return [] }
        lastTapAt = timestamp
        return [1, 0]
    }

    mutating func cancel() -> [UInt8] {
        let result: [UInt8] = dragging ? [0] : []
        singleFingerActive = false
        dragging = false; dragCandidate = false; lastTapAt = nil
        return result
    }

    /// Joining a second finger retires the single-finger gesture, releasing any drag.
    mutating func secondFingerBegan() -> [UInt8] {
        let release = cancel()
        twoFingerActive = true
        twoFingerScrolled = false
        return release
    }

    mutating func twoFingerScrollBegan() {
        twoFingerScrolled = true
    }

    mutating func endTwoFingerTap() -> [UInt8] {
        defer { twoFingerActive = false }
        return twoFingerActive && !twoFingerScrolled ? [2, 0] : []
    }

    mutating func setCursor(_ point: CGPoint, bounds: CGRect) { cursor = Self.clamp(point, to: bounds) }

    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return point }
        return CGPoint(x: min(max(point.x, rect.minX), rect.maxX.nextDown),
                       y: min(max(point.y, rect.minY), rect.maxY.nextDown))
    }

    /// Offset adjustment in view coordinates needed to keep a cursor within the inset viewport.
    static func edgePan(cursor: CGPoint, viewport: CGRect, inset: CGFloat = 40) -> CGPoint {
        let xInset = min(inset, viewport.width / 2)
        let yInset = min(inset, viewport.height / 2)
        let x = cursor.x < viewport.minX + xInset ? viewport.minX + xInset - cursor.x
            : cursor.x > viewport.maxX - xInset ? viewport.maxX - xInset - cursor.x : 0
        let y = cursor.y < viewport.minY + yInset ? viewport.minY + yInset - cursor.y
            : cursor.y > viewport.maxY - yInset ? viewport.maxY - yInset - cursor.y : 0
        return CGPoint(x: x, y: y)
    }
}

enum TouchInputMode: String, CaseIterable {
    case direct, trackpad
}

struct TouchInputPreferenceStore {
    var defaults: UserDefaults = .standard
    func mode(for hostID: String) -> TouchInputMode {
        TouchInputMode(rawValue: defaults.string(forKey: "touchInputMode.\(hostID)") ?? "") ?? .direct
    }
    func set(_ mode: TouchInputMode, for hostID: String) {
        defaults.set(mode.rawValue, forKey: "touchInputMode.\(hostID)")
    }
}
