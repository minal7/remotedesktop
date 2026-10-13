import Foundation
import XCTest
@testable import RemoteDesktopHost

final class GUIOwlPolicyAdapterTests: XCTestCase {
    private let imageSize = (width: 640, height: 240)

    func testClickVariantsScaleNormalizedCoordinatesToAttachedNonSquarePNG() throws {
        let cases: [(String, AgentAction)] = [
            ("left_click", .click(target: .point(x: 160, y: 180), button: nil, count: nil)),
            ("right_click", .click(target: .point(x: 160, y: 180), button: .right, count: nil)),
            ("middle_click", .click(target: .point(x: 160, y: 180), button: .middle, count: nil)),
            ("double_click", .click(target: .point(x: 160, y: 180), button: nil, count: 2)),
            ("triple_click", .click(target: .point(x: 160, y: 180), button: nil, count: 3)),
        ]

        for (name, expected) in cases {
            let raw = completion(["action": name, "coordinate": [250, 750]])
            XCTAssertEqual(try action(raw), expected, name)
        }
    }

    func testNormalizedCoordinateEdgesClampToLastPNGPixel() throws {
        let first = try action(completion(["action": "left_click", "coordinate": [0, 0]]))
        let last = try action(completion(["action": "left_click", "coordinate": [1000, 1000]]))

        XCTAssertEqual(first, .click(target: .point(x: 0, y: 0), button: nil, count: nil))
        XCTAssertEqual(last, .click(target: .point(x: 639, y: 239), button: nil, count: nil))
    }

    func testKeyChordNormalizesArrowAliasesAndTypePreservesExactText() throws {
        let key = try action(completion(["action": "key", "keys": ["Control", "ArrowLeft"]]))
        let scalarKey = try action(completion(["action": "key", "keys": "Return"]))
        let hotkeyAlias = try action(completion(["action": "hotkey", "keys": ["Command", "a"]]))
        let text = "  東京 e\u{301} 😀\n<tool_call>literal</tool_call>  "
        let typed = try action(completion(["action": "type", "text": text]))

        XCTAssertEqual(key, .key(chord: "Control+left"))
        XCTAssertEqual(scalarKey, .key(chord: "Return"))
        XCTAssertEqual(hotkeyAlias, .key(chord: "Command+a"))
        XCTAssertEqual(typed, .type(target: nil, text: text, mode: .append))
    }

