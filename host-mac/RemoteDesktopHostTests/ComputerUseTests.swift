import CoreGraphics
import CloudKit
import CryptoKit
import CoreImage
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTests: XCTestCase {
    func test_manifestPinsAuditedRepositoriesRevisionsAndHashes() {
        let manifest = ComputerUseArtifactManifest.current

        XCTAssertEqual(manifest.installationVersion, "os-atlas-pro-4b-q4-k-m-b9992")
        XCTAssertEqual(manifest.modelVariant, .pro4B)
        XCTAssertEqual(
            ComputerUseArtifactManifest.ModelVariant.allCases,
            [.pro4B, .base4B])
        XCTAssertEqual(manifest.modelRepository, "OS-Copilot/OS-Atlas-Pro-4B")
        XCTAssertEqual(
            manifest.modelRevision,
            "06b790b907d82f29bb317ba889e6888805953036")
        XCTAssertEqual(manifest.minimumMemoryBytes, 16 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(
            manifest.modelArtifacts.map(\.kind),
            [.textModelShard, .textModelShard, .visionProjector])
        XCTAssertEqual(
            manifest.modelArtifacts.map(\.fileName),
            [
                "os-atlas-pro-4b-q4_k_m-00001-of-00002.gguf",
                "os-atlas-pro-4b-q4_k_m-00002-of-00002.gguf",
                "mmproj-os-atlas-pro-4b-f16.gguf",
            ])
        for artifact in manifest.modelArtifacts {
            XCTAssertGreaterThan(artifact.byteCount, 1)
            XCTAssertEqual(artifact.sha256.count, 64)
            XCTAssertNotEqual(artifact.sha256, String(repeating: "0", count: 64))
            XCTAssertEqual(artifact.downloadURL.scheme, "https")
            XCTAssertEqual(artifact.downloadURL.host, "github.com")
            XCTAssertTrue(artifact.downloadURL.path.contains(
                "/releases/download/os-atlas-pro-4b-q4-k-m-b9992/"))
            XCTAssertTrue(artifact.fileName.hasSuffix(".gguf"))
        }
    }

    func test_computerUseReusesDeployedCloudKitSignalRecordType() {
        XCTAssertEqual(CloudKitComputerUseChannel.recordType, "WebRTCSignal")
    }

    func test_visualOpenAppUsesValidatedNativeApplicationOpener() async throws {
        var openedNames: [String] = []
        let tools = ComputerUseHostTools(
            injector: InputInjector(),
            mayAct: { true },
            applicationOpener: { openedNames.append($0) })

        try await tools.openApplication(named: "  Calculator  ")

        XCTAssertEqual(openedNames, ["Calculator"])
    }

    func test_visualOpenAppRejectsPathsAndPausedAutomationBeforeOpening() async {
        var openCount = 0
        var allowed = true
        let tools = ComputerUseHostTools(
            injector: InputInjector(),
            mayAct: { allowed },
            applicationOpener: { _ in openCount += 1 })

        for invalid in ["", "../Calculator.app", "/System/Applications/Calculator.app", "Bad\\Name"] {
            do {
                try await tools.openApplication(named: invalid)
                XCTFail("Unsafe application value was accepted: \(invalid)")
            } catch {
                // Expected fail-closed validation.
            }
        }
        allowed = false
        do {
            try await tools.openApplication(named: "Calculator")
            XCTFail("Paused automation opened an application")
        } catch {
            // The takeover gate must win before Launch Services is called.
        }

        XCTAssertEqual(openCount, 0)
    }

    func test_virtualScreenAndAccessibilityContextKeepModelTestsOffTheDesktop() throws {
        var captures = 0
        var inspectedActions: [ComputerUsePredictedAction] = []
        let expectedBounds = CGRect(x: 40, y: 80, width: 448, height: 320)
        let tools = ComputerUseHostTools(
            injector: InputInjector(),
            mayAct: { true },
            screenProvider: {
                captures += 1
                return ComputerUseScreenObservation(
                    image: CIImage(color: CIColor(
                        red: 0.5,
                        green: 0.5,
                        blue: 0.5))
                        .cropped(to: CGRect(x: 0, y: 0, width: 448, height: 320)),
                    displayBounds: expectedBounds)
            },
            accessibilityContextProvider: { action in
                inspectedActions.append(action)
                return "AXStaticText • Delivery quote total"
            })

        let observation = try tools.currentScreen()
        let benignQuoteRead = ComputerUsePredictedAction.scroll(
            x: 264,
            y: 240,
            dx: 0,
            dy: -360)

        XCTAssertEqual(captures, 1)
        XCTAssertEqual(observation.image.extent.width, 448)
        XCTAssertEqual(observation.image.extent.height, 320)
        XCTAssertEqual(observation.displayBounds, expectedBounds)
        XCTAssertNil(tools.approvalReason(for: benignQuoteRead))
        XCTAssertEqual(inspectedActions, [benignQuoteRead])
    }

    func test_stableCloudKitRetryRefreshesPreStartRecordWithoutChangingMessage() throws {
        let originalCreatedAt = Date(timeIntervalSince1970: 100)
        let hostStartedAt = Date(timeIntervalSince1970: 200)
        let refreshedAt = Date(timeIntervalSince1970: 300)
        let request = ComputerUseSetupRequest(requestID: "mobile-setup-request")
        let envelope = ComputerUseEnvelope(
            id: request.requestID,
            senderID: "IOS-PEER",
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: "setup-mobile-setup-request",
            kind: .setupRequest,
            body: try request.encodedBody(),
            createdAt: originalCreatedAt)
        let serverRecord = try CloudKitComputerUseChannel.record(for: envelope)
        let originalRecordName = serverRecord.recordID.recordName
        let originalPayload = serverRecord["payload"] as? String

        XCTAssertLessThanOrEqual(
            try XCTUnwrap(serverRecord["createdAt"] as? Date),
            hostStartedAt,
            "The fixture must begin outside a newly started host's bounded poll window")

        let refreshed = try CloudKitComputerUseChannel.refreshedConflictRecord(
            serverRecord,
            matching: envelope,
            refreshedAt: refreshedAt)

        XCTAssertEqual(refreshed.recordID.recordName, originalRecordName)
        XCTAssertEqual(refreshed["payload"] as? String, originalPayload)
        XCTAssertEqual(refreshed["createdAt"] as? Date, refreshedAt)
        XCTAssertGreaterThan(
            try XCTUnwrap(refreshed["createdAt"] as? Date),
            hostStartedAt,
            "The same idempotent request must become visible after the host starts")
    }

    func test_stableCloudKitRetryRejectsMessageIDCollisionWithDifferentBody() throws {
        let original = ComputerUseEnvelope(
            id: "stable-message-id",
            senderID: "IOS-PEER",
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: "setup-stable-message-id",
            kind: .setupRequest,
            body: try ComputerUseSetupRequest(
                requestID: "stable-message-id").encodedBody(),
            createdAt: Date(timeIntervalSince1970: 100))
        let serverRecord = try CloudKitComputerUseChannel.record(for: original)
        let originalCreatedAt = serverRecord["createdAt"] as? Date
        let collision = ComputerUseEnvelope(
            id: original.id,
            senderID: original.senderID,
            targetID: original.targetID,
            pairingCode: original.pairingCode,
            sessionID: original.sessionID,
            kind: original.kind,
            body: "different-body",
            createdAt: Date(timeIntervalSince1970: 200))

        XCTAssertThrowsError(try CloudKitComputerUseChannel.refreshedConflictRecord(
            serverRecord,
            matching: collision,
            refreshedAt: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(serverRecord["createdAt"] as? Date, originalCreatedAt)
    }

    func test_clarificationPolicyCollectsMissingEmailDetailsInOneQuestion() {
        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for:
                ComputerUsePromptRequest(prompt: "Send an email")),
            "Who should receive the email, and what should it say?")
        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for:
                ComputerUsePromptRequest(prompt: "Send an email to alex@example.com")),
            "What should the email say?")
        XCTAssertNil(ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(
                prompt: "Send an email to codex-computer-use-test@example.invalid with subject Remote Desktop computer use test and body This email confirms the local MCP Mail workflow completed end to end.")))
        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for:
                ComputerUsePromptRequest(
                    prompt: "Send an email to alex@example.com with subject Status and body")),
            "What should the email say?")
        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for:
                ComputerUsePromptRequest(
                    prompt: "Send an email to alex@example.com with subject Status and body:")),
            "What should the email say?")
        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for:
                ComputerUsePromptRequest(prompt: "Send an email to say hello")),
            "Who should receive the email? Please give me their name or email address.")
        XCTAssertNil(ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(
                prompt: "To alex@example.com. Say the meeting is at 3.",
                conversation: [
                    .init(role: .user, text: "Send an email"),
                    .init(
                        role: .assistant,
                        text: "Who should receive the email, and what should it say?"),
                ])))
    }

    func test_clarificationPolicyDoesNotReuseCompletedEmailBody() {
        let request = ComputerUsePromptRequest(
            prompt: "Send an email to second@example.com with subject Second subject",
            conversation: [
                .init(
                    role: .user,
                    text: "Send an email to first@example.com with subject First subject and body First body."),
                .init(
                    role: .assistant,
                    text: "Mail accepted the approved email for sending."),
            ])

        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for: request),
            "What should the email say?")
    }

    func test_clarificationPolicyLetsExplicitlyReadOnlyDeliveryQuoteReachVisualSafety() {
        XCTAssertNil(ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(prompt: "Check the current DoorDash delivery price and ETA. Do not place the order.")))
        XCTAssertNil(ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(prompt: "Get the current delivered price and ETA for the DoorDash item already in my cart. If I need to sign in, let me take over; I’ll sign in and open the complete itemized quote, then hand it back. After that, only read the restaurant, item, subtotal, delivery fee, service fee, tax, total, and ETA. Don’t enter credentials, change the cart, check out, or place the order.")))
        XCTAssertNotNil(ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(prompt: "Get food delivered with DoorDash")))
    }

    func test_clarificationPolicyDistinguishesCoordinatedQuoteNegationFromOrderingIntent() {
        let readOnlyQuotes = [
            "Get the DoorDash total and ETA, but don't enter credentials or place the order.",
            "Tell me the DoorDash delivery price. Never check out.",
            "Get the DoorDash cost, but do not change the cart or order anything.",
            "Get the DoorDash quote without ordering anything.",
            "Get the DoorDash total and stop at checkout.",
            "Get the DoorDash total and only read what is already visible.",
        ]
        for prompt in readOnlyQuotes {
            XCTAssertNil(
                ComputerUseClarificationPolicy.question(for:
                    ComputerUsePromptRequest(prompt: prompt)),
                prompt)
        }

        let genuineOrders = [
            "Don't enter credentials. Order food with DoorDash and tell me the total.",
            "Don't sign in with Apple; order food as a guest on DoorDash and tell me the total.",
            "Don't forget to order food with DoorDash and tell me the total.",
            "Do not cancel the order; buy food with DoorDash and tell me the total.",
            "Get food delivered with DoorDash and tell me the total before I confirm.",
        ]
        for prompt in genuineOrders {
            XCTAssertNotNil(
                ComputerUseClarificationPolicy.question(for:
                    ComputerUsePromptRequest(prompt: prompt)),
                prompt)
        }
    }

    func test_clarificationPolicyDoesNotGuessFoodOrderDetails() {
        let question = ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(
                prompt: "Order fried rice from my favorite restaurant using Uber Eats"))

        XCTAssertTrue(question?.contains("which restaurant") == true)
        XCTAssertTrue(question?.contains("how many") == true)
        XCTAssertTrue(question?.contains("delivery") == true)

        let addressIsNotQuantity = ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(
                prompt: "Order fried rice from Panda Express for delivery to 123 Main Street using Uber Eats"))
        XCTAssertTrue(addressIsNotQuantity?.contains("how many") == true)

        XCTAssertNil(ComputerUseClarificationPolicy.question(for:
            ComputerUsePromptRequest(
                prompt: "Panda Express, one order, deliver to my default address.",
                conversation: [
                    .init(
                        role: .user,
                        text: "Order fried rice from my favorite restaurant using Uber Eats"),
                    .init(
                        role: .assistant,
                        text: "Which restaurant, how many, and delivery or pickup?"),
                ])))
    }

    func test_clarificationPolicyDoesNotReuseCompletedFoodOrderDetails() {
        let request = ComputerUsePromptRequest(
            prompt: "Order food",
            conversation: [
                .init(
                    role: .user,
                    text: "Order one fried rice from Panda Express for delivery to my default address using Uber Eats."),
                .init(
                    role: .assistant,
                    text: "Done. Your previous order was placed."),
            ])

        XCTAssertEqual(
            ComputerUseClarificationPolicy.question(for: request),
            "Before I start the order, please tell me what you want to order, which restaurant, how many, delivery (and which address) or pickup, and which ordering app or website.")
    }

    func test_hostSafetyPolicyRequiresApprovalWithoutModelFlag() {
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .click(x: 10, y: 10, button: 1, count: 1),
            accessibilityContext: "AXButton • Send message"))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .key(usage: 0x28, modifiers: 0),
            accessibilityContext: "AXTextField • Reply"))
        XCTAssertNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .key(usage: 0x28, modifiers: 0),
            accessibilityContext: "AXSearchField • Search"))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .typeText("123456"),
            accessibilityContext: ""))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .click(x: 10, y: 10, button: 1, count: 1),
            accessibilityContext: "AXButton • Next"))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .click(x: 10, y: 10, button: 1, count: 1),
            accessibilityContext: "AXButton • Place Order"))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .click(x: 10, y: 10, button: 1, count: 1),
            accessibilityContext: "AXButton"))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .click(x: 10, y: 10, button: 1, count: 1),
            accessibilityContext: ""))
        XCTAssertNotNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .drag(fromX: 1, fromY: 2, toX: 3, toY: 4),
            accessibilityContext: "AXGroup • Desktop item"))
        XCTAssertNil(ComputerUseActionSafetyPolicy.approvalReason(
            for: .click(x: 10, y: 10, button: 1, count: 1),
            accessibilityContext: "AXStaticText • Display options"),
            "the word 'display' must not accidentally match the keyword 'pay'")
    }

    func test_inputInjectorChecksGateBeforePostingEvent() {
        let injector = InputInjector()
        XCTAssertFalse(injector.apply(
            .pointer(x: 10, y: 10, buttons: 1),
            ifAllowed: { false }))
    }

    func test_computerUseDoubleClickCarriesNativeClickCount() throws {
        let events = CapturedCGEventStore()
        let injector = InputInjector(
            eventPoster: { events.append($0) },
            uptime: { 100 })
        let tools = ComputerUseHostTools(injector: injector, mayAct: { true })

        try tools.perform(.click(x: 140, y: 180, button: 1, count: 2))

        let clicks = events.values().filter {
            $0.type == .leftMouseDown || $0.type == .leftMouseUp
        }
        XCTAssertEqual(clicks.map(\.clickCount), [1, 1, 2, 2])
        XCTAssertTrue(clicks.allSatisfy { $0.syntheticTag == InputInjector.syntheticEventTag })
    }

    func test_computerUseRightClickPostsNativeRightButtonPair() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })

        try tools.perform(.click(x: 320, y: 240, button: 2, count: 1))

        let clicks = events.values().filter {
            $0.type == .rightMouseDown || $0.type == .rightMouseUp
        }
        XCTAssertEqual(clicks.map(\.type), [.rightMouseDown, .rightMouseUp])
        XCTAssertEqual(clicks.map(\.clickCount), [1, 1])
        XCTAssertTrue(clicks.allSatisfy { $0.location == CGPoint(x: 320, y: 240) })
        XCTAssertTrue(clicks.allSatisfy {
            $0.syntheticTag == InputInjector.syntheticEventTag
        })
        XCTAssertFalse(events.values().contains {
            $0.type == .leftMouseDown || $0.type == .leftMouseUp
        })
    }

    func test_computerUseMiddleClickPostsNativeOtherButtonPair() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })

        try tools.perform(.click(x: 410, y: 275, button: 4, count: 1))

        let clicks = events.values().filter {
            $0.type == .otherMouseDown || $0.type == .otherMouseUp
        }
        XCTAssertEqual(clicks.map(\.type), [.otherMouseDown, .otherMouseUp])
        XCTAssertEqual(clicks.map(\.clickCount), [1, 1])
        XCTAssertTrue(clicks.allSatisfy { $0.location == CGPoint(x: 410, y: 275) })
        XCTAssertTrue(clicks.allSatisfy {
            $0.syntheticTag == InputInjector.syntheticEventTag
        })
    }

    func test_computerUseEnterPostsReturnKeyDownAndUp() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })

        try tools.perform(.key(usage: 0x28, modifiers: 0))

        let keys = events.values().filter {
            $0.type == .keyDown || $0.type == .keyUp
        }
        XCTAssertEqual(keys.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(keys.map(\.keyCode), [0x24, 0x24])
        XCTAssertTrue(keys.allSatisfy {
            $0.modifierFlags.intersection(Self.keyboardModifierFlags).isEmpty
        })
        XCTAssertTrue(keys.allSatisfy {
            $0.syntheticTag == InputInjector.syntheticEventTag
        })
    }

    func test_computerUseCommandShiftHotkeyPostsSKeyWithModifiers() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })
        let commandShift: UInt16 = (1 << 3) | (1 << 0)

        try tools.perform(.key(usage: 0x16, modifiers: commandShift))

        let keys = events.values().filter {
            $0.type == .keyDown || $0.type == .keyUp
        }
        XCTAssertEqual(keys.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(keys.map(\.keyCode), [0x01, 0x01])
        let expectedFlags: CGEventFlags = [.maskCommand, .maskShift]
        XCTAssertTrue(keys.allSatisfy {
            $0.modifierFlags.intersection(Self.keyboardModifierFlags)
                == expectedFlags
        })
        XCTAssertTrue(keys.allSatisfy {
            $0.syntheticTag == InputInjector.syntheticEventTag
        })
    }

    func test_computerUseScrollPostsRequestedDeltaExactlyOnce() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })

        try tools.perform(.scroll(x: 300, y: 240, dx: 75, dy: -360))

        let scrolls = events.values().filter { $0.type == .scrollWheel }
        XCTAssertEqual(scrolls.count, 1)
        XCTAssertEqual(scrolls.first?.horizontalScrollDelta, 75)
        XCTAssertEqual(scrolls.first?.verticalScrollDelta, -360)
    }

    func test_computerUseTextPreservesEmojiAndSupplementaryUnicode() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })
        let expected = "Dinner at 7 🍕 — bring 𐐷"

        try tools.perform(.typeText(expected))

        let observed = events.values()
            .filter { $0.type == .keyDown }
            .compactMap(\.unicodeText)
            .joined()
        XCTAssertEqual(observed, expected)
    }

    func test_computerUseDragInterpolatesHeldPointerPath() throws {
        let events = CapturedCGEventStore()
        let tools = ComputerUseHostTools(
            injector: InputInjector(eventPoster: { events.append($0) }),
            mayAct: { true })

        try tools.perform(.drag(fromX: 100, fromY: 120, toX: 460, toY: 300))

        let dragged = events.values().filter { $0.type == .leftMouseDragged }
        XCTAssertGreaterThanOrEqual(dragged.count, 4)
        let lastDragEvent = try XCTUnwrap(dragged.last)
        XCTAssertEqual(lastDragEvent.location.x, 460, accuracy: 0.5)
        XCTAssertEqual(lastDragEvent.location.y, 300, accuracy: 0.5)
        XCTAssertTrue(zip(dragged, dragged.dropFirst()).allSatisfy {
            $0.location.x <= $1.location.x && $0.location.y <= $1.location.y
        })
    }

    private static let keyboardModifierFlags: CGEventFlags = [
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskCommand,
        .maskAlphaShift,
    ]

    func test_hostPeerRejectsEveryDirectInputBeforeAuthenticatedHello() {
        let inputs: [ControlMessage] = [
            .pointer(x: 10, y: 20, buttons: 1),
            .scroll(x: 10, y: 20, dx: 0, dy: -120, phase: .begin),
            .key(usage: 0x04, down: true, modifiers: 0),
            .text("hello"),
        ]

        for input in inputs {
            XCTAssertFalse(HostPeerSession.acceptsDirectInput(
                input,
                helloAuthenticated: false))
        }
    }

    func test_hostPeerAcceptsEveryDirectInputAfterAuthenticatedHello() {
        let inputs: [ControlMessage] = [
            .pointer(x: 10, y: 20, buttons: 1),
            .scroll(x: 10, y: 20, dx: 0, dy: -120, phase: .begin),
            .key(usage: 0x04, down: true, modifiers: 0),
            .text("hello"),
        ]

        for input in inputs {
            XCTAssertTrue(HostPeerSession.acceptsDirectInput(
                input,
                helloAuthenticated: true))
        }
    }

    func test_managerRejectsUnauthorizedPromptThenAcceptsPairedPeer() async {
        let executor = ImmediateComputerUseExecutor(results: [.completed("Done")])
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Open Notes")

        XCTAssertFalse(manager.handle(prompt, channel: channel))
        await Task.yield()
        XCTAssertEqual(executor.callCount, 0)

        manager.authorizePeer(senderID: prompt.senderID)
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { executor.callCount == 1 && manager.activity == .idle }
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertTrue(manager.isPeerAuthorized(senderID: prompt.senderID))

        manager.handle(prompt, channel: channel)
        await Task.yield()
        XCTAssertEqual(executor.callCount, 1, "same task ID must never execute twice")
    }

    func test_applicationShutdownAwaitsCancelledExecutionBeforeRuntimeDeactivation() async {
        let executor = ShutdownBlockingComputerUseExecutor()
        let visualLoader = ShutdownRecordingVisualLoader()
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer {
            try? FileManager.default.removeItem(
                at: ledgerURL.deletingLastPathComponent())
        }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            visualExecutorLoader: visualLoader,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Open Calculator")
        manager.authorizePeer(senderID: prompt.senderID)

        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { executor.started }

        let completion = ShutdownCompletionProbe()
        let shutdown = Task {
            await manager.shutdown()
            completion.finished = true
        }
        await waitUntil { executor.cancellationWasObserved }

        XCTAssertFalse(completion.finished)
        XCTAssertEqual(
            visualLoader.deactivationCount,
            0,
            "The runtime must remain owned until cancelled execution unwinds")

        executor.release()
        await shutdown.value

        XCTAssertTrue(completion.finished)
        XCTAssertEqual(visualLoader.deactivationCount, 1)
        XCTAssertEqual(manager.activity, .idle)
    }

    func test_managerAsksForEmailDetailsBeforeModelOrScreenControl() async throws {
        let executor = ImmediateComputerUseExecutor(results: [.completed("Unexpected")])
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let request = ComputerUsePromptRequest(prompt: "Send an email")
        let prompt = makeEnvelope(kind: .prompt, body: try request.encodedBody())
        manager.authorizePeer(senderID: prompt.senderID)

        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil {
            await channel.sentMessages().contains { $0.kind == .assistant }
        }

        XCTAssertEqual(executor.callCount, 0)
        XCTAssertEqual(manager.activity, .idle)
        let messages = await channel.sentMessages()
        let answerEnvelope = try XCTUnwrap(messages.first { $0.kind == .assistant })
        let answer = try ComputerUseTaskUpdate.decodeBody(answerEnvelope.body)
        XCTAssertEqual(answer.taskID, prompt.id)
        XCTAssertEqual(
            answer.text,
            "Who should receive the email, and what should it say?")

        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await Task.yield()
        XCTAssertEqual(executor.callCount, 0, "ledger replay must not turn a question into an action")
    }

    func test_managerUsesClarificationConversationWhenAnswerIsComplete() async throws {
        let executor = ImmediateComputerUseExecutor(results: [.completed("Ready for approval")])
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let request = ComputerUsePromptRequest(
            prompt: "To alex@example.com. Say the meeting is at 3.",
            conversation: [
                .init(role: .user, text: "Send an email"),
                .init(
                    role: .assistant,
                    text: "Who should receive the email, and what should it say?"),
            ])
        let prompt = makeEnvelope(kind: .prompt, body: try request.encodedBody())
        manager.authorizePeer(senderID: prompt.senderID)

        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { executor.callCount == 1 && manager.activity == .idle }

        let modelPrompt = try XCTUnwrap(executor.prompts.first)
        XCTAssertTrue(modelPrompt.contains("User: Send an email"))
        XCTAssertTrue(modelPrompt.contains("Assistant: Who should receive"))
        XCTAssertTrue(modelPrompt.contains("Current user request: To alex@example.com"))
        XCTAssertFalse(modelPrompt.hasPrefix("{"), "the model should receive labeled chat, not wire JSON")
    }

    func test_interventionPausesAndResumeReplansSavedPrompt() async {
        let executor = SuspendingComputerUseExecutor()
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Organize the desktop")
        manager.authorizePeer(senderID: prompt.senderID)
        manager.handle(prompt, channel: channel)
        await waitUntil { executor.prompts.count == 1 }

        XCTAssertTrue(manager.blockActionsForUserIntervention())
        manager.userIntervened()
        XCTAssertEqual(manager.activity, .paused)

        manager.handle(makeEnvelope(kind: .resume), channel: channel)
        await waitUntil { executor.prompts.count == 2 }
        XCTAssertTrue(executor.prompts[1].contains("do not repeat"))
        manager.stop()
    }

    func test_executorRequestedUserInterventionPausesWithoutCompletingAndResumesTask() async throws {
        let guidance = "Sign in yourself, then tap Let AI continue."
        let executor = ImmediateComputerUseExecutor(results: [
            .userInterventionRequired(guidance),
            .completed("Visible delivery quote returned after sign-in."),
        ])
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer {
            try? FileManager.default.removeItem(
                at: ledgerURL.deletingLastPathComponent())
        }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(
            kind: .prompt,
            body: "Continue the visible task")
        manager.authorizePeer(senderID: prompt.senderID)

        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { manager.activity == .paused }
        await waitUntil {
            await channel.sentMessages().contains { message in
                guard message.kind == .status,
                      let update = try? ComputerUseTaskUpdate.decodeBody(message.body) else {
                    return false
                }
                return ComputerUseStatusSignal.userInterventionMessage(
                    from: update.text) == guidance
            }
        }

        let pausedMessages = await channel.sentMessages()
        XCTAssertFalse(
            pausedMessages.contains(where: { $0.kind == .assistant }),
            "A person-only sign-in step must keep the task resumable")

        XCTAssertTrue(manager.handle(
            makeEnvelope(kind: .resume),
            channel: channel))
        await waitUntil { executor.callCount == 2 && manager.activity == .idle }
        XCTAssertTrue(executor.prompts[1].contains("Continue from the current screen"))
        let completedMessages = await channel.sentMessages()
        XCTAssertTrue(completedMessages.contains { message in
            guard message.kind == .assistant,
                  let update = try? ComputerUseTaskUpdate.decodeBody(message.body) else {
                return false
            }
            return update.text == "Visible delivery quote returned after sign-in."
        })
    }

    func test_losingPeerAuthorizationPausesAutomationUntilExplicitResume() async {
        let executor = SuspendingComputerUseExecutor()
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Organize the desktop")
        manager.authorizePeer(senderID: prompt.senderID)
        manager.handle(prompt, channel: channel)
        await waitUntil { executor.prompts.count == 1 }

        manager.revokePeerAuthorization()
        XCTAssertEqual(manager.activity, .paused)
        XCTAssertFalse(manager.isPeerAuthorized(senderID: prompt.senderID))

        manager.handle(makeEnvelope(kind: .resume), channel: channel)
        await Task.yield()
        XCTAssertEqual(executor.prompts.count, 1)

        manager.authorizePeer(senderID: prompt.senderID)
        manager.handle(makeEnvelope(kind: .resume), channel: channel)
        await waitUntil { executor.prompts.count == 2 }
        manager.stop()
    }

    func test_approvalResponseIsScopedAndContinuesOnlyAfterApproval() async throws {
        let approvedAction = ComputerUsePredictedAction.key(
            usage: 0x28,
            modifiers: 0)
        let executor = ImmediateComputerUseExecutor(results: [
            .approvalRequired(
                message: "Send the email to Alex",
                action: approvedAction),
            .completed("Sent"),
        ])
        var performedActions: [ComputerUsePredictedAction] = []
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            approvalTargetProvider: { _ in
                ComputerUseApprovalTargetSnapshot(
                    context: "focused compose button",
                    applicationID: "com.threadmark.tests.fixture",
                    accessibilityIdentity: "fixture-return-target")
            },
            actionPerformer: { performedActions.append($0) },
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Reply to Alex")
        manager.authorizePeer(senderID: prompt.senderID)
        manager.handle(prompt, channel: channel)

        await waitUntil {
            if case .awaitingApproval = manager.activity { return true }
            return false
        }
        await waitUntil {
            await channel.sentMessages().contains(where: { $0.kind == .approvalRequest })
        }
        let sent = await channel.sentMessages()
        let requestEnvelope = try XCTUnwrap(
            sent.first(where: { $0.kind == .approvalRequest }))
        let request = try ComputerUseApprovalRequest.decodeBody(requestEnvelope.body)
        XCTAssertNotEqual(request.message, "Send the email to Alex")
        XCTAssertTrue(request.message.contains("Return"))
        let response = ComputerUseApprovalResponse(
            requestID: request.requestID,
            approved: true)
        manager.handle(
            makeEnvelope(kind: .approvalResponse, body: try response.encodedBody()),
            channel: channel)

        await waitUntil { executor.callCount == 2 && manager.activity == .idle }
        XCTAssertEqual(performedActions, [approvedAction])
        XCTAssertTrue(executor.prompts.last?.contains("executed the one action") == true)
    }

    func test_userInputInvalidatesPendingApproval() async throws {
        let executor = ImmediateComputerUseExecutor(results: [
            .approvalRequired(
                message: "Delete the file",
                action: .key(usage: 0x4C, modifiers: 0)),
        ])
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Delete the file")
        manager.authorizePeer(senderID: prompt.senderID)
        manager.handle(prompt, channel: channel)
        await waitUntil {
            if case .awaitingApproval = manager.activity { return true }
            return false
        }
        await waitUntil {
            await channel.sentMessages().contains(where: { $0.kind == .approvalRequest })
        }
        let sent = await channel.sentMessages()
        let approvalEnvelope = try XCTUnwrap(
            sent.first(where: { $0.kind == .approvalRequest }))
        let approval = try ComputerUseApprovalRequest.decodeBody(approvalEnvelope.body)

        XCTAssertTrue(manager.blockActionsForUserIntervention())
        manager.userIntervened()
        XCTAssertEqual(manager.activity, .paused)

        let response = ComputerUseApprovalResponse(
            requestID: approval.requestID,
            approved: true)
        manager.handle(
            makeEnvelope(kind: .approvalResponse, body: try response.encodedBody()),
            channel: channel)
        await Task.yield()
        XCTAssertEqual(executor.callCount, 1)

        manager.handle(makeEnvelope(kind: .resume), channel: channel)
        await waitUntil { executor.callCount == 2 }
        XCTAssertTrue(executor.prompts.last?.contains("do not repeat") == true)
        manager.stop()
    }

    func test_pauseControlInvalidatesPendingApprovalAndResumeReplans() async throws {
        let executor = ImmediateComputerUseExecutor(results: [
            .approvalRequired(
                message: "Send the message",
                action: .key(usage: 0x28, modifiers: 0)),
            .completed("Continued safely"),
        ])
        let channel = FakeHostComputerUseChannel()
        let ledgerURL = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent()) }
        let manager = HostComputerUseManager(
            injector: InputInjector(),
            executor: executor,
            taskLedger: ComputerUseTaskLedger(fileURL: ledgerURL),
            channelFactory: { _ in channel })
        let prompt = makeEnvelope(kind: .prompt, body: "Reply to the message")
        manager.authorizePeer(senderID: prompt.senderID)
        manager.handle(prompt, channel: channel)
        await waitUntil {
            if case .awaitingApproval = manager.activity { return true }
            return false
        }
        await waitUntil {
            await channel.sentMessages().contains(where: { $0.kind == .approvalRequest })
        }
        let sent = await channel.sentMessages()
        let approvalEnvelope = try XCTUnwrap(
            sent.first(where: { $0.kind == .approvalRequest }))
        let approval = try ComputerUseApprovalRequest.decodeBody(approvalEnvelope.body)

        manager.handle(makeEnvelope(kind: .pause), channel: channel)
        XCTAssertEqual(manager.activity, .paused)

        let staleResponse = ComputerUseApprovalResponse(
            requestID: approval.requestID,
            approved: true)
        manager.handle(
            makeEnvelope(kind: .approvalResponse, body: try staleResponse.encodedBody()),
            channel: channel)
        await Task.yield()
        XCTAssertEqual(executor.callCount, 1, "a paused approval must never execute")

        manager.handle(makeEnvelope(kind: .resume), channel: channel)
        await waitUntil { executor.callCount == 2 && manager.activity == .idle }
        XCTAssertTrue(executor.prompts.last?.contains("do not repeat") == true)
    }

    func test_taskLedgerPersistsAtMostOnceClaimAndTerminalReplay() throws {
        let url = temporaryLedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = ComputerUseTaskLedger(fileURL: url)
        XCTAssertEqual(try first.claim(taskID: "task-1"), .new)
        XCTAssertEqual(try first.claim(taskID: "task-1"), .accepted)
        first.complete(taskID: "task-1", response: "Finished")

        let relaunched = ComputerUseTaskLedger(fileURL: url)
        XCTAssertEqual(try relaunched.claim(taskID: "task-1"), .completed("Finished"))
    }

    func test_installerRecognizesOnlyReceiptInsideManagedRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("Models/test-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: model.appendingPathComponent("model.gguf"))

        let manifest = ComputerUseArtifactManifest(
            installationVersion: "test-v1",
            modelVariant: .pro4B,
            modelRepository: "test/model",
            modelRevision: "revision",
            modelArtifacts: [.init(
                kind: .textModelShard,
                fileName: "model.gguf",
                byteCount: 3,
                sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
                downloadURL: URL(string: "https://example.invalid/model.gguf")!)],
            minimumMemoryBytes: 0)
        let receipt = ComputerUseInstallationReceipt(
            installationVersion: manifest.installationVersion,
            modelVariant: manifest.modelVariant,
            modelDirectory: model.path,
            installedAt: Date())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(
            to: root.appendingPathComponent("active-installation.json"))

        let installer = ComputerUseInstaller(manifest: manifest, rootDirectory: root)
        let installedReceipt = await installer.currentInstallation()
        XCTAssertEqual(installedReceipt, receipt)

        // A same-size replacement must not inherit the host's Accessibility
        // permission merely because the receipt and byte count still match.
        try Data([3, 2, 1]).write(to: model.appendingPathComponent("model.gguf"))
        let replacedArtifactReceipt = await installer.currentInstallation()
        XCTAssertNil(replacedArtifactReceipt)
        try Data([1, 2, 3]).write(to: model.appendingPathComponent("model.gguf"))

        let outsideReceipt = ComputerUseInstallationReceipt(
            installationVersion: manifest.installationVersion,
            modelVariant: manifest.modelVariant,
            modelDirectory: FileManager.default.temporaryDirectory.path,
            installedAt: Date())
        try JSONEncoder().encode(outsideReceipt).write(
            to: root.appendingPathComponent("active-installation.json"),
            options: .atomic)
        let invalidReceipt = await installer.currentInstallation()
        XCTAssertNil(invalidReceipt)
    }

    func test_freshInstallPreflightUsesExistingAncestorBeforeRootExists() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseFreshPreflight-\(UUID().uuidString)", isDirectory: true)
        let root = base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Model", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path))
        XCTAssertEqual(
            ComputerUseInstaller.nearestExistingAncestor(of: root),
            base.standardizedFileURL)

        let installer = ComputerUseInstaller(
            manifest: testManifest(minimumMemoryBytes: 0),
            rootDirectory: root)
        try await installer.preflight()
    }

    func test_setupProgressRemainsMonotonicWhileNativeRuntimeLoads() {
        let updates: [ComputerUseInstaller.Update] = [
            .init(phase: .preparing, fraction: 0, detail: "Preparing"),
            .init(phase: .downloadingModel, fraction: 0.95, detail: "Model"),
            .init(phase: .verifying, fraction: 0.96, detail: "Verifying"),
            .init(phase: .ready, fraction: 1, detail: "Installed"),
        ]
        let fractions = updates.compactMap(HostComputerUseManager.visibleInstallerFraction)
            + [0.98, 0.99, 1]

        XCTAssertEqual(fractions[3], 0.97)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
    }

    func test_installerDetectsAndClearsInterruptedProcessMarker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseInterrupted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("installing\n".utf8).write(to: root.appendingPathComponent(
            ComputerUseInstaller.interruptedInstallationMarkerName))
        let installer = ComputerUseInstaller(
            manifest: testManifest(minimumMemoryBytes: 0),
            rootDirectory: root)

        let markerExists = await installer.interruptedInstallationExists()
        XCTAssertTrue(markerExists)
        await installer.clearInterruptedInstallationMarker()
        let markerWasCleared = await installer.interruptedInstallationExists()
        XCTAssertFalse(markerWasCleared)
    }

    func test_removeInstallationAlsoRemovesLegacyAdapterData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ComputerUseLegacyCleanup-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("Models/current", isDirectory: true)
        let adapters = root.appendingPathComponent("Adapters/legacy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: models,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: adapters,
            withIntermediateDirectories: true)
        try Data([1]).write(to: adapters.appendingPathComponent("adapter.bin"))
        try Data([1]).write(to: root.appendingPathComponent("active-installation.json"))

        let installer = ComputerUseInstaller(
            manifest: testManifest(minimumMemoryBytes: 0),
            rootDirectory: root)
        try await installer.removeInstallation()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Models").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Adapters").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("active-installation.json").path))
    }

    func test_modelDataDownloaderResumesFromDurablePartialFile() async throws {
        let payload = Data((0 ..< 37).map(UInt8.init))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseRangeDownload-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("model.gguf")
        defer {
            RangeServingURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.prefix(7).write(to: destination)

        RangeServingURLProtocol.configure(payload: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var progressValues: [Double] = []
        let downloader = ComputerUseHTTPDownloader(
            destination: destination,
            expectedByteCount: Int64(payload.count),
            chunkByteCount: 5,
            session: session,
            progress: { progressValues.append($0) })

        try await downloader.download(URLRequest(url: URL(string: "https://model.test/model.gguf")!))

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(RangeServingURLProtocol.requestedRanges().first, "bytes=7-11")
        for (earlier, later) in zip(progressValues, progressValues.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
        XCTAssertEqual(progressValues.last, 1)
    }

    func test_modelPackageDownloadUsesPinnedURLsAndReportsAggregateDurableByteProgress() async throws {
        let payload = Data((0 ..< 37).map(UInt8.init))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseBaseDownload-\(UUID().uuidString)", isDirectory: true)
        let staging = root
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(".progress-test-staging", isDirectory: true)
        let completedShard = staging.appendingPathComponent("shard-1.gguf")
        let partial = staging.appendingPathComponent("shard-2.gguf")
        defer {
            RangeServingURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try payload.write(to: completedShard)
        try payload.prefix(7).write(to: partial)

        RangeServingURLProtocol.configure(payload: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let manifest = ComputerUseArtifactManifest(
            installationVersion: "progress-test",
            modelVariant: .pro4B,
            modelRepository: "owner/model",
            modelRevision: "pinned-revision",
            modelArtifacts: [
                .init(
                    kind: .textModelShard,
                    fileName: "shard-1.gguf",
                    byteCount: Int64(payload.count),
                    sha256: Self.sha256Hex(payload),
                    downloadURL: URL(string: "https://model.test/shard-1.gguf")!),
                .init(
                    kind: .textModelShard,
                    fileName: "shard-2.gguf",
                    byteCount: Int64(payload.count),
                    sha256: Self.sha256Hex(payload),
                    downloadURL: URL(string: "https://model.test/shard-2.gguf")!),
            ],
            minimumMemoryBytes: 0)
        let installer = ComputerUseInstaller(
            manifest: manifest,
            rootDirectory: root,
            downloadSession: session,
            downloadChunkByteCount: 5)
        var updates: [ComputerUseInstaller.Update] = []

        let directory = try await installer.installModel { updates.append($0) }

        XCTAssertEqual(
            directory,
            root.appendingPathComponent("Models/progress-test", isDirectory: true))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("shard-1.gguf")),
            payload)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("shard-2.gguf")),
            payload)
        XCTAssertEqual(RangeServingURLProtocol.requestedRanges().first, "bytes=7-11")
        let downloadedAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("shard-2.gguf").path)
        let permissions = try XCTUnwrap(
            downloadedAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o111, 0)
        let fractions = updates.compactMap(\.fraction)
        XCTAssertEqual(
            fractions.first ?? -1,
            ComputerUseInstaller.installerFractionForModel(
                downloadedByteCount: Int64(payload.count + 7),
                totalByteCount: Int64(payload.count * 2)),
            accuracy: 0.000_001)
        XCTAssertEqual(fractions.last ?? -1, 0.95, accuracy: 0.000_001)
        XCTAssertTrue(fractions.contains(where: { $0 > 0.05 && $0 < 0.95 }))
        XCTAssertTrue(updates.allSatisfy { $0.detail.contains(" of ") })
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
    }

    func test_modelInstallerRejectsExecutableOrCredentialedArtifactBeforeNetwork() async {
        for (fileName, url) in [
            ("model.bin", "https://example.invalid/model.bin"),
            ("../model.gguf", "https://example.invalid/model.gguf"),
            ("model.gguf", "https://user:secret@example.invalid/model.gguf"),
        ] {
            let manifest = ComputerUseArtifactManifest(
                installationVersion: "invalid-test",
                modelVariant: .pro4B,
                modelRepository: "owner/model",
                modelRevision: "revision",
                modelArtifacts: [.init(
                    kind: .textModelShard,
                    fileName: fileName,
                    byteCount: 1,
                    sha256: String(repeating: "a", count: 64),
                    downloadURL: URL(string: url)!)],
                minimumMemoryBytes: 0)
            let installer = ComputerUseInstaller(manifest: manifest)
            do {
                try await installer.preflight()
                XCTFail("Expected invalid data-only manifest for \(fileName)")
            } catch let error as ComputerUseInstaller.InstallError {
                guard case .invalidManifest = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeEnvelope(
        kind: ComputerUseEnvelope.Kind,
        body: String = ""
    ) -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            senderID: "IOS-PEER",
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: "SESSION-1",
            kind: kind,
            body: body)
    }

    private func temporaryLedgerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseLedgerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    private func testManifest(
        minimumMemoryBytes: UInt64
    ) -> ComputerUseArtifactManifest {
        ComputerUseArtifactManifest(
            installationVersion: "test-v1",
            modelVariant: .pro4B,
            modelRepository: "test/model",
            modelRevision: "revision",
            modelArtifacts: [.init(
                kind: .textModelShard,
                fileName: "model.gguf",
                byteCount: 1,
                sha256: String(repeating: "a", count: 64),
                downloadURL: URL(string: "https://example.invalid/model.gguf")!)],
            minimumMemoryBytes: minimumMemoryBytes)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0 ..< timeoutIterations {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Computer Use state")
    }
}

private final class RangeServingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var ranges: [String] = []

    static func configure(payload: Data) {
        lock.withLock {
            self.payload = payload
            ranges = []
        }
    }

    static func reset() {
        lock.withLock {
            payload = Data()
            ranges = []
        }
    }

    static func requestedRanges() -> [String] {
        lock.withLock { ranges }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let range = request.value(forHTTPHeaderField: "Range"),
              let byteRange = Self.parse(range) else {
            client?.urlProtocol(self, didFailWithError:
                ComputerUseHTTPDownloader.DownloadError.invalidRangeResponse)
            return
        }
        let data = Self.lock.withLock { () -> Data in
            Self.ranges.append(range)
            return Self.payload
        }
        guard byteRange.lowerBound >= 0,
              byteRange.upperBound < data.count,
              byteRange.lowerBound <= byteRange.upperBound else {
            client?.urlProtocol(self, didFailWithError:
                ComputerUseHTTPDownloader.DownloadError.invalidRangeResponse)
            return
        }
        let body = data.subdata(in: byteRange.lowerBound ..< (byteRange.upperBound + 1))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(data.count)",
                "Content-Length": "\(body.count)",
            ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ value: String) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let pieces = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        guard pieces.count == 2,
              let start = Int(pieces[0]),
              let end = Int(pieces[1]) else { return nil }
        return start ... end
    }
}

