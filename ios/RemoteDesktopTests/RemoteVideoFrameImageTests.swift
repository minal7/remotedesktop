import XCTest
import CoreImage
import CoreVideo
import LiveKitWebRTC
@testable import RemoteDesktop

@MainActor
final class RemoteVideoFrameImageTests: XCTestCase {
    func test_i420PackingInterleavesVisibleChromaAndIgnoresSourcePadding() throws {
        let layout = try XCTUnwrap(RemoteVideoI420Layout(width: 4, height: 2, chromaWidth: 2, chromaHeight: 1,
            strideY: 7, strideU: 3, strideV: 4))
        // The final source row has no trailing padding in these arrays.
        let output = pack(layout, y: [1, 2, 3, 4, 251, 251, 251, 5, 6, 7, 8], u: [11, 12], v: [21, 22], strideY: 6, strideUV: 6)
        XCTAssertTrue(output.didPack)
        XCTAssertEqual(output.y, [1, 2, 3, 4, 0, 0, 5, 6, 7, 8, 0, 0])
        XCTAssertEqual(output.uv, [11, 21, 12, 22, 0, 0])
    }

    func test_i420OddDimensionsExtendOnlyTheVisibleLumaEdges() throws {
        let layout = try XCTUnwrap(RemoteVideoI420Layout(width: 3, height: 3, chromaWidth: 2, chromaHeight: 2,
            strideY: 4, strideU: 3, strideV: 4))
        XCTAssertEqual(layout.storageWidth, 4); XCTAssertEqual(layout.storageHeight, 4)
        let output = pack(layout, y: [1, 2, 3, 199, 4, 5, 6, 199, 7, 8, 9],
            u: [10, 11, 199, 12, 13], v: [20, 21, 199, 199, 22, 23], strideY: 6, strideUV: 6)
        XCTAssertTrue(output.didPack)
        XCTAssertEqual(output.y, [1, 2, 3, 3, 0, 0, 4, 5, 6, 6, 0, 0, 7, 8, 9, 9, 0, 0, 7, 8, 9, 9, 0, 0])
        XCTAssertEqual(output.uv, [10, 20, 11, 21, 0, 0, 12, 22, 13, 23, 0, 0])
        let geometry = try XCTUnwrap(RemoteVideoPixelGeometry(frameWidth: 3, frameHeight: 3, bufferWidth: 4, bufferHeight: 4,
            cropX: 0, cropY: 0, cropWidth: 3, cropHeight: 3, rotation: 0))
        XCTAssertEqual(geometry.cropInImageCoordinates, CGRect(x: 0, y: 1, width: 3, height: 3))
    }

    func test_i420SinglePixelPreservesSamplesInEvenStorage() throws {
        let layout = try XCTUnwrap(RemoteVideoI420Layout(width: 1, height: 1, chromaWidth: 1, chromaHeight: 1,
            strideY: 1, strideU: 1, strideV: 1))
        let output = pack(layout, y: [17], u: [128], v: [255], strideY: 2, strideUV: 2)
        XCTAssertTrue(output.didPack)
        XCTAssertEqual(output.y, [17, 17, 17, 17]); XCTAssertEqual(output.uv, [128, 255])
    }

    func test_i420LayoutRejectsInvalidDimensionsChromaAndUnboundedStrides() {
        for (width, height, chromaWidth, chromaHeight, y, u, v) in [
            (0, 2, 1, 1, 2, 1, 1), (2, -1, 1, 1, 2, 1, 1), (Int.max, 2, 1, 1, 2, 1, 1),
            (2, Int.max, 1, 1, 2, 1, 1), (3, 3, 1, 2, 3, 2, 2), (3, 3, 2, 1, 3, 2, 2),
            (2, 2, 1, 1, 1, 1, 1), (2, 2, 1, 1, 2, 0, 1), (2, 2, 1, 1, 2, 1, -1),
            (2, 2, 1, 1, Int.max, 1, 1), (2, 4, 1, 2, 2, Int.max, 1), (2, 4, 1, 2, 2, 1, Int.max),
            (2, 4, 1, 2, 64 * 1_024 * 1_024, 1, 1)
        ] {
            XCTAssertNil(RemoteVideoI420Layout(width: width, height: height, chromaWidth: chromaWidth,
                chromaHeight: chromaHeight, strideY: y, strideU: u, strideV: v))
        }
        XCTAssertNil(RemoteVideoI420Layout.destinationCount(stride: Int.max, rows: 2, rowBytes: 2))
        XCTAssertNil(RemoteVideoI420Layout.destinationCount(stride: 2, rows: Int.max, rowBytes: 2))
        XCTAssertNil(RemoteVideoI420Layout.destinationCount(stride: 2, rows: 0, rowBytes: 2))
    }

