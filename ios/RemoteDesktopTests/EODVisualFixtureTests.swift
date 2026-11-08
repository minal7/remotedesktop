import SwiftUI
import UIKit
import XCTest
@testable import RemoteDesktop

/// Fixture-driven layout evidence of the real SwiftUI view. Fixed rectangles do
/// not reproduce physical-device safe areas, keyboard, video, or system UI.
@MainActor
final class EODVisualFixtureTests: XCTestCase {
    func testComputerUseActualViewMatrix() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Fixture rendering is Simulator-only and does not establish physical-device behavior.")
        #endif
        guard ProcessInfo.processInfo.environment["RUN_EOD_FIXTURE_REVIEW"] == "1" else {
            throw XCTSkip("Opt in to generate private fixture screenshots.")
        }
        let states = ["computer-prompt", "computer-running", "computer-approval", "computer-done", "computer-stopping", "computer-error"]
        for state in states {
            let channel = ReviewChannel()
            let model = ComputerUseSessionModel(hostName: "Studio Mac", pairingCode: "123456", hostID: "HOST-ID",
                sessionID: "session-1", pendingStore: ReviewStore(), channel: channel)
            model.start()
            defer { model.stop() }
            if state != "computer-prompt" {
                XCTAssertTrue(model.sendPrompt("Open Calculator."))
                let prompt = try await channel.sentPrompt()
                switch state {
                case "computer-approval":
                    let approval = ComputerUseApprovalRequest(taskID: prompt.id,
                        message: "This is the first use of an untrusted app or site.",
                        details: [.init(label: "Action", value: #"{"type":"open_app","name":"Calculator"}"#)])
                    await channel.deliver(kind: .approvalRequest, body: try approval.encodedBody())
                    try await waitUntil { if case .approvalRequired = model.state { return true }; return false }
                case "computer-stopping":
                    model.stopCurrentTask()
                    XCTAssertEqual(model.statusText, "Stopping the task…")
                case "computer-done", "computer-error":
                    let outcome: ComputerUseTerminalOutcome = state == "computer-done" ? .taskCompleted : .unableToComplete
                    let text = state == "computer-done" ? "Opened Calculator." : "The task could not be completed."
                    await channel.deliver(kind: .assistant, body: try ComputerUseTaskUpdate(taskID: prompt.id, text: text, outcome: outcome).encodedBody())
                    try await waitUntil { model.latestTerminalOutcome == outcome }
                default: break
                }
            }
            let session = SessionModel()
            for (device, portrait) in [("small-iphone", CGSize(width: 375, height: 667)),
                                       ("pro-max", CGSize(width: 430, height: 932)),
                                       ("ipad", CGSize(width: 1024, height: 1366))] {
                for orientation in ["portrait", "landscape"] {
                    let size = orientation == "portrait" ? portrait : CGSize(width: portrait.height, height: portrait.width)
                    for appearance in ["light", "dark"] {
                        try capture(model: model, session: session, state: state, device: device, size: size,
                            orientation: orientation, appearance: appearance, textSize: .large, textLabel: "standard")
                    }
                }
            }
            if state == "computer-approval" {
                try capture(model: model, session: session, state: state, device: "small-iphone",
                    size: CGSize(width: 375, height: 667), orientation: "portrait", appearance: "light",
                    textSize: .accessibility3, textLabel: "large")
            }
            model.stop()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ReviewFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func capture(model: ComputerUseSessionModel, session: SessionModel, state: String,
                         device: String, size: CGSize, orientation: String, appearance: String,
                         textSize: DynamicTypeSize, textLabel: String) throws {
        let root = ComputerUseView(model: model).environmentObject(session)
            .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.horizontalSizeClass, device == "ipad" ? .regular : .compact)
        let controller = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "A Simulator window scene is required for actual view rendering.")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "fixture--\(state)--\(device)--\(orientation)--\(appearance)--\(textLabel)--image"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum ReviewFailure: Error { case timeout }

private actor ReviewChannel: ComputerUseSessionChannel {
    private var prompt: ComputerUseEnvelope?
    private var incoming: [ComputerUseEnvelope] = []
    func send(kind: ComputerUseEnvelope.Kind, body: String, to target: String?, sessionID: String?, messageID: String?) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(id: messageID ?? UUID().uuidString, senderID: "IOS-ID", targetID: target ?? "HOST-ID",
            pairingCode: "123456", sessionID: sessionID ?? "session-1", kind: kind, body: body)
        if kind == .prompt { prompt = envelope }
        return envelope
    }
    func poll() async throws -> [ComputerUseEnvelope] {
        while incoming.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let result = incoming; incoming.removeAll(); return result
    }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
    func sentPrompt() async throws -> ComputerUseEnvelope {
        let deadline = ContinuousClock.now + .seconds(3)
        while prompt == nil {
            guard ContinuousClock.now < deadline else { throw ReviewFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        return prompt!
    }
    func deliver(kind: ComputerUseEnvelope.Kind, body: String) {
        incoming.append(.init(senderID: "HOST-ID", targetID: "IOS-ID", pairingCode: "123456", sessionID: "session-1", kind: kind, body: body))
    }
}

private final class ReviewStore: ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: ComputerUsePendingPrompt?
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        guard record?.hostID == hostID, record?.pairingCode == pairingCode else { return nil }
        return record
    }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool { lock.lock(); defer { lock.unlock() }; record = pending; return true }
    func remove(hostID: String) { lock.lock(); defer { lock.unlock() }; if record?.hostID == hostID { record = nil } }
}
