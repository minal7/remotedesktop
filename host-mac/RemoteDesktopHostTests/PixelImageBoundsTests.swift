import AppKit
import CoreGraphics
import XCTest
@testable import RemoteDesktopHost

final class PixelImageBoundsTests: XCTestCase {
    func testTallImageResizeFitsModelPixelBudgetAndKeepsGeometryMapping() throws {
        let source = try XCTUnwrap(makeImage(width: 1280, height: 3299))
        let sourcePNG = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        XCTAssertThrowsError(try ComputerUseModelImagePolicy.validatePNG(sourcePNG))
        let resized = try XCTUnwrap(PixelGeometry.resize(source, width: 1280))
        XCTAssertLessThanOrEqual(resized.width, 4096)
        XCTAssertLessThanOrEqual(resized.height, 4096)
        XCTAssertLessThanOrEqual(resized.width * resized.height, 4_194_304)
        let bitmap = NSBitmapImageRep(cgImage: resized)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertNoThrow(try ComputerUseModelImagePolicy.validatePNG(png))

        let screen = CGRect(x: 20, y: 30, width: 1280, height: 3299)
        let target = CGPoint(x: 640, y: 1600)
        let imagePoint = try XCTUnwrap(PixelGeometry.imagePoint(target,
            imageSize: CGSize(width: resized.width, height: resized.height), screenBounds: screen))
        let roundTrip = try XCTUnwrap(PixelGeometry.point(imagePoint,
            imageSize: CGSize(width: resized.width, height: resized.height), screenBounds: screen))
        XCTAssertEqual(roundTrip.x, target.x, accuracy: 0.01)
        XCTAssertEqual(roundTrip.y, target.y, accuracy: 0.01)
        let mark = try XCTUnwrap(PixelGeometry.imageRect(CGRect(x: 600, y: 1580, width: 80, height: 80),
            captureBounds: screen, imageSize: CGSize(width: resized.width, height: resized.height)))
        XCTAssertTrue(mark.contains(imagePoint))
    }

    func testLandscapeResizeAndExtremeDimensionsRemainBounded() throws {
        let landscape = try XCTUnwrap(makeImage(width: 1920, height: 1080))
        let resizedLandscape = try XCTUnwrap(PixelGeometry.resize(landscape, width: 1280))
        XCTAssertEqual(resizedLandscape.width, 1280)
        XCTAssertEqual(resizedLandscape.height, 720)
        let extreme = try XCTUnwrap(PixelGeometry.boundedPixelSize(width: Int.max, height: Int.max, maximumWidth: 1280))
        XCTAssertGreaterThan(extreme.width, 0)
        XCTAssertGreaterThan(extreme.height, 0)
        XCTAssertLessThanOrEqual(extreme.width, 4096)
        XCTAssertLessThanOrEqual(extreme.height, 4096)
        XCTAssertLessThanOrEqual(extreme.width * extreme.height, 4_194_304)
        let wide = try XCTUnwrap(PixelGeometry.boundedPixelSize(width: 10_000, height: 100, maximumWidth: 10_000))
        XCTAssertEqual(wide.width, 4096)
        XCTAssertEqual(wide.height, 41)
        let tall = try XCTUnwrap(PixelGeometry.boundedPixelSize(width: 100, height: 10_000, maximumWidth: 1280))
        XCTAssertEqual(tall.width, 41)
        XCTAssertEqual(tall.height, 4096)
        XCTAssertNil(PixelGeometry.boundedPixelSize(width: 0, height: 1, maximumWidth: 1280))
        XCTAssertNil(PixelGeometry.boundedPixelSize(width: 1, height: -1, maximumWidth: 1280))
        XCTAssertNil(PixelGeometry.boundedPixelSize(width: 1, height: 1, maximumWidth: 0))
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
