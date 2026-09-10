import CoreImage
import CoreVideo
import Foundation
import LiveKitWebRTC
import Metal
import QuartzCore

/// Owns encoding and presentation of an exact supplied drawable, using public
/// Core Image/Metal APIs. Native output remains pending qualification.
@MainActor
final class RemoteVideoPresentationProducer {
    enum ContentMode: Equatable { case fill, aspectFit }
    enum Admission {
        case submitted(RemoteVideoPresentationTicket)
        case busy
        case unsupportedFrame
        case preparationFailed
        case unavailable
        case encodingFailed
    }

    let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let imageContext: CIContext
    private let colorSpace: CGColorSpace
    private let budget = RemoteVideoPresentationBudget.shared
    private(set) var contextID = UUID()
    private var active = true
    private var lastDrawableID: Int?
    private var lastReceiptTime: TimeInterval = 0
    private var lastReceiptDrawableID: Int?
    private var layout: (size: CGSize, contentMode: ContentMode)?

    init?(layer: CAMetalLayer) {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        self.layer = layer
        self.device = device
        self.queue = queue
        self.colorSpace = colorSpace
        self.imageContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = colorSpace
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
    }

    /// Call on layout, activity, visibility or input-presentation changes.
    /// Old GPU work keeps its permit until actual completion.
    func replaceContext() {
        guard active else { return }
        budget.retire(context: contextID)
        contextID = UUID()
        lastReceiptTime = 0
        lastReceiptDrawableID = nil
        layout = nil
    }

    func retire() {
        guard active else { return }
        active = false
        budget.retire(context: contextID)
    }

    func submit(frame: RTCVideoFrame, frameID: UUID, drawable: CAMetalDrawable,
                contentMode: ContentMode,
                onResult: @escaping @MainActor (UUID, RemoteVideoPresentationLedger.Result) -> Void) -> Admission {
        guard active, drawable.layer === layer, drawable.texture.device === device,
              !drawable.texture.isFramebufferOnly, drawable.texture.pixelFormat == .bgra8Unorm,
              drawable.presentedTime == 0, let drawableID = Int(exactly: drawable.drawableID),
              lastDrawableID.map({ drawableID > $0 }) ?? true,
              Self.validDestination(width: drawable.texture.width, height: drawable.texture.height) else { return .unavailable }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard size == layer.drawableSize,
              layout.map({ $0.size == size && $0.contentMode == contentMode }) ?? true else { return .unavailable }
        layout = (size, contentMode)
        let contextID = self.contextID
        guard let ticket = budget.reserve(context: contextID, frame: frameID,
            drawable: ObjectIdentifier(drawable), drawableID: drawableID,
            onResult: { [weak self] result in
                guard let self, self.active, self.contextID == contextID,
                      self.layer.drawableSize == size,
                      self.lastReceiptDrawableID.map({ drawableID > $0 }) ?? true else { return }
                if case .presented(let time) = result {
                    guard time >= self.lastReceiptTime else { return }
                    self.lastReceiptTime = time
                    self.lastReceiptDrawableID = drawableID
                }
                onResult(frameID, result)
            }) else { return .busy }
        let prepared: RemoteVideoFrameImage
        switch RemoteVideoFrameImage.prepare(frame) {
        case .ready(let value): prepared = value
        case .unsupported:
            budget.abandonUncommitted(ticket)
            return .unsupportedFrame
        case .resourceFailure:
            budget.abandonUncommitted(ticket)
            return .preparationFailed
        }
        guard let command = queue.makeCommandBuffer() else {
            budget.abandonUncommitted(ticket)
            return .encodingFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let output = Self.place(prepared.image, in: bounds, contentMode: contentMode)
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
        destination.colorSpace = colorSpace
        destination.alphaMode = .none
        // Core Image coordinates are lower-left; Metal texture storage for
        // the drawable is top-left. Do not apply a second image-space flip.
        destination.isFlipped = true
        let renderTask: CIRenderTask
        do { renderTask = try imageContext.startTask(toRender: output, to: destination) }
        catch {
            budget.abandonUncommitted(ticket)
            return .encodingFailed
        }
        guard active, self.contextID == contextID, budget.commit(ticket) else {
            budget.abandonUncommitted(ticket)
            return .unavailable
        }
        lastDrawableID = drawableID
        let budget = self.budget
        // The command's completion handler keeps image inputs alive until
        // the actual GPU completion, independently of observer/view lifetime.
        let resources = FrameResources(frame: frame, prepared: prepared, image: output, task: renderTask, context: imageContext)
        command.addCompletedHandler { command in
            withExtendedLifetime(resources) {
                let succeeded = command.status == .completed
                Task { @MainActor in budget.completeGPU(ticket, succeeded: succeeded) }
            }
        }
        drawable.addPresentedHandler { presented in
            let object = ObjectIdentifier(presented)
            let time = presented.presentedTime
            guard let id = Int(exactly: presented.drawableID) else { return }
            Task { @MainActor in budget.presented(ticket, drawable: object, drawableID: id, time: time) }
        }
        command.present(drawable)
        command.commit()
        return .submitted(ticket)
    }

    nonisolated static func validDestination(width: Int, height: Int) -> Bool {
        // Bounded drawable allocation is the caller's responsibility too.
        // This preflight rejects unexpected supplied destinations before CI.
        width > 0 && height > 0 && width <= 8_192 && height <= 8_192 &&
            width * height <= 16_777_216
    }

    private static func place(_ image: CIImage, in bounds: CGRect, contentMode: ContentMode) -> CIImage {
        var sx = bounds.width / image.extent.width, sy = bounds.height / image.extent.height
        if case .aspectFit = contentMode { sx = min(sx, sy); sy = sx }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (bounds.width - scaled.extent.width) / 2,
            y: (bounds.height - scaled.extent.height) / 2))
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        return positioned.composited(over: background).cropped(to: bounds)
    }

    private final class FrameResources: @unchecked Sendable {
        let frame: RTCVideoFrame
        let prepared: RemoteVideoFrameImage
        let image: CIImage
        let task: CIRenderTask
        let context: CIContext
        init(frame: RTCVideoFrame, prepared: RemoteVideoFrameImage, image: CIImage, task: CIRenderTask, context: CIContext) {
            self.frame = frame; self.prepared = prepared; self.image = image; self.task = task; self.context = context
        }
    }
}

/// Cropping metadata is in top-left buffer coordinates; CI uses lower-left.
/// Apply crop first, adaptation second, then frame rotation.
struct RemoteVideoPixelGeometry: Equatable {
    let frameWidth: Int, frameHeight: Int, bufferWidth: Int, bufferHeight: Int
    let cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int, rotation: Int
    var cropInImageCoordinates: CGRect {
        CGRect(x: cropX, y: bufferHeight - cropY - cropHeight, width: cropWidth, height: cropHeight)
    }
    init?(frameWidth: Int, frameHeight: Int, bufferWidth: Int, bufferHeight: Int,
          cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int, rotation: Int) {
        let limit = DesktopVideoQuality.maximumEncodedDimension
        guard [frameWidth, frameHeight, bufferWidth, bufferHeight, cropWidth, cropHeight].allSatisfy({ $0 > 0 && $0 <= limit }),
              cropX >= 0, cropY >= 0, cropX <= bufferWidth - cropWidth, cropY <= bufferHeight - cropHeight,
              [0, 90, 180, 270].contains(rotation) else { return nil }
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.bufferWidth = bufferWidth; self.bufferHeight = bufferHeight
        self.cropX = cropX; self.cropY = cropY; self.cropWidth = cropWidth; self.cropHeight = cropHeight; self.rotation = rotation
    }
}
