import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseLocalFileCatalogTests: XCTestCase {
    func testCatalogReportsNamesTypesSizesAndDatesWithoutCollapsingSimilarFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Quarterly Review.pptx", bytes: Data([1, 2, 3]))
        try fixture.write("Quarterly Review final.pptx", bytes: Data([4, 5]))
        try fixture.write("Budget.xlsx", bytes: Data([6]))
        try fixture.write("readme.txt", bytes: Data([7, 8, 9, 10]))

        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory, pageSize: 16)
        let page = try catalog.discover()

        XCTAssertTrue(page.isComplete)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(Set(page.candidates.map(\.displayName)), Set([
            "Quarterly Review.pptx", "Quarterly Review final.pptx", "Budget.xlsx", "readme.txt"
        ]))
        let presentation = try XCTUnwrap(page.candidates.first { $0.displayName == "Quarterly Review.pptx" })
        XCTAssertEqual(presentation.fileExtension, "pptx")
        XCTAssertEqual(presentation.byteCount, 3)
        XCTAssertNotNil(presentation.contentTypeIdentifier)
        XCTAssertNotNil(presentation.modifiedAt)
        XCTAssertNotEqual(presentation.id,
            try XCTUnwrap(page.candidates.first { $0.displayName == "Quarterly Review final.pptx" }).id)
        XCTAssertTrue(String(reflecting: page).contains("Quarterly Review.pptx"))
    }

    func testPaginationCursorCoversRemainingPagesOfCompleteInventory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("A.pptx", bytes: Data([1]))
        try fixture.write("B.xlsx", bytes: Data([2]))
        try fixture.write("C.txt", bytes: Data([3]))

        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory, pageSize: 1)
        let first = try catalog.discover()
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertTrue(first.isComplete, "The catalog knows there are more items and can continue the page")
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertFalse(cursor.contains(fixture.directory.path))

        let second = try catalog.nextPage(after: cursor)
        XCTAssertEqual(second.candidates.count, 1)
        XCTAssertTrue(second.isComplete, "Completeness describes the inventory scan, not the current page")
        XCTAssertNotEqual(first.candidates[0].id, second.candidates[0].id)
        let third = try catalog.nextPage(after: XCTUnwrap(second.nextCursor))
        XCTAssertEqual(third.candidates.count, 1)
        XCTAssertTrue(third.isComplete)
        XCTAssertNil(third.nextCursor)
    }

    func testInventoryHardCapReportsIncompleteEvenWhenKnownPagesAreExhausted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<3 { try fixture.write("File-\(index).pptx", bytes: Data([UInt8(index)])) }

        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory,
            pageSize: 1, maximumCandidates: 2)
        let first = try catalog.discover()
        XCTAssertFalse(first.isComplete)
        let second = try catalog.nextPage(after: XCTUnwrap(first.nextCursor))
        XCTAssertFalse(second.isComplete)
        XCTAssertNil(second.nextCursor, "Once the bounded inventory is exhausted, callers must not interpret it as a complete no-match")
    }

    func testResolveRequiresExactCandidateAndSameTaskAndRejectsChangedFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.write("Spec.xlsx", bytes: Data([1, 2]))
        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory)
        let candidate = try XCTUnwrap(catalog.discover().candidates.first)

        XCTAssertEqual(try catalog.resolve(candidateID: candidate.id, taskID: "task-a"), file)
        XCTAssertThrowsError(try catalog.resolve(candidateID: candidate.id, taskID: "task-b")) { error in
            XCTAssertEqual(error as? ComputerUseLocalFileCatalog.Failure, .foreignTask)
        }
        XCTAssertThrowsError(try catalog.resolve(candidateID: file.path, taskID: "task-a")) { error in
            XCTAssertEqual(error as? ComputerUseLocalFileCatalog.Failure, .unknownCandidate)
        }

        try FileManager.default.removeItem(at: file)
        _ = try fixture.write("Spec.xlsx", bytes: Data(repeating: 9, count: 64))
        XCTAssertThrowsError(try catalog.resolve(candidateID: candidate.id, taskID: "task-a")) { error in
            XCTAssertEqual(error as? ComputerUseLocalFileCatalog.Failure, .staleCandidate)
        }
    }

    func testSameSizeEditWithinOneSecondInvalidatesCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.write("Spec.xlsx", bytes: Data([1, 2, 3, 4]))
        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory)
        let candidate = try XCTUnwrap(catalog.discover().candidates.first)
        try Data([4, 3, 2, 1]).write(to: file)
        XCTAssertThrowsError(try catalog.resolve(candidateID: candidate.id, taskID: "task-a")) { error in
            XCTAssertEqual(error as? ComputerUseLocalFileCatalog.Failure, .staleCandidate)
        }
    }

    func testSymlinkAndNonRegularEntriesAreNotCandidates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside.pptx")
        try Data([1, 2, 3]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("linked.pptx"),
            withDestinationURL: outside)
        try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent("Folder.pptx"),
            withIntermediateDirectories: false)
        try fixture.write("Real.pptx", bytes: Data([4]))

        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory)
        let page = try catalog.discover()
        XCTAssertEqual(page.candidates.map(\.displayName), ["Real.pptx"])
        XCTAssertFalse(page.candidates.contains { $0.displayName == "linked.pptx" || $0.displayName == "Folder.pptx" })
    }

    private struct Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var directory: URL { parent.appendingPathComponent("Downloads", isDirectory: true) }

        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        @discardableResult func write(_ name: String, bytes: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }
        func remove() { try? FileManager.default.removeItem(at: parent) }
    }
}
