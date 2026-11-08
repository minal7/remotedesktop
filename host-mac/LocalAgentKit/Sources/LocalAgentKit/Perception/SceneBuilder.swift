import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Where the harness gets its view of the computer. Real builder in production, a
/// script in tests, so the whole loop can be tested without touching a screen.
public protocol SceneSource: AnyObject, Sendable {
    func build(_ options: SceneBuilder.Options) async -> Scene
    func captureForSettling(rect: CGRect) async -> ScreenFrame?
    /// The display showing only this scene's app. Nil when that isn't available.
    func captureApp(for scene: Scene) async -> (frame: ScreenFrame, regions: [CGRect])?
}

public extension SceneSource {
    func captureApp(for scene: Scene) async -> (frame: ScreenFrame, regions: [CGRect])? { nil }
}

/// Fuses accessibility and OCR into the one Scene the harness works from.
/// Takes no model time: everything here is deterministic host code.
public final class SceneBuilder: SceneSource, @unchecked Sendable {
    public struct Options: Sendable {
        public var capture = true
        public var deep = false
        public init(capture: Bool = true, deep: Bool = false) { self.capture = capture; self.deep = deep }
    }

    private let allocator = ElementIDAllocator()
    private var cachedOCR: (signature: [UInt8], lines: [OCRReader.Line])?
    private var cachedMenuBar: (pid: pid_t, names: [String])?
    private var lastTitle: (pid: pid_t, title: String)?

    public init() {}

    public func captureForSettling(rect: CGRect) async -> ScreenFrame? {
        try? await ScreenCapturer.capture(rect: rect)
    }

    public func captureApp(for scene: Scene) async -> (frame: ScreenFrame, regions: [CGRect])? {
        guard scene.pid > 0 else { return nil }
        return (try? await ScreenCapturer.captureApp(pid: scene.pid, near: scene.windowFrame)) ?? nil
    }

    public func build(_ options: Options = .init()) async -> Scene {
        var scene = Scene()
        guard let app = Self.frontmostApp() else { return scene }
        scene.appName = app.name
        scene.bundleID = app.bundleID
        scene.pid = app.pid

        let deep = options.deep
        let pid = app.pid
        var read = await Task.detached(priority: .userInitiated) {
            var reader = AccessibilityReader()
            reader.deep = deep
            if deep { reader.nodeBudget = 6_000; reader.timeBudget = 3 }
            return reader.read(pid: pid)
        }.value
        // A browser takes a few seconds to fill in its pages after being asked the first time.
        // Acting before then would miss what's on the page, so wait. An app with no pages waits once.
        if read.firstLook, read.url == nil, !read.windowFrame.isEmpty {
            for _ in 0..<12 where read.url == nil {
                try? await Task.sleep(for: .milliseconds(300))
                read = await Task.detached(priority: .userInitiated) { AccessibilityReader().read(pid: pid) }.value
            }
        }
        // A window that has just changed title with no page in it may be a page that's still filling in.
        if !read.firstLook, read.url == nil, !read.windowFrame.isEmpty, let before = lastTitle, before.pid == pid, before.title != read.windowTitle {
            for _ in 0..<6 where read.url == nil {
                try? await Task.sleep(for: .milliseconds(300))
                read = await Task.detached(priority: .userInitiated) { AccessibilityReader().read(pid: pid) }.value
            }
        }
        lastTitle = (pid, read.windowTitle)
        // Chromium only fills its tree after the first request. Look once more.
        if read.elements.count < 4, !read.windowFrame.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            read = await Task.detached(priority: .userInitiated) {
                AccessibilityReader().read(pid: pid)
            }.value
        }

