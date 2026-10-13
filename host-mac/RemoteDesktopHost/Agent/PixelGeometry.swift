import CoreGraphics

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
