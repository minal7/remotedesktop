import AppKit
import ApplicationServices
import Foundation

@MainActor
struct AgentNativeFilePickerSnapshot {
    enum Dialog: Equatable {
        case none
        case goToFolder(pathFieldFocused: Bool, path: String?)
        case fileSelection(selectedURLs: [URL], openEnabled: Bool, openIsDefault: Bool)
        case unsupported
    }

    let applicationIdentity: String
    let windowIdentity: String
    let dialog: Dialog
}

@MainActor
protocol AgentNativeFilePickerDriving: AnyObject {
    func snapshot(expectedWindowIdentity: String?) throws -> AgentNativeFilePickerSnapshot
    func pressKey(usage: Int, modifiers: UInt16, expectedWindowIdentity: String) async throws
    func enterText(_ text: String, expectedWindowIdentity: String) async throws
}

/// Drives only the generic macOS file selection dialog. Candidate paths are
/// resolved and revalidated by the host catalog and never enter agent text.
@MainActor
final class AgentNativeFilePicker {
    enum Failure: Error, Equatable {
        case invalidSelection
        case multipleFilesUnsupported
        case inactive
        case applicationChanged
        case windowChanged
        case pickerUnavailable
        case unsafeDialog
        case pathFieldUnavailable
        case unexpectedSelection
        case candidateChanged
        case inputRejected
        case timeout
        case selectionUnconfirmed
    }

    private let catalog: AgentFileCatalog
    private let driver: any AgentNativeFilePickerDriving
    private let mayAct: () -> Bool
    private let wait: @MainActor (Duration) async throws -> Void

    init(catalog: AgentFileCatalog, injector: InputInjector, mayAct: @escaping () -> Bool) {
        self.catalog = catalog
        self.mayAct = mayAct
        driver = AgentNativeFilePickerAccessibilityDriver(injector: injector, mayAct: mayAct)
        wait = { try await Task.sleep(for: $0) }
    }

    init(catalog: AgentFileCatalog, driver: any AgentNativeFilePickerDriving,
         mayAct: @escaping () -> Bool, wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.catalog = catalog
        self.driver = driver
        self.mayAct = mayAct
        self.wait = wait
    }

    func select(_ ids: [String]) async throws -> String {
        guard mayAct() else { throw Failure.inactive }
        guard !ids.isEmpty, ids.count <= 10, Set(ids).count == ids.count else { throw Failure.invalidSelection }
        guard ids.count == 1 else { throw Failure.multipleFilesUnsupported }
        let origin = try driver.snapshot(expectedWindowIdentity: nil)
        try check(origin, expected: nil)
        guard case .fileSelection(let initialSelection, _, _) = origin.dialog else {
            throw Failure.pickerUnavailable
        }

        let id = ids[0]
        let resolvedURL = try await catalog.fileURL(for: id)
        let authorizedURL = resolvedURL.standardizedFileURL
        guard authorizedURL.isFileURL, authorizedURL.path.utf8.count <= 4_096 else { throw Failure.invalidSelection }

        try check(try driver.snapshot(expectedWindowIdentity: origin.windowIdentity), expected: origin)
        let alreadySelected = initialSelection.count == 1 && Self.sameURL(initialSelection[0], authorizedURL)
        if !alreadySelected {
            try await driver.pressKey(usage: 0x0A, modifiers: (1 << 0) | (1 << 3),
                                      expectedWindowIdentity: origin.windowIdentity)
            try await waitForGoTo(origin: origin)

            let goTo = try driver.snapshot(expectedWindowIdentity: origin.windowIdentity)
            try check(goTo, expected: origin)
            guard case .goToFolder(let focused, let currentPath) = goTo.dialog, focused else {
                throw Failure.pathFieldUnavailable
            }
            if let currentPath, !currentPath.isEmpty {
                try await driver.pressKey(usage: 0x04, modifiers: 1 << 3,
                                          expectedWindowIdentity: origin.windowIdentity)
            }
            try await driver.enterText(authorizedURL.path, expectedWindowIdentity: origin.windowIdentity)
            let enteredPath = try driver.snapshot(expectedWindowIdentity: origin.windowIdentity)
            try check(enteredPath, expected: origin)
            guard case .goToFolder(let pathFocused, let pathValue) = enteredPath.dialog,
                  pathFocused, pathValue == authorizedURL.path else { throw Failure.pathFieldUnavailable }
            try await driver.pressKey(usage: 0x28, modifiers: 0, expectedWindowIdentity: origin.windowIdentity)
            try await waitForSelection(origin: origin, expectedURL: authorizedURL)
        }

        let selected = try driver.snapshot(expectedWindowIdentity: origin.windowIdentity)
        try check(selected, expected: origin)
        guard case .fileSelection(let selectedURLs, let openEnabled, let openIsDefault) = selected.dialog,
              selectedURLs.count == 1, Self.sameURL(selectedURLs[0], authorizedURL), openEnabled, openIsDefault else {
            throw Failure.unexpectedSelection
        }
        let revalidatedURL = try await catalog.fileURL(for: id).standardizedFileURL
        guard Self.sameURL(revalidatedURL, authorizedURL) else { throw Failure.candidateChanged }
        try check(try driver.snapshot(expectedWindowIdentity: origin.windowIdentity), expected: origin)
        try await driver.pressKey(usage: 0x28, modifiers: 0, expectedWindowIdentity: origin.windowIdentity)
        try await waitForDismissal(origin: origin)
        return "Selected one authorized file."
    }

