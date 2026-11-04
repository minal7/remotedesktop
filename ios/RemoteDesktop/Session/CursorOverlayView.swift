import UIKit
#if DEBUG
import os.signpost
#endif

#if DEBUG
/// Synthetic acceptance runs only; no image, shape ID, or user data is stored.
enum CursorAcceptanceTrace {
    static var arrival: CFTimeInterval?
    private static let collector = LatencyStatsCollector(side: "cursor-acceptance", enabled: enabled)
    static var enabled: Bool {
        LatencyStatsCollector.enabled && ProcessInfo.processInfo.environment["CURSOR_DIAGNOSTICS"] == "1"
    }
    static var capabilityOff: Bool {
        capabilityOff(labEnabled: LatencyStatsCollector.enabled, environment: ProcessInfo.processInfo.environment)
    }
    static func capabilityOff(labEnabled: Bool, environment: [String: String]) -> Bool {
        labEnabled && environment["CURSOR_CAPABILITY_OFF"] == "1"
    }
    static func sample(event: String, point: CGPoint?, startedAt: CFTimeInterval?, completedAt: CFTimeInterval) -> [String: Any] {
        var row: [String: Any] = ["type": "cursor", "event": event, "time": completedAt]
        if let point, point.x.isFinite, point.y.isFinite { row["x"] = point.x; row["y"] = point.y }
        if let startedAt, startedAt.isFinite, completedAt >= startedAt { row["elapsedMs"] = (completedAt - startedAt) * 1000 }
        return row
    }
    static func recordGeometry(rect: CGRect, display: DisplayInfo) {
        guard enabled, RemoteScreenGeometry.isFiniteRectangle(rect), display.w > 0, display.h > 0 else { return }
        collector.trace(["type": "cursor", "event": "geometry", "time": CACurrentMediaTime(),
                         "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
                         "displayWidth": display.w, "displayHeight": display.h])
    }
    static func record(event: String, point: CGPoint? = nil, startedAt: CFTimeInterval? = nil, completedAt: CFTimeInterval? = nil) {
        guard enabled else { return }
        let row = sample(event: event, point: point, startedAt: startedAt, completedAt: completedAt ?? CACurrentMediaTime())
        collector.trace(row)
    }
}
#endif

/// Host shape IDs are unique only within one transport session. The host may
/// refer to an earlier shape after an input-handshake renewal on that session.
struct CursorShapeCache {
    private var peerID: ObjectIdentifier?
    private(set) var shapes: [String: HostCursorShape] = [:]
    private(set) var selectedID: String?

    mutating func bindPeer(_ peer: AnyObject?) {
        let next = peer.map { ObjectIdentifier($0) }
        guard next != peerID else { return }
        peerID = next
        shapes.removeAll()
        selectedID = nil
    }

    mutating func store(_ shape: HostCursorShape) {
        shapes[shape.id] = shape
        selectedID = shape.id
    }

    mutating func select(_ id: String) { selectedID = id }
}

/// Cursor artwork lives inside the video content's coordinate system, so the
/// same transform used by input also transforms the hotspot and artwork.
final class CursorOverlayView: CALayer {
    private struct Shape {
        let image: CGImage
        let hotspot: CGPoint
        let size: CGSize
    }

    private let artwork = CALayer()
    private var shapes: [String: Shape] = [:]
    private var selectedID: String?
    private var contentScale = CGSize(width: 1, height: 1)
    private(set) var cursorContentPoint: CGPoint = .zero
    private(set) var hasPosition = false
    private var enabled = false
    private var surfaceVisible = false
    private var lastLocalMove: CFTimeInterval?
    private var pendingHostMove: DispatchWorkItem?
    #if DEBUG
    private let signpostLog = OSLog(subsystem: "com.threadmark.remotedesktop.client", category: "CursorOverlay")
    #endif

    override init() {
        super.init()
        isHidden = true
        artwork.contentsGravity = .resize
        addSublayer(artwork)
        updateShape()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled {
            pendingHostMove?.cancel()
            pendingHostMove = nil
            hasPosition = false
            lastLocalMove = nil
            selectedID = nil
            shapes.removeAll()
            updateShape()
        }
        updateVisibility()
    }

