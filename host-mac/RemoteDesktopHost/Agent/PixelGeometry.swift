import CoreGraphics
import ScreenCaptureKit

@MainActor
final class PixelResolvedTargets {
    let references: [Int: any PixelElementReference]
    private(set) var resolutionNote: String?

    init(references: [Int: any PixelElementReference], resolutionNote: String? = nil) {
        self.references = references; self.resolutionNote = resolutionNote
    }

    func appendResolutionNote(_ note: String) {
        guard !(resolutionNote?.contains(note) ?? false) else { return }
        resolutionNote = [resolutionNote, note].compactMap { $0 }.joined(separator: "; ")
    }
}

struct PixelPointSnap {
    let point: CGPoint
    let mark: PixelElementMark?
    let note: String?
    let keepsCoordinate: Bool

    init(point: CGPoint, mark: PixelElementMark?, note: String? = nil, keepsCoordinate: Bool = false) {
        self.point = point; self.mark = mark; self.note = note; self.keepsCoordinate = keepsCoordinate
    }
}

@MainActor
enum PixelTargetSnapping {
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXTextView", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXRow", "AXMenuItem",
        "AXMenuBarItem", "AXSlider", "AXIncrementor", "AXSwitch", "AXDisclosureTriangle"
    ]

    static func resolve(_ point: CGPoint, in marks: [PixelElementMark], maximumDistance: CGFloat = 12,
                        deadline: ContinuousClock.Instant = .now + .milliseconds(300)) -> PixelPointSnap {
        guard point.x.isFinite, point.y.isFinite, maximumDistance.isFinite, maximumDistance >= 0 else {
            return PixelPointSnap(point: point, mark: nil)
        }
        let candidates = marks.filter { mark in
            interactiveRoles.contains(mark.role) && mark.inView && !mark.screenRect.isNull && !mark.screenRect.isEmpty &&
            mark.screenRect.minX.isFinite && mark.screenRect.minY.isFinite &&
            mark.screenRect.width.isFinite && mark.screenRect.height.isFinite
        }.map { mark -> (PixelElementMark, CGFloat) in
            let dx = point.x - mark.screenRect.midX, dy = point.y - mark.screenRect.midY
            return (mark, dx * dx + dy * dy)
        }.filter { $0.1 <= maximumDistance * maximumDistance }
            .sorted { $0.1 < $1.1 }
        let containingCandidates = candidates.filter { $0.0.screenRect.contains(point) }
        if let containing = uniqueNearest(containingCandidates) {
            if let reference = containing.0.reference, let identity = containing.0.identity {
                switch reference.acceptsHit(at: point, intendedIdentity: identity, deadline: deadline) {
                case true: return PixelPointSnap(point: point, mark: nil)
                case nil:
                    return PixelPointSnap(point: point, mark: containing.0,
                        note: "target hit could not be verified", keepsCoordinate: true)
                case false:
                    if let alternative = nearestHitPoint(to: point, in: containing.0.screenRect,
                        deadline: deadline, matches: { reference.acceptsHit(at: $0, intendedIdentity: identity, deadline: deadline) }) {
                        return PixelPointSnap(point: alternative, mark: containing.0,
                            note: "adjusted click within mark \(containing.0.id)", keepsCoordinate: true)
                    }
                    return PixelPointSnap(point: point, mark: containing.0, note: "target overlapped", keepsCoordinate: true)
                }
            }
            return PixelPointSnap(point: point, mark: nil)
        }
        if !containingCandidates.isEmpty {
            return PixelPointSnap(point: point, mark: nil, note: "target overlapped", keepsCoordinate: true)
        }
        guard !marks.contains(where: { $0.screenRect.contains(point) }),
              let nearest = uniqueNearest(candidates) else { return PixelPointSnap(point: point, mark: nil) }
        return PixelPointSnap(point: CGPoint(x: nearest.0.screenRect.midX, y: nearest.0.screenRect.midY), mark: nearest.0)
    }

    static func resolvedAction(_ action: AgentAction, originalPoint: CGPoint, snap: PixelPointSnap,
                               imageSize: CGSize, screenBounds: CGRect) -> (action: AgentAction, note: String?) {
        guard snap.keepsCoordinate else {
            let rewritten = resolveClick(action, snappedMark: snap.mark)
            return (rewritten.action, snap.note ?? rewritten.note)
        }
        guard snap.point != originalPoint,
              let pixel = PixelGeometry.imagePoint(snap.point, imageSize: imageSize, screenBounds: screenBounds),
              case let .click(.point, button, count) = action else { return (action, snap.note) }
        return (.click(target: .point(x: Double(pixel.x), y: Double(pixel.y)), button: button, count: count), snap.note)
    }

    private static func uniqueNearest(_ candidates: [(PixelElementMark, CGFloat)]) -> (PixelElementMark, CGFloat)? {
        guard let nearest = candidates.first,
              candidates.dropFirst().first.map({ abs($0.1 - nearest.1) > 0.0001 }) ?? true else { return nil }
        return nearest
    }

    static func nearestHitPoint(to origin: CGPoint, in rect: CGRect, deadline: ContinuousClock.Instant,
                                matches: (CGPoint) -> Bool?) -> CGPoint? {
        // Bounded rays refine observed hits; this is not an exhaustive pixel-level proof.
        let directions: [(CGFloat, CGFloat)] = [(1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (1, -1), (-1, 1), (-1, -1)]
        let points = [0.15, 0.30, 0.45].flatMap { fraction in
            directions.map { dx, dy in
                CGPoint(x: origin.x + rect.width * fraction * dx,
                        y: origin.y + rect.height * fraction * dy)
            }
        }.filter { rect.contains($0) }.sorted {
            let left = ($0.x - origin.x) * ($0.x - origin.x) + ($0.y - origin.y) * ($0.y - origin.y)
            let right = ($1.x - origin.x) * ($1.x - origin.x) + ($1.y - origin.y) * ($1.y - origin.y)
            return left == right ? ($0.y, $0.x) < ($1.y, $1.x) : left < right
        }
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for candidate in points {
            guard ContinuousClock.now < deadline else { return best }
            guard matches(candidate) == true else { continue }
            var valid = candidate
            var invalid = origin
            for _ in 0..<8 {
                guard ContinuousClock.now < deadline else { break }
                let midpoint = CGPoint(x: (valid.x + invalid.x) / 2, y: (valid.y + invalid.y) / 2)
                guard rect.contains(midpoint) else { break }
                if matches(midpoint) == true { valid = midpoint } else { invalid = midpoint }
            }
            let dx = valid.x - origin.x, dy = valid.y - origin.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance { best = valid; bestDistance = distance }
        }
        return best
    }

    static func resolveClick(_ action: AgentAction, snappedMark: PixelElementMark?) -> (action: AgentAction, note: String?) {
        guard case let .click(.point, button, count) = action, let snappedMark else { return (action, nil) }
        let note = "snapped to mark \(snappedMark.id)\(snappedMark.name.isEmpty ? "" : " \"\(snappedMark.name)\"")"
        return (.click(target: .element(id: snappedMark.id), button: button, count: count), note)
    }
}

