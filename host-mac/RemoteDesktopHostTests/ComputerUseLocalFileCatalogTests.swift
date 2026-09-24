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

    func testTypedQueryFiltersThenSortsTheWholeInventoryBeforeFirstPage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["A.pptx", "B.pptx", "C.pptx"] { try fixture.write(name, bytes: Data([1])) }
        try fixture.write("newer-non-presentation.txt", bytes: Data([2]))

        // Use the existing unsorted pagination to choose a presentation known
        // to be outside its first page, independent of filesystem enumeration.
        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory, pageSize: 1)
        var rawPage = try catalog.discover()
        var raw = rawPage.candidates
        while let cursor = rawPage.nextCursor {
            rawPage = try catalog.nextPage(after: cursor)
            raw.append(contentsOf: rawPage.candidates)
        }
        let firstName = try XCTUnwrap(raw.first?.displayName)
        let targetName = try XCTUnwrap(raw.dropFirst().first { $0.fileExtension == "pptx" }?.displayName)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for name in ["A.pptx", "B.pptx", "C.pptx"] {
            try fixture.setModified(name, to: base)
        }
        try fixture.setModified(targetName, to: base.addingTimeInterval(100))
        try fixture.setModified("newer-non-presentation.txt", to: base.addingTimeInterval(200))

        let first = try catalog.discover(query: .init(fileKind: .presentation,
            sort: .init(field: .modifiedAt, direction: .descending)))
        XCTAssertEqual(first.candidates.map(\.displayName), [targetName])
        XCTAssertNotEqual(first.candidates.first?.displayName, firstName)
        XCTAssertTrue(first.isComplete)
        let second = try catalog.nextPage(after: XCTUnwrap(first.nextCursor))
        XCTAssertEqual(second.candidates.count, 1)
        XCTAssertFalse(second.candidates.contains { $0.displayName == "newer-non-presentation.txt" })
        XCTAssertNotEqual(first.candidates.first?.id, second.candidates.first?.id)
        XCTAssertEqual(try catalog.resolve(candidateID: XCTUnwrap(first.candidates.first).id, taskID: "task-a"),
            fixture.directory.appendingPathComponent(targetName))
    }

    func testTypedDateSortReportsGlobalTiesAndDoesNotReplaceMissingDates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tiedDate = Date(timeIntervalSince1970: 1_700_000_123)
        try fixture.write("Alpha.pptx", bytes: Data([1]), modifiedAt: tiedDate)
        try fixture.write("Beta.pptx", bytes: Data([2]), modifiedAt: tiedDate)
        try fixture.write("Notes.txt", bytes: Data([3]), modifiedAt: tiedDate)

        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory, pageSize: 1)
        let first = try catalog.discover(query: .init(fileKind: .presentation,
            sort: .init(field: .modifiedAt, direction: .descending)))
        XCTAssertTrue(first.hasTiedSortValues, "Tie diagnostics cover the complete query result, not only this page")
        XCTAssertEqual(first.candidates.map(\.displayName), ["Alpha.pptx"], "Date ties use a deterministic filename tie-break")
        let second = try catalog.nextPage(after: XCTUnwrap(first.nextCursor))
        XCTAssertEqual(second.candidates.map(\.displayName), ["Beta.pptx"])

        var originalMetadataCatalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory)
        let originalMetadata = try originalMetadataCatalog.discover().candidates
        let originalAddedDates = Dictionary(uniqueKeysWithValues: originalMetadata.map { ($0.displayName, $0.addedToDirectoryAt) })
        var addedDateCatalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory, pageSize: 1)
        let datePage = try addedDateCatalog.discover(query: .init(fileKind: .any,
            sort: .init(field: .addedToDirectoryAt, direction: .descending)))
        var dateCandidates = datePage.candidates
        var current = datePage
        while let cursor = current.nextCursor {
            current = try addedDateCatalog.nextPage(after: cursor)
            dateCandidates.append(contentsOf: current.candidates)
        }
        XCTAssertEqual(datePage.hasMissingSortValues, dateCandidates.contains { $0.addedToDirectoryAt == nil })
        for candidate in dateCandidates {
            XCTAssertEqual(candidate.addedToDirectoryAt, originalAddedDates[candidate.displayName],
                "Sorting preserves the exact optional date; it never substitutes another timestamp")
        }
    }

    func testNewQueryInvalidatesPriorCursorAndCandidateIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("A.pptx", bytes: Data([1]))
        try fixture.write("B.xlsx", bytes: Data([2]))
        var catalog = try ComputerUseLocalFileCatalog(taskID: "task-a", approvedDirectory: fixture.directory, pageSize: 1)
        let first = try catalog.discover(query: .init(fileKind: .any))
        XCTAssertEqual(first.candidates.count, 1)
        let staleCandidateID = try XCTUnwrap(first.candidates.first?.id)
        let staleCursor = try XCTUnwrap(first.nextCursor)
        let refreshed = try catalog.discover(query: .init(fileKind: .presentation))
        XCTAssertEqual(refreshed.candidates.count, 1)
        XCTAssertThrowsError(try catalog.nextPage(after: staleCursor)) { error in
            XCTAssertEqual(error as? ComputerUseLocalFileCatalog.Failure, .unknownCursor)
        }
        XCTAssertThrowsError(try catalog.resolve(candidateID: staleCandidateID, taskID: "task-a")) { error in
            XCTAssertEqual(error as? ComputerUseLocalFileCatalog.Failure, .unknownCandidate)
        }
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
        @discardableResult func write(_ name: String, bytes: Data, modifiedAt: Date? = nil) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            if let modifiedAt { try setModified(name, to: modifiedAt) }
            return url
        }
        func setModified(_ name: String, to date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        func remove() { try? FileManager.default.removeItem(at: parent) }
    }
}
