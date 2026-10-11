import Foundation
import AppKit
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseDefaultBrowserExecutorTests: XCTestCase {
    func testOnlyRetainedWindowCoordinatesAndSafeNavigationKeysAreAllowed() {
        let bounds = CGRect(x: 100, y: 50, width: 900, height: 700)
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.click(x: 150, y: 100, button: 1, count: 1), within: bounds))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permits(.click(x: 20, y: 100, button: 1, count: 1), within: bounds))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.drag(fromX: 150, fromY: 100, toX: 200, toY: 150), within: bounds))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permits(.drag(fromX: 150, fromY: 100, toX: 1_100, toY: 150), within: bounds))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.scroll(x: 200, y: 200, dx: 0, dy: 80), within: bounds))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x0F, modifiers: 8), within: bounds)) // Cmd-L
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x28, modifiers: 0), within: bounds)) // Return
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x04, modifiers: 8), within: bounds)) // Cmd-A
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x0F, modifiers: 0), within: bounds)) // plain L
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permits(.key(usage: 0x2B, modifiers: 0), within: bounds)) // Tab within page
        for chord in [(0x16, 8), (0x17, 8), (0x1A, 8), (0x14, 8), (0x35, 8),
                      (0x1E, 8), (0x2B, 2), (0x4E, 2), (0x0F, 2)] { // Cmd-N/T/W/Q/grave/1, Ctrl-Tab/PgDn/L
            XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permits(.key(usage: chord.0, modifiers: UInt16(chord.1)), within: bounds))
        }
    }

    func testObservedGmailControlApprovalBindingMatchesDesktopDispatchCoordinates() throws {
        let display = CGRect(x: -640, y: -200, width: 1280, height: 800)
        let center = CGPoint(x: 100.6, y: 87.6)
        let binding = try ComputerUseDefaultBrowserExecutor.observedControlActionPair(
            center: center, display: display)
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 800)),
            displayBounds: display))
        let dispatched = try XCTUnwrap(ComputerUseDesktopExecutor.nativeAction(binding.proposalAction, image: image))
        XCTAssertEqual(binding.predictedAction, dispatched,
            "The observed Send proposal's approval binding must match DesktopExecutor's exact display conversion")
    }

    func testSharedDisplayPointRejectsInvalidDisplayGeometry() {
        let invalidBounds = [
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0.5, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 100.5, height: 100),
            CGRect(x: 0, y: 0, width: 1_000_001, height: 100),
        ]

        for bounds in invalidBounds {
            XCTAssertThrowsError(try ComputerUseDesktopImage.displayPoint(
                normalizedX: 500, normalizedY: 500, displayBounds: bounds))
        }
    }

    func testDriveUploadShortcutUsesOnlyBoundCommandsAndDoesNotReplayPartialSequence() throws {
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode,
            bundleIdentifier: "com.apple.Safari", canonicalBundlePath: "/Applications/Safari.app",
            canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test requirement", teamIdentifier: nil, platformIdentifier: nil)
        let application = try XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari",
            processIdentifier: 42, launchGeneration: 1, codeIdentity: code))

        for failOnSecond in [false, true] {
            var actions: [ComputerUsePredictedAction] = []
            var events: [String] = []
            let allowed = true
            let injector = InputInjector(eventPoster: { _ in XCTFail("Virtual host commands must not post native events") })
            let tools = ComputerUseHostTools(injector: injector, mayAct: { allowed }, actionPerformer: { action in
                events.append("effect")
                actions.append(action)
                if failOnSecond && actions.count == 2 { throw ShortcutFailure.injected }
            }, frontmostApplicationIdentityProvider: { application })
            var attempted = false
            var validations = 0
            var begins = 0
            var phases: [String] = []
            let sequence = {
                try ComputerUseDefaultBrowserExecutor.performDriveUploadKeyboardSequence(tools: tools,
                    expectedApplication: application,
                    isAttempted: { attempted },
                    validateContext: { validations += 1; events.append("validate") },
                    phaseObserver: { phases.append($0) },
                    beginAttempt: {
                        guard !attempted else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
                        attempted = true
                        begins += 1
                        events.append("latch")
                    })
            }

            if failOnSecond {
                XCTAssertThrowsError(try sequence())
                XCTAssertTrue(attempted, "The first key latches the macro before any partial/uncertain result")
                XCTAssertThrowsError(try sequence(), "Resume must not replay either shortcut key")
            } else {
                try sequence()
                XCTAssertTrue(attempted)
            }
            XCTAssertEqual(actions.count, 2)
            XCTAssertEqual(validations, 2, "The retained context is rechecked immediately before each key")
            XCTAssertEqual(begins, 1)
            XCTAssertEqual(phases, failOnSecond
                ? ["before_first_key", "first_key_validating", "first_key_returned", "before_second_key", "second_key_validating"]
                : ["before_first_key", "first_key_validating", "first_key_returned", "before_second_key", "second_key_validating", "second_key_returned"])
            XCTAssertEqual(events, ["validate", "latch", "effect", "validate", "effect"],
                "The clean-context check and one-shot latch precede the first shortcut command")
            guard case .key(let firstUsage, let firstModifiers) = actions[0],
                  case .key(let secondUsage, let secondModifiers) = actions[1] else {
                return XCTFail("The fallback must contain only its two fixed keyboard commands")
            }
            XCTAssertEqual(firstUsage, 0x06) // Control-C opens Drive's New menu
            XCTAssertEqual(firstModifiers, 1 << 1)
            XCTAssertEqual(secondUsage, 0x18) // U chooses File upload
            XCTAssertEqual(secondModifiers, 0)
        }
    }

    func testWebUploadRequiresCleanCompleteBaselineBeforeFreshCompletion() {
        XCTAssertTrue(ComputerUseDefaultBrowserExecutor.webUploadProgressBaselineIsClean(
            controlsComplete: true, progressValues: []))
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.webUploadProgress(["Upload complete"]), .complete)
        XCTAssertFalse(ComputerUseDefaultBrowserExecutor.webUploadProgressBaselineIsClean(
            controlsComplete: true, progressValues: ["Upload complete"]))
        XCTAssertFalse(ComputerUseDefaultBrowserExecutor.webUploadProgressBaselineIsClean(
            controlsComplete: true, progressValues: ["Uploading 72%"]))
        XCTAssertFalse(ComputerUseDefaultBrowserExecutor.webUploadProgressBaselineIsClean(
            controlsComplete: true, progressValues: ["Upload failed"]))
        XCTAssertFalse(ComputerUseDefaultBrowserExecutor.webUploadProgressBaselineIsClean(
            controlsComplete: false, progressValues: []))
    }

    func testWebUploadCountedCompletionLabelsAreExactAndBaselineIsNotClean() {
        for label in ["1 upload complete", "2 uploads complete"] {
            XCTAssertEqual(ComputerUseDefaultBrowserExecutor.webUploadProgress([label]), .complete, label)
            XCTAssertFalse(ComputerUseDefaultBrowserExecutor.webUploadProgressBaselineIsClean(
                controlsComplete: true, progressValues: [label]), label)
        }

        for label in ["0 uploads complete", "-1 uploads complete", "01 uploads complete",
                      "one upload complete", "2 upload complete", "1000000 uploads complete",
                      "٢ uploads complete", "The provider says 2 uploads complete now"] {
            XCTAssertEqual(ComputerUseDefaultBrowserExecutor.webUploadProgress([label]), .unknown, label)
        }
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.webUploadProgress(
            ["2 uploads complete", "Uploading 12%"]), .inProgress,
            "Pending upload evidence takes precedence over a completion counter")
        XCTAssertEqual(ComputerUseDefaultBrowserExecutor.webUploadProgress(
            ["2 uploads complete", "Upload failed"]), .failed,
            "Failure evidence takes precedence over a completion counter")
    }

    private enum ShortcutFailure: Error { case injected }

}
