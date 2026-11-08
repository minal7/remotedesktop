import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentFileCatalogTests: XCTestCase {
    func testFindReturnsOnlyMetadataAndResolveReturnsValidatedBytesInRequestedOrder() async throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBytes = Data("first fixture".utf8)
        let secondBytes = Data("second fixture".utf8)
        try firstBytes.write(to: root.appendingPathComponent("Alpha Report.txt"))
        try secondBytes.write(to: root.appendingPathComponent("Beta Report.txt"))
        let catalog = AgentFileCatalog(authorizedRoots: [root])

        let candidates = try await catalog.find(query: "report", kind: "text")

        XCTAssertEqual(candidates.map(\.name).sorted(), ["Alpha Report.txt", "Beta Report.txt"])
        XCTAssertTrue(candidates.allSatisfy { !$0.id.contains("/") && !$0.name.contains(root.path) })
        XCTAssertFalse(candidates.contains { $0.id.contains(root.path) })
        let selected = [candidates[1], candidates[0]]
        let files = try await catalog.resolve(selected.map(\.id))
        XCTAssertEqual(files.map(\.id), selected.map(\.id))
        XCTAssertEqual(files.map(\.name), selected.map(\.name))
        let bytesByName = ["Alpha Report.txt": firstBytes, "Beta Report.txt": secondBytes]
        XCTAssertEqual(files.map(\.bytes), selected.map { bytesByName[$0.name]! })
        XCTAssertTrue(files.allSatisfy { $0.mimeType == "text/plain" })
        let selectedURL = try await catalog.fileURL(for: selected[0].id)
        XCTAssertEqual(selectedURL.standardizedFileURL,
                       root.appendingPathComponent(selected[0].name).standardizedFileURL)
    }

    func testSearchUsesFilenameTermsKindAndModifiedAfterWithNewestFirstOrdering() async throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("Report Old.txt")
        let newFile = root.appendingPathComponent("Report New.txt")
        try Data("old".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(30)], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(60)], ofItemAtPath: newFile.path)
        let catalog = AgentFileCatalog(authorizedRoots: [root], maximumResults: 1)

        let found = try await catalog.find(query: "report", kind: "public.plain-text",
                                           modifiedAfter: ISO8601DateFormatter().string(from: cutoff))
        XCTAssertEqual(found.map(\.name), ["Report New.txt"])
        let imageMatches = try await catalog.find(query: "report", kind: "image")
        XCTAssertTrue(imageMatches.isEmpty)
    }

    func testSymlinkSourcesAreSkippedAndChangedCandidatesCannotBeResolved() async throws {
        let parent = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let outside = parent.appendingPathComponent("outside.txt")
        try Data("outside secret fixture".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Outside Report.txt"),
                                                   withDestinationURL: outside)
        try Data("stable fixture".utf8).write(to: root.appendingPathComponent("Stable Report.txt"))
        let catalog = AgentFileCatalog(authorizedRoots: [root])

        let candidates = try await catalog.find(query: "report")
        XCTAssertEqual(candidates.map(\.name), ["Stable Report.txt"])
        try Data("changed fixture".utf8).write(to: root.appendingPathComponent("Stable Report.txt"))
        do {
            _ = try await catalog.resolve([candidates[0].id])
            XCTFail("A file changed after search was returned")
        } catch {
            guard let failure = error as? AgentFileCatalog.Failure,
                  case .staleCandidate = failure else { XCTFail("Unexpected error: \(error)"); return }
        }
    }

    func testInvalidAndDuplicateIDsFailClosedAndRootsCannotBeSymlinks() async throws {
        let parent = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("fixture".utf8).write(to: root.appendingPathComponent("Item.txt"))
        let catalog = AgentFileCatalog(authorizedRoots: [root])
        let items = try await catalog.find(query: "item")
        let item = try XCTUnwrap(items.first)
        do {
            _ = try await catalog.resolve([item.id, item.id])
            XCTFail("Duplicate IDs were accepted")
        } catch { XCTAssertTrue(error is AgentFileCatalog.Failure) }
        do {
            _ = try await catalog.resolve(["unknown-id"])
            XCTFail("Unknown ID was accepted")
        } catch { XCTAssertTrue(error is AgentFileCatalog.Failure) }

        let link = parent.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let unsafeCatalog = AgentFileCatalog(authorizedRoots: [link])
        do {
            _ = try await unsafeCatalog.find(query: "item")
            XCTFail("A symlink root was accepted")
        } catch {
            guard let failure = error as? AgentFileCatalog.Failure,
                  case .unsafeRoot = failure else { XCTFail("Unexpected error: \(error)"); return }
        }
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }
}
