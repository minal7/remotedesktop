import XCTest
import SwiftUI
import UIKit
@testable import RemoteDesktop

final class RemoteScreenInteractionTests: XCTestCase {
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
    func test_moveScreenToggle_reconfiguresActualGestureRecognizers() {
        let controller = RemoteScreenZoomController()
        let screen = RemoteScreenUIView()
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
