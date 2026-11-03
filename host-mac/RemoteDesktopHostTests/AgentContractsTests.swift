import Foundation
import XCTest
@testable import RemoteDesktopHost

final class AgentContractsTests: XCTestCase {
    func testEveryActionVariantRoundTripsWithTheFlatDiscriminator() throws {
        let fixtures: [(String, AgentAction)] = [
            (#"{"type":"click","target":{"id":0},"button":"right","count":2}"#, .click(target: .element(id: 0), button: .right, count: 2)),
            (#"{"type":"click","target":{"x":1.5,"y":2}}"#, .click(target: .point(x: 1.5, y: 2), button: nil, count: nil)),
            (#"{"type":"type","text":"Ada","mode":"replace"}"#, .type(target: nil, text: "Ada", mode: .replace)),
            (#"{"type":"type","target":{"id":8},"text":"!","mode":"append"}"#, .type(target: .element(id: 8), text: "!", mode: .append)),
            (#"{"type":"key","chord":"cmd+l"}"#, .key(chord: "cmd+l")),
            (#"{"type":"scroll","target":{"x":3,"y":4},"direction":"down","amount":2.5}"#, .scroll(target: .point(x: 3, y: 4), direction: .down, amount: 2.5)),
            (#"{"type":"select","target":{"id":4},"option":"April"}"#, .select(target: .element(id: 4), option: "April")),
            (#"{"type":"drag","from":{"id":1},"to":{"x":5,"y":6}}"#, .drag(from: .element(id: 1), to: .point(x: 5, y: 6))),
            (#"{"type":"open_url","url":"https://example.test/path"}"#, .openURL(url: "https://example.test/path")),
            (#"{"type":"open_app","name":"TextEdit"}"#, .openApp(name: "TextEdit")),
            (#"{"type":"find_files","query":"notes","kind":"document","modified_after":"2026-10-12T12:00:00.123Z"}"#, .findFiles(query: "notes", kind: "document", modifiedAfter: "2026-10-12T12:00:00.123Z")),
            (#"{"type":"set_files","target":{"id":3},"file_ids":["f-1","f-2"]}"#, .setFiles(target: .element(id: 3), fileIDs: ["f-1", "f-2"])),
            (#"{"type":"wait","seconds":10}"#, .wait(seconds: 10)),
            (#"{"type":"ask_user","question":"Which one?","choices":["A","B"]}"#, .askUser(question: "Which one?", choices: ["A", "B"])),
            (#"{"type":"done","answer":"Saved the note."}"#, .done(answer: "Saved the note.")),
            (#"{"type":"fail","reason":"The window is unavailable."}"#, .fail(reason: "The window is unavailable."))
        ]

        for (json, expected) in fixtures {
            let decoded = try decode(AgentAction.self, json)
            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(try decode(AgentAction.self, data: JSONEncoder().encode(decoded)), expected)
            XCTAssertEqual(decoded.type, expected.type)
        }
    }

    func testActionRejectsUnknownKeysInvalidTargetsNullOptionalsAndOutOfRangeNumbers() {
        let invalid = [
            #"{"type":"wait","seconds":1,"extra":true}"#,
            #"{"type":"click","target":{"id":2,"x":1,"y":2}}"#,
            #"{"type":"click","target":{"x":1,"y":2,"id":0}}"#,
            #"{"type":"click","target":{"id":-1}}"#,
            #"{"type":"click","target":{"x":1e999,"y":2}}"#,
            #"{"type":"type","text":"x","mode":"replace","target":null}"#,
            #"{"type":"wait","seconds":0}"#,
            #"{"type":"wait","seconds":10.01}"#,
            #"{"type":"scroll","direction":"up","amount":1e999}"#,
            #"{"type":"open_url","url":"not a uri"}"#,
            #"{"type":"open_url","url":"https://example.test/a b"}"#,
            #"{"type":"find_files","query":"x","modified_after":"yesterday"}"#,
            #"{"type":"set_files","target":{"id":0},"file_ids":[]}"#,
            #"{"type":"ask_user","question":"?","choices":null}"#
        ]
        for json in invalid { XCTAssertThrowsError(try decode(AgentAction.self, json), json) }

        XCTAssertThrowsError(try JSONEncoder().encode(AgentAction.wait(seconds: .infinity)))
        XCTAssertThrowsError(try JSONEncoder().encode(AgentAction.click(target: .point(x: .nan, y: 0), button: nil, count: nil)))
    }

    func testObservationRoundTripsExactFieldsAndKeepsSecureValuesRedacted() throws {
        let json = #"{"task":"Fill the form","surface":{"kind":"web","url":"https://example.test","title":"Example"},"screenshot":"base64-png","elements":[{"id":1,"role":"textbox","name":"Search","value":"password reset guide","state":["enabled"],"bbox":[0,1,100,20],"in_view":true},{"id":2,"role":"AXSecureTextField","name":"Secret","value":null,"state":["enabled"],"bbox":[2,3,80,20],"in_view":true},{"id":3,"role":"button","name":"Password help","value":"Help","state":["enabled"],"bbox":[4,5,50,20],"in_view":false}],"focus":null,"history":[{"action":{"type":"click","target":{"id":1}},"result":"ok"}],"budget":{"step":6,"max_steps":40}}"#
        let observation = try decode(AgentObservation.self, json)
        XCTAssertNil(observation.focus)
        XCTAssertEqual(observation.elements[0].value, "password reset guide", "ordinary text must not be treated as a secure field")
        XCTAssertNil(observation.elements[1].value)
        XCTAssertEqual(observation.elements[2].value, "Help", "element names do not determine secure status")
        let roundTripped = try decode(AgentObservation.self, data: JSONEncoder().encode(observation))
        XCTAssertEqual(roundTripped, observation)
    }

    func testObservationRejectsStructuralErrorsAndSecureValueLeaks() {
        let good = #"{"task":"t","surface":{"kind":"app","app":"com.example.App"},"screenshot":"png","elements":[],"focus":null,"history":[],"budget":{"step":0,"max_steps":1}}"#
        let invalid = [
            good.replacingOccurrences(of: #""focus":null"#, with: #""focus":null,"extra":1"#),
            good.replacingOccurrences(of: #""focus":null"#, with: #""focus":{"id":1,"role":"textbox","name":"x","value_prefix":"a"}"#),
            good.replacingOccurrences(of: #""budget":{"step":0,"max_steps":1}"#, with: #""budget":{"step":2,"max_steps":1}"#),
            good.replacingOccurrences(of: #""elements":[]"#, with: #""elements":[{"id":1,"role":"textbox","name":"a","value":null,"state":[],"bbox":[0,0,1,1],"in_view":true},{"id":1,"role":"textbox","name":"b","value":null,"state":[],"bbox":[0,0,1,1],"in_view":true}]"#),
            good.replacingOccurrences(of: #""elements":[]"#, with: #""elements":[{"id":1,"role":"password","name":"Password","value":"leaked","state":[],"bbox":[0,0,1,1],"in_view":true}]"#),
            good.replacingOccurrences(of: #""elements":[]"#, with: #""elements":[{"id":1,"role":"textbox","name":"OTP","value":"leaked","state":["one-time-code"],"bbox":[0,0,1,1],"in_view":true}]"#),
            good.replacingOccurrences(of: #""budget":{"step":0,"max_steps":1}"#, with: #""budget":{"step":0,"max_steps":1},"oops":true"#)
        ]
        for json in invalid { XCTAssertThrowsError(try decode(AgentObservation.self, json), json) }

        let secureFocus = good.replacingOccurrences(of: #""focus":null"#, with: #""focus":{"id":9,"role":"textbox","name":"Code","value_prefix":"123456","selection":[0,6]}"#)
            .replacingOccurrences(of: #""elements":[]"#, with: #""elements":[{"id":9,"role":"textbox","name":"Code","value":null,"state":["secure-entry"],"bbox":[0,0,1,1],"in_view":true}]"#)
        XCTAssertThrowsError(try decode(AgentObservation.self, secureFocus))

        let invalidEncode = AgentObservation(task: "t", surface: .app(bundleID: "app", title: nil), screenshot: "png",
                                             elements: [AgentElement(id: 1, role: "securetextfield", name: "x", value: "secret", state: [], bbox: .init(x: 0, y: 0, width: 1, height: 1), inView: true)],
                                             focus: nil, history: [], budget: .init(step: 0, maxSteps: 1))
        XCTAssertThrowsError(try JSONEncoder().encode(invalidEncode))
    }

    func testEpisodeStepAndFooterRoundTripAsJSONLLines() throws {
        let observation = AgentObservation(task: "Open a page", surface: .web(url: "https://example.test", title: nil), screenshot: "png",
                                          elements: [], focus: nil, history: [], budget: .init(step: 1, maxSteps: 40))
        let step = AgentEpisodeStep(episodeID: "episode-1", step: 1, observation: observation, promptVersion: "v1",
                                    rawModelOutput: "{bad json", action: nil, gate: .init(decision: .rejected, reason: "malformed"),
                                    execution: .init(status: .notExecuted, result: "no effect"),
                                    timings: .init(observationMS: 1, policyMS: 2, gateMS: 3, executionMS: 0, recordMS: 1, totalMS: 7))
        let footer = AgentEpisodeFooter(episodeID: "episode-1", outcome: "failed", approvals: [], corrections: ["Use the correct tab"], checkerVerdict: "not_run")
        for record in [AgentEpisodeRecord.step(step), .footer(footer)] {
            let bytes = try JSONEncoder().encode(record)
            XCTAssertEqual(try decode(AgentEpisodeRecord.self, data: bytes), record)
        }
    }

    func testEpisodeRejectsUnknownKeysNullOptionalsAndBadTimingValues() {
        let invalid = [
            #"{"type":"footer","episode_id":"e","outcome":"ok","approvals":[],"corrections":[],"extra":false}"#,
            #"{"type":"footer","episode_id":"e","outcome":"ok","approvals":[],"corrections":[],"checker_verdict":null}"#,
            #"{"type":"step","episode_id":"e","step":0,"observation":{"task":"t","surface":{"kind":"app","app":"x"},"screenshot":"p","elements":[],"focus":null,"history":[],"budget":{"step":0,"max_steps":1}},"prompt_version":"v1","raw_model_output":"","action":null,"gate":{"decision":"allowed","reason":""},"execution":{"status":"ok","result":""},"timings":{"observation_ms":-1,"policy_ms":0,"gate_ms":0,"execution_ms":0,"record_ms":0,"total_ms":0}}"#
        ]
        for json in invalid { XCTAssertThrowsError(try decode(AgentEpisodeRecord.self, json), json) }
    }

    func testSharedCrossLanguageContractCorpus() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testsDirectory.deletingLastPathComponent().appendingPathComponent("AcceptanceFixtures/agent-contracts.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[String: Any]])
        XCTAssertFalse(root.isEmpty)
        for entry in root {
            let kind = try XCTUnwrap(entry["kind"] as? String)
            let valid = try XCTUnwrap(entry["valid"] as? Bool)
            let name = try XCTUnwrap(entry["name"] as? String)
            let payload = try XCTUnwrap(entry["payload"])
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed, .sortedKeys])
            switch kind {
            case "action": try assertCorpusEntry(AgentAction.self, data: data, valid: valid, name: name)
            case "observation": try assertCorpusEntry(AgentObservation.self, data: data, valid: valid, name: name)
            case "episode": try assertCorpusEntry(AgentEpisodeRecord.self, data: data, valid: valid, name: name)
            default: XCTFail("Unknown corpus kind \(kind)")
            }
        }
    }

    private func assertCorpusEntry<T: Codable & Equatable>(_ type: T.Type, data: Data, valid: Bool, name: String) throws {
        if valid {
            let value = try JSONDecoder().decode(type, from: data)
            XCTAssertEqual(try JSONDecoder().decode(type, from: JSONEncoder().encode(value)), value, name)
        } else {
            XCTAssertThrowsError(try JSONDecoder().decode(type, from: data), name)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decode(type, data: Data(json.utf8))
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
