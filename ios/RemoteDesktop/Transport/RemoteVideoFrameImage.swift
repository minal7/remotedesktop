import CoreImage
import CoreVideo
import Foundation
import ImageIO
import LiveKitWebRTC

/// Retains the exact native or staged pixels used by the lazy CI image.
/// This is decoded-frame preparation, not evidence of capture or presentation.
struct RemoteVideoFrameImage {
    enum Preparation {
        case ready(RemoteVideoFrameImage)
        case unsupported
        case resourceFailure
    }
    let image: CIImage
    let pixelBuffer: CVPixelBuffer

    static func prepare(_ frame: RTCVideoFrame) -> Preparation {
        if let native = frame.buffer as? RTCCVPixelBuffer {
            let formats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB]
            guard formats.contains(CVPixelBufferGetPixelFormatType(native.pixelBuffer)),
                  let geometry = RemoteVideoPixelGeometry(frameWidth: Int(frame.width), frameHeight: Int(frame.height),
                    bufferWidth: CVPixelBufferGetWidth(native.pixelBuffer), bufferHeight: CVPixelBufferGetHeight(native.pixelBuffer),
                    cropX: Int(native.cropX), cropY: Int(native.cropY), cropWidth: Int(native.cropWidth), cropHeight: Int(native.cropHeight),
                    rotation: frame.rotation.rawValue),
                  let prepared = image(pixelBuffer: native.pixelBuffer, geometry: geometry) else { return .unsupported }
            return .ready(prepared)
        }

        // The bundled API's native software-decoder wrapper exposes I420
        // planes directly. Do not ask unknown/HDR/native buffers to convert
        // through toI420(), which can allocate and discard format metadata.
        guard let planar = frame.buffer as? LKRTCI420Buffer,
              Int(planar.width) == Int(frame.width), Int(planar.height) == Int(frame.height),
              let layout = RemoteVideoI420Layout(width: Int(planar.width), height: Int(planar.height),
                chromaWidth: Int(planar.chromaWidth), chromaHeight: Int(planar.chromaHeight),
                strideY: Int(planar.strideY), strideU: Int(planar.strideU), strideV: Int(planar.strideV)),
              let geometry = RemoteVideoPixelGeometry(frameWidth: layout.width, frameHeight: layout.height,
                bufferWidth: layout.storageWidth, bufferHeight: layout.storageHeight,
                cropX: 0, cropY: 0, cropWidth: layout.width, cropHeight: layout.height,
                rotation: frame.rotation.rawValue) else { return .unsupported }

        var allocated: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, layout.storageWidth, layout.storageHeight,
                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &allocated) == kCVReturnSuccess,
              let output = allocated,
              CVPixelBufferIsPlanar(output), CVPixelBufferGetPlaneCount(output) == 2,
              CVPixelBufferGetWidthOfPlane(output, 0) == layout.storageWidth,
              CVPixelBufferGetHeightOfPlane(output, 0) == layout.storageHeight,
              CVPixelBufferGetWidthOfPlane(output, 1) == layout.chromaWidth,
              CVPixelBufferGetHeightOfPlane(output, 1) == layout.chromaHeight,
              CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return .resourceFailure }

        let strideY = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let strideUV = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        let copied: Bool
        if let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)?.assumingMemoryBound(to: UInt8.self),
           let uv = CVPixelBufferGetBaseAddressOfPlane(output, 1)?.assumingMemoryBound(to: UInt8.self),
           let yCount = RemoteVideoI420Layout.destinationCount(stride: strideY, rows: layout.storageHeight, rowBytes: layout.storageWidth),
           let uvCount = RemoteVideoI420Layout.destinationCount(stride: strideUV, rows: layout.chromaHeight, rowBytes: layout.storageWidth) {
            // Native plane lengths follow the retained WebRTC buffer's public
            // stride/geometry contract. These are not untrusted wire pointers.
            copied = withExtendedLifetime(planar) {
                layout.pack(y: UnsafeBufferPointer(start: planar.dataY, count: layout.ySpan),
                    u: UnsafeBufferPointer(start: planar.dataU, count: layout.uSpan),
                    v: UnsafeBufferPointer(start: planar.dataV, count: layout.vSpan),
                    destinationY: UnsafeMutableBufferPointer(start: y, count: yCount), strideY: strideY,
                    destinationUV: UnsafeMutableBufferPointer(start: uv, count: uvCount), strideUV: strideUV)
            }
        } else { copied = false }
        let unlocked = CVPixelBufferUnlockBaseAddress(output, []) == kCVReturnSuccess
        guard copied, unlocked else { return .resourceFailure }

        // RTCVideoFrame/RTCI420Buffer expose no color-space metadata here.
        // Explicit SDR compatibility default: full-range BT.601 YCbCr with
        // centered chroma, interpreted as sRGB. This is not a recovered source
        // profile or proof of parity with the bundled renderer's native output.
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        guard let prepared = image(pixelBuffer: output, geometry: geometry) else { return .resourceFailure }
        return .ready(prepared)
    }

    private static func image(pixelBuffer: CVPixelBuffer, geometry: RemoteVideoPixelGeometry) -> RemoteVideoFrameImage? {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        guard input.extent == CGRect(x: 0, y: 0, width: geometry.bufferWidth, height: geometry.bufferHeight) else { return nil }
        var image = input.cropped(to: geometry.cropInImageCoordinates)
            .transformed(by: CGAffineTransform(translationX: -geometry.cropInImageCoordinates.minX,
                                               y: -geometry.cropInImageCoordinates.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(geometry.frameWidth) / CGFloat(geometry.cropWidth),
                                               y: CGFloat(geometry.frameHeight) / CGFloat(geometry.cropHeight)))
        switch geometry.rotation {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        return .init(image: image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
                     pixelBuffer: pixelBuffer)
    }
}

