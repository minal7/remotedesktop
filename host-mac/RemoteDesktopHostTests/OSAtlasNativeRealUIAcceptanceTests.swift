import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import XCTest
@testable import RemoteDesktopHost

/// Opt-in acceptance for the final, native effect layer used by OS-Atlas.
///
/// Unlike the deterministic action tests, this case creates a real, visible
/// AppKit window, posts production `ComputerUsePredictedAction` values through
/// `InputInjector`, and requires the UI to expose a postcondition for every
/// event. Production-global events must carry
/// `InputInjector.syntheticEventTag`; the permission-free process fallback
/// uses a reserved event-number marker after reconstructing the AppKit window
/// envelope. A click from the test runner or a person cannot produce a false
/// pass in either mode.
///
/// The case is deliberately excluded from ordinary unit-test runs because it
/// foregrounds a window. Enable it with a per-user, empty opt-in file:
///
///     /tmp/com.threadmark.remotedesktop.osatlas-native-real-ui-<uid>
///
/// When this exact built host has Accessibility and PostEvent grants, events
/// use the production `.cghidEventTap`. Otherwise, the acceptance still posts
/// real CGEvents into the AppKit event loop with
/// `NSApplication.sendEvent`; this proves native UI behavior without
/// requesting a new permission or weakening normal onboarding. Create the
/// adjacent `-require-global-<uid>` file to fail unless the production global
/// event path is available.
@MainActor
final class OSAtlasNativeRealUIAcceptanceTests: XCTestCase {
    func testOpenApplicationThenNativeActionMatrixProducesVisiblePostconditions()
        async throws {
        guard Self.isEnabled else {
            throw XCTSkip(
                "Create the per-user /tmp opt-in file to run the visible native-action acceptance fixture.")
        }

        let hasGlobalEventAccess = AXIsProcessTrusted()
            && CGPreflightPostEventAccess()
        if Self.requiresGlobalEventAccess {
            XCTAssertTrue(
                hasGlobalEventAccess,
                "The exact built host test process lacks Accessibility or PostEvent access required for production-global CGEvent delivery")
            guard hasGlobalEventAccess else { return }
        }
        let originalFrontmostApplication = NSWorkspace.shared.frontmostApplication
        let originalActivationPolicy = NSApp.activationPolicy()
        let calculatorBundleID = "com.apple.calculator"
        let calculatorWasRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: calculatorBundleID).isEmpty
        let applicationTools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { _ in }),
            mayAct: { true })

        var fixture: OSAtlasNativeActionFixture?
        defer {
            fixture?.close()
            if !calculatorWasRunning {
                for application in NSRunningApplication.runningApplications(
                    withBundleIdentifier: calculatorBundleID) {
                    _ = application.terminate()
                }
            }
            if let originalFrontmostApplication,
               !originalFrontmostApplication.isTerminated {
                originalFrontmostApplication.activate(options: [
                    .activateAllWindows,
                ])
            }
            _ = NSApp.setActivationPolicy(originalActivationPolicy)
        }

        // OPEN_APP is intentionally first: the shipped executor must activate
        // the task-relevant application before it can ground pointer actions.
        try await applicationTools.openApplication(named: "Calculator")
        let calculatorOpened = await Self.eventually {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == calculatorBundleID
        }
        guard calculatorOpened else {
            XCTFail(
                "OPEN_APP must make the requested installed application frontmost")
            return
        }

        let visibleFixture = try OSAtlasNativeActionFixture.show()
        fixture = visibleFixture
        let fixtureActivated = await Self.eventually {
            visibleFixture.isKeyAndFrontmost
        }
        guard fixtureActivated else {
            XCTFail(
                "The real UI fixture must be key and frontmost before posting input")
            return
        }

        let eventDelivery: String
        let injector: InputInjector
        if hasGlobalEventAccess {
            eventDelivery = "production global .cghidEventTap"
            injector = InputInjector()
        } else {
            eventDelivery = "process-targeted NSApplication.sendEvent fallback"
            injector = visibleFixture.makeProcessTargetedInjector()
        }
        let tools = ComputerUseHostTools(
            injector: injector,
            mayAct: { true })
        let displayBounds = visibleFixture.displayBounds

        func performAndConfirm(
            _ action: OSAtlasGUIAction,
            expected: OSAtlasNativeUIPostcondition
        ) async throws -> Bool {
            guard visibleFixture.isKeyAndFrontmost else {
                XCTFail(
                    "Fixture lost key/frontmost state immediately before \(expected.rawValue): \(visibleFixture.diagnostics)")
                return false
            }
            let eventCountBeforeAction = visibleFixture.localTaggedEventCount
            try tools.perform(try OSAtlasComputerUseExecutor.predictedAction(
                from: action,
                displayBounds: displayBounds))
            let confirmed = await Self.eventually(timeout: 1) {
                visibleFixture.hasVisiblePostcondition(expected)
            }
            guard confirmed else {
                XCTFail(
                    "\(expected.rawValue) did not produce its visible UI postcondition: \(visibleFixture.diagnostics)")
                return false
            }
            XCTAssertGreaterThan(
                visibleFixture.localTaggedEventCount,
                eventCountBeforeAction,
                "The UI changed without a locally monitored tagged event")
            return true
        }

        guard try await performAndConfirm(
            visibleFixture.clickAction,
            expected: .singleClick) else { return }
        guard try await performAndConfirm(
            visibleFixture.doubleClickAction,
            expected: .doubleClick) else { return }
        guard try await performAndConfirm(
            visibleFixture.rightClickAction,
            expected: .rightClick) else { return }
        guard try await performAndConfirm(
            visibleFixture.dragAction,
            expected: .drag) else { return }

        let scrollRows: [(OSAtlasScrollDirection, OSAtlasNativeUIPostcondition)] = [
            (.up, .scrollUp),
            (.down, .scrollDown),
            (.left, .scrollLeft),
            (.right, .scrollRight),
        ]
        for (direction, expected) in scrollRows {
            guard try await performAndConfirm(
                .scroll(direction),
                expected: expected) else { return }
        }

        guard try await performAndConfirm(
            .enter,
            expected: .enter) else { return }
        guard try await performAndConfirm(
            .hotkey(
                usage: 0x0E,
                modifiers: 1 << 3,
                displayName: "COMMAND+K"),
            expected: .hotkey) else { return }

        XCTAssertEqual(
            visibleFixture.visiblePostconditions,
            Set(OSAtlasNativeUIPostcondition.allCases))
        XCTAssertTrue(
            visibleFixture.visibleStatus.contains("10 / 10 native effects confirmed"))

        let openApplicationEvidence = calculatorWasRunning
            ? "activated existing Calculator process"
            : "launched Calculator from not-running state"
        let evidence = XCTAttachment(string:
            "OPEN_APP: \(openApplicationEvidence)\n"
                + "CGEvent delivery: \(eventDelivery)\n"
                + visibleFixture.visibleStatus)
        evidence.name = "OS-Atlas native real-UI postconditions"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private static var isEnabled: Bool {
        return FileManager.default.fileExists(atPath:
            "/tmp/com.threadmark.remotedesktop.osatlas-native-real-ui-\(getuid())")
    }

    private static var requiresGlobalEventAccess: Bool {
        FileManager.default.fileExists(atPath:
            "/tmp/com.threadmark.remotedesktop.osatlas-native-real-ui-require-global-\(getuid())")
    }

    private static func eventually(
        timeout: TimeInterval = 4,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        } while Date() < deadline
        return predicate()
    }
}