    func testScrollConvertsNativeWheelNotchesAndKeepsPositiveUpSign() throws {
        let oneNotch = try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: 1)
        let threeNotches = try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: 3)
        let negativeNotches = try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: -3)
        let up = try action(completion(["action": "scroll", "pixels": 3]))
        let downAtPoint = try action(completion(["action": "scroll", "pixels": -2,
            "coordinate": [250, 750]]))

        XCTAssertGreaterThan(oneNotch, 0)
        XCTAssertEqual(threeNotches, oneNotch * 3, accuracy: 0.001)
        XCTAssertEqual(negativeNotches, threeNotches, accuracy: 0.001)
        XCTAssertEqual(up, .scroll(target: nil, direction: .up, amount: threeNotches))
        XCTAssertEqual(downAtPoint, .scroll(target: .point(x: 160, y: 180), direction: .down,
            amount: try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: 2)))
    }

    func testWaitUsesPCDefaultAndEnforcesAgentContractBounds() throws {
        XCTAssertEqual(try action(completion(["action": "wait"])), .wait(seconds: 2))
        XCTAssertEqual(try action(completion(["action": "wait", "time": 10])), .wait(seconds: 10))
        for seconds in [0, -1, 10.01, 11] {
            XCTAssertThrowsError(try action(completion(["action": "wait", "time": seconds])), "time=\(seconds)")
        }
    }

    func testAnswerTerminateAndInteractKeepTheirDistinctHostMeanings() throws {
        XCTAssertEqual(try action(completion(["action": "answer", "text": "Observed result"])),
            .done(answer: "Observed result"))
        XCTAssertEqual(try action(completion(["action": "terminate", "status": "success"])),
            .done(answer: "Completed."))
        guard case .fail(let failure) = try action(completion(["action": "terminate", "status": "failure"])) else {
            return XCTFail("A failed terminal status must remain a failure")
        }
        XCTAssertFalse(failure.isEmpty)
        XCTAssertEqual(try action(completion(["action": "interact", "text": "Please handle this dialog."])),
            .askUser(question: "Please handle this dialog.", choices: nil))
        XCTAssertEqual(try action(completion(["action": "call_user"])),
            .askUser(question: "Please perform the requested manual operation.", choices: nil))
    }

    func testActionsWithoutARepresentableHostEffectFailWithoutInventingClicks() throws {
        for arguments: [String: Any] in [
            ["action": "mouse_move", "coordinate": [500, 500]],
            ["action": "left_click_drag", "coordinate": [500, 500]],
        ] {
            guard case .fail(let reason) = try action(completion(arguments)) else {
                return XCTFail("Unsupported pointer-only action must fail honestly")
            }
            XCTAssertFalse(reason.isEmpty)
        }

        guard case .fail(let horizontalReason) = try action(completion(["action": "hscroll", "pixels": 4])) else {
            return XCTFail("The pinned PC runner does not implement hscroll")
        }
        XCTAssertFalse(horizontalReason.isEmpty)
    }

    func testMalformedToolCallsAndUnboundedValuesAreRejected() throws {
        let malformed = [
            "Action: Wait.\n<tool_call>{\"name\":\"other\",\"arguments\":{\"action\":\"wait\",\"time\":1}}</tool_call>",
            "Action: Wait.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1,\"extra\":true}}</tool_call>",
            "Action: Wait.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1}}</tool_call>\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1}}</tool_call>",
            "Action: Wait.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1,\"time\":2}}</tool_call>",
            "Action: \n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1}}</tool_call>",
            "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1}}</tool_call>",
            "Action: Wait.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1}} trailing</tool_call>",
            "Action: Wait.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":1e999}}</tool_call>",
        ]
        for raw in malformed { XCTAssertThrowsError(try action(raw), raw) }

        for arguments in [
            #"{"action":"left_click","coordinate":[-1,0]}"#,
            #"{"action":"left_click","coordinate":[1001,0]}"#,
            #"{"action":"left_click","coordinate":[true,0]}"#,
            #"{"action":"scroll","pixels":1.5}"#,
            #"{"action":"scroll","pixels":0}"#,
            #"{"action":"scroll","pixels":10001}"#,
            #"{"action":"key","keys":[]}"#,
            #"{"action":"key","keys":["Enter",""]}"#,
            #"{"action":"key","keys":["Enter",7]}"#,
            #"{"action":"unknown_action"}"#,
        ] {
            let raw = "Action: Apply one step.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":\(arguments)}</tool_call>"
            XCTAssertThrowsError(try action(raw), arguments)
        }
        XCTAssertThrowsError(try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: 0))
        XCTAssertThrowsError(try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: 10_001))
        XCTAssertThrowsError(try GUIOwlPolicyAdapter.nativeWheelPixelAmount(forNotches: 10_000),
            "Converted scroll distances must stay within the host action limit")

        XCTAssertThrowsError(try GUIOwlPolicyAdapter.canonicalActionJSON(
            fromCompletion: completion(["action": "wait", "time": 1]), imageSize: (0, 240)))
        XCTAssertThrowsError(try GUIOwlPolicyAdapter.canonicalActionJSON(
            fromCompletion: completion(["action": "wait", "time": 1]), imageSize: (640, 0)))
    }

    private func action(_ raw: String) throws -> AgentAction {
        let json = try GUIOwlPolicyAdapter.canonicalActionJSON(fromCompletion: raw, imageSize: imageSize)
        return try JSONDecoder().decode(AgentAction.self, from: Data(json.utf8))
    }

    private func completion(_ arguments: [String: Any], action: String = "Apply one visible step.") -> String {
        let call = try! JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": arguments],
            options: [.sortedKeys, .withoutEscapingSlashes])
        return "Action: \(action)\n<tool_call>\(String(decoding: call, as: UTF8.self))</tool_call>"
    }
}
