import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO

// All coordinates are integer pixels from the image's top-left corner.
struct Crop: Equatable {
    let x: Int, y: Int, width: Int, height: Int
    init(_ string: String) throws {
        let pieces = string.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count == 4, let x = Int(pieces[0]), let y = Int(pieces[1]),
              let width = Int(pieces[2]), let height = Int(pieces[3]),
              x >= 0, y >= 0, width >= 8, height >= 8 else { throw Problem.invalid("Invalid crop: \(string)") }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
struct Image {
    let width: Int, height: Int
    let luma: [Double]
    init(path: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0,
              image.width <= 16384, image.height <= 16384,
              image.width * image.height <= 32_000_000 else { throw Problem.invalid("Cannot decode bounded image: \(path)") }
        let w = image.width, h = image.height
        width = w; height = h
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Problem.invalid("sRGB unavailable") }
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // Drawing the CGImage directly into this bitmap preserves its
            // top-to-bottom row order. Flipping the context reverses rows,
            // making top-left crops from differently sized images disagree.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard success else { throw Problem.invalid("Cannot rasterize image: \(path)") }
        var values = [Double](); values.reserveCapacity(w * h)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            // Transparent inputs cannot be compared consistently with opaque display screenshots.
            guard rgba[i + 3] == 255 else { throw Problem.invalid("Image has transparency: \(path)") }
            values.append(0.2126 * Double(rgba[i]) + 0.7152 * Double(rgba[i + 1]) + 0.0722 * Double(rgba[i + 2]))
        }
        luma = values
    }
    func validate(_ c: Crop) throws {
        guard c.x <= width, c.y <= height, c.width <= width - c.x, c.height <= height - c.y else {
            throw Problem.invalid("Crop exceeds image")
        }
    }
    func extract(_ c: Crop) -> [Double] {
        (0..<c.height).flatMap { y in (0..<c.width).map { x in luma[(c.y + y) * width + c.x + x] } }
    }
}
enum Problem: Error { case invalid(String) }

// Bilinear sampling in original reference coordinates, with pixel centers at integers.
func sample(_ image: Image, x: Double, y: Double) -> Double {
    let fx = max(0, min(Double(image.width - 1), x))
    let fy = max(0, min(Double(image.height - 1), y))
    let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, image.width - 1), y1 = min(y0 + 1, image.height - 1)
    let dx = fx - Double(x0), dy = fy - Double(y0)
    let a = image.luma[y0 * image.width + x0] * (1 - dx) + image.luma[y0 * image.width + x1] * dx
    let b = image.luma[y1 * image.width + x0] * (1 - dx) + image.luma[y1 * image.width + x1] * dx
    return a * (1 - dy) + b * dy
}

// Mean of non-overlapping 8×8 luma SSIM blocks, matching LocalLatencyProbe.
func ssim(_ a: [Double], _ b: [Double], width: Int, height: Int) -> Double {
    let c1: Double = 6.5025, c2: Double = 58.5225
    var total = 0.0, count = 0
    for y in stride(from: 0, through: height - 8, by: 8) {
        for x in stride(from: 0, through: width - 8, by: 8) {
            let indices = (y..<y + 8).flatMap { row in (x..<x + 8).map { row * width + $0 } }
            let ma = indices.reduce(0.0) { $0 + a[$1] } / 64
            let mb = indices.reduce(0.0) { $0 + b[$1] } / 64
            let va = indices.reduce(0.0) { $0 + pow(a[$1] - ma, 2) } / 64
            let vb = indices.reduce(0.0) { $0 + pow(b[$1] - mb, 2) } / 64
            let cov = indices.reduce(0.0) { $0 + (a[$1] - ma) * (b[$1] - mb) } / 64
            total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
            count += 1
        }
    }
    return total / Double(count)
}

func object(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count <= 1_000_000,
          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Problem.invalid("Invalid geometry JSON: \(path)")
    }
    return result
}
func integers(_ value: Any?, count: Int) throws -> [Int] {
    guard let values = value as? [Any], values.count == count else { throw Problem.invalid("Invalid pixel geometry") }
    return try values.map { value in
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= 16384 else {
            throw Problem.invalid("Invalid bounded pixel geometry")
        }
        return number.intValue
    }
}
func rectangle(_ values: [Int]) throws -> Crop {
    try Crop(values.map { String($0) }.joined(separator: ","))
}
func contains(_ outer: Crop, _ inner: Crop) -> Bool {
    inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width
        && inner.y + inner.height <= outer.y + outer.height
}