private enum OSAtlasNativeUIPostcondition: String, CaseIterable, Hashable {
    case singleClick = "CLICK"
    case doubleClick = "DOUBLE_CLICK"
    case rightClick = "RIGHT_CLICK"
    case drag = "DRAG"
    case scrollUp = "SCROLL_UP"
    case scrollDown = "SCROLL_DOWN"
    case scrollLeft = "SCROLL_LEFT"
    case scrollRight = "SCROLL_RIGHT"
    case enter = "ENTER"
    case hotkey = "HOTKEY"
}

@MainActor
private final class OSAtlasNativeActionFixture {
    let displayBounds: CGRect

    private let window: NSWindow
    private let content: OSAtlasNativeActionFixtureView
    private let screen: NSScreen
    private var localEventMonitor: Any?
    private var lastProcessTargetedLocalPoint: CGPoint?

    private init(
        window: NSWindow,
        content: OSAtlasNativeActionFixtureView,
        screen: NSScreen,
        displayBounds: CGRect
    ) {
        self.window = window
        self.content = content
        self.screen = screen
        self.displayBounds = displayBounds
        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .mouseMoved,
            .scrollWheel,
            .keyDown,
            .keyUp,
        ]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { event in
            MainActor.assumeIsolated {
                content.noteAnyLocallyDelivered(event)
                if isOSAtlasNativeFixtureEvent(event) {
                    content.noteLocallyDelivered(event)
                }
            }
            return event
        }
    }

    static func show() throws -> OSAtlasNativeActionFixture {
        guard let screen = screen(for: CGMainDisplayID()) else {
            throw OSAtlasNativeActionFixtureError.mainDisplayUnavailable
        }
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            throw OSAtlasNativeActionFixtureError.mainDisplayUnavailable
        }

        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(900, visible.width - 80),
            height: min(650, visible.height - 80))
        guard size.width >= 760, size.height >= 520 else {
            throw OSAtlasNativeActionFixtureError.displayTooSmall
        }
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
            screen: screen)
        window.title = "Remote Desktop OS-Atlas Native Action Fixture"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        let content = OSAtlasNativeActionFixtureView(frame: NSRect(
            origin: .zero,
            size: size))
        window.contentView = content

        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)

        return OSAtlasNativeActionFixture(
            window: window,
            content: content,
            screen: screen,
            displayBounds: displayBounds)
    }

    var isKeyAndFrontmost: Bool {
        window.isKeyWindow
            && NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
    }

    var clickAction: OSAtlasGUIAction {
        let point = normalizedPoint(at: content.singleClickRect.center)
        return .click(x: point.x, y: point.y)
    }

    var doubleClickAction: OSAtlasGUIAction {
        let point = normalizedPoint(at: content.doubleClickRect.center)
        return .doubleClick(x: point.x, y: point.y)
    }

    var rightClickAction: OSAtlasGUIAction {
        let point = normalizedPoint(at: content.rightClickRect.center)
        return .rightClick(x: point.x, y: point.y)
    }

    var dragAction: OSAtlasGUIAction {
        let start = normalizedPoint(at: content.dragSourceRect.center)
        let end = normalizedPoint(at: content.dragDestinationRect.center)
        return .drag(
            fromX: start.x,
            fromY: start.y,
            toX: end.x,
            toY: end.y)
    }

    var visiblePostconditions: Set<OSAtlasNativeUIPostcondition> {
        content.postconditions
    }

    var visibleStatus: String {
        content.statusLabel.stringValue
    }

    var localTaggedEventCount: Int {
        content.locallyDeliveredTaggedEventTypes.count
    }

    var diagnostics: String {
        let eventTypes = content.locallyDeliveredTaggedEventTypes
            .map(String.init(describing:))
            .joined(separator: ",")
        let eventDetails = content.locallyDeliveredTaggedEventDetails
            .joined(separator: "; ")
        let allEventDetails = content.allLocallyDeliveredEventDetails
            .joined(separator: "; ")
        return "key=\(window.isKeyWindow) frontmost=\(isKeyAndFrontmost) "
            + "window=\(window.windowNumber) taggedLocalEvents=[\(eventTypes)] "
            + "taggedLocalDetails=[\(eventDetails)] "
            + "allLocalDetails=[\(allEventDetails)] "
            + "status=\(visibleStatus)"
    }

    func makeProcessTargetedInjector() -> InputInjector {
        InputInjector(eventPoster: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      let appKitEvent = self.processTargetedEvent(from: event)
                else { return }
                let handledBefore = self.content.handledScrollEventCount
                NSApp.sendEvent(appKitEvent)
                if event.type == .scrollWheel,
                   self.content.handledScrollEventCount == handledBefore {
                    self.window.sendEvent(appKitEvent)
                }
            }
        })
    }

    private func processTargetedEvent(from event: CGEvent) -> NSEvent? {
        if event.type == .scrollWheel {
            // A CG scroll event has no AppKit factory that accepts a target
            // window. Its location is the physical cursor, which the fallback
            // intentionally does not move. Encode the preceding production
            // pointer target as locationInWindow for NSWindow.sendEvent while
            // preserving the production delta, flags, and synthetic tag.
            if let localPoint = lastProcessTargetedLocalPoint {
                event.location = CGPoint(
                    x: displayBounds.minX
                        + localPoint.x - screen.frame.minX,
                    y: displayBounds.minY
                        + screen.frame.maxY - localPoint.y)
            }
            return NSEvent(cgEvent: event)
        }

        let type: NSEvent.EventType
        switch event.type {
        case .leftMouseDown: type = .leftMouseDown
        case .leftMouseUp: type = .leftMouseUp
        case .rightMouseDown: type = .rightMouseDown
        case .rightMouseUp: type = .rightMouseUp
        case .mouseMoved: type = .mouseMoved
        case .leftMouseDragged: type = .leftMouseDragged
        case .rightMouseDragged: type = .rightMouseDragged
        default:
            return NSEvent(cgEvent: event)
        }

        // Direct NSApplication delivery bypasses WindowServer, so
        // NSEvent(cgEvent:) has windowNumber 0 and exposes its screen
        // coordinate as locationInWindow. Recreate only the test fallback's
        // mouse envelope with the real fixture window and a window-local
        // point. All semantic fields still come from InputInjector's CGEvent.
        let globalPoint = event.location
        let appKitScreenPoint = CGPoint(
            x: screen.frame.minX + globalPoint.x - displayBounds.minX,
            y: screen.frame.maxY - globalPoint.y + displayBounds.minY)
        let localPoint = window.convertPoint(fromScreen: appKitScreenPoint)
        lastProcessTargetedLocalPoint = localPoint
        guard let routedEvent = NSEvent.mouseEvent(
            with: type,
            location: localPoint,
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: UInt(event.flags.rawValue)),
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: osAtlasProcessTargetedEventNumber,
            clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
            pressure: Float(event.getDoubleValueField(.mouseEventPressure)))
        else { return nil }
        return routedEvent
    }

    func hasVisiblePostcondition(
        _ postcondition: OSAtlasNativeUIPostcondition
    ) -> Bool {
        content.postconditions.contains(postcondition)
            && content.statusLabel.stringValue.contains(postcondition.rawValue)
    }

    func close() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        window.orderOut(nil)
        window.close()
    }

    private func normalizedPoint(at localPoint: NSPoint) -> (x: Int, y: Int) {
        let windowPoint = content.convert(localPoint, to: nil)
        let appKitScreenPoint = window.convertPoint(toScreen: windowPoint)
        let appKitFrame = screen.frame
        let globalPoint = CGPoint(
            x: displayBounds.minX
                + appKitScreenPoint.x - appKitFrame.minX,
            y: displayBounds.minY
                + appKitFrame.maxY - appKitScreenPoint.y)
        let x = Int((((globalPoint.x - displayBounds.minX)
            / displayBounds.width) * 1_000).rounded())
        let y = Int((((globalPoint.y - displayBounds.minY)
            / displayBounds.height) * 1_000).rounded())
        return (
            min(1_000, max(0, x)),
            min(1_000, max(0, y)))
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }
}

