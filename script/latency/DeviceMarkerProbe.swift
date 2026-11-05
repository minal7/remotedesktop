import AppKit
import ScreenCaptureKit
import CoreMedia
import QuartzCore

// The observer reads only the marker cells and persists only their IDs and times.
enum LargeChangeCadence {
    enum Interval: Int {
        case stress = 2, recovery = 8

        static func parse(_ raw: String?) -> Interval? {
            guard let raw else { return .stress }
            guard let value = Double(raw), value.isFinite else { return nil }
            switch value {
            case 2: return .stress
            case 8: return .recovery
            default: return nil
            }
        }
        var role: String { self == .stress ? "stress" : "recovery" }
    }
    static func isPhoto(elapsed: TimeInterval, interval: Interval = .stress) -> Bool {
        guard elapsed.isFinite else { return false }
        return Int(max(0, elapsed) / Double(interval.rawValue)) % 2 == 1
    }
}

/// Independent bounded animation, deliberately outside the 10 Hz marker cells.
enum FixtureAnimationCadence {
    static func step(elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return Int(min(36_000, (elapsed * 60).rounded(.down)))
    }
    static func validTarget(_ target: TimeInterval, after previous: TimeInterval?) -> Bool {
        target.isFinite && target > 0 && (previous.map { target > $0 } ?? true)
    }
    static func displayStep(target: TimeInterval, anchor: TimeInterval) -> Int {
        step(elapsed: max(0, target - anchor) + 1.0 / 120)
    }
    static var requestedRange: CAFrameRateRange {
        CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    }
    static func frame(in bounds: NSRect) -> NSRect {
        NSRect(x: max(0, bounds.width - 240), y: 24,
               width: min(200, bounds.width), height: min(80, max(0, bounds.height - 24)))
    }
}

final class FixtureAnimationRegion: NSView {
    var step = 0
    private var targetAnchor: TimeInterval?
    private var previousTarget: TimeInterval?
    @objc func displayTick(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        guard FixtureAnimationCadence.validTarget(target, after: previousTarget) else { return }
        let anchor = targetAnchor ?? target
        targetAnchor = anchor; previousTarget = target
        let next = FixtureAnimationCadence.displayStep(target: target, anchor: anchor)
        guard next != step else { return }
        step = next; needsDisplay = true
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedHue: CGFloat(step % 120) / 120, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.setFill()
        NSRect(x: CGFloat(step % 40) * max(1, bounds.width / 40), y: 0,
               width: max(2, bounds.width / 16), height: bounds.height).intersection(bounds).fill()
    }
}

final class Pattern: NSView {
    var id = 1
    let cell: CGFloat
    let optical: Bool
    let photo: NSImage?
    var photoScene = false
    init(frame: NSRect, cell: CGFloat, optical: Bool = false, photo: NSImage? = nil) {
        self.cell = cell; self.optical = optical; self.photo = photo; super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static let textReferenceROI = NSRect(x: 64, y: 144, width: 256, height: 64)

    /// Draw only the owned synthetic text view into a bounded bitmap, never a desktop capture.
    func writeTextReference(to url: URL, screenWidth: Int, screenHeight: Int, backingScale: CGFloat) throws {
        let roi = Self.textReferenceROI
        guard optical, photo != nil, !photoScene, backingScale == 2,
              bounds.contains(roi), screenWidth == Int(bounds.width), screenHeight == Int(bounds.height),
              let bitmap = bitmapImageRepForCachingDisplay(in: roi),
              bitmap.pixelsWide == 512, bitmap.pixelsHigh == 128 else {
            throw NSError(domain: "Synthetic text reference geometry unavailable", code: 1)
        }
        cacheDisplay(in: roi, to: bitmap)
        var luma = Data(); luma.reserveCapacity(512 * 128)
        for y in 0..<128 {
            for x in 0..<512 {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent >= 0.999 else {
                    throw NSError(domain: "Synthetic text reference color unavailable", code: 1)
                }
                let value = max(0, min(255, (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) * 255))
                luma.append(UInt8(value.rounded()))
            }
        }
        guard let min = luma.min(), let max = luma.max(), min < 32, max > 223 else {
            throw NSError(domain: "Synthetic text reference lacks contrast", code: 1)
        }
        let object: [String: Any] = ["version": 1, "screenWidth": screenWidth, "screenHeight": screenHeight,
            "width": 512, "height": 128, "x": 64, "y": 144, "scale": 2, "luma": luma.base64EncodedString()]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .withoutOverwriting)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.darkGray.setFill(); bounds.fill()
        if let photo {
            if photoScene {
                let scale = max(bounds.width / photo.size.width, bounds.height / photo.size.height)
                let size = NSSize(width: photo.size.width * scale, height: photo.size.height * scale)
                let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
                photo.draw(in: rect)
            } else {
                NSColor.white.setFill(); bounds.fill()
                let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let line = "Remote desktop fixture 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ !@#$%^&*() "
                let text = String(repeating: line, count: max(1, Int(bounds.width / 500) + 1))
                var y: CGFloat = 0
                while y < bounds.height {
                    (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attributes)
                    y += 18
                }
            }
        }
        if optical && photo == nil {
            (id % 2 == 0 ? NSColor.white : NSColor.black).setFill()
            NSRect(x: bounds.width * 0.1, y: 450, width: bounds.width * 0.8,
                   height: min(bounds.height * 0.36, bounds.height - 470)).fill()
        }
        let word = UInt32(id) | (UInt32(id ^ 0xffff) << 16)
        for bit in 0..<32 {
            ((word & (1 << bit)) == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: (optical ? 36 : 16) + CGFloat(bit) * cell,
                   y: optical ? 370 : 40, width: cell, height: 40).fill()
        }
    }
}

