import AppKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentNativeObservationTests: XCTestCase {
    func testNativePolicyContextsOmitOffscreenAndDegenerateMarksAcrossCoordinateFrames() async throws {
        let png = try makePNG()
        let targetBox = AgentBoundingBox(x: 32, y: 20, width: 16, height: 8)
        let marks = [
            AgentElement(id: 17, role: "AXButton", name: "Target", value: nil, state: ["enabled"], bbox: targetBox, inView: true),
            AgentElement(id: 18, role: "AXMenuBarItem", name: "File", value: nil, state: ["visible", "read_only", "offscreen"],
                bbox: .init(x: 0, y: 0, width: 0, height: 0), inView: false),
            AgentElement(id: 19, role: "AXButton", name: "Offscreen control", value: nil, state: ["read_only", "offscreen"],
                bbox: .init(x: 8, y: 4, width: 30, height: 12), inView: false),
            AgentElement(id: 20, role: "AXButton", name: "Degenerate control", value: nil, state: ["visible"],
                bbox: .init(x: 40, y: 20, width: 0, height: 12), inView: true),
        ]
        let observation = AgentObservation(task: "Use the visible target", surface: .app(bundleID: "example.app", title: nil),
            screenshot: png.base64EncodedString(), elements: marks, focus: nil, history: [],
            budget: .init(step: 0, maxSteps: 5))
        try observation.validate()
        XCTAssertEqual(observation.elements.map(\.id), [17, 18, 19, 20])
        let canonicalJSON = try LlamaVLMPolicy.observationJSON(observation)
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonicalJSON.utf8)) as? [String: Any])
        let canonicalMarks = try XCTUnwrap(canonical["elements"] as? [[String: Any]])
        XCTAssertEqual(canonicalMarks.compactMap { $0["id"] as? Int }, [17, 18, 19, 20])

        for model in AgentPolicyModel.allCases {
            let transport = NativeObservationTransport(response: try nativeWaitResponse(for: model))
            let policy = try LlamaVLMPolicy(transport: transport, prompt: "test policy prompt", model: model)
            let output = try await policy.propose(observation)
            XCTAssertEqual(output.action, .wait(seconds: model == .uiTars15_7b ? 5 : 1), "native action parse for \(model)")

            let request = try XCTUnwrap(transport.inputs.first)
            let userMessage = try XCTUnwrap(request.messages.last(where: { $0.role == .user }))
            let userText = try XCTUnwrap(userMessage.content.compactMap { part -> String? in
                if case .text(let text) = part { return text }; return nil
            }.first)
            let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(userText.utf8)) as? [String: Any])
            let requestMarks = try XCTUnwrap(requestJSON["elements"] as? [[String: Any]])
            XCTAssertEqual(requestMarks.compactMap { $0["id"] as? Int }, [17], "outbound native marks for \(model)")
            XCTAssertFalse(userText.contains("File"))
            XCTAssertFalse(userText.contains("Offscreen control"))
            XCTAssertFalse(userText.contains("Degenerate control"))
        }
    }

    private func nativeWaitResponse(for model: AgentPolicyModel) throws -> String {
        let body = #"{"name":"computer_use","arguments":{"action":"wait","time":1}}"#
        if model == .uiTars15_7b {
            let response: [String: Any] = ["model": "ui-tars15-7b-v1", "choices": [[
                "finish_reason": "stop", "message": ["role": "assistant", "content": "Thought: wait.\nAction: wait()"]
            ]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        }
        let prefix = model == .guiOwl15_4b ? "Action: Wait.\n" : ""
        return prefix + "<tool_call>" + body + "</tool_call>"
    }

    private func makePNG() throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<100 {
            for x in 0..<100 { image.setColor(.white, atX: x, y: y) }
        }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class NativeObservationTransport: AgentVLMTransport {
    let response: String
    private(set) var inputs: [AgentVLMRequestInput] = []
    init(response: String) { self.response = response }
    func complete(_ input: AgentVLMRequestInput) async throws -> String { inputs.append(input); return response }
    func stop() async {}
}