        scene.windowTitle = read.windowTitle
        scene.windowFrame = read.windowFrame
        scene.windowButtons = read.windowButtons
        scene.windowHandle = read.windowHandle
        scene.otherWindows = Array(read.otherWindows.prefix(6))
        scene.menuBar = menuBarNames(pid: pid)
        scene.url = read.url
        scene.frameURLs = read.frameURLs
        if let page = read.pageFrame {
            scene.pageElementCount = read.elements.filter { page.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count
        }
        scene.hasModal = read.hasModal
        scene.hiddenAbove = read.hiddenAbove
        scene.hiddenBelow = read.hiddenBelow
        scene.handles = read.handles
        var elements = Self.mergeAdjacentText(read.elements)

        // No accessible window? Ask the window server. If there's still none, the app
        // has no window, and there's nothing of its to look at.
        var captureRect = read.windowFrame
        if captureRect.isEmpty, let bounds = Self.windowBounds(pid: pid) {
            captureRect = bounds.frame
            scene.windowFrame = bounds.frame
            if scene.windowTitle.isEmpty { scene.windowTitle = bounds.title }
        }
        if options.capture, !captureRect.isEmpty {
            scene.screenshot = try? await ScreenCapturer.capture(rect: captureRect)
        }

        // Too little from accessibility: read the pixels.
        if !captureRect.isEmpty, Self.needsOCR(elements: elements, window: captureRect), let frame = scene.screenshot {
            let lines = await ocrLines(frame)
            scene.usedOCR = !lines.isEmpty
            elements = Self.fuse(elements, lines: lines)
            scene.isVisuallyOpaque = true
        }

        elements = Self.removeNoise(elements)
        allocator.assign(&elements)
        scene.elements = elements
        scene.fingerprint = Self.fingerprint(of: scene)
        return scene
    }

