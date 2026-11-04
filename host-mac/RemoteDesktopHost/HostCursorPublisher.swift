import AppKit
import CoreGraphics
import CryptoKit
import Foundation

struct HostCursorShapeHistory {
    enum Update: Equatable { case none, shape, reference }
    private var current: String?
    private var sent = Set<String>()

    mutating func update(_ id: String) -> Update {
        guard current != id else { return .none }
        current = id
        return sent.insert(id).inserted ? .shape : .reference
    }
}

struct HostCursorPositionState {
    private(set) var bounds: CGRect
    private(set) var lastCommanded: CGPoint?
    private(set) var lastReported: CGPoint?

    init(bounds: CGRect) { self.bounds = bounds }

    mutating func updateBounds(_ bounds: CGRect) {
        guard self.bounds != bounds else { return }
        self.bounds = bounds
        lastCommanded = nil
        lastReported = nil
    }

    mutating func recordClient(_ point: CGPoint) {
        lastCommanded = point
        lastReported = nil
    }

    mutating func positionToPublish(global: CGPoint) -> CGPoint? {
        guard bounds.contains(global) else { return nil }
        let position = CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY)
        guard HostCursorPublisher.shouldPublish(position: position, lastCommanded: lastCommanded,
                                                lastReported: lastReported) else { return nil }
        lastReported = position
        return position
    }
}

/// Per-control-channel cursor state. All mutable state is confined to the main queue.
final class HostCursorPublisher {
    typealias Send = (Data) -> Void
    private let send: Send
    private var positionState: HostCursorPositionState
    private var timer: Timer?
    private var shapeHistory = HostCursorShapeHistory()

    init(displayBounds: CGRect, send: @escaping Send) {
        self.positionState = HostCursorPositionState(bounds: displayBounds)
        self.send = send
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        timer = nil
    }

    func updateDisplayBounds(_ bounds: CGRect) {
        dispatchPrecondition(condition: .onQueue(.main))
        positionState.updateBounds(bounds)
    }

    func recordClientPosition(_ point: CGPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        positionState.recordClient(point)
    }

    private func poll() {
        publishShape(NSCursor.currentSystem ?? .arrow)
        guard let global = CGEvent(source: nil)?.location,
              let position = positionState.positionToPublish(global: global) else { return }
        sendObject(["t": "cursorPosition", "x": position.x, "y": position.y])
    }

    static func shouldPublish(position: CGPoint, lastCommanded: CGPoint?, lastReported: CGPoint?) -> Bool {
        if let lastCommanded, hypot(position.x - lastCommanded.x, position.y - lastCommanded.y) <= 2 { return false }
        if let lastReported, position == lastReported { return false }
        return true
    }

    private func publishShape(_ cursor: NSCursor) {
        guard let shape = Self.shape(cursor) ?? Self.shape(.arrow) else { return }
        switch shapeHistory.update(shape.id) {
        case .none: break
        case .reference:
            sendObject(["t": "cursorShapeRef", "id": shape.id])
        case .shape:
            sendObject(["t": "cursorShape", "id": shape.id, "png": shape.png.base64EncodedString(),
                        "hotspotX": shape.hotspot.x, "hotspotY": shape.hotspot.y,
                        "widthPt": shape.size.width, "heightPt": shape.size.height])
        }
    }

    private func sendObject(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data)
    }

    private struct Shape {
        let id: String
        let png: Data
        let hotspot: CGPoint
        let size: CGSize
    }

    private static func shape(_ cursor: NSCursor) -> Shape? {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= 64 * 1024 else { return nil }
        let hot = cursor.hotSpot
        var digestInput = png
        digestInput.append(Data("|\(hot.x)|\(hot.y)|\(size.width)|\(size.height)".utf8))
        let id = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        return Shape(id: id, png: png, hotspot: hot, size: size)
    }
}
