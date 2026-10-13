import CoreGraphics

struct PixelPointSnap {
    let point: CGPoint
    let mark: PixelElementMark?
}

enum PixelTargetSnapping {
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXTextView", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXMenuItem",
        "AXMenuBarItem", "AXSlider", "AXIncrementor", "AXSwitch", "AXDisclosureTriangle"
    ]

    static func resolve(_ point: CGPoint, in marks: [PixelElementMark], maximumDistance: CGFloat = 12) -> PixelPointSnap {
        guard point.x.isFinite, point.y.isFinite, maximumDistance.isFinite, maximumDistance >= 0,
              !marks.contains(where: { $0.screenRect.contains(point) }) else {
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
        guard let nearest = candidates.first,
              candidates.dropFirst().first.map({ abs($0.1 - nearest.1) > 0.0001 }) ?? true else {
            return PixelPointSnap(point: point, mark: nil)
        }
        return PixelPointSnap(point: CGPoint(x: nearest.0.screenRect.midX, y: nearest.0.screenRect.midY), mark: nearest.0)
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
        guard let rect = imageRect(screenRect, captureBounds: captureBounds, imageSize: CGSize(width: image.width, height: image.height)) else { return nil }
        return image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
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
}
