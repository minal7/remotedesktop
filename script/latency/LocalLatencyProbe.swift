import AppKit
import ScreenCaptureKit
import CoreMedia
import LiveKitWebRTC

// Standalone diagnostic. Uses the repository's production capture and codec policy.
// No desktop pixels, SDP, ICE addresses, or user input are persisted.
func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

final class Measurements: @unchecked Sendable {
    let lock = NSLock()
    var sourceSeen: [Int: Double] = [:]
    var captured: [Int: Double] = [:]
    var decoded: [Int: Double] = [:]
    var displayed: [Int: Double] = [:]
    var captureOverhead: [Double] = []
    var observerIntervals: [Double] = []
    var observerTimestampOffsets: [Double] = []
    var lastObservation: Double?
    var collectText = false
    var sourceText: LumaPatch?
    var decodedText: LumaPatch?
    var nativeText: LumaPatch?
    var collectNativeText = false
    var nativeTextWidth = 0
    var nativeTextHeight = 0
    var dimensions = ""
    var adaptedSize = ""
    var receivedFrames = 0
    var observationFrames = 0
    var invalidSource = 0
    var invalidMirror = 0
    var firstID = 0
    var start = Double.infinity
    var end = Double.infinity
    func withLock<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
}

struct MarkerGeometry: Sendable {
    let screenWidth: Double
    let screenHeight: Double
    let sourceX: Double
    let sourceY: Double
    let cell: Double
    let mirrorX: Double
    let mirrorY: Double
    let mirrorWidth: Double
    var mirrorScale: Double { mirrorWidth / screenWidth }
    func read(width: Int, height: Int, mirror: Bool, pixel: (Int, Int) -> UInt8) -> Int? {
        var word: UInt32 = 0
        for bit in 0..<32 {
            var x = sourceX + (Double(bit) + 0.5) * cell
            var y = sourceY + 20
            if mirror { x = mirrorX + x * mirrorScale; y = mirrorY + y * mirrorScale }
            let px = Int(x / screenWidth * Double(width))
            let py = Int(y / screenHeight * Double(height))
            guard px >= 1, px < width - 1, py >= 1, py < height - 1 else { return nil }
            // Reject intermediate colors to avoid treating transient/occluded content as a marker.
            let luma = pixel(px, py)
            guard luma < 65 || luma > 185 else { return nil }
            if luma > 128 { word |= UInt32(1) << bit }
        }
        let low = Int(word & 0xffff)
        let high = Int(word >> 16)
        guard low > 0, high == (low ^ 0xffff) else { return nil }
        return low
    }
    func read(_ buffer: CVPixelBuffer, mirror: Bool) -> Int? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        if CVPixelBufferIsPlanar(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let p = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            return read(width: w, height: h, mirror: mirror) { x, y in p[y * stride + x] }
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        return read(width: w, height: h, mirror: mirror) { x, y in p[y * stride + x * 4 + 1] }
    }
}

struct LumaPatch {
    let width: Int
    let height: Int
    let values: [Double]
    var originX = 0
    var originY = 0
    var canvasWidth = 0
    var canvasHeight = 0

    static func read(width: Int, height: Int, geometry: MarkerGeometry,
                     limitedRange: Bool, pixel: (Int, Int) -> UInt8) -> Self {
        let x0 = Int(geometry.sourceX / geometry.screenWidth * Double(width))
        let y0 = Int((geometry.sourceY + 190) / geometry.screenHeight * Double(height))
        let x1 = Int((geometry.sourceX + geometry.cell * 32) / geometry.screenWidth * Double(width))
        let y1 = Int((geometry.sourceY + 278) / geometry.screenHeight * Double(height))
        guard x0 >= 0, y0 >= 0, x1 <= width, y1 <= height, x1 > x0, y1 > y0 else {
            return Self(width: 0, height: 0, values: [])
        }
        let values = (y0..<y1).flatMap { y in (x0..<x1).map { x -> Double in
            let luma = Double(pixel(x, y))
            return limitedRange ? min(255, max(0, (luma - 16) * 255 / 219)) : luma
        } }
        return Self(width: x1 - x0, height: y1 - y0, values: values,
                    originX: x0, originY: y0, canvasWidth: width, canvasHeight: height)
    }

