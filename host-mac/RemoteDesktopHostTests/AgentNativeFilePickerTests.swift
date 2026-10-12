import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentNativeFilePickerTests: XCTestCase {
    func testSelectsOnlyCatalogBoundSelectionAndConfirmsThroughInputDriver() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let catalog = AgentFileCatalog(authorizedRoots: [fixture.root])
        let candidates = try await catalog.find(query: "sample")
        let candidate = try XCTUnwrap(candidates.first)
        let expectedURL = try await catalog.fileURL(for: candidate.id)
        let driver = PickerDriver(selectedURL: expectedURL)
        let picker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { true }, wait: { _ in })

        let result = try await picker.select([candidate.id])

        XCTAssertEqual(result, "Selected one authorized file.")
        XCTAssertEqual(driver.keyUsages, [0x0A, 0x28, 0x28])
        XCTAssertEqual(driver.enteredText, [expectedURL.path])
        XCTAssertEqual(driver.finalWindowIdentity, "window-a")
    }

    func testDifferentAXSelectedURLNeverReceivesConfirmationReturn() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let catalog = AgentFileCatalog(authorizedRoots: [fixture.root])
        let candidates = try await catalog.find(query: "sample")
        let candidate = try XCTUnwrap(candidates.first)
        let driver = PickerDriver(selectedURL: URL(fileURLWithPath: "/tmp/other.txt"))
        let picker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { true }, wait: { _ in })

        do {
            _ = try await picker.select([candidate.id])
            XCTFail("The picker must reject a different selected URL")
        } catch {
            XCTAssertEqual(error as? AgentNativeFilePicker.Failure, .unexpectedSelection)
        }
        XCTAssertEqual(driver.keyUsages, [0x0A, 0x28])
    }

    func testMultipleIDsAndInactiveGateNeverOpenPicker() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let catalog = AgentFileCatalog(authorizedRoots: [fixture.root])
        let candidates = try await catalog.find(query: "sample")
        let candidate = try XCTUnwrap(candidates.first)
        let driver = PickerDriver(selectedURL: URL(fileURLWithPath: "/tmp/other.txt"))
        let picker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { false }, wait: { _ in })

        do {
            _ = try await picker.select([candidate.id])
            XCTFail("Inactive automation must not select a file")
        } catch {
            XCTAssertEqual(error as? AgentNativeFilePicker.Failure, .inactive)
        }
        XCTAssertTrue(driver.keyUsages.isEmpty)

        let activePicker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { true }, wait: { _ in })
        do {
            _ = try await activePicker.select([candidate.id, candidate.id + "-duplicate"])
            XCTFail("Multi-file selection is not supported yet")
        } catch {
            XCTAssertEqual(error as? AgentNativeFilePicker.Failure, .multipleFilesUnsupported)
        }
        XCTAssertTrue(driver.keyUsages.isEmpty)
    }

    func testWindowChangeBeforeConfirmationStopsInput() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let catalog = AgentFileCatalog(authorizedRoots: [fixture.root])
        let candidates = try await catalog.find(query: "sample")
        let candidate = try XCTUnwrap(candidates.first)
        let driver = PickerDriver(selectedURL: try await catalog.fileURL(for: candidate.id),
                                  changeWindowAfterPath: true)
        let picker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { true }, wait: { _ in })

        do {
            _ = try await picker.select([candidate.id])
            XCTFail("The dialog must remain bound to its captured window")
        } catch {
            XCTAssertEqual(error as? AgentNativeFilePicker.Failure, .windowChanged)
        }
        XCTAssertEqual(driver.keyUsages, [0x0A, 0x28])
    }

    func testOrdinaryWindowIsRejectedBeforeAnyKeyboardInput() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let catalog = AgentFileCatalog(authorizedRoots: [fixture.root])
        let candidates = try await catalog.find(query: "sample")
        let candidate = try XCTUnwrap(candidates.first)
        let driver = PickerDriver(selectedURL: URL(fileURLWithPath: "/tmp/other.txt"), hasPicker: false)
        let picker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { true }, wait: { _ in })

        do {
            _ = try await picker.select([candidate.id])
            XCTFail("The action must be confined to a recognized file picker")
        } catch {
            XCTAssertEqual(error as? AgentNativeFilePicker.Failure, .pickerUnavailable)
        }
        XCTAssertTrue(driver.keyUsages.isEmpty)
    }

    func testSelectionWithoutDefaultOpenButtonIsNotConfirmed() async throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let catalog = AgentFileCatalog(authorizedRoots: [fixture.root])
        let candidates = try await catalog.find(query: "sample")
        let candidate = try XCTUnwrap(candidates.first)
        let url = try await catalog.fileURL(for: candidate.id)
        let driver = PickerDriver(selectedURL: url, openIsDefault: false)
        let picker = AgentNativeFilePicker(catalog: catalog, driver: driver, mayAct: { true }, wait: { _ in })

        do {
            _ = try await picker.select([candidate.id])
            XCTFail("The selected item must not be confirmed through another dialog action")
        } catch {
            XCTAssertEqual(error as? AgentNativeFilePicker.Failure, .unexpectedSelection)
        }
        XCTAssertEqual(driver.keyUsages, [0x0A, 0x28])
    }
}

