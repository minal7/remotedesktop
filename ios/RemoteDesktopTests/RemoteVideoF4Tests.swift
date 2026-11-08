#if DEBUG
import CoreImage
import CoreVideo
import Metal
import XCTest
@testable import RemoteDesktop

final class RemoteVideoF4Tests: XCTestCase {
    func testFailedFrameRetriesInPlaceButNeverTransfersAcrossLayout() throws {
        let mailbox = RemoteVideoLatestFrameMailbox<NSObject>()
        let first = UUID(), second = UUID(), third = UUID()
        mailbox.replaceContext(first)
        let original = NSObject(); mailbox.offer(original)
        let failed = try XCTUnwrap(mailbox.takeLatest(context: first))
        mailbox.restoreFailed(frame: failed.id, context: first)
        XCTAssertTrue(mailbox.hasPending(context: first))
        mailbox.replaceContext(second, preservingLatestFrom: first)
        XCTAssertNil(mailbox.takeLatest(context: second))

        mailbox.offer(original)
        let older = try XCTUnwrap(mailbox.takeLatest(context: second))
        let newer = NSObject(); mailbox.offer(newer)
        mailbox.restoreFailed(frame: older.id, context: second)
        mailbox.replaceContext(third, preservingLatestFrom: second)
        XCTAssertTrue(try XCTUnwrap(mailbox.takeLatest(context: third)).frame === newer)
    }