private enum OSAtlasNativeActionFixtureError: Error {
    case mainDisplayUnavailable
    case displayTooSmall
}

@MainActor
private final class OSAtlasNativeActionFixtureView: NSView {
    private(set) var postconditions: Set<OSAtlasNativeUIPostcondition> = []
    private(set) var locallyDeliveredTaggedEventTypes: [NSEvent.EventType] = []
    private(set) var locallyDeliveredTaggedEventDetails: [String] = []
    private(set) var allLocallyDeliveredEventDetails: [String] = []
    let statusLabel = NSTextField(labelWithString:
        "0 / 10 native effects confirmed")

    private var isDraggingFixtureCard = false
    private var sawSyntheticDrag = false
    private var viewportOffset = CGPoint.zero
    private(set) var handledScrollEventCount = 0

    override var acceptsFirstResponder: Bool { true }

    var singleClickRect: NSRect {
        NSRect(x: 36, y: bounds.height - 194, width: 230, height: 86)
    }

    var doubleClickRect: NSRect {
        NSRect(x: 286, y: bounds.height - 194, width: 230, height: 86)
    }

    var rightClickRect: NSRect {
        NSRect(x: 536, y: bounds.height - 194, width: 230, height: 86)
    }

    var dragSourceRect: NSRect {
        NSRect(x: 50, y: 180, width: 190, height: 100)
    }

