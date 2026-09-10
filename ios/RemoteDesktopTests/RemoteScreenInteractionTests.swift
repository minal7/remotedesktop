import XCTest
import SwiftUI
import UIKit
@testable import RemoteDesktop

final class RemoteScreenInteractionTests: XCTestCase {
    func test_fullDisplaySurfaceSharesItsVideoAndInputRectangleAcrossAspectRatios() {
        for viewport in [CGRect(x: 0, y: 0, width: 1024, height: 768),
                         CGRect(x: 10, y: 20, width: 400, height: 900)] {
            for size in [(1920, 1080), (1200, 1920), (1728, 1117)] {
                let display = DisplayInfo(w: size.0, h: size.1, scale: 2, fullDisplaySurface: true)
                let layout = RemoteScreenRenderingLayout(bounds: viewport, display: display)
                let input = RemoteScreenGeometry(bounds: viewport, display: display)
                XCTAssertEqual(layout.contentMode, .scaleToFill)
                XCTAssertEqual(layout.videoRect, input.interactiveRect)
                let first = input.localToRemote(CGPoint(x: layout.videoRect.minX, y: layout.videoRect.minY))
                let last = input.localToRemote(CGPoint(x: layout.videoRect.maxX, y: layout.videoRect.maxY))
                XCTAssertEqual(first.x, 0); XCTAssertEqual(first.y, 0)
                XCTAssertEqual(last.x, size.0 - 1); XCTAssertEqual(last.y, size.1 - 1)
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let legacy = RemoteScreenRenderingLayout(bounds: bounds, display: DisplayInfo(w: 1728, h: 1117, scale: 2))
        XCTAssertEqual(legacy.videoRect, bounds); XCTAssertEqual(legacy.contentMode, .scaleAspectFit)
    }

    func test_fullDisplaySurfaceRestoresLogicalAspectIndependentlyOfDrawableRounding() {
        let display = DisplayInfo(w: 1728, h: 1117, scale: 2, fullDisplaySurface: true)
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let layout = RemoteScreenRenderingLayout(bounds: bounds, display: display)
        let drawable = MetalVideoRenderSizing.rendererFrameSize(CGSize(width: 3456, height: 2234),
            displayScale: 3, maximumTextureDimension: 8192)
        XCTAssertNotEqual(drawable.width / drawable.height, CGFloat(display.w) / CGFloat(display.h),
                          "Integral drawable rounding is not an exact logical aspect ratio")
        XCTAssertEqual(layout.videoRect.width / layout.videoRect.height,
                       CGFloat(display.w) / CGFloat(display.h), accuracy: 0.000000001)
        XCTAssertEqual(layout.contentMode, .scaleToFill,
                       "Fit the full surface to the logical rectangle, not another aspect-fit inside it")
        let input = RemoteScreenGeometry(bounds: bounds, display: display)
        let center = input.localToRemote(CGPoint(x: layout.videoRect.midX, y: layout.videoRect.midY))
        XCTAssertEqual(center.x, 864); XCTAssertEqual(center.y, 558)
    }

    func test_sessionChromePolicy_staysVisibleWhileConnectingThenAutoHides() {
        XCTAssertFalse(SessionChromePolicy.autoHides(after: .connecting))
        XCTAssertTrue(SessionChromePolicy.autoHides(after: .connected))
        XCTAssertFalse(SessionChromePolicy.autoHides(after: .idle))
        XCTAssertFalse(SessionChromePolicy.autoHides(after: .ended("test")))
    }

    func test_interactiveRect_matchesAspectFitDisplayArea() {
        let geometry = RemoteScreenGeometry(
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            display: DisplayInfo(w: 1920, h: 1080, scale: 2.0))

        let rect = geometry.interactiveRect
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 96, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.height, 576, accuracy: 0.001)
    }

    func test_localToRemote_clampsLetterboxedPointsToDisplayEdges() {
        let geometry = RemoteScreenGeometry(
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            display: DisplayInfo(w: 1920, h: 1080, scale: 2.0))

        let topLeft = geometry.localToRemote(CGPoint(x: 0, y: 0))
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0)

        let bottomRight = geometry.localToRemote(CGPoint(x: 1024, y: 768))
        XCTAssertEqual(bottomRight.x, 1919)
        XCTAssertEqual(bottomRight.y, 1079)
    }