@MainActor
private final class PickerDriver: AgentNativeFilePickerDriving {
    private enum Stage { case initialSelection, goTo, selection, dismissed, ordinaryWindow }
    private(set) var keyUsages: [Int] = []
    private(set) var enteredText: [String] = []
    private(set) var finalWindowIdentity: String?
    private var stage: Stage
    private var path = ""
    private let selectedURL: URL
    private let changeWindowAfterPath: Bool
    private let openIsDefault: Bool
    private var windowIdentity = "window-a"

    init(selectedURL: URL, changeWindowAfterPath: Bool = false, hasPicker: Bool = true,
         openIsDefault: Bool = true) {
        self.selectedURL = selectedURL
        self.changeWindowAfterPath = changeWindowAfterPath
        self.openIsDefault = openIsDefault
        stage = hasPicker ? .initialSelection : .ordinaryWindow
    }

    func snapshot(expectedWindowIdentity: String?) throws -> AgentNativeFilePickerSnapshot {
        if let expectedWindowIdentity, expectedWindowIdentity != windowIdentity {
            throw AgentNativeFilePicker.Failure.windowChanged
        }
        let dialog: AgentNativeFilePickerSnapshot.Dialog
        switch stage {
        case .dismissed, .ordinaryWindow: dialog = .none
        case .initialSelection: dialog = .fileSelection(selectedURLs: [], openEnabled: false, openIsDefault: false)
        case .goTo: dialog = .goToFolder(pathFieldFocused: true, path: path)
        case .selection: dialog = .fileSelection(selectedURLs: [selectedURL], openEnabled: true, openIsDefault: openIsDefault)
        }
        return .init(applicationIdentity: "app-a", windowIdentity: windowIdentity, dialog: dialog)
    }

    func pressKey(usage: Int, modifiers: UInt16, expectedWindowIdentity: String) async throws {
        guard expectedWindowIdentity == windowIdentity else { throw AgentNativeFilePicker.Failure.windowChanged }
        keyUsages.append(usage)
        finalWindowIdentity = expectedWindowIdentity
        switch (stage, usage) {
        case (.initialSelection, 0x0A): stage = .goTo
        case (.goTo, 0x28):
            stage = .selection
            if changeWindowAfterPath { windowIdentity = "window-b" }
        case (.selection, 0x28): stage = .dismissed
        default: break
        }
    }

    func enterText(_ text: String, expectedWindowIdentity: String) async throws {
        guard expectedWindowIdentity == windowIdentity else { throw AgentNativeFilePicker.Failure.windowChanged }
        enteredText.append(text)
        path = text
    }
}

private struct FileFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sample content".utf8).write(to: root.appendingPathComponent("sample.txt"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
