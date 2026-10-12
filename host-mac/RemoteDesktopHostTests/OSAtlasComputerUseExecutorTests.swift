import AppKit
import CoreImage
import CoreText
import Darwin
import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseActionContractsTests: XCTestCase {
    func testActionContractsKeepScrollDirectionAndRawTokenBound() {
        let down = OSAtlasSemanticActionRoute(directive: .scroll, scrollDirection: .down)
        let up = OSAtlasSemanticActionRoute(directive: .scroll, scrollDirection: .up)
        XCTAssertTrue(down.matches(.scroll(.down), rawActionLine: "SCROLL [DOWN]"))
        XCTAssertFalse(down.matches(.scroll(.up), rawActionLine: "SCROLL [DOWN]"))
        XCTAssertFalse(down.matches(.scroll(.down), rawActionLine: "SCROLL_UP"))
        XCTAssertNotEqual(down.privacySafeToken, up.privacySafeToken)
        XCTAssertEqual(OSAtlasRawActionVariant.resolve(action: .scroll(.left), rawActionLine: "SCROLL [LEFT]"), .scrollLeft)
        XCTAssertNil(OSAtlasRawActionVariant.resolve(action: .scroll(.left), rawActionLine: "SCROLL_LEFT"))
    }

    func testHistoryEntryEncodesOnlyTheActionContractShape() {
        XCTAssertEqual(OSAtlasGUIAction.scroll(.left).historyEntry, "SCROLL [LEFT]")
        XCTAssertEqual(OSAtlasGUIAction.openApplication("Notes").historyEntry, "OPEN_APP [Notes]")
        XCTAssertEqual(OSAtlasGUIAction.enter.historyEntry, "ENTER")
        XCTAssertEqual(OSAtlasGUIAction.ask("Which folder?").historyEntry, "ASK")
        XCTAssertEqual(OSAtlasGUIAction.report("Ready").historyEntry, "REPORT")
    }

    func testScreenCaptureConsentDetectorRecognizesExactObservedSystemPrompt() {
        let exactObservedPrompt = """
        “RemoteDesktopHost” is requesting to bypass the system private window picker and directly access your screen and audio.
        This will allow RemoteDesktopHost to record your screen and system audio, including personal or sensitive information that may be visible or audible.
        Allow
        Open System Settings
        """
        XCTAssertTrue(
            ComputerUseScreenCaptureConsentDetector
                .requiresUserIntervention(
                    inRecognizedText: exactObservedPrompt))
        XCTAssertTrue(
            ComputerUseScreenCaptureConsentDetector
                .requiresUserIntervention(
                    ComputerUseAuthenticationContextSnapshot(
                        focusedElement: "AXButton • Allow",
                        boundedWindowContext: exactObservedPrompt)))

        let nearbyButInsufficientText = [
            "RemoteDesktopHost can record your screen. Allow Open System Settings",
            "Bypass the system private window picker and directly access your screen and audio. Allow Open System Settings",
            "RemoteDesktopHost requests screen and audio access. Allow Open System Settings",
            "DoorDash Sign in Continue with Apple Open System Settings",
        ]
        for text in nearbyButInsufficientText {
            XCTAssertFalse(
                ComputerUseScreenCaptureConsentDetector
                    .requiresUserIntervention(inRecognizedText: text),
                text)
        }
    }

    func testAuthenticationBarrierRequiresFocusedCredentialOrMultipleSignals() {
        let directFocusedCredentials = [
            "AXTextField • AXSecureTextField",
            "AXTextField • Password",
            "AXTextField • Passcode",
            "AXTextField • Verification Code",
            "AXTextField • One-time password (OTP)",
        ]
        for focusedElement in directFocusedCredentials {
            XCTAssertTrue(
                ComputerUseAuthenticationBarrierDetector
                    .requiresUserIntervention(
                        ComputerUseAuthenticationContextSnapshot(
                            focusedElement: focusedElement,
                            boundedWindowContext: "")),
                focusedElement)
        }

        XCTAssertTrue(
            ComputerUseAuthenticationBarrierDetector
                .requiresUserIntervention(
                    ComputerUseAuthenticationContextSnapshot(
                        focusedElement: "AXWebArea • Account",
                        boundedWindowContext: """
                        AXHeading • Sign In
                        AXButton • Continue with Google
                        AXButton • Continue with Apple
                        """)),
            "A bounded sign-in sheet with two independent providers must pause")
        XCTAssertTrue(
            ComputerUseAuthenticationBarrierDetector
                .requiresUserIntervention(
                    ComputerUseAuthenticationContextSnapshot(
                        focusedElement: "AXTextField • Email Address",
                        boundedWindowContext: "AXHeading • Log In\nAXTextField • Password")),
            "A real login form with independent email and password signals must pause")
        XCTAssertTrue(
            ComputerUseAuthenticationBarrierDetector
                .requiresUserIntervention(
                    ComputerUseAuthenticationContextSnapshot(
                        focusedElement: "AXWebArea • Account",
                        boundedWindowContext: "AXHeading • Sign In\nAXTextField • Email\nAXSecureTextField • Password")),
            "A common login form using the standalone Email label must pause")
        XCTAssertTrue(
            ComputerUseAuthenticationBarrierDetector
                .requiresUserIntervention(
                    ComputerUseAuthenticationContextSnapshot(
                        focusedElement: "role=AXTextField • description=Email",
                        boundedWindowContext: """
                        role=AXStaticText • DoorDash
                        role=AXStaticText • Sign in to access your credits and discounts
                        role=AXStaticText • Login with email
                        role=AXRadioButton • Sign In
                        role=AXButton • Continue with Google
                        role=AXButton • Continue with Facebook
                        role=AXButton • Continue with Apple
                        role=AXTextField • Email
                        role=AXSecureTextField • Password
                        role=AXButton • Continue to Sign In
                        """)),
            "The shipped DoorDash identity page AX tree must pause even when Email, rather than Password, is focused")

        let accountChoosers = [
            ComputerUseAuthenticationContextSnapshot(focusedElement: "AXWebArea", boundedWindowContext: "AXHeading • Choose an account\nAXLink • alex@example.test • Signed out"),
            ComputerUseAuthenticationContextSnapshot(focusedElement: "AXWebArea", boundedWindowContext: "AXDialog • Pick an account\nAXButton • Use another account"),
            ComputerUseAuthenticationContextSnapshot(focusedElement: "AXWebArea", boundedWindowContext: "AXWindow • Select an account\nAXLink • Signed out"),
        ]
        for snapshot in accountChoosers {
            XCTAssertTrue(ComputerUseAuthenticationBarrierDetector.requiresUserIntervention(snapshot), "A structural account chooser must hand off before an account choice or passkey step")
        }

        let negatives = [
            ComputerUseAuthenticationContextSnapshot(focusedElement: "AXWebArea", boundedWindowContext: "AXStaticText • Choose an account\nAXButton • Continue reading"),
            ComputerUseAuthenticationContextSnapshot(focusedElement: "AXWebArea", boundedWindowContext: "AXHeading • Choose an account\nAXStaticText • Signed out"),
            ComputerUseAuthenticationContextSnapshot(focusedElement: "AXWebArea", boundedWindowContext: "AXStaticText • Choose an account in settings\nAXButton • Use another account"),
            ComputerUseAuthenticationContextSnapshot(
                focusedElement: "AXButton • Sign In",
                boundedWindowContext: "AXHeading • Welcome"),
            ComputerUseAuthenticationContextSnapshot(
                focusedElement: "AXWebArea",
                boundedWindowContext: "AXHeading • Sign In\nAXButton • Continue with Apple"),
            ComputerUseAuthenticationContextSnapshot(
                focusedElement: "AXStaticText • Password settings",
                boundedWindowContext: "Security article: how to change your password"),
            ComputerUseAuthenticationContextSnapshot(
                focusedElement: "AXWebArea • Help Center",
                boundedWindowContext: "AXStaticText • How to log in: enter your email address and password"),
            ComputerUseAuthenticationContextSnapshot(
                focusedElement: "AXTextField • Email Address",
                boundedWindowContext: "Newsletter preferences"),
            ComputerUseAuthenticationContextSnapshot(
                focusedElement: "AXWebArea • Help Center",
                boundedWindowContext: "AXHeading • Sign In\nAXStaticText • Email\nAXStaticText • Password"),
        ]
        for snapshot in negatives {
            XCTAssertFalse(
                ComputerUseAuthenticationBarrierDetector
                    .requiresUserIntervention(snapshot),
                "Lone or prose-only authentication words must not pause")
        }
    }

    func testAccessibilityCorrectionSnapsOnlyOneNearbyEnabledActionableElement() {
        let predicted = CGPoint(x: 100, y: 100)
        let container = OSAtlasAccessibilityClickCandidate(
            identity: "window",
            frame: CGRect(x: 0, y: 0, width: 500, height: 500),
            isEnabled: true,
            isActionable: false)
        let button = OSAtlasAccessibilityClickCandidate(
            identity: "button",
            frame: CGRect(x: 90, y: 112, width: 40, height: 20),
            isEnabled: true,
            isActionable: true)

        XCTAssertEqual(
            OSAtlasAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                directHit: container,
                nearbyCandidates: [button, button]),
            CGPoint(x: 110, y: 122))
    }

    func testAccessibilityCorrectionNeverGuessesAcrossAmbiguousOrDisabledTargets() {
        let predicted = CGPoint(x: 100, y: 100)
        let container = OSAtlasAccessibilityClickCandidate(
            identity: "group",
            frame: CGRect(x: 0, y: 0, width: 500, height: 500),
            isEnabled: true,
            isActionable: false)
        let first = OSAtlasAccessibilityClickCandidate(
            identity: "first",
            frame: CGRect(x: 90, y: 112, width: 40, height: 20),
            isEnabled: true,
            isActionable: true)
        let second = OSAtlasAccessibilityClickCandidate(
            identity: "second",
            frame: CGRect(x: 70, y: 85, width: 20, height: 20),
            isEnabled: true,
            isActionable: true)
        let disabled = OSAtlasAccessibilityClickCandidate(
            identity: "disabled",
            frame: CGRect(x: 95, y: 110, width: 30, height: 20),
            isEnabled: false,
            isActionable: true)
        let farAway = OSAtlasAccessibilityClickCandidate(
            identity: "far-away",
            frame: CGRect(x: 200, y: 200, width: 30, height: 20),
            isEnabled: true,
            isActionable: true)

        XCTAssertEqual(
            OSAtlasAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                directHit: container,
                nearbyCandidates: [first, second]),
            predicted)
        XCTAssertEqual(
            OSAtlasAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                directHit: container,
                nearbyCandidates: [disabled]),
            predicted)
        XCTAssertEqual(
            OSAtlasAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                directHit: container,
                nearbyCandidates: [farAway]),
            predicted)
        XCTAssertEqual(
            OSAtlasAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                directHit: nil,
                nearbyCandidates: [first]),
            predicted)
    }

    func testAccessibilityCorrectionKeepsPointAlreadyInsideActionableElement() {
        let predicted = CGPoint(x: 100, y: 100)
        let direct = OSAtlasAccessibilityClickCandidate(
            identity: "direct-button",
            frame: CGRect(x: 80, y: 80, width: 50, height: 40),
            isEnabled: true,
            isActionable: true)
        let other = OSAtlasAccessibilityClickCandidate(
            identity: "other-button",
            frame: CGRect(x: 120, y: 110, width: 30, height: 20),
            isEnabled: true,
            isActionable: true)

        XCTAssertEqual(
            OSAtlasAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                directHit: direct,
                nearbyCandidates: [other]),
            predicted)
    }

    func testSemanticAccessibilityCorrectionSnapsOnePurposeMatchedControl() {
        let predicted = CGPoint(x: 720, y: 450)
        let expected = CGPoint(x: 164, y: 252)
        let scope = OSAtlasSemanticAccessibilityClickScope(
            frame: CGRect(x: 80, y: 100, width: 1_160, height: 720),
            candidates: [
                OSAtlasSemanticAccessibilityClickCandidate(
                    identity: "purpose-link",
                    frame: CGRect(x: 132, y: 220, width: 64, height: 64),
                    isEnabled: true,
                    isActionable: true,
                    label: "Open travel details in a new tab"),
                OSAtlasSemanticAccessibilityClickCandidate(
                    identity: "unrelated-control",
                    frame: CGRect(x: 680, y: 420, width: 100, height: 50),
                    isEnabled: true,
                    isActionable: true,
                    label: "Search directory"),
            ])

        XCTAssertEqual(
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                targetHint:
                    "the square-with-arrow icon that opens travel details",
                scope: scope),
            expected)
    }

    func testSemanticAccessibilityCorrectionRejectsAmbiguousMissingAndInvalidControls() {
        let predicted = CGPoint(x: 300, y: 300)
        let frame = CGRect(x: 220, y: 220, width: 80, height: 40)
        func candidate(
            _ identity: String,
            label: String = "Rates",
            enabled: Bool = true,
            actionable: Bool = true,
            frame candidateFrame: CGRect? = nil
        ) -> OSAtlasSemanticAccessibilityClickCandidate {
            OSAtlasSemanticAccessibilityClickCandidate(
                identity: identity,
                frame: candidateFrame ?? frame,
                isEnabled: enabled,
                isActionable: actionable,
                label: label)
        }
        let scopeFrame = CGRect(x: 100, y: 100, width: 600, height: 500)

        XCTAssertNil(
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                targetHint: "Rates tab",
                scope: .init(
                    frame: scopeFrame,
                    candidates: [candidate("first"), candidate("second")])))
        XCTAssertNil(
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                targetHint: "Rates tab",
                scope: .init(
                    frame: scopeFrame,
                    candidates: [candidate(
                        "other",
                        label: "Overview")])))
        XCTAssertNil(
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: predicted,
                targetHint: "Rates tab",
                scope: .init(
                    frame: scopeFrame,
                    candidates: [
                        candidate("disabled", enabled: false),
                        candidate("container", actionable: false),
                        candidate(
                            "zero-frame",
                            frame: CGRect(x: 240, y: 240, width: 0, height: 40)),
                    ])))
    }

    func testSemanticAccessibilityCorrectionRequiresRawAndTargetInsideFocusedScope() {
        let unique = OSAtlasSemanticAccessibilityClickCandidate(
            identity: "unique-rate",
            frame: CGRect(x: 240, y: 240, width: 80, height: 40),
            isEnabled: true,
            isActionable: true,
            label: "Rates")
        let scopeFrame = CGRect(x: 100, y: 100, width: 500, height: 400)

        XCTAssertNil(
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: CGPoint(x: 50, y: 50),
                targetHint: "Rates tab",
                scope: .init(
                    frame: scopeFrame,
                    candidates: [unique])))
        XCTAssertNil(
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: CGPoint(x: 300, y: 300),
                targetHint: "Rates tab",
                scope: .init(
                    frame: scopeFrame,
                    candidates: [OSAtlasSemanticAccessibilityClickCandidate(
                        identity: "outside-scope",
                        frame: CGRect(x: 650, y: 240, width: 80, height: 40),
                        isEnabled: true,
                        isActionable: true,
                        label: "Rates")])))
    }
}

private enum ModelAccessTestFailure: Error { case queueDeadline, completionDeadline }