    func setSurfaceVisible(_ visible: Bool) {
        surfaceVisible = visible
        updateVisibility()
    }

    func setContentScale(_ scale: CGSize) {
        guard scale.width.isFinite, scale.height.isFinite, scale.width > 0, scale.height > 0 else { return }
        contentScale = scale
        updateShape()
    }

    func installShape(id: String, png: Data, hotspot: CGPoint, size: CGSize) {
        guard !id.isEmpty, png.count <= 64 * 1024,
              hotspot.x.isFinite, hotspot.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= 1024, size.height <= 1024,
              hotspot.x >= 0, hotspot.y >= 0, hotspot.x <= size.width, hotspot.y <= size.height,
              let image = UIImage(data: png)?.cgImage else { return }
        shapes[id] = Shape(image: image, hotspot: hotspot, size: size)
        setShape(id: id)
    }

    func setShape(id: String) {
        selectedID = id
        updateShape()
    }

    func moveCursor(toContentPoint point: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard point.x.isFinite, point.y.isFinite else { return }
        pendingHostMove?.cancel()
        pendingHostMove = nil
        guard enabled else { cursorContentPoint = point; return }
        lastLocalMove = now
        move(to: point, signpost: true, startedAt: now)
    }

    func moveHostCursor(toContentPoint point: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard enabled, point.x.isFinite, point.y.isFinite else { return }
        pendingHostMove?.cancel()
        pendingHostMove = nil
        #if DEBUG
        let arrival = CursorAcceptanceTrace.arrival ?? now
        #else
        let arrival = now
        #endif
        let delay = lastLocalMove.map { max(0, 0.150 - (now - $0)) } ?? 0
        guard delay > 0 else {
            move(to: point, signpost: false, startedAt: arrival)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            self.pendingHostMove = nil
            self.move(to: point, signpost: false, startedAt: arrival)
        }
        pendingHostMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func move(to point: CGPoint, signpost: Bool, startedAt: CFTimeInterval) {
        #if DEBUG
        let signpostID = OSSignpostID(log: signpostLog)
        if signpost { os_signpost(.begin, log: signpostLog, name: "InputToCursorCommit", signpostID: signpostID) }
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if DEBUG
        let log = signpostLog
        let shouldTrace = CursorAcceptanceTrace.enabled
        if signpost || shouldTrace {
            CATransaction.setCompletionBlock {
                if signpost { os_signpost(.end, log: log, name: "InputToCursorCommit", signpostID: signpostID) }
                if shouldTrace {
                    let completedAt = CACurrentMediaTime()
                    Task { @MainActor in
                        CursorAcceptanceTrace.record(event: signpost ? "input_commit" : "host_commit",
                                                     point: point, startedAt: startedAt, completedAt: completedAt)
                    }
                }
            }
        }
        #endif
        cursorContentPoint = point
        hasPosition = true
        artwork.position = point
        updateVisibility()
        CATransaction.commit()
    }

    private func updateVisibility() {
        isHidden = !(enabled && surfaceVisible && hasPosition)
    }

    private func updateShape() {
        let fallback = UIImage(named: "RemoteCursorArrow")?.cgImage.map {
            Shape(image: $0, hotspot: .zero, size: CGSize(width: 16, height: 24))
        }
        guard let shape = selectedID.flatMap({ shapes[$0] }) ?? fallback else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if DEBUG
        if CursorAcceptanceTrace.enabled, let arrival = CursorAcceptanceTrace.arrival {
            CATransaction.setCompletionBlock {
                let completedAt = CACurrentMediaTime()
                Task { @MainActor in CursorAcceptanceTrace.record(event: "shape_commit", startedAt: arrival, completedAt: completedAt) }
            }
        }
        #endif
        artwork.contents = shape.image
        artwork.bounds = CGRect(origin: .zero, size: CGSize(width: shape.size.width * contentScale.width,
                                                           height: shape.size.height * contentScale.height))
        artwork.anchorPoint = CGPoint(x: shape.hotspot.x / shape.size.width, y: shape.hotspot.y / shape.size.height)
        artwork.position = cursorContentPoint
        CATransaction.commit()
    }
}