    func test_i420ShortSourceOrDestinationRejectsBeforeAnyWrite() throws {
        let layout = try XCTUnwrap(RemoteVideoI420Layout(width: 2, height: 2, chromaWidth: 1, chromaHeight: 1,
            strideY: 2, strideU: 1, strideV: 1))
        let cases: [(y: [UInt8], u: [UInt8], v: [UInt8], strideY: Int, strideUV: Int, yCount: Int, uvCount: Int)] = [
            ([1, 2, 3], [4], [5], 2, 2, 4, 2), ([1, 2, 3, 4], [], [5], 2, 2, 4, 2),
            ([1, 2, 3, 4], [5], [], 2, 2, 4, 2), ([1, 2, 3, 4], [5], [6], 2, 2, 3, 2),
            ([1, 2, 3, 4], [5], [6], 2, 2, 4, 1), ([1, 2, 3, 4], [5], [6], 1, 2, 4, 2),
            ([1, 2, 3, 4], [5], [6], 2, 1, 4, 2), ([1, 2, 3, 4], [5], [6], Int.max, 2, 4, 2)
        ]
        for item in cases {
            let output = pack(layout, y: item.y, u: item.u, v: item.v, strideY: item.strideY, strideUV: item.strideUV,
                yCount: item.yCount, uvCount: item.uvCount)
            XCTAssertFalse(output.didPack)
            XCTAssertEqual(output.y, Array(repeating: 253, count: item.yCount))
            XCTAssertEqual(output.uv, Array(repeating: 253, count: item.uvCount))
        }
    }

    func test_nativeI420PreparationOwnsPackedPixelsAndExplicitSDRMetadata() throws {
        // Authored native CoreVideo/CoreImage fixture; no drawable or GPU
        // presentation is created. It remains unrun with the other cases.
        let source = LKRTCMutableI420Buffer(width: 3, height: 1)
        source.mutableDataY[0] = 10; source.mutableDataY[1] = 20; source.mutableDataY[2] = 30
        source.mutableDataU[0] = 40; source.mutableDataU[1] = 50
        source.mutableDataV[0] = 60; source.mutableDataV[1] = 70
        let frame = RTCVideoFrame(buffer: source, rotation: ._90, timeStampNs: 1)
        guard case .ready(let prepared) = RemoteVideoFrameImage.prepare(frame) else { return XCTFail("Expected native I420 preparation") }
        XCTAssertEqual(prepared.image.extent, CGRect(x: 0, y: 0, width: 1, height: 3))
        let pixels = prepared.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixels), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 4); XCTAssertEqual(CVPixelBufferGetHeight(pixels), 2)
        for (key, expected) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4),
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center)] {
            let value = try XCTUnwrap(CVBufferCopyAttachment(pixels, key, nil))
            XCTAssertTrue(CFEqual(value, expected))
        }
        source.mutableDataY[0] = 99; source.mutableDataU[0] = 88
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return XCTFail("Expected readable staging buffer") }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 1)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: y, count: 4)), [10, 20, 30, 30])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: y.advanced(by: row), count: 4)), [10, 20, 30, 30])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: uv, count: 4)), [40, 60, 50, 70])
    }

    func test_cvPreparationKeepsItsOriginalBufferCropAndFormatBoundary() throws {
        let pixels = try makePixelBuffer(width: 8, height: 6, format: kCVPixelFormatType_32BGRA)
        let marker = "preparation-fixture" as CFString
        CVBufferSetAttachment(pixels, marker, marker, .shouldPropagate)
        let wrapper = RTCCVPixelBuffer(pixelBuffer: pixels, adaptedWidth: 2, adaptedHeight: 3,
            cropWidth: 4, cropHeight: 2, cropX: 2, cropY: 2)
        let frame = RTCVideoFrame(buffer: wrapper, rotation: ._90, timeStampNs: 1)
        guard case .ready(let prepared) = RemoteVideoFrameImage.prepare(frame) else { return XCTFail("Expected CV preparation") }
        XCTAssertTrue(prepared.pixelBuffer === pixels)
        XCTAssertEqual(prepared.image.extent, CGRect(x: 0, y: 0, width: 3, height: 2))
        XCTAssertTrue(CFEqual(try XCTUnwrap(CVBufferCopyAttachment(prepared.pixelBuffer, marker, nil)), marker))
        let unsupported = try makePixelBuffer(width: 2, height: 2, format: kCVPixelFormatType_OneComponent8)
        let unsupportedFrame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: unsupported), rotation: ._0, timeStampNs: 2)
        guard case .unsupported = RemoteVideoFrameImage.prepare(unsupportedFrame) else { return XCTFail("No implicit format conversion") }
    }

    private func makePixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func pack(_ layout: RemoteVideoI420Layout, y: [UInt8], u: [UInt8], v: [UInt8],
                      strideY: Int, strideUV: Int, yCount: Int? = nil, uvCount: Int? = nil)
        -> (didPack: Bool, y: [UInt8], uv: [UInt8]) {
        var outputY = [UInt8](repeating: 253, count: yCount ?? strideY * layout.storageHeight)
        var outputUV = [UInt8](repeating: 253, count: uvCount ?? strideUV * layout.chromaHeight)
        let didPack = y.withUnsafeBufferPointer { y in u.withUnsafeBufferPointer { u in v.withUnsafeBufferPointer { v in
            outputY.withUnsafeMutableBufferPointer { outputY in outputUV.withUnsafeMutableBufferPointer { outputUV in
                layout.pack(y: y, u: u, v: v, destinationY: outputY, strideY: strideY, destinationUV: outputUV, strideUV: strideUV)
            } }
        } } }
        return (didPack, outputY, outputUV)
    }
}