enum PixelTargetContextLabel {
    static func resolve(_ action: AgentAction, targets: [AgentElement],
                        lookup: (Double, Double) -> String?) -> String? {
        guard case let .click(target, _, _) = action else { return nil }
        switch target {
        case let .point(x, y):
            guard targets.first?.name.isEmpty != false else { return nil }
            return lookup(x, y)
        case let .element(id):
            guard let element = targets.first(where: { $0.id == id }), element.name.isEmpty else { return nil }
            return lookup(element.bbox.x + element.bbox.width / 2, element.bbox.y + element.bbox.height / 2)
        }
    }

    static func rebound(_ action: AgentAction, targets: [AgentElement], previous: String?,
                        lookup: (Double, Double) -> String?) -> String? {
        guard case .click = action else { return previous }
        return resolve(action, targets: targets, lookup: lookup)
    }
}

enum PixelGeometry {
    static func nativeWindowCaptureConfiguration(width: Int, height: Int) -> SCStreamConfiguration? {
        guard #available(macOS 14.2, *) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = false
        return configuration
    }

    static func screenCaptureRect(fromAppKit rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func nativeWindowPixelSize(windowBounds: CGRect, pointPixelScale: CGFloat) -> (width: Int, height: Int)? {
        guard valid(windowBounds), pointPixelScale.isFinite, pointPixelScale > 0 else { return nil }
        let width = (windowBounds.width * pointPixelScale).rounded(.up)
        let height = (windowBounds.height * pointPixelScale).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width < CGFloat(Int.max), height < CGFloat(Int.max) else { return nil }
        return (Int(width), Int(height))
    }

    static func imagePoint(_ screenPoint: CGPoint, imageSize: CGSize, screenBounds: CGRect) -> CGPoint? {
        guard valid(screenBounds), imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              screenPoint.x.isFinite, screenPoint.y.isFinite, screenBounds.contains(screenPoint) else { return nil }
        return CGPoint(x: (screenPoint.x - screenBounds.minX) * imageSize.width / screenBounds.width,
                       y: (screenPoint.y - screenBounds.minY) * imageSize.height / screenBounds.height)
    }

    static func point(_ imagePoint: CGPoint, imageSize: CGSize, screenBounds: CGRect) -> CGPoint? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              screenBounds.width.isFinite, screenBounds.height.isFinite, screenBounds.width > 0, screenBounds.height > 0,
              imagePoint.x.isFinite, imagePoint.y.isFinite, imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x < imageSize.width, imagePoint.y < imageSize.height else { return nil }
        let result = CGPoint(x: screenBounds.minX + imagePoint.x * screenBounds.width / imageSize.width,
                             y: screenBounds.minY + imagePoint.y * screenBounds.height / imageSize.height)
        return screenBounds.contains(result) ? result : nil
    }

