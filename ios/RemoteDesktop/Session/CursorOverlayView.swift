import UIKit
#if DEBUG
import os.signpost
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
        move(to: point, signpost: true)
    }

    func moveHostCursor(toContentPoint point: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard enabled, point.x.isFinite, point.y.isFinite else { return }
        pendingHostMove?.cancel()
        pendingHostMove = nil
        let delay = lastLocalMove.map { max(0, 0.150 - (now - $0)) } ?? 0
        guard delay > 0 else {
            move(to: point, signpost: false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            self.pendingHostMove = nil
            self.move(to: point, signpost: false)
        }
        pendingHostMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func move(to point: CGPoint, signpost: Bool) {
        #if DEBUG
        let signpostID = OSSignpostID(log: signpostLog)
        if signpost { os_signpost(.begin, log: signpostLog, name: "InputToCursorCommit", signpostID: signpostID) }
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if DEBUG
        if signpost {
            let log = signpostLog
            CATransaction.setCompletionBlock { os_signpost(.end, log: log, name: "InputToCursorCommit", signpostID: signpostID) }
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
        artwork.contents = shape.image
        artwork.bounds = CGRect(origin: .zero, size: CGSize(width: shape.size.width * contentScale.width,
                                                           height: shape.size.height * contentScale.height))
        artwork.anchorPoint = CGPoint(x: shape.hotspot.x / shape.size.width, y: shape.hotspot.y / shape.size.height)
        artwork.position = cursorContentPoint
        CATransaction.commit()
    }
}