    static func read(_ buffer: CVPixelBuffer, geometry: MarkerGeometry) -> Self? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if !CVPixelBufferIsPlanar(buffer) {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            return read(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                        geometry: geometry, limitedRange: false) { x, y in
                let p = pixels + y * stride + x * 4
                return UInt8(min(255, max(0, (0.2126 * Double(p[2]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[0])).rounded())))
            }
        }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return read(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                    geometry: geometry,
                    limitedRange: CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            x, y in p[y * stride + x]
        }
    }

    /// Fixed native viewport comparison. Pixel centers use their original
    /// screen coordinates; there is no best-fit alignment or scale search.
    func resampled(to reference: Self) -> Self? {
        guard width > 1, height > 1, canvasWidth > 0, canvasHeight > 0,
              reference.width > 1, reference.height > 1,
              reference.canvasWidth > 0, reference.canvasHeight > 0 else { return nil }
        var result = reference
        var samples = [Double](); samples.reserveCapacity(reference.values.count)
        for y in 0..<reference.height {
            let py = min(Double(height - 1), max(0,
                (Double(reference.originY + y) + 0.5) * Double(canvasHeight) / Double(reference.canvasHeight) - 0.5 - Double(originY)))
            let y0 = Int(py), y1 = min(height - 1, y0 + 1), fy = py - Double(y0)
            for x in 0..<reference.width {
                let px = min(Double(width - 1), max(0,
                    (Double(reference.originX + x) + 0.5) * Double(canvasWidth) / Double(reference.canvasWidth) - 0.5 - Double(originX)))
                let x0 = Int(px), x1 = min(width - 1, x0 + 1), fx = px - Double(x0)
                let top = values[y0 * width + x0] * (1 - fx) + values[y0 * width + x1] * fx
                let bottom = values[y1 * width + x0] * (1 - fx) + values[y1 * width + x1] * fx
                samples.append(top * (1 - fy) + bottom * fy)
            }
        }
        result = Self(width: reference.width, height: reference.height, values: samples,
                      originX: reference.originX, originY: reference.originY,
                      canvasWidth: reference.canvasWidth, canvasHeight: reference.canvasHeight)
        return result
    }

    // Mean local SSIM over 8x8 synthetic-text blocks, with no alignment search.
    func ssim(comparedTo other: Self) -> Double? {
        guard width == other.width, height == other.height, width >= 8, height >= 8 else { return nil }
        let c1: Double = 6.5025, c2: Double = 58.5225
        var total = 0.0, count = 0
        for y in stride(from: 0, through: height - 8, by: 8) {
            for x in stride(from: 0, through: width - 8, by: 8) {
                let indices = (y..<y+8).flatMap { row in (x..<x+8).map { row * width + $0 } }
                let a = indices.reduce(0.0) { $0 + values[$1] } / 64
                let b = indices.reduce(0.0) { $0 + other.values[$1] } / 64
                let va = indices.reduce(0.0) { $0 + pow(values[$1] - a, 2) } / 64
                let vb = indices.reduce(0.0) { $0 + pow(other.values[$1] - b, 2) } / 64
                let cov = indices.reduce(0.0) { $0 + (values[$1] - a) * (other.values[$1] - b) } / 64
                total += ((2*a*b+c1) * (2*cov+c2)) / ((a*a+b*b+c1) * (va+vb+c2))
                count += 1
            }
        }
        return total / Double(count)
    }
}

final class PatternView: NSView {
    var markerID = 1
    var tick = 0
    let cell: Double
    // Keep a concrete, immutable font for the fixture. On macOS 27 the
    // dynamically resolved system monospace font crashed in CoreText during
    // baseline drawing, before any experimental encoder was enabled.
    private let headerAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Menlo-Bold", size: 18) ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
        .foregroundColor: NSColor.white]
    private let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Menlo-Regular", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.black]
    init(frame: NSRect, cell: Double) { self.cell = cell; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); bounds.fill()
        let word = UInt32(markerID) | (UInt32(markerID ^ 0xffff) << 16)
        for bit in 0..<32 {
            ((word & (UInt32(1) << bit)) == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: 16 + Double(bit) * cell, y: 40, width: cell, height: 40).fill()
        }
        ("LOCAL LATENCY PROBE  •  SOURCE  •  \(markerID)" as NSString).draw(at: NSPoint(x: 16, y: 10), withAttributes: headerAttributes)
        NSColor.white.setFill()
        NSRect(x: 16, y: 230, width: cell * 32, height: 88).fill()
        for (index, text) in ["Finder  Documents  Modified  Size  Kind", "The quick brown fox jumps over the lazy dog.",
                              "let readableText = 1234567890; // Remote Desktop", "Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm Nn"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 20, y: 234 + index * 20), withAttributes: textAttributes)
        }
        // Moving, colored desktop-like workload, independent of marker transitions.
        for row in 0..<5 {
            for col in 0..<20 {
                NSColor(calibratedHue: CGFloat((col * 13 + row * 17 + tick) % 360) / 360, saturation: 0.65, brightness: 0.8, alpha: 1).setFill()
                NSRect(x: Double((col * 39 + tick * 3) % max(1, Int(bounds.width))), y: Double(100 + row * 22), width: 32, height: 17).fill()
            }
        }
    }
}