private func waitForModelAccessQueue(_ expected: Int,
                                     count: () async -> Int) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await count() != expected {
        guard ContinuousClock.now < deadline else { throw ModelAccessTestFailure.queueDeadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func waitForModelAccessExpectations(_ expectations: [XCTestExpectation]) async throws {
    guard await XCTWaiter().fulfillment(of: expectations, timeout: 2) == .completed else {
        throw ModelAccessTestFailure.completionDeadline
    }
}

final class OSAtlasModelAccessGateTests: XCTestCase {
    func testCancellationBeforeAdmissionDoesNotOccupyTheModel() async throws {
        let gate = OSAtlasModelAccessGate()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.acquire()
        }
        do {
            let unexpected = try await cancelled.value
            gate.release(unexpected)
            XCTFail("A pre-cancelled request acquired model access")
        } catch is CancellationError {}
        let next = try await gate.acquire()
        gate.release(next)
        XCTAssertEqual(gate.queuedRequestCount, 0)
    }

    func testQueuedCancellationFinishesWhileTheOwnerStillHoldsAccess() async throws {
        let gate = OSAtlasModelAccessGate()
        let owner = try await gate.acquire()
        let finished = expectation(description: "Cancelled waiter finishes before owner release")
        let queued = Task {
            defer { finished.fulfill() }
            return try await gate.acquire()
        }
        do {
            try await waitForModelAccessQueue(1) { gate.queuedRequestCount }
            queued.cancel()
            try await waitForModelAccessExpectations([finished])
            XCTAssertEqual(gate.queuedRequestCount, 0)
        } catch {
            queued.cancel()
            gate.release(owner)
            if let acquired = try? await queued.value { gate.release(acquired) }
            throw error
        }
        // Cleanup follows the deadline, so a regression reports a failure
        // without keeping a test task suspended behind the original owner.
        gate.release(owner)
        do {
            let unexpected = try await queued.value
            gate.release(unexpected)
            XCTFail("Cancelled waiter returned a lease")
        } catch is CancellationError {}
        let next = try await gate.acquire()
        gate.release(next)
    }

    func testFIFOReservationAndStaleReleaseCannotGiveTwoCallersAccess() async throws {
        let gate = OSAtlasModelAccessGate()
        let owner = try await gate.acquire()
        let firstFinished = expectation(description: "First waiter receives the reservation")
        let first = Task {
            defer { firstFinished.fulfill() }
            return try await gate.acquire()
        }
        var second: Task<UUID, Error>?
        var firstLease: UUID?
        do {
            try await waitForModelAccessQueue(1) { gate.queuedRequestCount }
            let secondFinished = expectation(description: "Second waiter receives the next reservation")
            let secondRequest = Task {
                defer { secondFinished.fulfill() }
                return try await gate.acquire()
            }
            second = secondRequest
            try await waitForModelAccessQueue(2) { gate.queuedRequestCount }
            gate.release(owner)
            try await waitForModelAccessExpectations([firstFinished])
            firstLease = try await first.value
            XCTAssertEqual(gate.queuedRequestCount, 1)
            gate.release(owner)
            gate.release(UUID())
            XCTAssertEqual(gate.queuedRequestCount, 1, "Stale or unrelated release must preserve the new owner")
            gate.release(try XCTUnwrap(firstLease))
            try await waitForModelAccessExpectations([secondFinished])
            let secondLease = try await secondRequest.value
            XCTAssertNotEqual(try XCTUnwrap(firstLease), secondLease)
            gate.release(secondLease)
        } catch {
            first.cancel()
            second?.cancel()
            gate.release(owner)
            if let firstLease { gate.release(firstLease) }
            if let acquired = try? await first.value { gate.release(acquired) }
            if let second, let acquired = try? await second.value { gate.release(acquired) }
            throw error
        }
        XCTAssertEqual(gate.queuedRequestCount, 0)
    }

    func testCancellationAtHandoffDoesNotStrandTheFollowingRequest() async throws {
        let gate = OSAtlasModelAccessGate()
        let owner = try await gate.acquire()
        let firstFinished = expectation(description: "First request releases its reservation")
        let first = Task {
            defer { firstFinished.fulfill() }
            let lease = try await gate.acquire()
            defer { gate.release(lease) }
            try Task.checkCancellation()
        }
        var second: Task<Void, Error>?
        do {
            try await waitForModelAccessQueue(1) { gate.queuedRequestCount }
            let secondFinished = expectation(description: "Following request obtains exclusive access")
            let secondRequest = Task {
                defer { secondFinished.fulfill() }
                let lease = try await gate.acquire()
                gate.release(lease)
            }
            second = secondRequest
            try await waitForModelAccessQueue(2) { gate.queuedRequestCount }
            gate.release(owner)
            first.cancel()
            // Either acquisition won the cancellation race and its defer
            // releases, or acquire itself returns the cancelled reservation.
            try await waitForModelAccessExpectations([firstFinished, secondFinished])
            _ = try? await first.value
            try await secondRequest.value
        } catch {
            first.cancel()
            second?.cancel()
            gate.release(owner)
            _ = try? await first.value
            _ = try? await second?.value
            throw error
        }
        XCTAssertEqual(gate.queuedRequestCount, 0)
    }
}

final class OSAtlasLlamaRuntimeTests: XCTestCase {

    private var holoInputs: ComputerUseHoloRuntimeInputs {
        .init(modelURL: URL(fileURLWithPath: "/models/Holo-3.1-4B.Q4_K_M.gguf"),
              projectorURL: URL(fileURLWithPath: "/models/Holo-3.1-4B.mmproj-f16.gguf"),
              llamaServerURL: nativeTextInputs.llamaServerURL)
    }

    func testHoloSharesManagedLifecycleButKeepsItsOwnToolProtocol() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let response = try JSONSerialization.data(withJSONObject: ["model": ComputerUseHoloModel.modelAlias,
            "choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "", "tool_calls": [
                ["id": "scroll-1", "type": "function", "function": ["name": "scroll", "arguments": "{\"x\":250,\"y\":500,\"direction\":\"down\",\"distance\":240}"]]]]]]])
        let transport = FakeTransportMaker(events: events, completionDataResponses: [response])
        let runtime = textRuntime(launcher, transports: transport)
        do {
            _ = try await runtime.activateFara(faraInputs)
            let endpoint = try await runtime.activateHolo(holoInputs)
            let cached = try await runtime.activateHolo(holoInputs)
            XCTAssertEqual(endpoint, cached); XCTAssertNil(endpoint.variant)
            let configurations = await launcher.configurations()
            XCTAssertEqual(configurations.count, 2)
            let configuration = try XCTUnwrap(configurations.last), credential = try XCTUnwrap(configuration.authenticationFile)
            try credential.verify()
            for (flag, expected) in [("--model", holoInputs.modelURL.path), ("--mmproj", holoInputs.projectorURL.path),
                ("--alias", ComputerUseHoloModel.modelAlias), ("--ctx-size", "8192"), ("--image-max-tokens", "1536"), ("--parallel", "1"), ("--poll", "0")] {
                let index = try XCTUnwrap(configuration.arguments.firstIndex(of: flag)); XCTAssertEqual(configuration.arguments[index + 1], expected)
            }
            XCTAssertFalse(configuration.arguments.contains(endpoint.bearerToken)); XCTAssertFalse(configuration.arguments.contains("--chat-template"))
            XCTAssertEqual(configuration.maximumProcessCount, 1)
            XCTAssertEqual(configuration.resourceProfile.maximumResidentMemoryBytes, 4 * 1_024 * 1_024 * 1_024)
            let png = try XCTUnwrap(NSBitmapImageRep(data: makeTestJPEG(width: 4, height: 4))?.representation(using: .png, properties: [:]))
            let input = ComputerUseFaraModel.Input(goal: "Scroll the current pane down.", screenshotPNG: png, surface: .desktop)
            let proposal = try await runtime.proposeHolo(endpoint: endpoint, input: input)
            XCTAssertEqual(proposal.action, .scrollAt(horizontal: false, pixels: -240, point: .init(x: 250, y: 500)))
            do { _ = try await runtime.proposeFara(endpoint: endpoint, input: input); XCTFail("Fara protocol reached Holo") }
            catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession) }
            let request = try XCTUnwrap(transport.recordedCompletionRequests().first)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, ComputerUseHoloModel.modelAlias)
            XCTAssertNotNil(body["tools"]); XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
            let values = await events.values()
            XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Fara1.5-4B-Q4_K_M.gguf")),
                              try XCTUnwrap(values.firstIndex(of: "launch:Holo-3.1-4B.Q4_K_M.gguf")))
            await runtime.shutdown(); XCTAssertFalse(FileManager.default.fileExists(atPath: credential.directoryURL.path))
        } catch { await runtime.shutdown(); throw error }
    }

    func testHoloCancellationJoinsWorkerAndCannotCancelItsFaraReplacement() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, blocksCompletion: true)
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateHolo(holoInputs)
        let png = try XCTUnwrap(NSBitmapImageRep(data: makeTestJPEG(width: 4, height: 4))?.representation(using: .png, properties: [:]))
        let input = ComputerUseFaraModel.Input(goal: "Inspect the document.", screenshotPNG: png, surface: .desktop)
        let proposal = Task { try await runtime.proposeHolo(endpoint: endpoint, input: input) }
        await transport.waitUntilCompletionStarted(); proposal.cancel()
        do { _ = try await proposal.value; XCTFail("Cancelled Holo output returned") } catch { XCTAssertTrue(error is CancellationError) }
        let replacement = try await runtime.activateFara(faraInputs)
        await runtime.cancel(endpoint: endpoint)
        let cached = try await runtime.activateFara(faraInputs); XCTAssertEqual(cached, replacement)
        do { _ = try await runtime.proposeHolo(endpoint: replacement, input: input); XCTFail("Holo protocol reached Fara") }
        catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession) }
        let values = await events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Holo-3.1-4B.Q4_K_M.gguf")),
                          try XCTUnwrap(values.firstIndex(of: "launch:Fara1.5-4B-Q4_K_M.gguf")))
        XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        await runtime.shutdown()
    }

    func testHoloRejectsWrongDataAndUnder16GBBeforeLaunching() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let runtime = textRuntime(launcher, transports: FakeTransportMaker(events: events))
        for inputs in [ComputerUseHoloRuntimeInputs(modelURL: faraInputs.modelURL, projectorURL: holoInputs.projectorURL, llamaServerURL: holoInputs.llamaServerURL),
            .init(modelURL: holoInputs.modelURL, projectorURL: faraInputs.projectorURL, llamaServerURL: holoInputs.llamaServerURL),
            .init(modelURL: holoInputs.modelURL, projectorURL: holoInputs.projectorURL, llamaServerURL: URL(string: "https://example.invalid/llama-server")!)] {
            do { _ = try await runtime.activateHolo(inputs); XCTFail("Mismatched/untrusted Holo paths launched") }
            catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidLocalInstallation) }
        }
        let limited = OSAtlasLlamaRuntime(launcher: launcher, transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123), tokenProvider: FixedTokenProvider(token: "fixture"), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: FixedResourceInspector(snapshotValue: .init(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024 - 1, reclaimableMemoryBytes: .max)))
        do { _ = try await limited.activateHolo(holoInputs); XCTFail("16 GB floor ignored") }
        catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .insufficientPhysicalMemory) }
        let configurations = await launcher.configurations(); XCTAssertTrue(configurations.isEmpty)
        await runtime.shutdown(); await limited.shutdown()

        let exactBoundary = OSAtlasLlamaRuntime(launcher: launcher, transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43124), tokenProvider: FixedTokenProvider(token: "private-runtime-boundary-token"), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: FixedResourceInspector(snapshotValue: .init(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024, reclaimableMemoryBytes: .max)))
        _ = try await exactBoundary.activateHolo(holoInputs)
        let exactConfigurations = await launcher.configurations()
        XCTAssertEqual(exactConfigurations.count, 1, "Holo must launch at exactly 16 GB")
        await exactBoundary.shutdown()
    }

    func testHoloInvalidRequestsAndResponsesStopWorkerBeforeAnotherModelLoads() async throws {
        for scenario in ["invalid request", "malformed response", "wrong protocol"] {
            let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
            let wrongProtocol = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": [
                "role": "assistant", "content": "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"seconds\":0}}</tool_call>"]]]])
            let transport = FakeTransportMaker(events: events, completionDataResponses: [scenario == "wrong protocol" ? wrongProtocol : Data("invalid JSON".utf8)])
            let runtime = textRuntime(launcher, transports: transport)
            let endpoint = try await runtime.activateHolo(holoInputs)
            let configurations = await launcher.configurations(), credential = try XCTUnwrap(configurations.first?.authenticationFile)
            let png = try XCTUnwrap(NSBitmapImageRep(data: makeTestJPEG(width: 4, height: 4))?.representation(using: .png, properties: [:]))
            let input = ComputerUseFaraModel.Input(goal: scenario == "invalid request" ? "" : "Inspect the document.", screenshotPNG: png, surface: .desktop)
            do { _ = try await runtime.proposeHolo(endpoint: endpoint, input: input); XCTFail("Invalid contract returned an action: \(scenario)") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: credential.directoryURL.path), scenario)
            let stop = await runtime.lastWorkerStop; XCTAssertEqual(stop?.cleanupSucceeded, true)
            _ = try await runtime.activateFara(faraInputs)
            do { _ = try await runtime.proposeHolo(endpoint: endpoint, input: input); XCTFail("A failed request reached the replacement") }
            catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession) }
            let values = await events.values()
            XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Holo-3.1-4B.Q4_K_M.gguf")),
                              try XCTUnwrap(values.firstIndex(of: "launch:Fara1.5-4B-Q4_K_M.gguf")))
            XCTAssertEqual(transport.recordedCompletionRequests().count, scenario == "invalid request" ? 0 : 1)
            await runtime.shutdown()
        }
    }

    private var faraInputs: ComputerUseFaraRuntimeInputs {
        .init(modelURL: URL(fileURLWithPath: "/models/Fara1.5-4B-Q4_K_M.gguf"),
              projectorURL: URL(fileURLWithPath: "/models/mmproj-Fara1.5-4B-f16.gguf"),
              llamaServerURL: nativeTextInputs.llamaServerURL)
    }

    func testFaraUsesSharedLifecycleWithNativeVisionProfileAndPrivateCredential() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events)
        let runtime = textRuntime(launcher, transports: transport)
        do {
            _ = try await runtime.activateNativeText(nativeTextInputs)
            let endpoint = try await runtime.activateFara(faraInputs)
            let cached = try await runtime.activateFara(faraInputs)
            XCTAssertEqual(cached, endpoint); XCTAssertNil(endpoint.variant)
            let configurations = await launcher.configurations()
            XCTAssertEqual(configurations.count, 2)
            let configuration = try XCTUnwrap(configurations.last)
            let credential = try XCTUnwrap(configuration.authenticationFile)
            try credential.verify()
            let arguments = configuration.arguments
            for (flag, value) in [("--mmproj", faraInputs.projectorURL.path), ("--ctx-size", "8192"),
                                  ("--alias", ComputerUseFaraRuntimeInputs.modelAlias), ("--image-max-tokens", "1536"),
                                  ("--parallel", "1"), ("--poll", "0"), ("--cache-ram", "0")] {
                let index = try XCTUnwrap(arguments.firstIndex(of: flag))
                XCTAssertEqual(arguments[index + 1], value)
            }
            XCTAssertFalse(arguments.contains("--chat-template"))
            XCTAssertFalse(arguments.contains("--no-mmproj"))
            XCTAssertFalse(arguments.contains("--reasoning-budget"))
            XCTAssertFalse(arguments.contains(endpoint.bearerToken))
            XCTAssertTrue(arguments.contains("--no-context-shift"))
            XCTAssertEqual(configuration.maximumProcessCount, 1)
            do {
                _ = try await runtime.proposeNativeText(endpoint: endpoint, prompt: "Set Origin to Oslo.", fields: nativeTextFields)
                XCTFail("The Fara worker must never receive a general-model text contract")
            } catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession) }
            let values = await events.values()
            XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Qwen3.5-4B-Q4_K_M.gguf")),
                              try XCTUnwrap(values.firstIndex(of: "launch:Fara1.5-4B-Q4_K_M.gguf")))
            await runtime.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: credential.directoryURL.path))
            XCTAssertTrue(transport.recordedCompletionRequests().isEmpty)
        } catch { await runtime.shutdown(); throw error }
    }

    func testFaraContextBudgetTrimsOldestDesktopHistoryAndPreservesCurrentFileState() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [try faraWaitResponse()],
            inputTokenCounts: [7_000, 6_000, 5_000])
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs), png = try faraTestPNG()
        let first = "Oldest history narrative", second = "Newer history narrative"
        let goal = "Continue the requested browser task without losing the selected file."
        let candidate = ComputerUseLocalFileCatalog.Candidate(id: "candidate-exact-1",
            displayName: "Selected Presentation.pptx", contentTypeIdentifier: "org.openxmlformats.presentationml.presentation",
            fileExtension: "pptx", byteCount: 1_024, modifiedAt: Date(timeIntervalSince1970: 10),
            createdAt: nil, addedToDirectoryAt: nil)
        let catalog = ComputerUseMCPBrowserStepPlanner.LocalFileContext(query: .init(fileKind: .presentation),
            page: .init(candidates: [candidate], isComplete: true, nextCursor: nil,
                hasTiedSortValues: false, hasMissingSortValues: false), selectedCandidate: candidate)
        let directive = ComputerUseFaraModel.WorkerDirective(objective: "Continue the upload task",
            constraints: "Preserve the user's destination and selected file.", completionCriteria: ["Verify the current result"])
        var input = ComputerUseFaraModel.Input(goal: goal, screenshotPNG: png, surface: .desktop,
            history: [.init(screenshotPNG: png, response: faraWaitAction(first)),
                      .init(screenshotPNG: png, response: faraWaitAction(second))],
            actionError: "Previous action rejected; no input was sent.")
        input.browserWorkerDirective = directive; input.localFileCatalog = catalog
        input.selectedLocalFilePath = "/Users/fixture/Downloads/Selected Presentation.pptx"
        input.nativeOpenPanelSelection = .init(candidateSelected: true, primaryActionEnabled: true)
        input.hostDispatchedLocalFileConfirmationCandidateID = candidate.id
        let originalInput = input
        _ = try await runtime.proposeFara(endpoint: endpoint, input: input)
        XCTAssertEqual(input, originalInput, "Request budgeting must not mutate caller history")
        let counts = transport.recordedTokenCountRequests()
        XCTAssertEqual(counts.count, 3, "Recount after each oldest-history eviction")
        XCTAssertEqual(try counts.map(faraAssistantHistoryCount), [2, 1, 0])
        let completions = transport.recordedCompletionRequests()
        XCTAssertEqual(completions.count, 1)
        let final = try XCTUnwrap(completions.first)
        XCTAssertEqual(try faraImageCount(final), 1, "Desktop history reserves only the current screenshot")
        let body = try faraBodyString(try XCTUnwrap(final.httpBody))
        XCTAssertFalse(body.contains(first)); XCTAssertFalse(body.contains(second))
        for required in [goal, "Previous action rejected; no input was sent.", candidate.displayName,
                         candidate.id, "/Users/fixture/Downloads/Selected Presentation.pptx",
                         "Continue the upload task", "Verify the current result"] {
            XCTAssertTrue(body.contains(required), "Trimmed request lost current context: \(required)")
        }
        XCTAssertEqual(input.history.count, 2)
        await runtime.shutdown()
    }

    func testFaraContextBudgetRejectsOversizedCurrentObservationWithoutCompletion() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [try faraWaitResponse()], inputTokenCounts: [6_000])
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs)
        let input = ComputerUseFaraModel.Input(goal: "Keep the current task and observation.", screenshotPNG: try faraTestPNG(),
            surface: .desktop, actionError: "Current rejection feedback must remain.")
        do { _ = try await runtime.proposeFara(endpoint: endpoint, input: input); XCTFail("Mandatory current context cannot be evicted") }
        catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inputContextTooLarge) }
        XCTAssertEqual(transport.recordedTokenCountRequests().count, 1)
        XCTAssertTrue(transport.recordedCompletionRequests().isEmpty)
        await runtime.shutdown()
    }

    func testFaraContextBudgetKeepsShortBoundaryInputAndHistory() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [try faraWaitResponse()], inputTokenCounts: [5_568])
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs), png = try faraTestPNG()
        let prior = "Recent history remains when the complete request fits."
        let input = ComputerUseFaraModel.Input(goal: "Continue this task.", screenshotPNG: png, surface: .desktop,
            history: [.init(screenshotPNG: png, response: faraWaitAction(prior))], actionError: "Current feedback")
        _ = try await runtime.proposeFara(endpoint: endpoint, input: input)
        XCTAssertEqual(transport.recordedTokenCountRequests().count, 1)
        XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        let completion = try XCTUnwrap(transport.recordedCompletionRequests().first)
        XCTAssertEqual(try faraAssistantHistoryCount(completion), 1)
        let bodyData = try XCTUnwrap(completion.httpBody)
        XCTAssertTrue(try faraBodyString(bodyData).contains(prior))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let currentContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(currentContent.first { $0["type"] as? String == "image_url" })
        let imageURL = try XCTUnwrap((image["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(imageURL, "data:image/png;base64,\(png.base64EncodedString())",
            "Current screenshot must survive request-history budgeting byte for byte")
        await runtime.shutdown()
    }

    func testFaraContextBudgetReservesRecentBrowserScreenshotWindowAndClarifications() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [try faraWaitResponse()],
            inputTokenCounts: [4_000, 4_000, 4_000])
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs), png = try faraTestPNG()
        let originalGoal = "Continue the browser task after a clarification."
        let clarified = try ComputerUseUnresolvedTextGoal(userRequest: originalGoal)
            .answering("Which presentation?", with: "Selected Presentation.pptx")
        let input = ComputerUseFaraModel.Input(goal: originalGoal, screenshotPNG: png, surface: .browser,
            history: [.init(screenshotPNG: png, response: faraWaitAction("Oldest")),
                      .init(screenshotPNG: png, response: faraWaitAction("Middle")),
                      .init(screenshotPNG: png, response: faraWaitAction("Newest"))],
            currentURL: URL(string: "https://example.com/"), actionError: "Keep current rejection feedback",
            clarifiedGoal: clarified)
        _ = try await runtime.proposeFara(endpoint: endpoint, input: input)
        let counts = transport.recordedTokenCountRequests()
        XCTAssertEqual(counts.count, 3, "Three image reserves overflow; two recent images fit")
        XCTAssertEqual(try counts.map(faraImageCount), [3, 3, 2])
        let completion = try XCTUnwrap(transport.recordedCompletionRequests().first)
        XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        XCTAssertEqual(try faraAssistantHistoryCount(completion), 1)
        XCTAssertEqual(try faraImageCount(completion), 2)
        let body = try faraBodyString(try XCTUnwrap(completion.httpBody))
        for required in [originalGoal, "Selected Presentation.pptx", "Which presentation?", "https://example.com/",
                         "Keep current rejection feedback"] {
            XCTAssertTrue(body.contains(required), "Trimmed browser request lost mandatory context: \(required)")
        }
        XCTAssertEqual(input.history.count, 3)
        await runtime.shutdown()
    }

    func testFaraCorrectsOneCompleteInvalidActionFormatWithoutChangingCurrentTask() async throws {
        let events = RuntimeEventLog()
        let invalid = try faraCompletionResponse(#"{"action":"type","text":"https://drive.google.com/","coordinate":[500,500],"keys":["Enter"]}"#)
        let valid = try faraCompletionResponse(#"{"action":"type","text":"https://drive.google.com/"}"#)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [invalid, valid], inputTokenCounts: [100, 100])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs)
        let png = try faraTestPNG()
        let input = ComputerUseFaraModel.Input(goal: "Open the requested browser page.", screenshotPNG: png,
            surface: .desktop, actionError: "Keep prior rejection feedback.")
        let originalInput = input
        do {
            let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
            XCTAssertEqual(proposal.action, .typeText("https://drive.google.com/"))
            XCTAssertEqual(input, originalInput)
            let requests = transport.recordedCompletionRequests()
            XCTAssertEqual(requests.count, 2)
            let first = try faraBodyString(try XCTUnwrap(requests.first?.httpBody))
            let second = try faraBodyString(try XCTUnwrap(requests.last?.httpBody))
            XCTAssertTrue(first.contains(input.goal)); XCTAssertTrue(second.contains(input.goal))
            XCTAssertTrue(first.contains("Keep prior rejection feedback"))
            XCTAssertTrue(second.contains("Keep prior rejection feedback"))
            XCTAssertTrue(second.contains("previous proposal was rejected before execution"))
            XCTAssertEqual(try faraImageCount(try XCTUnwrap(requests.first)), 1)
            XCTAssertEqual(try faraImageCount(try XCTUnwrap(requests.last)), 1)
            XCTAssertEqual(try ComputerUseFaraModel.decode(valid).action, proposal.action)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testFaraInvalidActionFormatGetsOnlyOneCorrectionAttempt() async throws {
        let events = RuntimeEventLog()
        let invalid = try faraCompletionResponse(#"{"action":"type","text":"x","keys":["Enter"]}"#)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [invalid, invalid], inputTokenCounts: [100, 100])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs)
        do {
            _ = try await runtime.proposeFara(endpoint: endpoint, input: .init(
                goal: "Continue the original task.", screenshotPNG: try faraTestPNG(), surface: .desktop))
            XCTFail("Two invalid action formats must fail closed")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .invalidResponse)
            XCTAssertEqual(transport.recordedCompletionRequests().count, 2)
        }
        await runtime.shutdown()
    }

    func testFaraCancellationBeforeCorrectionCompletionDoesNotAcceptLateAction() async throws {
        let events = RuntimeEventLog()
        let invalid = try faraCompletionResponse(#"{"action":"type","text":"x","keys":["Enter"]}"#)
        let transport = FakeTransportMaker(events: events, blockedCompletionCall: 2,
            completionDataResponses: [invalid, try faraCompletionResponse(#"{"action":"wait","time":0}"#)],
            inputTokenCounts: [100, 100])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs)
        let operation = Task {
            try await runtime.proposeFara(endpoint: endpoint, input: .init(
                goal: "Continue the original task.", screenshotPNG: try faraTestPNG(), surface: .desktop))
        }
        guard await transport.waitUntilCompletionStarted(call: 2) else {
            operation.cancel()
            await runtime.shutdown()
            XCTFail("The correction request did not reach its bounded fake completion")
            return
        }
        operation.cancel()
        let result = await operation.result
        switch result {
        case .success: XCTFail("A cancelled correction must not accept a late action")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)")
        }
        XCTAssertEqual(transport.recordedCompletionRequests().count, 2)
        await runtime.shutdown()
    }

    func testFaraCorrectionBudgetOverflowStopsBeforeSecondCompletion() async throws {
        let events = RuntimeEventLog()
        let invalid = try faraCompletionResponse(#"{"action":"type","text":"x","keys":["Enter"]}"#)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [invalid], inputTokenCounts: [5_568, 5_569])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs)
        do {
            _ = try await runtime.proposeFara(endpoint: endpoint, input: .init(
                goal: "Continue the original task.", screenshotPNG: try faraTestPNG(), surface: .desktop,
                history: [.init(screenshotPNG: try faraTestPNG(), response: faraWaitAction("Prior action."))]))
            XCTFail("The correction must not evict context to fit")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .inputContextTooLarge)
            XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
            let requests = transport.recordedTokenCountRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(try requests.map(faraAssistantHistoryCount), [1, 1],
                "A retry budget failure must not trim retained history")
        }
        await runtime.shutdown()
    }

    func testFaraValidActionFormatUsesOneCompletionAndInvalidEnvelopeIsNotRetried() async throws {
        let events = RuntimeEventLog()
        let valid = try faraCompletionResponse(#"{"action":"wait","time":0}"#)
        let transport = FakeTransportMaker(events: events, completionDataResponses: [valid])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateFara(faraInputs)
        _ = try await runtime.proposeFara(endpoint: endpoint, input: .init(
            goal: "Wait for the page.", screenshotPNG: try faraTestPNG(), surface: .desktop))
        XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        await runtime.shutdown()

        let badEnvelope = try JSONSerialization.data(withJSONObject: ["model": ComputerUseFaraRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "length", "message": ["role": "assistant", "content": "truncated" ]]]])
        let badEvents = RuntimeEventLog()
        let badTransport = FakeTransportMaker(events: badEvents, completionDataResponses: [badEnvelope])
        let badRuntime = textRuntime(FakeLlamaLauncher(events: badEvents), transports: badTransport)
        let badEndpoint = try await badRuntime.activateFara(faraInputs)
        do {
            _ = try await badRuntime.proposeFara(endpoint: badEndpoint, input: .init(
                goal: "Wait for the page.", screenshotPNG: try faraTestPNG(), surface: .desktop))
            XCTFail("An invalid completion envelope must not receive format recovery")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .invalidResponse)
            XCTAssertEqual(badTransport.recordedCompletionRequests().count, 1)
        }
        await badRuntime.shutdown()
    }

    private func faraTestPNG() throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(data: makeTestJPEG(width: 4, height: 4))?.representation(using: .png, properties: [:]))
    }

    private func faraCompletionResponse(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": ComputerUseFaraRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": "\n<tool_call>{\"name\":\"computer_use\",\"arguments\":\(content)}</tool_call>"]]]])
    }

    private func faraWaitAction(_ narrative: String) -> String {
        "\(narrative)\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
    }

    private func faraWaitResponse() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": ComputerUseFaraRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": faraWaitAction("Wait for the current state.")]]]])
    }

    private func faraBodyString(_ request: Data) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        return messages.compactMap { message -> String? in
            if let text = message["content"] as? String { return text }
            guard let content = message["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private func faraImageCount(_ request: URLRequest) throws -> Int {
        guard let data = request.httpBody else { XCTFail("Expected request body"); return 0 }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        return messages.reduce(0) { count, message in
            count + ((message["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image_url" }.count ?? 0)
        }
    }

    private func faraAssistantHistoryCount(_ request: URLRequest) throws -> Int {
        guard let data = request.httpBody else { XCTFail("Expected request body"); return 0 }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        return messages.filter { $0["role"] as? String == "assistant" }.count
    }

    private var nativeTextInputs: ComputerUseNativeTextRuntimeInputs {
        ComputerUseNativeTextRuntimeInputs(
            modelURL: URL(fileURLWithPath: "/models/Qwen3.5-4B-Q4_K_M.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/app/Contents/Helpers/llama-server"))
    }

    func testFaraCancellationJoinsWorkerBeforeReplacementAndRejectsLateOldCancellation() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, blocksCompletion: true)
        let runtime = textRuntime(launcher, transports: transport)
        let png = try XCTUnwrap(NSBitmapImageRep(data: makeTestJPEG(width: 4, height: 4))?.representation(using: .png, properties: [:]))
        let endpoint = try await runtime.activateFara(faraInputs)
        let proposal = Task { try await runtime.proposeFara(endpoint: endpoint, input: .init(goal: "Click Destination.", screenshotPNG: png)) }
        await transport.waitUntilCompletionStarted()
        proposal.cancel()
        do { _ = try await proposal.value; XCTFail("Cancelled Fara output cannot return to an executor") }
        catch { XCTAssertTrue(error is CancellationError) }
        let replacement = try await runtime.activateNativeText(nativeTextInputs)
        await runtime.cancel(endpoint: endpoint)
        let cached = try await runtime.activateNativeText(nativeTextInputs)
        XCTAssertEqual(cached, replacement)
        do {
            _ = try await runtime.proposeFara(endpoint: endpoint, input: .init(goal: "Click Destination.", screenshotPNG: png))
            XCTFail("A stale Fara endpoint cannot reach its replacement")
        } catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .inactiveSession) }
        XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        let values = await events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Fara1.5-4B-Q4_K_M.gguf")),
                          try XCTUnwrap(values.firstIndex(of: "launch:Qwen3.5-4B-Q4_K_M.gguf")))
        await runtime.shutdown()
    }

    func testFaraRejectsWrongProjectorAndUnder16GBBeforeLaunching() async throws {
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let runtime = textRuntime(launcher, transports: FakeTransportMaker(events: events))
        do {
            _ = try await runtime.activateFara(.init(modelURL: faraInputs.modelURL,
                projectorURL: URL(fileURLWithPath: "/models/mmproj-OSAtlas-f16.gguf"), llamaServerURL: faraInputs.llamaServerURL))
            XCTFail("An unrelated projector must be rejected before launch")
        } catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .invalidLocalInstallation) }
        let limited = OSAtlasLlamaRuntime(launcher: launcher, transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123), tokenProvider: FixedTokenProvider(token: "fixture"),
            readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: FixedResourceInspector(snapshotValue: .init(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024 - 1,
                reclaimableMemoryBytes: .max)))
        do {
            _ = try await limited.activateFara(faraInputs)
            XCTFail("The trained-model launch must honor the 16 GB minimum")
        } catch { XCTAssertEqual(error as? OSAtlasLlamaRuntimeError, .insufficientPhysicalMemory) }
        let configurations = await launcher.configurations()
        XCTAssertTrue(configurations.isEmpty)
        await runtime.shutdown(); await limited.shutdown()

        let exactBoundary = OSAtlasLlamaRuntime(launcher: launcher, transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43124), tokenProvider: FixedTokenProvider(token: "private-runtime-boundary-token"),
            readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: FixedResourceInspector(snapshotValue: .init(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                reclaimableMemoryBytes: .max)))
        _ = try await exactBoundary.activateFara(faraInputs)
        let exactConfigurations = await launcher.configurations()
        XCTAssertEqual(exactConfigurations.count, 1, "Fara must launch at exactly 16 GB")
        await exactBoundary.shutdown()
    }

    private var nativeTextFields: [ComputerUseTextField] {
        [ComputerUseTextField(label: "Origin", snapshot: ComputerUseTextSnapshot(
            targetID: "field-origin", value: "old private value",
            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))]
    }

    private func textRuntime(_ launcher: FakeLlamaLauncher,
                             transports: FakeTransportMaker) -> OSAtlasLlamaRuntime {
        OSAtlasLlamaRuntime(launcher: launcher, transportMaker: transports,
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "private-runtime-test-token"),
            readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)
    }

    @MainActor
    func testRuntimeBrowserActionRecallUsesSharedWorkerWithoutFormChoices() async throws {
        let fixture = try await ResearchDriverFixture.make(candidateBodyHTML: "<p>Unresolved fees</p>")
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), base = try await owner.planNextAction(using: fixture.actions).input
        let events = RuntimeEventLog(), launcher = FakeLlamaLauncher(events: events)
        let responses = try [#"{"reading":0}"#, #"{"unavailable":true}"#].map { content in
            try JSONSerialization.data(withJSONObject: ["model":ComputerUseNativeTextRuntimeInputs.modelAlias,
                "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
        }
        let transport = FakeTransportMaker(events: events, completionDataResponses: responses)
        let runtime = textRuntime(launcher, transports: transport)
        let planner = ComputerUseRuntimeBrowserActionPlanner(inputs: nativeTextInputs, runtime: runtime)
        do {
            let empty = try ComputerUseBrowserActionInput(interpretation: base.interpretation, evidence: base.evidence,
                navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
            let skipped = try await planner.propose(empty), unused = await launcher.configurations()
            XCTAssertEqual(skipped.step, .readResults); XCTAssertTrue(unused.isEmpty)
            let action = try await owner.planNextAction(using: planner)
            XCTAssertFalse(action.input.needsFormDecision); XCTAssertTrue(action.input.needsPlanningDecision)
            XCTAssertEqual(action.step, .unavailable); XCTAssertEqual(action.input.recalledReadingIndices, [0])
            let configurations = await launcher.configurations()
            XCTAssertEqual(configurations.count, 1)
            let completions = transport.recordedCompletionRequests()
            XCTAssertEqual(completions.count, 2); XCTAssertEqual(transport.recordedTokenCountRequests(), completions)
            let request = try XCTUnwrap(completions.last), data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.last?["content"], action.input.contextJSON)
            XCTAssertTrue(action.input.contextJSON.contains("Unresolved fees"))
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
            XCTAssertEqual(fixture.server.count("/details"), 0)
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    func testNativeTextLaunchUsesPrivateCredentialAndMeasuredSingleModelBudget() throws {
        let token = "private-runtime-test-token"
        let file = try OSAtlasLlamaPrivateFile.authentication(token: token)
        defer { file.remove() }
        let configuration = OSAtlasLlamaLaunchConfiguration(nativeTextInputs: nativeTextInputs,
            port: 43123, bearerToken: token, authenticationFile: file)
        try file.verify()
        let arguments = configuration.arguments
        XCTAssertFalse(arguments.contains(token))
        XCTAssertFalse(arguments.contains("--api-key"))
        XCTAssertFalse(arguments.contains("--mmproj"))
        XCTAssertFalse(arguments.contains("--models-preset"))
        XCTAssertTrue(arguments.contains("--no-mmproj"))
        XCTAssertTrue(arguments.contains("--offline"))
        for (flag, value) in [("--host", "127.0.0.1"), ("--ctx-size", "6144"),
                              ("--parallel", "1"), ("--reasoning-budget", "512"),
                              ("--threads", "4"), ("--threads-batch", "4"),
                              ("--poll", "0"), ("--poll-batch", "0"),
                              ("--alias", ComputerUseNativeTextRuntimeInputs.modelAlias),
                              ("--api-key-file", file.fileURL.path)] {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag))
            XCTAssertEqual(arguments[index + 1], value)
        }
        XCTAssertNil(configuration.multimodalProjectorURL)
        XCTAssertEqual(configuration.maximumProcessCount, 1)
        XCTAssertEqual(configuration.resourceProfile, .compact)
        try Data("different-private-token".utf8).write(to: file.fileURL)
        XCTAssertThrowsError(try file.verify())
        XCTAssertThrowsError(try OSAtlasLlamaPrivateFile.authentication(token: "bad\ncredential"))
    }

    func testNativeTextAndVisualShareOneLifecycleAndRejectCrossModelOrStaleRequests() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events)
        let runtime = textRuntime(launcher, transports: transport)
        _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
        let text = try await runtime.activateNativeText(nativeTextInputs)
        XCTAssertNil(text.variant)
        let cached = try await runtime.activateNativeText(nativeTextInputs)
        XCTAssertEqual(cached, text)
        let configurations = await launcher.configurations()
        let credential = try XCTUnwrap(configurations.last?.authenticationFile)
        try credential.verify()
        do {
            _ = try await runtime.complete(endpoint: text, prompt: "Click", jpegData: Data())
            XCTFail("A text endpoint must not accept a visual request")
        } catch let error as OSAtlasLlamaRuntimeError { XCTAssertEqual(error, .inactiveSession) }
        _ = try await runtime.activate(inputs(variant: .pro4B, name: "replacement"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.directoryURL.path))
        do {
            _ = try await runtime.proposeNativeText(endpoint: text, prompt: "Set Origin to Oslo.", fields: nativeTextFields)
            XCTFail("A stale text endpoint must not reach the replacement model")
        } catch let error as OSAtlasLlamaRuntimeError { XCTAssertEqual(error, .inactiveSession) }
        XCTAssertTrue(transport.recordedCompletionRequests().isEmpty)
        let values = await events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:pro-Q4_K_M-00001-of-00002.gguf")),
                          try XCTUnwrap(values.firstIndex(of: "launch:Qwen3.5-4B-Q4_K_M.gguf")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Qwen3.5-4B-Q4_K_M.gguf")),
                          try XCTUnwrap(values.firstIndex(of: "launch:replacement-Q4_K_M-00001-of-00002.gguf")))
        await runtime.shutdown()
    }

    func testRuntimeTextPlannerUsesFrozenContractAndHostOwnedLiteral() async throws {
        let events = RuntimeEventLog()
        let response = try JSONSerialization.data(withJSONObject: [
            "model": ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"p2"}]}"#]]]])
        let transport = FakeTransportMaker(events: events, completionDataResponses: [response])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let planner = ComputerUseRuntimeTextGoalPlanner(inputs: nativeTextInputs, runtime: runtime)
        let result = try await planner.propose(prompt: "Set \"Origin\" to \"  東京\n\".", fields: nativeTextFields)
        XCTAssertEqual(result, .edits([ComputerUseTextPlanEdit(targetID: "field-origin", mode: .replaceAll, text: "  東京\n")]))
        let completion = try XCTUnwrap(transport.recordedCompletionRequests().first)
        XCTAssertEqual(transport.recordedTokenCountRequests(), [completion])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(completion.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], ComputerUseLocalTextGoalPlanner.candidateV2Instructions)
        XCTAssertTrue(messages[1]["content"]?.contains("literalFieldMatches") == true)
        XCTAssertFalse(String(decoding: completion.httpBody!, as: UTF8.self).contains("東京"))
        XCTAssertFalse(String(decoding: completion.httpBody!, as: UTF8.self).contains("old private value"))
        await runtime.shutdown()
    }

    func testNativeTextContextOverflowStopsBeforeCompletion() async throws {
        let events = RuntimeEventLog()
        let transport = FakeTransportMaker(events: events, inputTokenCounts: [3009])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateNativeText(nativeTextInputs)
        do {
            _ = try await runtime.proposeNativeText(endpoint: endpoint, prompt: "Set Origin to Oslo.", fields: nativeTextFields)
            XCTFail("Exact input overflow must reject before inference")
        } catch let error as ComputerUseLocalTextPlanError { XCTAssertEqual(error, .contextLimit) }
        XCTAssertTrue(transport.recordedCompletionRequests().isEmpty)
        let values = await events.values()
        XCTAssertTrue(values.contains("wait-finished:Qwen3.5-4B-Q4_K_M.gguf"))
        await runtime.shutdown()
    }

    func testRuntimeClarificationRetainsTurnsAndUsesTheExistingManagedModelLease() async throws {
        let events = RuntimeEventLog()
        let response = try JSONSerialization.data(withJSONObject: [
            "model": ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"p1"}]}"#]]]])
        let transport = FakeTransportMaker(events: events, completionDataResponses: [response])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Set Origin to a value")
            .answering("What exact text?", with: "\"  東京\n\"")
        let result = try await ComputerUseRuntimeTextGoalPlanner(inputs: nativeTextInputs, runtime: runtime)
            .propose(goal: goal, fields: nativeTextFields)
        guard case .edits(let edits, _) = result else { await runtime.shutdown(); return XCTFail("Clarification lost its literal") }
        XCTAssertEqual(edits.count, 1); XCTAssertTrue(edits[0].text.utf8.elementsEqual("  東京\n".utf8))
        let requests = transport.recordedCompletionRequests()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        XCTAssertEqual(context["userTurns"] as? [String], ["Set Origin to a value", "[exact quoted payload p1]"])
        XCTAssertEqual(context["questionsBeforeAnswers"] as? [String], ["What exact text?"])
        await runtime.shutdown()
    }

    func testRuntimeQuotationSyntaxCandidateUsesTheSameLeaseAndCannotEnableCopyFallback() async throws {
        let events = RuntimeEventLog()
        let response = try JSONSerialization.data(withJSONObject: ["model": ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices": [["finish_reason": "stop", "message": ["role": "assistant",
                "content": #"{"disposition":"supported","edits":[{"fieldID":"f1","mode":"replaceAll","value":"p1"}]}"#]]]])
        let transport = FakeTransportMaker(events: events, completionDataResponses: [response])
        let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
        let endpoint = try await runtime.activateNativeText(nativeTextInputs)
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Set Origin to a value")
            .answering("What exact text?", with: "\"  東京\n\"")
        let result = try await runtime.proposeNativeText(endpoint: endpoint, prompt: goal.userTurns[0], fields: nativeTextFields,
            contract: .quotedReferencesV12, clarificationGoal: goal)
        guard case .edits(let edits, _) = result else { await runtime.shutdown(); return XCTFail("The candidate lost its literal") }
        XCTAssertTrue(try XCTUnwrap(edits.first).text.utf8.elementsEqual("  東京\n".utf8))
        let requests = transport.recordedCompletionRequests()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        XCTAssertEqual(context["userTurns"] as? [String], ["Set Origin to a value", "\"[exact quoted payload p1]\""])
        do {
            _ = try await runtime.proposeNativeText(endpoint: endpoint, prompt: goal.userTurns[0], fields: nativeTextFields,
                contract: .quotedReferencesV12, allowFieldCopy: true, clarificationGoal: goal)
            XCTFail("The quotation-only candidate cannot inherit the experimental copy fallback")
        } catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, .invalidResponse) }
        XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        await runtime.shutdown()
    }

    func testRuntimeClarificationRejectsAnUnrelatedOriginalAndChecksExactContextLimit() async throws {
        for mismatchedOriginal in [false, true] {
            let events = RuntimeEventLog()
            let transport = FakeTransportMaker(events: events, inputTokenCounts: [3_009])
            let runtime = textRuntime(FakeLlamaLauncher(events: events), transports: transport)
            let endpoint = try await runtime.activateNativeText(nativeTextInputs)
            let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Set Origin to a value").answering("What exact text?", with: "Oslo")
            do {
                _ = try await runtime.proposeNativeText(endpoint: endpoint,
                    prompt: mismatchedOriginal ? "Different goal" : goal.userTurns[0], fields: nativeTextFields, clarificationGoal: goal)
                XCTFail("An invalid clarification must stop before completion")
            } catch { XCTAssertEqual(error as? ComputerUseLocalTextPlanError, mismatchedOriginal ? .invalidResponse : .contextLimit) }
            XCTAssertTrue(transport.recordedCompletionRequests().isEmpty)
            await runtime.shutdown()
        }
    }

    func testNativeTextCancellationReleasesModelLeaseBeforeVisualReplacement() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, blocksCompletion: true)
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateNativeText(nativeTextInputs)
        let fields = nativeTextFields
        let request = Task { try await runtime.proposeNativeText(endpoint: endpoint,
            prompt: "Set Origin to Oslo.", fields: fields) }
        await transport.waitUntilCompletionStarted()
        let replacementInputs = inputs(variant: .pro4B, name: "replacement")
        let replacement = Task { try await runtime.activate(replacementInputs) }
        for _ in 0..<20 { await Task.yield() }
        let before = await launcher.configurations()
        XCTAssertEqual(before.count, 1, "A replacement cannot unload a model during its active inference")
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled proposal must not escape") }
        catch is CancellationError {} // Test transport only releases after cancelAll.
        let current = try await replacement.value
        await runtime.cancel(endpoint: endpoint)
        let cached = try await runtime.activate(replacementInputs)
        XCTAssertEqual(cached, current, "A late text cancellation must not stop the replacement")
        let values = await events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "wait-finished:Qwen3.5-4B-Q4_K_M.gguf")),
                          try XCTUnwrap(values.firstIndex(of: "launch:replacement-Q4_K_M-00001-of-00002.gguf")))
        await runtime.shutdown()
    }

    func testCancellingQueuedActivationAndInferenceDoesNotCancelTheCurrentModelOwner() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transport = FakeTransportMaker(events: events, blocksCompletion: true)
        let runtime = textRuntime(launcher, transports: transport)
        let endpoint = try await runtime.activateNativeText(nativeTextInputs)
        let fields = nativeTextFields
        let owner = Task { try await runtime.proposeNativeText(endpoint: endpoint,
            prompt: "Set Origin to Oslo.", fields: fields) }
        await transport.waitUntilCompletionStarted()
        let activationFinished = expectation(description: "Queued activation cancels without owner release")
        let replacementInputs = inputs(variant: .pro4B, name: "replacement")
        let activation = Task {
            defer { activationFinished.fulfill() }
            return try await runtime.activate(replacementInputs)
        }
        let inferenceFinished = expectation(description: "Queued inference cancels without owner release")
        let inference = Task {
            defer { inferenceFinished.fulfill() }
            return try await runtime.proposeNativeText(endpoint: endpoint,
                prompt: "Set Origin to Paris.", fields: fields)
        }
        do {
            try await waitForModelAccessQueue(2) { await runtime.queuedModelAccessRequestCount }
            activation.cancel()
            inference.cancel()
            try await waitForModelAccessExpectations([activationFinished, inferenceFinished])
            let queuedCount = await runtime.queuedModelAccessRequestCount
            XCTAssertEqual(queuedCount, 0)
            let beforeShutdown = await events.values()
            XCTAssertFalse(beforeShutdown.contains("cancel-http"))
            XCTAssertFalse(beforeShutdown.contains(where: { $0.hasPrefix("terminate:") }))
            let launches = await launcher.configurations()
            XCTAssertEqual(launches.count, 1)
            XCTAssertEqual(transport.recordedCompletionRequests().count, 1)
        } catch {
            activation.cancel()
            inference.cancel()
            await runtime.shutdown()
            _ = try? await owner.value
            _ = try? await activation.value
            _ = try? await inference.value
            throw error
        }
        // The deliberately blocked owner exits only through explicit teardown.
        // A timeout above must not cause this test to hang during final joins.
        await runtime.shutdown()
        _ = try? await owner.value
        do { _ = try await activation.value; XCTFail("Cancelled activation returned a replacement") }
        catch is CancellationError {}
        do { _ = try await inference.value; XCTFail("Cancelled inference returned a proposal") }
        catch is CancellationError {}
    }

    func testNativeTextExpectedModelFilenameKeepsDefaultAndAllowsExplicitCandidate() async throws {
        let modelURL = URL(fileURLWithPath: "/models/Agents-A1-4B-Q4_K_M.gguf")
        let llamaServerURL = nativeTextInputs.llamaServerURL

        let defaultEvents = RuntimeEventLog()
        let defaultLauncher = FakeLlamaLauncher(events: defaultEvents)
        let defaultRuntime = textRuntime(defaultLauncher, transports: FakeTransportMaker(events: defaultEvents))
        do {
            _ = try await defaultRuntime.activateNativeText(ComputerUseNativeTextRuntimeInputs(
                modelURL: modelURL, llamaServerURL: llamaServerURL))
            XCTFail("The default installed Qwen filename must remain the only implicit accepted model")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .invalidLocalInstallation)
        }
        let defaultLaunches = await defaultLauncher.configurations()
        XCTAssertTrue(defaultLaunches.isEmpty, "Default filename mismatch must fail before launching")
        await defaultRuntime.shutdown()

        let candidateEvents = RuntimeEventLog()
        let candidateLauncher = FakeLlamaLauncher(events: candidateEvents)
        let candidateRuntime = textRuntime(candidateLauncher, transports: FakeTransportMaker(events: candidateEvents))
        let candidate = ComputerUseNativeTextRuntimeInputs(modelURL: modelURL, llamaServerURL: llamaServerURL,
            expectedModelFileName: "Agents-A1-4B-Q4_K_M.gguf")
        _ = try await candidateRuntime.activateNativeText(candidate)
        let candidateLaunches = await candidateLauncher.configurations()
        XCTAssertEqual(candidateLaunches.count, 1, "An explicitly pinned matching filename must pass validation and reach the launcher")
        XCTAssertEqual(candidateLaunches.first?.modelFirstSplitURL.lastPathComponent, "Agents-A1-4B-Q4_K_M.gguf")
        await candidateRuntime.shutdown()

        let mismatchEvents = RuntimeEventLog()
        let mismatchLauncher = FakeLlamaLauncher(events: mismatchEvents)
        let mismatchRuntime = textRuntime(mismatchLauncher, transports: FakeTransportMaker(events: mismatchEvents))
        let mismatch = ComputerUseNativeTextRuntimeInputs(modelURL: modelURL, llamaServerURL: llamaServerURL,
            expectedModelFileName: "Other-Model.gguf")
        do {
            _ = try await mismatchRuntime.activateNativeText(mismatch)
            XCTFail("An explicit expected-name mismatch must still be rejected")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .invalidLocalInstallation)
        }
        let mismatchLaunches = await mismatchLauncher.configurations()
        XCTAssertTrue(mismatchLaunches.isEmpty, "Expected-name mismatch must not invoke the launcher")
        await mismatchRuntime.shutdown()
    }

    func testNativeTextFailedReadinessRemovesPrivateCredentialAndRejectsUnknownModel() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let runtime = textRuntime(launcher, transports: FakeTransportMaker(events: events, healthResponses: [false]))
        do {
            _ = try await runtime.activateNativeText(nativeTextInputs)
            XCTFail("Failed readiness cannot return an endpoint")
        } catch let error as OSAtlasLlamaRuntimeError { XCTAssertEqual(error, .serverFailedToStart) }
        let configurations = await launcher.configurations()
        let file = try XCTUnwrap(configurations.first?.authenticationFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directoryURL.path))
        do {
            _ = try await runtime.activateNativeText(ComputerUseNativeTextRuntimeInputs(
                modelURL: URL(fileURLWithPath: "/models/unreviewed.gguf"), llamaServerURL: nativeTextInputs.llamaServerURL))
            XCTFail("An unreviewed model family cannot use the frozen form contract")
        } catch let error as OSAtlasLlamaRuntimeError { XCTAssertEqual(error, .invalidLocalInstallation) }
        let finalConfigurations = await launcher.configurations()
        XCTAssertEqual(finalConfigurations.count, 1)
        await runtime.shutdown()
    }
    func testCompletionRequestIsAuthenticatedLoopbackOnlyAndDeterministic() throws {
        let endpoint = OSAtlasLlamaEndpoint(
            generation: 7,
            variant: .pro4B,
            baseURL: URL(string: "http://127.0.0.1:43123")!,
            bearerToken: "unit-test-token")
        let request = try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: "Instructions\nScreenshot:\n<image>\nTask instruction: local prompt",
            jpegData: try makeTestJPEG(width: 32, height: 24))

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:43123/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "visual-grounder-v1")
        XCTAssertEqual(json["temperature"] as? Double, 0)
        XCTAssertEqual(json["max_tokens"] as? Int, 256)
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user"])
        let systemContent = try XCTUnwrap(
            messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(systemContent.count, 1)
        XCTAssertEqual(systemContent[0]["type"] as? String, "text")
        XCTAssertEqual(
            OSAtlasLlamaHTTPClient.officialInternVLSystemMessage,
            "你是由上海人工智能实验室联合商汤科技开发的书生多模态大模型，英文名叫InternVL, 是一个有用无害的人工智能助手。")
        XCTAssertEqual(
            systemContent[0]["text"] as? String,
            "你是由上海人工智能实验室联合商汤科技开发的书生多模态大模型，英文名叫InternVL, 是一个有用无害的人工智能助手。")

        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(
            content.compactMap { $0["type"] as? String },
            ["text", "image_url", "text"])
        XCTAssertTrue((content[0]["text"] as? String)?.hasSuffix("Screenshot:\n") == true)
        XCTAssertTrue((content[2]["text"] as? String)?.hasPrefix("\nTask instruction:") == true)
        XCTAssertFalse(content.compactMap { $0["text"] as? String }
            .contains(where: { $0.contains(OSAtlasPromptContract.screenshotMarker) }))
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: String])
        XCTAssertTrue(try XCTUnwrap(imageURL["url"]).hasPrefix("data:image/jpeg;base64,"))

        let remote = OSAtlasLlamaEndpoint(
            generation: 8,
            variant: .pro4B,
            baseURL: URL(string: "https://example.com")!,
            bearerToken: "token")
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: remote,
            prompt: "before<image>after",
            jpegData: try makeTestJPEG(width: 32, height: 24)))
    }

    func testCompletionRequestRejectsMissingOrDuplicateScreenshotMarker() throws {
        let endpoint = OSAtlasLlamaEndpoint(
            generation: 7,
            variant: .pro4B,
            baseURL: URL(string: "http://127.0.0.1:43123")!,
            bearerToken: "unit-test-token")
        let jpeg = try makeTestJPEG(width: 32, height: 24)

        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: "Screenshot is missing",
            jpegData: jpeg))
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: "before<image>middle<image>after",
            jpegData: jpeg))
    }

    func testCompletionRequestRejectsOversizedOrDecompressionBombImage() throws {
        let endpoint = OSAtlasLlamaEndpoint(
            generation: 7,
            variant: .pro4B,
            baseURL: URL(string: "http://127.0.0.1:43123")!,
            bearerToken: "unit-test-token")

        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: "before<image>after",
            jpegData: try makeTestJPEG(width: 449, height: 10)))

        var oversizedBytes = Data([0xFF, 0xD8, 0xFF])
        oversizedBytes.append(Data(
            repeating: 0,
            count: OSAtlasVisionInputPolicy.maximumEncodedBytes))
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.makeCompletionRequest(
            endpoint: endpoint,
            prompt: "before<image>after",
            jpegData: oversizedBytes))
    }

    func testLaunchArgumentsPinLoopbackAuthNoLogsAndInferenceBudget() {
        let configuration = OSAtlasLlamaLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/signed/llama-server"),
            workingDirectoryURL: URL(fileURLWithPath: "/runtime"),
            modelFirstSplitURL: URL(fileURLWithPath: "/model/pro-Q4_K_M-00001-of-00002.gguf"),
            multimodalProjectorURL: URL(fileURLWithPath: "/model/mmproj-model-f16.gguf"),
            port: 43123,
            bearerToken: "secret-token")
        XCTAssertEqual(configuration.arguments, [
            "--model", "/model/pro-Q4_K_M-00001-of-00002.gguf",
            "--mmproj", "/model/mmproj-model-f16.gguf",
            "--alias", "visual-grounder-v1",
            "--host", "127.0.0.1",
            "--port", "43123",
            "--api-key", "secret-token",
            "--offline",
            "--ctx-size", "8192",
            "--batch-size", "512",
            "--ubatch-size", "128",
            "--threads", "4",
            "--threads-batch", "4",
            "--poll", "0",
            "--poll-batch", "0",
            "--parallel", "1",
            "--no-cont-batching",
            "--image-min-tokens", "256",
            "--image-max-tokens", "256",
            "--mtmd-batch-max-tokens", "256",
            "--cache-ram", "0",
            "--ctx-checkpoints", "0",
            "--no-cache-idle-slots",
            "--jinja",
            "--chat-template", OSAtlasLlamaLaunchConfiguration.officialPhi3ChatTemplate,
            "--temp", "0",
            "--n-predict", "256",
            "--log-disable",
            "--no-webui",
        ])
        XCTAssertEqual(
            configuration.resourceProfile.maximumResidentMemoryBytes,
            8 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(configuration.resourceProfile, .standard)
        XCTAssertEqual(
            OSAtlasLlamaLaunchConfiguration.officialPhi3ChatTemplate,
            "{% for message in messages %}{{ '<|' + message['role'] + '|>\\n' + message['content'] + '<|end|>' }}{% endfor %}{% if add_generation_prompt %}{{ '<|assistant|>\\n' }}{% endif %}")
        XCTAssertFalse(configuration.arguments.contains("--no-jinja"))
        XCTAssertEqual(
            configuration.processEnvironment(inheriting: [
                "PATH": "/usr/bin",
                "LLAMA_ARG_TOOLS": "all",
            ]),
            ["PATH": "/usr/bin"])
    }

    func testRouterPresetAndCompactLaunchPinOneOfflineExplicitWorker() throws {
        let preset = OSAtlasLlamaRouterPreset(
            visualModelFirstSplitURL: URL(
                fileURLWithPath:
                    "/models/visual-Q4_K_M-00001-of-00002.gguf"),
            visualProjectorURL: URL(
                fileURLWithPath: "/models/mmproj-model-f16.gguf"),
            semanticModelURL: URL(
                fileURLWithPath: "/models/semantic-Q4_K_M.gguf"),
            resourceProfile: .compact)
        let presetFile = try OSAtlasLlamaRouterPresetFile.create(preset)
        defer { presetFile.remove() }

        try presetFile.verify()
        XCTAssertTrue(preset.contents.contains("[visual-grounder-v1]"))
        XCTAssertTrue(preset.contents.contains("[semantic-router-v1]"))
        XCTAssertEqual(
            preset.contents.components(separatedBy: "load-on-startup = false")
                .count - 1,
            2)
        XCTAssertTrue(preset.contents.contains("ctx-size = 4096"))
        // Both model sections must opt out of the upstream busy-wait default.
        for setting in ["poll = 0", "poll-batch = 0"] {
            XCTAssertEqual(preset.contents.components(separatedBy: "\n")
                .filter { $0 == setting }.count, 2)
        }
        XCTAssertFalse(preset.contents.contains("hf-repo"))
        XCTAssertFalse(preset.contents.contains("model-url"))

        let configuration = OSAtlasLlamaLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/signed/llama-server"),
            workingDirectoryURL: URL(fileURLWithPath: "/runtime"),
            modelFirstSplitURL: preset.visualModelFirstSplitURL,
            multimodalProjectorURL: preset.visualProjectorURL,
            port: 43123,
            bearerToken: "secret-token",
            resourceProfile: .compact,
            routerPresetFile: presetFile)
        XCTAssertEqual(configuration.arguments, [
            "--host", "127.0.0.1",
            "--port", "43123",
            "--api-key", "secret-token",
            "--models-preset", presetFile.fileURL.path,
            "--models-max", "1",
            "--no-models-autoload",
            "--offline",
            "--log-disable",
            "--no-webui",
        ])
        XCTAssertEqual(OSAtlasLlamaLaunchConfiguration.maximumModelWorkers, 2)
        XCTAssertEqual(configuration.resourceProfile.maximumResidentModelWorkers, 1)
        XCTAssertEqual(configuration.maximumProcessCount, 2)
        XCTAssertEqual(
            OSAtlasLlamaLaunchConfiguration.maximumRouterProcessCount,
            3)
        let environment = configuration.processEnvironment(inheriting: [
            "PATH": "/usr/bin",
            "LLAMA_ARG_TOOLS": "all",
            "LLAMA_ARG_MODELS_AUTOLOAD": "1",
            "GGML_METAL_PATH_RESOURCES": "/attacker",
            "HF_TOKEN": "must-not-be-inherited",
            "HUGGINGFACE_TOKEN": "must-not-be-inherited",
        ])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["LLAMA_ARG_TOOLS"])
        XCTAssertNil(environment["LLAMA_ARG_MODELS_AUTOLOAD"])
        XCTAssertNil(environment["GGML_METAL_PATH_RESOURCES"])
        XCTAssertNil(environment["HF_TOKEN"])
        XCTAssertNil(environment["HUGGINGFACE_TOKEN"])
        XCTAssertEqual(
            environment["LLAMA_CACHE"],
            presetFile.directoryURL
                .appendingPathComponent("cache", isDirectory: true).path)
    }

    func testGeneratedRouterPresetRejectsPostGenerationTampering() throws {
        let presetFile = try OSAtlasLlamaRouterPresetFile.create(
            OSAtlasLlamaRouterPreset(
                visualModelFirstSplitURL: URL(
                    fileURLWithPath:
                        "/models/visual-Q4_K_M-00001-of-00002.gguf"),
                visualProjectorURL: URL(
                    fileURLWithPath: "/models/mmproj-model-f16.gguf"),
                semanticModelURL: URL(
                    fileURLWithPath: "/models/semantic-Q4_K_M.gguf"),
                resourceProfile: .standard))
        defer { presetFile.remove() }

        try Data("version = 1\n[attacker]\nmodel-url = https://example.com/model"
            .utf8).write(to: presetFile.fileURL, options: .atomic)
        XCTAssertThrowsError(try presetFile.verify())
    }

    func testTextTokenBudgetRequestsUseExactB9992TemplateAndTokenizerContract()
        throws {
        let planner = ComputerUseLocalTextGoalPlanner(connection: try ComputerUseTextModelConnection(
            baseURL: URL(string: "http://127.0.0.1:43123")!,
            bearerToken: "unit-test-token-16",
            modelAlias: ComputerUseNativeTextRuntimeInputs.modelAlias))
        let completion = try planner.makeRequest(
            catalog: ComputerUseTextPayloadCatalog("Set Destination to Oslo."),
            fields: [ComputerUseTextField(label: "Destination", snapshot: ComputerUseTextSnapshot(
                targetID: "field-1", value: "", selection: NSRange(location: 0, length: 0),
                isEditable: true, isSecure: false))])
        let template = try OSAtlasLlamaHTTPClient
            .makeSemanticTemplateRequest(from: completion)

        XCTAssertEqual(
            template.url?.absoluteString,
            "http://127.0.0.1:43123/apply-template")
        XCTAssertEqual(template.httpBody, completion.httpBody)
        XCTAssertEqual(
            template.value(forHTTPHeaderField: "Authorization"),
            "Bearer unit-test-token-16")

        let rendered = "<|system|>route<|end|><|assistant|>"
        let templateData = try JSONSerialization.data(withJSONObject: [
            "prompt": rendered,
        ])
        XCTAssertEqual(
            try OSAtlasLlamaHTTPClient.templatePrompt(from: templateData),
            rendered)

        let tokenize = try OSAtlasLlamaHTTPClient.makeTokenizeRequest(
            from: completion,
            templatePrompt: rendered)
        XCTAssertEqual(
            tokenize.url?.absoluteString,
            "http://127.0.0.1:43123/tokenize")
        XCTAssertEqual(
            tokenize.value(forHTTPHeaderField: "Authorization"),
            "Bearer unit-test-token-16")
        let tokenizeBody = try XCTUnwrap(tokenize.httpBody)
        let tokenizeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: tokenizeBody)
                as? [String: Any])
        XCTAssertEqual(
            tokenizeJSON["model"] as? String,
            ComputerUseNativeTextRuntimeInputs.modelAlias)
        XCTAssertEqual(tokenizeJSON["content"] as? String, rendered)
        XCTAssertEqual(tokenizeJSON["add_special"] as? Bool, false)
        XCTAssertEqual(tokenizeJSON["parse_special"] as? Bool, true)
        XCTAssertEqual(tokenizeJSON["with_pieces"] as? Bool, false)
        XCTAssertEqual(
            try OSAtlasLlamaHTTPClient.tokenCount(
                from: Data(#"{"tokens":[1,2,3,4]}"#.utf8)),
            4)
    }

    func testTextTokenBudgetParsersFailClosedOnResponseDrift() throws {
        for value in [
            #"{"prompt":"ok","extra":true}"#,
            #"{"prompt":"","prompt":"duplicate"}"#,
            #"{"prompt":1}"#,
            #"[]"#,
        ] {
            XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.templatePrompt(
                from: Data(value.utf8)), value)
        }
        for value in [
            #"{"tokens":[]}"#,
            #"{"tokens":[1],"extra":true}"#,
            #"{"tokens":[-1]}"#,
            #"{"tokens":[{"id":1}]}"#,
            #"{"tokens":[1],"tokens":[2]}"#,
        ] {
            XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.tokenCount(
                from: Data(value.utf8)), value)
        }
    }

    func testCompactLaunchArgumentsBoundEightGiBRuntimeAllocations() throws {
        let configuration = OSAtlasLlamaLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/signed/llama-server"),
            workingDirectoryURL: URL(fileURLWithPath: "/runtime"),
            modelFirstSplitURL: URL(fileURLWithPath: "/model/pro-Q4_K_M-00001-of-00002.gguf"),
            multimodalProjectorURL: URL(fileURLWithPath: "/model/mmproj-model-f16.gguf"),
            port: 43123,
            bearerToken: "secret-token",
            resourceProfile: .compact)

        func value(after flag: String) throws -> String {
            let index = try XCTUnwrap(configuration.arguments.firstIndex(of: flag))
            return configuration.arguments[index + 1]
        }

        XCTAssertEqual(try value(after: "--ctx-size"), "4096")
        XCTAssertEqual(try value(after: "--batch-size"), "256")
        XCTAssertEqual(try value(after: "--ubatch-size"), "64")
        XCTAssertEqual(
            configuration.resourceProfile.maximumResidentMemoryBytes,
            4 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(
            configuration.resourceProfile.minimumLaunchMemoryBytes,
            3 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(
            configuration.resourceProfile.minimumInferenceMemoryBytes,
            1 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(try value(after: "--parallel"), "1")
        XCTAssertEqual(try value(after: "--poll"), "0")
        XCTAssertEqual(try value(after: "--poll-batch"), "0")
        XCTAssertEqual(try value(after: "--cache-ram"), "0")
        XCTAssertEqual(try value(after: "--ctx-checkpoints"), "0")
    }

    func testResourceProfileSelectionUsesExactHardwareBoundaries() {
        let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

        XCTAssertNil(OSAtlasLlamaResourceProfile.select(
            physicalMemoryBytes: 8 * gibibyte - 1))
        XCTAssertEqual(OSAtlasLlamaResourceProfile.select(
            physicalMemoryBytes: 8 * gibibyte), .compact)
        XCTAssertEqual(
            OSAtlasLlamaResourceProfile.compact.maximumResidentModelWorkers,
            1)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.select(
            physicalMemoryBytes: 16 * gibibyte - 1), .compact)
        XCTAssertEqual(OSAtlasLlamaResourceProfile.select(
            physicalMemoryBytes: 16 * gibibyte), .standard)
        XCTAssertEqual(
            OSAtlasLlamaResourceProfile.standard.maximumResidentModelWorkers,
            2)
    }

    func testResidentMemoryGuardCanInspectAProcessWithoutAllocating() throws {
        let bytes = try XCTUnwrap(OSAtlasProcessMemoryGuard.residentBytes(
            processID: getpid()))
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThan(
            bytes,
            OSAtlasLlamaResourceProfile.standard.maximumResidentMemoryBytes)
    }

    func testProcessTreeLimitAggregatesWorkersAndRejectsThirdWorker() {
        let bounded = OSAtlasProcessTreeSnapshot(
            processIDsChildFirst: [103, 102, 101],
            aggregateResidentMemoryBytes: 3_000)
        XCTAssertFalse(bounded.exceeds(
            maximumResidentMemoryBytes: 3_000,
            maximumProcessCount: 3))
        XCTAssertTrue(bounded.exceeds(
            maximumResidentMemoryBytes: 2_999,
            maximumProcessCount: 3))

        let thirdWorker = OSAtlasProcessTreeSnapshot(
            processIDsChildFirst: [104, 103, 102, 101],
            aggregateResidentMemoryBytes: 3_000)
        XCTAssertTrue(thirdWorker.exceeds(
            maximumResidentMemoryBytes: 4_000,
            maximumProcessCount:
                OSAtlasLlamaLaunchConfiguration.maximumRouterProcessCount))
    }

    func testDarwinProcessTreeInspectorIncludesRootAndAggregateRSS() throws {
        let rootIdentity = try XCTUnwrap(
            DarwinOSAtlasProcessInspector().identity(processID: getpid()))
        let snapshot = try DarwinOSAtlasProcessTreeInspector().snapshot(
            rootProcess: rootIdentity)

        XCTAssertEqual(snapshot.processIDsChildFirst.last, getpid())
        XCTAssertTrue(snapshot.processIDsChildFirst.contains(getpid()))
        XCTAssertGreaterThan(snapshot.aggregateResidentMemoryBytes, 0)
    }

    func testOptInNativeProcessTerminationReleasesItsExactLifetimeLease() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SINGLE_PROCESS_PROBE"] == "1" else {
            throw XCTSkip("Opt in to one task-owned sleeping process; no model is loaded")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-runtime-process-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("sleep-probe")
        // Compile Fixtures/runtime_sleep_probe.c separately, then pass its
        // path explicitly. A private copy confines exact-path cleanup to us.
        let probePath = try XCTUnwrap(ProcessInfo.processInfo.environment["REPAIR_SLEEP_PROBE_BINARY"])
        try FileManager.default.copyItem(at: URL(fileURLWithPath: probePath), to: executable)
        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning { process.terminate() }
            else { try? FileManager.default.removeItem(at: directory) }
        }
        let lease = try await OSAtlasLlamaServerLifetimeLease.acquire(executableURL: executable,
            lockDirectoryURL: directory, retryDelay: .milliseconds(5))
        do { try process.run() }
        catch { lease.release(); throw error }
        let inspector = DarwinOSAtlasProcessInspector()
        let identity = try XCTUnwrap(inspector.identity(processID: process.processIdentifier))
        XCTAssertTrue(process.isRunning)
        let server = FoundationOSAtlasLlamaServerProcess(process: process, rootIdentity: identity,
            executableURL: executable, lifetimeLease: lease,
            maximumResidentMemoryBytes: 128 * 1_024 * 1_024, maximumProcessCount: 1)
        let started = ContinuousClock.now
        await server.terminate()
        try await server.waitUntilExit()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "Shutdown must precede the helper's ten-second natural exit")
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
        XCTAssertEqual(server.workerStopReason, .requested)
        XCTAssertNil(try inspector.identity(processID: identity.processIdentifier))
        let replacement = try await OSAtlasLlamaServerLifetimeLease.acquire(executableURL: executable,
            lockDirectoryURL: directory, retryDelay: .milliseconds(5))
        replacement.release()
    }

    func testOptInNativeMemoryStopRetainsItsCauseThroughCleanup() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SINGLE_PROCESS_PROBE"] == "1" else {
            throw XCTSkip("Opt in to one sleeping process with a one-byte supervisor limit; no model")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("worker-stop-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("sleep-probe")
        let probe = try XCTUnwrap(ProcessInfo.processInfo.environment["REPAIR_SLEEP_PROBE_BINARY"])
        try FileManager.default.copyItem(at: URL(fileURLWithPath: probe), to: executable)
        let process = Process(); process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning { process.terminate() }
            else { try? FileManager.default.removeItem(at: directory) }
        }
        let lease = try await OSAtlasLlamaServerLifetimeLease.acquire(executableURL: executable,
            lockDirectoryURL: directory, retryDelay: .milliseconds(5))
        do { try process.run() } catch { lease.release(); throw error }
        let identity = try XCTUnwrap(DarwinOSAtlasProcessInspector().identity(processID: process.processIdentifier))
        let server = FoundationOSAtlasLlamaServerProcess(process: process, rootIdentity: identity,
            executableURL: executable, lifetimeLease: lease, maximumResidentMemoryBytes: 1, maximumProcessCount: 1)
        for _ in 0..<100 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning, "The supervisor must stop the sleeping process within two seconds")
        let beforeCleanup = server.workerStopReason
        await server.terminate(); try await server.waitUntilExit()
        XCTAssertEqual(server.workerStopReason, beforeCleanup, "Cleanup must preserve the first stop cause")
        guard case .resourceLimit(let bytes, let limit, let processes, let processLimit) = beforeCleanup else {
            return XCTFail("Expected an explicit resource stop, got \(String(describing: beforeCleanup))")
        }
        XCTAssertGreaterThan(bytes, 1); XCTAssertEqual(limit, 1)
        XCTAssertEqual(processes, 1); XCTAssertEqual(processLimit, 1)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        let replacement = try await OSAtlasLlamaServerLifetimeLease.acquire(executableURL: executable,
            lockDirectoryURL: directory, retryDelay: .milliseconds(5))
        replacement.release()
    }

    func testProcessTreeCleanupSignalsChildrenBeforeRouterRoot() throws {
        let inspector = FakeOSAtlasProcessTreeInspector(snapshotValue:
            OSAtlasProcessTreeSnapshot(
                processIDsChildFirst: [203, 202, 201],
                aggregateResidentMemoryBytes: 3_000))
        let controller = OSAtlasProcessTreeController(inspector: inspector)

        try controller.signalTree(
            rootProcess: .synthetic(processIdentifier: 201),
            signal: SIGTERM)

        XCTAssertEqual(inspector.events(), [
            "signal:15:203:root:201",
            "signal:15:202:root:201",
            "signal:15:201:root:201",
        ])
    }

    func testExclusiveProcessReaperAwaitsExactRuntimeBeforeLaunch() async throws {
        let inspector = FakeOSAtlasProcessInspector(
            processIDs: [41],
            exitsOnSignal: SIGTERM)
        let reaper = OSAtlasExclusiveProcessReaper(
            inspector: inspector,
            gracefulAttempts: 1,
            forcedAttempts: 1,
            retryDelay: .zero)

        try await reaper.prepareForExclusiveLaunch(
            executableURL: URL(fileURLWithPath: "/signed/llama-server"))

        XCTAssertEqual(inspector.events(), ["signal:15:41"])
        XCTAssertTrue(inspector.processIDs().isEmpty)
    }

    func testExclusiveProcessReaperFailsClosedWhenRuntimeSurvivesKill() async {
        let inspector = FakeOSAtlasProcessInspector(
            processIDs: [42],
            exitsOnSignal: nil)
        let reaper = OSAtlasExclusiveProcessReaper(
            inspector: inspector,
            gracefulAttempts: 1,
            forcedAttempts: 1,
            retryDelay: .zero)

        do {
            try await reaper.prepareForExclusiveLaunch(
                executableURL: URL(fileURLWithPath: "/signed/llama-server"))
            XCTFail("A second model must not launch while the old runtime survives")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .serverFailedToStart)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(inspector.events(), ["signal:15:42", "signal:9:42"])
    }

    func testIdentityBoundSignalIgnoresReusedPIDForSameExecutable() throws {
        let inspector = FakeOSAtlasProcessInspector(
            processIDs: [43],
            exitsOnSignal: SIGKILL)
        let staleIdentity = try XCTUnwrap(
            inspector.identity(processID: 43))
        inspector.replaceProcessIncarnation(processID: 43)

        try inspector.send(
            signal: SIGKILL,
            to: staleIdentity,
            ifExecutableMatches: URL(
                fileURLWithPath: "/signed/llama-server"))

        XCTAssertEqual(inspector.events(), [])
        XCTAssertEqual(inspector.processIDs(), [43])
    }

    func testLlamaLifetimeLeaseSerializesIndependentHostInstances()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "llama-lifetime-lease-tests-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = URL(
            fileURLWithPath: "/signed/llama-server")
        let first = try await OSAtlasLlamaServerLifetimeLease.acquire(
            executableURL: executableURL,
            lockDirectoryURL: directory,
            retryDelay: .milliseconds(5))
        let state = LockedLeaseAcquisitionState()
        let secondTask = Task {
            state.markStarted()
            let lease = try await OSAtlasLlamaServerLifetimeLease.acquire(
                executableURL: executableURL,
                lockDirectoryURL: directory,
                retryDelay: .milliseconds(5))
            state.markAcquired()
            return lease
        }
        while !state.started() { await Task.yield() }
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertFalse(
            state.acquired(),
            "A peer must not pass orphan reaping while this process owns the lifetime lease")

        first.release()
        let second = try await secondTask.value
        XCTAssertTrue(state.acquired())
        second.release()
    }

    func testWaitQuiescesCancelledMonitorBeforeSamePathLeaseReplacement()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "llama-monitor-lease-tests-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = URL(fileURLWithPath: "/signed/llama-server")
        let lifetimeLease = try await OSAtlasLlamaServerLifetimeLease.acquire(
            executableURL: executableURL,
            lockDirectoryURL: directory,
            retryDelay: .milliseconds(5))
        let staleMonitorInspector = BlockingOSAtlasProcessInspector(
            replacementProcess: .synthetic(processIdentifier: 7_002))
        let staleMonitorReaper = OSAtlasExclusiveProcessReaper(
            inspector: staleMonitorInspector,
            gracefulAttempts: 1,
            forcedAttempts: 1,
            retryDelay: .zero)
        let monitorCompletion = LockedMonitorCompletionState()
        let monitor = Task.detached(priority: .utility) {
            defer { monitorCompletion.markFinished() }
            do {
                try await staleMonitorReaper.prepareForExclusiveLaunch(
                    executableURL: executableURL)
            } catch {
                // Cancellation is the expected teardown path.
            }
        }
        while !staleMonitorInspector.scanStarted() { await Task.yield() }

        let emptyCleanupInspector = FakeOSAtlasProcessInspector(
            processIDs: [],
            exitsOnSignal: nil)
        let server = FoundationOSAtlasLlamaServerProcess(
            process: Process(),
            rootIdentity: .synthetic(processIdentifier: 7_001),
            executableURL: executableURL,
            lifetimeLease: lifetimeLease,
            maximumResidentMemoryBytes: .max,
            maximumProcessCount: Int.max,
            processReaper: OSAtlasExclusiveProcessReaper(
                inspector: emptyCleanupInspector,
                gracefulAttempts: 1,
                forcedAttempts: 1,
                retryDelay: .zero),
            processInspector: emptyCleanupInspector,
            memoryMonitorOverride: monitor)
        let waitTask = Task { try await server.waitUntilExit() }
        while !monitor.isCancelled { await Task.yield() }

        let replacementLeaseState = LockedLeaseAcquisitionState()
        let replacementLeaseTask = Task {
            replacementLeaseState.markStarted()
            let lease = try await OSAtlasLlamaServerLifetimeLease.acquire(
                executableURL: executableURL,
                lockDirectoryURL: directory,
                retryDelay: .milliseconds(5))
            replacementLeaseState.markAcquired()
            return lease
        }
        while !replacementLeaseState.started() { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(replacementLeaseState.acquired())

        // The cancelled monitor was already inside the exact-path scan. Once
        // that scan returns a same-path replacement identity, the post-scan
        // cancellation boundary must prevent every signal. `waitUntilExit`
        // then joins the monitor before releasing the lifetime lease.
        staleMonitorInspector.releaseBlockedScan()
        try await waitTask.value
        let replacementLease = try await replacementLeaseTask.value

        XCTAssertTrue(monitorCompletion.finished())
        XCTAssertTrue(replacementLeaseState.acquired())
        XCTAssertTrue(staleMonitorInspector.events().isEmpty)
        replacementLease.release()
    }

    func testEmergencyReaperKillsRootAndReapsWorkerWhenTreeSignalFails() async throws {
        let treeInspector = FakeOSAtlasProcessTreeInspector(
            snapshotValue: OSAtlasProcessTreeSnapshot(
                processIDsChildFirst: [42, 41],
                aggregateResidentMemoryBytes: 1_024),
            failsSignal: true)
        let workerInspector = FakeOSAtlasProcessInspector(
            processIDs: [42],
            exitsOnSignal: SIGKILL)
        let rootSignals = LockedSignalLog()
        let emergencyReaper = OSAtlasEmergencyProcessReaper(
            processTreeController: OSAtlasProcessTreeController(
                inspector: treeInspector),
            processReaper: OSAtlasExclusiveProcessReaper(
                inspector: workerInspector,
                gracefulAttempts: 1,
                forcedAttempts: 1,
                retryDelay: .zero),
            rootKiller: { process, signal in
                rootSignals.append(
                    processID: process.processIdentifier,
                    signal: signal)
            })

        try await emergencyReaper.killAndReap(
            rootProcess: .synthetic(processIdentifier: 41),
            executableURL: URL(fileURLWithPath: "/signed/llama-server"))

        XCTAssertEqual(rootSignals.values(), ["signal:9:41"])
        XCTAssertEqual(treeInspector.events(), ["signal:9:42:root:41"])
        XCTAssertEqual(workerInspector.events(), ["signal:15:42", "signal:9:42"])
        XCTAssertTrue(workerInspector.processIDs().isEmpty)
    }

    func testActivationStopsAndAwaitsOldProModelBeforeLaunchingReplacement() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transports = FakeTransportMaker(events: events)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: transports,
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)

        _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
        _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro-replacement"))

        let activeVariant = await runtime.activeVariant()
        let recordedEvents = await events.values()
        XCTAssertEqual(activeVariant, .pro4B)
        XCTAssertEqual(recordedEvents, [
            "launch:pro-Q4_K_M-00001-of-00002.gguf",
            "health",
            "cancel-http",
            "terminate:pro-Q4_K_M-00001-of-00002.gguf",
            "wait:pro-Q4_K_M-00001-of-00002.gguf",
            "wait-finished:pro-Q4_K_M-00001-of-00002.gguf",
            "launch:pro-replacement-Q4_K_M-00001-of-00002.gguf",
            "health",
        ])
        await runtime.shutdown()
    }

    func testCancelledReplacementKeepsExactOldServerTeardownInstalledUntilExit()
        async throws {
        let events = RuntimeEventLog()
        let waitGate = CancellationSensitiveProcessWaitGate()
        let launcher = CancellationSensitiveBlockingLlamaLauncher(
            events: events,
            firstProcessWaitGate: waitGate)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)

        _ = try await runtime.activate(inputs(variant: .pro4B, name: "old"))
        let replacementFinished = LockedLifecycleCompletionState()
        let replacement = Task {
            defer { replacementFinished.markFinished() }
            return try await runtime.activate(inputs(
                variant: .pro4B,
                name: "cancelled-replacement"))
        }
        while !waitGate.started() { await Task.yield() }
        replacement.cancel()

        let followupFinished = LockedLifecycleCompletionState()
        let followup = Task {
            defer { followupFinished.markFinished() }
            return try await runtime.activate(inputs(
                variant: .pro4B,
                name: "followup"))
        }
        for _ in 0 ..< 40 {
            _ = await runtime.activeVariant()
            await Task.yield()
        }

        XCTAssertFalse(replacementFinished.finished())
        XCTAssertFalse(followupFinished.finished())
        XCTAssertFalse(waitGate.cancellationWasObserved())
        let launchesWhileBlocked = await launcher.launches()
        XCTAssertEqual(launchesWhileBlocked, 1)

        waitGate.release()
        do {
            _ = try await replacement.value
            XCTFail("The cancelled replacement must not launch")
        } catch is CancellationError {
            // Expected only after exact old-process cleanup has completed.
        } catch {
            XCTFail("Caller cancellation must not poison teardown: \(error)")
        }
        let current = try await followup.value

        XCTAssertEqual(current.variant, .pro4B)
        XCTAssertTrue(replacementFinished.finished())
        XCTAssertTrue(followupFinished.finished())
        let values = await events.values()
        let oldExit = try XCTUnwrap(values.firstIndex(of:
            "wait-finished:old-Q4_K_M-00001-of-00002.gguf"))
        let followupLaunch = try XCTUnwrap(values.firstIndex(of:
            "launch:followup-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertLessThan(oldExit, followupLaunch)
        XCTAssertFalse(values.contains(
            "launch:cancelled-replacement-Q4_K_M-00001-of-00002.gguf"))
        await runtime.shutdown()
    }

    func testCancelledShutdownStillAwaitsExactServerAndDoesNotPoisonRestart()
        async throws {
        let events = RuntimeEventLog()
        let waitGate = CancellationSensitiveProcessWaitGate()
        let launcher = CancellationSensitiveBlockingLlamaLauncher(
            events: events,
            firstProcessWaitGate: waitGate)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)

        _ = try await runtime.activate(inputs(variant: .pro4B, name: "old"))
        let shutdownFinished = LockedLifecycleCompletionState()
        let shutdown = Task {
            defer { shutdownFinished.markFinished() }
            await runtime.shutdown()
        }
        while !waitGate.started() { await Task.yield() }
        shutdown.cancel()
        for _ in 0 ..< 40 {
            _ = await runtime.activeVariant()
            await Task.yield()
        }

        XCTAssertFalse(shutdownFinished.finished())
        XCTAssertFalse(waitGate.cancellationWasObserved())
        let launchesWhileBlocked = await launcher.launches()
        XCTAssertEqual(launchesWhileBlocked, 1)

        waitGate.release()
        await shutdown.value
        XCTAssertTrue(shutdownFinished.finished())
        let variantAfterShutdown = await runtime.activeVariant()
        XCTAssertNil(variantAfterShutdown)

        // Cancellation of the shutdown caller is not a cleanup failure. Once
        // exact exit has been proven, a later explicit activation may proceed.
        _ = try await runtime.activate(inputs(
            variant: .pro4B,
            name: "restart"))
        let values = await events.values()
        let oldExit = try XCTUnwrap(values.firstIndex(of:
            "wait-finished:old-Q4_K_M-00001-of-00002.gguf"))
        let restartLaunch = try XCTUnwrap(values.firstIndex(of:
            "launch:restart-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertLessThan(oldExit, restartLaunch)
        await runtime.shutdown()
    }

    func testCompactCachedActivationChecksOnlyResidentWorker() async throws {
        let events = RuntimeEventLog()
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.compactSufficient)
        let visualInputs = inputs(variant: .pro4B, name: "pro")
        let semanticURL = URL(
            fileURLWithPath: "/models/semantic-Q4_K_M.gguf")

        let original = try await runtime.activateMultiModel(
            visualInputs: visualInputs,
            semanticModelURL: semanticURL)
        let cached = try await runtime.activateMultiModel(
            visualInputs: visualInputs,
            semanticModelURL: semanticURL)

        XCTAssertEqual(cached, original)
        let values = await events.values()
        XCTAssertEqual(values, [
            "launch:pro-Q4_K_M-00001-of-00002.gguf",
            "health",
            "load:visual-grounder-v1",
            "model-health:visual-grounder-v1",
            "unload:visual-grounder-v1",
            "model-health:visual-grounder-v1",
            "load:semantic-router-v1",
            "model-health:semantic-router-v1",
            "unload:semantic-router-v1",
            "model-health:semantic-router-v1",
            "load:visual-grounder-v1",
            "model-health:visual-grounder-v1",
            "health",
            "model-health:visual-grounder-v1",
        ])
        await runtime.shutdown()
    }

    func testMultiModelLoadFailureTearsDownProcessAndPreset() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(
                events: events,
                failingLoadModel: .semanticRouter),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)

        do {
            _ = try await runtime.activateMultiModel(
                visualInputs: inputs(variant: .pro4B, name: "pro"),
                semanticModelURL: URL(
                    fileURLWithPath: "/models/semantic-Q4_K_M.gguf"))
            XCTFail("A failed explicit worker load must fail the endpoint")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let configurations = await launcher.configurations()
        let configuration = try XCTUnwrap(configurations.first)
        let presetURL = try XCTUnwrap(
            configuration.routerPresetFile?.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: presetURL.path))
        let values = await events.values()
        XCTAssertTrue(values.contains("load:visual-grounder-v1"))
        XCTAssertTrue(values.contains("load:semantic-router-v1"))
        XCTAssertTrue(values.contains("cancel-http"))
        XCTAssertTrue(values.contains(
            "terminate:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertTrue(values.contains(
            "wait:pro-Q4_K_M-00001-of-00002.gguf"))
        let activeVariant = await runtime.activeVariant()
        XCTAssertNil(activeVariant)
    }

    func testLateStaleCancelCannotAbortBlockedReplacementOrItsCachedEndpoint()
        async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(
            events: events,
            blockedLaunchNumber: 2)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)
        let oldInputs = inputs(variant: .pro4B, name: "pro")
        let replacementInputs = inputs(
            variant: .pro4B,
            name: "pro-replacement")
        let stale = try await runtime.activate(oldInputs)

        let replacement = Task {
            try await runtime.activate(replacementInputs)
        }
        await launcher.waitUntilFirstLaunchStarted()
        let staleCancel = Task {
            await runtime.cancel(endpoint: stale)
        }
        for _ in 0 ..< 20 { await Task.yield() }

        await launcher.releaseFirstLaunch()
        let current = try await replacement.value
        await staleCancel.value
        let cached = try await runtime.activate(replacementInputs)

        XCTAssertNotEqual(current.generation, stale.generation)
        XCTAssertEqual(cached, current)
        let values = await events.values()
        XCTAssertEqual(
            values.filter {
                $0 == "launch:pro-replacement-Q4_K_M-00001-of-00002.gguf"
            }.count,
            1)
        let activeVariant = await runtime.activeVariant()
        XCTAssertEqual(activeVariant, .pro4B)
        await runtime.shutdown()
    }

    func testReplacementFailsClosedWhenExitedProcessCannotBeReaped()
        async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(
            events: events,
            processWaitFails: true)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)

        _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
        do {
            _ = try await runtime.activate(inputs(
                variant: .pro4B,
                name: "replacement"))
            XCTFail("A replacement must not launch after cleanup failed")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .serverFailedToStart)
        }

        let values = await events.values()
        XCTAssertTrue(values.contains(
            "wait:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertFalse(values.contains(
            "launch:replacement-Q4_K_M-00001-of-00002.gguf"))
        let activeVariant = await runtime.activeVariant()
        XCTAssertNil(activeVariant)

        do {
            _ = try await runtime.activate(inputs(
                variant: .pro4B,
                name: "retry-after-poison"))
            XCTFail("A cleanup-poisoned runtime must not launch again")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .serverFailedToStart)
        }
        let finalValues = await events.values()
        XCTAssertFalse(finalValues.contains(
            "launch:retry-after-poison-Q4_K_M-00001-of-00002.gguf"))
    }

    func testActivationRestartsCachedServerWhenItsHealthEndpointDied() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transports = FakeTransportMaker(
            events: events,
            healthResponses: [true, false, false, false, true])
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: transports,
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)
        let proInputs = inputs(variant: .pro4B, name: "pro")

        let original = try await runtime.activate(proInputs)
        let recovered = try await runtime.activate(proInputs)
        let recordedEvents = await events.values()

        XCTAssertNotEqual(original.generation, recovered.generation)
        XCTAssertEqual(recordedEvents, [
            "launch:pro-Q4_K_M-00001-of-00002.gguf",
            "health",
            "health",
            "health",
            "health",
            "cancel-http",
            "terminate:pro-Q4_K_M-00001-of-00002.gguf",
            "wait:pro-Q4_K_M-00001-of-00002.gguf",
            "wait-finished:pro-Q4_K_M-00001-of-00002.gguf",
            "launch:pro-Q4_K_M-00001-of-00002.gguf",
            "health",
        ])
        await runtime.shutdown()
    }

    func testShutdownInvalidatesBlockedCachedHealthBeforeItCanRelaunch() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transports = FakeTransportMaker(
            events: events,
            healthResponses: [true],
            blockedHealthCall: 2)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: transports,
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)
        let proInputs = inputs(variant: .pro4B, name: "pro")

        _ = try await runtime.activate(proInputs)
        let staleActivation = Task {
            try await runtime.activate(proInputs)
        }
        await transports.waitUntilBlockedHealthStarted()

        // The transport deliberately ignores task cancellation while its
        // cached health response is blocked. Shutdown must still complete and
        // invalidate that activation before the response is allowed to resume.
        await runtime.shutdown()
        let variantAfterShutdown = await runtime.activeVariant()
        let valuesAfterShutdown = await events.values()
        XCTAssertNil(variantAfterShutdown)
        XCTAssertEqual(
            valuesAfterShutdown.filter { $0.hasPrefix("launch:") }.count,
            1)

        transports.releaseBlockedHealth(returning: false)
        do {
            _ = try await staleActivation.value
            XCTFail("A pre-shutdown activation must be cancelled")
        } catch is CancellationError {
            // Expected: the old lifecycle epoch cannot launch a replacement.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        let values = await events.values()
        XCTAssertEqual(values.filter { $0.hasPrefix("launch:") }.count, 1)
        XCTAssertTrue(values.contains("cancel-http"))
        XCTAssertTrue(values.contains("terminate:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertTrue(values.contains("wait:pro-Q4_K_M-00001-of-00002.gguf"))
        let finalVariant = await runtime.activeVariant()
        XCTAssertNil(finalVariant)
    }

    func testConcurrentProModelActivationCannotOverlapLaunches() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events, blocksFirstLaunch: true)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)

        let proActivation = Task {
            try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
        }
        await launcher.waitUntilFirstLaunchStarted()
        let replacementActivation = Task {
            try await runtime.activate(inputs(
                variant: .pro4B,
                name: "pro-replacement"))
        }
        for _ in 0 ..< 20 { await Task.yield() }
        let eventsBeforeRelease = await events.values()
        XCTAssertEqual(eventsBeforeRelease, [
            "launch:pro-Q4_K_M-00001-of-00002.gguf",
        ])

        await launcher.releaseFirstLaunch()
        _ = try? await proActivation.value
        _ = try await replacementActivation.value

        let values = await events.values()
        let proLaunch = try XCTUnwrap(values.firstIndex(of:
            "launch:pro-Q4_K_M-00001-of-00002.gguf"))
        let proWait = try XCTUnwrap(values.firstIndex(of:
            "wait:pro-Q4_K_M-00001-of-00002.gguf"))
        let replacementLaunch = try XCTUnwrap(values.firstIndex(of:
            "launch:pro-replacement-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertLessThan(proLaunch, proWait)
        XCTAssertLessThan(proWait, replacementLaunch)
        await runtime.shutdown()
    }

    func testBaseModelIsRejectedBeforeAnyLaunch() async throws {
        let events = RuntimeEventLog()
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero)

        do {
            _ = try await runtime.activate(inputs(variant: .base4B, name: "base"))
            XCTFail("Base must not be activated by the production runtime")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .proModelRequired)
        }
        let values = await events.values()
        let activeVariant = await runtime.activeVariant()
        XCTAssertTrue(values.isEmpty)
        XCTAssertNil(activeVariant)
    }

    func testCancellationStopsGenerationAndModelProcess() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let transports = FakeTransportMaker(events: events, blocksCompletion: true)
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: transports,
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)
        let endpoint = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))

        let completion = Task {
            try await runtime.complete(
                endpoint: endpoint,
                prompt: "private task text<image>private task suffix",
                jpegData: try makeTestJPEG(width: 32, height: 24))
        }
        await transports.waitUntilCompletionStarted()
        await runtime.cancel(endpoint: endpoint)

        do {
            _ = try await completion.value
            XCTFail("Completion should be cancelled")
        } catch {
            // Cancellation or inactive-session is expected depending on which
            // side of URLSession teardown resumes first.
        }
        let values = await events.values()
        XCTAssertTrue(values.contains("cancel-http"))
        XCTAssertTrue(values.contains("terminate:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertTrue(values.contains("wait:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertFalse(values.contains(where: { $0.contains("private task text") }))
        let activeVariant = await runtime.activeVariant()
        XCTAssertNil(activeVariant)
    }

    func testWorkerStopReportRemainsBoundToItsGenerationAndSurvivesRepeatedShutdown() async throws {
        let events = RuntimeEventLog()
        let reason = OSAtlasLlamaWorkerStopReason.resourceLimit(observedBytes: 1001, limitBytes: 1000,
            observedProcesses: 1, limitProcesses: 1)
        let runtime = OSAtlasLlamaRuntime(launcher: FakeLlamaLauncher(events: events, processStopReasons: [reason, nil]),
            transportMaker: FakeTransportMaker(events: events), portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"), readinessAttempts: 1, readinessDelay: .zero,
            resourceInspector: FixedResourceInspector.sufficient)
        let first = try await runtime.activate(inputs(variant: .pro4B, name: "first"))
        await runtime.shutdown()
        let firstReport = await runtime.lastWorkerStop
        XCTAssertEqual(firstReport, .init(generation: first.generation, reason: reason, cleanupSucceeded: true))
        await runtime.shutdown()
        let repeated = await runtime.lastWorkerStop
        XCTAssertEqual(repeated, firstReport)
        let second = try await runtime.activate(inputs(variant: .pro4B, name: "second"))
        await runtime.cancel(endpoint: first)
        let afterStaleCancellation = await runtime.lastWorkerStop
        XCTAssertEqual(afterStaleCancellation, firstReport)
        await runtime.shutdown()
        let secondReport = await runtime.lastWorkerStop
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertEqual(secondReport, .init(generation: second.generation, reason: nil, cleanupSucceeded: true),
            "An unavailable cause for the new worker cannot inherit the old worker's resource failure")
    }

    func testActivationFailsClosedBeforeLaunchBelowEightGiB() async {
        let events = RuntimeEventLog()
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector(
                snapshotValue: OSAtlasLlamaResourceSnapshot(
                    physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024 - 1,
                    reclaimableMemoryBytes: .max)))

        do {
            _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
            XCTFail("An unsupported Mac must not launch llama-server")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .insufficientPhysicalMemory)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let values = await events.values()
        XCTAssertTrue(values.isEmpty)
    }

    func testEightGiBActivationFailsBeforeLaunchWithoutCompactHeadroom() async {
        let events = RuntimeEventLog()
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: FixedResourceInspector(
                snapshotValue: OSAtlasLlamaResourceSnapshot(
                    physicalMemoryBytes:
                        OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes,
                    reclaimableMemoryBytes:
                        OSAtlasLlamaResourceProfile.compact.minimumLaunchMemoryBytes - 1)))

        do {
            _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
            XCTFail("Compact setup must not launch without its measured headroom")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .insufficientAvailableMemory)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let values = await events.values()
        XCTAssertTrue(values.isEmpty)
    }

    func testEightGiBActivationStopsAfterLoadWithoutCompactInferenceHeadroom() async {
        let events = RuntimeEventLog()
        let resources = SequenceResourceInspector(snapshots: [
            OSAtlasLlamaResourceSnapshot(
                physicalMemoryBytes:
                    OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes,
                reclaimableMemoryBytes:
                    OSAtlasLlamaResourceProfile.compact.minimumLaunchMemoryBytes),
            OSAtlasLlamaResourceSnapshot(
                physicalMemoryBytes:
                    OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes,
                reclaimableMemoryBytes:
                    OSAtlasLlamaResourceProfile.compact.minimumInferenceMemoryBytes - 1),
        ])
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: resources)

        do {
            _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
            XCTFail("Compact setup must not report ready without inference headroom")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .insufficientAvailableMemory)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let values = await events.values()
        XCTAssertTrue(values.contains("health"))
        XCTAssertTrue(values.contains("cancel-http"))
        XCTAssertTrue(values.contains(
            "terminate:pro-Q4_K_M-00001-of-00002.gguf"))
        let activeVariant = await runtime.activeVariant()
        XCTAssertNil(activeVariant)
    }

    func testActivationRechecksHeadroomAfterModelBecomesResident() async {
        let events = RuntimeEventLog()
        let resources = SequenceResourceInspector(snapshots: [
            FixedResourceInspector.sufficient.snapshotValue,
            OSAtlasLlamaResourceSnapshot(
                physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                reclaimableMemoryBytes: 1 * 1_024 * 1_024 * 1_024),
        ])
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: resources)

        do {
            _ = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))
            XCTFail("Setup must not report ready without inference headroom")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .insufficientAvailableMemory)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let values = await events.values()
        XCTAssertTrue(values.contains("health"))
        XCTAssertTrue(values.contains("cancel-http"))
        XCTAssertTrue(values.contains("terminate:pro-Q4_K_M-00001-of-00002.gguf"))
        let activeVariant = await runtime.activeVariant()
        XCTAssertNil(activeVariant)
    }

    func testActivationAcceptsBoundedPostLoadInferenceHeadroom() async throws {
        let events = RuntimeEventLog()
        let launcher = FakeLlamaLauncher(events: events)
        let resources = SequenceResourceInspector(snapshots: [
            OSAtlasLlamaResourceSnapshot(
                physicalMemoryBytes:
                    OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes,
                reclaimableMemoryBytes:
                    OSAtlasLlamaResourceProfile.compact.minimumLaunchMemoryBytes),
            OSAtlasLlamaResourceSnapshot(
                physicalMemoryBytes:
                    OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes,
                reclaimableMemoryBytes:
                    OSAtlasLlamaResourceProfile.compact.minimumInferenceMemoryBytes),
        ])
        let runtime = OSAtlasLlamaRuntime(
            launcher: launcher,
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: resources)

        let endpoint = try await runtime.activate(
            inputs(variant: .pro4B, name: "pro"))
        let activeVariant = await runtime.activeVariant()

        XCTAssertEqual(endpoint.variant, .pro4B)
        XCTAssertEqual(activeVariant, .pro4B)
        XCTAssertEqual(
            OSAtlasLlamaResourceProfile.compact.minimumInferenceMemoryBytes,
            1 * 1_024 * 1_024 * 1_024)
        let configurations = await launcher.configurations()
        XCTAssertEqual(configurations.count, 1)
        XCTAssertEqual(configurations.first?.resourceProfile, .compact)
        XCTAssertEqual(configurations.first?.resourceProfile.contextSize, 4_096)
        await runtime.shutdown()
        let values = await events.values()
        XCTAssertTrue(values.contains("health"))
        XCTAssertTrue(values.contains("terminate:pro-Q4_K_M-00001-of-00002.gguf"))
    }

    func testInferenceMemoryPressureStopsResidentModelBeforeHTTP() async throws {
        let events = RuntimeEventLog()
        let resources = SequenceResourceInspector(snapshots: [
            FixedResourceInspector.sufficient.snapshotValue,
            FixedResourceInspector.sufficient.snapshotValue,
            OSAtlasLlamaResourceSnapshot(
                physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                reclaimableMemoryBytes: 1 * 1_024 * 1_024 * 1_024),
        ])
        let runtime = OSAtlasLlamaRuntime(
            launcher: FakeLlamaLauncher(events: events),
            transportMaker: FakeTransportMaker(events: events),
            portProvider: FixedPortProvider(port: 43123),
            tokenProvider: FixedTokenProvider(token: "token"),
            readinessAttempts: 1,
            readinessDelay: .zero,
            resourceInspector: resources)
        let endpoint = try await runtime.activate(inputs(variant: .pro4B, name: "pro"))

        do {
            _ = try await runtime.complete(
                endpoint: endpoint,
                prompt: "safe local prompt<image>safe local suffix",
                jpegData: try makeTestJPEG(width: 32, height: 24))
            XCTFail("Inference must fail closed under memory pressure")
        } catch let error as OSAtlasLlamaRuntimeError {
            XCTAssertEqual(error, .insufficientAvailableMemory)
        }

        let values = await events.values()
        XCTAssertTrue(values.contains("cancel-http"))
        XCTAssertTrue(values.contains("terminate:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertTrue(values.contains("wait:pro-Q4_K_M-00001-of-00002.gguf"))
        XCTAssertFalse(values.contains("complete"))
        let activeVariant = await runtime.activeVariant()
        XCTAssertNil(activeVariant)
    }

    func testResponseRequiresExactlyOneChoice() throws {
        let valid = Data(#"{"choices":[{"message":{"content":"Actions:\nWAIT"}}]}"#.utf8)
        XCTAssertEqual(
            try OSAtlasLlamaHTTPClient.responseText(from: valid),
            "Actions:\nWAIT")
        let multiple = Data(#"{"choices":[{"message":{"content":"WAIT"}},{"message":{"content":"WAIT"}}]}"#.utf8)
        XCTAssertThrowsError(try OSAtlasLlamaHTTPClient.responseText(from: multiple))
    }

    private func inputs(
        variant: OSAtlasModelVariant,
        name: String
    ) -> OSAtlasLlamaRuntimeInputs {
        OSAtlasLlamaRuntimeInputs(
            variant: variant,
            modelFirstSplitURL: URL(
                fileURLWithPath: "/models/\(name)-Q4_K_M-00001-of-00002.gguf"),
            multimodalProjectorURL: URL(
                fileURLWithPath: "/models/\(name)-mmproj-model-f16.gguf"),
            llamaServerURL: URL(fileURLWithPath: "/app/Contents/Helpers/llama-server"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/app/Contents/Helpers"))
    }
}

private actor RuntimeEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private final class FakeOSAtlasProcessInspector: OSAtlasProcessInspecting,
    @unchecked Sendable {
    private let lock = NSLock()
    private let exitsOnSignal: Int32?
    private var runningProcesses: Set<OSAtlasProcessIdentity>
    private var recordedEvents: [String] = []

    init(processIDs: Set<pid_t>, exitsOnSignal: Int32?) {
        runningProcesses = Set(processIDs.map {
            .synthetic(processIdentifier: $0)
        })
        self.exitsOnSignal = exitsOnSignal
    }

    func identity(processID: pid_t) throws -> OSAtlasProcessIdentity? {
        lock.withLock {
            runningProcesses.first {
                $0.processIdentifier == processID
            }
        }
    }

    func matchingProcesses(
        for executableURL: URL
    ) throws -> [OSAtlasProcessIdentity] {
        lock.withLock {
            runningProcesses.sorted {
                $0.processIdentifier < $1.processIdentifier
            }
        }
    }

    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifExecutableMatches executableURL: URL
    ) throws {
        lock.withLock {
            guard runningProcesses.contains(process) else { return }
            recordedEvents.append(
                "signal:\(signalNumber):\(process.processIdentifier)")
            if exitsOnSignal == signalNumber {
                runningProcesses.remove(process)
            }
        }
    }

    func events() -> [String] {
        lock.withLock { recordedEvents }
    }

    func processIDs() -> [pid_t] {
        lock.withLock {
            runningProcesses.map(\.processIdentifier).sorted()
        }
    }

    func replaceProcessIncarnation(processID: pid_t) {
        lock.withLock {
            guard let previous = runningProcesses.first(where: {
                $0.processIdentifier == processID
            }) else { return }
            runningProcesses.remove(previous)
            runningProcesses.insert(OSAtlasProcessIdentity(
                processIdentifier: processID,
                canonicalExecutablePath: previous.canonicalExecutablePath,
                startTimeSeconds: previous.startTimeSeconds + 1,
                startTimeMicroseconds: previous.startTimeMicroseconds,
                effectiveUserIdentifier:
                    previous.effectiveUserIdentifier,
                realUserIdentifier: previous.realUserIdentifier))
        }
    }
}

private final class BlockingOSAtlasProcessInspector: OSAtlasProcessInspecting,
    @unchecked Sendable {
    private let condition = NSCondition()
    private let replacementProcess: OSAtlasProcessIdentity
    private var didStartScan = false
    private var shouldReleaseScan = false
    private var recordedEvents: [String] = []

    init(replacementProcess: OSAtlasProcessIdentity) {
        self.replacementProcess = replacementProcess
    }

    func identity(processID: pid_t) throws -> OSAtlasProcessIdentity? {
        processID == replacementProcess.processIdentifier
            ? replacementProcess : nil
    }

    func matchingProcesses(
        for executableURL: URL
    ) throws -> [OSAtlasProcessIdentity] {
        condition.lock()
        didStartScan = true
        condition.broadcast()
        while !shouldReleaseScan { condition.wait() }
        condition.unlock()
        return [replacementProcess]
    }

    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifExecutableMatches executableURL: URL
    ) throws {
        condition.withLock {
            recordedEvents.append(
                "signal:\(signalNumber):\(process.processIdentifier)")
        }
    }

    func scanStarted() -> Bool {
        condition.withLock { didStartScan }
    }

    func releaseBlockedScan() {
        condition.withLock {
            shouldReleaseScan = true
            condition.broadcast()
        }
    }

    func events() -> [String] {
        condition.withLock { recordedEvents }
    }
}

private final class LockedMonitorCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func markFinished() {
        lock.withLock { didFinish = true }
    }

    func finished() -> Bool {
        lock.withLock { didFinish }
    }
}

private final class FakeOSAtlasProcessTreeInspector:
    OSAtlasProcessTreeInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshotValue: OSAtlasProcessTreeSnapshot
    private let failsSignal: Bool
    private var recordedEvents: [String] = []

    init(
        snapshotValue: OSAtlasProcessTreeSnapshot,
        failsSignal: Bool = false
    ) {
        self.snapshotValue = snapshotValue
        self.failsSignal = failsSignal
    }

    func snapshot(
        rootProcess: OSAtlasProcessIdentity
    ) throws -> OSAtlasProcessTreeSnapshot {
        snapshotValue
    }

    func send(
        signal signalNumber: Int32,
        to process: OSAtlasProcessIdentity,
        ifMemberOfTreeRoot rootProcess: OSAtlasProcessIdentity
    ) throws {
        try lock.withLock {
            recordedEvents.append(
                "signal:\(signalNumber):\(process.processIdentifier):root:\(rootProcess.processIdentifier)")
            if failsSignal {
                throw OSAtlasLlamaRuntimeError.serverFailedToStart
            }
        }
    }

    func events() -> [String] {
        lock.withLock { recordedEvents }
    }
}

private final class LockedSignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [String] = []

    func append(processID: pid_t, signal: Int32) {
        lock.withLock {
            signals.append("signal:\(signal):\(processID)")
        }
    }

    func values() -> [String] {
        lock.withLock { signals }
    }
}