@MainActor
private final class ImmediateComputerUseExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Test runtime"
    private(set) var prompts: [String] = []
    private var results: [ComputerUseExecutionResult]
    var callCount: Int { prompts.count }

    init(results: [ComputerUseExecutionResult]) {
        self.results = results
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        prompts.append(prompt)
        return results.isEmpty ? .completed("Done") : results.removeFirst()
    }
}

@MainActor
private final class SuspendingComputerUseExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Suspending test runtime"
    private(set) var prompts: [String] = []

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        prompts.append(prompt)
        try await Task.sleep(for: .seconds(60))
        return .completed("Done")
    }
}

private final class ShutdownCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    func markObserved() {
        lock.withLock { observed = true }
    }

    func value() -> Bool {
        lock.withLock { observed }
    }
}

@MainActor
private final class ShutdownBlockingComputerUseExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Shutdown-blocking test runtime"
    private let cancellationProbe = ShutdownCancellationProbe()
    private var continuation: CheckedContinuation<ComputerUseExecutionResult, Never>?
    private(set) var started = false

    nonisolated var cancellationWasObserved: Bool {
        cancellationProbe.value()
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        started = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: { [cancellationProbe] in
            cancellationProbe.markObserved()
        }
    }

    func release() {
        continuation?.resume(returning: .completed("Done"))
        continuation = nil
    }
}

