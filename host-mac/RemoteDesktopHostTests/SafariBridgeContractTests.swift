import XCTest
@testable import RemoteDesktopHost

final class SafariBridgeContractTests: XCTestCase {
    func testTypedOpenTabResultBindsOnlyItsReturnedTabAndWindow() throws {
        let token = "0123456789abcdef0123456789abcdef"
        var bindings = SafariBridgeTaskBindings()
        try bindings.register(taskToken: token)
        let open = SafariBridgeCommand(taskToken: token, operation: .openTab, url: "https://drive.google.com/drive/my-drive")

        let wire = try open.encodedJSON()
        XCTAssertEqual(try SafariBridgeCommand.decode(wire), open)
        try bindings.validate(open)
        try bindings.accept(SafariBridgeResult(command: open, status: .ok, tabId: 17, windowId: 4), for: open)

        let boundPing = SafariBridgeCommand(
            taskToken: token, operation: .ping, tabId: 17, windowId: 4, nonce: "fresh")
        XCTAssertNoThrow(try bindings.validate(boundPing))
        XCTAssertThrowsError(try bindings.validate(SafariBridgeCommand(
            taskToken: token, operation: .ping, tabId: 18, windowId: 4, nonce: "fresh")))
        XCTAssertThrowsError(try bindings.validate(SafariBridgeCommand(
            taskToken: token, operation: .ping, tabId: 17, windowId: 5, nonce: "fresh")))
    }

    func testResultMustMatchCommandTaskOperationTabAndNonce() {
        let command = SafariBridgeCommand(
            taskToken: "0123456789abcdef0123456789abcdef",
            operation: .ping,
            tabId: 17,
            windowId: 4,
            nonce: "challenge")

        XCTAssertTrue(SafariBridgeResult(
            command: command, status: .ok, tabId: 17, windowId: 4, nonce: "challenge", documentId: "doc-1")
            .matches(command))
        XCTAssertFalse(SafariBridgeResult(
            command: command, status: .ok, tabId: 18, windowId: 4, nonce: "challenge", documentId: "doc-1")
            .matches(command))
        XCTAssertFalse(SafariBridgeResult(
            command: command, status: .ok, tabId: 17, windowId: 5, nonce: "challenge", documentId: "doc-1")
            .matches(command))
        XCTAssertFalse(SafariBridgeResult(
            command: command, status: .ok, tabId: 17, windowId: 4, nonce: "other", documentId: "doc-1")
            .matches(command))
        XCTAssertFalse(SafariBridgeResult(
            command: command, status: .ok, tabId: 17, windowId: 4, nonce: "challenge")
            .matches(command), "A successful ping must prove it reached the bound frame-0 content script.")
        XCTAssertFalse(SafariBridgeResult(
            command: command, status: .error, tabId: 17, windowId: 4, nonce: "challenge")
            .matches(command), "Error replies must carry a finite error enum.")

        let otherTask = SafariBridgeCommand(
            commandId: UUID(uuidString: command.commandId)!,
            taskToken: "fedcba9876543210fedcba9876543210",
            operation: .ping,
            tabId: 17,
            windowId: 4,
            nonce: "challenge")
        XCTAssertFalse(SafariBridgeResult(
            command: otherTask, status: .ok, tabId: 17, windowId: 4, nonce: "challenge", documentId: "doc-1")
            .matches(command))
    }

    func testTaskTokensAreIndependentAndCannotBeReboundByRegistration() throws {
        let first = "0123456789abcdef0123456789abcdef"
        let second = "fedcba9876543210fedcba9876543210"
        var bindings = SafariBridgeTaskBindings()
        try bindings.register(taskToken: first)
        try bindings.register(taskToken: second)
        XCTAssertThrowsError(try bindings.register(taskToken: first))

        let firstOpen = SafariBridgeCommand(taskToken: first, operation: .openTab, url: "https://drive.google.com/drive/my-drive")
        try bindings.accept(SafariBridgeResult(command: firstOpen, status: .ok, tabId: 17, windowId: 4), for: firstOpen)
        let secondPing = SafariBridgeCommand(
            taskToken: second, operation: .ping, tabId: 17, windowId: 4, nonce: "new-task")
        XCTAssertThrowsError(try bindings.validate(secondPing))

        XCTAssertTrue(bindings.finish(taskToken: first))
        XCTAssertThrowsError(try bindings.validate(SafariBridgeCommand(
            taskToken: first, operation: .ping, tabId: 17, windowId: 4, nonce: "after-end")))
    }

