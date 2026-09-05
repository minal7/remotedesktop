import AppKit
import ApplicationServices
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseNativeTextIntegrationTests: XCTestCase {
    func testRealNativeFieldsReceiveExactVerifiedEdits() async throws {
        try await runFixture(browser: false)
    }

    func testRealBrowserFieldsReceiveExactVerifiedEdits() async throws {
        try await runFixture(browser: true)
    }

    private func runFixture(browser: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_NATIVE_TEXT_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Use host-mac/scripts/run_text_edit_acceptance.sh on a prepared Mac")
        }
        guard AXIsProcessTrusted() else {
            return XCTFail("Accessibility permission is required for the opt-in live native test")
        }
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["COMPUTER_USE_TEXT_FIXTURE_EXECUTABLE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let state = directory.appendingPathComponent("state.json")
        let previousApp = NSWorkspace.shared.frontmostApplication
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [state.path]
        if browser { process.arguments?.append("--browser") }
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            previousApp?.activate(options: [])
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0 ..< 100 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier,
               FileManager.default.fileExists(atPath: state.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier)
        // WebKit publishes AX focus asynchronously after DOM focus. A visible
        // window and loaded DOM do not yet prove editable Accessibility focus.
        let readiness = ComputerUseAccessibilityTextTarget()
        for _ in 0..<80 {
            if readiness.snapshot() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let injector = InputInjector()
        let tools = ComputerUseHostTools(injector: injector, mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
        })
        // The fixture reports values through its own app state, independently
        // of the Accessibility readback used by the production text editor.
        let exact = "  \nTokyo 東京 e\u{301} 👨‍👩‍👧‍👦 😀\n" + String(repeating: "x", count: 2_000) + "\n  "
        do {
            try await tools.performVerified(.typeText(exact))
        } catch {
            if let bytes = try? Data(contentsOf: state),
               let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                for name in ["origin", "destination"] {
                    let value = fields[name] as? String ?? ""
                    print("Fixture \(name): \(value.utf8.count) bytes; prefix=\(String(value.prefix(35)).debugDescription)")
                }
            }
            if let value = readiness.snapshot() {
                print("Fixture AX: \(value.value.utf8.count) bytes; prefix=\(String(value.value.prefix(35)).debugDescription)")
            }
            throw error
        }
        try await verify(state, field: "origin", equals: exact)
        try await tools.editFocusedText("San Francisco", mode: .replaceAll)
        try await verify(state, field: "origin", equals: "San Francisco")
        try await tools.editFocusedText(" — appended", mode: .append)
        try await verify(state, field: "origin", equals: "San Francisco — appended")

        let root = AXUIElementCreateApplication(process.processIdentifier)
        let destination = try XCTUnwrap(findElement(id: "destination", root: root))
        XCTAssertEqual(AXUIElementSetAttributeValue(destination, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        try await Task.sleep(for: .milliseconds(100))
        try await tools.performVerified(.typeText("San Francisco"))
        try await verify(state, field: "destination", equals: "San Francisco")
        try await verify(state, field: "origin", equals: "San Francisco — appended")

        // Exercise real Unicode events as well as the preferred AX setter.
        try await tools.editFocusedText("", mode: .replaceAll)
        let textTarget = ComputerUseAccessibilityTextTarget()
        let snapshot = try XCTUnwrap(textTarget.snapshot())
        var postedChunks = 0
        let fallbackEditor = ComputerUseTextEditor(
            read: { textTarget.snapshot() },
            select: { textTarget.select($0) },
            replaceSelectedText: { _ in nil },
            postUnicode: { text in
                postedChunks += 1
                guard await injector.applyTextPaced(text, ifAllowed: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
                }) else { throw ComputerUseTextEditError.interrupted }
            },
            mayAct: { NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier })
        do {
            try await fallbackEditor.edit(exact, expected: snapshot)
        } catch {
            if let current = textTarget.snapshot() {
                print("Unicode fixture result: \(current.value.utf8.count) bytes; prefix=\(String(current.value.prefix(45)).debugDescription); chunks=\(postedChunks)")
            }
            try await Task.sleep(for: .seconds(1))
            if let bytes = try? Data(contentsOf: state),
               let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                for name in ["destination", "rawDestination"] {
                    print("Unicode after settling \(name): \((fields[name] as? String ?? "").utf8.count) bytes")
                }
            }
            print("AX after settling: \(textTarget.snapshot()?.value.utf8.count ?? -1) bytes")
            throw error
        }
        XCTAssertGreaterThan(postedChunks, 1)
        try await verify(state, field: "destination", equals: exact)

        // Whole natural-language task through real proposal, AX discovery,
        // journaled steps and independent final-state verification.
        if ProcessInfo.processInfo.environment["RUN_NATIVE_TEXT_GOALS_MODEL_ACCEPTANCE"] == "1" {
            let executor = ComputerUseNativeTextExecutor(injector: injector, mayAct: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
            }, journalDirectory: directory.appendingPathComponent("steps"))
            let result = try await executor.execute(taskID: "native-form-\(browser)",
                prompt: "Set both Origin and Destination to San Francisco.", progress: { _ in })
            guard case .completed = result else { return XCTFail("The complete field task must verify both edits") }
            try await verify(state, field: "origin", equals: "San Francisco")
            try await verify(state, field: "destination", equals: "San Francisco")
        }
        let beforeReplacement = try XCTUnwrap(textTarget.snapshot())
        try "replace-destination".write(to: state.appendingPathExtension("command"), atomically: true, encoding: .utf8)
        var replaced = false
        for _ in 0..<100 {
            if let bytes = try? Data(contentsOf: state),
               let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               value["generation"] as? Int == 1 { replaced = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(replaced, "Fixture must actually replace the control")
        XCTAssertNil(textTarget.snapshot(targetID: beforeReplacement.targetID),
                     "An old reference cannot target a new control with the same value, label and geometry")
        let afterReplacement = try XCTUnwrap(textTarget.snapshot())
        XCTAssertNotEqual(afterReplacement.targetID, beforeReplacement.targetID)
        XCTAssertTrue(afterReplacement.value.utf8.elementsEqual(beforeReplacement.value.utf8))
    }

    private func verify(_ state: URL, field: String, equals expected: String) async throws {
        for _ in 0 ..< 100 {
            if let bytes = try? Data(contentsOf: state),
               let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let actual = fields[field] as? String,
               actual.utf8.elementsEqual(expected.utf8) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The fixture app did not report the exact intended value for \(field)")
    }

    private func findElement(id: String, root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 150 {
            let element = queue.removeFirst()
            visited += 1
            var value: CFTypeRef?
            for name in [kAXIdentifierAttribute as String, "AXDOMIdentifier"] {
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   value as? String == id { return element }
            }
            for attribute in [kAXWindowsAttribute, kAXChildrenAttribute] {
                value = nil
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let children = value as? [AXUIElement] { queue.append(contentsOf: children) }
            }
        }
        return nil
    }

}
