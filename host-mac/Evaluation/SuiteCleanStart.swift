#if DEBUG
import AppKit
import ApplicationServices
import Darwin
import Foundation

struct SuiteCleanStartRequest {
    let bundleIDs: [String]

    static func decodeStrict(_ data: Data) throws -> Self {
        guard data.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["operation", "bundle_ids"],
              object["operation"] as? String == "suite_clean_start",
              let bundleIDs = object["bundle_ids"] as? [String],
              (1...8).contains(bundleIDs.count), Set(bundleIDs).count == bundleIDs.count,
              bundleIDs.allSatisfy({ id in
                  !id.isEmpty && id.utf8.count <= 255 && id.contains(".") &&
                  id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) } &&
                  !AgentSafetyBoundary.blocksAutomation(bundleID: id, appName: nil) &&
                  !AgentSafetyBoundary.readOnly(bundleID: id, appName: nil)
              }) else { throw AgentEvalWireError.invalidRequest }
        return Self(bundleIDs: bundleIDs)
    }
}

enum SuiteCleanStartWindowRole: Equatable {
    case window, nonWindow, unknown

    static func classify(_ role: String) -> Self {
        switch role {
        case "AXWindow", "AXDialog", "AXSheet": .window
        case "AXScrollArea": .nonWindow
        default: .unknown
        }
    }
}

/// DEBUG-only reset for already-running suite apps. It never launches or terminates apps,
/// sends AppleEvents, or answers unowned save/permission sheets.
@MainActor
enum SuiteCleanStart {
    private final class OverlayEscapeState { var attempted = false; let injector = InputInjector() }

    enum WindowListFailureAction: Equatable {
        case retry, fail(Int32)
    }

    static func windowListFailureAction(code: Int32, deadlineExpired: Bool) -> WindowListFailureAction {
        code == AXError.cannotComplete.rawValue && !deadlineExpired ? .retry : .fail(code)
    }