do {
    let args = CommandLine.arguments
    guard args.count == 7 else {
        throw Problem.invalid("Usage: CompareStaticText REFERENCE.png A_CROP.png B_CROP.png FIXTURE_GEOMETRY.json CAPTURE_GEOMETRY.json OUTPUT.json")
    }
    let reference = try Image(path: args[1]), a = try Image(path: args[2]), b = try Image(path: args[3])
    let fixture = try object(args[4]), capture = try object(args[5])
    let referenceSize = try integers(fixture["image_pixels"], count: 2)
    let referenceCrop = try integers(fixture["crop_pixels"], count: 4)
    let capturedReferenceSize = try integers(capture["reference_pixels"], count: 2)
    let capturedReferenceCrop = try integers(capture["reference_crop_pixels"], count: 4)
    let screenSize = try integers(capture["image_pixels"], count: 2)
    let captureCropValues = try integers(capture["crop_pixels"], count: 4)
    guard referenceSize == [reference.width, reference.height], referenceSize == capturedReferenceSize,
          referenceCrop == capturedReferenceCrop, screenSize.allSatisfy({ $0 > 0 }),
          a.width == b.width, a.height == b.height,
          [a.width, a.height] == Array(captureCropValues[2...3]) else {
        throw Problem.invalid("Reference, A/B, or capture geometry does not match")
    }
    let sourceCrop = try rectangle(referenceCrop), captureCrop = try rectangle(captureCropValues)
    try reference.validate(sourceCrop)
    guard captureCrop.x + captureCrop.width <= screenSize[0], captureCrop.y + captureCrop.height <= screenSize[1],
          let fontGeometry = fixture["font_crops_pixels"] as? [String: Any] else {
        throw Problem.invalid("Capture crop or per-font geometry is invalid")
    }
    let scale = min(Double(screenSize[0]) / Double(reference.width), Double(screenSize[1]) / Double(reference.height))
    let originX = (Double(screenSize[0]) - Double(reference.width) * scale) / 2
    let originY = (Double(screenSize[1]) - Double(reference.height) * scale) / 2
    func mapped(_ crop: Crop) throws -> Crop {
        let left = Int((originX + Double(crop.x) * scale).rounded())
        let top = Int((originY + Double(crop.y) * scale).rounded())
        let right = Int((originX + Double(crop.x + crop.width) * scale).rounded())
        let bottom = Int((originY + Double(crop.y + crop.height) * scale).rounded())
        return try rectangle([left, top, right - left, bottom - top])
    }
    guard try mapped(sourceCrop) == captureCrop else { throw Problem.invalid("Capture crop does not match fixed full-canvas aspect fit") }
    var fontResults: [String: Any] = [:]
    for name in ["11pt", "12pt", "13pt"] {
        let fontCrop = try rectangle(integers(fontGeometry[name], count: 4))
        try reference.validate(fontCrop)
        guard contains(sourceCrop, fontCrop) else { throw Problem.invalid("Font crop lies outside reference crop") }
        let target = try mapped(fontCrop)
        guard contains(captureCrop, target) else { throw Problem.invalid("Mapped font crop lies outside captured crop") }
        var refValues = [Double](), aValues = [Double](), bValues = [Double]()
        refValues.reserveCapacity(target.width * target.height)
        aValues.reserveCapacity(target.width * target.height); bValues.reserveCapacity(target.width * target.height)
        for y in target.y..<(target.y + target.height) {
            for x in target.x..<(target.x + target.width) {
                let sourceX = (Double(x) + 0.5 - originX) / scale - 0.5
                let sourceY = (Double(y) + 0.5 - originY) / scale - 0.5
                refValues.append(sample(reference, x: sourceX, y: sourceY))
                let index = (y - captureCrop.y) * a.width + x - captureCrop.x
                aValues.append(a.luma[index]); bValues.append(b.luma[index])
            }
        }
        let av = ssim(refValues, aValues, width: target.width, height: target.height)
        let bv = ssim(refValues, bValues, width: target.width, height: target.height)
        fontResults[name] = ["a_ssim": av, "b_ssim": bv, "b_minus_a": bv - av,
            "a_vs_b_ssim": ssim(aValues, bValues, width: target.width, height: target.height),
            "reference_crop_pixels": [fontCrop.x, fontCrop.y, fontCrop.width, fontCrop.height],
            "screenshot_crop_pixels": [target.x, target.y, target.width, target.height]]
    }
    let result: [String: Any] = ["fonts": fontResults, "image_pixels": screenSize,
        "capture_crop_pixels": captureCropValues, "reference_pixels": referenceSize,
        "reference_crop_pixels": referenceCrop,
        "method": "sRGB luma, fixed full-canvas aspect-fit pixel-center bilinear reference sampling, non-overlapping 8x8 SSIM; no alignment search",
        "acceptance": "not assessed"]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: args[6]), options: .withoutOverwriting)
    print(String(decoding: data, as: UTF8.self))
} catch { fputs("\(error)\n", stderr); exit(1) }