@MainActor
private final class ShutdownRecordingVisualLoader: ComputerUseVisualExecutorLoading {
    private(set) var deactivationCount = 0

    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting {
        ImmediateComputerUseExecutor(results: [.completed("Done")])
    }

    func deactivate() async {
        deactivationCount += 1
    }
}

@MainActor
private final class ShutdownCompletionProbe {
    var finished = false
}

private struct CapturedCGEvent {
    let type: CGEventType
    let location: CGPoint
    let clickCount: Int64
    let horizontalScrollDelta: Int64
    let verticalScrollDelta: Int64
    let unicodeText: String?
    let keyCode: Int64
    let modifierFlags: CGEventFlags
    let syntheticTag: Int64
}

private final class CapturedCGEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CapturedCGEvent] = []

    func append(_ event: CGEvent) {
        var actualLength = 0
        var codeUnits = [UniChar](repeating: 0, count: 64)
        codeUnits.withUnsafeMutableBufferPointer { buffer in
            event.keyboardGetUnicodeString(
                maxStringLength: buffer.count,
                actualStringLength: &actualLength,
                unicodeString: buffer.baseAddress)
        }
        let unicodeText = actualLength > 0
            ? String(decoding: codeUnits.prefix(actualLength), as: UTF16.self)
            : nil
        let snapshot = CapturedCGEvent(
            type: event.type,
            location: event.location,
            clickCount: event.getIntegerValueField(.mouseEventClickState),
            horizontalScrollDelta: event.getIntegerValueField(
                .scrollWheelEventPointDeltaAxis2),
            verticalScrollDelta: event.getIntegerValueField(
                .scrollWheelEventPointDeltaAxis1),
            unicodeText: unicodeText,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            modifierFlags: event.flags,
            syntheticTag: event.getIntegerValueField(.eventSourceUserData))
        lock.withLock { snapshots.append(snapshot) }
    }

    func values() -> [CapturedCGEvent] {
        lock.withLock { snapshots }
    }
}

private actor FakeHostComputerUseChannel: HostComputerUseChannel {
    private var sent: [ComputerUseEnvelope] = []

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: "HOST-ID",
            targetID: explicitTargetID ?? "IOS-PEER",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "SESSION-1",
            kind: kind,
            body: body)
        sent.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] { [] }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func sentMessages() -> [ComputerUseEnvelope] { sent }
}