private final class LockedLeaseAcquisitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didAcquire = false

    func markStarted() {
        lock.withLock { didStart = true }
    }

    func markAcquired() {
        lock.withLock { didAcquire = true }
    }

    func started() -> Bool {
        lock.withLock { didStart }
    }

    func acquired() -> Bool {
        lock.withLock { didAcquire }
    }
}

private final class LockedSemanticRecaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var routes = 0
    private var application = "Notes"

    func recordRoute() {
        lock.withLock {
            routes += 1
            if routes == 1 { application = "Calendar" }
        }
    }

    func routeCount() -> Int {
        lock.withLock { routes }
    }

    func frontmostApplication() -> String {
        lock.withLock { application }
    }
}

private final class LockedFocusedTypingTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var focused = false
    private var routes = 0
    private var caretFrames = 0
    private var editableChecks = 0
    private var performedActions: [ComputerUsePredictedAction] = []

    func nextRoute() -> OSAtlasSemanticActionRoute {
        lock.withLock {
            routes += 1
            if focused {
                return OSAtlasSemanticActionRoute(
                    directive: .type,
                    argument: .text("local pizza"))
            }
            return OSAtlasSemanticActionRoute(
                directive: .click,
                argument: .targetHint("Search"))
        }
    }

    func record(action: ComputerUsePredictedAction) {
        lock.withLock {
            performedActions.append(action)
            if case .click = action { focused = true }
        }
    }

    func nextCaretFrameIsOn() -> Bool? {
        lock.withLock {
            guard focused else { return nil }
            caretFrames += 1
            return caretFrames.isMultiple(of: 2)
        }
    }

    func context(for action: ComputerUsePredictedAction) -> String {
        lock.withLock {
            if case .typeText = action {
                editableChecks += 1
                return "AXSearchField • focused • editable=true"
            }
            return "AXButton • Search"
        }
    }

    func isFocused() -> Bool { lock.withLock { focused } }
    func routeCount() -> Int { lock.withLock { routes } }
    func caretFrameCount() -> Int { lock.withLock { caretFrames } }
    func editableCheckCount() -> Int { lock.withLock { editableChecks } }
    func actions() -> [ComputerUsePredictedAction] {
        lock.withLock { performedActions }
    }
}

private final class LockedSubmittedSearchAnswerTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var routes = 0
    private var submitted = false
    private var caretFrames = 0
    private var performedActions: [ComputerUsePredictedAction] = []

    func nextRoute(answer: String, prematureTerminal: Bool = false) -> OSAtlasSemanticActionRoute {
        lock.withLock {
            routes += 1
            if prematureTerminal {
                return .init(directive: .answer, argument: .visibleAnswer(
                    summary: answer, evidence: [answer]))
            }
            switch routes {
            case 1:
                return OSAtlasSemanticActionRoute(
                    directive: .type,
                    argument: .text("downtown branch hours"))
            case 2:
                return OSAtlasSemanticActionRoute(directive: .enter)
            default:
                return OSAtlasSemanticActionRoute(
                    directive: .answer,
                    argument: .visibleAnswer(
                        summary: answer,
                        evidence: [answer]))
            }
        }
    }

    func record(action: ComputerUsePredictedAction) {
        lock.withLock {
            performedActions.append(action)
            if action == .key(usage: 0x28, modifiers: 0) {
                submitted = true
            }
        }
    }

    func hasSubmitted() -> Bool { lock.withLock { submitted } }

    func nextCaretFrameIsOn() -> Bool {
        lock.withLock {
            caretFrames += 1
            return caretFrames.isMultiple(of: 2)
        }
    }

    func routeCount() -> Int { lock.withLock { routes } }
    func caretFrameCount() -> Int { lock.withLock { caretFrames } }
    func actions() -> [ComputerUsePredictedAction] {
        lock.withLock { performedActions }
    }
}

private final class LockedPlanningRetryResetTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var performedActions: [ComputerUsePredictedAction] = []
    private var routeAwaitingCapture = false
    private var retriesRemaining: [Int]
    private var routes = 0

    init(retriesPerSegment: Int) {
        retriesRemaining = [retriesPerSegment, retriesPerSegment]
    }

    func nextRoute() -> OSAtlasSemanticActionRoute {
        lock.withLock {
            routes += 1
            routeAwaitingCapture = true
            return OSAtlasSemanticActionRoute(
                directive: .click,
                argument: .targetHint(
                    performedActions.isEmpty ? "First" : "Second"))
        }
    }

    func record(action: ComputerUsePredictedAction) {
        lock.withLock { performedActions.append(action) }
    }

    func shouldUseChangedFrame() -> Bool {
        lock.withLock {
            let segment = min(performedActions.count, 1)
            defer { routeAwaitingCapture = false }
            guard routeAwaitingCapture,
                  retriesRemaining[segment] > 0 else { return false }
            retriesRemaining[segment] -= 1
            return true
        }
    }

    func context() -> String {
        lock.withLock {
            performedActions.isEmpty
                ? "AXButton • First" : "AXButton • Second"
        }
    }

    func actions() -> [ComputerUsePredictedAction] {
        lock.withLock { performedActions }
    }

    func remainingRetries() -> [Int] { lock.withLock { retriesRemaining } }
    func routeCount() -> Int { lock.withLock { routes } }
}