    static func ownsLoopbackFixtureWindow(url value: String?) -> Bool {
        guard let value, let parts = URLComponents(string: value), parts.scheme == "http",
              parts.host == "127.0.0.1", parts.port == 8765, parts.user == nil, parts.password == nil else {
            return false
        }
        let tokens = parts.queryItems?.filter { $0.name == "__eval_run" }.compactMap(\.value) ?? []
        return tokens.count == 1 && tokens[0].count == 32 &&
            tokens[0].unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    static func ownsNativeScratchDocument(url value: String?, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let value, let parts = URLComponents(string: value), parts.scheme == "file",
              (parts.host == nil || parts.host == "") else { return false }
        let root = homeDirectory.appendingPathComponent("AgentEval", isDirectory: true).standardizedFileURL
        let document = URL(fileURLWithPath: parts.path).standardizedFileURL
        guard document.path.hasPrefix(root.path + "/") else { return false }
        let relative = document.path.dropFirst(root.path.count + 1).split(separator: "/")
        guard relative.count >= 2 else { return false }
        let runName = String(relative[0])
        guard let separator = runName.lastIndex(of: "-"),
              isRunToken(String(runName[runName.index(after: separator)...])) else { return false }
        let runRoot = root.appendingPathComponent(runName, isDirectory: true)
        guard root.resolvingSymlinksInPath().path == root.path,
              runRoot.resolvingSymlinksInPath().path == runRoot.path else { return false }
        let resolvedRun = runRoot.resolvingSymlinksInPath().path
        let resolvedDocument = document.resolvingSymlinksInPath().path
        return resolvedDocument.hasPrefix(resolvedRun + "/") &&
            isPrivateOwnedDirectory(root) && isPrivateOwnedDirectory(runRoot) && isOwnedRegularFile(document)
    }

    static func ownsSuiteWindow(url: String?) -> Bool {
        ownsLoopbackFixtureWindow(url: url) || ownsNativeScratchDocument(url: url)
    }

    private static func isRunToken(_ token: String) -> Bool {
        token.count == 32 && token.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func ownedAttributes(_ url: URL, type: FileAttributeType) -> [FileAttributeKey: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
        return attributes
    }

    private static func isPrivateOwnedDirectory(_ url: URL) -> Bool {
        guard let attributes = ownedAttributes(url, type: .typeDirectory),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else { return false }
        return permissions & 0o077 == 0
    }

    private static func isOwnedRegularFile(_ url: URL) -> Bool {
        ownedAttributes(url, type: .typeRegular) != nil
    }

    static func discardButton(prompt: String, buttonTitles: [String]) -> String? {
        let text = prompt.lowercased()
        guard text.contains("changes will be lost"),
              text.contains("close the window") || text.contains("close this window"),
              text.contains("entered text") || text.contains("changes") else { return nil }
        let normalized = Set(buttonTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if normalized == Set(["cancel", "close"]) { return buttonTitles.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "close" } }
        if normalized == Set(["cancel", "don't save"]) { return buttonTitles.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "don't save" } }
        return nil
    }

    static func run(_ request: SuiteCleanStartRequest) async -> [String: Any] {
        guard AXIsProcessTrusted() else {
            return ["operation": "suite_clean_start", "passed": false, "applications": [],
                    "owner_action": "Enable Accessibility for the signed host, then rerun clean start."]
        }
        let targets = request.bundleIDs.map { bundleID in
            (bundleID, NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID })
        }
        if let (bundleID, app) = targets.first(where: { item in
            AgentSafetyBoundary.blocksAutomation(bundleID: item.0, appName: item.1?.localizedName) ||
            AgentSafetyBoundary.readOnly(bundleID: item.0, appName: item.1?.localizedName)
        }) {
            return ["operation": "suite_clean_start", "passed": false, "applications": [],
                    "owner_action": "Refusing to close protected app \(app?.localizedName ?? bundleID). Remove it from the suite app list."]
        }
        var reports: [[String: Any]] = []
        let overallDeadline = ProcessInfo.processInfo.systemUptime + 18
        let overlayEscape = OverlayEscapeState()
        for (bundleID, maybeApp) in targets {
            guard let app = maybeApp else {
                reports.append(["bundle_id": bundleID, "windows_before": 0, "windows_after": 0, "status": "not_running"])
                continue
            }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.75)
            var stage = "application-root-created"
            var initialCount = -1
            var actionsAttempted = 0
            var pressedWindows: [AXUIElement] = []
            do {
                stage = "initial-AXWindows-query"
                try await dismissSystemVoiceOverlayIfPresent(app: app, root: root, state: overlayEscape)
                let initial = try await windows(root)
                initialCount = initial.count
                while ProcessInfo.processInfo.systemUptime < overallDeadline {
                    stage = "fresh-AXWindows-query"
                    try await dismissSystemVoiceOverlayIfPresent(app: app, root: root, state: overlayEscape)
                    let current = try await windows(root)
                    for (index, window) in current.enumerated() { try ensureNotDialog(window, index: index) }
                    guard let window = current.first else { break }
                    guard !pressedWindows.contains(where: { CFEqual($0, window) }) else {
                        throw CleanStartFailure.windowRemainsAfterSingleClose(current.count)
                    }
                    stage = "initial-window-role[\(actionsAttempted)]"
                    AXUIElementSetMessagingTimeout(window, 0.75)
                    try ensureNotDialog(window, index: actionsAttempted)
                    stage = "close-button-query[\(actionsAttempted)]"
                    let ownedFixtureWindow = fixtureURL(window, deadline: ContinuousClock.now + .milliseconds(500)) != nil
                    var buttonValue: CFTypeRef?
                    let buttonError = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue)
                    guard buttonError == .success, let buttonValue,
                          CFGetTypeID(buttonValue) == AXUIElementGetTypeID() else {
                        throw CleanStartFailure.closeButtonUnavailable
                    }
                    let button = unsafeBitCast(buttonValue, to: AXUIElement.self)
                    AXUIElementSetMessagingTimeout(button, 0.75)
                    stage = "close-button-press[\(actionsAttempted)]"
                    pressedWindows.append(window)
                    actionsAttempted += 1
                    let pressError = AXUIElementPerformAction(button, kAXPressAction as CFString)
                    guard pressError == .success else { throw CleanStartFailure.closeFailed(pressError.rawValue) }
                    stage = "await-disappearance[\(actionsAttempted - 1)]"
                    try await waitUntilGone(window, app: root, bundleID: bundleID, ownedFixtureWindow: ownedFixtureWindow,
                        runningApp: app, overlayEscape: overlayEscape,
                        deadline: min(overallDeadline, ProcessInfo.processInfo.systemUptime + 6))
                }
                stage = "final-AXWindows-query"
                try await dismissSystemVoiceOverlayIfPresent(app: app, root: root, state: overlayEscape)
                let remainingWindows = try await windows(root)
                for (index, window) in remainingWindows.enumerated() { try ensureNotDialog(window, index: index) }
                guard remainingWindows.isEmpty else { throw CleanStartFailure.windowsRemain(remainingWindows.count) }
                reports.append(["bundle_id": bundleID, "windows_before": initial.count,
                                "windows_after": 0, "status": initial.isEmpty ? "already_clear" : "closed"])
            } catch {
                return ["operation": "suite_clean_start", "passed": false, "applications": reports,
                        "owner_action": "Clean start stopped at \(bundleID), stage=\(stage), initial_windows=\(initialCount), close_actions_attempted=\(actionsAttempted): \(error). Resolve any save or system dialog, then rerun."]
            }
        }
        return ["operation": "suite_clean_start", "passed": true, "applications": reports, "owner_action": ""]
    }

    private static func dismissSystemVoiceOverlayIfPresent(app: NSRunningApplication, root: AXUIElement,
                                                           state: OverlayEscapeState) async throws {
        guard let overlays = ElementMarks.systemVoiceOverlayWindows(root, ownerPID: app.processIdentifier), !overlays.isEmpty else { return }
        let alreadySent = state.attempted
        state.attempted = true
        do {
            _ = try await ElementMarks.dismissSystemVoiceOverlayIfPresent(app: app, appRoot: root,
                injector: state.injector, escapeAlreadySent: alreadySent, canInject: {
                    AXIsProcessTrusted() && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                })
        } catch { throw CleanStartFailure.systemOverlay }
    }

    private static func waitUntilGone(_ target: AXUIElement, app: AXUIElement, bundleID: String, ownedFixtureWindow: Bool,
                                     runningApp: NSRunningApplication, overlayEscape: OverlayEscapeState,
                                     deadline: TimeInterval) async throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await dismissOwnedDiscardPrompt(window: target, bundleID: bundleID,
                ownedFixtureWindow: ownedFixtureWindow) { continue }
            try await dismissSystemVoiceOverlayIfPresent(app: runningApp, root: app, state: overlayEscape)
            let current = try await windows(app)
            for (index, window) in current.enumerated() { try ensureNotDialog(window, index: index) }
            if !current.contains(where: { CFEqual($0, target) }) { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        try await dismissSystemVoiceOverlayIfPresent(app: runningApp, root: app, state: overlayEscape)
        let remaining = try await windows(app)
        if remaining.contains(where: { CFEqual($0, target) }) { throw CleanStartFailure.windowsRemain(remaining.count) }
    }

    private static func dismissOwnedDiscardPrompt(window: AXUIElement, bundleID: String,
                                                   ownedFixtureWindow: Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(500)
        let sheets = attachedSheets(window, deadline: deadline)
        guard !sheets.isEmpty else { return false }
        guard ownedFixtureWindow, sheets.count == 1,
              let roleValue = try? attribute(sheets[0], kAXRoleAttribute as String, deadline: deadline),
              let role = roleValue as? String, role == "AXSheet",
              let prompt = sheetStrings(sheets[0], deadline: deadline),
              let buttonTitle = Self.discardButton(prompt: prompt.text, buttonTitles: prompt.buttons.map(\.title)),
              let button = prompt.buttons.first(where: { $0.title == buttonTitle })?.element else {
            throw CleanStartFailure.dialogRequiresOwner("unowned or unrecognized AXSheet in \(bundleID)")
        }
        AXUIElementSetMessagingTimeout(button, 0.75)
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard error == .success else { throw CleanStartFailure.closeFailed(error.rawValue) }
        let waitDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        while ProcessInfo.processInfo.systemUptime < waitDeadline {
            let current = attachedSheets(window, deadline: ContinuousClock.now + .milliseconds(120))
            if !current.contains(where: { CFEqual($0, sheets[0]) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let remaining = attachedSheets(window, deadline: ContinuousClock.now + .milliseconds(120))
        if remaining.contains(where: { CFEqual($0, sheets[0]) }) {
            throw CleanStartFailure.windowsRemain(1)
        }
        return true
    }

    private static func attachedSheets(_ window: AXUIElement, deadline: ContinuousClock.Instant) -> [AXUIElement] {
        if let value = try? attribute(window, "AXSheets", deadline: deadline),
           let sheets = value as? [AXUIElement], !sheets.isEmpty { return sheets }
        var stack = (try? attribute(window, kAXChildrenAttribute as String, deadline: deadline))
            .map(ElementMarks.children) ?? []
        var visited = 0
        var sheets: [AXUIElement] = []
        while !stack.isEmpty && visited < 60 && ContinuousClock.now < deadline {
            let element = stack.removeLast()
            visited += 1
            let role = (try? attribute(element, kAXRoleAttribute as String, deadline: deadline)) as? String
            if role == "AXSheet" || role == "AXDialog" { sheets.append(element); continue }
            if visited < 60 {
                stack.append(contentsOf: (try? attribute(element, kAXChildrenAttribute as String, deadline: deadline))
                    .map(ElementMarks.children) ?? [])
            }
        }
        return sheets
    }

    private struct SheetPrompt {
        let text: String
        let buttons: [(title: String, element: AXUIElement)]
    }

    private static func sheetStrings(_ sheet: AXUIElement, deadline: ContinuousClock.Instant) -> SheetPrompt? {
        var stack = [sheet]
        var visited = 0
        var text: [String] = []
        var buttons: [(String, AXUIElement)] = []
        while !stack.isEmpty && visited < 120 && ContinuousClock.now < deadline {
            let element = stack.removeLast()
            visited += 1
            let role = (try? attribute(element, kAXRoleAttribute as String, deadline: deadline)) as? String
            if ["AXTextField", "AXTextArea", "AXSecureTextField", "AXTextEntryArea"].contains(role ?? "") { return nil }
            for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
                if let value = (try? attribute(element, key, deadline: deadline)) as? String, !value.isEmpty { text.append(value) }
            }
            if role == "AXStaticText",
               let value = (try? attribute(element, kAXValueAttribute as String, deadline: deadline)) as? String,
               !value.isEmpty { text.append(value) }
            if role == "AXButton",
               let title = (try? attribute(element, kAXTitleAttribute as String, deadline: deadline)) as? String,
               !title.isEmpty { buttons.append((title, element)) }
            if let children = (try? attribute(element, kAXChildrenAttribute as String, deadline: deadline)) as? [AXUIElement] {
                stack.append(contentsOf: children.prefix(max(0, 120 - visited - stack.count)))
            }
        }
        return text.isEmpty ? nil : SheetPrompt(text: text.joined(separator: " "), buttons: buttons)
    }

    private static func fixtureURL(_ window: AXUIElement, deadline: ContinuousClock.Instant) -> String? {
        var stack = [window]
        var visited = 0
        while !stack.isEmpty && visited < 160 && ContinuousClock.now < deadline {
            let element = stack.removeLast()
            visited += 1
            let role = (try? attribute(element, kAXRoleAttribute as String, deadline: deadline)) as? String
            if CFEqual(element, window) || role == "AXWebArea" {
                for key in ["AXURL", kAXDocumentAttribute as String] {
                    if let value = try? attribute(element, key, deadline: deadline),
                       let url = rawURL(value), ownsSuiteWindow(url: url) { return url }
                }
            }
            if let children = (try? attribute(element, kAXChildrenAttribute as String, deadline: deadline)) as? [AXUIElement] {
                stack.append(contentsOf: children.prefix(max(0, 160 - visited - stack.count)))
            }
        }
        return nil
    }

    private static func rawURL(_ value: CFTypeRef) -> String? {
        if let string = value as? String { return string }
        guard CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (unsafeBitCast(value, to: CFURL.self) as URL).absoluteString
    }

    private static func attribute(_ element: AXUIElement, _ name: String,
                                  deadline: ContinuousClock.Instant) throws -> CFTypeRef {
        guard ContinuousClock.now < deadline else { throw CleanStartFailure.dialogRequiresOwner("AX deadline expired") }
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else { throw CleanStartFailure.dialogRequiresOwner("AX attribute unavailable: \(name)") }
        return value
    }

    private static func ensureNotDialog(_ window: AXUIElement, index: Int) throws {
        AXUIElementSetMessagingTimeout(window, 0.75)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value)
        guard error == .success, let role = value as? String else {
            throw CleanStartFailure.roleUnavailable(index: index, code: error.rawValue)
        }
        if role == "AXDialog" || role == "AXSheet" { throw CleanStartFailure.dialogRequiresOwner(role) }
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String, subrole == "AXDialog" || subrole == "AXSystemDialog" {
            throw CleanStartFailure.dialogRequiresOwner(subrole)
        }
        var sheetsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &sheetsValue) == .success,
           let sheets = sheetsValue as? [AXUIElement], !sheets.isEmpty {
            throw CleanStartFailure.dialogRequiresOwner("AXSheet")
        }
    }

    private static func windows(_ app: AXUIElement) async throws -> [AXUIElement] {
        let retryDeadline = ProcessInfo.processInfo.systemUptime + 0.4
        var lastUnstableEntry = "unknown AX window role"
        repeat {
            AXUIElementSetMessagingTimeout(app, 0.2)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            if error != .success {
                switch windowListFailureAction(code: error.rawValue,
                    deadlineExpired: ProcessInfo.processInfo.systemUptime >= retryDeadline) {
                case .retry:
                    try await Task.sleep(for: .milliseconds(60))
                    if ProcessInfo.processInfo.systemUptime >= retryDeadline {
                        throw CleanStartFailure.windowListUnavailable(error.rawValue)
                    }
                    continue
                case .fail(let code): throw CleanStartFailure.windowListUnavailable(code)
                }
            }
            guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else {
                throw CleanStartFailure.windowListUnavailable(error.rawValue)
            }
            let array = unsafeBitCast(value, to: CFArray.self)
            var result: [AXUIElement] = []
            var retry = false
            for index in 0..<CFArrayGetCount(array) {
                guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                    lastUnstableEntry = "AXWindows[\(index)] was null"
                    retry = true
                    break
                }
                let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else {
                    lastUnstableEntry = "AXWindows[\(index)] typeID=\(CFGetTypeID(object))"
                    retry = true
                    break
                }
                let window = unsafeBitCast(object, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(window, 0.2)
                var roleValue: CFTypeRef?
                let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
                guard roleError == .success, let role = roleValue as? String else {
                    lastUnstableEntry = "AXWindows[\(index)] roleError=\(roleError.rawValue)"
                    retry = true
                    break
                }
                switch SuiteCleanStartWindowRole.classify(role) {
                case .window: result.append(window)
                case .nonWindow: continue
                case .unknown:
                    lastUnstableEntry = "AXWindows[\(index)] unrecognized role=\(role)"
                    retry = true
                }
                if retry { break }
            }
            if !retry { return result }
            guard ProcessInfo.processInfo.systemUptime < retryDeadline else {
                throw CleanStartFailure.unstableWindowEntry(lastUnstableEntry)
            }
            try await Task.sleep(for: .milliseconds(60))
        } while ProcessInfo.processInfo.systemUptime < retryDeadline
        throw CleanStartFailure.unstableWindowEntry(lastUnstableEntry)
    }
}

private enum CleanStartFailure: Error, CustomStringConvertible {
    case windowListUnavailable(Int32), unstableWindowEntry(String), roleUnavailable(index: Int, code: Int32)
    case dialogRequiresOwner(String), systemOverlay, closeButtonUnavailable, closeFailed(Int32), windowsRemain(Int), windowRemainsAfterSingleClose(Int)
    var description: String {
        switch self {
        case .windowListUnavailable(let code): return "AXWindows query failed (\(code))"
        case .unstableWindowEntry(let detail): return "AX window entry remained invalid after bounded reread: \(detail)"
        case .roleUnavailable(let index, let code): return "AX role query failed windowIndex=\(index) code=\(code)"
        case .dialogRequiresOwner(let role): return "\(role) requires owner action"
        case .systemOverlay: return "system overlay remains after one Escape"
        case .closeButtonUnavailable: return "AX close button unavailable; a dialog may require owner action"
        case .closeFailed(let code): return "AX close action failed (\(code))"
        case .windowsRemain(let count): return "\(count) suite window(s) remain after close"
        case .windowRemainsAfterSingleClose(let count): return "\(count) window(s) remain with no unpressed AX identity"
        }
    }
}

#endif
