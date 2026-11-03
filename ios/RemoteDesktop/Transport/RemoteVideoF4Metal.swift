#if DEBUG
import CoreVideo
import Foundation
import LiveKitWebRTC
import Metal
import QuartzCore

/// One-pass NV12 conversion. Textures and their backing pixel buffer are kept
/// alive through command completion, not merely until command submission.
final class RemoteVideoF4Metal {
    struct ColorConversion: Equatable {
        let kr: Float
        let kb: Float
        let videoRange: Bool
        var transfer709 = false

        static func select(pixelFormat: OSType, matrix: CFString?) -> ColorConversion? {
            let video: Bool
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: video = true
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: video = false
            default: return nil
            }
            if let matrix {
                if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) { return .init(kr: 0.2126, kb: 0.0722, videoRange: video) }
                if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) { return .init(kr: 0.2627, kb: 0.0593, videoRange: video) }
                guard CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) else { return nil }
            }
            return .init(kr: 0.299, kb: 0.114, videoRange: video)
        }

        func rgb(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
            let luma = videoRange ? (y - 16 / 255) * (255 / 219) : y
            let u = (cb - 128 / 255) * (videoRange ? 255 / 224 : 1)
            let v = (cr - 128 / 255) * (videoRange ? 255 / 224 : 1)
            let r = luma + 2 * (1 - kr) * v
            let b = luma + 2 * (1 - kb) * u
            let g = (luma - kr * r - kb * b) / (1 - kr - kb)
            return SIMD3(r, g, b)
        }
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let cache: CVMetalTextureCache
    init?(device: MTLDevice) {
        self.device = device
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache, let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "vertex_main"),
              let fragment = library.makeFunction(name: "fragment_main") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.cache = cache; self.pipeline = pipeline
    }

    final class Resources {
        let prepared: RemoteVideoFrameImage
        let y: CVMetalTexture
        let uv: CVMetalTexture
        init(_ prepared: RemoteVideoFrameImage, _ y: CVMetalTexture, _ uv: CVMetalTexture) {
            self.prepared = prepared; self.y = y; self.uv = uv
        }
    }
    func encode(prepared: RemoteVideoFrameImage, destination: MTLTexture,
                command: MTLCommandBuffer, mode: RemoteVideoPresentationProducer.ContentMode) -> Resources? {
        let pixel = prepared.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(pixel)
        let matrixValue = CVBufferGetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue()
        guard let matrixValue, CFGetTypeID(matrixValue) == CFStringGetTypeID() else { return nil }
        let matrix = matrixValue as! CFString
        guard var conversion = ColorConversion.select(pixelFormat: format, matrix: matrix),
              CVPixelBufferGetPlaneCount(pixel) == 2 else { return nil }
        guard let topLocation = CVBufferGetAttachment(pixel, kCVImageBufferChromaLocationTopFieldKey, nil)?.takeUnretainedValue(),
              CFEqual(topLocation, kCVImageBufferChromaLocation_Center) || CFEqual(topLocation, kCVImageBufferChromaLocation_Left) else { return nil }
        if let bottomLocation = CVBufferGetAttachment(pixel, kCVImageBufferChromaLocationBottomFieldKey, nil)?.takeUnretainedValue(),
           !CFEqual(bottomLocation, topLocation) { return nil }
        let chromaLeft = CFEqual(topLocation, kCVImageBufferChromaLocation_Left)
        // An embedded profile can carry a different transform than the
        // simple SDR attachments below; let Core Image interpret it.
        if CVBufferGetAttachment(pixel, kCVImageBufferICCProfileKey, nil) != nil { return nil }
        // Unsupported profiles fall back to Core Image instead of silently
        // treating a wide-gamut or HDR source as sRGB.
        guard let primaries = CVBufferGetAttachment(pixel, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue(),
              CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
              let transfer = CVBufferGetAttachment(pixel, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue() else { return nil }
        if CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2) { conversion.transfer709 = true }
        else if !CFEqual(transfer, kCVImageBufferTransferFunction_sRGB) { return nil }
        var y: CVMetalTexture?, uv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, .r8Unorm,
                  CVPixelBufferGetWidthOfPlane(pixel, 0), CVPixelBufferGetHeightOfPlane(pixel, 0), 0, &y) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, .rg8Unorm,
                  CVPixelBufferGetWidthOfPlane(pixel, 1), CVPixelBufferGetHeightOfPlane(pixel, 1), 1, &uv) == kCVReturnSuccess,
              let y, let uv, let yTexture = CVMetalTextureGetTexture(y), let uvTexture = CVMetalTextureGetTexture(uv) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let vertices = Self.vertices(geometry: prepared.geometry, destination: CGSize(width: destination.width, height: destination.height), mode: mode)
        var params = SIMD4<Float>(conversion.kr, conversion.kb, conversion.videoRange ? 1 : 0, conversion.transfer709 ? 1 : 0)
        var chromaOffset = SIMD2<Float>(chromaLeft ? 0.5 / Float(CVPixelBufferGetWidth(pixel)) : 0, 0)
        let g = prepared.geometry
        var crop = SIMD4<Float>(Float((Double(g.cropX) + 0.5) / Double(g.bufferWidth)),
                                Float((Double(g.cropY) + 0.5) / Double(g.bufferHeight)),
                                Float((Double(g.cropX + g.cropWidth) - 0.5) / Double(g.bufferWidth)),
                                Float((Double(g.cropY + g.cropHeight) - 0.5) / Double(g.bufferHeight)))
        encoder.setRenderPipelineState(pipeline)
        vertices.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            encoder.setVertexBytes(base, length: MemoryLayout<SIMD4<Float>>.stride * buffer.count, index: 0)
        }
        encoder.setFragmentTexture(yTexture, index: 0); encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&chromaOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return Resources(prepared, y, uv)
    }

    static func vertices(geometry g: RemoteVideoPixelGeometry, destination: CGSize,
                         mode: RemoteVideoPresentationProducer.ContentMode) -> [SIMD4<Float>] {
        let rotated = g.rotation == 90 || g.rotation == 270
        let w = CGFloat(rotated ? g.frameHeight : g.frameWidth)
        let h = CGFloat(rotated ? g.frameWidth : g.frameHeight)
        var sx: CGFloat = 1, sy: CGFloat = 1
        if mode == .aspectFit {
            let scale = min(destination.width / w, destination.height / h)
            sx = w * scale / destination.width; sy = h * scale / destination.height
        }
        func uv(_ x: CGFloat, _ y: CGFloat) -> (Float, Float) {
            let p: (CGFloat, CGFloat)
            switch g.rotation {
            case 90: p = (y, 1 - x)
            case 180: p = (1 - x, 1 - y)
            case 270: p = (1 - y, x)
            default: p = (x, y)
            }
            return (Float((CGFloat(g.cropX) + p.0 * CGFloat(g.cropWidth)) / CGFloat(g.bufferWidth)),
                    Float((CGFloat(g.cropY) + p.1 * CGFloat(g.cropHeight)) / CGFloat(g.bufferHeight)))
        }
        return [(CGFloat(-1), CGFloat(-1)), (-1, 1), (1, -1), (1, 1)].map { x, y in
            let (u, v) = uv((x + 1) / 2, (1 - y) / 2)
            return SIMD4(Float(x * sx), Float(y * sy), u, v)
        }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    vertex V vertex_main(uint id [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {
        V out; out.position = float4(vertices[id].xy, 0, 1); out.uv = vertices[id].zw; return out;
    }
    fragment float4 fragment_main(V in [[stage_in]], texture2d<float> y [[texture(0)]],
                                  texture2d<float> uv [[texture(1)]], constant float4 &p [[buffer(0)]],
                                  constant float4 &crop [[buffer(1)]], constant float2 &chromaOffset [[buffer(2)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        // Four samples cover a downscaled pixel footprint; upscaling stays bilinear.
        float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
        bool down = length(dx * float2(y.get_width(), y.get_height())) > 1.0 ||
                    length(dy * float2(y.get_width(), y.get_height())) > 1.0;
        float l; float2 chroma;
        if (down) {
            float2 a = dx * 0.25, b = dy * 0.25;
            float2 p0 = clamp(in.uv-a-b, crop.xy, crop.zw), p1 = clamp(in.uv+a-b, crop.xy, crop.zw);
            float2 p2 = clamp(in.uv-a+b, crop.xy, crop.zw), p3 = clamp(in.uv+a+b, crop.xy, crop.zw);
            l = (y.sample(s, p0).r + y.sample(s, p1).r + y.sample(s, p2).r + y.sample(s, p3).r) * 0.25;
            chroma = (uv.sample(s, p0+chromaOffset).rg + uv.sample(s, p1+chromaOffset).rg + uv.sample(s, p2+chromaOffset).rg + uv.sample(s, p3+chromaOffset).rg) * 0.25;
        } else {
            float2 point = clamp(in.uv, crop.xy, crop.zw);
            l = y.sample(s, point).r; chroma = uv.sample(s, point+chromaOffset).rg;
        }
        float2 c = chroma - float2(128.0 / 255.0);
        if (p.z > 0.5) { l = (l - 16.0 / 255.0) * (255.0 / 219.0); c *= 255.0 / 224.0; }
        float r = l + 2.0 * (1.0 - p.x) * c.y;
        float b = l + 2.0 * (1.0 - p.y) * c.x;
        float g = (l - p.x * r - p.y * b) / (1.0 - p.x - p.y);
        float3 rgb = float3(r, g, b);
        if (p.w > 0.5) {
            rgb = max(rgb, 0.0);
            float3 linear = select(rgb / 4.5, pow((rgb + 0.099) / 1.099, float3(1.0 / 0.45)), rgb >= 0.081);
            rgb = select(linear * 12.92, 1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055, linear > 0.0031308);
        }
        return float4(rgb, 1);
    }
    """
}
#endif