    func testEndTaskMayEchoItsBoundTabAndClearsAuthority() throws {
        let token = "0123456789abcdef0123456789abcdef"
        var bindings = SafariBridgeTaskBindings()
        try bindings.register(taskToken: token)
        let open = SafariBridgeCommand(taskToken: token, operation: .openTab, url: "https://drive.google.com/drive/my-drive")
        try bindings.accept(SafariBridgeResult(command: open, status: .ok, tabId: 17, windowId: 4), for: open)

        let end = SafariBridgeCommand(taskToken: token, operation: .endTask)
        XCTAssertTrue(SafariBridgeResult(command: end, status: .ok, tabId: 17, windowId: 4).matches(end))
        XCTAssertTrue(SafariBridgeResult(command: end, status: .ok).matches(end))
        try bindings.accept(SafariBridgeResult(command: end, status: .ok, tabId: 17, windowId: 4), for: end)
        XCTAssertThrowsError(try bindings.validate(SafariBridgeCommand(
            taskToken: token, operation: .ping, tabId: 17, windowId: 4, nonce: "after-detach")))
    }

    func testPingErrorCanCorrelateWithoutTabMetadata() {
        let command = SafariBridgeCommand(
            taskToken: "0123456789abcdef0123456789abcdef",
            operation: .ping,
            tabId: 17,
            windowId: 4,
            nonce: "challenge")
        XCTAssertTrue(SafariBridgeResult(command: command, status: .error, error: .missingPageAccess).matches(command))
        XCTAssertFalse(SafariBridgeResult(command: command, status: .error).matches(command))
    }

    func testGenericHTTPSAndLoopbackHTTPAreAllowedButCredentialAndDangerousSchemesAreRejected() {
        let token = "0123456789abcdef0123456789abcdef"
        XCTAssertFalse(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "file:///tmp/a")
            .isStructurallyValid)
        XCTAssertFalse(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "javascript:alert(1)")
            .isStructurallyValid)
        XCTAssertFalse(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "https://user:pass@drive.google.com/")
            .isStructurallyValid)
        XCTAssertFalse(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "http://example.com/")
            .isStructurallyValid)
        XCTAssertFalse(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "http://127.attacker.example/")
            .isStructurallyValid)
        XCTAssertFalse(SafariBridgeCommand(taskToken: token, operation: .endTask, tabId: 17, windowId: 4)
            .isStructurallyValid)
        XCTAssertFalse(SafariBridgeCommand(taskToken: "０123456789abcdef0123456789abcde", operation: .openTab, url: "https://mail.google.com/")
            .isStructurallyValid)
        XCTAssertTrue(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "https://example.org/search?q=general")
            .isStructurallyValid)
        XCTAssertTrue(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "http://127.0.0.1:8765/forms/basic.html")
            .isStructurallyValid)
        XCTAssertTrue(SafariBridgeCommand(taskToken: token, operation: .openTab, url: "https://example.org:8443/path")
            .isStructurallyValid)
    }

    func testTypedDOMCommandRequiresBoundTaskTabAndCorrelatedResult() throws {
        let token = "0123456789abcdef0123456789abcdef"
        var bindings = SafariBridgeTaskBindings(); try bindings.register(taskToken: token)
        let open = SafariBridgeCommand(taskToken: token, operation: .openTab, url: "https://example.org/")
        try bindings.accept(SafariBridgeResult(command: open, status: .ok, tabId: 17, windowId: 4), for: open)
        let snapshot = SafariBridgeCommand(taskToken: token, operation: .snapshot, tabId: 17, windowId: 4,
            payload: ["maxBytes": 65_536, "viewportOnly": false])
        XCTAssertTrue(snapshot.isStructurallyValid)
        XCTAssertNoThrow(try bindings.validate(snapshot))
        let response = SafariBridgeResult(command: snapshot, status: .ok, tabId: 17, windowId: 4,
            documentId: "doc-1", resultJSON: #"{"url":"https://example.org/"}"#)
        XCTAssertTrue(response.matches(snapshot))
        XCTAssertFalse(SafariBridgeResult(command: snapshot, status: .ok, tabId: 18, windowId: 4,
            documentId: "doc-1", resultJSON: "{}").matches(snapshot))
        XCTAssertThrowsError(try bindings.validate(SafariBridgeCommand(taskToken: token, operation: .snapshot,
            tabId: 18, windowId: 4, payload: ["maxBytes": 65_536])))
    }
}