    func test_touchCursorPolicy_onlyStartsDragOnSecondTap() {
        XCTAssertFalse(TouchCursorPolicy.beginsDrag(tapCount: 1))
        XCTAssertTrue(TouchCursorPolicy.beginsDrag(tapCount: 2))
    }

    func test_touchCursorPolicy_emitsClickAndDragReleaseSequences() {
        XCTAssertEqual(
            TouchCursorPolicy.endButtonSequence(duration: 0.1, isDragging: false, rightClickFired: false),
            [0b001, 0])
        XCTAssertEqual(
            TouchCursorPolicy.endButtonSequence(duration: 0.1, isDragging: true, rightClickFired: false),
            [0])
        XCTAssertEqual(
            TouchCursorPolicy.endButtonSequence(duration: 0.5, isDragging: false, rightClickFired: true),
            [])
    }

    func test_indirectPointerClickPolicy_mapsButtonsAndKeepsClickState() {
        XCTAssertEqual(
            IndirectPointerClickPolicy.buttons(from: [.primary, .secondary]),
            0b011)
        XCTAssertEqual(
            IndirectPointerClickPolicy.buttons(
                for: UIEvent.ButtonMask(),
                phase: .began,
                previousButtons: 0),
            0b001)
        XCTAssertEqual(
            IndirectPointerClickPolicy.buttons(
                for: UIEvent.ButtonMask(),
                phase: .moved,
                previousButtons: 0b001),
            0b001)
        XCTAssertEqual(
            IndirectPointerClickPolicy.buttons(
                for: .primary,
                phase: .ended,
                previousButtons: 0b001),
            0)
    }

    func test_touchCursorCenter_canReachInteractiveEdges() {
        let layer = TouchCursorLayer()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

        layer.show(at: CGPoint(x: 0, y: 0), within: rect)
        XCTAssertEqual(layer.cursorCenter.x, 0, accuracy: 0.001)
        XCTAssertEqual(layer.cursorCenter.y, 0, accuracy: 0.001)

        layer.show(at: CGPoint(x: 100, y: 50), within: rect)
        XCTAssertEqual(layer.cursorCenter.x, 100, accuracy: 0.001)
        XCTAssertEqual(layer.cursorCenter.y, 50, accuracy: 0.001)
    }

    func test_touchCursorMovement_clampsHotspotToEdge() {
        let layer = TouchCursorLayer()
        let rect = CGRect(x: 10, y: 20, width: 200, height: 120)

        layer.show(at: CGPoint(x: 110, y: 80), within: rect)
        layer.move(by: CGPoint(x: 500, y: 500), within: rect)

        XCTAssertEqual(layer.cursorCenter.x, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(layer.cursorCenter.y, rect.maxY, accuracy: 0.001)
    }

    func test_remoteZoomPolicy_clampsScaleAndUsesFriendlySteps() {
        XCTAssertEqual(RemoteZoomPolicy.clampedScale(0.5), 1)
        XCTAssertEqual(RemoteZoomPolicy.clampedScale(5), 4)
        XCTAssertEqual(RemoteZoomPolicy.nextScale(after: 1), 1.5)
        XCTAssertEqual(RemoteZoomPolicy.previousScale(before: 3), 2)
    }

    func test_remoteZoomPolicy_clampsPanToVisibleContent() {
        let viewport = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            RemoteZoomPolicy.clampedOffset(
                CGPoint(x: 500, y: -500),
                scale: 2,
                viewport: viewport),
            CGPoint(x: 100, y: -50))
        XCTAssertEqual(
            RemoteZoomPolicy.clampedOffset(
                CGPoint(x: 50, y: 50),
                scale: 1,
                viewport: viewport),
            .zero)
    }