    func testCrossModePermitsSurviveRetirementUntilGPUCompletion() throws {
        let pool = RemoteVideoGPUAdmission(capacity: 2)
        let legacyPermit = try XCTUnwrap(pool.acquire())
        let f4Permit = try XCTUnwrap(pool.acquire())
        let context = UUID(), drawable = NSObject(), f4Drawable = NSObject()
        var ledger = RemoteVideoPresentationLedger(capacity: 2)
        let ticket = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(drawable), drawableID: 1))
        let f4Ticket = try XCTUnwrap(ledger.reserve(context: UUID(), frame: UUID(), drawable: ObjectIdentifier(f4Drawable), drawableID: 2))
        XCTAssertTrue(ledger.commit(ticket)); XCTAssertTrue(ledger.commit(f4Ticket))
        XCTAssertTrue(ledger.retire(context: context).released.isEmpty)
        XCTAssertEqual(ledger.expire(f4Ticket).results.first?.1, .expired)
        XCTAssertNil(pool.acquire(), "Retirement and observation expiry cannot release GPU permits")
        XCTAssertEqual(ledger.completeGPU(ticket, succeeded: true).released, [ticket])
        legacyPermit.release()
        let successor = try XCTUnwrap(pool.acquire())
        legacyPermit.release()
        XCTAssertNil(pool.acquire(), "A duplicate completion must not free another submission's permit")
        XCTAssertEqual(ledger.completeGPU(f4Ticket, succeeded: true).released, [f4Ticket])
        f4Permit.release(); successor.release()
        let first = try XCTUnwrap(pool.acquire()), second = try XCTUnwrap(pool.acquire())
        XCTAssertNil(pool.acquire())
        first.release(); second.release()
    }

    func testLateReceiptDoesNotRequireDiscardingItsLedgerEntryForNextFrame() throws {
        var ledger = RemoteVideoPresentationLedger(capacity: 16)
        let context = UUID(), a = NSObject(), b = NSObject(), c = NSObject()
        let first = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(a), drawableID: 1))
        let second = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(b), drawableID: 2))
        XCTAssertTrue(ledger.commit(first)); XCTAssertTrue(ledger.commit(second))
        XCTAssertTrue(ledger.completeGPU(first, succeeded: true).results.isEmpty)
        let third = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(c), drawableID: 3))
        XCTAssertTrue(ledger.commit(third)); XCTAssertEqual(ledger.count, 3)
        XCTAssertEqual(ledger.presented(first, drawable: ObjectIdentifier(a), drawableID: 1, time: 1).results.first?.1, .presented(1))
        _ = ledger.retire(context: context)
        XCTAssertEqual(ledger.count, 2)
        _ = ledger.completeGPU(second, succeeded: true); _ = ledger.completeGPU(third, succeeded: true)
        XCTAssertEqual(ledger.count, 0)
    }

    func testTwoFramesCanBeCommittedBeforeEitherIsPresentedAndRetireSafely() throws {
        var ledger = RemoteVideoPresentationLedger(capacity: 2)
        let context = UUID(), a = NSObject(), b = NSObject()
        let first = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(a), drawableID: 1))
        let second = try XCTUnwrap(ledger.reserve(context: context, frame: UUID(), drawable: ObjectIdentifier(b), drawableID: 2))
        XCTAssertTrue(ledger.commit(first)); XCTAssertTrue(ledger.commit(second))
        XCTAssertTrue(ledger.completeGPU(second, succeeded: true).results.isEmpty)
        XCTAssertEqual(ledger.presented(second, drawable: ObjectIdentifier(b), drawableID: 2, time: 5).results.first?.1, .presented(5))
        let retired = ledger.retire(context: context)
        XCTAssertEqual(retired.silenced, [first]); XCTAssertEqual(ledger.count, 1)
        XCTAssertTrue(ledger.presented(first, drawable: ObjectIdentifier(a), drawableID: 1, time: 4).results.isEmpty)
        XCTAssertEqual(ledger.completeGPU(first, succeeded: true).released, [first])
        XCTAssertEqual(ledger.count, 0)
    }

    func testMetalRendersVideoRangeAndTopToBottomOrientation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this test host") }
        let renderer = try XCTUnwrap(RemoteVideoF4Metal(device: device), "The Metal shader must compile")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes as CFDictionary, &pixel), kCVReturnSuccess)
        let input = try XCTUnwrap(pixel)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(input, []), kCVReturnSuccess)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, 1)).assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(input, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(input, 1)
        for row in 0..<4 { for column in 0..<4 { y[row * yStride + column] = row < 2 ? 16 : 235 } }
        for row in 0..<2 { for column in 0..<4 { uv[row * uvStride + column] = 128 } }
        XCTAssertEqual(CVPixelBufferUnlockBaseAddress(input, []), kCVReturnSuccess)
        CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(input, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        let geometry = try XCTUnwrap(RemoteVideoPixelGeometry(frameWidth: 4, frameHeight: 4, bufferWidth: 4, bufferHeight: 4,
            cropX: 0, cropY: 0, cropWidth: 4, cropHeight: 4, rotation: 0))
        let prepared = RemoteVideoFrameImage(image: CIImage(cvPixelBuffer: input), pixelBuffer: input, geometry: geometry)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let resources = try XCTUnwrap(renderer.encode(prepared: prepared, destination: output, command: command, mode: .fill))
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(resources) {}
        XCTAssertEqual(command.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { output.getBytes(base, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        }
        XCTAssertLessThan(bytes[0], 8)
        XCTAssertGreaterThan(bytes[3 * 16], 247)

        // BT.709 video-range code values for saturated red exercise both
        // chroma channels and their matrix coefficients in the actual shader.
        XCTAssertEqual(CVPixelBufferLockBaseAddress(input, []), kCVReturnSuccess)
        let redY = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, 0)).assumingMemoryBound(to: UInt8.self)
        let redUV = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, 1)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<4 { for column in 0..<4 { redY[row * yStride + column] = 63 } }
        for row in 0..<2 { for column in 0..<2 {
            redUV[row * uvStride + column * 2] = 102
            redUV[row * uvStride + column * 2 + 1] = 240
        } }
        XCTAssertEqual(CVPixelBufferUnlockBaseAddress(input, []), kCVReturnSuccess)
        let colorCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let colorResources = try XCTUnwrap(renderer.encode(prepared: prepared, destination: output, command: colorCommand, mode: .fill))
        colorCommand.commit(); colorCommand.waitUntilCompleted()
        withExtendedLifetime(colorResources) {}
        XCTAssertEqual(colorCommand.status, .completed)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { output.getBytes(base, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        }
        XCTAssertLessThan(bytes[0], 10); XCTAssertLessThan(bytes[1], 10); XCTAssertGreaterThan(bytes[2], 240)

        CVBufferSetAttachment(input, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(input, []), kCVReturnSuccess)
        let leftY = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, 0)).assumingMemoryBound(to: UInt8.self)
        let leftUV = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, 1)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<4 { for column in 0..<4 { leftY[row * yStride + column] = 128 } }
        for row in 0..<2 {
            leftUV[row * uvStride] = 128; leftUV[row * uvStride + 1] = 128
            leftUV[row * uvStride + 2] = 240; leftUV[row * uvStride + 3] = 128
        }
        XCTAssertEqual(CVPixelBufferUnlockBaseAddress(input, []), kCVReturnSuccess)
        let leftCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let leftResources = try XCTUnwrap(renderer.encode(prepared: prepared, destination: output, command: leftCommand, mode: .fill))
        leftCommand.commit(); leftCommand.waitUntilCompleted()
        withExtendedLifetime(leftResources) {}
        XCTAssertEqual(leftCommand.status, .completed)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { output.getBytes(base, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        }
        XCTAssertGreaterThan(bytes[4], 220, "Left-sited chroma must be sampled halfway between the two chroma pixels at luma column one")
    }

    func testVideoRangeBlackAndWhite() throws {
        let c = try XCTUnwrap(RemoteVideoF4Metal.ColorConversion.select(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        let black = c.rgb(y: 16 / 255, cb: 128 / 255, cr: 128 / 255)
        let white = c.rgb(y: 235 / 255, cb: 128 / 255, cr: 128 / 255)
        XCTAssertEqual(black.x, 0, accuracy: 0.0001)
        XCTAssertEqual(black.y, 0, accuracy: 0.0001)
        XCTAssertEqual(white.x, 1, accuracy: 0.0001)
        XCTAssertEqual(white.z, 1, accuracy: 0.0001)
    }
    func testFullRangeAndUnknownFormat() throws {
        let c = try XCTUnwrap(RemoteVideoF4Metal.ColorConversion.select(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4))
        XCTAssertEqual(c.rgb(y: 1, cb: 128 / 255, cr: 128 / 255).y, 1, accuracy: 0.0001)
        XCTAssertNil(RemoteVideoF4Metal.ColorConversion.select(pixelFormat: kCVPixelFormatType_32BGRA, matrix: nil))
    }
    func testCropRotationAndAspectFit() throws {
        let geometry = try XCTUnwrap(RemoteVideoPixelGeometry(frameWidth: 100, frameHeight: 50,
            bufferWidth: 200, bufferHeight: 100, cropX: 20, cropY: 10, cropWidth: 100, cropHeight: 50, rotation: 90))
        let vertices = RemoteVideoF4Metal.vertices(geometry: geometry, destination: CGSize(width: 100, height: 100), mode: .aspectFit)
        XCTAssertEqual(vertices[0].x, -0.5, accuracy: 0.0001)
        XCTAssertEqual(vertices[0].y, -1, accuracy: 0.0001)
        XCTAssertEqual(vertices[0].z, 0.6, accuracy: 0.0001)
        XCTAssertEqual(vertices[0].w, 0.6, accuracy: 0.0001)
    }
}
#endif