    private func waitForGoTo(origin: AgentNativeFilePickerSnapshot) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            let state = try driver.snapshot(expectedWindowIdentity: origin.windowIdentity)
            try check(state, expected: origin)
            if case .goToFolder = state.dialog { return }
            if case .fileSelection = state.dialog { throw Failure.pathFieldUnavailable }
            if case .unsupported = state.dialog { throw Failure.unsafeDialog }
            try await wait(.milliseconds(100))
        }
        throw Failure.timeout
    }

    private func waitForSelection(origin: AgentNativeFilePickerSnapshot, expectedURL: URL) async throws {
        var sawDifferentSelection = false
        for _ in 0..<80 {
            try Task.checkCancellation()
            let state = try driver.snapshot(expectedWindowIdentity: origin.windowIdentity)
            try check(state, expected: origin)
            if case .fileSelection(let urls, _, _) = state.dialog {
                if urls.count == 1, Self.sameURL(urls[0], expectedURL) { return }
                if !urls.isEmpty && (urls.count != 1 || !Self.sameURL(urls[0], expectedURL)) {
                    sawDifferentSelection = true
                }
            } else if case .unsupported = state.dialog {
                throw Failure.unsafeDialog
            }
            try await wait(.milliseconds(100))
        }
        throw sawDifferentSelection ? Failure.unexpectedSelection : Failure.timeout
    }

    private func waitForDismissal(origin: AgentNativeFilePickerSnapshot) async throws {
        for _ in 0..<50 {
            try Task.checkCancellation()
            let state = try driver.snapshot(expectedWindowIdentity: origin.windowIdentity)
            try check(state, expected: origin)
            if case .none = state.dialog { return }
            try await wait(.milliseconds(100))
        }
        throw Failure.selectionUnconfirmed
    }

    private func check(_ snapshot: AgentNativeFilePickerSnapshot,
                       expected: AgentNativeFilePickerSnapshot?) throws {
        guard mayAct() else { throw Failure.inactive }
        if let expected {
            guard snapshot.applicationIdentity == expected.applicationIdentity else { throw Failure.applicationChanged }
            guard snapshot.windowIdentity == expected.windowIdentity else { throw Failure.windowChanged }
        }
    }

    private static func sameURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.isFileURL && rhs.isFileURL && lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}

@MainActor
private final class AgentNativeFilePickerAccessibilityDriver: AgentNativeFilePickerDriving {
    private struct Node {
        let element: AXUIElement
        let role: String
        let identifier: String
    }