    func test_metalRendererSizing_capsRetinaFrameForTripleScaleViewer() {
        let frameSize = CGSize(width: 3_456, height: 2_234)

        let safe = MetalVideoRenderSizing.rendererFrameSize(
            frameSize,
            displayScale: 3,
            maximumTextureDimension: 8_192)

        XCTAssertEqual(safe.width, 2_730)
        XCTAssertEqual(safe.height, 1_764)
        XCTAssertLessThanOrEqual(safe.width * 3, 8_192)
        XCTAssertLessThanOrEqual(safe.height * 3, 8_192)
        XCTAssertEqual(
            safe.width / safe.height,
            frameSize.width / frameSize.height,
            accuracy: 0.001)
    }

    func test_metalRendererSizing_keepsCompliantFramesAndHandlesPortrait() {
        XCTAssertEqual(
            MetalVideoRenderSizing.rendererFrameSize(
                CGSize(width: 1_920, height: 1_080),
                displayScale: 3,
                maximumTextureDimension: 8_192),
            CGSize(width: 1_920, height: 1_080))

        let portrait = MetalVideoRenderSizing.rendererFrameSize(
            CGSize(width: 2_160, height: 3_840),
            displayScale: 3,
            maximumTextureDimension: 8_192)
        XCTAssertEqual(portrait, CGSize(width: 1_535, height: 2_730))
        XCTAssertLessThanOrEqual(portrait.height * 3, 8_192)
    }

    func test_remoteTouchRoutingPolicy_separatesMoveScreenFromComputerControl() {
        XCTAssertTrue(RemoteTouchRoutingPolicy.routesTouchesToComputer(
            moveScreenEnabled: false))
        XCTAssertFalse(RemoteTouchRoutingPolicy.allowsViewportZoom(
            moveScreenEnabled: false))
        XCTAssertFalse(RemoteTouchRoutingPolicy.movesViewport(
            moveScreenEnabled: false,
            scale: 2))

        XCTAssertFalse(RemoteTouchRoutingPolicy.routesTouchesToComputer(
            moveScreenEnabled: true))
        XCTAssertTrue(RemoteTouchRoutingPolicy.allowsViewportZoom(
            moveScreenEnabled: true))
        XCTAssertFalse(RemoteTouchRoutingPolicy.movesViewport(
            moveScreenEnabled: true,
            scale: 1))
        XCTAssertTrue(RemoteTouchRoutingPolicy.movesViewport(
            moveScreenEnabled: true,
            scale: 2))
    }

    @MainActor
    func test_remoteScreenReadinessDisablesRemoteGesturesAndKeepsViewportControlsLocal() {
        let transport = ScreenInputTestTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeReady()
        let screen = RemoteScreenUIView(), zoom = RemoteScreenZoomController()
        screen.bindSession(session); screen.bindZoomController(zoom)
        XCTAssertTrue(screen.interactionState.remoteIndirectInputEnabled)
        let generation = session.remoteInputGeneration
        transport.onInputUnavailable?()
        let count = transport.sentCount
        screen.bindSession(session)
        XCTAssertFalse(screen.interactionState.remoteScrollEnabled)
        XCTAssertFalse(screen.interactionState.remoteLongPressEnabled)
        XCTAssertFalse(screen.interactionState.remoteIndirectInputEnabled)
        zoom.moveScreenEnabled = true
        XCTAssertTrue(screen.interactionState.viewportPinchEnabled)
        XCTAssertTrue(screen.interactionState.viewportPanEnabled)
        XCTAssertEqual(transport.sentCount, count, "Resetting remote recognizers cannot send cleanup into recovery")
        transport.makeReady()
        screen.bindSession(session)
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        XCTAssertFalse(screen.interactionState.remoteIndirectInputEnabled, "Viewport mode stays local after recovery")
        zoom.moveScreenEnabled = false
        XCTAssertTrue(screen.interactionState.remoteScrollEnabled)
        XCTAssertTrue(screen.interactionState.remoteLongPressEnabled)
        XCTAssertTrue(screen.interactionState.remoteIndirectInputEnabled)
    }