final class DecoderProbe: NSObject, LKRTCVideoRenderer {
    let records: Measurements
    let geometry: MarkerGeometry
    init(_ records: Measurements, _ geometry: MarkerGeometry) { self.records = records; self.geometry = geometry }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        let t = now()
        guard let frame else { return }
        records.withLock {
            records.receivedFrames += 1
            records.dimensions = "\(frame.width)x\(frame.height)"
        }
        guard frame.rotation == ._0 else { return }
        let id: Int?
        let text: LumaPatch?
        if let native = frame.buffer as? LKRTCCVPixelBuffer {
            guard native.cropX == 0, native.cropY == 0,
                  Int(native.cropWidth) == CVPixelBufferGetWidth(native.pixelBuffer),
                  Int(native.cropHeight) == CVPixelBufferGetHeight(native.pixelBuffer) else { return }
            id = geometry.read(native.pixelBuffer, mirror: false)
            text = records.withLock { records.collectText } ? LumaPatch.read(native.pixelBuffer, geometry: geometry) : nil
        } else {
            let buffer = frame.buffer.toI420()
            id = geometry.read(width: Int(buffer.width), height: Int(buffer.height), mirror: false) { x, y in buffer.dataY[y * Int(buffer.strideY) + x] }
            // This buffer exposes no reliable range metadata; it cannot prove
            // the native-reference sharpness gate.
            text = nil
        }
        records.withLock {
            records.decodedText = text
            if let id, records.decoded[id] == nil { records.decoded[id] = t }
        }
    }
}

final class DisplayProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let records: Measurements
    let geometry: MarkerGeometry
    let observerFPS = Int32(ProcessInfo.processInfo.environment["LATENCY_OBSERVER_FPS"] ?? "120") ?? 120
    var stream: SCStream?
    init(_ records: Measurements, _ geometry: MarkerGeometry) { self.records = records; self.geometry = geometry }
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw NSError(domain: "Probe", code: 1) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(geometry.screenWidth); config.height = Int(geometry.screenHeight)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: observerFPS)
        config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "latency.displayprobe", qos: .userInteractive))
        try await s.startCapture(); stream = s
    }
    func collectNativeText() async throws {
        guard let stream, let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return }
        let config = SCStreamConfiguration()
        config.width = mode.pixelWidth; config.height = mode.pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: observerFPS)
        config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
        records.withLock {
            records.collectNativeText = true
            records.nativeTextWidth = config.width
            records.nativeTextHeight = config.height
        }
        try await stream.updateConfiguration(config)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let displayTicks = attachments.first?[.displayTime] as? UInt64 else { return }
        let t = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(displayTicks))
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let source = geometry.read(buffer, mirror: false)
        let mirror = geometry.read(buffer, mirror: true)
        let needsNative = records.withLock {
            records.collectNativeText && source != nil
                && CVPixelBufferGetWidth(buffer) == records.nativeTextWidth
                && CVPixelBufferGetHeight(buffer) == records.nativeTextHeight
        }
        let native = needsNative ? LumaPatch.read(buffer, geometry: geometry) : nil
        records.withLock {
            if let native { records.nativeText = native }
            if t >= records.start && t <= records.end {
                records.observationFrames += 1
                records.observerTimestampOffsets.append((t - pts) * 1000)
                if let prev = records.lastObservation { records.observerIntervals.append((t - prev) * 1000) }
                records.lastObservation = t
                if source == nil { records.invalidSource += 1 }
                if mirror == nil { records.invalidMirror += 1 }
            }
            if let source, records.sourceSeen[source] == nil { records.sourceSeen[source] = t }
            if let mirror, records.displayed[mirror] == nil { records.displayed[mirror] = t }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("OBSERVER ERROR \(error)") }
}

