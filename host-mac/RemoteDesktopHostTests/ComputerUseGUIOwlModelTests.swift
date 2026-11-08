import AppKit
import CryptoKit
import Foundation
import WebKit
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseGUIOwlModelTests: XCTestCase {
    func packet(_ arguments: [String: Any], actionLine: String = "Perform this step.") throws -> Data {
        let call = try JSONSerialization.data(withJSONObject: ["name":"computer_use", "arguments":arguments], options: [.sortedKeys, .withoutEscapingSlashes])
        return try packet(content: "Action: " + actionLine + "\n<tool_call>\n" + String(decoding: call, as: UTF8.self) + "\n</tool_call>")
    }
    func packet(content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model":ComputerUseGUIOwlModel.modelAlias, "choices":[["finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
    func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    var endpoint: OSAtlasLlamaEndpoint {
        .init(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
    }

    func testNativeWirePreservesExactInputAndSeparatesStatusHandoffAndWheelUnits() throws {
        let text = "  東京 e\u{301} 😀\n\t<tool_call>literal</tool_call>  "
        let typed = try ComputerUseGUIOwlModel.decode(packet(["action":"type", "text":text], actionLine: "The task is complete."))
        XCTAssertEqual(typed.decision, .browser(.typeText(text)))
        guard case .browser(.typeText(let value)) = typed.decision else { return XCTFail("Expected exact insertion") }
        XCTAssertEqual(Array(value.utf8), Array(text.utf8))
        XCTAssertEqual(try ComputerUseGUIOwlModel.decode(packet(["action":"left_click", "coordinate":[920,688]])).decision, .browser(.pointer(.leftClick,.init(x:920,y:688))))
        XCTAssertEqual(try ComputerUseGUIOwlModel.decode(packet(["action":"key", "keys":["Enter"]])).decision, .browser(.key(["Enter"])))
        XCTAssertEqual(try ComputerUseGUIOwlModel.decode(packet(["action":"wait", "time":0.2])).decision, .browser(.wait(0.2)))
        XCTAssertEqual(try ComputerUseGUIOwlModel.decode(packet(["action":"answer", "text":"Observed facts"], actionLine:"Wrong facts")).decision, .browser(.reportCompletion("Observed facts")))
        for success in [true,false] {
            let parsed = try ComputerUseGUIOwlModel.decode(packet(["action":"terminate", "status":success ? "success" : "failure"]))
            XCTAssertEqual(parsed.decision, .terminalStatus(success:success))
        }
        let handoff = try ComputerUseGUIOwlModel.decode(packet(["action":"interact", "text":"Please take control."]))
        XCTAssertEqual(handoff.decision,.handoff("Please take control."))
        for horizontal in [true,false] {
            let scroll = try ComputerUseGUIOwlModel.decode(packet(["action":horizontal ? "hscroll" : "scroll", "pixels":-3.5]))
            XCTAssertEqual(scroll.decision,.wheel(horizontal:horizontal,amount:-3.5))
        }
        let middle = try ComputerUseGUIOwlModel.decode(packet(["action":"middle_click", "coordinate":[0,1000]]))
        XCTAssertEqual(middle.decision,.middleClick(.init(x:0,y:1000)))
    }
    func testMalformedOrForeignNativeCallsCannotBecomeActions() throws {
        let invalid = [
            #"{"action":"type","text":"one","text":"two"}"#,
            #"{"action":"type","text":"x","enter":true}"#, #"{"action":"type","text":true}"#,
            #"{"action":"answer","text":" "}"#, #"{"action":"terminate","answer":"Made-up facts"}"#,
            #"{"action":"terminate","status":"done"}"#, #"{"action":"terminate","status":true}"#,
            #"{"action":"interact","text":""}"#, #"{"action":"scroll","pixels":true}"#,
            #"{"action":"scroll","pixels":10001}"#, #"{"action":"hscroll","pixels":"4"}"#,
            #"{"action":"left_click","coordinate":[true,0]}"#, #"{"action":"left_click","coordinate":[0,1001]}"#,
            #"{"action":"middle_click","coordinate":[-1,2]}"#, #"{"action":"key","keys":["Enter","Enter"]}"#,
            #"{"action":"key","keys":[]}"#, #"{"action":"wait","time":31}"#,
            #"{"action":"web_search","query":"tickets"}"#, #"{"action":"visit_url","url":"https://example.com"}"#,
            #"{"action":"ask_user_question","question":"City?"}"#
        ]
        for args in invalid {
            XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(packet(content:"Action: Do it.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":" + args + "}</tool_call>")),args)
        }
        let valid = "Action: Wait.\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
        for content in [valid+valid,valid+" trailing",String(valid.dropLast()),"<think>"+valid,valid.replacingOccurrences(of:"Action: Wait.",with:"Action: \n"),valid.replacingOccurrences(of:"computer_use",with:"execute_code")] {
            XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(packet(content:content)))
        }
        for mode in ["length","wrong-model","wrong-role","reasoning-only","multiple-choices","extra-tool-call"] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with:packet(content:valid)) as? [String:Any])
            var choices = root["choices"] as! [[String:Any]], message = choices[0]["message"] as! [String:Any]
            switch mode {
            case "length": choices[0]["finish_reason"]="length"
            case "wrong-model": root["model"]="fara-browser-v1"
            case "wrong-role": message["role"]="user"
            case "reasoning-only": message["reasoning_content"]=valid;message["content"]=""
            case "extra-tool-call": message["tool_calls"]=[]
            default:break
            }
            choices[0]["message"]=message
            if mode=="multiple-choices" { choices.append(choices[0]) }
            root["choices"]=choices
            XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(JSONSerialization.data(withJSONObject:root)),mode)
        }
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(Data(#"{"model":"gui-owl-desktop-v1","model":"gui-owl-desktop-v1","choices":[]}"#.utf8)))
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(Data(repeating:32,count:1_048_577)))
    }
    func testRequestUsesPinnedDesktopRecipeAndRetainsOriginalResultBinding() throws {
        let image = try png(), source = URL(string:"https://example.com/public")!, reply = "  Kyoto e\u{301} 😀\n  "
        let native = try ComputerUseGUIOwlModel.decode(packet(["action":"wait","time":0]))
        let originalResult = ComputerUseFaraModel.Step.ResultObservation(currentURL:source,userResponse:reply,actionError:"Original not-sent result")
        let history = [ComputerUseFaraModel.Step(screenshotPNG:image,response:native.response,currentURL:source,resultObservation:originalResult)]
        let goal = "Find tickets. Stop before selecting tickets."
        let input = ComputerUseFaraModel.Input(goal:goal,screenshotPNG:image,history:history,currentURL:source,actionError:"Different current error")
        let request = try ComputerUseGUIOwlModel.makeRequest(endpoint:endpoint,input:input)
        XCTAssertEqual(request.url?.path,"/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as? [String:Any])
        XCTAssertEqual(body["model"] as? String,ComputerUseGUIOwlModel.modelAlias)
        XCTAssertEqual(body["temperature"] as? Double,0);XCTAssertNil(body["tools"]);XCTAssertNil(body["tool_choice"])
        XCTAssertEqual(body["max_tokens"] as? Int,1024)
        let messages = try XCTUnwrap(body["messages"] as? [[String:Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system","user","assistant","user"])
        guard messages.count == 4 else { return XCTFail("Native screenshot/action pairs must be retained") }
        let system = try XCTUnwrap((messages[0]["content"] as? [[String:String]])?.first?["text"])
        XCTAssertEqual(system.utf8.count,4465)
        XCTAssertEqual(SHA256.hash(data:Data(system.utf8)).map { String(format:"%02x",$0) }.joined(),"094160a5f8abf424690465500d9169244e065947505e9b48c3acabfbf815df9b")
        let blocks = try XCTUnwrap(messages[1]["content"] as? [[String:Any]])
        XCTAssertEqual(blocks.count,2)
        let summary = try XCTUnwrap(blocks[0]["text"] as? String)
        XCTAssertTrue(summary.hasPrefix("Please generate the next move according to the UI screenshot, instruction and previous actions.\n\nInstruction: "+goal+"\n\nPrevious actions:\nNo previous action."))
        XCTAssertFalse(summary.contains(native.response))
        XCTAssertEqual((messages[2]["content"] as? [[String:String]])?.first?["text"],native.response)
        let currentBlocks = try XCTUnwrap(messages[3]["content"] as? [[String:Any]])
        let current = try XCTUnwrap(currentBlocks.first?["text"] as? String)
        let original = try XCTUnwrap(current.components(separatedBy:"Previous action outcome: ").dropFirst().first?.components(separatedBy:"\n\nCurrent observation: ").first)
        let parsed = try JSONDecoder().decode([String:String].self,from:Data(original.utf8))
        XCTAssertEqual(parsed["observed_url"],source.absoluteString)
        XCTAssertEqual(parsed["user_response"]?.utf8.map { $0 },Array(reply.utf8))
        XCTAssertEqual(parsed["error"],"Original not-sent result")
        XCTAssertTrue(current.hasSuffix("\"Different current error\",\"observed_url\":\"https://example.com/public\"}"))
        XCTAssertEqual((blocks[1]["image_url"] as? [String:String])?["url"],"data:image/png;base64,"+image.base64EncodedString())
        var invalid=input;invalid.history[0] = .init(screenshotPNG:image,response: #"<tool_call>{"name":"computer_use","arguments":{"action":"wait","time":0}}</tool_call>"#)
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.makeRequest(endpoint:endpoint,input:invalid))
    }
    func testHistoryKeepsTwoRecentImageActionPairsAndOnlySummarizesTheOmittedPrefix() throws {
        let image = try png(), source = URL(string:"https://example.com/public")!
        let history = try (0..<5).map { index in
            ComputerUseFaraModel.Step(screenshotPNG:image,
                response:try ComputerUseGUIOwlModel.decode(packet(["action":"wait","time":index])).response,
                currentURL:source,actionError:"Before-\(index)",
                resultObservation:.init(currentURL:source,userResponse:nil,actionError:"Outcome-\(index)"))
        }
        let input = ComputerUseFaraModel.Input(goal:"Original complete goal",screenshotPNG:image,history:history,currentURL:source,actionError:"Current-only")
        let request = try ComputerUseGUIOwlModel.makeRequest(endpoint:endpoint,input:input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as? [String:Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String:Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String },["system","user","assistant","user","assistant","user"])
        guard messages.count == 6 else { return XCTFail("History must have a bounded native role sequence") }
        func text(_ index:Int) throws -> String { try XCTUnwrap((messages[index]["content"] as? [[String:Any]])?.first?["text"] as? String) }
        let first = try text(1)
        XCTAssertTrue(first.contains("Instruction: Original complete goal"))
        for index in 0..<3 {
            XCTAssertTrue(first.contains("Step\(index+1): "+history[index].response))
            XCTAssertTrue(first.contains("Outcome-\(index)"))
        }
        XCTAssertFalse(first.contains(history[3].response));XCTAssertFalse(first.contains(history[4].response))
        XCTAssertTrue(first.hasSuffix("\"Before-3\",\"observed_url\":\"https://example.com/public\"}"))
        XCTAssertEqual(try text(2),history[3].response);XCTAssertEqual(try text(4),history[4].response)
        XCTAssertTrue(try text(3).contains("Outcome-3"));XCTAssertTrue(try text(3).contains("Before-4"))
        XCTAssertTrue(try text(5).contains("Outcome-4"));XCTAssertTrue(try text(5).contains("Current-only"))
        XCTAssertEqual(messages.flatMap { $0["content"] as? [[String:Any]] ?? [] }.filter { $0["type"] as? String == "image_url" }.count,3)
    }
    func testRequestRejectsUnboundedOrUnsupportedInputBeforeSending() throws {
        let image=try png();let original=ComputerUseFaraModel.Input(goal:"Search for tickets.",screenshotPNG:image)
        for mode in ["empty-goal","large-goal","invalid-image","many-steps","invalid-url","page-reading","large-error","large-reply","invalid-history-image"] {
            var input=original
            switch mode {
            case "empty-goal":input = .init(goal:" ",screenshotPNG:image)
            case "large-goal":input = .init(goal:String(repeating:"x",count:8193),screenshotPNG:image)
            case "invalid-image":input = .init(goal:original.goal,screenshotPNG:Data())
            case "many-steps":input.history=Array(repeating:.init(screenshotPNG:image,response:"invalid"),count:21)
            case "invalid-url":input.currentURL=URL(string:"file:///private")
            case "page-reading":input.pageReading = .init(sourceURL:URL(string:"https://example.com")!,question:"Price?",text:"Unverified",truncated:false,omittedEmbeddedContent:false)
            case "large-error":input.actionError=String(repeating:"x",count:16385)
            case "large-reply":input.userResponse=String(repeating:"x",count:8193)
            case "invalid-history-image":input.history=[.init(screenshotPNG:Data(),response:try ComputerUseGUIOwlModel.decode(packet(["action":"wait","time":0])).response)]
            default:break
            }
            XCTAssertThrowsError(try ComputerUseGUIOwlModel.makeRequest(endpoint:endpoint,input:input),mode)
        }
        let remote=OSAtlasLlamaEndpoint(generation:1,variant:nil,baseURL:URL(string:"https://example.com")!,bearerToken:"fixture")
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.makeRequest(endpoint:remote,input:original))
    }
}

@MainActor
enum GUIOwlTestProposalRunner {
    static func propose(input:ComputerUseFaraModel.Input,directory:URL,index:Int,environment:[String:String],
                        registerProbe: (HoloProbeProcess) -> Void = { _ in }) async throws -> ComputerUseGUIOwlModel.Proposal {
        let endpoint=OSAtlasLlamaEndpoint(generation:1,variant:nil,baseURL:URL(string:"http://127.0.0.1:43123")!,bearerToken:"unused-diagnostic-request")
        let request=try ComputerUseGUIOwlModel.makeRequest(endpoint:endpoint,input:input)
        let requestFile=directory.appendingPathComponent("request-\(index).json")
        guard !FileManager.default.fileExists(atPath:requestFile.path) else { throw ComputerUseFaraAction.Failure.invalidResponse }
        try XCTUnwrap(request.httpBody).write(to:requestFile)
        let output=directory.appendingPathComponent("proposal-\(index)"),probe=HoloProbeProcess()
        registerProbe(probe)
        try probe.start(python:try XCTUnwrap(environment["GUI_OWL_PYTHON"]),script:try XCTUnwrap(environment["GUI_OWL_PROBE_SCRIPT"]),arguments:[requestFile.path,output.path,try XCTUnwrap(environment["GUI_OWL_ASSETS"]),try XCTUnwrap(environment["GUI_OWL_BINARY"]),"4"])
        let status=try await probe.finish()
        let report=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("report.json"))) as? [String:Any])
        XCTAssertEqual(report["ownedProcessExited"] as? Bool,true);XCTAssertEqual(report["credentialRemoved"] as? Bool,true)
        guard status==0 else { throw ComputerUseFaraAction.Failure.invalidResponse }
        return try ComputerUseGUIOwlModel.decode(Data(contentsOf:output.appendingPathComponent("response.json")))
    }
}