    var dragDestinationRect: NSRect {
        NSRect(x: 310, y: 180, width: 190, height: 100)
    }

    private var scrollRect: NSRect {
        NSRect(x: 555, y: 145, width: 275, height: 190)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.075,
            blue: 0.12,
            alpha: 1).cgColor

        statusLabel.frame = NSRect(
            x: 36,
            y: 28,
            width: frameRect.width - 72,
            height: 68)
        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setAccessibilityIdentifier(
            "osatlas-native-action-status")
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func noteLocallyDelivered(_ event: NSEvent) {
        locallyDeliveredTaggedEventTypes.append(event.type)
        let cgLocation = event.cgEvent?.location ?? .zero
        locallyDeliveredTaggedEventDetails.append(
            "type=\(event.type.rawValue) window=\(event.windowNumber) "
                + "locationInWindow=\(event.locationInWindow) "
                + "cgLocation=\(cgLocation)")
    }

    func noteAnyLocallyDelivered(_ event: NSEvent) {
        let cgLocation = event.cgEvent?.location ?? .zero
        let eventNumber = osAtlasMouseEventNumber(event)
            .map(String.init) ?? "n/a"
        allLocallyDeliveredEventDetails.append(
            "type=\(event.type.rawValue) window=\(event.windowNumber) "
                + "eventNumber=\(eventNumber) "
                + "locationInWindow=\(event.locationInWindow) "
                + "cgLocation=\(cgLocation)")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawText(
            "OS-Atlas native effects — local, no network, no external mutations",
            in: NSRect(x: 36, y: bounds.height - 76,
                       width: bounds.width - 72, height: 34),
            size: 21,
            weight: .semibold,
            color: .white)

        drawZone(singleClickRect, title: "Click once", detail: "CLICK")
        drawZone(doubleClickRect, title: "Double-click me", detail: "DOUBLE_CLICK")
        drawZone(rightClickRect, title: "Open context marker", detail: "RIGHT_CLICK")

        drawZone(
            dragSourceRect,
            title: "Drag this card",
            detail: "DRAG SOURCE",
            color: NSColor.systemOrange)
        drawZone(
            dragDestinationRect,
            title: "Drop card here",
            detail: "DRAG DESTINATION",
            color: NSColor.systemGreen)

        let scrollPath = NSBezierPath(roundedRect: scrollRect, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        scrollPath.fill()
        NSColor.systemTeal.setStroke()
        scrollPath.lineWidth = 2
        scrollPath.stroke()
        drawText(
            "Scroll viewport\nUP · DOWN · LEFT · RIGHT",
            in: NSRect(x: scrollRect.minX + 18,
                       y: scrollRect.maxY - 70,
                       width: scrollRect.width - 36,
                       height: 54),
            size: 15,
            weight: .medium,
            color: .white)
        let markerCenter = CGPoint(
            x: scrollRect.midX + max(-55, min(55, viewportOffset.x / 8)),
            y: scrollRect.midY + max(-32, min(32, viewportOffset.y / 8)))
        NSColor.systemTeal.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: markerCenter.x - 10,
            y: markerCenter.y - 10,
            width: 20,
            height: 20)).fill()