    private let reader = AgentMacAccessibility()
    private let injector: InputInjector
    private let mayAct: () -> Bool
    private var boundApplicationIdentity: String?

    init(injector: InputInjector, mayAct: @escaping () -> Bool) {
        self.injector = injector
        self.mayAct = mayAct
    }

    func snapshot(expectedWindowIdentity: String?) throws -> AgentNativeFilePickerSnapshot {
        guard mayAct() else { throw AgentNativeFilePicker.Failure.inactive }
        let window = try reader.window()
        if let expectedWindowIdentity, window.identity != expectedWindowIdentity {
            throw AgentNativeFilePicker.Failure.windowChanged
        }
        guard let bundleID = window.application.bundleIdentifier else { throw AgentNativeFilePicker.Failure.applicationChanged }
        guard string(window.element, kAXRoleAttribute as String) == "AXWindow" else {
            throw AgentNativeFilePicker.Failure.unsafeDialog
        }
        let appIdentity = Self.applicationIdentity(window, bundleID: bundleID)
        if expectedWindowIdentity == nil {
            boundApplicationIdentity = appIdentity
        } else if boundApplicationIdentity != appIdentity {
            throw AgentNativeFilePicker.Failure.applicationChanged
        }
        let nodes = try descendants(of: window.element)
        let appRoot = AXUIElementCreateApplication(window.application.processIdentifier)
        let dialog = try inspect(nodes: nodes, window: window, appRoot: appRoot)
        return AgentNativeFilePickerSnapshot(applicationIdentity: appIdentity, windowIdentity: window.identity, dialog: dialog)
    }

    func pressKey(usage: Int, modifiers: UInt16, expectedWindowIdentity: String) async throws {
        try checkIdentity(expectedWindowIdentity)
        guard injector.apply(.key(usage: usage, down: true, modifiers: modifiers), ifAllowed: admission(expectedWindowIdentity)) else {
            throw AgentNativeFilePicker.Failure.inputRejected
        }
        guard injector.apply(.key(usage: usage, down: false, modifiers: modifiers), ifAllowed: admission(expectedWindowIdentity)) else {
            injector.releaseHeldInput()
            throw AgentNativeFilePicker.Failure.inputRejected
        }
    }

    func enterText(_ text: String, expectedWindowIdentity: String) async throws {
        guard text.utf8.count <= 4_096 else { throw AgentNativeFilePicker.Failure.invalidSelection }
        try checkIdentity(expectedWindowIdentity)
        guard await injector.applyTextPaced(text, ifAllowed: admission(expectedWindowIdentity)) else {
            throw AgentNativeFilePicker.Failure.inputRejected
        }
    }

    private func admission(_ expectedWindowIdentity: String) -> () -> Bool {
        { [weak self] in
            guard let self, self.mayAct(), !Task.isCancelled,
                  let window = try? self.reader.window(),
                  let bundleID = window.application.bundleIdentifier else { return false }
            return window.identity == expectedWindowIdentity
                && Self.applicationIdentity(window, bundleID: bundleID) == self.boundApplicationIdentity
        }
    }

    private func checkIdentity(_ expectedWindowIdentity: String) throws {
        guard mayAct() else { throw AgentNativeFilePicker.Failure.inactive }
        let window = try reader.window()
        guard let bundleID = window.application.bundleIdentifier,
              Self.applicationIdentity(window, bundleID: bundleID) == boundApplicationIdentity else {
            throw AgentNativeFilePicker.Failure.applicationChanged
        }
        guard window.identity == expectedWindowIdentity else { throw AgentNativeFilePicker.Failure.windowChanged }
    }

    private static func applicationIdentity(_ window: AgentMacAccessibility.Window, bundleID: String) -> String {
        "\(window.application.processIdentifier):\(window.application.launchDate?.timeIntervalSince1970 ?? 0):\(bundleID)"
    }