    @MainActor
    func test_screenReplacementAndDismantlePreserveSuccessorControls() {
        let transport = ScreenInputTestTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeReady()
        let zoom = RemoteScreenZoomController()
        let old = RemoteScreenUIView(), next = RemoteScreenUIView()
        old.bindSession(session); old.bindZoomController(zoom)
        next.bindSession(session); next.bindZoomController(zoom)
        old.bindSession(session)
        XCTAssertFalse(old.interactionState.remoteIndirectInputEnabled)
        XCTAssertTrue(next.interactionState.remoteIndirectInputEnabled)
        transport.onInputUnavailable?(); transport.makeReady()
        next.bindSession(session)
        let count = transport.sentCount
        XCTAssertFalse(old.gestureRecognizerShouldBegin(UIGestureRecognizer()), "A late event cannot acquire the recovered source")
        XCTAssertTrue(next.gestureRecognizerShouldBegin(UIGestureRecognizer()))
        XCTAssertEqual(transport.sentCount, count)
        old.stopCapture()
        old.bindSession(session); old.bindZoomController(zoom)
        XCTAssertFalse(old.interactionState.remoteIndirectInputEnabled)
        zoom.moveScreenEnabled = true
        XCTAssertTrue(next.interactionState.viewportPanEnabled)
        XCTAssertFalse(next.interactionState.remoteIndirectInputEnabled)
        zoom.moveScreenEnabled = false
        XCTAssertTrue(next.interactionState.remoteIndirectInputEnabled)
        next.stopCapture()
        XCTAssertFalse(next.interactionState.remoteIndirectInputEnabled)
    }

    @MainActor
    func test_moveScreenToggle_reconfiguresActualGestureRecognizers() {
        let transport = ScreenInputTestTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeReady()
        let controller = RemoteScreenZoomController()
        let screen = RemoteScreenUIView()
        screen.bindSession(session)
        screen.bindZoomController(controller)

        XCTAssertEqual(screen.interactionState, RemoteScreenInteractionState(
            remoteScrollEnabled: true,
            remoteLongPressEnabled: true,
            remoteIndirectInputEnabled: true,
            viewportPinchEnabled: false,
            viewportPanEnabled: false))

        controller.moveScreenEnabled = true
        XCTAssertEqual(screen.interactionState, RemoteScreenInteractionState(
            remoteScrollEnabled: false,
            remoteLongPressEnabled: false,
            remoteIndirectInputEnabled: false,
            viewportPinchEnabled: true,
            viewportPanEnabled: true))

        controller.moveScreenEnabled = false
        XCTAssertEqual(screen.interactionState, RemoteScreenInteractionState(
            remoteScrollEnabled: true,
            remoteLongPressEnabled: true,
            remoteIndirectInputEnabled: true,
            viewportPinchEnabled: false,
            viewportPanEnabled: false))
    }
}

@MainActor
private final class ScreenInputTestTransport: Transport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onInputUnavailable: (@MainActor () -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?
    private(set) var sentCount = 0
    func connect(pairingCode: String, expectedHostID: String?) async throws {}
    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) { sentCount += 1 }
    func disconnect(reason: String) {}
    func makeReady() {
        onHostHello?(HostHello(app: "Fixture", version: "1", hostname: "Mac", os: "macOS", audio: false, monitors: 1))
        onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1)); onFirstVideoFrame?()
    }
}