private final class LockedLifecycleCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func markFinished() {
        lock.withLock { didFinish = true }
    }

    func finished() -> Bool {
        lock.withLock { didFinish }
    }
}

/// A process wait that blocks until explicitly released but aborts immediately
/// if the task performing cleanup is cancelled. It makes lifecycle-cancellation
/// leaks deterministic instead of relying on Process timing.
private final class CancellationSensitiveProcessWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didRelease = false
    private var didObserveCancellation = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var resumeSuccessfully = false
                var resumeWithCancellation = false
                lock.lock()
                didStart = true
                if didRelease {
                    resumeSuccessfully = true
                } else if didObserveCancellation {
                    resumeWithCancellation = true
                } else {
                    self.continuation = continuation
                }
                lock.unlock()
                if resumeSuccessfully {
                    continuation.resume()
                } else if resumeWithCancellation {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () ->
                CheckedContinuation<Void, Error>? in
                self.didObserveCancellation = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func started() -> Bool {
        lock.withLock { didStart }
    }

    func cancellationWasObserved() -> Bool {
        lock.withLock { didObserveCancellation }
    }

    func release() {
        let continuation = lock.withLock { () ->
            CheckedContinuation<Void, Error>? in
            didRelease = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private actor CancellationSensitiveBlockingLlamaLauncher:
    OSAtlasLlamaServerLaunching {
    private let events: RuntimeEventLog
    private let firstProcessWaitGate: CancellationSensitiveProcessWaitGate
    private var launchCount = 0

    init(
        events: RuntimeEventLog,
        firstProcessWaitGate: CancellationSensitiveProcessWaitGate
    ) {
        self.events = events
        self.firstProcessWaitGate = firstProcessWaitGate
    }

    func launch(
        configuration: OSAtlasLlamaLaunchConfiguration
    ) async throws -> any OSAtlasLlamaServerProcess {
        launchCount += 1
        let name = configuration.modelFirstSplitURL.lastPathComponent
        await events.append("launch:\(name)")
        return CancellationSensitiveBlockingLlamaProcess(
            name: name,
            events: events,
            waitGate: launchCount == 1 ? firstProcessWaitGate : nil)
    }

    func launches() -> Int {
        launchCount
    }
}

private final class CancellationSensitiveBlockingLlamaProcess:
    OSAtlasLlamaServerProcess, @unchecked Sendable {
    private let name: String
    private let events: RuntimeEventLog
    private let waitGate: CancellationSensitiveProcessWaitGate?

    init(
        name: String,
        events: RuntimeEventLog,
        waitGate: CancellationSensitiveProcessWaitGate?
    ) {
        self.name = name
        self.events = events
        self.waitGate = waitGate
    }

    func terminate() async {
        await events.append("terminate:\(name)")
    }

    func waitUntilExit() async throws {
        await events.append("wait:\(name)")
        try await waitGate?.wait()
        await events.append("wait-finished:\(name)")
    }
}

private actor FakeLlamaLauncher: OSAtlasLlamaServerLaunching {
    let events: RuntimeEventLog
    let blockedLaunchNumber: Int?
    let processWaitFails: Bool
    let processStopReasons: [OSAtlasLlamaWorkerStopReason?]
    private var launchCount = 0
    private var launchedConfigurations: [OSAtlasLlamaLaunchConfiguration] = []
    private var firstLaunchStarted = false
    private var firstLaunchContinuation: CheckedContinuation<Void, Never>?

    init(
        events: RuntimeEventLog,
        blocksFirstLaunch: Bool = false,
        blockedLaunchNumber: Int? = nil,
        processWaitFails: Bool = false,
        processStopReasons: [OSAtlasLlamaWorkerStopReason?] = []
    ) {
        self.events = events
        self.blockedLaunchNumber = blockedLaunchNumber
            ?? (blocksFirstLaunch ? 1 : nil)
        self.processWaitFails = processWaitFails
        self.processStopReasons = processStopReasons
    }

    func launch(
        configuration: OSAtlasLlamaLaunchConfiguration
    ) async throws -> any OSAtlasLlamaServerProcess {
        let name = configuration.modelFirstSplitURL.lastPathComponent
        launchedConfigurations.append(configuration)
        await events.append("launch:\(name)")
        launchCount += 1
        if blockedLaunchNumber == launchCount {
            firstLaunchStarted = true
            await withCheckedContinuation { continuation in
                firstLaunchContinuation = continuation
            }
        }
        return FakeLlamaProcess(
            name: name,
            events: events,
            waitFails: processWaitFails,
            workerStopReason: processStopReasons.indices.contains(launchCount - 1) ? processStopReasons[launchCount - 1] : nil)
    }

    func waitUntilFirstLaunchStarted() async {
        while !firstLaunchStarted { await Task.yield() }
    }

    func releaseFirstLaunch() {
        firstLaunchContinuation?.resume()
        firstLaunchContinuation = nil
    }

    func configurations() -> [OSAtlasLlamaLaunchConfiguration] {
        launchedConfigurations
    }
}

private actor FakeLlamaProcess: OSAtlasLlamaServerProcess {
    let name: String
    let events: RuntimeEventLog
    let waitFails: Bool
    nonisolated let workerStopReason: OSAtlasLlamaWorkerStopReason?

    init(
        name: String,
        events: RuntimeEventLog,
        waitFails: Bool = false,
        workerStopReason: OSAtlasLlamaWorkerStopReason? = nil
    ) {
        self.name = name
        self.events = events
        self.waitFails = waitFails
        self.workerStopReason = workerStopReason
    }

    func terminate() async {
        await events.append("terminate:\(name)")
    }

    func waitUntilExit() async throws {
        await events.append("wait:\(name)")
        if waitFails {
            throw OSAtlasLlamaRuntimeError.serverFailedToStart
        }
        await events.append("wait-finished:\(name)")
    }
}

private final class FakeTransportMaker: OSAtlasLlamaHTTPTransportMaking,
    @unchecked Sendable {
    private let events: RuntimeEventLog
    private let blocksCompletion: Bool
    private let blockedHealthCall: Int?
    private let condition = NSCondition()
    private var healthResponses: [Bool]
    private var healthCallCount = 0
    private var blockedHealthStarted = false
    private var blockedHealthContinuation: CheckedContinuation<Bool, Never>?
    private var earlyBlockedHealthResponse: Bool?
    private var completionStarted = false
    private var completionCallCount = 0
    private let blockedCompletionCall: Int?
    private var completionContinuation: CheckedContinuation<Data, Error>?
    private var completionResponses: [String]
    private var completionDataResponses: [Data]?
    private var inputTokenCounts: [Int]
    private var tokenCountRequests: [URLRequest] = []
    private var completionRequests: [URLRequest] = []
    private let failingLoadModel: OSAtlasLlamaServedModel?
    private let failingUnloadModel: OSAtlasLlamaServedModel?
    private let failingLoadOccurrence: Int
    private let failingUnloadOccurrence: Int
    private var modelLoadCounts: [OSAtlasLlamaServedModel: Int] = [:]
    private var modelUnloadCounts: [OSAtlasLlamaServedModel: Int] = [:]
    private let failsCompletion: Bool
    private var loadedModels: Set<OSAtlasLlamaServedModel> = []

    init(
        events: RuntimeEventLog,
        blocksCompletion: Bool = false,
        blockedCompletionCall: Int? = nil,
        healthResponses: [Bool] = [true],
        blockedHealthCall: Int? = nil,
        failingLoadModel: OSAtlasLlamaServedModel? = nil,
        failingUnloadModel: OSAtlasLlamaServedModel? = nil,
        failingLoadOccurrence: Int = 1,
        failingUnloadOccurrence: Int = 1,
        failsCompletion: Bool = false,
        completionResponses: [String] = [
            "Thoughts:\nwait\nActions:\nWAIT",
        ],
        completionDataResponses: [Data]? = nil,
        inputTokenCounts: [Int] = [1]
    ) {
        precondition(!healthResponses.isEmpty)
        precondition(!completionResponses.isEmpty)
        precondition(completionDataResponses?.isEmpty != true)
        precondition(!inputTokenCounts.isEmpty)
        precondition(inputTokenCounts.allSatisfy { $0 > 0 })
        self.events = events
        self.blocksCompletion = blocksCompletion
        self.blockedCompletionCall = blockedCompletionCall
        self.healthResponses = healthResponses
        self.blockedHealthCall = blockedHealthCall
        self.failingLoadModel = failingLoadModel
        self.failingUnloadModel = failingUnloadModel
        self.failingLoadOccurrence = max(1, failingLoadOccurrence)
        self.failingUnloadOccurrence = max(1, failingUnloadOccurrence)
        self.failsCompletion = failsCompletion
        self.completionResponses = completionResponses
        self.completionDataResponses = completionDataResponses
        self.inputTokenCounts = inputTokenCounts
    }

    func makeTransport() -> any OSAtlasLlamaHTTPTransport {
        FakeTransport(owner: self)
    }

    func waitUntilCompletionStarted() async {
        while true {
            let started = condition.withLock { completionStarted }
            if started { return }
            await Task.yield()
        }
    }

    func waitUntilCompletionStarted(call: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition.withLock({ completionCallCount >= call && completionStarted }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition.withLock { completionCallCount >= call && completionStarted }
    }

    func waitUntilBlockedHealthStarted() async {
        while true {
            let started = condition.withLock { blockedHealthStarted }
            if started { return }
            await Task.yield()
        }
    }

    func recordedTokenCountRequests() -> [URLRequest] {
        condition.withLock { tokenCountRequests }
    }

    func recordedCompletionRequests() -> [URLRequest] {
        condition.withLock { completionRequests }
    }

    func releaseBlockedHealth(returning response: Bool) {
        let continuation = condition.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard let continuation = blockedHealthContinuation else {
                earlyBlockedHealthResponse = response
                return nil
            }
            blockedHealthContinuation = nil
            return continuation
        }
        continuation?.resume(returning: response)
    }

    fileprivate func health() async -> Bool {
        await events.append("health")
        let shouldBlock = condition.withLock { () -> Bool in
            healthCallCount += 1
            if let blockedHealthCall,
               healthCallCount == blockedHealthCall {
                blockedHealthStarted = true
                return true
            }
            return false
        }
        if shouldBlock {
            return await withCheckedContinuation { continuation in
                let earlyResponse = condition.withLock { () -> Bool? in
                    if let earlyBlockedHealthResponse {
                        self.earlyBlockedHealthResponse = nil
                        return earlyBlockedHealthResponse
                    }
                    blockedHealthContinuation = continuation
                    return nil
                }
                if let earlyResponse {
                    continuation.resume(returning: earlyResponse)
                }
            }
        }
        return condition.withLock {
            if healthResponses.count > 1 {
                return healthResponses.removeFirst()
            }
            return healthResponses[0]
        }
    }

    fileprivate func modelIsHealthy(
        _ model: OSAtlasLlamaServedModel
    ) async -> Bool {
        await events.append("model-health:\(model.rawValue)")
        return condition.withLock { loadedModels.contains(model) }
    }

    fileprivate func loadModel(
        _ model: OSAtlasLlamaServedModel
    ) async throws {
        await events.append("load:\(model.rawValue)")
        let occurrence = condition.withLock { () -> Int in
            let value = (modelLoadCounts[model] ?? 0) + 1
            modelLoadCounts[model] = value
            return value
        }
        if failingLoadModel == model,
           occurrence == failingLoadOccurrence {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        _ = condition.withLock {
            loadedModels.insert(model)
        }
    }

    fileprivate func unloadModel(
        _ model: OSAtlasLlamaServedModel
    ) async throws {
        await events.append("unload:\(model.rawValue)")
        let occurrence = condition.withLock { () -> Int in
            let value = (modelUnloadCounts[model] ?? 0) + 1
            modelUnloadCounts[model] = value
            return value
        }
        if failingUnloadModel == model,
           occurrence == failingUnloadOccurrence {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        _ = condition.withLock {
            loadedModels.remove(model)
        }
    }

    fileprivate func exactInputTokenCount(
        _ request: URLRequest
    ) -> Int {
        condition.withLock {
            tokenCountRequests.append(request)
            if inputTokenCounts.count > 1 {
                return inputTokenCounts.removeFirst()
            }
            return inputTokenCounts[0]
        }
    }

    fileprivate func complete(_ request: URLRequest) async throws -> Data {
        let call = condition.withLock { () -> Int in
            completionRequests.append(request)
            completionCallCount += 1
            return completionCallCount
        }
        await events.append("complete")
        if failsCompletion {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        let shouldBlock = blocksCompletion || blockedCompletionCall == call
        guard !shouldBlock else {
            return try await withCheckedThrowingContinuation { continuation in
                condition.withLock {
                    completionStarted = true
                    completionContinuation = continuation
                }
            }
        }
        let dataResponse = condition.withLock { () -> Data? in
            guard var responses = completionDataResponses else {
                return nil
            }
            let response = responses[0]
            if responses.count > 1 {
                responses.removeFirst()
                completionDataResponses = responses
            }
            return response
        }
        if let dataResponse {
            return dataResponse
        }
        let response = condition.withLock { () -> String in
            if completionResponses.count > 1 {
                return completionResponses.removeFirst()
            }
            return completionResponses[0]
        }
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": response]]],
        ])
    }

    fileprivate func cancelAll() async {
        await events.append("cancel-http")
        let continuation = condition.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { completionContinuation = nil }
            return completionContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class FakeTransport: OSAtlasLlamaHTTPTransport, @unchecked Sendable {
    let owner: FakeTransportMaker

    init(owner: FakeTransportMaker) {
        self.owner = owner
    }

    func health(baseURL: URL, bearerToken: String) async throws -> Bool {
        await owner.health()
    }

    func modelIsHealthy(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws -> Bool {
        await owner.modelIsHealthy(model)
    }

    func loadModel(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws {
        try await owner.loadModel(model)
    }

    func unloadModel(
        baseURL: URL,
        bearerToken: String,
        model: OSAtlasLlamaServedModel
    ) async throws {
        try await owner.unloadModel(model)
    }

    func complete(request: URLRequest) async throws -> Data {
        try await owner.complete(request)
    }

    func exactInputTokenCount(
        completionRequest: URLRequest
    ) async throws -> Int {
        owner.exactInputTokenCount(completionRequest)
    }

    func cancelAll() async {
        await owner.cancelAll()
    }
}

private struct FixedPortProvider: OSAtlasLlamaPortProviding {
    let port: UInt16

    func availableLoopbackPort() throws -> UInt16 { port }
}

private struct FixedTokenProvider: OSAtlasLlamaTokenProviding {
    let token: String

    func bearerToken() -> String { token }
}

private struct FixedResourceInspector: OSAtlasLlamaResourceInspecting {
    static let sufficient = FixedResourceInspector(
        snapshotValue: OSAtlasLlamaResourceSnapshot(
            physicalMemoryBytes: .max,
            reclaimableMemoryBytes: .max))
    static let compactSufficient = FixedResourceInspector(
        snapshotValue: OSAtlasLlamaResourceSnapshot(
            physicalMemoryBytes:
                OSAtlasLlamaResourceProfile.minimumPhysicalMemoryBytes,
            reclaimableMemoryBytes: .max))

    let snapshotValue: OSAtlasLlamaResourceSnapshot

    func snapshot() throws -> OSAtlasLlamaResourceSnapshot {
        snapshotValue
    }
}

private final class SequenceResourceInspector: OSAtlasLlamaResourceInspecting,
    @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [OSAtlasLlamaResourceSnapshot]

    init(snapshots: [OSAtlasLlamaResourceSnapshot]) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
    }

    func snapshot() throws -> OSAtlasLlamaResourceSnapshot {
        lock.withLock {
            if snapshots.count > 1 {
                return snapshots.removeFirst()
            }
            return snapshots[0]
        }
    }
}

private func makeTestJPEG(width: Int, height: Int) throws -> Data {
    let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
        .cropped(to: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(width),
            height: CGFloat(height)))
    let context = CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
    ])
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let data = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality
                    as CIImageRepresentationOption: CGFloat(0.7),
            ]) else {
        throw OSAtlasLlamaRuntimeError.invalidVisionInput
    }
    return data
}