        drawText(
            "Keyboard proof: press Return, then ⌘K",
            in: NSRect(x: 50, y: 118, width: 450, height: 30),
            size: 16,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.9, alpha: 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard isOSAtlasNativeFixtureEvent(event) else { return }
        let point = fixturePoint(for: event)
        if singleClickRect.contains(point), event.clickCount == 1 {
            confirm(.singleClick)
        } else if doubleClickRect.contains(point), event.clickCount >= 2 {
            confirm(.doubleClick)
        } else if dragSourceRect.contains(point) {
            isDraggingFixtureCard = true
            sawSyntheticDrag = false
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isOSAtlasNativeFixtureEvent(event) else { return }
        let point = fixturePoint(for: event)
        if rightClickRect.contains(point) {
            confirm(.rightClick)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingFixtureCard,
              isOSAtlasNativeFixtureEvent(event) else {
            return
        }
        sawSyntheticDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isDraggingFixtureCard = false
            sawSyntheticDrag = false
        }
        guard isDraggingFixtureCard,
              sawSyntheticDrag,
              isOSAtlasNativeFixtureEvent(event) else { return }
        let point = fixturePoint(for: event)
        if dragDestinationRect.contains(point) {
            confirm(.drag)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isOSAtlasNativeFixtureEvent(event) else { return }
        handledScrollEventCount += 1
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        viewportOffset.x += dx
        viewportOffset.y += dy
        if abs(dy) >= abs(dx), dy > 0 {
            confirm(.scrollUp)
        } else if abs(dy) >= abs(dx), dy < 0 {
            confirm(.scrollDown)
        } else if dx > 0 {
            confirm(.scrollLeft)
        } else if dx < 0 {
            confirm(.scrollRight)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isOSAtlasNativeFixtureEvent(event) else { return }
        if event.keyCode == 0x24 {
            confirm(.enter)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask)
        if isOSAtlasNativeFixtureEvent(event),
           modifiers.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            confirm(.hotkey)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func confirm(_ postcondition: OSAtlasNativeUIPostcondition) {
        postconditions.insert(postcondition)
        let completed = OSAtlasNativeUIPostcondition.allCases.filter {
            postconditions.contains($0)
        }.map(\.rawValue)
        statusLabel.stringValue =
            "\(completed.count) / 10 native effects confirmed: "
            + completed.joined(separator: " · ")
        needsDisplay = true
    }

    private func fixturePoint(for event: NSEvent) -> NSPoint {
        guard event.eventNumber == osAtlasProcessTargetedEventNumber,
              let window,
              let screen = window.screen,
              let cgEvent = event.cgEvent else {
            return convert(event.locationInWindow, from: nil)
        }
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let globalPoint = cgEvent.location
        let appKitScreenPoint = CGPoint(
            x: screen.frame.minX + globalPoint.x - displayBounds.minX,
            y: screen.frame.maxY - globalPoint.y + displayBounds.minY)
        let windowPoint = window.convertPoint(fromScreen: appKitScreenPoint)
        return convert(windowPoint, from: nil)
    }

    private func drawZone(
        _ rect: NSRect,
        title: String,
        detail: String,
        color: NSColor = NSColor.systemBlue
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        color.withAlphaComponent(0.22).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 2
        path.stroke()
        drawText(
            title,
            in: NSRect(x: rect.minX + 14, y: rect.midY + 2,
                       width: rect.width - 28, height: 26),
            size: 16,
            weight: .semibold,
            color: .white)
        drawText(
            detail,
            in: NSRect(x: rect.minX + 14, y: rect.midY - 27,
                       width: rect.width - 28, height: 22),
            size: 12,
            weight: .medium,
            color: color)
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: style,
            ])
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// NSEvent exposes only the low 16 bits of eventNumber. "AC" is the reserved
// marker carried by the process-targeted AppKit envelope.
private let osAtlasProcessTargetedEventNumber = 0x4143

private func isOSAtlasNativeFixtureEvent(_ event: NSEvent) -> Bool {
    InputInjector.isSynthetic(event)
        || osAtlasMouseEventNumber(event)
            == osAtlasProcessTargetedEventNumber
}

private func osAtlasMouseEventNumber(_ event: NSEvent) -> Int? {
    switch event.type {
    case .leftMouseDown, .leftMouseUp,
         .rightMouseDown, .rightMouseUp,
         .otherMouseDown, .otherMouseUp,
         .mouseMoved, .leftMouseDragged,
         .rightMouseDragged, .otherMouseDragged:
        return event.eventNumber
    default:
        return nil
    }
}