final class OpticalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil) }
        else { super.keyDown(with: event) }
    }
}
final class Observer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let x: CGFloat, y: CGFloat, cell: CGFloat, screenWidth: CGFloat, screenHeight: CGFloat
    let lock = NSLock()
    var rows: [[String: Any]] = []
    var last = 0
    var lastTime: Double?
    var scenes: [Int: String] = [:]
    var lastScene: String?
    var stream: SCStream?
    func registerScene(id: Int, scene: String) {
        lock.lock(); defer { lock.unlock() }
        scenes[id] = scene
    }
    init(x: CGFloat, y: CGFloat, cell: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x; self.y = y; self.cell = cell; screenWidth = width; screenHeight = height
    }
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw NSError(domain: "Display unavailable", code: 1) }
        let config = SCStreamConfiguration()
        config.width = display.width; config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
        let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "latency.marker.observer"))
        try await s.startCapture(); stream = s
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let ticks = attachments.first?[.displayTime] as? UInt64,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), p = base.assumingMemoryBound(to: UInt8.self)
        var word: UInt32 = 0
        for bit in 0..<32 {
            let px = Int((x + (CGFloat(bit) + 0.5) * cell) / screenWidth * CGFloat(width))
            let py = Int((y + 20) / screenHeight * CGFloat(height))
            guard px >= 0, px < width, py >= 0, py < height else { return }
            let value = p[py * stride + px * 4 + 1]
            guard value < 65 || value > 185 else { return }
            if value > 128 { word |= UInt32(1) << bit }
        }
        let id = Int(word & 0xffff)
        guard id > 0, Int(word >> 16) == (id ^ 0xffff) else { return }
        let time = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks))
        lock.lock(); defer { lock.unlock() }
        if id != last {
            // ID 1 is warmup. A missing intermediate ID cannot provide a bracket.
            if last != 0 {
                var row: [String: Any] = ["marker_id": id, "previous_marker_id": last, "host_display_s": time]
                if let scene = scenes[id] {
                    row["scene"] = scene
                    row["scene_transition"] = lastScene != nil && lastScene != scene
                }
                if id == (last % 65534) + 1, let oldTime = lastTime, oldTime <= time {
                    row["previous_host_display_s"] = oldTime
                }
                rows.append(row)
            }
            last = id
            if let scene = scenes[id] { lastScene = scene }
            // A bounded run uses at most 6000 marker IDs; discard older entries.
            if id > 100 { scenes.removeValue(forKey: id - 100) }
        }
        lastTime = time
    }
    func sawInitialMarker() -> Bool { lock.lock(); defer { lock.unlock() }; return last == 1 }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fputs("Observer stopped: \(error)\n", stderr) }
}
@MainActor final class Runner: NSObject, NSApplicationDelegate {
    var window: NSWindow?, timer: Timer?, animationLink: CADisplayLink?, observer: Observer?
    let env = ProcessInfo.processInfo.environment
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await run() } catch { fputs("Marker probe: \(error)\n", stderr); exit(1) } }
    }
    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw NSError(domain: "Screen Recording permission required", code: 1) }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }), let output = env["LATENCY_HOST_TRACE"], let duration = Double(env["LATENCY_SECONDS"] ?? "60"), duration > 0 else { throw NSError(domain: "Missing output, screen, or duration", code: 1) }
        guard let sceneInterval = LargeChangeCadence.Interval.parse(env["LATENCY_SCENE_INTERVAL_S"]) else {
            throw NSError(domain: "Scene interval must be 2 or 8 seconds", code: 1)
        }
        let optical = env["LATENCY_OPTICAL"] == "1"
        let animate = env["LATENCY_FIXTURE_ANIMATION_60"] == "1"
        guard !animate || optical else { throw NSError(domain: "Animation requires optical fixture mode", code: 1) }
        let photo: NSImage?
        if let photoPath = env["LATENCY_LARGE_CHANGE_PHOTO"] {
            guard optical, !photoPath.isEmpty,
                  let image = NSImage(contentsOfFile: photoPath),
                  image.size.width > 0, image.size.height > 0 else {
                throw NSError(domain: "Large-change fixture requires optical mode and a valid licensed photo", code: 1)
            }
            photo = image
        } else { photo = nil }
        if optical && (!duration.isFinite || duration > 600 || screen.frame.height <= 500) {
            throw NSError(domain: "Optical mode requires a duration at most 600 seconds and a display taller than 500 points", code: 1)
        }
        let w = screen.frame.width, h = screen.frame.height, cell = floor(w * 0.42 / 32)
        let frame = optical ? screen.frame : NSRect(x: 20, y: h - 430, width: cell * 32 + 32, height: 100)
        let pattern = Pattern(frame: NSRect(origin: .zero, size: frame.size), cell: cell, optical: optical, photo: photo)
        let window = optical ? OpticalWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let animation: FixtureAnimationRegion?
        if animate {
            let region = FixtureAnimationRegion(frame: FixtureAnimationCadence.frame(in: pattern.bounds))
            region.wantsLayer = true
            pattern.addSubview(region)
            animation = region
        } else { animation = nil }
        window.contentView = pattern; window.level = optical ? .screenSaver : .floating
        window.isReleasedWhenClosed = false
        if optical {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { window.orderFrontRegardless() }
        self.window = window
        if let path = env["LATENCY_TEXT_REFERENCE_PATH"] {
            guard env["LATENCY_LAB"] == "1", !path.isEmpty else {
                throw NSError(domain: "Synthetic text reference requires lab opt-in", code: 1)
            }
            try pattern.writeTextReference(to: URL(fileURLWithPath: path), screenWidth: Int(w), screenHeight: Int(h),
                                           backingScale: screen.backingScaleFactor)
        }
        if let animation {
            guard #available(macOS 14.0, *) else { throw NSError(domain: "Display-linked animation requires macOS 14", code: 1) }
            let link = animation.displayLink(target: animation, selector: #selector(FixtureAnimationRegion.displayTick(_:)))
            link.preferredFrameRateRange = FixtureAnimationCadence.requestedRange
            link.add(to: .main, forMode: .common)
            animationLink = link
        }
        defer { animationLink?.invalidate(); animationLink = nil }
        let markerX: CGFloat = optical ? 36 : frame.minX + 16
        let markerY: CGFloat = optical ? 370 : h - frame.maxY + 40
        let observer = Observer(x: markerX, y: markerY, cell: cell, width: w, height: h)
        self.observer = observer
        if photo != nil { observer.registerScene(id: pattern.id, scene: "text") }
        try await observer.start()
        // Establish the initial frame before starting either the timer or the run.
        let deadline = Date().addingTimeInterval(10)
        while !observer.sawInitialMarker() {
            guard Date() < deadline else { throw NSError(domain: "Initial marker not observed", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let fixtureStart = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                pattern.id = (pattern.id % 65534) + 1
                if photo != nil {
                    let nextPhotoScene = LargeChangeCadence.isPhoto(elapsed: ProcessInfo.processInfo.systemUptime - fixtureStart, interval: sceneInterval)
                    let sceneChanged = pattern.photoScene != nextPhotoScene
                    pattern.photoScene = nextPhotoScene
                    observer.registerScene(id: pattern.id, scene: pattern.photoScene ? "photo" : "text")
                    if sceneChanged { pattern.needsDisplay = true }
                    else { pattern.setNeedsDisplay(NSRect(x: 36, y: 370, width: 32 * cell, height: 40)) }
                } else { pattern.needsDisplay = true }
            }
        }
        print("MARKER_READY geometry=\(markerX),\(markerY),\(cell),\(w),\(h)"); fflush(stdout)
        // The paired-session controller ends the source after its final arm.
        // SIGTERM still aborts without turning partial data into a full run.
        let sleeper = Task { try await Task.sleep(for: .seconds(duration)) }
        signal(SIGUSR1, SIG_IGN)
        let finishSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        finishSignal.setEventHandler { sleeper.cancel() }
        finishSignal.resume()
        try? await sleeper.value
        finishSignal.cancel()
        timer?.invalidate(); animationLink?.invalidate(); animationLink = nil
        try await observer.stream?.stopCapture()
        let rows = observer.snapshot()
        let result: [String: Any] = ["kind": "device_host_marker", "clock": "host_monotonic_seconds", "duration_s": duration, "initial_marker_observed_before_timing": true,
            "animation_enabled": animate, "animation_target_fps": animate ? 60 : 0,
            "scene_interval_s": sceneInterval.rawValue, "scene_interval_role": sceneInterval.role, "geometry": ["x": markerX, "y": markerY, "cell": cell, "screen_width": w, "screen_height": h], "markers": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        window.close(); NSApp.terminate(nil)
    }
}
MainActor.assumeIsolated { let app = NSApplication.shared; app.setActivationPolicy(.accessory); let runner = Runner(); app.delegate = runner; app.run() }