    static func imageRect(_ screenRect: CGRect, captureBounds: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              captureBounds.width > 0, captureBounds.height > 0 else { return nil }
        let clipped = screenRect.intersection(captureBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return CGRect(x: (clipped.minX - captureBounds.minX) * imageSize.width / captureBounds.width,
                      y: (clipped.minY - captureBounds.minY) * imageSize.height / captureBounds.height,
                      width: clipped.width * imageSize.width / captureBounds.width,
                      height: clipped.height * imageSize.height / captureBounds.height)
    }

    static func crop(_ image: CGImage, screenRect: CGRect, captureBounds: CGRect) -> CGImage? {
        cropWithBounds(image, screenRect: screenRect, captureBounds: captureBounds)?.image
    }

    static func cropWithBounds(_ image: CGImage, screenRect: CGRect, captureBounds: CGRect)
        -> (image: CGImage, screenBounds: CGRect)? {
        guard let rect = imageRect(screenRect, captureBounds: captureBounds,
            imageSize: CGSize(width: image.width, height: image.height)) else { return nil }
        let pixelBounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelBounds.isNull, !pixelBounds.isEmpty, let cropped = image.cropping(to: pixelBounds) else { return nil }
        let screenPerPixelX = captureBounds.width / CGFloat(image.width)
        let screenPerPixelY = captureBounds.height / CGFloat(image.height)
        let actualBounds = CGRect(x: captureBounds.minX + pixelBounds.minX * screenPerPixelX,
            y: captureBounds.minY + pixelBounds.minY * screenPerPixelY,
            width: pixelBounds.width * screenPerPixelX,
            height: pixelBounds.height * screenPerPixelY)
        return (cropped, actualBounds)
    }

    static func resize(_ image: CGImage, width: Int) -> CGImage? {
        guard width > 0, image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: width,
                height: max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded())),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage()
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}

enum PixelWindowActionBoundary {
    static func allows(_ point: CGPoint, windowBounds: CGRect, menuBarBounds: [CGRect],
                       sameAppDialogBounds: [CGRect]) -> Bool {
        guard point.x.isFinite, point.y.isFinite, valid(windowBounds) else { return false }
        if windowBounds.contains(point) { return true }
        return (menuBarBounds + sameAppDialogBounds).contains { valid($0) && $0.contains(point) }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}