/// Validated 8-bit planar input and even NV12 storage. Odd right/bottom luma
/// edges are extended, then cropped before adaptation/rotation in Core Image.
struct RemoteVideoI420Layout {
    let width: Int, height: Int, chromaWidth: Int, chromaHeight: Int
    let storageWidth: Int, storageHeight: Int
    let strideY: Int, strideU: Int, strideV: Int
    let ySpan: Int, uSpan: Int, vSpan: Int
    private static let maximumPlaneSpan = 64 * 1_024 * 1_024

    init?(width: Int, height: Int, chromaWidth: Int, chromaHeight: Int, strideY: Int, strideU: Int, strideV: Int) {
        let limit = DesktopVideoQuality.maximumEncodedDimension
        guard width > 0, height > 0, width <= limit, height <= limit,
              chromaWidth == (width + 1) / 2, chromaHeight == (height + 1) / 2,
              let ySpan = Self.sourceSpan(stride: strideY, rows: height, rowBytes: width),
              let uSpan = Self.sourceSpan(stride: strideU, rows: chromaHeight, rowBytes: chromaWidth),
              let vSpan = Self.sourceSpan(stride: strideV, rows: chromaHeight, rowBytes: chromaWidth) else { return nil }
        self.width = width; self.height = height; self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
        storageWidth = chromaWidth * 2; storageHeight = chromaHeight * 2
        self.strideY = strideY; self.strideU = strideU; self.strideV = strideV
        self.ySpan = ySpan; self.uSpan = uSpan; self.vSpan = vSpan
    }

    private static func sourceSpan(stride: Int, rows: Int, rowBytes: Int) -> Int? {
        guard rows > 0, rowBytes > 0, stride >= rowBytes, stride <= maximumPlaneSpan else { return nil }
        let (offset, overflow) = stride.multipliedReportingOverflow(by: rows - 1)
        let (count, additionOverflow) = offset.addingReportingOverflow(rowBytes)
        guard !overflow, !additionOverflow, count <= maximumPlaneSpan else { return nil }
        return count
    }

    static func destinationCount(stride: Int, rows: Int, rowBytes: Int) -> Int? {
        guard rows > 0, rowBytes > 0, stride >= rowBytes else { return nil }
        let (count, overflow) = stride.multipliedReportingOverflow(by: rows)
        guard !overflow, count <= maximumPlaneSpan else { return nil }
        return count
    }

    /// Source and destination storage must not overlap. Validate every span
    /// before writing; copy visible bytes only, never source row padding.
    func pack(y: UnsafeBufferPointer<UInt8>, u: UnsafeBufferPointer<UInt8>, v: UnsafeBufferPointer<UInt8>,
              destinationY: UnsafeMutableBufferPointer<UInt8>, strideY: Int,
              destinationUV: UnsafeMutableBufferPointer<UInt8>, strideUV: Int) -> Bool {
        guard y.count >= ySpan, u.count >= uSpan, v.count >= vSpan,
              let ySource = y.baseAddress, let uSource = u.baseAddress, let vSource = v.baseAddress,
              let yOutput = destinationY.baseAddress, let uvOutput = destinationUV.baseAddress,
              let yCount = Self.destinationCount(stride: strideY, rows: storageHeight, rowBytes: storageWidth),
              let uvCount = Self.destinationCount(stride: strideUV, rows: chromaHeight, rowBytes: storageWidth),
              destinationY.count >= yCount, destinationUV.count >= uvCount else { return false }
        for row in 0..<storageHeight {
            let source = ySource.advanced(by: min(row, height - 1) * self.strideY)
            let output = yOutput.advanced(by: row * strideY)
            output.initialize(repeating: 0, count: strideY)
            output.update(from: source, count: width)
            if storageWidth > width { output[width] = source[width - 1] }
        }
        for row in 0..<chromaHeight {
            let u = uSource.advanced(by: row * strideU), v = vSource.advanced(by: row * strideV)
            let output = uvOutput.advanced(by: row * strideUV)
            output.initialize(repeating: 0, count: strideUV)
            for column in 0..<chromaWidth { output[column * 2] = u[column]; output[column * 2 + 1] = v[column] }
        }
        return true
    }
}