    private func menuBarNames(pid: pid_t) -> [String] {
        if let cachedMenuBar, cachedMenuBar.pid == pid { return cachedMenuBar.names }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return [] }
        let names = AX.children(bar).compactMap { AX.string($0, kAXTitleAttribute)?.nilIfBlank }.filter { $0 != "Apple" }
        // The first entry repeats the app's own name; it rarely matters to a task.
        let trimmed = Array(names.dropFirst())
        cachedMenuBar = (pid, trimmed)
        return trimmed
    }

    private func ocrLines(_ frame: ScreenFrame) async -> [OCRReader.Line] {
        if let cachedOCR, ScreenFrame.distance(cachedOCR.signature, frame.signature) < 0.0002 { return cachedOCR.lines }
        let lines = await Task.detached(priority: .userInitiated) { (try? OCRReader.read(frame)) ?? [] }.value
        cachedOCR = (frame.signature, lines)
        return lines
    }

    public struct FrontApp: Sendable, Equatable {
        public let name: String
        public let bundleID: String
        public let pid: pid_t
    }

    /// The app in front. NSRunningApplication can report a process ID of -1 for a
    /// running app, so a bad ID is repaired from the window server, which always
    /// knows who owns what.
    public static func frontmostApp() -> FrontApp? {
        let current = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? ""
        var pid = app.processIdentifier
        if pid <= 0 { pid = windowOwnerPID(named: name) ?? pid }
        guard pid != current else { return nil }
        return FrontApp(name: name, bundleID: app.bundleIdentifier ?? "", pid: pid)
    }

    private static func normalWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    /// The window a sheet or dialog belongs to, so it's seen with what it sits on.
    static func parentWindow(of rect: CGRect, pid: pid_t) -> CGRect? {
        for window in normalWindows() where (window[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            if frame.width * frame.height > rect.width * rect.height, frame.contains(CGPoint(x: rect.midX, y: rect.midY)) { return frame }
        }
        return nil
    }

    static func windowOwnerPID(named name: String) -> pid_t? {
        for window in normalWindows() where (window[kCGWindowOwnerName as String] as? String) == name {
            if let pid = window[kCGWindowOwnerPID as String] as? Int { return pid_t(pid) }
        }
        return nil
    }

    /// Frontmost window bounds from the window server, for apps with no usable
    /// accessibility tree. Keeps the capture to that app, never the whole display:
    /// other apps' content is neither useful nor anything the model should read.
    static func windowBounds(pid: pid_t) -> (frame: CGRect, title: String)? {
        for window in normalWindows() where (window[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"], width > 40, height > 40 else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            return (frame, window[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    /// Accessibility is "poor" when it names few things or covers little of the
    /// window, typical of canvas, Java and remote-session surfaces.
    static func needsOCR(elements: [UIElement], window: CGRect) -> Bool {
        let content = elements.filter { !["close window", "minimize window", "zoom window"].contains($0.label) }
        guard window.width > 0, window.height > 0 else { return true }
        // A document editor is one huge text area and very little else. That's a good tree.
        let largeEditable = content.contains { $0.editable && $0.frame.width * $0.frame.height > window.width * window.height * 0.25 }
        if largeEditable { return false }
        if content.count < 5 { return true }
        let textCount = content.filter { $0.role == "text" || $0.editable }.count
        var covered = 0.0
        for element in content {
            let clipped = element.frame.intersection(window)
            if !clipped.isNull { covered += clipped.width * clipped.height }
        }
        return textCount < 2 && covered / (window.width * window.height) < 0.05
    }

    /// OCR lines become clickable `text` elements unless accessibility already covers them.
    static func fuse(_ elements: [UIElement], lines: [OCRReader.Line]) -> [UIElement] {
        var result = elements
        for line in lines {
            let overlapping = elements.contains { element in
                let intersection = element.frame.intersection(line.frame)
                guard !intersection.isNull else { return false }
                let area = line.frame.width * line.frame.height
                return area > 0 && intersection.width * intersection.height / area > 0.6 && !element.label.isEmpty
            }
            if overlapping { continue }
            result.append(UIElement(role: "text", label: line.text, frame: line.frame, source: .ocr))
        }
        return result
    }

    /// Punctuation fragments, text that merely repeats the control next to it (a web
    /// heading and its inner text, a label and its field), and machine-generated names
    /// tell the model nothing but cost tokens every step.
    static func removeNoise(_ elements: [UIElement]) -> [UIElement] {
        func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).lowercased() }
        var kept: [UIElement] = []
        kept.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() {
            if element.role == "text" {
                if !element.label.contains(where: { $0.isLetter || $0.isNumber }) { continue }
                let label = key(element.label)
                let previous = kept.last.map { key($0.label) }
                let next = index + 1 < elements.count ? key(elements[index + 1].label) : nil
                if label == previous || (label == next && elements[index + 1].isInteractive) { continue }
            }
            var element = element
            let hexDigits = element.label.filter { $0.isHexDigit }
            if element.label.count >= 24, hexDigits.count == element.label.count { element.label = "" }
            kept.append(element)
        }
        return kept
    }

    /// Web pages split a sentence across many static-text nodes. Joining the ones on
    /// a line saves many tokens and reads better.
    static func mergeAdjacentText(_ elements: [UIElement]) -> [UIElement] {
        var merged: [UIElement] = []
        merged.reserveCapacity(elements.count)
        for element in elements {
            if element.role == "text", let last = merged.last, last.role == "text", !last.inModal || element.inModal,
               abs(last.frame.midY - element.frame.midY) < max(last.frame.height, element.frame.height) * 0.6,
               element.frame.minX - last.frame.maxX < 24, element.frame.minX >= last.frame.minX - 2,
               last.label.count + element.label.count < 220 {
                merged[merged.count - 1].label = last.label + " " + element.label
                merged[merged.count - 1].frame = last.frame.union(element.frame)
            } else {
                merged.append(element)
            }
        }
        return merged
    }

    static func fingerprint(of scene: Scene) -> String {
        var hasher = Hasher()
        hasher.combine(scene.bundleID)
        hasher.combine(scene.windowTitle)
        hasher.combine(scene.url)
        hasher.combine(scene.hasModal)
        for element in scene.elements {
            hasher.combine(element.identityKey)
            hasher.combine(element.value)
            hasher.combine(element.focused)
        }
        return String(hasher.finalize(), radix: 16)
    }
}
