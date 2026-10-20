import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentMacOSCompatibilityTests: XCTestCase {
    func testFaraMapsGenericMacShortcutsBeforeActionValidation() throws {
        let cases: [(String, String, String?)] = [
            ("CTRL+A", "cmd+a", "mapped ctrl+a → cmd+a"),
            ("ctrl+shift+z", "cmd+shift+z", "mapped ctrl+shift+z → cmd+shift+z"),
            ("ctrl+home", "cmd+up", "mapped ctrl+home → cmd+up"),
            ("ctrl+end", "cmd+down", "mapped ctrl+end → cmd+down"),
            ("home", "cmd+left", "mapped home → cmd+left"),
            ("end", "cmd+right", "mapped end → cmd+right"),
            ("alt+left", "cmd+[", "mapped alt+left → cmd+["),
            ("alt+right", "cmd+]", "mapped alt+right → cmd+]"),
            ("alt+arrowleft", "cmd+[", "mapped alt+arrowleft → cmd+["),
            ("alt+arrowright", "cmd+]", "mapped alt+arrowright → cmd+]"),
            ("ctrl+tab", "ctrl+tab", nil),
        ]

        for (native, chord, note) in cases {
            let raw = completion(#"{"action":"key","keys":["\#(native.replacingOccurrences(of: "+", with: "\",\""))"]}"#)
            let action = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: raw, imageSize: (1280, 720))
            XCTAssertEqual(try JSONDecoder().decode(AgentAction.self, from: Data(action.utf8)), .key(chord: chord), native)
            XCTAssertEqual(try FaraPolicyAdapter.resultLineNote(fromCompletion: raw), note, native)
        }
    }

    func testFaraRejectsApplicationSwitchChordWithGenericRecoveryHint() throws {
        let raw = completion(#"{"action":"key","keys":["alt","tab"]}"#)
        XCTAssertThrowsError(try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: raw, imageSize: (1280, 720))) { error in
            guard case FaraPolicyAdapter.Failure.unsupportedProposal(let reason) = error else {
                return XCTFail("Expected an unsupported proposal, got \(error)")
            }
            XCTAssertEqual(reason, "Use open_app to switch apps.")
        }
    }

    func testFaraNativeOpenAppMapsToTheExistingGenericAction() throws {
        let raw = completion(#"{"action":"open_app","name":"Example Editor"}"#)
        let action = try FaraPolicyAdapter.canonicalActionJSON(fromCompletion: raw, imageSize: (1280, 720))
        XCTAssertEqual(try JSONDecoder().decode(AgentAction.self, from: Data(action.utf8)), .openApp(name: "Example Editor"))
    }

    func testKeyParserCoversPrintableUSKeysNavigationAndModifierAliases() throws {
        let usages: [(String, Int)] = [
            ("a", 0x04), ("z", 0x1D), ("1", 0x1E), ("0", 0x27),
            ("-", 0x2D), ("=", 0x2E), ("[", 0x2F), ("]", 0x30), ("\\", 0x31),
            (";", 0x33), ("'", 0x34), ("`", 0x35), (",", 0x36), (".", 0x37), ("/", 0x38),
            ("!", 0x1E), ("@", 0x1F), ("#", 0x20), ("$", 0x21), ("%", 0x22),
            ("^", 0x23), ("&", 0x24), ("*", 0x25), ("(", 0x26), (")", 0x27),
            ("_", 0x2D), ("plus", 0x2E), ("{", 0x2F), ("}", 0x30), ("|", 0x31),
            (":", 0x33), ("\"", 0x34), ("~", 0x35), ("<", 0x36), (">", 0x37), ("?", 0x38),
            ("A", 0x04),
            ("f1", 0x3A), ("f2", 0x3B), ("f3", 0x3C), ("f4", 0x3D),
            ("f5", 0x3E), ("f6", 0x3F), ("f7", 0x40), ("f8", 0x41),
            ("f9", 0x42), ("f10", 0x43), ("f11", 0x44), ("f12", 0x45),
            ("f13", 0x68), ("f14", 0x69), ("f15", 0x6A), ("f16", 0x6B),
            ("f17", 0x6C), ("f18", 0x6D), ("f19", 0x6E), ("f20", 0x6F),
            ("left", 0x50), ("right", 0x4F),
            ("up", 0x52), ("down", 0x51), ("home", 0x4A), ("end", 0x4D),
            ("pageup", 0x4B), ("pagedown", 0x4E), ("delete", 0x2A), ("forwarddelete", 0x4C),
            ("escape", 0x29), ("tab", 0x2B), ("space", 0x2C), ("return", 0x28),
        ]
        for (key, usage) in usages {
            let stroke = try AgentKeyStroke.parse(key)
            XCTAssertEqual(stroke.usage, usage, key)
            if key == "A" || "!@#$%^&*()_+{}|:\"~<>?".contains(key) {
                XCTAssertEqual(stroke.modifiers & 1, 1, "Shift required for \(key)")
            }
        }

        XCTAssertEqual(try AgentKeyStroke.parse("+").usage, 0x2e)
        XCTAssertEqual(try AgentKeyStroke.parse("+").modifiers & 1, 1)
        XCTAssertEqual(try AgentKeyStroke.parse("cmd++"), .init(usage: 0x2e, modifiers: 9))
        XCTAssertEqual(try AgentKeyStroke.parse(" ").usage, 0x2c)
        XCTAssertEqual(try AgentKeyStroke.parse("cmd+ ").modifiers, 8)
        let plus = completion(#"{"action":"key","keys":["+"]}"#)
        let commandPlus = completion(#"{"action":"key","keys":["cmd","+"]}"#)
        XCTAssertEqual(try JSONDecoder().decode(AgentAction.self,
            from: Data(try FaraPolicyAdapter.actionJSON(fromCompletion: plus).utf8)), .key(chord: "+"))
        XCTAssertEqual(try JSONDecoder().decode(AgentAction.self,
            from: Data(try FaraPolicyAdapter.actionJSON(fromCompletion: commandPlus).utf8)), .key(chord: "cmd++"))

        XCTAssertEqual(try AgentKeyStroke.parse("meta+option+control+shift+f5").modifiers, 15)
        XCTAssertEqual(try AgentKeyStroke.parse("command+alt+enter").modifiers, 12)
        XCTAssertEqual(try AgentKeyStroke.parse("shift+A"), .init(usage: 0x04, modifiers: 1))
        for modifierOnly in [
            "ctrl", "control", "cmd", "shift", "option", "fn", "function", "globe",
            "ctrl+shift", "cmd+option+control", "fn+globe",
        ] {
            XCTAssertThrowsError(try AgentKeyStroke.parse(modifierOnly), modifierOnly) { error in
                XCTAssertEqual(error as? AgentEnvironmentError, .unavailable("Unsupported key or modifier."))
            }
        }
        for unknown in ["shell+run", "cmd+", "f25", "not-a-key", "\u{1}"] {
            XCTAssertThrowsError(try AgentKeyStroke.parse(unknown), unknown) { error in
                XCTAssertEqual(error as? AgentEnvironmentError, .unavailable("Unsupported key or modifier."))
            }
        }
    }

    func testFaraPromptUsesVersionedGeneralMacOSAppendixAndKeepsNativeActionFormat() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "v2-fara", withExtension: "txt", subdirectory: "policy/prompts"))
        let appendix = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(appendix.split(whereSeparator: \.isWhitespace).count, 125)
        XCTAssertEqual(LlamaVLMPolicy.promptResourceName(for: .fara15_4b), "v2-fara")
        let prompt = LlamaVLMPolicy.nativePrompt(appendix, model: .fara15_4b)
        XCTAssertTrue(appendix.contains("operating macOS"))
        XCTAssertTrue(prompt.contains("operating macOS"))
        XCTAssertTrue(prompt.contains("cmd+shift+g"))
        XCTAssertTrue(prompt.contains("<tool_call>"))
        XCTAssertFalse(prompt.contains("Return exactly one JSON action"))
    }

    func testFaraProgressNarrationStripsNativeThinkEnvelope() throws {
        let narrative = "I can see the window is ready. I will continue with the visible control."
        let toolCall = #"<tool_call>{"name":"computer_use","arguments":{"action":"left_click","coordinate":[500,500]}}</tool_call>"#
        let completions = [
            "<think>\n\(narrative)\n</think>\n\(toolCall)",
            "<think>\n\(narrative)\n\(toolCall)",
        ]
        let ordinary = AgentObservation(task: "A generic task", surface: .app(bundleID: "example.app", title: nil),
            screenshot: "", elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 10))

        for raw in completions {
            let progress = try XCTUnwrap(FaraPolicyAdapter.progressText(fromCompletion: raw))
            let rendered = AgentProgressNarration.text(modelText: progress,
                action: .click(target: .point(x: 500, y: 500), button: nil, count: nil), observation: ordinary)
            XCTAssertEqual(rendered, "I can see the window is ready")
            XCTAssertFalse(rendered.contains("<think>"))
            XCTAssertFalse(rendered.contains("</think>"))
        }
    }

    func testProgressUsesOneShortSentenceAndNeverQuotesSensitiveValues() {
        let ordinary = AgentObservation(task: "A generic task", surface: .app(bundleID: "example.app", title: nil),
            screenshot: "", elements: [], focus: nil, history: [], budget: .init(step: 0, maxSteps: 10))
        let sentence = AgentProgressNarration.text(
            modelText: "The window is ready. Here are unrelated details.", action: .click(target: .point(x: 1, y: 1), button: nil, count: nil),
            observation: ordinary)
        XCTAssertEqual(sentence, "The window is ready")
        XCTAssertLessThanOrEqual(sentence.count, 120)
        XCTAssertEqual(AgentProgressNarration.text(modelText: nil, action: .type(target: nil, text: "private", mode: .append),
            observation: ordinary), "Entering the requested text.")

        let secure = AgentObservation(task: "A generic task", surface: ordinary.surface, screenshot: "",
            elements: [AgentElement(id: 1, role: "AXSecureTextField", name: "Password", value: nil,
                state: ["secure"], bbox: .init(x: 0, y: 0, width: 10, height: 10), inView: true)],
            focus: nil, history: [], budget: .init(step: 0, maxSteps: 10))
        let safe = AgentProgressNarration.text(modelText: "The password is private-value-123.", action: .type(target: nil, text: "private-value-123", mode: .append), observation: secure)
        XCTAssertEqual(safe, "I’m handling a sensitive control carefully.")
        XCTAssertFalse(safe.contains("private-value-123"))
    }

    private func completion(_ arguments: String) -> String {
        "<tool_call>{\"name\":\"computer_use\",\"arguments\":\(arguments)}</tool_call>"
    }
}