    private func descendants(of root: AXUIElement) throws -> [Node] {
        let deadline = Date().addingTimeInterval(2)
        var queue = [root], cursor = 0, nodes: [Node] = []
        while cursor < queue.count {
            try Task.checkCancellation()
            guard Date() < deadline, nodes.count < 2_000 else { throw AgentNativeFilePicker.Failure.unsafeDialog }
            let element = queue[cursor]; cursor += 1
            let role = string(element, kAXRoleAttribute as String) ?? ""
            let identifier = string(element, "AXIdentifier") ?? ""
            nodes.append(Node(element: element, role: role, identifier: identifier))
            queue.append(contentsOf: array(element, kAXChildrenAttribute as String))
        }
        return nodes
    }

    private func inspect(nodes: [Node], window: AgentMacAccessibility.Window,
                         appRoot: AXUIElement) throws -> AgentNativeFilePickerSnapshot.Dialog {
        let goToSheets = nodes.filter { $0.role == "AXSheet" && $0.identifier == "GoToWindow" }
        if goToSheets.count == 1 {
            let fields = try descendants(of: goToSheets[0].element).filter {
                $0.role == "AXTextField" && $0.identifier == "PathTextField"
            }
            guard fields.count == 1 else { return .unsupported }
            let focusedElement = value(reader.read(appRoot, kAXFocusedUIElementAttribute as String))
            let fieldTree = try descendants(of: fields[0].element)
            let focused = focusedElement.map { focused in
                fieldTree.contains { CFEqual($0.element, focused) }
            } ?? false
            return .goToFolder(pathFieldFocused: focused,
                               path: string(fields[0].element, kAXValueAttribute as String))
        }
        let panels = nodes.filter { node in
            ["AXSheet", "AXWindow"].contains(node.role)
                && (node.identifier == "open-panel" || CFEqual(node.element, window.element))
                && hasFilePanelControls(node.element)
        }
        guard panels.count == 1 else { return nodes.contains(where: { $0.role == "AXSheet" }) ? .unsupported : .none }
        let panelNodes = try descendants(of: panels[0].element)
        let lists = panelNodes.filter { ["AXList", "AXTable", "AXOutline"].contains($0.role) && $0.identifier == "ListView" }
        let buttons = panelNodes.filter { $0.role == "AXButton" && ["OKButton", "OpenButton"].contains($0.identifier) }
        guard lists.count == 1, buttons.count == 1 else { return .unsupported }
        let selected = array(lists[0].element, "AXSelectedChildren")
        let urls = selected.compactMap { selectedRowURL($0) }
        let enabled = (read(buttons[0].element, kAXEnabledAttribute as String) as? Bool) == true
        let defaultButton = value(read(panels[0].element, "AXDefaultButton"))
            ?? value(read(window.element, "AXDefaultButton"))
        let openIsDefault = defaultButton.map { CFEqual($0, buttons[0].element) } ?? false
        return .fileSelection(selectedURLs: urls, openEnabled: enabled, openIsDefault: openIsDefault)
    }

    private func hasFilePanelControls(_ panel: AXUIElement) -> Bool {
        guard let nodes = try? descendants(of: panel) else { return false }
        return nodes.contains(where: { $0.identifier == "ListView" })
            && nodes.contains(where: { ["OKButton", "OpenButton"].contains($0.identifier) })
    }

    private func selectedRowURL(_ row: AXUIElement) -> URL? {
        if let url = fileURL(read(row, "AXURL")) { return url }
        guard let children = try? descendants(of: row) else { return nil }
        return children.dropFirst().compactMap { fileURL(read($0.element, "AXURL")) }.first
    }

    private func fileURL(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL, url.isFileURL { return url }
        if let url = value as? NSURL, url.isFileURL { return url as URL }
        if let text = value as? String, let url = URL(string: text), url.isFileURL { return url }
        return nil
    }

    private func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { read(element, name) as? String }

    private func array(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        read(element, name) as? [AXUIElement] ?? []
    }

    private func value(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
