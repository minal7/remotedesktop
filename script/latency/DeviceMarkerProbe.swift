import AppKit
import ScreenCaptureKit
import CoreMedia

// The observer reads only the marker cells and persists only their IDs and times.
final class Pattern: NSView {
    var id = 1
    let cell: CGFloat
    let optical: Bool
    init(frame: NSRect, cell: CGFloat, optical: Bool = false) {
        self.cell = cell; self.optical = optical; super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.darkGray.setFill(); bounds.fill()
        if optical {
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
    var stream: SCStream?
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
                if id == (last % 65534) + 1, let oldTime = lastTime, oldTime <= time {
                    row["previous_host_display_s"] = oldTime
                }
                rows.append(row)
            }
            last = id
        }
        lastTime = time
    }
    func sawInitialMarker() -> Bool { lock.lock(); defer { lock.unlock() }; return last == 1 }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fputs("Observer stopped: \(error)\n", stderr) }
}
@MainActor final class Runner: NSObject, NSApplicationDelegate {
    var window: NSWindow?, timer: Timer?, observer: Observer?
    let env = ProcessInfo.processInfo.environment
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await run() } catch { fputs("Marker probe: \(error)\n", stderr); exit(1) } }
    }
    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw NSError(domain: "Screen Recording permission required", code: 1) }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }), let output = env["LATENCY_HOST_TRACE"], let duration = Double(env["LATENCY_SECONDS"] ?? "60"), duration > 0 else { throw NSError(domain: "Missing output, screen, or duration", code: 1) }
        let optical = env["LATENCY_OPTICAL"] == "1"
        if optical && (!duration.isFinite || duration > 600 || screen.frame.height <= 500) {
            throw NSError(domain: "Optical mode requires a duration at most 600 seconds and a display taller than 500 points", code: 1)
        }
        let w = screen.frame.width, h = screen.frame.height, cell = floor(w * 0.42 / 32)
        let frame = optical ? screen.frame : NSRect(x: 20, y: h - 430, width: cell * 32 + 32, height: 100)
        let pattern = Pattern(frame: NSRect(origin: .zero, size: frame.size), cell: cell, optical: optical)
        let window = optical ? OpticalWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pattern; window.level = optical ? .screenSaver : .floating
        window.isReleasedWhenClosed = false
        if optical {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { window.orderFrontRegardless() }
        self.window = window
        let markerX: CGFloat = optical ? 36 : frame.minX + 16
        let markerY: CGFloat = optical ? 370 : h - frame.maxY + 40
        let observer = Observer(x: markerX, y: markerY, cell: cell, width: w, height: h)
        self.observer = observer; try await observer.start()
        // Establish the initial frame before starting either the timer or the run.
        let deadline = Date().addingTimeInterval(10)
        while !observer.sawInitialMarker() {
            guard Date() < deadline else { throw NSError(domain: "Initial marker not observed", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { pattern.id = (pattern.id % 65534) + 1; pattern.needsDisplay = true }
        }
        print("MARKER_READY geometry=\(markerX),\(markerY),\(cell),\(w),\(h)"); fflush(stdout)
        try await Task.sleep(for: .seconds(duration))
        timer?.invalidate(); try await observer.stream?.stopCapture()
        let rows = observer.snapshot()
        let result: [String: Any] = ["kind": "device_host_marker", "clock": "host_monotonic_seconds", "duration_s": duration, "initial_marker_observed_before_timing": true, "geometry": ["x": markerX, "y": markerY, "cell": cell, "screen_width": w, "screen_height": h], "markers": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        window.close(); NSApp.terminate(nil)
    }
}
MainActor.assumeIsolated { let app = NSApplication.shared; app.setActivationPolicy(.accessory); let runner = Runner(); app.delegate = runner; app.run() }
