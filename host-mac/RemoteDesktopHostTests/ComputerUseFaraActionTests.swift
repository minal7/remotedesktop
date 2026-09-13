import Foundation
import AppKit
import WebKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseFaraActionTests: XCTestCase {
    func testOptInDecodeFrozenModelProposalAgainstIndependentDOMOracle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_FROZEN_PROPOSAL_CHECK"] == "1" else { throw XCTSkip("Opt-in: inspect a recorded model proposal without input effects") }
        let responseURL = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_RESPONSE_PATH"]))
        let oracleURL = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_ORACLE_PATH"]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any])
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? String)
        let action = try ComputerUseFaraAction.decodeNativeMessage(content)
        guard case .pointer(.leftClick, let point) = action else { return XCTFail("The actual model must propose one Destination click") }
        let oracle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: oracleURL)) as? [String: Any])
        let bounds = try XCTUnwrap(oracle["destination"] as? [String: Double])
        let width = try XCTUnwrap(oracle["imageWidth"] as? Int), height = try XCTUnwrap(oracle["imageHeight"] as? Int)
        let pixel = try point.pixel(width: width, height: height)
        let pageX = Double(pixel.x) * (try XCTUnwrap(bounds["viewportWidth"])) / Double(width)
        let pageY = Double(pixel.y) * (try XCTUnwrap(bounds["viewportHeight"])) / Double(height)
        let left = try XCTUnwrap(bounds["left"]), top = try XCTUnwrap(bounds["top"])
        // The oracle comes from the original DOM and was never included in the model request.
        XCTAssertGreaterThan(pageX, left + 8)
        XCTAssertLessThan(pageX, left + (try XCTUnwrap(bounds["width"])) - 8)
        XCTAssertGreaterThan(pageY, top + 8)
        XCTAssertLessThan(pageY, top + (try XCTUnwrap(bounds["height"])) - 8)
    }

    @MainActor
    func testOptInRenderFrozenBrowserGroundingFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_FROZEN_FIXTURE"] == "1" else { throw XCTSkip("Opt-in: render only a local fictional form") }
        let directory = URL(fileURLWithPath: try XCTUnwrap(environment["FARA_FROZEN_FIXTURE_DIRECTORY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pngURL = directory.appendingPathComponent("browser.png"), oracleURL = directory.appendingPathComponent("oracle.json")
        guard !FileManager.default.fileExists(atPath: pngURL.path), !FileManager.default.fileExists(atPath: oracleURL.path) else {
            throw ComputerUseFaraAction.Failure.invalidResponse
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1188, height: 768))
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString("""
            <!doctype html><html><head><meta charset='utf-8'><title>Local travel form</title>
            <style>body{font:22px system-ui;background:#f4f7fa;color:#152c41;margin:60px}main{width:820px}label{display:block;margin:36px 0 10px;font-weight:600}input{box-sizing:border-box;width:100%;height:70px;font:24px system-ui;padding:16px;border:2px solid #8195a7;border-radius:8px;background:white}button{margin-top:32px;padding:16px 40px;font:22px system-ui}</style></head>
            <body><main><h1>Travel details</h1><p>Local computer-use test — fictional form</p>
            <label for='origin'>Origin</label><input id='origin' value='Seattle'>
            <label for='destination'>Destination</label><input id='destination' value=''>
            <button type='button'>Search</button></main></body></html>
            """, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        var ready = false
        while ContinuousClock.now < deadline {
            ready = (try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('destination')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(ready)
        let observedBounds = try await webView.evaluateJavaScript("""
            (()=>{const r=document.getElementById('destination').getBoundingClientRect();return {left:r.left,top:r.top,width:r.width,height:r.height,viewportWidth:innerWidth,viewportHeight:innerHeight};})()
            """)
        let oracle = try XCTUnwrap(observedBounds as? [String: Any])
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 1188
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0); XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        try png.write(to: pngURL, options: .atomic)
        try JSONSerialization.data(withJSONObject: ["goal": "Click the Destination field.", "destination": oracle,
            "imageWidth": bitmap.pixelsWide, "imageHeight": bitmap.pixelsHigh, "scope": "native-WebKit-local-fictional-form-no-effects"], options: [.prettyPrinted, .sortedKeys]).write(to: oracleURL, options: .atomic)
    }

    private func call(_ arguments: String) -> String {
        "<tool_call>{\"name\":\"computer_use\",\"arguments\":\(arguments)}</tool_call>"
    }

    func testNativeNarrativeIsSeparateFromExactlyOneValidatedAction() throws {
        let click = call(#"{"action":"left_click","coordinate":[392,540]}"#)
        XCTAssertEqual(try ComputerUseFaraAction.decodeNativeMessage("The Destination field is below Origin.\n" + click),
                       .pointer(.leftClick, .init(x: 392, y: 540)))
        XCTAssertEqual(try ComputerUseFaraAction.decodeNativeMessage(click), .pointer(.leftClick, .init(x: 392, y: 540)))
        let payload = "literal <tool_call> and </tool_call> in the requested text"
        let arguments = try JSONSerialization.data(withJSONObject: ["action": "type", "text": payload])
        XCTAssertEqual(try ComputerUseFaraAction.decodeNativeMessage("The field is focused.\n" + call(String(decoding: arguments, as: UTF8.self))), .typeText(payload))
        for response in ["Only notes", "Notes\n" + click + click, "Notes\n" + click + "afterward",
                         "Notes <tool_call>malformed\n" + click, "Notes </tool_call>\n" + click,
                         String(repeating: "x", count: 32_768) + click] {
            XCTAssertThrowsError(try ComputerUseFaraAction.decodeNativeMessage(response))
        }
        // Call-only entry points cannot accidentally treat arbitrary prose as executable.
        XCTAssertThrowsError(try ComputerUseFaraAction.decode("Notes\n" + click))
    }

    func testDecodesOfficialClickAndExactUnicodeTyping() throws {
        let click = try ComputerUseFaraAction.decode(call(#"{"action":"left_click","coordinate":[500,250.5]}"#))
        XCTAssertEqual(click, .pointer(.leftClick, .init(x: 500, y: 250.5)))
        let payload = "  東京 e\u{301} 😀\n<tool_call>literal</tool_call>  "
        let arguments = try JSONSerialization.data(withJSONObject: ["action": "type", "text": payload])
        let action = try ComputerUseFaraAction.decode(call(String(decoding: arguments, as: UTF8.self)))
        guard case .typeText(let text) = action else { return XCTFail("Typing cannot imply a Return or another action") }
        XCTAssertTrue(text.utf8.elementsEqual(payload.utf8))
    }

    func testRejectsMalformedMultipleUnknownAndAmbiguousCalls() throws {
        let valid = call(#"{"action":"left_click","coordinate":[500,250]}"#)
        let invalid = ["", valid + valid, "Run this: " + valid, String(valid.dropLast()),
            call(#"{"action":"shell","text":"echo unexpected"}"#),
            call(#"{"action":"type","action":"key","text":"secret"}"#),
            call(#"{"action":"left_click","coordinate":[true,250]}"#),
            call(#"{"action":"left_click","coordinate":[-1,250]}"#),
            call(#"{"action":"left_click","coordinate":[1001,250]}"#),
            call(#"{"action":"left_click","coordinate":[1,2,3]}"#),
            call(#"{"action":"left_click","coordinate":[1,2],"text":"unrelated"}"#),
            call(#"{"action":"type"}"#), call(#"{"action":"key","keys":[]}"#),
            call(#"{"action":"visit_url","url":"javascript:alert(1)"}"#),
            call(#"{"action":"visit_url","url":"https://user:password@example.com/"}"#),
            call(#"{"action":"wait","time":-1}"#),
            valid.replacingOccurrences(of: "computer_use", with: "another_tool")]
        for response in invalid {
            XCTAssertThrowsError(try ComputerUseFaraAction.decode(response)) {
                XCTAssertEqual($0 as? ComputerUseFaraAction.Failure, .invalidResponse)
            }
        }
    }

    func testSeparatesUserHandoffAndReportedCompletionFromInput() throws {
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"ask_user_question","question":"Please sign in."}"#)), .askUser("Please sign in."))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"terminate","answer":"Found a concert."}"#)), .reportCompletion("Found a concert."))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"web_search","query":"Los Angeles concerts"}"#)), .webSearch("Los Angeles concerts"))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"visit_url","url":"https://example.com/events?q=live"}"#)), .visitURL(try XCTUnwrap(URL(string: "https://example.com/events?q=live"))))
        XCTAssertEqual(try ComputerUseFaraAction.decode(call(#"{"action":"key","keys":["Control","a"]}"#)), .key(["Control", "a"]))
    }

    func testMapsNormalizedPointsToCurrentImageCellsWithoutEscapingEdges() throws {
        let origin = try ComputerUseFaraAction.Point(x: 0, y: 0).pixel(width: 1188, height: 768)
        XCTAssertEqual(origin.x, 0); XCTAssertEqual(origin.y, 0)
        let middle = try ComputerUseFaraAction.Point(x: 500, y: 250).pixel(width: 1188, height: 768)
        XCTAssertEqual(middle.x, 594); XCTAssertEqual(middle.y, 192)
        let edge = try ComputerUseFaraAction.Point(x: 1000, y: 1000).pixel(width: 1188, height: 768)
        XCTAssertEqual(edge.x, 1187); XCTAssertEqual(edge.y, 767)
        let tiny = try ComputerUseFaraAction.Point(x: 999, y: 999).pixel(width: 1, height: 1)
        XCTAssertEqual(tiny.x, 0); XCTAssertEqual(tiny.y, 0)
        for point in [ComputerUseFaraAction.Point(x: .nan, y: 0), .init(x: .infinity, y: 0), .init(x: -1, y: 0), .init(x: 1001, y: 0)] {
            XCTAssertThrowsError(try point.pixel(width: 1188, height: 768))
        }
        XCTAssertThrowsError(try ComputerUseFaraAction.Point(x: 0, y: 0).pixel(width: 0, height: 768))
        XCTAssertThrowsError(try ComputerUseFaraAction.Point(x: 0, y: 0).pixel(width: Int.max, height: 768))
    }
}