final class PeerDelegate: NSObject, LKRTCPeerConnectionDelegate {
    weak var other: LKRTCPeerConnection?
    var track: LKRTCVideoTrack?
    var onTrack: ((LKRTCVideoTrack) -> Void)?
    func peerConnection(_ p: LKRTCPeerConnection, didChange s: LKRTCSignalingState) {}
    func peerConnection(_ p: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ p: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ p: LKRTCPeerConnection) {}
    func peerConnection(_ p: LKRTCPeerConnection, didChange s: LKRTCIceConnectionState) { print("ICE \(s.rawValue)") }
    func peerConnection(_ p: LKRTCPeerConnection, didChange s: LKRTCIceGatheringState) {}
    func peerConnection(_ p: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) { other?.add(candidate, completionHandler: { error in if let error { print("ICE ERROR \(error)") } }) }
    func peerConnection(_ p: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ p: LKRTCPeerConnection, didOpen channel: LKRTCDataChannel) {}
    func peerConnection(_ p: LKRTCPeerConnection, didAdd r: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) { adopt(r.track) }
    func peerConnection(_ p: LKRTCPeerConnection, didStartReceivingOn t: LKRTCRtpTransceiver) { adopt(t.receiver.track) }
    func adopt(_ t: LKRTCMediaStreamTrack?) {
        guard let t = t as? LKRTCVideoTrack, track == nil else { return }
        track = t; onTrack?(t)
    }
}

