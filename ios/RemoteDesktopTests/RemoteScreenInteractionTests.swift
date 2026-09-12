import XCTest
import SwiftUI
import UIKit
@testable import RemoteDesktop

final class RemoteScreenInteractionTests: XCTestCase {
    private var routingGeometry: RemoteScreenGeometry {
        RemoteScreenGeometry(bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            display: DisplayInfo(w: 100, h: 50, scale: 2, fullDisplaySurface: true))
    }

    func test_pointerRoutingRejectsMarginPressesAndUnownedMovementButtons() {
        let geometry = routingGeometry, viewport = geometry.bounds
        var routing = RemoteScreenInputRouting()
        for point in [CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 180), CGPoint(x: 200, y: 100)] {
            XCTAssertNil(routing.pointer(at: point, buttons: 1, geometry: geometry, viewport: viewport))
            XCTAssertEqual(routing.pointerButtons, 0)
        }
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 100, y: 100), buttons: 1, allowsNewButtons: false,
            geometry: geometry, viewport: viewport), .pointer(x: 50, y: 25, buttons: 0),
            "A moved event cannot create the press that began in a margin")
        XCTAssertNil(routing.pointer(at: CGPoint(x: 100, y: 20), buttons: 0, geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 100, y: 100), buttons: 1,
            geometry: geometry, viewport: viewport), .pointer(x: 50, y: 25, buttons: 1))
        XCTAssertNil(routing.pointer(at: CGPoint(x: 100, y: 100), buttons: 1,
            geometry: geometry, viewport: viewport), "Duplicate admitted events remain coalesced")
    }

    func test_pointerRoutingClampsHeldMotionAndReleasesAtLastVisiblePoint() {
        let geometry = routingGeometry, viewport = CGRect(x: 40, y: 70, width: 100, height: 60)
        var routing = RemoteScreenInputRouting()
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 100, y: 100), buttons: 3,
            geometry: geometry, viewport: viewport), .pointer(x: 50, y: 25, buttons: 3))
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 180, y: 150), buttons: 7,
            geometry: geometry, viewport: viewport), .pointer(x: 69, y: 39, buttons: 3),
            "Clamp an existing drag to visible cells without adding an outside button")
        XCTAssertEqual(routing.pointer(at: nil, buttons: 1, geometry: geometry, viewport: viewport),
                       .pointer(x: 69, y: 39, buttons: 1))
        let unavailable = RemoteScreenGeometry(bounds: .zero, display: nil)
        XCTAssertEqual(routing.pointer(at: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), buttons: 0,
            geometry: unavailable, viewport: .zero), .pointer(x: 69, y: 39, buttons: 0),
            "Missing geometry cannot prevent release of this routing state's existing hold")
        XCTAssertNil(routing.pointer(at: nil, buttons: 0, geometry: unavailable, viewport: .zero))
    }

    func test_pointerRoutingResetDropsOldHoldsAndRequiresANewPress() {
        let geometry = routingGeometry, viewport = geometry.bounds
        var routing = RemoteScreenInputRouting()
        _ = routing.pointer(at: CGPoint(x: 100, y: 100), buttons: 1, geometry: geometry, viewport: viewport)
        // Production discards this value when its view input-source lease is
        // retired; SessionModel owns the old lease's actual transport cleanup.
        routing = RemoteScreenInputRouting()
        XCTAssertNil(routing.pointer(at: nil, buttons: 0, geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 120, y: 110), buttons: 1, allowsNewButtons: false,
            geometry: geometry, viewport: viewport), .pointer(x: 60, y: 30, buttons: 0))
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 120, y: 110), buttons: 2,
            geometry: geometry, viewport: viewport), .pointer(x: 60, y: 30, buttons: 2))
        XCTAssertNil(routing.pointer(at: CGPoint(x: 120, y: 110), buttons: 8,
            geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.pointerButtons, 2)
    }

    func test_scrollRoutingRequiresInsideBeginAndTheOwningGesture() {
        let geometry = routingGeometry, viewport = geometry.bounds
        var routing = RemoteScreenInputRouting()
        XCTAssertNil(routing.scroll(at: CGPoint(x: 100, y: 20), dx: 0, dy: 10, phase: .begin,
            source: .indirect, geometry: geometry, viewport: viewport))
        XCTAssertNil(routing.scroll(at: CGPoint(x: 100, y: 100), dx: 0, dy: 10, phase: .changed,
            source: .indirect, geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.scroll(at: CGPoint(x: 100, y: 100), dx: 0, dy: 10, phase: .begin,
            source: .touch, geometry: geometry, viewport: viewport), .scroll(x: 50, y: 25, dx: 0, dy: 10, phase: .begin))
        XCTAssertNil(routing.scroll(at: CGPoint(x: 100, y: 100), dx: 0, dy: 20, phase: .begin,
            source: .indirect, geometry: geometry, viewport: viewport))
        XCTAssertNil(routing.scroll(at: nil, dx: 0, dy: 0, phase: .end,
            source: .indirect, geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.scroll(at: nil, dx: .nan, dy: .infinity, phase: .end,
            source: .touch, geometry: geometry, viewport: viewport), .scroll(x: 50, y: 25, dx: 0, dy: 0, phase: .end))
        XCTAssertNil(routing.endScroll())
        XCTAssertEqual(routing.scroll(at: CGPoint(x: 120, y: 110), dx: 0, dy: 5, phase: .begin,
            source: .indirect, geometry: geometry, viewport: viewport), .scroll(x: 60, y: 30, dx: 0, dy: 5, phase: .begin))
        XCTAssertNil(routing.scroll(at: nil, dx: 0, dy: 0, phase: .end,
            source: .touch, geometry: geometry, viewport: viewport), "Old finger cleanup cannot end the indirect successor")
        XCTAssertEqual(routing.endScroll(), .scroll(x: 60, y: 30, dx: 0, dy: 0, phase: .end))
    }

    func test_scrollRoutingEndsOnceOnBoundaryLossOrInvalidDelta() {
        let geometry = routingGeometry, viewport = geometry.bounds
        for (point, dy) in [(CGPoint(x: 100, y: 20), CGFloat(1)),
                            (CGPoint(x: 100, y: 100), CGFloat.nan),
                            (CGPoint(x: 100, y: 100), CGFloat(Int64(Int32.max) + 1))] {
            var routing = RemoteScreenInputRouting()
            _ = routing.scroll(at: CGPoint(x: 100, y: 100), dx: 0, dy: 0, phase: .begin,
                source: .indirect, geometry: geometry, viewport: viewport)
            XCTAssertEqual(routing.scroll(at: point, dx: 0, dy: dy, phase: .changed,
                source: .indirect, geometry: geometry, viewport: viewport), .scroll(x: 50, y: 25, dx: 0, dy: 0, phase: .end))
            XCTAssertNil(routing.scroll(at: CGPoint(x: 100, y: 100), dx: 0, dy: 10, phase: .changed,
                source: .indirect, geometry: geometry, viewport: viewport), "Reentry needs a new gesture begin")
            XCTAssertNil(routing.endScroll())
        }
    }

    func test_scrollRoutingRequiresObservedLocationAndBoundedDeltas() {
        let geometry = routingGeometry, viewport = geometry.bounds
        var routing = RemoteScreenInputRouting()
        XCTAssertNil(routing.scroll(at: nil, dx: 0, dy: 10, phase: .begin,
            source: .indirect, geometry: geometry, viewport: viewport), "No invented initial pointer at (0, 0)")
        XCTAssertNil(routing.scroll(at: CGPoint(x: 100, y: 100), dx: .infinity, dy: 0, phase: .begin,
            source: .indirect, geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.scroll(at: CGPoint(x: 100, y: 100), dx: -2.4, dy: 3.6, phase: .begin,
            source: .indirect, geometry: geometry, viewport: viewport), .scroll(x: 50, y: 25, dx: -2, dy: 4, phase: .begin))
        XCTAssertNil(routing.scroll(at: CGPoint(x: 100, y: 100), dx: 0.1, dy: 0.1, phase: .changed,
            source: .indirect, geometry: geometry, viewport: viewport))
        XCTAssertEqual(routing.endScroll(), .scroll(x: 50, y: 25, dx: 0, dy: 0, phase: .end),
                       "Mode changes can close either scroll source without new deltas")
    }

    func test_screenGeometryUsesAllLogicalCellsAndRejectsInvalidMappings() throws {
        let geometry = RemoteScreenGeometry(bounds: CGRect(x: 10, y: 20, width: 100, height: 60),
            display: DisplayInfo(w: 5, h: 3, scale: 1))
        for x in 0..<5 {
            for y in 0..<3 {
                let point = CGPoint(x: 10 + (Double(x) + 0.5) * 20, y: 20 + (Double(y) + 0.5) * 20)
                let remote = try XCTUnwrap(geometry.localToRemote(point))
                XCTAssertEqual(remote.x, x); XCTAssertEqual(remote.y, y)
            }
        }
        XCTAssertNil(geometry.localToRemote(CGPoint(x: 110, y: 80)))
        XCTAssertNil(geometry.localToRemote(CGPoint(x: CGFloat.nan, y: 20), clamping: true))
        for display in [nil, DisplayInfo(w: 0, h: 1, scale: 1),
                        DisplayInfo(w: Int(Int32.max) + 1, h: 1, scale: 1),
                        DisplayInfo(w: 5, h: 3, scale: .infinity)] {
            let invalid = RemoteScreenGeometry(bounds: geometry.bounds, display: display)
            XCTAssertNil(invalid.localToRemote(CGPoint(x: 50, y: 50), clamping: true))
        }
        let invalid = RemoteScreenGeometry(bounds: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 60), display: geometry.display)
        XCTAssertNil(invalid.localToRemote(.zero, clamping: true))
    }

    func test_screenGeometryClipsZoomedContentBeforeNewGestures() {
        let geometry = routingGeometry, viewport = CGRect(x: 40, y: 70, width: 100, height: 60)
        XCTAssertEqual(geometry.visibleRect(in: viewport), viewport)
        XCTAssertEqual(geometry.visibleRect(in: CGRect(x: 500, y: 500, width: 10, height: 10)), .zero)
        var routing = RemoteScreenInputRouting()
        XCTAssertNil(routing.pointer(at: CGPoint(x: 20, y: 100), buttons: 1,
            geometry: geometry, viewport: viewport), "The full desktop contains this point, but it is outside the viewport")
        XCTAssertEqual(routing.pointer(at: CGPoint(x: 40, y: 70), buttons: 1,
            geometry: geometry, viewport: viewport), .pointer(x: 20, y: 10, buttons: 1))
    }

    func test_touchCursorStaysInsideVisibleEdgesAndIgnoresInvalidMotion() throws {
        let cursor = TouchCursorLayer(), rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertNil(cursor.positionedCenter)
        cursor.show(at: .zero, within: rect)
        XCTAssertEqual(cursor.positionedCenter, .zero, "A positioned origin is distinct from an unpositioned cursor")
        cursor.move(by: CGPoint(x: 10000, y: 10000), within: rect)
        XCTAssertTrue(RemoteScreenGeometry.contains(try XCTUnwrap(cursor.positionedCenter), in: rect))
        let prior = cursor.positionedCenter
        cursor.move(by: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), within: rect)
        XCTAssertEqual(cursor.positionedCenter, prior)
        let zoomed = CGRect(x: 25, y: 10, width: 50, height: 20)
        cursor.clamp(to: zoomed)
        XCTAssertTrue(RemoteScreenGeometry.contains(try XCTUnwrap(cursor.positionedCenter), in: zoomed))
        cursor.clamp(to: .zero)
        XCTAssertTrue(cursor.isHidden)
    }

    func test_fullDisplaySurfaceSharesItsVideoAndInputRectangleAcrossAspectRatios() throws {
        for viewport in [CGRect(x: 0, y: 0, width: 1024, height: 768),
                         CGRect(x: 10, y: 20, width: 400, height: 900)] {
            for size in [(1920, 1080), (1200, 1920), (1728, 1117)] {
                let display = DisplayInfo(w: size.0, h: size.1, scale: 2, fullDisplaySurface: true)
                let layout = RemoteScreenRenderingLayout(bounds: viewport, display: display)
                let input = RemoteScreenGeometry(bounds: viewport, display: display)
                XCTAssertEqual(layout.contentMode, .scaleToFill)
                XCTAssertEqual(layout.videoRect, input.interactiveRect)
                let first = try XCTUnwrap(input.localToRemote(CGPoint(x: layout.videoRect.minX, y: layout.videoRect.minY)))
                let last = try XCTUnwrap(input.localToRemote(CGPoint(x: layout.videoRect.maxX, y: layout.videoRect.maxY), clamping: true))
                XCTAssertEqual(first.x, 0); XCTAssertEqual(first.y, 0)
                XCTAssertEqual(last.x, size.0 - 1); XCTAssertEqual(last.y, size.1 - 1)
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let legacy = RemoteScreenRenderingLayout(bounds: bounds, display: DisplayInfo(w: 1728, h: 1117, scale: 2))
        XCTAssertEqual(legacy.videoRect, bounds); XCTAssertEqual(legacy.contentMode, .scaleAspectFit)
    }

    func test_fullDisplaySurfaceRestoresLogicalAspectIndependentlyOfDrawableRounding() throws {
        let display = DisplayInfo(w: 1728, h: 1117, scale: 2, fullDisplaySurface: true)
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let layout = RemoteScreenRenderingLayout(bounds: bounds, display: display)
        let drawable = try XCTUnwrap(RemoteVideoDrawableSizing.size(bounds: layout.videoRect.size, scale: 3))
        XCTAssertNotEqual(drawable.width / drawable.height, CGFloat(display.w) / CGFloat(display.h),
                          "Integral drawable rounding is not an exact logical aspect ratio")
        XCTAssertEqual(layout.videoRect.width / layout.videoRect.height,
                       CGFloat(display.w) / CGFloat(display.h), accuracy: 0.000000001)
        XCTAssertEqual(layout.contentMode, .scaleToFill,
                       "Fit the full surface to the logical rectangle, not another aspect-fit inside it")
        let input = RemoteScreenGeometry(bounds: bounds, display: display)
        let center = try XCTUnwrap(input.localToRemote(CGPoint(x: layout.videoRect.midX, y: layout.videoRect.midY)))
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

    func test_localToRemote_clampsLetterboxedPointsToDisplayEdges() throws {
        let geometry = RemoteScreenGeometry(
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            display: DisplayInfo(w: 1920, h: 1080, scale: 2.0))

        let topLeft = try XCTUnwrap(geometry.localToRemote(CGPoint(x: 0, y: 0), clamping: true))
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0)

        let bottomRight = try XCTUnwrap(geometry.localToRemote(CGPoint(x: 1024, y: 768), clamping: true))
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

    func test_metalRendererSizing_capsRetinaFrameForTripleScaleViewer() throws {
        let viewBounds = CGSize(width: 3456, height: 2234)
        let pixels = try XCTUnwrap(RemoteVideoDrawableSizing.size(bounds: viewBounds, scale: 3))
        XCTAssertLessThanOrEqual(pixels.width, 8192)
        XCTAssertLessThanOrEqual(pixels.height, 8192)
        XCTAssertLessThanOrEqual(pixels.width * pixels.height, 16_777_216)
        XCTAssertGreaterThan(pixels.width, viewBounds.width, "The result is physical pixels, not an RTC point-size workaround")
        XCTAssertEqual(pixels.width / pixels.height, viewBounds.width / viewBounds.height, accuracy: 0.001)
    }

    func test_metalRendererSizing_keepsCompliantFramesAndHandlesPortrait() {
        XCTAssertEqual(RemoteVideoDrawableSizing.size(bounds: CGSize(width: 640, height: 360), scale: 3),
                       CGSize(width: 1920, height: 1080))
        XCTAssertEqual(RemoteVideoDrawableSizing.size(bounds: CGSize(width: 720, height: 1280), scale: 3),
                       CGSize(width: 2160, height: 3840))
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
    var onVideoFrameUnavailable: (@MainActor () -> Void)?
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
