import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

final class RemoteDesktopCloudStorageMCPTests: XCTestCase {
    func testProviderEnumerationUsesDirectCloudStorageChildrenAndICloudDrive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        try fixture.directory("Library/CloudStorage/GoogleDrive-account")
        try fixture.directory("Library/CloudStorage/nested/NotAProvider")
        try fixture.directory("Library/Mobile Documents/com~apple~CloudDocs")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.home.appendingPathComponent("Library/CloudStorage/Linked").path,
            withDestinationPath: fixture.home.appendingPathComponent("Library/CloudStorage/Dropbox").path)

        let providers = try fixture.storage().providers()
        XCTAssertEqual(Set(providers.map(\.id)), Set(["cloudstorage:Dropbox", "cloudstorage:GoogleDrive-account", "cloudstorage:nested", "icloud-drive"]))
        XCTAssertFalse(providers.contains { $0.label == "NotAProvider" || $0.id == "cloudstorage:Linked" })
    }

    func testPrepareOverridesModelHostFieldsAndCopyVerifiesHashesWithoutChangingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        let source = try fixture.source("Board Review.pptx", bytes: Data("presentation bytes".utf8))
        let storage = fixture.storage(uploadState: .uploaded)
        var arguments = fixture.arguments(source: source, hostFields: true)
        arguments["relative_folder"] = .string("Projects/Quarterly Review")
        let prepared = try await storage.prepare(arguments: arguments)

        XCTAssertFalse(prepared.needsReplacementApproval)
        let destination = fixture.dropbox.appendingPathComponent("Projects/Quarterly Review/Board Review.pptx")
        XCTAssertEqual(prepared.arguments["destination_path"], .string(destination.path))
        XCTAssertEqual(prepared.arguments["source_sha256"], .string(Fixture.sha256(Data("presentation bytes".utf8))))
        XCTAssertEqual(prepared.arguments["existing_destination_sha256"], .null)

        let result = try await storage.perform(arguments: prepared.arguments)
        let copiedURL = destination
        XCTAssertEqual(try Data(contentsOf: copiedURL), Data("presentation bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("presentation bytes".utf8))
        XCTAssertEqual(result.structuredContent?["destination_sha256"], prepared.arguments["source_sha256"])
        XCTAssertEqual(result.structuredContent?["upload_state"], .string("uploaded"))

        let call = try fixture.call(arguments: prepared.arguments)
        let verified = try RemoteDesktopCloudStorage.verified(call: call, result: result, trustedUserPrompt: "Save the presentation to Dropbox")
        XCTAssertEqual(verified.response, "Saved to Dropbox › Projects/Quarterly Review · uploaded")
        XCTAssertEqual(verified.callDigest, call.canonicalDigest)
        XCTAssertEqual(verified.completionPromptDigest, try MCPDigest.sha256(of: .string("Save the presentation to Dropbox")))
    }

    func testExistingDestinationRequiresApprovalAndRejectsChangedSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        let source = try fixture.source("Plan.pdf", bytes: Data("new".utf8))
        let destination = fixture.dropbox.appendingPathComponent("Plan.pdf")
        try Data("old".utf8).write(to: destination)
        let prepared = try await fixture.storage().prepare(arguments: fixture.arguments(source: source))
        XCTAssertTrue(prepared.needsReplacementApproval)
        XCTAssertEqual(prepared.arguments["existing_destination_sha256"], .string(Fixture.sha256(Data("old".utf8))))

        try Data("changed after preparation".utf8).write(to: destination)
        do {
            _ = try await fixture.storage().perform(arguments: prepared.arguments)
            XCTFail("Changed destination must not be replaced")
        } catch let error as RemoteDesktopCloudStorage.Failure {
            XCTAssertEqual(error, .destinationChanged)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("changed after preparation".utf8))
    }

    func testTraversalSymlinkAndUnapprovedSourceAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        let source = try fixture.source("Report.txt", bytes: Data("ok".utf8))
        var args = fixture.arguments(source: source)
        args["relative_folder"] = .string("../outside")
        XCTAssertThrowsError(try RemoteDesktopCloudStorage.validateArguments(args))

        let outside = try fixture.source("outside.txt", bytes: Data("outside".utf8), in: "tmp")
        do {
            _ = try await fixture.storage().prepare(arguments: fixture.arguments(source: outside))
            XCTFail("Source outside an approved root must be rejected")
        } catch let error as RemoteDesktopCloudStorage.Failure {
            XCTAssertEqual(error, .sourceUnavailable)
        }

        let link = fixture.home.appendingPathComponent("Downloads/alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do {
            _ = try await fixture.storage().prepare(arguments: fixture.arguments(source: link))
            XCTFail("A symlink source must be rejected")
        } catch let error as RemoteDesktopCloudStorage.Failure {
            XCTAssertEqual(error, .sourceUnavailable)
        }
    }

    func testRelativeFolderSchemaMatchesHostValidation() throws {
        let schema = RemoteDesktopCloudStorageMCP.inputSchema(providers: [])
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"],
              case .object(let folderSchema)? = properties["relative_folder"],
              case .string(let pattern)? = folderSchema["pattern"],
              case .string(let description)? = folderSchema["description"] else {
            return XCTFail("The planner schema must describe and constrain relative folder segments")
        }
        XCTAssertTrue(description.contains("provider root"))
        let expression = try NSRegularExpression(pattern: pattern)
        let cases: [(String, Bool)] = [
            ("", true),
            ("Projects/Quarterly Review", true),
            ("folder.with.periods", true),
            (".", false),
            ("..", false),
            ("/absolute", false),
            ("../escape", false),
            ("Projects/../escape", false),
            ("folder/", false),
            ("folder//child", false),
            ("folder\\child", false),
            ("folder:name", false),
            ("folder\0name", false),
        ]
        for (folder, expectedValid) in cases {
            let range = NSRange(folder.startIndex..<folder.endIndex, in: folder)
            let schemaValid = expression.firstMatch(in: folder, range: range)?.range == range
            let arguments: [String: MCPJSONValue] = [
                "source_path": .string("/Users/example/Downloads/source.txt"),
                "provider_id": .string("cloudstorage:Dropbox"),
                "relative_folder": .string(folder),
            ]
            XCTAssertEqual(schemaValid, expectedValid, "Schema validity for folder segment input")
            XCTAssertEqual((try? RemoteDesktopCloudStorage.validateArguments(arguments)) != nil,
                           expectedValid, "Host validation for folder segment input")
        }
    }

    func testUnknownAndPendingUploadStatesNeverClaimUploaded() async throws {
        for (injected, expectedResponse, expectedState) in [
            (RemoteDesktopCloudStorage.UploadState.unknown, "copied, upload status unknown", "unknown"),
            (.uploading, "Copied to Dropbox; upload is still pending.", "uploading"),
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.directory("Library/CloudStorage/Dropbox")
            let source = try fixture.source("Notes.txt", bytes: Data("note".utf8))
            let storage = fixture.storage(uploadState: injected, uploadTimeout: 0)
            let prepared = try await storage.prepare(arguments: fixture.arguments(source: source))
            let result = try await storage.perform(arguments: prepared.arguments)
            let verified = try RemoteDesktopCloudStorage.verified(
                call: fixture.call(arguments: prepared.arguments), result: result, trustedUserPrompt: "Save notes")
            XCTAssertEqual(result.structuredContent?["upload_state"], .string(expectedState))
            XCTAssertEqual(verified.response, expectedResponse)
            XCTAssertFalse(verified.response.localizedCaseInsensitiveContains("uploaded"))
        }
    }

    func testCancellationBeforeAtomicPublicationLeavesNoDestinationOrStage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        let source = try fixture.source("Cancel.txt", bytes: Data("cancel me".utf8))
        let enteredPublication = expectation(description: "copy is staged before publication")
        let releasePublication = DispatchSemaphore(value: 0)
        let storage = RemoteDesktopCloudStorage(
            homeURL: fixture.home, uploadTimeout: 0,
            uploadResourceReader: { _ in .unknown },
            beforePublish: {
                enteredPublication.fulfill()
                releasePublication.wait()
            })
        let prepared = try await storage.prepare(arguments: fixture.arguments(source: source))
        let task = Task { try await storage.perform(arguments: prepared.arguments) }
        await fulfillment(of: [enteredPublication], timeout: 5)
        task.cancel()
        releasePublication.signal()
        do {
            _ = try await task.value
            XCTFail("Canceled copy must not publish")
        } catch is CancellationError {
            // Expected: the cancellation token is checked after the coordinated wait.
        }
        let destination = fixture.dropbox.appendingPathComponent("Cancel.txt")
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 3
        var entries = try FileManager.default.contentsOfDirectory(atPath: fixture.dropbox.path)
        while !entries.isEmpty, ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
            entries = try FileManager.default.contentsOfDirectory(atPath: fixture.dropbox.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(entries.isEmpty, "Only the operation-owned staged item is cleaned up")
    }

    func testStoppingSessionCancelsStagedCopyBeforePublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        let source = try fixture.source("Stop.txt", bytes: Data("stop me".utf8))
        let enteredPublication = expectation(description: "copy is staged before publication")
        let releasePublication = DispatchSemaphore(value: 0)
        let storage = fixture.storage(uploadState: .unknown, beforePublish: {
            enteredPublication.fulfill()
            releasePublication.wait()
        })
        let prepared = try await storage.prepare(arguments: fixture.arguments(source: source))
        let session = RemoteDesktopCloudStorageMCPClientSession(processGeneration: 91, storage: storage)
        _ = try await session.start()
        let call = try fixture.call(arguments: prepared.arguments, processGeneration: 91)
        let execution = Task { try await session.execute(call) }
        await fulfillment(of: [enteredPublication], timeout: 5)
        await session.stop()
        releasePublication.signal()
        do {
            _ = try await execution.value
            XCTFail("Stopping a session must cancel its active copy")
        } catch is CancellationError {
            // Expected: stop cancels the tracked operation before publication.
        }

        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 3
        var entries = try FileManager.default.contentsOfDirectory(atPath: fixture.dropbox.path)
        while !entries.isEmpty, ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
            entries = try FileManager.default.contentsOfDirectory(atPath: fixture.dropbox.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dropbox.appendingPathComponent("Stop.txt").path))
        XCTAssertTrue(entries.isEmpty)
    }

    func testVerifierRejectsReceiptForAnotherDestinationOrHash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Library/CloudStorage/Dropbox")
        let source = try fixture.source("One.txt", bytes: Data("one".utf8))
        let prepared = try await fixture.storage(uploadState: .uploaded).prepare(arguments: fixture.arguments(source: source))
        let result = try await fixture.storage(uploadState: .uploaded).perform(arguments: prepared.arguments)
        let call = try fixture.call(arguments: prepared.arguments)
        let badFields: [String: MCPJSONValue] = [
            "status": .string("copied"), "provider_id": .string("cloudstorage:Dropbox"),
            "provider_label": .string("Dropbox"), "relative_folder": .string(""),
            "destination_path": .string("/foreign/file"),
            "source_sha256": prepared.arguments["source_sha256"]!,
            "destination_sha256": prepared.arguments["source_sha256"]!,
            "upload_state": .string("uploaded"),
        ]
        let forged = try MCPToolResult(text: "done", structuredContent: .object(badFields), isError: false, wasTruncated: false)
        XCTAssertThrowsError(try RemoteDesktopCloudStorage.verified(call: call, result: forged, trustedUserPrompt: "Save"))
        XCTAssertNoThrow(try RemoteDesktopCloudStorage.verified(call: call, result: result, trustedUserPrompt: "Save"))
    }

    private struct Fixture {
        let home: URL
        let dropbox: URL

        init() throws {
            let rawHome = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-storage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rawHome, withIntermediateDirectories: true)
            var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(rawHome.path, &resolvedPath) != nil else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            home = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
            dropbox = home.appendingPathComponent("Library/CloudStorage/Dropbox", isDirectory: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Downloads", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop", isDirectory: true), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
        func directory(_ relative: String) throws -> URL {
            let value = home.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        func source(_ name: String, bytes: Data, in relative: String = "Downloads") throws -> URL {
            let folder = try directory(relative)
            let value = folder.appendingPathComponent(name)
            try bytes.write(to: value)
            return value
        }
        func storage(uploadState: RemoteDesktopCloudStorage.UploadState = .unknown,
                     uploadTimeout: TimeInterval = 0.1,
                     beforePublish: @escaping @Sendable () throws -> Void = {}) -> RemoteDesktopCloudStorage {
            RemoteDesktopCloudStorage(homeURL: home, uploadTimeout: uploadTimeout, pollInterval: 0.05,
                                      uploadResourceReader: { _ in uploadState }, beforePublish: beforePublish)
        }
        func arguments(source: URL, hostFields: Bool = false) -> [String: MCPJSONValue] {
            var value: [String: MCPJSONValue] = [
                "source_path": .string(source.path), "provider_id": .string("cloudstorage:Dropbox"), "relative_folder": .string(""),
            ]
            if hostFields {
                value["source_sha256"] = .string(String(repeating: "0", count: 64))
                value["destination_path"] = .string("/model/invented/path")
                value["existing_destination_sha256"] = .string(String(repeating: "f", count: 64))
            }
            return value
        }
        func call(arguments: [String: MCPJSONValue], processGeneration: UInt64 = 7) throws -> MCPToolCall {
            let schema = RemoteDesktopCloudStorageMCP.inputSchema(providers: [
                .init(id: "cloudstorage:Dropbox", label: "Dropbox", rootURL: dropbox),
            ])
            return try MCPToolCall(taskID: "cloud-storage-test", serverID: RemoteDesktopCloudStorageMCP.serverID,
                                   processGeneration: processGeneration, toolName: RemoteDesktopCloudStorageMCP.toolName,
                                   arguments: arguments, schemaDigest: try MCPDigest.sha256(of: schema),
                                   risk: .approvalRequired,
                                   approval: MCPApprovalDisplay(summary: "Save copy", details: "Copy file", confirmLabel: "Save"))
        }
        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

private extension MCPJSONValue {
    subscript(_ key: String) -> MCPJSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }
}