func describe(_ p: LKRTCPeerConnection, offer: Bool) async throws -> LKRTCSessionDescription {
    try await withCheckedThrowingContinuation { c in
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let completion: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { s, e in
            if let e { c.resume(throwing: e) } else if let s { c.resume(returning: s) } else { c.resume(throwing: NSError(domain: "SDP", code: 1)) }
        }
        if offer { p.offer(for: constraints, completionHandler: completion) } else { p.answer(for: constraints, completionHandler: completion) }
    }
}
func setDescription(_ p: LKRTCPeerConnection, _ s: LKRTCSessionDescription, local: Bool) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        let f: @Sendable (Error?) -> Void = { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        if local { p.setLocalDescription(s, completionHandler: f) } else { p.setRemoteDescription(s, completionHandler: f) }
    }
}
func stats(_ p: LKRTCPeerConnection) async -> [[String: Any]] {
    await withCheckedContinuation { c in
        p.statistics { report in
            let allowed = Set(["inbound-rtp", "outbound-rtp", "remote-inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "codec", "transport"])
            c.resume(returning: report.statistics.values.filter { allowed.contains($0.type) }.map { value in
                let fields: [String: Any] = ["local-candidate", "remote-candidate"].contains(value.type)
                    ? ["candidateType": value.values["candidateType"] as? String ?? "unknown"] : value.values
                return ["id": value.id, "type": value.type, "values": fields]
            })
        }
    }
}
func summary(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["count": 0] }
    let s = values.sorted()
    func q(_ p: Double) -> Double { s[max(0, min(s.count - 1, Int(ceil(p * Double(s.count))) - 1))] }
    return ["count": s.count, "mean_ms": s.reduce(0,+) / Double(s.count), "min_ms": s[0], "p50_ms": q(0.5), "p95_ms": q(0.95), "p99_ms": q(0.99), "max_ms": s.last!]
}

private let f3PacerFieldTrial = "WebRTC-ProbingScreenshareBwe/2.5,2875,80,40,-60,3/"

@MainActor final class Runner: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var timer: Timer?
    var records = Measurements()
    let capture = ScreenCapture()
    var observer: DisplayProbe?
    var sink: DecoderProbe?
    var senderFactory: LKRTCPeerConnectionFactory?
    var receiverFactory: LKRTCPeerConnectionFactory?
    var sender: LKRTCPeerConnection?
    var receiver: LKRTCPeerConnection?
    var sendDelegate = PeerDelegate(), receiveDelegate = PeerDelegate()
    var videoSource: LKRTCVideoSource?
    var capturer: LKRTCVideoCapturer?
    var output = ProcessInfo.processInfo.environment["LATENCY_OUTPUT"] ?? "/tmp/local-latency.json"
    let duration = ProcessInfo.processInfo.environment["LATENCY_PAIR_FIX"] != nil
        ? 30.0 : (Double(ProcessInfo.processInfo.environment["LATENCY_SECONDS"] ?? "60") ?? 60)
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await run() } catch { print("ERROR \(error)"); try? Data("\(error)".utf8).write(to: URL(fileURLWithPath: output + ".error")); NSApp.terminate(nil) } }
    }
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let fix = environment["LATENCY_PAIR_FIX"], ["F1", "F2", "F3", "F3Pacer"].contains(fix) {
            let count = max(4, Int(environment["LATENCY_PAIRS"] ?? "4") ?? 4)
            let prefix = output
            let baseline = LatencyLabConfiguration.current
            if fix == "F1" && (baseline.f2Encoder || baseline.f3Sender) {
                throw NSError(domain: "F1 receiver trial requires stock sender settings", code: 1)
            }
            var paths: [String] = []
            for pair in 1...count {
                for enabled in [false, true] {
                    var selected = baseline
                    if fix == "F1" { selected.f1Playout = enabled }
                    if fix == "F2" { selected.f2Encoder = enabled }
                    if fix == "F3" { selected.f3Sender = enabled }
                    LatencyLabConfiguration.setRuntime(selected)
                    output = prefix + ".\(pair)-\(enabled ? "B" : "A").json"
                    guard !FileManager.default.fileExists(atPath: output) else {
                        throw NSError(domain: "Refusing to overwrite a paired result", code: 1)
                    }
                    records = Measurements()
                    sendDelegate = PeerDelegate(); receiveDelegate = PeerDelegate()
                    try await runTrial(f3Pacer: fix == "F3Pacer" && enabled, f1Receiver: fix == "F1" && enabled)
                    paths.append(output)
                }
            }
            let manifest: [String: Any] = ["fix": fix, "pairs": count, "runs": paths,
                "session": "one app invocation, identical scenario, fresh peer connections per trial",
                "duration_s": duration]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: prefix))
        } else {
            try await runTrial()
        }
        NSApp.terminate(nil)
    }
    func runTrial(f3Pacer: Bool = false, f1Receiver: Bool = false) async throws {
        let lab = LatencyLabConfiguration.current
        let configuredTrial: Any = f3Pacer ? (f3PacerFieldTrial as Any) : NSNull()
        let f1Trial = "WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:\(lab.f1MaximumDelayMs)/"
        let configuredF1Trial: Any = f1Receiver ? (f1Trial as Any) : NSNull()
        guard CGPreflightScreenCaptureAccess() else { throw NSError(domain: "Screen recording permission is required for the standalone latency probe", code: 1) }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { throw NSError(domain: "Main display is unavailable", code: 1) }
        let w = screen.frame.width, h = screen.frame.height
        let cell = floor(w * 0.42 / 32)
        let sourceFrame = NSRect(x: 20, y: h - 430, width: cell * 32 + 32, height: 330)
        let mirrorWidth = floor(w * 0.46), mirrorHeight = mirrorWidth * h / w
        let mirrorFrame = NSRect(x: w - mirrorWidth - 20, y: h - 100 - mirrorHeight, width: mirrorWidth, height: mirrorHeight)
        let geometry = MarkerGeometry(screenWidth: w, screenHeight: h, sourceX: sourceFrame.minX + 16, sourceY: h - sourceFrame.maxY + 40, cell: cell, mirrorX: mirrorFrame.minX, mirrorY: h - mirrorFrame.maxY, mirrorWidth: mirrorWidth)
        let pattern = PatternView(frame: NSRect(origin: .zero, size: sourceFrame.size), cell: cell)
        let video = LKRTCMTLVideoView(frame: NSRect(origin: .zero, size: mirrorFrame.size))
        for (frame, view, title) in [(sourceFrame, pattern as NSView, "Latency source"), (mirrorFrame, video as NSView, "Latency local viewer")] {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.title = title; window.contentView = view; window.level = .floating; window.isReleasedWhenClosed = false
            window.orderFrontRegardless(); windows.append(window)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { _ in
            MainActor.assumeIsolated {
                pattern.tick += 1
                if pattern.tick % 6 == 0 { pattern.markerID = (pattern.markerID % 65534) + 1 }
                pattern.needsDisplay = true
            }
        }
        LKRTCInitializeSSL()
        func factory() -> LKRTCPeerConnectionFactory {
            let f = LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: true, encoderFactory: DesktopVideoEncoderFactory(f2Enabled: lab.f2Encoder), decoderFactory: DesktopVideoDecoderFactory(), audioProcessingModule: nil)
            _ = f.audioDeviceModule.setEngineAvailability(LKRTCAudioEngineAvailability(isInputAvailable: false, isOutputAvailable: false))
            return f
        }
        func makeSenderFactory() -> LKRTCPeerConnectionFactory {
            guard f3Pacer else { return factory() }
            // Factory initialization snapshots the global trial. Restore it
            // synchronously before creating the independent receiver factory.
            LKRTCPeerConnectionFactory.configureFieldTrials(f3PacerFieldTrial)
            defer { LKRTCPeerConnectionFactory.configureFieldTrials(nil) }
            return factory()
        }
        func makeReceiverFactory() -> LKRTCPeerConnectionFactory {
            guard f1Receiver else { return factory() }
            LKRTCPeerConnectionFactory.configureFieldTrials(f1Trial)
            defer { LKRTCPeerConnectionFactory.configureFieldTrials(nil) }
            return factory()
        }
        let sf = makeSenderFactory(), rf = makeReceiverFactory(); senderFactory = sf; receiverFactory = rf
        let config = LKRTCConfiguration(); config.sdpSemantics = .unifiedPlan; config.iceServers = []
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let send = sf.peerConnection(with: config, constraints: constraints, delegate: sendDelegate)!
        let receive = rf.peerConnection(with: config, constraints: constraints, delegate: receiveDelegate)!
        sender = send; receiver = receive; sendDelegate.other = receive; receiveDelegate.other = send
        let sink = DecoderProbe(records, geometry); self.sink = sink
        receiveDelegate.onTrack = { track in track.add(video); track.add(sink) }
        let ti = LKRTCRtpTransceiverInit(); ti.direction = .recvOnly
        receive.addTransceiver(of: .video, init: ti)
        let offer = try await describe(receive, offer: true)
        try await setDescription(receive, offer, local: true); try await setDescription(send, offer, local: false)
        let source = sf.videoSource(forScreenCast: true)
        let capturer = LKRTCVideoCapturer(delegate: source)
        self.videoSource = source; self.capturer = capturer
        let track = sf.videoTrack(with: source, trackId: "screen")
        let videoSender = send.add(track, streamIds: ["screen"])!
        let answer = try await describe(send, offer: false)
        try await setDescription(send, answer, local: true); try await setDescription(receive, answer, local: false)
        let capturePolicy = DesktopVideoQuality.capturePolicy(
            negotiatedCodecs: videoSender.parameters.codecs, f2Requested: lab.f2Encoder)
        let parameters = videoSender.parameters
        for encoding in parameters.encodings { encoding.maxBitrateBps = NSNumber(value: DesktopVideoQuality.maximumBitrateBps); encoding.maxFramerate = NSNumber(value: capturePolicy.framesPerSecond); encoding.scaleResolutionDownBy = 1 }
        parameters.degradationPreference = NSNumber(value: DesktopVideoQuality.sharpnessPolicy.degradationPreference.rawValue)
        videoSender.parameters = parameters
        _ = send.setBweMinBitrateBps(nil, currentBitrateBps: nil, maxBitrateBps: NSNumber(value: DesktopVideoQuality.maximumBitrateBps))
        let macroblocks = capturePolicy.maximumMacroblocksPerFrame
        print("CONFIG screen=\(w)x\(h) macroblocks=\(macroblocks) codecs=\(videoSender.parameters.codecs.map { $0.name })")
        let records = self.records
        let owner = capture.beginSession(callbacks: .init(onVideoFrame: { frame, _ in
            let buffer = frame.imageBuffer
            let t = now(), pts = Double(frame.metadata.presentationTimeNanoseconds ?? frame.metadata.captureTimeNanoseconds) / 1e9
            let id = geometry.read(buffer, mirror: false)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let size = "\(width)x\(height)"
            let needsAdaptation = records.withLock { () -> Bool in
                guard size != records.adaptedSize else { return false }; records.adaptedSize = size; return true
            }
            if needsAdaptation { source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: capturePolicy.framesPerSecond) }
            let sourceText = records.withLock { records.collectText } ? LumaPatch.read(buffer, geometry: geometry) : nil
            records.withLock {
                records.sourceText = sourceText
                if let id, records.captured[id] == nil { records.captured[id] = pts }
                if t >= records.start && t <= records.end { records.captureOverhead.append((t - pts) * 1000) }
            }
            source.capturer(capturer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(pts * 1e9)))
        }, onAudioSample: nil, onVideoUnavailable: { _ in print("CAPTURE UNAVAILABLE") },
            onStopped: { _, error in print("CAPTURE ERROR \(error)") }))
        let observer = DisplayProbe(records, geometry); self.observer = observer
        try await observer.start()
        try await capture.start(for: owner, audioEnabled: false, maximumMacroblocksPerFrame: macroblocks,
                                framesPerSecond: capturePolicy.framesPerSecond)
        let senderTrace = LatencyStatsCollector(side: "loopback_sender", enabled: true,
            traceURL: URL(fileURLWithPath: output + ".sender.jsonl"))
        let receiverTrace = LatencyStatsCollector(side: "loopback_receiver", enabled: true,
            traceURL: URL(fileURLWithPath: output + ".receiver.jsonl"))
        for (collector, side) in [(senderTrace, "loopback_sender"), (receiverTrace, "loopback_receiver")] {
            collector.trace(["type": "lab_configuration", "component": "f3_pacer_trial", "side": side, "time": now(),
                             "scope": "sender_factory_only", "receiver_factory": "stock",
                             "configured": f3Pacer, "field_trial": configuredTrial,
                             "effective": "unverified"])
        }
        receiverTrace.trace(["type": "lab_configuration", "component": "f1_playout_trial", "side": "loopback_receiver",
                             "time": now(), "scope": "receiver_factory_only", "configured": f1Receiver,
                             "field_trial": configuredF1Trial, "effective": "unverified"])
        let polling = Task { @MainActor in
            var appliedPath: LatencyLabSenderPolicy.Path?
            while !Task.isCancelled {
                for (peer, collector) in [(send, senderTrace), (receive, receiverTrace)] {
                    let records = await stats(peer)
                    let reports = records.compactMap { value -> LatencyStatsReport? in
                        guard let id = value["id"] as? String, let type = value["type"] as? String,
                              let values = value["values"] as? [String: Any] else { return nil }
                        return LatencyStatsReport(id: id, type: type, values: values)
                    }
                    if peer === send, lab.f3Sender,
                       let path = LatencyLabSenderPolicy.selectedPath(in: reports), appliedPath != path,
                       send.setBweMinBitrateBps(NSNumber(value: path.minimumBitrate),
                           currentBitrateBps: NSNumber(value: path.startingBitrate),
                           maxBitrateBps: NSNumber(value: path.maximumBitrate)) {
                        let parameters = videoSender.parameters
                        for encoding in parameters.encodings {
                            encoding.networkPriority = path.isLAN ? .high : .low
                            encoding.bitratePriority = path.isLAN ? 2 : 1
                        }
                        videoSender.parameters = parameters
                        appliedPath = path
                        collector.trace(["type": "f3_path_applied", "time": now(),
                            "localType": path.localType, "remoteType": path.remoteType,
                            "startingBitrate": path.startingBitrate])
                    }
                    collector.ingest(reports, at: now())
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        defer { polling.cancel(); senderTrace.flush(); receiverTrace.flush() }
        let connectionDeadline = now() + 20
        while records.withLock({ records.receivedFrames == 0 }) {
            guard now() < connectionDeadline else { throw NSError(domain: "No decoded frame within 20 seconds", code: 1) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let statsAtFirstFrame = await stats(send)
        try await Task.sleep(for: .seconds(1))
        let statsAtOneSecond = await stats(send)
        try await Task.sleep(for: .seconds(1))
        let statsAtTwoSeconds = await stats(send)
        try await Task.sleep(for: .seconds(3))
        let statsBefore = await stats(send) + stats(receive)
        records.withLock { records.start = now(); records.end = records.start + duration; records.firstID = pattern.markerID + 1 }
        print("MEASURING \(duration)s after 5s warmup")
        try await Task.sleep(for: .seconds(duration))
        let lastID = pattern.markerID - 1
        let statsAfter = await stats(send) + stats(receive)
        records.withLock { records.collectText = true }
        try await Task.sleep(for: .seconds(1))
        timer?.invalidate(); timer = nil
        try await observer.collectNativeText()
        // Only the synthetic text crop is retained in memory. Two seconds after
        // the pattern stops, compare the final decoded text to the scaled source.
        try await Task.sleep(for: .seconds(2))
        let textSSIM = records.withLock { records.sourceText.flatMap { source in
            records.decodedText.flatMap { source.ssim(comparedTo: $0) }
        } }
        let nativeTextSSIM = records.withLock { records.nativeText.flatMap { native in
            records.decodedText.flatMap { $0.resampled(to: native) }
                .flatMap { native.ssim(comparedTo: $0) }
        } }
        polling.cancel()
        await polling.value
        senderTrace.flush(); receiverTrace.flush()
        await capture.stop(); try await observer.stream?.stopCapture()
        send.close(); receive.close()
        var result: [String: Any] = records.withLock {
            let ids = records.sourceSeen.keys.filter { $0 >= records.firstID && $0 <= lastID && records.sourceSeen[$0]! >= records.start && records.sourceSeen[$0]! <= records.end }.sorted()
            let samples: [[String: Any]] = ids.map { id in
                var row: [String: Any] = ["marker_id": id, "source_compositor_s": records.sourceSeen[id]!]
                if let t = records.captured[id] { row["capture_pts_s"] = t }
                if let t = records.decoded[id] { row["decode_callback_s"] = t }
                if let t = records.displayed[id] { row["viewer_compositor_s"] = t }
                return row
            }
            let displayDelay = ids.compactMap { id -> Double? in guard let d = records.displayed[id], let s = records.sourceSeen[id] else { return nil }; return (d-s)*1000 }
            let decodeDelay = ids.compactMap { id -> Double? in guard let d = records.decoded[id], let s = records.captured[id] else { return nil }; return (d-s)*1000 }
            let renderDelay = ids.compactMap { id -> Double? in guard let d = records.displayed[id], let s = records.decoded[id] else { return nil }; return (d-s)*1000 }
            return ["kind": "local_software_compositor_to_compositor_proxy_not_optical_glass_to_glass", "date_utc": ISO8601DateFormatter().string(from: Date()), "duration_s": duration, "warmup_after_first_decoded_frame_s": 5, "video_size": records.dimensions, "screen_points": [w,h], "capture_fps_limit": DesktopVideoQuality.targetFramesPerSecond, "observer_fps_limit": observer.observerFPS, "bitrate_cap_bps": DesktopVideoQuality.maximumBitrateBps, "audio": false, "network": "two WebRTC peers on the same Mac, host ICE candidates, no STUN/TURN", "source_marker_count": ids.count, "viewer_marker_count": displayDelay.count, "decoded_marker_count": decodeDelay.count, "compositor_to_compositor": summary(displayDelay), "capture_pts_to_decode_callback": summary(decodeDelay), "decode_callback_to_viewer_compositor": summary(renderDelay), "capture_pts_to_capture_callback": summary(records.captureOverhead), "observer_displaytime_minus_pts": summary(records.observerTimestampOffsets), "observer_complete_frame_intervals": summary(records.observerIntervals), "invalid_source_observations": records.invalidSource, "invalid_viewer_observations": records.invalidMirror, "samples": samples, "text_ssim": textSSIM as Any? ?? NSNull(), "stats_at_first_frame": statsAtFirstFrame, "stats_at_one_second": statsAtOneSecond, "stats_at_two_seconds": statsAtTwoSeconds, "stats_before": statsBefore, "stats_after": statsAfter]
        }
        var settings = lab.traceValues
        settings["f3Pacer"] = f3Pacer
        result["lab_configuration"] = settings
        result["sender_field_trial"] = configuredTrial
        result["sender_field_trial_effective"] = "unverified"
        result["receiver_field_trial"] = configuredF1Trial
        result["receiver_field_trial_effective"] = "unverified"
        result["measurement_start_s"] = records.withLock { records.start }
        result["measurement_end_s"] = records.withLock { records.end }
        result["native_text_ssim"] = nativeTextSSIM as Any? ?? NSNull()
        result["native_text_reference"] = "Independent native-resolution synthetic text, fixed screen coordinates, bilinear reconstructed decode; sampled after timing window"
        result["capture_fps_limit"] = Int(capturePolicy.framesPerSecond)
        result["sender_trace"] = output + ".sender.jsonl"
        result["receiver_trace"] = output + ".receiver.jsonl"
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        print("RESULT \(output)")
        print("SUMMARY \(result.filter { ["compositor_to_compositor", "capture_pts_to_decode_callback", "decode_callback_to_viewer_compositor", "observer_complete_frame_intervals", "video_size", "source_marker_count", "viewer_marker_count"].contains($0.key) })")
        windows.forEach { $0.close() }; windows.removeAll()
        self.sender = nil; self.receiver = nil; self.sink = nil; self.observer = nil
        videoSource = nil; self.capturer = nil
        senderFactory = nil; receiverFactory = nil
    }
}

MainActor.assumeIsolated {
    setlinebuf(stdout)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let runner = Runner()
    app.delegate = runner
    app.run()
}
